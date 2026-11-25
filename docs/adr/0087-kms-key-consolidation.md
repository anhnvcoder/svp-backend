# 0087. CMK chỉ ở chỗ cần khả năng mà key của AWS không có: ECR, AMP, log group ứng dụng, EBS dùng key của AWS

- Trạng thái: Chấp nhận
- Ngày: 2026-11-25
- Người quyết: người học (2026-11-25, sau đo Cost Explorer: giữ CMK có lý do, mỗi ranh giới một key), AI đề xuất bảng key và thứ tự áp

## Bối cảnh và vấn đề

- Mỗi root sống lâu tạo CMK riêng cho dữ liệu của mình: 18 CMK sống giữa các buổi (inventory của `svp-infra`), $1 mỗi key-tháng,
  cộng $1 cho mỗi lần xoay thứ nhất, thứ hai [N1]. Cost Explorer 1–23/11 của cả tổ chức: KMS khoảng hai phần ba phí giữ, khoản lớn
  nhất; người học trả từ túi riêng.
- Buổi stg 2026-11-24: workspace AMP mã hoá bằng CMK nên mọi role ghi, đọc, quản luật cần quyền KMS qua `aps`; thiếu là `403` khi
  remote write, query và ở controller ACK (svp-infra #72, #73). CMK đó không giữ ai trong account khỏi dữ liệu: role nào được `aps:*`
  cũng được cấp quyền KMS theo.
- Hướng dẫn của AWS: CMK khi cần kiểm soát key policy, vòng đời hay chia sẻ; key AWS sở hữu khi ưu tiên tiện [N2], [N3].

## Yếu tố quyết định

- Mỗi CMK giữ lại phải trả lời được: key AWS quản lý, sở hữu thiếu khả năng gì ở đây.
- Mỗi ranh giới bảo mật một key: không gộp hai dữ liệu khác người được giải mã hay vòng đời vào một key.
- Không đổi thứ có Object Lock hay retention bắt buộc khi không chứng minh được an toàn.
- Đường đổi chạy được giữa hai buổi, không mất dữ liệu người dùng; lịch xoá key cũ chỉ khi không còn gì dùng nó.

## Phương án đã cân nhắc

- **Giữ CMK theo khả năng, chuyển phần còn lại sang key của AWS** (đề xuất): bớt 6 key sống lâu; ECR, AMP đổi key là tài nguyên mới.
- Giữ nguyên 18 key: không việc gì, $18 mỗi tháng và hơn sau lần xoay đầu; lỗi KMS kiểu AMP còn lặp.
- Gộp về một CMK mỗi account: bớt nhiều key hơn, nhưng account `svp-backup` (được giải mã vault để copy) giải mã được cả state, log, image;
  blast radius và vòng đời chung, trái least privilege.
- Bỏ mọi CMK: hỏng copy snapshot RDS chéo account, secret SCRAM của MSK, topic SNS mà CloudWatch, EventBridge publish, DNSSEC.

## Kết quả quyết định

Chọn phương án đầu, vì giữ đúng các khả năng svp dùng và bỏ key chỉ tốn tiền, với cái giá là mất lịch sử metric một lần và hai lượt chép
lại image.

### 1. Luật

CMK chỉ khi cần một trong các khả năng: key policy riêng cho principal hay điều kiện khác IAM của account; dùng chéo account; principal
dịch vụ (CloudWatch, EventBridge) publish vào SNS mã hoá; dịch vụ bắt buộc CMK (secret SCRAM của MSK, KSK DNSSEC); xoá, xoay do mình kiểm
soát cho state và backup. Một CMK không phục vụ hai ranh giới: state và vault backup của mỗi env giữ key riêng, vì key vault cho
`svp-backup` `kms:Decrypt`, `GenerateDataKey`, `CreateGrant` để copy.

### 2. Bảng key

| Key (alias) | Root | Mã hoá gì | Đích | Vì sao |
| --- | --- | --- | --- | --- |
| `svp-tfstate` (management, stg, prd) | `aws/bootstrap`, `aws/accounts/<env>` | Bucket state | Giữ | Key policy riêng cho người đọc state (role plan CI chỉ qua S3) |
| `svp-cloudtrail` | `aws/org` | Trail cũ, bucket Object Lock | Giữ | Object khoá cần key tới hết retention |
| `svp-log-archive` (hai region) | `aws/log-archive` | Bucket log của tổ chức | Giữ | Key policy cho dịch vụ của mọi account |
| `svp-security-alarms` | `aws/security` | SNS cảnh báo bảo mật | Giữ | EventBridge publish cần key policy |
| `svp-backup-copy` | `aws/backup` | Vault copy | Giữ | Bản copy chéo account mã hoá bằng key của account đích |
| `svp-<env>-backup` (stg, prd) | `aws/accounts/<env>` | Vault env | Giữ | Key policy cho `svp-backup` copy; vault không đổi key |
| `svp-dnssec`, `svp-prd-dns-alarms` | `aws/accounts/prd` | KSK, SNS alarm DNSSEC | Giữ | Route 53 bắt buộc CMK; CloudWatch publish |
| `svp-<env>-ecr` (stg, prd) | `aws/accounts/<env>` | Repo ECR | `AES256` | §3 |
| `svp-<env>-observability` (stg, prd) | `aws/accounts/<env>` | Workspace AMP, log group | Key AWS sở hữu | §4 |
| `svp-ebs` (stg, prd) | `aws/baseline` | Key mặc định EBS | `aws/ebs` | §5 |
| `svp-<env>-rds`, `-msk-scram`, `-alarms`, `-uploads`, `-eks-secrets` | `aws/envs/<env>` | Theo buổi | Giữ | §6 |

### 3. ECR

Repo phát hành và template repo cache mã hoá `AES256` (SSE-S3 của ECR) [N4]. Mọi bên đẩy, kéo, quét ở trong account; bản gốc có chữ ký
ở GHCR, nên CMK không vạch ranh giới nào. Role `svp-<env>-ecr-template` giữ, chỉ còn `ecr:CreateRepository`, `ecr:TagResource`; role
node bỏ `kms:Decrypt` qua ECR. Mã hoá của repo không đổi được [N4]: repo cũ bị xoá hẳn (`delete-repository --force`), Terraform tạo lại,
CI chép lại bản phát hành.

### 4. AMP và log group ứng dụng

Workspace `svp-<env>` dùng key AWS sở hữu, mặc định của AMP; workspace tạo với CMK không đổi được về sau [N5], nên Terraform thay
workspace (mất lịch sử metric; root env tìm workspace theo alias, nên áp giữa hai buổi). Log group `/svp/<env>/otel` bỏ `kms_key_id`:
log mới dùng key của CloudWatch Logs, log ghi trước còn mã hoá bằng key cũ và cần key đó tới hết retention [N6]. Mọi statement KMS qua
`aps`, `logs` của role Pod Identity (Collector, Prometheus agent, ACK, Argo Rollouts, OpenCost) và statement `aps` của key policy, role
AMG bị gỡ; key policy giữ phần cho CloudWatch Logs và role AMG giữ `kms:Decrypt` qua `logs`, cho log cũ.

### 5. EBS

stg, prd dùng `aws/ebs` như các account khác: volume của node, Karpenter, bastion sống trong một buổi, không chia sẻ chéo account, không
backup EBS. Destroy `aws_ebs_default_kms_key` gọi `ResetEbsDefaultKmsKeyId`, SCP `svp-protect-baseline` cho phép vì root đi qua
`OrganizationAccountAccessRole`.

### 6. Key theo buổi

Key của root env vào `PendingDeletion` khi destroy, không tính phí lúc chờ [N1]; cùng luật vẫn giữ: RDS (Backup policy copy snapshot sang
`svp-backup`, snapshot `aws/rds` không copy chéo account được [N3]), MSK (secret SCRAM bắt buộc CMK), alarm (CloudWatch publish), `uploads`
(đọc bản gốc cần `kms:Decrypt` riêng ngoài `s3:GetObject`), Secret của EKS (envelope encryption tự kiểm soát,
[0055](0055-environment-matrix.md) §2).

### 7. Thứ tự áp và gỡ key cũ

PR này không xoá key nào: block `aws_kms_key`, alias và `prevent_destroy` của sáu key cũ giữ, chỉ hết consumer; gỡ block là apply gọi
`ScheduleKeyDeletion`. Runbook `kms-consolidation.md` của `svp-infra`: ghi hiện trạng, xoá repo ECR mã hoá KMS, apply
`aws/accounts/<env>` (workspace mới, log group, repo `AES256`), apply `aws/baseline`, chép lại image qua CI, rồi lệnh kiểm không còn repo,
volume, snapshot, grant nào dùng key và không lời gọi CloudTrail nào sau retention của log group. PR sau mới gỡ sáu block; key cũ chờ xoá 30
ngày, `CancelKeyDeletion` là đường cứu.

### 8. Chi phí

Bớt 6 key-tháng: $6 mỗi tháng, $12 sau năm đầu (hai lần xoay mỗi key) [N1]; từ PR gỡ block. Phí giữ KMS về 12 key. Thêm một lần: chép
lại tám bản phát hành vào ECR stg (lưu trữ như trước), workspace AMP mới (không phí tạo). Request KMS của dịch vụ dùng key AWS sở hữu
không tính [N2].

### 9. ADR cũ

Chỉnh (dòng `### Chỉnh bởi`): 0059 §9, §11; 0062 §2, §6, §11; 0063 §1, §2, §11, §12; 0060 §2, §12 (EBS `aws/ebs`); 0055 §2;
0057 §5, 0058 §1 (giữ CMK, lý do theo luật §1). 0048, 0053 chỉ nêu key giữ nguyên, không chỉnh.

### Hệ quả

- Tốt: bớt 6 CMK; role của cluster không còn quyền KMS nào, lỗi `403` KMS của AMP không thể lặp; mỗi CMK còn lại có lý do ghi được.
- Xấu: mất lịch sử metric AMP một lần; repo ECR tạo lại, image chép lại; CloudTrail không ghi việc dùng key của AMP, log group, ECR (key AWS
  sở hữu không cho xem) [N2]; snapshot EBS không chia sẻ chéo account được.
- Xem lại khi: cần chia sẻ image, snapshot EBS hay log chéo account; một tiêu chuẩn tuân thủ đòi CMK (Security Hub ECR.5 là control ngoài
  FSBP); cần thu hồi quyền đọc metric, log bằng key.

## Xác nhận

- Kiểm tĩnh: `make test` của `svp-infra` (`aws/modules/registry`: `AES256`, role template không quyền KMS; `aws/modules/observability`:
  workspace, log group không CMK, key policy ba statement; `aws/modules/eks`: không policy workload, node nào có hành động `kms:`),
  `make inventory-check`.
- Chưa kiểm trên account: runbook `kms-consolidation.md` (người học chạy giữa hai buổi), rồi PR gỡ sáu block.

## Hiện thực ở

- `svp-infra`: `aws/modules/registry/` (§3), `aws/modules/observability/` (§4), `aws/modules/eks/iam.tf`, `nodes.tf` (§3, §4),
  `aws/envs/<env>/main.tf`, `baseline.tf`, `aws/baseline/main.tf`, `ebs-key.tf` (§5), `docs/runbooks/kms-consolidation.md` (§7),
  `docs/handbook/06-baseline.md`, `08-accounts.md`, `15-cost.md`.

## Nguồn

Đọc 2026-11-25.

- [N1] AWS KMS pricing: <https://aws.amazon.com/kms/pricing/>
- [N2] AWS Prescriptive Guidance, key management best practices for AWS KMS:
  <https://docs.aws.amazon.com/prescriptive-guidance/latest/aws-kms-best-practices/key-management.html>
- [N3] AWS KMS keys: <https://docs.aws.amazon.com/kms/latest/developerguide/concepts.html>
- [N4] Amazon ECR, EncryptionConfiguration:
  <https://docs.aws.amazon.com/AWSCloudFormation/latest/TemplateReference/aws-properties-ecr-repository-encryptionconfiguration.html>
- [N5] Amazon Managed Service for Prometheus, encryption at rest:
  <https://docs.aws.amazon.com/prometheus/latest/userguide/encryption-at-rest-Amazon-Service-Prometheus.html>
- [N6] CloudWatch Logs, `disassociate-kms-key`: <https://docs.aws.amazon.com/cli/latest/reference/logs/disassociate-kms-key.html>

## Thông tin thêm

Bảng hiện trạng đủ theo root, account và số key mỗi root: inventory của `svp-infra` (`docs/reference/inventory.md`), dòng `aws_kms_key`.
