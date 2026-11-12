# 0059. AWS Organizations theo AWS SRA: account Log Archive và Security Tooling, OU `Security`, `Workloads/Prod`, `Workloads/NonProd`; baseline mỗi account áp từ management qua role truy cập org; SCP, RCP data perimeter, declarative policy EC2, tag policy gắn ở root; root tập trung; permission set chỉ đọc; NACL không mở 22/3389

- Trạng thái: Chấp nhận
- Ngày: 2026-11-12
- Người quyết: người học (duyệt kế hoạch nền bảo mật cấp org 2026-11-12), AI đề xuất thiết kế, nội dung policy và đối chiếu tài liệu AWS

## Bối cảnh và vấn đề

- [0048](0048-prd-aws.md) §1 dựng org gồm management và `svp-stg`, `svp-prd` ở OU `Workloads`; ba SCP gắn OU đó; trail org ghi vào bucket của
  management; Log Archive, Audit account và permission set chỉ đọc để sau; `SvpAdmin` phiên 4 giờ là quyền duy nhất.
- Rà AWS theo chuẩn ngành (AWS SRA, CIS AWS Foundations v5.0.0, Security Hub FSBP) thấy thiếu: account bảo mật riêng, SCP chặn IAM user và
  chặn tắt dịch vụ bảo mật, RCP, declarative policy, tag policy, centralized root access, quyền chỉ đọc, NACL chặn 22/3389 (EC2.21), CMK cho
  bucket state của management. Phát hiện, log và cảnh báo ở [0060](0060-org-detection-logging.md).
- Hiện trạng đọc 2026-11-12 (chỉ đọc): policy type SCP, RCP đã bật; trusted access chỉ `cloudtrail`, `sso`; không delegated admin; trusted access
  IAM chưa bật; dưới root có OU `Workloads` (của `aws/org`) và `Production`, `Development` (hai account demo đã đóng, `SUSPENDED`); không dịch vụ
  bảo mật, EBS mã hoá mặc định, S3 BPA cấp account, liên hệ SECURITY ở account nào.
- Ràng buộc như 0048: repo public, AI không chạy lệnh chạm account, buổi dựng và gỡ trong 4 giờ; dịch vụ cấp org tính tiền cả khi không có buổi.

## Yếu tố quyết định

- AWS SRA [N1]: management chỉ quản trị; log và công cụ bảo mật ở account riêng mà admin của workload không sửa được.
- Guardrail không cản buổi (dựng và gỡ trong 4 giờ); prd chỉ chặt hơn stg ở chỗ prd khác stg ([0055](0055-environment-matrix.md)).
- Baseline bảo mật chỉ đổi qua một đường có review: Terraform chạy từ management.
- Công cụ chính là Terraform thuần ([0034](0034-aws-stage7.md) §2); chi phí lúc không buổi có nguồn và dưới trần ở 0060.

## Phương án đã cân nhắc

Trạng thái ngành, được, mất và nguồn: [phụ lục](appendix/0059-org-structure-guardrails.md#phương-án).

- **Nhiều account theo SRA, Terraform thuần, ba root mới chạy từ management qua `OrganizationAccountAccessRole`** (khuôn Account Factory).
- Giữ một OU, không account bảo mật: log và finding nằm ở management hay account workload; admin workload chạm được chúng; lệch SRA.
- AWS Control Tower: hiện hành, dựng sẵn account log và audit, control, trail và Config do Control Tower quản (ngoài state Terraform);
  Account Factory for Terraform cần landing zone Control Tower và thêm một account quản AFT.
- Landing Zone Accelerator on AWS: hiện hành, đủ SRA; viết bằng AWS CDK, AWS khuyên dựng trên Control Tower: công cụ IaC thứ hai cạnh Terraform.

## Kết quả quyết định

Chọn nhiều account theo SRA bằng Terraform thuần, vì đạt SRA mà mọi thay đổi vẫn là `plan` đọc được trong một công cụ. Statement đủ của mọi
policy, bảng đối chiếu RCP và chi tiết từng §: [phụ lục](appendix/0059-org-structure-guardrails.md).

### 1. Account và OU

- Management (profile `anhnv-sso`): Organizations, Identity Center, trail org, policy, budget, state của `aws/bootstrap`, `aws/org`; không workload.
- Account mới `svp-log-archive` (Log Archive) và `svp-security` (Security Tooling) ở OU `Security` dưới root; OU `Workloads` (có sẵn) có hai OU
  con `Prod` (`svp-prd`) và `NonProd` (`svp-stg`). Email root của account mới ở `account_emails` (khoá `log-archive`, `security`) của
  `org.auto.tfvars`, không commit; `close_on_deletion = false`, `prevent_destroy`. Biến terminal `SVP_AWS_LOG_ACCOUNT_ID`,
  `SVP_AWS_SECURITY_ACCOUNT_ID` từ output của `aws/org`.
- `svp-stg`, `svp-prd` giữ địa chỉ `aws_organizations_account.member["stg"|"prd"]`; đổi `parent_id` là MoveAccount tại chỗ.
- Không import gì: tổ chức, OU `Workloads`, hai account đã ở state `aws/org`; không dịch vụ nào bật tay. OU `Production`, `Development` và hai
  account demo đã đóng (`SUSPENDED`) ở ngoài Terraform, không đổi; khi hai account không còn trong org, người học xoá hai OU rỗng (README `aws/org`).

### 2. Root chạy từ management và vai trò triển khai baseline

- Ba root mới `aws/log-archive`, `aws/security`, `aws/baseline` chạy bằng `anhnv-sso`, state ở bucket của `aws/bootstrap`; mỗi account đích một
  provider assume `OrganizationAccountAccessRole` (`allowed_account_ids` đúng account đó), tài nguyên `us-east-1` bằng đối số `region`.
- Hai account mới không có profile SSO ghi, không bucket state riêng: baseline áp từ management, như `AWSControlTowerExecution` của Control Tower.
- `OrganizationAccountAccessRole` (chỉ management assume được) là principal duy nhất được miễn ở `svp-protect-baseline` (§3); `SvpAdmin` ở
  stg, prd không đổi được baseline.

### 3. Bộ SCP

- Gắn root (mọi account thành viên; SCP không áp lên management [N2]): `svp-deny-leave-organization`, `svp-protect-cloudtrail`,
  `svp-deny-other-regions` (nội dung giữ, chuyển từ OU `Workloads` lên root), `svp-protect-baseline`, `svp-deny-iam-users`. Gắn OU `Prod`:
  `svp-prod-guardrails`. Chỉ `Deny`; mỗi đích ≤ 10 SCP, mỗi SCP ≤ 10 240 ký tự [N3].
- `svp-protect-baseline`, miễn `ArnNotLike aws:PrincipalARN arn:aws:iam::*:role/OrganizationAccountAccessRole`: S3 BPA cấp account; EBS mã hoá
  mặc định và key mặc định; recorder, delivery channel, aggregator của Config; tắt, rời, đổi detector, bộ lọc, IP tin cậy, đích xuất của GuardDuty;
  tắt, rời, đổi chuẩn, control, aggregator, chính sách tập trung, automation rule của Security Hub; xoá analyzer, archive rule của Access Analyzer;
  rule EventBridge `svp-security-*` và role `svp-security-*`; mọi thay đổi IAM trên `OrganizationAccountAccessRole`; CMK EBS (§9) theo tag
  `Stack=security-baseline` và alias `alias/svp-ebs`. Không chặn tạo, xoá plan Malware Protection, flow log, logging WAF: buổi tạo và gỡ chúng.
- `svp-deny-iam-users`: `iam:CreateUser`, `CreateAccessKey`, `CreateLoginProfile`, `UpdateLoginProfile` trên `arn:aws:iam::*:user/*`, không
  điều kiện, không miễn. SCP áp lên cả root của account thành viên [N2], nhưng task policy `IAMCreateRootUserPassword` của `sts:AssumeRoot` chỉ cho
  `iam:CreateLoginProfile` trên `arn:aws:iam::*:root` [N4]: statement không phủ ARN đó nên không chặn task.
- `svp-prod-guardrails` chặn Spot: `ec2:RunInstances` trên `instance` khi `ec2:InstanceMarketType` = `spot`, và `ec2:RequestSpotInstances`,
  `RequestSpotFleet`. `ec2:CreateFleet` (Karpenter) không có khoá `ec2:InstanceMarketType` ở loại `instance` [N5], nên SCP không chặn được
  Spot qua Karpenter: chặn đó vẫn là NodePool prd on-demand ([0056](0056-eks-platform-ha.md)). Đối chiếu bước gỡ buổi prd (`teardown.tfvars`,
  `pre-destroy.sh`, mục kết thúc của `session-prd.md`): không bước nào tạo EC2, nên không statement nào chặn gỡ.

### 4. RCP data perimeter

- Một RCP `svp-data-perimeter` gắn root (≤ 5 120 ký tự, ≤ 5 RCP mỗi đích kể cả `RCPFullAWSAccess` [N3]), theo mẫu identity perimeter của AWS
  [N6]: S3, KMS, Secrets Manager, SQS và các hành động STS của mẫu từ chối principal ngoài org (`aws:PrincipalOrgID`), trừ principal dịch vụ
  (`aws:PrincipalIsAWSService`); S3, KMS, Secrets Manager, SQS, STS từ chối dịch vụ AWS hành động thay tài nguyên ngoài org (`aws:SourceOrgID`, chỉ
  khi có `aws:SourceAccount`); mọi request không TLS bị từ chối.
- Không ngoại lệ riêng nào: không `aws:PrincipalAccount` (mẫu cần nó cho log truy cập ELB, FinSpace: không dùng), không tag `dp:exclude:*` (ai gắn
  tag cũng lách được). `AssumeRoleWithSAML` (Identity Center), `AssumeRoleWithWebIdentity`, `TagSession` không nằm trong statement principal [N6].
- RCP không áp lên tài nguyên của management, không đổi quyền của service-linked role [N7]. Bảng đối chiếu mọi luồng ở phụ lục.
- Malware Protection for EC2 trên volume CMK EBS (§9): service-linked role của GuardDuty tạo grant cho account dịch vụ của GuardDuty [N8]; account đó
  ngoài org và không phải principal dịch vụ, tài liệu không nêu ngoại lệ RCP cho nó: không thêm ngoại lệ, volume CMK EBS không được quét (0060 §2).

### 5. Declarative policy EC2

Policy `svp-ec2-baseline` (`DECLARATIVE_POLICY_EC2`) gắn root [N9]: chặn chia sẻ public AMI mới (`block_new_sharing`) và mọi snapshot EBS public
(`block_all_sharing`); IMDS mặc định `http_tokens = required`, hop limit 1 (như node EKS, Karpenter, bastion), `http_tokens_enforced = enabled`
(launch IMDSv1 bị từ chối); serial console tắt. Không chặn VPC public: NAT, NLB cần Internet gateway.

### 6. Tag policy

Policy `svp-tags` (`TAG_POLICY`) gắn root, khoá đúng hoa thường [N10]: `Project` = `svp`; `Env` = `stg`, `prd`; `ManagedBy` = `terraform`;
`Stack` = `bootstrap`, `org`, `baseline`, `log-archive`, `security`, `security-baseline`, `stg`, `prd`. Giá trị đối chiếu với `default_tags` của
mọi root, tag `Project` của EC2NodeClass Karpenter; Load Balancer Controller, VPC CNI, ExternalDNS không gắn bốn khoá này. `enforced_for`:
`ec2:ALL_SUPPORTED`, `eks:ALL_SUPPORTED`, `kms:ALL_SUPPORTED` (thao tác gắn giá trị sai bị từ chối); loại khác chỉ báo tuân thủ. Tag policy không
bắt buộc có tag.

### 7. Root tập trung và break-glass

- `aws/org` bật trusted access `iam.amazonaws.com` và `RootCredentialsManagement`, `RootSessions` [N11]: account thành viên không giữ mật khẩu,
  access key, MFA của root; việc chỉ root làm đi qua `sts:AssumeRoot` từ management với một task policy, phiên tối đa 15 phút [N12].
- Root của management: MFA phần cứng cất ngoài máy, là đường break-glass khi Identity Center hỏng.
- Việc cần root đầy đủ ở account thành viên: `IAMCreateRootUserPassword`, khôi phục mật khẩu qua email root, làm việc, rồi
  `IAMDeleteRootUserCredentials`. SCP chặn việc cần thì tháo, sửa từ `aws/org` (management không chịu SCP). Mỗi bước sinh cảnh báo (0060 §10).
  Quy trình: runbook `break-glass.md` của `svp-infra`.

### 8. Permission set

- `SvpAdmin` (`AdministratorAccess`) phiên `PT1H` thay `PT4H`, gán `svp-stg`, `svp-prd`. Phiên ngắn không cắt `apply` dài: với cấu hình
  `sso-session`, SDK lấy lại credential role từ token SSO tới hết phiên cổng truy cập [N13].
- `SvpReadOnly` (`ViewOnlyAccess` + `SecurityAudit`, `PT4H`) gán `svp-stg`, `svp-prd`, `svp-security`; inline chỉ thêm hành động đọc:
  `logs:FilterLogEvents`, `GetLogEvents`, `StartQuery`, `StopQuery`, `GetQueryResults` (log control plane EKS, log RDS khi điều tra). Không ghi
  gì, kể cả workflow của finding (0060 §10); không đọc object S3, giá trị secret, dữ liệu bảng.
- `SvpLogReader` (`PT4H`) chỉ ở `svp-log-archive`: `ViewOnlyAccess`, `s3:GetObject`, `s3:ListBucket` trên bucket log, `kms:Decrypt` qua S3 của
  hai region trên key `alias/svp-log-archive`.
- Profile mới `anhnv-stg-ro`, `anhnv-prd-ro`, `anhnv-security-ro`, `anhnv-log-ro` (`aws configure sso`).

### 9. Baseline bảo mật và CMK EBS

- Module `security-baseline`, root `aws/baseline` gọi một lần mỗi account (năm account): S3 BPA cấp account bốn cờ `true`; EBS mã hoá mặc định ở hai
  region; Config recorder và delivery channel, rule chuyển sự kiện (0060 §4, §10). Khác biệt giữa account (key EBS, nhóm rule, region của rule
  đăng nhập root: management ba region) là dữ liệu của bảng account trong root.
- CMK EBS: chỉ `svp-stg`, `svp-prd`, `ap-southeast-1`; alias `alias/svp-ebs`, rotation, chờ xoá 30 ngày; key policy như `aws/ebs` (mọi principal của
  account qua `ec2.ap-southeast-1.amazonaws.com`, kể cả service-linked role AutoScaling của node group) cộng quản trị bởi IAM của account. Region,
  account khác dùng `aws/ebs`.

### 10. NACL

Mọi NACL (public, private, database, mặc định) không có entry allow inbound từ `0.0.0.0/0` hay `::/0` với TCP, UDP hay `-1` phủ 22 hay 3389
(mục NACL của CIS, Security Hub EC2.21: rule Config của nó xét cả TCP lẫn UDP [N14]). Mỗi tầng một NACL riêng; NACL mặc định không còn allow.
Từ Internet: TCP và UDP 1024–3388, 3390–65535 (trả về, cổng target NLB giữ IP client), TCP 443 ở public; ICMP mọi loại. Từ CIDR VPC và
outbound tới mọi đích: TCP, UDP, ICMP, không giao thức IP khác (trong VPC không gì dùng); không entry deny. Giá: ở subnet public, kết nối TCP
hay UDP qua NAT gateway được NAT gán cổng nguồn 3389 (NAT dùng 1024–65535) mất gói trả về, khoảng 1/64 500 kết nối, client thử lại; subnet
private không mất gì (cổng tạm Linux 32768–60999). Không chọn "chỉ private, database và tắt EC2.21": Security Hub không tắt control theo tài
nguyên, CIS đòi mọi NACL.

### 11. Liên hệ SECURITY, CMK của bucket state

- `aws_account_alternate_contact` loại `SECURITY` cho management và bốn account thành viên từ `aws/org` (trusted access `account.amazonaws.com`);
  tên, chức danh, email, điện thoại ở biến `security_contact` (sensitive) của `org.auto.tfvars`.
- Bucket state của `aws/bootstrap` chuyển SSE-KMS với key `alias/svp-tfstate` của management (rotation, chờ xoá 30 ngày, Bucket Key); bỏ ngoại
  lệ trivy AWS-0132; `backend.hcl` có `kms_key_id` như `account-baseline`.

### 12. OIDC cho `terraform plan` trên PR: ngoài phạm vi

Không làm ở đây; luật "CI không credential" của `infra/AGENTS.md` và 0034 §2 giữ. Lý do: (a) plan cần role chỉ đọc ở năm account trong khi ba
root mới assume `OrganizationAccountAccessRole` (admin), nên cần role plan thứ hai mỗi account và cách root chọn role; (b) repo public: log và
artifact Actions ai cũng đọc, plan in ARN, account ID, domain; (c) Infracost đọc cùng plan JSON. Làm ở một quyết định riêng cùng Infracost.

### Hệ quả

- Tốt: log, finding và baseline nằm ngoài tầm admin của workload; root thành viên không có credential; dữ liệu S3, KMS, Secrets Manager, SQS
  không tới được principal ngoài org; mọi đổi baseline đi qua `plan` của Terraform.
- Xấu: thêm hai account và ba root; management là đường duy nhất vào hai account mới (admin của management là admin mọi account); `SvpAdmin`
  hết phiên mỗi giờ khi không dùng `sso-session`; Spot qua `CreateFleet` không bị SCP chặn; volume CMK EBS không được GuardDuty quét malware;
  declarative và tag policy gắn root áp cả management [N18]: việc khác ở management cũng không launch được IMDSv1, không dùng serial console,
  không chia sẻ AMI, snapshot public, không dùng bốn khoá tag với giá trị khác; NACL làm rơi ~1/64 500 kết nối NAT.
- Xem lại khi: AWS cho khoá điều kiện Spot ở `CreateFleet`, hay ngoại lệ RCP cho Malware Protection for EC2; cần OIDC plan (cùng Infracost); có
  người thứ hai cần quyền; thêm account workload.

## Xác nhận

- Lúc quyết chưa hiện thực. Kiểm tĩnh: `make check` của `svp-infra` (test module `org-policies`: tập policy, đích, chỉ `Deny`, cỡ, miễn đúng một
  role, điều kiện RCP; test `network`: NACL; test `security-baseline`).
- Sau áp: GuardDuty, Security Hub, Config, Access Analyzer có delegated admin `svp-security`; mọi probe của phép thử guardrail ở runbook
  `org-security-setup.md` bị từ chối với `explicit deny in a service control policy` (hay declarative policy); `iam list-organizations-features`
  có hai tính năng; root bốn account thành viên không mật khẩu, access key (`sts assume-root` với `IAMAuditRootUserCredentials`).
- Buổi stg, prd: node, bastion launch được với IMDSv2 bắt buộc; NLB, NAT, MSK, RDS, External Secrets chạy dưới RCP và NACL mới.

## Hiện thực ở

- `svp-infra`: `aws/org/` (OU, account, trusted access, delegated admin, `root-access.tf`, `contacts.tf`, `identity-center.tf`; §1, §3–§8, §11),
  `aws/modules/org-policies/` (§3–§6), `aws/log-archive/`, `aws/security/` (§2), `aws/baseline/`, `aws/modules/security-baseline/` (§2, §9),
  `aws/modules/network/` (§10), `aws/bootstrap/` (§11), `docs/runbooks/org-security-setup.md`, `docs/runbooks/break-glass.md` (§7).
- Repo code: `docs/explanation/aws-security.md`, `docs/threat-model.md`.

## Nguồn

Đọc 2026-11-12; đủ [N1]–[N19] ở phụ lục. [N1] <https://docs.aws.amazon.com/prescriptive-guidance/latest/security-reference-architecture/architecture.html>,
[N2] <https://docs.aws.amazon.com/organizations/latest/userguide/orgs_manage_policies_scps.html>,
[N6] <https://github.com/aws-samples/data-perimeter-policy-examples/tree/main/resource_control_policies>.

## Thông tin thêm

Phụ lục: [`appendix/0059-org-structure-guardrails.md`](appendix/0059-org-structure-guardrails.md) (phương án, statement đủ của mọi policy, bảng
đối chiếu RCP, permission set, nguồn).

### Chỉnh bởi

- §4, §5, §10: [0061](0061-edge-cloudfront-waf-acm.md): luồng RCP mới (giao log CloudFront v2 vào Log Archive, `dnssec-route53` dùng key KMS, CloudFront VPC origin) qua RCP không ngoại lệ; Internet gateway còn cho NAT và CloudFront VPC origin, không còn NLB; NACL public không còn TCP 443 từ Internet, thêm NACL tầng edge chỉ nhận từ CIDR VPC.
