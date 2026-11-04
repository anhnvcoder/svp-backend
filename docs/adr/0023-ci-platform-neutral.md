# 0023. CI trung lập nền tảng: YAML của nền tảng chỉ nối bước, logic ở `Makefile` và `deploy/ci/`, mọi chỗ đọc ngữ cảnh CI hay gọi API nền tảng đi qua adapter `deploy/ci/platform.sh` (hiện thực GitHub Actions và chạy trên máy), identity ký viết ở một chỗ; bảng ánh xạ GitHub ↔ GitLab (gitlab.com và self-managed)

- Trạng thái: Bị thay bởi [0037](0037-mainpath-standard-tools.md)
- Ngày: 2026-10-25
- Người quyết: người học (chốt 2026-10-25: thiết kế để mang CI sang nền tảng khác dễ, chưa chạy thật ở đó, chỉ xét GitHub và GitLab)

## Bối cảnh và vấn đề

- Dự án để học DevOps; đi làm có thể gặp GitLab (gitlab.com, hay GitLab self-managed của công ty, phổ biến ở Việt Nam). Phạm vi gồm cả phần CI lẫn phần repo: PR, nhánh bảo vệ, registry, token.
- [ADR-0015](0015-cicd-devsecops-stage5.md) §1 đã đặt logic ở `Makefile` và `deploy/ci/*.sh`, nhưng chỗ gắn GitHub còn rải ngoài `.github/`: `GITHUB_OUTPUT`, `GITHUB_STEP_SUMMARY`, `GITHUB_REPOSITORY`, `GITHUB_RUN_ID`, `GITHUB_RUN_ATTEMPT`, `GITHUB_SERVER_URL`, `GITHUB_WORKFLOW_REF`, `GITHUB_ACTIONS` và `gh pr`/`gh api`/gợi ý `gh workflow run` trong hơn mười script (`common.sh`, `plan.sh`, `promote.sh`, `rescan.sh`, `scan-gate.sh`, `vuln-predicate.sh`, `values-check.sh`, `deploy/k8s/gitops.sh` và các drill); `RUNNER_TEMP`, `::add-mask::`, `::warning::` trong `deploy/ci/verify-*.sh` ([ADR-0021](0021-deferred-verification-stage6b.md) §4); identity ký keyless viết hai lần (`common.sh` và values của chart `deploy/helm/svp-policy`). Danh sách đầy đủ ở [phụ lục](appendix/0023-ci-platform-neutral.md#bối-cảnh).
- Ràng buộc: không đổi hành vi của ba workflow (`ci.yml`, `images.yml`, `verify.yml`: output, summary, PR promote, attestation có link lượt chạy); không thêm công cụ; không viết `.gitlab-ci.yml` lúc này.

## Yếu tố quyết định

- Chuyển nền tảng không phải dò từng file, không sót chỗ chỉ lỗi lúc chạy (output mất thì bước sau vẫn "xanh").
- Kiểm được trên máy, không cần project GitLab; cùng ngôn ngữ và cách chạy của script hiện có; không thêm công cụ chính cho mảng đã có `Makefile`.

## Phương án đã cân nhắc

- Để nguyên, ghi danh sách chỗ phải sửa: biến GitHub rải trong 10+ script, dễ sót.
- **Adapter shell: một file `deploy/ci/platform.sh`, mỗi hàm một nhánh theo nền tảng**: rẻ nhất, chạy được trên máy, test bằng biến giả; cần kỷ luật (grep là phép kiểm), vài khái niệm không có tương đương.
- Dagger: chạy y hệt mọi CI nhưng thêm một engine và cách viết mới, vẫn cần adapter cho output, summary, mask, PR; job chạy Docker-in-Docker, đổi đường build/quét/ký đã kiểm ở ADR-0015 §4.
- Công cụ pipeline-as-code khác (Earthly, Nix, task runner): cùng cái giá, không bớt phần gắn nền tảng (token OIDC, PR, nhánh bảo vệ).
- Viết song song `.gitlab-ci.yml` ngay: không có project GitLab để chạy, YAML không chạy là YAML không kiểm được, mỗi thay đổi CI thành hai. Bảng ưu nhược đầy đủ ở [phụ lục](appendix/0023-ci-platform-neutral.md#các-lựa-chọn).

## Kết quả quyết định

Chọn **adapter shell**: rẻ nhất, cùng công cụ, kiểm được trên máy. Dagger xét lại khi pipeline cần chạy y hệt ở nhiều nơi thật (ví dụ dự án công ty chạy GitLab), không phải lúc chỉ có một nền tảng chạy thật.

1. **Nguyên tắc.** YAML của nền tảng (`.github/workflows/*.yml`, sau này `.gitlab-ci.yml`) chỉ nối bước: trigger, quyền, runner, service container, cache, artifact, gọi target `make` hay script. Logic ở `Makefile` và `deploy/ci/`. Script đọc ngữ cảnh CI hay gọi API nền tảng (PR, sự kiện, dispatch) thì đi qua hàm `ci_*` của `deploy/ci/platform.sh`. Phép kiểm `deploy/ci/platform-guard.sh` (job `config` của `ci.yml` và trên máy): grep `GITHUB_[A-Z_]+|\bgh (api|pr|run|workflow)\b` trên file đã track và file chưa track không bị ignore của `deploy/` và `Makefile`, bỏ symlink và file đã xoá khỏi working tree, loại `platform.sh`, hai test giả lập job GitHub (`platform-test.sh`, `verify-collect-test.sh`) và chính nó; có dòng khớp thì in `file:dòng:` và exit 1.
2. **Ngoại lệ có chủ ý, giữ trong YAML:** job `last-success` của `images.yml` gọi `gh api` vì giữ `actions: read` và không checkout, không chạy code của repo (ADR-0015 §3); các bước `docker login ghcr.io` bằng `GITHUB_TOKEN`; `$GITHUB_OUTPUT`, `$GITHUB_ENV`, `$GITHUB_PATH`, `::error::` của chính YAML; `$GITHUB_STEP_SUMMARY` do YAML của `ci.yml` ghi thẳng (bảng SARIF, anchor `sarif-summary`, và dòng bỏ qua của `buf`). Khi chuyển nền tảng thì viết lại cùng file đó.
3. **`platform.sh`** (source từ `common.sh`, hay source thẳng) chỉ định nghĩa hàm; mỗi hàm trả 1 và in `FAIL  ...` khi lỗi. Hai nền tảng: `github` (`GITHUB_ACTIONS=true`) và `local` (stdout, không mask, **không ghi gì qua API**: lệnh ghi chỉ in lệnh sẽ chạy; lệnh đọc vẫn hỏi GitHub bằng `gh` đã đăng nhập; `promote.sh` trên máy chỉ push `bot/promote` khi URL push của `origin` là đường dẫn trên đĩa, origin khác thì dừng trước khi đọc gì và gợi ý `PROMOTE_DRY_RUN=1`). Nền tảng khác (`GITLAB_CI`, `JENKINS_URL`, `TF_BUILD`, hay `CI` khác rỗng, `false`, `0`) thì dừng: "only GitHub Actions and local runs are implemented; add a branch in deploy/ci/platform.sh for another CI". Bảng tên chốt (hàm `ci_*`, cột `github`, `local`, nhánh `gitlab` sau này) ở [phụ lục](appendix/0023-ci-platform-neutral.md#quyết-định).
4. **Identity ký một chỗ:** issuer và subject chỉ viết ở `imageVerification.issuer`, `.subject` của `deploy/helm/svp-policy/values.yaml`; `common.sh` (`sign_identity`, dùng bởi `verify_signature`, `verify-release.sh`) và `drills/supplychain.sh` đọc hai dòng đó. Bản render của chart không đổi.
5. **`changed-services.sh`:** `platform.sh` nằm trong pipeline image nên đổi nó build lại cả bảy như đổi `common.sh`; `platform-test.sh` và `platform-guard.sh` được loại như `verify-collect-test.sh`; ADR (`docs/`) và values của `svp-policy` không build gì.
6. **Hành vi:** trên GitHub không đổi (giống từng byte với cùng biến giả). Trên máy khác có chủ ý: `promote.sh` không mở PR thật mà in lệnh và không push lên origin mạng; link lượt chạy là `local`; `verify-mask.sh` không in lệnh mask; thư mục tạm mặc định của năm script `verify-*` là `/tmp`.

Bảng ánh xạ CI (GitHub Actions ↔ GitLab CI), bảng ánh xạ repo, khác biệt gitlab.com và self-managed, danh sách bước mang sang GitLab và phần không mang được 1-1 ở [phụ lục](appendix/0023-ci-platform-neutral.md#bảng-ánh-xạ-ci-github-actions--gitlab-ci).

### Hệ quả

- Tốt: chỗ gắn nền tảng của script nằm trong một file có test (`deploy/ci/platform-test.sh`, trên máy, không mạng); mang sang GitLab là một danh sách việc có thứ tự, kể cả việc không mang được; identity ký sửa một chỗ; chạy script trên máy không mở PR thật, không push lên remote mạng, không in giá trị mask.
- Xấu: một lớp gián tiếp (đọc script phải biết `ci_*`); mỗi script mới phải dùng adapter (`platform-guard.sh` bắt); đổi `platform.sh` build lại cả bảy image. Không mang được 1-1 sang GitLab: mask giá trị sinh lúc chạy, trang summary và annotation, output theo bước (dotenv 5 KB), cổng "Approve workflows to run", check bắt buộc theo app (`integration_id`), ký keyless bằng Sigstore công khai trên self-managed, service container trên `127.0.0.1` (chỉ chắc ở executor Kubernetes).
- Xem lại khi: có project GitLab thật để chạy (viết `.gitlab-ci.yml` và nhánh `gitlab`, đo lại; xét Dagger nếu phải chạy y hệt ở cả hai), hay khi một bước mới cần khái niệm không có ở bảng ánh xạ.

## Xác nhận

- `deploy/ci/platform-test.sh` xanh: `github` với biến giả, `local`, GitLab CI và `CI=true` bị từ chối; `promote.sh` trên máy với origin `https://`, `git@host:` bị từ chối; `platform-guard.sh` sạch trên working tree, exit 1 với `$GITHUB_OUTPUT` thêm vào.
- Không đổi hành vi: bản script trước và sau, cùng biến giả, giống từng byte trên GitHub; `deploy/ci/verify-collect-test.sh` xanh 98 phép kiểm; `helm template deploy/helm/svp-policy` giống hệt; `make actionlint` sạch. Bảng kiểm chứng ở [phụ lục](appendix/0023-ci-platform-neutral.md#kiểm-chứng-đã-kiểm-ngày-2026-10-25).

## Hiện thực ở

Từ 2026-10-30 ([ADR-0033](0033-svp-web-repo.md)): identity ký ở `deploy/helm/svp-policy/files/sources.json` (một mục mỗi nguồn), `sign_identity`, `use_build_source` của `deploy/ci/common.sh`; `script_root`, `code_root` (`SVP_CODE_ROOT`) của `common.sh` cho script chạy trên cây của repo khác; `deploy/ci/platform-guard.sh [ROOT]`; `ci_change_request_author`, `ci_change_request_sender` của `deploy/ci/platform.sh`. Workflow của `svp-frontend` gọi các script này từ `.backend/` (checkout ở commit `.backend-commit`).

- `deploy/ci/platform.sh` (adapter), `deploy/ci/platform-test.sh` (test), `deploy/ci/platform-guard.sh` (phép kiểm); cả hai chạy ở job `config` của `.github/workflows/ci.yml`.
- Script gọi adapter: `deploy/ci/common.sh` (`sign_identity`), `plan.sh`, `promote.sh`, `rescan.sh`, `scan-gate.sh`, `values-check.sh`, `verify-release.sh`, `vuln-predicate.sh`, `verify-host.sh`, `verify-run.sh`, `verify-sample.sh`, `verify-mask.sh`, `verify-collect.sh` (và `verify-collect-test.sh` chạy chúng như job GitHub); `deploy/k8s/gitops.sh`, `deploy/k8s/drills/gitops.sh`, `deploy/k8s/drills/supplychain.sh`; bước `rescan` của `.github/workflows/images.yml`.
- Identity ký: `deploy/helm/svp-policy/values.yaml`. Quy tắc build: `deploy/ci/changed-services.sh`.

## Nguồn

- GitHub, "Workflow commands for GitHub Actions": <https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-commands>
- GitLab, `.gitlab-ci.yml` keyword reference: <https://docs.gitlab.com/ci/yaml/>
- Nguồn của từng dòng ánh xạ ([G1]–[G5], [L1]–[L20], đọc ngày 2026-10-25) ở [phụ lục](appendix/0023-ci-platform-neutral.md#nguồn).

## Thông tin thêm

Phụ lục: [`appendix/0023-ci-platform-neutral.md`](appendix/0023-ci-platform-neutral.md) (dòng trạng thái gốc với các ghi chú có ngày, bối cảnh đầy đủ, phân tích phương án, bảng tên chốt, hai bảng ánh xạ, bước mang sang GitLab, kiểm chứng, nguồn).

Bị thay bởi [0037](0037-mainpath-standard-tools.md) (2026-11-01): adapter đóng băng, `platform-guard.sh` bỏ, GitLab là bài lab của `svp-labs`.

### Chỉnh bởi

- §3: [0025](0025-gitops-config-repo.md), [0028](0028-dora-metrics.md) (từ 2026-10-30): bảng Tên chốt thêm hàm của repo cấu hình (PR ở repo đích và auto-merge, bot và credential git của GitHub App, `ci_push_time` theo repo, lượt chạy, bản ghi Deployment) và dòng của repo cấu hình ở bảng ánh xạ repo.
- §4: [0033](0033-svp-web-repo.md) (từ 2026-10-30): identity ký thành bảng nhiều nguồn `deploy/helm/svp-policy/files/sources.json`.
- §1: [0033](0033-svp-web-repo.md): `platform-guard.sh` nhận thư mục gốc, chạy cả ở `svp-frontend`.
- §3: [0033](0033-svp-web-repo.md): hàm `ci_*` đọc tác giả và người gửi PR; bảng ánh xạ thêm script chung, multi-project, credential thứ hai.
