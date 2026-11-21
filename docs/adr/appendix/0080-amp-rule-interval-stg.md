# Phụ lục ADR-0080: Luật trên AMP của stg đánh giá mỗi 30 s, prd giữ 15 s; chu kỳ là value `rules.amp.interval`

Phụ lục của [ADR-0080](../0080-amp-rule-interval-stg.md): câu bị thay, quota đọc lại, phép đo `promtool` ở 30 s và bảng từng luật.
Phép đo chạy ngày 2026-11-21 trên `svp-alerts.yaml`, `slo-generated.yaml`, `svp-alerts.test.yaml` của `main` lúc đó.

## Câu bị thay

ADR-0063 §5, nguyên văn:

> **Chu kỳ 15 s như k3d**: chart ghi `interval: 15s` vào mỗi nhóm. Quota AMP tối thiểu 30 s, chỉnh được [N6]: người học xin 15 s cho hai
> account trước buổi đầu; không được thì không bật luật trên AMP với 30 s (đổi nghĩa cửa sổ 45 s, `RateLimitFallbackActive`), quyết lại
> bằng ADR mới.

Phụ lục ADR-0063, mục "Chu kỳ và độ trễ", nguyên văn:

> AWS không duyệt thì không bật luật trên AMP với 30 s: chu kỳ đổi nghĩa của `RateLimitFallbackActive` (cửa sổ 2 m phải dài hơn `for`
> cộng hai lần đánh giá) và cửa sổ 45 s; quyết lại bằng ADR mới.

ADR-0080 thay hai câu đó: stg bật luật trên AMP với 30 s; phép đo dưới đây cho thấy cửa sổ 45 s và `RateLimitFallbackActive` vẫn cháy.
Câu "chart ghi `interval: 15s`" thành "chart ghi `rules.amp.interval`, mặc định `15s`".

## Quota

Trang AMP quotas, đọc 2026-11-21, bảng cột `Name | Default | Adjustable | Description`, nguyên văn:

> Rule evaluation interval | Each supported Region: 30 | Yes | The minimum rule evaluation interval of a rule group per workspace, in
> seconds.

`rule_query_offset` (trang AMP workspace configuration, cùng ngày): "The default value for new workspaces is 60 seconds"; "A rule query
offset delays rule evaluations and any resulting alerts by the configured duration."

## Phép đo

Mọi lệnh chạy ngoài repo, trên bản sao tạm, cùng image và cách gọi của target `slo-check` (`deploy/compose/compose.mk`):

```sh
tmp=$(mktemp -d)
cp -RL deploy/observability/prometheus/rules "$tmp/rules"
sed -i '' 's/^evaluation_interval: 15s$/evaluation_interval: 30s/' "$tmp/rules/svp-alerts.test.yaml"
env -u DOCKER_DEFAULT_PLATFORM docker run --rm --network none -v "$tmp/rules":/otel-lgtm/svp-rules:ro \
  --workdir /otel-lgtm/svp-rules --entrypoint /otel-lgtm/prometheus/promtool "$LGTM_IMAGE" test rules svp-alerts.test.yaml
```

`LGTM_IMAGE` là giá trị ghim trong `compose.mk`. Kết quả: exit 1, 11 lần kiểm đỏ ở 9 test case, mọi `promql_expr_test`
(recording rule, SLO) xanh.

Bộ test dò: một script đọc `svp-alerts.test.yaml` và viết, cho mỗi test case có `alert_rule_test`, hai file (15 s, 30 s) giữ nguyên
`input_series`, thay `alert_rule_test` bằng lưới `eval_time` cách nhau đúng một chu kỳ, từ 0 tới `eval_time` lớn nhất cộng 120 s, mỗi điểm
`exp_alerts: []`. promtool in phần `got` ở mỗi điểm cảnh báo cháy, tức dòng thời gian cháy. Dò thêm `CircuitBreakerOpen` với bộ ngắt
không đóng đúng 6 và 7 mẫu ở hai pha. Bản sao và script xoá sau phép đo.

promtool đánh giá luật trên lưới `evaluation_interval` từ 0; một `eval_time` không nằm trên lưới được kiểm theo lần đánh giá cuối không
sau nó (đọc từ kết quả: test đỏ ở 105 s khớp trạng thái của lần đánh giá 90 s).

### Chín test case đỏ ở 30 s

| Cảnh báo | `eval_time` của test | Mong đợi | 15 s: cháy, hết | 30 s: cháy, hết | Vì sao đỏ |
| --- | --- | --- | --- | --- | --- |
| `CircuitBreakerOpen` | 105 s | cháy | 105 s, 135 s | 120 s, 150 s | lệch: cháy ở lần đánh giá 120 s |
| `CircuitBreakerOpen` | 135 s | không | 105 s, 135 s | 120 s, 150 s | lệch: lần đánh giá 120 s còn cháy, hết ở 150 s |
| `BackgroundLoopStalled` `outbox-relay` | 195 s | cháy | 195 s, 270 s | 210 s, 270 s | lệch: cháy ở 210 s |
| `BackgroundLoopStalled` `outbox-cleanup` | 1 995 s | cháy | 1 995 s, 2 070 s | 2 010 s, 2 070 s | lệch: cháy ở 2 010 s |
| `BackgroundLoopStalled` `upload-sweep` | 1 155 s | cháy | 1 155 s, 1 230 s | 1 170 s, 1 230 s | lệch: cháy ở 1 170 s |
| `BackgroundLoopStalled` `timeline-prune` | 11 475 s | cháy | 11 475 s, 11 550 s | 11 490 s, 11 550 s | lệch: cháy ở 11 490 s |
| `RateLimitFallbackActive` | 105 s | cháy | 105 s, 165 s | 120 s, 180 s | lệch: cháy ở 120 s |
| `RateLimitFallbackActive` | 165 s | không | 105 s, 165 s | 120 s, 180 s | lệch: lần đánh giá 150 s còn cháy, hết ở 180 s |
| `KafkaDLQRecords` | 75 s | cháy | 75 s, 660 s | 90 s, 660 s | lệch: cháy ở 90 s |
| `OutboxRowsFailed` | 75 s | cháy | 75 s, 660 s | 90 s, 660 s | lệch: cháy ở 90 s |
| `KafkaConsumerLagHigh` | 135 s | cháy | 135 s, 210 s | 150 s, 210 s | lệch: cháy ở 150 s |

Hai dòng `CircuitBreakerOpen` và hai dòng `RateLimitFallbackActive` là hai lần kiểm của cùng một test case: 11 lần kiểm đỏ ở 9 test case.
Không test case nào đỏ vì luật không cháy hay cháy sai: mỗi cảnh báo mong đợi đều cháy, trễ tối đa 15 s; hết cháy trễ 0 hay 15 s.

### Dòng thời gian khác giữa 15 s và 30 s

Chỉ các test case có lúc cháy đầu hay lúc hết khác nhau, và các phép dò thêm; test case còn lại cho cùng lúc cháy đầu và lúc hết ở hai
chu kỳ, kể cả mọi test case mong đợi không cháy.

| Cảnh báo | Đầu vào của test | 15 s: cháy đầu | 30 s: cháy đầu | Ghi chú |
| --- | --- | --- | --- | --- |
| `CircuitBreakerOpen` | mở và nửa mở xen kẽ, đóng ở mẫu 135 s | 105 s | 120 s | cháy hai lần đánh giá ở 15 s, một ở 30 s |
| `CircuitBreakerOpen` | mở 8 mẫu liên tục rồi series dừng | 90 s | 90 s | hết cùng lúc (150 s) |
| `CircuitBreakerOpen` | không đóng đúng 6 mẫu (30–105 s) | 105 s | không cháy | điều kiện đúng ~15–25 s, lọt giữa hai lần đánh giá |
| `CircuitBreakerOpen` | không đóng đúng 6 mẫu (15–90 s) | 90 s | 90 s | pha khác: cháy |
| `CircuitBreakerOpen` | không đóng 7 mẫu, hai pha | 90 s, 105 s | 90 s, 120 s | luôn cháy |
| `BackgroundLoopStalled` (bốn vòng) | mẫu mới báo lần thành công cũ | ngưỡng + 15 s | ngưỡng + 30 s | hết cùng lúc |
| `RateLimitFallbackActive` | nhánh series mới, series sinh giữa hai lần đánh giá (45 s) | 105 s | 120 s | nhánh đúng tới 165 s; hết ở 165 s, 180 s |
| `RateLimitFallbackActive` | nhánh series mới, series sinh đúng lần đánh giá (120 s) | 180 s | 180 s | hết cùng lúc (240 s) |
| `RateLimitFallbackActive`, `RateLimitFallbackElevated` | nhánh `increase`, counter từ 0 s | 75 s | 90 s | |
| `KafkaDLQRecords`, `OutboxRowsFailed` | series mới | 75 s | 90 s | hết cùng lúc |
| `KafkaConsumerLagHigh` | lag 2 m | 135 s | 150 s | `for: 2m` đếm từ lần đánh giá đầu |
| `PostgresWALArchivingFailing` | lỗi lưu WAL | 450 s | 450 s | hết cùng lúc |
| `UptimeProbesAbsent` | probe mất | 1 185 s | 1 200 s | |
| `TLSCertExpiringSoon`, `TLSCertExpiryImminent` | cert sắp hết hạn | 5 415 s, 8 115 s | 5 430 s, 8 130 s | |
| `WebAvailabilityBudgetBurn` | lỗi từ 0 s | 30 s | 60 s | đọc recording rule của nhóm khác |
| `WebINPBudgetBurn` | INP chậm từ 0 s | 15 s | 60 s | như trên; series ghi bắt đầu ở 0 s nên lệch lớn nhất |

## Bảng từng luật

"Đếm mẫu" là luật đếm mẫu xuất (15 s) trong cửa sổ, không đếm lần đánh giá: chu kỳ 30 s không đổi điều kiện, chỉ đổi lúc nhìn thấy nó.

| Luật | Mức | Dựa vào chu kỳ thế nào | Hệ quả ở stg 30 s |
| --- | --- | --- | --- |
| `KafkaConsumerLagHigh` (hai luật) | page | `for: 2m`, `for: 20m` | lag phải kéo dài `for` cộng tới 30 s (thay 15 s) mới cháy |
| `RateLimitFallbackActive` | page | nhánh series mới đúng 120 s, `for: 1m` | cần ≤ 90 s, dư 30 s; luật "`for` cộng hai lần đánh giá" chạm biên 120 s |
| `RateLimitFallbackElevated` | ticket | cửa sổ 30 m, không `for` | cháy chậm hơn tối đa 15 s |
| `KafkaDLQRecords`, `OutboxRowsFailed` | page | cửa sổ 10 m, nhánh `offset 10m` | cháy chậm hơn tối đa 15 s |
| `CircuitBreakerOpen` | page | đếm mẫu `[80s] >= 5`; lọc 45 s | đợt không đóng đúng 6 mẫu có thể lọt; từ 7 mẫu luôn cháy |
| `BackgroundLoopStalled` (bốn luật) | page | đếm mẫu `span + 20 s`; lọc 45 s | cháy chậm hơn tối đa 15 s |
| Lọc gauge `timestamp(x) > time() - 45` | — | tuổi mẫu theo chu kỳ xuất | series sống luôn qua; instance đã dừng hết chậm hơn tối đa 15 s |
| `PostgresWALArchivingFailing`, `PostgresBackupTooOld` | page, ticket | `for: 5m`, `for: 1h`, ngưỡng giờ | không đổi nghĩa; Postgres trong cluster chỉ ở k3d |
| `ArgoCDApplicationDegraded`, `ArgoCDApplicationNotConverged` | page, ticket | `for: 10m`, `for: 30m` | `for` cộng tới 30 s |
| `UptimeProbesAbsent`, `TLSCertExpiringSoon`, `TLSCertExpiryImminent` | page, ticket | `absent_over_time [5m]`, `for` 5 m, 1 h, 15 m | `for` cộng tới 30 s |
| Recording rule `svp-cost` | — | không cửa sổ | không đổi |
| 13 cảnh báo burn rate của `slo-generated.yaml` | page, ticket | đọc recording rule của nhóm khác; cửa sổ nhỏ nhất 5 m | chậm hơn tới ~30 s; lần cháy đầu tới ~45 s |
