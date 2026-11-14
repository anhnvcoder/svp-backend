# 0034. Biến thể AWS chạy trên EKS ở Singapore; hạ tầng là Terraform trong repo riêng `svp-infra` (module `terraform-aws-modules` bọc mỏng, mỗi env một cấu hình gốc, stg cắt chi phí và prd chuẩn production chỉ khác ở biến); RDS PostgreSQL và S3 + CloudFront là dịch vụ managed, Redpanda, Valkey và observability chạy trong cluster; khác biệt k3d/EKS là lớp `platforms/` của `svp-gitops` cùng giá trị theo cluster do bootstrap đặt; NLB L4 giữ IP client trước Envoy, TLS Let's Encrypt DNS-01, `X-Forwarded-For` giữ 1 hop

- Trạng thái: Chấp nhận
- Ngày: 2026-10-31
- Người quyết: người học (trả lời ngày 2026-10-31 các dòng 2, 4, 5, 8 và 20; các dòng còn lại theo đề xuất, người học duyệt kế hoạch cùng ngày)

## Bối cảnh và vấn đề

- **Yêu cầu** (lộ trình, mục "7. AWS"): dựng cả hệ thống trên EKS, đạt SLO dưới tải k6, có báo cáo chi phí, destroy và quét sạch; so **ECS Fargate và EKS** (và App
  Runner), nói rõ lúc nào ECS Fargate đúng hơn và giá của EKS; chọn nơi đặt Terraform, số account, observability, registry, Kafka và Redis managed hay trong cluster.
- **Ba lớp** (người học chia): **7a** (ADR này: một cluster stg, smoke và k6, destroy sạch), **7b** (cluster prd, promote thật, Secrets Manager qua Pod Identity,
  [0032](0032-argocd-deploy-status.md) A và B, migration không downtime trên RDS), **7c** (mục tuỳ chọn: MediaConvert, nâng minor EKS, Istio ambient…; đủ: phụ lục).
- **Ràng buộc:** ba repo public (không account ID, IP cá nhân, email, tên miền thật; ví dụ `svp.example`, `000…`); AI không chạy lệnh chạm account; buổi tối đa 4 giờ.
  Đã chốt (2026-10-18): một instance Postgres, mỗi service database và role riêng; file gốc 30 ngày rồi Glacier Deep Archive, xoá sau 365 ngày; hop RL-1 chốt ở đây.

## Yếu tố quyết định

- Chart, policy, GitOps, bản ghi stg, promote prd đã kiểm trên Kubernetes chạy nguyên trên cloud; khác biệt nền tảng là dữ liệu, không vào git.
- Mỗi buổi rẻ (trần $5), dựng và destroy trong buổi, không tài nguyên sót; prd chuẩn production từ cùng code với stg; công cụ hiện hành, giá có nguồn.

## Phương án đã cân nhắc

`Câu N` là số câu hỏi người học trả lời; in đậm là lựa chọn. Bảng được/mất và so giá từng câu: phụ lục, mục "Các lựa chọn".

- Câu 1 nền tảng: **EKS**: mọi thứ đã kiểm trên Kubernetes chạy nguyên.
- Câu 1 ECS Fargate: không phí control plane; viết lại canary, GitOps, admission bằng dịch vụ AWS, dữ liệu thành managed.
- Câu 1 App Runner: không nhận khách mới từ 2026-04-30 [N16].
- Câu 2 Terraform: **A. repo riêng `svp-infra`, public**.
- Câu 2 B. `deploy/terraform/` trong repo code: ai merge code đổi được hạ tầng.
- Câu 2 C. repo riêng private: ruleset cần gói trả phí.
- Câu 3 account: **A. một account sandbox, mỗi env một state key và quyền riêng**.
- Câu 3 B. Organizations, account prd riêng ngay 7a: SSO, SCP trước khi có prd.
- Câu 4 region: **A. `ap-southeast-1`**: gần người dùng giả định; đắt hơn `us-east-1` ~14 % mỗi giờ với Spot, ~21 % on-demand.
- Câu 4 B. `us-east-1`.
- Câu 5 tên miền: **A. domain đã có, uỷ quyền subdomain `aws.<miền>` sang Route 53 bằng bốn bản ghi `NS`**.
- Câu 5 B. mua domain mới.
- Câu 5 C. không domain: không chứng chỉ công khai.
- Câu 6 load balancer, TLS: **A. NLB L4 giữ IP client + Envoy kết thúc TLS Let's Encrypt DNS-01**.
- Câu 6 B. ALB L7 + ACM: `X-Forwarded-For` thành 2 hop.
- Câu 6 C. NLB listener TLS + ACM: mất IP client nếu không Proxy Protocol v2.
- Câu 7 node: **A. managed node group Graviton Spot ở 7a, Karpenter ở 7b**.
- Câu 7 B. EKS Auto Mode: phí quản lý 12 % giá EC2, giấu controller.
- Câu 7 C. Cluster Autoscaler.
- Câu 8 module: **A. `terraform-aws-modules/vpc`, `/eks` ghim version, bọc mỏng; RDS, S3, CloudFront tự viết; bản tự viết hoàn toàn là lab 7c**.
- Câu 8 B. tự viết mọi resource ở đường chính.
- Câu 9 observability: **A. stack trong cluster như k3d**.
- Câu 9 B. Amazon Managed Prometheus + Managed Grafana + X-Ray: so ở 7c.
- Câu 9 C. Grafana Cloud gói miễn phí: so ở 7c.
- Câu 10 registry: **A. giữ GHCR, kéo ẩn danh theo digest**.
- Câu 10 B. ECR + OIDC từ CI: đổi prefix mọi nguồn; 7c.
- Câu 11 Kafka, Redis: **A. Redpanda, Valkey trong cluster**.
- Câu 11 B. MSK, ElastiCache: xét ở 7b khi prd cần độ bền.
- Câu 12 khác biệt k3d/EKS: **A. lớp `platforms/{k3d,eks}/` giữa `base/` và `envs/`, giá trị theo cluster do bootstrap đặt (kiểu GitOps Bridge [N38])**.
- Câu 12 B. env mới `stg-aws`.
- Câu 12 C. ghi giá trị account vào repo public.
- Câu 13 secret của EKS stg: **A. ESO provider `kubernetes`, nguồn nạp bằng `make eks-secrets`**.
- Câu 13 B. Secrets Manager + Pod Identity ngay 7a.
- Câu 14 cài Argo CD: **A. dùng lại `deploy/k8s/gitops.sh` qua `make eks-gitops-up`**.
- Câu 14 B. provider Helm/Kubernetes của Terraform: cùng `apply` với cluster [N27].
- Câu 15 kiểm IaC: **A. `terraform fmt`/`validate`, tflint ruleset AWS, trivy config bằng image ghim**.
- Câu 15 B. thêm checkov.
- Câu 15 C. thêm Infracost: 7c.
- Câu 16 credential S3: **A. EKS Pod Identity (`S3_CREDENTIALS=container`)**.
- Câu 16 B. IRSA: cần OIDC provider.
- Câu 16 C. access key IAM user: khoá dài hạn.
- Câu 17 PostgreSQL trên RDS: **A. 15 như local**: hết standard support 2028-02-29 [N37].
- Câu 17 B. 17 hay 18.
- Câu 18 tên CloudFront: **A. `*.cloudfront.net`**.
- Câu 18 B. tên riêng + chứng chỉ ACM ở `us-east-1`: 7c.
- Câu 19 CloudFront tính tiền: **A. pay-as-you-go**.
- Câu 19 B. flat-rate plan: bắt buộc web ACL WAF; dùng với `*.cloudfront.net` chưa kiểm [N10].
- Câu 20 mức chuẩn theo env: **A. một bộ module, stg cắt chi phí, prd chuẩn production, khác ở biến**.
- Câu 20 B. hai bộ code.
- Câu 20 C. stg cùng mức prd: ~2 lần chi phí.

## Kết quả quyết định

Chọn 1 EKS; 2A–20A (A ở mọi câu từ 2 tới 20), lý do ở từng § dưới đây; toàn văn từng § và mọi bảng: phụ lục. Phần Bối cảnh và dòng chi tiết rút khỏi các § ở [mục "Chi tiết rút khỏi ADR"](appendix/0034-aws-stage7.md#chi-tiết-rút-khỏi-adr).

### 1. Nền tảng: EKS 1.36

- **Giá của EKS:** $0,10/giờ mỗi cluster (2 cluster liên tục ≈ $146/tháng), $0,60/giờ ở extended support [N2]; nâng minor ít nhất mỗi ~14 tháng [N18]; ~10
  controller giữ version và quyền. **Minor 1.36:** cùng k3s v1.36.5, khớp `podSecurityVersion: v1.36`, support tới 2027-08-02 [N18]; 1.37 là bài `eks-minor-upgrade` của 7c; `CLOUD_K8S_VERSION` của `deploy/k8s/k8s.mk` theo 1.36.

### 2. Repo `svp-infra` và bố cục

- Repo `anhnvcoder/svp-infra` (public), clone ở `<workspace>/infra`, cài đặt theo [runbook `svp-infra-setup.md`](../runbooks/svp-infra-setup.md). Bố cục:
  `aws/bootstrap/` (một lần mỗi account: bucket state, budget, hosted zone), `aws/modules/{network,eks,rds,media}`, `aws/envs/<env>/` (key
  `aws/<env>/terraform.tfstate`, output `cluster_values`), `aws/scripts/`, `gcp/`, `cloudflare/`, `github/`; `make check` (fmt-check, validate với
  `init -backend=false`, tflint, trivy, shellcheck), `make lock` (cây: phụ lục). Tầng app **không** ở Terraform mà là GitOps (cổng riêng: promote, Kyverno).
- **CI** chỉ kiểm tĩnh, không credential AWS (OIDC ở 7c); `plan`, `apply`, `destroy` do người học chạy bằng SSO; thay đổi chéo theo thứ tự code → `svp-gitops` →
  `svp-infra`. **Chỉnh 0024 §9:** Terraform ở `aws/envs/<env>/`, `aws/modules/` của `svp-infra`; `envs/{aws,gcp,cf}` thành `aws/`, `gcp/`, `cloudflare/`.

### 3. Account và quyền

Một account sandbox, profile SSO; trước mọi lệnh ghi `aws sts get-caller-identity`, script so account với biến môi trường. Mỗi env một backend và cấu hình gốc
(7b xét account prd riêng: chỉ đổi backend, provider). Budget tháng (50/80/100 % thực tế, 100 % dự báo) ở `aws/bootstrap` [N13]; Cost Anomaly Detection bật tay [N14].

### 4. Region

`ap-southeast-1` cho mọi thứ của 7a; overlay prd đổi region store `aws` sang `ap-southeast-1` ở 7b; ACM cho tên riêng của CloudFront vẫn ở `us-east-1`.

### 5. DNS, TLS, load balancer và `X-Forwarded-For`

- **TLS:** cert-manager, Let's Encrypt **production**, DNS-01 qua Route 53 bằng Pod Identity; 5 chứng chỉ cùng bộ tên mỗi 7 ngày (tối đa 5 buổi/tuần) [N30].
- **Load balancer:** LBC tạo NLB `internet-facing` từ Service của Envoy, target `ip`, bật `preserve_client_ip.enabled=true` (mặc định tắt [N31]), listener chỉ TCP
  443; hairpin không chạy khi giữ IP client nên không pod nào gọi tên công khai của chính cluster (Job k6 phân giải về ClusterIP của Envoy).
- **`X-Forwarded-For` (chốt RL-1):** không L7 nào trước Envoy, gateway giữ **1 hop**: compose 0; k3d 1, `TRUSTED_PROXY_CIDRS` `10.42.0.0/16`; EKS 1, CIDR VPC
  (`cluster.vpcCidr`). NetworkPolicy của gateway (chỉ Envoy và web) giữ cho pod khác không tự làm hop tin cậy (RL-7).

### 6. Node

Managed node group Graviton `m7g.large` × 3, **Spot** ở stg, loại thay thế cùng cỡ qua biến [N4] (3 × 8 GiB cho RAM đo trên k3d ~7–9 GiB cộng hệ thống và k6); node thêm cho k6 bậc 4–8 bằng `aws eks update-nodegroup-config` trong buổi. Addon `vpc-cni` (network policy agent, ≥ 1.21.0 [N20]), `coredns`, `kube-proxy`,
`eks-pod-identity-agent`, `aws-ebs-csi-driver`, `metrics-server` (community [N19]). IMDSv2 hop limit 1: controller nhận region, VPC qua `cluster.*`.

### 7. Lớp nền tảng và hợp đồng giá trị theo cluster

- `svp-gitops` thêm giá trị `platform` (`k3d` | `eks`, bắt buộc như `env`) cho root `svp-root`, thư mục `platforms/<platform>/`, trường `platforms` của mỗi
  component trong `components.json`. Values theo thứ tự `base/` < `platforms/<platform>/<tên>.yaml` < `envs/<env>/<tên>.yaml` < `envs/<env>/images/` < mẫu
  `platforms/<platform>/<tên>.values.tpl` (Helm `tpl` trên `.Values.cluster`); `env=stg platform=k3d` render như cũ.
- **Hợp đồng `cluster.*`**: giá trị phụ thuộc account hay buổi, không bao giờ vào git. Bảng khoá (tên, nghĩa, ai dùng): [mục "Chi tiết rút khỏi ADR"](appendix/0034-aws-stage7.md#chi-tiết-rút-khỏi-adr); ai ghi, ai đọc, thêm khoá thì sửa đâu: cũng ở đó.

### 8. Thành phần local → AWS

EKS stg chạy như k3d trừ: control plane managed (API 443), 3 × `m7g.large` Spot ở 2 AZ subnet private, VPC CNI, NLB qua LBC, ACME qua Route 53, StorageClass `gp3`
do `svp-cluster` tạo [N24], RDS thay CloudNativePG, S3 + CloudFront thay RustFS, Pod Identity, NAT gateway. Bảng đầy đủ: phụ lục §8.

### 9. Dữ liệu

- **RDS:** một instance cho mọi service, PostgreSQL 15, `db.t4g.small`, gp3 20 GB, subnet private, chỉ nhận 5432 từ security group của node, `rds.force_ssl = 1`,
  mã hoá, mật khẩu master ở Secrets Manager (`manage_master_user_password`); **master username cố định `postgres`** [N41], `rds_superuser`, không superuser [N36] (phụ lục).
- **S3:** bucket `uploads`, `media` chặn public, `BucketOwnerEnforced`, SSE-S3, CORS, lifecycle; **CloudFront:** OAC, viewer HTTPS, `PriceClass_200` [N10]; chi tiết cấu hình: phụ lục.

### 10. Secret, IAM và Pod Identity

- 7a: ESO `kubernetes`, `make eks-secrets CONTEXT=svp-stg`; mật khẩu master RDS qua biến môi trường vào nguồn `pg-superuser`; chart không render `s3-root`, `s3-users`,
  `pg-backup-s3`. 7b: Secrets Manager `svp/prd/<entry>` (0026). Pod Identity mỗi role một policy hẹp; NetworkPolicy chỉ mở `169.254.170.23/32` TCP 80 [N21].
- Egress tới S3 (FF-5) chỉ TCP 443 tới `s3Cidrs`, không bao giờ `0.0.0.0/0`. **Chấp nhận ở stg:** luật theo địa chỉ không phân biệt bucket. **Trước prd (7b):**
  endpoint policy chỉ bucket `uploads`, `media` của env cộng bucket layer ECR của region, kiểm ở stg rồi mới áp prd.

### 11. Mức chuẩn theo env và bảng biến

prd chuẩn production (NAT mỗi AZ, RDS Multi-AZ, node nhiều AZ, bảo vệ xoá, không Spot cho phần stateful); stg cắt chi phí; một bộ module, khác ở biến (bảng: phụ lục).

### 12. Chi phí 7a (Singapore)

Giá đọc 2026-10-31, tổng mỗi giờ và mỗi buổi so với trần $5: [phụ lục](appendix/0034-aws-stage7.md#chi-tiết-rút-khỏi-adr).

### 13. Tài nguyên có thể nằm ngoài state Terraform và cách quét

NLB (LBC), volume EBS của PVC, bản ghi Route 53, ENI sót, log group, secret và snapshot RDS: `pre-destroy.sh` gỡ chúng khi controller còn chạy rồi mới `terraform
destroy`; `sweep.sh` chỉ đọc, exit 1 khi còn gì ngoài `aws/bootstrap`. Bảng ai tạo, cách gỡ, cách quét: phụ lục.

### 14. Buổi AWS

`docs/runbooks/session-stg.md` của `svp-infra`: account → DNS → `plan` lưu file, `apply` file đó → `make eks-gitops-up` → smoke, k6 → pre-destroy → `destroy` → `sweep.sh`; tối đa 4 giờ.

### Hệ quả

- Tốt: chart, policy, GitOps, promote chạy nguyên trên cloud, k3d stg và EKS stg cùng `envs/stg`; một repo hạ tầng, CI không credential; prd ở 7b chỉ đổi biến.
- Xấu: phí control plane, nâng minor, ~10 controller; repo thứ tư và hợp đồng `cluster.*`; Singapore đắt hơn ~14–21 %; Spot bị thu hồi, NAT tính theo GB; Let's
  Encrypt tối đa 5 buổi/tuần; `NS` ngoài gỡ trước khi xoá zone (AWS-7); endpoint API công khai giới hạn CIDR; NLB không có WAF.
- Xem lại khi: hệ thống ít service, team không vận hành Kubernetes (ECS Fargate); 1.36 còn dưới 2 tháng support; Spot thu hồi quá một lần mỗi buổi; 429 của Docker
  Hub [N29]; prd cần độ bền Kafka, Redis; CloudFront vượt 1 TB/tháng hay cần WAF. Hoàn tất chỗ để ngỏ của [0020](0020-reliability-stage6.md), RL-1, 0026.

## Xác nhận

Lúc quyết chưa hiện thực. Mười tám giả định chỉ chứng minh được trên AWS (VPC CNI NetworkPolicy, API 443, credential Pod Identity với form 15 phút, ghi có điều kiện
S3, PSA `v1.36`, NLB giữ IP, hairpin, metrics-server, IMDSv2, `rds_superuser`, Spot, Docker Hub, chứng chỉ, PVC, chi phí ±50 %, thời gian buổi, bucket không liệt kê ẩn danh, k6 đạt SLO) kiểm ở buổi AWS stg; bảng phép kiểm và cột Kết quả: phụ lục, "Kiểm chứng sau".

## Hiện thực ở

- `svp-infra`: `Makefile`, `.tflint.hcl`, `.github/workflows/check.yml` (§2, §15); `aws/bootstrap/` (§2, §3, §5); `aws/modules/{network,eks,rds,media}/` (§6, §8, §9, §11); `github/` (§2); `aws/envs/stg/` (§7, §10); `aws/scripts/`, `docs/runbooks/session-stg.md` (§13, §14).
- Repo code: `internal/objstore` (§9, §10); chart `svp-data`, `svp-observability`, `svp-cluster`, `svp-service`, `deploy/postgres/bootstrap.sql` (§5, §8, §9); `deploy/ci/gitops-check.sh`, `deploy/ci/cluster-values.example.yaml`, `deploy/k8s/gitops.sh`, target `eks-*` (§7, §14). `svp-gitops`: `platforms/`, `argocd/apps/` (§7).

## Nguồn

Đọc 2026-10-31; danh sách đầy đủ [N1]–[N41] ở phụ lục. [N2] <https://aws.amazon.com/eks/pricing/>, [N7] <https://aws.amazon.com/rds/postgresql/pricing/>, [N9] <https://aws.amazon.com/s3/pricing/>, [N10] <https://aws.amazon.com/cloudfront/pricing/>, [N11] <https://aws.amazon.com/secrets-manager/pricing/>, [N16] <https://aws.amazon.com/apprunner/>, [N18] <https://docs.aws.amazon.com/eks/latest/userguide/kubernetes-versions.html>, [N30] <https://letsencrypt.org/docs/rate-limits/>.

## Thông tin thêm

Phụ lục: [`appendix/0034-aws-stage7.md`](appendix/0034-aws-stage7.md) (trạng thái lúc chốt, bối cảnh, hai mươi bảng lựa chọn, toàn văn mười bốn §, "Kiểm chứng sau").

### Chỉnh bởi

- §2 "Biến cá nhân", §9 "S3": [0038](0038-s3-bucket-names.md): tên bucket.
- §2, §3, §4, §5, §6, §7, §10, §11, §13, §14: [0048](0048-prd-aws.md): AWS Organizations, sandbox chỉ còn là management, stg và prd ở account `svp-stg`, `svp-prd`, mỗi account một profile, state, zone `<env>.aws.<miền>` và budget; root `aws/org`, `aws/accounts/<env>`, `aws/gitops/<env>`; region store từ `cluster.region`, SCP chỉ cho `ap-southeast-1`, `us-east-1`; Karpenter để sau; `cluster.*` qua annotation cluster Secret của GitOps Bridge, thêm khoá `externalSecretsRoles`; Secret EKS của stg và prd từ Secrets Manager, endpoint S3 có policy ở prd; giá trị prd và wiring riêng của root prd; gỡ và quét theo account; trình tự buổi bằng `terraform apply` hai root.
- Câu 19, §9 "CloudFront": [0052](0052-cloudfront-flat-rate-free.md): distribution media của stg và prd trên gói flat-rate Free thay pay-as-you-go, có web ACL WAF ở cả hai env; `PriceClass_All` thay `PriceClass_200`; CORS của media bằng policy managed `Managed-SimpleCORS`.
- Câu 11, §7, §8, §12: [0053](0053-msk-elasticache-valkey.md): Kafka, Redis của stg và prd là Amazon MSK provisioned và ElastiCache for Valkey (cluster mode tắt) thay Redpanda, Valkey trong cluster EKS; client nối SASL SCRAM-SHA-512 trên TLS, Valkey bằng user ACL; hợp đồng `cluster.*` thêm khoá `kafkaBrokers`, `valkeyHost`, `dbCidrs` thêm egress 9096, 6379 tới MSK, ElastiCache cùng subnet; buổi stg thêm ~$0,6 cho MSK, ElastiCache.
- §7, §9 "RDS": [0054](0054-data-subnet-tier.md): VPC ba tầng; RDS, MSK, ElastiCache ở subnet database (route table không `0.0.0.0/0`) thay subnet private của node; `cluster.dbCidrs` là dải của subnet database.
- Câu 7, §6, §8: [0056](0056-eks-platform-ha.md): node workload do Karpenter tự quản cấp (stg Spot, prd on-demand) thay managed node group cố định; managed node group `system` on-demand mỗi AZ một node cho controller nền tảng; add-on và AMI ghim version; Envoy, Kyverno HA và trải zone; log control plane đủ năm loại ở cả hai env.
- Câu 17, §9 "RDS": [0057](0057-postgres17-verify-full.md): PostgreSQL 17 thay 15 ở RDS, CloudNativePG, compose và CI; client nối `verify-full` với bundle CA của RDS trên host RDS; prd lớp `db.m7g.large`; KMS key customer managed, storage autoscaling, tham số ghi log.
- §3: [0059](0059-org-structure-guardrails.md): org theo AWS SRA thêm account `svp-log-archive`, `svp-security` ở OU `Security`; `svp-stg`, `svp-prd` ở OU `Workloads/NonProd`, `Workloads/Prod`; baseline bảo mật mỗi account áp từ management; permission set chỉ đọc cạnh `SvpAdmin`.
- §3: [0060](0060-org-detection-logging.md): Cost Anomaly Detection (monitor theo dịch vụ, email hằng ngày, ngưỡng tác động $10) và tag phân bổ chi phí `Project`, `Env`, `Stack` do `aws/bootstrap` quản, thay bật tay.
- Câu 6, Câu 18, Câu 19, §5, §9 "CloudFront", Hệ quả: [0061](0061-edge-cloudfront-waf-acm.md): CloudFront có WAF trước web, API (VPC origin tới ALB internal ở tầng subnet edge, `TargetGroupBinding` tới Service ClusterIP của Envoy) thay NLB L4; cert ACM thay Let's Encrypt ở stg, prd, Envoy dùng CA nội bộ; gateway trên EKS lấy IP client từ `CloudFront-Viewer-Address` thay `X-Forwarded-For` 1 hop; media có tên riêng `media.<domain>` với cert ACM, media của prd pay-as-you-go; ExternalDNS bỏ.
- Câu 9, §8: [0063](0063-managed-observability.md): telemetry của `eks` vào Amazon Managed Service for Prometheus, CloudWatch Logs, X-Ray; Grafana là Amazon Managed Grafana, luật chạy ở AMP tới SNS; Prometheus, Loki, Tempo, Grafana trong cluster không còn ở `eks` (Pyroscope, GlitchTip ở lại); local giữ LGTM.
- Câu 10, §2: [0062](0062-ecr-registry-ci-oidc.md): image của stg, prd ở ECR private của account env (CI sao chép cùng digest kèm chữ ký, attestation từ GHCR), image bên thứ ba qua pull-through cache; CI của `svp-backend`, `svp-frontend` có role OIDC hẹp theo repo và mục đích; `svp-infra` vẫn không credential AWS.
- §8, §10: [0064](0064-interface-endpoints.md): API AWS của cluster qua endpoint interface có private DNS ở VPC mỗi env, đích ngoài AWS và vài API AWS không có endpoint ở region vẫn qua NAT (0064 §6); NetworkPolicy thêm TCP 443 tới `awsEndpointCidrs`.
- Câu 14, §7: [0065](0065-argocd-eks-capability.md): Argo CD trên `eks` chuyển sang EKS Capability cho Argo CD (AWS chạy, giữ HA; đăng nhập Identity Center; đích Application `name: in-cluster`) thay `deploy/k8s/gitops.sh` cài chart; k3d giữ cài tay; hiện thực ở thay đổi riêng, tới đó giữ cách cài hiện tại.
- Bối cảnh (7c: MediaConvert): [0066](0066-mediaconvert-transcode.md): stg, prd transcode bằng AWS Elemental MediaConvert (tier Basic, queue on-demand) qua lệnh con `media-worker mediaconvert`, trạng thái job qua EventBridge và SQS, endpoint interface `mediaconvert`; chọn mua thay tự chạy ffmpeg trên EKS, đánh đổi và chi phí ở ADR đó.
