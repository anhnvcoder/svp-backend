# Phát hành checker của `svp-gitops`, nâng ghim và đổi hợp đồng chéo repo

- Quy trình làm tay, không có cảnh báo. Mở khi đổi luật mà checker kiểm cây `svp-gitops` (hợp đồng chéo repo), khi duyệt PR phát hành
  `gitops-check` ở repo này hay PR Renovate nâng ghim checker ở `svp-gitops`, và khi một bản phát hành sai (tag lạ, bản mới làm đỏ cây).
- Thiết kế và lý do: [ADR-0077](../adr/0077-versioned-gitops-checker.md) (§1 checker, §2 release-please, §3 workflow và App, §4 tag bất biến,
  §5 ghim, §6 expand–contract, §7 phạm vi phiên bản). Luồng bằng sơ đồ: [`explanation/delivery.md`](../explanation/delivery.md#phát-hành-checker).
- Trạng thái: viết theo code, chưa chạy thử; lượt đầu (PR `1.0.0`, tag `gitops-check-v1.0.0`) kiểm theo mục Xác nhận của ADR-0077.
- Mọi lệnh "Kiểm" chỉ đọc, chạy bằng đăng nhập `gh` của người học. Không in khoá App `svp-release-please` ở đâu.

## Ý nghĩa và tác động tới người dùng

Check bắt buộc `gitops-ok` của `svp-gitops` chạy **checker** (`deploy/ci/gitops-check.sh` và file nó đọc trong `deploy/ci/`) của repo này ở
một bản phát hành: `check.yml` ghim `CHECKER_VERSION` (semver) cùng `CHECKER_COMMIT` (commit của tag `gitops-check-v<CHECKER_VERSION>`), và một
bước đỏ khi tag không trỏ đúng commit đó. Đường phát hành:

1. Commit `feat`, `fix`, `perf` đổi file dưới `deploy/ci` vào `main` (tiêu đề PR thành tiêu đề commit squash).
2. `release.yml` (job `release-please`, environment `release`, token của App `svp-release-please`) mở hay cập nhật PR phát hành
   `chore(main): release gitops-check <semver>`, nhãn `autorelease: pending`; PR chỉ đổi `deploy/ci/CHANGELOG.md` và
   `.release-please-manifest.json`, chạy `ci-ok`, `images-ok` như mọi PR và cần duyệt của Code Owner.
3. Merge PR đó: lượt `release.yml` kế tạo tag `gitops-check-v<semver>` và GitHub Release, nhãn đổi thành `autorelease: tagged`. Ruleset tag
   `gitops-check-tags` cấm sửa, xoá tag đó.
4. Renovate của `svp-gitops` mở PR nâng cả `CHECKER_VERSION` và `CHECKER_COMMIT` (bản major ở PR riêng), ở lượt Mend kế tiếp (4 giờ một
   lượt); PR đổi `.github/` nên cần người học duyệt.

Người dùng sản phẩm không thấy gì. Đường này hỏng thì cây `svp-gitops` vẫn được kiểm bằng bản đang ghim, nhưng thay đổi cần luật mới (dạng
cây mới) đỏ `gitops-ok` tới khi ghim lên bản có luật đó: PR promote stg treo, stg không nhận bản mới.

Commit `chore`, `docs`, `ci` không ra bản. File ngoài `deploy/ci` mà check cũng đọc ở `CHECKER_COMMIT` (`Makefile`:
target `ci-tools`, image ghim; `deploy/k8s/lib.sh`) không thuộc package: đổi chúng chỉ tới `svp-gitops` ở bản phát hành kế tiếp, tức khi có
một commit `feat`, `fix`, `perf` đổi `deploy/ci` (ADR-0077 §7). Danh sách service không phải file như vậy: check lấy nó từ bảng nguồn ở commit
mà `envs/<env>/charts.yaml` ghim, nên thêm service không cần bản checker mới.

## Kiểm tra nhanh (5 phút)

```sh
# The latest releases and the open release pull request.
gh release list -R anhnvcoder/svp-backend --limit 5
gh pr list -R anhnvcoder/svp-backend --label 'autorelease: pending' --json number,title,url
gh api -H 'Accept: application/vnd.github.raw' repos/anhnvcoder/svp-backend/contents/.release-please-manifest.json
# The commit of a tag: type "commit" is that commit; type "tag" (annotated) needs git/tags/<sha> --jq .object.sha.
gh api repos/anhnvcoder/svp-backend/git/ref/tags/gitops-check-v<x.y.z> --jq '.object.type + " " + .object.sha'
# The latest runs of release.yml and the tag ruleset.
gh run list -R anhnvcoder/svp-backend --workflow release.yml --limit 3 --json conclusion,headSha,createdAt
gh api repos/anhnvcoder/svp-backend/rulesets --jq '.[] | select(.name == "gitops-check-tags") | {id, target, enforcement}'
# The pin of svp-gitops and the Renovate pull requests that raise it.
gh api -H 'Accept: application/vnd.github.raw' repos/anhnvcoder/svp-gitops/contents/.github/workflows/check.yml |
  grep -n 'CHECKER_VERSION:\|CHECKER_COMMIT:'
gh pr list -R anhnvcoder/svp-gitops --author 'app/renovate' --json number,title,url
```

Đọc kết quả:

- Version của manifest bằng tag `gitops-check-v*` mới nhất; khác nhau là PR phát hành đã merge mà lượt tạo tag chưa chạy hay đỏ.
- `CHECKER_COMMIT` bằng commit của tag `gitops-check-v<CHECKER_VERSION>`; khác là bước khớp tag của `check.yml` đỏ ở mọi PR.
- Ruleset `gitops-check-tags` có `"target":"tag"`, `"enforcement":"active"`.
- Lượt `release.yml` đỏ: `gh run view <id> -R anhnvcoder/svp-backend --log-failed`.

## Nguyên nhân thường gặp

1. **Không có PR phát hành sau khi merge**: commit không phải `feat`, `fix`, `perf`, hay không đổi file dưới `deploy/ci` (chỉ `Makefile`,
   `deploy/k8s/lib.sh`, `deploy/docker-bake.json`: ngoài package). Dấu hiệu: lượt `release.yml` xanh mà không PR nào mở.
2. **Lượt `release.yml` đỏ ở bước tạo token**: environment `release` thiếu biến `SVP_RELEASE_APP_CLIENT_ID` hay secret
   `SVP_RELEASE_APP_PRIVATE_KEY`, App chưa cài lên repo này, hay khoá đã xoá. Cách đặt: `docs/runbooks/github-setup.md` của
   [`svp-infra`](https://github.com/anhnvcoder/svp-infra/blob/main/docs/runbooks/github-setup.md).
3. **Chưa có PR Renovate nâng ghim vài giờ sau tag**: Mend chạy 4 giờ một lượt; tick ô của dep trong issue Dependency Dashboard của
   `svp-gitops` để chạy ngay.
4. **`gitops-ok` đỏ ở bước khớp tag**: một dòng ghim bị sửa tay mà dòng kia không, hay ghim tay sang commit không phải commit của tag.
5. **`gitops-ok` đỏ trên cây không đổi ngay sau PR nâng ghim**: bản mới đổi hợp đồng mà cây chưa theo (bỏ dạng cũ không qua bước migrate,
   hay lỗi của checker).
6. **PR promote stg đỏ `is not the image file of a service`** sau khi thêm service: `charts.yaml` của env vẫn ghim commit chưa build
   service đó (hay không đọc được bảng nguồn ở commit ấy), nên file image của nó không thuộc service nào. Không phải việc của bản
   checker (mục "Release mới" ở [`svp-gitops-setup.md`](svp-gitops-setup.md#c1-promote-stg-tự-động)).
7. **Tag `gitops-check-v*` không do PR phát hành tạo** (không có PR phát hành đã merge cho version đó, hay commit của tag không nằm trên `main`):
   khoá App `svp-release-please` có thể đã lộ (threat model GIT-7).

## Giảm thiểu

- **Bản mới làm đỏ cây** (nguyên nhân 5): không merge PR Renovate nâng ghim; `svp-gitops` giữ bản đang ghim. PR đó đã merge thì revert
  bằng PR ở `svp-gitops` (cả hai dòng về bản trước), người học duyệt như mọi thay đổi `.github/`.
- **Tag sai** (bản lỗi đã phát hành): không dời, không xoá; ruleset cấm, và `svp-gitops` hay bản clone nào đó có thể đã ghim nó. Sửa bằng bản
  mới: commit `fix` dưới `deploy/ci`, PR phát hành patch, PR Renovate nâng ghim. Ghi lỗi vào mô tả GitHub Release của bản sai (sửa ghi chú,
  không đổi tag).
- **Tag lạ** (nguyên nhân 7): đóng PR Renovate nâng lên tag đó, không merge; làm "Giảm thiểu" của khoá App như
  [`svp-gitops-setup.md`](svp-gitops-setup.md#giảm-thiểu) cho App `svp-release-please` (Suspend, xoay khoá theo `github-setup.md` của
  `svp-infra`). Xoá tag lạ và GitHub Release của nó bằng quyền admin (bypass của ruleset):
  `gh release delete <tag> -R anhnvcoder/svp-backend --cleanup-tag`.

## Khôi phục và xác nhận

### Đổi hợp đồng theo expand–contract

Đổi hợp đồng giữa checker và cây `svp-gitops` (khoá mới, dạng file mới, luật mới) đi bằng ba PR, mỗi PR qua cổng thường, không ghim tạm
`GITOPS_REF`, không sửa tay `CHECKER_COMMIT`:

1. **Expand** (repo này): checker nhận cả dạng cũ lẫn mới; tiêu đề PR `feat(ci): …`. CI của repo này chạy checker `--worktree` với `main`
   của `svp-gitops` (job `config`, `make helm-check`), nên cây dạng cũ vẫn được kiểm trước merge. Merge rồi duyệt và merge PR phát hành minor
   (mục "Phát hành" dưới đây).
2. **Migrate** (`svp-gitops`): merge PR Renovate nâng ghim lên bản minor đó (mục "Nâng ghim"), rồi PR đổi cây sang dạng mới; check chạy bản mới
   nên nhận dạng mới.
3. **Contract** (repo này): bỏ dạng cũ bằng commit có `!` (`feat(ci)!: …`) hay footer `BREAKING CHANGE:`; CI `--worktree` với `main` của
   `svp-gitops` (đã dạng mới) xanh. Merge PR phát hành major, rồi PR Renovate major riêng ở `svp-gitops`.

Thứ tự sai thì cổng tự chặn: bỏ dạng cũ khi `main` của `svp-gitops` còn dạng cũ thì CI `--worktree` của repo này đỏ; PR `svp-gitops` dùng
dạng mới khi ghim còn bản cũ thì `gitops-ok` đỏ.

### Phát hành

1. Đọc PR phát hành: chỉ đổi `deploy/ci/CHANGELOG.md` và `.release-please-manifest.json`; version mới đúng mức của các commit liệt kê (có
   `!` thì major). PR không build image (`changed-services.sh` bỏ qua CHANGELOG), `ci-ok` và `images-ok` xanh.
2. Duyệt và merge (squash, như mọi PR). Không sửa tay CHANGELOG hay manifest: lượt `release.yml` kế ghi lại từ lịch sử.
3. Kiểm: lệnh "Kiểm tra nhanh" in tag `gitops-check-v<semver>` mới, commit của tag là commit merge của PR phát hành
   (`gh pr view <số> -R anhnvcoder/svp-backend --json mergeCommit`), PR mang nhãn `autorelease: tagged`.

### Nâng ghim

1. Trước khi duyệt PR Renovate ở `svp-gitops`, đọc ghi chú GitHub Release của mọi bản giữa hai ghim và lịch sử ở bản clone của repo này:

   ```sh
   git -C <bản clone svp-backend> fetch --tags origin
   git -C <bản clone svp-backend> log --oneline gitops-check-v<cũ>..gitops-check-v<mới> -- deploy/ci deploy/k8s/lib.sh deploy/docker-bake.json Makefile
   # The new tag's commit must be on main; otherwise no release pull request made it.
   git -C <bản clone svp-backend> merge-base --is-ancestor gitops-check-v<mới> origin/main && echo on-main
   ```

2. `gitops-ok` của PR xanh (bước khớp tag rồi checker mới trên cây hiện tại); merge.
3. Renovate không tới được (Mend lỗi): sửa tay cả hai dòng trong một PR, `CHECKER_COMMIT` là commit của tag đọc bằng lệnh "Kiểm tra nhanh".

## Leo thang

- Lượt `release.yml` vẫn đỏ ở bước token sau khi đã kiểm environment `release`, App và khoá: so input của bước tạo token trong
  `.github/workflows/release.yml` (`client-id`, `private-key`, `owner`, `repositories`) với tên ở runbook `github-setup.md` của `svp-infra`.
- release-please báo lỗi quyền khi gắn nhãn hay comment trên PR phát hành: App cần quyền khác mức ADR-0077 §3 đã chốt; đổi manifest App ở
  `svp-infra` bằng ADR mới, không cấp thêm quyền tay.
- Cây `svp-gitops` đỏ với cả bản cũ lẫn bản mới, hay một tag lạ đã được ghim và merge: revert ghim về bản cuối đã kiểm, ghi mốc thời gian và
  mở postmortem ([mẫu](../postmortems/README.md)).

## Liên kết

- [ADR-0077](../adr/0077-versioned-gitops-checker.md) và [phụ lục](../adr/appendix/0077-versioned-gitops-checker.md) (cấu hình release-please,
  quyền App, Renovate, nguồn); [ADR-0025](../adr/0025-gitops-config-repo.md) §5 (check `gitops-ok`).
- [`reference/ci.md`](../reference/ci.md) (workflow `release.yml`, check của `svp-gitops`), [`ci-cd.md`](../ci-cd.md#12-push-hay-merge-vào-main)
  (đọc một lượt `release.yml`), [`svp-gitops-setup.md`](svp-gitops-setup.md#c5-bump-commit-ghim-chart-và-checker) (C5).
- Threat model: [GIT-5, GIT-7](../threat-model.md#48-bề-mặt-khác).
- Không có diễn tập; phép kiểm là lượt đầu theo mục Xác nhận của ADR-0077.
