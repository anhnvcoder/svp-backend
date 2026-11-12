# Phụ lục ADR-0064: Gọi API AWS từ VPC của stg, prd đi qua endpoint interface có private DNS, một security group chỉ nhận 443 từ VPC, endpoint policy chặn principal ngoài account; ENI ở mọi AZ của prd, một AZ ở stg; NAT chỉ còn cho đích ngoài AWS

Phụ lục của [ADR-0064](../0064-interface-endpoints.md): phương án, bảng dịch vụ, policy, chi phí, bảng control FSBP, bảng luồng SCP, RCP và nguồn,
xếp theo §. Mọi nguồn đọc ngày 2026-11-13. Đường dẫn `aws/...` không kèm repo là của `svp-infra`; `<region>` là `ap-southeast-1`.

## Phương án

| Câu hỏi | Phương án | Trạng thái ngành | Được | Mất | Nguồn |
| --- | --- | --- | --- | --- | --- |
| Đường tới API AWS | Không endpoint interface, mọi gọi qua NAT | Hiện hành cho VPC nhỏ, chi phí thấp | $0 theo giờ; không gì mới phải giữ | Mọi gọi rời VPC; không điểm nào đặt policy; dữ liệu $0,059/GB qua NAT; FSBP EC2.10, EC2.55–EC2.57 FAILED | [N14], [N15] |
| | Chỉ endpoint FSBP đòi (`ec2`, `ecr.api`, `ecr.dkr`, `ssm`) cộng `eks-auth` | Hiện hành | Đạt control, rẻ hơn ~60 % | Secrets Manager, telemetry, STS, SQS vẫn qua NAT: một nửa đường có policy, nửa không | [N2], [N15] |
| | **Endpoint cho mọi dịch vụ cluster gọi, NAT giữ cho đích ngoài AWS** | Hiện hành, cách của EKS cho private cluster | Mọi gọi API AWS ở trong VPC, một policy; NAT chỉ còn cho đích ngoài AWS | 15 endpoint tính theo giờ mỗi AZ | [N2] |
| | VPC cô lập, bỏ NAT | Hiện hành cho môi trường bị quản chặt (Karpenter `isolatedVPC`) | Không đường nào ra Internet | Argo CD cần GitHub, Kyverno cần Sigstore, pull-through cache cần NAT lần kéo đầu: phải thêm mirror git, TUF nội bộ | [N9], [N18] |
| Nơi đặt endpoint | **Mỗi VPC env một bộ** | Hiện hành | Không Transit Gateway; endpoint gỡ cùng buổi | Hai env hai bộ | — |
| | Bộ chung ở VPC shared-services qua Transit Gateway và Route 53 Resolver | Hiện hành cho org nhiều VPC | Một bộ cho mọi VPC | Thêm Transit Gateway theo giờ và theo GB, một account mới; lab một VPC mỗi account | — |
| Endpoint policy | Mặc định (toàn quyền) | Mặc định của AWS | Không gì phải giữ | Credential của account khác dùng được đường này | [N12] |
| | **`Deny` khi `aws:PrincipalAccount` khác account env** | Hiện hành, vành danh tính của mẫu data perimeter | Credential ngoài account bị chặn ở endpoint | Thêm caller không ký request (IRSA) thì phải mở ngoại lệ | [N12] |
| | Thêm vành tài nguyên `aws:ResourceAccount` | Hiện hành, cần ngoại lệ theo dịch vụ | Chặn ghi dữ liệu sang tài nguyên account khác | Tham số SSM công khai Karpenter đọc AMI, bucket layer của ECR thuộc AWS: mỗi dịch vụ một ngoại lệ; RCP `svp-data-perimeter` đã giữ phía tài nguyên của S3, KMS, Secrets Manager, SQS, STS | [0059](../0059-org-structure-guardrails.md) §4 |
| Số AZ ở stg | **Một AZ** | Hiện hành (giảm dự phòng) | 1/2 phí giờ của stg hai AZ | Pod ở AZ khác đi chéo AZ; mất AZ đầu là mất API AWS (stg đã mất NAT khi đó) | [N14] |
| | Bằng prd (`az_count`) | Hiện hành | Không khác biệt | Gấp đôi phí theo giờ ở stg cho dự phòng stg không cần | — |
| | Không endpoint ở stg | — | $0 ở stg | Trái [0055](../0055-environment-matrix.md): private DNS, policy, NetworkPolicy chỉ chạy lần đầu ở prd | — |
| Security group | **Một SG chung cho §1** | Hiện hành | Một rule cho mọi endpoint cùng luật | — | — |
| | Một SG mỗi endpoint | Hiện hành | Tách được luật theo dịch vụ | 15 SG cùng một rule | — |

## §1. Dịch vụ

"Ai gọi" là thành phần trong VPC gọi tên API đó. Cột "Tài liệu nói" trích trang của dịch vụ về endpoint policy; ô trống là trang không nói, module đọc
thuộc tính `vpc_endpoint_policy_supported` lúc plan (§3). Mọi tên có trong danh sách dịch vụ PrivateLink [N1]; EKS ghi PrivateLink của `eks-auth`
chỉ thiếu ở vài region, không có `ap-southeast-1` [N3].

| Endpoint (`com.amazonaws.<region>.…`) | Ai gọi | Vì sao cần | Tài liệu nói về policy |
| --- | --- | --- | --- |
| `sts` | ACK prometheusservice (`GetCallerIdentity` lúc khởi động), SDK của pod khi cần STS | AMP: remote write không có Internet cần endpoint STS [N6]; SDK hiện hành dùng STS regional | — |
| `eks-auth` | EKS Pod Identity Agent trên mọi node (`AssumeRoleForPodIdentity`) | "If you are using private subnets for your nodes, you must set up an AWS PrivateLink interface endpoint for the EKS Auth API" [N4] | — ([N3] không nói) |
| `secretsmanager` | External Secrets | Mọi Secret của cluster trên eks | Nhận: "The default endpoint policy allows full access" [N10] |
| `logs` | Collector (log của service, ADR-0063) | Đích log trên eks | Nhận [N8] |
| `ssm` | SSM Agent của bastion `ssm-bastion` (tunnel API EKS), Karpenter (`GetParameter` tham số AMI) | EC2.57; Session Manager [N5] | Nhận: "You can create policies for VPC interface endpoints for AWS Systems Manager" [N5] |
| `ssmmessages` | SSM Agent của bastion: kênh phiên port forwarding | Session Manager [N5] | Như dòng `ssm` |
| `ec2messages` | SSM Agent của bastion, bản trước 3.3.40.0 | [N5] còn liệt kê; từ 3.3.40.0 agent dùng `ssmmessages` khi có | Như dòng `ssm` |
| `ecr.api` | kubelet (credential provider, `GetAuthorizationToken`), Kyverno khi xác minh chữ ký ở ECR (ADR-0062) | EC2.55; image phát hành và cache ở ECR | Nhận [N9] |
| `ecr.dkr` | kubelet, containerd (manifest), Kyverno (manifest, referrer) | EC2.56; layer đi qua gateway endpoint S3 (bucket `prod-<region>-starport-layer-bucket` đã có trong policy S3) | Nhận [N9] |
| `ec2` | Karpenter (`CreateFleet`, `Describe*`), VPC CNI (`ipamd`), EBS CSI, AWS Load Balancer Controller | EC2.10; "If you use the EKS Optimized AMI, you should enable the `ec2` endpoint" [N2] | — |
| `elasticloadbalancing` | AWS Load Balancer Controller (`TargetGroupBinding`, [0061](../0061-edge-cloudfront-waf-acm.md) §4) | [N2] liệt kê cho private cluster | — |
| `aps-workspaces` | Prometheus agent (remote write), Argo Rollouts (truy vấn canary), Collector khi xuất metric (ADR-0063) | "Prometheus-compatible APIs" [N6] | Nhận [N6] |
| `aps` | ACK prometheusservice (rule group, Alertmanager definition) | "workspace management tasks" [N6] | Nhận [N6] |
| `xray` | Collector (span qua OTLP `https://xray.<region>.amazonaws.com/v1/traces`, ADR-0063) | Đích trace trên eks; [N2] liệt kê | Nhận [N7] |
| `sqs` | Karpenter (hàng đợi interruption `svp-<env>-karpenter`, [0056](../0056-eks-platform-ha.md) §1) | Báo trước 2 phút khi Spot bị thu hồi | — |

**Không thêm:**

| Endpoint | Lý do |
| --- | --- |
| `kms` | Không thành phần nào trong VPC gọi KMS trực tiếp: EBS (đĩa node, PVC), Secrets Manager, ECR, S3, CloudWatch Logs, AMP dùng key thay người dùng ở phía dịch vụ; role Pod Identity cần `kms:Decrypt` cho lời gọi đó, không cần đường mạng tới KMS. [N2] không liệt kê. KMS nhận endpoint và policy ở mọi region [N11]: thêm khi có caller trực tiếp |
| `eks` | Chỉ Karpenter gọi `DescribeCluster` một lần lúc khởi động; NAT còn. EKS không cho bắt API EKS chỉ qua endpoint [N3] |
| `oidc-eks` | Chỉ IRSA cần; IRSA không dùng |
| `grafana`, `grafana-workspace` | Grafana Operator gọi workspace AMG; AMG không cấu hình VPC (ADR-0063), đường qua NAT tới endpoint công khai có xác thực |
| `stream-logs` | Chỉ `StartLiveTail`, `GetLogObject` [N8]: không thành phần nào gọi |

**OTLP qua endpoint:** trang OTLP của CloudWatch chỉ ghi tên công khai `https://xray.<region>.amazonaws.com/v1/traces` và
`https://logs.<region>.amazonaws.com/v1/logs` [N13]; trang endpoint của X-Ray [N7] và CloudWatch Logs [N8] không nói đường `/v1/*`. Private DNS
đè hai tên này cho mọi đường dẫn, nên buổi stg đầu tiên kiểm span và log tới đích. Không tới: bỏ `xray` hay `logs` khỏi danh sách (gọi qua NAT
như trước), ghi `### Chỉnh bởi`.

## §2. Private DNS và security group

- `private_dns_enabled = true`: Route 53 Resolver của VPC trả IP ENI cho tên regional của dịch vụ; cần `enable_dns_hostnames`, `enable_dns_support`
  của VPC (module `vpc` bật sẵn).
- STS: tên global `sts.amazonaws.com` không qua endpoint [N2]. SDK Go v2, JS v3, botocore hiện hành mặc định regional; Pod Identity không dùng STS.
- SG `svp-<env>-endpoints`: một rule ingress TCP 443, nguồn CIDR VPC (pod lấy IP trong VPC qua VPC CNI); không rule egress (endpoint chỉ trả lời).
  SG `<name>-guardduty-data` có sẵn giữ nguyên.

## §3. Endpoint policy

Policy của mọi endpoint ở §1 khi `vpc_endpoint_policy_supported` là `true` (account `000000000000` là ví dụ):

```json
{
  "Version": "2012-10-17",
  "Statement": [
    { "Effect": "Allow", "Principal": "*", "Action": "*", "Resource": "*" },
    {
      "Effect": "Deny", "Principal": "*", "Action": "*", "Resource": "*",
      "Condition": { "StringNotEquals": { "aws:PrincipalAccount": "000000000000" } }
    }
  ]
}
```

- `StringNotEquals` trên khoá không có (request không ký) cho `true`, nên request ẩn danh bị chặn: đúng ý, vì không caller nào của §1 ẩn danh.
- Không dùng wildcard với `aws:PrincipalAccount` [N12].
- Dịch vụ không nhận policy: AWS cho toàn quyền qua endpoint [N12]; module không gửi policy cho nó. Plan của người học ghi danh
  sách dịch vụ có `vpc_endpoint_policy_supported = false` vào Result của card apply; dịch vụ đó vẫn được IAM và RCP giữ.
- Systems Manager: tài liệu cảnh báo điều kiện theo principal chặn node hybrid [N5]; lab không có node hybrid.

## §4. Số AZ đặt ENI

| Env | `az_count` | `interface_endpoint_az_count` | ENI | Lý do |
| --- | --- | --- | --- | --- |
| prd | 3 | 3 | 45 | Mất một AZ không mất API AWS; không đi chéo AZ |
| stg | 2 | 1 | 15 | Giảm dự phòng (0055 §3); NAT của stg đã ở AZ đầu |

Validation của biến: số nguyên 1…`az_count`. Subnet lấy từ đầu danh sách subnet private (AZ đầu), cùng thứ tự với NAT đơn của stg.

## §5. Đường từ pod tới endpoint

| Pod | NetworkPolicy hiện có | Thêm |
| --- | --- | --- |
| Kyverno admission controller (`svp-cluster`) | TCP 443 tới `0.0.0.0/0` trừ `kyverno.privateRanges` | TCP 443 tới `awsEndpointCidrs` |
| External Secrets (`svp-cluster`) | Như Kyverno; TCP 80 tới `169.254.170.23/32` (Pod Identity Agent) | TCP 443 tới `awsEndpointCidrs` |
| Collector, Prometheus agent, ACK (`svp-observability`) | Theo ADR-0063 | TCP 443 tới `awsEndpointCidrs`; TCP 80 tới `169.254.170.23/32` |
| Namespace `svp` | Chặn egress mặc định; S3 qua prefix list | Không đổi: service không gọi API nào của §1 |

Value `awsEndpointCidrs` là danh sách, mặc định rỗng (k3d, compose: render như cũ), eks `[cluster.vpcCidr]` ở `platforms/eks/*.values.tpl`.

## §6. Thứ vẫn đi qua NAT

| Đích | Ai gọi | Vì sao không qua endpoint |
| --- | --- | --- |
| `github.com`, API GitHub | Argo CD (repo `svp-gitops`, Notifications) | Ngoài AWS |
| API Telegram | Argo CD Notifications | Ngoài AWS |
| Sigstore (TUF, Rekor, Fulcio) | Kyverno | Ngoài AWS |
| Registry upstream qua pull-through cache, lần kéo đầu | ECR thay kubelet | "you need to create a public subnet in the same VPC, with a NAT gateway" cho lần kéo đầu khi dùng endpoint [N9] |
| API ECR Public | Kéo từ `public.ecr.aws` không qua cache | Endpoint ECR Public chỉ ở `us-east-1` [N9] |
| API Pricing | Karpenter | Không endpoint ở region; `isolatedVPC: false` giữ tra giá on-demand [N18] |
| `eks:DescribeCluster` | Karpenter lúc khởi động | §1 bảng "Không thêm" |
| Workspace, API Amazon Managed Grafana | Grafana Operator | §1 bảng "Không thêm" |

## §7. Chi phí

### Bảng giá

| Mục | Giá (USD) | Nguồn |
| --- | --- | --- |
| Endpoint interface | 0,013 mỗi giờ, tính theo từng AZ đặt endpoint | [N14] Price List (`APS1-VpcEndpoint-Hours`: "$0.013 per VPC Endpoint Hour"); "billed for each hour that your VPC endpoint remains provisioned in each Availability Zone" |
| Dữ liệu qua endpoint | 0,01 mỗi GB tới 1 PB mỗi tháng | [N14] (`APS1-VpcEndpoint-Bytes`) |
| NAT gateway | 0,059 mỗi giờ; 0,059 mỗi GB xử lý | Phụ lục [0048](0048-prd-aws.md) §10 |
| Item AWS Config | 0,003 mỗi item ghi | Phụ lục [0061](0061-edge-cloudfront-waf-acm.md) §13 |
| Truyền chéo AZ | 0,01 mỗi GB mỗi chiều | Trang giá EC2 (truyền dữ liệu trong region) |

### Thêm mỗi buổi

Buổi 4 giờ; 15 dịch vụ. Dữ liệu là ước lượng: telemetry (metric remote write, log, span) và manifest image, ~2 GB mỗi buổi; layer image qua S3.

| Khoản | stg | prd |
| --- | --- | --- |
| Endpoint: 15 × AZ × 4 × 0,013 (stg 1 AZ, prd 3 AZ) | 0,78 | 2,34 |
| Dữ liệu qua endpoint: ~2 GB × 0,01 | 0,02 | 0,02 |
| Chéo AZ ở stg: ~1 GB × 0,02 | 0,02 | 0 |
| Item Config: ~17 tài nguyên (15 endpoint, SG, rule) × 0,003 | 0,05 | 0,05 |
| Dữ liệu không còn qua NAT: ~2 GB × 0,059 | −0,12 | −0,12 |
| **Cộng** | **~0,75** | **~2,3** |

### Lúc không buổi

$0: endpoint, SG thuộc root `aws/envs/<env>`, gỡ cùng buổi (**Nơi sống của tài nguyên**). Không khoản lưu trữ nào.

Cả hai dưới ngưỡng chi phí của bốn ADR cùng ngày (ghi ở phụ lục [0063](0063-managed-observability.md) cộng bảng tổng.

## Bảng control FSBP

Control Security Hub CSPM áp lên tài nguyên mới; "FSBP" là có trong AWS Foundational Security Best Practices v1.0.0 [N15].

| Control | Tiêu đề (tóm tắt) | FSBP | Kết quả | Lý do |
| --- | --- | --- | --- | --- |
| EC2.10 | EC2 dùng VPC endpoint của dịch vụ EC2 | có | Đạt | Endpoint `ec2` |
| EC2.55 | VPC có endpoint interface cho ECR API | có | Đạt | `ecr.api` |
| EC2.56 | VPC có endpoint interface cho Docker Registry | có | Đạt | `ecr.dkr` |
| EC2.57 | VPC có endpoint interface cho Systems Manager | có | Đạt | `ssm` |
| EC2.58 | VPC có endpoint interface cho Incident Manager Contacts | có | Chấp nhận (FAILED) | Không dùng Incident Manager; endpoint không caller là phí theo giờ không lý do |
| EC2.60 | VPC có endpoint interface cho Incident Manager | có | Chấp nhận (FAILED) | Như EC2.58 |
| EC2.18 | SG chỉ mở không giới hạn cổng được phép | có | Đạt | SG endpoint chỉ nhận từ CIDR VPC |
| EC2.19 | SG không mở không giới hạn cổng rủi ro cao | có | Đạt | Như trên |
| EC2.47 | VPC endpoint service có tag | không | Không áp | Lab không tạo endpoint service; endpoint có `default_tags` |

## Bảng luồng SCP, RCP

Đối chiếu với SCP và RCP `svp-data-perimeter` của [0059](../0059-org-structure-guardrails.md) §3, §4. RCP phủ S3, KMS, Secrets Manager, SQS, STS;
dịch vụ khác ngoài phạm vi RCP. Endpoint ở `ap-southeast-1`, trong region SCP `svp-deny-other-regions` cho phép; không SCP nào chặn
`ec2:CreateVpcEndpoint`, `ModifyVpcEndpoint`, `DeleteVpcEndpoints` (gỡ buổi chạy được).

| Luồng | Principal | Tài nguyên | Qua nhờ |
| --- | --- | --- | --- |
| Terraform tạo, gỡ endpoint, SG | `SvpAdmin` của env | EC2 (VPC) | Ngoài phạm vi RCP; SCP không chặn |
| Pod Identity Agent lấy credential | Role node | EKS Auth | Ngoài phạm vi RCP |
| External Secrets đọc secret | Role Pod Identity | Secrets Manager của env | Principal trong org (`aws:PrincipalOrgID`) |
| ACK `GetCallerIdentity` | Role Pod Identity | STS | Không tài nguyên; principal trong org |
| Karpenter nhận tin interruption | Role Pod Identity | SQS của env | Principal trong org |
| Karpenter đọc tham số AMI | Role Pod Identity | Tham số SSM công khai của AWS | Tài nguyên ngoài org: RCP chỉ áp lên tài nguyên của org |
| kubelet kéo image | Role node | ECR của env; layer ở bucket S3 của AWS | ECR ngoài phạm vi RCP; bucket layer không thuộc org |
| Collector, Prometheus agent, Argo Rollouts, ACK gọi AMP, CloudWatch Logs, X-Ray | Role Pod Identity | AMP, Logs, X-Ray của env | Ngoài phạm vi RCP; key KMS của chúng do dịch vụ gọi |
| Bastion mở phiên | Role của bastion; phiên SSO của người học | Systems Manager | Ngoài phạm vi RCP |
| Load Balancer Controller, VPC CNI, EBS CSI, Karpenter gọi EC2, ELB | Role Pod Identity, role node | EC2, ELB | Ngoài phạm vi RCP |

Không luồng nào cần ngoại lệ SCP hay RCP.

## Nguồn

- [N1] AWS PrivateLink, AWS services that integrate with AWS PrivateLink:
  <https://docs.aws.amazon.com/vpc/latest/privatelink/aws-services-privatelink-support.html>
- [N2] Amazon EKS, Deploy private clusters with limited internet access: <https://docs.aws.amazon.com/eks/latest/userguide/private-clusters.html>
- [N3] Amazon EKS, Access Amazon EKS using AWS PrivateLink: <https://docs.aws.amazon.com/eks/latest/userguide/vpc-interface-endpoints.html>
- [N4] Amazon EKS, Set up the Amazon EKS Pod Identity Agent: <https://docs.aws.amazon.com/eks/latest/userguide/pod-id-agent-setup.html>
- [N5] AWS Systems Manager, Improve the security of EC2 instances by using VPC endpoints:
  <https://docs.aws.amazon.com/systems-manager/latest/userguide/setup-create-vpc.html>
- [N6] Amazon Managed Service for Prometheus, interface VPC endpoints:
  <https://docs.aws.amazon.com/prometheus/latest/userguide/AMP-and-interface-VPC.html>
- [N7] AWS X-Ray, VPC endpoints: <https://docs.aws.amazon.com/xray/latest/devguide/xray-security-vpc-endpoint.html>
- [N8] CloudWatch Logs, interface VPC endpoints: <https://docs.aws.amazon.com/AmazonCloudWatch/latest/logs/cloudwatch-logs-and-interface-VPC.html>
- [N9] Amazon ECR, interface VPC endpoints: <https://docs.aws.amazon.com/AmazonECR/latest/userguide/vpc-endpoints.html>
- [N10] Secrets Manager, VPC endpoint: <https://docs.aws.amazon.com/secretsmanager/latest/userguide/vpc-endpoint-overview.html>
- [N11] AWS KMS, VPC endpoint: <https://docs.aws.amazon.com/kms/latest/developerguide/kms-vpc-endpoint.html>
- [N12] AWS PrivateLink, Control access to VPC endpoints using endpoint policies:
  <https://docs.aws.amazon.com/vpc/latest/privatelink/vpc-endpoints-access.html>
- [N13] CloudWatch, OTLP endpoints: <https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/CloudWatch-OTLPEndpoint.html>
- [N14] AWS Price List API, `AmazonVPC` `ap-southeast-1` (phát hành 2026-11-05):
  <https://pricing.us-east-1.amazonaws.com/offers/v1.0/aws/AmazonVPC/current/ap-southeast-1/index.json>; trang giá: <https://aws.amazon.com/privatelink/pricing/>
- [N15] Security Hub CSPM, FSBP: <https://docs.aws.amazon.com/securityhub/latest/userguide/fsbp-standard.html>; control EC2:
  <https://docs.aws.amazon.com/securityhub/latest/userguide/ec2-controls.html>
- [N16] AWS Well-Architected, Security Pillar, network protection (SEC05):
  <https://docs.aws.amazon.com/wellarchitected/latest/security-pillar/network-protection.html>
- [N17] Terraform AWS provider, data source `aws_vpc_endpoint_service` (`vpc_endpoint_policy_supported`):
  <https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/vpc_endpoint_service>
- [N18] Karpenter, settings (`isolatedVPC`): <https://karpenter.sh/docs/reference/settings/>
