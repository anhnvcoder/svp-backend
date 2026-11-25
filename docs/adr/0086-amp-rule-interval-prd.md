# 0086. prd chạy luật trên AMP mỗi 30 s như stg, không chờ quota 15 s

- Trạng thái: Chấp nhận
- Ngày: 2026-11-25
- Người quyết: người học (2026-11-25: prd không chờ case Support), AI ghi lý do và số đo

## Bối cảnh và vấn đề

- [0080](0080-amp-rule-interval-stg.md) §2, §5 để stg chạy 30 s (quota mặc định) và prd giữ 15 s, nên quota 15 s của account prd phải
  được duyệt trước buổi prd. Quota "Rule evaluation interval" mặc định 30 s, chỉnh được, là chu kỳ tối thiểu của một nhóm luật mỗi
  workspace [N1]; xin 15 là xin giảm nên API Service Quotas từ chối, đường còn lại là case Support.
- Case Support xin 15 s cho stg vẫn `Unassigned` sau nhiều ngày. Buổi prd không được chờ một case không ai nhận.
- Luật SLO là burn rate nhiều cửa sổ, nhỏ nhất 5 phút; phép đo của 0080 §3 cho 30 s chỉ thêm tối đa 15 s trễ cho luật đọc thẳng metric
  và không luật nào mất cảnh báo ngoài một trường hợp biên của `CircuitBreakerOpen`. AMP còn trễ mọi lần đánh giá `rule_query_offset`,
  mặc định 60 s [N2].

## Yếu tố quyết định

- Buổi prd chạy được với quota mặc định, không phụ thuộc case Support.
- stg và prd giống nhau: kiểm chu kỳ ở stg chứng minh được cho prd (0055 §1: khác biệt chỉ vì chi phí hay điều kiện tạm).
- Cái giá nhỏ và đo được (0080 §3); chart, luật và bộ test không đổi.

## Phương án đã cân nhắc

- Chờ case 15 s: prd hoãn không hạn.
- **Overlay prd đặt `30s`:** một file dữ liệu như stg, không đổi chart; mất: hai overlay giống nhau tới khi chart đổi mặc định.
- Đổi mặc định của chart `rules.amp.interval` thành `30s`, bỏ cả hai overlay: gọn hơn, nhưng đổi chart cần phát hành và promote trước
  buổi prd; k3d, compose không đọc value nên không ảnh hưởng. Hướng sau khi chart có bản phát hành kế.
- Viết lại luật cho không phụ thuộc chu kỳ: sửa luật, bộ test và runbook mà phép đo không đòi.

## Kết quả quyết định

Chọn overlay prd `30s`, vì buổi prd không chờ case và cái giá đã đo ở 0080 §3. Thay phần prd của 0080: §2 (prd không có overlay,
chạy mặc định 15 s), §4 (kiểm bù: buổi prd kiểm 15 s), §5 (prd cần quota 15 s), và phương án "30 s mọi env" bị 0080 loại.

### 1. prd 30 s

- `envs/prd/svp-observability.yaml` của `svp-gitops` đặt `rules.amp.interval: "30s"`, như `envs/stg/svp-observability.yaml`; chart giữ
  mặc định `15s` cho k3d, compose và bộ test của luật.
- `quota_table` của `preflight.sh` đặt cả stg và prd `max 30`: quota mặc định đạt, `quotas prd request` không xin gì cho AMP.
- Runbook `platform-setup.md` bước (8) không còn case Support của quota AMP; buổi prd kiểm chu kỳ `30`.

### 2. Cái giá, như stg

Cảnh báo prd cháy chậm hơn tối đa ~15 s (luật đọc thẳng metric) đến ~30 s (burn rate SLO; lần cháy đầu tới ~45 s) cộng
`rule_query_offset`; `CircuitBreakerOpen` có thể không cháy cho đợt không đóng đúng 6 mẫu. Lý do chấp nhận: 0080 §3.

### Hệ quả

- Tốt: không còn quota nào của AMP chặn buổi prd; prd và stg cùng chu kỳ.
- Xấu: prd chạy chu kỳ khác compose, k3d và bộ test của luật (15 s), cảnh báo chậm hơn như 0080 §3.
- Xem lại khi: chart đổi mặc định sang `30s` (bỏ cả hai overlay); thêm luật mà điều kiện đúng ngắn hơn 30 s; AWS cho quota chu kỳ
  dưới 30 s mà một luật cần.

## Xác nhận

- `make helm-check` render chart với overlay prd của `svp-gitops`; kiểm tay khi đổi chart: `helm template` với overlay ra `interval: 30s`.
- `make test` của `svp-infra`: `preflight-test.sh` đọc prd `max 30` (30 đạt, 60 đỏ, không yêu cầu quota AMP).
- Buổi prd: hai `RuleGroupsNamespace` `ACK.ResourceSynced` với quota mặc định, chu kỳ `30` ở phép kiểm luật trên AMP.

## Hiện thực ở

- `svp-gitops`: `envs/prd/svp-observability.yaml`, `envs/stg/svp-observability.yaml` (§1).
- `svp-infra`: `aws/scripts/preflight.sh` (`quota_table`), `docs/runbooks/platform-setup.md` (bước 8) (§1).
- Repo này: `docs/explanation/environments.md` (dòng chu kỳ luật).

## Nguồn

Đọc 2026-11-21 (câu trích của [N1], [N2] ở phụ lục của 0080; trang không đọc lại ngày ra quyết định).

- [N1] AMP quotas: <https://docs.aws.amazon.com/prometheus/latest/userguide/AMP_quotas.html>
- [N2] AMP workspace configuration: <https://docs.aws.amazon.com/prometheus/latest/userguide/AMP-workspace-configuration.html>

## Thông tin thêm

Phép đo ở 30 s: [phụ lục của 0080](appendix/0080-amp-rule-interval-stg.md#phép-đo).
