# 0060. Phát hiện liên tục toàn org do account Security Tooling quản (GuardDuty, Security Hub CSPM cấu hình tập trung với FSBP và CIS v5.0.0, AWS Config ghi liên tục, IAM Access Analyzer); log của org về account Log Archive; sự kiện bảo mật và finding nghiêm trọng qua EventBridge tới SNS email; Cost Anomaly Detection và tag phân bổ chi phí trong code

- Trạng thái: Chấp nhận
- Ngày: 2026-11-12
- Người quyết: người học (duyệt kế hoạch nền bảo mật cấp org 2026-11-12), AI đề xuất cấu hình, danh sách sự kiện, retention và bảng giá

## Bối cảnh và vấn đề

- Org chưa có dịch vụ phát hiện nào: không GuardDuty, Security Hub, Config, Access Analyzer ở account nào (đọc 2026-11-12); trail org ghi vào
  bucket của management ([0048](0048-prd-aws.md) §1), không data event; flow log vào CloudWatch Logs của env; web ACL không ghi log
  ([0052](0052-cloudfront-flat-rate-free.md) §3); không cảnh báo khi root đăng nhập, policy đổi hay trail dừng; Cost Anomaly Detection bật tay
  ([0034](0034-aws-stage7.md) §3), chưa có monitor.
- [0059](0059-org-structure-guardrails.md) dựng account `svp-security` (Security Tooling), `svp-log-archive` (Log Archive), root `aws/security`,
  `aws/log-archive`, `aws/baseline` chạy từ management.
- Dịch vụ cấp org tính tiền cả khi không có buổi; env stg, prd chỉ sống vài giờ mỗi buổi.

## Yếu tố quyết định

- AWS SRA [N1]: Security Tooling là delegated admin của dịch vụ bảo mật; Log Archive giữ trail org, flow log, log WAF; CIS AWS Foundations
  v5.0.0 và FSBP làm chuẩn đo [N6].
- Tài nguyên của buổi (vài giờ) phải được ghi và đánh giá; cảnh báo phải tới người khi cluster không chạy.
- Chi phí lúc không buổi có nguồn, dưới $30 mỗi tháng; mỗi khoản giữ tối thiểu mà vẫn đúng chuẩn.

## Phương án đã cân nhắc

Trạng thái ngành, được, mất: [phụ lục](appendix/0060-org-detection-logging.md#phương-án).

- **Dịch vụ AWS gốc, delegated admin `svp-security`, Security Hub CSPM cấu hình tập trung, Config `CONTINUOUS`, cảnh báo EventBridge → SNS.**
- Security Hub bản hợp nhất mới thay CSPM: AWS khuyên bật cả hai, tính phí theo tài nguyên; thêm một dịch vụ mới cho lab chưa cần tương quan.
- Config ghi hằng ngày (periodic): rẻ hơn mỗi item ghi được, nhưng chỉ ghi trạng thái mới nhất mỗi 24 giờ [N3]: tài nguyên của buổi có thể không
  bao giờ có item, control đổi theo thay đổi của Security Hub không đánh giá chúng.
- Thêm conformance pack CIS của Config: trùng chuẩn CIS v5.0.0 của Security Hub, đánh giá và tính tiền hai lần.
- Cảnh báo bằng metric filter CloudWatch trên log group của trail (CIS bản cũ): cần trail ghi thêm vào CloudWatch Logs, trả phí ingest.

## Kết quả quyết định

Chọn phương án in đậm, vì dịch vụ gốc của AWS là chuẩn SRA, sống ngoài cluster và Terraform quản được. Event pattern, retention, bảng giá và chi
tiết từng §: [phụ lục](appendix/0060-org-detection-logging.md).

### 1. Delegated admin và region

`aws/org` bật trusted access và đăng ký `svp-security` làm delegated admin của GuardDuty (hai region), Security Hub, Config
(`config.amazonaws.com`, `config-multiaccountsetup.amazonaws.com`), Access Analyzer. Region: `ap-southeast-1` (nhà) và `us-east-1`; region khác bị
`svp-deny-other-regions` chặn ở account thành viên. Lệch CIS ("mọi region"): management không chịu SCP mà không có dịch vụ phát hiện ngoài hai region.

### 2. GuardDuty

Tự bật mọi account (`ALL`, kể cả management) với S3 Protection, EKS Audit Log, Runtime Monitoring, RDS Protection, Lambda Protection (không có
Lambda, $0, control GuardDuty.6), Malware Protection for EC2 (GuardDuty.8; volume CMK EBS không quét được, 0059 §4). Ba additional configuration
quản agent tự động của Runtime Monitoring tắt (`EKS_ADDON_MANAGEMENT`, `ECS_FARGATE_AGENT_MANAGEMENT`, `EC2_AGENT_MANAGEMENT`): agent EKS theo §5;
không ECS; bastion là EC2 duy nhất ngoài EKS và không có giám sát runtime. Detector của `svp-security` ở hai region xuất finding về bucket
GuardDuty của Log Archive: finding của region thương mại xuất được về bucket ở region thương mại bất kỳ, key cùng region với bucket, bucket ở
account khác được [N4].

### 3. Security Hub CSPM

- Cấu hình tập trung [N5]: region nhà `ap-southeast-1`, aggregator gom `us-east-1`; một configuration policy gắn root: FSBP v1.0.0 và CIS AWS
  Foundations Benchmark v5.0.0 [N6], control mới tự bật. Tắt có lý do: GuardDuty.7, GuardDuty.13 (đòi agent tự quản [N7]: EKS dùng agent tự quản
  trong Terraform, EC2 chỉ có bastion), GuardDuty.12 (không ECS). Control tắt không chạy check, không tính tiền [N8].
- Security Hub bản hợp nhất: AWS ghi hai dịch vụ bổ sung nhau và khuyên bật cả hai; gói Essentials tính theo đơn vị tài nguyên và gộp phí CSPM [N9].
  Chưa bật; không đổi tài nguyên nào ở đây.

### 4. Config và Access Analyzer

- AWS Config: recorder mọi loại tài nguyên, `CONTINUOUS`, loại toàn cục (IAM) chỉ ở region nhà [N10]; delivery channel của cả hai region về bucket
  Config của Log Archive, snapshot 24 giờ; aggregator toàn org ở `svp-security`. Không conformance pack.
- IAM Access Analyzer loại `ORGANIZATION` (truy cập ngoài, không tính phí [N11]) ở hai region. Không bật analyzer truy cập không dùng ($0,20 mỗi
  role mỗi tháng; role của buổi sinh và mất mỗi lần).

### 5. Agent GuardDuty EKS

Add-on `aws-guardduty-agent` do module `eks` cài, version ghim như add-on khác; module `network` tạo interface endpoint
`com.amazonaws.<region>.guardduty-data` (private DNS, security group TCP 443 từ CIDR VPC, endpoint policy của tài liệu: cho mọi hành động, từ chối
khi `aws:PrincipalAccount` khác account) [N12]. Tự quản trong Terraform vì GuardDuty tự quản thì endpoint và security group do GuardDuty dựng,
ngoài state, chặn destroy VPC cuối buổi. Cả stg và prd.

### 6. Malware Protection for S3

Module `media` tạo plan Malware Protection cho bucket `uploads`, bật gắn tag kết quả (`GuardDutyMalwareScanStatus`), role IAM tin
`malware-protection-plan.guardduty.amazonaws.com` với quyền của tài liệu (rule EventBridge do GuardDuty quản, thông báo bucket, đọc object và
version, gắn tag, KMS khi bucket dùng KMS) [N13]; sống và gỡ cùng buổi. Cấu hình tổ chức không tự bật được plan này [N14]. video-service,
media-worker chưa đọc tag.

### 7. Bucket Log Archive

- Root `aws/log-archive`; tên `<tiền tố>-<id account log>-<region>` ([0038](0038-s3-bucket-names.md)): `svp-cloudtrail-`, `svp-cloudtrail-access-`,
  `svp-config-`, `svp-flowlogs-`, `svp-guardduty-` ở `ap-southeast-1`; `aws-waf-logs-svp-<log>-us-east-1` ở `us-east-1`.
- Bucket log WAF: tên bắt đầu `aws-waf-logs-`; tài liệu WAF không đặt region cho bucket của web ACL `CLOUDFRONT` và cho bucket của account khác
  khi chủ bucket ghi policy cho account tạo log [N15]: giữ `us-east-1`, region của web ACL và của nguồn giao log.
- Mã hoá: hai KMS key cùng alias `alias/svp-log-archive` (rotation, chờ xoá 30 ngày, `prevent_destroy`): key `ap-southeast-1` cho trail, Config,
  flow log, GuardDuty; key `us-east-1` chỉ cho log WAF (SSE-KMS đòi key cùng region với bucket). Bucket access log SSE-S3: S3 không giao server
  access log vào bucket SSE-KMS, và bucket đích cùng account, cùng region với bucket nguồn [N16].
- Mọi bucket: chặn public, `BucketOwnerEnforced`, chỉ TLS, versioning (version cũ hết hạn sau 1 ngày), policy cho principal dịch vụ với
  `aws:SourceOrgID` của org (trail: `aws:SourceArn` của trail ở management, như tài liệu CloudTrail [N17]).
- Retention: trail, access log của nó, Config, GuardDuty 365 ngày (PCI DSS 10.5.1, như trail hiện có), sang Glacier Instant Retrieval sau 90
  ngày; flow log và log WAF prd 90 ngày, stg 7 ngày (rule theo tiền tố account). Object Lock governance 365 ngày chỉ ở bucket trail: Config không
  giao vào bucket có Object Lock với retention mặc định [N10], mà retention mặc định theo bucket nên mọi account trong bucket trail cùng 365 ngày.

### 8. Trail org

`svp-audit` vẫn ở management, đổi đích sang `svp-cloudtrail-<log>-ap-southeast-1` với ARN `key/<id>` của key Log Archive. Bucket, key, bucket access
log cũ ở management giữ, `prevent_destroy`, chỉ đọc tới khi Object Lock của version cuối hết hạn, rồi gỡ theo README `aws/org`. Advanced event
selector: management event đọc và ghi; data event S3 chỉ của `svp-prd-uploads-<prd>-ap-southeast-1` (đọc và ghi) và `svp-prd-media-…` (chỉ ghi:
đọc là lưu lượng người xem qua CloudFront).

### 9. Flow log và log WAF

- Module `network` ghi flow log thẳng vào `svp-flowlogs-…`: mọi lưu lượng, định dạng Parquet, tiền tố tương thích Hive, phân vùng theo giờ,
  aggregation 60 giây, trường mặc định cộng `vpc-id`, `subnet-id`, `instance-id`, `tcp-flags`, `type`, `pkt-srcaddr`, `pkt-dstaddr`, `az-id`,
  `pkt-src-aws-service`, `pkt-dst-aws-service`, `flow-direction`, `traffic-path` [N18]. Bỏ log group CloudWatch và role của nó.
- Module `waf` ghi mọi request vào bucket log WAF, che header `authorization`, `cookie` (`SingleHeader`) [N15]. Hai loại giao mỗi 5 phút.

### 10. Đường cảnh báo

- Rule `svp-security-*` trên bus mặc định của từng account (module `security-baseline`) → role `svp-security-forwarder` (bắt buộc cho đích bus
  account khác [N19]) → bus `svp-security-events` của `svp-security`, `ap-southeast-1` (policy theo `aws:PrincipalOrgID`) → rule → topic SNS
  `svp-security-alarms` (module `alarms`, CMK, publisher `events.amazonaws.com`) → email `security_alert_email`.
- Nhóm sự kiện (pattern đủ, account, region ở phụ lục; mỗi pattern ≤ 2 048 ký tự [N20] nên mỗi nhóm một hay vài rule):
  - Root: `ConsoleLogin` của root ở `us-east-1` mọi account, thêm `us-east-2`, `us-west-2` ở management (CloudTrail ghi đăng nhập root ở một
    trong ba region [N21]; account thành viên không có mật khẩu root mà không qua `AssumeRoot`); `AssumeRoot` ở management, hai region, rule
    `ENABLED_WITH_ALL_CLOUDTRAIL_MANAGEMENT_EVENTS` để nhận cả khi sự kiện là chỉ đọc [N22].
  - Organizations và root tập trung: management, `us-east-1`.
  - Trail: `StopLogging`, `DeleteTrail`, `UpdateTrail`, `PutEventSelectors`, `PutInsightSelectors`, thành công hay bị từ chối; mọi account, hai
    region. Rule `svp-security-*`: mọi lệnh đổi, xoá, tắt, thành công hay bị từ chối; mọi account, hai region.
  - Dịch vụ phát hiện: tắt, rời, xoá, đổi GuardDuty, Security Hub, Config, Access Analyzer thành công; mọi account, hai region.
  - Lệnh bị từ chối trên hành động còn lại của `svp-protect-baseline`, `svp-deny-iam-users`: `errorCode` khớp `prefix` `AccessDenied` (phủ
    `AccessDeniedException` của API JSON) hay `Client.UnauthorizedOperation` (EC2, kể cả `--dry-run`), theo filter "unauthorized API calls" của
    CIS v1.2.0 3.1 [N2]; mọi account kể cả stg, prd, hai region.
  - Đổi quản trị (cờ dữ liệu, chỉ management, `svp-log-archive`, `svp-security`): IAM ghi (`us-east-1`), lập lịch xoá, tắt, đổi policy KMS key,
    policy, ACL, lifecycle, mã hoá, Object Lock của bucket, permission set và gán của Identity Center (management, region của Identity
    Center). stg, prd bỏ: mỗi buổi tạo, xoá hàng chục role, key, bucket.
  - Finding: event "Security Hub Findings - Imported" bắn cho mọi finding mới và mỗi lần cập nhật [N23]; rule trên bus mặc định của `svp-security`
    (region aggregator) lọc `Severity.Label` `HIGH`, `CRITICAL`, `RecordState` `ACTIVE`, `Workflow.Status` `NEW`, `ProductName` `GuardDuty`, `IAM
    Access Analyzer`. Finding control FSBP, CIS không gửi email: đọc trên bảng Security Hub theo runbook.
- Input transformer ghi tên sự kiện hay tiêu đề finding, account, region, principal, `errorCode` và URL runbook
  `https://github.com/anhnvcoder/svp-backend/blob/main/docs/runbooks/security-alert.md`. Email lặp: GuardDuty gửi lần lặp lại của finding đang
  mở sang Security Hub theo tần suất xuất finding cập nhật, mặc định 6 giờ [N4], [N28]. Dừng bằng `Workflow.Status` `NOTIFIED` hay
  `SUPPRESSED` qua đường ghi của `svp-security` (management assume `OrganizationAccountAccessRole`); `SvpReadOnly` không ghi (0059 §8).

### 11. Chi phí org

Ở `aws/bootstrap` (management): Cost Anomaly Detection monitor `DIMENSIONAL`/`SERVICE`, subscription email `DAILY` tới `budget_emails`, ngưỡng
`ANOMALY_TOTAL_IMPACT_ABSOLUTE` ≥ $10: một buổi thường làm mỗi dịch vụ tăng dưới $10 ([0048](0048-prd-aws.md) §10), env quên gỡ một ngày vượt
ngưỡng ở dịch vụ EC2, EKS. Không tính phí (FAQ: "no effort or cost" [N24]). Tag phân bổ chi phí `Project`, `Env`, `Stack` kích hoạt bằng
`aws_ce_cost_allocation_tag` (đã có, `Inactive`); `ManagedBy` không cần.

### 12. Chi phí liên tục

Lúc không buổi, năm account, hai region (bảng giá `ap-southeast-1`, `us-east-1` từ AWS Price List API và trang giá, đọc 2026-11-12; cách ước ở
phụ lục): Security Hub CSPM ~$9 (khoản lớn nhất), KMS ~$6 (sáu key mới), GuardDuty ~$2,4, Config ~$1,5, S3 log ~$1,1, còn lại $0: **~$20 mỗi tháng**
(khoảng $15–30); 30 ngày đầu GuardDuty, Security Hub dùng thử. Mỗi buổi thêm ~$4–8 (item Config, check Security Hub, Runtime Monitoring, EKS Audit
Log, flow log; prd thêm data event). Giữ tối thiểu: tài nguyên toàn cục chỉ ghi ở region nhà; control dùng chung rule Config của FSBP và CIS chỉ
tính một lần [N8]; tắt control không áp dụng; data event chỉ bucket người dùng của prd, `media` chỉ ghi; flow log Parquet; không conformance pack,
không analyzer truy cập không dùng.

### Hệ quả

- Tốt: mọi account có phát hiện liên tục, đánh giá FSBP và CIS, lịch sử cấu hình kể cả tài nguyên của buổi; log ngoài tầm admin của workload;
  root đăng nhập, policy đổi, trail dừng, guardrail bị thử đều tới email trong vài phút.
- Xấu: ~$20 mỗi tháng kể cả khi không buổi; budget tháng của management phải nâng trên mức này cộng buổi trước khi áp; buổi tốn thêm ~$4–8;
  control GuardDuty.7, .12, .13 tắt; bastion không giám sát runtime; volume CMK EBS không quét malware; finding control FAILED phải đọc tay;
  management ngoài hai region không có phát hiện; rule đăng nhập root ở ba region của management; `AssumeRoot` gọi từ management ở region
  khác `ap-southeast-1`, `us-east-1` không sinh email (STS nhận nó ở mọi endpoint region, management không chịu SCP region).
- Xem lại khi: chi phí đo sau 7 ngày (hay ước của Security Hub, GuardDuty lúc dùng thử) vượt $30 mỗi tháng; phí CSPM vượt phí Essentials ước theo
  tài nguyên; item Config mỗi buổi vượt $3 (ghi `AWS::EC2::NetworkInterface` theo ngày); cần chặn file nhiễm malware trước transcode (media-worker
  đọc tag); thêm Lambda, ECS hay EC2 chạy lâu; cần đích cảnh báo ngoài email.

## Xác nhận

- Lúc quyết chưa hiện thực. Kiểm tĩnh: `make check` của `svp-infra` (test `security-baseline`: recorder `CONTINUOUS`, nhóm pattern, rule ở
  hai region, rule đăng nhập root ở các region của biến; `network`: flow log S3 Parquet; `waf`: logging che header; `alarms`: publisher).
- Sau áp (runbook `org-security-setup.md`): plan `aws/org` lần hai `No changes`; năm account là thành viên GuardDuty, Security Hub,
  aggregator Config; Access Analyzer `ACTIVE`; log mới của năm account vào bucket trail mới; rule `svp-security-admin-sso` ở region của
  instance Identity Center; mỗi phép thử guardrail, `sts assume-root`, một finding mẫu HIGH ở stg tới email có URL runbook; chi phí theo
  dịch vụ sau 1 và 7 ngày so với §12.
- Buổi stg, prd: add-on agent `ACTIVE`, coverage EKS `HEALTHY`; flow log, log WAF (header bị che) vào bucket; object `uploads` có tag
  `NO_THREATS_FOUND`; prd có data event; destroy sạch, `sweep.sh` không báo `Stack=security-baseline`.

## Hiện thực ở

- `svp-infra`: `aws/security/` (§2–§4, §10), `aws/log-archive/` (§7), `aws/org/` (trusted access, delegated admin, `audit-trail.tf`; §1, §8),
  `aws/baseline/`, `aws/modules/security-baseline/` (Config, rule; §4, §10), `aws/modules/alarms/` (§10), `aws/modules/network/`,
  `aws/modules/eks/addons.tf` (§5, §9), `aws/modules/waf/` (§9), `aws/modules/media/` (§6), `aws/bootstrap/` (§11), `aws/envs/<env>/`,
  `aws/scripts/tf.sh`, `aws/scripts/lib.sh` (§7, §9), `docs/runbooks/org-security-setup.md`, `session-stg.md`, `session-prd.md`.
- Repo code: `docs/runbooks/security-alert.md` (§10), `docs/explanation/aws-security.md`, `docs/explanation/environments.md`.

## Nguồn

Đọc 2026-11-12; đủ [N1]–[N29] ở phụ lục. [N4] <https://docs.aws.amazon.com/guardduty/latest/ug/guardduty_exportfindings.html>,
[N5] <https://docs.aws.amazon.com/securityhub/latest/userguide/central-configuration-intro.html>,
[N21] <https://docs.aws.amazon.com/awscloudtrail/latest/userguide/cloudtrail-event-reference-aws-console-sign-in-events.html>.

## Thông tin thêm

Phụ lục: [`appendix/0060-org-detection-logging.md`](appendix/0060-org-detection-logging.md) (phương án, bucket, event pattern, bảng giá, nguồn).

### Chỉnh bởi

- §7: [0061](0061-edge-cloudfront-waf-acm.md): thêm bucket `svp-cloudfront-<log>-us-east-1` (log CloudFront v2, khuôn bucket log WAF, key `us-east-1`) cùng delivery destination mỗi env và policy của nó ở `us-east-1`; `SvpLogReader` đọc bucket đó.
- §1–§4, §12: [0067](0067-backup-dr.md): `svp-backup` nhận GuardDuty, Security Hub, Config, Inspector như mọi account thành viên; chi phí liên tục thêm ~$2,2 mỗi tháng cho account này.
