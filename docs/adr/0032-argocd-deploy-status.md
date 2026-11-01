# 0032. Argo CD báo ngược trạng thái triển khai: cảnh báo Prometheus ngay, commit status và tin nhắn khi có cluster chạy lâu dài

- Trạng thái: Chấp nhận (người học duyệt 2026-10-30, chọn A + B + C); phần C đã hiện thực, kiểm trên runner sau khi bản chart có
  nó được promote lên stg (mục Kiểm chứng sau); phần repo code của A và B (Secret `argocd/argocd-notifications-secret` qua External
  Secrets, values Argo CD theo nền tảng) đã viết, chưa kiểm trên EKS; cấu hình Notifications ở `svp-gitops` chưa có
- Ngày: 2026-10-30

## Bối cảnh

Từ phần 4 của giai đoạn 6b ([ADR-0025](0025-gitops-config-repo.md)) mô hình triển khai là **pull**: `images.yml` của repo code build,
ký rồi mở PR promote vào `svp-gitops`; check `gitops-ok` xanh thì PR tự merge; Argo CD **trong** cluster kéo `main` của `svp-gitops`
về và apply. CI không có quyền vào cluster.

Hệ quả: lượt CI xong khi PR promote merge, còn việc triển khai (pod mới lên, canary qua, migrate chạy) xảy ra sau, trong cluster.
Trên GitHub không có dấu hiệu nào cho biết bản đó có lên được hay không. Ở mô hình push (CI chạy `kubectl apply`/`helm upgrade`)
lỗi triển khai hiện ngay trong lượt Actions; ở đây nó chỉ thấy trong UI của Argo CD, mà UI đó chỉ mở được bằng port-forward
(threat model OPS-2). Lab hiện tắt hẳn thành phần thông báo của Argo CD (`notifications.enabled: false` ở `base/argo-cd.yaml` của
`svp-gitops`), và Prometheus không scrape Argo CD.

Hai môi trường của lab hôm nay đều dựng tạm trên runner rồi xoá (kịch bản `gitops` của `verify.yml`,
[ADR-0021](0021-deferred-verification-stage6b.md)); cluster chạy lâu dài chỉ có từ giai đoạn 7 (EKS stg, prd).

## Các lựa chọn

### A. Argo CD Notifications ghi commit status lên commit của `svp-gitops` (hiện hành)

- Được: người mở `svp-gitops` thấy ngay trên commit một dấu `argocd/<env>` (đang chạy, xanh, đỏ) cạnh `gitops-ok`, link sang
  Application. Thành phần có sẵn của Argo CD, không thêm công cụ.
- Mất: Argo CD cần một token GitHub chỉ có quyền ghi commit status trên `svp-gitops` (một Secret mới trong cluster). Không dùng
  GitHub Deployments cho việc này: environment `stg` của `svp-gitops` đang giữ bản ghi stg mà check prd đọc (ADR-0025), trộn hai
  loại thì check đọc nhầm. Trên cluster dựng tạm, mỗi lượt kiểm sẽ rắc status lên commit.

### B. Argo CD Notifications gửi tin nhắn (Telegram, Slack) khi sync lỗi hay Degraded (hiện hành)

- Được: báo ngay lúc lỗi, kèm tên Application và revision.
- Mất: thêm một kênh cấu hình riêng với Alertmanager; cùng lý do cluster dựng tạm như A.

### C. Cảnh báo Prometheus từ metric `argocd_app_info` (hiện hành)

- Được: đi qua đúng đường cảnh báo đã có (Alertmanager, runbook, `promtool` test); bắt cả lỗi xảy ra **sau** khi triển khai đã
  xanh (pod crash dần, tài nguyên bị xoá). Làm và kiểm được ngay trên cluster của runner.
- Mất: phải chờ `for` (10 phút) mới cháy; không gắn trạng thái vào commit.

### D. CI tự chờ Argo CD (`argocd app wait` trong job promote)

- Được: lỗi hiện ngay trong lượt Actions như mô hình push.
- Mất: CI phải có quyền gọi API của Argo CD, tức quyền vào cluster: mất đúng cái lợi bảo mật của mô hình pull. Cách cũ với GitOps.

### E. Kargo (mới nổi)

- Được: UI riêng cho việc promote qua từng môi trường, có bước kiểm.
- Mất: thay cả luồng promote đã có (ADR-0025), thêm một hệ thống phải vận hành.

## Quyết định

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
2. **A và B ở giai đoạn 7**, khi có cluster EKS chạy lâu dài: bật Notifications, commit status `argocd/<env>` bằng token chỉ quyền
   commit status trên `svp-gitops`, tin nhắn sync lỗi hay Degraded qua kênh Telegram của Alertmanager. Token là của GitHub App
   riêng `svp-argocd-notifier` (chỉ **Commit statuses: Read and write**, cài chỉ trên `svp-gitops`), không thêm quyền cho
   `svp-gitops-promoter`: App đó ghi được nội dung `svp-gitops`, khoá của nó không được vào cluster (threat model SEC-8). Khoá vào
   Secret `argocd/argocd-notifications-secret` (khoá `github-appID`, `github-installationID`, `github-privateKey`, `telegram-token`)
   qua External Secrets ([ADR-0026](0026-secrets-gitops.md)), bật bằng dữ liệu (`externalSecrets.argocdNotifications` của chart
   `svp-cluster`, mặc định tắt) chỉ trên nền tảng có cluster chạy cả buổi, nên cluster dựng tạm của runner không rắc status lên
   commit. Values Argo CD của nền tảng ở `platforms/<platform>/argo-cd.yaml` của `svp-gitops`, đọc sau `base/argo-cd.yaml`.

Không chọn D vì phá mô hình pull; không chọn E vì thay cả luồng promote.

## Hệ quả

- Được: một triển khai không lên được trên cluster GitOps thành cảnh báo có runbook trong 10 phút; đường dev và compose không đổi.
- Phải trả: một PodMonitor, một cổng mở thêm từ Prometheus sang `argocd`, hai rule và runbook; một bước kiểm trong kịch bản
  `gitops`. Cảnh báo không phủ trường hợp application controller chết (series biến mất, không gì cháy): Argo CD là một
  Application không quản chính nó, xem lại khi có cảnh báo theo trạng thái pod từ kube-state-metrics.
- Xem lại khi: có cluster chạy lâu dài (giai đoạn 7: làm A, B); cảnh báo cháy nhầm trên stg (một Application `OutOfSync` vĩnh viễn
  vì diff không đáng kể thì thêm `ignoreDifferences`, không nới rule).

## Kiểm chứng sau

| Giả định | Phép kiểm | Kết quả |
| --- | --- | --- |
| Rule đúng: cháy sau 10 phút `Degraded`, đếm liền qua đổi nhãn, không cháy khi hồi trong 8 phút; ticket sau 30 phút `OutOfSync` hay `Suspended`; không series thì không cháy; Application bị gỡ (series hết) hay đang xoá (`operation="delete"`) không page | `make slo-check` (`promtool test rules`, `svp-alerts.test.yaml`) | Đạt (2026-10-30, trên máy; ca đang xoá đỏ khi bỏ bộ lọc `operation`) |
| Prometheus thấy mọi Application qua PodMonitor và policy mới, cả cụm Synced/Healthy thì không cảnh báo nào cháy | Bước `gitops-argocd-metrics` của kịch bản `gitops` (`verify.yml`); bước tự bỏ qua khi chart stg đang chạy chưa có PodMonitor | Chưa kiểm: chart có PodMonitor (`fa5af94`) tới `envs/stg/charts.yaml` ở commit `cb7ebf2` của `svp-gitops` (2026-10-30), nên bước không còn tự bỏ qua; chưa có lượt `gitops` nào sau đó. Commit ghim không có trong bản clone thì bước đỏ, không bỏ qua |
| Cảnh báo cháy thật khi một Application hỏng trên cluster | Chưa có diễn tập | Chưa kiểm |
| Secret `argocd/argocd-notifications-secret` dựng được từ nguồn (khoá App giải base64 đúng), controller ESO chỉ ghi được Secret đó ở `argocd` | `make eks-secrets`, rồi `make drill-k8s-threats` SEC-5 (ba ca của `argocd`) trên cluster có entry bật | Chưa kiểm (buổi EKS) |
| Commit status `argocd/stg` hiện trên commit của `svp-gitops` mà Argo CD triển khai, đúng trạng thái và link Application | Một lượt promote trên EKS stg, đọc `gh api repos/anhnvcoder/svp-gitops/commits/<sha>/statuses` | Chưa kiểm (buổi EKS) |
| Tin nhắn Telegram tới khi sync lỗi hay Application `Degraded` | Làm hỏng một Application trên EKS stg | Chưa kiểm (buổi EKS) |

## Hiện thực ở

- `deploy/helm/svp-observability/templates/argocd.yaml`: PodMonitor `argocd-application-controller`.
- `deploy/helm/svp-observability/values.yaml` (`argocd`): namespace, nhãn pod, cổng metric.
- `deploy/helm/svp-observability/templates/networkpolicies.yaml` (policy `prometheus`): egress sang `argocd` cổng 8082.
- `deploy/observability/prometheus/rules/svp-alerts.yaml` (nhóm `argocd`), `svp-alerts.test.yaml`: hai cảnh báo và test.
- `docs/runbooks/argocd-application-degraded.md`: runbook của cả hai cảnh báo.
- `deploy/ci/verify/gitops.sh` (`gitops_argocd_metrics`, bước `gitops-argocd-metrics`).
- A và B, phần repo code:
  - `deploy/helm/svp-cluster/files/external-secrets.yaml` (entry `argocd/argocd-notifications-secret`, `enabledBy:
    argocdNotifications`, `sharedNamespace: true`), `values.yaml` (`externalSecrets.argocdNotifications`),
    `templates/external-secrets.yaml` (ValidatingAdmissionPolicy `svp-external-secrets-writes`: ở `argocd` chỉ Secret đó, Opaque).
  - `deploy/k8s/secrets.sh` (nguồn `svp-secrets/argocd-notifications` từ ba biến `SVP_ARGOCD_NOTIFY_*` của `.env` khi entry bật),
    `.env.example`.
  - `deploy/k8s/gitops.sh` (Argo CD với `platforms/<platform>/argo-cd.yaml` sau `base/argo-cd.yaml`; bật nguồn theo values của
    `svp-cluster`), `deploy/ci/gitops-check.sh` (render Argo CD với file đó, đếm ExternalSecret theo `enabledBy`).
  - `deploy/ci/verify/gitops.sh` (`gitops-external-secrets`: entry `enabledBy` chỉ khi Argo CD render nó),
    `deploy/k8s/drills/threats.sh` (SEC-5, ba ca của `argocd`).
  - `docs/runbooks/argocd-notifier-key-rotation.md`: xoay khoá App, nghi khoá lộ.
- A và B, phần `svp-gitops`: chưa có; `base/argo-cd.yaml` vẫn `notifications.enabled: false`, chưa có
  `platforms/eks/argo-cd.yaml`.
