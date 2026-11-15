# 0075. Service mesh Istio ambient: mTLS STRICT, quyền theo ServiceAccount, cân tải và canary gRPC theo request

- Trạng thái: Chấp nhận
- Ngày: 2026-11-15
- Người quyết: người học (2026-11-15: làm hết theo chuẩn ngành trước buổi cloud, AI tự quyết thiết kế), AI đề xuất thiết kế theo tài liệu
  và mã nguồn ở tag đã ghim

## Bối cảnh và vấn đề

Rà soát backend theo chuẩn ngành ngày 2026-11-08 ghi hai lệch mức cao về gRPC trong cluster:

- **Cân tải:** gateway gọi service bằng `pick_first` qua ClusterIP, một kết nối HTTP/2 dài dính một pod, nên replica và HPA của service gần
  như không chia tải. `MaxConnectionAge` 30 s và canary chia theo số pod của [0072](0072-pod-operations.md) §8 chỉ gần đúng.
- **Plaintext:** kênh gateway → service chưa mã hoá, service không xác thực service gọi (IN-3 của [threat model](../threat-model.md)).
  [0042](0042-caller-identity-grpc.md) §4 chọn Istio ambient cho lớp kênh nhưng chỉ dựng ở EKS, vì k3d đã vượt ngân sách RAM
  ([0014](0014-kubernetes-local-stage4.md) §2, [0017](0017-gitops-capacity-media-worker-max2.md)) mà request mặc định của Istio thêm
  ~3,2 GiB; [0020](0020-reliability-stage6.md) §16 dời Istio tới khi cluster cloud đủ RAM.

Ràng buộc: repo public; máy 16 GB không chạy k3d để đo (đo trên runner của `verify.yml`); một đường thẳng, khác biệt nền tảng là dữ
liệu của `svp-gitops` ([0037](0037-mainpath-standard-tools.md)); `svp` chỉ nhận image phát hành đã ký ([0015](0015-cicd-devsecops-stage5.md));
node ứng dụng của EKS do Karpenter dựng ([0056](0056-eks-platform-ha.md)); không công cụ mới (không `istioctl`). Sự thật bên ngoài (cổng,
nhãn, chart Istio 1.32.0, Argo CD, Argo Rollouts, Karpenter): [phụ lục](appendix/0075-service-mesh.md#sự-thật-đã-kiểm).

## Yếu tố quyết định

- mTLS và danh tính workload trên mọi chặng giữa pod của `svp`, quyền theo ServiceAccount, không đổi code service.
- Cân tải và canary gRPC theo từng request, không theo kết nối hay số pod.
- Cùng chart, cùng component ở k3d (đường dev và GitOps) và EKS; compose thiếu gì thì ghi cái giá.
- Không nới guard đang có: PSA `restricted` của namespace dự án, Kyverno của `svp`, NetworkPolicy default-deny, image ghim digest.
- RAM của mesh trên k3d đo được trên runner, so với ngân sách của 0014 §2.

## Phương án đã cân nhắc

Trạng thái ngành, được, mất, nguồn: [phụ lục](appendix/0075-service-mesh.md#phương-án). In đậm là lựa chọn.

- Mesh: **Istio ambient** (ztunnel mỗi node, waypoint Envoy chỉ nơi cần L7; Stable cho một cluster [S36]); Istio sidecar (Envoy trong mọi
  pod, tài nguyên cấp theo pod [S36]); Linkerd (sidecar mỗi pod, mã nguồn mở chỉ còn bản edge [S37], [S38]); Cilium (thay CNI, mutual
  authentication Beta, chaining với VPC CNI giới hạn policy L7 [S39], [S41]).
- Cân tải gRPC: **waypoint L7**; client `round_robin` qua Service headless (không chia canary theo trọng số [S42], [S43]); chỉ `MaxConnectionAge`.
- Chỗ đặt waypoint: **một waypoint ở namespace riêng `svp-mesh`**; waypoint của `svp` (Kyverno của `svp` từ chối `proxyv2`); mỗi Service một.
- Namespace của ztunnel, istio-cni: **`istio-system` PSA `privileged`**; `kube-system` (Kyverno bỏ namespace này khỏi mọi webhook).
- Nơi chạy: **k3d (cả hai đường) và EKS**; chỉ đường GitOps của k3d; chỉ EKS như 0042 §4.

## Kết quả quyết định

Chọn các phương án in đậm: ambient cho mTLS L4 ở mọi pod mà không thêm container vào pod nào, L7 chỉ ở bốn Service gRPC, mọi guard giữ
nguyên. Giá trị đủ, sự thật và nguồn của từng §: phụ lục.

### 1. Thành phần mesh, phiên bản

Bốn component của `argocd/apps/components.json` (`svp-gitops`) ở `istio-system`, chart từ `https://blob.istio.io/istio-release/charts`
(Istio thôi phát hành ở GCS từ 1.31 [S3]), một version (bản vá mới nhất của minor mới nhất còn hỗ trợ) cho bốn chart và mọi image ghim
digest: `istio-base` (CRD, wave 2), `istiod` (3), `istio-cni`, `ztunnel` (4), sau `svp-cluster` (1), trước các release (7); Renovate nâng
cả bốn trong một PR. `base/<component>.yaml` là giá trị k3d (request hạ cho cụm lab), `platforms/eks/<component>.yaml` khác
biệt của EKS (istiod hai replica trải zone, request của chart). Không cờ bật tắt mesh; compose không có mesh (Istio cần Kubernetes).

### 2. Namespace mesh

- `istio-system`: PSA `privileged` từ chart `svp-cluster` (`platformNamespaces`), vì ztunnel, istio-cni chạy root với `NET_ADMIN`,
  `SYS_ADMIN` [S15], [S21]; không default-deny (không giữ dữ liệu dự án). Không dùng `kube-system`: Kyverno bỏ namespace đó khỏi mọi
  webhook, kể cả registry mirror ([0062](0062-ecr-registry-ci-oidc.md)).
- `svp` mang `istio.io/dataplane-mode: ambient`; `svp-mesh` (PSA `restricted`, default-deny, allow-dns) chỉ giữ waypoint; `svp-data`,
  `svp-obs`, `svp-edge` ngoài mesh (ztunnel chuyển nguyên, TLS riêng giữ). Pod proxy của Envoy Gateway vào mesh bằng nhãn pod ở `EnvoyProxy`
  (`envoyDeployment.pod.labels`); danh tính của chúng là namespace `envoy-gateway-system` (tên ServiceAccount có hậu tố băm).

### 3. Waypoint

Gateway `waypoint` (class `istio-waypoint`, `istio.io/waypoint-for: service`) ở `svp-mesh`, chart `svp-cluster`; listener HBONE 15008 chỉ
nhận Service của `svp`. Bốn Service gRPC mang `istio.io/use-waypoint: waypoint`, `istio.io/use-waypoint-namespace: svp-mesh`; gateway, web
không qua waypoint (không cần L7). istiod tạo Deployment, Service, ServiceAccount `waypoint`; ConfigMap ở `parametersRef` đặt replica (1 ở
k3d, 2 ở EKS kèm PDB), resources và seccomp `RuntimeDefault` mà PSA `restricted` đòi [S14], [S21]. Gateway mang
`argocd.argoproj.io/ignore-healthcheck: "true"`: health của Argo CD chờ `Programmed=True` mà chỉ istiod (wave 3) đặt, thiếu nó thì
`svp-cluster` không bao giờ Healthy [S26]; sức khoẻ waypoint đọc ở Deployment của nó và ở §11.

### 4. Ghim image waypoint

Pod waypoint do istiod tạo lúc chạy, không có trong render. `base/istiod.yaml` ghi `global.proxy.image` (và `global.proxy_init.image` cạnh
nó) nguyên ref có digest, và thay template sidecar `grpc-simple` (kéo `busybox:1.28` không ghim, ambient không dùng) bằng `""` [S21].
Policy `images-pinned` của checker đọc thêm khoá JSON `"image"` trong `data.values` của ConfigMap `istio-sidecar-injector`, đỏ khi ref thiếu
digest; giá trị là Go template của istiod (chứa `{{`) được bỏ qua ở đó và ở `image_refs` của `deploy/ci/gitops-check.sh`.

### 5. meshConfig

`defaultHttpRetryPolicy.attempts: 0`: waypoint không retry (mặc định của Istio thử lại hai lần [S22]); retry chỉ ở client gRPC của gateway
theo method idempotent, hai lớp sẽ nhân số lời gọi. `enableTracing: false`: span do service phát qua OTel, waypoint chỉ chuyển header.
`accessLogFile: ""`: service đã log mọi request.

### 6. mTLS STRICT và node mới

Mỗi release của `svp-service` có `PeerAuthentication` `mode: STRICT` chọn pod của nó: không plaintext ở cổng nào; probe của kubelet đi
đường riêng của ambient [S8]. Pod lên node trước istio-cni thì chạy ngoài mesh [S30], nên istiod gỡ taint `cni.istio.io/not-ready:NoSchedule`
khi istio-cni, ztunnel Ready (`taint.enabled: true`), NodePool Karpenter đặt taint đó ở `startupTaints`, và trên EKS pod của `svp` chỉ lên
node Karpenter (`nodeAffinity` `karpenter.sh/nodepool` Exists, `platforms/eks/<release>.yaml`), không lên nhóm `system` không taint
[S33], [S35]. k3d không có Karpenter: node có trước mesh.

### 7. AuthorizationPolicy theo ServiceAccount

Mọi release, `action: ALLOW`, không rule thì không ai vào. Danh tính SPIFFE `cluster.local/ns/<namespace>/sa/<serviceaccount>` ở khoá
`mesh` của peer (`values.yaml` của `svp-service`); peer `ingressFrom` thiếu `mesh` làm render lỗi.

- L4 (ztunnel, `selector` pod): release gRPC chỉ nhận danh tính của waypoint ở cổng gRPC, vì waypoint không mang danh tính của client [S16],
  nên lời gọi tới thẳng IP pod bị từ chối. Release khác nhận peer `ingressFrom` (Envoy: namespace `envoy-gateway-system`); release không
  `ingressFrom` (media-worker, dlq-replay) không nhận ai.
- L7 (waypoint, `targetRefs` Service, policy `<release>-waypoint` ở `svp`): chỉ peer `ingressFrom` (gateway) [S17], [S18].
- Không scrape nào vào pod của `svp` (metric đi OTLP ra Collector); probe của kubelet không qua policy.

### 8. NetworkPolicy ambient

Lớp mạng giữ, theo nhãn như trước, chỉ thêm cổng ambient cần [S6]: 15008 (HBONE) cạnh cổng service giữa các peer trong mesh và tới pod
waypoint; release gRPC nhận peer `waypoint` ở 15008; nguồn probe `169.254.7.127/32` vào cổng probe (NetworkPolicy `envoy` của `svp-cluster`:
19003, 19002). `svp-mesh`: vào 15008 từ `svp`, ra 15008 tới `svp`, 15012 tới `istio-system`. Cổng service vẫn mở cho peer, để plaintext của
§11 chạm tới lớp mTLS thay vì bị NetworkPolicy chặn trước.

### 9. Cân tải gRPC theo request

Waypoint cân tải từng request trên pod của Service. Code giữ `pick_first` và `insecure.NewCredentials()`: process nói plaintext tới ztunnel
trong chính pod, mesh mã hoá trên dây; compose không mesh thì lớp ứng dụng của 0042 §1 che. TLS trong code sẽ mã hoá hai lần và cần đường
cấp chứng chỉ thứ hai. `MaxConnectionAge` của 0072 §8 giữ: vô hại sau waypoint, vẫn chia tải ở compose và cho client ngoài mesh.

### 10. Canary gRPC theo request

Release `protocol: grpc` có `canary: true` là Rollout có `trafficRouting` qua plugin Gateway API của Argo Rollouts trên `GRPCRoute` tên
release: `parentRefs` là Service của release (GAMMA, waypoint thực thi), `backendRefs` `<release>` (stable) và `<release>-canary`, trọng số
khởi đầu 100/0 [S19], [S20]. Bước, analysis trên pod canary, giới hạn giữ như 0072 §8. Khoá `canaryRoute` của component nêu tên route
(`HTTPRoute` khi release có `httpRoute.host`, `GRPCRoute` khi `protocol: grpc`), helmfile của đường dev đòi nó khi và chỉ khi `canary: true`;
Role `argo-rollouts` của `svp` cho plugin `get`, `update` trên `grpcroutes` của bốn release gRPC; Application bỏ qua trọng số của cả hai kind.

### 11. Diễn tập mesh

`make drill-k8s-mesh` (Chainsaw, `deploy/k8s/drills/mesh/`, cụm `k3d-svp`): plaintext từ pod ngoài mesh (M-1), ServiceAccount lạ qua
waypoint (M-2), danh tính gateway gọi thẳng IP pod (M-3) bị từ chối; mọi pod của `svp` và pod Envoy được ambient bắt (M-4); đối chứng
`/readyz` qua Envoy; dòng `RESULT mesh-memory` (RAM, không làm đỏ). ztunnel nhận TCP trước khi nối upstream [S32], nên probe phán **đóng**
khi connect lỗi hay socket bị đóng, reset trước hạn giữ W, **mở** khi socket còn tới W (15 s, quá hạn nối 10 s của ztunnel); `web-13`,
`ff-5`, ca từ standin của `in-2-in-4` phán như vậy. Bước chạy ở job `gitops`, `dev-k3d` của `verify.yml`, nhận dispatch trên `feat/*`.

### 12. EKS

Node nhận TCP 15017 (webhook của istiod [S21], [S25]) từ security group của cluster qua `node_security_group_additional_rules` của module
`eks` (`svp-infra`); rule 1025–65535 giữa các node đã gồm 15008, 15012. Chưa kiểm: probe link-local qua network policy của VPC CNI [S24].

### 13. ADR cũ

Chỉnh: 0042 §4, Hệ quả; 0072 §8; 0020 §16. Đã xét, không chỉnh: 0014 §2 (ngân sách giữ, RAM của mesh so với nó), 0037 (mesh là component
chung, không cờ), 0056 (`startupTaints`, `nodeAffinity` thêm vào NodePool và pod, nhóm `system` giữ), 0062 (mirror áp cho `istio-system`).

### Hệ quả

- Tốt: mTLS, danh tính workload và quyền theo ServiceAccount trên mọi chặng giữa pod của `svp` mà không đổi code; IN-3 đóng trên cluster;
  lời gọi bỏ qua waypoint bị từ chối; cân tải và canary gRPC theo request; một chart cho k3d và EKS; guard cũ giữ.
- Xấu:
  - Mỗi lời gọi gRPC thêm một chặng Envoy. **Độ trễ mesh** (p99 `rpc.client.call.duration` của gateway trừ p99 `rpc.server.call.duration`
    của service, cùng method, cùng cửa sổ 5 phút dưới k6) chưa đo. Waypoint hỏng thì mọi lời gọi gRPC hỏng; k3d chỉ một replica.
  - RAM: bốn thành phần thường trực, trên k3d chưa đo. `istio-system` `privileged`: hai DaemonSet root có quyền mạng của node (IN-14).
  - Telemetry (OTLP, Pyroscope, GlitchTip) vẫn plaintext ra `svp-obs` ngoài mesh. Không scrape metric của Istio: sức khoẻ mesh qua probe,
    health của Argo CD và §11; lời gọi bị từ chối chỉ thấy ở log. compose không có mesh: kênh plaintext, không xác thực service gọi.
  - `GRPCRoute` ở mesh có trong mã Istio 1.32.0 nhưng tài liệu chỉ ghi `HTTPRoute`, không profile conformance mesh gRPC [S19];
    `use-waypoint-namespace` mới Beta [S11].
  - Lúc chuyển: PR backend merge trước (nhãn PSA `istio-system`), nâng checker, rồi PR `svp-gitops`; giữa hai merge lượt `gitops` theo lịch
    trên `main` đỏ. prd ghim chart cũ (`istio-system` `restricted`, Istio Degraded): chỉ dựng khi `envs/prd/charts.yaml` có chart mesh.
- Xem lại khi: RAM đo trên runner vượt ngân sách của 0014 §2 (người học chọn bước cắt); Độ trễ mesh làm p99 của một SLO độ trễ vượt ngưỡng
  dưới k6; Istio đổi hay ghi vào tài liệu hành vi `GRPCRoute` ở mesh; một service gọi service khác (thêm danh tính vào policy L7); cần cảnh
  báo trên mesh (PodMonitor của istiod, ztunnel, waypoint); probe link-local hỏng trên EKS; capability Argo CD được hiện thực.

## Xác nhận

- Kiểm tĩnh: `make helm-check`, `deploy/ci/gitops-check.sh` trên `svp-gitops`, `make kyverno-test` (ca `images-pinned` của ConfigMap
  injector), `gitops-check-test.sh`, `rotate-test.sh`, `make chainsaw-lint`, `drills/run-test.sh`, `steps-test.sh`, `verify-collect-test.sh`,
  `make actionlint`, `make zizmor`, `make docs-check`; `svp-infra`: `make test DIRS=aws/modules/eks` (rule 15017).
- Runner: `drill-k8s-mesh` ở `dev-k3d`, `gitops` chưa chạy; RAM (`RESULT mesh-memory`) chưa đo, đo ở lượt `dev-k3d` đầu tiên, số vào phụ lục.
- Buổi stg: Độ trễ mesh, tải chia đều giữa pod, canary gRPC theo request, probe qua network policy của VPC CNI, RAM trên node; rồi prd.

## Hiện thực ở

- §1, §5, §6: `svp-gitops` `argocd/apps/components.json`, `base/istio-base.yaml`, `istiod.yaml`, `istio-cni.yaml`, `ztunnel.yaml`,
  `platforms/eks/istiod.yaml`, `istio-cni.yaml`, `ztunnel.yaml`, `argocd/project.yaml`, `argocd/apps/templates/applications.yaml`,
  `renovate.json`, `docs/components.md`.
- §2, §3, §6, §8: `deploy/helm/svp-cluster/` (`values.yaml`, `templates/namespaces.yaml`, `waypoint.yaml`, `gateway.yaml`,
  `networkpolicies.yaml`, `karpenter.yaml`, `ci/eks-example.yaml`); `svp-gitops` `platforms/eks/svp-cluster.yaml`.
- §4: `deploy/ci/gitops-policies/images-pinned.yaml`, `test/images-pinned/`, `deploy/ci/gitops-check.sh`, `gitops-check-test.sh`.
- §6–§10: `deploy/helm/svp-service/` (`templates/mesh-policy.yaml`, `networkpolicy.yaml`, `service.yaml`, `grpcroute.yaml`, `canary.yaml`,
  `deployment.yaml`, `migrate.yaml`, `values.yaml`, `values.schema.json`, `ci/`), `deploy/k8s/helmfile.yaml.gotmpl`, `install.sh`,
  `rotate-test.sh`, `services/gateway/cmd/gateway/main.go`, `internal/grpcserver/grpcserver.go`; `svp-gitops` `platforms/eks/<release>.yaml`,
  `base/argo-rollouts.yaml`.
- §11: `deploy/k8s/drills/mesh/`, `deploy/k8s/drills/templates/mesh-client-up.yaml`, `ambient-probe.js`, `deploy/k8s/drills/run.sh`,
  `run-test.sh`, `deploy/k8s/drills/threats/` (`web-13`, `ff-5`, `in-2-in-4`, `psa-platform`), `deploy/k8s/k8s.mk`,
  `.github/workflows/verify.yml`, `deploy/ci/verify-collect.sh`, `verify-collect-test.sh`, `deploy/ci/verify-steps/steps-test.sh`.
- §12: `svp-infra` `aws/modules/eks/security-groups.tf`, `cluster.tf`, `tests/validation.tftest.hcl`, `README.md`.
- Hiện trạng: [`architecture.md`](../architecture.md) §6.5, [`threat-model.md`](../threat-model.md), [`k8s.md`](../reference/k8s.md),
  [`reliability.md`](../explanation/reliability.md), runbook [`mesh-traffic-denied.md`](../runbooks/mesh-traffic-denied.md).

## Nguồn

Đọc 2026-11-15; sự thật [S1]–[S35], phương án [S36]–[S43], tên đủ và trích dẫn ở [phụ lục](appendix/0075-service-mesh.md#nguồn-phương-án).

- [S13] <https://istio.io/latest/docs/ambient/usage/waypoint/>, [S36] <https://istio.io/latest/docs/overview/dataplane-modes/>,
  [S37] <https://linkerd.io/releases/>, [S43] <https://github.com/grpc/grpc/blob/master/doc/load-balancing.md>

## Thông tin thêm

Phụ lục: [`appendix/0075-service-mesh.md`](appendix/0075-service-mesh.md) (sự thật đã kiểm ở Istio 1.32.0, phương án, số đo, nguồn).
