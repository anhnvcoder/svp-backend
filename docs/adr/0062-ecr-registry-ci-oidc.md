# 0062. Image của stg, prd ở ECR private của từng account env: CI sao chép cùng digest kèm chữ ký, attestation từ GHCR bằng role OIDC hẹp theo repo và mục đích; image bên thứ ba qua pull-through cache được làm nóng theo tag, Kyverno đổi tham chiếu lúc tạo pod; Inspector quét repo cache

- Trạng thái: Chấp nhận
- Ngày: 2026-11-13
- Người quyết: người học (duyệt plan R4: registry ở mỗi account env, CI có credential AWS, chuyển hướng bằng Kyverno), AI đề xuất thiết kế
  và giá trị theo tài liệu AWS, GitHub, Kyverno

## Bối cảnh và vấn đề

- Node eks kéo image phát hành ẩn danh từ GHCR theo digest qua NAT ([0034](0034-aws-stage7.md) Câu 10A); Kyverno xác minh chữ ký, `vuln`,
  provenance ở GHCR ([0040](0040-sigstore-bundle-actions-attest.md)); image bên thứ ba đi thẳng từ năm registry upstream; CI không có
  credential AWS (0034 §2). Rà theo FSBP thiếu: quét image trong account (ECR.1, Inspector.2); admission phụ thuộc GHCR; Docker Hub giới hạn lượt kéo.
- Số đo 30 ngày tới 2026-11-13 (phụ lục §11): 285 digest mới vào `envs/stg/images/` của `svp-gitops`, 28 vào prd; 38 digest bên thứ ba ghim.
- Tài liệu ràng buộc thiết kế: kéo lần đầu theo digest qua pull-through cache lỗi [N9]; repo đổi tên sau 2026-07-15 nhận `sub` OIDC dạng id
  bất biến [N12]; Kyverno deprecate `ClusterPolicy` ở v1.19 [N15]; một báo cáo ECR từ chối referrer chép bằng `oras cp -r` [N10].
- Ràng buộc: repo public, AI không chạy lệnh chạm account, buổi tối đa 4 giờ, stg như prd ([0055](0055-environment-matrix.md)), SCP, RCP của [0059](0059-org-structure-guardrails.md).

## Yếu tố quyết định

- Pod trên eks chỉ kéo từ registry trong account của nó; image vào prd chỉ qua `promote-prd` có người duyệt.
- Admission kiểm chữ ký, `vuln`, provenance ngay ở registry pod kéo, cùng identity keyless như GHCR; build một lần, không ký lại.
- Credential AWS của CI tối thiểu: mỗi role đúng một `sub`, một repo nguồn, một mục đích, phiên 1 giờ; `svp-infra` không có.
- Control FSBP `ECR.*`, `Inspector.*` đạt hay chấp nhận có lý do; chi phí có nguồn, cộng vào bảng tổng ở phụ lục [0063](0063-managed-observability.md).

## Phương án đã cân nhắc

Trạng thái ngành, được, mất, nguồn: [phụ lục](appendix/0062-ecr-registry-ci-oidc.md#phương-án). In đậm là lựa chọn.

- Nơi đặt: **ECR của mỗi account env**; ECR ở account Shared Services (một bản, một lượt quét; thêm account, policy chéo account); giữ GHCR + cache GHCR.
- Đưa bản phát hành vào ECR: **oras chép index và từng referrer**; build lại và push ECR (trái build một lần); replication stg → prd (mọi bản
  vào prd, không qua duyệt); ký lại bằng ký managed của ECR (mất identity keyless của nguồn).
- Image bên thứ ba: **pull-through cache + Kyverno đổi tham chiếu + làm nóng theo tag**; sửa registry trong values từng chart (~15 chart); mirror
  của containerd trên node (credential ECR không đi theo mirror); giữ kéo upstream qua NAT.
- Policy đổi tham chiếu: **`MutatingPolicy` (CEL)**; `ClusterPolicy` mutate (deprecate ở v1.19, dự kiến bỏ ở v1.20 [N15]).
- Giữ bản phát hành: **không lifecycle**; giữ N bản mới nhất (xoá được bản đang chạy hay đích rollback); archive (không kéo được khi đang archive [N3]).
- Quét: **Inspector liên tục trên repo cache**; Inspector mọi repo (quét lại bản đã quét ở CI, ~$51 mỗi tháng ở nhịp đo); basic scanning (không Inspector.2).
- Credential CI: **role OIDC**; access key IAM user (SCP `svp-deny-iam-users` cấm); không credential (giữ GHCR).

## Kết quả quyết định

Chọn các phương án in đậm: image chạy trên eks nằm trong account, có chữ ký và attestation đi theo, credential CI hẹp tới từng repo và mục đích.
Cái giá: credential AWS trong CI, lưu trữ tăng theo số bản phát hành, một bước làm nóng cache mỗi buổi. Giá trị đủ từng mục: phụ lục, cùng số §.

### 1. Nơi đặt registry

**Registry ECR của env**: registry private của `svp-stg`, `svp-prd` ở `ap-southeast-1`, host `<account>.dkr.ecr.ap-southeast-1.amazonaws.com` [N27],
module `registry` gọi từ root `aws/accounts/<env>` (sống qua destroy). AWS SRA không nêu registry trong account Shared Services [N28]; registry
chung tiết kiệm một bản lưu, một lượt quét mỗi digest, đổi lại thêm account, policy và key chéo account, image chưa duyệt cạnh image prd.

### 2. Repo phát hành

- **Repo phát hành** mã hoá bằng key `alias/svp-<env>-ecr` (xoay hằng năm; ECR dùng key qua grant [N5]); tag `IMMUTABLE`: ECR.2 chỉ nhận đúng giá trị
  này [N24], referrer đi qua referrers API nên không cần tag dự phòng [N1]. Image chép theo digest, không tag: digest trong git là danh tính.
- Không lifecycle policy: mọi bản phát hành ở đây không tag, nên rule `untagged` hay `any` nào cũng chọn được chúng; rule không chọn gì chỉ để
  control xanh là cấu hình rỗng. ECR.3 FAILED ở repo phát hành, chấp nhận. GC theo tập đang dùng là việc sau; khi xoá, referrer tự hết hạn theo
  subject trong 24 giờ và manifest con không bị xoá khi index còn [N3].

### 3. Sao chép phát hành

- ECR nhận OCI 1.1: referrers API, manifest có `subject` [N1]; `ListImageReferrers` trả cả Sigstore bundle [N2]; cosign đọc bundle trên ECR qua
  referrers API [N20]. GHCR không có referrers API: oras đọc referrer của GHCR qua tag dự phòng [N21], [N22].
- `ecr-copy.sh copy` đồng bộ một digest, chạy lại an toàn, không xoá: (i) chép index (kéo theo mọi manifest con [N21]) nếu đích chưa có; (ii) với
  từng subject (index và mọi manifest con, **Đồ thị phát hành** ở phụ lục) chép referrer nguồn có mà đích thiếu, trừ `vuln` khi đích đã có một;
  (iii) verify chữ ký, SBOM, provenance, `vuln` trên bản ECR với identity của nguồn. oras ghim, nguồn `--from-distribution-spec v1.1-referrers-tag`,
  đích `--to-distribution-spec v1.1-referrers-api` (không ghi tag dự phòng vào repo `IMMUTABLE`); không `oras cp -r`: lỗi phải hiện đúng referrer,
  và một báo cáo ECR từ chối referrer chép bằng `-r` [N10].
- Ba chỗ chạy, mỗi chỗ một role (§5): (a) job `ecr-copy` sau `sign` trên `main` của mỗi repo code → ECR stg; (b) `promote-prd` → ECR prd mọi image
  của `envs/stg/images/` ở `stg_ref`, chép và verify hết mới mở PR, một image lỗi thì không mở; (c) job `rescan` (§4). ECR prd chỉ nhận index qua (b).

### 4. Digest phát hành và rescan ECR

- **Digest phát hành**: mỗi leg `ecr-copy` tải artifact `ecr-<image>` chỉ sau verify đạt; promote stg đọc `ecr-*` thay `release-*`: image lỗi
  không được promote, image khác vẫn đi; chạy lại leg lỗi rồi `promote` thì đi tiếp.
- **Tập rescan ECR**: rescan đọc `envs/<e>/images/` của `svp-gitops` ở `main`, ở mọi PR promote đang mở (cả `bot/promote-prd`) và ở `values_ref`;
  digest dưới `envs/<e>/` được làm mới ở ECR của env `<e>` bằng role rescan của account đó: `refresh` bỏ qua khi ECR không có index; có thì chép
  `vuln` mới, gỡ `vuln` khác bằng `BatchDeleteImage` [N3], chép referrer thiếu, verify, còn đúng một `vuln` (như 0040 §3). Vì vậy PR promote chờ
  quá 72 giờ vẫn được làm mới hằng ngày; rollback tới digest cũ: dispatch rescan với `values_ref` ghi digest đó dưới `envs/<env>/` (ca: phụ lục).
- **Rescan digest chưa promote** (bản ECR bị bỏ lại tới khi `vuln` quá hạn): dispatch rescan ở repo phát hành image với `digest`, `image`, `env`:
  `rescan.sh run` trên GHCR, `refresh` sang ECR của `env` bằng role rescan. `stg` (leg (a) lỗi): thêm `copy`, chạy lại leg và `promote`. `prd`
  ((b) đã chép rồi lỗi ở image khác, chưa mở PR): chạy lại `promote-prd`. Chỉ role rescan có `BatchDeleteImage`: role release,
  promote chạy ở mọi bản phát hành, xoá nhầm chữ ký thì pod bị từ chối; `vuln` đích quá hạn thì `copy` lỗi, nêu lệnh rescan, không tự gỡ.

### 5. Role CI ECR

- Mỗi account một IAM OIDC provider `token.actions.githubusercontent.com`, audience `sts.amazonaws.com` [N11], không thumbprint (IAM xác minh
  GitHub bằng CA tin cậy [N13]). Năm role theo bảng **Role CI ECR**, phiên 1 giờ (mức thấp nhất của IAM [N13]).
- **`sub` dạng bất biến**: repo tạo, đổi tên hay chuyển sau 2026-07-15 nhận `repo:<owner>@<owner-id>/<repo>@<repo-id>:...` [N11], [N12];
  `svp-backend`, `svp-frontend` đổi tên 2026-10-31. Trust `StringEquals` đúng một chuỗi: `repo:anhnvcoder@<owner-id>/svp-backend@<repo-id>:ref:refs/heads/main`,
  `...:environment:promote-prd`, `...:environment:ecr-rescan` (job có environment nhận dạng environment thay ref [N11]). Id là số công khai của
  API GitHub, ghi trong `locals` của root; người học đọc `use_immutable_subject` của hai repo trước khi tạo role (phụ lục §5).
- **Quyền đẩy ECR** không có quyền KMS: ECR gọi `GenerateDataKey`, `Decrypt` qua grant, người đẩy, kéo không cần quyền trên key [N5];
  `ListImageReferrers` cần `ecr:BatchGetImage` [N2].
- Tách theo repo nguồn: frontend không ghi được image backend và ngược lại. Tách theo mục đích: stg nhận bản từ `main`, prd chỉ từ `promote-prd`
  (có người duyệt), rescan riêng vì chỉ nó xoá. Rủi ro còn lại (job nào trên `main` khai `ecr-rescan` cũng nhận role rescan): threat model.
- `aws-actions/configure-aws-credentials` ghim SHA (v6.3.0 lúc quyết [N14]), `mask-aws-account-id: true`; đăng nhập bằng `aws ecr get-login-password`
  vào `DOCKER_CONFIG` riêng của job. Ngoại lệ có ADR của luật "CI không credential AWS" (0034 §2): chỉ hai repo code; `svp-infra` vẫn không.

### 6. Pull-through cache

- Năm rule: `ghcr` → `ghcr.io`, `docker-hub` → `registry-1.docker.io`, `quay` → `quay.io`, `k8s` → `registry.k8s.io`, `ecr-public` →
  `public.ecr.aws`; GHCR, Docker Hub bắt buộc credential [N6]. Upstream ngoài tầm thì ECR trả bản đã cache [N6].
- Secret `ecr-pullthroughcache/ghcr`, `ecr-pullthroughcache/docker-hub` (khoá `username`, `accessToken`) mã hoá bằng key `aws/secretsmanager`:
  ECR không nhận CMK cho secret này [N6]; ECR đọc nó bằng service-linked role `AWSServiceRoleForECRPullThroughCache` [N6]. GHCR: PAT (classic),
  chỉ `read:packages` (GitHub Packages chỉ nhận PAT classic [N26]); Docker Hub: PAT "Repo Public Read-only" [N26]; hạn 90 ngày; người học tạo,
  ghi giá trị và xoay trước hạn theo runbook.
- Repository creation template mỗi tiền tố (`PULL_THROUGH_CACHE`): KMS cùng key; tag `MUTABLE` (AWS khuyên cho cache, tag bất biến chặn ECR
  cập nhật tag [N6], [N7]); lifecycle xoá image không được kéo 30 ngày (`sinceImagePulled` + `expire`, `tagStatus: any` [N3]; ECR nhận cặp
  này từ 2026-11-11 [N31]): upstream còn bản gốc. Template có KMS cần role tạo repo `svp-<env>-ecr-template` (trust `ecr.amazonaws.com`) [N7].
- Role node (MNG `system`, node Karpenter) thêm `ecr:BatchImportUpstreamImage`, `ecr:CreateRepository` trên `repository/<tiền tố>/*` [N6]; kéo giữ
  `AmazonEC2ContainerRegistryReadOnly` có sẵn.

### 7. Làm nóng cache

Kéo lần đầu theo digest một image chưa cache lỗi (`manifest unknown`, roadmap ECR [N9]); mọi image của cluster ghim digest. Mỗi buổi, sau
`aws/envs/<env>`, trước bootstrap Argo CD, `aws/scripts/ecr-warm.sh` kéo **theo tag** qua ECR mọi image bên thứ ba ghim trong bản render eks
của env (danh sách do `deploy/ci/image-list.sh` in), nhập index cùng mọi manifest con [N6], rồi kiểm digest ghim có ở ECR; không có (tag upstream
đã dời, cache trả bản cũ trong 24 giờ [N6]) thì lỗi, nêu image. Chạy lại khi PR đổi digest bên thứ ba merge giữa buổi. Lệnh kéo chốt bằng phép thử.

### 8. Chuyển hướng image

- `svp-registry-mirror` là `MutatingPolicy` `policies.kyverno.io/v1` như IVP đang chạy: `ClusterPolicy` deprecate ở v1.19, dự kiến bỏ ở v1.20 [N15];
  CEL, `matchConstraints` CREATE `pods`, loại namespace `kyverno`; `failurePolicy: Ignore`: bài AWS để người dùng chọn, Kyverno chết thì pod kéo
  upstream qua NAT [N8]; namespace `svp` vẫn bị IVP `Fail` chặn. Kyverno không nhận request của `kube-system` (cấu hình webhook của nó): Karpenter,
  Load Balancer Controller kéo upstream; pod tạo trước policy kéo upstream tới lần tạo lại.
- Đổi đúng phần trước tên repo theo **Ánh xạ registry**, giữ tag, digest. Chuẩn hoá Docker Hub: tham chiếu không host (đoạn đầu không có `.`, `:`,
  không là `localhost`), `index.docker.io/`, `registry-1.docker.io/` là `docker.io/`; tên một đoạn thêm `library/` (cache đòi [N6]). Hàm `image()`
  của Kyverno trả `index.docker.io` [N16]: test Kyverno CLI chốt mọi dạng. Container thêm bằng `kubectl debug` (UPDATE) không bị đổi.

### 9. Ảnh phát hành trên eks

**Ảnh phát hành trên eks** dùng `credentials.providers: [amazon]` [N17]. Kyverno v1.19.1 dựng với `aws-sdk-go-v2/config` v1.32.31 và
`ecr-login` v0.12.0 [N18], mới hơn bản tối thiểu có Pod Identity [N18]; tài liệu Kyverno chỉ nêu IRSA [N17], nên Pod Identity kiểm ở buổi stg.
Role của `kyverno/kyverno-admission-controller`: `ecr:GetAuthorizationToken` (resource `*`), `ecr:BatchGetImage`, `ecr:GetDownloadUrlForLayer` trên
ARN **Repo phát hành**, không KMS [N5]. Kyverno tìm bundle bằng `remote.Referrers` [N19], nên ở ECR đi qua referrers API.

### 10. Quét ECR

- Inspector qua delegated admin `svp-security`, bật ECR cho mọi account thành viên cả `svp-security` (Inspector.2 xét admin và mọi thành viên [N24]);
  registry `ENHANCED`, `CONTINUOUS_SCAN`, filter `<tiền tố>/*` của năm tiền tố §6 [N23]; finding vào Security Hub như GuardDuty; quét lại mặc định.
- Repo phát hành không vào filter: trivy, grype chặn trước push, rescan hằng ngày, admission đòi `vuln` dưới 72 giờ (0040); Inspector quét lại
  ~$0,18 mỗi digest mỗi account. ECR.1 FAILED ở repo phát hành, chấp nhận.
- Chỉ ECR: node thay mỗi buổi, AMI EKS ghim version, vá bằng nâng AMI ([0056](0056-eks-platform-ha.md)), GuardDuty Runtime Monitoring theo dõi node
  ([0060](0060-org-detection-logging.md)); lab không có Lambda. Inspector.1, .3, .4 FAILED, chấp nhận.

### 11. Chi phí registry

Theo trang giá, Price List (đọc 2026-11-13; bảng ở phụ lục). Lúc không buổi: hai key KMS $2, bốn secret $1,6, cache ~$1 mỗi tháng; repo phát
hành stg tăng ~14,5 GB mỗi tháng ở nhịp đo (+$1,45 mỗi tháng sau mỗi tháng), prd ~1,5 GB. Mỗi buổi: Inspector ~$0,18 mỗi digest bên thứ ba mới
mỗi account (buổi đầu tối đa 38 digest, ~$6,8); kéo trong region không tính phí; cache không phí riêng [N8].

### 12. Khác biệt stg/prd, hợp đồng cluster và ADR cũ

Giống ở hai env: registry, repo, cache, template, quét, Kyverno. Khác theo thiết kế: bộ role của **Role CI ECR**. `ecrRegistry` của **Hợp đồng
cluster** khớp dạng host của tài liệu ECR [N27]. ADR cũ chỉnh: 0034 Câu 10, §2; 0015; 0040 §3; 0041; 0055 §2, §3.

### Hệ quả

- Tốt: pod eks không phụ thuộc GHCR, Docker Hub lúc kéo; admission đọc chữ ký, attestation ngay ở ECR; prd nhận image chỉ qua duyệt; image bên thứ
  ba được quét, có finding ở Security Hub; credential CI ngắn hạn, mỗi role một chuỗi `sub`.
- Xấu: CI có credential AWS; hai bản lưu, tăng không giới hạn tới khi có GC; làm nóng cache mỗi buổi; PAT xoay tay; tám control FSBP
  chấp nhận FAILED (phụ lục); Kyverno thêm webhook mutate; Inspector tính mỗi digest bên thứ ba mới ở cả hai account.
- Xem lại khi: ECR kéo được theo digest chưa cache [N9] (bỏ §7); repo phát hành stg vượt 30 GB (GC theo tập đang dùng); ECR từ chối một
  referrer; Inspector một buổi vượt ~$9 (§11); cần account registry chung (§1).

## Xác nhận

- Lúc quyết chưa hiện thực. Kiểm tĩnh: test mocked module `registry`, `eks` của `svp-infra`; test Kyverno CLI của `svp-policy` (đổi tham chiếu, bốn
  dạng Docker Hub, `releaseRegistry`); test của `ecr-copy.sh`, `rescan.sh`, `image-list.sh`, `ecr-warm.sh`; `make check`, `helm-check`, `docs-check`.
- **Phép thử trước khi dựng** (người học, account sandbox, chưa chạy): `oras` chép một bản phát hành cùng referrer GHCR → ECR, `cosign verify`,
  `verify-attestation` trên ECR; qua cache, kéo theo digest một image chưa cache (mong lỗi), theo tag rồi theo digest (mong được); ECR nhận
  template cache có rule `sinceImagePulled` + `expire` (bị từ chối tới 2026-11-11 [N31]).
- Buổi stg, prd: pod kéo từ ECR, IVP nhận (Kyverno đọc ECR bằng Pod Identity), thời gian admission; lượt `main` đầu chép, verify; rescan làm mới `vuln`.

## Hiện thực ở

- `svp-infra`: `aws/modules/registry/` (§1, §2, §5, §6, §10), `aws/accounts/<env>/` (§1, §5), `aws/org/`, `aws/security/inspector.tf` (§10),
  `aws/modules/eks/` (§6, §9), `aws/envs/<env>/` (§12), `aws/scripts/ecr-warm.sh` (§7), `github/` (§5).
- Repo này: `deploy/ci/ecr-copy.sh`, `rescan.sh`, `.github/workflows/images.yml` (§3, §4, §5); `deploy/ci/image-list.sh` (§7); `deploy/helm/svp-policy/`
  (§8, §9). `svp-frontend`: `.github/workflows/images.yml` (§3, §4). `svp-gitops`: `platforms/eks/svp-policy.values.tpl` (§8, §9).

## Nguồn

Đọc 2026-11-13; tên đủ, trích dẫn và [N4], [N22], [N29], [N30] ở phụ lục.

- ECR: [N1] <https://aws.amazon.com/about-aws/whats-new/2024/06/amazon-ecr-oci-image-distribution-version-1-1>, [N2] <https://docs.aws.amazon.com/AmazonECR/latest/APIReference/API_ListImageReferrers.html>,
  [N3] <https://docs.aws.amazon.com/AmazonECR/latest/userguide/LifecyclePolicies.html>, [N5] <https://docs.aws.amazon.com/AmazonECR/latest/userguide/encryption-at-rest.html>,
  [N6] <https://docs.aws.amazon.com/AmazonECR/latest/userguide/pull-through-cache.html>, [N27] <https://docs.aws.amazon.com/AmazonECR/latest/userguide/Registries.html>,
  [N7] <https://docs.aws.amazon.com/AmazonECR/latest/userguide/repository-creation-templates.html>, [N9] <https://github.com/aws/containers-roadmap/issues/2837>,
  [N10] <https://github.com/aws/containers-roadmap/issues/2783>, [N31] <https://github.com/aws/containers-roadmap/issues/2728>, [N8] <https://aws.amazon.com/blogs/containers/announcing-pull-through-cache-for-registry-k8s-io-in-amazon-elastic-container-registry/>
- GitHub, IAM: [N11] <https://docs.github.com/en/actions/reference/security/oidc>, [N14] <https://github.com/aws-actions/configure-aws-credentials>,
  [N26] <https://docs.github.com/en/packages/working-with-a-github-packages-registry/working-with-the-container-registry>,
  [N12] <https://github.blog/changelog/2026-04-23-immutable-subject-claims-for-github-actions-oidc-tokens>, [N13] <https://docs.aws.amazon.com/IAM/latest/UserGuide/id_roles_providers_create_oidc_verify-thumbprint.html>
- Kyverno, Sigstore, ORAS: [N15] <https://kyverno.io/blog/2026/08/20/announcing-kyverno-release-1.19/>, [N16] <https://kyverno.io/docs/policy-types/cel-libraries/>, [N17] <https://kyverno.io/docs/policy-types/image-validating-policy/>,
  [N18] <https://raw.githubusercontent.com/kyverno/kyverno/v1.19.1/go.mod>, [N19] <https://github.com/kyverno/kyverno/issues/16664>, [N20] <https://docs.sigstore.dev/cosign/system_config/registry_support/>, [N21] <https://oras.land/docs/commands/oras_cp>
- Quét, control, giá, SRA: [N23] <https://docs.aws.amazon.com/inspector/latest/user/scanning-ecr.html>, [N25] <https://aws.amazon.com/inspector/pricing/>,
  [N24] <https://docs.aws.amazon.com/securityhub/latest/userguide/ecr-controls.html>, [N28] <https://docs.aws.amazon.com/prescriptive-guidance/latest/security-reference-architecture/shared-services.html>

## Thông tin thêm

Phụ lục: [`appendix/0062-ecr-registry-ci-oidc.md`](appendix/0062-ecr-registry-ci-oidc.md) (phương án, giá trị đủ từng §, control, luồng, chi phí).
