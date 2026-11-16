# 0077. Checker của `svp-gitops` phát hành theo semver bằng release-please với tag `gitops-check-v<semver>` bất biến, `svp-gitops` ghim version cùng commit của tag và Renovate nâng cả hai; đổi hợp đồng chéo repo theo expand–contract; image và chart giữ ghim commit

- Trạng thái: Chấp nhận
- Ngày: 2026-11-15
- Người quyết: người học (2026-11-15: làm các khoảng trống CI/CD trước buổi cloud, AI tự quyết thiết kế), AI đề xuất thiết kế theo tài liệu
  và mã nguồn của release-please, Renovate, GitHub ở version ghim

## Bối cảnh và vấn đề

- Bốn khoảng trống CI/CD còn lại sau các ADR AWS: plan trên PR và chi phí ([0076](0076-terraform-plan-infracost-pr.md)), thứ tự merge chéo
  repo và tự động phát hành (ADR này).
- Check bắt buộc `gitops-ok` của `svp-gitops` chạy `deploy/ci/gitops-check.sh` của repo này ở `CHECKER_COMMIT` (commit ghim trong `check.yml`,
  [0025](0025-gitops-config-repo.md) §5); Renovate đề xuất commit mới nhất của `main` (`git-refs`, 0025 §10). Mỗi commit `main` là một "bản" checker:
  không changelog, không tín hiệu nào nói bản mới có phá cây `svp-gitops` hay không.
- Đổi hợp đồng giữa checker và cây `svp-gitops` cần thứ tự tay: [0072](0072-pod-operations.md) §2 để PR promote stg đầu của release mới đỏ tới khi
  một PR khác nâng `CHECKER_COMMIT`; thử nhánh `svp-gitops` chưa merge cần ghim tạm `GITOPS_REF` (`make gitops-clone`, `verify.yml`).
- Ràng buộc: tiêu đề PR đã theo Conventional Commits và thành commit squash ([0041](0041-github-hardening.md) (h)); `deploy/ci/`, `.github/` có Code
  Owner; repo public; PR do `GITHUB_TOKEN` mở không chạy CI của nó, nên PR phát hành cần token khác [N6].

## Yếu tố quyết định

- Một bản checker có tên nói mức tương thích (semver) và trỏ đúng một commit bất biến.
- Đổi hợp đồng chéo repo không cần ghim tạm hay nâng tay; mỗi bước qua cổng PR có sẵn (`ci-ok`, `images-ok`, `gitops-ok`).
- Không đổi cách checker chạy: checkout repo code đủ lịch sử, chart đọc ở revision của env.
- Công cụ chuẩn, quyền hẹp, không secret mới ngoài khoá một GitHub App.

## Phương án đã cân nhắc

Trạng thái ngành, được, mất, nguồn: [phụ lục](appendix/0077-versioned-gitops-checker.md#phương-án). In đậm là lựa chọn.

- Cách ghim: giữ commit `main` + `git-refs` (hiện trạng); reusable workflow `@vN` (hiện hành [N11]: job chạy ở repo gọi, nhưng check còn
  đọc chart ở lịch sử repo code nên vẫn checkout); OCI artifact bằng ORAS (hiện hành, CNCF Sandbox [N12]: thêm push, ký, vẫn cần lịch sử repo
  code); image checker (thêm build, quét, ký một image); **tag git semver trên repo code**.
- Công cụ phát hành: **release-please** (hiện hành [N1]: PR phát hành từ Conventional Commits, changelog, tag, GitHub Release, manifest cho
  monorepo); semantic-release (hiện hành [N13]: phát hành ngay khi push, tag không qua PR); changesets (hiện hành [N14]: mỗi PR thêm file
  changeset, hướng monorepo npm).

## Kết quả quyết định

Chọn tag semver do release-please tạo: dùng lại Conventional Commits đã bắt buộc, mỗi bản phát hành là một PR qua cổng như mọi PR, check của
`svp-gitops` giữ nguyên cách chạy. Giá trị đủ, trích nguồn: [phụ lục](appendix/0077-versioned-gitops-checker.md), cùng số §.

### 1. Checker

**Checker** là `deploy/ci/gitops-check.sh` và mọi file nó đọc trong `deploy/ci/`: `common.sh`, `values-check.sh`, `verify-release.sh`,
`gitops-policies/`, `gitops-tree-policies/`, `cluster-values.example.yaml`. Chart ở revision của env vẫn đọc từ lịch sử repo code, không thuộc
phiên bản checker. Danh sách service mà file image của env được phép có cũng không thuộc: `values-check.sh` lấy nó từ bảng nguồn ở commit
`envs/<env>/charts.yaml` ghim (`release_sources`), nên service mới không cần bản checker mới; danh sách của checker chỉ là dự phòng khi bảng không đọc được.

### 2. Release checker

- **Release checker**: release-please ở chế độ manifest, `release-please-config.json` và `.release-please-manifest.json` ở gốc; một package
  `deploy/ci`, `component` `gitops-check`, `release-type: simple`, `initial-version` `1.0.0` [N2], [N5]; tag `gitops-check-v<semver>`
  (`include-component-in-tag`, `include-v-in-tag` mặc định `true` [N2]); changelog `deploy/ci/CHANGELOG.md` (mặc định `CHANGELOG.md` dưới đường
  package [N2], [N4]).
- `feat` → minor, `fix`, `perf` → patch, `!` hay `BREAKING CHANGE` → major; `chore`, `docs`, `ci` không ra bản; chỉ commit đổi file dưới
  `deploy/ci` được đếm.
- Version chỉ ở manifest và tag: không `version.txt`, vì strategy `simple` không tạo file version còn thiếu (`createIfMissing: false` [N4]).
  PR phát hành chỉ đổi `deploy/ci/CHANGELOG.md` và manifest.
- Không `bootstrap-sha` (tài liệu khuyên tránh [N2]): đặt nó sau lịch sử thì có thể không còn commit `feat`, `fix` nào để ra PR `1.0.0`.
  CHANGELOG `1.0.0` liệt kê lịch sử `feat`, `fix` của `deploy/ci` trong `commit-search-depth` mặc định 500 commit [N3].

### 3. Workflow và App phát hành

- `.github/workflows/release.yml`: `push` lên `main`, `concurrency` không huỷ, `permissions: {}` cho `GITHUB_TOKEN`; job `release-please` với
  `environment: release`, token từ App bằng `actions/create-github-app-token` (ghim như `images.yml`), `googleapis/release-please-action` v5.0.0
  (2026-04-22, release-please 17.6.0 [N6]) ghim SHA; không checkout, không chạy code của repo.
- **App release** `svp-release-please`, chỉ cài trên repo này: `contents: write` (nhánh PR phát hành, tag, GitHub Release), `pull_requests: write`
  (PR, nhãn `autorelease: pending`, `autorelease: tagged` [N3], comment), `metadata: read`. Không `issues: write`: endpoint nhãn, comment mà
  release-please gọi [N7] nhận `pull_requests: write` [N8], dù README của action liệt kê nó cho `GITHUB_TOKEN` [N6]; lượt đầu kiểm.
- Token của App làm PR phát hành chạy CI như mọi PR [N6]; PR đó qua `ci-ok`, `images-ok`, Code Owner; tag và GitHub Release tạo khi nó merge.
  Ruleset `main` không cho App đẩy thẳng lên `main`.
- **Environment release**: environment `release`, chỉ nhánh `main` (như `promote`), biến `SVP_RELEASE_APP_CLIENT_ID`, secret khoá App
  `SVP_RELEASE_APP_PRIVATE_KEY`; Terraform ở `infra/github/`, khoá người học đặt.

### 4. Tag bất biến

**Ruleset tag checker**: ruleset tag của repo này, include `refs/tags/gitops-check-v*`, cấm `update`, `deletion`, không cấm tạo (App tạo
tag), bypass admin như ruleset tag của `svp-gitops`. Tag đã phát hành không dời được; sửa bản lỗi bằng bản mới.

### 5. Ghim checker

- **Ghim checker**: `check.yml` của `svp-gitops` có `CHECKER_VERSION: <semver>` (dòng `# renovate: datasource=github-tags depName=anhnvcoder/svp-backend`,
  `extractVersion=^gitops-check-v(?<version>.+)$`) và `CHECKER_COMMIT: <commit của tag>`. Hai job dùng checker (`gitops`, `diff-preview`)
  checkout ở `CHECKER_COMMIT`, và một bước đỏ khi tag `gitops-check-v$CHECKER_VERSION` không trỏ đúng commit đó.
- Renovate nâng cả hai trong một PR (customManager regex của `svp-gitops/renovate.json`, thay manager `git-refs`): datasource `github-tags` lấy
  digest của mỗi bản là commit của tag, kể cả tag có annotate [N9], và đặt nó thành digest mới của bản cập nhật [N10]. Major ở PR riêng
  (`separateMajorMinor` mặc định `true` [N15]).
- Luật Renovate riêng của dep này thay luật `git-refs`: `minimumReleaseAge: null`, `schedule: ["at any time"]` [N15], vì cấu hình chung của
  `svp-gitops` chờ 3 ngày, chỉ chạy sáng thứ Bảy; PR tới ở lượt Mend kế tiếp (4 giờ một lượt, hay ngay khi tick Dependency Dashboard [N16]).

### 6. Expand–contract

**Expand–contract**: đổi hợp đồng giữa **Checker** và cây `svp-gitops` theo ba PR:

1. expand: repo code nhận cả dạng cũ lẫn mới, commit `feat`, phát hành minor; CI repo code chạy checker `--worktree` với `main` của `svp-gitops`
   nên dạng cũ còn được kiểm;
2. migrate: `svp-gitops` nâng **Ghim checker** (PR Renovate), rồi đổi cây sang dạng mới;
3. contract: repo code bỏ dạng cũ bằng commit `!`, phát hành major; `svp-gitops` nâng.

Không PR nào cần ghim tạm `GITOPS_REF` hay nâng `CHECKER_COMMIT` tay. Release mới của 0072 §2 không đi đường này: không có hợp đồng nào đổi (§1).

### 7. Phạm vi phiên bản

- Chỉ **Checker** có semver. Image service giữ tag theo commit và digest ([0015](0015-cicd-devsecops-stage5.md) §5): build một lần, promote cùng
  digest, mỗi commit `main` là một bản ứng viên; người tiêu thụ là GitOps của chính hệ thống, semver không thêm thông tin cho Argo CD. Chart ở
  `deploy/helm/` giữ ghim commit trong `envs/<env>/charts.yaml`, đi cùng image của env.
- Package là cả thư mục `deploy/ci`: `feat`, `fix` ở script không thuộc checker (`plan.sh`, promote, `scan-gate.sh`…) cũng ra bản mới, thêm một
  PR Renovate vô hại ở `svp-gitops`. `Makefile` (target `ci-tools`, version Helm, buf mà check cài ở `CHECKER_COMMIT`) và `deploy/k8s/lib.sh`
  (nạp qua `common.sh`) nằm ngoài package: đổi chúng chỉ tới `svp-gitops` ở bản phát hành kế tiếp.

### 8. ADR cũ

Chỉnh: 0025 §5, §10; 0072 §2, Hệ quả; 0041 (d), (f).

### Hệ quả

- Tốt: version nói mức tương thích, changelog cho mỗi bản; đổi hợp đồng chéo repo đi bằng PR thường, không ghim tạm; tag bất biến nên commit
  checker đã ghim không dời; dùng lại Conventional Commits và cổng PR có sẵn.
- Xấu: thêm một App (khoá xoay tay), một environment, một workflow, một ruleset; mỗi bản thêm một PR phát hành ở repo này và một PR Renovate ở
  `svp-gitops`; CHANGELOG `1.0.0` dài (lịch sử `deploy/ci` không cắt); script không thuộc checker cũng ra bản; đổi `Makefile` tới `svp-gitops`
  chậm một bản; tag bất biến nên bản lỗi chỉ sửa bằng bản mới; checker chưa nâng ghim thì PR `svp-gitops` dùng dạng mới vẫn đỏ (đúng ý expand);
  PR nâng ghim chờ lượt Mend kế tiếp, tới 4 giờ sau tag.
- Xem lại khi: package `deploy/ci` ra bản không đổi checker quá thường (tách **Checker** vào `deploy/ci/gitops-check/`); image hay chart có người
  tiêu thụ ngoài hệ thống; Renovate đổi cách lấy digest của `github-tags`; release-please thôi bảo trì; lượt đầu cần `issues: write`.

## Xác nhận

- Lúc quyết chưa hiện thực. Kiểm tĩnh: config release-please theo `$schema` [N2]; `make zizmor`, actionlint với `release.yml`; regex Renovate
  khớp đúng hai dòng (Python `re`); bước khớp tag chạy tay với commit đúng và sai.
- Sau merge: `release.yml` mở PR `1.0.0` bằng App (không lỗi quyền nhãn, comment), PR đó qua `ci-ok`, `images-ok`; merge tạo tag
  `gitops-check-v1.0.0`, GitHub Release; ruleset từ chối dời tag; PR `svp-gitops` ghim bản đó qua `gitops-ok`; PR Renovate đầu nâng cả version
  và commit.

## Hiện thực ở

- Repo này: `release-please-config.json`, `.release-please-manifest.json` (§2), `.github/workflows/release.yml` (§3), `deploy/ci/CHANGELOG.md`
  (§2, do release-please viết), `CODEOWNERS`; `docs/reference/ci.md`, `docs/runbooks/gitops-checker-release.md` (§5, §6);
  `deploy/ci/values-check.sh`, `deploy/ci/gitops-tree-policies/lib.rego`, `author.rego` (§1: danh sách service theo revision của env).
- `svp-infra`: `github/apps/svp-release-please.json`, `github/apps/destinations.json`, `github/environments.tf`, `github/repositories.tf`
  (`patterns_allowed`), `github/rulesets.tf` (§3, §4).
- `svp-gitops`: `.github/workflows/check.yml`, `renovate.json` (§5).

## Nguồn

Đọc 2026-11-15; [N1]–[N17] kèm link và trích dẫn ở [phụ lục](appendix/0077-versioned-gitops-checker.md#nguồn).

## Thông tin thêm

Phụ lục: [`appendix/0077-versioned-gitops-checker.md`](appendix/0077-versioned-gitops-checker.md) (phương án, release-please, App, Renovate, nguồn).
