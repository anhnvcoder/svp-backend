# 0010. Redis không bắt buộc cho rate limit GCRA và cache feed khám phá, timeout/retry/circuit breaker ở gateway, job dọn upload bỏ dở

- Trạng thái: Chấp nhận
- Ngày: 2026-10-11

## Bối cảnh và vấn đề

- Luồng upload, follow, feed, like, lượt xem đã chạy đầu-cuối ([ADR-0008](0008-async-upload-pipeline-stage2a.md), [ADR-0009](0009-engagement-feed-stage2b.md)); còn Redis, cache feed khám phá + singleflight ([ADR-0005](0005-feed-fan-out-on-write.md) luật 6), rate limit ở gateway (RL-3, RL-6), timeout/retry/circuit breaker giữa service, job dọn upload bỏ dở ([ADR-0004](0004-direct-upload-and-hls.md) luật 4) và UP-7.
- Biện pháp [threat model](../appendix/threat-model.md#tổng-hợp-theo-giai-đoạn-mục-5-cũ) còn mở: JWT-4, JWT-6, JWT-9, UP-7, RL-1 tới RL-3, RL-6; hành vi khi Redis lỗi đã chốt theo loại route ở [§4.4](../threat-model.md#44-rate-limit-ở-gateway), ADR này chốt ngưỡng và cách làm. Lab `rate-limiter`, `cache-stampede`, `distributed-cron-lock` không làm: ngưỡng chọn bằng lập luận, xem lại bằng k6.
- NFR: feed p99 < 150 ms tại 1.000 req/s; khởi tạo upload thành công 99,9%; cache chống key nóng (feed khám phá), không vì tổng tải ([capacity](../explanation/capacity.md#rút-ra-gì)). Hiện trạng: tắt engagement-service thì like treo tới timeout 3 s của gateway rồi 504.
- Ràng buộc máy: Redis 8.8.0 native `127.0.0.1:6379` dùng chung với dự án khác (gateway db 10, feed-service db 14); không thêm container.

## Yếu tố quyết định

Redis lỗi không được làm sập feed hay bỏ trống giới hạn đăng nhập; không thêm hệ thống mới khi thứ có sẵn đủ dùng; mọi lời gọi ra ngoài có hạn; số đo chứ không đoán (k6 xem lại ngưỡng); không chạm dữ liệu Redis của dự án khác.

## Phương án đã cân nhắc

- §1 client **A `go-redis/v9`**: client chính thức, `Script` tự dùng `EVALSHA`, timeout tách dial, đọc/ghi, chờ pool; kéo thêm vài module phụ vào `go.sum`.
- §1 client B `rueidis`: nhanh hơn nhờ pipeline tự động; API khác hẳn, ít tài liệu, tốc độ không cần ở tải lab: loại.
- §1 test **A db riêng + tiền tố khoá ngẫu nhiên, chỉ xoá khoá của mình**: không chạm db khác, chạy song song được; phải dọn bằng `SCAN`.
- §1 test B `miniredis`: thêm dependency, Lua và `TIME` không chắc giống Redis thật: loại.
- §1 test C `FLUSHDB` trước mỗi test: gõ sai số db là xoá dữ liệu dự án khác: loại.
- §2 A fixed window (`INCR` + `EXPIRE`): ở mép cửa sổ cho qua gấp đôi ngưỡng, burst không tách khỏi tốc độ: loại.
- §2 B sliding log bằng `ZSET`: chính xác; bộ nhớ O(số request) mỗi khoá: loại.
- §2 C sliding window counter: là xấp xỉ, hai khoá mỗi lớp, burst không tách: loại.
- §2 **D GCRA bằng một Lua script**: một khoá, tốc độ và burst tách riêng, nguyên tử, giờ bằng `TIME` của Redis; ~30 dòng Lua tự viết.
- §2 E `redis_rate`: thêm dependency cho ~30 dòng Lua, bộ đếm dự phòng vẫn tự viết: loại.
- §2 F chỉ đếm trong bộ nhớ: N replica là ngưỡng gấp N, deploy là về 0: loại.
- §2 IP **A `RemoteAddr`, bỏ header do client đặt**: client không giả được (RL-1); sau proxy mọi client chung một địa chỉ.
- §2 IP B `X-Forwarded-For` với số hop tin cậy: chưa có proxy để chốt số hop: loại.
- §3 chỗ đặt **A cache-aside ở feed-service**: chủ read model giữ cache; vẫn tốn một lời gọi gRPC mỗi request.
- §3 chỗ đặt B ở gateway: gateway phải hiểu dữ liệu của feed-service, hai nơi giữ bản read model: loại.
- §3 làm mới **A chỉ TTL ngắn**: không có cuộc đua xoá và ghi lại; video mới chậm tối đa bằng TTL.
- §3 làm mới B xoá khi `video.ready`: cuộc đua cache-aside để bản cũ sống tới hết TTL: loại.
- §3 stampede **A singleflight trong tiến trình**: không thêm round trip; R replica thì tối đa R truy vấn.
- §3 stampede B khoá `SET NX`: thêm round trip, khoá hết hạn giữa chừng, cần đường lui khi Redis lỗi: loại.
- §3 stampede C XFetch: vẫn cần A lúc cache trống, thêm tham số chưa có số đo: loại.
- §4 timeout **A hạn chung 3 s, riêng `GetStats` 100 ms**: deadline truyền xuống; service chết thì chờ đủ 3 s nếu không có breaker.
- §4 timeout B hạn theo method: thêm bảng phải giữ khớp mà chưa có số đo p99: loại.
- §4 retry **A `retryPolicy` của grpc-go**: không thêm thư viện, có `retryThrottling`; sai tên method thì im lặng không retry.
- §4 retry B interceptor tự viết hoặc `go-grpc-middleware/retry`: thêm code cho việc grpc-go làm sẵn: loại.
- §4 retry C không retry: service khởi động lại là lỗi thẳng tới người dùng: loại.
- §4 breaker **A `gobreaker/v2`**: half-open, đếm theo thế hệ, `IsExcluded`; một dependency mới.
- §4 breaker B tự viết: tự gánh các ca đua của half-open: loại.
- §4 breaker C service mesh: chưa có mesh, compose không có: loại.
- §4 bulkhead **A không thêm**: không giới hạn đoán mò; service chậm vẫn giữ goroutine tới 3 s.
- §4 bulkhead B semaphore theo service đích: chưa có số đo để đặt kích thước: loại.
- §5 job **A goroutine + `pg_try_advisory_xact_lock`**: như relay outbox, khoá tự nhả; giữ khoá dòng trong lúc gọi S3.
- §5 job B khoá Redis `SET NX PX`: video-service thêm Redis chỉ cho việc này, cần fencing token: loại.
- §5 job C CronJob của k8s: compose không có, không chặn được lần chạy tay chồng lên: loại.
- §5 job D lifecycle rule của bucket: chỉ xoá object, không đổi trạng thái `UPLOADING`: loại.
- §5 UP-7 A đếm mọi video `UPLOADING`: bỏ dở 3 upload là bị khoá tới 1 giờ: loại.
- §5 UP-7 **B đếm video `UPLOADING` có form còn hạn**: đúng số form còn ghi được; thêm một truy vấn đếm và một khoá advisory mỗi `InitUpload`.
- §5 UP-7 C bộ đếm Redis ở gateway: lệch với database, Redis lỗi là mất giới hạn: loại.

## Kết quả quyết định

Chọn `go-redis` với Redis không bắt buộc (§1), rate limit GCRA theo `RemoteAddr` có bộ đếm dự phòng trong bộ nhớ (§2), cache-aside trang đầu khám phá ở feed-service TTL 5 s với singleflight (§3), hạn chung 3 s, `retryPolicy` của grpc-go và `gobreaker` ở gateway (§4), job dọn trong video-service khoá advisory và UP-7 đếm form còn hạn (§5), vì Redis lỗi không làm sập feed hay bỏ trống giới hạn đăng nhập, không thêm hệ thống mới và mọi lời gọi ra ngoài có hạn; từng phần ở §1–§7, phân tích phương án ở phụ lục.

### 1. Redis

Chọn client **A** (`go-redis` **v9.23.0**, như [ADR-0007](0007-go-monorepo-toolchain-and-stage1-scope.md) mục 3) và cách ly test **A**.

- **Cấu hình:** một biến `REDIS_URL` dạng `redis://<host>:<port>/<db>`; native: gateway `redis://127.0.0.1:6379/10`, feed-service `redis://127.0.0.1:6379/14`; compose `redis://host.docker.internal:6379/<db>`. Gói `internal/redisx` dựng client với dial **100 ms**, đọc/ghi **50 ms**, chờ pool **50 ms**, `ContextTimeoutEnabled: true`; lỗi không in URL (trên cloud URL chứa mật khẩu).
- **Khởi động được khi Redis lỗi:** không ping bắt buộc; `/readyz` **không** kiểm Redis, vì mọi chỗ dùng Redis đều có đường lui và rút pod thì mất cả đường lui. **Mọi khoá có TTL** (Redis local `maxmemory 0`, `noeviction`). Tiền tố khoá theo service: gateway `svp:gw:`, feed-service `svp:feed:` (qua constructor; chuẩn bị cho ACL theo tiền tố, số db không phải ranh giới quyền, IN-7).
- **Test:** db **15** qua `SVP_TEST_REDIS_URL` (`redis://127.0.0.1:6379/15`); `internal/redistest` từ chối URL không phải `127.0.0.1`/`localhost` cổng 6379 db 15, mỗi test một tiền tố ngẫu nhiên, chỉ xoá khoá của mình, **không** `FLUSHDB`/`FLUSHALL`; thiếu biến thì `t.Skip`. db 0, 5 và **7** chứa dữ liệu dự án khác: không dùng. Cỡ dữ liệu vài MB ở tải lab.

### 2. Rate limit ở gateway

Biện pháp JWT-4, JWT-6, JWT-9, UP-7 (phần route), RL-1, RL-2, RL-3, RL-6. Chọn thuật toán **D** và IP **A**; số hop proxy tin cậy là việc bắt buộc của bước đưa gateway ra sau Envoy Gateway (Hệ quả).

| Lớp | Route | Khoá | Redis tốt | Redis lỗi |
| --- | --- | --- | --- | --- |
| `register` | `POST /auth/register` | IP | 60/giờ, burst 20 | đóng mềm: bộ đếm trong bộ nhớ 30/giờ, burst 10 |
| `login-ip` | `POST /auth/login` | IP | 60/phút, burst 30 | đóng mềm: 30/phút, burst 15 |
| `login-email` | `POST /auth/login` | (IP, email) | 10/giờ, burst 5 | đóng mềm: 5/giờ, burst 3 |
| `upload` | `POST /videos` | `user_id` | 30/giờ, burst 10 | đóng mềm: 15/giờ, burst 5 |
| `write` | `PUT`/`DELETE /videos/{id}/like`, `POST /videos/{id}/views`, `PUT`/`DELETE /me/following/{id}`, `POST /videos/{id}/complete` | `user_id` | 120/phút, burst 60 | mở |
| `read` | `GET /feed/following`, `GET /feed/explore`, `GET /videos/{id}` | `user_id` | 600/phút, burst 200 | mở |
| `view-once` (RL-3) | `POST /videos/{id}/views` | (`user_id`, `video_id`) | một lượt mỗi 60 s | mở (chuyển tiếp) |

- **Cách đếm:** mọi lần gọi đều đếm, `healthz`/`readyz` không giới hạn. GCRA: khoảng phát `T` = chu kỳ / rate; mỗi request `tat' = max(tat, now) + T`, cho qua nếu `tat' − now ≤ T × burst`, lưu `tat'` với `PEXPIRE` = `tat' − now`; từ chối thì không đổi `tat`, `Retry-After` = `tat' − now − T × burst`. Đọc, tính, ghi trong **một Lua script** (`EVALSHA`), giờ bằng `TIME` của Redis. `login`: `login-ip` trước khi đọc thân request, rồi decode JSON và `login-email`; lớp theo user chạy **sau** kiểm JWT; `POST /videos/{id}/views` qua cả `write` lẫn `view-once`.
- **Redis lỗi (RL-2):** mỗi lần gọi Redis có hạn **50 ms**, lỗi hoặc quá hạn là "Redis lỗi". **Đóng mềm** = bộ đếm GCRA cùng công thức bằng Go trong bộ nhớ từng instance (map + mutex + quét khoá hết hạn), ngưỡng bằng nửa; **mở** = cho qua. Log WARN `rate limit store unavailable, using fallback` không quá một dòng mỗi 10 s.
- **Vượt ngưỡng:** 429 `application/problem+json` ([mã lỗi](../reference/contracts.md#mã-lỗi-grpc-sang-http-ở-gateway)), `code` **`RATE_LIMITED`**, `detail` `"too many requests"`, header `Retry-After` (giây, làm tròn lên, tối thiểu 1).
- **RL-3:** khoá view-once đặt bằng `SET NX PX 60000`; lượt thứ hai của cùng cặp trong 60 s trả **202 như thường nhưng không gọi engagement-service**. Chuyển tiếp `RecordView` lỗi (503/504) thì `DEL` khoá (best-effort) để lần thử lại vẫn được đếm. Redis lỗi thì chuyển tiếp như thường.
- **Khoá** `svp:gw:rl:<lớp>:<định danh>`: IP lấy từ `RemoteAddr`, **bỏ qua** `X-Forwarded-For`, `X-Real-IP`, `Forwarded` (RL-1), IPv6 gộp theo /64; email là SHA-256 (hex, cắt 32 ký tự) của email đã chuẩn hoá (`TrimSpace` + `ToLower`), **không có email thô trong Redis** (JWT-8), không HMAC (khoá sống tối đa 30 phút); `view-once` là `<user_id>:<video_id>`, chỉ đặt khi `{video_id}` là UUID dạng chuẩn (`internal/ids.Parse`), id khác chuyển tiếp để engagement-service trả 400 `INVALID_VIDEO_ID`. Mã ở `services/gateway/internal/ratelimit`, gắn ở `services/gateway/internal/api`; 429 ghi vào `services/gateway/openapi.yaml`.

### 3. Cache feed khám phá

Chọn chỗ đặt **A**, làm mới **A**, chống stampede **A**. Cache-aside ở **feed-service**, chỉ **trang đầu** (`page_token` rỗng): khoá `svp:feed:explore:v1:first:<page_size đã chuẩn hoá>` (0 → 10, trên 50 → 50), giá trị là bytes protobuf của `GetExploreFeedResponse`, **TTL 5 s**; `v1` để đổi định dạng giá trị.

- **Không** xoá chủ động khi có video mới: video mới vào khám phá chậm tối đa 5 s, chấp nhận vì khám phá không có NFR độ tươi riêng (NFR 10 s là của feed following).
- **Singleflight** (`golang.org/x/sync/singleflight`, `golang.org/x/sync` đã có `// indirect`) cho mỗi khoá; lần đọc Postgres chạy với `context.WithoutCancel` + hạn riêng **2 s**, để client đầu huỷ không làm hỏng các request đang chờ. Redis lỗi hoặc quá **50 ms** thì đọc Postgres (vẫn qua singleflight) và không báo lỗi; ghi cache lỗi thì bỏ qua; Postgres lỗi thì trả lỗi như cũ. Mỗi lần đọc Postgres cho trang đầu log INFO `explore page loaded from database` kèm `page_size`. **Số đo:** N request đồng thời lúc cache trống → đúng **1** lần đọc Postgres (test Go và diễn tập); trước đó là N lần.

### 4. Timeout, retry, circuit breaker, bulkhead

Timeout **A**, retry **A**, circuit breaker **A**, bulkhead **A**. Mọi lời gọi gRPC đều có deadline (chỉ gateway gọi gRPC); bảng kiểm kê mọi lời gọi ra ngoài và hạn của chúng ở phụ lục. Khoảng trống ngoài gRPC (việc sau): Postgres trong vòng nền (relay, consumer, projector, dọn timeline) không có hạn riêng, `DATABASE_URL` không đặt `connect_timeout`/`statement_timeout`, client Kafka và S3 dùng mặc định thư viện.

- **Timeout:** `callTimeout` **3 s** cho mọi lời gọi gRPC, `statsTimeout` **100 ms** (ADR-0009 mục 9), Redis **50 ms**.
- **Retry:** service config lúc dial, mọi lần thử trong cùng deadline 3 s; chỉ method idempotent (`Follow`, `Unfollow`, `GetVideo`, `CompleteUpload`, `GetFollowingFeed`, `GetExploreFeed`, `Like`, `Unlike`), chỉ mã `UNAVAILABLE`, `maxAttempts` 3, `initialBackoff` `0.05s`, `maxBackoff` `0.2s`, `backoffMultiplier` 2; `retryThrottling` `maxTokens` 10, `tokenRatio` 0.1 (đếm riêng mỗi `ClientConn`; cấu hình JSON đầy đủ ở phụ lục). **Không retry** `Register`, `Login`, `InitUpload`, `RecordView`, `GetStats`; `DEADLINE_EXCEEDED` không retry.
- **Circuit breaker:** `github.com/sony/gobreaker/v2` **v2.4.0**, một breaker cho mỗi service đích ở gateway (user, video, feed, engagement), unary client interceptor; retry của grpc-go chạy bên dưới. **Tính là lỗi:** `UNAVAILABLE` không kèm `ErrorInfo`, `DEADLINE_EXCEEDED`; riêng `GetStats` chỉ tính `UNAVAILABLE` đó. **Không tính:** mã nghiệp vụ (tính như thành công, `IsSuccessful`), `CANCELLED`, và `UNAVAILABLE` **kèm `ErrorInfo`** domain `svp` reason `DEPENDENCY_UNAVAILABLE` (`IsExcluded`; ví dụ `RecordView` khi Redpanda chết, `CompleteUpload` khi MinIO chết), vì breaker chỉ trả lời "service có tới được không".
- **Mở** khi 5 lỗi liên tiếp, hoặc ≥ 20 lời gọi với tỉ lệ lỗi ≥ 50% trong cửa sổ trượt 10 s (`Interval` 10 s, `BucketPeriod` 1 s); **mở 5 s** rồi half-open cho **1** lời gọi (`MaxRequests` 1), thành công thì đóng, lỗi thì mở lại 5 s. Mở thì trả ngay `codes.Unavailable` (503), feed trả trang không `stats` mà không chờ 100 ms. Đổi trạng thái log WARN `circuit breaker state changed` kèm `target`, `from`, `to`. `grpc.health.v1.Health/Check` của `/readyz` **bỏ qua breaker**. Service → service không có lời gọi đồng bộ nên không có breaker.
- **Bulkhead:** không thêm; xem lại bằng k6. **Tiêu chí đo:** tắt engagement-service, sau khi breaker mở thì `PUT /videos/{id}/like` trả 503 trong **< 100 ms**; bật lại thì breaker tự đóng và like trả 204.

### 5. Job dọn upload bỏ dở và UP-7

Job **A**, UP-7 **B**. Job vẫn giữ luật 4 của ADR-0004 (một instance một lúc), nên ADR-0004 không bị chỉnh.

- **Job:** trong **video-service** (goroutine như relay), chu kỳ **5 phút**, hạn `UPLOADING` **1 giờ**, lô **100** video mỗi transaction. Mỗi lô: `pg_try_advisory_xact_lock(<hằng số int64 riêng>)`, khác `lockID` của `internal/outbox`, không được khoá thì bỏ lượt; (1) `SELECT ... FOR UPDATE` tối đa 100 video `UPLOADING` quá hạn, `ORDER BY created_at`; (2) xoá object `uploads/<video_id>` từng cái; (3) chuyển `FAILED` **chỉ** các video đã xoá được, `WHERE status = 'UPLOADING'`.
- **Hạn mỗi lô 30 s** cho cả transaction; hết hạn thì rollback, video giữ `UPLOADING`, lượt kết thúc. **Chạy lô tiếp ngay chỉ khi lô vừa rồi đủ 100 video và cả 100 đã `FAILED`**; ngược lại kết thúc lượt, chờ chu kỳ sau (không thì S3 lỗi với ≥ 100 video quá hạn thành vòng lặp không nghỉ). Đua với `CompleteUpload` an toàn nhờ khoá dòng: job thắng thì `CompleteUpload` trả `FAILED_PRECONDITION` `VIDEO_FAILED`. Biến `UPLOAD_ABANDON_AFTER` (mặc định `1h`), `UPLOAD_SWEEP_INTERVAL` (mặc định `5m`), chỉ diễn tập đặt ngắn; dưới 15 phút (hạn form) chỉ dùng cho diễn tập.
- **UP-7:** mỗi user tối đa **3** video `UPLOADING` có form còn hạn (`created_at` trong 15 phút gần nhất, hạn form của ADR-0004; 3 × 500 MB = 1,5 GB). Đếm và `INSERT` trong một transaction dưới `pg_advisory_xact_lock(hashtextextended('video-upload-author:' || author_id, 0))`. Vượt thì `RESOURCE_EXHAUSTED`, reason **`TOO_MANY_UPLOADS`** (→ 429); comment của `InitUpload` trong `proto/svp/video/v1/video_service.proto` thêm lỗi này. Migration `00003` của video-service: hai index một phần `WHERE status = 'UPLOADING'`: `(author_id, created_at)` và `(created_at)`.

### 6. Việc treo của phần B: `title` đã trim ở feed-service

feed-service kiểm `title` của `video.ready` sau khi trim nhưng lưu bản nguyên văn. Quyết định: lưu **bản đã trim**, kiểm và lưu cùng một giá trị.

### 7. Diễn tập và số đo

Qua `Makefile` trên stack compose, script ở `deploy/compose/drills/`: `drill-rate-limit` (429 `RATE_LIMITED` có `Retry-After`; Redis không tới được thì login vẫn bị giới hạn bằng bộ đếm dự phòng; UP-7 → 429 `TOO_MANY_UPLOADS`), `drill-engagement-down` (breaker mở thì like 503 < 100 ms, feed 200 không `stats`, bật lại thì tự đóng), `measure-explore-cache` (N request đồng thời → 1 dòng `explore page loaded from database`), `drill-upload-cleanup` (video bỏ dở quá hạn → `FAILED`, object bị xoá). **Giả Redis lỗi** bằng cách dựng lại gateway với `REDIS_URL` trỏ tên miền `.invalid` (RFC 2606), **không** tắt Redis native dùng chung. Script diễn tập và smoke xoá khoá `svp:gw:rl:register:*` ở db 10 (`SCAN` + `DEL`, không `FLUSHDB`), **chỉ ở lab local**. `make smoke`: lượt xem thứ hai trong 60 s vẫn 202 nhưng không được đếm (RL-3).

### Hệ quả

- Tốt: login và đăng ký luôn có giới hạn kể cả khi Redis lỗi (dò mật khẩu một tài khoản còn 10 lần mỗi giờ mỗi IP mà không khoá được chủ thật); spam lượt xem bị chặn mà client không biết (RL-3), ghi rác theo `video_id` bị giữ ở 2 lần/s mỗi tài khoản (RL-6), mở form upload hàng loạt bị chặn (UP-7); Redis lỗi không sập feed; N request đồng thời → 1 truy vấn mỗi instance mỗi 5 s; service chết thì fail nhanh (503 < 100 ms) thay vì 3 s mỗi request; upload bỏ dở không nằm mãi.
- Xấu: thêm hai dependency trực tiếp (`go-redis`, `gobreaker`), `golang.org/x/sync` thành direct. Route có rate limit thêm 1–3 lần gọi Redis; Redis treo cộng tới 100–150 ms vào các route đó, ngang ngân sách p99 150 ms. Bộ đếm dự phòng lỏng đi N lần với N instance và về 0 mỗi lần deploy. IP từ `RemoteAddr` **chỉ đúng ở compose**: sau Envoy Gateway mọi client chung bucket `login-ip` và `register`; đọc `X-Forwarded-For` với số hop tin cậy (RL-1) là **điều kiện tiên quyết** trước khi đưa gateway ra sau Envoy Gateway. Khoá `login-email` là SHA-256 không muối (tối đa 30 phút). RL-3 chỉ chặn 60 s, nhiều tài khoản giả vẫn đẩy được lượt xem. Cache khám phá trễ tới 5 s; breaker chung cho mọi method của một service; lỗi phụ thuộc không mở breaker nên không fail nhanh (Redpanda chết thì mỗi `RecordView` chờ 2 s rồi 503); retry chỉ cho `UNAVAILABLE`; `GetStats` không tính `DEADLINE_EXCEEDED`; job dọn giữ khoá dòng tối đa 30 s trong lúc gọi S3 và kết thúc lượt ở lô đầu có video xoá lỗi; vòng nền đọc Postgres chưa có hạn riêng.
- Xem lại khi: k6 cho thấy người dùng giả hợp lệ nhận 429 hoặc lạm dụng lọt dưới ngưỡng (chỉnh bảng mục 2); Redis treo làm p99 chịu thêm 50 ms mỗi lần gọi (bọc Redis bằng breaker); bộ đếm dự phòng chạy quá 1% thời gian hoặc hơn 3 instance gateway (chia ngưỡng theo số instance); breaker mở oan hoặc một method hỏng kéo cả service (tách breaker theo method); trang đầu khám phá tốn quá 10% thời gian Postgres của feed-service ở 1.000 req/s hoặc hơn 10 replica (khoá phân tán hoặc làm mới sớm); có NFR độ tươi khám phá dưới 5 s; lô của job dọn chạm hạn 30 s hoặc `CompleteUpload` p99 tăng (tách bước gọi S3 khỏi transaction); còn video `UPLOADING` tạo hơn 2 giờ trước; lượt xem dùng để xếp hạng (RL-3 dài hơn 60 s và chống tài khoản giả).

## Xác nhận

Đã kiểm ngày 2026-10-11 trước khi quyết (bảng lệnh và kết quả ở phụ lục): version `go-redis`, `gobreaker`, API của hai thư viện, hành vi retry của grpc-go, Redis local, đua `CompleteUpload` với `FAILED`. Sau khi làm: test Go cho `ratelimit`, `breaker`, `sweep` và cache khám phá; bốn diễn tập ở mục 7 (`rate-limit.sh`, `engagement-down.sh`, `measure-explore-cache.sh`, `upload-cleanup.sh`); `make smoke`.

## Hiện thực ở

- Redis không bắt buộc (§1): `internal/redisx/`, `internal/redistest/`; Redis native qua `host.docker.internal`, mỗi service một db và các biến Redis, hạn dọn upload, cache của từng service ở `deploy/compose/compose.yaml`; Valkey của k3d với `noeviction` như Redis native ở `deploy/helm/svp-data/templates/valkey.yaml`.
- Rate limit (§2): `services/gateway/internal/ratelimit/`, problem `RATE_LIMITED` ở `services/gateway/internal/httpx/problem.go`, `services/gateway/cmd/gateway/main.go`, `services/gateway/openapi.yaml`, `deploy/k8s/values/services/gateway.yaml`.
- Cache feed khám phá (§3): `services/feed-service/internal/server/`, `services/feed-service/cmd/feed-service/main.go`, `deploy/k8s/values/services/feed-service.yaml`.
- Timeout, retry, circuit breaker, bulkhead (§4): `services/gateway/internal/breaker/`, `services/gateway/internal/api/`, `services/gateway/cmd/gateway/main.go`.
- Job dọn upload bỏ dở và UP-7 (§5): `services/video-service/internal/server/sweep.go`, `services/video-service/internal/server/server.go`, `services/video-service/migrations/00003_index_uploading_videos.sql`, `services/video-service/cmd/video-service/main.go`.
- Diễn tập và số đo (§7): `deploy/compose/drills/` (`rate-limit.sh`, `measure-explore-cache.sh`, `upload-cleanup.sh`, `engagement-down.sh`, `measure-freshness.sh`, `measure-ready.sh`, `alert-to-sentry.sh`), `deploy/compose/smoke.sh`, `deploy/compose/lib.sh` (xoá khoá rate limit đăng ký), `deploy/compose/compose.mk`, `Makefile`; cảnh báo của breaker và rate limit ở `deploy/observability/prometheus/rules/svp-alerts.yaml`; thí nghiệm cloud `deploy/k8s/cloud/chaos/b-network-delay-engagement.yaml`.

## Thông tin thêm

Phụ lục: [`appendix/0010-redis-ratelimit-cache-resilience-stage2c.md`](appendix/0010-redis-ratelimit-cache-resilience-stage2c.md) (trạng thái gốc, bối cảnh đầy đủ, bảng kiểm chứng, phân tích phương án, lý do từng ngưỡng, kiểm kê lời gọi ra ngoài, cấu hình retry JSON, các bước của job dọn, hệ quả đầy đủ).

### Chỉnh bởi

- §2: [0016](0016-web-client.md): bảng lớp rate limit thêm `refresh`.
- §2: [0018](0018-web-profiles-public-video-upload.md): thêm lớp `public`.
- §4: [0031](0031-chaos-findings-feed-engagement-tempo.md): bulkhead "không thêm" và timeout "một hạn chung" cho Like/Unlike của engagement-service bị thay một phần: hai pool Postgres tách ngân sách, hạn ghi 1 s phía server, lỗi Postgres trả `DEPENDENCY_UNAVAILABLE` không thử lại.
