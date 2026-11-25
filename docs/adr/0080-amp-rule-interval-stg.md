# 0080. Luật trên AMP của stg đánh giá mỗi 30 s, prd giữ 15 s; chu kỳ là value `rules.amp.interval`

- Trạng thái: Chấp nhận
- Ngày: 2026-11-21
- Người quyết: AI quyết thay người học theo uỷ quyền (2026-11-21: buổi stg chạy với quota mặc định của AMP, không chờ case Support)

## Bối cảnh và vấn đề

- [0063](0063-managed-observability.md) §5 chốt chu kỳ 15 s như k3d cho luật trên AMP, cần quota của account nâng xuống 15 s; AWS không
  duyệt thì quyết lại bằng ADR mới. ADR này là ADR đó.
- Case Support xin quota 15 s cho account stg chưa có người xử lý. Quota "Rule evaluation interval" mặc định 30 s, chỉnh được, là "the
  minimum rule evaluation interval of a rule group per workspace, in seconds" [N1]. Với quota mặc định, nhóm luật chu kỳ 15 s không
  hợp lệ: ACK không tạo được `RuleGroupsNamespace` và đường cảnh báo ACK → ruler → SNS của buổi stg hỏng.
- Chart ghi cứng `interval: 15s` vào mọi nhóm khi `rules.target: amp`; luật được viết và test ở 15 s (comment đầu `svp-alerts.yaml`,
  `svp-alerts.test.yaml`). AMP còn trễ mọi lần đánh giá `rule_query_offset`, 60 s cho workspace mới [N2].
- [0055](0055-environment-matrix.md) §1 chỉ cho stg khác prd ở nhóm giảm với lý do chi phí; lý do ở đây là quota của account.

## Yếu tố quyết định

- Buổi stg chạy được với quota mặc định và vẫn học đủ đường ACK → ruler → SNS → email.
- prd chạy đúng chu kỳ mà luật được thiết kế và test (15 s).
- Cái giá ở stg đo được, có số: cảnh báo chậm hơn, và một trường hợp biên của `CircuitBreakerOpen` (§3) được chấp nhận ở stg.
- Khác biệt là dữ liệu (value của chart, overlay của env), không `if env`; khác biệt có điều kiện kết thúc.

## Phương án đã cân nhắc

- Chờ quota: không đổi gì, nhưng buổi stg hoãn không hạn vì case chưa có người xử lý.
- **stg 30 s, prd 15 s:** buổi stg chạy ngay, prd giữ thiết kế; mất: một khác biệt stg/prd không vì chi phí, cảnh báo stg chậm hơn.
- 30 s mọi env: stg giống prd, không cần quota nào; mất: prd chạy chu kỳ khác compose, k3d và bộ test, cảnh báo prd chậm hơn mãi.
- Bỏ luật trên AMP ở stg, hay luật ở Prometheus trong cluster: mất đường ACK → ruler → SNS mà buổi stg cần học; luật chết cùng cluster
  (phương án 0063 đã loại).
- Viết lại luật cho không phụ thuộc chu kỳ: sửa luật, bộ test và runbook; phép đo (§3) chỉ thấy một trường hợp biên của một
  luật, chấp nhận được ở stg.

## Kết quả quyết định

Chọn stg 30 s, prd 15 s, vì buổi stg chạy được ngay mà prd không đổi thiết kế; cái giá chỉ ở stg và tạm thời. Câu của 0063 §5 và phụ lục
0063 bị thay, nguyên văn: [phụ lục](appendix/0080-amp-rule-interval-stg.md#câu-bị-thay).

### 1. Chu kỳ là value của chart

- `rules.amp.interval` của chart `svp-observability`, mặc định `15s`: khi `rules.target: amp` chart ghi nó làm `interval` của mọi nhóm
  trong hai `RuleGroupsNamespace`. Giá trị phải khớp `^[1-9][0-9]*(s|m)$`, sai thì render `fail` nêu value và giá trị.
- `rules.target: prometheus` (k3d) không đọc value: Prometheus trong cluster, compose giữ 15 s.

### 2. stg 30 s, prd 15 s

- Overlay `envs/stg/svp-observability.yaml` của `svp-gitops` đặt `30s`; prd không có overlay nên chạy mặc định `15s`.
- stg chạy 30 s chỉ khi `revision` chart của stg chứa commit thêm value; trước đó stg vẫn render 15 s.

### 3. Luật nhạy với chu kỳ

Đo bằng `promtool test rules` của image `slo-check` trên bản sao tạm của thư mục luật với `evaluation_interval: 30s`, và một bộ test dò
thời điểm cháy ở 15 s và 30 s; lệnh, bảng từng luật, từng test case: [phụ lục](appendix/0080-amp-rule-interval-stg.md#phép-đo).

- Bộ test hiện có: 9 test case (11 lần kiểm) đỏ ở 30 s, mỗi cái là lệch thời điểm đánh giá của test: promtool chỉ đánh giá
  trên lưới 30 s nên cảnh báo cháy ở lần đánh giá kế (≤ 15 s sau) hay còn cháy tới lần kế. Không test case nào đỏ vì luật
  không cháy hay cháy sai.
- Bộ test dò, trên đầu vào của bộ test hiện có: mọi cảnh báo cháy ở 15 s đều cháy ở 30 s; không cảnh báo nào cháy ở
  30 s mà 15 s không cháy.
- `RateLimitFallbackActive`: nhánh `unless … offset 2m` đúng 120 s từ mẫu đầu của series; `for: 1m` cần lần đánh giá đầu thấy
  series (≤ 30 s) cộng 60 s, tức ≤ 90 s, còn dư 30 s (ở 15 s dư 45 s). Luật "dài hơn `for` cộng hai lần đánh giá" của comment
  chạm biên: 60 + 2 × 30 = 120 s.
- Luật gauge lọc mẫu mới hơn 45 s (`2 x 15 s export + 15 s evaluation`): tuổi mẫu của series sống phụ thuộc chu kỳ xuất 15 s,
  không phụ thuộc chu kỳ đánh giá, nên series sống luôn qua lọc; cảnh báo về instance đã dừng hết ở lần đánh giá đầu sau 45 s,
  chậm hơn tối đa 15 s.
- `CircuitBreakerOpen` (`count_over_time … [80s] >= 5`, `min_over_time … > 0`): đếm mẫu xuất, không đếm lần đánh giá; nhưng điều kiện chỉ
  đúng ~15–25 s khi bộ ngắt không đóng đúng 6 mẫu liên tiếp, nên ở 30 s đợt đó lọt tuỳ pha (đo: một pha không cháy); từ 7 mẫu luôn cháy.
- `BackgroundLoopStalled` (cửa sổ `span + 20 s`, `span / 15 + 1` mẫu), `KafkaDLQRecords`, `OutboxRowsFailed` (cửa sổ 10 m): đếm mẫu xuất,
  điều kiện đúng liên tục khi sự cố còn; chỉ cháy chậm hơn tối đa 15 s.
- Luật có `for` (`KafkaConsumerLagHigh`, Argo CD, Postgres, uptime, TLS): `for` bắt đầu đếm ở lần đánh giá đầu thấy điều kiện, nên điều
  kiện phải đúng `for` cộng tới một chu kỳ (30 s thay 15 s) mới cháy.
- Burn rate của `slo-generated.yaml` đọc recording rule của nhóm khác; mỗi nhóm chạy theo nhịp riêng, nên cảnh báo có thể đọc
  bản ghi của lần trước: ở trạng thái ổn định chậm hơn tới hai chu kỳ (60 s thay 30 s, tức ~30 s); lần cháy đầu sau khi series bắt
  đầu có thể chậm hơn (đo: +45 s, phụ lục). Cửa sổ nhỏ nhất 5 m, không luật SLO nào dựa vào 15 s.

### 4. Khác biệt tạm vì quota (chỉnh 0055 §1, §4)

- 0055 §1 thêm một lý do cho nhóm giảm có điều kiện: quota của account chưa được duyệt, khác biệt tạm, có điều kiện kết thúc.
- Dòng mới của nhóm giảm có điều kiện ở `environments.md`: chu kỳ luật trên AMP; mất gì: cảnh báo stg cháy chậm hơn, đợt sự cố ngắn
  (dưới ~30 s điều kiện đúng) có thể lọt; kiểm bù: buổi prd kiểm chu kỳ 15 s ở phép kiểm luật trên AMP.
- Kết thúc: quota 15 s của account stg được duyệt thì bỏ overlay, stg về 15 s như prd, xoá dòng của `environments.md`.

### 5. prd vẫn cần quota 15 s

prd chạy mặc định `15s`: quota 15 s của account prd phải được duyệt trước buổi prd (bước quota của runbook `platform-setup.md` của
`svp-infra`); chưa duyệt thì `RuleGroupsNamespace` của prd không tạo được, như stg trước ADR này.

### Hệ quả

- Tốt: buổi stg chạy với quota mặc định, đủ đường cảnh báo; prd và mọi env local giữ 15 s; chu kỳ đổi bằng value, không sửa chart.
- Xấu: stg khác prd ở chu kỳ; cảnh báo stg cháy chậm hơn tối đa ~15 s (luật đọc thẳng metric) đến ~30 s (burn rate SLO; lần cháy đầu tới
  ~45 s), hết chậm hơn tối đa 15 s, cộng `rule_query_offset` 60 s sẵn có; `CircuitBreakerOpen` có thể không cháy cho đợt không đóng đúng 6
  mẫu (~75–90 s) ở stg.
- Xem lại khi: quota 15 s của stg được duyệt (bỏ overlay); prd không được duyệt 15 s trước buổi prd (quyết lại cho prd bằng ADR mới); thêm
  luật mà điều kiện đúng ngắn hơn 30 s hay dựa vào số lần đánh giá.

## Xác nhận

- `make helm-check` render chart với overlay stg (không assert số); kiểm tay khi đổi chart: `helm template` ra `interval: 15s` khi không
  overlay, `30s` với overlay stg, value sai định dạng thì `fail` (card chart của PR).
- `make slo-check` giữ xanh ở 15 s; phép đo 30 s ở phụ lục chạy trên bản sao tạm, không có test 30 s trong repo.
- Buổi stg: hai `RuleGroupsNamespace` `ACK.ResourceSynced` với quota mặc định, một cảnh báo tới SNS. Buổi prd: chu kỳ 15 s ở phép kiểm luật.

## Hiện thực ở

- Repo này: `deploy/helm/svp-observability/values.yaml` (`rules.amp.interval`), `templates/prometheusrules.yaml` (§1, kiểm định dạng),
  `docs/explanation/environments.md` (§4).
- `svp-gitops`: `envs/stg/svp-observability.yaml` (§2).
- `svp-infra`: `aws/scripts/preflight.sh` (`quota_table`: stg tối đa 30, prd tối đa 15), `docs/runbooks/platform-setup.md` (§5).

## Nguồn

Đọc 2026-11-21.

- [N1] AMP quotas: <https://docs.aws.amazon.com/prometheus/latest/userguide/AMP_quotas.html>
- [N2] AMP workspace configuration: <https://docs.aws.amazon.com/prometheus/latest/userguide/AMP-workspace-configuration.html>
- [N3] Prometheus, alerting rules (`for`): <https://prometheus.io/docs/prometheus/latest/configuration/alerting_rules/>
- [N4] Prometheus, unit testing for rules: <https://prometheus.io/docs/prometheus/latest/configuration/unit_testing_rules/>

## Thông tin thêm

Phụ lục: [`appendix/0080-amp-rule-interval-stg.md`](appendix/0080-amp-rule-interval-stg.md) (câu bị thay, quota, phép đo, bảng từng luật).

### Chỉnh bởi

- §2, §4, §5, Phương án (30 s mọi env): [0086](0086-amp-rule-interval-prd.md): prd cũng chạy 30 s với overlay
  `envs/prd/svp-observability.yaml`; quota 15 s của account prd không còn cần.
