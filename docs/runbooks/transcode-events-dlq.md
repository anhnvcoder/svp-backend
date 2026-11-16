# transcode-events-dlq

- Severity: `page`. Alarm CloudWatch `svp-<env>-transcode-events-dlq` của module `transcode`
  (`infra/aws/modules/transcode/alarms.tf`), chỉ ở AWS (stg, prd).
- Chuẩn bị biến `ENV`, `N` và hàm `awsx`: [README](README.md#alarm-của-dịch-vụ-managed-rds-msk-elasticache). Mọi lệnh
  AWS do người học chạy. Log và Kafka của cluster đi qua `kubectl` với context của cluster `$ENV`; lệnh Kafka qua
  `svp-kafka` ([ADR-0053](../adr/0053-msk-elasticache-valkey.md) §13) trong Deployment `svp-ops` của namespace
  `svp-data`.

Luồng, bản ghi job và lý do từng bước: [`explanation/transcode.md`](../explanation/transcode.md).

## Ý nghĩa và tác động tới người dùng

DLQ `svp-<env>-transcode-events-dlq` có ít nhất một message nhìn thấy được (`ApproximateNumberOfMessagesVisible` lớn hơn
0). Message vào đó bằng một trong hai đường:

- **Redrive từ hàng đợi `svp-<env>-transcode-events`:** bridge (`media-worker mediaconvert`) nhận message đủ
  `maxReceiveCount` lần mà không xoá: hoặc nó không bảo đảm được message (log `transcode event ignored`), hoặc `settle`
  lỗi mỗi lần (log `transcode event interrupted`).
- **Dead-letter của đích rule `svp-<env>-mediaconvert-job-state`:** EventBridge không giao được event vào hàng đợi sau
  hết lượt thử. Message mang thuộc tính `ERROR_CODE`, `ERROR_MESSAGE`, `RULE_ARN`, `TARGET_ARN`.

Mỗi message là trạng thái cuối của một job không được `settle` từ SQS. Video của job đó đứng ở `PROCESSING` (người dùng
thấy "đang xử lý"), trừ khi đường `video.uploaded` đã phát kết quả cho version đó. Video khác vẫn transcode bình thường,
trừ khi nguyên nhân chung cho mọi job (quyền, Kafka, bản phát hành lỗi).

Biến thể cùng hậu quả, không qua alarm này: lần thử cuối của `video.uploaded` không ghi được bản ghi job, log ERROR
`transcode result undecided`, record vào dead-letter topic `video.lifecycle.v1.dlq` của kafkax; cảnh báo
`KafkaDLQRecords` ([kafka-dlq-records.md](kafka-dlq-records.md)) báo nó. Mục Khôi phục dưới đây xử lý cả hai.

## Kiểm tra nhanh (5 phút)

Compose, k3d: không có alarm này (local chạy `media-worker serve` với ffmpeg, không MediaConvert, không SQS).

AWS (người học chạy, chỉ đọc):

```sh
DLQ=$(awsx sqs get-queue-url --queue-name "$N-transcode-events-dlq" --query QueueUrl --output text)
MEDIA=$N-media-$(awsx sts get-caller-identity --query Account --output text)-ap-southeast-1
# 1. How many messages the DLQ holds
awsx sqs get-queue-attributes --queue-url "$DLQ" --attribute-names ApproximateNumberOfMessages ApproximateNumberOfMessagesNotVisible
# 2. Read up to 10 messages without deleting them (visibility 0: they show again at once).
# One line each: jobId, status, video_id, version, delivery error code.
awsx sqs receive-message --queue-url "$DLQ" --max-number-of-messages 10 --visibility-timeout 0 --message-attribute-names All \
  --output json | jq -r '.Messages[]? | [(.Body | fromjson? | .detail.jobId, .detail.status, .detail.userMetadata.video_id,
  .detail.userMetadata.version), (.MessageAttributes.ERROR_CODE.StringValue // "-")] | @tsv'
# 3. The job of one line of step 2: status, queue, metadata, error code
awsx mediaconvert get-job --id <jobId> --query 'Job.[Status,Queue,UserMetadata,ErrorCode,ErrorMessage]'
# 4. The job record of the version (which job decides the result)
awsx s3api get-object --bucket "$MEDIA" --key "transcode-jobs/<video_id>/<version>.json" /dev/stdout
```

```sh
# 5. Bridge logs around that job (kubectl context of cluster $ENV)
kubectl --context <context của cluster $ENV> -n svp logs -l app.kubernetes.io/name=media-worker --since=2h --tail=-1 | grep '<jobId>'
# 6. Kafka variant: records in the dead-letter topic of video.lifecycle.v1
kubectl --context <context của cluster $ENV> -n svp-data exec deploy/svp-ops -c kafka -- /opt/svp/bin/svp-kafka get-offsets --topic video.lifecycle.v1.dlq
```

Đọc: bước 2 có `ERROR_CODE` là đường dead-letter của EventBridge; không có là redrive. Dòng chỉ có một cột (`fromjson?`
không đọc được thân) là message không phải event JSON. Bước 3 `Queue` khác ARN queue `svp-<env>` hay `UserMetadata`
thiếu `video_id`, `version`, `attempt` là job bridge không nhận. Bước 4 `NoSuchKey`: version chưa có bản ghi; có
`job_id` khác `<jobId>`: job trong message là job lạc. Bước 5 cho dòng `transcode event ignored` hay
`transcode event interrupted` kèm `error`.

## Nguyên nhân thường gặp

1. **`settle` lỗi lặp lại** (log `transcode event interrupted`): bridge thiếu quyền S3 (`AccessDenied` khi `CopyObject`,
   tạo master hay bản ghi), `GetJob` bị throttle kéo dài, Kafka không nhận publish (MSK lỗi, mật khẩu đổi). Nhiều
   message cùng lúc, cùng `error`.
2. **Job không phải của bridge** (log `transcode event ignored`, `job is not in the queue of this environment` hay
   `job metadata lacks …`): job tạo tay trên queue env (thử từ console, CLI) không có `UserMetadata` của bridge. Một hai
   message lẻ, không có video nào kẹt.
3. **Bản phát hành lệch settings** (`job writes outside its attempt directory`, `job reports … outputs`,
   `job has an HLS output … outside the ladder`): code dựng job và code đọc job khác nhau, hay settings đổi giữa lúc tạo
   job và lúc `settle`. Bắt đầu ngay sau deploy.
4. **Bản ghi job hỏng** (`job record … is malformed`, `recorded job … belongs to another attempt`): object trong
   `transcode-jobs/` bị ghi tay hay bởi thứ khác ngoài bridge.
5. **EventBridge không giao được** (bước 2 có `ERROR_CODE`, thường quyền): policy của hàng đợi không còn cho
   `events.amazonaws.com` với `aws:SourceArn` của rule, hay hàng đợi bị xoá, tạo lại ngoài Terraform.

## Giảm thiểu

- Không xoá message của DLQ khi chưa biết video nào bị ảnh hưởng: message là bằng chứng duy nhất của kết quả job. DLQ
  giữ message theo hạn ở `infra/aws/modules/transcode/events.tf`.
- Không phát tay `transcode.*`, không huỷ job, không sửa hay xoá bản ghi job: bản ghi là thứ giữ "một version, một kết
  quả" ([ADR-0066](../adr/0066-mediaconvert-transcode.md) §6).
- Nguyên nhân 1, 5: sửa quyền, hàng đợi hay Kafka bằng Terraform (`svp-infra`, người học chạy), không sửa tay trên
  console. Message mới ngừng vào DLQ khi nguyên nhân hết.
- Nguyên nhân 3: dừng promote, quay về bản trước bằng PR revert của commit promote ở `svp-gitops` (ruleset `main`).
- Video ở `PROCESSING` không có bước giảm thiểu cho người dùng: kết quả về khi message được `settle`.

## Khôi phục và xác nhận

Phát lại an toàn vì `settle` chỉ đọc bản ghi job: message phát lại ra đúng kết quả của job trong bản ghi, dù message là
của job lạc, và video-service chịu event trùng. Chỉ phát lại **sau khi** nguyên nhân đã hết (bước 5 không còn lỗi mới).

Lệnh ghi là bước người học quyết, chạy ở bản clone `svp-infra` với biến account của `$ENV` (`SVP_AWS_STG_ACCOUNT_ID`
hay `SVP_AWS_PRD_ACCOUNT_ID`) đã export, không ghi vào file nào. Mỗi lệnh ghi nối sau
`aws/scripts/check-account.sh "$ENV"` bằng `&&`: script so account của profile `anhnv-$ENV` với biến đó, khác thì thoát
khác 0 và lệnh ghi không chạy.

```sh
# Keeps the session directory if one is set.
export SVP_SESSION_DIR="${SVP_SESSION_DIR:-$PWD/.session/$(date -u +%Y%m%dT%H%M%SZ)}"
SRC=$(awsx sqs get-queue-url --queue-name "$N-transcode-events" --query QueueUrl --output text)
DLQ_ARN=$(awsx sqs get-queue-attributes --queue-url "$DLQ" --attribute-names QueueArn --query Attributes.QueueArn --output text)
SRC_ARN=$(awsx sqs get-queue-attributes --queue-url "$SRC" --attribute-names QueueArn --query Attributes.QueueArn --output text)
# Move every DLQ message back to the source queue; the target is explicit: EventBridge messages have no redrive source.
aws/scripts/check-account.sh "$ENV" &&
  awsx sqs start-message-move-task --source-arn "$DLQ_ARN" --destination-arn "$SRC_ARN"
awsx sqs list-message-move-tasks --source-arn "$DLQ_ARN" --query 'Results[0].[Status,ApproximateNumberOfMessagesMoved,FailureReason]'
```

Message của nguyên nhân 2 (job không phải của bridge) quay lại DLQ sau đủ số lần nhận: đó là đúng thiết kế. Sau khi đã
chắc không video nào gắn với nó (bước 3, 4), xoá riêng nó và ghi `MessageId`, `jobId` vào postmortem. Cũng ở bản clone
`svp-infra`, như khối trên:

```sh
# Get the ReceiptHandle of that exact message (MessageId, jobId noted above)
awsx sqs receive-message --queue-url "$DLQ" --max-number-of-messages 10 --query 'Messages[].[MessageId,ReceiptHandle]'
aws/scripts/check-account.sh "$ENV" &&
  awsx sqs delete-message --queue-url "$DLQ" --receipt-handle <ReceiptHandle>
```

Biến thể Kafka (`transcode result undecided`): sau khi S3 ghi được lại, đưa offset của group `media-worker` về offset
gốc của record theo [kafka-dlq-records.md](kafka-dlq-records.md) (dừng consumer bằng annotation
`autoscaling.keda.sh/paused-replicas` của KEDA, `--dry-run` trước). `video.uploaded` giao lại đọc bản ghi nếu có, không
có thì tạo job mới; cả hai cho đúng một kết quả. Cách này cũng dùng được khi message của một job đã mất hẳn (quá hạn giữ
của hàng đợi): `settle` từ `video.uploaded` gọi `GetJob` của job trong bản ghi.

Xác nhận:

```sh
awsx sqs get-queue-attributes --queue-url "$DLQ" --attribute-names ApproximateNumberOfMessages
awsx cloudwatch describe-alarms --alarm-names "$N-transcode-events-dlq" --query 'MetricAlarms[0].StateValue'
```

DLQ về 0 (hay chỉ còn message đã quyết giữ lại), `StateValue` về `OK`; log bridge có `transcode result published` với
`job_id` của từng job đã phát lại; video ở `READY` hay `FAILED` (feed của tác giả, hay `GET /public/videos/{id}` trả 200
với video `READY`); `make eks-smoke` do người học chạy.

## Leo thang

- Message quay lại DLQ sau khi phát lại mà không phải nguyên nhân 2: nguyên nhân chưa hết; dừng phát lại, đọc lại bước
  5.
- Nhiều job `ERROR` cùng mã ngoài bảng "Mã lỗi" của phụ lục ADR-0066, hay MediaConvert không trả lời `GetJob`: xem AWS
  Health của region, mở case với AWS Support.
- Video của người dùng kẹt `PROCESSING` hơn vài phút, hay phải phát lại hơn vài message: mở postmortem
  ([mẫu](../postmortems/README.md)).

## Liên kết

- Dashboard: CloudWatch → Alarms `svp-<env>-transcode-events-dlq`; SQS → `svp-<env>-transcode-events-dlq` → Monitoring;
  `svp-pipeline` (pipeline video, DLQ của Kafka).
- ADR: [ADR-0066](../adr/0066-mediaconvert-transcode.md) §6, §7 (bản ghi job, hàng đợi, mã lỗi);
  [ADR-0058](../adr/0058-managed-data-operations.md) (alarm của dịch vụ managed).
- Diễn tập: không có. Test của package `internal/mediaconvert` (`make test PKGS=./services/media-worker/...`) phủ
  message lặp, job lạc (mất response, người gọi cũ sau rebalance), message không hành động được, khởi động lại chỉ còn
  message; buổi stg kiểm đường alarm tới email bằng `set-alarm-state` (README).
