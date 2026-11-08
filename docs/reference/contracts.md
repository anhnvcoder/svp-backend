# Contract: proto, topic, phân trang, mã lỗi và REST

Trang này trả lời: service nói chuyện với nhau và với client theo quy ước nào: bố cục `proto/`, topic event, page token của feed,
cách gateway đổi mã lỗi gRPC sang HTTP và danh sách route REST. Nguồn sự thật là [`proto/`](../../proto/) và
[`services/gateway/openapi.yaml`](../../services/gateway/openapi.yaml); trang này tóm tắt chúng và ghi hai quyết định không nằm trong
file nào ở đó: cách mã hoá cursor ([phân trang feed](#phân-trang-feed)) và cách đổi mã lỗi sang HTTP
([mã lỗi](#mã-lỗi-grpc-sang-http-ở-gateway)).

Contract nội bộ quản lý bằng `buf` theo [ADR-0002](../adr/0002-sync-rest-edge-grpc-internal.md). Các quyết định khó đảo ngược (kiểu
ID, envelope event, cách chia topic, versioning, bố cục thư mục, danh tính người gọi, đường dẫn media) và lựa chọn đã cân nhắc ở
[ADR-0006](../adr/0006-contract-ids-and-event-envelope.md).

## Bố cục và quy ước chung

Vì sao: [ADR-0006](../adr/0006-contract-ids-and-event-envelope.md), [ADR-0007](../adr/0007-go-monorepo-toolchain-and-stage1-scope.md),
[ADR-0029](../adr/0029-immutable-media-versions.md), [ADR-0042](../adr/0042-caller-identity-grpc.md).

```text
buf.yaml                         v2, module proto, lint STANDARD, breaking FILE, không deps
proto/svp/
├── event/v1/event.proto         EventMeta: envelope chung của mọi event
├── user/v1/                     user_service.proto, events.proto
├── video/v1/                    video_service.proto, events.proto
├── engagement/v1/               engagement_service.proto, events.proto
├── feed/v1/                     feed_service.proto
└── media/v1/events.proto        event của media-worker (không có service gRPC)
```

- Kiểm từ gốc repo: `buf lint` (sạch, không output) và `buf build`. `buf breaking` (luật `FILE`) so với nhánh `main` ở CI.
  Sinh code Go theo [ADR-0007](../adr/0007-go-monorepo-toolchain-and-stage1-scope.md): managed mode trong `buf.gen.yaml` (không
  ghi tay `go_package`), code ra ở `gen/go`, và code sinh ra được commit (`make generate`).
- ID là UUIDv7, trong proto là `string` 36 ký tự chữ thường, trong Postgres là `uuid`, sinh ở code Go.
- Người gọi không nằm trong request: gateway chuyển tiếp access token đã kiểm trong gRPC metadata `authorization`, service
  kiểm lại rồi lấy người gọi từ `sub` ([xác thực](../architecture.md#64-xác-thực)).
- API và event mang object key (`uploads/<video_id>`, `media/<video_id>/<version>/master.m3u8`; video `READY` trước khi có
  version giữ key `media/<video_id>/master.m3u8`), không mang URL; mọi object HLS và thumbnail mang
  `Cache-Control: max-age=31536000, immutable` ([ADR-0029](../adr/0029-immutable-media-versions.md)); gateway ghép URL
  công khai từ cấu hình của môi trường. Ngoại lệ: `upload_url` của presigned POST.
- Mỗi RPC có comment ghi ngữ nghĩa, idempotency và các mã lỗi chính.

## Topic

Vì sao: [ADR-0003](../adr/0003-async-events-outbox.md), [ADR-0006](../adr/0006-contract-ids-and-event-envelope.md).

Một topic cho một luồng thực thể của một producer, không phải cho mỗi loại event, để mọi event của một thực thể giữ thứ
tự trên một partition. Mỗi topic có một message bọc: field 1 là `svp.event.v1.EventMeta meta` (`event_id` UUIDv7,
`occurred_at`), sau đó `oneof event` với mỗi loại event của
[danh mục event](../architecture.md#5-khối) là một nhánh.

| Topic | Message bọc | Event (nhánh `oneof`) | Phát | Key |
| --- | --- | --- | --- | --- |
| `user.follows.v1` | `svp.user.v1.FollowEvent` | `user.followed` (`UserFollowed`), `user.unfollowed` (`UserUnfollowed`) | user-service | `follower_id` |
| `video.lifecycle.v1` | `svp.video.v1.VideoEvent` | `video.uploaded` (`VideoUploaded`), `video.ready` (`VideoReady`) | video-service | `video_id` |
| `media.transcodes.v1` | `svp.media.v1.TranscodeEvent` | `transcode.completed` (`TranscodeCompleted`), `transcode.failed` (`TranscodeFailed`) | media-worker | `video_id` |
| `engagement.views.v1` | `svp.engagement.v1.ViewEvent` | `view.recorded` (`ViewRecorded`) | engagement-service | `video_id` |

- DLQ: `<topic>.dlq` ([ADR-0003](../adr/0003-async-events-outbox.md)).
- Trace context (`traceparent`) đi trong header Kafka theo quy ước OpenTelemetry, không nằm trong proto.
- Thêm loại event = thêm một nhánh `oneof`; consumer gặp nhánh chưa biết thì bỏ qua và commit offset.

## Phân trang feed

Vì sao: [ADR-0005](../adr/0005-feed-fan-out-on-write.md), [ADR-0009](../adr/0009-engagement-feed-stage2b.md) mục 8,
[ADR-0018](../adr/0018-web-profiles-public-video-upload.md) §4.

Field theo Google AIP-158: request có `page_size`, `page_token`; response có `next_page_token`.

- `page_size` 0 thì dùng mặc định 10; lớn hơn 50 thì hạ về 50; số âm thì `INVALID_ARGUMENT`.
- `next_page_token` rỗng nghĩa là hết trang.
- `page_token` **mờ** với client và gateway: gateway chuyển nguyên giá trị (query `?cursor=`), không đọc, không tự tạo.
- Bên trong, token là base64url không padding của bytes protobuf gồm (`published_at`, `video_id`) của item cuối trang,
  đúng cursor keyset của [ADR-0005](../adr/0005-feed-fan-out-on-write.md): field 1 `published_at` varint int64 micro giây
  Unix, field 2 `video_id` 16 byte, khoảng 36 ký tự. feed-service mã hoá tay bằng gói `protowire`, không có file
  `.proto` ([ADR-0009](../adr/0009-engagement-feed-stage2b.md) mục 8); token **không** nằm trong `proto/` vì không phải
  contract công khai, và đổi được bất cứ lúc nào (token cũ không giải mã được thì client tải lại từ trang đầu).
- Token dài quá **64 ký tự** bị từ chối trước khi giải mã. Token hỏng (không phải base64url, giải mã lỗi, thiếu field,
  sai kiểu wire, `video_id` không đủ 16 byte) thì `INVALID_ARGUMENT`, reason `INVALID_PAGE_TOKEN`; field lạ bỏ qua.
  `page_size` âm thì reason `INVALID_PAGE_SIZE`.
- **Không ký HMAC.** Token chỉ lọc trong timeline của chính người gọi (`user_id` lấy từ access token đã kiểm, không từ page token),
  hoặc trong feed khám phá vốn công khai; sửa token chỉ đổi vị trí đọc trong dữ liệu mình vốn được xem. Lựa chọn khác: ký HMAC
  để phát hiện sửa (thêm quản lý khoá, không chặn được gì thêm); dùng `OFFSET` (bị lệch trang khi có video mới, ADR-0005).
- **Danh sách video theo tác giả** (`ListAuthorVideos` của video-service,
  [ADR-0018](../adr/0018-web-profiles-public-video-upload.md) §4) dùng cùng định dạng và cùng luật, với field 1 là
  `created_at` (thứ tự `created_at DESC, video_id DESC`, vì video chưa `READY` không có `published_at`), qua gói chung
  `internal/pagetoken`. Quyền xem (tác giả thấy mọi trạng thái, người khác chỉ `READY`) đến từ `author_id` của request và
  người gọi, không từ token, nên token vẫn không cần ký.

## Mã lỗi gRPC sang HTTP ở gateway

Vì sao: [ADR-0002](../adr/0002-sync-rest-edge-grpc-internal.md), [ADR-0010](../adr/0010-redis-ratelimit-cache-resilience-stage2c.md),
[ADR-0043](../adr/0043-idempotency-key.md). Bảng trong code: `grpcToHTTP` và `reasonToHTTP` ở
[`services/gateway/internal/httpx/problem.go`](../../services/gateway/internal/httpx/problem.go).

Service trả mã gRPC chuẩn, kèm lý do máy đọc được bằng `google.rpc.ErrorInfo.reason` trong status details (dạng
`UPPER_SNAKE_CASE`, ví dụ `VIDEO_NOT_FOUND`; gắn bằng gói Go `errdetails`, proto không cần import `google/rpc`). Gateway đổi
theo bảng:

| Mã gRPC | HTTP |
| --- | --- |
| `OK` | 200 |
| `INVALID_ARGUMENT` | 400 |
| `FAILED_PRECONDITION` | 400 |
| `OUT_OF_RANGE` | 400 |
| `UNAUTHENTICATED` | 401 |
| `PERMISSION_DENIED` | 403 |
| `NOT_FOUND` | 404 |
| `ALREADY_EXISTS` | 409 |
| `ABORTED` | 409 |
| `RESOURCE_EXHAUSTED` | 429 |
| `CANCELLED` | 499 (client đóng kết nối, mã không chuẩn theo nginx; client thường không nhận được) |
| `UNKNOWN` | 500 |
| `INTERNAL` | 500 |
| `DATA_LOSS` | 500 |
| `UNIMPLEMENTED` | 501 |
| `UNAVAILABLE` | 503 |
| `DEADLINE_EXCEEDED` | 504 |

Thân lỗi theo RFC 9457 (`Content-Type: application/problem+json`):

```json
{
  "type": "about:blank",
  "title": "Not Found",
  "status": 404,
  "detail": "video not found",
  "code": "VIDEO_NOT_FOUND",
  "trace_id": "4bf92f3577b34da6a3ce929d0e0e4736"
}
```

- `type` là `about:blank` và `title` là tên chuẩn của mã HTTP; `detail` là message của service; `code` là
  `ErrorInfo.reason`, không có thì là tên mã gRPC (`NOT_FOUND`); `trace_id` để tra log và trace.
- `trace_id` là trace ID của span OpenTelemetry mà gateway mở cho request: trace gốc mới (`traceparent` của client bị bỏ
  qua, [ADR-0011](../adr/0011-observability-stage3.md) §3), trừ khi gateway bật `TRUST_TRACE_CONTEXT` (compose và k3d,
  [ADR-0019](../adr/0019-web-k3d-supply-chain-observability.md) §7): khi đó request từ web mang trace của web; cùng giá trị với
  trace trong Tempo, field `trace_id` của log và tag `trace_id` của event lỗi. `/healthz`, `/readyz` không có span, nên problem
  của chúng (503 `NOT_READY`) có `trace_id` rỗng.
- Với mã 5xx, gateway **không** trả message gốc và lý do của service (tránh lộ chi tiết nội bộ): `detail` bỏ trống, `code`
  là tên mã gRPC, chỉ `trace_id` để tra.
- Lỗi do chính gateway sinh (JWT sai hoặc hết hạn: 401; vượt rate limit: 429) dùng cùng định dạng.
- Vượt rate limit ([ADR-0010](../adr/0010-redis-ratelimit-cache-resilience-stage2c.md) mục 2): 429, `code` `RATE_LIMITED`,
  `detail` `"too many requests"`, header `Retry-After` tính bằng giây (làm tròn lên, tối thiểu 1). Khác với 429 do service
  trả qua `RESOURCE_EXHAUSTED` (`TOO_MANY_UPLOADS` của `POST /videos`, `SERVER_BUSY` của login): những lỗi đó không có
  `Retry-After`.
- Hai reason có mã HTTP riêng thay mã theo bảng: `IDEMPOTENCY_KEY_MISMATCH` (`INVALID_ARGUMENT`) là 422, `VIDEO_NOT_UPLOADING`
  (`FAILED_PRECONDITION`) là 409 ([ADR-0043](../adr/0043-idempotency-key.md)).
- Circuit breaker của service đích đang mở ([đọc feed](../architecture.md#62-đọc-feed)): gateway không gọi mạng mà trả ngay
  `UNAVAILABLE`, tức 503 với `code` `UNAVAILABLE`, `detail` rỗng, như mọi 5xx. Service báo phụ thuộc của nó chết (`UNAVAILABLE`
  kèm reason `DEPENDENCY_UNAVAILABLE`, ví dụ `RecordView` khi Kafka chết, `CompleteUpload` khi object store chết) cũng là 503
  không lộ reason. Like/Unlike khi Postgres chậm quá hạn ghi 1 s phía server hay không tới được cũng trả lỗi đó, kèm trailer
  `grpc-retry-pushback-ms: -1` nên gateway không thử lại ([ADR-0031](../adr/0031-chaos-findings-feed-engagement-tempo.md) §2).
- Lỗi từ engagement-service khi ghép feed **không** đi qua bảng này: gateway nuốt lỗi và trả feed không kèm số đếm
  (graceful degradation, [đọc feed](../architecture.md#62-đọc-feed)).

## REST ở gateway

Vì sao: [ADR-0002](../adr/0002-sync-rest-edge-grpc-internal.md), [ADR-0007](../adr/0007-go-monorepo-toolchain-and-stage1-scope.md)
mục 8, [ADR-0033](../adr/0033-svp-web-repo.md).

REST ở biên được viết tay trong [`services/gateway/openapi.yaml`](../../services/gateway/openapi.yaml) (OpenAPI 3.1); file đó là
nguồn của danh sách route, schema và mã lỗi từng route. JSON dùng `snake_case`, khớp tên field trong proto; thời gian theo RFC 3339,
UTC. File này là hợp đồng với web client ở repo khác: `info.version` theo semver, phát hành có chữ ký trên GHCR
([ba repo và hợp đồng API](../explanation/delivery.md#ba-repo-và-hợp-đồng-api)). Mọi field thêm sau bản đầu là tuỳ chọn nên client
cũ không vỡ. Route đăng ký ở `services/gateway/internal/api/api.go`:

| Route | Xác thực | Lớp rate limit | Việc |
| --- | --- | --- | --- |
| `POST /auth/register` | không | `register` | đăng ký; `handle`, `display_name` tuỳ chọn (thiếu handle thì sinh `u_` + 12 hex); trùng handle 409 `HANDLE_ALREADY_TAKEN`, sai dạng 400 `INVALID_HANDLE` |
| `POST /auth/login` | không | `login-ip`, `login-email` | đổi email và mật khẩu lấy access token và refresh token |
| `POST /auth/refresh` | không (refresh token trong thân) | `refresh` | đổi refresh token lấy cặp token mới; token đã trình không dùng lại được ([ADR-0016](../adr/0016-web-client.md) §2–5) |
| `POST /auth/logout` | không (refresh token trong thân) | `refresh` | thu hồi cả họ refresh token của lần đăng nhập; idempotent, trả 204 |
| `GET /me`, `PATCH /me` | Bearer JWT | `read`, `write` | hồ sơ của mình (`user_id`, `handle`, `display_name`, không có email); đổi tên hiển thị |
| `GET /profiles/{handle}` | Bearer JWT | `read` | hồ sơ theo handle (không phân biệt hoa thường) kèm `followed_by_me`; 404 `USER_NOT_FOUND` |
| `PUT` / `DELETE /me/following/{user_id}` | Bearer JWT | `write` | follow, unfollow |
| `POST /videos` | Bearer JWT | `upload` | tạo video `UPLOADING`, trả form presigned POST: `upload_url`, `form_fields`, `expires_at` (15 phút); header `Idempotency-Key` tuỳ chọn (một UUID chữ thường trong Structured Field String, sai dạng thì 400 `INVALID_IDEMPOTENCY_KEY`): gọi lặp cùng khoá, cùng `title`, `size_bytes`, `content_type` trả cùng `video_id` với form ký mới, khác thân thì 422 `IDEMPOTENCY_KEY_MISMATCH`, video đã rời `UPLOADING` thì 409 `VIDEO_NOT_UPLOADING`; khoá có phạm vi tác giả, lưu cùng transaction với video, sống bằng đời của video ([ADR-0043](../adr/0043-idempotency-key.md)) |
| `POST /videos/{video_id}/complete` | Bearer JWT | `write` | báo upload xong: video-service `HEAD` object, chuyển `PROCESSING`, trả 202; gọi lại khi đã `PROCESSING` hay `READY` thì trả video hiện tại |
| `GET /videos/{video_id}` | Bearer JWT | `read` | đọc một video kèm `author`, `stats`; có `playlist_url`, `thumbnail_url` khi video đã `READY` |
| `GET /users/{user_id}/videos`, `GET /me/videos` | Bearer JWT | `read` | video của một tác giả, mới nhất trước, query `cursor`, `page_size` như feed; chỉ tác giả thấy video chưa `READY` |
| `GET /public/videos/{video_id}` | **không**, bỏ qua `Authorization` | `public` theo IP | video `READY` kèm `author` và số đếm không `liked_by_me`; mọi ca khác (không có, chưa `READY`, id sai dạng) cùng 404 `VIDEO_NOT_FOUND`; `Cache-Control: public, max-age=30` |
| `GET /feed/following` | Bearer JWT | `read` | feed đang theo dõi (30 ngày); query `cursor`, `page_size`; trả `items` (kèm `stats` nếu engagement-service trả kịp 100 ms) và `next_cursor` |
| `GET /feed/explore` | Bearer JWT | `read` | feed khám phá, mọi video `READY`; cùng query và dạng trả như feed following |
| `PUT` / `DELETE /videos/{video_id}/like` | Bearer JWT | `write` | like, unlike; idempotent, trả 204 |
| `POST /videos/{video_id}/views` | Bearer JWT | `write` | ghi một lượt xem, trả 202; số lượt xem cập nhật sau vài giây |
| `GET /healthz`, `GET /readyz` | không | không | liveness, readiness |

Item của feed và của danh sách video mang `author` (`user_id`, `handle`, `display_name`).

`playlist_url`, `thumbnail_url` là `MEDIA_PUBLIC_BASE_URL` + `/` + object key, ở cả item của feed. Path hay query không
phải UTF-8 hợp lệ thì gateway trả 400 `INVALID_UTF8` ở mọi route, không gọi service.

Chi tiết hiện thực của luồng upload chốt ở [ADR-0008](../adr/0008-async-upload-pipeline-stage2a.md):

- object key trong contract là nguyên văn key trong bucket, bucket chọn theo tiền tố `uploads/` hay `media/` (mục 4);
- storage có hai endpoint: nội bộ cho service gọi API S3, công khai cho URL ký trả client (mục 3);
- mỗi service chỉ một relay outbox chạy tại một thời điểm, khoá bằng `pg_try_advisory_xact_lock`, để event cùng key giữ
  thứ tự (mục 7; chỉnh câu `FOR UPDATE SKIP LOCKED` của [ADR-0003](../adr/0003-async-events-outbox.md)).

Chi tiết hiện thực của luồng feed, like và lượt xem chốt ở [ADR-0009](../adr/0009-engagement-feed-stage2b.md):

- follow, unfollow phát `user.followed` / `user.unfollowed` qua outbox của user-service, chỉ khi cạnh thật sự đổi
  (mục 1);
- feed-service giữ bản sao `follows`, `videos` và `timeline`; mọi thao tác của một tác giả khoá `pg_advisory_xact_lock`
  theo tác giả; `video.ready` fan-out bằng một câu `INSERT ... SELECT`; follow mới đưa tối đa 20 video trong 30 ngày vào
  timeline; job mỗi giờ dọn dòng quá 30 ngày (mục 6, 7);
- gateway ghép `stats` bằng một `GetStats` cho cả trang, timeout 100 ms, không retry (mục 9).

Rate limit, cache, timeout/retry/circuit breaker và job dọn upload chốt ở
[ADR-0010](../adr/0010-redis-ratelimit-cache-resilience-stage2c.md); ngưỡng của từng lớp ở
`services/gateway/internal/ratelimit/ratelimit.go`:

- mọi route trừ `/healthz`, `/readyz` có rate limit GCRA bằng một Lua script trong Valkey db 10 (mục 2): `register` theo
  IP 60/giờ, burst 20; `login-ip` theo IP 60/phút, burst 30, và `login-email` theo cặp (IP, email) 10/giờ, burst 5 (khoá chứa
  SHA-256 của email, không có email thô); `refresh` theo IP cho `/auth/refresh`, `/auth/logout` 60/phút, burst 30; `upload`
  (`POST /videos`) 30/giờ, burst 10; `write` 120/phút, burst 60; `read` 600/phút, burst 200, ba lớp sau theo `user_id`. Mọi lần
  gọi đều được đếm. IP là địa chỉ kết nối; `X-Forwarded-For` chỉ được đọc trên kết nối từ proxy tin cậy, theo
  `TRUSTED_PROXY_HOPS` và `TRUSTED_PROXY_CIDRS` (compose 0 hop, k3d 1 hop từ Envoy; RL-1,
  [ADR-0014](../adr/0014-kubernetes-local-stage4.md) §9);
- Valkey lỗi hay quá 50 ms thì `register`, `login-ip`, `login-email`, `refresh`, `upload` **đóng mềm** (bộ đếm trong bộ nhớ của
  từng instance, ngưỡng bằng nửa), `write` và `read` **mở**; gateway log WARN `rate limit store unavailable, using fallback` tối
  đa một dòng mỗi 10 s (RL-2);
- lớp `public` theo IP cho `GET /public/videos/{video_id}`: 120/phút, burst 60, Valkey lỗi thì đóng mềm 60/phút, burst 30
  ([ADR-0018](../adr/0018-web-profiles-public-video-upload.md) §6); ở compose mọi khách xem qua web chung một bucket IP;
- lượt xem thứ hai của cùng cặp (`user_id`, `video_id`) trong 60 s vẫn nhận 202 nhưng không được đếm (RL-3, khoá
  `SET NX PX 60000`); chuyển tiếp `RecordView` lỗi thì xoá khoá đó để lần thử lại được đếm;
- mỗi user tối đa 3 video `UPLOADING` có form còn hạn (tạo trong 15 phút gần nhất); quá thì 429 `TOO_MANY_UPLOADS`
  (UP-7, đếm ở video-service dưới advisory lock theo tác giả, mục 5);
- video-service chạy job dọn upload bỏ dở mỗi 5 phút, một instance một lúc nhờ `pg_try_advisory_xact_lock`: video
  `UPLOADING` quá 1 giờ bị xoá object `uploads/<video_id>` rồi chuyển `FAILED`, lô 100 video, hạn 30 s mỗi lô (mục 5);
- mọi lời gọi gRPC của gateway có deadline (3 s, `GetStats` 100 ms); hạn của lời gọi ngoài gRPC (Postgres trong vòng nền
  và consumer, produce Kafka, S3) chốt ở [ADR-0011](../adr/0011-observability-stage3.md) §11.
