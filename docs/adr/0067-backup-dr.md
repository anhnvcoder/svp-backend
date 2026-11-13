# 0067. Backup và DR của stg, prd: RDS giữ PITR gốc; AWS Backup chụp RDS và S3 hằng ngày theo Backup policy của Organizations, copy sang account `svp-backup` vào vault khoá governance; `uploads` mã hoá SSE-KMS; mất region ngoài phạm vi

- Trạng thái: Chấp nhận
- Ngày: 2026-11-13
- Người quyết: người học (duyệt account đích, Backup policy, RTO/RPO, vault lock, PITR gốc, mất region ngoài phạm vi và chi phí),
  AI đề xuất thiết kế, giá trị có nguồn và bảng chi phí

## Bối cảnh và vấn đề

- Dữ liệu của stg, prd nằm ở một instance RDS PostgreSQL (`svp_user`, `svp_video`, `svp_engagement`, `svp_feed`, `svp_glitchtip`; CMK sống
  theo buổi, [0057](0057-postgres17-verify-full.md)) và hai bucket của module `media`: `uploads` (bản gốc; sau 30 ngày sang Glacier Deep Archive,
  xoá sau 365 ngày), `media` (HLS, [0029](0029-immutable-media-versions.md)); cả hai SSE-S3, versioning chỉ ở prd
  ([0055](0055-environment-matrix.md) §3). MSK, ElastiCache Valkey ([0053](0053-msk-elasticache-valkey.md)), EKS, cấu hình GitOps dựng lại được.
- Bảo vệ duy nhất là backup tự động gốc của RDS (prd 7, stg 1 ngày) trong chính account env: admin hay kẻ chiếm account env xoá được cả
  instance lẫn backup; không bản sao nào ra khỏi account (org theo SRA của [0059](0059-org-structure-guardrails.md),
  [0060](0060-org-detection-logging.md)); phục hồi dữ liệu managed chưa diễn tập trên cloud ([0020](0020-reliability-stage6.md) §6); chưa có RTO/RPO.
- **Nơi sống của tài nguyên** mới: sống giữa buổi là account `svp-backup` và mọi thứ của root `aws/backup` (bản copy theo retention), baseline,
  contact của nó, **Vault env**, key vault env, opt-in, role của `aws/accounts/<env>`, **Quản lý ở Organizations**, **Backup policy**; theo buổi
  (root `aws/envs/<env>`) là key `uploads`, alarm của **Module backup**, recovery point của vault env (xoá cuối buổi).
- Ràng buộc: env dựng và gỡ trong buổi (≤ 4 giờ, khoảng một buổi mỗi tuần mỗi env); stg giống prd, nhỏ hơn (0055); AI không chạm account.

## Yếu tố quyết định

- Có bản sao ngoài tầm admin của account env, không xoá được trước hạn (AWS SRA; Central Backup account của Control Tower [N41]).
- RTO, RPO có số, đo được trong buổi, tiêu chí đạt viết trước khi đo; stg đi cùng đường với prd (0055), khác biệt là dữ liệu.
- Chi phí có nguồn: sống giữa buổi ≤ $5 mỗi tháng; phần này mỗi buổi ≤ $2 ở stg, ≤ $3 ở prd. Dịch vụ managed, Terraform thuần, không công cụ mới.

## Phương án đã cân nhắc

Trạng thái ngành, được, mất, nguồn: [phụ lục](appendix/0067-backup-dr.md#phương-án). In đậm là lựa chọn.

- Chiến lược DR [N42]: **backup và khôi phục trong region**; backup có bản ở region thứ hai; pilot light; warm standby; đa site.
- Account đích của bản copy: **account `svp-backup` riêng ở OU `Security`**; `svp-log-archive`; `svp-security`; không copy ra ngoài.
- Nơi khai báo plan: **Backup policy của Organizations**; plan Terraform trong từng account env; delegated administrator.
- Lịch: **hằng ngày**; hằng giờ. PITR của RDS: **backup tự động gốc của RDS**; continuous backup của AWS Backup.
- Vault lock: **governance, chỉ ở vault copy**; compliance; không lock.
- Mất region: **ngoài phạm vi**; AWS Backup copy sang region thứ hai; S3 CRR cùng RDS cross-Region automated backups.
- Mã hoá `uploads`: **SSE-KMS bằng CMK với Bucket Key**; giữ SSE-S3.
- Quyền của role AWS Backup: **managed policy của AWS Backup**; policy tự viết theo ARN key.
- Kiểm dữ liệu sau khôi phục: **digest nội dung và `xmin` mỗi bảng qua `svp-pg`**; đếm hàng và `max(created_at)`; không kiểm.

## Kết quả quyết định

Chọn các phương án in đậm. Giá trị mở (tên policy, action, điều kiện, cú pháp, metric, giá) ghi một lần ở bảng "Giá trị → nguồn" của
phụ lục, mỗi dòng một nguồn đọc 2026-11-13; code và runbook đọc từ đó.

### 1. Phạm vi dữ liệu

**Phạm vi dữ liệu**: AWS Backup giữ RDS (mọi database, kể cả `svp_glitchtip`) và hai bucket `uploads`, `media` (`media` không dựng lại được khi
bản gốc đã hết hạn). Không backup, dựng lại: MSK (topic, user, ACL do `kafka-init`), Valkey (cache, session web, rate limit: mất session thì đăng
nhập lại), EKS và cấu hình GitOps (git, Argo CD), image ECR (CI dựng, ký lại), state Terraform (bucket có versioning, `prevent_destroy`), log (Log
Archive). Mất MSK: outbox chưa relay nằm trong Postgres ([0003](0003-async-events-outbox.md)), phát lại khi MSK dựng lại; event đã relay mà
consumer chưa xử lý thì mất, read model (feed, đếm) lệch. AWS Backup bỏ object ở Glacier Flexible Retrieval, Deep Archive [N11]: bản gốc
`uploads` cũ hơn 30 ngày không có trong backup.

### 2. Mục tiêu RTO/RPO

**Mục tiêu RTO/RPO**, prd và stg như nhau, đo ở §9, §10. 28 giờ = chu kỳ 24 giờ + start window + completion window (§4): tuổi lớn nhất của
recovery point hoàn tất gần nhất khi mọi job thành công; tính từ cấu hình (test của `org-policies`), không đo được trong buổi.

| Sự cố | RPO | RTO | Đường khôi phục |
| --- | --- | --- | --- |
| Hỏng dữ liệu RDS | ≤ 5 phút = T0 − `LatestRestorableTime` đọc lúc T0 (log giao dịch lên S3 mỗi năm phút [N24]) | ≤ 60 phút tới instance `available` và **Kiểm dữ liệu** đạt | PITR gốc ra instance mới |
| Object S3 bị xoá, ghi đè | 0 khi còn version cũ (30 ngày); không thì ≤ 28 giờ | ≤ 30 phút | version cũ; restore item-level |
| Mất bucket | ≤ 28 giờ | theo số object (§10) | restore cả bucket |
| Mất account env (bị chiếm) | ≤ 28 giờ | giờ, không cam kết | copy ngược từ **Vault copy** rồi restore (§5) |
| Mất region | ngoài phạm vi (§12) | — | dựng từ IaC ở region khác, không dữ liệu |

### 3. Account `svp-backup`, Organizations, opt-in

- **Account backup**: `svp-backup` ở OU `Security`, khuôn `svp-log-archive` (`close_on_deletion = false`, `prevent_destroy`), không profile
  ghi; root `aws/backup` chạy từ management qua `OrganizationAccountAccessRole`. Baseline, contact SECURITY, GuardDuty (`ALL`), Security Hub
  (policy gắn root), Config áp như mọi account; Inspector nhận nó khi `aws/security` apply lại. `SvpReadOnly` gán thêm đọc đủ metadata vault,
  recovery point, job [N32], [N33]. **Quản lý ở Organizations**: trusted access `backup.amazonaws.com`, `BACKUP_POLICY`, cross-account backup
  bật ở management, có hiệu lực cho mọi account thành viên [N1]. Không delegated administrator (Control Tower tách Backup Administrator,
  Central Backup [N41]; lab gộp đích vào `svp-backup`, management giữ policy như SCP, RCP).
- **Opt-in loại tài nguyên** ở management (plan của Backup policy theo opt-in của management, đè account thành viên chỉ cho plan đó [N3]) và
  mỗi account env: map đủ mọi loại AWS Backup hỗ trợ ở Singapore [N15], khoá viết như API trả (phụ lục §3), mọi khoá `true` vì account dùng
  AWS Backup lần đầu được opt-in mọi loại hỗ trợ lúc đó [N13]; `RDS`, `S3` là hai loại cần. Selection theo loại kèm tag thì opt-in không xét [N14].

### 4. Backup policy, lịch, retention

- **Backup policy**: `svp-backup-prd` gắn OU `Prod`, `svp-backup-stg` gắn OU `NonProd`; plan `svp-<env>` ở `ap-southeast-1`, rule `daily` vào
  vault `svp-<env>`, selection `resources` `svp-<env>-tagged` (role `arn:aws:iam::$account:role/svp-<env>-backup`, mẫu ARN RDS DB instance và
  S3 bucket, điều kiện `aws:ResourceTag/Backup` = `daily` của **Tag backup**), `copy_actions` tới `svp-<env>-copy` bằng id thật của
  `svp-backup` (`$account` chỉ cho cùng account [N4]); JSON ở phụ lục §4. Plan sinh ra trong account thành viên là bất biến [N5]; **Quét
  backup** phân biệt nó với plan cục bộ bằng `BackupPlanName` (khoá plan của policy `svp-<env>`): AWS không ghi dạng ID riêng cho plan đó.
- **Lịch và retention**: `cron(0 18 * * ? *)` UTC, start window 60 phút, completion window 180 phút, không continuous backup. Retention vault
  env / bản copy: prd 35 / 35 ngày, stg 2 / 2; mọi retention ≥ 2 ngày nên bản trước còn tới khi bản kế tiếp hoàn tất muộn nhất (28 giờ).
  Vault lock governance: `svp-prd-copy` min 7, max 35; `svp-stg-copy` min 1, max 7. Job on-demand của diễn tập dùng retention vault env.
- Tag policy `svp-tags` thêm khoá `Backup` (giá trị `daily`) và giá trị `backup` của `Stack`. **Khác biệt stg/prd** chỉ là retention, lock và
  OU gắn policy; stg bật versioning hai bucket của module `media` (backup S3 cần versioning [N11]).

### 5. Vault, lock, copy chéo account

- **Vault env** `svp-<env>` ở `aws/accounts/<env>` (không lock: recovery point bị xoá mỗi cuối buổi) và **Vault copy** `svp-stg-copy`,
  `svp-prd-copy` ở `aws/backup`, qua **Module backup** với key của **Key vault**. AWS Backup mã hoá lại bản copy bằng key của vault đích [N1],
  [N2]: bản copy dùng được khi key RDS, key vault env đã xoá. Vault access policy của vault copy: `Allow` `backup:CopyIntoBackupVault` cho
  `arn:aws:iam::<account env>:root`, `Resource "*"`, không điều kiện thêm [N1]; action khác từ account khác bị từ chối bất kể policy [N18].
  Lock governance gỡ được bằng quyền IAM `DeleteBackupVaultLockConfiguration` (gỡ lab); compliance không gỡ được sau grace time [N17].
- AWS Backup không restore chéo account: copy về account đích rồi restore [N1]. Runbook mất account env thêm lúc sự cố (không có sẵn, để account
  env không chạm bản copy): statement của key `alias/svp-backup-copy` cho account đích, vault access policy của vault đích, role copy.
- **Module backup**: alarm `svp-<env>-backup-job-failed`, `svp-<env>-backup-copy-failed` là query Metrics Insights
  `SELECT SUM(NumberOfBackupJobsFailed) FROM "AWS/Backup"` (và `NumberOfCopyJobsFailed`) [N44], chu kỳ 300 s (metric đẩy mỗi 5 phút), không
  lọc dimension vì tài liệu chỉ nêu dimension ví dụ [N16]; ngưỡng > 0, `Severity=ticket`, `treat_missing_data = "notBreaching"`.

### 6. Khoá KMS

**Key vault** `alias/svp-backup-copy` (root `aws/backup`, `prevent_destroy`), `alias/svp-<env>-backup` (root `aws/accounts/<env>`): rotation,
chờ xoá 30 ngày. **Key policy chuẩn**: statement quản trị mặc định, thêm statement chéo account cho `arn:aws:iam::<backup>:root` (JSON: phụ lục §6):

| Key | Action | Điều kiện | Nguồn |
| --- | --- | --- | --- |
| **Key RDS chia sẻ** | `kms:Decrypt`, `kms:DescribeKey`, `kms:GenerateDataKey`; `kms:CreateGrant` | `CreateGrant` khi `kms:GrantIsForAWSResource` = `true` | [N1], [N2] |
| `alias/svp-<env>-backup` | như trên | `CreateGrant` thêm `kms:ViaService` `backup.*.amazonaws.com`, `kms:EncryptionContextKeys` có `aws:backup:backup-vault` | [N2] |
| `alias/svp-backup-copy` | danh sách rỗng: không statement | — | [N1], [N2] |

### 7. Role của AWS Backup

**Ngoại lệ managed policy**: role `svp-<env>-backup` (trust `backup.amazonaws.com`, `aws:SourceAccount` = account env) chỉ gắn
`AWSBackupServiceRolePolicyForBackup` (có `backup:CopyFromBackupVault`, `CopyIntoBackupVault` cho copy chéo account [N1]),
`AWSBackupServiceRolePolicyForRestores`, `AWSBackupServiceRolePolicyForS3Backup`, `AWSBackupServiceRolePolicyForS3Restore` [N10]; không inline.
KMS trong chúng là `Resource "*"` thu hẹp bằng `kms:ViaService` hay `kms:GrantIsForAWSResource` (phụ lục §7). Cái giá: role dùng được mọi key của
account qua các dịch vụ đó; chỉ AWS Backup của đúng account assume được. Không viết policy theo ARN key: AWS sửa chúng theo dịch vụ [N10].

### 8. `uploads` SSE-KMS

**Mã hoá uploads**: CMK `alias/<name_prefix>-uploads` (rotation, chờ xoá 7 ngày như key RDS), Bucket Key (encryption context là ARN bucket,
request KMS giảm tới 99 % [N30]). Quyền trên đúng ARN key: video-service `kms:GenerateDataKey` (ký form POST một request [N29]); media-worker
(cả Probe, 0066 §3) và role MediaConvert `kms:Decrypt`; role Malware Protection `kms:GenerateDataKey`, `kms:Decrypt` khi `kms:ViaService` =
`s3.<region>.amazonaws.com` [N31]; role Backup theo §7. `media` giữ SSE-S3: nội dung công khai qua CloudFront, CMK không thêm ranh giới.

### 9. Diễn tập PITR và kiểm dữ liệu

- **Kiểm dữ liệu** mỗi bảng do migration của video, engagement, feed tạo, qua **svp-pg**: `count(*)` và `md5` các dòng `xmin::text || ':' ||
  t::text` xếp thứ tự. PITR của RDS dựng từ snapshot volume và log giao dịch [N23], [N24] (khôi phục file rồi replay WAL [N28]); `xmin` nằm trong
  header tuple trên trang [N26], [N27], nên bản khôi phục giữ nó và digest đổi khi có INSERT, UPDATE, DELETE, kể cả trả lại giá trị cũ.
- **Diễn tập PITR** (khi không tải): S1 xong lúc t1, T_r = t1 làm tròn lên giây; chờ `LatestRestorableTime` ≥ T_r; S2 trên nguồn, S1 ≠ S2 là FAIL
  không restore; T0 = gọi restore `--restore-time T_r` ra `svp-<env>-pitr` (cùng subnet group, security group, parameter group, lớp; một AZ); R
  trên bản khôi phục xong lúc T1; RTO = T1 − T0, RPO = T0 − LRT đọc ngay trước T0. PASS khi R = S1 và trong §2; R ≠ S1 là FAIL "restore khác mẫu
  S1", chưa chứng minh restore sai: kết luận chỉ về nội dung tại các mẫu. Rồi xoá instance, kể cả khi FAIL; cắt ứng dụng là bước của runbook.

### 10. Diễn tập object S3

**Diễn tập object S3**: recovery point là dòng của **Điểm của buổi** có ARN bucket media; key `.m3u8` đầu tiên theo từ điển dưới `media/` có trước
recovery point; ghi độ dài, SHA-256; T0; `delete-object` (delete marker: restore coi là chưa có object [N12]); restore item-level vào chính
bucket bằng role Backup, metadata `DestinationBucketName`, `ItemsToRestore` (≤ 5 S3 URI), `EncryptionType` `original`, `RestoreACLs` `false`
(bucket `BucketOwnerEnforced`) [N12]; tải lại, độ dài và SHA-256 bằng trước = T1; RTO = T1 − T0. ETag không so: AWS Backup không giữ ETag
[N11]. Mất bucket: AWS không công bố tốc độ restore S3; ước theo số object ở phụ lục §10, chưa đo.

### 11. Xoá cuối buổi

**Xoá cuối buổi**: `restore-drill.sh <env> cleanup` sau lần ghi Terraform cuối vào root env, ngay trước `plan --destroy`: xoá `svp-<env>-pitr`;
gỡ tag `Backup`; chờ mọi job chưa kết thúc (có hạn); xoá recovery point vault env đã có copy `COMPLETED`, giữ và in lệnh cho cái chưa có; ghi
`backup-drained`. `tf.sh` ghi `backup-undrained` trước mọi `env apply` (`restore-drill.sh` trước `backup`, `rds`, `s3`) và từ chối destroy khi sự
kiện cuối không phải `backup-drained`, không cờ bỏ qua. Vault và bản copy giữ.

### 12. Mất region: ngoài phạm vi

Mất `ap-southeast-1` là mất dữ liệu từ lần backup cuối; env dựng lại từ IaC ở region khác không dữ liệu. Copy sang `us-east-1` (SCP đã cho) thêm
~$2–3 mỗi tháng ở mức lab (CMK, $0,09 mỗi GB chuyển [N37]); cái giá thật là đường dựng env ở region thứ hai và RTO giờ tới ngày (phụ lục §12).

### 13. Chi phí

Sống giữa buổi ~$4,4 mỗi tháng (ba CMK $3, bản copy ~$1,3, Config ~$0,1), dưới trần $5; baseline `svp-backup` ~$2,2 cộng vào chi phí của 0060
§12. Mỗi buổi ~$0,15 ở stg, ~$0,34 ở prd (giờ instance PITR lớn nhất). Bảng giá `ap-southeast-1`: phụ lục, mục "Chi phí".

### Hệ quả

- Tốt: bản copy ở account admin env không chạm được, khoá governance; RTO/RPO có số, đo mỗi buổi; plan không sửa được từ account env.
- Xấu: thêm một account, một root, ba CMK (~$4,4 cộng ~$2,2 baseline mỗi tháng); bản gốc `uploads` sau 30 ngày không có backup; lịch không chạy
  trong buổi nên buổi chỉ kiểm cấu hình mà lịch dựa vào; job RDS theo lịch FAILED khi rơi vào 1 giờ trước hay trong maintenance window [N20]
  (chưa đặt, RDS chọn ngẫu nhiên); `svp-pg` giữ mật khẩu ba user app; role Backup dùng được mọi key qua dịch vụ; mất account cần sửa Terraform
  lúc sự cố; mất region mất dữ liệu.
- Xem lại khi: env sống qua đêm (lịch chạy thật, đo RPO S3); dữ liệu thật cần RPO S3 dưới một ngày; cần sống sót mất region; AWS ghi dimension
  của metric `AWS/Backup` hay dạng ID của plan sinh từ policy.

## Xác nhận

- Lúc quyết chưa hiện thực. Kiểm tĩnh: `make check` của `svp-infra` (`backup-vault`, `backup-alarms`, `org-policies` gồm retention × 24 ≥ 28,
  `media`, `rds`, `transcode`, root mới), `make session-test` (`restore-drill.sh`, `tf.sh`, `sweep.sh`), `deploy/ops/ops-test.sh`, `make helm-check`.
- Thử sandbox ở management: job theo lịch và on-demand, restore item-level (ETag mới, SHA-256 như cũ), PITR `--restore-time`, xoá trong vault
  lock bị từ chối; output `describe-region-settings` đối chiếu danh sách khoá ở phụ lục §3.
- Buổi stg, prd: copy chéo account RDS và S3 `COMPLETED`, **Diễn tập PITR**, **Diễn tập object S3** trong §2, `cleanup` rồi destroy; số đo vào
  phụ lục. Chưa đo: RTO mất bucket, mất account; chi phí thật.

## Hiện thực ở

- `svp-infra`: `aws/org/`, `aws/modules/org-policies/`, `aws/backup/`, `aws/accounts/<env>/backup.tf`, `aws/modules/backup-vault/`, `backup-alarms/`,
  `rds/`, `media/`, `transcode/`, `aws/baseline/`, `aws/envs/<env>/`, `aws/scripts/` (`restore-drill.sh`, `tf.sh`, `sweep.sh`), `docs/runbooks/`.
- Repo này: `deploy/ops/svp-pg`, `deploy/helm/svp-data/` (container `postgres` của `svp-ops`, NetworkPolicy), `docs/explanation/backup-dr.md`,
  `docs/runbooks/rds-restore.md`, `docs/runbooks/s3-restore.md`.

## Nguồn

Đọc 2026-11-13; đủ [N1]–[N44] ở phụ lục. [N1] <https://docs.aws.amazon.com/aws-backup/latest/devguide/create-cross-account-backup.html>.

## Thông tin thêm

Phụ lục: [`appendix/0067-backup-dr.md`](appendix/0067-backup-dr.md) (phương án, giá trị → nguồn, JSON policy, chi phí, FSBP, SCP, RCP).
