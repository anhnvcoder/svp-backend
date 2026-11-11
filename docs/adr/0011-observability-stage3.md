# 0011. OpenTelemetry qua Collector riêng tới LGTM, GlitchTip tự host, Pyroscope và cảnh báo SLO bằng Sloth

- Trạng thái: Chấp nhận
- Ngày: 2026-10-16
- Người quyết: người học (kế hoạch quan sát với các điều chỉnh ở Bối cảnh); phần còn lại theo đề xuất của ADR này

## Bối cảnh và vấn đề

- Luồng upload, feed, like/view, retry, circuit breaker và job nền đã chạy, nhưng chỉ có log JSON và `traceparent` tự truyền: chưa có span, metric hay cảnh báo để phân biệt một request chậm với consumer đứng.
- NFR ở [architecture §2](../architecture.md#2-ràng-buộc-và-yêu-cầu-phi-chức-năng): feed p99 < 150 ms, đọc feed và khởi tạo upload sẵn sàng 99,9%, video một phút tới `READY` p95 < 120 s, độ tươi feed p95 < 10 s. Timeout vòng nền còn treo ở [ADR-0010 §4](0010-redis-ratelimit-cache-resilience-stage2c.md#4-timeout-retry-circuit-breaker-bulkhead).
- Giữ contract header của [ADR-0006](0006-contract-ids-and-event-envelope.md), trace gốc do gateway tạo ([ADR-0007 §8](0007-go-monorepo-toolchain-and-stage1-scope.md#8-phạm-vi-giai-đoạn-1)), outbox và mạng worker của [ADR-0008](0008-async-upload-pipeline-stage2a.md); không đổi proto hay envelope nghiệp vụ.
- Máy Apple M2 16 GB, Postgres/Redis native dùng chung; chạy native arm64, lần lượt LGTM và Elastic, không chạy compose cùng k3d. Đây là cấu hình dev local, chưa phải mô hình production.
- Điều chỉnh kế hoạch đã duyệt: Collector riêng và Alertmanager bên cạnh LGTM; GlitchTip thay Sentry SaaS vì máy chủ động chặn `sentry.io` trong `/etc/hosts` (không sửa cấu hình máy để vượt chặn; SDK vẫn là `sentry-go`, đổi sang Sentry bằng DSN); bài Elastic chạy lần lượt.
- Ranh giới bảo mật cần giữ: JWT-8, UP-8, RL-2, OPS-1/2, FF-5 trong [threat model](../threat-model.md). Không ghi password, token, email vào telemetry; không gửi header, thân request, form presigned hay query chứa chữ ký.

## Yếu tố quyết định

- Đổi backend quan sát bằng cấu hình, không sửa service (mục tiêu học OpenTelemetry); API không phụ thuộc backend quan sát.
- SLO dựa trên metric trực tiếp, không phụ thuộc sampling; một đường cảnh báo → metric → trace → log → lỗi theo trace ID.
- RAM vừa máy 16 GB (profile tùy chọn, đo bằng cùng tải); không mở cổng quản trị mới; bí mật không vào telemetry.

## Phương án đã cân nhắc

- §1 Collector có sẵn trong LGTM
- §1 **Collector contrib riêng**
- §1 SDK riêng của từng backend
- §2 **OTel API/SDK và instrumentation cùng đợt phát hành**
- §2 trộn version
- §2 tự viết instrumentation
- §3 tin trace header của client
- §3 **W3C TraceContext nội bộ, gateway tạo trace gốc**
- §3 một producer span cho cả lô outbox
- §4 đọc stdout container
- §4 **slog ra stdout và bridge OTLP**
- §5 Prometheus scrape `/metrics`
- §5 **periodic reader đẩy OTLP**
- §5 chỉ sinh RED từ trace
- §6 pull pprof ở cổng quản trị
- §6 **`pyroscope-go` đẩy profile**
- §6 profile cả media-worker
- §7 Sentry SaaS
- §7 Sentry tự host
- §7 **GlitchTip tự host, giao thức Sentry**
- §7 lọc mọi chuỗi bằng regex
- §8 tự viết mọi rule SLO
- §8 **Sloth sinh rule, Alertmanager định tuyến**
- §8 SLO cho cả freshness
- §8 gộp `max by` trước khi tính tuổi gauge
- §8 **chỉ xét mẫu mới hơn 45 s, giữ từng instance**
- §9 **LGTM dev image + Collector/Alertmanager/GlitchTip riêng**
- §9 tách mọi backend
- §9 bật cả LGTM và Elastic
- §10 export đồng bộ
- §10 **export bất đồng bộ, hàng đợi có hạn**
- §10 endpoint mặc định của SDK
- §11 context vòng đời tiến trình
- §11 **deadline từng bước/lần thử, rollback có hạn riêng**
- §11 một deadline 5 s cho mọi việc
- §11 producer idempotent không huỷ
- §11 **cho huỷ produce idempotent đang gửi**
- §12 **Collector → APM Server → Elasticsearch**
- §12 exporter `elasticsearch` ghi thẳng
- §12 chạy đồng thời
- §13 backend luôn bật
- §13 **profile tùy chọn có giới hạn, đo cùng tải**
- §13 nâng Docker VM hết RAM máy

Bảng được/mất ở [phụ lục](appendix/0011-observability-stage3.md).

## Kết quả quyết định

Chọn Collector riêng tới LGTM, GlitchTip, Pyroscope và Sloth/Alertmanager, vì đổi backend chỉ bằng cấu hình, SLO không lệ thuộc sampling và cả bộ chạy vừa máy 16 GB; mỗi § dưới giữ quyết định, chi tiết, bảng và số đo ở phụ lục.

### 1. Đường đi telemetry và Collector

- Service → **OTLP/gRPC** → `otelcol:4317` (Collector contrib riêng, trong mạng `default` và `worker`, cổng không publish); media-worker vẫn chỉ ở mạng `worker`. `obs`: Collector → `lgtm:4317`; `obs-elastic`: cùng endpoint, exporter khác → APM Server → Elasticsearch, Kibana đọc.
- Receiver `otlp` gRPC và `prometheus` scrape `redpanda:9644/public_metrics` mỗi **15 s**. Processor theo thứ tự: `memory_limiter` (`limit_mib: 192`, `spike_limit_mib: 48` trong container 256 MiB), xoá attribute nhạy cảm (header `authorization`, `cookie`, `user.email`, `user.name`, ở signal và resource, cho cả trace/log/metric), `batch` (1 s, 1024).
- Collector tự xuất metric bằng `service.telemetry` (OTLP/gRPC mỗi 15 s thẳng tới `lgtm:4317`, `service.name=otelcol`, không mở `:8888`). Cấu hình xử lý mang sang Helm; tail sampling để giai đoạn 7, không hàng đợi đĩa.

### 2. Gói Go, version và route HTTP

- Module OTel cùng đợt phát hành 2026-10-02, build bằng Go 1.27.2: `otel`, `sdk` v1.47.0, `semconv/v1.43.0`, contrib v0.72.0, `otlploggrpc` v0.23.0, `otelslog` v0.21.0, `otelpgx` v0.13.0, `redisotel` v9.23.0, `sentry-go` v0.50.0, `pyroscope-go` v1.4.3; bảng đầy đủ và version dependency sau probe ở phụ lục. Ghim và kiểm khi nâng.
- `otelaws` v0.72.0 bị upstream đánh dấu deprecated: giữ cho S3 hiện tại, xét lại trước khi nâng AWS SDK hay lên cloud. pgx không bật `WithIncludeQueryParameters`; Redis `redisotel.WithDBStatement(false)`.
- Không dùng `franz-go/plugin/kotel`, `sentry-go/otel`, `sentry-go/slog`, `prometheus/client_golang`.
- Route HTTP: middleware bọc từng route, ngoài auth/rate limit, sau khi mux khớp: gắn `semconv.HTTPRoute(route)`, tên span `METHOD /pattern`; `route` là pattern từ `r.Pattern` bỏ method, route không khớp để rỗng.

### 3. Lan truyền trace và sampling

- Propagator toàn cục chỉ `propagation.TraceContext{}`, không Baggage; HTTP `otelhttp` dùng propagator rỗng, mỗi request nghiệp vụ mở trace gốc mới (gateway nhận trace context đến khi bật `TRUST_TRACE_CONTEXT`: chỉnh bởi 0019). Bỏ `/healthz`, `/readyz` và `/grpc.health.v1.Health/Check` khỏi instrumentation.
- Kafka giữ `traceparent`, `tracestate` khi khác rỗng; `kafkax.Produce` là nơi duy nhất mở span Producer `send <topic>`, mỗi record một span. `outbox.Write` inject context vào `headers` jsonb (không migration); relay chỉ extract, không mở producer span.
- Consumer mở span `process <topic>`; consumer theo lô một span, link tới từng context hợp lệ, tối đa **128 link**. Header hỏng/thiếu thì mở trace gốc mới. Sampler mặc định `parentbased_always_on` (đổi bằng `OTEL_TRACES_SAMPLER`), chưa tail sampling.

### 4. Log có cấu trúc và Loki

- Giữ `log/slog`; nhánh `serve` dùng `slog.NewMultiHandler` cho JSON stdout, bridge `otelslog` và handler lỗi của §7; `trace_id`, `span_id` từ SpanContext. Log → Collector → Loki bằng OTLP (schema **v13**, `/otlp/v1/logs`).
- `limits_config.allow_structured_metadata: true`; `otlp_config.resource_attributes` đặt `ignore_defaults: true`, chỉ `service.name` là `index_label`. Không đưa `service.instance.id`, user/video ID, IP hay trace ID vào label index. Tempo → Loki: `{service_name="<service>"} | trace_id = "<trace>"`. Bí mật chặn ở nguồn, không dựa vào bộ lọc Collector.

### 5. Metric, tên series và cardinality

- Periodic reader mỗi **15 s** đẩy OTLP qua Collector vào Prometheus của LGTM; không service nào có `/metrics`. `service.name` là tên service, `service.instance.id` duy nhất mỗi tiến trình, không `service.namespace`; dashboard và rule lọc bằng `service_name`.
- Histogram thời gian unit `s`, bucket explicit qua SDK View: H `[0.005 … 10]` s, V `[10 … 600]` s, F `[0.1 … 60]` s (bảng đầy đủ ở phụ lục); không native histogram. Instrument nghiệp vụ: `svp.ratelimit.decisions`, `svp.breaker.state`, `svp.kafka.dlq.records`, `svp.loop.last_success`, `svp.video.ready.duration`, `svp.transcode.duration`, `svp.feed.freshness`; không gắn `user_id`, `video_id`, `trace_id`, email, IP vào metric.
- Counter gọi `Add(ctx, 0, …)` cho mọi tổ hợp label đã biết trước khi có sự kiện; gauge breaker giữ trạng thái chuyển gần nhất (không gọi `cb.State()` trong callback); loop ghi Unix timestamp của lần thành công (chưa từng thì 0).
- Thời lượng video tới `READY` đo từ cột `processing_at` (migration `00004_add_processing_at.sql`), ghi sau khi transaction commit; freshness đo tới sau commit fan-out. Lag Redpanda: `rpk cluster config set enable_consumer_group_metrics '[group,partition,consumer_lag]'` trong `redpanda-init`. Metric thư viện dùng tên mặc định: `otelpgx.RecordStats`, `runtime.Start`, `redisotel.InstrumentMetrics`.

### 6. Profiling và cổng quản trị

- Gateway, user-, video-, engagement-, feed-service đẩy `pyroscope-go` tới `http://lgtm:4040`, không qua Collector; bật CPU, alloc space, inuse space, goroutine; không mutex/block; `PYROSCOPE_SERVER_ADDRESS` rỗng thì tắt. media-worker không profile.
- Không `net/http/pprof`, không `/metrics`, nên không cần cổng quản trị; test gateway xác nhận `/debug/pprof/` và `/metrics` trả **404**.

### 7. Theo dõi lỗi bằng GlitchTip và ranh giới dữ liệu

- **GlitchTip 6.2.6** tự host, `sentry-go`, gói `internal/sentryx`. `SENTRY_DSN` rỗng thì tắt; `SENTRY_ENVIRONMENT` mặc định `local`; `SendDefaultPII=false`, flush tối đa **2 s**; một organization và project `svp`, tag `service`. Gửi mức ≥ ERROR; không biến lỗi 4xx dự kiến thành event.
- Chỉ chuyển attribute trong allowlist; message là hằng; exception chỉ mang kiểu lỗi (`%T`) và mã an toàn, không `err.Error()`; `BeforeSend` bỏ `Request`, `User` chỉ giữ `id`, che email và JWT. Mỗi fingerprint tối đa **1 event/30 s**, cả tiến trình **60 event/phút**; GlitchTip lỗi thì bỏ event. media-worker không gửi lỗi.
- All-in-one một container `glitchtip` (`GLITCHTIP_EMBED_WORKER=true`, `VALKEY_URL=""` tường minh, không Valkey). Database native `svp_glitchtip` ở `127.0.0.1:5432`, hai role `svp_glitchtip_migrator` và `svp_glitchtip_app`; `VTASKS_CONCURRENCY=2`, `DATABASE_POOL_MAX_SIZE=4`, `GRANIAN_WORKERS=1`.
- Khởi tạo bằng job `glitchtip-init` (migrate, `createcachetable` bằng migrator, `maintain_partitions`, `bootstrap.py` idempotent); DSN và API token sinh sau init vào `.env`, không in ra. API diễn tập dùng Bearer token hai scope; retention lỗi **14 ngày**.

### 8. SLO và cảnh báo

- Sloth `github.com/slok/sloth/cmd/sloth@v0.16.0`; spec `deploy/observability/slo/svp-slos.yaml`, `make slo` sinh `slo-generated.yaml` (commit cả file sinh). Cửa sổ **30 ngày**; page **14,4×** (1 h/5 m) và **6×** (6 h/30 m); ticket **3×** (1 d/2 h) và **1×** (3 d/6 h). SLI 30 ngày tính thẳng từ query (`disableOptimized: true`), Prometheus giữ **30 ngày** (`storage.tsdb.retention.time: 30d`).
- Bốn SLO: `feed-availability` 99,9%, `upload-init-availability` 99,9%, `feed-latency` 99% trong 150 ms, `video-ready-latency` 95% trong 120 s. Freshness p95 < 10 s là panel và `make measure-freshness`, chưa là SLO. Không có traffic thì không báo SLO tốt giả.
- Rule viết tay `deploy/observability/prometheus/rules/svp-alerts.yaml`, evaluation **15 s**: `KafkaConsumerLagHigh` (`for` 2 m; media-worker 20 m), `BackgroundLoopStalled`, `RateLimitFallbackActive`, `KafkaDLQRecords`, `CircuitBreakerOpen`, đều page. Gauge chỉ xét mẫu mới hơn **45 s** và khớp đủ label gồm instance; thời lượng đo bằng mẫu thật, rule không có `for`. Ngưỡng vòng nền: relay 60 s, cleanup 1860 s, sweep 960 s, prune 11100 s, cộng `for` của bảng.
- Alertmanager riêng, `127.0.0.1:9093`, `group_wait: 10s`, `group_interval: 1m`, `repeat_interval: 4h`; chỉ `severity="page"` đi Telegram khi có `SVP_ALERT_TELEGRAM_BOT_TOKEN`, `SVP_ALERT_TELEGRAM_CHAT_ID` (compose secret); ticket chỉ xem UI. Silence ở volume `alertmanager-data`. Link "Source" đi qua datasource proxy của Grafana (`--web.external-url`, `--web.route-prefix=/`). Test bằng `make slo-check`.

### 9. Stack local, image và đường dẫn cấu hình

- Profile `obs`: `otelcol`, `lgtm`, `alertmanager`, `glitchtip`, job `glitchtip-init`; `obs-elastic`: `otelcol` cấu hình Elastic, Elasticsearch, Kibana, APM Server. Không bật cả hai bộ. Image ghim `tag@sha256` đa kiến trúc: `grafana/otel-lgtm` `0.36.0`, Collector `0.162.0`, `prom/alertmanager` `v0.34.1`, `glitchtip/glitchtip` `6.2.6` (digest và thành phần của LGTM ở phụ lục).
- Cấu hình Prometheus, Tempo, Loki, datasource và dashboard nạp bằng bind mount read-only vào đường dẫn của image; rule, provisioning, dashboard là file trong repo. `make up` chỉ `core`; `OBS=lgtm|elastic|off`; `make down` gỡ mọi profile, giữ volume.
- Chỉ publish loopback Grafana **3000**, GlitchTip **8000**, Alertmanager **9093**, Kibana **5601**; script host truy vấn qua `/api/datasources/proxy/uid/<uid>/...`. Grafana không tải plugin lúc chạy (`GF_PLUGINS_PREINSTALL_DISABLED=true`, `GF_PLUGINS_PREINSTALL_AUTO_UPDATE=false`, `GF_PLUGINS_PUBLIC_KEY_RETRIEVAL_DISABLED=true`); chấp nhận mất app Drilldown và LLM. Anonymous Admin chỉ chấp nhận vì loopback (OPS-2).
- Biến của service: `OTEL_EXPORTER_OTLP_ENDPOINT=http://otelcol:4317`, `OTEL_EXPORTER_OTLP_INSECURE=true`, `PYROSCOPE_SERVER_ADDRESS=http://lgtm:4040`, `SENTRY_DSN=${SENTRY_DSN:-}`, `SENTRY_ENVIRONMENT=local`; worker bỏ Pyroscope/Sentry.

### 10. Backend observability không tới được và phép đo overhead

- Chỉ nhánh **`serve`** khởi tạo OTel, Sentry, Pyroscope; `healthcheck`, `migrate` chỉ có logger stdout. `telemetry.Setup` dial lười; batch span/log processor hàng đợi **2048**, đầy thì bỏ; metric reader **15 s**, export timeout **5 s**; shutdown ba provider chung ngân sách **5 s**; lỗi nội bộ OTel log WARN tối đa một dòng/phút.
- `OTEL_SDK_DISABLED=true` không dựng provider; endpoint rỗng hay không đặt thì không dựng exporter, không rơi về `localhost:4317`. Backend tắt không làm readiness lỗi.
- Đo cùng tải ba trạng thái: **a** `OBS=off`; **b** `OBS=lgtm`; **c** `make up` (SDK bật, backend không tới); công bố riêng **b−a** và **c−a**.

### 11. Hạn của pool và vòng nền

- Mọi I/O nền có deadline từng bước/lần thử, rollback có hạn riêng **5 s** từ `context.WithoutCancel`: mở pool `ConnectTimeout` 5 s và `Ping` 5 s (chỉnh bởi 0020 §11: cửa sổ thử lại 30 s); relay đọc/khoá 5 s, produce 10 s, đánh dấu/commit 5 s; dọn outbox 30 s; consumer `transcode.*` 10 s, projector feed 30 s, lô engagement 30 s; dọn timeline 2 phút; dọn upload 30 s mỗi lô 100 video; media-worker giữ 15 phút (ffprobe 30 s, ffmpeg 10 phút, produce 30 s); DLQ 10 s; commit offset 10 s. Bảng đầy đủ ở phụ lục.
- `internal/pgpool` dựng pool có tracer `otelpgx` và `RecordStats`. `HandlerTimeout` dựng mới mỗi lần thử, hết hạn là lỗi tạm; shutdown không DLQ.
- Giữ mặc định franz-go v1.22.1 trừ **thêm `kgo.AllowIdempotentProduceCancellation()`** tại `internal/kafkax.NewClient`; hạn produce: outbox **10 s**, lượt xem **2 s**, kết quả worker **30 s**, DLQ **10 s**. Không bọc `ProduceSync` bằng goroutine. Giữ override rebalance worker 164 phút.
- Đánh đổi: timeout không khẳng định record chưa ghi; relay giữ `event_id` khi retry, consumer nghiệp vụ phải idempotent; không hứa exactly-once qua một request có kết quả không rõ.

### 12. Bài so sánh Elastic

- Giữ **APM Server** cho biến thể so sánh; không thay bằng exporter `elasticsearch` trước khi chứng minh tương thích (tài liệu Elastic cảnh báo bỏ qua pipeline xử lý). Chạy **lần lượt** `OBS=lgtm` rồi `OBS=elastic`, mỗi bộ `make smoke` **3 lần + một upload tới READY**, heap Elasticsearch **1 GB**, security tắt chỉ vì dev local, chỉ publish Kibana trên loopback; kết luận ở [ADR-0012](0012-elastic-vs-grafana-stage3.md).
- Mốc giá managed tra 2026-10-16 (Grafana Cloud, Elastic Observability Serverless) là giá niêm yết, chưa phải dự toán; bảng ở phụ lục.

### 13. Ngân sách tài nguyên

- `mem_limit`: `lgtm` 1536 MiB, `otelcol` 256 MiB, `alertmanager` 64 MiB, `glitchtip` 512 MiB, `glitchtip-init` 512 MiB. Dự toán `obs` tăng **1,25–2 GiB** so với core (trần các container chạy lâu dài khoảng **2,31 GiB**); Elastic tăng **3–3,5 GiB**, đo riêng.
- Prometheus giữ 30 ngày: RAM gần như không đổi, đĩa khoảng **1,2–2,6 GB** nếu chạy liên tục 30 ngày. Docker Desktop khuyến nghị khoảng **10 GB** nếu Elastic gây áp lực; không đổi giới hạn chỉ để che OOM.

### Hệ quả

- Tốt: một trace nối request, outbox và fan-out mà không đổi contract nghiệp vụ; SLO không phụ thuộc sampling; đổi backend và sang Helm giữ đường instrumentation, backend hỏng thì API vẫn chạy; error tracker chạy local không cần tài khoản ngoài; không mở handler quản trị, worker giữ cô lập mạng.
- Xấu: thêm SDK, CPU/RAM, hàng đợi có thể mất telemetry, module v0.x cần kiểm khi nâng, `otelaws` không còn hỗ trợ upstream; Collector, Alertmanager, GlitchTip tăng công vận hành (all-in-one giữ credential maintenance trong container web), LGTM gộp chỉ cho dev; SLO video chỉ đếm mẫu kết thúc; produce có hạn nên gửi lại sau huỷ có thể tạo bản sao; tracker ít thông tin hơn log (tra Loki bằng trace ID).
- Xem lại khi: overhead a/b/c làm feed vượt 150 ms hay vượt ngân sách RAM; Collector drop hay tracker chạm 512 MiB (thêm Valkey riêng, không lấy db Redis native); lên k8s/cloud (xác thực UI, secret, TLS/NetworkPolicy, retention và chi phí thật); nâng OTel/LGTM/GlitchTip hay AWS SDK (kiểm lại tên metric, bucket, route, provisioning, API tag query, phương án thay `otelaws`).

## Xác nhận

- Probe 2026-10-16 trên dữ liệu giả chọn cấu hình và version (build dependency, image/digest, mount LGTM, OTLP → Prometheus/Loki/Tempo, Redpanda thật, GlitchTip thật, API lỗi); bảng lệnh và kết quả ở [phụ lục](appendix/0011-observability-stage3.md#kiểm-chứng-đã-kiểm-ngày-2026-10-16).
- Rule §8 đã kiểm bằng `make slo-check` (promtool 3.15.0 của image LGTM) với bộ test `svp-alerts.test.yaml`; các ca trong phụ lục §8.
- Chưa kiểm khi quyết: overhead a/b/c (§10), RAM Collector và Alertmanager dưới tải thật (§13), tải Elastic (đã đo ở [ADR-0012](0012-elastic-vs-grafana-stage3.md)).

## Hiện thực ở

- SDK, Collector, trace, log, metric (§1–§5): `internal/telemetry/`, `internal/logx/`, `internal/kafkax/tracing.go`, `services/gateway/internal/httpx/`, metric trong `services/*/internal/` (projector, server, worker, breaker, ratelimit); `deploy/observability/otelcol/` (`config.yaml`, `k8s-config.yaml`), `deploy/observability/lgtm/loki-config.yaml`, `deploy/observability/grafana/`, `deploy/observability/prometheus/prometheus.yaml`.
- GlitchTip (§7): `internal/sentryx/`, `deploy/observability/glitchtip/` (`init.sh`, `bootstrap.py`), database `svp_glitchtip` ở `deploy/postgres/bootstrap.sh`, phần báo lỗi khởi động và tắt êm của `services/*/cmd/*/main.go`.
- SLO và cảnh báo (§8): `deploy/observability/slo/svp-slos.yaml`, `deploy/observability/prometheus/rules/` (`svp-alerts.yaml`, `svp-alerts.test.yaml`), `deploy/observability/alertmanager/entrypoint.sh`.
- Stack local và overhead (§9, §10): profile `obs` của `deploy/compose/compose.yaml`, `deploy/compose/compose.mk` (`OBS=lgtm|elastic|off`), `Makefile`, `services/gateway/cmd/gateway/telemetry_test.go`, `services/gateway/internal/api/telemetry_test.go`; diễn tập `deploy/compose/drills/` (`alert-to-sentry.sh`, `obs-threats.sh`, `common.sh`).
- Hạn pool và vòng nền (§11): `internal/pgpool/`, `internal/kafkax/consumer.go`, `internal/outbox/`, `services/engagement-service/internal/server/`, `services/feed-service/`, `services/video-service/internal/server/`, `services/video-service/migrations/00004_add_processing_at.sql`, `deploy/redpanda/create-topics.sh`.
- Bài so sánh Elastic (§12): `deploy/observability/elastic/kibana.yml`. Trong cluster k3d: `deploy/helm/svp-observability/`, `deploy/helm/svp-service/values.yaml`, `deploy/k8s/values/kube-prometheus-stack.yaml`, `deploy/k8s/secrets.sh`.
- Hiện trạng: [`explanation/observability.md`](../explanation/observability.md), [`reference/compose.md`](../reference/compose.md), [`architecture.md`](../architecture.md).

## Nguồn

- GlitchTip, [hướng dẫn cài đặt](https://glitchtip.com/documentation/install/) (không cần Valkey, tra 2026-10-16); Elastic, [upstream OpenTelemetry](https://www.elastic.co/docs/solutions/observability/apm/opentelemetry/upstream-opentelemetry-collectors-language-sdks); [Grafana pricing](https://grafana.com/pricing/), [Elastic pricing](https://www.elastic.co/pricing/serverless-observability/).

## Thông tin thêm

Phụ lục: [`appendix/0011-observability-stage3.md`](appendix/0011-observability-stage3.md) (tiêu đề và dòng trạng thái gốc, bối cảnh đầy đủ, bảng được/mất từng §, bảng version Go, bảng metric và bucket, công thức PromQL và ca test của rule, bảng image, mount và hạn thời gian, bảng kiểm chứng, số RAM và đĩa).

### Chỉnh bởi

- §1: [0012](0012-elastic-vs-grafana-stage3.md): hai service compose `otelcol`, `otelcol-elastic` chung alias mạng `otelcol` thay một service đổi cấu hình theo biến.
- §3: [0019](0019-web-k3d-supply-chain-observability.md): gateway nhận `traceparent`/`tracestate` của request đến khi bật `TRUST_TRACE_CONTEXT`.
- §8: [0021](0021-deferred-verification-stage6b.md): `RateLimitFallbackActive` theo tỷ lệ quyết định dự phòng của từng instance, có sàn số lượng và `for: 1m`; thêm ticket `RateLimitFallbackElevated`.
- §11: [0013](0013-kafka-metadata-min-age.md): `MetadataMinAge` 1 s cho mọi client franz-go.
- §11: [0020](0020-reliability-stage6.md): ngân sách kết nối Postgres lúc khởi động 5 s thành cửa sổ thử lại 30 s.
- §1, §5, §8: [0053](0053-msk-elasticache-valkey.md): Collector đọc lag bằng receiver `kafkametrics` (user `svp-otelcol`, SCRAM-SHA-512 trên TLS) thay scrape `redpanda:9644/public_metrics` và `enable_consumer_group_metrics` của Redpanda; rule lag dùng metric `kafka.consumer_group.lag` của receiver.
- §7: [0057](0057-postgres17-verify-full.md): database `svp_glitchtip` nằm trên container `postgres` của compose (TLS `verify-full`) thay Postgres native `127.0.0.1:5432`.
