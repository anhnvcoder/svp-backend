# 0029. Output HLS bất biến theo version: `media/<video_id>/<version>/…` với version là `event_id` của `video.uploaded`, mỗi lần thử ghi thư mục riêng và master chỉ tạo một lần, `Cache-Control: max-age=31536000, immutable`; CMAF (fMP4) chỉ đánh giá, làm khi chạm transcode

- Trạng thái: Chấp nhận
- Ngày: 2026-10-28
- Người quyết: người học (duyệt 2026-10-28; chốt trước layout có version, không ghi đè, header và hướng CMAF)

## Bối cảnh và vấn đề

- [ADR-0004](0004-direct-upload-and-hls.md) (phần Phát) ghi output HLS vào đường dẫn cố định `media/<video_id>/`, transcode lại chỉ ghi đè; [ADR-0008](0008-async-upload-pipeline-stage2a.md) §8 dựa vào đó cho idempotency của media-worker, §10 chốt layout `media/<id>/master.m3u8`, `media/<id>/<rendition>/…`, `media/<id>/thumbnail.jpg`.
- Ghi đè cùng key xung đột với cache dài: libx264 đa luồng không bit-exact, nên transcode lại đổi byte của segment dưới cùng URL, và bản trong cache trình duyệt không xoá được; object chưa mang `Cache-Control` nào. Egress là khoản chi lớn nhất ([explanation/capacity.md](../explanation/capacity.md)) và cloud đặt CloudFront trước bucket `media`, cache theo `max-age` của origin [N7]; cache dài đòi URL đổi khi nội dung đổi, đúng cách `immutable` được thiết kế cho [N5].
- **Người học đã chốt** (2026-10-28): output ở `media/<video_id>/<version>/…`; transcode lại ghi version mới, không sửa object cũ; `Cache-Control: max-age=31536000, immutable` cho segment và playlist VOD; CMAF chỉ đánh giá. ADR này chốt version là gì, cách bảo đảm không ghi đè object đã công khai, cách phát lại kết quả, header, tương thích ngược, bảng CMAF.
- **Ràng buộc:** event mang object key, không URL ([ADR-0006](0006-contract-ids-and-event-envelope.md) §6), key phải qua `objstore.IsMediaKey`; video-service từ chối `transcode.completed` có `duration` không dương và chỉ nhận khi video `PROCESSING`; `event_id` là UUIDv7 sinh trước khi commit outbox, `video.uploaded` chỉ ghi một lần mỗi video; hai lần thử cùng event có thể chạy song song (kafkax không huỷ handler khi mất partition, `RebalanceTimeout` 164 phút); `svp-media-worker` chỉ có `s3:GetObject` trên `uploads/uploads/*` và `s3:PutObject` trên `media/media/*`, và trên S3, HEAD key chưa có trả 403 khi thiếu `s3:ListBucket` [N13]. Chi tiết: phụ lục, mục "Bối cảnh".

## Yếu tố quyết định

- Không byte nào dưới URL đã công khai đổi, kể cả khi hai worker chạy cùng event; cache một năm nói thật.
- Phát lại cùng event không tốn transcode và không để lại rác; không thêm khoá, database hay trạng thái ngoài store cho media-worker.
- Quyền thêm tối thiểu; contract `proto/` không phá vỡ; video cũ vẫn phát.

## Phương án đã cân nhắc

- §1 version: A. id ngẫu nhiên mỗi lần chạy: phát lại để lại object mồ côi.
- §1 B. số đếm tăng dần: cần trạng thái chung, hai worker lấy cùng số.
- §1 **C. `event_id` của `video.uploaded`**: tất định, không trạng thái ngoài event; lộ mốc `CompleteUpload` trong URL.
- §1 D. băm nội dung: đọc trọn file gốc, transcode lại cố ý không ra version mới.
- Không ghi đè: K1. chung prefix, kiểm master trước, master cuối: không chặn writer cũ.
- Không ghi đè: K2. `If-None-Match: *` mọi object chung prefix: segment hai lần chạy trộn nhau.
- Không ghi đè: K3. khoá theo video: S3 không có fencing token.
- Không ghi đè: **K4. mỗi lần thử một thư mục, master là object duy nhất ở cấp version, tạo một lần bằng `If-None-Match: *`** [N14].
- Nhận biết master đã có: E1. HEAD: 403 khi thiếu `ListBucket` [N13], lần đầu mọi video thành lỗi quyền.
- Nhận biết master đã có: **E2. `ListObjectsV2` với `Prefix` là key master, `MaxKeys` 1**: quyền giới hạn được bằng `s3:prefix`.
- Nhận biết master đã có: E3. chỉ dựa vào 412: mỗi lần phát lại chạy trọn ffmpeg.
- Lấy `duration`, renditions khi master đã có: **R1. đọc lại master và playlist rendition đã lưu**.
- Lấy `duration`, renditions khi master đã có: R2. object `result.json`: thêm object công khai, thêm định dạng.
- Lấy `duration`, renditions khi master đã có: R3. transcode lại không tải lên: tới 10 phút CPU.

Được/mất đầy đủ: phụ lục, mục "Các lựa chọn".

## Kết quả quyết định

Chọn C, K4, E2, R1 và giữ MPEG-TS, vì version tất định theo yêu cầu transcode, writer cũ chỉ ghi được vào thư mục không ai trỏ tới, master tạo đúng một lần, phát lại không transcode, và không cần khoá hay trạng thái ngoài store. Mỗi § dưới giữ quyết định; lập luận từng bước và toàn văn ở phụ lục.

### 1. Version: `event_id` của `video.uploaded` (C); mỗi lần thử một thư mục (K4)

- `V` là `meta.event_id` của `video.uploaded`; `A` là UUIDv7 mới (`ids.New`) mỗi lần handler chạy, không bao giờ dùng lại. Master `media/<video_id>/<V>/master.m3u8` do đúng một lần thử tạo bằng `If-None-Match: *`; playlist rendition, segment, thumbnail ở `media/<video_id>/<V>/<A>/…`, chỉ lần thử `A` ghi.
- Tên file và thứ tự tải lên giữ như ADR-0008 §9–§10 (master cuối cùng); URI biến thể trong master là đường tương đối `<A>/<rendition>/index.m3u8` (RFC 8216 §4.1 [N1]): worker thêm `<A>/` vào dòng URI sau mỗi `#EXT-X-STREAM-INF`; master có `#EXT-X-MEDIA` hay `#EXT-X-I-FRAME-STREAM-INF` là lỗi.
- `meta.event_id` sai dạng UUID chuẩn thì `kafkax.Permanent` (sang DLQ); không đoạn path nào lấy từ nội dung file gốc.
- `transcode.completed` mang `playlist_key` (master của version) và `thumbnail_key` (trong thư mục lần thử master trỏ tới); không thêm field. Transcode lại là event mới, version mới; luồng transcode lại cần thiết kế riêng khi có nhu cầu.

### 2. Trình tự một lần thử (K4, E2, R1)

1. **Kiểm master** bằng `ListObjectsV2` (`Prefix` là key master, `MaxKeys` 1): có thì sang bước 5, rỗng thì bước 2; lỗi, kể cả 403, là lỗi storage tạm thời, không bao giờ coi là "chưa có"; không dùng HEAD hay GET để hỏi.
2. **Transcode** như nay; nhánh `transcode.failed` không đổi.
3. **Tải lên thư mục của lần thử:** sửa URI master, tải tuần tự segment, thumbnail, playlist rendition dưới `media/<video_id>/<V>/<A>/`.
4. **Tạo master** bằng `PutObject` có `If-None-Match: *`: thành công thì phát `transcode.completed` với key của `A`, `duration` và renditions phân tích từ master vừa tải lên và playlist rendition thấp nhất của nó; 412 thì sang bước 5 (thư mục `A` thành mồ côi nếu master không trỏ tới); lỗi khác (409, 5xx, mạng) là lỗi tạm thời, lần thử sau bắt đầu lại từ bước 1 với `A` mới.
5. **Master đã có:** không transcode, không PUT gì; tải master và playlist rendition thấp nhất (mỗi file tối đa 1 MiB), URI biến thể phải cùng một `A'` là UUID chuẩn và tên rendition của ladder, `RESOLUTION` cho kích thước, bitrate tra từ ladder, `duration` là tổng `#EXTINF` (phải dương), `thumbnail_key` trong `A'`; rồi phát `transcode.completed`. Phân tích dùng chung một hàm với bước 4. Lỗi ở bước này là lỗi tạm thời, hết lượt thì `RETRIES_EXHAUSTED`; **không bao giờ** ghi lại gì của version đó.

Vì sao `immutable` nói thật: người xem chỉ tới object qua key mà video-service công khai sau khi master có; master chỉ được tạo, không bao giờ ghi lại [N14]; object trong `A*` chỉ lần thử `A*` ghi, xong trước khi tạo master, và `A` không dùng lại; thư mục mồ côi không được trỏ tới, bucket không cho liệt kê ẩn danh (UP-6), `A` có 62 bit ngẫu nhiên; video `FAILED` bị `DeletePrefix("media/<id>/")` xoá mọi version.

Quyền của `svp-media-worker` thêm hai statement: `s3:GetObject` trên `arn:aws:s3:::media/media/*` (bước 5) và `s3:ListBucket` trên `arn:aws:s3:::media` với `StringLike` `s3:prefix` `media/*` (bước 1); `If-None-Match: *` chỉ cần `s3:PutObject`; liệt kê ẩn danh vẫn đóng; ở cloud hai quyền vào IAM role của worker.

### 3. Header

- `Cache-Control: max-age=31536000, immutable` (RFC 8246 [N5], RFC 9111 §5.2.2.1 [N6]) đặt lúc `PutObject` cho **mọi** object của một version: segment, playlist rendition (VOD, không đổi được [N1]), master (chỉ tạo một lần), thumbnail (key nằm dưới version). Không thêm `public`.
- `objstore.Upload` nhận thêm giá trị `Cache-Control` (rỗng là không đặt); bucket `uploads` không đổi.
- Store trả lại header đã lưu: RustFS lưu `Cache-Control` của `PutObject` [N9]; S3 + CloudFront cache theo `max-age` trong giới hạn Maximum TTL, cache policy trên cloud đặt Maximum TTL ≥ 31536000 nếu muốn edge giữ trọn năm [N7]; Envoy của k3d không sửa header response.
- Ở compose (HTTP `localhost`) trình duyệt có thể bỏ qua `immutable` [N5], `max-age` vẫn có hiệu lực; k3d (HTTPS) và CloudFront không bị.

### 4. Tương thích ngược

- Video `READY` cũ giữ key `media/<id>/master.m3u8`, không di chuyển dữ liệu, không đặt lại header; gateway, feed-service chỉ dùng key do event mang, `IsMediaKey` nhận cả hai dạng; `DeletePrefix("media/<id>/")` xoá mọi version và layout cũ.
- Phát lại `video.uploaded` của video cũ ghi một version mới mà video-service bỏ qua (video đã `READY`): object mồ côi, chấp nhận ở lab, dọn tay nếu cần.
- `proto/`: chỉ đổi comment (`TranscodeEvent`, `playlist_key`), không đổi field, số, tên (`buf breaking` sạch); `make generate` cùng thay đổi.

### 5. CMAF (fMP4): đánh giá, làm khi chạm transcode

Giữ MPEG-TS bây giờ: ladder chỉ H.264 + AAC, phát được ở mọi đích (hls.js transmux TS [N3], HLS gốc), không DRM, không DASH, không live. Chuyển sang fMP4 (CMAF) trong cùng thay đổi với lần chạm transcode kế tiếp, version mới tách sạch output cũ và mới. Xem lại khi: thêm HEVC hay AV1 (Apple bắt buộc fMP4 [N2]); cần DRM hay DASH; làm live hay LL-HLS; đo được thời gian main thread do hls.js transmux đáng kể trên máy yếu. Bảng so TS với fMP4: phụ lục.

### Hệ quả

- Tốt: cache một năm ở trình duyệt và CDN cho toàn bộ output HLS, giảm request và egress lặp lại (nhất là thumbnail của feed); hai worker cùng event không đổi được byte nào đã công khai, không khoá hay trạng thái ngoài store; phát lại `video.uploaded` không chạy ffmpeg (một lệnh liệt kê và hai GET nhỏ thay tới 10 phút CPU); transcode lại (CMAF) có sẵn đường: version mới ở URL mới.
- Xấu: worker thêm quyền đọc và liệt kê `media/` và một nhánh code; path dài thêm hai đoạn UUID (74 ký tự), UUIDv7 lộ mốc thời gian trong URL; phụ thuộc ghi có điều kiện của store, đổi store (như đường quay lại MinIO của [ADR-0022](0022-local-object-store-minio-replacement.md)) phải qua lại phép kiểm; object mồ côi chưa có job dọn; `drill-duplicates` đổi tiêu chí (không ghi gì, giống hệt từng byte) thay cho "`BANDWIDTH` lệch ≤ 5 %".
- Xem lại khi: có luồng transcode lại thật (đổi key của video `READY`, xoá version cũ sau khi hết hạn cache); object mồ côi chiếm chỗ đáng kể (job dọn chỉ xoá thư mục lần thử dưới version **đã có master** mà master không trỏ tới); các điều kiện CMAF ở §5.
- ADR cũ được chỉnh bởi ADR này: ADR-0004 (phần Phát), ADR-0008 §6, §8, §10; nội dung chỉnh ở phụ lục, mục "Hệ quả".

## Xác nhận

- `make test-stack` trên runner: RustFS 1.0.3 làm đúng ghi có điều kiện (`TestIntegrationCreateOnce`), lưu và trả `Cache-Control` khi GET ẩn danh (`TestIntegrationCacheControl`), policy thật của worker đủ cho E2 và R1 (`TestIntegrationWorkerReadsMedia`).
- `make smoke`, `make k8s-smoke` (qua Envoy, cả cluster GitOps): key có version và lần thử, mọi object mang header; `drill-duplicates`: phát lại không ghi object nào, ETag giữ nguyên; `drill-kill-worker`: `READY` một lần, master trỏ thư mục lần thử sau.
- Unit test `worker`, `transcode` (`-race`): hai lần thử song song, đọc lại playlist ra cùng giá trị; `buf lint`, `buf breaking` sạch.
- Chưa kiểm riêng: video `READY` cũ (key không version) trên volume có video cũ. Bảng kiểm chứng và id lượt chạy: phụ lục, mục "Kiểm chứng sau".

## Hiện thực ở

- `services/media-worker/internal/worker/worker.go` (+ `worker_test.go`): version từ `meta.event_id`, kiểm master bằng `Storage.Exists`, id lần thử, tạo master bằng `Storage.Create`, `job.stored` phát lại kết quả, hằng `cacheControl`.
- `services/media-worker/internal/transcode/transcode.go` (+ `transcode_test.go`): `rewriteMaster`, `ParseMaster`, `Master.LowestPlaylist`, `PlaylistDuration`.
- `internal/objstore/objstore.go` (`Upload(…, cacheControl)`, `Create`, `Exists`), `internal/objstore/integration_test.go`.
- `proto/svp/media/v1/events.proto`, `proto/svp/video/v1/events.proto`, `proto/svp/video/v1/video_service.proto`, `proto/svp/feed/v1/feed_service.proto` (comment của key), `gen/go`.
- `deploy/s3/media-worker-policy.json`, `deploy/s3/init.sh`; `deploy/compose/smoke.sh`, `deploy/compose/drills/duplicate-events.sh`, `deploy/compose/drills/kill-worker.sh`, `deploy/ci/verify-steps/objstore.sh` (bước `test-stack-objstore`), `deploy/ci/verify-steps/objstore-test.sh`. Mô tả từng file: phụ lục, mục "Hiện thực ở".

## Nguồn

- [N1] RFC 8216, HTTP Live Streaming: <https://www.rfc-editor.org/rfc/rfc8216.html>
- [N5] RFC 8246, HTTP Immutable Responses: <https://www.rfc-editor.org/rfc/rfc8246.html>
- [N7] Amazon CloudFront, "Manage how long content stays in the cache (expiration)": <https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/Expiration.html>
- [N14] Amazon S3, "How to prevent object overwrites with conditional writes": <https://docs.aws.amazon.com/AmazonS3/latest/userguide/conditional-writes.html>
- Danh sách đầy đủ [N1]–[N16] kèm trích dẫn và ngày đọc: phụ lục, mục "Nguồn".

## Thông tin thêm

Phụ lục: [`appendix/0029-immutable-media-versions.md`](appendix/0029-immutable-media-versions.md) (tiêu đề và trạng thái gốc, bối cảnh đầy đủ, mọi phương án, toàn văn các §, bảng CMAF, "Kiểm chứng sau", hệ quả, hiện thực ở, nguồn).
