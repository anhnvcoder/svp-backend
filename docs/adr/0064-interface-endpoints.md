# 0064. Gọi API AWS từ VPC của stg, prd đi qua endpoint interface có private DNS, một security group chỉ nhận 443 từ VPC, endpoint policy chặn principal ngoài account; ENI ở mọi AZ của prd, một AZ ở stg; NAT giữ đích ngoài AWS và vài API AWS

- Trạng thái: Chấp nhận
- Ngày: 2026-11-13
- Người quyết: người học (prd là production chuẩn ngành, stg chạy như prd), AI đề xuất danh sách dịch vụ, policy và số AZ theo tài liệu AWS

## Bối cảnh và vấn đề

- Node và pod ở subnet private gọi API AWS (Pod Identity, ECR, Secrets Manager, EC2, SQS của Karpenter, telemetry tới AMP, CloudWatch Logs,
  X-Ray) qua NAT gateway tới endpoint công khai. VPC chỉ có gateway endpoint S3 và endpoint interface `guardduty-data`
  ([0060](0060-org-detection-logging.md)): mọi gọi khác rời VPC, không policy nào giới hạn được ai dùng đường ra đó.
- Security Hub FSBP có control đòi endpoint interface cho EC2, ECR API, ECR Docker, Systems Manager (EC2.10, EC2.55–EC2.57) [N15].
- Cùng đợt thay đổi thêm đích AWS mới gọi từ cluster: ECR private, AMP, CloudWatch Logs, X-Ray (ADR-0062, ADR-0063).
- Ràng buộc: env sống trong buổi tối đa 4 giờ; stg chạy như prd, chỉ giảm dự phòng ([0055](0055-environment-matrix.md)); AI không chạy lệnh chạm account.

## Yếu tố quyết định

- Lưu lượng tới API AWS không rời VPC, đi qua điểm có policy; credential lộ ra ngoài account không dùng được qua đường này
  (Well-Architected SEC05 [N16]; EKS "private clusters" [N2]).
- Pod không phải sửa gì: tên API công khai phân giải ra IP trong VPC.
- Thêm dưới ngưỡng chi phí của run (phụ lục §7); stg giảm dự phòng, không giảm đường đi.

## Phương án đã cân nhắc

Trạng thái ngành, được, mất, nguồn: [phụ lục](appendix/0064-interface-endpoints.md#phương-án). In đậm là lựa chọn.

- Đường tới API AWS: không endpoint, mọi gọi qua NAT (như hiện có; FSBP EC2.10, EC2.55–EC2.57 FAILED); chỉ endpoint FSBP đòi; **endpoint cho
  các dịch vụ ở §1, NAT giữ đích ngoài AWS và các API AWS ở §6**; VPC cô lập, bỏ NAT
  (Argo CD cần GitHub, Kyverno cần Sigstore: không được).
- Nơi đặt: **mỗi VPC env một bộ**; bộ endpoint chung ở VPC shared-services qua Transit Gateway (mẫu nhiều VPC; lab một VPC mỗi account).
- Endpoint policy: mặc định (mọi principal); **chặn principal ngoài account**; thêm vành tài nguyên `aws:ResourceAccount` (vỡ với tài nguyên
  của AWS: tham số SSM công khai Karpenter đọc, bucket layer của ECR).
- Số AZ ở stg: **một AZ**; bằng prd; không endpoint ở stg (trái 0055: đường đi, policy, NetworkPolicy phải chạy thử ở stg).

## Kết quả quyết định

Chọn các phương án in đậm, vì gọi tới các API AWS ở §1 đi qua endpoint có policy trong VPC mà pod không đổi gì; NAT giữ GitHub, registry
công khai, Sigstore, Telegram và các API AWS ở §6 (không có endpoint ở region, hay có mà §1 không đặt). Giá trị đủ từng mục, bảng dịch vụ:
phụ lục, cùng số §.

### 1. Dịch vụ

- **Endpoint interface** (module `network`, danh sách là dữ liệu của module): `sts`, `eks-auth`, `secretsmanager`, `logs`, `ssm`, `ssmmessages`,
  `ec2messages`, `ecr.api`, `ecr.dkr`, `ec2`, `elasticloadbalancing`, `aps-workspaces`, `aps`, `xray`, `sqs`. Mỗi dịch vụ có trong danh sách
  PrivateLink của AWS [N1]; ai gọi, vì sao cần: bảng ở phụ lục §1.
- **`kms` không vào danh sách:** không thành phần nào trong VPC gọi KMS trực tiếp; EBS, Secrets Manager, ECR, S3, CloudWatch Logs, AMP gọi KMS thay
  người dùng ở phía dịch vụ. Bảng endpoint cho private cluster của EKS cũng không có KMS [N2].
- `guardduty-data` và gateway endpoint S3 giữ như cũ (security group, policy riêng của 0060 và module `network`).
- Mỗi dịch vụ đọc bằng data source `aws_vpc_endpoint_service` lúc plan [N17]: dịch vụ không có ở region thì plan dừng, trước khi tạo gì.

### 2. Private DNS và security group

- `private_dns_enabled = true` cho mọi endpoint: tên regional (`sts.<region>.amazonaws.com`, `api.ecr.<region>.amazonaws.com`…) phân giải ra IP
  ENI trong VPC, SDK và agent không cần cấu hình endpoint riêng. SDK dùng STS regional (mặc định của SDK hiện hành); STS global không qua endpoint [N2].
- Một security group `svp-<env>-endpoints` cho mọi endpoint của §1: ingress TCP 443 từ CIDR VPC, không rule egress. Endpoint ở subnet private
  (cùng tầng với node).

### 3. Endpoint policy

- Mọi endpoint của §1 mà dịch vụ nhận policy: `Allow` mọi hành động cho mọi principal, `Deny` khi `aws:PrincipalAccount` khác account của env
  (cùng mẫu với `guardduty-data`). Policy không thay IAM hay resource policy [N12]: nó chỉ chặn credential của account khác dùng đường này.
- Dịch vụ không nhận policy thì AWS cho toàn quyền qua endpoint [N12]: module đặt policy khi `vpc_endpoint_policy_supported` của data source là
  `true`, không đoán theo tên. Tài liệu xác nhận nhận policy: ECR, Secrets Manager, CloudWatch Logs, AMP (`aps`, `aps-workspaces`), X-Ray,
  Systems Manager; còn lại theo thuộc tính lúc plan (phụ lục §3).
- Không ngoại lệ nào cho caller không mang principal: mọi caller của §1 ký request bằng credential trong account (Pod Identity, role node, profile
  của bastion). Request không ký (`AssumeRoleWithWebIdentity` của IRSA) bị chặn ở endpoint `sts`: IRSA không dùng ([0034](0034-aws-stage7.md) Câu 16).

### 4. Số AZ đặt ENI

Biến `interface_endpoint_az_count` (subnet private đầu danh sách AZ): prd bằng `az_count`, stg `1`. Private DNS chỉ trả IP của ENI đang có, nên pod
ở AZ khác của stg đi chéo AZ tới ENI đó. stg đã phụ thuộc AZ đầu cho đường ra (`single_nat_gateway = true`): một AZ cho endpoint không thêm miền lỗi.

### 5. Đường từ pod tới endpoint

NetworkPolicy của Kyverno, External Secrets (`svp-cluster`) và Collector, Prometheus agent, ACK (`svp-observability`) mở TCP 443 tới địa chỉ công
khai, trừ mọi dải private; private DNS đổi đích của chúng thành IP trong VPC, nên chúng bị chặn nếu không mở thêm. Theo **Đường tới endpoint interface**:
value `awsEndpointCidrs` (mặc định rỗng, render như cũ; eks `[cluster.vpcCidr]`) thêm TCP 443 tới các CIDR đó. Gateway endpoint S3 dùng route theo
prefix list (IP công khai) nên luồng S3 không đổi.

### 6. Thứ vẫn đi qua NAT

GitHub (Argo CD đọc `svp-gitops`, Notifications), Telegram, Sigstore (Kyverno), lần kéo đầu của pull-through cache [N9], API ECR Public (chỉ
`us-east-1`), API Pricing của Karpenter (không endpoint ở region; `isolatedVPC` của Karpenter giữ `false` [N18]), `eks:DescribeCluster` lúc
Karpenter khởi động, API và workspace của Amazon Managed Grafana (Grafana Operator). Bảng đủ: phụ lục §6.

### 7. Chi phí

Theo Price List `AmazonVPC` `ap-southeast-1` (phát hành 2026-11-05): $0,013 mỗi endpoint mỗi AZ mỗi giờ, $0,01 mỗi GB xử lý [N14]. Buổi 4 giờ
thêm ~$0,75 ở stg (15 ENI), ~$2,3 ở prd (45 ENI), đã trừ dữ liệu không còn qua NAT; lúc không buổi $0 (endpoint thuộc root env, gỡ cùng buổi).
Dưới ngưỡng chi phí đặt cho thay đổi này; bảng: phụ lục §7.

### Hệ quả

- Tốt: gọi tới các API AWS ở §1 nằm trong VPC, qua policy chặn credential ngoài account; FSBP EC2.10, EC2.55–EC2.57 đạt; dữ liệu telemetry
  rẻ hơn qua endpoint ($0,01 so với $0,059 mỗi GB qua NAT); Pod Identity, kéo image không phụ thuộc NAT.
- Xấu: 15 endpoint mỗi env tính theo giờ, khoản cố định lớn nhất của buổi prd trong run; thêm value NetworkPolicy theo nền tảng; stg mất API
  AWS khi AZ đầu hỏng (như NAT của nó); EC2.58, EC2.60 (Incident Manager) FAILED có chủ đích.
- Xem lại khi: OTLP của X-Ray hay CloudWatch Logs không đi qua endpoint (phụ lục §1); thêm thành phần gọi KMS trực tiếp; dùng IRSA; số VPC
  tăng tới mức endpoint chung qua Transit Gateway rẻ hơn.

## Xác nhận

- Lúc quyết chưa hiện thực. Kiểm tĩnh: `make test` của `svp-infra` (module `network`: đủ 15 dịch vụ, private DNS, SG chỉ 443 từ CIDR VPC, policy
  chỉ ở dịch vụ nhận, số subnet theo `interface_endpoint_az_count`); `make helm-check` của repo này (`awsEndpointCidrs` rỗng render như cũ).
- Plan của người học in `vpc_endpoint_policy_supported` từng dịch vụ (phụ lục §3).
- Buổi stg, prd: từ một pod, tên của §1 phân giải ra IP trong CIDR VPC; External Secrets đồng bộ, Kyverno xác minh, Pod Identity, kéo image
  chạy; span và log tới X-Ray, CloudWatch Logs; Security Hub báo EC2.10, EC2.55–EC2.57 PASSED; `sweep.sh <env>` không còn endpoint.

## Hiện thực ở

- `svp-infra`: `aws/modules/network/` (§1–§4), `aws/envs/<env>/<env>.tfvars` (`interface_endpoint_az_count`), `aws/scripts/sweep.sh`.
- Repo này: `deploy/helm/svp-cluster/`, `deploy/helm/svp-observability/` (value `awsEndpointCidrs`, §5).
- `svp-gitops`: `platforms/eks/*.values.tpl` (`awsEndpointCidrs` từ `cluster.vpcCidr`).

## Nguồn

Đọc 2026-11-13; đủ [N1]–[N18] ở phụ lục. [N1] <https://docs.aws.amazon.com/vpc/latest/privatelink/aws-services-privatelink-support.html>,
[N2] <https://docs.aws.amazon.com/eks/latest/userguide/private-clusters.html>,
[N12] <https://docs.aws.amazon.com/vpc/latest/privatelink/vpc-endpoints-access.html>.

## Thông tin thêm

Phụ lục: [`appendix/0064-interface-endpoints.md`](appendix/0064-interface-endpoints.md) (phương án, bảng dịch vụ, policy, chi phí, bảng control FSBP,
bảng luồng SCP, RCP, nguồn).
