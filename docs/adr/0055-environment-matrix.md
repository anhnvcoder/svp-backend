# 0055. stg chạy cùng dịch vụ, cấu hình, xác thực, mã hoá và giám sát với prd; stg chỉ giảm dự phòng, cỡ, số lượng, retention và bảo vệ xoá; mỗi khác biệt là dữ liệu có lý do

- Trạng thái: Chấp nhận
- Ngày: 2026-11-11
- Người quyết: người học (2026-11-08: prd là production chuẩn ngành, stg chạy như prd chạy nhưng cắt dự phòng cho sự cố hạ tầng; dự án là mẫu
  tham khảo, mỗi khác biệt stg/prd viết ra có lý do), AI đề xuất ma trận

## Bối cảnh và vấn đề

- [0048](0048-prd-aws.md) §3 cho prd khác stg ở `prd.tfvars` và một danh sách wiring đóng (root prd thêm bastion SSM, `teardown.tfvars`); bảng biến
  ở phụ lục 0048 ghi giá trị mỗi env nhưng không ghi khác biệt nào được phép, vì sao, và mất gì.
- Hệ quả: stg lệch prd ở cả cấu hình, không chỉ ở dự phòng: endpoint API EKS công khai, Secret không mã hoá bằng CMK, không log control plane,
  không flow log, endpoint S3 không policy, broker log MSK tắt, Database Insights, enhanced monitoring và export log RDS tắt, access log media
  tắt. Lỗi ở các đường đó (key policy, quyền IAM của log, tunnel SSM) chỉ lộ ra ở buổi prd.
- [0034](0034-aws-stage7.md) §11 và [0053](0053-msk-elasticache-valkey.md) §1 đã chốt một bộ module, khác ở biến, không `if env`; luật managed/local
  của 0053 §1 vẫn áp cho local. Ràng buộc buổi như 0034, 0048: env dựng và gỡ trong buổi tối đa 4 giờ.

## Yếu tố quyết định

- stg phải bắt được lỗi cấu hình trước prd: cùng dịch vụ, cấu hình, xác thực, đường vận hành [N1].
- Chi phí stg theo buổi: dự phòng cho sự cố hạ tầng (AZ, NAT, failover) là phần đắt nhất và stg không hứa giữ dữ liệu qua sự cố [N2], [N3].
- Mỗi khác biệt đọc được ở một chỗ, có lý do và nguồn; khác biệt không ghi là lỗi.

## Phương án đã cân nhắc

- Giữ danh sách khác biệt đóng của 0048 §3: wiring giống nhau, nhưng biến nào khác cũng được; stg đi đường cấu hình khác prd mà không ai quyết.
- stg sao y prd (3 AZ, NAT mỗi AZ, Multi-AZ, on-demand, cùng cỡ): gần prd nhất [N1], nhưng một buổi stg tốn gần bằng buổi prd, trái luật chi phí
  của người học; bảo vệ xoá còn cản gỡ cuối buổi.
- stg giữ dịch vụ, cắt cấu hình (KMS, log, endpoint private tắt ở stg): rẻ hơn ít, nhưng mọi đường cấu hình prd chỉ chạy lần đầu ở prd.
- **Ba nhóm phải giống, được giảm, giảm có điều kiện:** stg đi mọi đường cấu hình của prd; chỉ dự phòng, cỡ, số lượng, retention và bảo vệ xoá
  nhỏ hơn; cái nào giảm làm mất một hành vi thì ghi hành vi đó và chỗ kiểm bù.

## Kết quả quyết định

Chọn ba nhóm. Bảng đủ từng thành phần (nhóm, chỗ giữ giá trị, lý do, nguồn) ở
[`docs/explanation/environments.md`](../explanation/environments.md); ADR này giữ luật.

### 1. Luật

- Mỗi thành phần thuộc đúng một nhóm (§2–§4). Khác biệt stg/prd không thuộc nhóm nào và không phải định danh (§5) là lỗi, sửa về giống prd.
- Khác biệt chỉ là dữ liệu (§6); thêm thành phần hay khác biệt mới thì thêm dòng vào bảng của `environments.md` trong cùng thay đổi.
- Thành phần mới mặc định thuộc nhóm phải giống; xếp vào nhóm giảm cần lý do chi phí và, nếu mất hành vi, chỗ kiểm bù.

### 2. Phải giống

Khác là lỗi:

- Dịch vụ và version: EKS minor, add-on EKS và version ghim, Karpenter và AMI ghim, chart nền tảng, PostgreSQL trên RDS, Kafka trên MSK, Valkey
  trên ElastiCache.
- Cấu hình dịch vụ: parameter group RDS kể cả tham số ghi log, `aws_msk_configuration` trừ RF và min ISR (§4), parameter group Valkey.
- Xác thực và TLS: SCRAM của MSK, RBAC của Valkey, TLS tới Postgres; IAM, Pod Identity, role của SecretStore.
- Mạng: ba tầng subnet ([0054](0054-data-subnet-tier.md)), policy của S3 gateway endpoint bật [N13], NetworkPolicy.
- Đường tới API EKS: endpoint private, tunnel SSM qua bastion ở cả hai root [N9].
- Mã hoá: CMK cho Secret của EKS [N11], RDS, MSK, SNS của alarm; ElastiCache mã hoá at-rest.
- Edge: web ACL WAF và gói CloudFront ([0052](0052-cloudfront-flat-rate-free.md)).
- HA của workload nền tảng: Envoy, Kyverno, trải zone (thành phần và giá trị ở ADR-0056, `0056-eks-platform-ha.md`).
- Loại log và giám sát: log control plane đủ năm loại [N10], VPC flow log [N12], export log RDS, Database Insights, enhanced monitoring, broker
  log MSK, slow-log Valkey, S3 access log của media, cùng bộ alarm managed (ADR-0058, `0058-managed-data-operations.md`).

### 3. Được giảm

Chỉ vì chi phí, không mất hành vi mà stg cần kiểm:

- Số AZ: stg 2 (vẫn đa AZ: EBS gắn zone, trải pod theo zone, MSK cần ít nhất hai AZ), prd 3 [N2].
- Cỡ: lớp RDS (stg `db.t4g`, prd `db.m7g`: lớp T chỉ cho dev, test [N5]), broker MSK, node ElastiCache, node EKS.
- Số lượng: broker MSK bằng số AZ, replica service, trần storage, `limits` của NodePool.
- Retention log (stg 1 ngày: log group bị xoá cùng env), retention backup RDS (stg 1 ngày).
- Bảo vệ xoá: deletion protection, final snapshot, giữ backup tự động, `force_destroy` của bucket; versioning của media.

### 4. Giảm có điều kiện

Mất một hành vi; mỗi dòng ghi chỗ kiểm bù:

| Giảm ở stg | Mất gì | Kiểm bù |
| --- | --- | --- |
| RDS một AZ [N6] | failover sang standby | diễn tập failover RDS ở buổi prd |
| Valkey một node [N8] | failover sang replica | diễn tập failover Valkey ở buổi prd |
| MSK RF 2, min ISR 1 [N7] | bảo đảm giữ ghi `acks=all` khi mất broker | diễn tập mất broker ở buổi prd |
| NAT đơn [N4] | egress của mọi AZ khi AZ của NAT mất | không kiểm ở stg; prd có NAT mỗi AZ |
| NodePool workload Spot [N14] | node bị thu hồi giữa chừng | stg kiểm luôn đường interruption của Karpenter |
| Valkey `apply_immediately = true` [N15] | đổi cấu hình chờ cửa sổ bảo trì | plan prd hiện thay đổi chờ; stg sống vài giờ, không tới cửa sổ |

### 5. Định danh của env

Ngoài ba nhóm: tên `svp-<env>`, account, zone và domain, cổng local của tunnel API (stg `127.0.0.1:6444`, prd `6443`: một lệnh nhầm context không
tới cluster kia), `SENTRY_ENVIRONMENT`, bản phát hành mỗi env chạy và khoá ghim revision của prd ([0048](0048-prd-aws.md) §7, §8). Chúng khác vì là
env khác, không phải mức khác.

### 6. Khác biệt là dữ liệu (thay 0048 §3)

- Chỗ giữ: `infra/aws/envs/<env>/<env>.tfvars` (prd thêm `teardown.tfvars`, chỉ nhấc bảo vệ khi gỡ), `infra/aws/gitops/<env>/<env>.tfvars`,
  `gitops/envs/<env>/`. Lớp `gitops/platforms/eks/` dùng chung hai env nên không giữ khác biệt stg/prd.
- Hai root `aws/envs/<env>` có `*.tf` giống hệt, kể cả bastion SSM; `diff -r -x .terraform -x '*.auto.tfvars'` của hai thư mục chỉ còn dòng `env`
  của `locals` trong `main.tf`, file `<env>.tfvars`, `teardown.tfvars` (prd), `README.md`, `backend.hcl.example`, `example.auto.tfvars.example`.
- Hai root `aws/gitops/stg`, `aws/gitops/prd` cũng có `*.tf` giống hệt, chỉ khác dòng `env`.
- Không `if env` trong module hay root. Ngoại lệ trivy `Scope: stg only` chỉ được cho thành phần nhóm §3, §4; thành phần nhóm §2 không có
  ngoại lệ chỉ-stg. Ba lớp kiểm của 0048 §3 (test module mức prd, trivy root prd, diff hai root) giữ nguyên.

### Hệ quả

- Tốt: stg chạy mọi đường cấu hình, mã hoá và vận hành của prd; buổi prd chỉ còn kiểm dự phòng (§4); người đọc thấy mỗi khác biệt và cái giá.
- Xấu: buổi stg tốn thêm KMS key, log ingest, bastion SSM; mỗi lệnh `kubectl` vào stg cần tunnel như prd; giữ bảng của `environments.md` khớp
  tfvars là việc tay mỗi lần đổi biến.
- Xem lại khi: stg chạy lâu dài (khi đó retention, backup, bảo vệ xoá không còn lý do giảm); chi phí buổi stg đo được vượt ngân sách; hay một
  lỗi chỉ prd gặp mà thuộc nhóm §2 (thiếu dòng trong ma trận).

## Xác nhận

- Lúc quyết chưa hiện thực; root stg còn lệch ở các mục của Bối cảnh, bảng "Trạng thái đích" của `environments.md` liệt kê.
- Còn lại: lệnh `diff` của §6 chỉ còn file được phép; `make check` của `svp-infra` (trivy root prd không ngoại lệ chỉ-stg, root stg chỉ ngoại lệ §3,
  §4); mỗi biến của `stg.tfvars`, `prd.tfvars` có dòng trong bảng; buổi stg chạy tunnel SSM, CMK, log như prd; buổi prd chạy các kiểm bù của §4.

## Hiện thực ở

- `svp-infra`: `aws/envs/stg/`, `aws/envs/prd/` (`<env>.tfvars`, `teardown.tfvars`), `aws/gitops/<env>/<env>.tfvars`, `aws/modules/`.
- `svp-gitops`: `envs/stg/`, `envs/prd/`, `platforms/eks/`.
- Repo code: `docs/explanation/environments.md` (bảng đủ từng thành phần).

## Nguồn

Đọc 2026-11-11.

- [N1] The Twelve-Factor App, X. Dev/prod parity: <https://12factor.net/dev-prod-parity>
- [N2] AWS Well-Architected, REL10-BP01: <https://docs.aws.amazon.com/wellarchitected/latest/reliability-pillar/rel_fault_isolation_multiaz_region_system.html>
- [N3] AWS Well-Architected, Cost Optimization Pillar: <https://docs.aws.amazon.com/wellarchitected/latest/cost-optimization-pillar/welcome.html>
- [N4] NAT gateway basics: <https://docs.aws.amazon.com/vpc/latest/userguide/nat-gateway-basics.html>
- [N5] RDS DB instance class types: <https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/Concepts.DBInstanceClass.Types.html>
- [N6] RDS Multi-AZ: <https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/Concepts.MultiAZSingleStandby.html>
- [N7] MSK best practices: <https://docs.aws.amazon.com/msk/latest/developerguide/bestpractices.html>
- [N8] ElastiCache Multi-AZ: <https://docs.aws.amazon.com/AmazonElastiCache/latest/dg/AutoFailover.html>
- [N9] EKS cluster endpoint: <https://docs.aws.amazon.com/eks/latest/userguide/cluster-endpoint.html>
- [N10] EKS Best Practices, Auditing and logging: <https://docs.aws.amazon.com/eks/latest/best-practices/auditing-and-logging.html>
- [N11] EKS Best Practices, Data encryption: <https://docs.aws.amazon.com/eks/latest/best-practices/data-encryption-and-secrets-management.html>
- [N12] VPC Flow Logs: <https://docs.aws.amazon.com/vpc/latest/userguide/flow-logs.html>
- [N13] Gateway endpoints for S3: <https://docs.aws.amazon.com/vpc/latest/privatelink/vpc-endpoints-s3.html>
- [N14] Karpenter disruption: <https://karpenter.sh/docs/concepts/disruption/>
- [N15] Modifying an ElastiCache cluster: <https://docs.aws.amazon.com/AmazonElastiCache/latest/dg/Clusters.Modify.html>

## Thông tin thêm

### Chỉnh bởi

- §2, §4: [0059](0059-org-structure-guardrails.md): CMK EBS làm key EBS mặc định ở cả hai env (nhóm mã hoá phải giống), NACL không mở 22/3389 ở cả hai env; SCP `svp-prod-guardrails` ở OU `Prod` chặn Spot qua `RunInstances` ở prd, cạnh dòng NodePool Spot của stg.
- §2, §3, §4: [0060](0060-org-detection-logging.md): flow log VPC ghi thẳng vào bucket của `svp-log-archive` (không còn log group của env), log WAF, agent GuardDuty EKS cùng endpoint `guardduty-data`, Malware Protection cho `uploads` thuộc nhóm phải giống; retention flow log và log WAF: stg 7 ngày, prd 90 ngày (được giảm); data event S3 của trail chỉ cho `uploads`, `media` của prd (giảm có điều kiện: stg không có dữ liệu người dùng thật; kiểm bù ở buổi prd).
- §2, §3: [0061](0061-edge-cloudfront-waf-acm.md): mạng bốn tầng subnet (thêm tầng edge); edge phải giống gồm ba distribution, VPC origin, ALB internal, ba web ACL, cert ACM và TLS policy, response headers policy, log v2 của web, api, CAA; được giảm ở stg: gói Free và không access log của media, không DNSSEC, không query log Route 53, ALB không deletion protection.
- §2: [0062](0062-ecr-registry-ci-oidc.md): registry ECR, repo phát hành, pull-through cache, quét Inspector, `svp-registry-mirror` thuộc nhóm phải giống ở cả hai env; bộ role CI ECR khác theo thiết kế (stg nhận bản từ `main`, prd chỉ từ `promote-prd`), không phải giảm.
- §2, §3: [0063](0063-managed-observability.md): đích telemetry, Prometheus agent HA, luật và Alertmanager thuộc nhóm phải giống; retention được giảm ở stg: AMP 31 ngày (prd 150), log group ứng dụng và `aws/spans` 7 ngày (prd 30).
- §2, §3: [0064](0064-interface-endpoints.md): endpoint interface, private DNS, security group, endpoint policy thuộc nhóm Mạng, phải giống; số AZ đặt ENI được giảm: stg 1, prd bằng số AZ của VPC.
- §2: [0066](0066-mediaconvert-transcode.md): transcode bằng MediaConvert (queue, tier, giới hạn, role, rule EventBridge, hàng đợi SQS và DLQ, alarm, endpoint `mediaconvert`) thuộc nhóm phải giống; số AZ đặt ENI của endpoint theo 0064.
- §2, §3: [0067](0067-backup-dr.md): versioning của hai bucket của module `media` thành phải giống (backup S3 cần versioning; stg bật `media_versioning_enabled`); AWS Backup (Backup policy, vault env, role, opt-in, key vault, alarm) và SSE-KMS của `uploads` thuộc nhóm phải giống; retention recovery point và vault lock được giảm ở stg (2 ngày, lock 1–7; prd 35, lock 7–35).
