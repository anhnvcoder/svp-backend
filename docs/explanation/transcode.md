# Transcode: ffmpeg ở local, MediaConvert ở stg, prd

Trang này giải thích video đi từ file gốc tới HLS bằng hai đường và vì sao kết quả của hai đường như nhau. Quyết định và
lý do ở [ADR-0066](../adr/0066-mediaconvert-transcode.md) (giá trị có nguồn, bảng quyền, mã lỗi ở
[phụ lục](../adr/appendix/0066-mediaconvert-transcode.md)); version, lần thử và master tạo một lần ở
[ADR-0029](../adr/0029-immutable-media-versions.md). Code ở `services/media-worker/`: lệnh con `serve` (package
`worker`, `transcode`) và lệnh con `mediaconvert` (package `mediaconvert`).

## Hai đường, một hợp đồng

Binary `media-worker` có hai lệnh con. Cả hai nghe `video.uploaded` ở topic `video.lifecycle.v1` (group `media-worker`),
phát `transcode.completed` hay `transcode.failed` vào `media.transcodes.v1`, ghi cùng bố cục object, nên video-service,
feed-service và web không biết đường nào đã chạy.

| | `serve` | `mediaconvert` |
| --- | --- | --- |
| Chạy ở | compose, k3d | EKS của stg, prd |
| Ai mở file người dùng | ffprobe, ffmpeg trong container worker | AWS Elemental MediaConvert; file không vào cluster |
| Kiểm đầu vào | ffprobe với danh sách định dạng cho phép và giới hạn của package `transcode` | `Probe` của MediaConvert, cùng giới hạn đó (FF-9 nhánh (a)) |
| Trạng thái job | Tiến trình con trong cùng lượt xử lý | Rule EventBridge `svp-<env>-mediaconvert-job-state` gửi vào SQS `svp-<env>-transcode-events` |
| `Cache-Control` của object | Ghi lúc upload | `CopyObject` tại chỗ sau khi job `COMPLETE` |
| Ai quyết kết quả một version | Master: lượt tạo được master trước thắng | **Bản ghi job** `transcode-jobs/<video_id>/<version>.json` |

Nền tảng chọn lệnh con bằng dữ liệu, không bằng cờ trong code: value `args` của chart `svp-service` mặc định rỗng
(binary chạy `serve`), values eks của release `media-worker` ở `svp-gitops` đặt `[mediaconvert]`. Cùng image, release,
user Kafka `svp-media-worker` và KEDA cho cả hai. Lý do mua dịch vụ ở cloud: file người dùng không mở trong cluster
(FF-1 tới FF-5 chuyển sang nhà cung cấp), node không cần CPU cho đỉnh transcode; cái giá: image trên EKS mang ffmpeg
không dùng, thêm queue, role, rule, hai hàng đợi và runbook (ADR-0066, phần Hệ quả).

## Đường local: `serve`

```mermaid
sequenceDiagram
    participant K as Kafka
    participant W as media-worker serve
    participant S3 as Object store
    participant FF as ffprobe, ffmpeg

    K->>W: video.uploaded (version = event_id)
    W->>S3: master của version có chưa?
    alt master đã có
        W->>S3: đọc master và playlist thấp nhất
    else chưa có
        W->>S3: tải uploads/<video_id>
        W->>FF: kiểm định dạng, giới hạn; transcode HLS và thumbnail
        W->>S3: ghi segment, playlist, thumbnail vào <version>/<attempt>/
        W->>S3: tạo master.m3u8 (If-None-Match)
    end
    W->>K: transcode.completed hay transcode.failed
```

Mỗi lượt thử tải file gốc về thư mục tạm, chạy ffprobe rồi ffmpeg (chỉ protocol `file`, danh sách demuxer và decoder cho
phép, giới hạn tài nguyên: threat model mục 4.3), ghi output vào thư mục lần thử `<attempt>/` mới, rồi tạo master sau
cùng. File không dùng được thành `transcode.failed` ngay; chỉ lỗi storage, Kafka, môi trường mới được thử lại, và lần
thử cuối thành `RETRIES_EXHAUSTED`. Lượt thử gặp master đã có không transcode lại, đọc kết quả đã lưu và phát lại nó.

## Đường cloud: `mediaconvert`

```mermaid
sequenceDiagram
    participant K as Kafka
    participant B as media-worker mediaconvert
    participant S3 as S3 uploads, media
    participant MC as MediaConvert svp-env
    participant EB as EventBridge
    participant Q as SQS svp-env-transcode-events

    K->>B: video.uploaded (version = event_id)
    B->>S3: bản ghi job của version có chưa?
    alt chưa có
        B->>MC: Probe s3://uploads/uploads/<video_id>
        alt vượt giới hạn, không phải video, không có object
            B->>S3: tạo bản ghi reason (If-None-Match)
        else đạt
            B->>MC: CreateJob (attempt mới, UserMetadata)
            B->>S3: tạo bản ghi job (If-None-Match)
        end
    end
    B->>MC: GetJob của job trong bản ghi
    Note over B: SUBMITTED, PROGRESSING: chưa phát gì
    MC->>S3: đọc file gốc, ghi HLS và frame capture vào <version>/<attempt>/
    MC->>EB: MediaConvert Job State Change (COMPLETE hay ERROR)
    EB->>Q: event của queue env
    B->>Q: ReceiveMessage (long polling)
    B->>MC: GetJob của job trong message, kiểm queue, metadata, destination
    B->>S3: đọc bản ghi; chưa có thì tạo bản ghi job này
    alt job trong bản ghi COMPLETE
        B->>S3: CopyObject tại chỗ mọi object, frame capture thành thumbnail.jpg
        B->>S3: tạo master.m3u8 (If-None-Match), đọc lại master và playlist thấp nhất
        B->>K: transcode.completed
    else ERROR hay bản ghi reason
        B->>K: transcode.failed
    end
    B->>Q: DeleteMessage
```

Bridge chạy hai vòng trong một tiến trình: consumer Kafka (`video.uploaded`) và vòng đọc SQS (trạng thái job). Hai vòng
kết thúc ở cùng một bước `settle` trên bản ghi job, nên đường nào tới trước cũng phát cùng một kết quả. Từng bước:

1. **Kiểm đầu vào.** `Probe` đọc file gốc trong bucket `uploads` bằng quyền của chính bridge (Probe không nhận role),
   nên bridge giữ `s3:GetObject` trên `uploads/*` dù không tự mở file. Thời lượng vượt giới hạn của `serve` thành
   `DURATION_EXCEEDED`; không thời lượng, không track video, kích thước hay fps vượt thành `INVALID_INPUT`; object không
   có thành `SOURCE_MISSING`. Các lý do đó được ghi thành bản ghi `reason`, không job nào được tạo. Giới hạn là hằng số
   của package `transcode`, dùng chung với `serve`.
2. **Job.** Settings dựng trong Go: thang rendition của `serve` trên kích thước hiển thị (sau xoay theo `rotation` của
   Probe), H.264 + AAC, không audio khi nguồn không có, một frame capture JPEG. `InputClippings` cắt tại frame cuối của
   thời lượng Probe báo, không quá giới hạn: trần chi phí khi metadata nói dối. `UserMetadata` mang `video_id`,
   `version`, `attempt` và `traceparent`, nên trace của `video.uploaded` nối tới lần `settle` từ SQS. Job chạy với
   **Role MediaConvert** `svp-<env>-mediaconvert`, chỉ đọc `uploads/*`, ghi `media/*`.
3. **Trạng thái.** Rule `svp-<env>-mediaconvert-job-state` chỉ khớp `COMPLETE` và `ERROR` của queue env, gửi vào hàng
   đợi SQS thay vì gọi thẳng bridge: bridge chết thì event chờ trong hàng đợi. Bridge chỉ hành động trên message mà nó
   bảo đảm được (job thuộc queue env, `UserMetadata` đúng dạng, destination nằm dưới thư mục lần thử); message khác ở
   lại hàng đợi, sau `maxReceiveCount` lần nhận thì redrive đưa vào DLQ `svp-<env>-transcode-events-dlq`. Event
   EventBridge không giao được cũng vào DLQ đó.
4. **Kết quả.** Job `COMPLETE`: header, master, rồi `transcode.completed` (mục dưới). Job `ERROR`: mã lỗi do đầu vào
   thành `INVALID_INPUT`, còn lại `RETRIES_EXHAUSTED` (bảng mã ở phụ lục ADR-0066); bridge không nộp lại job. Message
   chỉ bị xoá sau khi `settle` xong.

Bridge gọi MediaConvert và SQS qua endpoint interface trong VPC (private DNS của module `network`), S3 qua gateway
endpoint, với credential của role Pod Identity `svp/media-worker`. Quyền của role đó là phần S3 của module `media` cộng
policy của module `transcode` (bảng "Quyền bridge" ở phụ lục ADR-0066): `CreateJob` trên queue env, `GetJob`, `Probe`,
`iam:PassRole` chỉ cho MediaConvert, ba action SQS trên hàng đợi; không `ListJobs`, `CancelJob`, không
`s3:DeleteObject`.

## Bản ghi job: một version, một kết quả

`CreateJob` không có cách chống trùng bền: `ClientRequestToken` chỉ trả lại job cũ trong thời gian ngắn sau request đầu.
Vì vậy một version có thể có nhiều job: response của `CreateJob` mất rồi kafkax thử lại, consumer mất partition sau
rebalance vẫn tạo job, request hết hạn ở phía bridge nhưng phía AWS vẫn tạo. Bridge không ngăn job trùng; nó quyết job
nào được tính.

Bản ghi job là object `transcode-jobs/<video_id>/<version>.json` trong bucket `media`, một dòng JSON:
`{"attempt":…,"job_id":…}` khi version có job, `{"reason":…}` khi version hỏng trước khi có job. Bridge chỉ tạo nó bằng
`objstore.Create` (`If-None-Match: *`): lần ghi đầu thắng, không bao giờ ghi lại; lần ghi sau gặp `ErrExists` thì đọc
bản đã có. Kết quả của version là kết quả của job (hay lý do) trong bản ghi. Job không có tên ở đó là job lạc: nó không
đổi được kết quả, kể cả khi `ERROR` của nó tới trước `COMPLETE` của job đã ghi. Đường SQS cũng ghi bản ghi khi version
chưa có, nên job tạo xong mà mất response vẫn có thể là job thắng. Lý lẽ từng nhánh ở phụ lục ADR-0066 §6.

Bản ghi nằm ngoài tiền tố `media/` vì hai lẽ: bucket policy chỉ cho CloudFront đọc `media/*`, nên bản ghi không ra CDN;
video-service xoá `media/<video_id>/` khi video `FAILED`, nên một job lạc tới sau lần dọn đó vẫn thấy bản ghi và không
phát kết quả khác. Lifecycle của module `media` xoá tiền tố `transcode-jobs/` sau hạn mà ADR-0066 §6 ghi, dài hơn mọi
job và hạn giữ message của SQS, Kafka. Hỏi bản ghi có chưa bằng `ListObjectsV2` theo đúng key: không có quyền liệt kê
thì `GET` một key thiếu trả 403, không phải 404.

Hợp đồng là at-least-once: mỗi version phát kết quả ít nhất một lần, mọi event phát cho một version mang cùng một kết
quả (trừ `meta`). Phát lại là bình thường: message SQS lặp, crash sau publish trước `DeleteMessage` hay trước commit
offset, `video.uploaded` giao lại. Mỗi lần `settle` đọc cùng bản ghi và cùng master, và video-service đã chịu được event
trùng. Kết quả còn bất định thì không phát gì: lần thử cuối của `video.uploaded` không ghi được bản ghi
`RETRIES_EXHAUSTED` thì record vào dead-letter topic `video.lifecycle.v1.dlq`, video ở `PROCESSING`, vì phát `FAILED`
khi một job có thể còn chạy sẽ khiến video-service xoá file mà job đó đang dùng.

## Bố cục output

Hai đường ghi cùng một bố cục. Mọi object của một lần thử nằm phẳng trong `media/<video_id>/<version>/<attempt>/`:

- playlist mỗi rendition `index_<rendition>.m3u8` (`<rendition>` là bậc của thang: `360p`, `720p`, `1080p` hay
  `source`), segment cùng thư mục, playlist trỏ tương đối;
- `thumbnail.jpg`;
- ở đường cloud thêm frame capture `thumb.<số>.jpg` và manifest của output group `index.m3u8`, không master nào trỏ tới
  chúng.

Master `media/<video_id>/<version>/master.m3u8` là object duy nhất của version ngoài thư mục lần thử; URI biến thể trong
nó là `<attempt>/index_<rendition>.m3u8`, và `transcode.ParseMaster` chỉ nhận dạng đó. Bố cục phẳng vì MediaConvert đặt
tên playlist bằng tên gốc của destination (`.../<attempt>/index`) cộng `NameModifier` (`_<rendition>`) trong một thư
mục, còn thư mục con mỗi rendition không có trong tài liệu của nó; `serve` đổi theo để chỉ có một dạng. Master kiểu cũ
(`<attempt>/<rendition>/index.m3u8`) trong volume local không đọc lại được: dựng lại stack local.

MediaConvert không đặt được `Cache-Control` trên output S3. Khi `settle` job `COMPLETE`, bridge liệt kê thư mục lần thử
và `CopyObject` tại chỗ từng object (`MetadataDirective` `REPLACE`, `Cache-Control` và `Content-Type` như `serve` ghi),
chép frame capture thành `thumbnail.jpg`, rồi mới tạo master. Player chỉ tới object qua master, nên không object nào
được phát thiếu header; một lần thử bị cắt giữa chừng chép lại cho cùng kết quả. Object lạ trong thư mục lần thử (tên
không có `Content-Type`, thư mục con) làm `settle` lỗi trước khi có master. CloudFront và module `media` không đổi giữa
stg (gói Free, chỉ policy managed) và prd.

## Kết quả của version

`transcode.completed` dựng chỉ từ object đã lưu, cùng một hàm (`worker.ReadStored`) cho mọi lần phát ở cả hai đường: đọc
master, lấy lần thử và các rendition từ `ParseMaster`, thời lượng là tổng `EXTINF` của playlist rendition thấp nhất,
`playlist_key` là master, `thumbnail_key` là `thumbnail.jpg` của lần thử trong master. Bridge không lấy thời lượng hay
kích thước từ event: mọi lần phát lại, từ `video.uploaded` hay từ SQS, đọc cùng các object nên ra cùng một event.

Master ghi kích thước thật của mỗi rendition từ `GetJob` (`outputGroupDetails`), ghép với bậc của thang theo cạnh ngắn,
và tên, bitrate của thang; hàm dựng master là của `serve`.

## Metric

`svp.transcode.duration` giữ tên, đơn vị, bucket và thuộc tính `outcome` của `serve`, nên dashboard và alert không đổi.
Ở đường cloud nó là `Timing.FinishTime − Timing.StartTime` của job trong bản ghi: thời gian MediaConvert xử lý, không
tính chờ queue. `ready` ghi khi `settle` tạo được master (một lần mỗi version); `failed` ghi khi `settle` phát
`transcode.failed` từ message SQS của chính job đó. Bản ghi `reason`, phát lại từ `video.uploaded` và message của job
lạc không ghi.

## Lỗi và cách nhận ra

Log của bridge mang `video_id`, `version` và `job_id` khi đã biết; lỗi đã bỏ đường thư mục làm việc. Đọc trong Loki
(`{service_name="media-worker"} |= "<chuỗi>"`) hay log pod `media-worker`.

| Dòng log hay dấu hiệu | Nghĩa | Đi đâu tiếp |
| --- | --- | --- |
| ERROR `media-worker failed`, `MEDIACONVERT_QUEUE_ARN is malformed`, `… is not in the region S3_REGION names` | Thiếu hay sai dạng biến của lệnh con, hay hàng đợi, queue khác region của `S3_REGION`; pod không khởi động | [`reference/environment.md`](../reference/environment.md#biến-và-hành-vi-khởi-động-của-service) |
| INFO `source refused` (`reason`) | Probe từ chối file; bản ghi `reason`, không job | Hành vi đúng; `detail` trong log nói giới hạn nào |
| INFO `transcode job running` | Job trong bản ghi còn `SUBMITTED`, `PROGRESSING` | Kết quả tới qua SQS |
| INFO `transcode result published` (`outcome`, `reason`, `job_id`) | Kết quả đã phát | — |
| WARN `transcode job interrupted` | Lần thử của `video.uploaded` lỗi tạm (Probe, `CreateJob`, S3, Kafka); kafkax thử lại | Lặp tới lần cuối thì WARN `transcode retries exhausted` |
| ERROR `transcode result undecided` | Lần thử cuối không ghi được bản ghi: record vào `video.lifecycle.v1.dlq`, video ở `PROCESSING` | [`kafka-dlq-records.md`](../runbooks/kafka-dlq-records.md), [`transcode-events-dlq.md`](../runbooks/transcode-events-dlq.md) |
| WARN `transcode event interrupted` | `GetJob`, S3 hay publish lỗi khi `settle` message SQS; message hiện lại sau visibility timeout | Lặp đủ số lần nhận thì message vào DLQ |
| WARN `transcode event ignored` | Message không bảo đảm được: không phải JSON, không phải trạng thái job, job của queue khác, `UserMetadata` hay destination sai, job chưa kết thúc | Message vào DLQ sau đủ số lần nhận |
| WARN `receive transcode events failed`, `delete transcode event failed` | Lỗi gọi SQS; vòng đọc thử lại, message chưa xoá sẽ được `settle` lại cho cùng kết quả | Quyền SQS, endpoint `sqs` |
| Alarm `svp-<env>-transcode-events-dlq` | DLQ có message: video của job đó ở `PROCESSING` | [`transcode-events-dlq.md`](../runbooks/transcode-events-dlq.md) |

Giới hạn đã nhận: event mất (EventBridge hết lượt thử, message vào DLQ) để video ở `PROCESSING` tới khi người vận hành
chuyển message về; không có job tự gỡ. Job lạc `COMPLETE` vẫn tính tiền và để object mồ côi trong thư mục lần thử của
nó; job đầu `ERROR` vì lỗi tạm làm version `FAILED` (không nộp lại).

## Liên kết

- Quyết định: [ADR-0066](../adr/0066-mediaconvert-transcode.md), [ADR-0029](../adr/0029-immutable-media-versions.md),
  [ADR-0004](../adr/0004-direct-upload-and-hls.md).
- Mối đe doạ: FF-1 tới FF-9 ở [threat model mục 4.3](../threat-model.md#43-ffmpeg-đọc-file-người-dùng).
- Hạ tầng: module `transcode`, `media`, `network` của
  [`svp-infra`](https://github.com/anhnvcoder/svp-infra/tree/main/aws/modules); stg so với prd ở
  [`environments.md`](environments.md).
- Vận hành: [`transcode-events-dlq.md`](../runbooks/transcode-events-dlq.md); đo thời gian tới `READY` bằng
  `make transcode-timing`, `make eks-transcode-timing` ([`reference/compose.md`](../reference/compose.md)).
