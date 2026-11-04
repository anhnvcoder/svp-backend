# 0036. Đổi tên repo `short-video-platform` → `svp-backend`, `svp-web` → `svp-frontend`: image chuyển sang prefix mới mang tên repo; bảng nguồn của lượt chuyển giữ hai nguồn cũ ở dạng nghỉ hưu (được nhận, không ai phát hành) để stg, prd đi qua bằng PR bot như mọi bản phát hành, rồi gỡ khi prd chạy bộ bản mới

- Trạng thái: Chấp nhận
- Ngày: 2026-10-31
- Người quyết: người học (đổi tên repo, ràng buộc của lượt chuyển; 3A chọn ở mốc duyệt kế hoạch)

## Bối cảnh và vấn đề

- **Việc đã xảy ra.** Ngày 2026-10-31 người học đổi tên hai repo trên GitHub: `anhnvcoder/short-video-platform` (trong ADR này gọi là
  **backend**) thành `anhnvcoder/svp-backend`, `anhnvcoder/svp-web` thành `anhnvcoder/svp-frontend`. `svp-gitops`, `svp-infra`, `svp-labs`
  giữ tên; thư mục workspace `labs/short-video-platform/` và hai bản clone `backend/`, `frontend/` giữ tên. Lượt `images.yml` cuối dưới tên cũ
  (id lượt, commit, PR: phụ lục) đã đưa sáu image backend và web lên stg, qua check `gitops-ok` chỉ nhận identity cũ.
- **GitHub sau khi đổi tên** [W1]: web và `git clone`, `git fetch`, `git push` theo tên cũ được chuyển sang tên mới; action của repo đổi tên
  thì không (không workflow nào `uses:` action hay reusable workflow của hai repo, [ADR-0033](0033-svp-web-repo.md) §5); tạo repo mới trùng tên
  cũ thì chuyển hướng ngừng. Trang không nói về REST API hay GitHub Packages.
- **Identity ký mang tên repo.** SAN của chứng chỉ Fulcio là `server_url` + `job_workflow_ref`, dạng `owner/repo/.github/workflows/…@ref` [W3].
  Từ lúc đổi tên, mọi lượt `images.yml` ký bằng `https://github.com/anhnvcoder/svp-backend/.github/workflows/images.yml@refs/heads/main`
  (frontend tương tự), provenance nêu `workflow.repository` mới; không CI nào ký được identity cũ nữa.
- **Bảng nguồn còn tên cũ.** `deploy/helm/svp-policy/files/sources.json` có hai nguồn `backend`, `web` theo tên cũ; `use_build_source` của
  `deploy/ci/common.sh` chọn nguồn theo `ci_repo_url` (tên hiện tại), nên cả hai repo không build, ký gì (fail-closed); policy `svp-images`,
  `verify-release.sh` và check `svp-gitops` từ chối identity mới.
- **Bảng đọc theo `revision` của env** (ADR-0033 §2, §3): stg ở `c049c1b`, prd ở `f6bbc0e`, cả hai bảng hai nguồn tên cũ, cả hai env chạy sáu
  bản `ghcr.io/anhnvcoder/short-video-platform/<svc>` và web `ghcr.io/anhnvcoder/svp-web/web`.
- **Hai repo phát hành độc lập** (ADR-0033 §4): backend promote stg trước; web tới stg sau, nên giữa hai PR bot stg chạy sáu bản identity mới
  và web identity cũ: bảng ở revision đó phải nhận cả hai.
- **Luật của bảng** (`_release_sources_jq` của `deploy/k8s/lib.sh` và template của chart, `deploy/ci/sources-test.sh` giữ hai nơi khớp):
  prefix không trùng, không lồng; một service ở tối đa hai nguồn; mọi nguồn có `promoter`, không hai nguồn chung một `promoter`.
- **Đồng hồ:** `values-check.sh --gitops` đòi attestation `vuln` không quá 48 giờ; Kyverno `maxAttestationAge: 72h`.

## Yếu tố quyết định

- Không nới chính sách (một prefix một identity, Enforce, provenance).
- CI/CD một đường thẳng, không nhánh `if` theo chế độ, tương thích ngược tối đa một bản (người học, 2026-10-31).
- Không lúc nào bảng ở `revision` của env từ chối bản env đang chạy; mọi đổi chart, nguồn đi stg trước prd; không xoá package cũ.

## Phương án đã cân nhắc

Bảng được/mất từng lựa chọn: phụ lục, mục "Các lựa chọn".

- 1A. Prefix mới theo tên repo (`ghcr.io/anhnvcoder/svp-backend/`, `…/svp-frontend/`): tên package khớp repo, policy như nay; 12 package mới bật public tay.
- 1B. Giữ prefix cũ, đổi `repository`, `subject` tại chỗ: mọi bản đang chạy và mọi rollback bị từ chối ngay.
- 1C. Giữ prefix cũ, một nguồn nhiều identity: đổi schema, CEL, script; nới chính sách theo trục mới.
- 1D. Identity theo id bất biến của repo (`repository_id` [W3]): policy so SAN có tên repo; chưa đọc tài liệu Kyverno khớp theo id.
- 2A. Bảng chuyển bốn nguồn, hai nguồn cũ nghỉ hưu (đúng giá trị cũ, không `promoter`): stg, prd đi bằng PR bot; thêm luật tiếp quản, gỡ ở PR sau.
- 2B. Đổi tại chỗ, một PR tay thay bảy file stg: PR bot của stg đỏ tới PR tay, không lùi được ngay.
- 2C. Như 2A nhưng nguồn cũ giữ `promoter`: hai nguồn chung một `promoter`, bảng bị từ chối.
- 3A. Image diễn tập `drill-no-provenance` cho ca (l): phép provenance vẫn chứng minh dưới Enforce; thêm một image, một package.
- 3B. Ca (l) SKIP có lý do: mất bằng chứng phép provenance trên cluster.

## Kết quả quyết định

Chọn 1A, 2A, 3A. Lý do chung: giữ nguyên mọi phép kiểm (một prefix một identity, provenance theo repo của nguồn) và đi qua bằng đúng đường
phát hành đang có; phần riêng của lượt chuyển chỉ là dữ liệu (hai nguồn nghỉ hưu) và một luật tiếp quản, gỡ ở bản sau. Toàn văn từng §: phụ lục.

### 1. Vì sao phải có lượt chuyển

Subject keyless mang tên repo nên đổi theo tên; Kyverno, `verify-release.sh`, check `svp-gitops` kiểm theo bảng ở `revision` của env, chỉ đổi
qua PR promote; stg sẽ có lúc lẫn bản identity cũ và mới, prd lẫn tên cũ tới khi PR promote prd thay cả bảy. Vậy bảng của commit đưa vào stg
phải nhận cả bản cũ đang chạy lẫn bản mới sắp tới, và chỉ bỏ bản cũ khi không env nào còn chạy nó.

### 2. Prefix image mới

- Nguồn `backend`: `ghcr.io/anhnvcoder/svp-backend/` (sáu service Go, ba image diễn tập, hợp đồng `api/gateway`); nguồn `web`:
  `ghcr.io/anhnvcoder/svp-frontend/` (`web`, `web-sourcemaps`). Không giữ prefix cũ cho bản mới.
- Hợp đồng API phát hành lại dưới `ghcr.io/anhnvcoder/svp-backend/api/gateway:<version>` (cùng version, ký identity backend mới), vì
  `make generate` của `svp-frontend` kiểm chữ ký hợp đồng bằng identity của nguồn `backend` đọc từ bảng ở `.backend-commit`.
- Người học bật public 12 package mới (mặc định private, public rồi không đổi lại private được [W2]) trước khi PR bot của nó được kiểm.
  Package cũ giữ nguyên, không xoá.

### 3. Nguồn nghỉ hưu

- Bảng của bản chuyển (commit merge của PR đổi tên ở backend, gọi là **T**) có bốn nguồn: `backend`, `web` (tên mới, có `promoter`
  `svp-gitops-promoter`, `svp-web-promoter`) và `oldbackend` (sáu service Go), `oldweb` (`web`) với `repository`, `imagePrefix`, `subject` cũ,
  không `promoter`; `drillImages` của `backend` thêm `drill-no-provenance` (bảng đầy đủ: phụ lục).
- **Nguồn không `promoter` là nguồn nghỉ hưu:** policy, `verify-release.sh`, check nhận bản của nó như mọi nguồn; không lượt CI nào là của nó;
  `promote.sh --source`, `rescan.sh --source` từ chối nó; rescan bỏ file của nó, không đỏ; bản của nó tự hết hạn (mục 5).
- Mọi luật khác của bảng giữ; sửa cùng lúc `_release_sources_jq` và template, `sources-test.sh` đưa ca mới qua cả hai.
- **`oldbackend` bỏ `web`:** không env nào chạy `short-video-platform/web`, nên bảng chuyển cũng là bước 8 (PR-3) của ADR-0033 §9; rollback web về
  bản đó bị phép 1 từ chối từ T.
- **Tiếp quản:** bot của nguồn N được thay image của `svc` khi image trước là bản của N, của `backend` hay của một nguồn nghỉ hưu có `svc`;
  image sau vẫn phải là bản của N. `promote.sh` tiếp quản file của nguồn nghỉ hưu ở chế độ backend và `--source web`; file của nguồn đang hoạt
  động khác để nguyên như ADR-0033 §4.
- **Check `svp-gitops` không trỏ bản clone repo nguồn nào nữa** (bỏ `SVP_SOURCE_DIR_*`): check clone ẩn danh, blob-less từng URL; URL cũ đi theo
  chuyển hướng của GitHub [W1].
- Bản của `oldbackend` kiểm như nguồn khác `backend`: tag là commit trên `main` của repo nguồn, không theo luật tổ tiên với `revision`.

### 4. Trình tự và mốc

1. PR backend (bảng bốn nguồn, `promoter` tuỳ chọn, mọi tên, Go module, `drill-no-provenance`) merge thành T; `images.yml` ở T ký dưới prefix
   mới; PR `bot/promote-stg` đỏ với checker cũ: dự kiến.
2. PR `svp-gitops`: `CHECKER_COMMIT` = T, checkout `anhnvcoder/svp-backend`, bỏ checkout repo web và `SVP_SOURCE_DIR_WEB`, `chartRepoURL`,
   `sourceRepos` theo tên mới; merge **trước** khi PR bot của bước 1 được kiểm lại.
3. Người học bật public bảy package `svp-backend/…` (sáu service, `api/gateway`).
4. Chạy lại job `promote` ở T: PR bot tiếp quản từ `oldbackend`, tự merge; dispatch `images.yml -f drill=true`, bật public ba package diễn tập.
5. PR `svp-frontend` (`.backend-commit` = T, hợp đồng dưới `svp-backend/api/gateway`); bật public hai package; PR `bot/promote-stg-web` tiếp quản
   `web.yaml` từ `oldweb`. Stg đủ bảy bản mới.
6. `verify.yml` kịch bản `gitops` trên `main`, job `record-stg` ghi bản ghi stg.
7. Promote prd bản ghi đó (người học duyệt PR prd).
8. PR backend gỡ `oldbackend`, `oldweb` và luật tiếp quản, chỉ khi mọi file `envs/stg/images/`, `envs/prd/images/` đã dưới hai prefix mới; giữ
   việc đọc bảng có nguồn không `promoter` tới khi không env nào còn ở commit có nó, giữ phần đọc lịch sử (mục 8).
9. Nâng `CHECKER_COMMIT` lên commit merge của bước 8 (mục 9).

Cách lùi: trước bước 4 lùi là sửa tiếp; sau bước 4, 5 PR của người học trả file về digest cũ, chỉ trong hạn 48 giờ của attestation cũ; sau
bước 8 bản trước đổi tên bị phép 1 từ chối.

### 5. Đồng hồ attestation

- **Mốc vận hành: PR bot stg của backend (bước 4) merge trước 2026-11-02 07:00 UTC** (48 giờ sau rescan sớm nhất của các bản identity cũ);
  PR bot web (bước 5) thay bản cũ cuối của stg nên không có hạn này; prd không có hạn trước bước 7. Trễ mốc: người học mở một PR thay cả bảy file stg và `charts.yaml` (T) cùng lúc.
- Lượt lịch `verify.yml` kế tiếp (2026-11-07 00:37 UTC) dựng stg từ `main`: tới lúc đó stg phải đủ bảy bản mới.
- Rollback về bản trước đổi tên: muộn nhất từ khoảng 2026-11-03 08:57 UTC không bản identity cũ nào qua được check hay Kyverno Enforce.
  Giờ của từng lượt chạy: phụ lục.

### 6. Ca (l) của `drill-k8s-supplychain`

- `images.yml -f drill=true` dựng `drill-vulnerable`, `drill-unsigned` và `drill-no-provenance` (ký và attest `vuln`, **không** provenance)
  dưới prefix của `backend`; `drillImages`, `drill_images` của `common.sh` thêm tên đó; rescan không đụng image diễn tập.
- `supplychain.sh` ca (l) mặc định `<imagePrefix của backend>drill-no-provenance@<digest>` (`SUPPLYCHAIN_NO_PROVENANCE` ghi đè), vẫn kiểm trước
  khi gửi pod, thiếu thì FAIL kèm lệnh dispatch; kịch bản `gitops` lấy digest mới nhất; chỉ lượt lịch mà attestation quá 72 giờ thì SKIP kèm `NOTE` (dispatch thì FAIL).
- Ca (m) chạy với bốn nguồn; cặp có nguồn nghỉ hưu mà không pod nào chạy bản của nó thì SKIP có lý do.

### 7. Giữ và đổi

- **Đổi:** hai tên repo ở URL, `owner/name`, checkout, clone, `depName` của Renovate, link `…/blob/main/…` (cả `runbook_url`); prefix image như
  mục 2; `.web/svp-web` → `.web/svp-frontend`; chữ `svp-web` khi nói về repo → `svp-frontend`; Go module
  `github.com/anhnvcoder/short-video-platform` → `github.com/anhnvcoder/svp-backend` (không repo nào khác import module này).
- **Giữ:** thư mục workspace; tên nguồn `backend`, `web` và service `web`; App `svp-gitops-promoter`, `svp-web-promoter`, nhánh bot; tên thành
  phần lúc chạy (meter OTel `svp-web`, dashboard, project GlitchTip `svp`); repo `svp-gitops`, `svp-infra`, `svp-labs`; nội dung lịch sử; hai
  nguồn nghỉ hưu và fixture test trước đổi tên.

### 8. Đọc lịch sử dưới tên cũ là lâu dài, không phải phần chuyển tiếp

- Tên cũ của repo code khai **một chỗ, dạng dữ liệu** trong `deploy/ci/platform.sh`: `ci_is_run_url`, `ci_run_workflow` nhận `run_url` dưới tên
  cũ; mọi lời gọi API đọc lượt bằng tên hiện tại và id của lượt (không dựa vào chuyển hướng của API).
- `dora.sh` gán nguồn theo bảng ở `charts.revision` của chính bản ghi, gom commit theo repo, tên cũ quy về tên hiện tại; nên bước 8 không làm
  `dora.yml` đỏ. Phần DORA của mục này bị thay (Chỉnh bởi).

### 9. Sau khi gỡ

Ngay khi PR gỡ (bước 8) merge, người điều phối mở PR một dòng ở `svp-gitops` nâng `CHECKER_COMMIT` lên commit merge đó, merge khi `gitops-ok`
xanh, không chờ Renovate. Checker mới vẫn phải đọc được bảng bốn nguồn khi prd còn ở T.

### 10. Không dùng lại hai tên cũ

Không tạo repo nào tên `short-video-platform` hay `svp-web` dưới `anhnvcoder`, kể cả sau khi gỡ nguồn nghỉ hưu: GitHub thôi chuyển hướng khi
tên được dùng lại [W1]; repo mới mang tên cũ ký được đúng subject cũ mà bảng ở mọi revision trước bước 8 nhận; `ci_is_run_url` nhận
`run_url` dưới tên cũ.

### Hệ quả

- Tốt: tên package khớp tên repo, mỗi nguồn vẫn một prefix, một identity, một credential; đi qua bằng PR bot và PR prd, không cắt tay, không
  lúc nào bảng của env từ chối bản env đang chạy; phần riêng của lượt chuyển là dữ liệu và một luật tiếp quản, gỡ ở bản sau.
- Xấu: 12 package mới bật public tay, package cũ ở lại; bản T mang luật tiếp quản; hạn 48 giờ nằm trên đường găng; từ lúc đổi tên tới khi PR
  của mỗi repo merge, `images.yml` của repo đó không build, ký gì; sáu bản của `oldbackend` không qua luật tổ tiên; rollback về bản trước đổi
  tên mất hẳn sau 72 giờ; check clone ẩn danh mọi nguồn khác `backend` theo URL, dựa vào chuyển hướng của GitHub.
- Xem lại khi: không env nào và không bản ghi stg nào còn trỏ commit có nguồn nghỉ hưu (bỏ phần đọc bảng không `promoter`); đổi tên lần nữa
  (dùng lại mục 2, 3, hay 1D); thêm trust OIDC từ GitHub Actions sang cloud (repo đổi tên sau 2026-07-15 dùng `sub` dạng id bất biến [W3]).
- ADR cũ được chỉnh một phần: [ADR-0033](0033-svp-web-repo.md) §2, §3, §9; [ADR-0025](0025-gitops-config-repo.md) §5;
  [ADR-0027](0027-slsa-build-provenance.md) §6 (rollback về bản trước đổi tên bị từ chối như về bản trước provenance).

## Xác nhận

- Bước 1–5: T = `b5f22c2` (PR #59); `images.yml` của `svp-frontend` xanh, PR bot #37 của `svp-gitops` tiếp quản `web.yaml` từ `oldweb`.
- Bước 6: `verify.yml` kịch bản `gitops` trên `main` `success`, bản ghi stg tạo được.
- Bước 7: prd chạy bảy bản dưới `svp-backend/`, `svp-frontend/` (PR #40 của `svp-gitops`), `charts.revision` vẫn là T; `dora.yml` `success`.
- Bước 8, 9: PR gỡ merge `344da5f` (PR #61, 2026-11-01), `CHECKER_COMMIT` nâng lên đó; `drill-k8s-supplychain` mọi ca PASS, rescan hai repo xanh.
- Id lượt chạy và chi tiết từng bước: phụ lục, mục "Kết quả".

## Hiện thực ở

- Bảng nguồn (mục 3): `deploy/helm/svp-policy/files/sources.json`, `deploy/helm/svp-policy/templates/imagevalidatingpolicy.yaml`;
  `deploy/k8s/lib.sh` (`release_sources`, `ghcr_prefix`, `web_url`; luật bảng chỉ ở template từ [ADR-0050](0050-bash-to-standard-tools.md)); `deploy/ci/common.sh`; `deploy/ci/sources-test.sh`.
- Tên repo code (mục 7, 8): `run_repo_url` của `deploy/ci/common.sh` (trên máy), lệnh `gh workflow run` mà script trong `deploy/ci/`,
  `deploy/k8s/` in ra, `deploy/k8s/gitops.sh` (`chart_repo_url`).
- Script phát hành (mục 3, 8): `deploy/ci/gitops-check.sh`, `promote.sh`, `promote-prd.sh`, `rescan.sh`, `contract.sh`, `dora.sh`, `deploy/ci/verify/`.
- Ca (l) (mục 6): `.github/workflows/images.yml`, `deploy/ci/verify/gitops.sh`, `deploy/k8s/drills/supplychain.sh`.
- Go module, tên ở cấu hình (mục 7): `go.mod`, `gen/go`, `.github/workflows/`, `Makefile`, `deploy/`, `renovate.json`.
- Repo khác: `svp-gitops` (`.github/workflows/check.yml`, `argocd/apps/values.yaml`, `argocd/project.yaml`); `svp-frontend` (`.backend-commit`,
  `api/contract.json`, `scripts/backend.sh`). Danh sách đầy đủ của PR đổi tên và PR gỡ: phụ lục.

## Nguồn

Đọc ngày 2026-10-31; trích dẫn đầy đủ ở phụ lục.

- [W1] GitHub Docs, "Renaming a repository": <https://docs.github.com/en/repositories/creating-and-managing-repositories/renaming-a-repository>
- [W2] GitHub Docs, "Configuring a package's access control and visibility":
  <https://docs.github.com/en/packages/learn-github-packages/configuring-a-packages-access-control-and-visibility>
- [W3] GitHub Docs, "OpenID Connect reference": <https://docs.github.com/en/actions/reference/security/oidc>

## Thông tin thêm

Phụ lục: [`appendix/0036-repo-rename.md`](appendix/0036-repo-rename.md) (dòng trạng thái lúc chốt, bối cảnh với id lượt chạy, bảng lựa chọn,
toàn văn mười §, kết quả từng bước, hiện thực ở, nguồn).

### Chỉnh bởi

- §8: [0037](0037-mainpath-standard-tools.md): phần DORA bị thay bởi §1 của 0037 từ 2026-11-01: `dora.sh` rời đường chính sang bài lab;
  danh sách tên cũ `_ci_renamed_repos` cùng hai người đọc còn lại (bản ghi stg, comment của file `svp-gitops`) bỏ ở phần B của 0037.
