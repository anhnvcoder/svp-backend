# 0008. Luồng upload bất đồng bộ: franz-go, aws-sdk-go-v2, outbox có khoá relay, media-worker trên alpine + ffmpeg

- Trạng thái: Chấp nhận
- Ngày: 2026-10-11

## Bối cảnh và vấn đề

- Luồng upload thật của [architecture §6.1](../architecture.md#61-upload-tới-khi-vào-feed): `InitUpload` trả presigned POST, client đẩy file lên MinIO, `CompleteUpload` `HEAD` rồi ghi outbox, relay phát `video.uploaded`, media-worker transcode ra HLS, phát `transcode.completed` / `transcode.failed`, video-service chuyển `READY` hoặc `FAILED` (bước bù). Redis, rate limit, engagement-service và feed-service thuộc các ADR sau.
- Các ADR trước đã chốt hướng: Redpanda, outbox, at-least-once, DLQ ([ADR-0003](0003-async-events-outbox.md)); presigned POST, HLS, hai bucket ([ADR-0004](0004-direct-upload-and-hls.md)); topic theo luồng thực thể, envelope, bỏ qua nhánh `oneof` chưa biết ([ADR-0006](0006-contract-ids-and-event-envelope.md)); cấu hình bằng biến môi trường, image distroless ([ADR-0007](0007-go-monorepo-toolchain-and-stage1-scope.md)). ADR này chọn thư viện, image, cấu hình hạ tầng và chi tiết hiện thực mà code luồng upload dùng; tên biến, version, cổng, đường dẫn lấy từ đây.
- Biện pháp bắt buộc của [threat model §5](../threat-model.md#5-tổng-hợp-theo-giai-đoạn) cho phần này: UP-1 tới UP-6, FF-1 tới FF-4, FF-6, FF-7, IN-5. Ràng buộc máy: Apple M2, 16 GB; Docker VM có 7,65 GiB và 8 CPU (`docker info`, 2026-10-11); compose profile `core` gồm service + Redpanda + MinIO (plan, mục Ràng buộc máy); chạy native arm64.

## Yếu tố quyết định

Không mất event khi crash và giữ thứ tự theo key; thư viện build `CGO_ENABLED=0` chạy trên image static; credential theo service với quyền tối thiểu; ffmpeg chạy sau whitelist và giới hạn tài nguyên; code storage và Kafka dùng lại được trên cloud.

## Phương án đã cân nhắc

- §1 **A `franz-go`**: thuần Go, build `CGO_ENABLED=0`, producer idempotent mặc định, commit tay, có `kfake` để test; phải tự viết vòng poll và commit.
- §1 B `confluent-kafka-go`: bọc librdkafka, trưởng thành nhất; cần cgo, phá image static: loại.
- §1 C `segmentio/kafka-go`: API đơn giản; consumer group hạn chế, phát triển chậm: loại.
- §1 `IBM/sarama`: API nặng, mặc định dễ sai (producer không idempotent mặc định): loại.
- §2 **A `aws-sdk-go-v2/service/s3`**: SDK chính chủ, dùng lại nguyên khi lên AWS, có `PresignPostObject`; nhiều module, phải chỉnh mặc định cho MinIO.
- §2 B `minio-go/v7`: một module; lên AWS thì repo có hai SDK cho cùng một việc: loại.
- §3 **A hai endpoint (nội bộ, công khai)**: client nhận URL mở được từ máy host, trên AWS hai biến cùng giá trị; thêm một biến và một presign client.
- §3 B `host.docker.internal` cho cả hai phía: máy host không phân giải tên này ổn định: loại.
- §3 C `network_mode: host`: mất cô lập mạng của compose, cổng gRPC lộ ra máy (IN-2): loại.
- §4 **A key trong contract là key trong bucket**: không cắt ghép chuỗi, key trùng ở database, event, policy, CDN; `media/media/...` lặp ở local.
- §4 B bỏ tiền tố khi ghi: URL local gọn; mọi chỗ đọc ghi phải cắt ghép tiền tố, policy lệch key: loại.
- §5 A bật auto-create: gõ sai tên là có topic mới, cấu hình topic không nằm trong repo: loại.
- §5 B service tạo topic bằng `kadm`: service cần quyền quản trị broker (ngược IN-4): loại.
- §5 **C tắt auto-create, `redpanda-init` tạo topic bằng `rpk`**: topology ở một chỗ trong repo; thêm một container one-shot.
- §5 1 partition: thứ tự toàn cục; chỉ một media-worker chạy được: loại.
- §5 **3 partition**: tối đa 3 media-worker song song; thứ tự chỉ trong một partition (đủ, vì key theo `video_id`).
- §5 6+ partition: dư chỗ scale; thừa với tải hiện tại, giảm về sau không được: loại.
- §6 **A `cgr.dev/chainguard/minio` ghim digest**: build từ mã nguồn, còn cập nhật, không root, có `mc`; chỉ có tag `latest`, đổi digest bằng tay.
- §6 B `derklaro/minio`: có tag; một cá nhân dựng, đóng băng, không có bản vá: loại.
- §6 C SeaweedFS, Garage, RustFS: còn phát triển; phải kiểm lại POST policy, bucket policy, user IAM: để ADR riêng.
- §7 A `FOR UPDATE SKIP LOCKED`: nhiều replica relay song song; hai event cùng key có thể lệch thứ tự: loại.
- §7 **B một relay, khoá `pg_try_advisory_xact_lock`**: gửi đúng thứ tự `id`; thông lượng bằng một replica.
- §8 A auto-commit định kỳ: worker chết giữa chừng là mất event: loại.
- §8 **B commit tay sau khi handler xong**: at-least-once, trùng không gây sai với handler idempotent; tự viết vòng xử lý, retry, DLQ.
- §8 **retry trong process có backoff, rồi DLQ**: đơn giản, lỗi tạm thời ngắn tự hết; partition bị chặn trong lúc retry.
- §8 topic retry riêng (`<topic>.retry.N`): không chặn partition; mất thứ tự theo key: loại.
- §9 distroless `static`: không có ffmpeg, chép vào phải kèm thư viện động: loại.
- §9 **`alpine` ghim tag + `apk add ffmpeg`**: nhỏ, ffmpeg do Alpine build và vá, có `ffprobe`; có shell và package manager trong image.
- §9 `debian-slim` + `apt install ffmpeg`: image nặng hơn nhiều: loại.
- §9 ffmpeg static tải ngoài: bản mới nhất; khó kiểm nguồn, tự gánh cập nhật: loại.
- §10 segment 2 s: khởi phát nhanh nhất; gấp đôi số object và request: loại.
- §10 **segment 4 s**: ít object hơn một nửa, video ngắn vẫn khởi phát nhanh; đổi bitrate chậm hơn một nhịp.
- §10 segment 6 s: ít object nhất; khởi phát chậm thấy rõ với video 15–60 s: loại.
- §10 preset `ultrafast`: nhanh nhất; file to hơn rõ, tốn egress: loại.
- §10 **preset `veryfast`**: giữ được mục tiêu ~60 s cho video 60 s trên 2 vCPU; file to hơn `medium` một chút.
- §10 preset `medium`: file nhỏ hơn; chậm gấp vài lần, khó giữ p95 < 2 phút: loại.
- §11 **A biến môi trường**: cùng một image chạy ở compose, k8s, cloud; danh sách biến dài thêm.
- §11 B một biến URL gộp: trộn bí mật với địa chỉ, phải tự parse: loại.
- §12 **A cổng mặc định, chỉ `127.0.0.1`**: công cụ dùng mặc định là chạy; có thể đụng phần mềm khác (đã kiểm: không có).
- §12 B dải riêng `92xx`: phải nhớ ánh xạ, không thêm lợi ích khi cổng đang trống: loại.
- §13 A làm đủ mọi biện pháp của luồng upload cùng lúc: cần Redis và khoá phân tán, khó đo từng phần: loại.
- §13 **B luồng upload chạy đầu-cuối có số đo**: kết thúc ở trạng thái chạy được; upload bỏ dở chưa bị chặn tới phần sau.

## Kết quả quyết định

Chọn franz-go (§1), aws-sdk-go-v2 với hai endpoint và key nguyên văn (§2–§4), topic tạo bằng `redpanda-init` với 3 partition (§5), MinIO Chainguard ghim digest (§6), outbox một relay có khoá advisory (§7), commit tay với retry trong process rồi DLQ (§8), media-worker trên alpine + ffmpeg sau whitelist (§9, §10), vì không mất event khi crash và giữ thứ tự theo key, build được `CGO_ENABLED=0`, credential theo service với quyền tối thiểu và code storage, Kafka dùng lại được trên cloud; từng phần ở §1–§13.

### 1. Thư viện Kafka

Chọn **A**: `github.com/twmb/franz-go` cho producer (relay outbox, media-worker, DLQ) và consumer group; `github.com/twmb/franz-go/pkg/kfake` chỉ cho test (không gắn tag nên ghim pseudo-version; kéo `franz-go/pkg/kadm` làm dependency gián tiếp). Version ở phụ lục và `go.mod`. Không dùng `kadm` trong code: topic là hạ tầng, tạo bằng `rpk` (mục 5), service không tạo hay sửa topic.

### 2. Thư viện object storage

Chọn **A**: `github.com/aws/aws-sdk-go-v2`, `.../credentials` (`credentials.NewStaticCredentialsProvider`), `.../service/s3` (client S3, `PresignClient`); version ở phụ lục và `go.mod`.

- **Không dùng gói `config`** (`config.LoadDefaultConfig`): nó đọc `~/.aws/config`, `~/.aws/credentials` và biến `AWS_*` của môi trường, nên service có thể vô tình nhận credential khác với biến đã khai. Dựng thẳng `s3.Options`: `Region` = `S3_REGION`, `BaseEndpoint` = `S3_ENDPOINT`, `UsePathStyle: true`, `Credentials` = static credentials từ `S3_ACCESS_KEY_ID`/`S3_SECRET_ACCESS_KEY`, `RequestChecksumCalculation` và `ResponseChecksumValidation` = `aws.RequestChecksumCalculationWhenRequired` / `aws.ResponseChecksumValidationWhenRequired` (mặc định mới của SDK gửi checksum CRC mà MinIO bản cũ và GCS không nhận đủ). Khi lên AWS chỉ đổi phần credential, phần còn lại giữ.
- **Presigned POST** bằng `s3.NewPresignClient(client).PresignPostObject(ctx, &s3.PutObjectInput{Bucket, Key}, opts)`, với `opts.Expires = 15 * time.Minute` và `opts.Conditions` gồm `[]any{"content-length-range", 1, size}` và `map[string]string{"Content-Type": contentType}`. Đọc mã nguồn (`presign_post.go`, `createPolicyDocument`): policy luôn có `{"bucket": ...}`; nếu `Conditions` không có điều kiện nào về `key` thì SDK tự thêm `{"key": key}`, tức **khớp chính xác** key (UP-1). Code không được thêm `["starts-with", "$key", ...]`, vì có nó thì SDK bỏ điều kiện khớp chính xác; điều kiện bổ sung được nối nguyên vào policy, nên `content-length-range` [1, `size` đã khai] và `Content-Type` khớp chính xác nằm trong phần đã ký (UP-1); `Values` trả về gồm `key`, `policy`, `X-Amz-Algorithm`, `X-Amz-Credential`, `X-Amz-Date`, `X-Amz-Signature`, **không có `Content-Type`**: service tự thêm `Content-Type` vào `form_fields`, không thì storage từ chối form vì policy đòi field đó; với `UsePathStyle`, URL = `<endpoint>/<bucket>`; policy không chứa host.

### 3. Hai endpoint cho storage

Chọn **A**. Service gọi API S3 (`HeadObject`, `DeleteObject`, `GetObject`, `PutObject`) qua `S3_ENDPOINT=http://minio:9000`.

- `upload_url` trả client ký bằng một presign client riêng dựng với `BaseEndpoint` = `S3_PUBLIC_ENDPOINT` (`http://127.0.0.1:9000` ở local). Ký presigned chỉ là tính toán cục bộ, không gọi mạng, nên client này không cần tới được endpoint công khai.
- Cần hai client dù chữ ký POST không ký host, vì SDK ghép URL trả về từ endpoint của client, và presigned GET/PUT thì có ký host; hai endpoint là cách đúng cho mọi loại presigned. Trên AWS hai biến cùng giá trị nên code không có nhánh riêng cho local.

### 4. Object key và bucket

Chọn **A**. Key trong contract (`uploads/<video_id>`, `media/<video_id>/...`) là key trong bucket. Tiền tố `uploads/` → bucket `S3_UPLOADS_BUCKET` (mặc định `uploads`); tiền tố `media/` → bucket `S3_MEDIA_BUCKET` (mặc định `media`).

- URL phát = `MEDIA_PUBLIC_BASE_URL` + `/` + key. Local `MEDIA_PUBLIC_BASE_URL=http://127.0.0.1:9000/media`, nên URL là `http://127.0.0.1:9000/media/media/<id>/master.m3u8`. Chấp nhận chữ `media` lặp: đó là tên bucket (path-style) cộng tiền tố key; trên CDN, `MEDIA_PUBLIC_BASE_URL` là domain CDN và URL thành `https://<cdn>/media/<id>/master.m3u8`.
- Path-style luôn bật ở đường local (MinIO local không có DNS cho virtual-hosted style). Xem lại khi lên AWS: S3 vẫn nhận path-style cho bucket hiện có nhưng AWS khuyên virtual-hosted.

### 5. Redpanda

Chọn **C** và **3 partition** (tối đa 3 media-worker song song, khớp "≥ 3 worker" ở [capacity](../explanation/capacity.md#kết-quả); thứ tự chỉ trong một partition là đủ, vì key theo `video_id`, ADR-0003 luật 3; tăng partition về sau được, giảm thì không).

- Image `redpandadata/redpanda:v26.2.4` (đã kiểm arm64; digest lúc kiểm `sha256:c98c2f04a751e6646012cc701bac5183252cee44c88ba1dfa412e4c7124f2e89`). Một node, chạy `--smp 1 --memory 1G --overprovisioned`; giới hạn container 1,5 GB RAM, 1 CPU.
- Listener: `redpanda:9092` cho mạng compose; listener thứ hai quảng bá `127.0.0.1:19092`, publish `127.0.0.1:19092` cho test và `rpk` từ máy host. Admin API, schema registry, HTTP proxy không publish. `auto_create_topics_enabled=false` đặt tường minh lúc khởi động.
- `redpanda-init` dùng cùng image, chạy `rpk topic create` cho từng topic, bỏ qua lỗi "đã tồn tại" (idempotent); service chờ nó xong (`service_completed_successfully`).
- Topic, replication 1: `video.lifecycle.v1`, `media.transcodes.v1` 3 partition, giữ 7 ngày (`retention.ms=604800000`); `video.lifecycle.v1.dlq`, `media.transcodes.v1.dlq` 1 partition, giữ 14 ngày (`retention.ms=1209600000`). Consumer group: `media-worker` (đọc `video.lifecycle.v1`, ghi DLQ `video.lifecycle.v1.dlq`), `video-service` (đọc `media.transcodes.v1`, ghi DLQ `media.transcodes.v1.dlq`). DLQ giữ lâu hơn topic gốc để kịp xem và phát lại. Topic của user-service (`user.follows.v1`) và engagement-service (`engagement.views.v1`) tạo cùng lúc với code phát chúng.

### 6. MinIO

MinIO ngừng phát hành image chính thức (Docker Hub trả `denied`, Quay đòi đăng nhập, repo GitHub archive; chi tiết kiểm ngày 2026-10-11 ở phụ lục), nên không ghim `minio/minio:RELEASE.*` được. Chọn **A**: `cgr.dev/chainguard/minio@sha256:7df55d002b698e4494a131b848dd553361bbe58b7e19f62d9623c29af1ba9ccf` cho cả `minio` và `minio-init` (bị thay một phần bởi [0022](0022-local-object-store-minio-replacement.md), xem Chỉnh bởi).

- MinIO chỉ chạy local, sau `127.0.0.1`; rủi ro của một bản community không còn bảo trì chính chủ vì vậy chỉ nằm trên máy dev (đường cloud dùng S3 hoặc GCS).
- Container `minio`: giới hạn 512 MB RAM; API publish `127.0.0.1:9000`, console `127.0.0.1:9001`; image chạy uid 65532 nên volume dữ liệu phải ghi được bởi uid này.
- Container one-shot `minio-init` (`--entrypoint /bin/sh`, script dùng `mc`) tạo bucket, policy, user; idempotent. Root credential (`MINIO_ROOT_USER` ghi trong compose, `MINIO_ROOT_PASSWORD` = `SVP_MINIO_ROOT_PASSWORD`) chỉ có ở `minio` và `minio-init`, service không bao giờ nhận (UP-5).
- User theo service (UP-4, UP-5, FF-4), mỗi user một policy gắn riêng, secret key từ `SVP_VIDEO_S3_SECRET_KEY` và `SVP_MEDIA_WORKER_S3_SECRET_KEY`: `svp-video-service` có `s3:PutObject`, `s3:GetObject` (cần cho `HeadObject`), `s3:DeleteObject` trên `arn:aws:s3:::uploads/uploads/*`, `s3:ListBucket` trên `arn:aws:s3:::media` với điều kiện `StringLike` `s3:prefix` = `media/*` (`StringEquals` không khớp `media/<id>/`, liệt kê để dọn bị từ chối) và `s3:DeleteObject` trên `arn:aws:s3:::media/media/*` (dọn HLS dở của video `FAILED`); `svp-media-worker` có `s3:GetObject` trên `arn:aws:s3:::uploads/uploads/*` và `s3:PutObject` trên `arn:aws:s3:::media/media/*`.
- Bucket `media`: ẩn danh chỉ `s3:GetObject` trên `arn:aws:s3:::media/media/*`, **không** `s3:ListBucket` (UP-6). Đặt bằng `mc anonymous set-json` với policy viết tay, không dùng policy dựng sẵn `download` của `mc` (policy đó cho cả liệt kê bucket). Test kiểm: đọc ẩn danh một object được, liệt kê ẩn danh bị từ chối. Bucket `uploads`: không có quyền ẩn danh nào.
- Ba biến bí mật mới trong `.env`: `SVP_MINIO_ROOT_PASSWORD`, `SVP_VIDEO_S3_SECRET_KEY`, `SVP_MEDIA_WORKER_S3_SECRET_KEY`. `make env` thêm biến còn thiếu vào `.env` có sẵn, không đổi biến đã có; dòng có tên biến mà giá trị rỗng tính là thiếu.

### 7. Outbox

Hiện thực phương án B của [ADR-0003](0003-async-events-outbox.md). Chọn **B**: một relay tại một thời điểm, khoá bằng `pg_try_advisory_xact_lock`. Đây là chỉnh nhỏ so với câu "`FOR UPDATE SKIP LOCKED`" của ADR-0003, vì hai event cùng key có thể rơi vào hai lô ở hai replica và lệch thứ tự trên partition (vi phạm luật 3); phần còn lại của ADR-0003 giữ nguyên.

- Bảng `outbox` nằm trong database của từng service, tạo bằng migration goose của service đó: `id` (identity, khoá chính), `event_id` (`uuid`, unique), `topic`, `record_key`, `payload` (bytes của message bọc), `headers` (`jsonb`, header Kafka gồm `traceparent`), `created_at`, `published_at`; chỉ mục từng phần `outbox_unpublished_idx` trên `id` khi `published_at IS NULL` (DDL ở phụ lục).
- Bất biến khi ghi: transaction nghiệp vụ khoá dòng thực thể trước (`UPDATE ... WHERE` hoặc `SELECT ... FOR UPDATE`), rồi mới chèn dòng outbox trong cùng transaction. Nhờ vậy hai transaction cùng một thực thể nối đuôi nhau, `id` của outbox tăng theo thứ tự commit; chèn outbox trước khi khoá thì transaction lấy `id` 10 có thể commit sau transaction lấy `id` 11, và relay gửi event lệch thứ tự.
- Relay là goroutine trong service, code ở gói dùng chung `internal/outbox`. Mỗi vòng là một transaction: (1) `pg_try_advisory_xact_lock(<hằng số int64 của internal/outbox>)`, không được khoá thì commit và chờ (khoá advisory thuộc phạm vi database, mỗi service một database, nên một hằng số chung cho mọi service là đủ); (2) đọc tối đa 100 dòng `published_at IS NULL` theo `id` tăng dần; (3) produce đồng bộ (`ProduceSync`) giữ key, payload, header; (4) `UPDATE ... SET published_at = now()` cho các dòng đã gửi, commit (khoá tự nhả khi transaction kết thúc).
- Lấy đủ 100 dòng thì chạy vòng tiếp ngay; ít hơn thì chờ 200 ms. Produce lỗi thì rollback, chờ rồi thử lại; dòng đã produce mà chưa kịp đánh dấu sẽ được gửi lại (at-least-once, consumer chịu được trùng).
- Dọn: mỗi 10 phút xoá theo lô (vài nghìn dòng một lệnh) các dòng `published_at < now() - interval '24 hours'`. Xoá là idempotent, chạy cùng lúc ở nhiều replica cũng không sai, nên không cần khoá.
- Phải trả: thông lượng relay bằng một replica (thừa với vài event mỗi giây của luồng upload); transaction của relay mở trong lúc produce (tối đa bằng timeout produce); không đo được lag outbox tới khi có metric ([ADR-0011](0011-observability-stage3.md)).

### 8. Consumer

Chọn **B** và **retry trong process**, hiện thực một lần ở gói dùng chung `internal/kafkax`: commit tay sau khi handler trả về (thành công, hoặc đã đẩy sang DLQ, hoặc bỏ qua có chủ ý).

- Lỗi tạm thời: `MaxAttempts` là tổng số lần gọi handler cho một record, kể cả lần đầu (mặc định 5); giữa hai lần là backoff mũ từ 0,5 s tới trần 10 s, có jitter (mặc định tối đa 0,5 + 1 + 2 + 4 = 7,5 s chờ). Consumer đặt ngân sách riêng được (media-worker, mục 9). Handler nhận biết lần thử hiện tại có phải lần cuối không (media-worker cần để phát `transcode.failed` với `RETRIES_EXHAUSTED` thay vì để event vào DLQ).
- Lỗi vĩnh viễn (handler bọc bằng `kafkax.Permanent(err)`: event không parse được, thiếu field bắt buộc, vi phạm nghiệp vụ) hoặc hết lượt: produce sang `<topic>.dlq` giữ nguyên key, value, header gốc, thêm header `dlq-reason` (`permanent` | `retries-exhausted`, gạch nối), `dlq-error`, `dlq-topic`, `dlq-partition`, `dlq-offset`; rồi commit (IN-5).
- Nhánh `oneof` chưa biết hoặc không cần: bỏ qua và commit (ADR-0006). `traceparent` đọc từ header Kafka khi nhận và ghi vào header khi produce (cùng key với metadata gRPC, ADR-0007 mục 8).
- Job dài và rebalance: handler của media-worker chạy tới 10 phút. Heartbeat của franz-go chạy nền nên worker không bị loại khỏi group vì job dài. Consumer bật `BlockRebalance` (media-worker bật): rebalance **chờ** handler đang chạy xong và commit của nó vào, không huỷ handler; vì commit lên partition đã bị thu về sẽ mất. `RebalanceTimeout` vì vậy phải phủ trọn ngân sách retry của một record (mọi lần thử cộng mọi backoff), không thì group loại thành viên không kịp vào lại; ở media-worker là 164 phút (mục 9). Với balancer mặc định cooperative-sticky, chỉ việc thu partition bị chờ; giao partition của thành viên đã chết không bị chặn. Khi worker dừng (huỷ context), handler bị huỷ và event đó không được commit; worker nhận partition sẽ làm lại từ đầu, ghi đè cùng đường dẫn (mục 9).
- **`processed_events`** (`event_id uuid PRIMARY KEY`, `consumer text NOT NULL`, `processed_at timestamptz NOT NULL DEFAULT now()`) là thiết kế cho consumer có tác dụng không tự idempotent (ADR-0003 luật 1). Luồng upload **không tạo** bảng này: hai consumer đều tự idempotent. video-service chuyển trạng thái một chiều (`PROCESSING` → `READY`/`FAILED`) kèm outbox trong cùng transaction, gặp lại event thì trạng thái đã khác `PROCESSING` và không làm gì; media-worker ghi đè đường dẫn cố định. Idempotent của transcode nghĩa là cùng kết quả nghiệp vụ, không phải cùng từng byte (libx264 đa luồng không cho kết quả bit-exact): playlist biến thể giống hệt, `master.m3u8` giống hệt sau khi che `BANDWIDTH`/`AVERAGE-BANDWIDTH`, và các giá trị bandwidth đo được lệch nhau ≤ 5 % (`make drill-duplicates` kiểm). Tạo khi có consumer cần (bộ đếm của engagement-service).

### 9. media-worker

Chọn **alpine + `apk add ffmpeg`** (Alpine build và vá ffmpeg, có `ffprobe`; shell và package manager trong image bù bằng `read_only`, `cap_drop`, không root).

- Không database, không cổng, không gRPC (FF-4); không healthcheck HTTP (không có server), probe liveness/readiness ở k3d. Nhận `video.lifecycle.v1`, phát `media.transcodes.v1` bằng produce thẳng (không có database nên không có outbox, ADR-0003 luật 4).
- Image riêng `deploy/docker/media-worker.Dockerfile`: stage build Go giống `service.Dockerfile` (`golang:1.27.2-trixie`, `CGO_ENABLED=0`, `-trimpath`); runtime `alpine:3.24.2` (digest lúc kiểm `sha256:294b683cb724975bec92580e1e685676bd4b50bda910ddb8c51d4cabeaec77e6`) + `apk add --no-cache ffmpeg`. Không ghim version gói `ffmpeg`: Alpine xoá bản cũ khỏi repo khi có bản vá, ghim cứng sẽ làm build gãy; tag alpine ghim giữ nhánh 3.24, bản vá trong nhánh được nhận khi build lại. Bản đã kiểm: ffmpeg 8.1.2-r0. Thư mục `/work` tạo sẵn trong image, chủ là 65532:65532; chạy `USER 65532:65532`.
- Compose: `read_only: true`, `cap_drop: [ALL]`, `security_opt: [no-new-privileges:true]`, seccomp mặc định; 2 CPU, 2 GB RAM; named volume gắn vào `/work` làm thư mục tạm (không dùng tmpfs, vì tmpfs tính vào RAM, mà một job cần tới gần 1 GB).
- Mạng: media-worker chỉ nối vào một mạng compose riêng `worker` (`internal: true`, không ra internet) chứa thêm `redpanda` và `minio`; không nối mạng mặc định nơi có gateway và các service gRPC (FF-4; lớp NetworkPolicy đầy đủ ở k3d, FF-5).
- Mỗi worker xử lý một job một lúc. Job tải file gốc về `/work/<video_id>/` (FF-2 bắt buộc file cục bộ), xoá thư mục job khi xong (thành công hay lỗi), xoá thư mục sót lại trong `/work` lúc khởi động. Đĩa mỗi job < 1 GB (gốc ≤ 500 MiB + đầu ra của video ≤ 3 phút).
- Ghi kết quả: upload segment và playlist biến thể trước, `master.m3u8` sau cùng, rồi mới phát `transcode.completed`. Người xem chỉ tới được bản HLS qua master playlist, nên không ai thấy master trỏ tới segment chưa có.
- Phân loại lỗi: **vĩnh viễn**, phát `transcode.failed` ngay (`INVALID_INPUT` hoặc `DURATION_EXCEEDED`): file hỏng, ngoài whitelist, vượt giới hạn, ffprobe/ffmpeg thoát lỗi, bị tín hiệu giết (crash trên file độc, chạm giới hạn RAM) hoặc hết giờ (30 s / 10 phút), vì file độc chỉ chạy một lần, không chặn partition qua các lần retry; **tạm thời**, thử lại: storage, Kafka, mạng, và hết `tryTimeout` (15 phút) của một lần thử (tải về, ffprobe, ffmpeg, upload), lần cuối vẫn lỗi thì phát `transcode.failed` với `RETRIES_EXHAUSTED`; event hỏng (không parse được, thiếu field, key sai dạng): `kafkax.Permanent`, sang DLQ.
- Ngân sách retry: 10 lần thử, backoff 1 s tới trần 60 s (tổng chờ khoảng 4 phút), để sự cố storage hay broker một hai phút không thành `RETRIES_EXHAUSTED` (khiến video-service xoá file gốc của người dùng). `RebalanceTimeout` = 10 × (15 phút + 30 s produce) + 9 × 60 s = 164 phút.

### 10. HLS và ffmpeg

Segment **4 s**, preset **`veryfast`** (giữ được mục tiêu ~60 s cho video 60 s trên 2 vCPU, A8); đo lại thời gian transcode và kích thước đầu ra, đổi nếu số đo lệch.

- Ladder theo cạnh ngắn (video dọc là chủ yếu, ADR-0004), bitrate theo A6: `360p` 0,8 Mbps, `720p` 2,5 Mbps, `1080p` 5 Mbps. Không upscale: chỉ tạo các bậc có cạnh ngắn ≤ cạnh ngắn của nguồn. Nguồn nhỏ hơn 360p thì một bản ở kích thước gốc (làm tròn xuống cạnh chẵn), tên `source`, bitrate 0,8 Mbps.
- H.264 (`libx264`, `-preset veryfast`) + AAC 128 kbps; nguồn không có audio thì đầu ra không có audio. Segment MPEG-TS 4 s (`-hls_time 4`), keyframe mỗi 2 s không phụ thuộc fps (`-force_key_frames "expr:gte(t,n_forced*2)"`), `-sc_threshold 0`, `-hls_playlist_type vod`.
- Một lần chạy ffmpeg cho mọi bản: `-filter_complex` với `split` + `scale`, `-var_stream_map` đặt tên theo rendition, `-master_pl_name master.m3u8`. Thumbnail JPEG lấy ở giây 1 (video ngắn hơn 1 s thì ở giữa video), một lần chạy ffmpeg riêng với cùng các giới hạn.
- Đường dẫn: `media/<id>/master.m3u8`, `media/<id>/<rendition>/index.m3u8`, segment trong `media/<id>/<rendition>/`, `media/<id>/thumbnail.jpg`.
- **FF-1:** chạy `ffprobe` trước (JSON, `-show_format -show_streams`), chỉ nhận container MP4/MOV (`format_name` `mov,mp4,m4a,3gp,3g2,mj2`) hoặc WebM/Matroska (`matroska,webm`); codec video `h264`, `hevc`, `vp8`, `vp9`, `av1`; audio `aac`, `mp3`, `opus`, `vorbis`. ffprobe và ffmpeg đều chạy với `-format_whitelist` (demuxer `mov`, `matroska`) và `-codec_whitelist` cùng danh sách. Tên trong `-codec_whitelist` là tên **decoder** của bản ffmpeg trong image, có thể khác tên codec (ví dụ AV1 có thể giải bằng `libdav1d`, MP3 bằng `mp3float`); chuỗi chính xác chốt khi viết code, có test cho file hợp lệ và file bị từ chối. Sai whitelist thì `transcode.failed` với `INVALID_INPUT`.
- **FF-2:** `-protocol_whitelist file`; demuxer playlist/tham chiếu (HLS, concat...) không có trong whitelist định dạng; ffmpeg và ffprobe chạy với môi trường rỗng (`cmd.Env = []string{}`) trên file cục bộ trong `/work/<video_id>/`.
- **FF-3:** `ffprobe` kiểm thời lượng ≤ 181 s (1 s dung sai), cạnh dài ≤ 4096 px, fps ≤ 120, ≤ 8 stream, có ít nhất một video stream; quá thời lượng thì `DURATION_EXCEEDED`, sai giới hạn khác thì `INVALID_INPUT`. ffmpeg vẫn ép `-t 180` vì metadata có thể nói dối. Timeout bằng `exec.CommandContext`: 30 s cho ffprobe, 10 phút cho ffmpeg. **FF-7:** `-map_metadata -1`, luôn mã hoá lại, không `-c copy`.

### 11. Cấu hình mới

Chọn **A**. Thiếu biến bắt buộc hoặc sai định dạng thì service thoát ngay lúc khởi động với lỗi nêu tên biến (không in giá trị), như ADR-0007. Bảng biến của `video-service`, `media-worker`, `gateway` (`KAFKA_BROKERS`, `S3_*`, `WORK_DIR`, `MEDIA_PUBLIC_BASE_URL`) ở phụ lục; hiện hành ở [`reference/environment.md`](../reference/environment.md).

- Biến bí mật trong `.env` (mục 6): `SVP_MINIO_ROOT_PASSWORD`, `SVP_VIDEO_S3_SECRET_KEY`, `SVP_MEDIA_WORKER_S3_SECRET_KEY`. (**Bị thay một phần bởi [0022](0022-local-object-store-minio-replacement.md)**: root là `SVP_S3_ROOT_PASSWORD`, thêm `SVP_S3_PROBE_SECRET_KEY` của user thử; endpoint compose `http://s3:9000`.)
- **Test:** `SVP_TEST_S3_ENDPOINT`, `SVP_TEST_S3_VIDEO_ACCESS_KEY` / `SVP_TEST_S3_VIDEO_SECRET_KEY`, `SVP_TEST_S3_WORKER_ACCESS_KEY` / `SVP_TEST_S3_WORKER_SECRET_KEY`, `SVP_TEST_KAFKA_BROKERS`. Thiếu biến nào thì test cần biến đó gọi `t.Skip`; test chỉ cần Kafka mà không cần broker thật dùng `kfake`, nên `make check` vẫn chạy được không cần Docker. `make test-stack` đặt các biến này từ `.env` (MinIO `http://127.0.0.1:9000`, Redpanda `127.0.0.1:19092`) khi stack đang chạy.

### 12. Cổng và RAM

Chọn **A**: MinIO API `127.0.0.1:9000` (client upload, test, URL phát local); MinIO console `127.0.0.1:9001` (**bị thay một phần bởi [0022](0022-local-object-store-minio-replacement.md)**: console tắt, không cổng 9001); Redpanda Kafka API `127.0.0.1:19092` (test và `rpk` từ host; trong compose là `redpanda:9092`). Giới hạn bộ nhớ trên Docker VM 7,65 GiB: `redpanda` 1,5 GB, 1 CPU; `minio` 512 MB; `media-worker` 2 GB, 2 CPU; `gateway`, `user-service`, `video-service` không đổi (vài chục MB mỗi cái); `redpanda-init`, `minio-init`, migrate là one-shot, thoát sau vài giây. Tổng giới hạn < 4,5 GB, còn chỗ cho Postgres/Redis native ngoài VM và cho profile `obs` (không bật cùng `obs-elastic`).

### 13. Phạm vi phần A

Chọn **B**. Ngoài phần A (ghi lại ở Hệ quả): job dọn upload bỏ dở ([ADR-0004](0004-direct-upload-and-hls.md) luật 4) và giới hạn số video `UPLOADING` mỗi user (UP-7): làm cùng rate limit ([ADR-0010](0010-redis-ratelimit-cache-resilience-stage2c.md)); phát lại DLQ: làm bằng `rpk` (đọc `<topic>.dlq`, produce lại vào topic gốc), chưa có công cụ riêng; cảnh báo DLQ ở [ADR-0011](0011-observability-stage3.md); SASL/ACL của Redpanda (IN-4): [ADR-0014](0014-kubernetes-local-stage4.md).

### Hệ quả

- Tốt: luồng upload chạy thật trên local: storage tự ép key, kích thước, content type (UP-1); credential theo service với quyền tối thiểu (UP-4, UP-5, FF-4); bucket `media` không liệt kê được (UP-6). Không mất event khi crash (outbox + commit tay); event cùng video giữ thứ tự (relay một luồng, key theo `video_id`); event hỏng không chặn partition (DLQ). ffmpeg chạy sau ba lớp whitelist (định dạng, codec, giao thức), giới hạn tài nguyên và container không quyền, không mạng ra ngoài (FF-1 tới FF-4, FF-7). Event `transcode.*` giả không đổi được video (FF-6): video-service chỉ nhận khi video đang `PROCESSING`, và mọi key phải dạng `media/<video_id>/<seg>/...`, mỗi đoạn chỉ gồm `[A-Za-z0-9._-]`, không phải `.` hay `..` (gateway ghép key vào URL phát, mà trình duyệt chuẩn hoá `%2e%2e` và `\` khi phân tích URL, nên key như `media/<id>/%2e%2e/<id khác>/...` trỏ được sang video khác). Code storage và Kafka dùng lại được trên AWS: cùng SDK S3, cùng Kafka API cho MSK; `make check` không cần Docker nhờ `kfake`.
- Xấu: thêm 5 dependency trực tiếp (`franz-go`, `kfake` cho test, `aws-sdk-go-v2`, `credentials`, `service/s3`) và các module nội bộ của SDK AWS trong `go.sum`. MinIO dùng image Chainguard ghim digest: cập nhật bằng tay, phụ thuộc chính sách của Chainguard. media-worker có image riêng trên alpine (có shell, package manager), khác chuẩn distroless của service. Relay outbox một luồng cho mỗi service; transaction mở trong lúc produce. Retry trong process chặn partition trong lúc retry: mặc định tối đa ~7,5 s chờ mỗi event lỗi; media-worker khoảng 4 phút chờ cộng thời gian các lần thử, vì lỗi của nó thường là storage hay broker gián đoạn. Chưa có lúc quyết: job dọn upload bỏ dở, giới hạn `UPLOADING` mỗi user (UP-7), rate limit; công cụ phát lại và cảnh báo DLQ; SASL/ACL Redpanda (IN-4); probe cho media-worker.
- Xem lại khi: digest MinIO không pull được, Chainguard đổi chính sách, hoặc có lỗ hổng chưa vá ảnh hưởng local (chuyển sang SeaweedFS, Garage hoặc RustFS bằng ADR mới); lag outbox (từ `created_at` tới `published_at`) p95 vượt 1 s, hoặc số event mỗi giây vượt khả năng một relay (cân nhắc relay theo phân đoạn key hoặc CDC, ADR-0003); thời gian transcode video 60 s trên 2 CPU vượt 90 s, hoặc kích thước HLS lệch A6 quá 30% (đổi preset hoặc ladder); thời gian tới khung hình đầu tiên ở 360p vượt 2 s trên mạng 4G giả lập (thử segment 2 s); cần nhiều hơn 3 media-worker song song (tăng partition của `video.lifecycle.v1`, chỉ tăng được).

## Xác nhận

Đã kiểm ngày 2026-10-11 trước khi quyết: version module (`go list -m -json <module>@latest`), `PresignPostObject` (đọc `presign_post.go` và chạy thử chương trình ký), image Redpanda, alpine + ffmpeg (có `-format_whitelist`, `-codec_whitelist`, `-protocol_whitelist`, encoder `libx264`, `aac`), image MinIO thay thế, cổng trống bằng `lsof -nP -iTCP -sTCP:LISTEN`; bảng lệnh và kết quả ở phụ lục. Kiểm bằng test: `internal/objstore/integration_test.go` (presigned POST, quyền theo user), test consumer và relay trên `kfake`, diễn tập `make drill-kill-worker`, `make drill-duplicates`, và `make measure-ready` (đo thời gian từ `CompleteUpload` tới `READY`, mục 10).

## Hiện thực ở

- Kafka và consumer (§1, §8): `internal/kafkax/` (franz-go, commit tay, DLQ); bảng `processed_events` và xử lý event ở `services/video-service/internal/server/transcode.go`.
- Object storage (§2–§4): `internal/objstore/` (aws-sdk-go-v2, presigned POST, hai endpoint, object key), test chạy thật ở `internal/objstore/integration_test.go`.
- Redpanda (§5): `deploy/redpanda/bootstrap.yaml`, `deploy/redpanda/create-topics.sh`. MinIO (§6): bị thay một phần bởi [0022](0022-local-object-store-minio-replacement.md); user, policy và bucket policy giữ ở `deploy/s3/` (`init.sh`, file JSON), service `s3` của `deploy/compose/compose.yaml`.
- Outbox một relay (§7): `internal/outbox/`, `services/video-service/migrations/00002_create_outbox.sql`.
- media-worker, HLS và ffmpeg (§9, §10): `services/media-worker/` (`cmd/media-worker/main.go`, `internal/worker/`, `internal/transcode/`), `deploy/docker/media-worker.Dockerfile`; trên k3d `deploy/k8s/values/services/media-worker.yaml`, `deploy/k8s/drills/keda.sh`.
- Cấu hình mới, cổng và RAM (§11, §12): `services/video-service/cmd/video-service/main.go`, `services/video-service/internal/server/server.go`, `deploy/compose/compose.yaml`.
- Diễn tập: `deploy/compose/drills/kill-worker.sh`, `deploy/compose/drills/duplicate-events.sh`, `deploy/compose/drills/measure-ready.sh`.

## Thông tin thêm

Phụ lục: [`appendix/0008-async-upload-pipeline-stage2a.md`](appendix/0008-async-upload-pipeline-stage2a.md) (trạng thái gốc, bảng kiểm chứng, phân tích phương án, bảng version, DDL outbox, bảng biến môi trường, bối cảnh MinIO).

### Chỉnh bởi

- §9: [0014](0014-kubernetes-local-stage4.md): đúng một replica media-worker chỉnh cho k8s.
- §6, §11, §12: [0022](0022-local-object-store-minio-replacement.md): MinIO image Chainguard, `minio-init` bằng `mc`, console, tên `minio` và biến `SVP_MINIO_ROOT_PASSWORD` (§11), cổng console (§12) bị thay một phần bằng RustFS, service `s3`, init viết lại (`deploy/s3/init.sh`, `curl --aws-sigv4` thay `mc`), CORS theo bucket, console tắt; user, policy và bucket policy của §6 giữ nguyên; image MinIO Chainguard chỉ còn trong `make object-store-copy`, làm đường quay lại.
- §6, §8, §10: [0029](0029-immutable-media-versions.md): policy của `svp-media-worker` thêm `GetObject` trên `media/media/*` và `ListBucket` theo tiền tố `media/*` (§6); media-worker idempotent bằng master tạo có điều kiện thay cho ghi đè đường dẫn cố định, `drill-duplicates` kiểm không object nào bị ghi (§8); đường dẫn `media/<id>/<version>/<attempt>/` (§10).
