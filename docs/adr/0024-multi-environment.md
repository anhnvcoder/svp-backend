# 0024. Nhiều môi trường dev, stg, prd: build một lần, mọi env chạy cùng digest đã ký, khác biệt chỉ ở overlay values mỗi env mà Argo CD chọn theo giá trị `env` của root Application; k3d đóng vai stg, prd chỉ render và kiểm tĩnh tới khi có cluster cloud

- Trạng thái: Chấp nhận
- Ngày: 2026-10-26
- Người quyết: người học (duyệt 2026-10-26, chọn (a) ở cả bảy dòng "Cần người học chọn")

## Bối cảnh và vấn đề

- **Yêu cầu:** build một lần, promote cùng digest; cấu hình chia gốc + `envs/{dev,stg,prd}`; stg tự đồng bộ sau merge, prd qua PR có người duyệt; khác biệt giữa env chỉ ở config (replica, resources, tên miền, cỡ database, secret); Terraform cùng module, mỗi env một state; dữ liệu prd không chép sang stg; chạy thử trên runner với k3d đóng vai stg. Trên cloud, stg nhỏ và prd dựng trong cùng buổi trên **hai cluster EKS riêng**; repo cấu hình `svp-gitops` tách sau (public, PR promote mở bằng GitHub App).
- **Hiện trạng lúc quyết** (`main` ở `744f108`): một cluster k3d `svp` mỗi lúc, hai đường cài không chạy chung ([ADR-0014](0014-kubernetes-local-stage4.md) §12): đường dev `make k8s-up` (image `dev-*` chưa ký, Kyverno Audit) và đường GitOps `make k8s-gitops-up` (image GHCR theo digest đã ký, Kyverno Enforce); values ở `deploy/k8s/values/`, digest do PR promote của [ADR-0015](0015-cicd-devsecops-stage5.md) §9 ghi; image không mang gì theo môi trường, nên một digest và một chữ ký (`images.yml@refs/heads/main`) đúng cho mọi env. Tên miền k3d nằm ở 11 giá trị trong 5 file; sáu release báo lỗi với `SENTRY_ENVIRONMENT: k3d`.
- **Ràng buộc:** một cluster lab mỗi lúc (máy 16 GB hay runner 4 vCPU, [ADR-0021](0021-deferred-verification-stage6b.md) §1); kịch bản của `verify.yml` giữ tên đã chốt; repo public nên overlay không chứa secret; đường dev (`install.sh`), `images.yml`, chart và values gốc không đổi khi dựng cấu trúc env.
- **Hiện trạng ngành** (đọc 2026-10-26): môi trường là thư mục trên một nhánh của repo cấu hình, mỗi env một nhánh là anti-pattern [N1], [N2]; Argo CD lấy values từ nguồn git thứ hai qua `ref: values` [N3]; Source Hydrator, GitOps Promoter, Kargo đang lên, chưa 1.0 [N5], [N6]; Terraform khuyên mỗi bản triển khai một cấu hình gốc với backend riêng, không dùng workspace để cách ly [N4]. Chi tiết hiện trạng và ràng buộc: phụ lục, mục "Bối cảnh".

## Yếu tố quyết định

- Một công cụ (Helm), một nhánh; khác biệt của env đọc được ở một chỗ và kiểm được bằng render, không phải quy ước.
- Mọi env chạy đúng image đã build và ký một lần; prd chỉ nhận bộ đã chạy cùng nhau ở stg, máy kiểm.
- Không thêm controller khi mỗi lúc chỉ có một cluster; đường dev và số đo của đường GitOps giữ nguyên.

## Phương án đã cân nhắc

- §1 khác biệt env: **A. values gốc + overlay Helm values mỗi env, Argo CD ghép bằng `valueFiles`**.
- §1 B. Kustomize trên manifest đã render: công cụ thứ hai, mất `helm template` làm phép kiểm chung.
- §1 C. một nhánh mỗi env: anti-pattern [N1].
- §1 D. bộ values đầy đủ mỗi env: chép 24 component, lệch dần.
- §1 E. Source Hydrator + GitOps Promoter hay Kargo: thêm controller, còn preview.
- §2 digest mỗi env: A. một digest ở gốc: prd không có cổng riêng.
- §2 **B. mỗi env một bộ file digest, promote prd là PR chép cả bộ của một bản stg đã chạy và kiểm**.
- §2 C. một digest, prd theo ref git khác: là 1C cho riêng digest.
- §2 D. Argo CD Image Updater: đã loại ở ADR-0015 §9.
- §3 chọn env: **A. giá trị `env` của root Application, chart app-of-apps chỉ thêm overlay có thật, sai thì lỗi render**.
- §3 B. luôn ghi đường overlay với `ignoreMissingValueFiles: true`: file sai tên bị bỏ qua lặng lẽ [N3].
- §3 C. ApplicationSet: thêm controller, thứ tự wave chỉ có qua Progressive Syncs Beta [N7].
- §3 D. một bản chart mỗi env.
- §4 dev: **A. dev là values gốc qua `make k8s-up` và compose, không `envs/dev/`**.
- §4 B. `envs/dev/` cùng một env Argo CD theo `main`: không có cluster thứ hai.
- §5 prd trước khi có cloud: **A. chỉ render và kiểm tĩnh**.
- §5 B. dựng prd trên k3d: không kiểm thêm gì so với A.
- §6 Terraform: **A. module chung, mỗi env một cấu hình gốc với backend riêng** [N4].
- §6 B. một cấu hình, workspace `stg`, `prd`: chung backend, chung quyền.

Bảng được/mất đầy đủ: phụ lục, mục "Các lựa chọn".

## Kết quả quyết định

Chọn 1A, 2B, 3A, 4A, 5A và 6A, vì giữ một công cụ và một nhánh, đặt khác biệt của env ở nơi đọc được và kiểm được bằng render, và không thêm controller nào khi mỗi lúc chỉ có một cluster. Mỗi § dưới giữ quyết định; chi tiết, danh sách việc và câu trả lời từng dòng "Cần người học chọn" ở phụ lục.

### 1. Ba môi trường

| Env | Chạy ở đâu | Image | Kyverno | Values | Cổng |
| --- | --- | --- | --- | --- | --- |
| dev | máy: compose (`make up`), k3d `make k8s-up` | build từ working tree, `dev-*` chưa ký | Audit | gốc | không |
| stg | k3d `make k8s-gitops-up` (máy, hay kịch bản `gitops` của runner); cloud: EKS stg | GHCR, digest đã ký | Enforce | gốc + `envs/stg/` | tự động sau build trên `main` (trước khi tách repo: PR promote của ADR-0015 §9) |
| prd | chỉ render tới khi có cloud; cloud: EKS prd | đúng bộ digest đã chạy cùng nhau ở stg | Enforce | gốc + `envs/prd/` | PR có người duyệt, cả bộ digest phải bằng một bản ghi triển khai stg (§8) |

- Cùng tên cluster `svp`, một cluster mỗi lúc: dev và stg luân phiên; kịch bản `gitops` của `verify.yml` là "k3d đóng vai stg", `dev-k3d` vẫn là dev; tên env không trùng tên kịch bản hay job nào của ADR-0021.
- stg và prd đều tự đồng bộ (`automated`, `selfHeal`): cổng là merge vào git, không phải nút Sync, nên git luôn là thứ đang chạy.

### 2. Cấu trúc thư mục (phần 3)

- Values gốc cho mọi env (đường dev chỉ đọc lớp này); `envs/<env>/<component>.yaml` chỉ chứa phần khác gốc, một file cho mỗi component có khác biệt, tên file là `name` của component trong `components.json`; component không có file thì chạy values gốc; comment đầu file (tiếng Anh) nói vì sao env khác gốc. Chart app-of-apps thấy thư mục env qua symlink `files/envs`.
- Thứ tự ghép: `values.yaml` của chart → file `values` của component (nếu có) → overlay của env; Helm thay cả danh sách, nên đổi một phần tử của list thì ghi lại cả list.
- Overlay **không được** có: (a) image ở bất kỳ dạng nào (mọi env chạy đúng image của gốc, build một lần); (b) `canary` và `httpRoute.name` của release `svp-service` (`canaryRoute` phản chiếu hai khoá đó cho mọi env); (c) secret hay giá trị bí mật (overlay chỉ nêu tên Secret). Quy tắc áp cho cả chart upstream khi cần.

### 3. Nội dung overlay ở phần 3

- **stg:** `env.SENTRY_ENVIRONMENT: stg` cho sáu release báo lỗi; không gì khác (tên miền giữ `svp.localhost`, replica và resources như gốc) để số đo RAM so được với các lượt trước.
- **prd (chỉ render):** `SENTRY_ENVIRONMENT: prd`; tên miền giữ chỗ dưới TLD dành riêng `.example` (RFC 2606): `svp.example`, `api.svp.example`, `s3.svp.example`, không ghi cổng, đủ 11 giá trị, render prd không được còn `svp.localhost`; sàn replica: mọi release trên đường request ít nhất 2 replica trải hai node với PDB `minAvailable: 1` (media-worker giữ KEDA tối thiểu 1, ngoài đường request). Resources, `hpa.maxReplicas`, `canaryLimits`, cỡ database và tên miền thật đặt theo số đo trên cloud, không đoán trước; overlay prd không có digest.

### 4. Argo CD chọn env (phần 3)

- Root `svp-root` mang `env` trong `spec.source.helm.valuesObject`, ghi bằng `jq --arg` nên luôn là chuỗi; `gitops.sh` luôn đặt `env: stg` (k3d chỉ đóng vai stg), không nhận biến môi trường cho env.
- Chart app-of-apps: `env` bắt buộc (`required`) và phải là một thư mục dưới `files/envs/`; mỗi file overlay phải ứng một component, overlay của `svp-service` không có `image`, `canary`, `httpRoute.name`; sai một điều thì `fail` lúc render (Argo CD báo `ComparisonError`, `make helm-check` báo cùng lỗi); component có overlay thì Application thêm `$values/…/envs/<env>/<name>.yaml` sau values gốc.
- Không ApplicationSet: một cluster, một env mỗi lúc.

### 5. Digest và phép kiểm bản phát hành

- Trước khi tách repo, digest chỉ ở values gốc và đó là digest của stg; PR promote của ADR-0015 §9 là cổng của stg; `values-check`, `rescan`, `measure-gitops` không đổi.
- Overlay không có digest (quy tắc (a)), nên không digest nào nằm ngoài tầm của rescan và Renovate không có gì để đụng trong thư mục env. Từ khi tách repo: §8.

### 6. Phép kiểm tĩnh (phần 3)

- `make helm-check` render root với `env=stg` và `env=prd` và mỗi chart với gốc cộng overlay từng env; render prd không chứa `svp.localhost`.
- Danh sách image của render mỗi env phải bằng đúng danh sách của render gốc: phép kiểm "build một lần, mọi env cùng image".
- Ca âm của chart app-of-apps (env lạ, overlay không có component, overlay có `image`) kiểm một lần lúc hiện thực; trên cluster, kịch bản `gitops` kiểm overlay áp thật (`valueFiles` của Application `gateway`, `SENTRY_ENVIRONMENT=stg` của pod).

### 7. Việc của phần 3

Tạo overlay `stg/` (sáu file) và `prd/` (sáu file release cùng `svp-cluster.yaml`, `svp-data.yaml`), symlink và template của chart app-of-apps, tham số env của `argocd_root_app`, `gitops.sh` in `env: stg`, phép kiểm của §6; AppProject và `renovate.json` không đổi trừ khi render chỉ ra là cần. Danh sách mười bước: phụ lục.

### 8. Phần 4: repo `svp-gitops`

- Values gốc thành `base/`, overlay thành `envs/`, cùng danh sách component và manifest Argo CD chuyển sang `svp-gitops`; chart của repo nằm đâu do [ADR-0025](0025-gitops-config-repo.md) chọn; cấu trúc env giữ nguyên.
- **Digest theo env:** `envs/<env>/images/<svc>.yaml`, mỗi file chỉ một khối `image`, tách khỏi file cấu hình env; `base/services/<svc>.yaml` không còn khối `image`; thứ tự ghép thêm lớp cuối `envs/<env>/images/<name>.yaml`; chart đòi đủ bảy file digest cho env nó dựng và từ chối khoá ngoài `image`; promote chỉ ghi `images/`, nên diff của PR promote chỉ là digest.
- **Đơn vị promote là cả bộ bảy digest:** smoke và k6 ở stg kiểm một tổ hợp service cùng chạy; stg vẫn nhận từng service, bản ghi chụp đúng bộ đang chạy.
- **stg tự động:** job `promote` ghi `envs/stg/images/` bằng token GitHub App, mở PR và bật auto-merge sau check (chữ ký, attestation `vuln` ≤ 48 giờ, render); CODEOWNERS không có dòng nào cho `envs/stg/`.
- **prd qua PR có người duyệt:** promote prd chép **cả bộ** bảy digest trong payload của một bản ghi triển khai stg sang `envs/prd/images/`, PR do App mở (người học không duyệt được PR của chính mình); không có promote prd theo service; CODEOWNERS sở hữu `envs/prd/` và mọi file chung, ruleset bật `require_code_owner_review`.
- **Bản ghi triển khai stg:** Deployment GitHub trên `svp-gitops`, environment `stg`, `ref` là commit Argo CD của stg đã đồng bộ, trạng thái `success`, payload là bộ bảy `repository@digest` đọc từ pod đang chạy và URL lượt kiểm; chỉ ghi sau khi phép kiểm trên stg qua, bởi chính phép kiểm từ ngoài cluster (job sau `gitops` của `verify.yml`, có environment `promote`; trên cloud là script kiểm stg người học chạy); ghi và đọc qua hàm `ci_*` của `platform.sh`.
- **Check của PR prd:** ngoài chữ ký và attestation như `values-check`, bộ bảy digest tại HEAD của PR phải **bằng đúng payload của một bản ghi** `success` có `ref` trên nhánh chính của `svp-gitops`; so cả bộ, không so từng digest; không khớp thì đỏ, kể cả khi mọi digest có trong lịch sử `envs/stg/`.
- **Rollback prd:** promote prd với bản ghi stg cũ hơn; bộ cũ hơn hai ngày phải rescan (`images.yml -f rescan=true -f values_ref=<ref>`) trước khi mở PR; sửa gấp một service ở prd vẫn đi qua stg và một lượt kiểm.
- Cơ chế chọn env giữ chart app-of-apps với `env`; chuyển kiểu brownfield, hai nguồn không chạy song song quá một buổi; trên GitLab Code Owners là gói Premium, gói Free cổng prd chỉ còn protected branch cộng quy ước.

### 9. Giai đoạn 7: stg và prd trên hai cluster EKS

- Stg nhỏ và prd dựng trong cùng buổi, xoá cả hai cuối buổi; mỗi cluster một Argo CD với `env` của nó, không cluster nào giữ credential của cluster kia.
- **Lớp nền tảng khác lớp env:** khác biệt k3d với EKS (dịch vụ managed, Load Balancer Controller, ACM, ExternalDNS) không vào `envs/`; quy tắc env giữ giữa stg và prd trên EKS. Overlay prd nhận tên miền thật và cỡ đo được từ k6 trên stg EKS; stg trên EKS cùng sàn replica với prd, resources nhỏ hơn.
- **Terraform (6A):** mỗi env một cấu hình gốc gọi module chung, backend S3 và khoá riêng, khác biệt ở `terraform.tfvars`; `plan` → review → `apply` stg trước prd, `destroy` cả hai; tách account AWS cho prd chỉ còn đổi backend và provider.
- **Secret mỗi env:** Secrets Manager theo đường `svp/<env>/…`, External Secrets của mỗi cluster chỉ đọc đường của env mình (Pod Identity); không có `.env` trên EKS.
- **Dữ liệu:** mỗi env database, bucket, cache, topic riêng; không chép hay restore dữ liệu prd sang stg, kể cả snapshot và bản "đã ẩn danh"; stg dùng dữ liệu tổng hợp; cần dữ liệu giống prd ở stg thì viết ADR riêng (che dữ liệu) trước. Migration expand/contract đi qua stg trước prd.

### Hệ quả

- Tốt: một chỗ để đọc env khác gốc ở đâu; "chỉ khác config" và "mọi env cùng image" thành phép kiểm tĩnh ở CI; đường dev và số đo của đường GitOps giữ nguyên; prd trên cloud nhận sẵn overlay đã render được và các quy tắc dữ liệu, secret, Terraform.
- Xấu: thay đổi ở gốc (values chung, version chart do Renovate nâng) tới mọi env cùng lúc, muốn thử trước thì đặt ở overlay stg rồi dời vào gốc; chart app-of-apps thêm logic và symlink, gỡ lỗi values phải `helm template` hai lớp; overlay prd chỉ đúng về hình, chưa đúng về cỡ tới khi có cloud; check prd phụ thuộc một bản ghi ngoài git và `verify.yml` thêm một job cầm secret; prd chỉ nhận cả bộ, không đường tắt theo digest; lệch chữ với lộ trình (không `envs/dev/`, không ApplicationSet).
- Xem lại khi: có cluster thứ hai chạy cùng lúc (xét env dev của Argo CD); Source Hydrator lên GA trong bản Argo CD ghim hay GitOps Promoter tới 1.0 (xét 1E); overlay một env dài gần bằng gốc; một Grafana xem nhiều env (thêm `deployment.environment.name` vào resource của telemetry).
- ADR cũ được chỉnh bởi ADR này: [ADR-0014](0014-kubernetes-local-stage4.md) §12, §13, [ADR-0015](0015-cicd-devsecops-stage5.md) §7–§10, [ADR-0021](0021-deferred-verification-stage6b.md); nội dung chỉnh ở phụ lục, mục "Hệ quả".

## Xác nhận

- `make helm-check` và phép kiểm image mỗi env đạt trên máy (2026-10-26), ca âm của chart app-of-apps fail đúng message; render stg chỉ khác render GitOps cũ ở sáu dòng `SENTRY_ENVIRONMENT`.
- Kịch bản `gitops` trên runner: overlay stg áp thật (Application `gateway` có overlay trong `valueFiles`, pod có `SENTRY_ENVIRONMENT=stg`, event GlitchTip mang environment `stg`).
- Sau tách repo: PR bot chỉ đổi `envs/stg/` tự merge sau `gitops-ok`; bản ghi stg ghi được và check PR prd nhận bộ khớp, đỏ với bộ sửa tay hay bộ chỉ có trong lịch sử `envs/stg/`.
- Không đạt: PR của người học sửa file chung không bị chặn (tác giả kiêm Code Owner duy nhất); chưa kiểm: hai replica của service trên EKS, ca bộ ghép từ hai bản ghi, backend Terraform tách quyền theo env. Bảng kiểm chứng và id lượt chạy: phụ lục, mục "Kiểm chứng sau".

## Hiện thực ở

- Overlay và chart app-of-apps: repo `svp-gitops` (`base/`, `envs/stg/`, `envs/prd/`, `envs/<env>/images/`, `envs/<env>/charts.yaml`, `argocd/apps/`, `CODEOWNERS`); ruleset ở `github/rulesets.tf` của `svp-infra`.
- Chọn env và dựng: `argocd_root_app` của `deploy/k8s/lib.sh`, `deploy/k8s/gitops.sh`; phép kiểm tĩnh: `deploy/ci/gitops-check.sh` (`make helm-check` chạy `--worktree`); kiểm trên cluster: `deploy/k8s/drills/gitops/` (`make drill-k8s-gitops`, bước của job `gitops` ở `.github/workflows/verify.yml`).
- Promote và bản ghi: `deploy/ci/promote.sh`, `deploy/ci/release-set.sh`, `deploy/ci/record-stg.sh`, `deploy/ci/promote-prd.sh`, bước 1b của `deploy/ci/gitops-check.sh`, `ci_deployment_record`, `ci_deployment_list` của `deploy/ci/platform.sh` (chi tiết ở [ADR-0025](0025-gitops-config-repo.md)). Danh sách theo phần và ngày: phụ lục, mục "Hiện thực ở".

## Nguồn

- [N1] Codefresh, "Stop Using Branches for Deploying to Different GitOps Environments": <https://codefresh.io/about-gitops/branches-gitops-environments/>
- [N3] Argo CD, "Multiple Sources for an Application": <https://argo-cd.readthedocs.io/en/stable/user-guide/multiple_sources/>
- [N4] HashiCorp, Terraform "Manage Workspaces": <https://developer.hashicorp.com/terraform/cli/workspaces>
- [N7] Argo CD, "Progressive Syncs": <https://argo-cd.readthedocs.io/en/release-3.5/operator-manual/applicationset/Progressive-Syncs/>
- Danh sách đầy đủ [N1]–[N7] kèm ghi chú: phụ lục, mục "Nguồn".

## Thông tin thêm

Phụ lục: [`appendix/0024-multi-environment.md`](appendix/0024-multi-environment.md) (tiêu đề và trạng thái gốc, bối cảnh đầy đủ, bảng lựa chọn, toàn văn các §, "Cần người học chọn", "Kiểm chứng sau", hệ quả, hiện thực ở, nguồn).

### Chỉnh bởi

- §9: [0026](0026-secrets-gitops.md): Secret mỗi env là ExternalSecret của từng namespace qua store riêng; ở prd mỗi store assume một role chỉ đọc entry namespace đó cần.
- §8: [0025](0025-gitops-config-repo.md): payload bản ghi stg và check prd thêm `charts`, tên dành riêng `charts.yaml` trong thư mục env, bản cài Argo CD ở `argocd/` của `svp-gitops`.
- §8: [0028](0028-dora-metrics.md): bản ghi stg ghi trạng thái `success` với `auto_inactive: false`; deployment của GitLab không có payload.
- §9: [0034](0034-aws-stage7.md): nơi và tên thư mục Terraform (repo `svp-infra`, `aws/envs/<env>/`, `aws/modules/`); lớp nền tảng là lớp values `platforms/<platform>/` với giá trị `cluster.*`.
- §8: [0037](0037-mainpath-standard-tools.md): bị thay từ 2026-11-01: promote prd chép bộ của một bản ghi stg, bản ghi stg, check prd so bản ghi.
