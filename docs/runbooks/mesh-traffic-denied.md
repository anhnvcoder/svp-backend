# Lời gọi trong mesh bị từ chối

Không có cảnh báo `page` ứng với sự cố này nên không có `runbook_url`; mở runbook khi
một lời gọi giữa các workload của namespace `svp` thất bại sau khi mesh Istio ambient
([ADR-0075](../adr/0075-service-mesh.md)) vào cluster, hay khi `make drill-k8s-mesh` đỏ.

## Ý nghĩa và tác động tới người dùng

Mesh áp hai lớp lên mọi pod của `svp`: mTLS STRICT (ztunnel không nhận plaintext) và `AuthorizationPolicy` theo ServiceAccount
(gRPC chỉ qua waypoint, từng peer chỉ đúng `ingressFrom` của release). Lời gọi vi phạm bị từ chối, và client thấy:

- gRPC `PERMISSION_DENIED` hay HTTP 403 (RBAC của waypoint): danh tính gọi không được `<release>-waypoint` cho phép.
- Kết nối bị đóng hay reset ngay, gRPC `UNAVAILABLE`: ztunnel từ chối (plaintext vào pod STRICT, danh tính không được
  `AuthorizationPolicy` `<release>` cho phép, gọi thẳng IP pod bỏ qua waypoint).
- Kết nối treo rồi đóng sau khoảng 10 s (hạn nối upstream của ztunnel): NetworkPolicy chặn, không phải policy của mesh.

Người dùng thấy lỗi ở request đi qua cặp gateway → service gRPC bị từ chối (đăng nhập, feed, upload, like). Service không dính cặp đó
vẫn chạy. Mesh không đổi thứ gì ở compose: compose không có lớp này.

## Kiểm tra nhanh (5 phút)

**Compose:** Không có, vì compose không có mesh ([`compose.md`](../reference/compose.md)).

**k3d** (cluster `svp`; mọi lệnh `kubectl` ghi `--context k3d-svp`, không `istioctl`). Chạy theo thứ tự:

```sh
# 1. Mesh is up: istiod, istio-cni, ztunnel (one pod per node) Ready; waypoint has all its replicas.
kubectl --context k3d-svp -n istio-system get pods -o wide
kubectl --context k3d-svp -n svp-mesh get deploy,pod

# 2. Ambient captured the caller and the callee: column REDIRECTION must read "enabled".
kubectl --context k3d-svp -n svp get pod -o custom-columns=NAME:.metadata.name,SA:.spec.serviceAccountName,\
REDIRECTION:'.metadata.annotations.ambient\.istio\.io/redirection',MODE:'.metadata.labels.istio\.io/dataplane-mode'

# 3. The gRPC Service points to the waypoint and the policies rendered as expected.
kubectl --context k3d-svp -n svp get svc <release> -o jsonpath='{.metadata.labels}{"\n"}'
kubectl --context k3d-svp -n svp get peerauthentication,authorizationpolicy
kubectl --context k3d-svp -n svp get authorizationpolicy <release> <release>-waypoint -o yaml

# 4. Logs where the call was denied: every ztunnel pod (caller's and callee's node), then every waypoint replica.
kubectl --context k3d-svp -n svp get pod <pod đích> -o jsonpath='{.status.podIP}{"\n"}'
kubectl --context k3d-svp -n istio-system logs -l app=ztunnel --prefix --since=15m --tail=-1 \
  | grep -i -e <ip pod đích> -e denied -e 401
kubectl --context k3d-svp -n svp-mesh logs -l gateway.networking.k8s.io/gateway-name=waypoint --prefix --since=15m --tail=-1
```

Cách đọc:

- Bước 1: pod không Ready thì xử lý nó trước, mọi dấu hiệu khác là hệ quả.
- Bước 2: pod thiếu `enabled` (hay mang `MODE=none`) nằm ngoài mesh, gửi plaintext và bị STRICT từ chối; pod `pending` được bắt một
  phần, chưa ztunnel nào nhận. `SA` của bên gọi là danh tính nó mang: principal `cluster.local/ns/svp/sa/<SA>`.
- Bước 3: Service gRPC phải có nhãn `istio.io/use-waypoint: waypoint` và `istio.io/use-waypoint-namespace: svp-mesh`. `AuthorizationPolicy`
  `<release>` (L4) của release gRPC chỉ liệt kê principal `cluster.local/ns/svp-mesh/sa/waypoint`; `<release>-waypoint` (L7) liệt kê principal
  của peer `ingressFrom` (gateway). Bên gọi không có trong danh sách thì bị từ chối đúng thiết kế.
- Bước 4: `-l` đọc mọi pod (mỗi node một pod ztunnel, waypoint có thể nhiều replica), tiền tố `--prefix` nêu pod ghi dòng đó
  (cột `NODE` của bước 1 cho node của pod đó); `--tail=-1` vì với `-l` kubectl chỉ in 10 dòng cuối mỗi pod. ztunnel đích trả 401 cho
  CONNECT của HBONE khi policy từ chối, ztunnel nguồn đóng socket của app; waypoint từ chối L7 bằng RBAC (403 hay `grpc-status` 7).
  Không dòng nào ở cả hai chỗ mà lời gọi vẫn treo thì lỗi ở mạng (nguyên nhân 4).

Render từ chart để đối chiếu với cluster (chạy ở gốc repo, `svp-gitops` ở `SVP_GITOPS_DIR`):

```sh
helm template <release> deploy/helm/svp-service -n svp -f "$SVP_GITOPS_DIR/base/services/<release>.yaml" \
  --set-string image.repository=x/y --set-string image.tag=t --show-only templates/mesh-policy.yaml
```

**EKS:** cùng các lệnh với `--context svp-<env>`, người học chạy sau khi mở tunnel ([`eks.md`](../reference/eks.md)). `make drill-k8s-mesh`
chỉ chạy trên k3d.

## Nguyên nhân thường gặp

1. **Pod ngoài mesh.** Bước 2 không có `enabled`: pod lên trước khi istio-cni, ztunnel sẵn sàng trên node; namespace `svp` mất nhãn
   `istio.io/dataplane-mode: ambient`; hay pod mang `dataplane-mode: none` (pod diễn tập M-1 cố ý như vậy).
2. **Danh tính không được phép.** Bước 3: ServiceAccount của bên gọi không có trong `ingressFrom` của release đích, hay release mới thêm
   mà chưa có `mesh` ở peer của nó (render lỗi chứ không sinh policy). Dấu hiệu: waypoint hay ztunnel đích ghi từ chối, mọi lời gọi từ danh tính
   đó đều bị.
3. **Bỏ qua waypoint.** Gọi thẳng IP pod gRPC, hay Service thiếu nhãn `use-waypoint`, hay waypoint chưa có pod Ready (ztunnel gửi thẳng tới
   đích khi waypoint chưa có địa chỉ): policy L4 của release gRPC chỉ nhận waypoint nên từ chối. Dấu hiệu: bước 1 waypoint thiếu replica
   hay bước 3 thiếu nhãn; lời gọi qua tên Service thất bại, lời gọi qua waypoint đang chạy thì qua.
4. **NetworkPolicy thiếu cổng HBONE.** Lời gọi treo ~10 s rồi đóng, ztunnel không ghi từ chối: policy `ingressFrom` hay `egress` của release
   thiếu 15008 cho peer đó (`kubectl --context k3d-svp -n svp get networkpolicy <release> -o yaml`), hay NetworkPolicy `waypoint` của `svp-mesh`.
5. **istiod không phát được chứng chỉ hay cấu hình.** Bước 1: istiod không Ready, ztunnel hay waypoint log lỗi nối `istiod.istio-system:15012`.
   Pod mới không có danh tính nên không nối được ai. Trên EKS còn: webhook của istiod timeout vì security group node thiếu TCP 15017
   từ control plane ([`eks.md`](../reference/eks.md)).

## Giảm thiểu

- Nguyên nhân 1: xoá pod ngoài mesh (`kubectl --context k3d-svp -n svp delete pod <pod>`), controller tạo pod mới, bị bắt ngay khi istio-cni
  Ready. Namespace mất nhãn thì khôi phục bằng chart `svp-cluster` (Argo CD sync hay `make k8s-up`), không gắn nhãn tay.
- Nguyên nhân 3: đưa waypoint về đủ replica (`kubectl --context k3d-svp -n svp-mesh rollout status deploy/waypoint`); thiếu thì xem pod
  `Pending` hay NetworkPolicy `waypoint`.
- Không gỡ `PeerAuthentication` hay `AuthorizationPolicy`, không thêm principal bằng tay để lời gọi qua: policy là thiết kế, thêm tay
  bị Argo CD hay lượt `make k8s-up` kế tiếp ghi đè, và mở quyền cho danh tính chưa ai duyệt. Danh tính cần gọi thật thì sửa `ingressFrom`
  của release ở `svp-gitops` hay chart rồi để Argo CD sync.

## Khôi phục và xác nhận

- Pod của release đích Ready, bước 2 mọi pod `svp` có `REDIRECTION=enabled`.
- Lời gọi thật qua: `make k8s-smoke` xanh (k3d); `make drill-k8s-mesh` xanh (đối chứng: gateway gọi được, ServiceAccount lạ vẫn bị từ chối).
- Trên EKS: pod `svp` Ready, bước 8 của "Trình tự buổi" ở [`eks.md`](../reference/eks.md), rồi `make eks-smoke`.

## Leo thang

Dừng tự xử lý khi istiod hay ztunnel không lên sau khi node đã Ready, hay khi nhiều release cùng bị từ chối mà `ingressFrom`, nhãn
và pod đều đúng: đó là hỏng cấu hình mesh, không phải một policy. Mở postmortem ([mẫu](../postmortems/README.md)) nếu người dùng
mất request trên stg hay prd. Với drill đỏ ở CI, đọc log của lượt `verify.yml` ([`ci-cd.md`](../ci-cd.md)) trước khi đoán.

## Liên kết

- Thiết kế và lý do: [ADR-0075](../adr/0075-service-mesh.md); sự thật về cổng, nhãn, hành vi từ chối:
  [phụ lục](../adr/appendix/0075-service-mesh.md); threat model IN-2 ở [`threat-model.md`](../threat-model.md).
- Thành phần, namespace, cách đọc log: [`k8s.md`](../reference/k8s.md#cluster-k3d).
- Diễn tập tái hiện: `make drill-k8s-mesh` (ca M-1 đến M-4, đối chứng; chỉ k3d).
