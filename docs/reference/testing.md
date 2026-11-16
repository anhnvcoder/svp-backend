# Quy ước test

Loại tài liệu (Diátaxis): **reference**, tra cứu khi cần một lệnh hay một quy tắc cụ thể; luật làm việc ở [`AGENTS.md`](../../AGENTS.md).

## Quy ước

- Test dùng database riêng tên `svp_<...>_test` (service: `svp_<svc>_<pkg>_test`, ví dụ `svp_engagement_server_test`,
  `svp_feed_projector_test`; gói dùng chung như `internal/dbmigrate` và test lượt xem của engagement-service
  `svp_engagement_views_<x>_test`: mỗi test một database), tạo từ `SVP_TEST_POSTGRES_URL`; helper ở `internal/pgtest` từ
  chối tên không khớp `^svp_[a-z0-9_]+_test$`, nên test không chạm được database thật của service.
- `SVP_TEST_POSTGRES_URL` mặc định trỏ Postgres native của máy (`127.0.0.1:5432`, không TLS; `Makefile`), không phải container
  `postgres` của compose (container đó không publish cổng). Job `check` của CI chạy cùng URL trên service container Postgres 17, cùng
  major với compose, k3d và RDS; Postgres native của máy có thể là major cũ hơn, nên lỗi chỉ có ở 17 lộ ra ở CI
  ([ADR-0057](../adr/0057-postgres17-verify-full.md) §1, §4).
- Migration ([ADR-0068](../adr/0068-zero-downtime-migrations.md) §6 (h), §10, §11; cách viết ở
  [`schema-change.md`](../runbooks/schema-change.md)): migration đổi bảng đã có kèm test chạy SQL của release trước sau migration
  (khuôn `services/user-service/migrations/migrations_test.go`). `internal/dbmigrate/files_test.go` (`TestMigrationFiles`) kiểm mọi file
  của `services/*/migrations/` và `internal/dbmigrate/testdata/*/` theo luật transaction của file. Test diễn tập `drill_test.go`
  (`TestRenameDrill`, `TestRenameDrillNaive`, `TestRenameDrillLockTimeout`) dùng database `svp_migration_drill_test`,
  `svp_migration_drill_naive_test`, `svp_migration_drill_lock_test`; số dòng nạp trước đọc từ `SVP_DRILL_ROWS` (mặc định 20 000 trong
  `make test`; `make migration-drill` đặt 1 000 000). `TestBackfillKeyset` chạy migration backfill mẫu trên bảng rỗng và bảng có id không liên
  tục, database `svp_migration_backfill_empty_test`, `svp_migration_backfill_gaps_test`.
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
  stack đang tắt. Test SCRAM-SHA-512 trên TLS của `internal/kafkax` (`sasl_test.go`) cho `kfake` một CA của chính test và nạp CA đó qua
  một hook chưa export của package, chỉ đặt từ file `_test.go`: Go trên macOS bỏ qua `SSL_CERT_FILE`, `SSL_CERT_DIR`, nên `t.Setenv` không
  thay được hook. Vì đổi biến môi trường và hook nên các test đó không chạy song song.
- Test cần object store thật đọc `SVP_TEST_S3_ENDPOINT`, `SVP_TEST_S3_VIDEO_ACCESS_KEY` /
  `SVP_TEST_S3_VIDEO_SECRET_KEY`, `SVP_TEST_S3_WORKER_ACCESS_KEY` / `SVP_TEST_S3_WORKER_SECRET_KEY`,
  `SVP_TEST_S3_PROBE_ACCESS_KEY` / `SVP_TEST_S3_PROBE_SECRET_KEY`; thiếu biến thì test gọi `t.Skip`. `make test-stack` đặt các biến này.
  Không test nào nối Kafka thật: broker của stack (SASL_SSL 9096, không publish cổng) chỉ tới được từ container của compose.
- Test tích hợp checksum của `internal/objstore` (multipart CRC32 bằng user thử, chạy qua `make test-stack`, xem
  [`compose.md`](compose.md)) gồm hai lượt vì SDK gửi checksum theo hai dạng: header `x-amz-checksum-crc32` qua HTTP, như công
  cụ sao lưu gửi tới endpoint `http://` trong cluster, và trailer `aws-chunked`, dạng SDK chỉ chọn khi URL request là https. Lượt
  trailer vì vậy đi qua một proxy TLS của chính test đặt trước endpoint HTTP, như một gateway TLS đứng trước store trong cluster.
  Mỗi lượt kiểm trên transport của client rằng mọi part đã gửi đúng dạng của nó, nên không thể qua nhờ dạng kia.
- Test Redis dùng Redis native `127.0.0.1:6379` db 15 qua `SVP_TEST_REDIS_URL` (không Valkey của stack: nó TLS, user riêng, không publish cổng); helper `internal/redistest` từ chối URL nào khác `127.0.0.1:6379` /
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
