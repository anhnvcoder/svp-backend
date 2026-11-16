# Khôi phục object hay bucket S3 của `media` (stg, prd)

- Quy trình làm tay, không có cảnh báo riêng; chỉ AWS, cho hai bucket của module `media`: `uploads` (bản gốc người dùng
  tải lên) và `media` (HLS). Thiết kế, mục tiêu RTO/RPO và nguồn: [ADR-0067](../adr/0067-backup-dr.md) §2, §10; giải
  thích: [`backup-dr.md`](../explanation/backup-dr.md).
- **Người học chạy mọi lệnh**, ở bản clone `svp-infra` với biến account của `$ENV` (`SVP_AWS_STG_ACCOUNT_ID` hay
  `SVP_AWS_PRD_ACCOUNT_ID`) đã export, không ghi vào file nào. Mỗi lệnh ghi nối sau
  `aws/scripts/check-account.sh "$ENV"` bằng `&&`: account của profile khác biến thì script thoát khác 0 và lệnh ghi
  không chạy.

```sh
ENV=stg
N=svp-$ENV
ACCOUNT=$(AWS_PROFILE=anhnv-$ENV aws sts get-caller-identity --query Account --output text --region ap-southeast-1)
MEDIA=$N-media-$ACCOUNT-ap-southeast-1
UPLOADS=$N-uploads-$ACCOUNT-ap-southeast-1
B=$MEDIA          # the bucket of the incident: $MEDIA or $UPLOADS
K='<key>'         # the object of the incident, e.g. media/<video_id>/<version>/master.m3u8
```

## Ý nghĩa và tác động tới người dùng

Mở trang này khi object của một trong hai bucket bị xoá hay ghi đè nhầm, hay cả bucket mất. Object HLS của `media` mất
thì video đó không phát (CloudFront trả 403 hay 404 khi cache hết hạn); bản gốc ở `uploads` mất thì video không
transcode lại được. Các video khác vẫn chạy.

Hai bucket bật versioning ở cả hai env: xoá tạo delete marker, ghi đè giữ version cũ, nên object còn version cũ lấy lại
được ngay, không mất gì (RPO 0). Hết version (quá hạn giữ version cũ, hay bucket bị xoá) thì khôi phục từ recovery point
của AWS Backup, mất những gì ghi sau lần backup đó.

## Kiểm tra nhanh (5 phút)

Compose, k3d: không có (object store trong cluster không có backup).

AWS:

```sh
# 1. The bucket still exists, with versioning on
AWS_PROFILE=anhnv-$ENV aws s3api get-bucket-versioning --bucket "$B" --region ap-southeast-1
# 2. Versions and delete markers of the key: the newest first
AWS_PROFILE=anhnv-$ENV aws s3api list-object-versions --bucket "$B" --prefix "$K" --query '{versions: Versions[?Key==`'"$K"'`].[VersionId,IsLatest,LastModified,Size], markers: DeleteMarkers[?Key==`'"$K"'`].[VersionId,IsLatest,LastModified]}' --output json --region ap-southeast-1
# 3. Recovery points of the bucket in the env vault, and their copies in account svp-backup (read-only profile)
AWS_PROFILE=anhnv-$ENV aws backup list-recovery-points-by-backup-vault --backup-vault-name "$N" --by-resource-arn "arn:aws:s3:::$B" --query 'RecoveryPoints[].[CreationDate,Status,RecoveryPointArn]' --output text --region ap-southeast-1
AWS_PROFILE=anhnv-backup-ro aws backup list-recovery-points-by-backup-vault --backup-vault-name "$N-copy" --by-resource-type S3 --query 'RecoveryPoints[].[CreationDate,Status,RecoveryPointArn]' --output text --region ap-southeast-1
```

Đọc: bước 1 lỗi `NoSuchBucket` là mất bucket. Bước 2 có delete marker `IsLatest` true là object bị xoá; version mới nhất
khác nội dung mong đợi là bị ghi đè. Không còn version nào thì chỉ còn recovery point (bước 3).

## Nguyên nhân thường gặp

1. **Xoá hay ghi đè nhầm** bằng tay, script hay lỗi ứng dụng: bước 2 có delete marker hay version mới ở thời điểm sự cố.
2. **Lifecycle đã dọn**: version cũ quá hạn giữ, hay bản gốc `uploads` đã sang lớp lưu trữ archive (AWS Backup bỏ các
   object đó, ADR-0067 §1): bước 2 không còn version.
3. **Bucket bị xoá** (thao tác tay, hay account env bị chiếm): bước 1 `NoSuchBucket`.

## Giảm thiểu

- Ghi lại key, thời điểm phát hiện và thời điểm sự cố (UTC) cho postmortem.
- Không xoá version, delete marker hay recovery point khác trong lúc điều tra: chúng là đường lui.

## Khôi phục và xác nhận

### Object còn version cũ (RPO 0)

Xoá nhầm: xoá delete marker mới nhất, version trước nó lại thành bản hiện tại. Ghi đè nhầm: chép version đúng lên chính
key đó (thành version mới nhất; bucket `uploads` mã hoá lại bằng key mặc định của bucket).

```sh
# Deleted: the version id of the delete marker that IsLatest from step 2
aws/scripts/check-account.sh "$ENV" &&
  AWS_PROFILE=anhnv-$ENV aws s3api delete-object --bucket "$B" --key "$K" --version-id '<version id of the delete marker>' --region ap-southeast-1
# Overwritten: the version id of the right content from step 2
aws/scripts/check-account.sh "$ENV" &&
  AWS_PROFILE=anhnv-$ENV aws s3api copy-object --bucket "$B" --key "$K" --copy-source "$B/$K?versionId=<version id>" --region ap-southeast-1
```

### Object hay bucket từ recovery point của AWS Backup

Recovery point là dòng của bước 3 có `Status` `COMPLETED`, mới nhất trước thời điểm sự cố. Restore chạy bằng role
`svp-$ENV-backup` và không ghi đè gì: nó chỉ tạo version mới cho key chưa có hay đang là delete marker (bucket đích phải
bật versioning). Metadata theo [phụ lục ADR-0067 §10](../adr/appendix/0067-backup-dr.md#10-restore-s3): `ItemsToRestore`
là chuỗi JSON của tối đa năm S3 URI (bỏ khoá này là restore cả bucket), `RestoreACLs` `false` vì bucket tắt ACL.
`EncryptionType` `original` mã hoá như lúc backup: với `uploads` key KMS lúc backup phải còn; key đã xoá thì dùng
`SSE-KMS` kèm `KMSKey` là ARN của key `alias/$N-uploads` hiện tại.

Mất bucket: dựng lại bucket rỗng trước (apply root `aws/envs/<env>` theo runbook buổi của `svp-infra`, cùng tên,
versioning bật), rồi restore cả bucket vào đó.

```sh
RP='<RecoveryPointArn from step 3>'
# One object: the key of the incident; drop ItemsToRestore to restore the whole bucket.
META=$(jq -nc --arg b "$B" --arg k "s3://$B/$K" '{DestinationBucketName: $b, ItemsToRestore: ([$k] | tojson), EncryptionType: "original", RestoreACLs: "false"}')
aws/scripts/check-account.sh "$ENV" &&
  JOB=$(AWS_PROFILE=anhnv-$ENV aws backup start-restore-job --recovery-point-arn "$RP" --iam-role-arn "arn:aws:iam::$ACCOUNT:role/$N-backup" --resource-type S3 --metadata "$META" --query RestoreJobId --output text --region ap-southeast-1)
until S=$(AWS_PROFILE=anhnv-$ENV aws backup describe-restore-job --restore-job-id "$JOB" --query Status --output text --region ap-southeast-1) && [ "$S" != PENDING ] && [ "$S" != RUNNING ]; do sleep 30; done; echo "$S"
```

`S` phải là `COMPLETED`; khác thì đọc `StatusMessage` của cùng lệnh `describe-restore-job` (bỏ `--query`).

### Từ vault copy

Dùng khi mất account env, hay recovery point chỉ còn ở `svp-$ENV-copy`. AWS Backup không restore chéo account: làm
5a, 5b, 5c của [rds-restore.md, bước 5](rds-restore.md#5-khôi-phục-từ-vault-copy) (thêm quyền lúc sự cố, copy ngược về
vault `svp-$ENV`, gỡ quyền) với `RP` là recovery point S3 của bước 3 ở trên, rồi làm mục trước với
`RP` là `DestinationRecoveryPointArn` của job copy. Bản copy S3 mã hoá bằng key của vault `svp-$ENV`, mà role
`svp-$ENV-backup` dùng được qua AWS Backup; `EncryptionType` `original` với `uploads` cần key `alias/$N-uploads` lúc
backup còn, account dựng lại thì không: dùng `SSE-KMS` với key hiện tại như mục trước. Object đã xác nhận thì xoá
recovery point vừa copy về theo đoạn cuối bước 5 của [rds-restore.md](rds-restore.md#5-khôi-phục-từ-vault-copy):
`cleanup` cuối buổi không xoá nó.

### Xác nhận

Object đúng khi độ dài và SHA-256 bằng bản đúng đã biết (ví dụ tải version đúng ở bước 2 trước khi nó hết hạn). ETag
không dùng để so: AWS Backup không giữ ETag, object khôi phục có ETag mới cùng nội dung.

```sh
AWS_PROFILE=anhnv-$ENV aws s3api get-object --bucket "$B" --key "$K" restored.bin --query ContentLength --region ap-southeast-1
shasum -a 256 restored.bin
```

Với object của `media`: video đó phát lại được qua web.

## Leo thang

- Khôi phục từ vault copy: không xoá gì ở `svp-backup`, không gỡ vault lock. Job copy `FAILED` hai lần thì gỡ quyền
  (5c của [rds-restore.md](rds-restore.md)), mở case với AWS Support và postmortem ([mẫu](../postmortems/README.md)).
- Restore cả bucket chậm: AWS không công bố tốc độ restore S3; ước ở phụ lục ADR-0067 §10. Job quá một giờ vẫn `RUNNING`
  thì ghi trạng thái cho postmortem và chờ; không chạy job thứ hai vào cùng bucket.
- Restore `FAILED` hai lần: giữ nguyên trạng thái, mở case với AWS Support.

## Liên kết

- ADR: [ADR-0067](../adr/0067-backup-dr.md) §2 (mục tiêu), §5–§7 (vault copy, khoá, role), §8 (mã hoá `uploads`), §10
  (diễn tập object S3); threat model BAK-3.
- Cấu hình: module `media` (versioning, lifecycle, mã hoá) và `aws/accounts/<env>/backup.tf` (vault env, role
  `svp-<env>-backup`) của `svp-infra`.
- Diễn tập tái hiện: `aws/scripts/restore-drill.sh <env> s3` của `svp-infra` trong buổi stg, prd (xoá một object `.m3u8`
  của bucket media, restore item-level, so độ dài và SHA-256, đo RTO); số đo ở phụ lục ADR-0067. Khôi phục từ version,
  cả bucket và từ bản copy không có diễn tập.
