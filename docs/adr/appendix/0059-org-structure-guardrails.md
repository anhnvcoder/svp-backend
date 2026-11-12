# Phụ lục ADR-0059: AWS Organizations theo AWS SRA: account Log Archive và Security Tooling, OU `Security`, `Workloads/Prod`, `Workloads/NonProd`; baseline mỗi account áp từ management qua role truy cập org; SCP, RCP data perimeter, declarative policy EC2, tag policy gắn ở root; root tập trung; permission set chỉ đọc; NACL không mở 22/3389

Phụ lục của [ADR-0059](../0059-org-structure-guardrails.md): phương án, statement đủ của mọi policy, bảng đối chiếu RCP, permission set và
nguồn, xếp theo §. Mọi nguồn đọc ngày 2026-11-12. Đường dẫn `aws/...`, `docs/...` không kèm repo là của `svp-infra`.

## Phương án

| Phương án | Trạng thái ngành | Được | Mất | Nguồn |
| --- | --- | --- | --- | --- |
| **SRA nhiều account, Terraform thuần, root chạy từ management qua `OrganizationAccountAccessRole`** | Hiện hành; khuôn "execution role" của Control Tower, AFT | Đúng SRA (Log Archive, Security Tooling ở OU Security, account workload ở OU Workloads); mọi thứ trong state, `plan` đọc được; một công cụ | Tự viết phần Control Tower có sẵn (baseline, guardrail); management là đường duy nhất vào hai account mới | [N1] |
| Một OU, không account bảo mật | Lệch SRA | Ít account, ít root | Log, finding ở account mà admin workload hay management chạm được; delegated admin không có chỗ đặt | [N1] |
| AWS Control Tower (landing zone 3.x/4.0) | Hiện hành, cách AWS khuyên cho landing zone | Dựng sẵn account log và audit, control, Account Factory; landing zone 4.0 không còn đòi OU Security | Trail, Config, control do Control Tower quản, ngoài state Terraform; AFT đòi landing zone Control Tower và thêm "AFT management account"; khó gỡ | [N15] |
| Landing Zone Accelerator on AWS | Hiện hành, giải pháp của AWS | Đủ SRA và khung tuân thủ, cấu hình khai báo | Viết bằng AWS CDK, AWS khuyên dựng trên Control Tower; công cụ IaC thứ hai cạnh Terraform | [N16] |

SRA còn OU `Infrastructure` (account Network, Shared Services) [N1]: lab không có hạ tầng mạng dùng chung giữa env (mỗi env một VPC trong account
của nó), nên không tạo. Log DNS của Route 53 Resolver mà SRA đặt ở Log Archive [N1] chưa bật.

## §3. Bộ SCP

Mọi statement `Effect: Deny`. Ba SCP có sẵn (`svp-deny-leave-organization`, `svp-protect-cloudtrail`, `svp-deny-other-regions`) giữ nội dung ở
`aws/modules/org-policies/main.tf` ([0048](../0048-prd-aws.md) §1), chỉ đổi đích sang root. Đích: root có năm SCP này cộng `FullAWSAccess`
(6 trên 10 [N3]); OU `Prod` có `svp-prod-guardrails` cộng `FullAWSAccess`.

### `svp-protect-baseline`

Mọi statement cùng điều kiện miễn `ArnNotLike` `aws:PrincipalARN` = `arn:aws:iam::*:role/OrganizationAccountAccessRole`.

| Sid | Action | Resource | Điều kiện thêm |
| --- | --- | --- | --- |
| `ProtectAccountPublicAccessBlock` | `s3:PutAccountPublicAccessBlock` (đặt và xoá BPA cấp account) | `*` | — |
| `ProtectEbsDefaultEncryption` | `ec2:DisableEbsEncryptionByDefault`, `ec2:ModifyEbsDefaultKmsKeyId`, `ec2:ResetEbsDefaultKmsKeyId` | `*` | — |
| `ProtectConfig` | `config:DeleteConfigurationAggregator`, `DeleteConfigurationRecorder`, `DeleteDeliveryChannel`, `DeleteRetentionConfiguration`, `PutConfigurationAggregator`, `PutConfigurationRecorder`, `PutDeliveryChannel`, `StopConfigurationRecorder` | `*` | — |
| `ProtectGuardDuty` | `guardduty:CreateFilter`, `CreateIPSet`, `DeleteDetector`, `DeleteMembers`, `DeletePublishingDestination`, `DisassociateFromAdministratorAccount`, `DisassociateFromMasterAccount`, `DisassociateMembers`, `StopMonitoringMembers`, `UpdateDetector`, `UpdateFilter`, `UpdateIPSet`, `UpdateMalwareScanSettings`, `UpdateMemberDetectors`, `UpdateOrganizationConfiguration`, `UpdatePublishingDestination` | `*` | — |
| `ProtectSecurityHub` | `securityhub:BatchDeleteAutomationRules`, `BatchDisableStandards`, `BatchUpdateAutomationRules`, `CreateAutomationRule`, `DeleteConfigurationPolicy`, `DeleteFindingAggregator`, `DisableImportFindingsForProduct`, `DisableSecurityHub`, `DisassociateFromAdministratorAccount`, `DisassociateFromMasterAccount`, `StartConfigurationPolicyDisassociation`, `UpdateConfigurationPolicy`, `UpdateFindingAggregator`, `UpdateOrganizationConfiguration`, `UpdateSecurityControl`, `UpdateStandardsControl` | `*` | — |
| `ProtectAccessAnalyzer` | `access-analyzer:CreateArchiveRule`, `DeleteAnalyzer`, `UpdateArchiveRule` | `*` | — |
| `ProtectAlertRules` | `events:DeleteRule`, `DisableRule`, `PutRule`, `PutTargets`, `RemoveTargets` | `arn:aws:events:*:*:rule/svp-security-*`, `arn:aws:events:*:*:rule/*/svp-security-*` | — |
| `ProtectBaselineRoles` | `iam:AttachRolePolicy`, `DeleteRole`, `DeleteRolePermissionsBoundary`, `DeleteRolePolicy`, `DetachRolePolicy`, `PutRolePermissionsBoundary`, `PutRolePolicy`, `TagRole`, `UntagRole`, `UpdateAssumeRolePolicy`, `UpdateRole`, `UpdateRoleDescription` | `arn:aws:iam::*:role/OrganizationAccountAccessRole`, `arn:aws:iam::*:role/svp-security-*` | — |
| `ProtectEbsKey` | `kms:DisableKey`, `DisableKeyRotation`, `PutKeyPolicy`, `ScheduleKeyDeletion`, `TagResource`, `UntagResource` | `*` | `StringEquals` `aws:ResourceTag/Stack` = `security-baseline` |
| `ProtectEbsAlias` | `kms:CreateAlias`, `DeleteAlias`, `UpdateAlias` | `arn:aws:kms:*:*:alias/svp-ebs` | — |

- Role chuyển sự kiện của module `security-baseline` đặt tên bắt đầu `svp-security-` để `ProtectBaselineRoles` phủ nó.
- `ProtectEbsKey` dựa vào tag `Stack=security-baseline` mà `default_tags` của `aws/baseline` gắn; ở stg, prd chỉ CMK EBS là KMS key mang tag
  đó. Chặn cả `TagResource`, `UntagResource` để không ai gỡ tag rồi xoá key.
- Không có trong danh sách (buổi tạo và gỡ): `guardduty:CreateMalwareProtectionPlan`, `DeleteMalwareProtectionPlan`, `ec2:CreateFlowLogs`,
  `DeleteFlowLogs`, `wafv2:PutLoggingConfiguration`, `DeleteLoggingConfiguration`.
- `svp-security`, `svp-log-archive` không có principal ghi nào ngoài `OrganizationAccountAccessRole`; statement có tác dụng chính ở stg, prd
  (`SvpAdmin`).

### `svp-deny-iam-users`

| Sid | Action | Resource | Điều kiện |
| --- | --- | --- | --- |
| `DenyIamUsers` | `iam:CreateAccessKey`, `CreateLoginProfile`, `CreateUser`, `UpdateLoginProfile` | `arn:aws:iam::*:user/*` | không; không miễn principal nào |

Task policy `IAMCreateRootUserPassword` chỉ để lại `iam:CreateLoginProfile`, `iam:GetLoginProfile`, và chặn mọi resource khác
`arn:aws:iam::*:root` (`NotResource`) [N4]. SCP áp lên root của account thành viên [N2], nhưng ARN `arn:aws:iam::<id>:root` không khớp
`arn:aws:iam::*:user/*`, nên task vẫn chạy. `IAMDeleteRootUserCredentials` chỉ dùng hành động `Delete*`, `Deactivate*`, `List*`, `Get*` [N4],
ngoài statement.

### `svp-prod-guardrails`

| Sid | Action | Resource | Điều kiện |
| --- | --- | --- | --- |
| `DenySpotRunInstances` | `ec2:RunInstances` | `arn:aws:ec2:*:*:instance/*` | `StringEquals` `ec2:InstanceMarketType` = `spot` |
| `DenySpotRequests` | `ec2:RequestSpotFleet`, `ec2:RequestSpotInstances` | `*` | — |

Service Authorization Reference của EC2 (bản JSON `servicereference.us-east-1.amazonaws.com/v1/ec2/ec2.json`) [N5]: loại `instance` của
`RunInstances` có khoá `ec2:InstanceMarketType`; loại `instance` của `CreateFleet` có `ec2:InstanceType`, `ec2:Tenancy`, `ec2:AvailabilityZone`…
nhưng không có `ec2:InstanceMarketType`. Tài liệu EC2 Fleet không nói `CreateFleet` loại `instant` có kiểm `ec2:RunInstances` của người gọi hay
không, nên không dựa vào đó.

Đối chiếu bước gỡ buổi prd:

| Bước | API | Bị `svp-prod-guardrails` chặn? |
| --- | --- | --- |
| `terraform apply`, `destroy` với `teardown.tfvars` (`rds_deletion_protection = false`, `media_force_destroy = true`) | RDS, S3, EKS, MSK, ElastiCache, EC2 xoá | Không: không tạo EC2 |
| `pre-destroy.sh` | `kubectl delete` (TargetGroupBinding, EC2NodeClass, NodePool…), Karpenter `TerminateInstances` | Không |
| Mục "Kết thúc buổi" của `session-prd.md` | `rds delete-db-snapshot`, `delete-db-instance-automated-backup`, `pricing-plan-manager list-subscriptions` | Không |

## §4. RCP data perimeter

Mẫu `identity_perimeter_rcp.json` của AWS [N6], bỏ ngoại lệ riêng của mẫu (`aws:PrincipalAccount`, `aws:ResourceTag/dp:exclude:identity`), bỏ
dịch vụ lab không dùng; thêm statement TLS. Mọi statement `Effect: Deny`, `Principal: "*"`, `Resource: "*"`; `<org-id>` lấy từ
`aws_organizations_organization` ở `aws/org`.

| Sid | Action | Điều kiện |
| --- | --- | --- |
| `EnforceOrgIdentities` | `s3:*`, `sqs:*`, `kms:*`, `secretsmanager:*`, `sts:AssumeRole`, `sts:DecodeAuthorizationMessage`, `sts:GetAccessKeyInfo`, `sts:GetFederationToken`, `sts:GetServiceBearerToken`, `sts:GetSessionToken`, `sts:SetContext` | `StringNotEqualsIfExists` `aws:PrincipalOrgID` = `<org-id>`; `BoolIfExists` `aws:PrincipalIsAWSService` = `false` |
| `EnforceConfusedDeputyProtection` | `s3:*`, `sqs:*`, `kms:*`, `secretsmanager:*`, `sts:*` | `StringNotEqualsIfExists` `aws:SourceOrgID` = `<org-id>`; `Null` `aws:SourceAccount` = `false`; `Bool` `aws:PrincipalIsAWSService` = `true` |
| `EnforceSecureTransport` | `s3:*`, `sqs:*`, `kms:*`, `secretsmanager:*`, `sts:*` | `BoolIfExists` `aws:SecureTransport` = `false` |

- `AssumeRoleWithSAML`, `AssumeRoleWithWebIdentity`, `SetSourceIdentity`, `TagSession` không có trong `EnforceOrgIdentities`: request liên kết
  danh tính không mang `aws:PrincipalOrgID` [N6].
- RCP không áp lên tài nguyên của management, áp cả account là delegated admin; không đổi quyền của service-linked role [N7].
- Root có `RCPFullAWSAccess` cộng `svp-data-perimeter`: 2 trên 5 [N3].

### Bảng đối chiếu

Phạm vi: mọi principal dịch vụ trong `assume_role_policy`, key policy KMS, policy bucket, secret, SQS, SNS của `aws/{modules,envs,org,bootstrap,accounts}`
và ba root mới (grep `Service`, `identifiers`, `.amazonaws.com`), cộng luồng của module `terraform-aws-modules` mà root env gọi. "Ngoài phạm vi
RCP" là luồng chạm tài nguyên của management hay chỉ chạm dịch vụ RCP này không phủ.

| Luồng | Principal | Tài nguyên | Qua nhờ |
| --- | --- | --- | --- |
| CloudFront OAC đọc `media` (`aws/modules/media/s3.tf`) | `cloudfront.amazonaws.com` | S3 `media` | Principal dịch vụ; `aws:SourceOrgID` của distribution cùng account; viewer `https-only` nên CloudFront gọi S3 bằng HTTPS |
| Upload presigned POST từ trình duyệt | Role Pod Identity của video-service ký URL (`aws/envs/<env>/pod-identity.tf`) | S3 `uploads` | Principal trong org; URL `https://` |
| Service đọc, ghi object (video-service, media-worker) | Role Pod Identity | S3 `uploads`, `media` | Principal trong org |
| Pod Identity nhận role (`aws/modules/eks/iam.tf`, `karpenter.tf`, `aws/modules/external-secrets/main.tf`, `aws/envs/<env>/pod-identity.tf`) | `pods.eks.amazonaws.com` | STS `AssumeRole`, `TagSession` | Principal dịch vụ; `aws:SourceAccount` (nếu có) là account của cluster, trong org |
| External Secrets đọc secret | Role Pod Identity của controller, namespace | Secrets Manager, KMS | Principal trong org |
| MSK đọc secret SCRAM `AmazonMSK_*` mã hoá CMK (`aws/modules/msk/main.tf`) | MSK (service-linked role hay principal dịch vụ) | Secrets Manager, KMS | SLR không chịu RCP; principal dịch vụ với `aws:SourceOrgID` của org |
| Secret master do RDS quản với CMK (`aws/modules/rds/main.tf`, `master_user_secret_kms_key_id`) | RDS (service-linked role) | Secrets Manager, KMS | SLR không chịu RCP |
| Mã hoá at-rest bằng CMK của RDS, MSK, Secret EKS, Performance Insights | Dịch vụ thay principal gọi (grant, forward access session) | KMS | Principal gọi trong org hay principal dịch vụ; mẫu AWS không nêu ngoại lệ; xác nhận khi buổi stg dựng chúng |
| Enhanced monitoring RDS (`aws/modules/rds/main.tf`) | `monitoring.rds.amazonaws.com` | STS `AssumeRole` | Principal dịch vụ; trust có `aws:SourceAccount`, `aws:SourceArn` của account trong org |
| Role node group, node Karpenter, bastion SSM (`aws/modules/ssm-bastion/main.tf`, module `eks`) | `ec2.amazonaws.com` | STS `AssumeRole` | Principal dịch vụ; không `aws:SourceAccount` nên statement dịch vụ không xét |
| Role cluster EKS (module `eks`) | `eks.amazonaws.com` | STS `AssumeRole` | Như dòng trên |
| AutoScaling của node group dùng CMK EBS | `AWSServiceRoleForAutoScaling` | KMS (qua EC2) | SLR không chịu RCP |
| EBS CSI tạo volume mã hoá mặc định | Role Pod Identity `ebs_csi` | KMS (qua EC2) | Principal trong org |
| Interruption queue của Karpenter (module `eks`, SSE do SQS quản) | `events.amazonaws.com`, `sqs.amazonaws.com` gửi; role Karpenter đọc | SQS | Principal dịch vụ, `aws:SourceArn` là rule cùng account; Karpenter trong org |
| Alarm CloudWatch → SNS mã hoá CMK (`aws/modules/alarms/main.tf`) | `cloudwatch.amazonaws.com` | KMS | Principal dịch vụ; `aws:SourceAccount` trong org |
| Rule `svp-security-*` → SNS `svp-security-alarms` mã hoá CMK | `events.amazonaws.com` | KMS | Như dòng trên |
| Role chuyển sự kiện `svp-security-*` | `events.amazonaws.com` | STS `AssumeRole` | Principal dịch vụ; account trong org |
| Trail org ghi bucket, key Log Archive (`aws/org/audit-trail.tf`, `aws/log-archive/`) | `cloudtrail.amazonaws.com` | S3, KMS của `svp-log-archive` | Principal dịch vụ; `aws:SourceAccount` là management, trong org |
| Config giao snapshot, lịch sử | `config.amazonaws.com` (SLR không ghi được S3 [N17]) | S3, KMS của `svp-log-archive` | Principal dịch vụ; `aws:SourceAccount` của từng account |
| Aggregator Config nhận role ở `svp-security` (`aws/security/`, [0060](../0060-org-detection-logging.md) §4) | `config.amazonaws.com` | STS `AssumeRole` | Principal dịch vụ; `aws:SourceAccount` là `svp-security`, trong org |
| Flow log, log WAF | `delivery.logs.amazonaws.com` | S3, KMS của `svp-log-archive` (hai region) | Principal dịch vụ; `aws:SourceAccount` là stg, prd |
| GuardDuty xuất finding | `guardduty.amazonaws.com` | S3, KMS của `svp-log-archive` | Principal dịch vụ; `aws:SourceAccount` là `svp-security` |
| S3 server access log (`aws/modules/media/logs.tf`, bucket access của Log Archive) | `logging.s3.amazonaws.com` | S3 | Principal dịch vụ; `aws:SourceAccount` trong org |
| Malware Protection for S3 (`aws/modules/media/`) | `malware-protection-plan.guardduty.amazonaws.com` nhận role; role đọc object, gắn tag, dùng KMS | STS, S3, KMS | Principal dịch vụ khi nhận role; role trong org khi đọc |
| Malware Protection for EC2 trên volume CMK EBS | SLR GuardDuty tạo grant; account dịch vụ GuardDuty dùng key [N8] | KMS stg, prd | **Không qua**: ngoài org, không phải principal dịch vụ; không thêm ngoại lệ (ADR §4) |
| Identity Center | Người dùng SAML | STS `AssumeRoleWithSAML` | Không có trong `EnforceOrgIdentities`; statement dịch vụ chỉ xét principal dịch vụ |
| `sts:AssumeRoot` từ management | Role SSO của management | STS (root account thành viên) | Không có trong `EnforceOrgIdentities`; người gọi trong org |
| Ba root mới, provider `log_archive` của `aws/org` vào account thành viên | Role SSO của management | STS `AssumeRole` vào `OrganizationAccountAccessRole` | Principal trong org |
| State Terraform của stg, prd (`aws/accounts/<env>`) | `SvpAdmin` | S3, KMS | Principal trong org |
| Đọc log | `SvpLogReader` | S3, KMS của `svp-log-archive` | Principal trong org |
| Trail cũ, state `aws/bootstrap`, `aws/org`, `github/` | Mọi principal | S3, KMS của management | Ngoài phạm vi RCP (management) |

Không luồng nào cần `aws:PrincipalAccount`: không log truy cập ELB (NLB không bật access log), không FinSpace, không bên thứ ba [N6].

## §5. Declarative policy EC2

```json
{
  "ec2_attributes": {
    "image_block_public_access": { "state": { "@@assign": "block_new_sharing" } },
    "snapshot_block_public_access": { "state": { "@@assign": "block_all_sharing" } },
    "instance_metadata_defaults": {
      "http_tokens": { "@@assign": "required" },
      "http_put_response_hop_limit": { "@@assign": "1" },
      "http_endpoint": { "@@assign": "enabled" },
      "http_tokens_enforced": { "@@assign": "enabled" }
    },
    "serial_console_access": { "status": { "@@assign": "disabled" } }
  }
}
```

- `http_tokens` chỉ là mặc định; `http_tokens_enforced = enabled` mới từ chối launch IMDSv1 và bật IMDSv1 trên instance có sẵn [N9]. Node group
  hệ thống (`aws/modules/eks/nodes.tf`), EC2NodeClass Karpenter, bastion (`aws/modules/ssm-bastion/main.tf`) đều đặt `http_tokens = required`, hop 1.
- `block_new_sharing` cho AMI: AMI đã public vẫn public (không có); `block_all_sharing` cho snapshot: snapshot đã public thành private [N9].
- `vpc_block_public_access` không đặt.

## §6. Tag policy

```json
{
  "tags": {
    "Project": { "tag_key": { "@@assign": "Project" }, "tag_value": { "@@assign": ["svp"] },
                 "enforced_for": { "@@assign": ["ec2:ALL_SUPPORTED", "eks:ALL_SUPPORTED", "kms:ALL_SUPPORTED"] } },
    "Env": { "tag_key": { "@@assign": "Env" }, "tag_value": { "@@assign": ["stg", "prd"] },
             "enforced_for": { "@@assign": ["ec2:ALL_SUPPORTED", "eks:ALL_SUPPORTED", "kms:ALL_SUPPORTED"] } },
    "ManagedBy": { "tag_key": { "@@assign": "ManagedBy" }, "tag_value": { "@@assign": ["terraform"] },
                   "enforced_for": { "@@assign": ["ec2:ALL_SUPPORTED", "eks:ALL_SUPPORTED", "kms:ALL_SUPPORTED"] } },
    "Stack": { "tag_key": { "@@assign": "Stack" },
               "tag_value": { "@@assign": ["bootstrap", "org", "baseline", "log-archive", "security", "security-baseline", "stg", "prd"] },
               "enforced_for": { "@@assign": ["ec2:ALL_SUPPORTED", "eks:ALL_SUPPORTED", "kms:ALL_SUPPORTED"] } }
  }
}
```

| Nơi gắn tag | Khoá, giá trị |
| --- | --- |
| `default_tags` của `aws/bootstrap`, `aws/org` | `Project=svp`, `ManagedBy=terraform`, `Stack=bootstrap` hay `org` |
| `default_tags` của `aws/accounts/<env>` | thêm `Env=<env>`, `Stack=baseline` |
| `default_tags` của `aws/envs/<env>`, `aws/gitops/<env>` | `Env=<env>`, `Stack=<env>` |
| `default_tags` của ba root mới | `Stack=log-archive`, `security`, `security-baseline` (không `Env`) |
| `aws/modules/eks/cluster.tf` | `Project=svp` |
| EC2NodeClass Karpenter (`deploy/helm/svp-cluster/templates/karpenter.yaml` của repo code) | `Project=svp` |
| Load Balancer Controller, VPC CNI, EBS CSI, ExternalDNS | Tag riêng của chúng, không dùng bốn khoá |

`ALL_SUPPORTED` của `ec2`, `eks`, `kms` có chế độ enforce theo bảng tài nguyên hỗ trợ [N10]. `s3`, `rds` không enforce (`rds:db` không hỗ trợ
enforce [N10]): chỉ báo tuân thủ. Basic compliance không bắt tài nguyên tạo không tag [N10].

## §7. Root tập trung

| Task policy | Hành động để lại | Dùng khi |
| --- | --- | --- |
| `IAMAuditRootUserCredentials` | Đọc credential của root | Kiểm root thành viên không có mật khẩu, access key, MFA |
| `IAMCreateRootUserPassword` | `iam:CreateLoginProfile`, `GetLoginProfile` trên `arn:aws:iam::*:root` | Việc cần đăng nhập root đầy đủ: cho khôi phục mật khẩu qua email root |
| `IAMDeleteRootUserCredentials` | Xoá access key, chứng chỉ ký, mật khẩu, MFA của root | Dọn sau khi dùng root |
| `S3UnlockBucketPolicy` | Xoá bucket policy chặn mọi principal | Bucket policy khoá mọi người |
| `SQSUnlockQueuePolicy` | Xoá queue policy chặn mọi principal | Queue policy khoá mọi người |

- Bật: trusted access `iam.amazonaws.com`, rồi `enable-organizations-root-credentials-management`, `enable-organizations-root-sessions` [N11].
  Khôi phục mật khẩu root của account thành viên chỉ được khi "Privileged root actions" bật [N11].
- Phiên `AssumeRoot` từ 0 tới 900 giây, mặc định 900 [N12].
- Account do Organizations tạo không có mật khẩu root; root tập trung giữ trạng thái đó và cho kiểm bằng task audit.

## §8. Permission set

| Permission set | Policy | Phiên | Gán ở | Profile |
| --- | --- | --- | --- | --- |
| `SvpAdmin` | `AdministratorAccess` | `PT1H` | `svp-stg`, `svp-prd` | `anhnv-stg`, `anhnv-prd` (có sẵn) |
| `SvpReadOnly` | `ViewOnlyAccess`, `SecurityAudit`; inline `logs:FilterLogEvents`, `logs:GetLogEvents`, `logs:StartQuery`, `logs:StopQuery`, `logs:GetQueryResults` | `PT4H` | `svp-stg`, `svp-prd`, `svp-security` | `anhnv-stg-ro`, `anhnv-prd-ro`, `anhnv-security-ro` |
| `SvpLogReader` | `ViewOnlyAccess`; inline `s3:GetObject`, `s3:ListBucket` trên bucket log của Log Archive ([0060](../0060-org-detection-logging.md) §7); `kms:Decrypt` với `kms:ViaService` thuộc `s3.ap-southeast-1.amazonaws.com`, `s3.us-east-1.amazonaws.com` và `ForAnyValue:StringEquals` `kms:ResourceAliases` = `alias/svp-log-archive` | `PT4H` | `svp-log-archive` | `anhnv-log-ro` |

- Năm hành động inline của `SvpReadOnly` đều không phải ghi (`IsWrite` = `false` trong Service Authorization Reference [N19]). Đổi
  `Workflow.Status` của finding là ghi: đi qua đường ghi của `svp-security` ([0060](../0060-org-detection-logging.md) §10).
- Session duration của permission set giới hạn thời gian đăng nhập vào account, 1–12 giờ [N13]. Với cấu hình token provider (`sso-session`), SDK
  tự làm mới phiên và lấy access token mới bằng refresh token khi phiên cổng truy cập còn hạn; cấu hình cũ (không `sso-session`) cố định 8 giờ
  và không tự làm mới [N13].

## §9. CMK EBS

Key policy:

| Sid | Principal | Action | Điều kiện |
| --- | --- | --- | --- |
| `EnableIamPermissions` | `arn:aws:iam::<account>:root` | `kms:*` | — |
| `AllowEc2UseForAccount` | `*` | `kms:Encrypt`, `kms:Decrypt`, `kms:ReEncrypt*`, `kms:GenerateDataKey*`, `kms:CreateGrant`, `kms:DescribeKey` | `StringEquals` `kms:CallerAccount` = `<account>`, `kms:ViaService` = `ec2.ap-southeast-1.amazonaws.com` |

Rotation bật, chờ xoá 30 ngày, alias `alias/svp-ebs`, `ebs_kms_key_arn` của module là ARN key này; đổi key hay xoá bị `ProtectEbsKey`,
`ProtectEbsAlias` chặn trừ `OrganizationAccountAccessRole`.

## §10. NACL

Rule Config `nacl-no-unrestricted-ssh-rdp` của EC2.21 NON_COMPLIANT khi entry inbound allow nguồn CIDR cho TCP hay UDP cổng 22, 3389 (mô
tả control của Security Hub chỉ nêu TCP; rule Config mới là cái đánh giá); không sinh finding cho NACL mặc định; chạy khi đổi [N14]. Dạng
entry inbound mỗi NACL riêng:

| Tầng | Nguồn `0.0.0.0/0` (và `::/0` nếu VPC có IPv6) | Nguồn CIDR VPC |
| --- | --- | --- |
| Public | TCP 443; TCP, UDP 1024–3388, 3390–65535; ICMP mọi loại | TCP, UDP, ICMP |
| Private | TCP, UDP 1024–3388, 3390–65535; ICMP mọi loại | TCP, UDP, ICMP |
| Database | Không | TCP, UDP, ICMP |

Outbound mọi tầng: allow TCP, UDP, ICMP tới mọi đích. Không giao thức IP nào khác (ESP, GRE…) qua NACL: trong VPC không gì dùng, nên
mỗi giao thức một entry thay cho `-1`. NACL mặc định không còn allow (không subnet nào gắn nó).

## Nguồn

- [N1] AWS SRA, architecture: <https://docs.aws.amazon.com/prescriptive-guidance/latest/security-reference-architecture/architecture.html>;
  Log Archive account: <https://docs.aws.amazon.com/prescriptive-guidance/latest/security-reference-architecture/log-archive.html>;
  Security Tooling account: <https://docs.aws.amazon.com/prescriptive-guidance/latest/security-reference-architecture/security-tooling.html>
- [N2] Service control policies (áp cả root của account thành viên, không áp service-linked role, không áp management):
  <https://docs.aws.amazon.com/organizations/latest/userguide/orgs_manage_policies_scps.html>
- [N3] Quotas for AWS Organizations (SCP 10 240, RCP 5 120, declarative và tag 10 000 ký tự; SCP 10, RCP 5 mỗi đích):
  <https://docs.aws.amazon.com/organizations/latest/userguide/orgs_reference_limits.html>
- [N4] AWS managed policies for IAM, task policies của `sts:AssumeRoot`: <https://docs.aws.amazon.com/IAM/latest/UserGuide/security-iam-awsmanpol.html>;
  <https://docs.aws.amazon.com/IAM/latest/UserGuide/id_root-user-privileged-task.html>
- [N5] Service Authorization Reference, Amazon EC2: <https://docs.aws.amazon.com/service-authorization/latest/reference/list_amazonec2.html>;
  bản JSON: <https://servicereference.us-east-1.amazonaws.com/v1/ec2/ec2.json>
- [N6] `aws-samples/data-perimeter-policy-examples`, `resource_control_policies` (README, `identity_perimeter_rcp.json`):
  <https://github.com/aws-samples/data-perimeter-policy-examples/tree/main/resource_control_policies>
- [N7] Resource control policies (dịch vụ hỗ trợ, không áp management, không áp service-linked role):
  <https://docs.aws.amazon.com/organizations/latest/userguide/orgs_manage_policies_rcps.html>
- [N8] GuardDuty, service-linked role của Malware Protection: <https://docs.aws.amazon.com/guardduty/latest/ug/slr-permissions-malware-protection.html>;
  volume hỗ trợ: <https://docs.aws.amazon.com/guardduty/latest/ug/gdu-malpro-supported-volumes.html>
- [N9] Declarative policy syntax: <https://docs.aws.amazon.com/organizations/latest/userguide/orgs_manage_policies_declarative_syntax.html>
- [N10] Tag policy examples: <https://docs.aws.amazon.com/organizations/latest/userguide/orgs_manage_policies_example-tag-policies.html>;
  tài nguyên hỗ trợ enforce: <https://docs.aws.amazon.com/organizations/latest/userguide/orgs_manage_policies_supported-resources-enforcement.html>
- [N11] Centrally manage root access: <https://docs.aws.amazon.com/IAM/latest/UserGuide/id_root-enable-root-access.html>
- [N12] STS `AssumeRoot`: <https://docs.aws.amazon.com/STS/latest/APIReference/API_AssumeRoot.html>
- [N13] Identity Center session duration: <https://docs.aws.amazon.com/singlesignon/latest/userguide/howtosessionduration.html>; SDK SSO credentials:
  <https://docs.aws.amazon.com/sdkref/latest/guide/feature-sso-credentials.html>, <https://docs.aws.amazon.com/sdkref/latest/guide/understanding-sso.html>
- [N14] Security Hub, EC2.21: <https://docs.aws.amazon.com/securityhub/latest/userguide/ec2-controls.html#ec2-21>; rule Config (TCP hay UDP):
  <https://docs.aws.amazon.com/config/latest/developerguide/nacl-no-unrestricted-ssh-rdp.html>
- [N15] AWS Control Tower: <https://docs.aws.amazon.com/controltower/latest/userguide/what-is-control-tower.html>,
  <https://docs.aws.amazon.com/controltower/latest/userguide/how-control-tower-works.html>, AFT: <https://docs.aws.amazon.com/controltower/latest/userguide/aft-overview.html>
- [N16] Landing Zone Accelerator on AWS: <https://docs.aws.amazon.com/solutions/latest/landing-zone-accelerator-on-aws/solution-overview.html>
- [N17] AWS Config, quyền bucket S3 (giao chéo account, SLR không ghi object): <https://docs.aws.amazon.com/config/latest/developerguide/s3-bucket-policy.html>
- [N18] Loại policy của Organizations, cột "Affects management account" (SCP, RCP: không; declarative, tag: có):
  <https://docs.aws.amazon.com/organizations/latest/userguide/orgs_manage_policies.html>
- [N19] Service Authorization Reference, CloudWatch Logs: <https://docs.aws.amazon.com/service-authorization/latest/reference/list_amazoncloudwatchlogs.html>;
  bản JSON: <https://servicereference.us-east-1.amazonaws.com/v1/logs/logs.json>
