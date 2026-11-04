# Phụ lục ADR-0037: Đường chính theo công cụ chuẩn, một đường thẳng: DORA và CI trung lập nền tảng rời đường chính, promote bằng bước Actions `yq` + `gh pr`, bỏ bản ghi stg, check của `svp-gitops` rút gọn, khác biệt nền tảng là dữ liệu

Phụ lục của [ADR-0037](../0037-mainpath-standard-tools.md): phần chuyển ra khỏi ADR, giữ nguyên văn: số đo lúc quyết, phân tích sáu nhóm phương án với trạng thái công cụ, nguồn. Đây là lịch sử, nên giữ ngày và nhãn tiến độ của lúc ghi.

## Trạng thái ghi lúc chốt

- Trạng thái: Chấp nhận (người học duyệt 2026-10-31); §1, §2, §4 (smoke, `gitops.sh`) hiện thực ở PR-A 2026-11-01; §4–§6 (promote, check rút gọn, policy Kyverno CLI) ở PR-B 2026-11-01; `actions/attest` ở PR-D theo [0040](../0040-sigstore-bundle-actions-attest.md); §3 (allowlist action), Argo CD Notifications chưa

## Bối cảnh

Ngày 2026-10-31 người học chốt hai hướng: **đường chính** (build, quét, ký, promote, triển khai stg/prd, CI) dùng công cụ chuẩn ngành;
**đường học** là repo `svp-labs` (bản clone `<workspace>/labs`): bản tự làm dựng một lần, đo, so với bản chuẩn, kết luận vào ADR, không bảo trì.
Bản đánh giá cùng ngày (ghi chú học, không nằm trong repo) đếm bằng `wc -l` ở commit `2fc7870` của repo này:

| Đo ở `2fc7870` | Dòng |
| --- | --- |
| `deploy/ci/*.sh` (43 file) | 16 564 |
| Adapter CI: `platform.sh`, `platform-test.sh`, `platform-guard.sh`; 641 lời gọi `ci_*` ở 37 file | 856 + 1 749 + 74 |
| Promote và bản ghi stg: `promote.sh`, `promote-prd.sh`, `release-set.sh`, `record-stg.sh` (+ test) | 1 242 (+ 1 291) |
| `gitops-check.sh` (+ test) | 927 (+ 632) |
| DORA: `dora.sh` (+ test), `dora.yml` | 575 (+ 450), 78 |

Phần công cụ giao hàng đã lớn ngang code sản phẩm Go (14 912 dòng không test), và phần lớn sinh ra từ ba ràng buộc của lab, không phải của
ngành:

1. **stg và prd không chạy lâu dài** (stg dựng và xoá trong một lượt `verify.yml`, EKS ở giai đoạn 7 dựng và xoá trong buổi): không Argo CD nào
   sống đủ lâu để báo trạng thái, nên repo tự chế bản ghi stg, check prd so bản ghi (bước 1b của `gitops-check.sh`), DORA từ bản ghi.
2. **`allowed_actions` chỉ cho action của GitHub và `sigstore/cosign-installer`** ([0015](../0015-cicd-devsecops-stage5.md) §11): mọi công cụ
   thành script gọi image ghim digest.
3. **CI trung lập nền tảng** ([0023](../0023-ci-platform-neutral.md)): mọi API của GitHub (PR, Deployment, artifact, event) đi qua adapter.

Thêm vào đó là thói quen giữ tương thích ngược với mọi commit và cây cũ (bảng nguồn dựng lại cho commit chưa có `sources.json`, cây
`svp-gitops` chưa có `platforms/`, biến `SVP_SMOKE_LEGACY_MEDIA`), và nhánh shell theo nền tảng k3d/EKS cho những thứ chỉ là giá trị khác nhau.

## Các lựa chọn

Trạng thái công cụ (**cũ**, **hiện hành**, **mới nổi**) lấy từ bản đánh giá ngày 2026-10-31; nguồn ở mục Nguồn, chỗ bản đánh giá không có nguồn
riêng ghi "không nguồn riêng", chỗ chưa thử ghi "chưa kiểm".

### 1. DORA

| Lựa chọn | Trạng thái | Ghi chú |
| --- | --- | --- |
| A. Giữ `dora.sh` + `dora.yml` ([0028](../0028-dora-metrics.md)) | tự làm | Số của stg dựng/xoá mỗi lượt không đo giao hàng; chính script ghi "stg lab" |
| B. Apache DevLake | hiện hành [N7] | Cần nguồn triển khai chạy lâu dài (prd) |
| C. SaaS (LinearB, Swarmia, DX…), dashboard DORA của GitLab Ultimate | hiện hành [N9] | Trả phí hay khác nền tảng |
| D. Four Keys của Google | cũ (archive 11/03/2024 [N8]) | Không chọn |

### 2. CI trung lập nền tảng

| Lựa chọn | Trạng thái | Ghi chú |
| --- | --- | --- |
| A. Giữ adapter, thêm hàm `ci_*` cho mỗi API mới | tự làm | Mỗi hàm mới kéo nhánh GitLab trên giấy và test; adapter bọc cả API PR, Deployment, artifact là hiếm gặp |
| B. YAML riêng của nền tảng, logic ở `Makefile` và script; script đọc biến GitHub và `gh` trực tiếp | hiện hành (không nguồn riêng) | Phần "logic ở Make/script" repo đã làm |
| C. Dagger (pipeline chạy mọi nơi) | hiện hành, ngách [N10] | Thêm một công cụ chính cho một nhu cầu chưa có |

### 3. Action bên thứ ba

| Lựa chọn | Trạng thái | Ghi chú |
| --- | --- | --- |
| A. Giữ chỉ action của GitHub | — | Mọi công cụ thành script gọi image ghim |
| B. Allowlist từng action theo pattern, ghim SHA bắt buộc (`patterns_allowed`) | hiện hành (không nguồn riêng) | Hẹp, Renovate theo dõi SHA |

### 4. Tương thích ngược

| Lựa chọn | Ghi chú |
| --- | --- |
| A. Giữ đường cho mọi commit và cây cũ | Mỗi đường cũ là một nhánh `if` có test, sống mãi |
| B. Giữ tối đa một bản phát hành rồi xoá | Commit cũ hơn thì dừng với message rõ, không đọc lại |

### 5. Khác biệt k3d/EKS

| Lựa chọn | Ghi chú |
| --- | --- |
| A. Nhánh shell theo nền tảng (như check hôm nay ghi cứng `stg:k3d stg:eks prd:eks` và "prd, eks thì không có `svp.localhost`") | Thêm nền tảng là sửa script |
| B. Giá trị khác nhau là dữ liệu của `svp-gitops`, việc khác nhau (vòng đời cluster) vẫn là shell | Thêm nền tảng là sửa dữ liệu |

### 6. Promote, bản ghi stg, check của `svp-gitops`

| Lựa chọn | Trạng thái | Ghi chú |
| --- | --- | --- |
| A. Giữ `promote.sh`, `promote-prd.sh`, bản ghi stg, check 1b/1c | tự làm | ~2 500 dòng script + test |
| B. Kargo v1.12 (27/10/2026; Freight, Stage, verification) | hiện hành, đang lên [N1] [N2] | Trạng thái Freight nằm trong CRD của cluster; cluster dựng/xoá mỗi buổi thì mất (suy luận, chưa kiểm) |
| C. Argo CD Image Updater v1.4 (CRD `ImageUpdater`, write-back qua PR từ v1.2.0) | hiện hành [N3] | Bị [0015](../0015-cicd-devsecops-stage5.md) §9, [0024](../0024-multi-environment.md) loại vì đọc tag không gắn chữ ký; lý do "chưa 1.0" của 0024 nay đã cũ |
| D. Bước Actions `yq` + `gh pr create` + `gh pr merge --auto` | hiện hành, phổ biến nhất ở team nhỏ (không nguồn riêng) | ~50–80 dòng cho stg, ~30 dòng cho prd (ước lượng) |
| Bản ghi triển khai: Argo CD Notifications ghi commit status/Deployment | hiện hành (không nguồn riêng; [0032](../0032-argocd-deploy-status.md) A, B) | Cần Argo CD chạy suốt buổi |
| Luật trên manifest đã render: Kyverno CLI `apply`/`test` | hiện hành [N5] [N6] | Cùng ngôn ngữ policy với admission của cluster, nên chọn hơn conftest/OPA |
| Diff manifest do Argo CD render trong PR: argocd-diff-preview | hiện hành [N4] | — |

## Nguồn

- [N1] Kargo: [releases](https://github.com/akuity/kargo/releases) (v1.12.5 ngày 27/10).
- [N2] [Akuity: The Promotion Layer GitOps Was Missing](https://akuity.io/blog/kargo-gitops-promotion-layer).
- [N3] Argo CD Image Updater: [releases](https://github.com/argoproj-labs/argocd-image-updater/releases) (v1.4.0, CRD `ImageUpdater`, PR
  write-back từ v1.2.0; năm của bản phát hành suy ra, trang chỉ hiện ngày/tháng).
- [N4] argocd-diff-preview: [repo](https://github.com/dag-andersen/argocd-diff-preview).
- [N5] Kyverno: [Testing Policies (CLI)](https://kyverno.io/docs/testing-policies/).
- [N6] Conftest + Kyverno CLI trong CI: [oneuptime 2026-03-13](https://oneuptime.com/blog/post/2026-03-13-policy-compliance-check-ci-flux-cd/view).
- [N7] [Apache DevLake DORA](https://devlake.apache.org/docs/v0.19/DORA), [DevLake](https://devlake.apache.org/).
- [N8] [Four Keys, repo đã archive](https://github.com/dora-team/fourkeys).
- [N9] [Best DORA Metrics Trackers for 2026](https://typoapp.io/blog/dora-metrics-trackers).
- [N10] Dagger: [docs](https://docs.dagger.io/).

## Ghi chú bổ sung

- Lịch sử chưa có ở ADR: bước promote `yq` + `gh pr` thay `promote.sh`, `promote-prd.sh` là một mục "kiểm sau push" còn treo (kiểm trên lượt chạy thật sau merge).
