# security-alert

- Nguồn: email từ topic SNS `svp-security-alarms` của account `svp-security` (`ap-southeast-1`), dòng đầu `svp-security:` (sự kiện) hay
  `svp-security finding` (finding). Rule ở root `aws/security` và module `aws/modules/security-baseline` của `svp-infra`
  ([ADR-0060](../adr/0060-org-detection-logging.md) §10); đường đi của email: [`aws-security.md`](../explanation/aws-security.md#luồng-phát-hiện-tới-cảnh-báo).
  Chỉ ở AWS.
- Mọi lệnh AWS do người học chạy. Lệnh dưới chỉ đọc, bằng permission set chỉ đọc: `anhnv-security-ro` cho finding, `anhnv-log-ro` cho log,
  `anhnv-<env>-ro` cho cấu hình của stg, prd. Lệnh ghi (mục Giảm thiểu) ghi rõ, người học quyết.

Dán một lần cho mỗi terminal. Biến account (`SVP_AWS_LOG_ACCOUNT_ID`, `SVP_AWS_SECURITY_ACCOUNT_ID`, `SVP_AWS_STG_ACCOUNT_ID`,
`SVP_AWS_PRD_ACCOUNT_ID`) export trong terminal, không ghi vào file nào ([`aws-security.md`](../explanation/aws-security.md#cấu-trúc-org-theo-aws-sra)):

```sh
sec()  { AWS_PROFILE=anhnv-security-ro aws --region ap-southeast-1 "$@"; }   # Security Hub, aggregator ở region nhà
logs() { AWS_PROFILE=anhnv-log-ro aws --region ap-southeast-1 "$@"; }        # bucket log ở region nhà
LOG=$SVP_AWS_LOG_ACCOUNT_ID
ORG=$(AWS_PROFILE=anhnv-security-ro aws organizations describe-organization --region us-east-1 --query Organization.Id --output text)
AWS_PROFILE=anhnv-security-ro aws sts get-caller-identity --region ap-southeast-1   # account là svp-security
```

## Ý nghĩa và tác động tới người dùng

Một sự kiện bảo mật xảy ra ở một account của org, hay GuardDuty, IAM Access Analyzer có finding mới mức HIGH, CRITICAL. Email ghi loại sự kiện
(`AWS API Call via CloudTrail`, `AWS Console Sign In via CloudTrail`), tên lệnh, account, region, principal, mã lỗi; email finding ghi mức,
dịch vụ, tiêu đề, account, region. Phân loại theo nhóm của rule:

| Nhóm | Rule | Nhận ra trong email | Nghĩa |
| --- | --- | --- | --- |
| Root | `svp-security-root-signin`, `svp-security-root-session` | `ConsoleLogin` với principal root; `AssumeRoot` | Root đăng nhập console, hay management mở phiên root trên account thành viên (chỉ bắt phiên mở ở `ap-southeast-1`, `us-east-1`). Ngoài break-glass có chủ đích là sự cố |
| Organizations | `svp-security-org` (chỉ management) | `AttachPolicy`, `UpdatePolicy`, `DetachPolicy`, `MoveAccount`, `RegisterDelegatedAdministrator`… | Guardrail, cấu trúc org, delegated admin hay root tập trung đổi. Có `apply` của `aws/org` cùng lúc là bình thường |
| Trail | `svp-security-trail` | `StopLogging`, `DeleteTrail`, `UpdateTrail`, `PutEventSelectors` | Trail bị dừng hay đổi; có mã lỗi là bị chặn, không mã lỗi chỉ hợp lệ khi đang `apply` `aws/org` |
| Rule cảnh báo | `svp-security-alert-rules` | `PutRule`, `DisableRule`, `DeleteRule`, `PutTargets`, `RemoveTargets` trên tên `svp-security-*` | Đường cảnh báo bị đổi; không mã lỗi chỉ hợp lệ khi đang `apply` `aws/baseline` |
| Dịch vụ phát hiện | `svp-security-detection` | lệnh của GuardDuty, Security Hub, Config, Access Analyzer, không mã lỗi | Dịch vụ phát hiện bị tắt hay đổi thành công; hợp lệ khi đang `apply` `aws/security`, `aws/baseline` |
| Bị guardrail từ chối | `svp-security-denied-iam`, `svp-security-denied-detection`, `svp-security-denied-storage` | mã lỗi `AccessDenied…` hay `Client.UnauthorizedOperation` | Ai đó thử việc mà `svp-protect-baseline`, `svp-deny-iam-users` chặn: tạo IAM user, access key, tắt dịch vụ phát hiện, đổi S3 BPA, EBS mặc định, key `alias/svp-ebs`. Guardrail đã giữ; câu hỏi là ai thử và vì sao |
| Đổi quản trị | `svp-security-admin-iam`, `svp-security-admin-kms-s3`, `svp-security-admin-sso` (management, `svp-log-archive`, `svp-security`) | lệnh IAM, KMS, S3, Identity Center, không mã lỗi | IAM, key, bucket hay permission set của ba account không chạy workload đổi; hợp lệ khi đang `apply` root cấp org |
| Finding | `svp-security-findings` | `svp-security finding HIGH` hay `CRITICAL` | GuardDuty thấy hành vi đáng ngờ (credential dùng lạ, trao đổi với địa chỉ độc hại, malware), hay Access Analyzer thấy tài nguyên chia sẻ ra ngoài org |

Người dùng của lab không thấy gì: cảnh báo không đổi đường request. Tác động là ở account: credential, log hay dữ liệu có thể đang bị dùng.
Control FSBP, CIS bị FAILED không gửi email; đọc định kỳ ở mục [Đọc bảng Security Hub định kỳ](#đọc-bảng-security-hub-định-kỳ).

## Kiểm tra nhanh (5 phút)

Compose, k3d: không có cảnh báo này (không có account AWS).

AWS (người học chạy), theo thứ tự:

```sh
# 1. Có apply nào của người học đang chạy hay vừa chạy không? Có thì so tên lệnh trong email với plan đã đọc.
# 2. Finding mới, còn mở, HIGH và CRITICAL của mọi account (Security Hub gom us-east-1 về region nhà)
sec securityhub get-findings --filters '{"SeverityLabel":[{"Value":"HIGH","Comparison":"EQUALS"},{"Value":"CRITICAL","Comparison":"EQUALS"}],"RecordState":[{"Value":"ACTIVE","Comparison":"EQUALS"}],"WorkflowStatus":[{"Value":"NEW","Comparison":"EQUALS"}]}' --sort-criteria Field=UpdatedAt,SortOrder=desc --query 'Findings[].[UpdatedAt,Severity.Label,ProductName,AwsAccountId,Region,Title,Id,ProductArn]' --output text --max-items 20
# Bước 3, 4 chạy ở region của finding (cột Region ở bước 2)
FR=ap-southeast-1   # hay us-east-1
fr() { AWS_PROFILE=anhnv-security-ro aws --region "$FR" "$@"; }
# 3. Chi tiết finding GuardDuty
DET=$(fr guardduty list-detectors --query 'DetectorIds[0]' --output text)
fr guardduty list-findings --detector-id "$DET" --finding-criteria '{"Criterion":{"service.archived":{"Eq":["false"]},"severity":{"Gte":7}}}' --max-results 20
fr guardduty get-findings --detector-id "$DET" --finding-ids <id> --query 'Findings[].[Type,Severity,AccountId,Resource.ResourceType,Service.Action.ActionType,Service.Count,Service.EventFirstSeen,Service.EventLastSeen]' --output text
# 4. Finding Access Analyzer còn mở (tài nguyên chia sẻ ra ngoài org)
AA=$(fr accessanalyzer list-analyzers --type ORGANIZATION --query 'analyzers[0].arn' --output text)
fr accessanalyzer list-findings-v2 --analyzer-arn "$AA" --filter '{"status":{"eq":["ACTIVE"]}}' --query 'findings[].[updatedAt,resourceOwnerAccount,resourceType,resource,findingType]' --output text
```

Sự kiện CloudTrail của email (nhóm khác Finding): đọc bản ghi đủ trong bucket trail của Log Archive, ở thư mục của region trong email (nơi
CloudTrail ghi sự kiện: IAM, Organizations ở `us-east-1`; đăng nhập root ở `us-east-1`, với management có thể ở `us-east-2`, `us-west-2`).

```sh
# 5. Tệp log của account và region trong email, hôm nay (UTC); đổi ngày nếu email cũ
ACC=<account trong email>; REG=<region trong email>
P="s3://svp-cloudtrail-$LOG-ap-southeast-1/AWSLogs/$ORG/$ACC/CloudTrail/$REG/$(date -u +%Y/%m/%d)/"
logs s3 ls "$P" | tail -n 20
# 6. Bản ghi của lệnh trong email: ai, từ IP nào, qua phiên nào, kết quả
EV=<tên lệnh trong email>
for f in $(logs s3 ls "$P" | awk '{print $4}' | tail -n 12); do logs s3 cp "$P$f" - | gunzip | jq -c --arg ev "$EV" '.Records[] | select(.eventName==$ev) | {eventTime, eventName, arn: .userIdentity.arn, src: .sourceIPAddress, ua: .userAgent, errorCode, errorMessage}'; done
```

Trail giao log vài phút sau sự kiện: bước 6 chưa thấy gì thì chờ rồi chạy lại. Cấu hình hiện tại của account stg, prd (biến `ENV`):

```sh
ENV=stg; ID=$([ "$ENV" = stg ] && echo "$SVP_AWS_STG_ACCOUNT_ID" || echo "$SVP_AWS_PRD_ACCOUNT_ID")
ro() { AWS_PROFILE=anhnv-$ENV-ro aws --region ap-southeast-1 "$@"; }
ro sts get-caller-identity   # account là $ID
# 7. Baseline còn nguyên: bốn cờ true, EBS mã hoá mặc định true, recorder đang ghi
ro s3control get-public-access-block --account-id "$ID" --query 'PublicAccessBlockConfiguration'
ro ec2 get-ebs-encryption-by-default
ro configservice describe-configuration-recorder-status --query 'ConfigurationRecordersStatus[].[name,recording,lastStatus]' --output text
# 8. IAM user của account (phải rỗng: svp-deny-iam-users chặn tạo)
AWS_PROFILE=anhnv-$ENV-ro aws iam list-users --region us-east-1 --query 'Users[].[UserName,CreateDate]' --output text
```

Management không có permission set chỉ đọc: cấu hình của nó đọc bằng `anhnv-sso`, chỉ lệnh `get`, `describe`, `list`.

## Nguyên nhân thường gặp

1. **`apply` của chính người học**: tên lệnh khớp plan vừa áp, principal là `OrganizationAccountAccessRole` (root cấp org) hay phiên
   `AWSReservedSSO_…` của người học, thời điểm trong lúc `apply`. Không cần làm gì thêm.
2. **Phép thử guardrail hay cảnh báo thử** của runbook `org-security-setup.md`: lệnh bị từ chối ở stg, prd với tên probe của runbook đó.
3. **Lệnh tay vượt guardrail** (script cũ, console): bị từ chối, principal là `SvpAdmin` của người học. Sửa cách làm qua Terraform.
4. **Finding GuardDuty của buổi**: node, bastion, pod làm việc lạ với GuardDuty (tải image, port scan của công cụ diễn tập). Đọc `Type`,
   `Resource` ở bước 3; trùng với việc của buổi thì ghi lại rồi chặn email lặp (mục Giảm thiểu).
5. **Credential hay phiên bị dùng ngoài người học**: principal, IP (`src`), `userAgent` ở bước 6 không phải của máy người học; root đăng nhập mà
   không ai mở break-glass. Đây là sự cố: sang Giảm thiểu ngay.

## Giảm thiểu

Ghi, người học quyết; mỗi lệnh ghi chạy sau `aws sts get-caller-identity` với cùng profile.

- **Nghi credential, phiên bị lộ**: Identity Center (console của management, region của Identity Center) → Users → người học → tắt
  user hay xoá active session; phiên role đã cấp còn sống tới hết hạn của permission set (ADR-0059 §8). Không đăng nhập được nữa, hay root
  đăng nhập lạ: theo [`break-glass.md`](https://github.com/anhnvcoder/svp-infra/blob/main/docs/runbooks/break-glass.md) của `svp-infra`.
- **Env stg, prd bị chiếm**: gỡ env theo runbook buổi (`session-stg.md`, `session-prd.md` của `svp-infra`), sau khi đã chép bước 3, 6 ra ngoài
  làm bằng chứng. Log ở Log Archive còn sau khi env mất.
- **Guardrail cản việc cần làm** (không phải tấn công): sửa policy ở `aws/org` qua plan, không tắt guardrail bằng tay; management không chịu SCP.
- **Email lặp của một finding đã xử lý**: đặt `Workflow.Status` `NOTIFIED` (đã xem, còn theo dõi) hay `SUPPRESSED` (không phải lỗi) ở
  `svp-security`; `SvpReadOnly` không ghi được, nên đi qua role truy cập org từ management (ADR-0060 §10):

```sh
(
  eval "$(AWS_PROFILE=anhnv-sso aws sts assume-role --region ap-southeast-1 --role-arn "arn:aws:iam::$SVP_AWS_SECURITY_ACCOUNT_ID:role/OrganizationAccountAccessRole" --role-session-name svp-triage --query 'Credentials.[AccessKeyId,SecretAccessKey,SessionToken]' --output text | awk '{print "export AWS_ACCESS_KEY_ID="$1" AWS_SECRET_ACCESS_KEY="$2" AWS_SESSION_TOKEN="$3}')"
  aws sts get-caller-identity --region ap-southeast-1   # account là svp-security
  aws securityhub batch-update-findings --region ap-southeast-1 --finding-identifiers Id=<Id của bước 2>,ProductArn=<ProductArn của bước 2> --workflow Status=SUPPRESSED --note Text='<lý do>',UpdatedBy=<tên>
)
```

Dấu ngoặc giữ credential tạm trong subshell, không còn trong terminal sau đó.

## Khôi phục và xác nhận

- Bước 7 cho baseline nguyên vẹn ở stg, prd; bước 8 rỗng; bước 2 không còn finding `NEW` của sự cố.
- Thay đổi lạ đã hoàn tác bằng `apply` của root sở hữu nó, và plan lần sau của root đó `No changes`.
- Cảnh báo thử của `org-security-setup.md` vẫn tới email (đường cảnh báo còn chạy).

## Leo thang

- Bước 6 cho thấy principal, IP lạ; root đăng nhập không ai mở; finding CRITICAL không giải thích được bằng việc của buổi: sự cố bảo mật. Giữ
  bằng chứng (bước 2, 3, 6), làm Giảm thiểu, mở postmortem ([mẫu](../postmortems/README.md)).
- Cần root của account thành viên, hay Identity Center không vào được: [`break-glass.md`](https://github.com/anhnvcoder/svp-infra/blob/main/docs/runbooks/break-glass.md).
- Nghi account AWS bị chiếm mà không tự khoá được: mở case với AWS Support (AWS Security) từ management.

## Liên kết

- Thiết kế: [`aws-security.md`](../explanation/aws-security.md), [ADR-0059](../adr/0059-org-structure-guardrails.md) (guardrail, permission set,
  break-glass), [ADR-0060](../adr/0060-org-detection-logging.md) §10 và phụ lục (event pattern đủ), [`threat-model.md`](../threat-model.md#412-tổ-chức-aws).
- Console: Security Hub CSPM, GuardDuty, IAM Access Analyzer, Config aggregator `svp-org` ở account `svp-security`; bucket
  `svp-cloudtrail-<log>-ap-southeast-1` ở `svp-log-archive`.
- Diễn tập: phép thử guardrail và cảnh báo thử ở mục kiểm sau áp của
  [`org-security-setup.md`](https://github.com/anhnvcoder/svp-infra/blob/main/docs/runbooks/org-security-setup.md) (`svp-infra`).

## Đọc bảng Security Hub định kỳ

Control FAILED của FSBP, CIS không tới email. Mỗi tuần, và sau mỗi buổi stg, prd, đọc control FAILED còn mở của mọi account, hai region. Lệnh
không đặt `--max-items`: CLI đọc hết mọi trang.

```sh
# Số finding FAILED theo control và mức
sec securityhub get-findings --filters '{"ComplianceStatus":[{"Value":"FAILED","Comparison":"EQUALS"}],"RecordState":[{"Value":"ACTIVE","Comparison":"EQUALS"}],"WorkflowStatus":[{"Value":"NEW","Comparison":"EQUALS"}]}' --query 'Findings[].[Compliance.SecurityControlId,Severity.Label]' --output text | sort | uniq -c | sort -rn
# Tài nguyên FAILED của một control trong danh sách trên
C=<SecurityControlId, ví dụ S3.9>
sec securityhub get-findings --filters '{"ComplianceSecurityControlId":[{"Value":"'"$C"'","Comparison":"EQUALS"}],"ComplianceStatus":[{"Value":"FAILED","Comparison":"EQUALS"}],"RecordState":[{"Value":"ACTIVE","Comparison":"EQUALS"}],"WorkflowStatus":[{"Value":"NEW","Comparison":"EQUALS"}]}' --query 'Findings[].[AwsAccountId,Region,Resources[0].Id]' --output text
```

Console: Security Hub CSPM của `svp-security` (region nhà) → Controls, lọc `Failed`. Mỗi control FAILED: sửa trong Terraform; không áp dụng cho
lab thì thêm vào danh sách tắt có lý do ở `security-hub.tf` của `aws/security`, qua ADR. Tài nguyên của buổi đã gỡ để lại finding `ARCHIVED`, không
cần làm gì.
