# Phụ lục ADR-0066: Transcode của stg, prd bằng AWS Elemental MediaConvert

Phụ lục của [ADR-0066](../0066-mediaconvert-transcode.md): phương án, bảng "giá trị → nguồn", các bảng quyền, mã lỗi,
chi phí, bảng control FSBP, bảng luồng SCP, RCP, phương pháp đo hai đường và nguồn, xếp theo §. Mọi nguồn đọc ngày
2026-11-13. Đường dẫn `aws/...` không kèm repo là của `svp-infra`; `<region>` là `ap-southeast-1`, `<account>` là
account của env, `<uploads>`, `<media>` là tên bucket theo [0038](../0038-s3-bucket-names.md)
(`svp-<env>-uploads-<account>-<region>`, `svp-<env>-media-<account>-<region>`).

## Phương án

| Câu hỏi | Phương án | Trạng thái ngành | Được | Mất | Nguồn |
| --- | --- | --- | --- | --- | --- |
| Transcode ở stg, prd | ffmpeg trong `media-worker` trên EKS, KEDA scale theo lag Kafka (như k3d) | Hiện hành (tự vận hành trên Kubernetes) | Một đường cho mọi nền tảng; không dịch vụ mới; chi phí theo CPU node | File người dùng chạy trong cluster (FF-1 tới FF-5 vẫn ở ta); node phải có CPU cho đỉnh; cập nhật ffmpeg, whitelist, giới hạn tài nguyên là việc của ta | [N38], threat model FF-1…FF-5 |
| | **AWS Elemental MediaConvert, tier Basic, queue on-demand** | Hiện hành, dịch vụ managed của AWS cho VOD | File người dùng không vào cluster (FF-9 nhánh (a)); không CPU node cho transcode; job lỗi không tính tiền | Tính theo phút output; thêm EventBridge, SQS, role, bridge; hành vi API phải theo tài liệu | [N1], [N2], [N9] |
| | Google Cloud Transcoder API | Hiện hành, dịch vụ managed của GCP | Cùng mô hình với MediaConvert | Chỉ có trên GCP: là phương án của lúc chạy trên GCP, không dùng được ở AWS | [N37] |
| Bridge | **Lệnh con `media-worker mediaconvert`** (cùng image, release, user Kafka, KEDA) | — | Không đụng tập phát hành (CI, `sources.json`, ECR, luật cây gitops, promote, Kyverno) | Image trên eks mang ffmpeg không dùng (bề mặt CVE vẫn chặn phát hành) | ADR §2 |
| | Service mới, image riêng không ffmpeg | — | Image nhỏ, không ffmpeg | Tập phát hành đòi một image đã ký cho mỗi service ở mọi env, chỉ có sau khi backend merge: cần cơ chế nhận service mới qua ba repo, chưa có | ADR §2 |
| | Lambda | Hiện hành | Không pod | Thêm runtime, đóng gói, IAM ngoài cluster; cần SCRAM tới MSK trong VPC và cùng code hợp đồng | — |
| Trạng thái job về | **EventBridge rule → SQS (DLQ, alarm)** | Hiện hành, cách AWS mô tả cho MediaConvert | Giữ message khi bridge chết; thử lại, DLQ có sẵn | Thêm hai queue, policy | [N10], [N28], [N29] |
| | EventBridge → SNS | Hiện hành | Fan-out | Không giữ lại khi bridge không nghe | — |
| | Bridge gọi `GetJob` định kỳ | Cũ | Không hạ tầng mới | `GetJob` 2 request/s mỗi account [N12]; trễ theo chu kỳ poll | [N12] |
| Kiểm thời lượng (FF-9) | **(a) `Probe` của MediaConvert** | Hiện hành | Không mở file người dùng trong cluster | Probe đọc S3 bằng quyền người gọi (§3): bridge giữ `s3:GetObject` trên `uploads` | [N4] |
| | (b) `ffprobe` trong cluster | Hiện hành | Như `serve` | Bridge gánh FF-1 tới FF-4 cho bước này | Threat model FF-9 |
| Header `Cache-Control` | **`CopyObject` tại chỗ ở origin** | Hiện hành | Một đường cho stg (CloudFront gói Free) và prd | Vài chục request mỗi video, vài giây trước `READY` | [N22], [0052](../0052-cloudfront-flat-rate-free.md) |
| | Response headers policy của CloudFront | Hiện hành | Không request thêm | Gói Free của stg chỉ nhận policy managed: stg khác prd | [0052](../0052-cloudfront-flat-rate-free.md) |
| Bố cục output | **Phẳng chung hai đường: `<attempt>/index_<rendition>.m3u8`** | — | Một `ParseMaster`, một bố cục | `serve` đổi tên file; master kiểu cũ ở volume local không đọc lại | [N5], [N6] |
| | `ParseMaster` nhận hai dạng | — | `serve` không đổi | Nhánh theo nguồn trong code | — |
| | Bridge chép output sang bố cục cũ | — | `serve` không đổi | Gấp đôi object và request | — |

## Giá trị → nguồn

Mỗi giá trị mở của thiết kế một dòng; bảng chi tiết ở mục cùng tên bên dưới.

| Giá trị | Chốt | Nguồn |
| --- | --- | --- |
| Tier | Basic: có HLS với AVC, frame capture, input clipping; Professional chỉ thêm caption, DRM, nhiều track audio… không dùng | [N1] (bảng so tier) |
| Giá mỗi phút output, `ap-southeast-1` | Basic, AVC single-pass: $0,0085 mỗi phút chuẩn hoá (100 000 phút đầu mỗi tháng); hệ số SD 1×, HD 2×, 4K 4× ở ≤ 30 fps (1,25×, 2,5× ở > 30–60 fps); SD < 720, HD 720–1080, dọc đo theo chiều ngang; tính theo giây, tối thiểu 10 s mỗi output; job `ERROR` không tính | [N1], [N2] (`SIN-Normalized-Transcode-Minute-Basic`, `SIN-B-AVC-SD-S-30` $0,0085, `SIN-B-AVC-HD-S-30` $0,017), [N9] |
| **Chi phí R5** | ~$0,72 mỗi buổi stg, ~$0,84 mỗi buổi prd; $0 lúc không buổi | Mục "Chi phí" |
| `ClientRequestToken` | Chỉ trả lại job cũ khi dùng lại token trong một phút sau request thành công; không chống trùng sau đó, nên kết quả do **Bản ghi job** quyết | [N3] |
| IAM của `Probe` | Request chỉ có `inputFiles[].fileUrl`, không có role (khác `CreateJob`, `role` bắt buộc): MediaConvert chỉ có quyền người gọi để đọc S3; bridge cần `s3:GetObject` trên `<uploads>/uploads/*`. Lỗi 403 của Probe là "credentials you sent" | [N4], [N8] |
| Trường của Probe | `probeResults[].container.duration` (giây); `container.tracks[]` với `trackType` `video`/`audio`, `duration` (giây, của track); `videoProperties.width`, `height` (kích thước mã hoá), `frameRate` (`numerator`/`denominator`); `videoProperties.rotation` (độ, theo chiều kim đồng hồ, từ ma trận `tkhd` của MP4; null khi 0 hay không có) | [N4] |
| Đặt tên output | HLS: tên playlist = tên gốc của destination + `NameModifier` (`main` + `v1` → `mainv1.m3u8`), manifest của group = tên gốc (`main.m3u8`); frame capture đánh số tự động (`file.0000036.jpg`); `HlsDirectoryStructure` `SINGLE_DIRECTORY` | [N5], [N6], [N7], [N8] |
| Điểm cắt `InputClippings` | `EndTimecode` = frame cuối của min(180 s, thời lượng track video của Probe) (FF ≤ 99), `TimecodeSource` `ZEROBASED`; timecode ngoài timeline của input là lỗi 1060 (§4) | [N4], [N8], [N9], [N19] |
| `Cache-Control` trên output | MediaConvert không đặt được: `S3DestinationSettings` chỉ có `accessControl`, `encryption`, `storageClass` | [N8] |
| Trường `GetJob` dùng | `status`, `queue`, `userMetadata`, `errorCode`, `errorMessage`, `timing.startTime`/`finishTime`, `outputGroupDetails[].outputDetails[].durationInMs`, `videoDetails.widthInPx`/`heightInPx`, `settings.outputGroups[].outputGroupSettings.hlsGroupSettings.destination`, `fileGroupSettings.destination` | [N8] |
| S3 `If-None-Match` | `PutObject` (và `CopyObject`) với `If-None-Match: *` thất bại khi key đã có; chỉ xét bản hiện tại trong bucket có versioning; chỉ cần `s3:PutObject` | [N21] |
| Mã lỗi → lý do | Bảng "Mã lỗi" | [N9] |
| `maxReceiveCount` | 5 | [N24], mục "Hàng đợi" |
| Endpoint interface | `com.amazonaws.<region>.mediaconvert` có trong danh sách PrivateLink; tên regional `mediaconvert.<region>.amazonaws.com`; private DNS đè tên đó (0064 §2) | [N12], [N20] |
| Job đồng thời | Queue on-demand ở `ap-southeast-1`: 100 (mặc định và trần); account: 1 000 mỗi region; `CreateJob` 5/s, `GetJob` 2/s, `Probe` 5/s (burst 100) | [N12], [N13] |
| Dạng ARN, URL của hợp đồng cluster | Queue `arn:${Partition}:mediaconvert:${Region}:${Account}:queues/${QueueName}`; role `arn:aws:iam::<account>:role/<tên>`; queue SQS `https://sqs.<region>.amazonaws.com/<account>/<tên>` (dạng theo ví dụ của tài liệu): khớp ba regex của hợp đồng | [N14], [N32], [N25] |
| Quyền Role MediaConvert | Bảng "Role MediaConvert" | [N14], [N15], [N16] |
| Quyền bridge | Bảng "Quyền bridge" | [N14], [N22], [N23] |
| Control FSBP | Bảng "Control FSBP" | [N36] |
| SCP, RCP | Bảng "Luồng SCP, RCP" | `aws/modules/org-policies/` |

## §3. Kiểm đầu vào

- Kích thước hiển thị: `rotation` 90 hay 270 thì đổi chỗ `width`, `height`. Rotation ở mức container là cái
  `VideoSelector` `Rotate` `AUTO` đọc: xoay tự động chỉ với `.mov`, `.mp4`, góc 90, 180, 270 (lệch tới 1° được làm
  tròn), góc khác thì không xoay [N17]. Probe còn có `codecMetadata.rotation` (SEI Display Orientation của H.264,
  H.265); bridge không dùng trường đó vì xoay tự động không theo nó.
- Nguồn có track `audio` hay không quyết job có audio selector hay không.
- Object không có: S3 trả 403 thay 404 cho người gọi không có `s3:ListBucket` [N23]; Probe có 404 "resource you
  requested does not exist" [N4], nhưng tài liệu không nói Probe trả gì khi object nguồn thiếu và người gọi chỉ có
  `s3:GetObject`. Thử ở account sandbox (Probe trên key không có), trước khi code dựa vào mã đó cho `SOURCE_MISSING`.

## §4. Job MediaConvert

- Tier Basic đủ: HLS với AVC, frame capture, input clipping, xoay tự động nằm trong cả hai tier [N1].
- `UserMetadata`: tối đa 10 khoá; khoá, giá trị chỉ chữ, số, khoảng trắng và `_ . : / = + - @`; khoá không bắt đầu bằng
  `aws:` [N18]. `traceparent` (`00-<32 hex>-<16 hex>-<2 hex>`) và UUID nằm trong tập đó.
- Frame capture chỉ được trong job có output audio, video thường [N7]: job luôn có output group HLS.
- `InputClippings`: `EndTimecode` là timecode `HH:MM:SS:FF` trên timeline của input, frame của nó nằm trong clip; với
  `TimecodeSource` `ZEROBASED` frame đầu là `00:00:00:00` [N8], [N19]. Lỗi 1060 là "The start and end timecodes
  specified for an input clip don't exist in the associated input stream" [N9]: một điểm cắt cố định ở 3 phút nằm ngoài
  timeline của mọi video ngắn hơn 3 phút. Vì vậy `EndTimecode` là frame cuối n = ⌊min(180, d) × fps⌋ − 1, với d là
  `container.tracks[].duration` (giây) của track video và fps là `videoProperties.frameRate` `numerator`/`denominator`
  của Probe [N4]: trừ một vì frame của `EndTimecode` nằm trong clip, frame đếm từ 0. n ghi thành `HH:MM:SS:FF` theo tốc
  độ danh nghĩa (fps làm tròn, không drop-frame); FF chỉ có hai chữ số [N8], nên trên 100 fps FF là min(frame, 99): cắt
  sớm dưới 0,2 s ở cuối, cái giá chấp nhận vì nguồn trên 100 fps hiếm và trần chi phí cần cắt cả video ngắn; nếu dịch vụ đọc nhãn đó là drop-frame thì nó chỉ tới frame sớm hơn,
  vẫn trong input. `TimecodeSource` `ZEROBASED`, `StartTimecode` không đặt. Điểm cuối luôn nằm trên timeline mà Probe
  báo, nên video hợp lệ không gặp 1060.
- Trần chi phí vẫn giữ: output ≤ thời lượng Probe ≤ 180 s (Probe quá giới hạn đã thành `DURATION_EXCEEDED`, §3). File có
  metadata nói dài hơn timeline thật thì điểm cuối nằm ngoài input: job `ERROR` 1060, không tính tiền [N9], lý do
  `INVALID_INPUT` (bảng "Mã lỗi"). File có metadata nói ngắn hơn thật thì output bị cắt tại thời lượng Probe: trần chi
  phí của FF-9.
- Job mẫu ở account sandbox xác nhận Probe cho thời lượng track video và job với điểm cuối đó ra đủ thời lượng (frame
  cuối có mặt).
- Queue on-demand `svp-<env>`, `ConcurrentJobs` mặc định 100 [N12], [N13]: gấp nhiều lần số job một buổi tạo cùng lúc
  (32 video của seed).

## §5. Bố cục output

Thư mục của một lần thử `media/<video_id>/<version>/<attempt>/`:

| Object | Ai tạo | Tên |
| --- | --- | --- |
| Playlist rendition | MediaConvert, output group HLS, destination `.../<attempt>/index`, `NameModifier` `_<rendition>` | `index_<rendition>.m3u8` [N5], [N6] |
| Segment | MediaConvert, cùng thư mục (`SINGLE_DIRECTORY`) | Do MediaConvert đặt; playlist trỏ tương đối |
| Manifest của group | MediaConvert | `index.m3u8`: không master nào trỏ tới |
| Frame capture | MediaConvert, output group File, destination `.../<attempt>/thumb`, `MaxCaptures` 1 | `thumb.<7 chữ số>.jpg` [N7] |
| `thumbnail.jpg` | Bridge, `CopyObject` từ frame capture | `thumbnail.jpg` |
| Master của version | Bridge, `If-None-Match` | `media/<video_id>/<version>/master.m3u8` |

- `GetJob` `OutputDetail` chỉ có `durationInMs` và `videoDetails`, không có đường file [N8]; mẫu event của tài liệu liệt
  kê `mainv2` trước `mainv1` [N6], nên thứ tự output trong `outputDetails` không được coi là thứ tự trong settings. Kích
  thước thật ghép với bậc của thang theo cạnh ngắn (mỗi bậc một cạnh ngắn riêng).
- Volume local có master kiểu cũ (`<attempt>/<rendition>/index.m3u8`): dựng lại stack local (`make down`, xoá volume,
  `make up`); không giữ đường đọc cũ.

## §6. Bản ghi job và quyết định kết quả

Hợp đồng: mỗi version phát kết quả ít nhất một lần; mọi event bridge phát cho một version mang cùng một kết quả. Bản ghi
job `transcode-jobs/<video_id>/<version>.json` chỉ được tạo bằng `If-None-Match: *` [N21] và không bao giờ ghi lại, nên
kết quả của version là kết quả của job đầu tiên được ghi, mọi job khác là job lạc. Từng nhánh:

- **Mất response của `CreateJob`.** Job J1 đã tạo nhưng bridge không biết; kafkax thử lại, bản ghi chưa có, bridge tạo
  J2 và ghi bản ghi J2. Nếu message SQS của J1 tới trước khi J2 được ghi, nhánh SQS ghi bản ghi J1 trước; lần ghi J2 gặp
  `ErrExists`, J2 thành job lạc và `settle` bản ghi J1. Ai ghi trước thì thắng, và mọi đường sau đọc cùng bản ghi.
- **Người gọi cũ tỉnh lại sau rebalance.** A kiểm bản ghi rồi treo; B tạo J_B, ghi bản ghi, J_B lỗi, bridge phát
  `transcode.failed`, video-service xoá nguồn và output. A tỉnh, tạo J_A (thường `ERROR` vì nguồn đã xoá), ghi bản ghi
  gặp `ErrExists`, `settle` bản ghi J_B: phát lại cùng `transcode.failed`. Message SQS của J_A thấy bản ghi J_B, không
  đổi gì. Job `ERROR` không tính tiền [N9].
- **Request xong sau lần đọc cuối.** `CreateJob` hết thời gian ở lần thử cuối của kafkax, nhưng phía AWS vẫn tạo job:
  bridge ghi bản ghi `RETRIES_EXHAUSTED` và phát `transcode.failed`. Job lạc chạy xong sau đó; message của nó thấy bản
  ghi `reason`, phát lại cùng kết quả. Output của job lạc nằm dưới `media/<video_id>/` sau khi video-service đã dọn:
  object mồ côi, như 0029 đã nhận.
- **`ERROR` của job lạc.** Message của job lạc chỉ ghi bản ghi khi version chưa có bản ghi nào; khi đã có, nó `settle`
  bản ghi đã có. `ERROR` của job lạc vì thế không thắng được job đã ghi. Nếu job lạc là job ghi đầu tiên, nó chính là
  kết quả: version `FAILED` dù một job khác có thể xong sau; bridge không nộp lại job (cái giá của "một version, một kết
  quả").
- **Ghi bản ghi lỗi ở lần thử cuối.** Không phát gì: record vào dead-letter topic của kafkax, video ở `PROCESSING`;
  không phát `FAILED` khi kết quả còn bất định.
- **Lặp lại là bình thường.** Message SQS lặp, crash sau publish trước `DeleteMessage` hay commit offset, phát lại
  `video.uploaded`: `settle` đọc cùng bản ghi và cùng master, nên event phát lại giống hệt (trừ `meta`); video-service
  đã nhận event trùng.
- **Cleanup không xoá bản ghi.** Bản ghi ngoài `media/`: `DeletePrefix media/<video_id>/` của video-service không chạm
  nó, và bucket policy chỉ mở `media/*` cho CloudFront. Lifecycle xoá `transcode-jobs/` sau 30 ngày, lâu hơn mọi job,
  hạn giữ message của SQS và của Kafka.

## §7. Event trạng thái job, hàng đợi, ánh xạ kết quả

- Event "MediaConvert Job State Change" của `aws.mediaconvert` mang `detail.status`, `detail.queue` (ARN queue),
  `detail.jobId`, `detail.userMetadata`, `detail.errorCode` [N10], [N11]; rule khớp `source`, `detail-type`,
  `detail.status` `COMPLETE`/`ERROR`, `detail.queue`.
- EventBridge thử lại đích mặc định 24 giờ, tối đa 185 lần, rồi bỏ event nếu đích không có DLQ [N28]; DLQ của đích là
  queue SQS cùng region, policy cho `events.amazonaws.com` `sqs:SendMessage` với `aws:SourceArn` là rule [N29], [N30].
- Hàng đợi: SSE-SQS (không tính thêm; SSE-KMS mới tính phí KMS [N27]); long polling tối đa 20 s [N26]; `maxReceiveCount`
  5: tài liệu khuyên đủ cao để chịu lỗi tạm [N24], và 5 lần nhận đủ cho throttle của `GetJob` (2/s) và lỗi S3 tạm;
  message không bảo đảm được (§7 của ADR) tới DLQ sau 5 lần nhận.
- Event bị mất (đích hỏng quá 24 giờ, hay message tới DLQ): video ở `PROCESSING`. Alarm DLQ báo; runbook chuyển message
  từ DLQ về hàng đợi nguồn sau khi sửa nguyên nhân. Đây là giới hạn của thiết kế, không có job tự gỡ.

### Mã lỗi

Theo bảng mã của MediaConvert [N9]. "Do đầu vào" là lỗi mà tài liệu mô tả bằng nội dung file (không đọc được, thiếu
track, codec, cấu trúc, cắt cụt); Probe đã qua nên file đã nói dối metadata hay hỏng giữa chừng.

| Mã | Tên trong tài liệu | Lý do |
| --- | --- | --- |
| 1010 | File access error (không mở được, sai định dạng) | `INVALID_INPUT` |
| 1020 | Missing video error | `INVALID_INPUT` |
| 1021 | Missing audio error (job chỉ có audio khi Probe thấy audio) | `INVALID_INPUT` |
| 1030 | Unsupported codec error | `INVALID_INPUT` |
| 1056 | File open error | `INVALID_INPUT` |
| 1060 | Timecode clipping error | `INVALID_INPUT` |
| 1075 | Demux structure error | `INVALID_INPUT` |
| 1076 | File truncation error | `INVALID_INPUT` |
| 1092 | Audio decode error | `INVALID_INPUT` |
| 1040, 1080, 1091, 1093 | Lỗi cấu hình job | `RETRIES_EXHAUSTED` |
| 1401, 1404, 1432, 1433, 1434, 1515, 1517 | Quyền S3, IAM, ghi output, file không thấy | `RETRIES_EXHAUSTED` |
| 1522, 1550, 1999 | Timeout, lỗi hệ thống | `RETRIES_EXHAUSTED` |
| Mọi mã khác (1041–1043, 16xx, 1700, 3xxx: tính năng và input HTTP không dùng) | — | `RETRIES_EXHAUSTED` |

## §9. Quyền

### Role MediaConvert

Trust: `mediaconvert.amazonaws.com`, `sts:AssumeRole`, `StringEquals` `aws:SourceAccount` = `<account>`, `ArnLike`
`aws:SourceArn` = ARN queue `svp-<env>`; tài liệu ghi `aws:SourceArn` của MediaConvert là ARN queue [N15].

| Action | Resource | Điều kiện | Vì sao | Nguồn |
| --- | --- | --- | --- | --- |
| `s3:GetObject` | `arn:aws:s3:::<uploads>/uploads/*` | — | Đọc input của job | [N23], role cho "access to your input files" [N39] |
| `s3:PutObject` | `arn:aws:s3:::<media>/media/*` | — | Ghi output (mọi output dưới thư mục attempt, code kiểm tiền tố) | [N40], [N39] |

Không quyền KMS: hai bucket SSE-S3. Bucket chuyển SSE-KMS thì thêm `kms:Decrypt` (input) và `kms:GenerateDataKey`
(output), điều kiện `kms:ViaService` `s3.<region>.amazonaws.com` [N16]. Tài liệu không liệt kê quyền tối thiểu khác
(role tạo từ console dùng quyền S3 rộng); job mẫu ở account sandbox xác nhận hai quyền trên đủ.

### Quyền bridge

Role Pod Identity `svp/media-worker` = policy S3 của module `media` + policy của module `transcode`. `<queue>` là
`svp-<env>`.

| Action | Resource | Điều kiện | Vì sao | Nguồn |
| --- | --- | --- | --- | --- |
| `mediaconvert:CreateJob` | `arn:aws:mediaconvert:<region>:<account>:queues/<queue>` | — | Tạo job; resource type `Queue` (không dùng `JobTemplate`, `Preset`) | [N14] |
| `mediaconvert:GetJob` | `arn:aws:mediaconvert:<region>:<account>:jobs/*` | — | Job ID chỉ biết sau khi tạo; resource type `Job*` | [N14] |
| `mediaconvert:Probe` | `*` | — | Action không có resource type | [N14] |
| `iam:PassRole` | ARN **Role MediaConvert** | `iam:PassedToService` = `mediaconvert.amazonaws.com` | Action phụ thuộc của `CreateJob` | [N14] |
| `sqs:ReceiveMessage`, `sqs:DeleteMessage`, `sqs:ChangeMessageVisibility` | `arn:aws:sqs:<region>:<account>:svp-<env>-transcode-events` | — | Đọc event | SQS API |
| `s3:GetObject`, `s3:PutObject` | `arn:aws:s3:::<media>/media/*`, `arn:aws:s3:::<media>/transcode-jobs/*` | — | Đọc playlist, `CopyObject` tại chỗ (cần đọc nguồn, ghi đích [N22]), master, bản ghi job | [N21], [N22] |
| `s3:ListBucket` | `arn:aws:s3:::<media>` | `StringLike` `s3:prefix` `media/*`, `transcode-jobs/*` | Liệt kê thư mục attempt; hỏi bản ghi có chưa bằng `ListObjectsV2` (`Prefix` là key, như 0029 E2): không có `ListBucket`, GET key thiếu trả 403 thay 404 [N23] | [N23] |
| `s3:GetObject` | `arn:aws:s3:::<uploads>/uploads/*` | — | Probe đọc S3 bằng quyền người gọi (§3) | [N4] |

Không quyền nào khác: không `mediaconvert:ListJobs`, `CancelJob`, không `s3:DeleteObject`.

## §10. Mạng

- Endpoint `com.amazonaws.<region>.mediaconvert` có trong danh sách PrivateLink [N20]; tài liệu không công bố AZ nào có
  nó. Data source `aws_vpc_endpoint_service` và precondition của module `network` dừng plan khi region không có dịch vụ
  hay thiếu một AZ của `interface_endpoint_az_count`, trước khi tạo gì (0064 §1).
- Kiểm tay trước buổi đầu (người học chạy, chỉ đọc); trong output tìm đủ AZ của VPC và
  `mediaconvert.ap-southeast-1.amazonaws.com`:

  ```bash
  AWS_PROFILE=anhnv-stg-ro aws ec2 describe-vpc-endpoint-services --region ap-southeast-1 \
    --service-names com.amazonaws.ap-southeast-1.mediaconvert \
    --query 'ServiceDetails[].[AvailabilityZones,PrivateDnsName,VpcEndpointPolicySupported]'
  ```

## Chi phí

### Bảng giá

| Mục | Giá (USD) | Nguồn |
| --- | --- | --- |
| MediaConvert Basic, AVC, ≤ 30 fps | 0,0085 mỗi phút chuẩn hoá; SD 1×, HD 2×; tối thiểu 10 s mỗi output; job `ERROR` không tính | [N1], [N2], [N9] |
| Probe | $0 cho 1 000 000 lần gọi đầu mỗi tháng (`SIN-Probe`) | [N2] |
| SQS standard | 0,40 mỗi triệu request | [N33] |
| EventBridge, event của dịch vụ AWS trên default bus, giao tới dịch vụ cùng account | Ingest "AWS management events: Free"; "To a service in the same account: Free" | [N31] |
| S3 `PUT`, `COPY`, `LIST` | 0,005 mỗi 1 000 request | [N34] |
| Endpoint interface | 0,013 mỗi giờ mỗi AZ | Phụ lục [0064](0064-interface-endpoints.md) §7 |
| CloudWatch alarm (độ phân giải chuẩn) | 0,10 mỗi alarm mỗi tháng | [N35] |
| Item AWS Config | 0,003 mỗi item | Phụ lục [0061](0061-edge-cloudfront-waf-acm.md) §13 |

Frame capture: trang giá không có dòng riêng; bảng dưới tính nó như một output HD (2×) suốt thời lượng video, cận trên.

### Mỗi buổi

Phút chuẩn hoá = Σ output (thời lượng tính tiền, phút × hệ số). Thang theo `ladderFor` của `serve`; `eks-smoke` một
video 10 s 1280×720 (`deploy/compose/smoke.sh`), `eks-seed` 32 video 2 s 320×240 (`deploy/k8s/eks-seed.sh`), **Clip tham
chiếu** 60 s 1080×1920.

| Khoản | Output mỗi video | Phút chuẩn hoá | stg | prd |
| --- | --- | --- | --- | --- |
| `make eks-smoke` | 360p SD, 720p HD, frame capture HD; mỗi cái 10 s | 0,83 | 0,007 | 0,007 |
| `make eks-seed` | `source` SD, frame capture SD; mỗi cái tính tối thiểu 10 s | 32 × 0,33 = 10,7 | 0,091 | 0,091 |
| Phép đo hai đường (a), 5 video | 360p SD, 720p HD, 1080p HD (dọc 1080 ngang), frame capture HD | 5 × 7 = 35 | 0,298 | 0,298 |
| Phép kiểm FF-9, clip 200 s | Probe từ chối, không job (Probe $0); cận trên khi Probe sai: cắt 180 s, cùng thang | 0 (cận trên 21) | 0,179 | 0,179 |
| Một job lạc `COMPLETE` dự phòng | Như **Clip tham chiếu** | 7 | 0,060 | 0,060 |
| Endpoint `mediaconvert`, 4 giờ (stg 1 AZ, prd 3 AZ) | — | — | 0,052 | 0,156 |
| SQS: ≤ 3 pod × 4 giờ × 180 long poll + message | ~2 500 request | — | 0,001 | 0,001 |
| S3 `CopyObject`, `LIST`, master, bản ghi | ~600 request | — | 0,003 | 0,003 |
| Bản cũ của object chép tại chỗ (versioning media chỉ ở prd, 0055 §3) | ~0,4 GB | — | 0 | 0,010 |
| Alarm, 4 giờ | 1 alarm | — | 0,001 | 0,001 |
| Item Config: queue, role, rule, 2 SQS, alarm, endpoint, policy | ~8 | — | 0,024 | 0,024 |
| **Cộng** | | | **~0,72** | **~0,84** |

Trần mỗi buổi $3 cho phần này ở mỗi env: đạt. Lúc không buổi: $0 (mọi tài nguyên ở root `aws/envs/<env>`, gỡ cùng buổi;
không lưu trữ). Phút chuẩn hoá cộng dồn theo org mỗi tháng [N1]: các buổi lab không ra khỏi bậc 100 000 phút đầu.

## Control FSBP

Control Security Hub CSPM áp lên tài nguyên mới; "FSBP" là có trong AWS Foundational Security Best Practices [N36]. Danh
sách control không có mục nào cho MediaConvert.

| Control | Tiêu đề (tóm tắt) | FSBP | Kết quả | Lý do |
| --- | --- | --- | --- | --- |
| SQS.1 | Queue SQS mã hoá at rest | có | Đạt | SSE-SQS ở cả hai queue |
| SQS.3 | Policy queue SQS không cho truy cập công khai | có | Đạt | Principal `events.amazonaws.com` với `aws:SourceArn` của rule |
| SQS.2 | Queue SQS có tag | không | Đạt | `default_tags` của root |
| EventBridge.3 | Custom event bus có resource policy | có | Không áp | Rule ở default bus |
| IAM.1 | Policy không cho `"*"` quản trị | có | Đạt | Action liệt kê từng cái |
| IAM.21 | Policy tự tạo không wildcard action theo dịch vụ | có | Đạt | Không `mediaconvert:*`, `sqs:*`, `s3:*` |
| CloudWatch.15 | Alarm có action | không | Đạt | Alarm DLQ gửi topic của module `alarms` |

## Luồng SCP, RCP

Đối chiếu SCP và RCP `svp-data-perimeter` của [0059](../0059-org-structure-guardrails.md)
(`aws/modules/org-policies/main.tf`). RCP phủ S3, SQS, KMS, Secrets Manager, STS. Mọi tài nguyên ở `ap-southeast-1`,
trong region SCP `deny-other-regions` cho phép; `iam:*` là action toàn cục của SCP đó.

| Luồng | Principal | Tài nguyên | Qua nhờ |
| --- | --- | --- | --- |
| Terraform tạo, gỡ queue, role, rule, SQS, alarm, endpoint | `SvpAdmin` của env | MediaConvert, IAM, EventBridge, SQS, CloudWatch, EC2 | `protect-baseline` chỉ chặn rule `svp-security-*` và role `svp-security-*`, `OrganizationAccountAccessRole`; tên mới không khớp |
| Bridge gọi `CreateJob`, `GetJob`, `Probe` | Role Pod Identity | MediaConvert | Ngoài phạm vi RCP |
| Bridge `iam:PassRole` | Role Pod Identity | Role MediaConvert | Ngoài phạm vi RCP |
| MediaConvert nhận role | `mediaconvert.amazonaws.com` | STS (role) | `EnforceConfusedDeputyProtection`: `aws:SourceOrgID` [N41] của account trong org khớp (`IfExists`) |
| MediaConvert đọc `uploads`, ghi `media` | Role MediaConvert | S3 của env | `EnforceOrgIdentities`: principal trong org; bucket policy chỉ chặn không TLS |
| Probe đọc `uploads` | Role Pod Identity qua MediaConvert | S3 của env | Principal trong org |
| EventBridge gửi vào SQS, DLQ | `events.amazonaws.com` | SQS của env | `aws:SourceOrgID` khớp (`IfExists`); policy queue theo `aws:SourceArn` |
| Bridge đọc, xoá message | Role Pod Identity | SQS của env | Principal trong org, TLS qua endpoint `sqs` |
| Bridge đọc, chép, tạo object | Role Pod Identity | S3 của env | Principal trong org; gateway endpoint S3 cho bucket của env |

Không luồng nào cần ngoại lệ SCP hay RCP. TLS của lời gọi S3 từ phía MediaConvert không ghi trong tài liệu: job mẫu ở
sandbox, nơi RCP `EnforceSecureTransport` cũng áp, xác nhận.

## Phép đo hai đường: phương pháp

Cùng **Clip tham chiếu** (60 s, 1080×1920, 30 fps, H.264 + AAC), 5 lần upload mỗi đường; (a) MediaConvert ở stg trong
buổi, (b) ffmpeg trên stack compose của máy (`make up OBS=lgtm`, một lần, ngoài buổi).

Sinh clip (một lần, ở thư mục tạm):

```bash
ffmpeg -f lavfi -i testsrc2=size=1080x1920:rate=30 -f lavfi -i sine=frequency=440 -t 60 \
  -c:v libx264 -pix_fmt yuv420p -c:a aac clip-60s.mp4
```

### Thời gian tới `READY`

Script `deploy/compose/transcode-timing.sh` qua target của nó, biến `CLIP` (đường file clip) và `N` (số lần); in mỗi lần
`<video_id> <giây>`, dòng cuối `p50=<giây> max=<giây>`:

```bash
make transcode-timing CLIP=/tmp/clip-60s.mp4 N=5                         # (b), stack compose
make eks-transcode-timing CONTEXT=svp-stg CLIP=/tmp/clip-60s.mp4 N=5     # (a), stg session, through the API tunnel
```

### Chi phí mỗi phút video

(a) Job ID của từng video ở **Bản ghi job**, rồi phút output theo loại từ `GetJob`, bằng profile `anhnv-stg` của buổi
(`SvpAdmin`): `anhnv-stg-ro` (`SvpReadOnly`: `ViewOnlyAccess` [N42], `SecurityAudit` [N43], quyền đọc log) không có
`s3:GetObject`, `mediaconvert:GetJob`:

```bash
media=svp-stg-media-${SVP_AWS_STG_ACCOUNT_ID}-ap-southeast-1
AWS_PROFILE=anhnv-stg aws s3api list-objects-v2 --region ap-southeast-1 \
  --bucket "$media" --prefix "transcode-jobs/<video_id>/" --query 'Contents[].Key'
AWS_PROFILE=anhnv-stg aws s3 cp "s3://$media/transcode-jobs/<video_id>/<version>.json" - --region ap-southeast-1
AWS_PROFILE=anhnv-stg aws mediaconvert get-job --id <job_id> --region ap-southeast-1 \
  --query 'Job.OutputGroupDetails[].OutputDetails[].[DurationInMs,VideoDetails.WidthInPx,VideoDetails.HeightInPx]'
```

Chi phí (a) = Σ (max(`DurationInMs`, 10 000) / 60 000 × hệ số theo cạnh đo của output × $0,0085) / (5 × 1 phút). Đối
chiếu tổng: Cost Explorer của ngày buổi (management) so với tổng tính theo output của mọi job trong buổi (smoke, seed,
FF-9 gồm), không tách 5 job:

```bash
AWS_PROFILE=anhnv-sso aws ce get-cost-and-usage --region us-east-1 --time-period Start=<YYYY-MM-DD>,End=<YYYY-MM-DD+1> \
  --granularity DAILY --metrics UnblendedCost \
  --filter "{\"And\":[{\"Dimensions\":{\"Key\":\"SERVICE\",\"Values\":[\"AWS Elemental MediaConvert\"]}},
    {\"Dimensions\":{\"Key\":\"LINKED_ACCOUNT\",\"Values\":[\"$SVP_AWS_STG_ACCOUNT_ID\"]}}]}"
```

(b) CPU-giây thật của container `media-worker` từ Docker Engine API, đọc trước và sau 5 lần upload, worker không làm
việc khác:

```bash
id=$(env -u DOCKER_DEFAULT_PLATFORM docker ps -q --filter label=com.docker.compose.project=svp \
  --filter label=com.docker.compose.service=media-worker)
sock=$(env -u DOCKER_DEFAULT_PLATFORM docker context inspect --format '{{.Endpoints.docker.Host}}')
sock=${sock#unix://}
cpu() {
  curl -s --unix-socket "$sock" "http://localhost/containers/$id/stats?stream=false" |
    jq '.cpu_stats.cpu_usage.total_usage'
}
before=$(cpu); make transcode-timing CLIP=/tmp/clip-60s.mp4 N=5; after=$(cpu)
echo "cpu_seconds=$(( (after - before) / 1000000000 ))"
```

Chi phí (b) = CPU-giây / (5 × 1 phút) × (giá On-Demand mỗi giờ của loại node eks ở `ap-southeast-1` / số vCPU / 3600).
Giá node đọc từ trang giá EC2 (ngày đọc ghi cạnh số). CPU của máy khác node eks: ghi độ lệch. `svp.transcode.duration`
của (b) là thời gian thực, chỉ ghi kèm.

### Kết quả

| Đường | 5 lần (giây) | p50 | max | Chi phí mỗi phút video | Ghi chú |
| --- | --- | --- | --- | --- | --- |
| (a) MediaConvert, stg | | | | | |
| (b) ffmpeg, compose | | | | | |

### Công vận hành

| Việc | ffmpeg trên EKS | MediaConvert |
| --- | --- | --- |
| Cập nhật bộ giải mã, vá CVE | ffmpeg trong image, quét và build lại | AWS; image eks vẫn mang ffmpeg không dùng |
| Giới hạn tài nguyên, bom tài nguyên (FF-3) | `limits`, `-t`, timeout, KEDA, CPU node cho đỉnh | Probe và điểm cắt; dịch vụ tự cấp |
| Cô lập file người dùng (FF-1, FF-2, FF-4) | Container không quyền, whitelist | File không vào cluster |
| Thứ phải giữ thêm | — | Queue, role, rule, hai SQS, alarm, endpoint, runbook DLQ, bản ghi job |
| Quan sát | Metric, log của worker | Metric của bridge từ `Timing`; event lỗi qua SQS |

## Nguồn

- [N1] AWS Elemental MediaConvert pricing (tier, phút chuẩn hoá, độ phân giải, tối thiểu 10 s):
  <https://aws.amazon.com/mediaconvert/pricing/>
- [N2] AWS Price List API, `AWSElementalMediaConvert` `ap-southeast-1` (phát hành 2026-09-11):
  <https://pricing.us-east-1.amazonaws.com/offers/v1.0/aws/AWSElementalMediaConvert/current/ap-southeast-1/index.json>
- [N3] MediaConvert API Reference, Preventing duplicate jobs:
  <https://docs.aws.amazon.com/mediaconvert/latest/apireference/idempotency.html>
- [N4] MediaConvert API Reference, Probe: <https://docs.aws.amazon.com/mediaconvert/latest/apireference/probe.html>
- [N5] MediaConvert, Output file names and paths:
  <https://docs.aws.amazon.com/mediaconvert/latest/ug/output-file-names-and-paths.html>
- [N6] MediaConvert, Apple HLS group: <https://docs.aws.amazon.com/mediaconvert/latest/ug/apple-hls-group.html>
- [N7] MediaConvert, File group with a frame capture output:
  <https://docs.aws.amazon.com/mediaconvert/latest/ug/file-group-with-frame-capture-output.html>
- [N8] MediaConvert API Reference, Jobs id (`GetJob`, schema `Job`, `S3DestinationSettings`, `InputClipping`):
  <https://docs.aws.amazon.com/mediaconvert/latest/apireference/jobs-id.html>
- [N9] MediaConvert, Error codes: <https://docs.aws.amazon.com/mediaconvert/latest/ug/mediaconvert_error_codes.html>
- [N10] MediaConvert, Events with COMPLETE status:
  <https://docs.aws.amazon.com/mediaconvert/latest/ug/ev_status_complete.html>
- [N11] MediaConvert, Events with ERROR status:
  <https://docs.aws.amazon.com/mediaconvert/latest/ug/ev_status_error.html>
- [N12] AWS General Reference, MediaConvert endpoints and quotas:
  <https://docs.aws.amazon.com/general/latest/gr/mediaconvert.html>
- [N13] MediaConvert, Working with on-demand queues:
  <https://docs.aws.amazon.com/mediaconvert/latest/ug/working-with-on-demand-queues.html>
- [N14] Service Authorization Reference, AWS Elemental MediaConvert:
  <https://docs.aws.amazon.com/service-authorization/latest/reference/list_mediaconvert.html>
- [N15] MediaConvert, Cross-service confused deputy prevention:
  <https://docs.aws.amazon.com/mediaconvert/latest/ug/cross-service-confused-deputy-prevention.html>
- [N16] MediaConvert, Granting permissions to access encrypted Amazon S3 buckets:
  <https://docs.aws.amazon.com/mediaconvert/latest/ug/granting-permissions-for-mediaconvert-to-access-encrypted-s3-buckets.html>
- [N17] MediaConvert, automatic rotation: <https://docs.aws.amazon.com/mediaconvert/latest/ug/automatic-rotation.html>;
  requirements: <https://docs.aws.amazon.com/mediaconvert/latest/ug/auto-rotate-requirements.html>
- [N18] MediaConvert, Using metadata tags: <https://docs.aws.amazon.com/mediaconvert/latest/ug/user-metadata-tags.html>
- [N19] MediaConvert, Specifying input files and input clips:
  <https://docs.aws.amazon.com/mediaconvert/latest/ug/assembling-multiple-inputs-and-input-clips.html>
- [N20] AWS PrivateLink, AWS services that integrate with AWS PrivateLink:
  <https://docs.aws.amazon.com/vpc/latest/privatelink/aws-services-privatelink-support.html>
- [N21] Amazon S3, conditional writes: <https://docs.aws.amazon.com/AmazonS3/latest/userguide/conditional-writes.html>
- [N22] Amazon S3 API, CopyObject (`x-amz-metadata-directive`, quyền):
  <https://docs.aws.amazon.com/AmazonS3/latest/API/API_CopyObject.html>
- [N23] Amazon S3 API, GetObject (403 thay 404 khi thiếu `s3:ListBucket`):
  <https://docs.aws.amazon.com/AmazonS3/latest/API/API_GetObject.html>
- [N24] Amazon SQS, dead-letter queues:
  <https://docs.aws.amazon.com/AWSSimpleQueueService/latest/SQSDeveloperGuide/sqs-dead-letter-queues.html>
- [N25] Amazon SQS, queue and message identifiers (queue URL):
  <https://docs.aws.amazon.com/AWSSimpleQueueService/latest/SQSDeveloperGuide/sqs-queue-message-identifiers.html>
- [N26] Amazon SQS, short and long polling:
  <https://docs.aws.amazon.com/AWSSimpleQueueService/latest/SQSDeveloperGuide/sqs-short-and-long-polling.html>
- [N27] Amazon SQS, encryption at rest:
  <https://docs.aws.amazon.com/AWSSimpleQueueService/latest/SQSDeveloperGuide/sqs-server-side-encryption.html>
- [N28] Amazon EventBridge, retry policy:
  <https://docs.aws.amazon.com/eventbridge/latest/userguide/eb-rule-retry-policy.html>
- [N29] Amazon EventBridge, dead-letter queues:
  <https://docs.aws.amazon.com/eventbridge/latest/userguide/eb-rule-dlq.html>
- [N30] Amazon EventBridge, resource-based policies (SQS):
  <https://docs.aws.amazon.com/eventbridge/latest/userguide/eb-use-resource-based.html>
- [N31] Amazon EventBridge pricing: <https://aws.amazon.com/eventbridge/pricing/>
- [N32] IAM identifiers (ARN của role): <https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_identifiers.html>
- [N33] AWS Price List API, `AWSQueueService` `ap-southeast-1` (phát hành 2026-11-11):
  <https://pricing.us-east-1.amazonaws.com/offers/v1.0/aws/AWSQueueService/current/ap-southeast-1/index.json>
- [N34] AWS Price List API, `AmazonS3` `ap-southeast-1` (phát hành 2026-11-09):
  <https://pricing.us-east-1.amazonaws.com/offers/v1.0/aws/AmazonS3/current/ap-southeast-1/index.json>
- [N35] AWS Price List API, `AmazonCloudWatch` `ap-southeast-1` (phát hành 2026-11-04):
  <https://pricing.us-east-1.amazonaws.com/offers/v1.0/aws/AmazonCloudWatch/current/ap-southeast-1/index.json>
- [N36] Security Hub CSPM, FSBP: <https://docs.aws.amazon.com/securityhub/latest/userguide/fsbp-standard.html>; control
  SQS: <https://docs.aws.amazon.com/securityhub/latest/userguide/sqs-controls.html>; EventBridge:
  <https://docs.aws.amazon.com/securityhub/latest/userguide/eventbridge-controls.html>; IAM:
  <https://docs.aws.amazon.com/securityhub/latest/userguide/iam-controls.html>; CloudWatch:
  <https://docs.aws.amazon.com/securityhub/latest/userguide/cloudwatch-controls.html>
- [N37] Google Cloud Transcoder API: <https://cloud.google.com/transcoder/docs/concepts/overview>
- [N38] KEDA, Apache Kafka scaler: <https://keda.sh/docs/2.18/scalers/apache-kafka/>
- [N39] MediaConvert, Setting up IAM permissions: <https://docs.aws.amazon.com/mediaconvert/latest/ug/iam-role.html>
- [N40] Amazon S3 API, PutObject: <https://docs.aws.amazon.com/AmazonS3/latest/API/API_PutObject.html>
- [N41] IAM, global condition context keys (`aws:SourceOrgID`):
  <https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_policies_condition-keys.html>
- [N42] AWS managed policy `ViewOnlyAccess`:
  <https://docs.aws.amazon.com/aws-managed-policy/latest/reference/ViewOnlyAccess.html>
- [N43] AWS managed policy `SecurityAudit`:
  <https://docs.aws.amazon.com/aws-managed-policy/latest/reference/SecurityAudit.html>
