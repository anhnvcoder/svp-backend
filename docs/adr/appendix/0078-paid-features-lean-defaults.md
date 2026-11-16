# Phụ lục ADR-0078: Mọi cờ chi phí của ADR-0071 mặc định giá trị rẻ nhất hợp lệ ở mọi account; prd chạy một buổi, đổi về giá trị production trước buổi đó; phần chuẩn ngành giữ trong code nhưng buổi cloud mặc định chỉ chạy phép kiểm lõi; `managed_grafana` thêm giá trị `off`

Phụ lục của [ADR-0078](../0078-paid-features-lean-defaults.md): bảng xét lại §8, §9 của ADR-0071 và bảng chi phí. Đường
dẫn `aws/...` là của `svp-infra`. Số tiền là USD, lấy nguyên từ phụ lục chi phí của ADR đã có (cột nguồn ghi dòng); phép
tính duy nhất là cộng, trừ, nhân, chia theo giả định của chính bảng nguồn, ghi ở ô. "chưa có số" là khoản mà phụ lục
nguồn không tách riêng.

## Xét lại

Mỗi dòng của hai bảng "Cờ không bao giờ tắt" và "Không cờ" ở [kho mục](0071-paid-features.md#kho-mục) của phụ lục 0071,
thêm chính `managed_grafana`. Điều (a), (b), (c) là của ADR §4. "Giữ" là giữ như 0071.

| Mục | Chi phí | Nguồn | Xét (a), (b), (c) | Kết luận |
| --- | --- | --- | --- | --- |
| CloudTrail org trail, data event prd | ~0 tháng không buổi (bản đầu miễn phí); data event prd ~0 mỗi buổi (~10 000 × 0,000001) | [0060](../0060-org-detection-logging.md) phụ lục §12 "Ước lúc không buổi", "Thêm mỗi buổi" | (a) không đạt; (b) an toàn cơ bản: ghi mọi lệnh, là đường thay thế khi Config, Security Hub tắt | Giữ |
| GuardDuty, protection plan | Plan (Runtime, log audit EKS, RDS) ~0,5 mỗi buổi; phân tích CloudTrail ~2,4 tháng năm account | 0060 phụ lục §12 "Thêm mỗi buổi", "Ước lúc không buổi" | Plan: (a) không đạt; detector: (b) an toàn cơ bản (phát hiện lạm dụng credential lúc không ai trực) | Giữ |
| IAM Access Analyzer truy cập ngoài | 0 | 0060 phụ lục §12 "Ước lúc không buổi" | (a) không đạt | Giữ |
| SCP, RCP, tag policy, backup policy | 0 | [0048](../0048-prd-aws.md) phụ lục "Chi phí" bảng R dòng "Organizations, SCP" | (a) không đạt; (b) guardrail của mọi account | Giữ |
| Budget, Cost Anomaly Detection | 0 | 0048 phụ lục bảng R dòng Budget; 0060 phụ lục §12 | (a) không đạt; (b) báo tiền khi env quên gỡ | Giữ |
| Baseline account | Một CMK EBS mỗi env, 1 mỗi key | 0060 phụ lục §12 dòng KMS | (a) không đạt; (b) key đang dùng (mã hoá EBS mặc định) | Giữ |
| Đường sự kiện bảo mật tới email | ~0 | 0060 phụ lục §12 dòng EventBridge, SNS | (a) không đạt; (b) an toàn cơ bản | Giữ |
| Mọi KMS CMK | 1 mỗi key | 0048 phụ lục bảng R; 0060, 0062, 0063, [0067](../0067-backup-dr.md) phụ lục | (b) key đang dùng: xoá key là mất dữ liệu mã hoá bằng nó | Giữ |
| Bucket Log Archive | ~1,1 cả org | 0060 phụ lục §12 dòng S3 Log Archive | (a) không đạt | Giữ |
| AWS Backup | Bản copy stg 0,07, prd 1,25; ba CMK 3,00 mỗi tháng; ~0,15 stg, ~0,34 prd mỗi buổi | 0067 phụ lục "Chi phí" "Sống giữa buổi", "Mỗi buổi" | Bản copy, buổi: (a) không đạt; CMK: key đang dùng (bản copy mã hoá bằng nó) | Giữ |
| VPC flow log | 0 tháng không buổi (gỡ cùng buổi); 0,2–0,4 mỗi buổi | 0060 phụ lục §12 "Thêm mỗi buổi" | (a) không đạt | Giữ |
| Log WAF | ~0 | 0060 phụ lục §12 "Thêm mỗi buổi" | (a) không đạt | Giữ |
| AMP, CloudWatch Logs, X-Ray | Lưu trữ < 0,3 hai account; AMP 2,52 (0,72 khi một env) buổi đầu tháng, 4,32 buổi sau; log 0,35; span 0,35 | [0063](../0063-managed-observability.md) phụ lục §12 | (b) đường cảnh báo là chức năng lõi | Giữ |
| Grafana trong cluster thay AMG | — | 0063 phụ lục §4 "Data source" | Thay bằng `off` không chạy Grafana nào (ADR §5) | Bỏ dòng |
| Endpoint interface | 0 tháng không buổi; stg 0,75, prd 2,3 mỗi buổi | [0064](../0064-interface-endpoints.md) phụ lục §7 "Thêm mỗi buổi" | (a) prd đạt, stg không; (c) không đạt: bỏ thì NetworkPolicy tới API AWS và đường NAT đổi; prd chỉ chạy buổi capstone | Giữ |
| WAF Bot Control, ATP | ~0,11 mỗi buổi (phí cố định); 0 tháng không buổi | [0061](../0061-edge-cloudfront-waf-acm.md) phụ lục §13 "Bảng giá", "Thêm mỗi buổi" | (a) không đạt | Giữ |
| Secret, repo cache ECR | Mỗi env: secret 0,8 (1,6 ÷ 2), cache ~0,5 (~1 ÷ 2) mỗi tháng | [0062](../0062-ecr-registry-ci-oidc.md) phụ lục §11 "Lúc không buổi (hai account)" | (b) node kéo image bên thứ ba qua cache: chức năng lõi | Giữ |
| Lưu trữ bản phát hành ECR | stg ~0,7 tháng 1, ~3,6 tháng 3, ~8 tháng 6 | 0062 phụ lục §11 "Lưu trữ tăng theo bản phát hành" | (b) image để chạy; (c) không có đường thay bằng cờ: GC theo "Xem lại khi" của 0062 | Giữ |
| NAT, Multi-AZ, cỡ, gói CloudFront, số AZ endpoint, retention | 0 tháng không buổi; NAT 0,059 mỗi giờ mỗi NAT | 0048 phụ lục "Chi phí" bảng H₀ | Đã là dữ liệu theo env trong `<env>.tfvars` | Giữ |
| `managed_grafana` (AMG) | `session`: 18 mỗi buổi stg; `always`: 9 mỗi tháng không buổi | [phụ lục 0071](0071-paid-features.md#theo-cờ-stg) "Theo cờ (stg)"; 0063 phụ lục §12 | (a) đạt; (b) alert đi AMP → SNS, phép kiểm lõi không cần dashboard; (c) `off` của ADR §5 | Thêm `off` |

## Chi phí

Dùng thử tháng đầu (GuardDuty, Security Hub) không trừ, như ADR-0071 §11.

### Tháng không buổi

| Dòng | Tháng 1 | Tháng 6 | Nguồn |
| --- | --- | --- | --- |
| Cả org với giá trị stg của ADR-0071 | ~48,5 | ~56,8 | Phụ lục 0071 "Cả org", dòng Tổng |
| Security Hub, Config của management, `svp-log-archive`, prd: 3 × (~1,8 + ~0,3) | −6,3 | −6,3 | 0060 phụ lục §12 "Ước lúc không buổi" (~1 800 check × 0,001, ~100 item × 0,003 mỗi account) |
| Security Hub, Config của `svp-backup`: ~1 800 × 0,001 + ~100 × 0,003 | −2,1 | −2,1 | 0067 phụ lục "Sống giữa buổi", dòng baseline `svp-backup` (~2,2 trừ GuardDuty ~0,05) |
| AMG prd: 18 ÷ 2 | −9 | −9 | 0063 phụ lục §12 "Phần này, tháng không buổi (hai account)" |
| **Cộng** | **~31,1** | **~39,4** | |
| Bớt thêm tới | ~0,6 | ~0,6 | Dòng "< 0,5" của 0062 phụ lục §11 "Lúc không buổi (hai account)" (Inspector quét lại gộp với request KMS, API Secrets Manager; chưa có số riêng), tính một lần cho hai env; item Config của recovery point 0,09 (0067 phụ lục "Sống giữa buổi") |

Phần còn lại lớn nhất: KMS key, lưu trữ bản phát hành ECR, Security Hub và Config của `svp-security` (~1,8 + ~0,3, 0060
phụ lục §12).

### Buổi prd

Một buổi 4 giờ với giá trị production, là buổi prd duy nhất trong tháng; tháng đó trả thêm các dòng theo tháng của prd.

| Khoản | USD | Nguồn |
| --- | --- | --- |
| Control plane EKS, nhóm node hệ thống (3 `m7g.large`), NAT mỗi AZ, RDS, MSK, ElastiCache, dùng của buổi | ~11,0 | [0053](../0053-msk-elasticache-valkey.md) §16 (C của prd: H₀, O₀ của 0048 phụ lục, H_k, O_k) |
| Node Karpenter on-demand ngoài nhóm hệ thống (NodePool prd, `limits` 32 vCPU) | chưa có số | [0056](../0056-eks-platform-ha.md) §2; H₀ chỉ có 3 node, O₀ chỉ "Node thêm khi đo" |
| KMS key, ~16 CloudWatch alarm của dịch vụ data | chưa có số | [0058](../0058-managed-data-operations.md) "Hệ quả" (chỉ giá tháng: $0,10 mỗi metric của alarm) |
| RDS Multi-AZ `db.m7g.large` thay `db.t4g.medium` của H₀: (0,468 − 0,203) × 4 | ~1,06 | [0057](../0057-postgres17-verify-full.md) "Hệ quả"; 0048 phụ lục bảng H₀ |
| Observability, registry, endpoint ba AZ (AMP, log, span, AMG +9 của tháng có buổi, Inspector ≤ 9) | ~23,5 | 0063 phụ lục §12 "Bảng tổng của run", cột "Mỗi buổi prd", buổi đầu tháng cách buổi trước một tháng |
| AMG prd mức tối thiểu của tháng (không còn ở tháng không buổi): 18 ÷ 2 | 9 | 0063 phụ lục §12 "Phần này, tháng không buổi (hai account)" |
| Security Hub, Config của prd cho tháng: ~1,8 + ~0,3 | ~2,1 | 0060 phụ lục §12 "Ước lúc không buổi" (mỗi account) |
| Lượt check đầu khi Security Hub bật lại | chưa có số | Phụ lục 0071 "Đổi cờ", `security_hub` về `always` |
| Config, Security Hub, GuardDuty, flow log theo thay đổi của buổi | ~4–8 | 0060 phụ lục §12 "Thêm mỗi buổi" (có thể trùng ~0,2 item Config, check của ba dòng dưới) |
| Edge: WAF, ALB, log | ~0,55 | 0061 phụ lục §13 "Thêm mỗi buổi" |
| MediaConvert, SQS, S3 | ~0,84 | [0066](../0066-mediaconvert-transcode.md) phụ lục "Chi phí" "Mỗi buổi" |
| Backup, PITR | ~0,34 | 0067 phụ lục "Chi phí" "Mỗi buổi" |
| Chi phí theo namespace, uptime | ~0,09–0,18 | [0074](../0074-cost-uptime.md) phụ lục "Mỗi buổi 4 giờ (mỗi env)" |
| Secret ký media | ~0,002 | [0073](../0073-premium-playback.md) §10 |
| Argo CD capability | 0 (chưa hiện thực; ~0,34 khi hiện thực) | [0065](../0065-argocd-eks-capability.md) phụ lục §8 |
| Service mesh | chưa có số | [0075](../0075-service-mesh.md) không tách |
| **Cộng** | **~52,5–56,6** cộng phần chưa có số | |

Khoản lớn nhất đã có số là observability, registry (AMG hai user của tháng có buổi, Inspector quét lại digest bên
thứ ba). Đổi cờ prd về giá trị của ADR §1 sau buổi không tốn thêm: cờ chỉ gỡ tài nguyên
([phụ lục 0071](0071-paid-features.md#đổi-cờ) "Đổi cờ").

### Buổi stg

Không đổi khi ADR chấp nhận. Khi ADR §5 hiện thực, mỗi buổi bớt AMG 18 (phụ lục 0071 "Theo cờ (stg)", `session`).
