# Phụ lục ADR-0006: Contract nội bộ: ID là UUIDv7, event bọc theo topic của luồng thực thể, proto đặt ở `proto/svp/<domain>/v1`

Phụ lục của [ADR-0006](../0006-contract-ids-and-event-envelope.md): phần chuyển ra khỏi ADR, giữ nguyên văn và xếp theo §: phân tích phương án chi tiết,
bảng và khối cấu hình, số đo, lệnh đã chạy. Đây là lịch sử, nên giữ ngày và nhãn tiến độ của lúc ghi.

<!-- markdownlint-disable MD052 -->

## Tiêu đề và trạng thái ghi lúc chốt

Tiêu đề gốc: 0006. Contract nội bộ: ID là UUIDv7, event bọc theo topic của luồng thực thể, proto đặt ở `proto/svp/<domain>/v1`

- Trạng thái: Chấp nhận; §5 (MVP không có refresh token) chỉnh bởi [0016](../0016-web-client.md); §5 (phương án C, `x-user-id`) chỉnh bởi [0042](../0042-caller-identity-grpc.md)
- Ngày: 2026-10-11

## 1. Bố cục thư mục và cấu hình `buf`

### Các lựa chọn về bố cục

#### A. `proto/<service>/v1/` với package `svp.<service>.v1` (đúng chữ ADR-0002)

- Mất: trượt luật `PACKAGE_DIRECTORY_MATCH` của `STANDARD`. Luật này bắt package `svp.user.v1` phải nằm trong thư mục
  `svp/user/v1` tính từ gốc module. Đã thử với buf 1.73.0.

#### B. Bỏ tiền tố, package `user.v1` ở `proto/user/v1/`

- Được: đường dẫn ngắn, khớp ADR-0002 về thư mục.
- Mất: tên package chung chung dễ đụng với package của thư viện khác (`user.v1` không nói gì về hệ thống); đổi tên package
  sau này là thay đổi phá vỡ mọi thứ.

#### C. Giữ A, tắt luật `PACKAGE_DIRECTORY_MATCH`

- Mất: đường dẫn file không còn đoán được từ package (và ngược lại); `import` trong proto lệch với tên package; bỏ một luật
  của bộ chuẩn chỉ để giữ một câu chữ trong ADR thì không đáng.

#### D. `proto/svp/<domain>/v1/` với package `svp.<domain>.v1`

- Được: lint sạch với `STANDARD` nguyên vẹn; package có tiền tố riêng của hệ thống; đường dẫn import
  (`svp/event/v1/event.proto`) đọc ra ngay package.
- Mất: thêm một cấp thư mục; lệch chữ với ADR-0002.

## 2. Kiểu ID: UUIDv7

### Các lựa chọn về kiểu ID

#### A. `bigserial`

- Được: 8 byte, nhỏ nhất, nhanh nhất cho index.
- Mất: chỉ database sinh được, nên outbox không biết `event_id`/`video_id` trước khi `INSERT`; lộ số lượng người dùng và
  video (đoán được tốc độ tăng trưởng, duyệt lần lượt `/videos/1`, `/videos/2`...); trùng nhau giữa các database khi gộp
  hay phát lại event.

#### B. UUIDv4

- Được: sinh ở đâu cũng được, không lộ gì.
- Mất: hoàn toàn ngẫu nhiên, nên mỗi lần chèn rơi vào một chỗ bất kỳ của index B-tree: trang index bị tách liên tục, cache
  của Postgres chứa đầy trang nguội, index phình.

#### C. ULID

- Được: có thứ tự thời gian như UUIDv7.
- Mất: không phải chuẩn IETF; Postgres không có kiểu riêng (lưu `text` 26 ký tự hoặc ép sang `uuid`); thư viện và công cụ
  ít hơn.

#### D. Snowflake (64 bit: thời gian + máy + số thứ tự)

- Được: 8 byte, có thứ tự.
- Mất: phải cấp số máy cho mỗi instance (khó khi pod tự scale); JSON của JavaScript mất chính xác với số > 2^53, gateway
  phải trả dạng chuỗi.

#### E. UUIDv7 (RFC 9562)

- Được: 48 bit đầu là mili giây Unix, phần còn lại ngẫu nhiên, nên vừa sinh được ở bất kỳ instance nào không cần hỏi
  database, vừa chèn vào cuối index như số tăng dần; không lộ số lượng; là chuẩn, Postgres lưu bằng kiểu `uuid` 16 byte.
- Mất: 16 byte, gấp đôi `bigint`; lộ thời điểm tạo (với video và event thì vốn không bí mật).

- Cursor keyset (`published_at`, `video_id`) ([ADR-0005](../0005-feed-fan-out-on-write.md) luật 5) dùng `video_id` làm khoá
  phụ, nhưng khoá phụ chỉ cần duy nhất và so sánh được: Postgres so `uuid` theo byte nên UUIDv4 cũng dùng được. Đây không
  phải lý do chọn UUIDv7; thời điểm nằm trong `video_id` là lúc `InitUpload`, không phải `published_at`.
- Sắp theo `id` ra gần đúng thứ tự tạo là tiện ích khi debug, cũng không phải lý do chọn.

## 3. Envelope event và cách chia topic

### Các lựa chọn cách chia topic

#### A. Một topic cho mỗi loại event (`user.followed`, `user.unfollowed`, ...)

- Được: mỗi topic một schema, đơn giản; consumer chỉ subscribe loại mình cần.
- Mất: Kafka chỉ giữ thứ tự **trong một partition của một topic**. `user.followed` rồi `user.unfollowed` của cùng một
  `follower_id` nằm ở hai topic khác nhau thì feed-service có thể đọc unfollow trước follow (hai consumer, hai lag khác
  nhau), xoá một cạnh chưa có rồi thêm cạnh vào: bản sao follow sai vĩnh viễn. Luật 3 của ADR-0003 (mọi event của một thực
  thể giữ thứ tự) không đứng được.

#### B. Một topic cho một luồng thực thể của một producer

- Được: mọi event về một thực thể (cùng key) vào cùng partition, giữ thứ tự; số topic ít.
- Mất: một topic chứa nhiều loại event, nên cần một cách để biết record là loại nào; consumer chỉ cần một loại vẫn phải đọc
  (và bỏ qua) các loại kia.

### Các lựa chọn envelope (khi một topic có nhiều loại)

#### C. Metadata để hết trong header Kafka (kiểu CloudEvents binary mode), value là payload trần

- Được: theo chuẩn CloudEvents; router đọc được loại event mà không giải mã value.
- Mất: header là map chuỗi không kiểu, `buf` không kiểm được; quên header là mất `event_id`; loại event là một chuỗi tự do,
  consumer phải tự ánh xạ chuỗi sang message.

#### D. Message bọc chung với payload `google.protobuf.Any`

- Được: một message bọc duy nhất cho mọi topic.
- Mất: danh sách loại event của một topic không nằm ở đâu trong contract; `buf breaking` không thấy khi một loại bị bỏ;
  consumer giải mã theo chuỗi `type_url`.

#### E. Mỗi topic một message bọc: field 1 là envelope, sau đó `oneof` các loại event

- Được: kiểu chặt, `buf` kiểm cả envelope lẫn từng nhánh; contract ghi rõ topic nào chứa loại nào; consumer `switch` theo
  nhánh `oneof` (Go sinh ra một interface với mỗi nhánh một kiểu), compiler bắt lỗi gõ sai tên loại; thêm loại event = thêm
  một nhánh, không phá contract.
- Mất: mỗi topic một message bọc phải viết; consumer cũ gặp nhánh mới thì thấy `oneof` rỗng và phải bỏ qua có chủ ý.

## 4. Versioning

- Cân nhắc: `WIRE_JSON`, cho phép xoá field nếu đã `reserved` số và tên, vẫn giữ tương thích trên dây và JSON. Giữ `FILE`
  vì mọi service trong monorepo dùng chung code Go sinh từ proto: xoá một field trong `v1` làm vỡ build của service khác,
  trong khi `deprecated` đã đủ để ngừng dùng mà không phá gì.

- Cân nhắc: schema registry (Confluent/Redpanda). Kiểm tương thích lúc chạy, theo từng topic; nhưng thêm một hệ thống phải
  vận hành, trong khi `buf breaking` ở CI đã chặn trước khi code lên. Xem lại khi có producer ngoài monorepo này.

## 5. Danh tính người gọi

### Các lựa chọn về danh tính

#### A. Mỗi request mang `user_id` của người gọi

- Mất: service phải tin field do gateway điền, mà field nằm chung với dữ liệu nghiệp vụ, rất dễ có một handler lấy luôn giá
  trị client gửi lên; contract lẫn lộn "ai đang gọi" với "gọi về ai".

#### B. Truyền JWT xuống, mỗi service tự kiểm

- Được: không service nào phải tin gateway.
- Mất: mọi service phải có khoá công khai và logic kiểm JWT; thêm vài trăm micro giây mỗi chặng.

#### C. Gateway kiểm JWT, đặt `user_id` đã xác thực vào gRPC metadata `x-user-id`

- Được: request chỉ mang id của **thực thể khác** (`followee_id`, `video_id`), danh tính tách khỏi dữ liệu; một interceptor
  ở mỗi service đọc metadata vào `context`; đúng [architecture.md §7.4](../../architecture.md#64-xác-thực).
- Mất: service tin metadata do bất kỳ ai gọi được tới nó đặt. Bên trong cluster tạm tin nhau qua mạng; mTLS để giai đoạn 6.

## 6. Đường dẫn media trong contract

### Các lựa chọn về đường dẫn media

#### A. API và event mang URL tuyệt đối (`https://cdn.example.com/media/<id>/master.m3u8`)

- Mất: URL gắn với môi trường lúc phát event. Phát lại event từ local lên cloud, đổi CDN hay đổi domain thì bản sao ở
  feed-service chứa URL sai, phải dựng lại read model.

#### B. API và event mang object key (`uploads/<video_id>`, `media/<video_id>/master.m3u8`)

- Được: dữ liệu không phụ thuộc môi trường; gateway ghép URL công khai từ cấu hình (MinIO local, CDN trên cloud), đổi CDN
  chỉ là đổi cấu hình.
- Mất: gateway phải biết base URL; client không dùng được dữ liệu thô từ service (vốn không gọi thẳng service).
