# Phụ lục ADR-0071: Dịch vụ AWS tốn tiền mà hệ thống không cần để chạy có cờ theo account trong một file commit đọc qua một module chỉ trả dữ liệu; prd và bốn account dùng chung bật hết; stg chỉ dựng Amazon Managed Grafana trong buổi và tắt Inspector ECR, Security Hub CSPM, AWS Config; guardrail lõi không có cờ

Phụ lục của [ADR-0071](../0071-paid-features.md): phương án, kho mục, bảng tháng không buổi, đổi cờ, nguồn. Mọi nguồn đọc ngày 2026-11-14. Đường
dẫn `aws/...` là của `svp-infra`. Số tiền là USD, lấy nguyên từ phụ lục chi phí của ADR đã có (cột nguồn ghi mục); phép tính duy nhất là cộng, nhân,
chia theo giả định của chính bảng đó, ghi ở ô. "chưa có số" là khoản mà phụ lục không tách riêng.

## Phương án

| Câu hỏi | Phương án | Trạng thái ngành | Được | Mất | Nguồn |
| --- | --- | --- | --- | --- | --- |
| Nơi giữ cờ | `paid_features` trong `<env>.tfvars` của từng root | Hiện hành (biến đầu vào của root) | Root tự đủ, không đọc file ngoài | Cờ Inspector ở `aws/security` và `aws/accounts/<env>`, cờ Security Hub, Config ở `aws/security` và `aws/baseline`: hai bản chép mỗi cờ; root org không có `<env>.tfvars` | [N22] |
| Nơi giữ cờ | **Một file JSON commit, đọc qua module `paid-features` không provider, không resource** | Hiện hành: HashiCorp gọi module không mô tả hạ tầng mà gói cách lấy dữ liệu là "data-only module"; ở đây dữ liệu là file commit thay data source | Một nguồn, một `validation` cho mọi root và script (`jq`) | Root đọc file ngoài thư mục; `make test` chỉ mount module, file thật được kiểm ở plan và `session-test` | [N1] |
| Nơi giữ cờ | Không cờ: stg đúng như prd | Hiện hành (dev/prod parity) | stg bắt lỗi của mọi dịch vụ | Trả mọi khoản cả tháng không buổi | [N21] |
| AMG ở stg | `always` | Hiện hành | Dashboard xem được giữa buổi | $9 mỗi tháng không buổi | [N14] |
| AMG ở stg | **`session`: dựng ở bước mở, gỡ ở bước đóng của buổi** | Hiện hành (tài nguyên theo buổi, như env) | $0 tháng không buổi; hợp đồng cluster không đổi trong buổi | Bước mở, đóng; mỗi buổi trả một workspace mới | [N14] |
| AMG ở stg | `off` + Grafana trong cluster đọc AMP | Hiện hành ở cluster tự quản | Không phí AMG | Grafana 12+ cần plugin Amazon Managed Service for Prometheus để ký SigV4; image ghim không có, hardening cấm tải plugin lúc chạy | [N15] |
| Tắt Security Hub một account | **Configuration policy `service_enabled = false` của central configuration** | Cũ: AWS gọi central configuration là "legacy feature", vẫn dùng tiếp được, không ghi ngày ngừng | Cùng cơ chế với [0060](../0060-org-detection-logging.md) §3, một association | Không gắn được vào delegated admin | [N2], [N3] |
| Tắt Security Hub một account | Security Hub CSPM declarative policy của Organizations | Hiện hành, AWS khuyên | Cách AWS khuyên | Loại trừ central configuration: phải chuyển cả cấu hình của 0060 | [N4] |
| Tắt Security Hub một account | `DisableSecurityHub` ở account | — | — | Account do central configuration quản không gọi được `DisableSecurityHub` | [N2] |
| Inspector ở stg | **`off` + quét cơ bản ECR** | Hiện hành (quét cơ bản là bản AWS native) | Không phí Inspector ở stg | Digest mới ở stg chỉ có quét cơ bản tới khi promote | [N9], [N12] |
| Email finding GuardDuty khi Security Hub tắt | **Rule EventBridge ở admin GuardDuty, hai region** | Hiện hành (mẫu EventBridge của GuardDuty) | Giữ email HIGH, CRITICAL của account tắt | Dòng email chung ở đường `us-east-1` | [N17], [N18] |
| Email finding GuardDuty khi Security Hub tắt | Không email | — | Không thêm rule | Finding lạm dụng credential của stg không tới người | — |

## Kho mục

Mỗi mục một dòng. Chi phí là của stg; "hai account" chia 2, "năm account" chia 5 theo giả định của bảng nguồn. Điều (a), (b), (c) là của ngưỡng
ở ADR §7.

### Cờ

| Mục | Tài nguyên, root | stg tháng không buổi | stg mỗi buổi | Nguồn | Ngưỡng |
| --- | --- | --- | --- | --- | --- |
| `managed_grafana` | Workspace `svp-<env>`, role `svp-<env>-grafana`, gán nhóm, service account `svp-grafana-operator` (`aws/modules/observability/grafana.tf`), SSM parameter `/svp/<env>/grafana-workspace-id`; root `aws/accounts/<env>`, đọc ở `aws/envs/<env>` | `always` 9 (18 hai account ÷ 2); `session` 0 | `always` +9 ở buổi đầu tháng, 0 buổi sau; `session` 18 (hai user × 9) | [0063](../0063-managed-observability.md) phụ lục §12 "Bảng giá", "Phần này, tháng không buổi (hai account)", "Phần này, mỗi buổi 4 giờ" | (a) 9 ≥ 2; (b) alert đi AMP → SNS, không qua AMG; (c) cùng module dựng lại trong buổi |
| `inspector_ecr` | Enabler, member association (`aws/security/inspector.tf`); cấu hình quét registry (`aws/modules/registry/repositories.tf`, root `aws/accounts/<env>`) | chưa có số riêng: dòng "< 0,5" gộp quét lại, request KMS, API Secrets Manager của hai account | 0 khi không digest bên thứ ba mới; ≤ 6,8 buổi đầu tiên; ≤ 9 buổi cách buổi trước một tháng | [0062](../0062-ecr-registry-ci-oidc.md) phụ lục §11 "Lúc không buổi (hai account)", "Mỗi buổi (mỗi account env)" | (a) ≤ 9 mỗi buổi; (b) admission dựa vào `vuln` của CI ([0040](../0040-sigstore-bundle-actions-attest.md)), không vào Inspector; (c) quét cơ bản ECR |
| `security_hub` | Configuration policy `svp-security-off` và association (`aws/security/security-hub.tf`); rule `svp-security-guardduty-findings` (`aws/security/alerts.tf`) | ~1,8 (~1 800 check × 0,001 mỗi account) | 1–3 | [0060](../0060-org-detection-logging.md) phụ lục §12 "Ước lúc không buổi", "Thêm mỗi buổi" | (a) 1–3 mỗi buổi; (b) posture không cần để chạy; (c) prd cùng module được chấm; email GuardDuty qua rule riêng |
| `config_recording` | Recorder, delivery channel, recorder status hai region (`aws/modules/security-baseline/config.tf`, root `aws/baseline`) | ~0,3 (~100 item × 0,003 mỗi account) | 2–4,5 | 0060 phụ lục §12 "Ước lúc không buổi", "Thêm mỗi buổi" | (a) 2–4,5 mỗi buổi; (b) không cần để chạy; (c) CloudTrail org ghi mọi lệnh |

### Cờ không bao giờ tắt

| Mục | Tài nguyên, root | stg tháng không buổi | stg mỗi buổi | Nguồn | Lý do |
| --- | --- | --- | --- | --- | --- |
| CloudTrail org trail, data event prd | Trail `svp-audit` (`aws/org/audit-trail.tf`) | ~0 (bản đầu miễn phí) | ~0 (stg không có data event) | 0060 phụ lục §12 "Ước lúc không buổi", "Thêm mỗi buổi" | Ghi mọi lệnh của mọi account; là đường thay thế khi Config, Security Hub tắt |
| GuardDuty, mọi protection plan | `aws/security/guardduty.tf`, add-on agent, plan Malware Protection | ~0,5 (2,4 năm account ÷ 5) | ~0,5 | 0060 phụ lục §12 | Phát hiện lạm dụng credential cần nhất lúc không ai trực; rẻ |
| IAM Access Analyzer truy cập ngoài | Analyzer `ORGANIZATION` ở `aws/security` | 0 | 0 | 0060 phụ lục §12 "Ước lúc không buổi" dòng Access Analyzer ngoài | Không tính phí |
| SCP, RCP, tag policy, backup policy | `aws/org`, `aws/backup` | 0 | 0 | [0048](../0048-prd-aws.md) phụ lục "Chi phí" bảng R dòng "Organizations, SCP" | Không phí; guardrail của mọi account |
| Budget, Cost Anomaly Detection | `aws/bootstrap/budget.tf`, `cost.tf`; `aws/modules/account-baseline/budget.tf` | 0 | 0 | 0048 phụ lục bảng R dòng Budget; 0060 phụ lục §12 dòng Cost Anomaly Detection | Không phí; báo tiền khi env quên gỡ |
| Baseline account (Block Public Access, mã hoá EBS mặc định, liên hệ SECURITY, root access) | `aws/baseline`, `aws/org/contacts.tf`, `root-access.tf`, `aws/accounts/<env>` | CMK EBS stg 1 | 0 | 0060 phụ lục §12 dòng KMS (1 mỗi key) | Chặn lộ dữ liệu và chiếm root; gần như không phí |
| Đường sự kiện bảo mật tới email | Rule `svp-security-*`, bus `svp-security-events`, topic `svp-security-alarms` | ~0 | ~0 | 0060 phụ lục §12 dòng EventBridge, SNS | Guardrail báo khi ai đổi hay tắt dịch vụ phát hiện |
| Mọi KMS CMK | Key của stg: `alias/svp-tfstate`, CMK EBS, `alias/svp-stg-ecr`, `alias/svp-stg-observability`, `alias/svp-stg-backup` | 5 (5 × 1) | 0 | 0048 phụ lục bảng R; 0060, 0062, 0063, [0067](../0067-backup-dr.md) phụ lục (1 mỗi key) | Xoá key là mất dữ liệu mã hoá bằng nó |
| Bucket Log Archive | `aws/log-archive` | ~1,1 cả org | — | 0060 phụ lục §12 dòng S3 Log Archive | Bằng chứng ngoài tầm admin của workload |
| AWS Backup | `aws/backup`, `aws/accounts/<env>/backup.tf` | bản copy stg 0,07 + key vault 1 | ~0,15 | 0067 phụ lục "Chi phí" "Sống giữa buổi", "Mỗi buổi" | Giữ dữ liệu; cũng dưới (a) |
| VPC flow log, log WAF | `aws/modules/network`, `aws/modules/waf` | 0 (gỡ cùng buổi; bucket ở Log Archive) | flow log 0,2–0,4; log WAF ~0 | 0060 phụ lục §12 "Thêm mỗi buổi" | Điều tra sau sự cố; dưới (a) |

### Không cờ

| Mục | Tài nguyên, root | stg tháng không buổi | stg mỗi buổi | Nguồn | Điều không đạt |
| --- | --- | --- | --- | --- | --- |
| AMP ingest, CloudWatch Logs, X-Ray | `aws/modules/observability` | lưu trữ < 0,3 hai account | AMP 2,52 buổi đầu tháng (0,72 khi một env), 4,32 buổi sau; log 0,35; span 0,35 | 0063 phụ lục §12 | (b): metric, alert, log, trace cần để chạy; trả theo dùng |
| Grafana trong cluster thay AMG (giá trị `off`) | Chart `kube-prometheus-stack` của `svp-gitops` | — | — | 0063 phụ lục §4 "Data source"; [N15] | (c): image ghim không có plugin đọc AMP |
| Endpoint interface | `aws/modules/network` | 0 | 0,75 | [0064](../0064-interface-endpoints.md) phụ lục §7 | (a) 0,75 < 1; bỏ thì NetworkPolicy tới API AWS và đường NAT đổi |
| WAF Bot Control (web), ATP (api) | `aws/modules/waf` | 0 (gỡ cùng buổi) | (10 + 10) × 4/730 ≈ 0,11 phí cố định; request dưới hạn mức | [0061](../0061-edge-cloudfront-waf-acm.md) phụ lục §13 "Bảng giá", "Thêm mỗi buổi" | (a) |
| AWS Backup stg | dòng ở bảng trên | 1,07 | ~0,15 | 0067 phụ lục "Chi phí" | (a), và thuộc bảng trên |
| Secret, repo cache ECR | `aws/modules/registry/cache.tf` | secret 0,8 (1,6 ÷ 2); cache ~0,5 (~1 ÷ 2) | < 0,01 | 0062 phụ lục §11 | (b): node kéo image bên thứ ba qua cache |
| Lưu trữ bản phát hành ECR stg | Repo `svp-backend/*`, `svp-frontend/web` | ~0,7 tháng 1; ~3,6 tháng 3; ~8 tháng 6 | — | 0062 phụ lục §11 "Lưu trữ tăng theo bản phát hành" | (b) image để chạy; (c) không có đường thay bằng cờ: GC theo "Xem lại khi" của 0062 |
| NAT theo AZ, Multi-AZ RDS, ElastiCache, MSK, cỡ, gói CloudFront Free của media stg, số AZ endpoint, retention log | `single_nat_gateway`, `rds_multi_az`, `media_flat_rate_free`, `interface_endpoint_az_count`… trong `aws/envs/<env>/<env>.tfvars` | 0 (gỡ cùng buổi) | NAT 0,059 mỗi giờ mỗi NAT | 0048 phụ lục "Chi phí" bảng H₀ | Đã là dữ liệu theo env ([0055](../0055-environment-matrix.md) §3, §4), giữ nguyên |

## Bảng tháng không buổi

### Theo cờ (stg)

Mỗi ô "`always` → giá trị stg". n là số buổi stg trong tháng; Inspector theo số digest bên thứ ba mới, không theo n.

| Cờ | Giá trị stg | Tháng không buổi | Mỗi buổi | n = 0 | n = 1 | n = 2 | n = 3 | Nguồn |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| `managed_grafana` | `session` | 9 → 0 | +9 ở buổi đầu tháng, 0 buổi sau → 18 | 9 → 0 | 18 → 18 | 18 → 36 | 18 → 54 | 0063 phụ lục §12 |
| `inspector_ecr` | `off` | < 0,5 (gộp, chưa có số riêng) → 0 | 0–9 → 0 | < 0,5 → 0 | ≤ 9 → 0 | ≤ 9 + 0,18 mỗi digest mới → 0 | như n = 2 | 0062 phụ lục §11 |
| `security_hub` | `off` | ~1,8 → 0 | 1–3 → 0 | 1,8 → 0 | 2,8–4,8 → 0 | 3,8–7,8 → 0 | 4,8–10,8 → 0 | 0060 phụ lục §12 |
| `config_recording` | `off` | ~0,3 → 0 | 2–4,5 → 0 | 0,3 → 0 | 2,3–4,8 → 0 | 4,3–9,3 → 0 | 6,3–13,8 → 0 | 0060 phụ lục §12 |
| **Cộng stg** | | **~11,1 (+ tới 0,5) → 0** | | | | | | |

`managed_grafana`: trang giá AMG không nói tính theo phần tháng khi workspace xoá giữa tháng [N14]; bảng lấy cách đọc bất lợi (mỗi workspace có trong
tháng tính đủ hai user). `session` lợi 9 ở tháng không buổi, bằng ở tháng một buổi, thiệt 18 mỗi buổi thêm từ buổi thứ hai: tháng có ≥ 2 buổi stg
đặt `always` trước buổi đầu.

### Cả org

| Nguồn | Mọi cờ `always` | Giá trị stg |
| --- | --- | --- |
| 0060 phụ lục §12 "Ước lúc không buổi" (năm account) | ~20 | ~17,9 (bớt Security Hub ~1,8, Config ~0,3 của stg) |
| 0067 phụ lục "Sống giữa buổi": baseline `svp-backup` | ~2,2 | ~2,2 |
| 0067 phụ lục "Sống giữa buổi": CMK, bản copy | ~4,4 | ~4,4 |
| 0063 phụ lục §12 "Phần này, tháng không buổi (hai account)" | ~20,3 | ~11,3 (bớt AMG stg 9) |
| 0062 phụ lục §11 "Lúc không buổi (hai account)" | ~5,7 tháng 1; ~9 tháng 3; ~14 tháng 6 | như cột trái, bớt tới 0,5 (Inspector stg nằm trong dòng "< 0,5") |
| 0061 phụ lục §13 "Lúc không buổi" | ~2,4 | ~2,4 |
| 0064 phụ lục §7 "Lúc không buổi"; 0065 qua 0063 phụ lục §12 "Bảng tổng của run" | 0 | 0 |
| 0048 phụ lục "Chi phí" bảng R | ~4,6 | ~4,6 |
| **Tổng** | **~59,6 tháng 1; ~67,9 tháng 6** | **~48,5 tháng 1; ~56,8 tháng 6 (bớt thêm tới 0,5)** |

Cộng các bảng như chúng ghi; mỗi bảng tự ghi phần nó không cộng lại (key trail cũ ở 0060). Phần còn lại lớn nhất khi cờ stg đã tắt: AMG prd 9, Security
Hub năm account còn lại, KMS, lưu trữ bản phát hành ECR.

## Đổi cờ

Từ `always` sang giá trị kia trên state đã có tài nguyên; root chưa áp phần của dịch vụ đó thì đổi cờ không destroy gì. Địa chỉ trong module mang
`[0]` khi module dùng `count` theo cờ. Thứ tự root theo ADR §10.

### `managed_grafana` → `session`

- `aws/accounts/<env>` với `session_open = false`: destroy `module.observability.aws_grafana_workspace.this`, `aws_grafana_role_association.admin`,
  `aws_grafana_role_association.viewer`, `aws_grafana_workspace_service_account.operator`, `aws_iam_role_policy.grafana`, `aws_iam_role.grafana` và
  SSM parameter `/svp/<env>/grafana-workspace-id`. Workspace AMP, key `alias/svp-<env>-observability`, log group không đổi.
- Mất: không dữ liệu nào cần giữ: data source và dashboard do Grafana Operator dựng lại từ `svp-gitops` mỗi buổi; id, URL workspace đổi mỗi buổi
  (SSM parameter mang id mới); token cũ ở entry `svp/<env>/grafana-operator` vô dụng, script buổi tạo token mới.
- Về `always`: workspace tạo ở lần áp sau, giữ qua các buổi; chi phí theo bảng trên.

### `inspector_ecr` → `off`

- `aws/security`: `aws_inspector2_enabler.members` sửa tại chỗ (bỏ id account), rồi destroy `aws_inspector2_member_association.members["<id account>"]`:
  enabler phụ thuộc association, Terraform xử lý resource phụ thuộc trước khi xoá resource nó phụ thuộc, nên quét tắt trước khi account rời admin
  (ADR §4, [N10]). AWS đổi kiểu quét của registry sang Basic [N9].
- `aws/accounts/<env>`: `module.registry.aws_ecr_registry_scanning_configuration.this` sửa tại chỗ (`ENHANCED`, `CONTINUOUS_SCAN` → `BASIC`,
  `SCAN_ON_PUSH`, cùng filter repo cache).
- Mất: mọi finding Inspector của account [N9]; quét đã lập của kiểu cũ không còn, có lại khi về kiểu cũ [N13].
- Về `always`: Inspector quét mọi image đủ điều kiện để sinh finding mới [N9]; giả định tính như lượt quét đầu, 0,09 mỗi image (0062 phụ lục §11;
  trang giá không nói riêng lượt bật lại).

### `security_hub` → `off`

- `aws/security`: tạo configuration policy `svp-security-off`, association của account, rule `svp-security-guardduty-findings` ở hai region cùng
  target, role `svp-security-guardduty-forwarder`; không destroy resource nào trong state.
- Trong AWS: configuration policy có hiệu lực ở home Region và mọi region liên kết [N2]; Security Hub ngừng sinh và nhận finding của account;
  finding archived xoá sau 30 ngày, active và insight sau 90 ngày [N6].
- Về `always`: account về policy `svp-security-standards`; bật lại trong 90 ngày lấy lại finding active (archived: 30 ngày), có thể có finding trùng
  [N6]; check bắt đầu trong hai giờ, phần lớn trong 25 phút [N7], 0,001 mỗi check (0060 phụ lục §12 "Bảng giá"); số check của lượt đầu chưa có số.

### `config_recording` → `off`

- `aws/baseline`: destroy trong module của account (`module.stg` với stg) `aws_config_configuration_recorder_status.this`,
  `aws_config_delivery_channel.this`, `aws_config_configuration_recorder.this`, mỗi cái hai khoá region; `aws_iam_service_linked_role.config` giữ.
- Mất: không gì đã ghi: thông tin đã ghi giữ, đọc bằng `GetResourceConfigHistory` [N8]; bản đã giao ở bucket `svp-config-…` của Log Archive giữ;
  aggregator của `svp-security` ngừng nhận dữ liệu mới của account.
- Về `always`: recorder ghi lại mọi tài nguyên: ~100 item × 0,003 ≈ 0,3 (0060 phụ lục §12 "Ước lúc không buổi").

## Nguồn

Đọc 2026-11-14.

- [N1] HashiCorp, Module Composition, "Data-only Modules": <https://developer.hashicorp.com/terraform/language/modules/develop/composition>: "It
  may sometimes be useful to write modules that do not describe any new infrastructure at all, but merely retrieve information about existing
  infrastructure that was created elsewhere using data sources"; "the source of this information can change over time without updating every
  configuration that depends on it".
- [N2] Security Hub CSPM, central configuration: <https://docs.aws.amazon.com/securityhub/latest/userguide/central-configuration-intro.html>:
  "Configuration policies let the delegated administrator specify whether Security Hub CSPM is enabled or disabled"; "Central configuration is a
  legacy feature. Security Hub CSPM declarative policies are replacing it as the way to manage Security Hub CSPM across an organization"; "If your
  organization currently uses central configuration, you can continue to use the information in this section"; account do central configuration
  quản không dùng được `DisableSecurityHub`, `EnableSecurityHub`. Không ghi ngày ngừng.
- [N3] Configuration policies: <https://docs.aws.amazon.com/securityhub/latest/userguide/configuration-policies-overview.html>: "you can associate
  it with one or more accounts, organizational units (OUs), or the root"; "You can't associate a configuration policy that disables Security Hub
  CSPM with the delegated administrator account".
- [N4] Declarative policies: <https://docs.aws.amazon.com/securityhub/latest/userguide/accounts-orgs-policies.html>: "You can target the
  organization root, organizational units (OUs), or individual accounts"; "The two mechanisms are mutually exclusive".
- [N5] Config cho Security Hub CSPM: <https://docs.aws.amazon.com/securityhub/latest/userguide/securityhub-prereq-config.html>: "To receive
  control findings in Security Hub CSPM, AWS Config must be enabled for your account in each AWS Region"; "you must turn on recording in AWS Config
  for the types of resources that correspond to your enabled controls".
- [N6] Tắt Security Hub CSPM: <https://docs.aws.amazon.com/securityhub/latest/userguide/securityhub-disable.html>,
  <https://docs.aws.amazon.com/securityhub/1.0/APIReference/API_DisableSecurityHub.html>: "Security Hub CSPM stops generating, updating,
  and ingesting findings for the account"; "After 30 days, Security Hub CSPM permanently deletes all existing archived findings"; "After
  90 days, Security Hub CSPM permanently deletes all existing active findings"; "Security Hub CSPM might initially generate duplicate
  findings".
- [N7] Lịch chạy check: <https://docs.aws.amazon.com/securityhub/latest/userguide/securityhub-standards-schedule.html>: "After you enable a
  security standard, AWS Security Hub CSPM begins to run all checks within two hours. Most checks begin to run within 25 minutes".
- [N8] `DeleteConfigurationRecorder`: <https://docs.aws.amazon.com/config/latest/APIReference/API_DeleteConfigurationRecorder.html>: "This
  operation does not delete the configuration information that was previously recorded. You will be able to access the previously recorded
  information by using the GetResourceConfigHistory operation".
- [N9] Inspector, bật và tắt kiểu quét: <https://docs.aws.amazon.com/inspector/latest/user/deactivate-scans.html>: "When you deactivate Amazon ECR
  scanning for an account, the Amazon ECR scan type account changes from Enhanced scanning with Amazon Inspector to Basic scanning with Amazon ECR";
  "When you deactivate a scan type, you lose access to any findings the scan type produced"; "If you reactivate the scan type, Amazon Inspector
  scans all eligible resources to generate new findings". <https://docs.aws.amazon.com/inspector/latest/user/activate-scans.html>: "When you
  activate this scan type, you change the scanning configuration setting for your private registry from basic scanning to enhanced scanning".
- [N10] Inspector nhiều account: <https://docs.aws.amazon.com/inspector/latest/user/deactivating-best-practices.html>: "If your account is a
  member account in a multi-account environment, you cannot deactivate Amazon Inspector";
  <https://docs.aws.amazon.com/inspector/latest/user/disassociating-member-accounts.html>: "When you disassociate a member account, Amazon Inspector
  is still activated in the account, and the account becomes a standalone account".
- [N11] ECR `RegistryScanningRule`: <https://docs.aws.amazon.com/AmazonECR/latest/APIReference/API_RegistryScanningRule.html>: "When the `BASIC`
  scan type is specified, the `SCAN_ON_PUSH` scan frequency is supported"; filter `WILDCARD`:
  <https://docs.aws.amazon.com/AmazonECR/latest/APIReference/API_ScanningRepositoryFilter.html>; quét cơ bản:
  <https://docs.aws.amazon.com/AmazonECR/latest/userguide/image-scanning-basic.html>: "Amazon ECR basic scanning supports filters to specify which
  repositories to scan on push"; "An image can be scanned once per 24 hours".
- [N12] ECR basic scanning bản mới (2024-08-06): <https://aws.amazon.com/about-aws/whats-new/2024/08/new-version-amazon-ecr-basic-scanning/>:
  "generally available in all AWS commercial regions and the AWS GovCloud (US) Regions at no additional cost"; tài liệu Inspector: "Basic scanning is
  provided and billed through Amazon ECR" (<https://docs.aws.amazon.com/inspector/latest/user/scanning-ecr.html>); trang giá ECR không có dòng
  quét cơ bản.
- [N13] ECR image scanning: <https://docs.aws.amazon.com/AmazonECR/latest/userguide/image-scanning.html>: "Switching between Enhanced scanning and
  Basic scanning will cause previously established scans to no longer be available"; "if you switch back to your previous scanning type the
  established scans will be available".
- [N14] AMG, trang giá và FAQ: <https://aws.amazon.com/grafana/pricing/>, <https://aws.amazon.com/grafana/faqs/>: "All user licenses are per
  workspace, per month"; tối thiểu một Editor mỗi workspace "even if no users log in"; "Each Service account is billed as an Amazon Manager Grafana
  user" (nguyên văn); "You will be charged at the end of the month for your usage". Không trang nào nói về phần tháng hay workspace xoá giữa tháng.
- [N15] AMG, data source AMP: <https://docs.aws.amazon.com/grafana/latest/userguide/prometheus-data-source.html>: "Starting in Amazon Managed
  Grafana version 12, SigV4 authentication support in the Core Prometheus plugin has been removed"; Grafana v13.3:
  <https://grafana.com/docs/grafana/v13.3/datasources/prometheus/configure/aws-authentication/>: "Prometheus data sources configured with SigV4
  authentication are automatically migrated to the dedicated Amazon Managed Service for Prometheus plugin on Grafana startup"; "Install the plugin
  if it isn't already installed".
- [N16] GuardDuty và Security Hub CSPM: <https://docs.aws.amazon.com/guardduty/latest/ug/securityhub-integration.html>: "Once you enable GuardDuty
  and Security Hub CSPM in the same account within the same AWS Region, GuardDuty starts sending all the generated findings to Security Hub CSPM".
- [N17] GuardDuty và EventBridge: <https://docs.aws.amazon.com/guardduty/latest/ug/guardduty_findings_eventbridge.html>: "EventBridge rules in your
  administrator account will trigger based on applicable findings from your member accounts"; "You can identify the member account where the
  GuardDuty finding originated using the `accountId` field of the finding's JSON details"; ví dụ pattern lọc `detail.severity` bằng số.
- [N18] Mức độ finding GuardDuty: <https://docs.aws.amazon.com/guardduty/latest/ug/guardduty_findings-severity.html>: giá trị 1,0–10,0; Critical
  9,0–10,0, High 7,0–8,9, Medium 4,0–6,9, Low 1,0–3,9.
- [N19] Tần suất xuất finding: <https://docs.aws.amazon.com/guardduty/latest/ug/guardduty_exportfindings.html>: "By default, updated findings are
  exported every 6 hours"; trang EventBridge: "Possible values are 15 minutes, 1 hour, or the default 6 hours", áp cho EventBridge, S3, Detective.
- [N20] GuardDuty theo region: <https://docs.aws.amazon.com/guardduty/latest/ug/guardduty_settingup.html>: "GuardDuty is a Regional service".
- [N21] The Twelve-Factor App, X. Dev/prod parity: <https://12factor.net/dev-prod-parity>.
- [N22] HashiCorp, Input variables (đọc 2026-11-14): <https://developer.hashicorp.com/terraform/language/values/variables>: "Add variables blocks to your
  root module to let consumers pass values into the module at run time"; giá trị gán trong file `.tfvars` của từng root, nên mỗi root giữ một bản.
- [N23] Security Hub CSPM, internal providers (đọc 2026-11-14): <https://docs.aws.amazon.com/securityhub/latest/userguide/securityhub-internal-providers.html>:
  "For organization analyzers, the `AwsAccountId` ASFF field reflects the administrator account ID".
