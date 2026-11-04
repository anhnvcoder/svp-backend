# 0006. Contract nội bộ: ID là UUIDv7, event bọc theo topic của luồng thực thể, proto đặt ở `proto/svp/<domain>/v1`

- Trạng thái: Chấp nhận
- Ngày: 2026-10-11

## Bối cảnh và vấn đề

- [ADR-0002](0002-sync-rest-edge-grpc-internal.md) chọn gRPC bên trong, contract Protobuf quản lý bằng `buf`; [ADR-0003](0003-async-events-outbox.md) chọn event Protobuf trên Redpanda, outbox, at-least-once, key theo thực thể, và để envelope "chốt ở bước viết contract". Contract ở [`proto/`](../../proto/), tóm tắt ở [architecture.md §8](../architecture.md#8-khái-niệm-xuyên-suốt), chi tiết ở [`reference/contracts.md`](../reference/contracts.md).
- Những thứ dưới đây rất tốn để đổi về sau: kiểu ID nằm trong mọi bảng, mọi API, mọi event; event nằm lâu trên topic (giữ 7 ngày, phát lại được), nên schema event giống schema dữ liệu hơn là giống API. Cách mã hoá cursor và bảng đổi mã lỗi sang HTTP đổi được ở một chỗ, nên ghi ở `reference/contracts.md`, không ở ADR này.
- Ràng buộc: `buf` 1.73.0, bộ luật `STANDARD`, không dùng BSR hay dependency mạng; Postgres local là bản 15; outbox cần biết `event_id` trước khi commit; consumer của `user.follows` phải thấy follow và unfollow của một người theo đúng thứ tự (ADR-0003 luật 3).

## Yếu tố quyết định

Lint `STANDARD` nguyên vẹn, `buf` offline; ID sinh ở mọi instance, chèn index theo thứ tự; giữ thứ tự event của một thực thể.

## Phương án đã cân nhắc

- §1 A `proto/<service>/v1/`, package `svp.<service>.v1`: đúng chữ ADR-0002; trượt luật `PACKAGE_DIRECTORY_MATCH` của `STANDARD`: loại.
- §1 B package `user.v1` ở `proto/user/v1/`: đường dẫn ngắn; tên package chung chung dễ đụng package của thư viện khác: loại.
- §1 C giữ A, tắt luật `PACKAGE_DIRECTORY_MATCH`: đường dẫn file không còn đoán được từ package: loại.
- §1 **D `proto/svp/<domain>/v1/`, package `svp.<domain>.v1`**: lint sạch với `STANDARD` nguyên vẹn, package có tiền tố riêng; thêm một cấp thư mục.
- §2 A `bigserial`: 8 byte; outbox không biết id trước `INSERT`, lộ số lượng người dùng và video: loại.
- §2 B UUIDv4: sinh ở đâu cũng được; chèn ngẫu nhiên vào B-tree làm index phình: loại.
- §2 C ULID: có thứ tự thời gian; không phải chuẩn IETF, Postgres không có kiểu riêng: loại.
- §2 D Snowflake: 8 byte, có thứ tự; phải cấp số máy cho mỗi instance, JSON của JavaScript mất chính xác trên 2^53: loại.
- §2 **E UUIDv7 (RFC 9562)**: sinh ở mọi instance, chèn vào cuối index, kiểu `uuid` của Postgres; 16 byte, lộ thời điểm tạo.
- §3 A mỗi loại event một topic: mỗi topic một schema; follow và unfollow ở hai topic có thể đọc lệch thứ tự: loại.
- §3 **B một topic cho một luồng thực thể**: cùng key cùng partition, giữ thứ tự; consumer phải đọc cả loại mình không cần.
- §3 C metadata trong header Kafka (CloudEvents binary mode): `buf` không kiểm được header, quên header là mất `event_id`: loại.
- §3 D message bọc chung với `google.protobuf.Any`: danh sách loại event của topic không nằm trong contract: loại.
- §3 **E mỗi topic một message bọc, field 1 là envelope rồi `oneof`**: `buf` kiểm từng nhánh; consumer phải bỏ qua có chủ ý nhánh chưa biết.
- §4 luật `WIRE_JSON`: cho xoá field đã `reserved`; xoá field trong `v1` làm vỡ build service khác: giữ `FILE`.
- §4 schema registry: kiểm tương thích lúc chạy; thêm một hệ thống phải vận hành: chưa dùng.
- §5 A `user_id` của người gọi trong mỗi request: lẫn "ai đang gọi" với "gọi về ai": loại.
- §5 B truyền JWT xuống, mỗi service tự kiểm: không ai phải tin gateway; mọi service cần khoá và logic kiểm JWT: loại.
- §5 **C gateway kiểm JWT, đặt `x-user-id` vào metadata**: danh tính tách khỏi dữ liệu; service tin metadata tới khi có mTLS.
- §6 A URL tuyệt đối: URL gắn môi trường lúc phát event, phát lại hay đổi CDN là sai: loại.
- §6 **B object key**: dữ liệu không phụ thuộc môi trường; gateway phải biết base URL.

## Kết quả quyết định

Chọn bố cục `proto/svp/<domain>/v1/` (§1 D), ID UUIDv7 (§2 E), một topic cho một luồng thực thể với message bọc `oneof` (§3 B + E), luật breaking `FILE` (§4), danh tính qua `x-user-id` (§5 C) và object key thay URL (§6 B), vì giữ lint `STANDARD` nguyên vẹn và `buf` offline, ID sinh được ở mọi instance mà vẫn chèn index theo thứ tự, và event của một thực thể giữ thứ tự; từng phần ở §1–§6.

### 1. Bố cục thư mục và cấu hình `buf`

Chọn **D**. Đây là chỉnh nhỏ về đường dẫn trong ADR-0002, không đổi quyết định chính (gRPC + `buf`) của nó.

- `buf.yaml` (v2) ở gốc repo: `modules: [{path: proto}]`, `lint.use: [STANDARD]`, `breaking.use: [FILE]`, không có `deps`. Lệnh chạy từ gốc repo: `buf lint`, `buf build`.
- Domain: `user`, `video`, `engagement`, `feed` (4 service gRPC), `media` (event của media-worker, không có service gRPC), `event` (envelope dùng chung). Domain là chủ đề của contract, không phải tên service: `media` là kết quả transcode chứ không phải "media-worker".
- File: `<domain>_service.proto` cho API, `events.proto` cho event, `svp/event/v1/event.proto` cho envelope.
- Chỉ import well-known types (`google/protobuf/timestamp.proto`, `duration.proto`), có sẵn trong `buf`. Không import `google/rpc/*`, `google/api/*`: cần `deps` từ BSR, mà chưa có lý do. Chi tiết lỗi gắn bằng gói Go `errdetails` lúc chạy, không cần nằm trong proto ([mã lỗi](../reference/contracts.md#mã-lỗi-grpc-sang-http-ở-gateway)).
- `FILE` là bộ luật breaking chặt nhất: chặn cả việc chuyển message sang file khác, vì code Go sinh ra theo file.
- Chưa đặt `option go_package`: chưa có `go.mod` nên chưa biết module path; cách đặt (ghi tay trong từng file hay managed mode trong `buf.gen.yaml`) chốt ở [ADR-0007](0007-go-monorepo-toolchain-and-stage1-scope.md) §2.

### 2. Kiểu ID: UUIDv7

Chọn **E** cho mọi thực thể (user, video) và cho `event_id`.

- **Trong proto:** `string` dạng chuẩn 36 ký tự, chữ thường (`0192f1c4-...`). Cân nhắc `bytes` 16 byte (gọn hơn một nửa trên dây), nhưng `string` đọc được ngay bằng `grpcurl` và trong log, gateway trả JSON không phải đổi. Service kiểm định dạng ở biên, sai thì `INVALID_ARGUMENT`.
- **Trong Postgres:** cột `uuid`, không phải `text`.
- **Sinh ở code Go** của service sở hữu thực thể (thư viện chọn ở [ADR-0007](0007-go-monorepo-toolchain-and-stage1-scope.md) §3). Không dựa vào hàm `uuidv7()` của Postgres: hàm này chỉ có từ bản 18, máy đang cài `postgresql@15`; và outbox cần `event_id` ngay trong code trước khi commit.
- Cursor keyset (`published_at`, `video_id`) ([ADR-0005](0005-feed-fan-out-on-write.md) luật 5) và thứ tự theo `id` không phải lý do chọn UUIDv7 (phụ lục).

### 3. Envelope event và cách chia topic

Chọn **B + E**.

- Envelope `svp.event.v1.EventMeta { string event_id = 1; google.protobuf.Timestamp occurred_at = 2; }`, chỉ hai field. `event_id` là UUIDv7, sinh trước khi commit outbox, gửi lại vẫn giữ nguyên để consumer chống trùng. `occurred_at` là thời điểm thay đổi xảy ra ở producer, không phải lúc relay gửi; payload không lặp lại field này.
- Mỗi message bọc có `meta` ở field 1, `oneof event` từ field 2. Tên trong danh mục event (`user.followed`) ứng với một nhánh `oneof`. Comment của message bọc ghi tên topic, producer, key và topic DLQ.

  | Topic | Message bọc | Nhánh `oneof` | Key |
  | --- | --- | --- | --- |
  | `user.follows.v1` | `svp.user.v1.FollowEvent` | `UserFollowed`, `UserUnfollowed` | `follower_id` |
  | `video.lifecycle.v1` | `svp.video.v1.VideoEvent` | `VideoUploaded`, `VideoReady` | `video_id` |
  | `media.transcodes.v1` | `svp.media.v1.TranscodeEvent` | `TranscodeCompleted`, `TranscodeFailed` | `video_id` |
  | `engagement.views.v1` | `svp.engagement.v1.ViewEvent` | `ViewRecorded` | `video_id` |

- Tên topic: `<domain>.<luồng>.v<N>`. DLQ theo ADR-0003: `<topic>.dlq`.
- **Trace context** (`traceparent`, `tracestate`) đi trong **header Kafka** theo quy ước OpenTelemetry, không nằm trong proto: đó là dữ liệu hạ tầng, thư viện instrumentation của OpenTelemetry tự đọc ghi header, contract nghiệp vụ không phải đổi khi đổi cách tracing.
- Key partition là key của Kafka record, không lặp trong envelope; consumer đọc nó từ payload.

### 4. Versioning

- Package `v1` đi cùng hậu tố topic `.v1`.
- Trong một version chỉ thay đổi tương thích: thêm field, thêm nhánh `oneof`, thêm RPC, thêm giá trị enum. `buf breaking` với luật `FILE` chặn phần còn lại (đổi số field, đổi kiểu, đổi tên, xoá) ở CI.
- Trong `v1` không xoá field, nhánh `oneof` hay giá trị enum: đánh `[deprecated = true]` và ngừng dùng. Luật `FILE` báo lỗi khi xoá field kể cả khi số và tên đã `reserved` (`FIELD_NO_DELETE`, đã thử với buf 1.73.0), vì `FILE` giữ tương thích cả mã nguồn sinh ra: code Go đang dùng field đó sẽ không biên dịch được. `WIRE` chỉ giữ tương thích trên dây nên lỏng hơn.
- Xoá thật chỉ khi sang package `v2`: message trong `v2` khai báo `reserved` cả số lẫn tên của field cũ, để không ai dùng lại số cũ với nghĩa mới.
- Thay đổi phá vỡ: tạo package `v2` và topic `.v2`; producer phát song song cả hai bản trong thời gian chuyển, consumer chuyển dần, xong thì ngừng `v1`. Với gRPC: server phục vụ cả `v1` và `v2` cho tới khi không còn client gọi `v1`.
- Giữ `FILE`, chưa dùng `WIRE_JSON` hay schema registry (phụ lục).

### 5. Danh tính người gọi

Chọn **C**. Comment của mỗi service ghi RPC nào cần người gọi; thiếu hoặc sai định dạng `x-user-id` thì `UNAUTHENTICATED`. Rủi ro giả mạo header này (gọi thẳng service, gateway quên xoá header client gửi lên) do [threat model](../threat-model.md) xét.

**Mã lỗi đăng ký và đăng nhập:**

- `Register` với email đã tồn tại trả `ALREADY_EXISTS`. Như vậy client dò được email nào đã đăng ký. Chấp nhận ở MVP, giảm bằng rate limit ở gateway; cách triệt để (luôn trả thành công rồi gửi email xác nhận) cần hệ thống email, ngoài phạm vi.
- `Login` sai email hay sai mật khẩu đều trả `UNAUTHENTICATED` với **cùng `reason`** (`INVALID_CREDENTIALS`) và **cùng message**, không phân biệt hai trường hợp.
- Gateway trả `ErrorInfo.reason` ra client thành `code` và message thành `detail` ([mã lỗi](../reference/contracts.md#mã-lỗi-grpc-sang-http-ở-gateway)), nên trường hợp nào cần che thì phải giống nhau ở cả ba: mã gRPC, `reason`, message. Tương tự với video: `GetVideo` trả `NOT_FOUND` khi video không tồn tại, hoặc chưa `READY` mà người gọi không phải tác giả (video đã `READY` thì ai cũng xem được); `CompleteUpload` trả `NOT_FOUND` khi video không tồn tại hoặc của người khác. Mọi trường hợp đó cùng `VIDEO_NOT_FOUND` và cùng message.
- MVP không có refresh token: token hết hạn thì đăng nhập lại.

### 6. Đường dẫn media trong contract

Chọn **B**. Ngoại lệ duy nhất là `upload_url` của `InitUpload`: đó là chữ ký ngắn hạn cho endpoint của storage, không được lưu và không đi vào event.

### Hệ quả

- Tốt: ID sinh ở đâu cũng được, chèn index theo thứ tự, không lộ số lượng; outbox có `event_id` trước khi commit. Thứ tự event của một thực thể giữ được kể cả khi topic có nhiều loại; kiểu event được `buf` kiểm như API. Contract không chứa gì phụ thuộc môi trường; `buf lint` và `buf breaking` chạy offline, không cần BSR.
- Xấu: ID 16 byte và chuỗi 36 ký tự trên dây, service kiểm định dạng UUID ở biên. Consumer phải bỏ qua có chủ ý nhánh `oneof` chưa biết (và nhánh của loại mình không cần). Thay đổi phá vỡ tốn một đợt chạy song song `v1`/`v2`. Các service tin `x-user-id` cho tới khi có mTLS.
- Xem lại khi: có producer hoặc consumer ngoài monorepo (cân nhắc schema registry); một topic có consumer chỉ cần một phần nhỏ loại event mà đọc thừa thành đáng kể; có service bên ngoài cluster gọi thẳng vào service nội bộ.

## Xác nhận

`make check` chạy `buf lint` và `buf build`; `buf breaking --against '.git#branch=main'` khi sửa `proto/` (luật `FILE`).

## Hiện thực ở

- Bố cục proto, envelope event, versioning (§1, §3, §4): `proto/svp/<domain>/v1/`, `buf.yaml`; consumer bỏ qua có chủ ý nhánh `oneof` chưa biết: `services/feed-service/internal/projector/projector.go`, `services/video-service/internal/server/transcode.go`, `services/media-worker/internal/worker/worker.go` (và test `services/video-service/internal/server/transcode_test.go`).
- ID UUIDv7 (§2): `internal/ids/`.
- Danh tính người gọi `x-user-id` (§5): `internal/callerid/`.

## Thông tin thêm

Phụ lục: [`appendix/0006-contract-ids-and-event-envelope.md`](appendix/0006-contract-ids-and-event-envelope.md) (trạng thái gốc, phân tích phương án).

### Chỉnh bởi

- §5: [0016](0016-web-client.md): MVP không có refresh token; thêm refresh token.
- §5: [0042](0042-caller-identity-grpc.md): phương án C (`x-user-id`) bị thay bằng access token chuyển tiếp trong metadata `authorization`.
