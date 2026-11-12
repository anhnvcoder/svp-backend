# 0014. Chạy cả hệ thống trên Kubernetes local: k3d với Helm, Envoy Gateway, dữ liệu trong cluster, Argo CD và canary bằng Argo Rollouts

- Trạng thái: Chấp nhận
- Ngày: 2026-10-18

## Bối cảnh và vấn đề

- Chạy cả hệ thống trên Kubernetes local: k3d, Helm chart, Gateway API + Envoy Gateway + cert-manager, observability tách deployment, probe/resource/ PDB/HPA, KEDA theo lag, NetworkPolicy, RBAC, Argo CD app-of-apps, Argo Rollouts canary. **Xong khi:** đẩy code lên git thì Argo CD tự đồng bộ, và bản canary lỗi tự rollback.
- Đã chốt từ trước: Gateway API + Envoy Gateway (ingress-nginx ngừng bảo trì), Argo CD, KEDA, cert-manager; số hop proxy tin cậy RL-1 = 1 trên k3d; `MetadataMinAge` 1 s ([ADR-0013](0013-kafka-metadata-min-age.md)); `internal/kafkax` đọc `KAFKA_SASL_USERNAME`/`KAFKA_SASL_PASSWORD` (SCRAM-SHA-256); gateway đọc `TRUSTED_PROXY_HOPS` (mặc định 0) và `TRUSTED_PROXY_CIDRS`.
- Máy Apple M2 16 GB; Docker Desktop khoảng **9,7 GiB**, 8 CPU; `kubectl` 1.37.1, `helm` 4.3.0, Go 1.27.2, Postgres native 15.18; compose `core` + `obs` lúc nghỉ 1,71–2,61 GiB. ADR này chốt version, digest, tên namespace, Secret, cổng, biến môi trường và tên metric mà mọi phần hạ tầng của k3d dùng; bối cảnh đầy đủ ở [phụ lục](appendix/0014-kubernetes-local-stage4.md). Threat model ([mục 5](../appendix/threat-model.md#tổng-hợp-theo-giai-đoạn-mục-5-cũ)) cho k3d: FF-3, FF-4, FF-5, FF-6, IN-2, IN-4, IN-9, RL-1, OPS-2.

## Yếu tố quyết định

- RAM: compose và k3d không chạy cùng lúc, cluster nghỉ dự kiến ~5,6 GiB trong Docker VM 9,7 GiB. Threat model: NetworkPolicy chặn hai chiều, PSA `restricted`, SASL + ACL, Postgres không `trust`, UI chỉ qua port-forward có đăng nhập.
- Một nguồn danh sách thành phần cho đường dev và GitOps; mọi thành phần ghim version (digest cho image project tự ghim); công cụ theo hiện trạng ngành, mỗi mảng một công cụ chính.

## Phương án đã cân nhắc

- Topology: 1 node (PDB, drain vô nghĩa): loại
- Topology: 3 node (thêm RAM, không học thêm): loại
- Topology: **1 server + 1 agent**
- Topology: giữ Traefik: loại
- Topology: MetalLB: loại
- Topology: chuyển hẳn sang k3d (dựng chậm, RAM gấp ~2,5 lần): loại; compose giữ vai đường dev chính
- Dữ liệu A: Postgres, Redis native (pod tới qua `host.k3d.internal`: lỗ `trust` dùng chung, IN-9 không đạt): loại
- Dữ liệu C: StatefulSet tự viết hay Bitnami: loại
- Dữ liệu **B: tất cả trong cluster**
- Biên vào: Traefik của k3s: loại
- Biên vào: ingress-nginx: loại
- Biên vào: HTTP/mkcert: loại
- Biên vào: **Envoy Gateway + CA tự ký của cert-manager**
- Canary: Flagger (hệ Flux): loại
- Canary: chỉ rolling update (không phân tích): loại
- Canary: **Argo Rollouts + plugin Gateway API**
- GitOps: Flux: loại
- GitOps: ApplicationSet (một file JSON đủ): loại
- GitOps: webhook GitHub (cluster local không nhận được): loại
- Secret: Sealed Secrets/SOPS (thêm khoá phải giữ): hoãn
- Secret: External Secrets (cần secret store, việc của cloud): hoãn
- Secret: **script đọc `.env`**

## Kết quả quyết định

Chọn k3d 1 server + 1 agent, dữ liệu trong cluster (B), Envoy Gateway + cert-manager, Argo CD app-of-apps, Argo Rollouts canary và Secret dựng từ `.env`, vì vừa ngân sách RAM, có biện pháp cho từng rủi ro threat model của k3d và giữ một nguồn danh sách thành phần cho hai đường cài (từng phần ở §1–§14).

### 1. Công cụ và version

Chọn **k3s v1.36.5**: minor mới nhất mà mọi thành phần có tuyên bố hỗ trợ chính thức đều nhận, nằm trong skew của `kubectl` 1.37, và là kênh `stable`
của k3s ngày 2026-10-18. Argo Rollouts 1.10.1 chạy ngoài dải e2e đúng một minor, chấp nhận (phương án thay: k3s v1.35.9). Cài thêm **chỉ k3d** v5.9.0
bằng `go install` ghim trong `make tools` (version đặt qua `-ldflags`); không cài CLI `argocd`, `kubectl-argo-rollouts`. Mọi chart ghim version, image
project tự ghim kèm digest đa kiến trúc (bảng ở phụ lục).

### 2. Topology và ngân sách RAM

Cluster k3d `svp` (context `k3d-svp`, `deploy/k8s/k3d.yaml`): 1 server + 1 agent, server vẫn chạy workload; cổng host chỉ `127.0.0.1` (API `6550`,
Envoy HTTPS `8443`, registry `5111`); subnet cố định `10.200.0.0/24`; tắt Traefik, giữ servicelb, local-path, metrics-server; `pod-max-pids=512`; PSA
`restricted` mặc định toàn cluster; kubeconfig gộp nhưng không đổi context hiện tại. Compose và k3d không chạy cùng lúc. RAM nghỉ dự kiến ~5,6 GiB,
đỉnh ~7,9 GiB (3 media-worker transcode). Nghỉ **> 6,5 GiB** hoặc đỉnh **> 8,7 GiB** thì áp lần lượt: tắt Pyroscope; tắt metrics-generator của Tempo;
media-worker tối đa 2 replica; giảm giới hạn và retention của Loki, Prometheus. Nghỉ trên 6,5 GiB mà đủ (a) đỉnh dưới 8,7 GiB và (b) phần vượt là page
cache thì ghi số, không cắt.

### 3. Namespace, Pod Security, NetworkPolicy

Namespace theo vai trò `svp`, `svp-data`, `svp-obs`, `svp-edge`, cộng namespace mặc định của chart platform. Cả bốn namespace và các namespace công cụ
nhãn PSA `restricted` v1.36 (enforce, warn, audit); mức mặc định toàn cluster `restricted` ở API server (`deploy/k8s/pod-security-admission.yaml`) chỉ
miễn trừ `kube-system`. Ở bốn namespace của project: `default-deny` chặn `Ingress` và `Egress`, `allow-dns`, mỗi luồng khác một policy theo label pod
(bảng luồng ở phụ lục là danh sách đủ); `allow-kube-api` mở egress tới `ipBlock 10.200.0.0/24` cổng 6443 và `10.43.0.1/32` cổng 443 chỉ cho pod có
label `svp-kube-api: allow`; admission webhook của Prometheus operator tắt. Alertmanager ra TCP 443 tới địa chỉ công khai (`ipBlock` `0.0.0.0/0` trừ
dải riêng) vì NetworkPolicy không khoá theo tên miền. Còn hở: `kube-system` không enforce gì.

### 4. Dữ liệu ở đâu (IN-9)

Chọn **B**, tất cả trong cluster; test (`make test`) vẫn dùng Postgres/Redis native. Postgres: CloudNativePG `svp-pg` ở `svp-data`, `instances: 1`,
major 15, `scram-sha-256` không rule `trust`, `sslmode=require`, superuser chỉ cho Job bootstrap. Valkey 9.1.2: không persistence, `noeviction`,
`maxmemory 64mb`, không mật khẩu (IN-7 chấp nhận ở local). Redpanda: chart chính thức, 1 broker, SASL SCRAM-SHA-256 không TLS, Kafka nội bộ `9092`,
mọi listener external tắt. Object store ban đầu MinIO (nay RustFS theo [0022](0022-local-object-store-minio-replacement.md)). Đổi lấy ~0,6 GiB RAM và
công vận hành operator; `DATABASE_URL`, `REDIS_URL` giống mọi môi trường nên lên cloud chỉ đổi giá trị.

### 5. Redpanda SASL và ACL (IN-4, FF-6)

SASL SCRAM-SHA-256, mỗi service một user, ACL tối thiểu `resource-pattern-type literal` theo bảng user → quyền (ở phụ lục); superuser duy nhất là
`svp-admin`, chỉ Job init dùng để tạo user và ACL. `config.cluster.admin_api_require_auth: true`; `/public_metrics` không cần xác thực. Hook
`postStart` của chart thay bằng `/bin/true` (chỉ đúng với một broker). NetworkPolicy: `9644` chỉ từ Job init và Collector, `9092` chỉ từ 5 service có
Kafka, KEDA và Job init. Compose không bật SASL: IN-4 chỉ thực thi ở k3d.

### 6. Image

Registry local k3d `k3d-svp-registry` (`127.0.0.1:5111`, ghim digest). Tag phát hành là 12 ký tự hex đầu SHA commit; tag dev là
`dev-<12 hex của image ID>`, chỉ qua `--set image.tag`, để `k8s-up` lặp lại không tạo revision canary mới. Chart `svp-service` báo lỗi bằng `required`
khi `image.tag` rỗng.

### 7. Chart và bố cục thư mục

Một chart ứng dụng chung `svp-service` cho 6 release, cùng `svp-cluster`, `svp-data`, `svp-observability`. Một file
`deploy/argocd/apps/components.json` là danh sách duy nhất cho `install.sh` và chart app-of-apps (wave 0–7, wave nhỏ cài trước); Argo CD không nằm
trong đó. File của compose (rule, dashboard, bootstrap SQL, script init) dùng lại bằng symlink trong `files/` của chart; đã kiểm với Helm 4.3.0 và
Argo CD v3.5.5 (symlink trỏ ra ngoài gốc repo bị từ chối).

### 8. Secret

Không Secret nào trong git. `make env` bổ sung biến vào `.env`; `deploy/k8s/secrets.sh` đọc `.env` và tạo Secret bằng `kubectl apply -f -` từ stdin,
không in giá trị (bảng Secret ở phụ lục). Secret `keda-kafka` ở namespace `keda`, không ở `svp`. Đổi mật khẩu: `make k8s-secrets` rồi `make k8s-up`
(Redpanda nhận mật khẩu mới trước khi apply Secret nào; workload restart theo `resourceVersion`).

### 9. Biên vào (Gateway API)

Envoy Gateway; `GatewayClass` và `Gateway` `svp` ở `svp-edge`, một listener `https` cổng 443 hostname `*.svp.localhost`, TLS `Terminate` với Secret
`svp-wildcard-tls`; `externalTrafficPolicy: Cluster`. Chứng chỉ: `svp-selfsigned` → `svp-local-ca` → `svp-ca` → `svp-wildcard`, CA xuất ra
`.k8s/ca.crt`. HTTPRoute `api` → `gateway:8080` và `s3` → `minio:9000` (`timeouts.request: 10m`); không route cho UI vận hành. Gateway đặt
`TRUSTED_PROXY_HOPS=1`, `TRUSTED_PROXY_CIDRS=10.42.0.0/16`; ở k3d gateway thấy tối đa hai địa chỉ client (một mỗi node).

### 10. Workload

ServiceAccount riêng, không mount token, không Role; securityContext `restricted` (65532). Gateway readiness và liveness `/healthz` (không `/readyz`),
service gRPC dùng probe `grpc` gốc; migrate bằng Job hook `pre-install,pre-upgrade`. Gateway 2 replica + PDB `minAvailable: 1` + HPA 2–4; feed-service
HPA 1–2; ba service còn lại 1 replica không PDB. media-worker scale bằng KEDA Kafka scaler theo lag (`lagThreshold: "1"`, `minReplicaCount: 1`,
`maxReplicaCount: 3`), đăng nhập qua `ClusterTriggerAuthentication` `keda-kafka`; quyền operator KEDA thu hẹp (`restrict.secret`, cert-manager cấp
chứng chỉ, RBAC tự cấp). Workload do HPA giữ không render `replicas`. Request/limit mọi container ghi ở values (bảng ở phụ lục); Valkey limit CPU `1`
và probe `tcpSocket`.

### 11. Observability trong cluster

Tách deployment: kube-prometheus-stack (Service `kps-*`), Loki, Tempo, Pyroscope single-binary, Collector chart, GlitchTip; datasource cùng UID với
compose. Prometheus operator chỉ watch `svp-obs`; tắt node-exporter và scrape control plane k3s. Alertmanager không mount token. Quyền thu hẹp:
Grafana chỉ ConfigMap, kube-state-metrics bỏ `secrets`, operator namespaced. Collector `GOMEMLIMIT=140MiB`, queue exporter theo byte. UI chỉ qua
`kubectl port-forward` trên `127.0.0.1`, không HTTPRoute, LoadBalancer hay NodePort.

### 12. GitOps

Argo CD app-of-apps tối giản (chart 10.10.5, v3.5.5), poll `timeout.reconciliation: 60s` và jitter `0s`: push → thấy commit thường ≤ 60 s, tệ nhất
~120 s. Root `svp-root` → chart `deploy/argocd/apps` → một Application mỗi phần tử `components.json`, `ServerSideApply=true`, server-side diff (root
giữ diff cũ). AppProject `svp` giới hạn nguồn, đích (kể cả `kube-system` cho RoleBinding của KEDA) và kind cluster-scope; AppProject `default` khoá
rỗng; health tuỳ biến cho Application con và `Alertmanager`. Argo CD là ngoại lệ tương đương cluster-admin; CloudNativePG hết ngoại lệ, Envoy Gateway
thu hẹp, cert-manager ngoại lệ đầy đủ (còn hở `kube-system`). Hai đường cài không chạy trên một cluster: dev `make k8s-up`, GitOps
`make k8s-gitops-up`.

### 13. Canary

Argo Rollouts v1.10.1 + plugin `argoproj-labs/gatewayAPI` v0.17.0 (sha256 ghim); controller namespaced (`--namespace=svp`). Chỉ gateway là `Rollout`,
hai backendRef `gateway`, `gateway-canary` trên HTTPRoute `api`, mỗi backendRef có filter `RequestHeaderModifier` để Envoy tách cluster (canary là
`httproute/svp/api/rule/0/backend/1`). Bước: `setWeight: 25`, pause 60 s, `setWeight: 50`, pause 60 s, bước `analysis` `gateway-canary-gate`, 100%.
Phân tích từ metric Envoy: 5xx < 1% và p99 < 150 ms, cần ≥ 30 phản hồi không phải 4xx; Prometheus lỗi liên tiếp thì abort. Restart gateway bằng
`spec.restartAt`; release `gateway` cài Helm client-side `--wait=hookOnly`; Application `gateway` bỏ qua trọng số và hash selector với
`RespectIgnoreDifferences=true`.

### 14. Compose vẫn là đường dev chính

Compose giữ vai trò và mọi target cũ giữ hành vi (không SASL, Postgres/Redis native, `make up`/`smoke`/diễn tập). k3d để học vận hành Kubernetes; diễn
tập của compose không port sang k3d, ngoài `make k8s-smoke` (chạy `deploy/compose/smoke.sh` qua `https://api.svp.localhost:8443` với `.k8s/ca.crt`).

### Hệ quả

- Tốt: cùng code, đổi môi trường chỉ đổi values; mỗi rủi ro threat model của k3d có biện pháp kiểm được; canary tự phân tích và tự abort.
- Xấu: hai đường cài phải giữ khớp qua `components.json` và wave; Secret nằm ngoài GitOps (`secrets.sh` chạy từ máy có `.env`); AppProject `svp` ghi được vào `kube-system`; Alertmanager ra được mọi địa chỉ công khai cổng 443; cert-manager còn hở `kube-system`; RAM nghỉ ~5,6 GiB so với 1,7–2,6 GiB của compose; rate limit theo IP gộp mọi client của máy; phụ thuộc chi tiết bên thứ ba (tên cluster của Envoy Gateway, hook `postStart` của chart Redpanda).
- Xem lại khi: RAM đo vượt ngưỡng sau mọi bước cắt; Argo Rollouts có bản e2e 1.36+ (nâng cùng k3s); nâng Envoy Gateway hay chart Redpanda; Redpanda từ 3 broker; thêm người hay repo vào GitOps (tách AppProject platform); lên cloud.

## Xác nhận

- Kiểm tĩnh bằng `helm template`, mã nguồn ở tag ghim; cluster dựng lại từ đầu (đường dev) và `make k8s-gitops-up` (đường GitOps): `make drill-k8s-threats` 10/10 PASS hai lượt, `make drill-k8s-canary` (bản tốt promote, bản lỗi abort), `make drill-k8s-pdb`, `make drill-k8s-keda`. RAM: nghỉ 5,87–6,78 GiB, đỉnh 7,95 GiB, đạt điều kiện (a), (b) của §2.
- Chưa kiểm: đỉnh RAM đủ 3 worker cùng transcode, gate `Inconclusive` thật, `RespectIgnoreDifferences` giữa lúc canary, pg_rewind (số đo ở phụ lục).

## Hiện thực ở

- Công cụ, topology, cổng, compose (§1, §2, §14): `deploy/k8s/` (`k3d.yaml`, `k8s.mk`, `lib.sh`, `install.sh`), `Makefile`, `deploy/compose/compose.mk`; RAM của §2 đo bằng sampler và runner cũ của `.github/workflows/verify.yml` (đã bỏ: [0039](0039-mainpath-drills-scan-gate-sourcemaps.md) §1, [0050](0050-bash-to-standard-tools.md); số đo ở phụ lục).
- Namespace, Pod Security, NetworkPolicy (§3): `deploy/k8s/pod-security-admission.yaml`, `deploy/helm/svp-cluster/`, `templates/networkpolicies.yaml` của `svp-data`, `svp-observability`, `templates/networkpolicy.yaml` của `svp-service`.
- Dữ liệu, Redpanda SASL và ACL (§4, §5): `deploy/helm/svp-data/` (object store `s3` theo [0022](0022-local-object-store-minio-replacement.md)), `deploy/k8s/values/cloudnative-pg.yaml`, `deploy/k8s/values/redpanda.yaml`.
- Image, chart, Secret (§6, §7, §8): `deploy/k8s/lib.sh`, bảng image `deploy/docker-bake.json`, năm chart dưới `deploy/helm/`, `deploy/argocd/apps/components.json` dùng chung cho `deploy/k8s/helmfile.yaml.gotmpl` (qua `deploy/k8s/install.sh`) và `deploy/argocd/apps/`, `deploy/k8s/values/`, `deploy/k8s/secrets.sh` và `deploy/k8s/rotate.sh` (thứ tự xoay credential; restart do Reloader, [0050](0050-bash-to-standard-tools.md) mục 5), `deploy/k8s/glitchtip-init.sh`.
- Biên vào, workload (§9, §10): `deploy/helm/svp-cluster/templates/gateway.yaml`, `certificates.yaml`, `deploy/helm/svp-service/`, `deploy/k8s/values/envoy-gateway.yaml`, `cert-manager.yaml`, `keda.yaml`, `deploy/k8s/values/services/`.
- Observability (§11): `deploy/helm/svp-observability/`, `deploy/k8s/values/kube-prometheus-stack.yaml`, `loki.yaml`, `tempo.yaml`, `pyroscope.yaml`, `otel-collector.yaml`, `deploy/observability/otelcol/k8s-config.yaml`.
- GitOps, canary (§12, §13): `deploy/k8s/gitops.sh`, `deploy/argocd/project.yaml`, `deploy/k8s/values/argo-cd.yaml`, `argo-rollouts.yaml`, `deploy/helm/svp-service/templates/canary.yaml`, `deploy/ci/trivy-config-ignore.yaml` (ngoại lệ RBAC của CloudNativePG).
- Diễn tập: `deploy/k8s/drills/` (`keda.sh`, `pdb.sh`, `gitops.sh`, `canary.sh`, `traffic.sh`, `threats.sh`). Danh sách theo từng file ở mục cuối của phụ lục; hiện trạng ở [`deployment.md`](../explanation/deployment.md#kubernetes-cục-bộ-k3d), [`k8s.md`](../reference/k8s.md).

## Nguồn

- Tương thích Kubernetes của Envoy Gateway: <https://gateway.envoyproxy.io/news/releases/matrix/>
- Network policy controller của k3s: <https://docs.k3s.io/networking/networking-services#network-policy-controller>

## Thông tin thêm

Phụ lục: [`appendix/0014-kubernetes-local-stage4.md`](appendix/0014-kubernetes-local-stage4.md) (phân tích phương án, bảng version và digest, số đo, lần sửa có ngày, lịch sử kiểm chứng; mở đầu có nguyên văn dòng trạng thái ghi lúc chốt).

### Chỉnh bởi

- §6, §12: [0015](0015-cicd-devsecops-stage5.md): tag phát hành, `make k8s-release` và đường image: image phát hành build trong CI, kéo từ GHCR theo digest.
- §2, §10: [0017](0017-gitops-capacity-media-worker-max2.md): tiêu chí ổn định (c), cửa sổ đỉnh 2 worker, bước cắt 3 đã áp, `maxReplicaCount` 2, topic giữ 3 partition.
- §3, §9, §10, §13: [0019](0019-web-k3d-supply-chain-observability.md): luồng của web, listener `https-apex` và Certificate `svp-apex` cho `svp.localhost`, tên HTTPRoute theo release, Envoy bỏ trace context của client, release `web`, PDB khi số replica cố định, canary của web với ngưỡng theo release.
- §10, §12: [0020](0020-reliability-stage6.md): `timeoutSeconds` của probe; `WATCH_NAMESPACE` của CloudNativePG thêm `cnpg-system`, Role của operator ở `cnpg-system` thu hẹp còn đọc, ghi Secret, event, Lease, ValidatingAdmissionPolicy `svp-cnpg-operator-secrets`.
- §3, §4, §12, §13: [0021](0021-deferred-verification-stage6b.md): uid/gid Valkey `10999`, Redpanda `--reserve-memory=128M`, Argo CD đọc repo qua HTTPS ẩn danh thay deploy key SSH (2026-10-28), asset plugin theo kiến trúc node ở cả hai đường.
- §12: [0024](0024-multi-environment.md): overlay môi trường `deploy/k8s/envs/`, cluster GitOps đóng vai stg.
- §1, §2, §4, §7, §8, §9, §10: [0022](0022-local-object-store-minio-replacement.md): MinIO thay một phần bởi RustFS (StatefulSet, Service và Job `s3`, `s3-init`, Secret `s3-root`, `s3-users`, CORS theo bucket, giới hạn 512 MiB, uid 10001).
- §10 và giới hạn RAM của Tempo trong bảng của §2: [0031](0031-chaos-findings-feed-engagement-tempo.md): feed-service luôn 2 replica, PDB `minAvailable: 1`, ưu tiên trải hai node; Tempo 768 MiB thành 1 GiB.
- §8: [0026](0026-secrets-gitops.md): Secret của đường GitOps do External Secrets Operator dựng; đường dev giữ `secrets.sh`; store AWS ở bản cloud.
- §12: [0025](0025-gitops-config-repo.md) (2026-10-30): Argo CD đọc `svp-gitops` cho root và values, chart ở commit ghim của repo code, `sourceRepos` thêm `svp-gitops`, version và values của Argo CD ở `argocd/bootstrap.json`, `base/argo-cd.yaml` của `svp-gitops`, đường dev đọc `components.json`, `base/` từ bản clone.
- §10: [0044](0044-grpc-readiness.md): readiness gRPC là tên health `readiness` theo Postgres của service, liveness và startup giữ health tổng.
- §6, §7, §8: [0050](0050-bash-to-standard-tools.md): đường dev cài component bằng helmfile (`deploy/k8s/helmfile.yaml.gotmpl`), image dev build bằng `docker buildx bake` theo bảng `deploy/docker-bake.json`, Secret đổi thì Reloader restart workload opt in; `make k8s-secrets` tự làm trọn một lượt xoay credential, không còn `make k8s-up` sau nó.
- §4, §5, §8, §14: [0053](0053-msk-elasticache-valkey.md): Kafka của compose và k3d là Apache Kafka KRaft (`apache/kafka`) thay Redpanda, SASL SCRAM-SHA-512 trên TLS cổng 9096 ở cả compose (IN-4 thực thi cả ở compose), user và ACL theo service giữ nguyên, không còn Admin API 9644; Valkey có TLS và user ACL theo db và tiền tố thay chạy không mật khẩu, compose có container Valkey riêng thay Redis native db 9/10/14 (test vẫn Redis native db 15); broker local nhận mật khẩu mới bằng `kafka-configs`.
- §4: [0057](0057-postgres17-verify-full.md): CloudNativePG major 17 thay 15, client nối `sslmode=verify-full` với CA local thay `require`.
