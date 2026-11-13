# 0066. Transcode của stg, prd bằng AWS Elemental MediaConvert (tier Basic, queue on-demand) qua lệnh con `media-worker mediaconvert`: Probe trước job, bản ghi job quyết kết quả mỗi version, trạng thái job qua EventBridge và SQS, header đặt ở origin; compose, k3d giữ ffmpeg

- Trạng thái: Chấp nhận
- Ngày: 2026-11-13
- Người quyết: người học (mua dịch vụ managed cho stg, prd; bridge là lệnh con, không service mới), AI đề xuất thiết kế
  và bảng chi phí

## Bối cảnh và vấn đề

- [0004](0004-direct-upload-and-hls.md) (phần Phát) hứa "trên cloud, media-worker sẽ gọi MediaConvert (AWS) hoặc
  Transcoder API (GCP)"; [0034](0034-aws-stage7.md) dời MediaConvert sang mục tuỳ chọn mà không nêu đánh đổi, nên eks
  chạy ffmpeg trong cluster như k3d.
- Threat model FF-9: trên cloud phải kiểm thời lượng trước khi tạo job (dịch vụ tính theo phút output), chọn nhánh (a)
  thời lượng do nhà cung cấp báo nếu có, không thì (b) `ffprobe` trong cluster; giữ điểm cắt đầu vào làm trần chi phí.
- Hợp đồng event có sẵn (`video.uploaded` → `transcode.completed` / `transcode.failed`,
  `proto/svp/media/v1/events.proto`) và bất biến của [0029](0029-immutable-media-versions.md) (version, lần thử, master
  tạo một lần, `Cache-Control` một năm) phải giữ: video-service, feed-service, web không đổi. video-service coi `FAILED`
  là cuối và xoá nguồn, output.
- Ràng buộc: env sống trong buổi tối đa 4 giờ, stg chạy như prd ([0055](0055-environment-matrix.md)); CloudFront media
  của stg ở gói Free chỉ nhận policy managed ([0052](0052-cloudfront-flat-rate-free.md)); khác biệt nền tảng là dữ liệu
  của `svp-gitops`, không cờ trong code.

## Yếu tố quyết định

- File người dùng không mở trong cluster trên cloud (FF-1 tới FF-5 chuyển sang nhà cung cấp); quyền của thành phần trên
  cloud hẹp, có nguồn.
- Mỗi version đúng một kết quả dù job trùng, response mất, event lặp; at-least-once như mọi consumer khác
  ([0003](0003-async-events-outbox.md)).
- Chi phí buổi dưới trần $3 mỗi env cho phần này, $0 lúc không buổi; giá có nguồn.
- Một đường thẳng cho stg và prd; local giữ ffmpeg cùng hợp đồng; không đụng tập phát hành image.

## Phương án đã cân nhắc

Trạng thái ngành, được, mất, nguồn: [phụ lục](appendix/0066-mediaconvert-transcode.md#phương-án). In đậm là lựa chọn.

- Transcode ở stg, prd: ffmpeg trên EKS, KEDA theo lag Kafka (như k3d); **MediaConvert**; Google Cloud Transcoder API
  (chỉ GCP: phương án lúc chạy trên GCP).
- Bridge: **lệnh con của `media-worker`**; service mới với image không ffmpeg; Lambda.
- Trạng thái job: **EventBridge → SQS**; EventBridge → SNS; bridge gọi `GetJob` định kỳ.
- Kiểm thời lượng: **(a) `Probe` của MediaConvert**; (b) `ffprobe` trong cluster.
- Header: **`CopyObject` tại chỗ ở origin**; response headers policy của CloudFront.
- Bố cục output: **một bố cục phẳng cho cả hai đường**; `ParseMaster` nhận hai dạng; chép output sang bố cục cũ.

## Kết quả quyết định

Chọn các phương án in đậm. Giá trị mở (giá, giới hạn, tên trường, hành vi API) ghi một lần ở bảng "Giá trị → nguồn" của
phụ lục, mỗi dòng một nguồn AWS đọc 2026-11-13; code và hạ tầng đọc từ đó.

### 1. Mua: MediaConvert ở stg, prd; ffmpeg ở compose, k3d

MediaConvert là dịch vụ managed hiện hành cho VOD: file người dùng không vào cluster, node không phải có CPU cho đỉnh
transcode, job `ERROR` không tính tiền. Tier Basic đủ mọi tính năng cần (HLS với AVC, frame capture, input clipping,
xoay tự động); queue on-demand `svp-<env>`. stg và prd giống hệt (cùng module, tier, giới hạn): thành phần nhóm "phải
giống" của 0055. Compose, k3d chạy `serve` (ffmpeg) như cũ.

### 2. Bridge: lệnh con `media-worker mediaconvert`

Cùng image, release `media-worker`, user Kafka `svp-media-worker`, group, KEDA; nền tảng chọn lệnh bằng value `args` của
chart `svp-service` (mặc định rỗng là `serve`, eks đặt `[mediaconvert]` ở `svp-gitops`). Lý do: tập phát hành
(`sources.json`, `envs/<env>/images/`, luật cây gitops, promote) đòi một image đã ký cho mỗi service ở mọi env, chỉ có
sau khi backend merge; service mới cần cơ chế nhận service qua ba repo chưa có. Cái giá: image trên eks mang ffmpeg
không dùng. SDK thêm `aws-sdk-go-v2/service/mediaconvert` và `.../service/sqs`, cùng module SDK đã dùng cho S3, vì
bridge gọi hai API đó; không thư viện nào khác.

### 3. Kiểm đầu vào bằng Probe (FF-9 nhánh (a))

`Probe` trên `s3://<uploads>/uploads/<video_id>` trước khi tạo job, so với giới hạn của `serve` (một nguồn hằng số): quá
thời lượng → `DURATION_EXCEEDED`; không thời lượng, không track video, kích thước hay fps vượt → `INVALID_INPUT`; object
không có → `SOURCE_MISSING`. Probe cho kích thước hiển thị (trường `rotation` của track) và có audio hay không. Probe
không nhận role: nó đọc S3 bằng quyền người gọi, nên bridge giữ `s3:GetObject` trên `uploads` dù không tự mở file.

### 4. Job

Settings dựng trong Go (provider Terraform không có job template): thang của `serve` trên kích thước hiển thị, H.264 +
AAC, segment 4 s, keyframe 2 s, xoay tự động, không audio khi nguồn không có, một frame capture JPEG, `UserMetadata`
mang `video_id`, `version`, `attempt` (UUID mới mỗi lần gọi, cũng là `ClientRequestToken`), `traceparent`. Token chỉ
chống trùng trong một phút, nên không dựa vào nó. Trần chi phí là `InputClippings` với `EndTimecode` = min(180 s, thời
lượng track video của Probe), làm tròn xuống một frame theo fps của Probe, `TimecodeSource` `ZEROBASED`: output không
dài hơn thời lượng Probe báo, và không quá 180 s; trên 100 fps FF chỉ hai chữ số nên cắt sớm dưới 0,2 s (phụ lục §4). Điểm cuối cố định 3:00 không dùng được: nó nằm ngoài timeline của mọi
video ngắn hơn, và timecode ngoài input là lỗi 1060. File có timeline ngắn hơn metadata cũng gặp 1060, thành
`INVALID_INPUT` (phụ lục §4).

### 5. Bố cục output

Mọi object của một lần thử phẳng trong `media/<video_id>/<version>/<attempt>/`: playlist `index_<rendition>.m3u8`,
segment cùng thư mục, `thumbnail.jpg`; URI biến thể trong master là `<attempt>/index_<rendition>.m3u8`, `serve` đổi
theo. Lý do: MediaConvert đặt tên playlist bằng tên gốc của destination cộng `NameModifier` trong một thư mục; tên thư
mục con mỗi stream không có trong tài liệu. Master kiểu cũ trong volume local không đọc lại: dựng lại stack local.

### 6. Bản ghi job quyết kết quả mỗi version

Object `transcode-jobs/<video_id>/<version>.json` của bucket media, chỉ tạo bằng `If-None-Match: *`, không ghi lại: job
của version hay lý do hỏng trước khi có job. Job không có tên trong bản ghi không quyết kết quả. Đường `video.uploaded`
và đường SQS cùng một hàm `settle` trên bản ghi, nên response mất, người gọi cũ tỉnh lại, request xong muộn, `ERROR` của
job lạc không đổi được kết quả đã có; lý lẽ từng nhánh ở phụ lục §6. Bản ghi nằm ngoài `media/`: CDN không đọc, cleanup
`media/<video_id>/` của video-service không xoá; lifecycle xoá sau 30 ngày. Kết quả còn bất định (ghi bản ghi lỗi ở lần
thử cuối) thì không phát gì: dead-letter topic, video ở `PROCESSING`.

### 7. Trạng thái job: EventBridge → SQS, DLQ, alarm

Rule `svp-<env>-mediaconvert-job-state` (default bus, `aws.mediaconvert`, `COMPLETE`/`ERROR` của queue env) gửi vào SQS
`svp-<env>-transcode-events` (SSE-SQS, policy theo `aws:SourceArn`, chặn không TLS), redrive và DLQ của đích tới
`svp-<env>-transcode-events-dlq` sau `maxReceiveCount` 5; alarm DLQ mức page. Bridge chỉ hành động trên message có job
của queue env, `UserMetadata` đúng dạng và destination dưới thư mục lần thử; message khác để redrive đưa vào DLQ.
`ERROR` → `transcode.failed`: mã lỗi do đầu vào → `INVALID_INPUT`, còn lại → `RETRIES_EXHAUSTED`, không nộp lại job
(bảng mã ở phụ lục). Event mất (quá hạn thử của EventBridge, hay message vào DLQ) để video ở `PROCESSING`: giới hạn đã
nhận, xử lý ở runbook `transcode-events-dlq`.

### 8. Header, master, kết quả

MediaConvert không đặt được `Cache-Control` trên output S3. Khi `settle` job `COMPLETE`, bridge `CopyObject` tại chỗ
từng object của lần thử (`MetadataDirective` `REPLACE`, `Cache-Control`, `Content-Type` như `serve`), chép frame capture
thành `thumbnail.jpg`, rồi mới tạo master `If-None-Match` bằng hàm dựng master của `serve` (kích thước thật từ
`GetJob`). `transcode.completed` dựng chỉ từ object đã lưu, đường `stored` của `serve`: thời lượng là tổng `EXTINF` của
playlist thấp nhất, không lấy từ event. CloudFront và module `media` không đổi ở cả hai env.

### 9. IAM

- Role `svp-<env>-mediaconvert`: trust `mediaconvert.amazonaws.com` với `aws:SourceAccount` và `aws:SourceArn` là ARN
  queue (cách tài liệu chống confused deputy); `s3:GetObject` trên `uploads/*` của `uploads`, `s3:PutObject` trên
  `media/*` của `media`; không KMS vì bucket SSE-S3.
- Role Pod Identity của `media-worker`: `CreateJob` trên queue, `GetJob`, `Probe`, `iam:PassRole` có
  `iam:PassedToService`, ba action SQS, S3 trên `media/*`, `transcode-jobs/*` và `uploads/*`, `ListBucket` theo hai tiền
  tố của `media`. Bảng đủ, mỗi dòng một nguồn: phụ lục §9.

### 10. Mạng

Endpoint interface `mediaconvert` vào danh sách của module `network` (cùng private DNS, security group, policy của
[0064](0064-interface-endpoints.md)); `sqs` đã có. Values eks của `media-worker` thêm
`{cidr: <cluster.vpcCidr>, ports: [443]}` vào `externalPeers.s3` có sẵn, không value egress mới. Cái giá: pod ra được
TCP 443 tới mọi IP trong VPC, không chỉ endpoint.

### 11. Metric

`svp.transcode.duration` (cùng tên, bucket, `outcome` như `serve`) bằng `Timing.FinishTime − Timing.StartTime` của job
trong bản ghi: thời gian MediaConvert xử lý, không tính chờ queue. `ready` ghi khi `settle` tạo được master; `failed`
ghi khi `settle` phát `transcode.failed` từ message của chính job đó. Dashboard, alert không đổi.

### 12. Chi phí

Basic ở `ap-southeast-1`: $0,0085 mỗi phút chuẩn hoá (SD 1×, HD 2× ở ≤ 30 fps), tối thiểu 10 s mỗi output, Probe miễn
phí tới một triệu lần mỗi tháng. Một phút video dọc 1080p ra ba bậc và frame capture là ~7 phút chuẩn hoá, ~$0,06. Phần
của thay đổi này mỗi buổi 4 giờ (smoke, seed, đo hai đường, kiểm FF-9, endpoint, SQS, S3, alarm): ~$0,72 ở stg, ~$0,84 ở
prd; $0 lúc không buổi. Bảng: phụ lục, mục "Chi phí".

### Hệ quả

- Tốt: file người dùng không mở trong cluster trên cloud; eks không cần CPU cho transcode; kết quả mỗi version duy nhất
  mà không khoá, không database; video-service, feed-service, web và hợp đồng `proto/` không đổi; stg, prd một đường.
- Xấu: thêm queue, role, rule, hai SQS, alarm, endpoint và runbook; bridge vẫn đọc được `uploads` (Probe); job lạc
  `COMPLETE` vẫn tính tiền và để object mồ côi; job đầu lỗi tạm làm version `FAILED` (không nộp lại); event mất để video
  ở `PROCESSING` tới khi người vận hành chuyển DLQ; image eks mang ffmpeg; `serve` và volume local đổi bố cục.
- Xem lại khi: phép đo hai đường cho chi phí mỗi phút của MediaConvert vượt xa ffmpeg trên node ở tải thật; cần caption,
  DRM, nhiều audio (Professional); chạy trên GCP (Transcoder API); số video mỗi ngày làm job lạc hay event mất thành
  việc thường xuyên.

## Xác nhận

- Lúc quyết chưa hiện thực. Kiểm tĩnh: test vàng `CreateJobInput` của bridge, test `settle` cho từng nhánh ở phụ lục §6,
  `make test` của `svp-infra` (module `transcode`, endpoint), `make helm-check` (`args` rỗng render như cũ).
- Account sandbox: Probe, một job mẫu thật (tên output, header sau `CopyObject`, quyền tối thiểu của role, điểm cắt đầu
  vào), output thành testdata.
- Buổi stg, prd: smoke, seed, kiểm FF-9 (clip 200 s → `DURATION_EXCEEDED`, không job), phép đo hai đường; bảng kết quả ở
  phụ lục.
- Chưa đo: thời gian tới `READY` và chi phí thật mỗi phút của hai đường.

## Hiện thực ở

- Repo này: `services/media-worker/` (lệnh con `mediaconvert`, `internal/mediaconvert/`, bố cục phẳng của `serve`),
  `internal/objstore/` (chép tại chỗ), `deploy/helm/svp-service/` (value `args`), `deploy/compose/transcode-timing.sh`,
  `docs/explanation/transcode.md`, `docs/runbooks/transcode-events-dlq.md`.
- `svp-infra`: `aws/modules/transcode/` (queue, role, rule, SQS, DLQ, alarm, policy của bridge), `aws/modules/network/`
  (endpoint `mediaconvert`), `aws/modules/media/` (S3 của bridge, lifecycle `transcode-jobs/`), `aws/envs/<env>/`,
  `aws/scripts/`.
- `svp-gitops`: `platforms/eks/media-worker.yaml`, `platforms/eks/media-worker.values.tpl` (`args`, biến, egress).

## Nguồn

Đọc 2026-11-13; đủ [N1]–[N43] ở phụ lục. [N1] <https://aws.amazon.com/mediaconvert/pricing/>, [N3]
<https://docs.aws.amazon.com/mediaconvert/latest/apireference/idempotency.html>, [N4]
<https://docs.aws.amazon.com/mediaconvert/latest/apireference/probe.html>, [N5]
<https://docs.aws.amazon.com/mediaconvert/latest/ug/output-file-names-and-paths.html>, [N8]
<https://docs.aws.amazon.com/mediaconvert/latest/apireference/jobs-id.html>, [N9]
<https://docs.aws.amazon.com/mediaconvert/latest/ug/mediaconvert_error_codes.html>, [N15]
<https://docs.aws.amazon.com/mediaconvert/latest/ug/cross-service-confused-deputy-prevention.html>, [N21]
<https://docs.aws.amazon.com/AmazonS3/latest/userguide/conditional-writes.html>.

## Thông tin thêm

Phụ lục: [`appendix/0066-mediaconvert-transcode.md`](appendix/0066-mediaconvert-transcode.md) (phương án, giá trị →
nguồn, quyết định kết quả từng nhánh, mã lỗi, bảng quyền, chi phí, control FSBP, luồng SCP, RCP, phương pháp và bảng đo
hai đường, nguồn).
