# Quy ước test

Loại tài liệu (Diátaxis): **reference**, tra cứu khi cần một lệnh hay một quy tắc cụ thể; luật làm việc ở [`AGENTS.md`](../../AGENTS.md).

## Quy ước

- Test dùng database riêng tên `svp_<...>_test` (service: `svp_<svc>_<pkg>_test`, ví dụ `svp_engagement_server_test`,
  `svp_feed_projector_test`; gói dùng chung như `internal/dbmigrate` và test lượt xem của engagement-service
  `svp_engagement_views_<x>_test`: mỗi test một database), tạo từ `SVP_TEST_POSTGRES_URL`; helper ở `internal/pgtest` từ
  chối tên không khớp `^svp_[a-z0-9_]+_test$`, nên test không chạm được database thật của service.
- Test gateway gọi service qua `bufconn` (gRPC trong bộ nhớ), không mở cổng.
- Fuzz test (`FuzzXxx` trong `fuzz_test.go` của gói) kiểm tính chất bằng oracle độc lập với hàm (regexp, bảng `unicode`,
  `ed25519.Verify`, `proto.Marshal`), không chỉ "không panic"; tất định, không dựa trạng thái toàn cục. `TestMain` nào dựng
  database (user-service) bỏ bước đó khi cờ `test.fuzz` khác rỗng hay `test.fuzzworker` bật: mỗi worker chạy lại `TestMain`
  và `internal/pgtest` DROP rồi CREATE database theo tên cố định.
- Test thử lại kết nối Postgres (`internal/pgretry`, `internal/pgpool`, `internal/dbmigrate`) dùng helper của
  `internal/pgretry/pgretrytest` (`ClosedPort`, `Blackhole`, `DelayedProxy`: proxy đóng mọi kết nối một lúc rồi mới chuyển tiếp
  tới database test; `LatencyProxy`: proxy trễ mỗi chiều, đổi được trễ, cắt kết nối giữa chừng, cho test Postgres chậm của
  engagement-service), mọi cổng do chính test mở; test đo thời gian với cửa sổ thử lại rút ngắn còn 1,5 s.
- Test Kafka dùng `kfake` (cluster Kafka giả trong bộ nhớ của franz-go), không cần Docker, nên `make check` chạy được khi
  stack đang tắt.
- Test cần object store hay Redpanda thật đọc `SVP_TEST_S3_ENDPOINT`, `SVP_TEST_S3_VIDEO_ACCESS_KEY` /
  `SVP_TEST_S3_VIDEO_SECRET_KEY`, `SVP_TEST_S3_WORKER_ACCESS_KEY` / `SVP_TEST_S3_WORKER_SECRET_KEY`,
  `SVP_TEST_S3_PROBE_ACCESS_KEY` / `SVP_TEST_S3_PROBE_SECRET_KEY`,
  `SVP_TEST_KAFKA_BROKERS`; thiếu biến thì test gọi `t.Skip`. `make test-stack` đặt các biến này; hiện chưa có test nào
  dùng `SVP_TEST_KAFKA_BROKERS`.
- Test Redis dùng db 15 qua `SVP_TEST_REDIS_URL`; helper `internal/redistest` từ chối URL nào khác `127.0.0.1:6379` /
  `localhost:6379` db 15, cho mỗi test một tiền tố khoá ngẫu nhiên `svp:test:<hex>:` và khi xong chỉ xoá khoá của tiền tố
  đó. Không `FLUSHDB`/`FLUSHALL`, kể cả ở db 15. Thiếu biến thì test gọi `t.Skip`.
- Test web (Vitest, e2e Playwright) ở `svp-frontend`, theo mục "Quy ước test" của `AGENTS.md` repo đó (cùng quy tắc Redis db 15, tiền tố
  ngẫu nhiên); e2e chỉ chạy trên stack `make up` hay cluster k3d của repo này.
- Test telemetry không cần Collector, LGTM hay GlitchTip: span, metric đọc bằng exporter và reader trong bộ nhớ của OTel
  SDK (`tracetest.NewSpanRecorder`, `tracetest.NewInMemoryExporter`, `sdkmetric.NewManualReader`); lỗi gửi tới tracker
  đọc bằng transport Sentry giả trong bộ nhớ, hoặc một server `httptest` do test tự mở làm GlitchTip giả (DSN trỏ host
  `.invalid` khi chỉ cần reporter bật mà không có mạng). Test không gọi cổng localhost đoán sẵn: endpoint OTLP rỗng thì
  không dựng exporter, Collector "không tới được" là cổng do chính test mở rồi đóng.
- Luồng đầu-cuối (đăng ký, đăng nhập, tạo và đọc video, follow, upload tới `READY` và phát HLS, feed, like/view,
  unfollow) kiểm bằng `make smoke` trên stack đang chạy; độ bền và số đo của luồng upload và luồng feed kiểm bằng các
  target diễn tập của [`compose.md`](compose.md) và [`k8s.md`](k8s.md).
