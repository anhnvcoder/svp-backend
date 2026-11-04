# 0026. Secret của đường GitOps (stg, prd) do External Secrets Operator dựng từ một kho nguồn ngoài git: ở stg trên k3d là namespace nguồn `svp-secrets` đọc qua provider `kubernetes`, ở prd là AWS Secrets Manager hay GCP Secret Manager; đường dev giữ `make k8s-secrets` từ `.env`

- Trạng thái: Chấp nhận
- Ngày: 2026-10-28
- Người quyết: người học (duyệt 2026-10-28, chọn (a) ở cả năm dòng "Cần người học chọn")

## Bối cảnh và vấn đề

- **Yêu cầu:** cấu hình của đường GitOps chuyển sang repo **public** `svp-gitops` ([ADR-0025](0025-gitops-config-repo.md)); Secret phải tới cluster của stg (k3d trên runner, sau đó EKS, GKE) và prd mà không có giá trị, khoá hay file khoá nào trong repo nào. [ADR-0024](0024-multi-environment.md) §9 đã ghi hướng cloud: Secrets Manager theo đường `svp/<env>/…`, External Secrets của mỗi cluster chỉ đọc đường của env mình (Pod Identity); threat model SEC-3 ghi cùng biện pháp.
- **Hiện trạng lúc quyết** ([ADR-0014](0014-kubernetes-local-stage4.md) §8): không Secret nào trong git; `deploy/k8s/secrets.sh` (`make k8s-secrets`) đọc `.env` rồi tạo 25 Secret, `deploy/k8s/glitchtip-init.sh` tạo thêm 3; cả đường dev và đường GitOps dùng hai script đó, nên Argo CD không biết cluster cần Secret nào và đổi `.env` trên cluster GitOps là bước tay.
- **Ràng buộc:** không secret trong repo nào, job của `verify.yml` không secret, không environment ([ADR-0021](0021-deferred-verification-stage6b.md); ngoại lệ duy nhất là job ghi bản ghi stg); cluster của kịch bản `gitops` mới mỗi lượt, `.env` sinh trên runner; đường GitOps trên runner đã vượt RAM nghỉ (b) của ADR-0014 §2 (7 510 MiB so với 6 656 MiB, [ADR-0017](0017-gitops-capacity-media-worker-max2.md)); PSA `restricted`, NetworkPolicy chặn hai chiều, image ghim `@sha256:`; công cụ mới qua bảng trạng thái ngành, người học chọn.

## Yếu tố quyết định

- Repo không chứa giá trị lẫn ciphertext; runner không cần secret của CI.
- Cùng một mẫu cho stg lab và cloud, chỉ kho nguồn đổi; Argo CD khuyên cách quản secret ở cluster đích [N1].
- Ít pod nhất trên đường đã vượt RAM; quyền đọc kho chia được theo namespace.

## Phương án đã cân nhắc

- §1 công cụ: **A. External Secrets Operator (ESO)**: hiện hành (trạng thái ngành đọc 2026-10-28), CNCF Sandbox, repo chỉ chứa tham chiếu.
- §1 B. SOPS + age qua plugin Argo CD: ciphertext trong repo, khoá là secret của CI, plaintext trong cache Redis của Argo CD [N1].
- §1 C. Sealed Secrets: khoá gắn từng cluster mới mỗi lượt, cloud vẫn phải chuyển sang ESO.
- §1 D. Vault/OpenBao + VSO: nặng RAM nhất, secret zero, VSO là BSL.
- §1 E. Argo CD Vault Plugin: legacy.
- §1 F. Secrets Store CSI Driver: DaemonSet `privileged`, không đạt PSA `restricted`.
- §2 kho nguồn stg lab: **a. provider `kubernetes` đọc namespace `svp-secrets`** [N5].
- §2 b. moto giả lập Secrets Manager: thêm pod, credential giả, không kiểm IAM thật.
- §2 c. OpenBao dev.
- §2 d. provider `fake`: giá trị trong git.
- §2 e. LocalStack: cần auth token, trái ADR-0021.
- §3 phạm vi: **a. ESO chỉ trên đường GitOps, dev giữ `make k8s-secrets`**.
- §3 b. ESO cả đường dev: thêm RAM trên máy 16 GB.

**Ciphertext trong repo public tính là secret trong repo:** thứ đã vào kho public không xoá được, mọi giá trị cũ chỉ còn được bảo vệ bằng một khoá mãi mãi [N18], và khoá đó phải tới mỗi cluster mới bằng secret của CI; nên "không secret, không khoá trong repo nào" đọc là cũng không ciphertext.

Bảng đầy đủ (RAM ước lượng, trên runner, lên cloud, hợp chốt repo public): phụ lục, mục "Các lựa chọn".

## Kết quả quyết định

Chọn 1A, 2a, 3a, vì repo không chứa giá trị lẫn ciphertext, cloud dùng cùng mẫu chỉ đổi store, job `gitops` vẫn không secret, và đường dev cùng máy 16 GB không đổi. Mỗi § dưới giữ quyết định; lý do từng cấu hình, bảng Secret đầy đủ và toàn văn ở phụ lục.

### 1. Công cụ: External Secrets Operator

- Chart `external-secrets` của nhà phát triển, ghim version (lúc quyết 2.14.0 [N2]) và image `@sha256:`; Renovate nâng theo `minimumReleaseAge`.
- Chỉ kind namespaced: tắt `processClusterStore`, `processClusterExternalSecret`, `processPushSecret`, `processClusterPushSecret`, `processClusterGenerator` và CRD tương ứng; không `ClusterSecretStore`.
- `rbac.aggregateToView/Edit/Admin: false`: ai tạo được ExternalSecret là đọc được thứ store đọc (SEC-7).
- **Không webhook, không cert-controller** (`webhook.create: false`, `certController.create: false`, `crds.conversion.enabled` mặc định `false`) [N10]: webhook chỉ kiểm tra, controller tự kiểm template [N27]; chứng chỉ cho webhook cần một pod đọc Secret mọi namespace hay một Issuer có trước ESO ở wave 0. Mất: spec sai chỉ bị kiểm theo schema CRD, lỗi còn lại hiện ở `Ready=False` và health Degraded của Argo CD [N26]; bù bằng kubeconform trên render stg, prd trong `make helm-check`.
- `rbac.serviceAccountTokenCreate: false`, quyền xin token đặt lại hẹp ở §6; namespace `external-secrets` PSA `restricted`.

### 2. Kho nguồn

- **stg trên k3d/runner:** namespace **`svp-secrets`**, chỉ Secret nguồn, không pod; mỗi entry một Secret, key là tên biến `.env`; `SecretStore` provider `kubernetes`, `remoteNamespace: svp-secrets`, CA từ ConfigMap `kube-root-ca.crt`, `auth.serviceAccount` là ServiceAccount riêng của store [N5].
- **prd:** AWS Secrets Manager, mỗi entry `svp/<env>/<entry>` là JSON cùng key; store `aws` không khối `auth` (Pod Identity [N6]), mỗi `SecretStore` một `role` chỉ `secretsmanager:GetSecretValue` trên đúng entry namespace đó cần; GCP: provider `gcpsm` với `auth.workloadIdentity` [N7]. IAM chi tiết do ADR của cloud chốt.
- ExternalSecret dùng `remoteRef.key: <prefix><entry>`, `property: <KEY>`; `prefix` rỗng ở stg, `svp/prd/` ở prd, đặt ở overlay env.
- 11 entry theo nhóm người dùng: `pg-superuser`, `pg-roles`, `s3-root`, `s3-users`, `kafka-admin`, `kafka-users`, `jwt-signing`, `jwt-verify`, `web`, `obs` (do `secrets.sh` ghi) và `glitchtip-runtime` (`secrets.sh` tạo rỗng, `glitchtip-init.sh` ghi giá trị thật). Bảng entry → key: phụ lục.

### 3. Phạm vi và ai đổ giá trị

- ESO chỉ trên đường GitOps: component đánh dấu để `install.sh` bỏ qua; ExternalSecret và store tắt ở values gốc, bật ở overlay `envs/stg/`, `envs/prd/`; `make k8s-up`, `make k8s-secrets` của đường dev không đổi hành vi.
- **stg lab:** `secrets.sh` có chế độ GitOps (do `gitops.sh` gọi trước Argo CD): kiểm `.env` như nay, rồi chỉ apply Secret nguồn ở `svp-secrets`, không tạo Secret đích nào.
- **`glitchtip-init.sh`:** ghi DSN và hai token vào entry `glitchtip-runtime`, `force-sync` ba ExternalSecret `sentry`, `glitchtip-api`, `glitchtip-sourcemaps`, chờ mỗi cái xong một lượt đồng bộ mới, rồi restart chỉ khi Secret đích đổi. Entry có sẵn giá trị rỗng để ExternalSecret `sentry` Ready ngay (tránh khoá vòng giữa `svp-cluster` và GlitchTip); `SENTRY_DSN` rỗng là reporter tắt; script coi token rỗng như chưa có.
- **prd:** người học đặt giá trị vào Secrets Manager bằng đăng nhập của mình (lệnh do AI soạn); PushSecret không bật.

### 4. Danh sách Secret

- Mọi Secret mà `secrets.sh` (25) và `glitchtip-init.sh` (3) tạo: ở đường GitOps mỗi Secret là một ExternalSecret cùng tên, namespace, key, type, ở `svp-data`, `svp`, `svp-obs`, `keda`; mọi ExternalSecret có `target.template` (ít nhất `type`, §7), template dựng giá trị ghép (chuỗi kết nối, `users.txt`, cấu hình Alertmanager) như script nay. Khoá ký JWT chỉ ở `user-service-env`, gateway chỉ có khoá công khai. Đường dev giữ script cho cả 28.
- Không thành ExternalSecret: mọi Secret của đường dev; Secret do operator hay chart tự sinh (CA, chứng chỉ cert-manager, PKI của CloudNativePG, Secret của Argo CD, chứng chỉ webhook Kyverno), vì chúng sinh và xoay trong cluster; Secret nguồn ở `svp-secrets`.
- Bảng 28 Secret (namespace, key, entry nguồn): phụ lục.

### 5. Đặt manifest ở đâu

- Template ở chart **`svp-cluster`** (một file liệt kê đủ 28 ExternalSecret, 4 SecretStore, ServiceAccount, Role), wave 1, đã tạo mọi namespace đích; ESO ở wave 0 để CRD có trước; kho nguồn đầy trước khi Argo CD cài, nên ExternalSecret Ready trước pod đầu tiên đọc Secret.
- Values gốc `externalSecrets.enabled: false`; overlay **chỉ nêu tên**, không giá trị: stg bật, `store: kubernetes`, `prefix: ""`; prd bật, `store: aws`, `prefix: svp/prd/`, region, role từng store, host Postgres. Quy tắc overlay của ADR-0024 giữ nguyên; overlay ở `envs/` của `svp-gitops`, chart ở repo code.
- prd render với store AWS trong `make helm-check` (render prd không được còn `svp-secrets`).

### 6. Bảo mật

- **Xin token: thu hẹp, bắt buộc.** Chart `svp-cluster` thêm ở mỗi namespace đích một Role chỉ `create` `serviceaccounts/token` với `resourceNames` là ServiceAccount của store; không thu hẹp thì controller bị chiếm xin được token của mọi ServiceAccount và leo quyền.
- **Đọc, ghi Secret: thử thu hẹp, ghi ngoại lệ nếu không được** (cache Secret của controller là watch toàn cluster [N11]); không được thì giữ ClusterRole của chart và `make drill-k8s-threats` in ngoại lệ SEC-5 kèm lý do.
- **ServiceAccount của store chỉ đọc kho theo nhu cầu:** bốn `svp-secrets-reader`, mỗi cái một Role ở `svp-secrets` chỉ `get` với `resourceNames` là entry namespace đó dùng, cộng `create` `selfsubjectrulesreviews` [N5].
- **Không pod nào chạy dưới ServiceAccount của store:** hai ValidatingAdmissionPolicy (bật khi store `kubernetes`): `svp-store-serviceaccount-pods` từ chối pod có `serviceAccountName` là `svp-secrets-reader`, `svp-store-serviceaccount-tokens` từ chối Secret token gắn với nó; controller không bị chặn vì provider lấy token bằng TokenRequest [N28].
- **Ai tạo được ExternalSecret:** chỉ Argo CD; aggregate tắt; `drill-k8s-threats` kiểm không ServiceAccount nào của `svp` tạo được ExternalSecret hay SecretStore.
- **NetworkPolicy** ở `external-secrets`: `default-deny`, `allow-dns`, `allow-kube-api`, chỉ ingress vào cổng metrics từ Prometheus; prd thêm TCP 443 ra địa chỉ public và TCP 80 chỉ tới `169.254.170.23/32` (`allow-pod-identity-agent`) [N29], không mở `169.254.0.0/16` hay cổng 2703; rule IPv6 (`fd00:ec2::23/128`) chốt khi biết họ IP của cluster prd. `svp-secrets` có `default-deny`.
- PSA `restricted` cho `external-secrets` và `svp-secrets`; AppProject `svp` chỉ thêm hai namespace đó và kind cluster-scoped chart render.
- Threat model §4.7: **SEC-5** controller ESO bị chiếm; **SEC-6** store đọc entry không phải của nó hay kho của env khác; **SEC-7** quyền tạo ExternalSecret là quyền đọc kho; SEC-3 ghi hiện thực bằng ESO. `drill-k8s-threats` thêm ca (a)–(f) có đối chứng, `verify-mask.sh` mask Secret của `svp-secrets`.

### 7. Xoay vòng

- **Đường dev (như nay):** sửa `.env` → `make k8s-secrets` → `make k8s-up` chạy Job init và restart workload có Secret đổi.
- **Mọi ExternalSecret `refreshPolicy: OnChange`** [N9]: Secret đích chỉ đổi khi script annotate `force-sync`; không `Periodic`, vì thứ tự đổi mật khẩu (Redpanda trước, object store restart trước Job `s3-init`, service restart sau Job init) không giữ được khi làm mới định kỳ.
- **stg lab:** sửa `.env` → `make k8s-secrets` (chế độ GitOps: `redpanda_admin`, apply Secret nguồn, `force-sync` mọi ExternalSecret, restart object store, Redpanda) → sync `svp-data` (Job init) → restart workload có Secret đổi; bước tay ở `gitops.sh` thu còn một lệnh.
- **Chờ một lượt đồng bộ mới, không chờ Secret đích đổi:** script đọc `status.syncedResourceVersion`, annotate `force-sync` bằng giá trị chưa dùng, chờ có hạn tới khi giá trị đó đổi và `Ready` là `True`; quá hạn thì in `reason`, `message` và dừng; `metadata.generation` đổi trong lúc chờ thì dừng và in lệnh chạy lại [N27].
- **Mọi ExternalSecret có `target.template`, ít nhất `type`:** không template thì annotation `force-sync` chép sang Secret đích và workload restart thừa [N27].
- **prd:** đổi giá trị trong Secrets Manager (người học), rồi script làm như stg từ bước `force-sync`; không thêm Reloader.

### Hệ quả

- Tốt: danh sách Secret cluster cần nằm trong git (chỉ tên, key, nguồn), Argo CD sync và báo health từng cái, repo không giá trị hay ciphertext; cùng mẫu cho stg lab và cloud, cloud chỉ thêm store `aws` và IAM; đổi `.env` trên cluster GitOps còn một lệnh; đường dev và máy 16 GB không đổi.
- Xấu: một controller quyền rộng trên Secret (SEC-5), một pod và CRD trên đường đã vượt RAM; không webhook nên spec sai chỉ lộ ở health Degraded; hai cách đưa Secret vào cluster, `secrets.sh` hai chế độ, định tuyến Alertmanager có bản thứ ba; ở stg lab lợi ích bảo mật thật (không secret zero, IAM) chỉ có ở cloud; phụ thuộc một dự án từng dừng phát hành năm 2025 [N3].
- Xem lại khi: ESO dừng phát hành lại hay không vá CVE của image ghim quá 30 ngày (xét Secrets Store CSI Driver hay provider khác); ESO cache được theo nhiều namespace (bỏ ngoại lệ SEC-5); có xoay tự động ở prd (xét Reloader); RAM nghỉ với ESO vượt thêm quá 100 MiB (đặt `resources`, xem lại cache); chart ESO bật lại conversion webhook (chọn lại dòng 5).
- Tài liệu và ADR được chỉnh khi chấp nhận: [ADR-0014](0014-kubernetes-local-stage4.md) §8, ADR-0024 §9, ADR-0021 (bước kiểm ExternalSecret), threat model; chi tiết ở phụ lục, mục "Hệ quả".

## Xác nhận

- `make helm-check`: render gốc không ExternalSecret; stg và prd mỗi env 28 ExternalSecret, 4 SecretStore, đúng provider, prd không `svp-secrets`; kubeconform `-strict` hợp lệ, ca âm đỏ.
- Kịch bản `gitops` trên runner (trước và sau khi tách repo): ESO Healthy ở wave 0, 28 ExternalSecret Ready với đúng type và key, `k8s-smoke` xanh; SEC-5, SEC-6, SEC-7 và `SEC-6-reader` của `drill-k8s-threats` PASS kèm đối chứng; pod ESO 46 MiB; `dev-k3d` không có ESO.
- Không làm thu hẹp đọc Secret (§6): controller luôn watch metadata Secret toàn cluster; giữ ClusterRole, ghi Secret giới hạn bằng ValidatingAdmissionPolicy `svp-external-secrets-writes`.
- Chưa kiểm: `force-sync` trên cluster GitOps, thời gian tới Secret đích, quét giá trị bí mật trong artifact của đường GitOps, Pod Identity và NetworkPolicy trên EKS. Bảng kiểm chứng và id lượt chạy: phụ lục, mục "Kiểm chứng sau".

## Hiện thực ở

- Repo `svp-gitops`: `argocd/apps/components.json` (component `external-secrets`, wave 0, `gitopsOnly: true`), `argocd/apps/templates/applications.yaml`, `argocd/project.yaml`, `base/external-secrets.yaml`, `envs/stg/svp-cluster.yaml`, `envs/prd/svp-cluster.yaml`.
- `deploy/helm/svp-cluster/files/external-secrets.yaml` (danh sách 28 Secret), `deploy/helm/svp-cluster/templates/external-secrets.yaml` (SecretStore, ServiceAccount, Role, ExternalSecret, ValidatingAdmissionPolicy `svp-external-secrets-writes`, `svp-store-serviceaccount-pods`, `-tokens`), `templates/namespaces.yaml`, `templates/networkpolicies.yaml`, `values.yaml`.
- `deploy/k8s/secrets.sh`, `deploy/k8s/glitchtip-init.sh`, `deploy/k8s/lib.sh` (`es_force_sync`), `deploy/k8s/gitops.sh`, `deploy/k8s/install.sh` (bỏ qua `gitopsOnly`).
- Kiểm: `deploy/k8s/drills/threats.sh`, `deploy/ci/verify/gitops.sh` (bước `gitops-external-secrets`), `deploy/ci/verify-mask.sh`, `deploy/ci/gitops-check.sh`, `renovate.json`. Danh sách theo ngày: phụ lục, mục "Hiện thực ở".

## Nguồn

- [N1] Argo CD, "Secret Management": <https://argo-cd.readthedocs.io/en/stable/operator-manual/secret-management/>
- [N5] ESO, provider Kubernetes: <https://external-secrets.io/latest/provider/kubernetes/>
- [N6] ESO, AWS Access: <https://external-secrets.io/latest/provider/aws-access/>
- [N18] Sealed Secrets, README: <https://github.com/bitnami-labs/sealed-secrets>
- Danh sách đầy đủ [N1]–[N29] kèm trích dẫn và ngày đọc: phụ lục, mục "Nguồn".

## Thông tin thêm

Phụ lục: [`appendix/0026-secrets-gitops.md`](appendix/0026-secrets-gitops.md) (tiêu đề và trạng thái gốc, bối cảnh đầy đủ, bảng công cụ và kho nguồn, toàn văn các §, bảng entry và 28 Secret, "Cần người học chọn", "Kiểm chứng sau", hệ quả, hiện thực ở, nguồn).
