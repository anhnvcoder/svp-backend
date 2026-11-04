# 0037. Đường chính theo công cụ chuẩn, một đường thẳng: DORA và CI trung lập nền tảng rời đường chính, promote bằng bước Actions `yq` + `gh pr`, bỏ bản ghi stg, check của `svp-gitops` rút gọn, khác biệt nền tảng là dữ liệu

- Trạng thái: Chấp nhận
- Ngày: 2026-11-01
- Người quyết: người học (duyệt 2026-10-31)

## Bối cảnh và vấn đề

Ngày 2026-10-31 người học chốt hai hướng: **đường chính** (build, quét, ký, promote, triển khai stg/prd, CI) dùng công cụ chuẩn ngành; **đường học** là repo `svp-labs` (bản clone `<workspace>/labs`): bản tự làm dựng một lần, đo, so với bản chuẩn, kết luận vào ADR, không bảo trì.

Bản đánh giá cùng ngày (ghi chú học, không nằm trong repo) đếm ở commit `2fc7870`: `deploy/ci/*.sh` 43 file, 16 564 dòng; adapter CI 856 + 1 749 + 74 dòng với 641 lời gọi `ci_*` ở 37 file; promote và bản ghi stg 1 242 (+ 1 291 test) dòng; `gitops-check.sh` 927 (+ 632); DORA 575 (+ 450) và `dora.yml` 78. Phần công cụ giao hàng đã lớn ngang code sản phẩm Go (14 912 dòng không test), và phần lớn sinh ra từ ba ràng buộc của lab, không phải của ngành:

1. **stg và prd không chạy lâu dài** (stg dựng và xoá trong một lượt `verify.yml`, EKS dựng và xoá trong buổi): không Argo CD nào sống đủ lâu để báo trạng thái, nên repo tự chế bản ghi stg, check prd so bản ghi (bước 1b của `gitops-check.sh`), DORA từ bản ghi.
2. **`allowed_actions` chỉ cho action của GitHub và `sigstore/cosign-installer`** ([0015](0015-cicd-devsecops-stage5.md) §11): mọi công cụ thành script gọi image ghim digest.
3. **CI trung lập nền tảng** ([0023](0023-ci-platform-neutral.md)): mọi API của GitHub (PR, Deployment, artifact, event) đi qua adapter.

Thêm vào đó là thói quen giữ tương thích ngược với mọi commit và cây cũ (bảng nguồn dựng lại cho commit chưa có `sources.json`, cây `svp-gitops` chưa có `platforms/`, biến `SVP_SMOKE_LEGACY_MEDIA`) và nhánh shell theo nền tảng k3d/EKS cho những thứ chỉ là giá trị khác nhau. Bảng số đo đầy đủ ở [phụ lục](appendix/0037-mainpath-standard-tools.md#bối-cảnh).

## Yếu tố quyết định

- Công cụ của đường chính là thứ người học gặp ở công ty; bớt code tự làm không có người dùng ngoài lab.
- Thêm nền tảng hay env là sửa dữ liệu, không sửa script; không đường nào chỉ để giữ tương thích với commit cũ.

## Phương án đã cân nhắc

Trạng thái công cụ (cũ, hiện hành, mới nổi) lấy từ bản đánh giá ngày 2026-10-31; bảng đầy đủ và nguồn ở [phụ lục](appendix/0037-mainpath-standard-tools.md#các-lựa-chọn).

### 1. DORA

- A. Giữ `dora.sh` + `dora.yml`: tự làm; số của stg dựng/xoá mỗi lượt không đo giao hàng.
- B. Apache DevLake: hiện hành, cần nguồn triển khai chạy lâu dài.
- C. SaaS hay dashboard DORA của GitLab Ultimate: trả phí hay khác nền tảng.
- D. Four Keys: cũ, đã archive.

### 2. CI trung lập nền tảng

- A. Giữ adapter và thêm hàm `ci_*` cho mỗi API mới: tự làm, kéo nhánh GitLab trên giấy và test.
- **B. YAML riêng của nền tảng, logic ở `Makefile` và script, script đọc biến GitHub và `gh` trực tiếp**.
- C. Dagger: hiện hành, ngách; thêm công cụ cho nhu cầu chưa có.

### 3. Action bên thứ ba

- A. Giữ chỉ action của GitHub.
- **B. allowlist từng action theo pattern, ghim SHA bắt buộc** (`patterns_allowed`).

### 4. Tương thích ngược

- A. Giữ đường cho mọi commit và cây cũ: mỗi đường là một nhánh `if` có test, sống mãi.
- **B. giữ tối đa một bản phát hành rồi xoá**.

### 5. Khác biệt k3d/EKS

- A. Nhánh shell theo nền tảng.
- **B. giá trị khác nhau là dữ liệu của `svp-gitops`**, việc khác nhau (vòng đời cluster) vẫn là shell.

### 6. Promote, bản ghi stg, check của `svp-gitops`

- A. Giữ `promote.sh`, `promote-prd.sh`, bản ghi stg, check 1b/1c: ~2 500 dòng.
- B. Kargo v1.12: trạng thái Freight nằm trong CRD của cluster, cluster dựng/xoá mỗi buổi thì mất.
- C. Argo CD Image Updater v1.4: đọc tag không gắn chữ ký.
- **D. bước Actions `yq` + `gh pr create` + `gh pr merge --auto`**: phổ biến nhất ở team nhỏ.
- Luật trên manifest đã render bằng Kyverno CLI: cùng ngôn ngữ policy với admission.
- argocd-diff-preview: hiện hành.

## Kết quả quyết định

**Nguyên tắc.** Đường chính là một đường thẳng: không thêm nhánh `if` theo chế độ (máy/CI, nền tảng CI, cây cũ/mới). Khác biệt k3d/EKS là dữ liệu, không phải shell. Tương thích ngược với commit hay cây cũ giữ tối đa một bản phát hành rồi xoá. Logic chỉ cho test (CLI giả, chế độ `local`) nằm trong test hay ở `svp-labs`. Mọi công cụ mới chạy bằng image ghim digest như `KUBECONFORM_IMAGE`, hay bằng action khi đã có trong allowlist (mục 3).

1. **DORA rời đường chính (1D bỏ, 1A thành lab).** Xoá `dora.yml`; `dora.sh` và test của nó thành bài lab `dora/` của `svp-labs`, đóng băng, chạy được ở một commit ghim của `svp-backend` (script cần `common.sh`, `platform.sh`, `lib.sh` của commit đó). Khi có prd chạy lâu dài thì dùng Apache DevLake (1B). Thay [0028](0028-dora-metrics.md).
2. **Adapter CI trung lập đóng băng (2B).** Không thêm hàm `ci_*`; script mới đọc biến GitHub và gọi `gh` trực tiếp; `platform-guard.sh` bị xoá và bỏ khỏi job `config` của `svp-backend` và `svp-frontend`; hàm của adapter bị xoá khi không còn script nào (ở cả hai repo) dùng. Không gỡ adapter một lần (chi phí lớn, không cần). CI trên GitLab là bài lab của `svp-labs` (bảng ánh xạ của 0023 là đề bài). Thay [0023](0023-ci-platform-neutral.md).
3. **`allowed_actions` mở theo pattern cho đúng các action cần (3B).** Ghim SHA vẫn bắt buộc (`sha_pinning_required`); cài đặt sửa ở `infra/github/` của repo `svp-infra` (cài đặt GitHub dạng code). Mở khi có bước đầu tiên thật sự dùng action bên thứ ba, từng action một, không mở trước.
4. **Bỏ tương thích ngược (4B).** Bỏ biến `SVP_SMOKE_LEGACY_MEDIA` (mọi bản phát hành ghi key media có version từ [0029](0029-immutable-media-versions.md)); revision `svp-gitops` chưa có `platforms/` thì bootstrap và check dừng; `release_sources` không dựng bảng cho commit chưa có `sources.json` nữa, commit như vậy thì dừng nêu commit.
5. **Ma trận env × nền tảng là dữ liệu (5B).** Khoá `platforms` ở đầu `argocd/apps/components.json` của `svp-gitops`: `{"k3d": {"envs": ["stg"], "localHosts": true}, "eks": {"envs": ["stg", "prd"]}}` (env nào render trên nền tảng nào; render của nền tảng nào được nêu tên lab `*.svp.localhost`); check đọc khoá này, thiếu hay sai dạng là đỏ, tên nền tảng phải khớp thư mục `platforms/`. Nhánh vòng đời (tạo cluster k3d hay dùng cluster EKS có sẵn, đường vào Valkey, mặc định object store theo context) vẫn là shell, vì đó là việc khác nhau, không phải giá trị khác nhau.
6. **Promote bằng bước Actions, bỏ bản ghi stg, check rút gọn (6D).**
   - **stg:** job `promote` của `images.yml` (và job tương ứng ở `svp-frontend`) dựng nhánh bot một commit trên `main` của `svp-gitops`, `yq -i` khối `image` của file mỗi service vừa ký (backend thêm `envs/stg/charts.yaml`), push `--force-with-lease`, `gh pr create`/`edit`, `gh pr merge --auto --squash --match-head-commit`. Thứ tự giữ bằng nhóm `concurrency` không huỷ sẵn có của workflow thay cho luật tổ tiên của `promote.sh`; còn một guard nhỏ ở promote của backend: commit của lượt là tổ tiên thật của `revision` đang ở `envs/stg/charts.yaml` thì từ chối (chạy lại hay dispatch commit cũ không kéo chart và migration lùi), bằng `revision` thì nhận.
   - **prd:** dispatch `promote_prd` nhận `stg_ref` (`main` hay SHA đủ 40 hex của một commit trên `main` `svp-gitops`; commit cũ hơn là rollback), chép giá trị khối `image` của cả bảy file và ba khoá của `charts.yaml` ở `envs/stg/` của commit đó sang `envs/prd/`, mở PR không auto-merge; Code Owner duyệt.
   - **Bỏ:** bản ghi stg tự dựng (`release-set.sh`, `record-stg.sh`, job `record-stg`), phép "bộ prd = payload một bản ghi" (bước 1b), dạng cũ của luật tác giả PR (bước 1c: tiếp quản, đọc qua adapter), luật tổ tiên của check (tag image là tổ tiên của `revision`; tag nguồn khác là commit trên `main` repo nguồn). Bản ghi trạng thái triển khai sau này là Argo CD Notifications theo [0032](0032-argocd-deploy-status.md) A, B, khi có EKS stg chạy suốt buổi.
   - **Giữ luật tác giả hẹp viết từ dữ liệu** (sửa sau review của bước rút gọn, 2026-11-01): PR của `<promoter>[bot]` một nguồn chỉ đổi file image của chính service của nguồn đó (`envs/{stg,prd}/images/`), bot của `backend` thêm `envs/{stg,prd}/charts.yaml`; bot khác không đổi gì dưới `envs/`. Lý do: `/envs/stg/` không Code Owner nên PR bot tự merge; bỏ hẳn luật thì khoá App lộ (GIT-6, Cao) đổi được `charts.yaml` về commit cũ hay overlay stg mà không ai duyệt.
   - **`gitops-check.sh` còn:** hình dạng cây, `charts.yaml` (khoá, hai giá trị dẫn xuất, `revision` trên `main` repo code), render root, render chart + kubeconform, luật khai báo bằng Kyverno CLI trên manifest đã render (image bên thứ ba ghim digest, `svp.localhost` theo khoá `platforms`; ref image nào ngoài tầm policy thì giữ phép quét của script), kiểm bản phát hành (chữ ký, attestation, nguồn). Check của `svp-gitops` thêm argocd-diff-preview (chỉ báo, ngoài `gitops-ok`, diff vào tóm tắt job). Kyverno CLI và argocd-diff-preview chạy bằng image ghim digest, không cần action.
   - Kargo (6B) là bài lab của `svp-labs`; Image Updater (6C) giữ loại vì lý do chữ ký.
   - Provenance bằng `actions/attest` thay predicate tự dựng: chưa làm. Spike `svp-labs/attest-spike` (Kyverno v1.19.1): policy nhận được hai định dạng giữa các image, nhưng một image có Sigstore bundle thì Kyverno và cosign bỏ `.sig`/`.att` cũ; chuyển phải gồm chữ ký, `vuln`, provenance trong một bản phát hành, và rescan `--replace` với bundle chưa kiểm. ADR riêng khi làm.

   Thay [0025](0025-gitops-config-repo.md) §6 (job promote, bản ghi stg, quyền `deployments` của App) và [0024](0024-multi-environment.md) §8 (promote prd từ bản ghi, check prd so bản ghi).

### Hệ quả

- Tốt: bớt khoảng 1 025 dòng DORA, ~2 500 dòng promote và bản ghi, phần lớn độ phức tạp của `gitops-check.sh` (ước lượng lúc quyết 150–250 dòng; thực tế còn ~1 130 dòng cộng ~170 dòng policy, phần lớn là render và kiểm External Secrets giữ nguyên); không còn hàm `ci_*` mới; thêm nền tảng hay env là sửa `components.json`; công cụ của đường chính là thứ người học gặp ở công ty.
- Xấu (nói thẳng):
  - **Không còn bản ghi stg và cổng tự động "prd = bộ stg đã kiểm"** cho tới khi có Argo CD Notifications. Cổng tạm là duyệt của Code Owner trên PR prd (PR do bot mở, nên người học duyệt được). `stg_ref` chỉ bảo đảm bộ prd từng nằm trên `main` của `envs/stg/`, không bảo đảm stg đã đồng bộ và smoke qua với đúng bộ đó.
  - **Bot của một nguồn đổi được file image của chính nó sang một bản phát hành đã ký cũ hơn** (luật tổ tiên đã bỏ) và PR đó tự merge; lớp còn lại: chữ ký đúng identity của nguồn, admission Kyverno, guard tổ tiên của bước promote.
  - **Dispatch hay chạy lại một commit cũ có thể kéo stg lùi** ở chỗ không có guard: guard tổ tiên chỉ ở bước promote (backend và web của `svp-frontend`), check của `svp-gitops` không còn chặn tag lùi ở nguồn nào (PR do người mở).
  - Bài lab `dora/` không theo `main`: chỉ chạy được ở commit ghim của `svp-backend`, không ai sửa khi script chung đổi.
  - Lúc chuyển: checker cũ của `svp-gitops` (còn 1b) làm PR prd đỏ cho tới khi `CHECKER_COMMIT` được nâng.
- Xem lại khi: có EKS stg chạy suốt buổi (bật Notifications A, B; cân nhắc lại cổng prd tự động từ commit status); có prd chạy lâu dài (DevLake); bài lab Kargo cho kết quả; bước đầu tiên cần action bên thứ ba (mở allowlist, mục 3).

## Xác nhận

Hiện thực và kiểm: mục 1, 2, 4 (smoke, `gitops.sh`), 5 và 6 (promote, check rút gọn, policy Kyverno CLI) đã vào `svp-backend` ngày 2026-11-01; provenance bằng `actions/attest` theo [0040](0040-sigstore-bundle-actions-attest.md). Chưa làm: mục 3 (allowlist action; mở khi có bước dùng action bên thứ ba), Argo CD Notifications; kiểm sau push các bước promote `yq` + `gh pr` trên lượt chạy thật. Dòng trạng thái gốc ở [phụ lục](appendix/0037-mainpath-standard-tools.md#trạng-thái-ghi-lúc-chốt).

## Hiện thực ở

Repo `svp-backend` (đường dẫn từ gốc repo):

- `.github/workflows/dora.yml`, `deploy/ci/dora.sh`, `deploy/ci/dora-test.sh`: xoá (mục 1).
- `deploy/ci/platform-guard.sh` (xoá), job `config` của `.github/workflows/ci.yml`, `deploy/ci/changed-services.sh` (mục 2); `deploy/ci/platform.sh`, `deploy/ci/platform-test.sh` xoá theo [0050](0050-bash-to-standard-tools.md) mục 1.
- `deploy/compose/smoke.sh` (bỏ `SVP_SMOKE_LEGACY_MEDIA`), `deploy/k8s/gitops.sh` (đòi `platforms/`), `release_sources` của `deploy/k8s/lib.sh`, `deploy/ci/sources-test.sh` (mục 4).
- `.github/workflows/images.yml` job `promote`, `promote-prd` (input `stg_ref`, `yq` bằng `YQ_IMAGE` ghim của `Makefile`) và guard `stg_ref` + tổ tiên, `promote_open_pr` ở `deploy/ci/common.sh` có test ở job `config`; `deploy/ci/promote.sh`, `promote-prd.sh`, `promote-prd-test.sh`: xoá; `promote-test.sh` thành test của guard (mục 6).
- `.github/workflows/verify.yml` (job `record-stg`), `deploy/ci/verify/gitops.sh` (bước `release-set-before`, `release-set`), `deploy/ci/verify-collect.sh`, `verify-collect-test.sh`; `deploy/ci/record-stg.sh`, `release-set.sh`, `release-set-test.sh`: xoá (mục 6).
- `deploy/ci/gitops-check.sh`, `gitops-check-test.sh` (bỏ 1b, dạng cũ của 1c, luật tổ tiên, cây cũ; luật tác giả hẹp từ `sources.json`; ma trận từ `platforms`), `deploy/ci/gitops-policies/` (policy Kyverno CLI và `kyverno test`), `KYVERNO_CLI_IMAGE` của `Makefile` (mục 5, 6).

Repo khác:

- `svp-labs`: `README.md`, bài `dora/` (mục 1).
- `svp-frontend`: `.github/workflows/ci.yml` (bỏ bước guard, mục 2), `.github/workflows/images.yml` job `promote` (mục 6).
- `svp-infra`: `github/` (`allowed_actions`; chưa hiện thực, mục 3).
- `svp-gitops`: `argocd/apps/components.json` (khoá `platforms`, mục 5), `.github/workflows/check.yml` (`CHECKER_COMMIT`, job `diff-preview`, mục 6).

Chi tiết vận hành (lệnh, job, input) ở [`docs/ci-cd.md`](../ci-cd.md).

## Nguồn

- Kargo [releases](https://github.com/akuity/kargo/releases); Argo CD Image Updater [releases](https://github.com/argoproj-labs/argocd-image-updater/releases); Kyverno [Testing Policies (CLI)](https://kyverno.io/docs/testing-policies/); [argocd-diff-preview](https://github.com/dag-andersen/argocd-diff-preview); [Apache DevLake DORA](https://devlake.apache.org/docs/v0.19/DORA). Danh sách [N1]–[N10] đầy đủ ở [phụ lục](appendix/0037-mainpath-standard-tools.md#nguồn).

## Thông tin thêm

Phụ lục: [`appendix/0037-mainpath-standard-tools.md`](appendix/0037-mainpath-standard-tools.md) (dòng trạng thái gốc, số đo lúc quyết, bảng sáu nhóm phương án với trạng thái công cụ, nguồn).

### Chỉnh bởi

- §6: [0040](0040-sigstore-bundle-actions-attest.md): chữ ký, `vuln`, SBOM và provenance của image phát hành sang Sigstore bundle, provenance bằng `actions/attest`.
- §2: [0050](0050-bash-to-standard-tools.md): bỏ hẳn adapter `platform.sh`, không còn "đóng băng, xoá dần".
