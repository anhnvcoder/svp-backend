# Phụ lục ADR-0060: Phát hiện liên tục toàn org do account Security Tooling quản (GuardDuty, Security Hub CSPM cấu hình tập trung với FSBP và CIS v5.0.0, AWS Config ghi liên tục, IAM Access Analyzer); log của org về account Log Archive; sự kiện bảo mật và finding nghiêm trọng qua EventBridge tới SNS email; Cost Anomaly Detection và tag phân bổ chi phí trong code

Phụ lục của [ADR-0060](../0060-org-detection-logging.md): phương án, cấu hình dịch vụ, bucket, event pattern, bảng giá và nguồn, xếp theo §.
Mọi nguồn đọc ngày 2026-11-12. Đường dẫn `aws/...`, `docs/...` không kèm repo là của `svp-infra`; `<log>`, `<sec>`, `<prd>`, `<stg>`, `<mgmt>` là
id account `svp-log-archive`, `svp-security`, `svp-prd`, `svp-stg`, management; `<org-id>` là id org.

## Phương án

| Phương án | Trạng thái ngành | Được | Mất | Nguồn |
| --- | --- | --- | --- | --- |
| **GuardDuty, Security Hub CSPM cấu hình tập trung, Config `CONTINUOUS`, Access Analyzer; delegated admin Security Tooling; EventBridge → SNS** | Hiện hành, khuôn SRA | Dịch vụ gốc, Terraform quản; finding gom một chỗ; cảnh báo sống ngoài cluster | Phí theo check, item, event kể cả khi không buổi | [N1], [N5] |
| Security Hub bản hợp nhất thay CSPM | Mới; AWS khuyên bật cùng CSPM | Tương quan finding, gói Essentials tính theo tài nguyên, gộp phí CSPM | Thêm dịch vụ mới; lab chưa cần tương quan; phí theo tài nguyên chưa đo được | [N9] |
| Config ghi hằng ngày (periodic) | Hiện hành, cách giảm phí cho loại đổi nhiều | Giá mỗi item ghi theo ngày cao hơn nhưng ít item | Chỉ ghi trạng thái mới nhất mỗi 24 giờ nếu khác item trước: tài nguyên sống vài giờ có thể không có item, control đổi theo thay đổi không đánh giá chúng | [N3] |
| Thêm conformance pack CIS | Hiện hành | Đánh giá CIS cả khi không Security Hub | Trùng chuẩn CIS v5.0.0 của Security Hub; $0,001 mỗi lần đánh giá pack | [N6], [N25] |
| Metric filter CloudWatch trên log group của trail (CIS v1.2.0, v1.4.0; Security Hub CloudWatch.x) | Cũ hơn EventBridge | Một chỗ đọc log | Trail ghi thêm vào CloudWatch Logs (phí ingest); thêm alarm mỗi filter | [N2] |

## §1. Delegated admin và region

Trusted access và delegated admin (ở `aws/org`):

| Dịch vụ | Service principal trusted access | Delegated admin |
| --- | --- | --- |
| GuardDuty | `guardduty.amazonaws.com` (thêm `malware-protection.guardduty.amazonaws.com` nếu tài liệu GuardDuty đòi khi áp) | `svp-security`, mỗi region `ap-southeast-1`, `us-east-1` |
| Security Hub | `securityhub.amazonaws.com` | `svp-security` |
| Config | `config.amazonaws.com`, `config-multiaccountsetup.amazonaws.com` | `svp-security` |
| IAM Access Analyzer | `access-analyzer.amazonaws.com` | `svp-security` |
| Account Management (liên hệ SECURITY, ADR-0059 §11) | `account.amazonaws.com` | — |
| IAM (root tập trung, ADR-0059 §7) | `iam.amazonaws.com` | — |

Giữ `cloudtrail.amazonaws.com`, `sso.amazonaws.com` có sẵn.

## §2. GuardDuty

| Cấu hình tổ chức | Giá trị |
| --- | --- |
| `auto_enable_organization_members` | `ALL` (account có sẵn và account mới; delegated admin thêm management làm thành viên) |
| `S3_DATA_EVENTS`, `EKS_AUDIT_LOGS`, `RDS_LOGIN_EVENTS`, `LAMBDA_NETWORK_LOGS`, `EBS_MALWARE_PROTECTION` | `ALL` |
| `RUNTIME_MONITORING` | `ALL`; additional configuration `EKS_ADDON_MANAGEMENT`, `ECS_FARGATE_AGENT_MANAGEMENT`, `EC2_AGENT_MANAGEMENT` = `NONE` |
| Tần suất xuất finding cập nhật | Mặc định 6 giờ (finding mới xuất ngay) |
| Publishing destination | Detector `svp-security` ở hai region → `svp-guardduty-<log>-ap-southeast-1`, key `alias/svp-log-archive` region nhà (ARN `key/<id>`) |

Tài liệu GuardDuty: tự bật cho mọi protection plan trừ Malware Protection for S3 [N14]; "For the findings generated in a commercial Region,
you can choose to export these findings to an S3 bucket in any commercial Region"; "The AWS Region of your KMS key and the Amazon S3 bucket
must be the same"; xuất được về bucket ở account khác [N4]. Bucket policy và key policy cho `guardduty.amazonaws.com` với `aws:SourceAccount` =
`<sec>`, `aws:SourceArn` là detector của hai region [N4]. Thư mục tiền tố (nếu dùng) phải có sẵn trong bucket [N4].

## §3. Security Hub CSPM

- Cấu hình tập trung: delegated admin `svp-security`, region nhà `ap-southeast-1`, finding aggregator `SPECIFIED_REGIONS` gom `us-east-1` [N5].
- Configuration policy `svp-security-standards` gắn root: Security Hub bật; chuẩn `aws-foundational-security-best-practices/v/1.0.0` và
  `cis-aws-foundations-benchmark/v/5.0.0` [N6]; control mới tự bật; tắt GuardDuty.7, GuardDuty.12, GuardDuty.13.
- Lý do tắt: GuardDuty.7 "checks whether GuardDuty EKS Runtime Monitoring with automated agent management is enabled"; GuardDuty.12, GuardDuty.13
  kiểm agent tự động cho ECS Fargate, EC2 [N7]. Runtime Monitoring EKS vẫn bật với agent quản trong Terraform; không ECS; EC2 ngoài EKS chỉ là
  bastion. GuardDuty.11 (Runtime Monitoring bật) giữ.
- Control của FSBP và CIS dùng chung một rule Config chỉ tính một lần mỗi check; control tắt không chạy check, không tính tiền [N8].
- Check periodic chạy "within 12 or 24 hours after the most recent run"; check theo thay đổi chạy khi tài nguyên đổi, và Security Hub kiểm ít nhất
  24 giờ một lần để không sót cập nhật từ Config [N8].

## §4. Config và Access Analyzer

### Config

- Recorder `default` mỗi account mỗi region: mọi loại tài nguyên hỗ trợ, `recording_mode` `CONTINUOUS`; loại toàn cục (IAM) chỉ ở `ap-southeast-1`
  ("we recommend recording global resources in a single Region only", region nhà của cấu hình tập trung [N10]); service-linked role
  `AWSServiceRoleForConfig` (chưa có ở account nào: Terraform tạo).
- Delivery channel của hai region → `svp-config-<log>-ap-southeast-1`, `s3_kms_key_arn` = ARN `key/<id>` của key region nhà, snapshot `TwentyFour_Hours`.
  SLR của Config không ghi được object: Config giao bằng principal `config.amazonaws.com` [N26]. Giao từ recorder `us-east-1` vào bucket region
  nhà là giả định (tài liệu đọc được không nói về region của bucket); kiểm bằng `describe-delivery-channel-status` ở `us-east-1` sau áp.
- Aggregator `svp-org` ở `svp-security`: nguồn tổ chức, mọi region (trivy AWS-0019; recorder chỉ chạy ở hai region), role với managed policy `AWSConfigRoleForOrganizations`.
- Daily recording: "receive a configuration item (CI) representing the most recent state of your resources over the last 24-hour period, only
  if it's different from the previous CI recorded" [N3].

### Access Analyzer

Analyzer `svp-org` loại `ORGANIZATION` ở `svp-security`, mỗi region `ap-southeast-1`, `us-east-1`; truy cập ngoài không tính phí [N11].

## §5. Agent GuardDuty EKS

Endpoint policy theo tài liệu [N12]:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    { "Action": "*", "Resource": "*", "Effect": "Allow", "Principal": "*" },
    { "Condition": { "StringNotEquals": { "aws:PrincipalAccount": "<account của env>" } },
      "Action": "*", "Resource": "*", "Effect": "Deny", "Principal": "*" }
  ]
}
```

Security group của endpoint: inbound TCP 443 từ CIDR VPC ("in-bound port 443 enabled from your VPC" [N12]). Add-on `aws-guardduty-agent` có sau
endpoint.

## §6. Malware Protection for S3

Role của plan: trust `malware-protection-plan.guardduty.amazonaws.com` (`sts:AssumeRole`); quyền: `events:PutRule`, `DeleteRule`, `PutTargets`,
`RemoveTargets`, `DescribeRule`, `ListTargetsByRule` trên rule do GuardDuty quản; `s3:PutBucketNotification`, `GetBucketNotification`;
`s3:GetObject`, `GetObjectVersion`, `ListBucket`; gắn tag object; `kms:GenerateDataKey`, `kms:Decrypt` khi bucket SSE-KMS [N13]. Free tier: 1 000
request và 1 GB mỗi tháng mỗi region [N25].

## §7. Bucket Log Archive

| Bucket | Nội dung | Mã hoá | Object Lock | Retention |
| --- | --- | --- | --- | --- |
| `svp-cloudtrail-<log>-ap-southeast-1` | Trail org (`AWSLogs/<mgmt>/`, `AWSLogs/<org-id>/`) | SSE-KMS key region nhà | Governance 365 ngày | 365 ngày; Glacier Instant Retrieval sau 90 |
| `svp-cloudtrail-access-<log>-ap-southeast-1` | Server access log của bucket trail | SSE-S3 | — | 365 ngày |
| `svp-config-<log>-ap-southeast-1` | Lịch sử, snapshot Config mọi account, hai region | SSE-KMS key region nhà | — | 365 ngày; Glacier Instant Retrieval sau 90 |
| `svp-flowlogs-<log>-ap-southeast-1` | Flow log VPC stg, prd | SSE-KMS key region nhà | — | prd 90 ngày; stg 7 ngày (tiền tố `AWSLogs/aws-account-id=<stg>/`) |
| `svp-guardduty-<log>-ap-southeast-1` | Finding GuardDuty xuất | SSE-KMS key region nhà | — | 365 ngày; Glacier Instant Retrieval sau 90 |
| `aws-waf-logs-svp-<log>-us-east-1` | Log WAF stg, prd | SSE-KMS key `us-east-1` | — | prd 90 ngày; stg 7 ngày (tiền tố `AWSLogs/<stg>/`) |

- Mọi bucket: version cũ hết hạn sau 1 ngày, multipart dở hủy sau 1 ngày (như bucket trail hiện có ở `aws/org/audit-trail.tf`).
- 365 ngày: PCI DSS v4 10.5.1 (ít nhất 12 tháng), như trail hiện có. 90 ngày cho log mạng của prd: đủ một quý điều tra; stg 7 ngày: env sống vài
  giờ, đủ đọc lại sau buổi ([0055](../0055-environment-matrix.md) §3, retention được giảm).
- Bucket policy (cùng điều kiện TLS `aws:SecureTransport`):

| Principal | Bucket | Hành động | Điều kiện |
| --- | --- | --- | --- |
| `cloudtrail.amazonaws.com` | trail | `s3:GetBucketAcl`; `s3:PutObject` trên `AWSLogs/<mgmt>/*`, `AWSLogs/<org-id>/*` | `aws:SourceArn` = trail `svp-audit` của management; `s3:x-amz-acl` = `bucket-owner-full-control` [N17] |
| `logging.s3.amazonaws.com` | trail-access | `s3:PutObject` | `aws:SourceArn` = bucket trail, `aws:SourceAccount` = `<log>` [N16] |
| `config.amazonaws.com` | config | `s3:GetBucketAcl`, `s3:ListBucket`; `s3:PutObject` trên `AWSLogs/*` | `aws:SourceOrgID` = `<org-id>`; `s3:x-amz-acl` = `bucket-owner-full-control` [N26] |
| `delivery.logs.amazonaws.com` | flowlogs, WAF | `s3:GetBucketAcl`, `s3:ListBucket`; `s3:PutObject` trên `AWSLogs/*` | `aws:SourceOrgID` = `<org-id>`; `s3:x-amz-acl` = `bucket-owner-full-control` [N18], [N15] |
| `guardduty.amazonaws.com` | guardduty | `s3:GetBucketLocation`, `s3:PutObject` | `aws:SourceAccount` = `<sec>`, `aws:SourceArn` = detector hai region [N4] |

  Mẫu của tài liệu flow log, WAF, Config dùng `aws:SourceAccount` (danh sách account) và `aws:SourceArn`; ở đây dùng `aws:SourceOrgID` để
  không phải liệt kê account. Lần giao đầu tiên của mỗi loại sau áp xác nhận điều kiện đó.

- Key policy (ngoài statement `kms:*` cho IAM của `<log>`):

| Key | Principal | Hành động | Điều kiện |
| --- | --- | --- | --- |
| Region nhà | `cloudtrail.amazonaws.com` | `kms:GenerateDataKey*`, `kms:DescribeKey` | `aws:SourceArn` = trail; `StringLike` `kms:EncryptionContext:aws:cloudtrail:arn` = `arn:aws:cloudtrail:*:<mgmt>:trail/*` [N17] |
| Region nhà | `config.amazonaws.com` | `kms:GenerateDataKey`, `kms:Decrypt` | `aws:SourceOrgID` = `<org-id>` |
| Region nhà | `delivery.logs.amazonaws.com` | `kms:Encrypt`, `kms:Decrypt`, `kms:ReEncrypt*`, `kms:GenerateDataKey*`, `kms:DescribeKey` | `aws:SourceOrgID` = `<org-id>` [N18] |
| Region nhà | `guardduty.amazonaws.com` | `kms:GenerateDataKey` | `aws:SourceAccount` = `<sec>`, `aws:SourceArn` = detector hai region [N4] |
| `us-east-1` | `delivery.logs.amazonaws.com` | `kms:GenerateDataKey*` (tài liệu WAF), cộng như dòng flow log | `aws:SourceOrgID` = `<org-id>` [N15] |

## §8. Trail org

Advanced event selector của `svp-audit`:

| Tên | Trường |
| --- | --- |
| `management` | `eventCategory` = `Management` (đọc và ghi) |
| `prd-uploads` | `eventCategory` = `Data`, `resources.type` = `AWS::S3::Object`, `resources.ARN` bắt đầu `arn:aws:s3:::svp-prd-uploads-<prd>-ap-southeast-1/` |
| `prd-media-writes` | `eventCategory` = `Data`, `resources.type` = `AWS::S3::Object`, `readOnly` = `false`, `resources.ARN` bắt đầu `arn:aws:s3:::svp-prd-media-<prd>-ap-southeast-1/` |

## §10. Đường cảnh báo

### Rule theo account và region

Mọi rule trên bus mặc định, đích bus `arn:aws:events:ap-southeast-1:<sec>:event-bus/svp-security-events` qua role `svp-security-forwarder` của
account (trust `events.amazonaws.com` với `aws:SourceAccount` = account; quyền `events:PutEvents` trên bus đó). `state` `ENABLED` trừ dòng ghi khác.

| Rule | Account | Region |
| --- | --- | --- |
| `svp-security-root-signin` | Mọi account | `us-east-1`; management thêm `us-east-2`, `us-west-2` |
| `svp-security-root-session` (`ENABLED_WITH_ALL_CLOUDTRAIL_MANAGEMENT_EVENTS`) | Management | `ap-southeast-1`, `us-east-1` |
| `svp-security-org` | Management | `us-east-1` |
| `svp-security-trail` | Mọi account | `ap-southeast-1`, `us-east-1` |
| `svp-security-detection` | Mọi account | `ap-southeast-1`, `us-east-1` |
| `svp-security-alert-rules` | Mọi account | `ap-southeast-1`, `us-east-1` |
| `svp-security-denied-iam` | Mọi account | `us-east-1` (IAM ghi sự kiện ở đó) |
| `svp-security-denied-detection`, `svp-security-denied-storage` | Mọi account | `ap-southeast-1`, `us-east-1` |
| `svp-security-admin-iam`, `svp-security-admin-sso` | Management, `svp-log-archive`, `svp-security` (`admin-sso` chỉ management) | `us-east-1` (`admin-sso`: region của Identity Center, tức `sso_region` của `aws/org`, truyền vào `aws/baseline` làm dữ liệu) |
| `svp-security-admin-kms-s3` | Management, `svp-log-archive`, `svp-security` | `ap-southeast-1`, `us-east-1` |
| `svp-security-notify` (trên bus `svp-security-events`) | `svp-security` | `ap-southeast-1`: khớp mọi sự kiện (`{"source": [{"prefix": ""}]}`) → SNS |
| `svp-security-findings` (bus mặc định) | `svp-security` | `ap-southeast-1` (region aggregator) → SNS |

- Rule `svp-security-root-signin` ở `us-east-2`, `us-west-2` chỉ ở management: `svp-deny-other-regions` chặn account thành viên tạo rule ở đó, và
  root thành viên chỉ có mật khẩu sau `IAMCreateRootUserPassword` (bắt bởi `svp-security-root-session`).
- `svp-security-alert-rules`, `svp-security-trail` khớp cả lệnh thành công và bị từ chối; nhóm `denied-*` không lặp lại chúng để mỗi lệnh một email.
- `svp-security-admin-sso` chỉ bắn ở region của Identity Center (CloudTrail ghi sự kiện `sso.amazonaws.com` ở đó): region đặt sai thì rule im
  lặng, nên phép kiểm sau áp đối chiếu region của rule với region của instance Identity Center.
- `svp-security-root-session` chỉ ở hai region: STS không nhận `AssumeRoot` ở endpoint toàn cục, chỉ ở endpoint region [N29], mà management
  không chịu `svp-deny-other-regions`. Gọi ở region khác không sinh email; ADR ghi chỗ hở này ở Hệ quả.
- Đích bus ở account khác cần role trên target với target tạo sau 2023-03-02 [N19]; rule ở `us-east-1`, `us-east-2`, `us-west-2` gửi sang bus ở
  `ap-southeast-1` là gửi chéo region [N19].

### Event pattern

`AWS API Call via CloudTrail` dưới đây viết tắt `API`. Lệnh ghi khớp rule `ENABLED`; sự kiện chỉ đọc chỉ khớp rule
`ENABLED_WITH_ALL_CLOUDTRAIL_MANAGEMENT_EVENTS` [N22]. Toán tử `prefix`, `exists`, `$or` theo [N27].

`svp-security-root-signin`:

```json
{ "source": ["aws.signin"], "detail-type": ["AWS Console Sign In via CloudTrail"], "detail": { "userIdentity": { "type": ["Root"] } } }
```

`svp-security-root-session`:

```json
{ "source": ["aws.sts"], "detail-type": ["AWS API Call via CloudTrail"],
  "detail": { "eventSource": ["sts.amazonaws.com"], "eventName": ["AssumeRoot"] } }
```

`svp-security-org`:

```json
{ "detail-type": ["AWS API Call via CloudTrail"],
  "detail": { "eventSource": ["organizations.amazonaws.com", "iam.amazonaws.com"],
    "eventName": ["AttachPolicy", "CreatePolicy", "DeletePolicy", "DetachPolicy", "UpdatePolicy", "EnablePolicyType", "DisablePolicyType",
      "EnableAWSServiceAccess", "DisableAWSServiceAccess", "RegisterDelegatedAdministrator", "DeregisterDelegatedAdministrator",
      "CreateAccount", "CloseAccount", "InviteAccountToOrganization", "RemoveAccountFromOrganization", "MoveAccount",
      "CreateOrganizationalUnit", "DeleteOrganizationalUnit", "EnableOrganizationsRootCredentialsManagement",
      "DisableOrganizationsRootCredentialsManagement", "EnableOrganizationsRootSessions", "DisableOrganizationsRootSessions"] } }
```

(`iam:CreatePolicy`, `DeletePolicy` của IAM cùng tên cũng khớp ở management: chấp nhận, đó là đổi IAM ở management.)

`svp-security-trail`:

```json
{ "detail-type": ["AWS API Call via CloudTrail"],
  "detail": { "eventSource": ["cloudtrail.amazonaws.com"],
    "eventName": ["DeleteTrail", "PutEventSelectors", "PutInsightSelectors", "StopLogging", "UpdateTrail"] } }
```

`svp-security-detection` (thành công: `errorCode` vắng):

```json
{ "detail-type": ["AWS API Call via CloudTrail"],
  "detail": { "eventSource": ["guardduty.amazonaws.com", "securityhub.amazonaws.com", "config.amazonaws.com", "access-analyzer.amazonaws.com"],
    "eventName": ["<mọi hành động của ProtectGuardDuty, ProtectSecurityHub, ProtectConfig, ProtectAccessAnalyzer ở phụ lục ADR-0059 §3>"],
    "errorCode": [{ "exists": false }] } }
```

`svp-security-alert-rules`:

```json
{ "detail-type": ["AWS API Call via CloudTrail"],
  "detail": { "eventSource": ["events.amazonaws.com"],
    "eventName": ["DeleteRule", "DisableRule", "PutRule", "PutTargets", "RemoveTargets"],
    "$or": [ { "requestParameters": { "name": [{ "prefix": "svp-security-" }] } },
             { "requestParameters": { "rule": [{ "prefix": "svp-security-" }] } } ] } }
```

`svp-security-denied-iam`:

```json
{ "detail-type": ["AWS API Call via CloudTrail"],
  "detail": { "eventSource": ["iam.amazonaws.com"],
    "eventName": ["CreateUser", "CreateAccessKey", "CreateLoginProfile", "UpdateLoginProfile", "AttachRolePolicy", "DeleteRole",
      "DeleteRolePermissionsBoundary", "DeleteRolePolicy", "DetachRolePolicy", "PutRolePermissionsBoundary", "PutRolePolicy", "TagRole",
      "UntagRole", "UpdateAssumeRolePolicy", "UpdateRole", "UpdateRoleDescription"],
    "errorCode": [{ "prefix": "AccessDenied" }] } }
```

`svp-security-denied-detection`: cùng `eventSource`, `eventName` của `svp-security-detection`, thay điều kiện `errorCode` bằng
`[{ "prefix": "AccessDenied" }]` (API JSON trả `AccessDeniedException`).

`svp-security-denied-storage`:

```json
{ "detail-type": ["AWS API Call via CloudTrail"],
  "detail": { "eventSource": ["s3.amazonaws.com", "ec2.amazonaws.com", "kms.amazonaws.com"],
    "eventName": ["PutAccountPublicAccessBlock", "DeleteAccountPublicAccessBlock", "DisableEbsEncryptionByDefault",
      "ModifyEbsDefaultKmsKeyId", "ResetEbsDefaultKmsKeyId", "DisableKey", "DisableKeyRotation", "PutKeyPolicy", "ScheduleKeyDeletion",
      "TagResource", "UntagResource", "CreateAlias", "DeleteAlias", "UpdateAlias"],
    "errorCode": [{ "prefix": "AccessDenied" }, "Client.UnauthorizedOperation"] } }
```

`svp-security-admin-iam` (thành công):

```json
{ "detail-type": ["AWS API Call via CloudTrail"],
  "detail": { "eventSource": ["iam.amazonaws.com"],
    "eventName": [{ "prefix": "Add" }, { "prefix": "Attach" }, { "prefix": "Create" }, { "prefix": "Deactivate" }, { "prefix": "Delete" },
      { "prefix": "Detach" }, { "prefix": "Enable" }, { "prefix": "Put" }, { "prefix": "Remove" }, { "prefix": "Reset" }, { "prefix": "Set" },
      { "prefix": "Update" }, { "prefix": "Upload" }],
    "errorCode": [{ "exists": false }] } }
```

`svp-security-admin-sso` (thành công):

```json
{ "detail-type": ["AWS API Call via CloudTrail"],
  "detail": { "eventSource": ["sso.amazonaws.com"],
    "eventName": ["AttachManagedPolicyToPermissionSet", "CreateAccountAssignment", "CreatePermissionSet", "DeleteAccountAssignment",
      "DeleteInlinePolicyFromPermissionSet", "DeletePermissionSet", "DetachManagedPolicyFromPermissionSet", "ProvisionPermissionSet",
      "PutInlinePolicyToPermissionSet", "UpdatePermissionSet"],
    "errorCode": [{ "exists": false }] } }
```

`svp-security-admin-kms-s3` (thành công):

```json
{ "detail-type": ["AWS API Call via CloudTrail"],
  "detail": { "eventSource": ["kms.amazonaws.com", "s3.amazonaws.com"],
    "eventName": ["DisableKey", "DisableKeyRotation", "PutKeyPolicy", "ScheduleKeyDeletion", "DeleteAlias", "UpdateAlias",
      "PutBucketPolicy", "DeleteBucketPolicy", "PutBucketAcl", "PutBucketLifecycle", "DeleteBucketLifecycle", "PutBucketEncryption",
      "DeleteBucketEncryption", "PutObjectLockConfiguration", "PutBucketVersioning", "PutBucketOwnershipControls", "PutBucketLogging",
      "PutBucketPublicAccessBlock", "DeleteBucketPublicAccessBlock"],
    "errorCode": [{ "exists": false }] } }
```

`svp-security-findings`:

```json
{ "source": ["aws.securityhub"], "detail-type": ["Security Hub Findings - Imported"],
  "detail": { "findings": { "Severity": { "Label": ["HIGH", "CRITICAL"] }, "RecordState": ["ACTIVE"],
    "Workflow": { "Status": ["NEW"] }, "ProductName": ["GuardDuty", "IAM Access Analyzer"] } } }
```

- Filter "unauthorized API calls" của CIS v1.2.0 3.1 (control CloudWatch.2): `{($.errorCode="*UnauthorizedOperation") ||
  ($.errorCode="AccessDenied*")}` [N2]. Trong các hành động của danh sách chỉ EC2 trả mã `UnauthorizedOperation`, ghi là
  `Client.UnauthorizedOperation`, nên pattern khớp đúng mã đó; mọi dịch vụ khác trả mã bắt đầu `AccessDenied`.
- Mỗi pattern ≤ 2 048 ký tự [N20]; nhóm nào vượt khi hiện thực thì tách theo `eventSource`, giữ tên `svp-security-<nhóm>-<dịch vụ>`.
- Tên sự kiện S3 Control cho BPA cấp account (`PutAccountPublicAccessBlock`, `DeleteAccountPublicAccessBlock`) và cấp bucket
  (`PutBucketPublicAccessBlock`, `DeleteBucketPublicAccessBlock`) theo cách CloudTrail đặt tên; phép thử guardrail BPA xác nhận khi áp.

### Input transformer

| Rule | Biến | Mẫu |
| --- | --- | --- |
| `svp-security-notify` | `detail-type`, `account`, `region`, `$.detail.eventName`, `$.detail.userIdentity.arn`, `$.detail.errorCode` | `"svp-security: <detail-type> <eventName> account <account> region <region> by <arn> error <errorCode>. Runbook: <URL>"` |
| `svp-security-findings` | `$.detail.findings[0].Title`, `Severity.Label`, `AwsAccountId`, `Region`, `ProductName` | `"svp-security finding <severity> <product>: <title>, account <account> region <region>. Runbook: <URL>"` |

`<URL>` = `https://github.com/anhnvcoder/svp-backend/blob/main/docs/runbooks/security-alert.md`.

## §11. Chi phí org

| Tài nguyên | Giá trị |
| --- | --- |
| `aws_ce_anomaly_monitor` | `svp-services`, `DIMENSIONAL`, dimension `SERVICE` |
| `aws_ce_anomaly_subscription` | `svp-daily`, `DAILY`, email `budget_emails`, `threshold_expression` `ANOMALY_TOTAL_IMPACT_ABSOLUTE` `GREATER_THAN_OR_EQUAL` 10 |
| `aws_ce_cost_allocation_tag` | `Project`, `Env`, `Stack` = `Active` |

## §12. Chi phí liên tục

### Bảng giá

`ap-southeast-1` trừ dòng ghi khác. "Price List" là file `https://pricing.us-east-1.amazonaws.com/offers/v1.0/aws/<mã>/current/<region>/index.json`
của AWS Price List API, mô tả giá chép nguyên văn. Mọi dòng đọc 2026-11-12.

| Dịch vụ | Mục | Giá (USD) | Nguồn |
| --- | --- | --- | --- |
| GuardDuty | Phân tích event CloudTrail | 0,0000046 mỗi event ($4,60 mỗi triệu); `us-east-1` 0,000004 | Price List `AmazonGuardDuty`; <https://aws.amazon.com/guardduty/pricing/> |
| GuardDuty | S3 data event | 0,00000116 mỗi event (500 triệu đầu); `us-east-1` 0,0000008 | Price List `AmazonGuardDuty` |
| GuardDuty | Log audit EKS | 0,00000219 mỗi log (100 triệu đầu); `us-east-1` 0,0000016 | Price List `AmazonGuardDuty` |
| GuardDuty | Runtime Monitoring | 1,85 mỗi vCPU-tháng (500 vCPU đầu) | Price List `AmazonGuardDuty` |
| GuardDuty | RDS Protection | 1,22 mỗi vCPU-tháng | Price List `AmazonGuardDuty` |
| GuardDuty | Malware Protection S3 | 0,135 mỗi GB sau 1 GB đầu; 0,000323 mỗi request sau 1 000 đầu | Price List `AmazonGuardDuty` |
| GuardDuty | Malware Protection EBS | 0,05 mỗi GB quét | Price List `AmazonGuardDuty` |
| GuardDuty | Dùng thử | 30 ngày cho account chưa bật | <https://aws.amazon.com/guardduty/pricing/> |
| Security Hub CSPM | Security check | 0,001 mỗi check (100 000 đầu mỗi account mỗi region); `us-east-1` 0,001 | Price List `AWSSecurityHub` |
| Security Hub CSPM | Finding ingestion | 10 000 đầu miễn phí, rồi 0,00003; finding của check luôn miễn phí | Price List `AWSSecurityHub` |
| Security Hub CSPM | Dùng thử | 30 ngày mỗi account mỗi region | Price List `AWSSecurityHub`; <https://aws.amazon.com/security-hub/pricing/> |
| Security Hub (hợp nhất) | Essentials, EC2 | 0,0052083 mỗi instance-giờ | Price List `AWSSecurityHub` |
| Config | Item ghi liên tục | 0,003 mỗi item; `us-east-1` 0,003 | Price List `AWSConfig` |
| Config | Item ghi hằng ngày | 0,012 mỗi item | Price List `AWSConfig` |
| Config | Rule, conformance pack evaluation | 0,001 mỗi lần (100 000 đầu); `ConfigRuleEvaluationInternal` 0,00 | Price List `AWSConfig` |
| KMS | Customer managed key | 1 mỗi key version mỗi tháng | Price List `awskms`; <https://aws.amazon.com/kms/pricing/> |
| KMS | Rotation | Lần xoay thứ nhất, thứ hai mỗi lần thêm $1 mỗi tháng, dừng ở lần thứ hai | <https://aws.amazon.com/kms/pricing/> |
| KMS | Request | 0,03 mỗi 10 000; 20 000 đầu mỗi tháng miễn phí | Price List `awskms` |
| CloudTrail | Management event bản đầu | 0 | Price List `AWSCloudTrail`; <https://aws.amazon.com/cloudtrail/pricing/> |
| CloudTrail | Data event | 0,000001 mỗi event ($0,10 mỗi 100 000) | Price List `AWSCloudTrail` |
| CloudWatch vended log | Giao S3 (`APS1-S3-Egress-Bytes`, flow log) | 0,35 mỗi GB (10 TB đầu) | Price List `AmazonCloudWatch` |
| CloudWatch vended log | Giao S3 log WAF, `us-east-1` | 0,25 mỗi GB (10 TB đầu) | Price List `AmazonCloudWatch` (`us-east-1`) |
| CloudWatch vended log | Chuyển sang Parquet | 0,049 mỗi GB | Price List `AmazonCloudWatch` |
| S3 | Standard | 0,025 mỗi GB-tháng (50 TB đầu) | Price List `AmazonS3` |
| S3 | Glacier Instant Retrieval | 0,005 mỗi GB-tháng | Price List `AmazonS3` |
| S3 | PUT, COPY, POST, LIST | 0,005 mỗi 1 000 request | Price List `AmazonS3` |
| EventBridge | Sự kiện quản lý AWS gửi chéo account | 1,00 mỗi triệu | Price List `AWSEvents`; <https://aws.amazon.com/eventbridge/pricing/> |
| EventBridge | Sự kiện quản lý AWS vào bus | 0 ("ingested by the event bus for free") | <https://aws.amazon.com/eventbridge/pricing/> |
| SNS | Email | 1 000 đầu mỗi tháng miễn phí, rồi 2,00 mỗi 100 000 | Price List `AmazonSNS` |
| IAM Access Analyzer | Truy cập ngoài | Không tính phí; truy cập không dùng 0,20 mỗi role hay user mỗi tháng (ví dụ `us-east-1`) | <https://aws.amazon.com/iam/access-analyzer/pricing/> |
| Cost Anomaly Detection | Monitor, subscription | "no effort or cost" (cấu hình mặc định) | [N24] |

### Ước lúc không buổi

Năm account (management, `svp-log-archive`, `svp-security`, `svp-stg`, `svp-prd`), hai region; không env nào chạy.

| Khoản | Giả định | Tháng (USD) |
| --- | --- | --- |
| Security Hub CSPM | ~25 control periodic áp dụng ở region nhà, ~15 ở `us-east-1` mỗi account, chạy mỗi 12–24 giờ (~45 lần mỗi tháng); check theo thay đổi ít vì tài nguyên không đổi: ~1 800 check mỗi account × 5 × 0,001 | ~9 (6–15) |
| KMS | Sáu key mới (log archive hai region, SNS `svp-security`, CMK EBS stg và prd, state management) × 1; ~100 000 request (CloudTrail mỗi file log) trừ 20 000 miễn phí × 0,03/10 000 | ~6,3 |
| GuardDuty | ~50 000 event CloudTrail mỗi account mỗi region (đọc, ghi của chính Config, Security Hub, Access Analyzer) × 5 × (4,60 + 4,00)/triệu; ~200 000 S3 data event (giao log) × 1,16/triệu | ~2,4 (1–5) |
| Config | ~100 item mỗi account (hai region) × 5 × 0,003; evaluation của rule do Security Hub tạo không tính ở Config (SKU `ConfigRuleEvaluationInternal` 0,00; giả định) | ~1,5 (0,6–3) |
| S3 Log Archive | ~2 GB × 0,025; ~200 000 PUT (file log, digest mỗi giờ mỗi region mỗi account của trail, Config) × 0,005/1 000 | ~1,1 |
| CloudTrail, EventBridge, SNS, Access Analyzer ngoài, Cost Anomaly Detection | Bản trail đầu miễn phí; vài chục sự kiện | ~0 |
| **Tổng** | | **~20 (15–30)** |

Khoản lớn nhất là Security Hub CSPM. Tháng đầu GuardDuty, Security Hub dùng thử 30 ngày: ~$9. Key trail cũ ở management đã tính ở
[0048](../0048-prd-aws.md) §10, không cộng lại. Từ năm thứ hai mỗi key xoay thêm $1 mỗi tháng tới lần xoay thứ hai.

### Thêm mỗi buổi

| Khoản | Giả định (một env, 4 giờ) | USD |
| --- | --- | --- |
| Config | ~600–1 500 item (tạo, đổi, xoá của ~250 tài nguyên, ENI và node xoay) × 0,003 | 2–4,5 |
| Security Hub | ~1 000–3 000 check theo thay đổi × 0,001 | 1–3 |
| GuardDuty | Runtime ~10 vCPU × 4/730 × 1,85; log audit EKS ~200 000 × 2,19/triệu; RDS 2 vCPU × 4/730 × 1,22 | ~0,5 |
| Flow log | ~0,5–1 GB × (0,35 + 0,049) | 0,2–0,4 |
| Log WAF, Malware Protection S3, data event prd | Vài MB; dưới free tier; ~10 000 event × 0,000001 | ~0 |
| **Tổng** | | **~4–8** |

### Giữ tối thiểu mà vẫn đúng chuẩn

| Cách | Đúng chuẩn vì | Tiết kiệm |
| --- | --- | --- |
| Loại toàn cục chỉ ghi ở region nhà | Khuyến nghị của Security Hub [N10] | Item IAM không ghi hai lần |
| Bật FSBP và CIS cùng lúc | Rule Config dùng chung chỉ tính một check [N8] | Không trả hai lần cho phần trùng |
| Tắt GuardDuty.7, .12, .13 | Control không áp dụng hay đã bù (agent EKS trong Terraform) | Không check, không tính tiền [N8] |
| Data event chỉ `uploads`, `media` (ghi) của prd | Dữ liệu người dùng thật chỉ ở prd | Không trả cho lượt xem qua CloudFront |
| Không conformance pack, không analyzer truy cập không dùng | Chuẩn CIS đã chạy ở Security Hub; truy cập ngoài vẫn quét | $0,001 mỗi evaluation; $0,20 mỗi role |
| Flow log Parquet, retention log mạng stg 7 ngày | Đủ điều tra sau buổi | Ít byte quét, ít lưu |

Nếu đo sau 7 ngày vượt $30 mỗi tháng: so phí CSPM với gói Essentials theo tài nguyên; ghi `AWS::EC2::NetworkInterface` theo ngày
(`recordingModeOverrides`); viết ADR mới trước khi tắt control hay region.

## Nguồn

- [N1] AWS SRA: <https://docs.aws.amazon.com/prescriptive-guidance/latest/security-reference-architecture/security-tooling.html>,
  <https://docs.aws.amazon.com/prescriptive-guidance/latest/security-reference-architecture/log-archive.html>
- [N2] Security Hub, control CloudWatch (filter "unauthorized API calls" của CIS): <https://docs.aws.amazon.com/securityhub/latest/userguide/cloudwatch-controls.html>
- [N3] AWS Config, tần suất ghi: <https://docs.aws.amazon.com/config/latest/developerguide/select-resources.html>,
  <https://docs.aws.amazon.com/config/latest/developerguide/managing-recorder_console-change-recording-frequency.html>
- [N4] GuardDuty, xuất finding: <https://docs.aws.amazon.com/guardduty/latest/ug/guardduty_exportfindings.html>
- [N5] Security Hub CSPM, cấu hình tập trung: <https://docs.aws.amazon.com/securityhub/latest/userguide/central-configuration-intro.html>
- [N6] Security Hub CSPM, CIS AWS Foundations Benchmark v5.0.0: <https://docs.aws.amazon.com/securityhub/latest/userguide/cis-aws-foundations-benchmark.html>
- [N7] Security Hub, control GuardDuty: <https://docs.aws.amazon.com/securityhub/latest/userguide/guardduty-controls.html>
- [N8] Security Hub, tạo và cập nhật finding control (tính tiền check, control tắt): <https://docs.aws.amazon.com/securityhub/latest/userguide/controls-findings-create-update.html>;
  lịch chạy check: <https://docs.aws.amazon.com/securityhub/latest/userguide/securityhub-standards-schedule.html>
- [N9] Security Hub và Security Hub CSPM: <https://docs.aws.amazon.com/securityhub/latest/userguide/what-are-securityhub-services.html>,
  <https://docs.aws.amazon.com/securityhub/latest/userguide/what-is-securityhub-v2.html>; giá: <https://aws.amazon.com/security-hub/pricing/>
- [N10] Security Hub, điều kiện Config (tài nguyên toàn cục một region): <https://docs.aws.amazon.com/securityhub/latest/userguide/securityhub-setup-prereqs.html>;
  Config delivery channel (không nhận bucket có Object Lock với retention mặc định): <https://docs.aws.amazon.com/config/latest/developerguide/manage-delivery-channel.html>
- [N11] IAM Access Analyzer pricing: <https://aws.amazon.com/iam/access-analyzer/pricing/>
- [N12] GuardDuty, agent EKS quản tay và VPC endpoint: <https://docs.aws.amazon.com/guardduty/latest/ug/managing-gdu-agent-eks-manually.html>,
  <https://docs.aws.amazon.com/guardduty/latest/ug/eksrunmon-prereq-deploy-security-agent.html>
- [N13] GuardDuty Malware Protection for S3, quyền role: <https://docs.aws.amazon.com/guardduty/latest/ug/malware-protection-s3-iam-policy-prerequisite.html>,
  <https://docs.aws.amazon.com/guardduty/latest/ug/gdu-malware-protection-s3.html>
- [N14] GuardDuty, tự bật cho tổ chức: <https://docs.aws.amazon.com/guardduty/latest/ug/set-guardduty-auto-enable-preferences.html>
- [N15] AWS WAF, log tới S3: <https://docs.aws.amazon.com/waf/latest/developerguide/logging-s3.html>; `LoggingConfiguration` (che `SingleHeader`):
  <https://docs.aws.amazon.com/waf/latest/APIReference/API_LoggingConfiguration.html>
- [N16] S3 server access logging (bucket đích SSE-S3, cùng account và region): <https://docs.aws.amazon.com/AmazonS3/latest/userguide/enable-server-access-logging.html>
- [N17] CloudTrail, bucket policy: <https://docs.aws.amazon.com/awscloudtrail/latest/userguide/create-s3-bucket-policy-for-cloudtrail.html>; key policy:
  <https://docs.aws.amazon.com/awscloudtrail/latest/userguide/create-kms-key-policy-for-cloudtrail.html>
- [N18] VPC flow log tới S3: <https://docs.aws.amazon.com/vpc/latest/userguide/flow-logs-s3.html>; giao log tới S3 qua `delivery.logs`:
  <https://docs.aws.amazon.com/AmazonCloudWatch/latest/logs/AWS-logs-infrastructure-V2-S3.html>
- [N19] EventBridge, gửi sự kiện giữa account: <https://docs.aws.amazon.com/eventbridge/latest/userguide/eb-cross-account.html>; region
  đích chéo region (mọi region trừ GovCloud, Trung Quốc, có `ap-southeast-1`):
  <https://aws.amazon.com/about-aws/whats-new/2021/11/amazon-eventbridge-cross-region-expands>, <https://docs.aws.amazon.com/eventbridge/latest/userguide/eb-cross-region.html>
- [N20] EventBridge quotas (event pattern 2 048 ký tự): <https://docs.aws.amazon.com/eventbridge/latest/userguide/eb-quota.html>
- [N21] CloudTrail, sự kiện đăng nhập console: <https://docs.aws.amazon.com/awscloudtrail/latest/userguide/cloudtrail-event-reference-aws-console-sign-in-events.html>
- [N22] EventBridge, sự kiện quản lý của CloudTrail: <https://docs.aws.amazon.com/eventbridge/latest/userguide/eb-service-event-cloudtrail-management.html>
- [N23] Security Hub CSPM, loại sự kiện EventBridge: <https://docs.aws.amazon.com/securityhub/latest/userguide/securityhub-cwe-integration-types.html>
- [N24] AWS Cost Anomaly Detection FAQ: <https://aws.amazon.com/aws-cost-management/aws-cost-anomaly-detection/faqs/>
- [N25] AWS Price List API, file theo region: <https://pricing.us-east-1.amazonaws.com/offers/v1.0/aws/index.json>; GuardDuty Malware Protection for S3
  free tier: <https://docs.aws.amazon.com/guardduty/latest/ug/pricing-malware-protection-for-s3-guardduty.html>
- [N26] AWS Config, quyền bucket S3 (giao chéo account, SLR không ghi object): <https://docs.aws.amazon.com/config/latest/developerguide/s3-bucket-policy.html>
- [N27] EventBridge, toán tử so khớp: <https://docs.aws.amazon.com/eventbridge/latest/userguide/eb-create-pattern-operators.html>
- [N28] GuardDuty gửi finding sang Security Hub CSPM (mới trong ~5 phút, cập nhật theo tần suất xuất finding):
  <https://docs.aws.amazon.com/guardduty/latest/ug/securityhub-integration.html>
- [N29] STS `AssumeRoot` (không nhận endpoint toàn cục): <https://docs.aws.amazon.com/STS/latest/APIReference/API_AssumeRoot.html>
