# Phụ lục ADR-0075: Service mesh Istio ambient: mTLS STRICT, quyền theo ServiceAccount, cân tải và canary gRPC theo request

Phụ lục của [ADR-0075](../0075-service-mesh.md): sự thật bên ngoài mà thiết kế mesh dựa vào, rồi
phương án, nguồn và số đo. Mục `## Sự thật đã kiểm` là nguồn duy nhất của các sự thật đó; mọi nguồn đọc ngày
2026-11-15.

## Sự thật đã kiểm

Cách kiểm: bốn chart kéo về thư mục tạm ngoài repo bằng `helm pull --repo
https://blob.istio.io/istio-release/charts <chart> --version 1.32.0 --untar`, render bằng `helm template` (Helm
v4.3.1); mã nguồn đọc ở bản clone `--depth 1` của đúng tag (commit ở mục Nguồn bên dưới); không cài gì vào cluster
nào. Tài liệu và mã nguồn ở tag nói khác nhau thì mã nguồn thắng, dòng ghi cả hai. Cột "Dựa vào" nêu thuật ngữ
thiết kế dùng sự thật đó. Ký hiệu `[Sn]` trỏ tới mục Nguồn.

### Phiên bản Istio

| Sự thật | Giá trị | Nguồn | Dựa vào |
| --- | --- | --- | --- |
| Minor mới nhất còn hỗ trợ, bản vá mới nhất | **1.32.0**; hai minor còn hỗ trợ kia ở 1.31.4 và 1.30.8 | [S1], [S2] | **Phiên bản Istio** |
| Ngày phát hành | 2026-11-09 (Supported Releases: "Nov 9, 2026"; GitHub release `1.32.0` lúc 2026-11-09T19:07:47Z) | [S1], [S2] | **Phiên bản Istio** |
| Hết hỗ trợ | ~Jun 2027 (dự kiến); minor được hỗ trợ tới 6 tuần sau khi minor N+2 ra | [S1] | **Phiên bản Istio** |
| Kubernetes hỗ trợ | 1.33–1.37 (tối thiểu 1.33). k3d chạy `rancher/k3s:v1.36.6-k3s1` (`K3S_IMAGE_TAG` của `Makefile`), EKS `kubernetes_version = "1.36"` (`aws/envs/{stg,prd}/*.tfvars` của svp-infra): cả hai trong dải | [S1], [S2] | **Phiên bản Istio** |
| Repo chart | Từ 1.31 Istio thôi phát hành vào `istio-release.storage.googleapis.com`, `gcr.io/istio-release`, `registry.istio.io`; chart HTTP ở `https://blob.istio.io/istio-release/charts` (trả 308 sang `istio-release.r2.istio.io`, Helm theo được), chart OCI ở `ghcr.io/istio/release/charts`, image vẫn ở Docker Hub. Index của repo GCS (sinh 2026-11-06T17:38:22Z) dừng ở bản ổn định 1.30.8 và 1.31.0-rc.0; `istiod-1.31.0.tgz`, `istiod-1.32.0.tgz` ở đó trả 404. Index của `blob.istio.io` (sinh 2026-11-09T18:58:07Z) có 1.32.0 cho `base`, `istiod`, `cni`, `ztunnel`. Istio tắt thử hạ tầng GCP ngày 2026-11-17 (15:00–21:00 UTC) và 2026-12-08 15:00 tới 2026-12-09 15:00 UTC | [S3], [S4], [S5] | **Thành phần mesh** (repo) |

Digest multi-arch index trên `docker.io/istio`, mỗi index liệt kê đúng hai manifest `linux/amd64` và
`linux/arm64`. `profile: ambient` đặt `global.variant: distroless`, nên ref mà chart tự dựng là tag
`-distroless`; giá trị `image` chứa `/` được dùng nguyên, không gắn thêm variant.

| Image | Digest của tag `1.32.0` | Digest của tag `1.32.0-distroless` |
| --- | --- | --- |
| `pilot` | `sha256:5383df363d976589a51ab438831f82e9b5303dfc42128f2fb1f493b3f6acca78` | `sha256:219ab7efcf1fd1f883086ad4a4a649c0e70bee3200423d6eef9f435103a79423` |
| `proxyv2` | `sha256:b8d47c6d8d6e4b3fee7ae1e6f44339ec13091c24dc07f113a35efb0141a688d0` | `sha256:9cd1f1cc261f3fe250ab483543e7256c39d5871eae5f1817c0809eff09e365d4` |
| `ztunnel` | `sha256:9d7bdca90124e3680317c29b1e19a94335a15dba3ca51b8676c027b333869f69` | `sha256:953a77fc17379301de4b7c6697b1668471c9c1f6ff912c9c5b78f454ab362180` |
| `install-cni` | `sha256:e37743a29f5cc2e37e823bbeaef3a2a62bbdf758e4db5d3ab2101450652f09ed` | `sha256:bf8fa30fe56fc7209941af23999f1463071b9885c22ec81f5998645718698787` |

Lệnh (buildx v0.20.1), mỗi image và tag một lần; output có `MediaType:
application/vnd.docker.distribution.manifest.list.v2+json`, dòng `Digest:` là digest index ở bảng trên:

```bash
env -u DOCKER_DEFAULT_PLATFORM docker buildx imagetools inspect docker.io/istio/pilot:1.32.0-distroless
```

### (1) Cổng HBONE, nguồn của probe, Envoy Gateway

| Sự thật | Giá trị ở 1.32.0 | Nguồn | Dựa vào |
| --- | --- | --- | --- |
| Cổng HBONE, chiều vào | 15008/TCP. Lưu lượng mesh giữa hai pod đi trong đường hầm tới cổng 15008 của pod đích; NetworkPolicy do CNI thực thi ở host, ngoài pod, nên NetworkPolicy chỉ mở cổng ứng dụng sẽ chặn HBONE: pod trong mesh phải mở vào 15008 | [S6] | **NetworkPolicy ambient** (a), **Waypoint** |
| Cổng HBONE, chiều ra | ztunnel mở listener và socket ra ngay trong network namespace của pod ("Data will now enter and leave the pod network namespace encrypted"); kết nối ra đi từ IP pod tới IP pod đích (hay pod waypoint) cổng 15008, nên NetworkPolicy chiều ra của pod nguồn phải mở 15008 tới đích đó. Listener trong pod: 15001 (ra), 15006 (vào plaintext), 15008 (vào HBONE) | [S7], [S8] | **NetworkPolicy ambient** (b), **Waypoint** |
| Nguồn của probe kubelet vào pod đã enrol | Mọi kết nối TCP mà process của node (kubelet: probe, hook lifecycle `httpGet`) mở tới IP pod đã enrol được SNAT ở host netns sang `169.254.7.127` (IPv6 `fd16:9254:7127:1337:ffff:ffff:ffff:ffff`), cổng đích giữ nguyên; tài liệu bảo NetworkPolicy mở `ipBlock` `169.254.7.127/32` tuỳ CNI. Mã: `DefaultHostProbeSNATIP` (`cni/pkg/nodeagent/options.go`); luật `POSTROUTING ... -m owner --socket-exists -m set --match-set istio-inpod-probes dst -j SNAT --to-source 169.254.7.127` (`cni/pkg/iptables/iptables.go`); IP vào ipset `istio-inpod-probes` khi pod được thêm vào mesh (`AddPodToMesh`, `meshdataplane_linux.go`) | [S6], [S8] | **NetworkPolicy ambient** (a), **Envoy trong mesh** |
| Probe vào pod không enrol | Không SNAT: pod ngoài ipset trên (gồm pod `istio.io/dataplane-mode: none` như pod waypoint) nhận probe từ địa chỉ của node, và Kubernetes luôn cho lưu lượng giữa pod và node nó chạy ("traffic to and from the node where a Pod is running is always allowed") | [S8], [S10] | **Waypoint** (NetworkPolicy của `svp-mesh` không cần rule cho probe) |
| Cổng probe của pod proxy Envoy Gateway v1.9.3 (version ghim ở `components.json`, image `v1.9.3` ở `base/envoy-gateway.yaml` của svp-gitops) | Container `envoy`: startup, readiness, liveness `GET /ready` cổng **19003** (`EnvoyReadinessPort`, port tên `readiness`). Container `shutdown-manager`: startup, readiness, liveness `GET /healthz` cổng **19002** (`ShutdownManagerPort`); hook preStop của `envoy` là `GET /shutdown/ready` cổng 19002, kubelet gọi như probe. Pod do controller tạo lúc chạy, render không thấy | [S9] | **Envoy trong mesh** (NetworkPolicy `envoy` mở 19003, 19002 từ `169.254.7.127/32`) |
| Nhãn pod proxy Envoy | `EnvoyProxy` `spec.provider.kubernetes.envoyDeployment.pod.labels` (`KubernetesPodSpec.Labels`) có ở v1.9.3 | [S9] | **Envoy trong mesh** |
| DNS trong pod đã enrol | istio-cni chuyển DNS UDP 53 không tới localhost sang ztunnel 15053 trong pod (`ambient.dnsCapture: true` mặc định, render có `AMBIENT_DNS_CAPTURE: "true"`); proxy DNS của ztunnel chạy theo từng pod, gửi tiếp từ network namespace của pod, nên luật DNS chiều ra của pod giữ nguyên | [S8], [S12], [S32] | **NetworkPolicy ambient** |

### (2) Nhãn enrol, annotation đã bắt

| Sự thật | Giá trị ở 1.32.0 | Nguồn | Dựa vào |
| --- | --- | --- | --- |
| Nhãn enrol | `istio.io/dataplane-mode` (Stable) trên Namespace hay Pod, giá trị `ambient` hay `none` | [S11] | **Namespace mesh** |
| Bộ chọn enrol mặc định của chart `cni` | `ambient.enablementSelectors`: pod có `istio.io/dataplane-mode: ambient` ở bất kỳ namespace nào; hoặc namespace có nhãn đó và pod không mang `none`. `excludeNamespaces: [kube-system]` | [S12] | **Namespace mesh**, **Envoy trong mesh** (pod Envoy enrol bằng nhãn pod) |
| Annotation pod đã bị bắt | `ambient.istio.io/redirection` do istio-cni đặt: `enabled` là đã bắt, giá trị khác là chưa; `pending` là bắt một phần, chưa ztunnel nào nhận, pod chưa có lưu lượng. istiod coi pod ứng dụng là đích HBONE khi annotation là `enabled` (`setTunnelProtocol`, `workloads.go`; pod tự nói HBONE thì qua nhãn `networking.istio.io/tunnel: http`) | [S11], [S14], [S30] | **Ca drill mesh** (M-4) |

### (3) Waypoint

| Sự thật | Giá trị ở 1.32.0 | Nguồn | Dựa vào |
| --- | --- | --- | --- |
| Class | `istio-waypoint`, controller `istio.io/mesh-controller`, template `waypoint`, Service ClusterIP; istiod tự tạo GatewayClass | [S14] | **Waypoint** |
| `istio.io/waypoint-for` | Trên Gateway hay GatewayClass: `service`, `workload`, `all`, `none`; không đặt thì `service` | [S11], [S13], [S14] | **Waypoint** |
| Nhãn dùng waypoint | `istio.io/use-waypoint: <tên>` (Stable) trên Service, Pod, Namespace; `istio.io/use-waypoint-namespace: <namespace>` (Beta), đặt cùng nhãn trên khi waypoint ở namespace khác | [S11], [S13] | **Waypoint** |
| Điều kiện cho Service namespace khác | Listener `protocol: HBONE`, `port: 15008` có `allowedRoutes.namespaces.from: All`, hay `Selector` khớp nhãn namespace của Service; không đặt là `Same` (`makeAllowedRoutes`, `AllowsAttachmentFromNamespace`). Gateway waypoint phải có đúng một listener HBONE 15008, sai thì listener `Accepted=False` | [S13], [S14] | **Waypoint** |
| Khi waypoint chưa có địa chỉ | Gateway chỉ có địa chỉ khi Deployment có ít nhất một pod Ready; waypoint không tồn tại, chưa có địa chỉ, hay sai loại lưu lượng thì ztunnel gửi thẳng tới đích, không báo lỗi (condition `istio.io/WaypointBound` của Service ghi lý do). Policy `selector` ở đích chỉ nhận danh tính waypoint thì đường vòng đó bị chặn | [S13], [S14] | **AuthorizationPolicy** |
| Tên ServiceAccount | Bằng tên Gateway (class waypoint không thêm hậu tố, `DisableNameSuffix`), đổi được bằng annotation `gateway.istio.io/service-account`; Deployment, Service cùng tên. Gateway `waypoint` ở `svp-mesh`: ServiceAccount `waypoint`, principal `cluster.local/ns/svp-mesh/sa/waypoint` | [S13], [S14] | **Principal** |
| Nhãn pod của Deployment waypoint | `gateway.networking.k8s.io/gateway-name: <tên>` (selector), `gateway.networking.k8s.io/gateway-class-name: istio-waypoint`, `gateway.istio.io/managed: istio.io-mesh-controller`, `istio.io/dataplane-mode: none`, `sidecar.istio.io/inject: "false"`, `service.istio.io/canonical-name: <tên>`, `service.istio.io/canonical-revision: latest`, cộng `spec.infrastructure.labels` của Gateway (khoá tiền tố `gateway.networking.k8s.io/` bị bỏ) | [S21] | **Peer mesh** (`waypoint`) |
| Cổng và probe | Container `istio-proxy`: 15020 (`metrics`), 15021 (`status-port`), 15090 (`http-envoy-prom`); startup và readiness `GET /healthz/ready` cổng **15021**; nhận HBONE ở 15008; nối istiod `istiod.istio-system.svc:15012` (CA và xDS) | [S21] | **Waypoint** |
| Tuỳ biến `spec.infrastructure.parametersRef` | `group: ""`, `kind: ConfigMap`, cùng namespace với Gateway. Khoá `data` chỉ được `deployment`, `service`, `serviceAccount`, `horizontalPodAutoscaler`, `podDisruptionBudget` (khoá khác: render lỗi, không tạo gì); mỗi khoá là strategic merge patch lên object sinh ra. Replica: `deployment` với `spec.replicas`; resources, securityContext: `deployment` với `spec.template.spec`. HPA và PDB chỉ được tạo khi có khoá của nó (template sẵn: HPA `maxReplicas: 1`, PDB chỉ có selector). ConfigMap ở `istio-system` mang nhãn `gateway.istio.io/defaults-for-class: istio-waypoint` áp cho cả class, trước ConfigMap của Gateway; ConfigMap đổi thì istiod render lại Gateway trỏ tới nó | [S14] | **Waypoint** |
| securityContext mặc định, PSA `restricted` | Container `istio-proxy`: `privileged: false`, `runAsUser: 1337`, `runAsGroup: 1337`, `runAsNonRoot: true`, `allowPrivilegeEscalation: false`, `readOnlyRootFilesystem: true`, `capabilities.drop: [ALL]`; không securityContext mức pod; `seccompProfile` chỉ có khi values `gateways.seccompProfile` của chart `istiod` đặt (áp mọi template gateway). `restricted` đòi seccomp `RuntimeDefault` hay `Localhost`, nên mặc định **không đạt**; đạt khi `gateways.seccompProfile: {type: RuntimeDefault}` hay patch `deployment` đặt `spec.template.spec.securityContext.seccompProfile.type: RuntimeDefault`. Volume (emptyDir, downwardAPI, projected, configMap) đều được `restricted` cho | [S15], [S21] | **Waypoint** |
| Resources mặc định | `global.waypoint.resources`: requests 100m CPU, 128Mi; limits 2 CPU, 1Gi | [S21] | **Waypoint** |

### (4) PeerAuthentication, AuthorizationPolicy

| Sự thật | Giá trị ở 1.32.0 | Nguồn | Dựa vào |
| --- | --- | --- | --- |
| `PeerAuthentication` STRICT theo `selector` | ztunnel thực thi PeerAuthentication; `DISABLE` bị bỏ qua. Mã: policy STRICT hiệu lực (mesh, namespace hay `selector`) làm workload trỏ policy tĩnh `istio-system/istio_converted_static_strict`, DENY khi kết nối không có principal; nhiều policy `selector` chọn cùng pod thì policy cũ nhất thắng; `portLevelMtls` sinh policy riêng | [S16], [S18] | **mTLS STRICT** |
| `AuthorizationPolicy` `selector` (L4, ztunnel đích) | Dùng được: `principals`, `notPrincipals`, `namespaces`, `notNamespaces`, `ipBlocks`, `notIpBlocks`, `ports`, `notPorts`, và `when` trên `source.ip`, `source.namespace`, `source.principal`, `destination.ip`, `destination.port`. Rule ALLOW có thuộc tính L7 bị bỏ qua, nên không ai vào; không policy nào thì ALLOW; có policy ALLOW thì chỉ khớp mới vào | [S16] | **AuthorizationPolicy** (L4) |
| `AuthorizationPolicy` `targetRefs` Service (waypoint) | Waypoint của Service thực thi; policy phải ở namespace của Service (`PolicyTargetReference.namespace`: "cross namespace referencing is not currently supported"). Waypoint gắn policy khi namespace của policy bằng namespace của Service (`ShouldAttachPolicy`), không xét namespace của waypoint: policy ở `svp` cho Service dùng waypoint ở `svp-mesh` được áp. Waypoint bỏ qua policy `selector` | [S17], [S18] | **AuthorizationPolicy** (L7) |
| Nguồn ztunnel đích thấy khi có waypoint | Danh tính của waypoint (`cluster.local/ns/svp-mesh/sa/waypoint`), không phải client: "Waypoint proxies do not impersonate the identity of the source workload" | [S16] | **AuthorizationPolicy** |

### (5) GAMMA, plugin Gateway API của Argo Rollouts

| Sự thật | Giá trị | Nguồn | Dựa vào |
| --- | --- | --- | --- |
| `GRPCRoute` `parentRefs` Service, waypoint thực thi | Tài liệu: bảng route của waypoint chỉ ghi `HTTPRoute` (Beta), `TLSRoute`, `TCPRoute` (Alpha). Mã 1.32.0 thắng: `GRPCRouteCollection` dựng route mesh cho `parentRefs` kind Service (nhánh mesh của `computeRoute`, dùng chung với HTTPRoute); listener waypoint báo `supportedKinds` `HTTPRoute` và `GRPCRoute`; `SupportedFeatures` gồm mọi tính năng Gateway API trừ backend client certificate, misdirected request, UDPRoute; hai `backendRefs` có `weight` thành weighted clusters (`route.go`). CRD `grpcroutes` tối thiểu bundle v1.1.0; Envoy Gateway v1.9.3 cài v1.6.1. Conformance ambient chạy profile MeshHTTP và GatewayGRPC, không có profile mesh gRPC | [S17], [S19], [S22] | **Canary gRPC theo request** |
| Plugin v0.17.0 (asset ghim ở `base/argo-rollouts.yaml`) | Khoá `grpcRoute` (một tên, thành một mục của `grpcRoutes` với `useHeaderRoutes: true`), `grpcRoutes` (danh sách), `grpcRouteSelector`. `SetWeight`: `get` GRPCRoute, ở mọi rule chứa cả Service canary lẫn stable đặt weight canary `w`, stable `100 - w`, rồi `update`; thêm nhãn `rollouts.argoproj.io/gatewayapi-canary: in-progress` khi `w > 0`, gỡ khi `w = 0` (`disableInProgressLabel` tắt). Rule header chỉ khi Rollout có bước `setHeaderRoute`. Quyền cần: `get`, `update` trên `grpcroutes` (thêm `list` chỉ khi dùng selector) | [S20] | **Canary gRPC theo request** (Role `argo-rollouts`) |

### (6) Values của chart

| Sự thật | Giá trị ở 1.32.0 | Nguồn | Dựa vào |
| --- | --- | --- | --- |
| `profile: ambient` | Khoá `profile` (hay `global.profile`) của `istiod`, `cni`, `ztunnel`: bật `pilot.env.PILOT_ENABLE_AMBIENT: "true"`, `cni.ambient.enabled: true`, `meshConfig.defaultConfig.proxyMetadata.ISTIO_META_ENABLE_HBONE: "true"`, `global.variant: distroless` | [S21] | **Thành phần mesh** |
| `global.platform` | k3d: `k3s`. Trang k3d của Istio bảo đặt `k3d` (k3d với Flannel mặc định), profile đó lấy `cniConfDir: /var/lib/rancher/k3s/agent/etc/cni/net.d`, `cniBinDir: /bin`; k3s `v1.36.6+k3s1` tạo thư mục plugin ổn định `/var/lib/rancher/k3s/data/cni` và containerd chỉ tìm ở đó (lượt `verify.yml` dev-k3d 43704103160: `FailedCreatePodSandBox` "failed to find plugin \"istio-cni\" in path [/var/lib/rancher/k3s/data/cni]"). Profile `k3s` (trang của Istio: K3s với CNI kèm theo) lấy cùng `cniConfDir` và `cniBinDir: /var/lib/rancher/k3s/data/cni`; với `istiod`, `ztunnel` profile chỉ đặt khoá `cni.*` (istiod còn nhận env `PLATFORM`, chỉ `openshift`, `gcp` đổi hành vi). EKS: không có profile nền tảng (chỉ `gke`, `k3d`, `k3s`, `microk8s`, `minikube`, `openshift`), để trống; `cni` dùng mặc định `/etc/cni/net.d`, `/opt/cni/bin` | [S21], [S23], [S44] | **Thành phần mesh** |
| Khoá ghim image | `istiod`: `image` (pilot), `global.proxy.image`, `global.proxy_init.image`; `cni`: `image`; `ztunnel`: `image`; giá trị chứa `/` được dùng nguyên (ref có digest). Render: `cni`, `ztunnel` mỗi chart đúng một ref ghim; Deployment `istiod` ref pilot ghim. `base` không render workload (15 CRD, ServiceAccount `istio-reader-service-account`, ValidatingWebhookConfiguration `istiod-default-validator`), `image` chỉ là tên thuộc tính trong schema CRD; giống bản render 1.30.8 đã đối chiếu | [S21] | **Thành phần mesh**, **Ghim image waypoint** |
| (a) Image proxy trong render của `istiod` | Kind `ConfigMap`, tên `istio-sidecar-injector` (namespace `istio-system`), khoá `data.values`: một object JSON. `global.proxy.image` là khoá JSON `"image"` trong object `global.proxy`, `global.proxy_init.image` là `"image"` trong `global.proxy_init` ngay cạnh; giá trị là nguyên chuỗi đã đặt (ref đầy đủ có digest), mặc định của chart là tên trơn `proxyv2`. Template `waypoint` (`files/waypoint.yaml`, trong `data.config`) dùng nguyên giá trị khi nó chứa `/`, không thì `{{ .ProxyImage }}` istiod dựng lúc chạy (hub/`proxyv2`:tag-variant). Cùng các ref đó còn ở ConfigMap `values` (`original-values`, `merged-values`; chart ghi "modifying these values has no effect") | [S14], [S21] | **Ghim image waypoint** |
| (b) Giá trị Go template trong render | Nằm trong `data.config` của `istio-sidecar-injector` (template `sidecar`, `gateway`, `grpc-simple`, `grpc-agent`, `waypoint`, `kube-gateway`, `agentgateway`, `agentgateway-waypoint`); istiod nạp bằng `text/template` (`ParseTemplates`) và điền lúc chạy, không phải image. `image_refs` của `deploy/ci/gitops-check.sh` trên render thấy `{{ .ProxyImage }}` ×5, `{{ .ProxyInitImage }}` ×1, `{{ .AgentgatewayImage }}` ×2, ``{{ annotation .ObjectMeta `gateway.istio.io/agentgatewayImage` .Values.global.agentgateway.image }}`` ×2 | [S14], [S21] | **Ghim image waypoint** |
| (c) `busybox:1.28` | Chỉ ở template `grpc-simple` (`files/grpc-simple.yaml`, init container `grpc-bootstrap-init`). `istiod-injector-configmap.yaml` bỏ template mặc định khi `sidecarInjectorWebhook.templates` có khoá cùng tên, rồi chép các template của values vào. Đặt `grpc-simple: ""`: render ghi `grpc-simple: ""`, hết `busybox:1.28`, `image_refs` chỉ còn Go template và ref ghim. istiod nạp mỗi template bằng `template.Parse` (`parseDryTemplate`): `""` và `"{}"` đều parse và execute không lỗi (thử bằng Go 1.27.3). Template chỉ dùng cho pod có annotation `inject.istio.io/templates: grpc-simple` ở namespace bật sidecar injection | [S14], [S21] | **Ghim image waypoint** |
| Khoá của meshConfig | Values `meshConfig` của chart `istiod`, ghi vào ConfigMap `istio` khoá `mesh`. `defaultHttpRetryPolicy.attempts: 0` tắt retry toàn mesh (mặc định 2 lần với `connect-failure,refused-stream,unavailable,cancelled,retriable-status-codes`); route không tự đặt retry dùng giá trị này (`TranslateRoute`), và `GRPCRoute` không có trường retry. `enableTracing: false` (mặc định `true` ở `DefaultMeshConfig`). Access log: `accessLogFile` mặc định `""` là tắt | [S22] | **meshConfig** |
| Requests mặc định | `istiod` 500m CPU, 2048Mi (HPA min 1, max 5); `cni` 100m, 100Mi; `ztunnel` 200m, 512Mi; waypoint 100m, 128Mi (limits 2 CPU, 1Gi); `base` không có pod | [S21] | **Thành phần mesh** |
| Quyền của ztunnel, istio-cni | ztunnel: thêm `NET_ADMIN`, `SYS_ADMIN`, `NET_RAW`, `runAsUser: 0`, `allowPrivilegeEscalation: true`, hostPath `/var/run/ztunnel`; istio-cni: thêm `NET_ADMIN`, `NET_RAW`, `SYS_PTRACE`, `SYS_ADMIN`, chạy root, hostPath thư mục CNI, `/proc`, `/var/run/netns`; cả hai `priorityClassName: system-node-critical`. Chỉ PSA `privileged` nhận hai pod này | [S15], [S21] | **Namespace mesh** |

### (7) Yêu cầu của EKS

| Sự thật | Giá trị | Nguồn | Dựa vào |
| --- | --- | --- | --- |
| Tài liệu nền tảng của Istio | Trang "Platform Setup" Amazon EKS chỉ trỏ tới `aws-samples/istio-on-eks`. "Platform-Specific Prerequisites" của ambient: VPC CNI có Pod ENI trunking và SecurityGroupPolicy thì phải đặt `POD_SECURITY_GROUP_ENFORCING_MODE=standard`, không thì probe hỏng. svp-infra không dùng (`git grep` không thấy `ENABLE_POD_ENI`, `SecurityGroupPolicy`). istio-cni còn tự đặt route cho probe của pod branch ENI (`AMBIENT_ENABLE_AWS_BRANCH_ENI_PROBE` mặc định `true`, chỉ chạy khi node có `tcp_early_demux=0`) | [S8], [S23] | **Thành phần mesh** |
| Control plane tới istiod | Webhook `istio-sidecar-injector` (Mutating), `istio-validator-istio-system`, `istiod-default-validator` (Validating) gọi Service `istiod` cổng 443, `targetPort: 15017` của pod istiod. Rule mặc định của `terraform-aws-modules/eks` v21.29.0 từ security group cluster tới node: 4443, 6443, 8443, 9443, 10251 (cộng 443, 10250 luôn có): **15017 cần rule riêng** | [S21], [S25] | Rule security group webhook istiod của svp-infra |
| Giữa các node | Rule `ingress_nodes_ephemeral` cùng module: TCP 1025–65535 giữa các node, gồm 15008, 15012, 15020, 15021: không cần rule mới | [S25] | **NetworkPolicy ambient** |
| Network policy của VPC CNI | Cần VPC CNI ≥ 1.21.0 (add-on ghim `v1.23.3-eksbuild.1`). Tối đa 24 tổ hợp cổng và giao thức cho một dải CIDR trên mọi policy (selector được dịch thành CIDR): thêm 15008 tính vào trần đó. Tài liệu AWS không nói gì về nguồn link-local của probe: **chưa kiểm**, kiểm ở buổi cloud stg (pod của `svp` Ready sau khi enrol) | [S24] | **NetworkPolicy ambient** |

### (8) Argo CD, Helm

| Sự thật | Giá trị | Nguồn | Dựa vào |
| --- | --- | --- | --- |
| Health của `gateway.networking.k8s.io/Gateway` ở Argo CD v3.5.5 | `resource_customizations/gateway.networking.k8s.io/Gateway/health.lua`: `ResolvedRefs` hay `Accepted` `False` (của Gateway hay listener) là Degraded; `Programmed` khác `True` là Progressing; chưa có status là Progressing; còn lại Healthy | [S26] | **Waypoint** |
| Status mặc định của CRD Gateway (Gateway API v1.6.1, experimental, do Envoy Gateway v1.9.3 cài) | `Accepted` và `Programmed` `Unknown`, reason `Pending`, "Waiting for controller": không controller nào nhận class thì Gateway Progressing mãi | [S28] | **Waypoint** |
| Annotation `argocd.argoproj.io/ignore-healthcheck` ở v3.5.5 | `"true"` trên con trực tiếp của Application thì health của nó không vào health của Application (`controller/health.go`, `docs/operator-manual/health.md` "Ignoring Child Resource Health Check in Applications"; hướng dẫn nâng cấp 3.1 → 3.2 đã nhắc nó) | [S26] | **Waypoint** |
| Bản Argo CD của capability EKS | **Chưa kiểm**: tài liệu AWS không ghi version upstream; đọc trường `version` của `aws eks describe-capability` ở buổi cloud. Capability chưa được hiện thực ([ADR-0065](../0065-argocd-eks-capability.md)): eks hiện chạy Argo CD tự cài v3.5.5 (chart `argo-cd` 10.11.7 của `argocd/bootstrap.json`) | [S27] | **Waypoint** |
| Health của `GRPCRoute` ở v3.5.5 | `GRPCRoute/health.lua`: parent của generation hiện tại có `ResolvedRefs` hay `Accepted` `False` là Degraded; có condition và đúng generation là Healthy; chưa có status là Progressing | [S26] | **Canary gRPC theo request** |
| `--wait` của Helm v4.3.1 với Gateway chưa có controller | Không chờ. `Wait` dùng kstatus của `github.com/fluxcd/cli-utils` v1.2.2: Gateway không phải kind có luật riêng, status không có `observedGeneration`, condition không có `Reconciling`, `Stalled`, `Ready`, nên kết quả là `Current` ("Resource is current") | [S28] | **Waypoint** (đường dev `wait: true`) |
| Trường webhook istiod tự vá | `istiod-default-validator` (chart `base`) và `istio-validator-istio-system` (chart `istiod`): `.webhooks[].clientConfig.caBundle` và `.webhooks[].failurePolicy` (render `Ignore` khi không phải upgrade, istiod đổi thành `Fail` khi sẵn sàng); `istio-sidecar-injector` (Mutating): `.webhooks[].clientConfig.caBundle`. Values `base.validationFailurePolicy: Fail` của cả hai chart render sẵn `Fail` (chart ghi: hợp với công cụ server-side apply), khi đó chỉ còn `caBundle` lệch | [S21], [S29] | `ignoreDifferences` của Application `istio-base`, `istiod` |

### (9) Pod khởi động trước istio-cni trên node mới

| Sự thật | Giá trị ở 1.32.0 | Nguồn | Dựa vào |
| --- | --- | --- | --- |
| Plugin đã cài, agent chưa trả lời | `cmdAdd` của plugin trả lỗi "istio-cni cmdAdd failed to contact node Istio CNI agent": sandbox không tạo được, kubelet thử lại tới khi agent chạy | [S30] | **mTLS STRICT** |
| Plugin chưa cài (DaemonSet chưa lên node mới) | Pod chạy không redirection: không annotation `enabled`, istiod không coi nó là đích HBONE, peer gửi plaintext tới nó và policy của nó không được thực thi; plaintext nó gửi tới pod STRICT bị từ chối. Agent khi lên lấy ảnh chụp pod ambient đang chạy và enrol chúng (`GetActiveAmbientPodSnapshot`, `reconcilePod`) | [S30] | **mTLS STRICT** |
| Cách Istio chặn khe đó với autoscaler | Untaint controller, tắt mặc định: người dựng node đặt taint `cni.istio.io/not-ready:NoSchedule` lúc tạo node, istiod gỡ nó khi node sẵn sàng. Tài liệu ghi hai giá trị, `pilot.taint.enabled: true` và `pilot.env.PILOT_ENABLE_NODE_UNTAINT_CONTROLLERS: "true"`. Mã chart 1.32.0 thắng: một khoá `taint.enabled: true` (hay `pilot.taint.enabled`) đã render env `PILOT_ENABLE_NODE_UNTAINT_CONTROLLERS: "true"`, `PILOT_NODE_UNTAINT_CONTROLLERS_TAINT_NAME` (bằng `taint.name`, mặc định `cni.istio.io/not-ready`) và quyền `patch` trên `nodes` ở ClusterRole của istiod; `taint.namespace` trống là namespace của istiod (istio-cni cùng `istio-system`: để trống). Deployment `istiod` luôn tolerate `cni.istio.io/not-ready` (`operator: Exists`), kể cả khi tắt. `cni.repair` chỉ cho sidecar | [S30] | **mTLS STRICT** (`taint.enabled`) |
| Điều kiện gỡ taint | Controller chạy ở bản istiod giữ leader election, chỉ xét node đang mang taint; gỡ khi node có pod nhãn `k8s-app: istio-cni-node` Ready ở namespace của istio-cni và, ở ambient (`PILOT_NODE_UNTAINT_CHECK_ZTUNNEL` mặc định `true`), pod `app: ztunnel` Ready ở namespace của istiod hay của `trustedZtunnelNamespace`. DaemonSet `istio-cni-node`, `ztunnel` với values mặc định tolerate mọi taint `NoSchedule` (`operator: Exists`), nên lên được node mang taint | [S30] | **mTLS STRICT** |
| `startupTaints` của Karpenter v1.15.1 (version ghim ở `components.json`) | Trường `spec.template.spec.startupTaints` của NodePool: taint mà một DaemonSet sẽ gỡ; pod chờ không cần tolerate nó để Karpenter dựng node cho pod. Node AL2023 đăng ký với taint đó qua `registerWithTaints` của kubelet (nodeadm), cùng `karpenter.sh/unregistered:NoExecute`, nên không pod nào lên node trước khi taint có. NodeClaim giữ `Initialized` `Unknown` (reason `StartupTaintsExist`) tới khi taint được gỡ; Karpenter chỉ có hạn ở bước launch (5 phút) và đăng ký (15 phút), không có hạn ở bước này | [S33] | **mTLS STRICT** (`startupTaints` của NodePool) |
| Node không do Karpenter dựng | Nhóm node hệ thống `system` (EKS managed node group, `aws/modules/eks/nodes.tf` của svp-infra) không taint, không nhãn riêng, và pod của `svp` ở mã [S34] không có `nodeSelector`, affinity hay toleration nào (`git grep` ở chart `svp-service` và ở `base/`, `platforms/`, `envs/` của svp-gitops), nên lên được đó: node hệ thống mới (đổi AMI, thay node hỏng) còn khe trên. Taint `cni.istio.io/not-ready` đặt lên nhóm đó thì mọi pod phải chạy trước Istio (add-on, Argo CD, Karpenter; Istio do Argo CD cài) phải tolerate nó. k3d: node có trước Istio | [S34] | **mTLS STRICT** (pod của `svp` chỉ lên node Karpenter trên EKS) |
| Nhãn `karpenter.sh/nodepool` của Karpenter v1.15.1 | Mọi NodeClaim Karpenter dựng mang nhãn `karpenter.sh/nodepool: <tên NodePool>` và yêu cầu `In [<tên>]` (`NewNodeClaimTemplate`); lúc đăng ký, Karpenter chép nhãn của NodeClaim lên Node (`syncNode`) trong cùng patch gỡ taint `karpenter.sh/unregistered:NoExecute`, nên không pod nào lên node trước khi nhãn có. Pod chờ có `nodeAffinity` bắt buộc `karpenter.sh/nodepool` `Exists` khớp NodePool `default` (giao của `Exists` với `In [default]` là `default`, `Requirement.Intersection`), nên Karpenter dựng node cho nó; kube-scheduler chỉ đặt pod đó lên node mang khoá nhãn này ("Exists: A label with this key exists on the object"), nên không bao giờ lên nhóm `system`. Chiều ngược `DoesNotExist` thì Karpenter không dựng node (`validateKarpenterManagedLabelCanExist`) | [S33], [S35] | **mTLS STRICT** (`nodeAffinity` của pod `svp` trên EKS) |

### (10) port-forward và cách ztunnel đóng kết nối

| Sự thật | Giá trị ở 1.32.0 | Nguồn | Dựa vào |
| --- | --- | --- | --- |
| `kubectl port-forward` tới pod ambient | Không qua ztunnel: containerd v2.4.2 dial `localhost:<port>` trong network namespace của pod, và luật trong pod không chuyển đích `127.0.0.1` hay ra `lo` (`! -d 127.0.0.1/32` ở PREROUTING, `-o lo -j ACCEPT` ở OUTPUT); PeerAuthentication, AuthorizationPolicy không áp | [S8], [S31] | **Ca drill mesh** |
| App trong pod bị bắt mở kết nối ra | TCP tới mọi đích không phải loopback vào ztunnel 15001 trong pod: `connect` xong ngay. ztunnel nối upstream rồi mới chép dữ liệu; nối hỏng thì nó bỏ socket của app (đóng: FIN, hay RST khi còn byte của app chưa đọc; đường này không đặt zero linger) | [S32] | **Đóng/mở trong ambient** |
| AuthorizationPolicy đích từ chối | ztunnel đích trả 401 cho CONNECT của HBONE; ztunnel nguồn không thử lại lỗi 4xx và đóng socket của app ngay | [S32] | **Đóng/mở trong ambient**, **Ca drill mesh** (M-3) |
| Đích không trả lời (NetworkPolicy chặn, đích ngoài mesh không trả lời) | Hạn nối upstream `CONNECTION_TIMEOUT` = 10 s, hằng số (`src/proxy.rs`); thử lại `OUTBOUND_CONNECT_MAX_RETRIES` mặc định 0, và có thử lại thì tổng vẫn tính từ lúc bắt đầu tới 10 s (`connect_with_retries`). Socket của app bị đóng sau tối đa ~10 s. App đích từ chối: ztunnel đích trả 503, đóng ngay | [S32] | **Đóng/mở trong ambient** (W > 10 s) |
| Client plaintext vào pod STRICT | Client ngoài mesh (hay `istio.io/dataplane-mode: none`): PREROUTING của pod đích chuyển sang ztunnel 15006, bắt tay TCP xong, rồi policy STRICT (không principal) từ chối và socket bị đóng ngay, không chờ hạn. Client trong mesh luôn đi HBONE (mTLS) nên qua STRICT; chỉ AuthorizationPolicy từ chối được (401 như trên) | [S8], [S32] | **Đóng/mở trong ambient**, **Ca drill mesh** (M-1) |

### Nguồn

Đọc ngày 2026-11-15. Mã nguồn đọc ở tag, commit trong ngoặc.

- [S1] Istio, "Supported Releases": <https://istio.io/latest/docs/releases/supported-releases/>
- [S2] Istio 1.32.0: <https://github.com/istio/istio/releases/tag/1.32.0>;
  <https://istio.io/latest/news/releases/1.32.x/announcing-1.32/>
- [S3] Istio 1.31 Upgrade Notes, "Deprecation of GCP infrastructure and hosting":
  <https://istio.io/latest/news/releases/1.31.x/announcing-1.31/upgrade-notes/>
- [S4] Index chart: <https://blob.istio.io/istio-release/charts/index.yaml>;
  <https://istio-release.storage.googleapis.com/charts/index.yaml>
- [S5] Istio, "Install with Helm" (ambient): <https://istio.io/latest/docs/ambient/install/helm/>
- [S6] Istio, "Ambient and Kubernetes NetworkPolicy": <https://istio.io/latest/docs/ambient/usage/networkpolicy/>
- [S7] Istio, "Ztunnel traffic redirection": <https://istio.io/latest/docs/ambient/architecture/traffic-redirection/>
- [S8] `istio/istio` tag `1.32.0` (`19cc19624069`): `cni/pkg/nodeagent/options.go`, `meshdataplane_linux.go`,
  `brancheni_linux.go`, `cni/pkg/iptables/iptables.go`: <https://github.com/istio/istio/tree/1.32.0/cni/pkg>
- [S9] `envoyproxy/gateway` tag `v1.9.3` (`ec0171b20585`): `internal/xds/bootstrap/bootstrap.go`,
  `internal/cmd/envoy/shutdown_manager.go`, `internal/infrastructure/kubernetes/proxy/resource.go`,
  `api/v1alpha1/shared_types.go`: <https://github.com/envoyproxy/gateway/tree/v1.9.3>
- [S10] Kubernetes, "Network Policies": <https://kubernetes.io/docs/concepts/services-networking/network-policies/>
- [S11] `istio/api` tag `1.32.0` (`97748e4cb005`): `label/labels.yaml`, `annotation/annotations.yaml`:
  <https://github.com/istio/api/tree/1.32.0>
- [S12] Chart `cni` 1.32.0, `values.yaml` (`ambient.enablementSelectors`, `excludeNamespaces`, `ambient.dnsCapture`):
  <https://github.com/istio/istio/blob/1.32.0/manifests/charts/istio-cni/values.yaml>
- [S13] Istio, "Configure waypoint proxies": <https://istio.io/latest/docs/ambient/usage/waypoint/>
- [S14] `istio/istio` tag `1.32.0`: `pilot/pkg/config/kube/gatewaycommon/` (`classinfo.go`, `gateway_utils.go`,
  `deploymentcontroller.go`), `pilot/pkg/serviceregistry/ambient/` (`waypoints.go`, `workloads.go`),
  `pkg/config/constants/constants.go`, `pkg/kube/inject/` (`webhook.go`, `inject.go`):
  <https://github.com/istio/istio/tree/1.32.0/pilot/pkg>
- [S15] Kubernetes, "Pod Security Standards": <https://kubernetes.io/docs/concepts/security/pod-security-standards/>
- [S16] Istio, "Use Layer 4 security policy": <https://istio.io/latest/docs/ambient/usage/l4-policy/>
- [S17] Istio, "Use Layer 7 features": <https://istio.io/latest/docs/ambient/usage/l7-features/>
- [S18] `istio/istio` tag `1.32.0`: `pilot/pkg/serviceregistry/ambient/authorization.go`,
  `pilot/pkg/model/policyattachment.go`; `istio/api` tag `1.32.0`: `type/v1beta1/selector.proto`
- [S19] `istio/istio` tag `1.32.0`: `pilot/pkg/config/kube/gateway/route_collections.go`, `supported_features.go`,
  `testdata/waypoint.status.yaml.golden`, `pkg/config/schema/gatewayapi/minimumversions.go`,
  `tests/integration/ambient/gateway_conformance_test.go`
- [S20] `argoproj-labs/rollouts-plugin-trafficrouter-gatewayapi` tag `v0.17.0` (`18b8ad9d04d7`): `pkg/plugin/types.go`,
  `plugin.go`, `grpcroute.go`, `labels.go`, `internal/defaults/defaults.go`:
  <https://github.com/argoproj-labs/rollouts-plugin-trafficrouter-gatewayapi/tree/v0.17.0>
- [S21] Chart `base`, `istiod`, `cni`, `ztunnel` 1.32.0 từ `https://blob.istio.io/istio-release/charts`
  (`helm pull`), và render: `helm template istiod <chart> -n istio-system --set profile=ambient --set
  global.platform=k3d --set image=<pilot> --set global.proxy.image=<proxyv2> --set
  global.proxy_init.image=<proxyv2>`, tương tự cho `cni`, `ztunnel` (`image`) và `base`; thêm
  `sidecarInjectorWebhook.templates.grpc-simple: ""` cho (6)(c)
- [S22] `istio/api` tag `1.32.0`: `mesh/v1alpha1/config.proto`; `istio/istio` tag `1.32.0`: `pkg/config/mesh/mesh.go`,
  `pilot/pkg/networking/core/route/route.go`
- [S23] Istio, "Platform-Specific Prerequisites":
  <https://istio.io/latest/docs/ambient/install/platform-prerequisites/>; "Platform Setup", Amazon EKS:
  <https://istio.io/latest/docs/setup/platform-setup/amazon-eks/>
- [S24] AWS, "Limit Pod traffic with Kubernetes network policies":
  <https://docs.aws.amazon.com/eks/latest/userguide/cni-network-policy.html>
- [S25] `terraform-aws-modules/terraform-aws-eks` tag `v21.29.0`, `node_groups.tf`
  (`node_security_group_recommended_rules`):
  <https://github.com/terraform-aws-modules/terraform-aws-eks/blob/v21.29.0/node_groups.tf>
- [S26] `argoproj/argo-cd` tag `v3.5.5` (`a5038b0e2bba`):
  `resource_customizations/gateway.networking.k8s.io/Gateway/health.lua`, `GRPCRoute/health.lua`,
  `controller/health.go`, `common/common.go`, `docs/operator-manual/health.md`,
  `docs/operator-manual/upgrading/3.1-3.2.md`: <https://github.com/argoproj/argo-cd/tree/v3.5.5>
- [S27] AWS, "Argo CD considerations": <https://docs.aws.amazon.com/eks/latest/userguide/argocd-considerations.html>
- [S28] `helm/helm` tag `v4.3.1` (`c0d08d0d6d94`): `pkg/kube/statuswait.go`; `fluxcd/cli-utils` tag
  `v1.2.2` (`5620149f28a2`): `pkg/kstatus/status/status.go`, `generic.go`, `core.go`; CRD Gateway API v1.6.1 ở
  `envoyproxy/gateway` `v1.9.3`: `charts/gateway-helm/charts/crds/crds/gatewayapi-crds.yaml`
- [S29] `istio/istio` tag `1.32.0`: `pkg/webhooks/validation/controller/controller.go`,
  `pkg/webhooks/webhookpatch.go`; template `validatingwebhookconfiguration.yaml` của chart `istiod`,
  `defaultrevision-validatingwebhookconfiguration.yaml` của chart `base`
- [S30] Istio, "Install the Istio CNI node agent" (Race condition & mitigation, Untaint controller):
  <https://istio.io/latest/docs/setup/additional-setup/cni/>; `istio/istio` tag `1.32.0`:
  `cni/pkg/plugin/plugin.go`, `cni/pkg/nodeagent/informers.go`, `pilot/pkg/serviceregistry/ambient/workloads.go`,
  `pilot/pkg/controllers/untaint/nodeuntainter.go`, `pilot/pkg/features/pilot.go`, `pilot/pkg/bootstrap/server.go`;
  chart `istiod` `values.yaml` (`taint`), `templates/deployment.yaml`, `templates/clusterrole.yaml` và render với
  `--set taint.enabled=true`; `values.yaml` (`tolerations`) của chart `cni`, `ztunnel`
- [S31] `containerd/containerd` tag `v2.4.2`, `internal/cri/server/sandbox_portforward_linux.go`:
  <https://github.com/containerd/containerd/blob/v2.4.2/internal/cri/server/sandbox_portforward_linux.go>
- [S32] `istio/ztunnel` tag `1.32.0` (`82d679bb9313`): `src/proxy.rs`, `src/proxy/outbound.rs`, `src/proxy/inbound.rs`,
  `src/proxy/inbound_passthrough.rs`, `src/config.rs`, `src/inpod/statemanager.rs`, `src/dns/forwarder.rs`:
  <https://github.com/istio/ztunnel/tree/1.32.0>
- [S33] `kubernetes-sigs/karpenter` tag `v1.15.1` (`8fb3abde2be3`): `pkg/apis/v1/nodepool.go`, `nodeclaim.go`,
  `labels.go`, `pkg/controllers/nodeclaim/lifecycle/registration.go`, `initialization.go`, `liveness.go`,
  `pkg/controllers/provisioning/provisioner.go`, `scheduling/nodeclaimtemplate.go`, `pkg/scheduling/requirement.go`;
  `aws/karpenter-provider-aws` tag `v1.15.1` (`2b6449d0a2d8`): `go.mod`,
  `pkg/providers/amifamily/bootstrap/nodeadm.go`, `pkg/providers/amifamily/resolver.go`:
  <https://github.com/kubernetes-sigs/karpenter/tree/v1.15.1>
- [S34] Mã của dự án trên `main`: svp-infra `aws/modules/eks/nodes.tf` (`83daee7`); svp-backend
  `deploy/helm/svp-service/` (`79867b9`); svp-gitops `base/`, `platforms/`, `envs/` (`567dfca`)
- [S35] Kubernetes, "Assigning Pods to Nodes" (Operators):
  <https://kubernetes.io/docs/concepts/scheduling-eviction/assign-pod-node/>
- [S44] `k3s-io/k3s` tag `v1.36.6+k3s1` (`fa45d6a5ad0c`): `cmd/k3s/main.go` (`cniPath`, thư mục plugin CNI ổn định):
  <https://github.com/k3s-io/k3s/blob/v1.36.6%2Bk3s1/cmd/k3s/main.go>; `istio/istio` tag `1.32.0`: `pkg/platform/platform.go`

## Phương án

Nguồn đọc ngày 2026-11-15 (mục [Nguồn phương án](#nguồn-phương-án) và [Nguồn](#nguồn) của sự thật); trích dẫn giữ
nguyên tiếng Anh. In đậm là lựa chọn. Trạng thái ngành: hiện hành, cũ hay mới nổi.

### Mesh

| Phương án | Trạng thái ngành | Được | Mất | Nguồn |
| --- | --- | --- | --- | --- |
| **Istio ambient** (ztunnel mỗi node, waypoint Envoy chỉ nơi cần L7) | Hiện hành: "Stable, only single-cluster", "production-ready for single cluster use cases" từ 1.22; GA ở 1.24 (2024-11-07, phụ lục ADR-0042 [N3]); 1.32.0 hỗ trợ tới ~Jun 2027 | mTLS L4 ở ztunnel, không container thêm trong pod, "Label a namespace - no pod restart required"; L7 "1 (destination waypoint)" bước; waypoint "can be auto-scaled like any other Kubernetes deployment" | ztunnel, istio-cni cần PSA `privileged` (sự thật (6)); L7 thêm một chặng Envoy; chưa có ở ambient: multi-cluster, multi-network, VM, sidecar ↔ waypoint | [S36], [S1] |
| Istio sidecar (Envoy trong mọi pod) | Hiện hành, cũ hơn ambient: "Stable, including multi-cluster"; "well understood and thoroughly battle-tested" | L4 và L7 ở mọi proxy, đủ tính năng nhiều cluster | "comes with a resource cost and operational overhead"; "Wasteful; CPU and memory resources must be provisioned for worst case usage of each individual pod"; "restart all pods to have sidecars added"; container `proxyv2` vào mọi pod của `svp`, nơi Kyverno chỉ nhận image phát hành đã ký | [S36] |
| Linkerd (proxy sidecar mỗi pod) | Hiện hành nhưng mã nguồn mở chỉ còn edge (edge-26.11.2): "As of February 2024, the Linkerd open source project itself no longer provides stable release artifacts"; stable 2.20 (2026-06-23) do nhà cung cấp | Tự cân tải HTTP/2, gRPC theo request ("without any configuration required", EWMA) | "micro-proxies which are deployed as sidecar containers inside application pods": cùng cái giá tài nguyên và Kyverno như sidecar; bản stable cần nhà cung cấp | [S37], [S38] |
| Cilium (CNI eBPF, mutual authentication SPIFFE) | Mới nổi cho mTLS: "Mutual Authentication (Beta)", "still in development and considered beta"; "Ztunnel Transparent Encryption (Beta)" | Một thành phần cho CNI, NetworkPolicy và mesh | Thay Flannel của k3d; trên EKS chaining với VPC CNI: "Layer 7 Policy" và "IPsec Transparent Encryption" "may be limited", pod có sẵn "Policy enforcement will also not be applied"; hai cấu hình CNI theo nền tảng | [S39], [S40], [S41] |

### Cân tải gRPC

| Phương án | Trạng thái ngành | Được | Mất | Nguồn |
| --- | --- | --- | --- | --- |
| **Waypoint L7** (proxy cân tải) | Hiện hành: L7 LB "can distribute the streams from one client among multiple backends" | "Simple client", "Works with untrusted clients"; trọng số theo request của `GRPCRoute` cho canary; code không đổi | "LB is in the data path", "Higher latency"; một Deployment dùng chung | [S42], sự thật (5) |
| Client `round_robin` qua Service headless (`dns:///`) | Hiện hành: cân tải của gRPC "happens on a per-call basis"; `round_robin` gửi "each successive RPC to the next successive subchannel" | "High performance because elimination of extra hop" | "Complex client", "Client needs to be trusted"; chia đều theo subchannel nên không có trọng số canary theo request (canary vẫn theo số pod như ADR-0072 §8); mTLS vẫn cần lớp khác | [S42], [S43] |
| Chỉ `MaxConnectionAge` (hiện trạng) | `pick_first` là mặc định: "all RPCs sent on the channel will be sent to that address" | Không thêm gì | Chia theo kết nối và số pod, gần đúng; release ít được gọi thường Inconclusive (ADR-0072 §8) | [S43] |

### Chỗ đặt waypoint

| Phương án | Được | Mất | Nguồn |
| --- | --- | --- | --- |
| **Một waypoint chung ở namespace riêng `svp-mesh`** | `ImageValidatingPolicy` `svp-images` của `svp` giữ nguyên (chỉ image phát hành đã ký, `deploy/helm/svp-policy/templates/imagevalidatingpolicy.yaml`); một Deployment; listener HBONE chọn đúng namespace `svp`; policy L7 ở `svp` vẫn áp | Nhãn `istio.io/use-waypoint-namespace` mới Beta; một chỗ hỏng chung cho bốn Service | Sự thật (3), (4); [S11], [S13] |
| Waypoint của namespace `svp` | Không cần nhãn khác namespace | Pod `proxyv2` (image của Istio, không do repo phát hành) trong `svp`: phải thêm ngoại lệ cho Kyverno | `svp-images` |
| Mỗi Service một waypoint | Hỏng một waypoint chỉ chạm một Service | Bốn Deployment (tám ở EKS với hai replica), RAM và cấu hình gấp bốn | Sự thật (3) |

### Namespace của ztunnel, istio-cni

| Phương án | Được | Mất | Nguồn |
| --- | --- | --- | --- |
| **`istio-system` PSA `privileged`** | Namespace của cách cài bằng Helm của Istio; policy `svp-registry-mirror` của Kyverno áp (image kéo qua pull-through cache ECR ở EKS, ADR-0062) | Thêm một namespace `privileged` (IN-14 của threat model) | [S5]; `deploy/helm/svp-policy/templates/mutatingpolicy.yaml` |
| `kube-system` | Namespace hệ thống sẵn có | Kyverno bỏ `kube-system` khỏi mọi webhook nó đăng ký (namespaceSelector của ConfigMap): không mirror, image kéo thẳng từ Docker Hub | `mutatingpolicy.yaml`, `imagevalidatingpolicy.yaml` |

### Nơi chạy mesh

| Phương án | Được | Mất |
| --- | --- | --- |
| **k3d (đường dev và GitOps) và EKS** | Một danh sách `components.json` (ADR-0037); policy của chart chạy trong drill k3d trước buổi cloud; NetworkPolicy, PeerAuthentication, AuthorizationPolicy cùng một bản ở mọi cluster | RAM trên máy 16 GB; đo trên runner |
| Chỉ đường GitOps của k3d | Đường dev nhẹ hơn | Hai danh sách thành phần (`gitopsOnly`); đường dev không có CRD Istio nên chart cần cờ tắt policy mesh, drill khác nhau theo đường |
| Chỉ EKS (ADR-0042 §4) | Không đổi RAM k3d | Policy mesh chỉ chạy trong buổi cloud tính tiền; chart cần cờ bật tắt mesh theo nền tảng, trái ADR-0037 |

## Số đo

Ngày 2026-11-15. Request, limit là giá trị cấu hình (`base/`, `platforms/eks/` của `svp-gitops` ở nhánh
`feat/m1-service-mesh`, khoá `waypoint` của `deploy/helm/svp-cluster/values.yaml`), không phải số đo.

| Thành phần | k3d request (limit) | Số pod k3d | EKS request (limit) | Mặc định của chart (sự thật (6)) |
| --- | --- | --- | --- | --- |
| istiod | 10m, 100Mi (512Mi) | 1 | 500m, 2048Mi (2048Mi), 2 replica | 500m, 2048Mi |
| istio-cni | 10m, 40Mi (256Mi) | 1 mỗi node | 100m, 100Mi (256Mi) | 100m, 100Mi |
| ztunnel | 10m, 40Mi (256Mi) | 1 mỗi node | 200m, 512Mi (512Mi) | 200m, 512Mi |
| waypoint | 50m, 64Mi (1 CPU, 256Mi) | 1 | như k3d, 2 replica | 100m, 128Mi (2 CPU, 1Gi) |

- Tổng request trên k3d 1 server + 1 agent (ADR-0014 §2): 100 + 2 × 40 + 2 × 40 + 64 = 324 MiB; tổng limit
  512 + 2 × 256 + 2 × 256 + 256 = 1 792 MiB. Cùng cụm, request mặc định của chart: 2 048 + 2 × 100 + 2 × 512 + 128 =
  3 400 MiB.
- RAM dùng thật: **chưa đo**. Đo ở lượt `dev-k3d` đầu tiên của `verify.yml` (dòng `RESULT mesh-memory` của
  `make drill-k8s-mesh`, `logs/drill-k8s-mesh.results.log`), cộng vào RAM nghỉ, so với ngân sách ADR-0014 §2; trên node
  EKS ở buổi stg.
- Độ trễ mesh: **chưa đo**. Đo ở buổi stg dưới k6, theo định nghĩa ở mục Hệ quả của ADR.

## Nguồn phương án

Đọc ngày 2026-11-15.

- [S36] Istio, "Sidecar or ambient?" (tài liệu 1.32): <https://istio.io/latest/docs/overview/dataplane-modes/>
- [S37] Linkerd, "Releases and Versions": <https://linkerd.io/releases/>
- [S38] Linkerd, "Load Balancing": <https://linkerd.io/2-edge/features/load-balancing/>; "Architecture":
  <https://linkerd.io/2-edge/reference/architecture/>
- [S39] Cilium, "Mutual Authentication (Beta)":
  <https://docs.cilium.io/en/stable/network/servicemesh/mutual-authentication/mutual-authentication/>
- [S40] Cilium, "Transparent Encryption": <https://docs.cilium.io/en/stable/security/network/encryption/>
- [S41] Cilium, "AWS VPC CNI plugin" (chaining): <https://docs.cilium.io/en/stable/installation/cni-chaining-aws-cni/>
- [S42] gRPC, "gRPC Load Balancing": <https://grpc.io/blog/grpc-load-balancing/>
- [S43] gRPC, "Load Balancing in gRPC": <https://github.com/grpc/grpc/blob/master/doc/load-balancing.md>
