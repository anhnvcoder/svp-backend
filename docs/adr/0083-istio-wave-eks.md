# 0083. Bốn release Istio cùng sync wave 1 với `svp-cluster`, để istiod gỡ startup taint của node Karpenter trên EKS

- Trạng thái: Chấp nhận
- Ngày: 2026-11-24
- Người quyết: AI quyết thay người học theo uỷ quyền (2026-11-24: sửa deadlock thứ tự wave của buổi stg đầu tiên trên EKS)

## Bối cảnh và vấn đề

- [0075](0075-service-mesh.md) §1 đặt `istio-base` ở wave 2, `istiod` 3, `istio-cni`, `ztunnel` 4, sau `svp-cluster` (1). Root `svp-apps`
  chỉ sang wave kế khi mọi Application của wave trước Healthy [N1].
- 0075 §6: NodePool `default` của Karpenter đăng ký node với startup taint `cni.istio.io/not-ready:NoSchedule` [N3]; istiod
  (`taint.enabled: true`) gỡ taint khi istio-cni và ztunnel đã Ready trên node [N2].
- Chart `svp-cluster` (wave 1) chứa Gateway `svp`; Gateway chỉ `Programmed` khi pod Envoy của nó chạy, và trên EKS pod Envoy chỉ lên node
  Karpenter (`envoy.nodeAffinity` ở `platforms/eks/svp-cluster.yaml`). `svp-cluster` chờ Envoy, Envoy chờ taint được gỡ, taint chờ Istio,
  Istio chờ `svp-cluster`: vòng chờ không bao giờ hết.
- Buổi stg đầu tiên (2026-11-24): pod Envoy Pending 22 phút, Gateway `Programmed=False` (`NoResources`), root báo "waiting for healthy
  state of Application/svp-cluster". Gỡ tay: xoá taint trên node Karpenter, rồi khởi động lại Envoy khi ztunnel Healthy. k3d không có
  Karpenter và taint nên không lộ; không check tĩnh nào bắt.

## Yếu tố quyết định

- Root sync xong trên EKS không cần bước tay; đường k3d (dev và GitOps) giữ hành vi.
- Health của root và commit status `argocd/<env>` ([0032](0032-argocd-deploy-status.md)) vẫn phản ánh lối vào: Gateway `svp` phải
  `Programmed`.
- Thay đổi nhỏ, không tách chart; một check tĩnh chặn đặt lại thứ tự sai.

## Phương án đã cân nhắc

- **Istio cùng wave 1 với `svp-cluster`:** Argo CD sync song song, istiod gỡ taint trong lúc `svp-cluster` còn chờ Gateway; chỉ đổi bốn số
  wave. Mất: trong một wave Argo CD không xếp thứ tự, nên mọi thứ tự của năm Application phải dựng được (§2).
- Istio ở wave 0, trước `svp-cluster`: namespace `istio-system` và nhãn PSA `privileged` vẫn do `svp-cluster` (wave 1) tạo; trên k3d (mặc
  định `restricted`) pod istio-cni, ztunnel bị từ chối, wave 0 không bao giờ Healthy: deadlock chuyển sang k3d.
- Gateway `svp` sang Application riêng ở wave sau Istio: phải tách chart `svp-cluster` (Gateway, `EnvoyProxy`, chính sách đi kèm) và thêm
  component; đổi lớn hơn cho cùng kết quả.
- Bỏ health của Gateway `svp` (`argocd.argoproj.io/ignore-healthcheck` như waypoint): `svp-cluster` Healthy ngay, nhưng root và
  `argocd/<env>` báo Healthy khi lối vào chưa `Programmed`: mất tín hiệu của 0032.
- Bỏ startup taint: pod lên node trước istio-cni thì chạy ngoài mesh [N2], trái mTLS STRICT của 0075 §6.

## Kết quả quyết định

Chọn Istio cùng wave 1 với `svp-cluster`, vì hết vòng chờ chỉ bằng dữ liệu thứ tự, giữ health thật của lối vào và không tách chart.

### 1. Wave

`istio-base`, `istiod`, `istio-cni`, `ztunnel` có `wave: 1` trong `argocd/apps/components.json` của `svp-gitops`, cùng `svp-cluster`;
mọi component khác giữ wave; Istio vẫn trước các release (7). Waypoint giữ `ignore-healthcheck` (0075 §3): health của nó đọc ở Deployment.

### 2. Mọi thứ tự trong wave 1 đều dựng được

- `istio-system`: Application Istio sync trước thì `CreateNamespace` tạo namespace không nhãn theo Pod Security mặc định của cluster, rồi
  `svp-cluster` gắn `privileged`. EKS mặc định `privileged`: pod lên ngay. k3d mặc định `restricted`: pod istio-cni, ztunnel bị từ chối
  tới khi có nhãn, rồi DaemonSet controller tạo lại. `svp-cluster` sync trước thì namespace đã có nhãn.
- CRD của `istio-base`: render của `istiod`, `istio-cni`, `ztunnel` chỉ có kind lõi (Deployment, DaemonSet, ConfigMap, RBAC, webhook,
  PDB), không cần CRD của mesh; lỗi thoáng qua có `retry` của Application. `svp-cluster` không render object `*.istio.io`, nên webhook
  `Fail` của `istio-base` không chặn wave 1; policy mesh ở chart `svp-service` (wave 7).
- Không release Istio nào render kind mà CRD tới ở wave sau (ServiceMonitor, policy Kyverno), đã kiểm trên `base/`, `platforms/k3d/`,
  `platforms/eks/` và overlay của `envs/stg`, `envs/prd`.

### 3. Luật wave của startup taint

Trên nền tảng `eks`, component có pod chỉ lên node Karpenter (node mang startup taint) phải có wave ≥ wave của từng component gỡ taint:
`istiod` (values `taint.enabled: true`), `istio-cni`, `ztunnel`. Cùng wave hợp lệ, nhỏ hơn là lỗi. Pin có hai dạng, ở mọi độ sâu của
values: node affinity term bắt buộc với key `karpenter.sh/nodepool` và `operator` `Exists` hay `In` (`DoesNotExist` và term `preferred`
không tính), hoặc `nodeSelector` có key đó (key khác như `kubernetes.io/arch` không tính). Values đọc theo chuỗi `base/<tên>.yaml`,
`platforms/eks/<tên>.yaml`, rồi overlay `envs/<env>/<tên>.yaml` của mỗi env chạy trên `eks`; một file trong chuỗi pin là pin (luật thận
trọng: không suy luận file sau gỡ pin), và lỗi do overlay nêu tên env. Policy conftest `waves.rego` trong package `gitops.platforms`
của `deploy/ci/gitops-tree-policies/` kiểm luật này ở bước 1 của `deploy/ci/gitops-check.sh`, tức trong `make helm-check` và CI của
repo này; PR của `svp-gitops` chỉ chịu luật sau khi `check.yml` của nó nâng bản checker ghim lên bản có luật này. Thông báo nêu
component (kèm env khi chỉ overlay của env đó pin), wave của nó và wave của component gỡ taint.

### 4. Đường k3d

GitOps trên k3d dùng cùng `components.json`; node k3d không có taint nên chỉ thấy pod Istio bị PSA từ chối vài lần như §2. Đường dev
(`make k8s-up`, helmfile) chỉ `needs` release của wave trước: bốn release Istio `needs` thêm `svp-cluster` để namespace `istio-system`
có trước, như `reloader` với `argo-rollouts`.

### Hệ quả

- Tốt: root sync xong trên EKS không bước tay; health của root, `argocd/<env>` giữ nghĩa; check tĩnh đỏ khi thứ tự sai trở lại.
- Xấu: wave 1 không còn thứ tự giữa mesh và namespace của nó (§2); trên EKS pod Istio tạo trước `svp-registry-mirror` (wave 3) nên kéo
  image từ registry gốc qua NAT tới lần tạo lại, như mọi pod tạo trước policy ([0062](0062-ecr-registry-ci-oidc.md) §8); wave 1 dài hơn.
- Xem lại khi: thêm node pool hay taint khởi động khác, hay component khác gỡ taint; Istio đổi cách gỡ taint; tách chart `svp-cluster` vì
  lý do khác (khi đó Gateway sang wave sau Istio).

## Xác nhận

- Kiểm tĩnh: `jq` trên `components.json` in bốn release Istio ở wave 1; `deploy/ci/gitops-check.sh --root ../gitops` (cả `waves.rego`)
  exit 0; `make conftest-verify` (`waves_test.rego`: cây với wave cũ 2, 3, 4 bị từ chối nêu `svp-cluster`, cả pin bằng `nodeSelector`
  và pin chỉ ở overlay của một env; k3d, component không gắn node Karpenter không bị xét); `argocd/apps/cluster-contract-test.sh`,
  `argocd/root/application-health-test.sh` của `svp-gitops`.
- Buổi stg sau: root qua wave 1 không gỡ taint tay; node Karpenter mất taint sau khi istio-cni, ztunnel Ready; pod Envoy Running, Gateway
  `Programmed`; ghi phút của wave 1.

## Hiện thực ở

- `svp-gitops`: `argocd/apps/components.json` (§1); `base/istio-base.yaml`, `istiod.yaml`, `istio-cni.yaml`, `ztunnel.yaml`,
  `argocd/apps/templates/applications.yaml`, `docs/components.md` (§1, §2).
- Repo này: `deploy/ci/gitops-tree-policies/waves.rego`, `waves_test.rego`, `docs/reference/ci.md` (§3); `deploy/k8s/helmfile.yaml.gotmpl`
  (§4); `deploy/helm/svp-cluster/templates/waypoint.yaml`, `docs/explanation/deployment.md` (§1).

## Nguồn

Đọc 2026-11-24.

- [N1] Argo CD, "Sync Phases and Waves": <https://argo-cd.readthedocs.io/en/stable/user-guide/sync-waves/>
- [N2] Istio, "Install the Istio CNI node agent" (Race condition & mitigation, Untaint controller):
  <https://istio.io/latest/docs/setup/additional-setup/cni/>
- [N3] Karpenter, NodePools (`startupTaints`): <https://karpenter.sh/docs/concepts/nodepools/>
