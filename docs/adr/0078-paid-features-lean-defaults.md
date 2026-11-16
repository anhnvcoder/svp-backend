# 0078. Mọi cờ chi phí của ADR-0071 mặc định giá trị rẻ nhất hợp lệ ở mọi account; prd chạy một buổi, đổi về giá trị production trước buổi đó; phần chuẩn ngành giữ trong code nhưng buổi cloud mặc định chỉ chạy phép kiểm lõi; `managed_grafana` thêm giá trị `off`

- Trạng thái: Chấp nhận
- Ngày: 2026-11-16
- Người quyết: người học (2026-11-16: prd và bốn account dùng chung giữa các buổi lấy giá trị rẻ như stg, prd chỉ chạy
  một buổi; ngay sau đó: phần chuẩn ngành dựng trong code để hiểu, buổi cloud mặc định không chạy), AI đề xuất giá trị,
  bảng xét lại và số

## Bối cảnh và vấn đề

- [0071](0071-paid-features.md) để prd và bốn account dùng chung (management, `svp-log-archive`, `svp-security`,
  `svp-backup`) ở `always`: tháng không buổi của cả org ~$48,5 ở tháng đầu, ~$56,8 ở tháng thứ sáu với giá trị stg;
  khoản lớn nhất còn lại gồm AMG prd $9 và Security Hub CSPM của các account đó ([phụ lục
  0071](appendix/0071-paid-features.md#cả-org)).
- Lộ trình học chỉ cần một buổi prd, ở cuối lộ trình (buổi capstone); mọi buổi khác là stg. Giữa các buổi prd không chạy
  workload, nhưng posture của nó và của account dùng chung vẫn được chấm, tính tiền cả tháng.
- Người học muốn hiểu các phần chuẩn ngành (dashboard managed, chấm posture, quét Inspector, diễn tập khôi phục) nên
  chúng phải có trong code; một buổi cloud chủ yếu kiểm hệ thống chạy được.

## Yếu tố quyết định

- Hệ thống chạy được và giữ an toàn cơ bản ở mọi giá trị cờ ([0071](0071-paid-features.md), "Yếu tố quyết định").
- `validation` của module `paid-features` là giới hạn dưới: chỉ bật thứ nó đòi.
- Mỗi số có nguồn ở phụ lục chi phí đã có; không ước mới.
- Phần chuẩn ngành bật lại được bằng một thay đổi của file cờ và thứ tự áp của 0071 §10.

## Phương án đã cân nhắc

- Giữ 0071 (prd, account dùng chung `always`): posture chấm cả tháng ở năm account; trả ~$48,5 mỗi tháng không buổi.
- **Giá trị rẻ nhất hợp lệ ở mọi account; prd đổi về giá trị production trước buổi duy nhất của nó**: ~$31,1 mỗi tháng;
  giữa các buổi chỉ `svp-security` được chấm.
- Tắt cả Security Hub của `svp-security` (gỡ delegated admin hay chuyển sang declarative policy): central configuration
  không gắn được policy tắt vào delegated admin [N3]; finding của GuardDuty, Access Analyzer ở `svp-security` mất đường
  email; phải đổi cấu hình của [0060](0060-org-detection-logging.md).

## Kết quả quyết định

Chọn phương án in đậm, vì nó bớt ~$17,4 mỗi tháng không buổi mà không chạm guardrail lõi, và mọi phần tắt bật lại được
bằng code đã có. Bảng xét lại và bảng chi phí: [phụ lục](appendix/0078-paid-features-lean-defaults.md).

### 1. Giá trị của file cờ

File commit `aws/paid-features.json` của `svp-infra` ghi cho mọi account giá trị rẻ nhất mà `validation` cho phép.
Module giữ nghĩa của khoá, cờ vắng: `always`, tức giá trị production của 0071 §1.

| Khoá account | `managed_grafana` | `inspector_ecr` | `security_hub` | `config_recording` |
| --- | --- | --- | --- | --- |
| `mgmt`, `log-archive`, `backup` | không đặt được (cờ của env) | không đặt được (cờ của env) | `off` | `off` |
| `security` | không đặt được | không đặt được | vắng (`always`, §2) | vắng (`always`, §2) |
| `stg`, `prd` | `session` | `off` | `off` | `off` |

Khi §5 đã hiện thực, `managed_grafana` của `stg`, `prd` thành `off`.

### 2. Phần `validation` buộc bật

`svp-security` giữ `security_hub` `always` (delegated admin, [N3]) và vì thế `config_recording` `always` (control của
Security Hub là rule Config, [N5]): ~$1,8 + ~$0,3 mỗi tháng (phụ lục 0060 §12 "Ước lúc không buổi", mỗi account).
Inspector vẫn bật ở `svp-security` và member `svp-log-archive`, `svp-backup`, vì `inspector_ecr` chỉ đặt được cho env;
ba account đó không có image.

### 3. prd chạy một buổi

- prd chỉ chạy buổi capstone. Phép kiểm prd của buổi khác chuyển sang stg hay vào buổi đó.
- **Đổi cờ prd**: trước buổi, xoá khoá `prd` khỏi file (giá trị production) và áp theo thứ tự "bật" của 0071 §10
  (`aws/baseline`, `aws/security`, `aws/accounts/prd`) bằng runbook `docs/runbooks/paid-features.md` của `svp-infra`;
  sau buổi, ghi lại giá trị của §1 và áp theo thứ tự "tắt" (`aws/security`, `aws/baseline`, `aws/accounts/prd`). Account
  dùng chung giữ giá trị của §1 suốt buổi.
- Không mục nào của 0071 §8 đổi: CloudTrail, GuardDuty, SCP, budget, Backup, KMS, flow log, log WAF vẫn bật ở mọi
  account.

### 4. Xét lại §8, §9 của 0071

Một mục thành cờ khi cả ba đúng: (a) ≥ $2 mỗi tháng không buổi hay ≥ $1 mỗi buổi ở bất kỳ account nào; (b) không cần cho
chức năng lõi (upload, transcode, feed, phát, xác thực, triển khai qua Argo CD, đường cảnh báo) hay an toàn cơ bản của
account; (c) có đường chạy không có nó bằng code. Chỉ AMG đạt: nó thêm `off` (§5). Mọi mục khác giữ như 0071, mỗi mục
một dòng có số và nguồn ở phụ lục.

### 5. `managed_grafana` = `off`

- Không workspace AMG, SSM parameter, entry `svp/<env>/grafana-operator`, ExternalSecret của nó, đích dashboard cần
  Grafana, egress tới Grafana; mọi Application vẫn Healthy. Alert đi AMP → SNS, không qua AMG; phép kiểm lõi không cần
  dashboard.
- **Hợp đồng cluster**: `grafanaUrl` là chuỗi rỗng `""` đúng khi cờ của env là `off`, ngoài ra là
  `https://g-<id>.grafana-workspace.<region>.amazonaws.com`; khoá luôn có trong tập khoá.
- Khác "Grafana trong cluster" mà 0071 §3 bỏ: `off` không chạy Grafana nào. Mặc định của stg, prd khi đã hiện thực (§1).

### 6. Phép kiểm lõi và chuẩn ngành

- Runbook buổi `session-stg.md`, `session-prd.md` của `svp-infra` đánh dấu mỗi phép kiểm `lõi` hay `chuẩn ngành`; đường
  mặc định của buổi chỉ chạy `lõi`.
- `lõi`: phép kiểm chứng minh upload, transcode, feed, phát, xác thực, triển khai qua Argo CD (cả commit status
  `argocd/<env>` mà promote cần), đường cảnh báo (luật ở AMP, Alertmanager tới topic SNS của env, email alarm đã xác
  nhận); bước tạo, kiểm, gỡ env (account, DNS, root, secret, chờ, dọn backup, teardown, quét sót); đọc an toàn không tốn
  tiền (finding GuardDuty ở `svp-security`).
- `chuẩn ngành` (chọn bật, ghi cần cờ nào): dashboard, bậc tải k6 và seed, diễn tập khôi phục, kiểm sâu nền tảng
  managed, Inspector, finding Security Hub, edge premium.

### 7. Cái mất

- Giữa các buổi prd và account dùng chung không có chấm FSBP, CIS và lịch sử Config; posture chỉ được chấm ở
  `svp-security`.
- Inspector của prd tắt: registry quét cơ bản khi push; digest bên thứ ba chỉ có quét cơ bản tới buổi prd; admission dựa
  vào attestation `vuln` của CI ([0040](0040-sigstore-bundle-actions-attest.md)), không vào Inspector.
- Tắt Security Hub xoá finding cũ của account (archived sau 30 ngày, active sau 90 ngày [N6]); tắt quét Inspector xoá
  finding của nó [N9].
- Finding GuardDuty mức ≥ 7 của management, `svp-log-archive`, `svp-backup`, stg, prd tới email qua rule
  `svp-security-guardduty-findings` (0071 §5); ở `us-east-1` là dòng chung của rule `notify`.
- Đổi cờ prd trước buổi trả lượt bật lại: Inspector quét lại, Security Hub chạy lại mọi check, Config ghi lại mọi tài
  nguyên (§8).

### 8. Chi phí

Theo phụ lục chi phí của ADR đã có, mỗi ô ghi dòng nguồn; không ước mới; dùng thử tháng đầu không trừ (như 0071 §11).
Tháng không buổi ~$31,1 ở tháng đầu, ~$39,4 ở tháng thứ sáu (bớt ~$17,4 so với 0071), bớt thêm tới ~$0,6. Buổi prd 4 giờ
với giá trị production ~$52,5–56,6 cộng phần chưa có số: node Karpenter ngoài nhóm hệ thống, alarm của
[0058](0058-managed-data-operations.md), lượt check đầu của Security Hub, service mesh. Buổi stg không đổi tới khi §5
hiện thực; sau đó bớt AMG $18 mỗi buổi. Bảng: [phụ lục](appendix/0078-paid-features-lean-defaults.md#chi-phí).

### 9. ADR cũ

Chỉnh: 0071 §1–§7, §9, §11, §12, "Hệ quả"; 0055 §1, §2, §6; 0060 §3, §4, §10, §12; 0062 §10, §11; 0063 §4, §12; 0067 §3,
§13, "Hệ quả".

### 10. Thứ tự hiện thực

- §1–§3, §7, §8 hiện thực cùng ADR này: file cờ, test, script, runbook, tài liệu.
- §5 theo expand–contract qua ba repo: chart của repo này nhận `grafanaUrl` rỗng mà vẫn nhận dạng URL, rồi bản phát hành
  chart, PR của `svp-gitops` nâng chart, cuối cùng `svp-infra` đổi file cờ sang `off`. Mỗi bước trước giữ dạng URL chạy
  được, nên không buổi nào hỏng ở giữa.
- §6 đi cùng hay sau §5, trước buổi stg đầu.

### Hệ quả

- Tốt: tháng không buổi bớt ~$17,4; phần chuẩn ngành vẫn trong code, bật lại bằng file cờ; buổi mặc định ngắn hơn.
- Xấu: §7; buổi prd thêm hai lượt áp ba root và trả lượt bật lại; stg và prd giữa các buổi không thử Security Hub,
  Config, Inspector; lỗi chỉ lộ khi chấm posture chờ tới buổi prd; quên đổi cờ trước buổi thì buổi prd chạy với giá trị
  rẻ.
- Xem lại khi: prd chạy đều (≥ 1 buổi mỗi tháng) hay chạy lâu dài, hoặc có dữ liệu người dùng thật (prd về giá trị
  production); tháng có ≥ 2 buổi stg thành thường lệ (AMG `always` ở stg, như 0071 §3); buổi prd tìm ra cấu hình sai mà
  chấm posture ở stg đã bắt được (bật Security Hub, Config cho buổi stg); org chuyển Security Hub sang declarative
  policy.

## Xác nhận

- Kiểm tĩnh ở `svp-infra`: `make test DIRS='aws/modules/paid-features'` khớp cả file của §1; `make session-test` đọc
  file thật; `bash aws/scripts/verify-test.sh` có ca `svp-backup` `off`.
- Sau áp: plan lần hai `No changes` ở `aws/security`, `aws/baseline`, `aws/accounts/<env>`; Security Hub `disabled` và
  không recorder ở management, `svp-log-archive`, `svp-backup`, stg, prd; registry prd `BASIC`; `svp-security` vẫn chấm
  FSBP, CIS.
- Buổi prd: plan của bước đổi cờ chỉ chạm tài nguyên của bốn cờ; phép kiểm 0071 §12 chạy sau đó.
- Lúc chấp nhận §5 (`off`) và §6 (phép kiểm `lõi`, `chuẩn ngành`) chưa hiện thực; thứ tự theo §10.

## Hiện thực ở

- `svp-infra`: `aws/paid-features.json`, `aws/modules/paid-features/tests/` (§1, §2); `aws/scripts/verify.sh` (§1:
  `svp-backup` có thể `off`); `docs/runbooks/paid-features.md`, `session-prd.md` (§3); `infracost.yml` (§8). §5, §6:
  chưa hiện thực.
- Repo code: `docs/explanation/paid-features.md`, `environments.md`, `aws-security.md`, `docs/threat-model.md` (ORG-6),
  `docs/runbooks/security-alert.md` (§7).

## Nguồn

Đọc 2026-11-16; cùng nguồn của [phụ lục 0071](appendix/0071-paid-features.md#nguồn), giữ số [N…] của nó.

- [N3] <https://docs.aws.amazon.com/securityhub/latest/userguide/configuration-policies-overview.html>
- [N5] <https://docs.aws.amazon.com/securityhub/latest/userguide/securityhub-prereq-config.html>
- [N6] <https://docs.aws.amazon.com/securityhub/latest/userguide/securityhub-disable.html>
- [N9] <https://docs.aws.amazon.com/inspector/latest/user/deactivate-scans.html>

## Thông tin thêm

Phụ lục: [`appendix/0078-paid-features-lean-defaults.md`](appendix/0078-paid-features-lean-defaults.md) (bảng xét lại,
chi phí).
