# 0032. Argo CD báo ngược trạng thái triển khai: cảnh báo Prometheus ngay, commit status và tin nhắn khi có cluster chạy lâu dài

- Trạng thái: Chấp nhận
- Ngày: 2026-10-30
- Người quyết: người học (chọn A + B + C)

## Bối cảnh và vấn đề

Triển khai theo mô hình **pull** ([ADR-0025](0025-gitops-config-repo.md)): `images.yml` của repo code build, ký rồi mở PR promote vào
`svp-gitops`; check `gitops-ok` xanh thì PR tự merge; Argo CD **trong** cluster kéo `main` của `svp-gitops` về và apply. CI không có quyền vào
cluster, nên lượt CI xong khi PR promote merge, còn việc triển khai (pod mới lên, canary qua, migrate chạy) xảy ra sau, trong cluster. Ở mô hình push (CI chạy `kubectl apply`/`helm upgrade`) lỗi
triển khai hiện ngay trong lượt Actions; ở đây trên GitHub không có dấu hiệu nào cho biết bản đó có lên được không; lỗi chỉ thấy trong UI của Argo CD, mà UI đó chỉ mở bằng port-forward
(threat model OPS-2). Thành phần thông báo của Argo CD đang tắt (`notifications.enabled: false` ở `base/argo-cd.yaml` của `svp-gitops`) và
Prometheus không scrape Argo CD. Cluster của lab dựng tạm trên runner rồi xoá (kịch bản `gitops` của `verify.yml`,
[ADR-0021](0021-deferred-verification-stage6b.md)); cluster chạy lâu dài chỉ có ở EKS (stg, prd).

## Yếu tố quyết định

- Giữ mô hình pull: CI không có quyền vào cluster.
- Báo lỗi triển khai qua đường cảnh báo và runbook đã có, kiểm được trên cluster của runner.
- Không thêm hệ thống phải vận hành; mỗi token có quyền nhỏ nhất.

## Phương án đã cân nhắc

- **A. Argo CD Notifications ghi commit status `argocd/<env>` lên commit của `svp-gitops`**: thấy ngay trên commit cạnh `gitops-ok`; cần token chỉ quyền commit status, cluster dựng tạm rắc status lên commit.
- **B. Argo CD Notifications gửi tin nhắn (Telegram) khi sync lỗi hay Degraded**: báo ngay lúc lỗi; thêm một kênh cấu hình riêng với Alertmanager.
- **C. Cảnh báo Prometheus từ `argocd_app_info`**: đi qua Alertmanager, runbook, `promtool` test, bắt cả lỗi sau khi triển khai đã xanh; chờ `for` 10 phút, không gắn vào commit.
- D. CI tự chờ Argo CD (`argocd app wait` trong job promote): lỗi hiện ngay trong lượt Actions; CI phải có quyền vào cluster, mất lợi bảo mật của pull.
- E. Kargo: UI promote theo môi trường có bước kiểm; thay cả luồng promote ([ADR-0025](0025-gitops-config-repo.md)), thêm hệ thống phải vận hành.

Bản đầy đủ từng phương án ở [phụ lục](appendix/0032-argocd-deploy-status.md#các-lựa-chọn-bản-đầy-đủ).

## Kết quả quyết định

Chọn **A + B + C**, theo hai đợt:

Chọn **A + B + C**, theo hai đợt:

1. **C làm ngay.** Prometheus scrape application controller của Argo CD (PodMonitor `argocd-application-controller` trong
   `svp-obs`, chỉ giữ `argocd_app_info`; policy `prometheus` mở egress tới cổng 8082 của pod đó, phía `argocd` policy ingress của
   chart argo-cd 10.10.5 đã nhận cổng `metrics` của controller từ mọi namespace). Hai cảnh báo:
   - `ArgoCDApplicationDegraded` (`severity=page`): Application ở health `Degraded`, `Missing` hay `Unknown` liền 10 phút, trừ
     Application đang bị xoá (`operation="delete"`: bỏ khỏi `components.json`, finalizer xoá những gì nó đã triển khai).
     Argo CD v3.5.5 không tính tài nguyên chưa tạo được vào health của Application (chỉ `OutOfSync`), nên `Missing` là khi
     không tài nguyên nào của nó còn; sync không áp được thì page tới từ root `svp-root`, `Degraded` khi sync của Application
     con đã `Failed` hẳn (health check của Application con trong `base/argo-cd.yaml` của `svp-gitops`).
   - `ArgoCDApplicationNotConverged` (`severity=ticket`): Application không `Synced` hay vẫn `Progressing`/`Suspended` liền 30 phút.

   Gộp theo `name`, `dest_namespace` để một Application đổi nhãn trạng thái (`Degraded` sang `Missing`) vẫn đếm liền. Metric được
   scrape (có staleness marker khi pod mất), nên dùng `for` an toàn, khác các gauge đẩy qua OTLP. Compose và đường dev không có
   Argo CD: không có series, không cảnh báo nào cháy.
2. **A và B khi có cluster EKS chạy lâu dài**: bật Notifications, commit status `argocd/<env>` bằng token chỉ quyền
   commit status trên `svp-gitops` (một GitHub App riêng hay quyền thêm cho App hiện có, chốt lúc làm), tin nhắn sync lỗi hay
   Degraded qua kênh Telegram của Alertmanager.

Không chọn D vì phá mô hình pull; không chọn E vì thay cả luồng promote.

### Hệ quả

- Được: một triển khai không lên được trên cluster GitOps thành cảnh báo có runbook trong 10 phút; đường dev và compose không đổi.
- Phải trả: một PodMonitor, một cổng mở thêm từ Prometheus sang `argocd`, hai rule và runbook; một bước kiểm trong kịch bản
  `gitops`. Cảnh báo không phủ trường hợp application controller chết (series biến mất, không gì cháy): Argo CD là một
  Application không quản chính nó, xem lại khi có cảnh báo theo trạng thái pod từ kube-state-metrics.
- Xem lại khi: có cluster chạy lâu dài (làm A, B); cảnh báo cháy nhầm trên stg (một Application `OutOfSync` vĩnh viễn
  vì diff không đáng kể thì thêm `ignoreDifferences`, không nới rule).

## Xác nhận

- Rule đúng (cháy sau 10 phút `Degraded`, đếm liền qua đổi nhãn, ticket sau 30 phút, không page khi Application bị gỡ hay đang xoá):
  `make slo-check` (`promtool test rules`, `svp-alerts.test.yaml`), đạt 2026-10-30.
- Prometheus thấy mọi Application qua PodMonitor và policy mới: bước `gitops-argocd-metrics` của kịch bản `gitops` (`verify.yml`); chưa có
  lượt `gitops` nào kiểm.
- Cảnh báo cháy thật khi một Application hỏng trên cluster: chưa có diễn tập.

Bảng đầy đủ ở [phụ lục](appendix/0032-argocd-deploy-status.md#kiểm-chứng-bảng-đầy-đủ).

## Hiện thực ở

- `deploy/helm/svp-observability/templates/argocd.yaml`: PodMonitor `argocd-application-controller`.
- `deploy/helm/svp-observability/values.yaml` (`argocd`): namespace, nhãn pod, cổng metric.
- `deploy/helm/svp-observability/templates/networkpolicies.yaml` (policy `prometheus`): egress sang `argocd` cổng 8082.
- `deploy/observability/prometheus/rules/svp-alerts.yaml` (nhóm `argocd`), `svp-alerts.test.yaml`: hai cảnh báo và test.
- `docs/runbooks/argocd-application-degraded.md`: runbook của cả hai cảnh báo.
- `deploy/ci/verify/gitops.sh` (`gitops_argocd_metrics`, bước `gitops-argocd-metrics`).
- A và B: chưa có (cluster EKS chạy lâu dài); `base/argo-cd.yaml` của repo `svp-gitops` vẫn `notifications.enabled: false`.

## Thông tin thêm

Phụ lục: [`appendix/0032-argocd-deploy-status.md`](appendix/0032-argocd-deploy-status.md).
