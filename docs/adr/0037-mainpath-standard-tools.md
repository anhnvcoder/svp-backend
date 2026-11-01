# 0037. Đường chính theo công cụ chuẩn, một đường thẳng: DORA và CI trung lập nền tảng rời đường chính, promote bằng bước Actions `yq` + `gh pr`, bỏ bản ghi stg, check của `svp-gitops` rút gọn, khác biệt nền tảng là dữ liệu

- Trạng thái: Chấp nhận (người học duyệt 2026-10-31); §1, §2, §4 (smoke, `gitops.sh`) hiện thực ở PR-A 2026-11-01; §4–§6 (promote, check rút gọn, policy Kyverno CLI) ở PR-B 2026-11-01; §3 (allowlist action), Argo CD Notifications và `actions/attest` chưa
- Ngày: 2026-11-01

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
2. **`allowed_actions` chỉ cho action của GitHub và `sigstore/cosign-installer`** ([0015](0015-cicd-devsecops-stage5.md) §11): mọi công cụ
   thành script gọi image ghim digest.
3. **CI trung lập nền tảng** ([0023](0023-ci-platform-neutral.md)): mọi API của GitHub (PR, Deployment, artifact, event) đi qua adapter.

Thêm vào đó là thói quen giữ tương thích ngược với mọi commit và cây cũ (bảng nguồn dựng lại cho commit chưa có `sources.json`, cây
`svp-gitops` chưa có `platforms/`, biến `SVP_SMOKE_LEGACY_MEDIA`), và nhánh shell theo nền tảng k3d/EKS cho những thứ chỉ là giá trị khác nhau.

## Các lựa chọn

Trạng thái công cụ (**cũ**, **hiện hành**, **mới nổi**) lấy từ bản đánh giá ngày 2026-10-31; nguồn ở mục Nguồn, chỗ bản đánh giá không có nguồn
riêng ghi "không nguồn riêng", chỗ chưa thử ghi "chưa kiểm".

### 1. DORA

| Lựa chọn | Trạng thái | Ghi chú |
| --- | --- | --- |
| A. Giữ `dora.sh` + `dora.yml` ([0028](0028-dora-metrics.md)) | tự làm | Số của stg dựng/xoá mỗi lượt không đo giao hàng; chính script ghi "stg lab" |
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
| B. Kargo v1.12 (27/10/2026; Freight, Stage, verification) | hiện hành, đang lên [N1][N2] | Trạng thái Freight nằm trong CRD của cluster; cluster dựng/xoá mỗi buổi thì mất (suy luận, chưa kiểm) |
| C. Argo CD Image Updater v1.4 (CRD `ImageUpdater`, write-back qua PR từ v1.2.0) | hiện hành [N3] | Bị [0015](0015-cicd-devsecops-stage5.md) §9, [0024](0024-multi-environment.md) loại vì đọc tag không gắn chữ ký; lý do "chưa 1.0" của 0024 nay đã cũ |
| D. Bước Actions `yq` + `gh pr create` + `gh pr merge --auto` | hiện hành, phổ biến nhất ở team nhỏ (không nguồn riêng) | ~50–80 dòng cho stg, ~30 dòng cho prd (ước lượng) |
| Bản ghi triển khai: Argo CD Notifications ghi commit status/Deployment | hiện hành (không nguồn riêng; [0032](0032-argocd-deploy-status.md) A, B) | Cần Argo CD chạy suốt buổi |
| Luật trên manifest đã render: Kyverno CLI `apply`/`test` | hiện hành [N5][N6] | Cùng ngôn ngữ policy với admission của cluster, nên chọn hơn conftest/OPA |
| Diff manifest do Argo CD render trong PR: argocd-diff-preview | hiện hành [N4] | — |

## Quyết định

**Nguyên tắc.** Đường chính là một đường thẳng: không thêm nhánh `if` theo chế độ (máy/CI, nền tảng CI, cây cũ/mới). Khác biệt k3d/EKS là dữ
liệu, không phải shell. Tương thích ngược với commit hay cây cũ giữ tối đa một bản phát hành rồi xoá. Logic chỉ cho test (CLI giả, chế độ
`local`) nằm trong test hay ở `svp-labs`. Mọi công cụ mới chạy bằng image ghim digest như `KUBECONFORM_IMAGE`, hay bằng action khi đã có trong
allowlist (mục 3).

1. **DORA rời đường chính (1D bỏ, 1A thành lab).** Xoá `dora.yml`; `dora.sh` và test của nó thành bài lab `dora/` của `svp-labs`, đóng băng,
   chạy được ở một commit ghim của `svp-backend` (script cần `common.sh`, `platform.sh`, `lib.sh` của commit đó). Khi có prd chạy lâu dài thì
   dùng Apache DevLake (1B). Thay [0028](0028-dora-metrics.md).
2. **Adapter CI trung lập đóng băng (2B).** Không thêm hàm `ci_*`; script mới đọc biến GitHub và gọi `gh` trực tiếp; `platform-guard.sh` bị
   xoá và bỏ khỏi job `config` của `svp-backend` và `svp-frontend`; hàm của adapter bị xoá khi không còn script nào (ở cả hai repo) dùng. Không gỡ
   adapter một lần (chi phí lớn, không cần). CI trên GitLab là bài lab của `svp-labs` (bảng ánh xạ của 0023 là đề bài). Thay
   [0023](0023-ci-platform-neutral.md).
3. **`allowed_actions` mở theo pattern cho đúng các action cần (3B).** Ghim SHA vẫn bắt buộc (`sha_pinning_required`); cài đặt sửa ở
   `infra/github/` của repo `svp-infra` (cài đặt GitHub dạng code). Mở khi có bước đầu tiên thật sự dùng action bên thứ ba, từng action một, không
   mở trước.
4. **Bỏ tương thích ngược (4B).** Bỏ biến `SVP_SMOKE_LEGACY_MEDIA` (mọi bản phát hành ghi key media có version từ
   [0029](0029-immutable-media-versions.md)); revision `svp-gitops` chưa có `platforms/` thì bootstrap và check dừng; `release_sources` không
   dựng bảng cho commit chưa có `sources.json` nữa, commit như vậy thì dừng nêu commit.
5. **Ma trận env × nền tảng là dữ liệu (5B).** Khoá `platforms` ở đầu `argocd/apps/components.json` của `svp-gitops`:
   `{"k3d": {"envs": ["stg"], "localHosts": true}, "eks": {"envs": ["stg", "prd"]}}` (env nào render trên nền tảng nào; render của nền tảng nào
   được nêu tên lab `*.svp.localhost`); check đọc khoá này, thiếu hay sai dạng là đỏ, tên nền tảng phải khớp thư mục `platforms/`. Nhánh vòng đời
   (tạo cluster k3d hay dùng cluster EKS có sẵn, đường vào Valkey, mặc định object store theo context) vẫn là shell, vì đó là việc khác nhau, không
   phải giá trị khác nhau.
6. **Promote bằng bước Actions, bỏ bản ghi stg, check rút gọn (6D).**
   - **stg:** job `promote` của `images.yml` (và job tương ứng ở `svp-frontend`) dựng nhánh bot một commit trên `main` của `svp-gitops`, `yq -i`
     khối `image` của file mỗi service vừa ký (backend thêm `envs/stg/charts.yaml`), push `--force-with-lease`, `gh pr create`/`edit`,
     `gh pr merge --auto --squash --match-head-commit`. Thứ tự giữ bằng nhóm `concurrency` không huỷ sẵn có của workflow thay cho luật tổ tiên
     của `promote.sh`; còn một guard nhỏ ở promote của backend: commit của lượt là tổ tiên thật của `revision` đang ở `envs/stg/charts.yaml` thì
     từ chối (chạy lại hay dispatch commit cũ không kéo chart và migration lùi), bằng `revision` thì nhận.
   - **prd:** dispatch `promote_prd` nhận `stg_ref` (`main` hay SHA đủ 40 hex của một commit trên `main` `svp-gitops`; commit cũ hơn là rollback),
     chép giá trị khối `image` của cả bảy file và ba khoá của `charts.yaml` ở `envs/stg/` của commit đó sang `envs/prd/`, mở PR không auto-merge;
     Code Owner duyệt.
   - **Bỏ:** bản ghi stg tự dựng (`release-set.sh`, `record-stg.sh`, job `record-stg`), phép "bộ prd = payload một bản ghi" (bước 1b), dạng cũ của luật tác giả
     PR (bước 1c: tiếp quản, đọc qua adapter), luật tổ tiên của check (tag image là tổ tiên của `revision`; tag nguồn khác là commit trên `main` repo nguồn). Bản ghi trạng thái
     triển khai sau này là Argo CD Notifications theo [0032](0032-argocd-deploy-status.md) A, B, khi có EKS stg chạy suốt buổi.
   - **Giữ luật tác giả hẹp viết từ dữ liệu** (sửa sau review của bước rút gọn, 2026-11-01): PR của `<promoter>[bot]` một nguồn chỉ đổi file
     image của chính service của nguồn đó (`envs/{stg,prd}/images/`), bot của `backend` thêm `envs/{stg,prd}/charts.yaml`; bot khác không đổi gì dưới
     `envs/`. Lý do: `/envs/stg/` không Code Owner nên PR bot tự merge; bỏ hẳn luật thì khoá App lộ (GIT-6, Cao) đổi được `charts.yaml` về commit cũ
     hay overlay stg mà không ai duyệt.
   - **`gitops-check.sh` còn:** hình dạng cây, `charts.yaml` (khoá, hai giá trị dẫn xuất, `revision` trên `main` repo code), render root, render
     chart + kubeconform, luật khai báo bằng Kyverno CLI trên manifest đã render (image bên thứ ba ghim digest, `svp.localhost` theo khoá
     `platforms`; ref image nào ngoài tầm policy thì giữ phép quét của script), kiểm bản phát hành (chữ ký, attestation, nguồn). Check của
     `svp-gitops` thêm argocd-diff-preview (chỉ báo, ngoài `gitops-ok`, diff vào tóm tắt job). Kyverno CLI và argocd-diff-preview chạy bằng image
     ghim digest, không cần action.
   - Kargo (6B) là bài lab của `svp-labs`; Image Updater (6C) giữ loại vì lý do chữ ký.
   - Provenance bằng `actions/attest` thay predicate tự dựng: chưa làm. Spike `svp-labs/attest-spike` (Kyverno v1.19.1): policy nhận được hai
     định dạng giữa các image, nhưng một image có Sigstore bundle thì Kyverno và cosign bỏ `.sig`/`.att` cũ; chuyển phải gồm chữ ký, `vuln`,
     provenance trong một bản phát hành, và rescan `--replace` với bundle chưa kiểm. ADR riêng khi làm.

   Thay [0025](0025-gitops-config-repo.md) §6 (job promote, bản ghi stg, quyền `deployments` của App) và [0024](0024-multi-environment.md) §8
   (promote prd từ bản ghi, check prd so bản ghi).

## Hệ quả

- Được: bớt khoảng 1 025 dòng DORA, ~2 500 dòng promote và bản ghi, phần lớn độ phức tạp của `gitops-check.sh` (ước lượng lúc quyết 150–250 dòng; thực tế còn ~1 130 dòng cộng ~170 dòng policy, phần lớn là render và kiểm External Secrets giữ nguyên);
  không còn hàm `ci_*` mới; thêm nền tảng hay env là sửa `components.json`; công cụ của đường chính là thứ người học gặp ở công ty.
- Phải trả (nói thẳng):
  - **Không còn bản ghi stg và cổng tự động "prd = bộ stg đã kiểm"** cho tới khi có Argo CD Notifications. Cổng tạm là duyệt của Code Owner trên
    PR prd (PR do bot mở, nên người học duyệt được). `stg_ref` chỉ bảo đảm bộ prd từng nằm trên `main` của `envs/stg/`, không bảo đảm stg đã
    đồng bộ và smoke qua với đúng bộ đó.
  - **Bot của một nguồn đổi được file image của chính nó sang một bản phát hành đã ký cũ hơn** (luật tổ tiên đã bỏ) và PR đó tự merge; lớp còn
    lại: chữ ký đúng identity của nguồn, admission Kyverno, guard tổ tiên của bước promote.
  - **Dispatch hay chạy lại một commit cũ có thể kéo stg lùi** ở chỗ không có guard: guard tổ tiên chỉ ở bước promote (backend và web của `svp-frontend`), check của
    `svp-gitops` không còn chặn tag lùi ở nguồn nào (PR do người mở).
  - Bài lab `dora/` không theo `main`: chỉ chạy được ở commit ghim của `svp-backend`, không ai sửa khi script chung đổi.
  - Đợt chuyển: checker cũ của `svp-gitops` (còn 1b) làm PR prd đỏ cho tới khi `CHECKER_COMMIT` được nâng.
- Xem lại khi: có EKS stg chạy suốt buổi (bật Notifications A, B; cân nhắc lại cổng prd tự động từ commit status); có prd chạy lâu dài (DevLake);
  bài lab Kargo cho kết quả; bước đầu tiên cần action bên thứ ba (mở allowlist, mục 3).

## Hiện thực ở

Repo `svp-backend` (đường dẫn từ gốc repo):

- `.github/workflows/dora.yml`, `deploy/ci/dora.sh`, `deploy/ci/dora-test.sh`: xoá (mục 1).
- `deploy/ci/platform.sh` (header đóng băng; hàm hết người dùng bị xoá), `deploy/ci/platform-test.sh`, `deploy/ci/platform-guard.sh` (xoá),
  job `config` của `.github/workflows/ci.yml`, `deploy/ci/changed-services.sh` (mục 2).
- `deploy/compose/smoke.sh` (bỏ `SVP_SMOKE_LEGACY_MEDIA`), `deploy/k8s/gitops.sh` (đòi `platforms/`),
  `release_sources` của `deploy/k8s/lib.sh`, `deploy/ci/sources-test.sh` (mục 4).
- `.github/workflows/images.yml` job `promote`, `promote-prd` (input `stg_ref`, `yq` bằng `YQ_IMAGE` ghim của `Makefile`) và guard `stg_ref` + tổ tiên,
  `promote_open_pr` ở `deploy/ci/common.sh` có test ở job `config`;
  `deploy/ci/promote.sh`, `promote-prd.sh`, `promote-prd-test.sh`: xoá; `promote-test.sh` thành test của guard (mục 6).
- `.github/workflows/verify.yml` (job `record-stg`), `deploy/ci/verify/gitops.sh` (bước `release-set-before`, `release-set`),
  `deploy/ci/verify-collect.sh`, `verify-collect-test.sh`; `deploy/ci/record-stg.sh`, `release-set.sh`, `release-set-test.sh`: xoá (mục 6).
- `deploy/ci/gitops-check.sh`, `gitops-check-test.sh` (bỏ 1b, dạng cũ của 1c, luật tổ tiên, cây cũ; luật tác giả hẹp từ `sources.json`; ma trận từ `platforms`), `deploy/ci/gitops-policies/`
  (policy Kyverno CLI và `kyverno test`), `KYVERNO_CLI_IMAGE` của `Makefile` (mục 5, 6).

Repo khác:

- `svp-labs`: `README.md`, bài `dora/` (mục 1).
- `svp-frontend`: `.github/workflows/ci.yml` (bỏ bước guard, mục 2), `.github/workflows/images.yml` job `promote` (mục 6).
- `svp-infra`: `github/` (`allowed_actions`; chưa hiện thực, mục 3).
- `svp-gitops`: `argocd/apps/components.json` (khoá `platforms`, mục 5), `.github/workflows/check.yml` (`CHECKER_COMMIT`, job `diff-preview`,
  mục 6).

Chi tiết vận hành (lệnh, job, input) ở [`docs/ci-cd.md`](../ci-cd.md).

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
