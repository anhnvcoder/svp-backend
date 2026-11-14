# Phụ lục ADR-0067: Backup và DR của stg, prd

Phụ lục của [ADR-0067](../0067-backup-dr.md): phương án, bảng "giá trị → nguồn", JSON của Backup policy, vault access policy, key policy,
statement KMS của các managed policy, quyền KMS của `uploads`, lý lẽ `xmin`, restore S3, DR đa region, chi phí, control FSBP, luồng SCP, RCP và
nguồn, xếp theo §. Mọi nguồn đọc ngày 2026-11-13. Đường dẫn `aws/...` không kèm repo là của `svp-infra`; `<backup>` là id account `svp-backup`
(ví dụ `222222222222`), `<env account>` là id account env (ví dụ `000000000000`), `<region>` là `ap-southeast-1`.

## Phương án

| Câu hỏi | Phương án | Trạng thái ngành | Được | Mất | Nguồn |
| --- | --- | --- | --- | --- | --- |
| Chiến lược DR | **Backup và khôi phục trong region** | Hiện hành, mức rẻ nhất trong bốn chiến lược của AWS | Rẻ; đủ cho mất dữ liệu, hỏng dữ liệu, mất account | RTO giờ; mất region là mất dữ liệu | [N42] |
| | Backup có bản ở region thứ hai | Hiện hành | Sống sót mất region về dữ liệu | Thêm vault, CMK, phí chuyển; vẫn phải dựng env ở region mới | [N42], §12 |
| | Pilot light, warm standby, đa site | Hiện hành | RTO phút | Hạ tầng chạy sẵn ở region thứ hai: trái luật env theo buổi | [N42] |
| Account đích của bản copy | **`svp-backup` riêng, OU `Security`** | Hiện hành: Central Backup account của Control Tower | Dữ liệu người dùng không chung account log hay công cụ bảo mật; account env không vào được | Thêm một account (email, baseline, đóng mất 90 ngày) | [N41] |
| | `svp-log-archive` | — | Không thêm account | Admin log đọc được bản copy; trộn dữ liệu người dùng với log | — |
| | `svp-security` | — | Không thêm account | Account có quyền rộng nhất của org giữ thêm dữ liệu | — |
| | Không copy | Cũ | $0 | Mất account env là mất cả backup | — |
| Nơi khai báo plan | **Backup policy của Organizations** | Hiện hành | Admin account env không sửa, xoá được plan; một chỗ khai báo | Cú pháp riêng (`@@assign`), sửa phải apply `aws/org` bằng management | [N4], [N5] |
| | Plan Terraform trong `aws/accounts/<env>` | Hiện hành | Một cú pháp Terraform | `SvpAdmin` của env sửa, xoá được plan | — |
| | Delegated administrator | Hiện hành (Control Tower) | Quản trị ngoài management | Thêm policy uỷ quyền, `AWSBackupOrganizationAdminAccess`; YAGNI với một người vận hành | [N3] |
| Lịch | **Hằng ngày** | Hiện hành | Ít recovery point | RPO S3 28 giờ | [N20] |
| | Hằng giờ | Hiện hành | RPO S3 1 giờ | Snapshot RDS hằng giờ giữ 35 ngày là hàng trăm snapshot mỗi instance; PITR đã phủ RDS | — |
| PITR của RDS | **Backup tự động gốc của RDS** | Hiện hành | Terraform giữ `backup_retention_period`, không lệch | PITR nằm trong account env (bản copy là snapshot hằng ngày) | [N24] |
| | Continuous backup của AWS Backup | Hiện hành | PITR quản ở AWS Backup, tới 35 ngày | AWS Backup nắm cửa sổ backup tự động và đổi retention bằng `ModifyDBInstance`: lệch state Terraform mỗi plan | [N19] |
| Vault lock | **Governance, chỉ ở vault copy** | Hiện hành | Bản copy không xoá được trước min retention; lab gỡ được lock | Người có quyền IAM gỡ lock được | [N17] |
| | Compliance | Hiện hành (yêu cầu pháp lý) | Không ai gỡ được sau grace time | Lab không xoá được vault | [N17] |
| | Lock cả vault env | — | Vault env cũng khoá | Recovery point vault env bị xoá mỗi cuối buổi (key RDS bị xoá cùng env): phải gỡ lock bằng management mỗi buổi | — |
| Mất region | **Ngoài phạm vi** | — | $0 thêm | Mất dữ liệu từ lần backup cuối | §12 |
| | AWS Backup copy sang region thứ hai | Hiện hành | Dữ liệu sống sót | §12 | [N37] |
| | S3 CRR cùng RDS cross-Region automated backups | Hiện hành | RPO phút | Thêm replication, key ở region đích; control S3.7 | [N42], [N34] |
| Mã hoá `uploads` | **SSE-KMS bằng CMK, Bucket Key** | Hiện hành cho dữ liệu người dùng | Kiểm toán và thu hồi qua key; S3.17 đạt | $1 mỗi key-tháng theo buổi; quyền KMS cho bốn principal | [N29], [N30] |
| | Giữ SSE-S3 | Hiện hành | Không quyền KMS | Không kiểm toán dùng key | — |
| Quyền role Backup | **Managed policy của AWS Backup** | Hiện hành, AWS hướng dẫn bắt đầu từ đây | AWS sửa theo dịch vụ | KMS `Resource "*"` có điều kiện | [N10] |
| | Policy tự viết theo ARN key | — | Hẹp nhất | Phải theo kịp mọi action AWS Backup cần (copy, restore, S3) | [N6]–[N9] |
| Kiểm dữ liệu | **Digest nội dung và `xmin` mỗi bảng** | — | Bắt mọi INSERT, UPDATE, DELETE, kể cả trả lại giá trị cũ | Đọc toàn bảng (dữ liệu lab nhỏ) | §9 |
| | `count(*)`, `max(created_at)` | — | Rẻ | UPDATE giữ nguyên hai số vẫn PASS | — |

## Giá trị → nguồn

| Giá trị | Chốt | Nguồn | Mục |
| --- | --- | --- | --- |
| Managed policy của role `svp-<env>-backup` | `AWSBackupServiceRolePolicyForBackup` (v30), `AWSBackupServiceRolePolicyForRestores` (v36), `AWSBackupServiceRolePolicyForS3Backup` (v5), `AWSBackupServiceRolePolicyForS3Restore` (v2); `ForBackup` có `backup:CopyFromBackupVault`, `CopyIntoBackupVault` | [N1], [N6]–[N10] | §7 |
| Statement KMS và điều kiện của từng managed policy | Nguyên văn ở §7 | [N6]–[N9] | §7 |
| Statement của **Key RDS chia sẻ** | `kms:Decrypt`, `kms:DescribeKey`, `kms:GenerateDataKey`; `kms:CreateGrant` khi `kms:GrantIsForAWSResource`; principal account `svp-backup` | [N1], [N2] | §6 |
| Statement của key vault env | Như trên, `CreateGrant` thêm `kms:ViaService` `backup.*.amazonaws.com`, `kms:EncryptionContextKeys` `aws:backup:backup-vault` | [N2] | §6 |
| Statement của key vault copy | Danh sách rỗng | [N1], [N2] | §6 |
| Mã hoá của bản copy | Key của vault đích ("re-encrypts your copy using the encryption key of your destination vault") | [N1], [N2] | §5 |
| Điều kiện vault access policy | Principal `arn:aws:iam::<env account>:root`, chỉ `backup:CopyIntoBackupVault`, không điều kiện thêm | [N1], [N18] | §5 |
| Cú pháp Backup policy | `plans.<tên>.regions/rules/selections`; `@@assign`; selection `resources` với `iam_role_arn`, `resource_types`, `conditions.string_equals.<tên>.condition_key/condition_value`; `copy_actions` khoá bằng ARN vault, id thật cho chéo account | [N4] | §4 |
| Trường phân biệt plan của policy | `BackupPlanName` = khoá plan trong policy; plan bất biến trong account thành viên; `BackupPlansListMember` không có trường đánh dấu | [N4], [N5], [N43] | §4 |
| Danh sách **Opt-in loại tài nguyên** | Mọi loại AWS Backup hỗ trợ ở Singapore theo bảng của AWS, khoá viết như API trả (phụ lục §3), mọi khoá `true` | [N13], [N14], [N15], [N45] | §3 |
| Opt-in của management áp plan của policy | Đè opt-in của account thành viên, chỉ cho plan đó | [N3] | §3 |
| Hiệu lực org của cross-account backup (`isCrossAccountBackupEnabled`) | Bật ở management; chỉ management đổi được; bật rồi mọi account thành viên làm đích được | [N1] | §3 |
| Quyền đọc của `SvpReadOnly` (`read_only`) | Đủ, không inline thêm: bảng ở §3 | [N32], [N33] | §3 |
| `aws/security` nhận account mới | GuardDuty `auto_enable_organization_members = "ALL"`; Security Hub cấu hình `CENTRAL`, policy gắn root; Inspector đọc `non_master_accounts` lúc apply | `aws/security/guardduty.tf`, `security-hub.tf`, `inspector.tf` | §3 |
| Metric, dimension của **Module backup** | `AWS/Backup` `NumberOfBackupJobsFailed`, `NumberOfCopyJobsFailed`, đẩy mỗi 5 phút; dimension chỉ có ví dụ; query Metrics Insights không lọc dimension | [N16], [N44] | §5 |
| Action KMS mỗi principal của **Mã hoá uploads** | Bảng ở §8 | [N8], [N9], [N29], [N31] | §8 |
| Metadata restore item-level S3 | `DestinationBucketName`, `ItemsToRestore` (≤ 5), `EncryptionType`, `RestoreACLs`; delete marker hiện tại coi là không có object | [N12] | §10 |
| ETag | Không giữ qua restore | [N11] | §10 |
| `xmin` qua restore point-in-time | Giữ: lý lẽ ở §9 | [N23], [N24], [N26]–[N28] | §9 |
| Gỡ lock governance | Người có quyền IAM gỡ được (`DeleteBackupVaultLockConfiguration`); compliance không | [N17] | §5 |
| Restore chéo account | Không hỗ trợ: copy rồi restore ở account đích | [N1] | §5 |
| Maintenance window | Backup của dịch vụ database không bắt đầu được 1 giờ trước hay trong maintenance window | [N20] | ADR, Hệ quả |
| Object archive | AWS Backup bỏ Glacier Flexible Retrieval, Deep Archive | [N11] | §1 |
| **Chi phí R6** | Sống giữa buổi ~$4,4 mỗi tháng; baseline `svp-backup` ~$2,2 (theo 0060); mỗi buổi ~$0,15 stg, ~$0,35 prd | Mục "Chi phí" | §13 |

## §3. Account, Organizations, opt-in

- `isCrossAccountBackupEnabled`: "you must enable cross-account backup in the AWS Backup console or through the UpdateGlobalSettings API";
  "Cross-account backup can only be enabled or disabled using these credentials" (management); "When you first enable cross-account backups
  using your AWS Organizations management account, any user of a member account can configure their account to be a destination account" [N1].
- Opt-in: "the resource opt-in settings in the management account override the settings in a member account", "but only for that backup plan";
  plan cục bộ của account thành viên theo opt-in của chính nó [N3]. "When an account uses AWS Backup (creates a backup vault or backup plan) in a
  Region, the account automatically is opted into all resource types supported by AWS Backup in the Region at that time" [N13]. "If both a
  resource type and tags are specified in a resource assignment, the resource type specified in the backup plan takes priority over the tag
  condition. Service opt-in settings are disregarded in this situation" [N14].
- Khoá của map: mọi loại tài nguyên mà bảng "Supported services by AWS Region" của AWS Backup ghi cho Singapore [N15] (ngày đọc: có Aurora
  DSQL, Redshift Serverless; chưa có Timestream), viết như `DescribeRegionSettings` trả và test của provider liệt kê [N45]: `Aurora`,
  `CloudFormation`, `DSQL`, `DocumentDB`, `DynamoDB`, `EBS`, `EC2`, `EFS`, `EKS`, `FSx`, `Neptune`, `RDS`, `Redshift`, `Redshift Serverless`,
  `S3`, `SAP HANA on Amazon EC2`, `Storage Gateway`, `VirtualMachine`. Bảng của AWS gộp các loại FSx vào một khoá `FSx`, Windows VSS vào
  `EC2`, DynamoDB advanced vào `DynamoDB`. Không đặt `resource_type_management_preference`. API trả map tên → bool, không liệt kê khoá
  [N14]; AWS thêm loại theo thời gian, nên output `describe-region-settings` của thử sandbox ở management là phép đối chiếu khoá trước
  khi áp `aws/org`: khoá API trả mà danh sách thiếu (ví dụ `Timestream` khi Singapore có) thì thêm `true`; khoá API không trả thì bỏ.
- `SvpReadOnly` (`ViewOnlyAccess` + `SecurityAudit`) đọc đủ metadata ở `svp-backup`:

| Việc | Action | Có trong |
| --- | --- | --- |
| Vault, lock (`Locked`, min, max của `DescribeBackupVault`) | `backup:ListBackupVaults`, `DescribeBackupVault` | `ViewOnlyAccess`, `SecurityAudit` |
| Vault access policy | `backup:GetBackupVaultAccessPolicy` | `SecurityAudit` |
| Recovery point | `backup:ListRecoveryPointsByBackupVault`, `DescribeRecoveryPoint`, `ListRecoveryPointsByResource` | `ViewOnlyAccess` |
| Job | `backup:ListBackupJobs`, `DescribeBackupJob`, `ListCopyJobs`, `DescribeCopyJob`, `ListRestoreJobs`, `DescribeRestoreJob` | `ViewOnlyAccess` |
| Plan, cài đặt | `backup:ListBackupPlans`, `GetBackupPlan`, `ListBackupSelections`, `GetBackupSelection`, `DescribeRegionSettings`, `DescribeGlobalSettings`, `ListTags` | `ViewOnlyAccess` |

## §4. Backup policy

Policy `svp-backup-prd` (stg: `svp-stg`, retention 2, vault `svp-stg`, `svp-stg-copy`). Cú pháp, `$account` cho `iam_role_arn`, id thật cho
copy chéo account, selection `resources` có `conditions` [N4]; giới hạn 30 điều kiện mỗi selection [N4].

```json
{
  "plans": {
    "svp-prd": {
      "regions": { "@@assign": ["ap-southeast-1"] },
      "rules": {
        "daily": {
          "schedule_expression": { "@@assign": "cron(0 18 * * ? *)" },
          "start_backup_window_minutes": { "@@assign": "60" },
          "complete_backup_window_minutes": { "@@assign": "180" },
          "target_backup_vault_name": { "@@assign": "svp-prd" },
          "lifecycle": { "delete_after_days": { "@@assign": "35" } },
          "copy_actions": {
            "arn:aws:backup:ap-southeast-1:222222222222:backup-vault:svp-prd-copy": {
              "target_backup_vault_arn": {
                "@@assign": "arn:aws:backup:ap-southeast-1:222222222222:backup-vault:svp-prd-copy"
              },
              "lifecycle": { "delete_after_days": { "@@assign": "35" } }
            }
          }
        }
      },
      "selections": {
        "resources": {
          "svp-prd-tagged": {
            "iam_role_arn": { "@@assign": "arn:aws:iam::$account:role/svp-prd-backup" },
            "resource_types": { "@@assign": ["arn:aws:rds:*:*:db:*", "arn:aws:s3:::*"] },
            "conditions": {
              "string_equals": {
                "backup-daily": {
                  "condition_key": { "@@assign": "aws:ResourceTag/Backup" },
                  "condition_value": { "@@assign": "daily" }
                }
              }
            }
          }
        }
      }
    }
  }
}
```

- `"arn:aws:rds:*:*:db:*"`, `"arn:aws:s3:::*"` nằm trong danh sách loại tài nguyên Organizations nhận cho `resource_types` [N4]; snapshot RDS
  (`…:snapshot:…`) không khớp mẫu instance nên tag kế thừa qua `copy_tags_to_snapshot` không làm nó bị chọn.
- Plan trong account thành viên: "appears in the AWS Backup console as an immutable plan for that account. You can view it, but not change it"
  [N5]. `BackupPlansListMember` có `BackupPlanArn`, `BackupPlanId`, `BackupPlanName`, `CreationDate`, `CreatorRequestId`, `DeletionDate`,
  `LastExecutionDate`, `VersionId`, `AdvancedBackupSettings`, không trường nào đánh dấu plan của policy [N43]: **Quét backup** dùng tên.
- Retention ≥ 2 ngày: bản trước hết hạn sau 24 × retention giờ, bản kế tiếp hoàn tất muộn nhất sau 24 + (60 + 180) / 60 = 28 giờ; 2 × 24 = 48 ≥ 28.

## §5. Vault, copy, alarm

Vault access policy của `svp-prd-copy` (của `svp-stg-copy`: account stg) theo mẫu chia sẻ theo account của [N1]:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "CopyFromPrdAccount",
      "Effect": "Allow",
      "Principal": { "AWS": "arn:aws:iam::000000000000:root" },
      "Action": "backup:CopyIntoBackupVault",
      "Resource": "*"
    }
  ]
}
```

- "Regardless of the AWS Backup vault's access policy, cross-account access for any action other than `backup:CopyIntoBackupVault` will be
  rejected" [N18]. Role nguồn cần `CopyIntoBackupVault` ở cả identity policy lẫn vault policy; "The AWS managed policy
  `AWSBackupServiceRolePolicyForBackup` includes both of these permissions" [N1].
- Mã hoá: "AWS Backup re-encrypts your copy using the encryption key of your destination vault" [N1]; "AWS Backup encrypts the copy using the
  KMS key of the target vault" [N2]. Vault đích của RDS (không fully managed) phải dùng CMK [N1], [N2]: `alias/svp-backup-copy` là CMK.
- Vault đích không được là vault mặc định [N1]. Restore: "AWS Backup does not support recovering resources from one AWS account to another.
  However, you can copy a backup from one account to a different account and then restore it in that account" [N1].
- Lock: "Vaults locked in governance mode can have the lock removed by users with sufficient IAM permissions"; compliance "cannot be deleted
  once the cooling-off period ("grace time") expires if any recovery points are in the vault"; min retention ngắn nhất 1 ngày [N17].
- Alarm: "AWS Backup emits updated metrics to CloudWatch every 5 minutes"; `NumberOfBackupJobsFailed` "The number of backup jobs with status of
  Failed"; `NumberOfCopyJobsFailed` "The number of cross-account and cross-Region copy jobs that AWS Backup attempted but could not complete";
  dimension "Resource type, vault name" là ví dụ, "The vault name of copy jobs is that of their destination vault" [N16]. `FROM "AWS/Backup"`
  (không `SCHEMA`) gộp metric mọi tập dimension; alarm trên query Metrics Insights được hỗ trợ [N44]. Query:
  `SELECT SUM(NumberOfBackupJobsFailed) FROM "AWS/Backup"`, `SELECT SUM(NumberOfCopyJobsFailed) FROM "AWS/Backup"`; chu kỳ 300 s, 1/1, > 0.

## §6. Key policy

Statement thêm vào key RDS của env (principal là account `svp-backup`); key vault env thêm cùng hai statement với điều kiện `CreateGrant` của
mẫu [N2]. Mẫu của [N2] có `kms:ListKeys`, `kms:ListAliases`: hai action không gắn với một key, key policy không cấp được, nên bỏ.

```json
[
  {
    "Sid": "BackupAccountUseForCopy",
    "Effect": "Allow",
    "Principal": { "AWS": "arn:aws:iam::222222222222:root" },
    "Action": ["kms:Decrypt", "kms:DescribeKey", "kms:GenerateDataKey"],
    "Resource": "*"
  },
  {
    "Sid": "BackupAccountGrantForCopy",
    "Effect": "Allow",
    "Principal": { "AWS": "arn:aws:iam::222222222222:root" },
    "Action": "kms:CreateGrant",
    "Resource": "*",
    "Condition": { "Bool": { "kms:GrantIsForAWSResource": "true" } }
  }
]
```

Điều kiện `CreateGrant` của key vault env (nguyên văn mẫu [N2]):

```json
{
  "ForAnyValue:StringEquals": { "kms:EncryptionContextKeys": "aws:backup:backup-vault" },
  "Bool": { "kms:GrantIsForAWSResource": true },
  "StringLike": { "kms:ViaService": "backup.*.amazonaws.com" }
}
```

- Nguồn: "In the source account, if your resources are encrypted with a customer managed key, you must share this customer managed key with
  the destination account" [N1]; "At a minimum, the key policy requires the following permissions: `kms:createGrant`, `kms:generateDataKey`,
  `kms:decrypt`" [N2]; "Cross-account copy with AWS managed keys isn't supported for resources that aren't fully managed by AWS Backup" [N2].
- Key RDS không dùng `kms:ViaService` `backup.*`: snapshot RDS do RDS sao chép (không fully managed [N22]), grant không đi qua AWS Backup.
- `alias/svp-backup-copy`: tài liệu chỉ đòi chia sẻ key nguồn và vault access policy đích [N1], [N2]; key đích không cần statement chéo account.
  Copy ngược khi mất account env thêm statement cho account đích lúc đó.

## §7. Managed policy của role Backup

Statement KMS nguyên văn (phiên bản mặc định lúc đọc):

`AWSBackupServiceRolePolicyForBackup` v30 [N6]:

```json
[
  { "Sid": "KMSDynamoDBPermissions", "Effect": "Allow", "Action": ["kms:Decrypt", "kms:GenerateDataKey"], "Resource": "*",
    "Condition": { "StringLike": { "kms:ViaService": ["dynamodb.*.amazonaws.com"] } } },
  { "Sid": "KMSPermissions", "Effect": "Allow", "Action": "kms:DescribeKey", "Resource": "*" },
  { "Sid": "KMSCreateGrantPermissions", "Effect": "Allow", "Action": "kms:CreateGrant", "Resource": "*",
    "Condition": { "Bool": { "kms:GrantIsForAWSResource": "true" } } },
  { "Sid": "KMSEC2Permissions", "Effect": "Allow",
    "Action": ["kms:GenerateDataKeyWithoutPlaintext", "kms:ReEncryptTo", "kms:ReEncryptFrom"],
    "Resource": "arn:aws:kms:*:*:key/*",
    "Condition": { "StringLike": { "kms:ViaService": ["ec2.*.amazonaws.com"] },
      "ForAnyValue:StringEquals": { "kms:EncryptionContextKeys": "aws:ebs:id" } } },
  { "Sid": "KMSDSQLPermissions", "Effect": "Allow", "Action": ["kms:Decrypt"], "Resource": "*",
    "Condition": { "StringLike": { "kms:ViaService": ["dsql.*.amazonaws.com"] },
      "ForAnyValue:StringEquals": { "kms:EncryptionContextKeys": "aws:dsql:ClusterId" } } }
]
```

`AWSBackupServiceRolePolicyForRestores` v36 [N7]:

```json
[
  { "Sid": "KMSDescribePermissions", "Effect": "Allow", "Action": "kms:DescribeKey", "Resource": "*" },
  { "Sid": "KMSPermissions", "Effect": "Allow",
    "Action": ["kms:Decrypt", "kms:Encrypt", "kms:GenerateDataKey", "kms:ReEncryptTo", "kms:ReEncryptFrom",
      "kms:GenerateDataKeyWithoutPlaintext", "kms:DescribeKey"],
    "Resource": "*",
    "Condition": { "StringLike": { "kms:ViaService": ["dynamodb.*.amazonaws.com", "ec2.*.amazonaws.com",
      "elasticfilesystem.*.amazonaws.com", "rds.*.amazonaws.com", "redshift.*.amazonaws.com", "dsql.*.amazonaws.com",
      "redshift-serverless.*.amazonaws.com"] } } },
  { "Sid": "KMSCreateGrantPermissions", "Effect": "Allow", "Action": "kms:CreateGrant", "Resource": "*",
    "Condition": { "Bool": { "kms:GrantIsForAWSResource": "true" } } }
]
```

`AWSBackupServiceRolePolicyForS3Backup` v5 [N8]:

```json
{ "Sid": "KmsPermissions", "Effect": "Allow", "Action": ["kms:Decrypt", "kms:DescribeKey"], "Resource": "*",
  "Condition": { "StringLike": { "kms:ViaService": "s3.*.amazonaws.com" } } }
```

`AWSBackupServiceRolePolicyForS3Restore` v2 [N9]:

```json
{ "Effect": "Allow", "Action": ["kms:DescribeKey", "kms:GenerateDataKey", "kms:Decrypt"], "Resource": "*",
  "Condition": { "StringLike": { "kms:ViaService": "s3.*.amazonaws.com" } } }
```

- S3: "Start with AWSBackupServiceRolePolicyForS3Backup", "Start with AWSBackupServiceRolePolicyForS3Restore" [N10]. Backup đọc object SSE-KMS:
  "AWS Backup calls `kms:Decrypt` against the source KMS key" [N11]: `ForS3Backup` đủ; restore vào `uploads` ghi object SSE-KMS:
  `ForS3Restore` có `GenerateDataKey`, `Decrypt` qua S3.
- Trust: `backup.amazonaws.com` với `aws:SourceAccount` = account env (Principal dịch vụ của mọi job, kể cả job của Backup policy).

## §8. Quyền KMS của `uploads`

| Principal | Việc với `uploads` | Action KMS (Resource = ARN key `uploads`) | Nguồn |
| --- | --- | --- | --- |
| video-service | Ký form POST (trình duyệt upload bằng credential của video-service), `HeadObject`, xoá | `kms:GenerateDataKey` | "you need `kms:GenerateDataKey` permissions on the key" để upload [N29]; `HeadObject`, `DeleteObject` không dùng key |
| media-worker (`serve` đọc, bridge Probe đọc bằng quyền người gọi) | `GetObject` | `kms:Decrypt` | "To download an object encrypted with an AWS KMS key, you need `kms:Decrypt`" [N29] |
| Role MediaConvert | Đọc nguồn của job | `kms:Decrypt` | [N29] |
| Role Malware Protection | Đọc object, ghi object kiểm tra, gắn tag | `kms:GenerateDataKey`, `kms:Decrypt` khi `kms:ViaService` = `s3.<region>.amazonaws.com` | Statement `AllowDecryptForMalwareScan` [N31] |
| Role `svp-<env>-backup` | Backup, restore | Theo §7 | [N8], [N9] |

Multipart cần thêm `kms:Decrypt` [N29]; form POST là một request nên video-service không cần. Bucket Key: "the bucket ARN is used as the
encryption context" [N29], "can reduce AWS KMS request costs by up to 99 percent" [N30]: policy không ràng encryption context theo object.

## §9. `xmin` qua restore point-in-time

- RDS: "RDS creates a storage volume snapshot of your DB instance, backing up the entire DB instance" [N23]; "RDS uploads transaction logs for DB
  instances to Amazon S3 every five minutes" [N24]: PITR dựng instance mới từ snapshot volume rồi áp log giao dịch tới thời điểm chọn.
- PostgreSQL: "we can combine a file-system-level backup with backup of the WAL files. If recovery is needed, we restore the file system backup
  and then replay from the backed-up WAL files"; "it is possible to restore the database to its state at any time since your base backup was
  taken" [N28]. `xmin`: "The identity (transaction ID) of the inserting transaction for this row version" [N26]; `t_xmin` là trường "insert XID
  stamp" của `HeapTupleHeaderData`, nằm trong mỗi tuple trên trang [N27].
- Kết luận: bản khôi phục là bản sao trang dữ liệu cộng replay WAL, nên mỗi hàng còn thấy mang đúng `t_xmin` như trên nguồn tại thời điểm đó.
  Một UPDATE tạo bản hàng mới với `xmin` mới [N26], nên đổi rồi trả lại giá trị cũ vẫn đổi digest. Không nguồn nào nói "restore giữ `xmin`"
  thành câu; kết luận suy từ ba cơ chế trên.

## §10. Restore S3

- Metadata [N12]: `DestinationBucketName` (bắt buộc); `ItemsToRestore` "A list of up to five paths of individual objects to restore", mỗi mục là
  S3 URI của object; `EncryptionType` `original` | `SSE-S3` | `SSE-KMS`; `KMSKey` chỉ khi SSE-KMS; `RestoreACLs`;
  `RestoreLatestVersionsUpTo` (mặc định bản mới nhất). Dạng chuỗi của danh sách trong map metadata đối chiếu với output thử sandbox.
- Restore vào chính bucket: "AWS Backup does not perform a destructive restore"; "A delete marker in the current version is treated as the object
  as nonexistent, so a restore can occur"; bucket đích phải bật versioning; "If ACLs were enabled during the backup, the destination bucket for
  the restore must have ACLs enabled; otherwise, the restore job fails" [N12]. Bucket của module `media` là `BucketOwnerEnforced` (ACL tắt), nên
  `RestoreACLs` `false`; thử sandbox với bucket cùng cấu hình xác nhận.
- ETag: "You may also restore all backed-up data and metadata except original creation date, version ID, storage class, and e-tags" [N11].
- Mất bucket: AWS không công bố tốc độ restore S3; phía S3 nhận "at least 3,500 PUT/COPY/POST/DELETE ... requests per second per partitioned
  Amazon S3 prefix" [N40]. Lab mỗi env dưới 10⁴ object (seed 32 video, smoke, đo 5 clip; mỗi clip 60 s ~50 object HLS): ngay cả ở 10 object mỗi
  giây là ~17 phút cộng thời gian dựng job đo ở **Diễn tập object S3**; ước dưới 60 phút, chưa đo.

## §12. DR đa region và chi phí

| Phương án | Thêm gì | Chi phí lab (USD mỗi tháng) | Khôi phục khi mất `ap-southeast-1` |
| --- | --- | --- | --- |
| **Ngoài phạm vi** | — | 0 | Không dữ liệu; env dựng trống từ IaC ở region khác |
| AWS Backup copy thêm sang `us-east-1` (SCP `deny-other-regions` đã cho) | Vault, CMK ở `us-east-1`, `copy_actions` thứ hai mỗi policy | CMK 1 + lưu như bản copy ~1,3 + chuyển ~1,5 GB × 4 buổi × 0,09 = 0,54: ~2,8 | Dựng env ở `us-east-1` (IaC chỉ cho `ap-southeast-1`: endpoint, ACM, quota, AMI, zone), copy rồi restore: giờ tới ngày |
| S3 CRR cùng RDS cross-Region automated backups | Replication rule, key ở region đích, role replication | Lưu, chuyển liên tục, request replication (chưa ước) | Dữ liệu tới phút; vẫn dựng env: giờ |
| Pilot light, warm standby | Hạ tầng chạy sẵn ở region thứ hai | Hàng chục tới hàng trăm (EKS, RDS, MSK sống) | Phút tới giờ [N42] |

Phí chuyển sang region khác: `APS1-USE1-CrossRegion-WarmBytes-S3` $0,09 mỗi GB [N37]. Cái giá chấp nhận: mất region là mất dữ liệu từ lần
backup cuối; lab không có dữ liệu thật và env sống theo buổi.

## Chi phí

### Bảng giá

| Mục | Giá (USD) | Nguồn |
| --- | --- | --- |
| AWS Backup, lưu warm S3 | 0,06 mỗi GB-tháng (`APS1-WarmStorage-ByteHrs-S3`) | [N37] |
| Snapshot RDS (recovery point RDS là snapshot RDS) | 0,095 mỗi GB-tháng; phần bằng dung lượng đã cấp miễn phí ở account có instance | Phụ lục [0048](0048-prd-aws.md) (AmazonRDS `index.csv`, đọc 2026-11-05); Price List `AWSBackup` không có dòng RDS [N37] |
| Restore S3 từ warm, restore một phần | 0,024 mỗi GB (`APS1-Restore-WarmBytes-S3`, `APS1-PartialRestore-Warm-S3`) | [N37] |
| Request GET, LIST của backup S3 | 0,0000024 mỗi GET, 0,000024 mỗi LIST | [N37] |
| Copy chéo account cùng region | Lưu trữ tính ở account đích; Price List không có dòng phí chuyển chéo account cùng region | [N39], [N37] |
| KMS CMK | 1 mỗi key-tháng, theo giờ; key chờ xoá không tính | [N38] |
| KMS request | 0,03 mỗi 10 000; 20 000 đầu mỗi tháng miễn phí | [N38] |
| RDS single-AZ | `db.t4g.small` 0,051, `db.m7g.large` 0,234 mỗi giờ | Phụ lục [0057](0057-postgres17-verify-full.md) |
| gp3 của RDS | 0,138 mỗi GB-tháng | Phụ lục [0034](0034-aws-stage7.md) |
| Item Config, check Security Hub | 0,003 mỗi item; 0,001 mỗi check | Phụ lục [0060](0060-org-detection-logging.md) |

### Sống giữa buổi

Giả định: một buổi mỗi tuần mỗi env; mỗi buổi một recovery point on-demand mỗi tài nguyên, cộng một của lịch nếu env sống qua 18:00 UTC; snapshot
RDS ≤ 1 GB (database lab vài trăm MB cộng WAL); hai bucket ≤ 0,5 GB (clip đo, smoke, seed và HLS). Env mới mỗi buổi nên mỗi bản copy là đầy đủ.

| Khoản | Cách tính | USD mỗi tháng |
| --- | --- | --- |
| Ba CMK (`svp-backup-copy`, `svp-stg-backup`, `svp-prd-backup`) | 3 × 1 | 3,00 |
| Bản copy prd (35 ngày: ≤ 10 recovery point mỗi tài nguyên) | 10 × (1 × 0,095 + 0,5 × 0,06) | 1,25 |
| Bản copy stg (2 ngày: ≤ 2 recovery point, sống ~2/7 thời gian) | 2 × (0,095 + 0,03) × 2/7 | 0,07 |
| Item Config của recovery point, job | ~30 × 0,003 | 0,09 |
| KMS request | Trong 20 000 miễn phí | 0 |
| **Cộng (Chi phí R6, sống giữa buổi)** | | **~4,4** |
| Baseline `svp-backup` (ngoài trần, cộng vào 0060 §12) | Security Hub ~1 800 check × 0,001 + Config ~100 item × 0,003 + GuardDuty ~0,05 | ~2,2 |

Trần $5 mỗi tháng cho ba CMK và bản copy: đạt. Khoản lớn nhất là ba CMK.

### Mỗi buổi

| Khoản | stg | prd |
| --- | --- | --- |
| Instance `svp-<env>-pitr` ~1 giờ | 0,051 | 0,234 |
| gp3 20 GB của instance PITR ~1 giờ | 0,004 | 0,004 |
| Recovery point ở vault env vài giờ | < 0,001 | < 0,001 |
| Request GET, LIST của backup S3 (~1 000 object) | 0,003 | 0,003 |
| Restore item-level (< 1 MB) | ~0 | ~0 |
| Key `uploads` 4 giờ (chờ xoá không tính) | 0,005 | 0,005 |
| Hai alarm 4 giờ | < 0,01 | < 0,01 |
| Item Config (key, alarm, recovery point, job, instance PITR) ~20 | 0,06 | 0,06 |
| Check Security Hub theo thay đổi ~20 | 0,02 | 0,02 |
| **Cộng** | **~0,15** | **~0,34** |

Trần mỗi buổi $2 ở stg, $3 ở prd: đạt. Khoản lớn nhất là giờ instance PITR.

## Control FSBP

Control Security Hub CSPM áp lên tài nguyên mới; "FSBP" là có trong AWS Foundational Security Best Practices [N34]; org bật FSBP và CIS v5.0.0
(0060 §3), control ngoài hai chuẩn này không chạy.

| Control | Tiêu đề (tóm tắt) | FSBP | Kết quả | Lý do |
| --- | --- | --- | --- | --- |
| Backup.1 | Recovery point mã hoá at rest | có | Đạt | S3 bằng key vault; snapshot RDS bằng key RDS; bản copy bằng key vault đích |
| Backup.2, .3, .5 | Recovery point, vault, plan có tag | không | Không chạy | Chuẩn Resource Tagging không bật; vault, key có `default_tags` |
| KMS.1 | Policy customer managed không cho decrypt mọi key | có | Đạt | Policy run viết ghi ARN key; managed policy của AWS không phải customer managed |
| KMS.2 | Inline không cho decrypt mọi key | có | Đạt | Inline của video-service, media-worker, MediaConvert, Malware Protection ghi ARN key; role Backup không inline |
| KMS.3 | Key không bị xoá ngoài ý muốn | có | Đạt ở key vault; key `uploads` lên lịch xoá cuối buổi | Key theo buổi như key RDS: finding tới khi key xoá xong, chấp nhận |
| KMS.4 | Rotation | không (CIS) | Đạt | Rotation bật ở mọi key mới |
| KMS.5 | Key không public | có | Đạt | Principal chéo account là một account cụ thể |
| S3.5 | Chỉ TLS | có | Đạt | Bucket policy có sẵn |
| S3.17 | Bucket mã hoá KMS | không | Không chạy | `uploads` SSE-KMS; `media` SSE-S3 (ADR §8) |
| S3.7 | Cross-Region replication | không | Không chạy | Mất region ngoài phạm vi (ADR §12) |
| RDS.11 | Backup tự động bật, ≥ 7 ngày | có | prd đạt; stg như trước (1 ngày, 0055 §3) | Không đổi |
| RDS.26 | Instance có backup plan | không | Không chạy | Instance có plan qua Backup policy |
| IAM.1, IAM.21 | Không `*` quản trị, không wildcard action theo dịch vụ | có | Đạt | Không `kms:*`, `backup:*` trong policy run viết |
| CloudWatch.15 | Alarm có action | không | Đạt | Alarm gửi topic của module `alarms` |

## Luồng SCP, RCP

Đối chiếu SCP và RCP `svp-data-perimeter` của [0059](../0059-org-structure-guardrails.md) (`aws/modules/org-policies/main.tf`). RCP phủ S3, SQS,
KMS, Secrets Manager, STS; AWS Backup, RDS ngoài phạm vi RCP. Mọi tài nguyên ở `ap-southeast-1` (trong `deny-other-regions`); IAM,
Organizations là action toàn cục. SCP, RCP không áp lên management.

| Luồng | Principal | Tài nguyên | Qua nhờ |
| --- | --- | --- | --- |
| Backup policy, trusted access, global settings, opt-in ở management | Management | Organizations, Backup | SCP, RCP không áp management |
| Terraform tạo vault, lock, access policy, key ở `svp-backup` | `OrganizationAccountAccessRole` | Backup, KMS | `protect-baseline` không phủ Backup; key không tag `Stack=security-baseline`, alias khác `svp-ebs` |
| Terraform tạo vault env, key, role, opt-in; key `uploads`, alarm | `SvpAdmin` của env | Backup, KMS, IAM, CloudWatch | Role tên `svp-<env>-backup` không khớp `svp-security-*` |
| AWS Backup assume role `svp-<env>-backup` | `backup.amazonaws.com` | STS của account env | `EnforceConfusedDeputyProtection`: `aws:SourceOrgID` của account env khớp org |
| Backup đọc RDS, S3, giải mã object `uploads` qua S3 | Role `svp-<env>-backup` | RDS, S3, KMS của env | `EnforceOrgIdentities`: principal trong org; TLS |
| Copy job vào `svp-<env>-copy` | Role `svp-<env>-backup` | Vault của `svp-backup` | Backup ngoài RCP; vault access policy cho account env |
| Copy RDS: `svp-backup` dùng key RDS, key vault env | Principal, dịch vụ của `svp-backup` | KMS của account env | Principal trong org; dịch vụ thay account trong org (`aws:SourceOrgID` khớp) |
| Mã hoá bản copy bằng `alias/svp-backup-copy` | Dịch vụ trong `svp-backup` | KMS của `svp-backup` | Cùng account, trong org |
| Restore item-level vào bucket media | Role `svp-<env>-backup` | S3 | Principal trong org; TLS |
| PITR, xoá `svp-<env>-pitr`, xoá recovery point vault env | `SvpAdmin` | RDS, Backup, KMS qua RDS | RDS, Backup ngoài RCP; KMS với principal trong org |
| Gỡ tag `Backup` (**Xoá cuối buổi**) | `SvpAdmin` | RDS, S3 bucket tagging | S3 principal trong org, TLS; tag policy không chặn gỡ tag (0059 §6) |
| Ghi object kiểm tra, quét `uploads` | Role Malware Protection | S3, KMS | Principal trong org |
| SCP của OU `Security` lên `svp-backup` | — | — | OU không có SCP riêng; năm SCP gắn root áp như `svp-log-archive`; không bước nào tạo IAM user |

Không luồng nào bị chặn; **Backup policy** không cần sửa.

## Nguồn

- [N1] AWS Backup, Creating backup copies across AWS accounts:
  <https://docs.aws.amazon.com/aws-backup/latest/devguide/create-cross-account-backup.html>
- [N2] AWS Backup, Encryption for backups in AWS Backup: <https://docs.aws.amazon.com/aws-backup/latest/devguide/encryption.html>
- [N3] AWS Backup, Managing AWS Backup resources across multiple AWS accounts:
  <https://docs.aws.amazon.com/aws-backup/latest/devguide/manage-cross-account.html>
- [N4] AWS Organizations, Backup policy syntax and examples:
  <https://docs.aws.amazon.com/organizations/latest/userguide/orgs_manage_policies_backup_syntax.html>
- [N5] AWS Organizations, Backup policies: <https://docs.aws.amazon.com/organizations/latest/userguide/orgs_manage_policies_backup.html>
- [N6] AWSBackupServiceRolePolicyForBackup (v30):
  <https://docs.aws.amazon.com/aws-managed-policy/latest/reference/AWSBackupServiceRolePolicyForBackup.html>
- [N7] AWSBackupServiceRolePolicyForRestores (v36):
  <https://docs.aws.amazon.com/aws-managed-policy/latest/reference/AWSBackupServiceRolePolicyForRestores.html>
- [N8] AWSBackupServiceRolePolicyForS3Backup (v5):
  <https://docs.aws.amazon.com/aws-managed-policy/latest/reference/AWSBackupServiceRolePolicyForS3Backup.html>
- [N9] AWSBackupServiceRolePolicyForS3Restore (v2):
  <https://docs.aws.amazon.com/aws-managed-policy/latest/reference/AWSBackupServiceRolePolicyForS3Restore.html>
- [N10] AWS Backup, Managed policies for AWS Backup:
  <https://docs.aws.amazon.com/aws-backup/latest/devguide/security-iam-awsmanpol.html>
- [N11] AWS Backup, Amazon S3 backups: <https://docs.aws.amazon.com/aws-backup/latest/devguide/s3-backups.html>
- [N12] AWS Backup, Restore S3 data: <https://docs.aws.amazon.com/aws-backup/latest/devguide/restoring-s3.html>
- [N13] AWS Backup, Getting started (Service Opt-in): <https://docs.aws.amazon.com/aws-backup/latest/devguide/getting-started.html>
- [N14] AWS Backup API, UpdateRegionSettings: <https://docs.aws.amazon.com/aws-backup/latest/devguide/API_UpdateRegionSettings.html>
- [N15] AWS Backup, Feature availability (Supported services by AWS Region):
  <https://docs.aws.amazon.com/aws-backup/latest/devguide/backup-feature-availability.html>
- [N16] AWS Backup, Monitoring AWS Backup metrics with CloudWatch: <https://docs.aws.amazon.com/aws-backup/latest/devguide/cloudwatch.html>
- [N17] AWS Backup Vault Lock: <https://docs.aws.amazon.com/aws-backup/latest/devguide/vault-lock.html>
- [N18] AWS Backup, Vault access policies: <https://docs.aws.amazon.com/aws-backup/latest/devguide/create-a-vault-access-policy.html>
- [N19] AWS Backup, Continuous backups and point-in-time recovery:
  <https://docs.aws.amazon.com/aws-backup/latest/devguide/point-in-time-recovery.html>
- [N20] AWS Backup, Backup plan options and configuration:
  <https://docs.aws.amazon.com/aws-backup/latest/devguide/plan-options-and-configuration.html>
- [N21] AWS Backup, Amazon RDS backups: <https://docs.aws.amazon.com/aws-backup/latest/devguide/rds-backup.html>
- [N22] AWS Backup, Feature availability by resource:
  <https://docs.aws.amazon.com/aws-backup/latest/devguide/backup-feature-availability.html>
- [N23] Amazon RDS, Introduction to backups:
  <https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/USER_WorkingWithAutomatedBackups.html>
- [N24] Amazon RDS, Restoring a DB instance to a specified time: <https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/USER_PIT.html>
- [N25] Amazon RDS, Sharing encrypted snapshots: <https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/share-encrypted-snapshot.html>
- [N26] PostgreSQL 17, System Columns: <https://www.postgresql.org/docs/17/ddl-system-columns.html>
- [N27] PostgreSQL 17, Database Page Layout: <https://www.postgresql.org/docs/17/storage-page-layout.html>
- [N28] PostgreSQL 17, Continuous Archiving and Point-in-Time Recovery: <https://www.postgresql.org/docs/17/continuous-archiving.html>
- [N29] Amazon S3, Using server-side encryption with AWS KMS keys (SSE-KMS):
  <https://docs.aws.amazon.com/AmazonS3/latest/userguide/UsingKMSEncryption.html>
- [N30] Amazon S3, Reducing the cost of SSE-KMS with Amazon S3 Bucket Keys:
  <https://docs.aws.amazon.com/AmazonS3/latest/userguide/bucket-key.html>
- [N31] GuardDuty, Malware Protection for S3 IAM role policy:
  <https://docs.aws.amazon.com/guardduty/latest/ug/malware-protection-s3-iam-policy-prerequisite.html>
- [N32] ViewOnlyAccess (v48): <https://docs.aws.amazon.com/aws-managed-policy/latest/reference/ViewOnlyAccess.html>
- [N33] SecurityAudit (v94): <https://docs.aws.amazon.com/aws-managed-policy/latest/reference/SecurityAudit.html>
- [N34] Security Hub CSPM, AWS Foundational Security Best Practices standard:
  <https://docs.aws.amazon.com/securityhub/latest/userguide/fsbp-standard.html>
- [N35] Security Hub CSPM, AWS Backup controls: <https://docs.aws.amazon.com/securityhub/latest/userguide/backup-controls.html>
- [N36] Security Hub CSPM, AWS KMS controls: <https://docs.aws.amazon.com/securityhub/latest/userguide/kms-controls.html>
- [N37] AWS Price List API, `AWSBackup` `ap-southeast-1` (phát hành 2026-11-12):
  <https://pricing.us-east-1.amazonaws.com/offers/v1.0/aws/AWSBackup/current/ap-southeast-1/index.json>
- [N38] AWS KMS pricing: <https://aws.amazon.com/kms/pricing/>
- [N39] AWS Backup pricing: <https://aws.amazon.com/backup/pricing/>
- [N40] Amazon S3, Best practices design patterns: optimizing performance:
  <https://docs.aws.amazon.com/AmazonS3/latest/userguide/optimizing-performance.html>
- [N41] AWS Control Tower, AWS Backup in AWS Control Tower và tài nguyên của nó:
  <https://docs.aws.amazon.com/controltower/latest/userguide/backup.html>,
  <https://docs.aws.amazon.com/controltower/latest/userguide/backup-resources.html>
- [N42] AWS Whitepaper, Disaster recovery options in the cloud:
  <https://docs.aws.amazon.com/whitepapers/latest/disaster-recovery-workloads-on-aws/disaster-recovery-options-in-the-cloud.html>
- [N43] AWS Backup API, BackupPlansListMember: <https://docs.aws.amazon.com/aws-backup/latest/devguide/API_BackupPlansListMember.html>
- [N44] Amazon CloudWatch, Alarms on Metrics Insights queries và ngữ pháp truy vấn:
  <https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/cloudwatch-metrics-insights-alarms.html>,
  <https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/cloudwatch-metrics-insights-querylanguage.html>
- [N45] terraform-provider-aws, acceptance test của `aws_backup_region_settings` (khoá `resource_type_opt_in_preference` API trả):
  <https://github.com/hashicorp/terraform-provider-aws/blob/main/internal/service/backup/region_settings_test.go>
