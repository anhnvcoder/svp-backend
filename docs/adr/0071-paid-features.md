# 0071. Dịch vụ AWS tốn tiền mà hệ thống không cần để chạy có cờ theo account trong một file commit đọc qua một module chỉ trả dữ liệu; prd và bốn account dùng chung bật hết; stg chỉ dựng Amazon Managed Grafana trong buổi và tắt Inspector ECR, Security Hub CSPM, AWS Config; guardrail lõi không có cờ

- Trạng thái: Chấp nhận
- Ngày: 2026-11-14
- Người quyết: người học (2026-11-14: mỗi env một khối dữ liệu bật, tắt dịch vụ tốn tiền; prd bật hết; stg tắt cái đắt mà không làm hỏng việc
  chạy được), AI đề xuất danh sách cờ, giá trị và thứ tự áp

## Bối cảnh và vấn đề

- Các root sống lâu (`aws/org`, `aws/security`, `aws/baseline`, `aws/backup`, `aws/accounts/<env>` của `svp-infra`) tính tiền cả tháng không buổi:
  cộng các phụ lục chi phí của ADR đã có, khoảng $60 mỗi tháng ở tháng đầu, tăng tới khoảng $68 ở tháng thứ sáu
  ([phụ lục](appendix/0071-paid-features.md#bảng-tháng-không-buổi)). Phần của stg gồm Amazon Managed Grafana (AMG) $9, Security Hub CSPM ~$1,8,
  Config ~$0,3, Inspector quét lại; mỗi buổi stg thêm Config $2–4,5, Security Hub $1–3, Inspector tới ~$9.
- [0055](0055-environment-matrix.md) §2 xếp mọi dịch vụ giám sát và bảo mật vào nhóm phải giống: stg trả cùng các khoản đó dù buổi stg chủ yếu kiểm
  đường chạy, không kiểm posture.
- Khác biệt env là dữ liệu, không `if env` ([0055](0055-environment-matrix.md) §6). Một dịch vụ có thể chạm nhiều root: Inspector ở `aws/security`
  và `aws/accounts/<env>`; Security Hub, Config ở `aws/security` và `aws/baseline`.

## Yếu tố quyết định

- Hệ thống vẫn chạy được ở mọi giá trị cờ: metric, log, trace, alert, mạng, dữ liệu không có cờ.
- Mỗi cờ tắt có đường thay thế bằng code và image đã có, và cái giá ghi ra.
- Guardrail phát hiện lạm dụng và giữ dữ liệu (CloudTrail, GuardDuty, KMS, Backup) không phụ thuộc cờ.
- Một nguồn cho mỗi cờ, đọc được ở mọi root và script chạm nó; `validation` một chỗ.

## Phương án đã cân nhắc

Trạng thái ngành, được, mất, nguồn: [phụ lục](appendix/0071-paid-features.md#phương-án).

- Biến `paid_features` trong `<env>.tfvars` của từng root (hiện hành, biến đầu vào Terraform): mỗi root tự đủ, nhưng một cờ chạm hai root thành
  hai bản chép có thể lệch, và root org (`aws/security`, `aws/baseline`) không có `<env>.tfvars`.
- **Khối cờ: một file JSON commit `aws/paid-features.json` đọc qua module `paid-features` không provider, không resource** (hiện hành, cùng ý
  "data-only module" của HashiCorp [N1]): một nguồn cho mọi root và cho script (`jq`); root đọc file ngoài thư mục của nó.
- Không cờ, stg đúng như prd (hiện hành, dev/prod parity [N21]): stg bắt được lỗi của mọi dịch vụ, trả mọi khoản mỗi tháng.

## Kết quả quyết định

Chọn **Khối cờ**, vì một cờ chạm nhiều root vẫn có một nguồn và một `validation`, và prd giữ chuẩn production chỉ bằng việc không ghi gì.
Kho mục đủ, bảng tháng, địa chỉ resource khi đổi cờ, trích nguồn: [phụ lục](appendix/0071-paid-features.md).

### 1. Khối cờ và module

- `aws/paid-features.json` là object `{"<khoá account>": {"<cờ>": "<giá trị>"}}`, chỉ ghi giá trị khác mặc định; khoá hay cờ vắng là `always`.
  Khoá account: `mgmt`, `log-archive`, `security`, `backup`, `stg`, `prd` (cùng khoá với `local.accounts` của `aws/baseline`).
- Module `aws/modules/paid-features` nhận map đó, `validation` từ chối khoá, cờ, giá trị lạ, cờ của account env đặt ở account khác, tổ hợp sai §7 và
  `security_hub` = `off` ở `security`. Output `flags` đủ sáu khoá, mỗi khoá đủ bốn cờ; `off_accounts`, `session_accounts` theo cờ. Mọi root dùng cờ
  gọi module này; script đọc cùng file qua `paid_feature`, `session_features` của `aws/scripts/lib.sh`.

### 2. Cờ và giá trị stg

| Cờ | Giá trị | Account | stg |
| --- | --- | --- | --- |
| `managed_grafana` | `always`, `session` | stg, prd | `session` |
| `inspector_ecr` | `always`, `off` | stg, prd | `off` |
| `security_hub` | `always`, `off` | mọi account trừ `security` | `off` |
| `config_recording` | `always`, `off` | mọi account | `off` |

prd và bốn account dùng chung để mặc định: prd là chuẩn production, account dùng chung giữ guardrail cho cả org. File commit đúng một khoá `stg`.

### 3. `managed_grafana`

- `session`: workspace `svp-<env>`, role `svp-<env>-grafana`, gán nhóm, service account `svp-grafana-operator` và SSM parameter
  `/svp/<env>/grafana-workspace-id` chỉ có trong buổi: biến `session_open` của root `aws/accounts/<env>` (chỉ `tf.sh <env> account plan --open`,
  `--close` đặt) bật `grafana_enabled` của module `observability`. Workspace AMP, key `alias/svp-<env>-observability`, log group, X-Ray luôn có.
- Root env đọc id workspace từ SSM parameter thay biến `grafana_workspace_id`; `cluster_values` trong buổi đủ mọi khoá như cũ.
- Không có `off` với Grafana trong cluster: Grafana 12+ bỏ SigV4 khỏi data source Prometheus lõi, đọc AMP cần plugin Amazon Managed Service for
  Prometheus [N15]; image ghim không có plugin đó và hardening của `kube-prometheus-stack` cấm tải plugin lúc chạy.
- Tính tiền: mỗi user mỗi workspace mỗi tháng, tối thiểu một Editor mỗi workspace kể cả khi không ai đăng nhập, service account tính như user
  [N14]; trang giá không nói tính theo phần tháng khi workspace xoá giữa tháng, nên ADR lấy cách đọc bất lợi: mỗi workspace có trong tháng tính đủ.
  `always`: $9 tháng không buổi, $18 tháng có buổi. `session`: mỗi buổi một workspace mới, $18 mỗi buổi. Lợi $9 ở tháng không buổi, bằng ở tháng một
  buổi, thiệt $18 mỗi buổi thêm từ buổi thứ hai. Buổi stg thường ≤ 1 mỗi tháng (buổi chung stg, prd); tháng có ≥ 2 buổi thì đặt `always` trước buổi đầu.

### 4. `inspector_ecr`

- `off`: `aws/security` không đưa account vào `aws_inspector2_enabler.members` và member association; module `registry` dùng quét cơ bản
  (`scan_type = "BASIC"`, một rule `SCAN_ON_PUSH` cùng filter repo cache): BASIC nhận đúng `SCAN_ON_PUSH` [N11], miễn phí [N12].
- Tắt quét ECR của Inspector đổi kiểu quét của registry từ Enhanced sang Basic; bật đổi ngược lại [N9]: `aws/security` đi trước, root account đặt lại
  rule. Gỡ quét trước khi gỡ association: account bị gỡ association khi Inspector còn bật thành account độc lập, admin không quản được nữa [N10].
- Đường thay thế: quét cơ bản ở stg; Inspector của prd quét cùng digest bên thứ ba ghim ở `svp-gitops`. Cái giá: digest mới ở stg trước promote chỉ có
  quét cơ bản; tắt quét xoá finding Inspector của account [N9]. Với `security_hub` = `always`, ECR.1 của repo không vào filter vẫn là finding.

### 5. `security_hub`

- `off`: `aws/security` gắn account vào configuration policy `svp-security-off` (`service_enabled = false`) của central configuration [N2], [N3].
  Policy tắt dịch vụ không gắn được vào delegated admin [N3], nên `security` không có `off`.
- GuardDuty gửi finding vào Security Hub của cùng account, cùng region [N16]: account `off` mất đường email của rule `svp-security-findings`. Admin
  GuardDuty nhận sự kiện finding của member ở EventBridge [N17], GuardDuty theo region [N20]: rule `svp-security-guardduty-findings` ở hai region của
  `svp-security` lọc `detail.accountId` là các account `off` và `detail.severity` ≥ 7 (HIGH 7,0–8,9, CRITICAL 9,0–10,0 [N18]); ở `us-east-1` đi
  qua bus `svp-security-events` bằng role `svp-security-guardduty-forwarder`. Lần lặp của finding đến theo tần suất xuất, mặc định 6 giờ [N19].
- Access Analyzer loại `ORGANIZATION` chạy ở `svp-security`, finding của nó mang `AwsAccountId` của account admin [N23], không qua
  Security Hub của stg. Cái giá: không control FSBP, CIS ở stg; finding cũ của account bị xoá sau 30 ngày (archived), 90 ngày (active)
  [N6]; email finding GuardDuty qua `us-east-1` là dòng chung của rule `notify`.
- Central configuration là tính năng cũ, AWS khuyên Security Hub CSPM declarative policy của Organizations; hai cách loại trừ nhau [N2], [N4].

### 6. `config_recording`

`off`: module `security-baseline` của account không tạo recorder, delivery channel, recorder status ở hai region; service-linked role giữ. Xoá
recorder không xoá thông tin đã ghi, vẫn đọc bằng `GetResourceConfigHistory` [N8]; bản đã giao vào bucket Config của Log Archive giữ. Cái giá: không
lịch sử cấu hình của tài nguyên buổi stg; CloudTrail org vẫn ghi mọi lệnh ở stg.

### 7. Phụ thuộc và ngưỡng

- `security_hub` = `always` cần `config_recording` = `always`: control finding cần Config bật và ghi ở mỗi region [N5].
- `inspector_ecr` = `off` với `security_hub` = `always` hợp lệ. `managed_grafana` không phụ thuộc cờ nào: AMP luôn có.
- Một mục thành cờ khi cả ba đúng: (a) phụ lục ADR đã có cho chi phí stg ≥ $2 mỗi tháng không buổi hay ≥ $1 mỗi buổi; (b) không cần để chạy và không
  thuộc §8; (c) giá trị khác `always` có đường thay thế bằng code, image đã có.

### 8. Không bao giờ tắt

CloudTrail org trail và data event của prd; GuardDuty với mọi protection plan; Access Analyzer truy cập ngoài; SCP, RCP, tag policy, backup policy;
budget, Cost Anomaly Detection; baseline account; đường sự kiện bảo mật tới email; mọi KMS CMK; bucket Log Archive; AWS Backup; VPC flow log, log
WAF. Lý do từng dòng: [phụ lục](appendix/0071-paid-features.md#kho-mục).

### 9. Không cờ

AMP, CloudWatch Logs, X-Ray (cần để chạy); endpoint interface, WAF Bot Control, ATP (dưới ngưỡng ở stg); secret, repo cache ECR (cần để chạy); lưu
trữ bản phát hành ECR (GC theo "Xem lại khi" của [0062](0062-ecr-registry-ci-oidc.md)); NAT, Multi-AZ, cỡ, gói CloudFront, số AZ endpoint, retention
đã là dữ liệu trong `<env>.tfvars`. Số và điều ngưỡng không đạt: phụ lục.

### 10. Thứ tự áp và đổi cờ

- Tắt cờ của account: `aws/security` (Security Hub, Inspector), rồi `aws/baseline` (Config), rồi `aws/accounts/<env>` (rule quét cơ bản). Bật:
  `aws/baseline` trước (Security Hub cần Config đang ghi [N5]), rồi `aws/security` (bật Inspector tự đổi registry sang Enhanced [N9]), rồi
  `aws/accounts/<env>` (đặt lại rule `CONTINUOUS_SCAN`).
- Cờ chỉ xoá tài nguyên của dòng nó ở §2–§6; không cờ nào chạm KMS key, bucket, vault, recovery point, log group. Bật lại thì Inspector quét lại
  mọi image đủ điều kiện [N9], Security Hub chạy lại mọi check trong hai giờ [N7], Config ghi lại mọi tài nguyên như item mới.

### 11. Chi phí

Theo phụ lục chi phí của 0048, 0060, 0061, 0062, 0063, 0064, 0067, không ước mới: tháng không buổi của cả org ~$59,6 khi mọi cờ `always`, ~$48,5
với giá trị stg (tháng đầu; bớt ~$11,1: AMG $9, Security Hub ~$1,8, Config ~$0,3). Mỗi buổi stg bớt Config $2–4,5, Security Hub $1–3, Inspector
0–~$9; AMG theo §3. Bảng đủ: [phụ lục](appendix/0071-paid-features.md#bảng-tháng-không-buổi).

### 12. Phép kiểm buổi theo cờ

Của `svp-infra` `docs/runbooks/session-stg.md`: `managed_grafana` (`session` chạy được sau bước mở account): "Giá trị secret" (token
Grafana Operator), "Đo" (dashboard SLO), "Kafka và Valkey managed" (e), "Phép kiểm nền tảng managed" (Explore, dashboard, Operator);
`inspector_ecr`: lệnh Inspector `list-coverage`, `list-findings` của "Phép kiểm nền tảng managed"; `security_hub`: cả hai lệnh của
"Finding bảo mật của buổi"; `config_recording`: không phép kiểm nào đọc Config, control FAILED cần Config đi cùng `security_hub`.

### 13. ADR cũ

Chỉnh: 0055 §1, §2, §6; 0060 §3, §4, §10, §12; 0062 §10; 0063 §4, §12.

### Hệ quả

- Tốt: tháng không buổi bớt ~$11; buổi stg bớt tới ~$16,5 ngoài AMG; prd và account dùng chung không đổi; thêm cờ là một dòng JSON và một nhánh `count`.
- Xấu: stg không thử được Security Hub, Config, Inspector như prd; mỗi buổi stg thêm bước mở, đóng account và trả AMG mỗi lần; tắt Security Hub
  mất finding cũ của stg; root đọc file ngoài thư mục của nó, `make test` chỉ thấy module, file thật chỉ được kiểm ở plan và `session-test`.
- Xem lại khi: tháng có ≥ 2 buổi stg thành thường lệ (AMG `always`); org chuyển Security Hub sang declarative policy (cờ `security_hub` thành đích
  của policy đó); stg chạy lâu dài; một lỗi Inspector, Security Hub hay Config chỉ lộ ở prd.

## Xác nhận

- Lúc quyết chưa hiện thực. Kiểm tĩnh: `make check` của `svp-infra` (test của module `paid-features` cho mọi giá trị và `validation`; module
  `observability`, `registry`, `security-baseline` ở cả hai trạng thái cờ, KMS key, AMP workspace, log group có ở mọi giá trị); `session-test`.
- Sau áp: plan lần hai `No changes` ở `aws/security`, `aws/baseline`, `aws/accounts/stg`; Security Hub của stg `disabled`, recorder không có, registry
  stg `BASIC`; giữa buổi `sweep.sh stg` không thấy workspace AMG; buổi stg chạy đủ phép kiểm §12 sau bước mở.

## Hiện thực ở

- `svp-infra`: `aws/paid-features.json`, `aws/modules/paid-features/` (§1, §7); `aws/modules/observability/`, `aws/accounts/<env>/`,
  `aws/envs/<env>/baseline.tf` (§3); `aws/security/inspector.tf`, `aws/modules/registry/` (§4); `aws/security/security-hub.tf`,
  `aws/security/alerts.tf` (§5); `aws/baseline/main.tf`, `aws/modules/security-baseline/` (§6); `aws/scripts/lib.sh`, `tf.sh`, `session.sh`,
  `sweep.sh` (§1, §3); `docs/runbooks/` (§10, §12).
- Repo code: `docs/explanation/paid-features.md`.

## Nguồn

Đọc 2026-11-14; đủ [N1]–[N21] kèm câu trích ở [phụ lục](appendix/0071-paid-features.md#nguồn).
[N2] <https://docs.aws.amazon.com/securityhub/latest/userguide/central-configuration-intro.html>,
[N9] <https://docs.aws.amazon.com/inspector/latest/user/deactivate-scans.html>,
[N14] <https://aws.amazon.com/grafana/pricing/>,
[N17] <https://docs.aws.amazon.com/guardduty/latest/ug/guardduty_findings_eventbridge.html>.

## Thông tin thêm

Phụ lục: [`appendix/0071-paid-features.md`](appendix/0071-paid-features.md) (phương án, kho mục, bảng tháng không buổi, đổi cờ, nguồn).
