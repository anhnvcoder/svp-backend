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
   commit status trên `svp-gitops`, tin nhắn sync lỗi hay Degraded qua kênh Telegram của Alertmanager. Token là của GitHub App
   riêng `svp-argocd-notifier` (chỉ **Commit statuses: Read and write**, cài chỉ trên `svp-gitops`), không thêm quyền cho
   `svp-gitops-promoter`: App đó ghi được nội dung `svp-gitops`, khoá của nó không được vào cluster (threat model SEC-8). Khoá vào
   Secret `argocd/argocd-notifications-secret` (khoá `github-appID`, `github-installationID`, `github-privateKey`, `telegram-token`)
   qua External Secrets ([ADR-0026](0026-secrets-gitops.md)), bật bằng dữ liệu (`externalSecrets.argocdNotifications` của chart
   `svp-cluster`, mặc định tắt) chỉ trên nền tảng có cluster chạy cả buổi, nên cluster dựng tạm của runner không rắc status lên
   commit. Values Argo CD của nền tảng ở `platforms/<platform>/argo-cd.yaml` của `svp-gitops`, đọc sau `base/argo-cd.yaml`.
   Chỉ root `svp-root` báo (nhãn `svp.io/notify=root`, subscription ở values đó): root `Healthy` khi mọi wave con đã sync và
   `Healthy`, nên mỗi commit của `svp-gitops` có một status `argocd/<env>` cho cả môi trường, không một status mỗi Application.
   Chat Telegram không vào repo public: bootstrap gắn subscription Telegram lên root bằng annotation khi `.env` có token và chat
   id hợp lệ (cùng luật receiver của Alertmanager); thiếu thì chỉ có commit status.

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
- Secret `argocd/argocd-notifications-secret` dựng được từ nguồn, controller ESO chỉ ghi được Secret đó ở `argocd`: `make eks-secrets`, rồi
  `make drill-k8s-threats` SEC-5 (ba ca của `argocd`) trên cluster có entry bật; chưa kiểm.
- Commit status `argocd/stg` trên commit của `svp-gitops` và tin nhắn Telegram khi sync lỗi hay `Degraded`: buổi EKS stg; chưa kiểm.

Bảng đầy đủ ở [phụ lục](appendix/0032-argocd-deploy-status.md#kiểm-chứng-bảng-đầy-đủ).

## Hiện thực ở

- `deploy/helm/svp-observability/templates/argocd.yaml`: PodMonitor `argocd-application-controller`.
- `deploy/helm/svp-observability/values.yaml` (`argocd`): namespace, nhãn pod, cổng metric.
- `deploy/helm/svp-observability/templates/networkpolicies.yaml` (policy `prometheus`): egress sang `argocd` cổng 8082.
- `deploy/observability/prometheus/rules/svp-alerts.yaml` (nhóm `argocd`), `svp-alerts.test.yaml`: hai cảnh báo và test.
- `docs/runbooks/argocd-application-degraded.md`: runbook của cả hai cảnh báo.
- `deploy/k8s/drills/gitops/argocd-metrics/` (test `gitops-argocd-metrics` của `make drill-k8s-gitops`).
- A và B, phần repo code:
  - `deploy/helm/svp-cluster/files/external-secrets.yaml` (entry `argocd/argocd-notifications-secret`, `enabledBy:
    argocdNotifications`, `sharedNamespace: true`), `values.yaml` (`externalSecrets.argocdNotifications`),
    `templates/external-secrets.yaml` (ValidatingAdmissionPolicy `svp-external-secrets-writes`: ở `argocd` chỉ Secret đó, Opaque).
  - `deploy/k8s/secrets.sh` (nguồn `svp-secrets/argocd-notifications` từ ba biến `SVP_ARGOCD_NOTIFY_*` của `.env` khi entry bật),
    `.env.example`.
  - `deploy/k8s/gitops.sh` (Argo CD với `platforms/<platform>/argo-cd.yaml` sau `base/argo-cd.yaml`; bật nguồn theo values của
    `svp-cluster`; chat Telegram lên root), `deploy/k8s/lib.sh` (`argocd_root_app`: nhãn `svp.io/notify=root`;
    `argocd_root_telegram`), `deploy/ci/gitops-check.sh` (render Argo CD với file đó, đếm ExternalSecret theo `enabledBy`).
  - `deploy/k8s/drills/gitops/external-secrets/` (test `gitops-external-secrets`: entry `enabledBy` chỉ khi Argo CD render nó),
    `deploy/k8s/drills/threats/sec-5-6-7/` (SEC-5, ba ca của `argocd`).
  - `docs/runbooks/argocd-notifier-key-rotation.md`: xoay khoá App, nghi khoá lộ.
- A và B, phần `svp-gitops`: `platforms/eks/argo-cd.yaml` (service, template, trigger, subscription theo nhãn của root),
  `platforms/eks/svp-cluster.yaml` (`externalSecrets.argocdNotifications: true`); `base/argo-cd.yaml` giữ notifications tắt cho k3d.

## Thông tin thêm

Phụ lục: [`appendix/0032-argocd-deploy-status.md`](appendix/0032-argocd-deploy-status.md).

### Chỉnh bởi

- Kết quả quyết định, đợt 2: [0048](0048-prd-aws.md): trên EKS nhãn `svp.io/notify: root` và người nhận Telegram của root do ApplicationSet `svp-bootstrap` đặt (chat id từ annotation của cluster Secret mà Terraform ghi), không qua `gitops.sh`.
