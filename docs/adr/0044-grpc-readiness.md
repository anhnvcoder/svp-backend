# 0044. Readiness của service gRPC là tên health `readiness`, do vòng nền ping Postgres của service đặt; liveness, startup giữ health tổng

- Trạng thái: Chấp nhận
- Ngày: 2026-11-02
- Người quyết: AI đề xuất, người học uỷ quyền

## Bối cảnh và vấn đề

Bốn service gRPC (user, video, engagement, feed) đăng ký health service chuẩn của gRPC (`internal/grpcserver`): trạng thái tổng `""` là SERVING
từ lúc listen tới lúc tắt, không phụ thuộc gì. Chart `svp-service` cho startup, readiness và liveness cùng hỏi trạng thái đó
(`deploy/helm/svp-service/templates/deployment.yaml`; quyết định ở [0014](0014-kubernetes-local-stage4.md) §10, thời hạn probe ở
[0020](0020-reliability-stage6.md) §10). Pod mất đường tới Postgres của nó (mạng, CloudNativePG đổi primary, pool hỏng) vẫn Ready và vẫn nhận
RPC chỉ để trả lỗi; pod mới chưa nối được database cũng vào Service ngay. Đối chiếu chuẩn ngành ngày 2026-11-01 ghi lệch này.

Mọi RPC của cả bốn service đọc hay ghi Postgres riêng của service đó ([0001](0001-service-boundaries-and-data-ownership.md)). Phụ thuộc
khác chỉ ảnh hưởng một phần: Redis (feed-service cache khám phá, có đường khi cache lỗi), object store (chỉ `CompleteUpload`, transcode),
Kafka (consumer và outbox relay chạy độc lập với việc phục vụ RPC, lag có cảnh báo riêng).

## Yếu tố quyết định

- Pod không phục vụ được RPC nào thì rời Service; pod còn phục vụ được thì không bị kéo theo.
- Liveness không bao giờ phụ thuộc thứ ngoài tiến trình (restart không chữa được database chết).
- Không thêm binary hay sidecar; dùng probe `grpc` gốc của Kubernetes (GA từ v1.27, trường `service` [N1]).

## Phương án đã cân nhắc

Trạng thái ngành đọc ngày 2026-11-02 từ nguồn ở mục Nguồn.

| Phương án | Trạng thái | Nguồn | Ghi chú |
| --- | --- | --- | --- |
| A. Cả ba probe hỏi health tổng, không phụ thuộc (như hiện nay) | hiện hành (mặc định của Spring Boot: không thêm kiểm phụ thuộc vào readiness) | [N4] | Pod mất database vẫn nhận RPC |
| B. Readiness là tên health riêng, vòng nền ping pool Postgres của service; liveness, startup giữ `""` | hiện hành | [N2][N4] | Tách bạch "sống" và "phục vụ được" |
| C. Như B nhưng kiểm mọi phụ thuộc (Redis, object store, Kafka) | cũ, bị khuyên tránh | [N4][N5] | Phụ thuộc không thiết yếu kéo pod khỏi Service |
| D. Liveness cũng kiểm database | cũ, bị khuyên tránh | [N4][N5] | Database chập chờn là restart mọi pod |
| E. Probe `exec` chạy `grpc_health_probe` | cũ: probe `grpc` gốc thay chỗ, GA từ v1.27 | [N1] | Thêm binary vào image distroless |

## Kết quả quyết định

Chọn **B**.

1. **Tên health `readiness`.** `grpcserver.Run` đăng ký thêm tên `readiness` (cùng tên ở cả bốn service, để chart dùng một giá trị) với trạng
   thái NOT_SERVING lúc khởi động. Tên phải được đăng ký trước khi listen: tên lạ trả `NOT_FOUND`, probe tính là hỏng [N2]. Tổng `""` giữ
   nguyên: SERVING từ lúc listen tới shutdown; shutdown đặt cả hai NOT_SERVING như hiện nay.
2. **Vòng nền.** Mỗi **2 s** gọi phép kiểm của service với timeout **1 s**; **3 lần lỗi liên tiếp** → NOT_SERVING; **1 lần qua** → SERVING
   (cả lần đầu, nên pod vào Service ngay khi database trả lời). Đổi trạng thái thì log một dòng (WARN khi thành NOT_SERVING), không log mỗi
   lần kiểm. Vòng dừng theo context của server.
   - 2 s: probe readiness chạy mỗi 5 s và đọc trạng thái đã tính, nên trạng thái probe đọc cũ tối đa 2 s; một ping mỗi 2 s mỗi pod là tải
     không đáng kể.
   - 1 s: nhỏ hơn chu kỳ nên hai lần kiểm không chồng nhau; ping tới Postgres cùng cluster khoẻ tốn cỡ mili giây (chưa đo trên cluster).
   - 3 lần (~6 s): một ping chậm lẻ (GC, mất một gói, pool bận một nhịp) không đổi trạng thái. Kubelet thêm lớp thứ hai: `failureThreshold`
     mặc định 3 × chu kỳ 5 s, nên pod rời Service sau khoảng 16–21 s database không trả lời, về lại sau tối đa ~7 s (2 s + 5 s).
3. **Phép kiểm là `Ping` của pool Postgres của service** (engagement-service: `writePool`, RPC ghi và consumer lượt xem cùng cần nó). `Ping`
   của pgxpool mượn một kết nối của pool rồi chạy câu lệnh rỗng [N6]: pool đầy thì nó chờ kết nối như RPC (rủi ro pool cạn ở dưới).
4. **Kafka, Redis, object store không vào readiness** (C bị loại): consumer và relay chạy trong pod NotReady như thường; feed-service có đường
   khi cache lỗi; object store chỉ ảnh hưởng một phần RPC.
5. **Liveness và startup giữ health tổng** (D bị loại). Chart: `readinessProbe.grpc.service: readiness`, giữ chu kỳ và thời hạn của
   [0020](0020-reliability-stage6.md) §10.
6. **Ngoài Kubernetes giữ health tổng:** healthcheck của compose (`/app healthcheck`) và `/readyz` của gateway vẫn hỏi `""`. Compose không định
   tuyến theo health; `/readyz` của gateway đổi theo readiness của service phía sau thì một database chết rút mọi pod gateway, ngược với thiết kế
   xuống cấp theo route ([0014](0014-kubernetes-local-stage4.md) §10).

### Rủi ro: readiness phụ thuộc thứ dùng chung

Mọi pod của một service dùng chung một Postgres. Database chết thì mọi pod rời Service cùng lúc: đó là cảnh báo của Henning Jacobs [N5]
(10 pod, một Postgres, "all 10 pods will be down") và của tài liệu Spring Boot [N4], vốn để người viết ứng dụng tự quyết: đưa phụ thuộc dùng
chung vào readiness và chấp nhận service rời phục vụ khi nó chết, hoặc để ngoài và xử lý ở tầng trên bằng circuit breaker của bên gọi. Breaker
của gateway (`services/gateway/internal/breaker`) chỉ đếm là lỗi `UNAVAILABLE` không mang ErrorInfo và `DEADLINE_EXCEEDED`; mã khác là service
đã trả lời, đếm là thành công. So với hiện nay:

- Hiện nay, pod vẫn Ready và RPC vẫn tới pod. Database từ chối kết nối: RPC trả nhanh `INTERNAL` (like, unlike: `UNAVAILABLE` kèm
  `DEPENDENCY_UNAVAILABLE`, không tính), breaker **giữ đóng**, client nhận 500 (like: 503). Database không trả lời: phần lớn RPC hết hạn 3 s
  của gateway (`DEADLINE_EXCEEDED`), breaker mở sau 5 lỗi liên tiếp.
- Theo B: kết nối **mới** của gateway tới Service không còn endpoint bị từ chối ngay (`UNAVAILABLE` không ErrorInfo), breaker mở sau 5 lần và
  mở 5 s mỗi đợt, client nhận 503 ngay: với database từ chối kết nối, đó là hành vi mới. Kết nối đang mở vẫn tới pod NotReady và nhận lỗi
  như hiện nay (giới hạn thứ nhất dưới đây). Database về thì mọi pod về lại trong ~7 s, không restart; gateway chậm hơn thế: breaker đang mở chờ
  tới lượt thử (tối đa 5 s), và kênh gRPC đã bị từ chối chỉ nối lại theo backoff của gRPC (1 s nhân 1,6 mỗi lần, tối đa 120 s [N7]), nên sau
  một sự cố dài gateway có thể trễ thêm vài chục giây (chưa đo).
- Lúc database chết không gì xấu hơn: không pod nào phục vụ được, dù Ready hay không; cái giá là gateway về chậm hơn. Thứ B thêm được:
  pod lỗi riêng lẻ (mất mạng tới database, lúc CloudNativePG đổi primary) rời Service trong khi pod khác phục vụ; rollout không đưa pod chưa
  nối được database vào Service, Deployment dừng lại với pod cũ còn chạy.

Hai giới hạn nói thẳng:

- Gateway giữ kết nối HTTP/2 lâu dài qua ClusterIP (kube-proxy chọn pod lúc mở kết nối, client dùng `pick_first`): rút pod khỏi EndpointSlice
  chỉ có tác dụng với kết nối mới; kết nối đang mở vẫn tới pod NotReady cho tới khi đứt. Muốn tác dụng đủ cần cân bằng theo pod (Service
  headless + `round_robin`, mesh) hay `MaxConnectionAge` ở server: ngoài phạm vi ADR này.
- PodDisruptionBudget của chart chưa đặt `unhealthyPodEvictionPolicy`; mặc định `IfHealthyBudget` không cho evict pod NotReady khi ngân sách
  không đủ [N3], nên trong lúc database chết, `kubectl drain` một node có pod của service đó bị chặn.

### Rủi ro: pool cạn dưới tải

Pool nhỏ: mặc định của pgx là `max(4, số CPU)` kết nối (`internal/pgpool`), `writePool` của engagement-service mặc định 5. Tải dồn làm mọi kết nối
bận quá 1 s trong 3 lần kiểm liền (~6 s) thì `readiness` thành NOT_SERVING dù database khoẻ. Đợt tải tới mọi pod cùng lúc nên các pod có thể cùng
rời Service, dồn tải vào pod còn lại: chuỗi sụp đổ mà [N5] cảnh báo. Chấp nhận khi chưa có số đo (pool cạn bao lâu dưới tải: chưa đo); dòng log
WARN khi đổi trạng thái cho thấy nó trong test tải. Đo thấy readiness lật khi database khoẻ thì đổi phép kiểm sang một kết nối riêng ngoài pool
(một kết nối mỗi pod, không chờ tải của RPC).

### Hệ quả

- Tốt: pod không phục vụ được không nhận RPC mới; rollout và pod lỗi riêng lẻ được che; liveness không bao giờ restart vì database.
- Xấu: mỗi pod thêm một goroutine và một ping mỗi 2 s; pool cạn dưới tải có thể rút pod khỏi Service; hai giới hạn ở trên.
- Xem lại khi: gateway đổi sang cân bằng theo pod hay mesh (readiness có tác dụng đủ); service có RPC không cần Postgres; test tải thấy
  readiness lật khi database khoẻ (kết nối kiểm riêng); drain bị chặn trong một sự cố thật (đặt `unhealthyPodEvictionPolicy: AlwaysAllow`).

## Xác nhận

Test của `internal/grpcserver` với health client thật trên listener cục bộ: `readiness` thành NOT_SERVING sau 3 lần kiểm lỗi và về SERVING khi
hết lỗi, `""` vẫn SERVING suốt; phép kiểm treo bị timeout cắt; shutdown đặt cả hai NOT_SERVING. `make helm-check` render
`readinessProbe.grpc.service`. Chưa kiểm lúc chấp nhận: các việc trên làm cùng phần hiện thực; diễn tập dừng Postgres trên k3d (pod NotReady,
không restart) chưa chạy.

## Ưu nhược từng phương án

- A: tốt là không phụ thuộc gì; xấu là pod mất database vẫn nhận RPC, rollout không chờ database.
- B: như Kết quả quyết định và Rủi ro.
- C: xấu là Redis hay object store chập chờn rút cả service dù phần lớn RPC còn chạy.
- D: xấu là database chập chờn restart mọi pod, thêm tải nối lại vào database đang yếu [N4][N5].
- E: xấu là thêm binary vào image distroless trong khi probe gốc làm được.

## Hiện thực ở

- `internal/grpcserver/grpcserver.go` (tên `readiness`, vòng nền, tham số phép kiểm của `Run`), `grpcserver_test.go`.
- `services/{user,video,engagement,feed}-service/cmd/<service>/main.go` (truyền `Ping` của pool).
- `deploy/helm/svp-service/templates/deployment.yaml` (`readinessProbe.grpc.service`, comment khối probe gRPC).

## Nguồn

Truy cập 2026-11-02.

- [N1] Kubernetes: [Configure Liveness, Readiness and Startup Probes](https://kubernetes.io/docs/tasks/configure-pod-container/configure-liveness-readiness-startup-probes/)
  (probe gRPC "Stable since Kubernetes v1.27"; pod chưa sẵn sàng không nhận traffic qua Service); trường `service` của `GRPCAction`:
  [`core/v1/types.go`](https://github.com/kubernetes/api/blob/master/core/v1/types.go).
- [N2] gRPC: [Health Checking Protocol](https://github.com/grpc/grpc/blob/master/doc/health-checking.md) (`""` là sức khoẻ tổng; tên chưa
  đăng ký trả `NOT_FOUND`).
- [N3] Kubernetes: [Specifying a Disruption Budget, Unhealthy Pod Eviction Policy](https://kubernetes.io/docs/tasks/run-application/configure-pdb/#unhealthy-pod-eviction-policy).
- [N4] Spring Boot: [Actuator Endpoints, Checking External State With Kubernetes Probes](https://docs.spring.io/spring-boot/reference/actuator/endpoints.html).
- [N5] Henning Jacobs: [Kubernetes Liveness Probes are Dangerous](https://srcco.de/posts/kubernetes-liveness-probes-are-dangerous.html) (2019-09-28).
- [N6] pgx v5: [`pgxpool.Pool.Ping`](https://pkg.go.dev/github.com/jackc/pgx/v5/pgxpool#Pool.Ping) ("acquires a connection from the Pool and
  executes an empty sql statement against it").
- [N7] gRPC: [Connection Backoff Protocol](https://github.com/grpc/grpc/blob/master/doc/connection-backoff.md) (`INITIAL_BACKOFF` 1 s,
  `MULTIPLIER` 1.6, `MAX_BACKOFF` 120 s); grpc-go dùng cùng giá trị trong `backoff.DefaultConfig`.
