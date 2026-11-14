# Môi trường stg và prd: cái gì giống, cái gì giảm và vì sao

Trang này trả lời: stg khác prd ở đâu, mỗi khác biệt thuộc nhóm nào, vì sao được phép, và khi stg giảm một thứ thì mất hành vi gì, kiểm bù ở
đâu. Luật và lý do chọn ba nhóm ở [ADR-0055](../adr/0055-environment-matrix.md); compose, k3d, EKS gồm gì ở [`deployment.md`](deployment.md).

Trang không chép số. Giá trị nằm ở:

| Viết tắt trong bảng | File |
| --- | --- |
| `<env>.tfvars` | [`aws/envs/stg/stg.tfvars`](https://github.com/anhnvcoder/svp-infra/blob/main/aws/envs/stg/stg.tfvars), [`aws/envs/prd/prd.tfvars`](https://github.com/anhnvcoder/svp-infra/blob/main/aws/envs/prd/prd.tfvars) của `svp-infra`; biến không có trong file lấy mặc định ở `variables.tf` cùng thư mục |
| `teardown.tfvars` | [`aws/envs/prd/teardown.tfvars`](https://github.com/anhnvcoder/svp-infra/blob/main/aws/envs/prd/teardown.tfvars): bảo vệ nhấc khi gỡ prd |
| gitops root | `aws/gitops/<env>/<env>.tfvars` của `svp-infra` |
| module `<tên>` | [`aws/modules/<tên>/`](https://github.com/anhnvcoder/svp-infra/tree/main/aws/modules) của `svp-infra`: giá trị chung hai env |
| root `aws/<tên>` | [`aws/<tên>/`](https://github.com/anhnvcoder/svp-infra/tree/main/aws) của `svp-infra`: root cấp org (`org`, `log-archive`, `baseline`), sống giữa các buổi, chung hai env |
| root `aws/accounts/<env>` | [`aws/accounts/<env>/main.tf`](https://github.com/anhnvcoder/svp-infra/tree/main/aws/accounts) của `svp-infra`: baseline của account env (zone, budget, registry ECR, nơi nhận telemetry), sống giữa các buổi; giá trị theo env ở khối `locals` cạnh `env` |
| `envs/<env>/`, `platforms/eks/`, `base/` | thư mục cùng tên của [`svp-gitops`](https://github.com/anhnvcoder/svp-gitops); `platforms/eks/` dùng chung hai env |

## Ba nhóm

- **Phải giống:** dịch vụ, version, cấu hình, xác thực và TLS, IAM, mạng, đường tới API, mã hoá, edge, HA của workload nền tảng, loại log và
  giám sát. Khác là lỗi.
- **Được giảm:** số AZ, cỡ, số lượng, retention, bảo vệ xoá, versioning. Chỉ vì chi phí; stg không mất hành vi cần kiểm.
- **Giảm có điều kiện:** stg mất một hành vi (thường là failover); cột "Mất gì → kiểm bù" ghi chỗ kiểm hành vi đó.
- **Định danh:** tên, account, zone, cổng tunnel, bản phát hành. Khác vì là env khác, không phải mức khác (ADR-0055 §5).

Cột "stg so với prd" nói hướng khác biệt; số ở file của cột "Giá trị ở". [ADR-0056](../adr/0056-eks-platform-ha.md),
[ADR-0057](../adr/0057-postgres17-verify-full.md) và [ADR-0058](../adr/0058-managed-data-operations.md) giữ số của
Karpenter, nhóm node hệ thống, Envoy và Kyverno HA, PostgreSQL 17, lớp RDS, alarm;
[ADR-0062](../adr/0062-ecr-registry-ci-oidc.md), [ADR-0063](../adr/0063-managed-observability.md),
[ADR-0064](../adr/0064-interface-endpoints.md) giữ số của registry, retention telemetry và endpoint interface;
[ADR-0059](../adr/0059-org-structure-guardrails.md), [ADR-0060](../adr/0060-org-detection-logging.md) giữ guardrail, log
và retention cấp org ([`aws-security.md`](aws-security.md)). Mỗi biến của `<env>.tfvars` có ít nhất một dòng; thêm hay
bỏ biến thì sửa bảng trong cùng thay đổi (ADR-0055 §1).

## Mạng

| Thành phần | Giá trị ở | Nhóm | stg so với prd | Lý do | Mất gì → kiểm bù | Nguồn |
| --- | --- | --- | --- | --- | --- | --- |
| Số AZ | `az_count` (`<env>.tfvars`) | được giảm | stg ít AZ hơn, vẫn đa AZ | Hai AZ đủ thấy hành vi theo zone (EBS gắn zone, trải pod, MSK cần ít nhất hai AZ); AZ thứ ba chỉ thêm dự phòng | — | [REL10], [MSKBP] |
| NAT gateway | `single_nat_gateway` (`<env>.tfvars`) | giảm có điều kiện | stg một NAT, prd mỗi AZ một | NAT tính theo giờ mỗi cái | Egress của mọi AZ khi AZ của NAT mất → không kiểm ở stg; prd có NAT mỗi AZ | [NAT] |
| Bốn tầng subnet: public (chỉ NAT), private, database, edge | module `network` | phải giống | như nhau | Subnet database không có route ra Internet ([ADR-0054](../adr/0054-data-subnet-tier.md)); subnet edge chỉ có ALB, không pod ([ADR-0061](../adr/0061-edge-cloudfront-waf-acm.md) §3) | — | [EKSSUB] |
| VPC flow log và đích của nó | module `network` (`flow_log_bucket_arn` do root suy từ id account log) | phải giống | cả hai ghi vào bucket `svp-flowlogs-…` của `svp-log-archive`, cùng định dạng ([ADR-0060](../adr/0060-org-detection-logging.md) §9) | Log nằm ngoài tầm admin của env và còn sau khi env bị gỡ; đường ghi chéo account chạy ở stg trước | — | [FL], [SRA] |
| Retention flow log | root `aws/log-archive` (lifecycle theo tiền tố account) | được giảm | stg ngắn hơn ([ADR-0060](../adr/0060-org-detection-logging.md) §7) | Log của stg chỉ phủ một buổi vài giờ | — | [COST] |
| NACL không mở 22, 3389 từ Internet | module `network` | phải giống | như nhau ([ADR-0059](../adr/0059-org-structure-guardrails.md) §10) | Cùng luật mạng; Security Hub đánh giá control EC2.21 trên cả hai | — | [CIS] |
| Policy S3 gateway endpoint | `s3_endpoint_restricted` (`<env>.tfvars`) | phải giống | bật ở cả hai | Policy chỉ cho bucket trong danh sách: image kéo từ bucket thiếu sẽ lỗi, stg gặp lỗi đó trước prd | — | [S3EP] |
| Bucket thêm của endpoint | `s3_endpoint_extra_buckets` (`<env>.tfvars`) | phải giống | cùng danh sách | Bucket mà `registry.k8s.io` chuyển hướng client trong AWS tới | — | [S3EP] |
| NetworkPolicy | add-on `vpc-cni` của module `eks` (network policy agent), chart | phải giống | như nhau | Chính sách mạng của chart áp như nhau mọi nơi | — | [EKSNET] |
| Endpoint interface: dịch vụ, private DNS, security group `svp-<env>-endpoints`, endpoint policy | module `network` | phải giống | như nhau ([ADR-0064](../adr/0064-interface-endpoints.md)) | Mọi gọi API AWS của cluster đi qua endpoint có policy chặn principal ngoài account; đường đi, policy và NetworkPolicy tới endpoint chạy thử ở stg trước | — | [PLEP], [EKSPRIV] |
| Số AZ đặt ENI của endpoint interface | `interface_endpoint_az_count` (`<env>.tfvars`) | được giảm | stg một AZ, prd mọi AZ | Endpoint tính theo giờ mỗi AZ; pod ở AZ khác của stg đi chéo AZ tới ENI, cùng đường, cùng policy. stg đã phụ thuộc AZ đầu cho đường ra (một NAT) | — | [PLEP], [COST] |

## EKS: control plane và truy cập

| Thành phần | Giá trị ở | Nhóm | stg so với prd | Lý do | Mất gì → kiểm bù | Nguồn |
| --- | --- | --- | --- | --- | --- | --- |
| Minor Kubernetes | `kubernetes_version` (`<env>.tfvars`) | phải giống | như nhau | prd chỉ chạy cái stg đã chạy; nâng minor đi qua stg trước | — | [EKSUPG] |
| Endpoint private của API, endpoint công khai tắt | module `eks` (root không mở endpoint công khai) | phải giống | như nhau | API không mở ra Internet; mọi lệnh vận hành đi cùng một đường | — | [EKSEP] |
| Bastion SSM và tunnel tới API | module `ssm-bastion`, `ssm-bastion.tf` của root | phải giống | ở cả hai root | Cùng đường tới endpoint private: không inbound, không khoá SSH | — | [SSM], [EKSEP] |
| Cổng local của tunnel | `api_tunnel_port` (`<env>.tfvars`), `api_server_url` (gitops root) | định danh | khác nhau (ADR-0055 §5) | Một lệnh nhầm context không tới cluster kia | — | — |
| Loại log control plane | `control_plane_log_types` (`<env>.tfvars`) | phải giống | đủ năm loại ở cả hai | Audit và điều tra quyền cần cùng log | — | [EKSLOG], [CPLOG] |
| Retention log control plane | `control_plane_log_retention_days` (`<env>.tfvars`) | được giảm | stg ngắn hơn | Log group bị xoá cùng env | — | [COST] |
| Mã hoá Secret bằng CMK | `eks_secrets_kms_encryption` (`<env>.tfvars`) | phải giống | bật ở cả hai | Envelope encryption của Secret; key policy và quyền KMS chạy ở stg trước | — | [EKSENC] |
| Add-on EKS và version ghim | module `eks` (`addons.tf`) | phải giống | như nhau ([ADR-0056](../adr/0056-eks-platform-ha.md) §8) | Cùng bộ add-on, cùng bản | — | [EKSUPG] |
| Pod Identity, access entry, IMDSv2 | module `eks` | phải giống | như nhau | Pod lấy quyền qua Pod Identity, không IRSA, không quyền của node | — | [EKSIAM] |
| Agent GuardDuty Runtime Monitoring và endpoint `guardduty-data` | module `eks` (`addons.tf`), module `network` | phải giống | như nhau ([ADR-0060](../adr/0060-org-detection-logging.md) §5) | Cùng giám sát runtime; agent và endpoint tự quản trong Terraform chạy ở stg trước | — | [GDRT] |

## Node

| Thành phần | Giá trị ở | Nhóm | stg so với prd | Lý do | Mất gì → kiểm bù | Nguồn |
| --- | --- | --- | --- | --- | --- | --- |
| Nhóm node hệ thống (loại, on-demand, AMI ghim) | module `eks` (`nodes.tf`, `system_node_instance_type`) | phải giống | như nhau | Controller nền tảng không chạy trên Spot hay trên node Karpenter quản | — | [EKSKARP] |
| Số node của nhóm hệ thống | số AZ (min = desired), `system_node_max_size = 2 * var.az_count` ở `main.tf` của root | được giảm | theo số AZ | Mỗi AZ một node; số lượng là chi phí | — | [EKSKARP] |
| Karpenter, AMI của EC2NodeClass, `terminationGracePeriod` | component `karpenter`, `platforms/eks/svp-cluster.yaml` | phải giống | như nhau | Cùng controller, cùng AMI với nhóm hệ thống, cùng trần drain | — | [EKSKARP], [KDIS] |
| Họ, thế hệ, cỡ instance, đĩa, IMDS của node Karpenter | chart `svp-cluster` (`templates/karpenter.yaml`) | phải giống | như nhau | Karpenter chọn cỡ theo pod đang chờ trong cùng tập ở hai env | — | [EKSKARP] |
| Capacity type của NodePool | `platforms/eks/svp-cluster.yaml` (prd), `envs/stg/svp-cluster.yaml` (stg) | giảm có điều kiện | stg Spot, prd on-demand | Spot rẻ hơn nhiều cho env sống vài giờ | Node bị thu hồi giữa chừng → stg kiểm luôn đường interruption của Karpenter | [SPOT], [KDIS] |
| SCP chặn Spot qua `RunInstances` | SCP `svp-prod-guardrails` ở OU `Prod` (root `aws/org`) | giảm có điều kiện | chỉ prd | Đi cùng dòng trên: stg chạy Spot nên không chặn | Chặn Spot qua `RunInstances` → phép thử guardrail khi áp org; Spot qua Karpenter do NodePool on-demand giữ ([ADR-0059](../adr/0059-org-structure-guardrails.md) §3) | [SCP] |
| Key EBS mặc định (CMK `alias/svp-ebs`) | root `aws/baseline` | phải giống | như nhau ([ADR-0059](../adr/0059-org-structure-guardrails.md) §9) | Volume của node, Karpenter, bastion mã hoá bằng cùng loại key; key policy chạy ở stg trước | — | [EBSENC] |
| `limits` của NodePool | `platforms/eks/svp-cluster.yaml` (prd), `envs/stg/svp-cluster.yaml` (stg) | được giảm | stg trần thấp hơn | Trần chặn chi phí chạy quá | — | [EKSKARP] |
| Ngân sách disruption của NodePool | `platforms/eks/svp-cluster.yaml` (prd), `envs/stg/svp-cluster.yaml` (stg) | được giảm | stg thay nhiều node một lần hơn | Mức gián đoạn chấp nhận được khác nhau | — | [KDIS] |

## Nền tảng trong cluster

| Thành phần | Giá trị ở | Nhóm | stg so với prd | Lý do | Mất gì → kiểm bù | Nguồn |
| --- | --- | --- | --- | --- | --- | --- |
| Chart, component và version nền tảng | `argocd/apps/components.json`, `base/`, `platforms/eks/` | phải giống | như nhau: lớp `platforms/eks/` không theo env | Chart nền tảng là dịch vụ; khác version là khác hệ thống | — | [12F] |
| Envoy ingress HA (HPA, PDB, trải zone) | chart `svp-cluster` (`templates/gateway.yaml`) | phải giống | như nhau | Ingress là đường của mọi request | — | [EKSAPP] |
| Kyverno HA (ba replica, PDB, trải zone) | `platforms/eks/kyverno.yaml` | phải giống | như nhau | Admission webhook chết thì không tạo được pod | — | [EKSAPP] |
| Trải theo zone | chart `svp-service` (`spreadAcrossNodes`) | phải giống | như nhau | Mất một AZ không mất mọi replica | — | [EKSAPP] |
| Kiểm image (chữ ký, báo cáo lỗ hổng, provenance) | `envs/<env>/svp-policy.yaml` | phải giống | như nhau | prd chỉ chạy image đã qua cùng cổng ở stg | — | [12F] |
| Thu telemetry trong cluster (Collector, Prometheus agent), Pyroscope, GlitchTip, Argo CD | `platforms/eks/` | phải giống | như nhau | Cùng cách quan sát và triển khai | — | [12F] |

## Registry và image

| Thành phần | Giá trị ở | Nhóm | stg so với prd | Lý do | Mất gì → kiểm bù | Nguồn |
| --- | --- | --- | --- | --- | --- | --- |
| Registry ECR, repo phát hành (KMS, tag bất biến, không lifecycle), pull-through cache, template repo cache | module `registry`, root `aws/accounts/<env>` | phải giống | như nhau ([ADR-0062](../adr/0062-ecr-registry-ci-oidc.md)) | Pod kéo image từ registry trong account của nó; chép, xác minh và cache chạy ở stg trước | — | [ECRPTC], [ECRBP] |
| Quét Inspector trên repo cache | module `registry`, root `aws/security` | phải giống | như nhau | Image bên thứ ba được quét ở cả hai account; finding vào Security Hub | — | [INSPECR] |
| Chuyển hướng image (`svp-registry-mirror`), `releaseRegistry`, credential ECR của Kyverno | `platforms/eks/svp-policy.values.tpl` | phải giống | như nhau; host là registry của env | Cùng policy đổi tham chiếu và xác minh ở ECR | — | [ECRPTC] |
| Bộ role CI ECR | `ci_roles` (khối `locals` của root `aws/accounts/<env>`) | định danh | stg nhận bản phát hành từ `main` (role release mỗi repo code), prd chỉ qua `promote-prd` (role promote); cả hai có role rescan | Đường vào image theo env, không phải mức khác: prd chỉ nhận cái stg đã chạy, qua người duyệt ([ADR-0062](../adr/0062-ecr-registry-ci-oidc.md) §5) | — | [GHOIDC] |

## Observability

| Thành phần | Giá trị ở | Nhóm | stg so với prd | Lý do | Mất gì → kiểm bù | Nguồn |
| --- | --- | --- | --- | --- | --- | --- |
| Nơi nhận telemetry (workspace AMP, log group ứng dụng, X-Ray qua Transaction Search, Amazon Managed Grafana), khoá KMS | module `observability`, root `aws/accounts/<env>` | phải giống | như nhau ([ADR-0063](../adr/0063-managed-observability.md)) | Cùng đích, cùng tên metric, luật, dashboard; dữ liệu sống qua destroy ở cả hai | — | [EKSOBS] |
| Prometheus agent HA, luật và Alertmanager trên AMP, dashboard qua Grafana Operator | `platforms/eks/`, chart `svp-observability` | phải giống | như nhau | Cảnh báo, dashboard và canary đọc cùng dữ liệu ở hai env | — | [EKSOBS] |
| Retention của workspace AMP | `amp_retention_days` (`locals` của root `aws/accounts/<env>`) | được giảm | stg ngắn hơn, vẫn phủ cửa sổ SLO dài nhất | Lưu trữ tính theo dung lượng giữ | — | [COST] |
| Retention của log group ứng dụng | `log_retention_days` (`locals` của root `aws/accounts/<env>`) | được giảm | stg ngắn hơn | Log của stg chỉ phủ một buổi vài giờ | — | [COST] |
| Retention của `aws/spans` | `span_retention_days` (`locals` của root `aws/accounts/<env>`; đặt bằng lệnh của output `spans_retention_command`) | được giảm | stg ngắn hơn | Như log group ứng dụng; log group do X-Ray tạo nên Terraform chỉ in lệnh | — | [COST] |

## RDS PostgreSQL

| Thành phần | Giá trị ở | Nhóm | stg so với prd | Lý do | Mất gì → kiểm bù | Nguồn |
| --- | --- | --- | --- | --- | --- | --- |
| Major PostgreSQL, parameter group (TLS bắt buộc, tham số ghi log) | module `rds` | phải giống | như nhau ([ADR-0057](../adr/0057-postgres17-verify-full.md) §1, §6) | Cùng engine, cùng cấu hình | — | [RDSBP] |
| CMK của storage, Performance Insights, secret master | module `rds` | phải giống | như nhau | Key policy và quyền KMS chạy ở stg trước | — | [RDSBP] |
| TLS `verify-full` với bundle CA của RDS | module `rds` (`ca_cert_identifier`), chart `svp-cluster`, `platforms/eks/` | phải giống | như nhau | Client kiểm cert server theo tên ở mọi env | — | [RDSBP] |
| Lớp instance | `rds_instance_class` (`<env>.tfvars`) | được giảm | stg lớp T, prd lớp M | Lớp T chỉ cho dev và test | — | [RDST] |
| Multi-AZ | `rds_multi_az` (`<env>.tfvars`) | giảm có điều kiện | stg một AZ, prd có standby | Standby nhân đôi giá instance | Failover sang standby → diễn tập failover RDS ở buổi prd | [RDSMAZ] |
| Trần storage tự tăng | `rds_max_allocated_storage` (`<env>.tfvars`) | được giảm | stg trần thấp hơn | Trần chặn chi phí | — | [RDSBP] |
| Retention backup | `rds_backup_retention_period` (`<env>.tfvars`) | được giảm | stg ngắn hơn | Dữ liệu stg không cần giữ quá buổi | — | [RDSBAK] |
| Giữ backup tự động sau khi xoá | `rds_delete_automated_backups` (`<env>.tfvars`) | được giảm | stg xoá cùng instance | Bảo vệ xoá; stg không còn gì sau buổi | — | [RDSDEL] |
| Deletion protection | `rds_deletion_protection` (`<env>.tfvars`; prd nhấc ở `teardown.tfvars`) | được giảm | stg tắt | Bảo vệ xoá | — | [RDSDEL] |
| Final snapshot | `rds_skip_final_snapshot` (`<env>.tfvars`) | được giảm | stg bỏ qua | Bảo vệ xoá | — | [RDSDEL] |
| Performance Insights, Database Insights | `rds_performance_insights_enabled` (`<env>.tfvars`) | phải giống | bật ở cả hai | Cùng công cụ đọc tải database | — | [RDSDI] |
| Retention Performance Insights | `rds_performance_insights_retention_period` (`<env>.tfvars`) | được giảm | cả hai ở mức miễn phí | Retention | — | [RDSDI] |
| Enhanced monitoring | `rds_monitoring_interval` (`<env>.tfvars`) | phải giống | bật ở cả hai, cùng chu kỳ | Cùng metric hệ điều hành, cùng role IAM | — | [RDSEM] |
| Export log PostgreSQL | `rds_cloudwatch_logs_exports` (`<env>.tfvars`) | phải giống | cùng loại ở cả hai | Tham số ghi log chỉ có ích khi log tới CloudWatch | — | [RDSLOG] |
| Retention log RDS | `rds_cloudwatch_logs_retention_days` (`<env>.tfvars`) | được giảm | stg ngắn hơn | Log group bị xoá cùng env | — | [COST] |

## MSK

| Thành phần | Giá trị ở | Nhóm | stg so với prd | Lý do | Mất gì → kiểm bù | Nguồn |
| --- | --- | --- | --- | --- | --- | --- |
| Version Kafka, `aws_msk_configuration` trừ RF và min ISR, SCRAM trên TLS, CMK | module `msk` | phải giống | như nhau | Cùng broker, cùng xác thực ([ADR-0053](../adr/0053-msk-elasticache-valkey.md)) | — | [MSKBP] |
| Số broker | `az_count` (`<env>.tfvars`), module `msk` | được giảm | bằng số AZ | Một broker mỗi AZ | — | [MSKBP] |
| Loại broker | `msk_broker_instance_type` (`<env>.tfvars`) | được giảm | stg nhỏ hơn | Cỡ là chi phí | — | [MSKBP] |
| Replication factor | `msk_replication_factor` (`<env>.tfvars`) | giảm có điều kiện | stg thấp hơn, theo số broker | Hai broker không giữ được RF 3 | Bản sao thứ ba khi mất broker → diễn tập mất broker ở buổi prd | [MSKBP] |
| Min in-sync replicas | `msk_min_insync_replicas` (`<env>.tfvars`) | giảm có điều kiện | stg thấp hơn | Đi theo RF để vẫn ghi được khi một broker dừng | Bảo đảm giữ ghi `acks=all` khi mất broker → diễn tập mất broker ở buổi prd | [MSKBP] |
| Broker log | `msk_broker_logs_enabled` (`<env>.tfvars`) | phải giống | bật ở cả hai | Cùng log để điều tra client và ACL | — | [MSKLOG] |
| Retention broker log | `msk_broker_logs_retention_days` (`<env>.tfvars`) | được giảm | stg ngắn hơn | Log group bị xoá cùng env | — | [COST] |
| Storage autoscaling (target tracking, không thu nhỏ) | module `msk` | phải giống | như nhau ([ADR-0058](../adr/0058-managed-data-operations.md) §4) | Đĩa broker đầy là sự cố ở mọi env | — | [MSKAUTO] |
| Trần dung lượng mỗi broker | `msk_broker_volume_max_size` (`<env>.tfvars`) | được giảm | stg trần thấp hơn | Trần chặn chi phí; dung lượng đã tăng không giảm | — | [MSKAUTO] |

## ElastiCache for Valkey

| Thành phần | Giá trị ở | Nhóm | stg so với prd | Lý do | Mất gì → kiểm bù | Nguồn |
| --- | --- | --- | --- | --- | --- | --- |
| Version, parameter group, RBAC, TLS, mã hoá at-rest, không snapshot, cửa sổ bảo trì | module `elasticache` | phải giống | như nhau | Cùng engine, cùng xác thực ([ADR-0053](../adr/0053-msk-elasticache-valkey.md)) | — | [ECBP] |
| Loại node | `valkey_node_type` (`<env>.tfvars`) | được giảm | stg nhỏ hơn | Cỡ là chi phí | — | [ECBP] |
| Số node | `valkey_node_count` (`<env>.tfvars`) | giảm có điều kiện | stg một node, prd có replica ở AZ khác | Replica nhân đôi giá | Failover sang replica → diễn tập failover Valkey ở buổi prd | [ECMAZ] |
| `apply_immediately` | `valkey_apply_immediately` (`<env>.tfvars`) | giảm có điều kiện | stg áp ngay, prd chờ cửa sổ bảo trì | stg sống vài giờ, không tới cửa sổ bảo trì | Thay đổi chờ cửa sổ → plan prd hiện thay đổi chờ | [ECMOD] |
| Slow-log tới CloudWatch Logs | module `elasticache` | phải giống | như nhau | Cùng log để đọc lệnh chậm | — | [ECLOG] |
| Retention slow-log | `valkey_slow_log_retention_days` (`<env>.tfvars`) | được giảm | stg ngắn hơn | Log group bị xoá cùng env | — | [COST] |

## Edge: CloudFront, WAF, DNS

Đường vào và lý do: [`edge.md`](edge.md); quyết định ở [ADR-0061](../adr/0061-edge-cloudfront-waf-acm.md) §14.

| Thành phần | Giá trị ở | Nhóm | stg so với prd | Lý do | Mất gì → kiểm bù | Nguồn |
| --- | --- | --- | --- | --- | --- | --- |
| Ba distribution (web, api, media), cert ACM mỗi tên, TLS policy viewer | module `edge`, module `media` | phải giống | như nhau | Cùng đường vào, cùng TLS | — | [CFVPC], [CFTLS] |
| VPC origin, ALB internal, target group của Envoy, TLS policy ALB | module `edge` | phải giống | như nhau | Chỉ CloudFront tới được Envoy ở cả hai env | — | [CFVPC] |
| Deletion protection của ALB | `edge_alb_deletion_protection` (`<env>.tfvars`; prd nhấc ở `teardown.tfvars`) | được giảm | stg tắt | Bảo vệ xoá | — | [ELBDEL] |
| Response headers policy của web, api | module `edge` | phải giống | như nhau | Cùng header bảo mật ở mọi env | — | [CFHDR] |
| Ba web ACL (rate-based, IP reputation, Core rule set, Known bad inputs; ATP ở api, Bot Control ở web) | `waf.tf` của root env, module `waf` | phải giống | như nhau | Luật WAF chặn nhầm thì stg gặp trước prd | — | [WAFMR] |
| Log WAF (che `authorization`, `cookie`) | module `waf` (`log_bucket_arn` do root suy từ id account log) | phải giống | cả hai ghi vào bucket `aws-waf-logs-svp-…` của `svp-log-archive` ([ADR-0060](../adr/0060-org-detection-logging.md) §9) | Cùng log request ở edge, cùng che header | — | [WAFLOG] |
| Retention log WAF | root `aws/log-archive` (lifecycle theo tiền tố account) | được giảm | stg ngắn hơn ([ADR-0060](../adr/0060-org-detection-logging.md) §7) | Log của stg chỉ phủ một buổi vài giờ | — | [COST] |
| Log chuẩn v2 của web, api tới bucket log CloudFront | module `edge` (ARN destination do root suy), root `aws/log-archive` | phải giống | như nhau | Đường log chéo account chạy ở stg trước | — | [CFLOG] |
| Retention log CloudFront | root `aws/log-archive` (lifecycle theo tiền tố account) | được giảm | stg ngắn hơn | Log của stg chỉ phủ một buổi vài giờ | — | [COST] |
| Gói CloudFront của media | `media_flat_rate_free` (`<env>.tfvars`) | được giảm | stg gói flat-rate Free: không log chuẩn, CORS `Managed-SimpleCORS`; prd pay-as-you-go với log chuẩn và policy `svp-prd-media` | Gói Free không tính phí theo request; web, api của stg vẫn chạy log chuẩn và policy tự viết như prd | — | [CFPLAN] |
| Envoy sau ALB (Service ClusterIP, `TargetGroupBinding`, cert CA nội bộ, nguồn NetworkPolicy) | `platforms/eks/svp-cluster.yaml`, `svp-cluster.values.tpl` | phải giống | như nhau | Cùng chuỗi chặng mà IP client dựa vào | — | [EKSNET] |
| IP client từ `CloudFront-Viewer-Address` | `platforms/eks/gateway.values.tpl` | phải giống | như nhau | Rate limit theo IP thật ở cả hai env | — | [CFHDRS] |
| Bản ghi alias và validation ACM | module `edge`, module `media` | phải giống | như nhau; tên theo zone của env | Bản ghi trong state, không controller nào trong cluster ghi zone | — | [ACMDNS] |
| CAA ở đỉnh zone | module `account-baseline` | phải giống | như nhau | Chỉ CA của Amazon phát hành cert cho tên của env | — | [ACMCAA] |
| DNSSEC và hai alarm của nó | `dnssec_enabled` (root `aws/accounts/<env>`) | được giảm | chỉ prd | Zone prd giữ tên của mọi env (stg là zone con của nó); ký thêm khoá KMS, alarm page và đường gỡ nhiều bước ([ADR-0061](../adr/0061-edge-cloudfront-waf-acm.md) §11) | — | [R53SEC] |
| Query log Route 53 | `query_log_enabled` (root `aws/accounts/<env>`) | được giảm | chỉ prd | Truy vấn tên stg không cần giữ | — | [R53QL] |

## Media: S3

| Thành phần | Giá trị ở | Nhóm | stg so với prd | Lý do | Mất gì → kiểm bù | Nguồn |
| --- | --- | --- | --- | --- | --- | --- |
| Chặn truy cập công khai, chỉ TLS, OAC | module `media` | phải giống | như nhau | Chỉ distribution media đọc bucket | — | [S3SEC] |
| Malware Protection for S3 trên `uploads` | module `media` (`malware-protection.tf`) | phải giống | như nhau ([ADR-0060](../adr/0060-org-detection-logging.md) §6) | Cùng plan, cùng role, cùng tag kết quả trên object | — | [GDMS3] |
| Data event S3 của trail org | trail `svp-audit` (root `aws/org`) | giảm có điều kiện | chỉ `uploads` (đọc, ghi) và `media` (ghi) của prd | Data event tính theo event; stg không có dữ liệu người dùng thật | Truy vết đọc, ghi object ở stg → không có ở stg; buổi prd kiểm data event có trong bucket trail | [CTDATA] |
| Xoá bucket còn object | `media_force_destroy` (`<env>.tfvars`; prd nhấc ở `teardown.tfvars`) | được giảm | stg xoá được ngay | Bảo vệ xoá | — | [S3SEC] |
| Versioning | `media_versioning_enabled` (`<env>.tfvars`) | được giảm | stg tắt | Media stg dựng lại được; bản cũ chỉ tốn chỗ | — | [S3VER] |
| S3 access log | `media_access_logging_enabled` (`<env>.tfvars`) | phải giống | bật ở cả hai | Cùng log truy cập, cùng bucket log và quyền ghi | — | [S3LOG] |

## Secret, IAM và alarm

| Thành phần | Giá trị ở | Nhóm | stg so với prd | Lý do | Mất gì → kiểm bù | Nguồn |
| --- | --- | --- | --- | --- | --- | --- |
| Entry Secrets Manager, role SecretStore theo namespace | module `external-secrets` | phải giống | như nhau; tên entry theo env | Cùng đường Secret vào cluster | — | [EKSENC] |
| Alarm CloudWatch của RDS, MSK, ElastiCache và SNS mã hoá CMK | module `alarms` và alarm trong module dịch vụ | phải giống | cùng bộ alarm ([ADR-0058](../adr/0058-managed-data-operations.md)) | Alarm phải sống khi cluster chết; stg kiểm ngưỡng và runbook | — | [CWALARM] |
| Email nhận alarm | `alarm_email` (`*.auto.tfvars` không commit) | định danh | theo env | Giá trị cá nhân | — | — |

## Workload và phát hành

| Thành phần | Giá trị ở | Nhóm | stg so với prd | Lý do | Mất gì → kiểm bù | Nguồn |
| --- | --- | --- | --- | --- | --- | --- |
| Replica, PDB, trải node của service | `envs/prd/<service>.yaml`; stg dùng `base/services/` | được giảm | stg ít replica hơn ở vài service | Số lượng là chi phí; PDB đi cùng số replica (một replica với `minAvailable: 1` chặn drain) | — | [EKSAPP] |
| Bản phát hành (commit chart, image) | `envs/<env>/charts.yaml`, `envs/<env>/images/` | định danh | prd chạy bộ stg đã chạy | Promote theo [ADR-0048](../adr/0048-prd-aws.md) §7, §8 | — | — |
| Ghim revision `svp-gitops` | `require_pinned_revision` (gitops root) | định danh | prd bắt buộc ghim | prd chỉ chạy commit stg đã đồng bộ | — | — |
| Tên env của lỗi | `SENTRY_ENVIRONMENT` ở `envs/<env>/<service>.yaml` | định danh | theo env | Mỗi lỗi trong GlitchTip nói env của nó | — | — |
| `envs/prd/svp-data.yaml` | `envs/prd/` | định danh tạm | chỉ prd | Giá trị giữ chỗ cho chart cũ prd đang ghim; gỡ khi prd ghim chart có `s3.mode` | — | — |

## Nguồn

| Nhãn | Nguồn |
| --- | --- |
| [PLEP] | AWS PrivateLink, interface VPC endpoints: <https://docs.aws.amazon.com/vpc/latest/privatelink/create-interface-endpoint.html> |
| [EKSPRIV] | Amazon EKS, private clusters (endpoint cần cho cluster không ra Internet): <https://docs.aws.amazon.com/eks/latest/userguide/private-clusters.html> |
| [ECRPTC] | Amazon ECR, pull through cache: <https://docs.aws.amazon.com/AmazonECR/latest/userguide/pull-through-cache.html> |
| [ECRBP] | Security Hub, controls for Amazon ECR: <https://docs.aws.amazon.com/securityhub/latest/userguide/ecr-controls.html> |
| [INSPECR] | Amazon Inspector, scanning Amazon ECR container images: <https://docs.aws.amazon.com/inspector/latest/user/scanning-ecr.html> |
| [GHOIDC] | GitHub, OpenID Connect reference: <https://docs.github.com/en/actions/reference/security/oidc> |
| [EKSOBS] | AWS Prescriptive Guidance, Amazon EKS observability best practices: <https://docs.aws.amazon.com/prescriptive-guidance/latest/amazon-eks-observability-best-practices/introduction.html> |
| [12F] | The Twelve-Factor App, X. Dev/prod parity: <https://12factor.net/dev-prod-parity> |
| [REL10] | AWS Well-Architected, REL10-BP01 Deploy the workload to multiple locations: <https://docs.aws.amazon.com/wellarchitected/latest/reliability-pillar/rel_fault_isolation_multiaz_region_system.html> |
| [COST] | AWS Well-Architected, Cost Optimization Pillar: <https://docs.aws.amazon.com/wellarchitected/latest/cost-optimization-pillar/welcome.html> |
| [NAT] | NAT gateway basics: <https://docs.aws.amazon.com/vpc/latest/userguide/nat-gateway-basics.html> |
| [FL] | VPC Flow Logs: <https://docs.aws.amazon.com/vpc/latest/userguide/flow-logs.html> |
| [S3EP] | Gateway endpoints for Amazon S3: <https://docs.aws.amazon.com/vpc/latest/privatelink/vpc-endpoints-s3.html> |
| [EKSSUB] | EKS Best Practices, VPC and Subnet Considerations: <https://docs.aws.amazon.com/eks/latest/best-practices/subnets.html> |
| [EKSNET] | EKS Best Practices, Network security: <https://docs.aws.amazon.com/eks/latest/best-practices/network-security.html> |
| [EKSEP] | Amazon EKS cluster endpoint access: <https://docs.aws.amazon.com/eks/latest/userguide/cluster-endpoint.html> |
| [EKSLOG] | EKS Best Practices, Auditing and logging: <https://docs.aws.amazon.com/eks/latest/best-practices/auditing-and-logging.html> |
| [CPLOG] | Amazon EKS control plane logs: <https://docs.aws.amazon.com/eks/latest/userguide/control-plane-logs.html> |
| [EKSENC] | EKS Best Practices, Data encryption and secrets management: <https://docs.aws.amazon.com/eks/latest/best-practices/data-encryption-and-secrets-management.html> |
| [EKSIAM] | EKS Best Practices, Identity and Access Management: <https://docs.aws.amazon.com/eks/latest/best-practices/identity-and-access-management.html> |
| [EKSUPG] | EKS Best Practices, Cluster upgrades: <https://docs.aws.amazon.com/eks/latest/best-practices/cluster-upgrades.html> |
| [EKSAPP] | EKS Best Practices, Running highly-available applications: <https://docs.aws.amazon.com/eks/latest/best-practices/application.html> |
| [EKSKARP] | EKS Best Practices, Karpenter: <https://docs.aws.amazon.com/eks/latest/best-practices/karpenter.html> |
| [KDIS] | Karpenter, Disruption: <https://karpenter.sh/docs/concepts/disruption/> |
| [SPOT] | EC2 Spot Instance interruptions: <https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/spot-interruptions.html> |
| [SSM] | AWS Systems Manager Session Manager: <https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager.html> |
| [RDSBP] | Best practices for Amazon RDS: <https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/CHAP_BestPractices.html> |
| [RDST] | RDS DB instance class types: <https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/Concepts.DBInstanceClass.Types.html> |
| [RDSMAZ] | RDS Multi-AZ DB instance deployments: <https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/Concepts.MultiAZSingleStandby.html> |
| [RDSBAK] | RDS automated backups: <https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/USER_WorkingWithAutomatedBackups.html> |
| [RDSDEL] | Deleting a DB instance: <https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/USER_DeleteInstance.html> |
| [RDSDI] | CloudWatch Database Insights: <https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/USER_DatabaseInsights.html> |
| [RDSEM] | RDS Enhanced Monitoring: <https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/USER_Monitoring.OS.html> |
| [RDSLOG] | Publishing RDS logs to CloudWatch Logs: <https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/USER_LogAccess.Procedural.UploadtoCloudWatch.html> |
| [MSKBP] | MSK best practices for Standard brokers: <https://docs.aws.amazon.com/msk/latest/developerguide/bestpractices.html> |
| [MSKLOG] | MSK logging: <https://docs.aws.amazon.com/msk/latest/developerguide/msk-logging.html> |
| [MSKAUTO] | MSK automatic scaling of storage: <https://docs.aws.amazon.com/msk/latest/developerguide/msk-autoexpand.html> |
| [ECBP] | ElastiCache best practices: <https://docs.aws.amazon.com/AmazonElastiCache/latest/dg/BestPractices.html> |
| [ECMAZ] | ElastiCache Multi-AZ: <https://docs.aws.amazon.com/AmazonElastiCache/latest/dg/AutoFailover.html> |
| [ECMOD] | Modifying an ElastiCache cluster (`ApplyImmediately`): <https://docs.aws.amazon.com/AmazonElastiCache/latest/dg/Clusters.Modify.html> |
| [ECLOG] | ElastiCache log delivery: <https://docs.aws.amazon.com/AmazonElastiCache/latest/dg/Log_Delivery.html> |
| [CWALARM] | CloudWatch recommended alarms: <https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/Best_Practice_Recommended_Alarms_AWS_Services.html> |
| [S3SEC] | Security best practices for Amazon S3: <https://docs.aws.amazon.com/AmazonS3/latest/userguide/security-best-practices.html> |
| [S3LOG] | S3 server access logging: <https://docs.aws.amazon.com/AmazonS3/latest/userguide/ServerLogs.html> |
| [S3VER] | S3 versioning: <https://docs.aws.amazon.com/AmazonS3/latest/userguide/Versioning.html> |
| [SRA] | AWS Security Reference Architecture, Log Archive account: <https://docs.aws.amazon.com/prescriptive-guidance/latest/security-reference-architecture/log-archive.html> |
| [CIS] | Security Hub control EC2.21 (CIS AWS Foundations Benchmark): <https://docs.aws.amazon.com/securityhub/latest/userguide/ec2-controls.html#ec2-21> |
| [GDRT] | GuardDuty Runtime Monitoring, EKS: <https://docs.aws.amazon.com/guardduty/latest/ug/how-runtime-monitoring-works-eks.html> |
| [SCP] | Service control policies: <https://docs.aws.amazon.com/organizations/latest/userguide/orgs_manage_policies_scps.html> |
| [EBSENC] | EBS encryption by default: <https://docs.aws.amazon.com/ebs/latest/userguide/encryption-by-default.html> |
| [WAFLOG] | AWS WAF logging: <https://docs.aws.amazon.com/waf/latest/developerguide/logging.html> |
| [GDMS3] | GuardDuty Malware Protection for S3: <https://docs.aws.amazon.com/guardduty/latest/ug/gdu-malware-protection-s3.html> |
| [CTDATA] | CloudTrail data events: <https://docs.aws.amazon.com/awscloudtrail/latest/userguide/logging-data-events-with-cloudtrail.html> |
| [CFVPC] | CloudFront, Restrict access with VPC origins: <https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/private-content-vpc-origins.html> |
| [CFTLS] | CloudFront, supported protocols and ciphers between viewers and CloudFront: <https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/secure-connections-supported-viewer-protocols-ciphers.html> |
| [CFHDR] | CloudFront, response headers policies: <https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/adding-response-headers.html> |
| [CFHDRS] | CloudFront, Add CloudFront request headers: <https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/adding-cloudfront-headers.html> |
| [CFLOG] | CloudFront, standard logging (v2): <https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/standard-logging.html> |
| [CFPLAN] | CloudFront, flat-rate pricing plans: <https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/flat-rate-pricing-plan.html> |
| [ELBDEL] | ALB, deletion protection: <https://docs.aws.amazon.com/elasticloadbalancing/latest/application/edit-load-balancer-attributes.html> |
| [WAFMR] | AWS WAF, AWS Managed Rules: <https://docs.aws.amazon.com/waf/latest/developerguide/aws-managed-rule-groups-baseline.html> |
| [ACMDNS] | ACM, DNS validation: <https://docs.aws.amazon.com/acm/latest/userguide/dns-validation.html> |
| [ACMCAA] | ACM, CAA records: <https://docs.aws.amazon.com/acm/latest/userguide/setup-caa.html> |
| [R53SEC] | Route 53, DNSSEC signing: <https://docs.aws.amazon.com/Route53/latest/DeveloperGuide/dns-configuring-dnssec.html> |
| [R53QL] | Route 53, public DNS query logging: <https://docs.aws.amazon.com/Route53/latest/DeveloperGuide/query-logs.html> |
