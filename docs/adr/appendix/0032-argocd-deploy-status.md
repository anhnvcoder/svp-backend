# Phụ lục ADR-0032: các lựa chọn, kiểm chứng, trạng thái gốc

Phụ lục của [ADR-0032](../0032-argocd-deploy-status.md), nguyên văn phần chuyển ra khi rút gọn ADR theo mẫu.

## Trạng thái gốc

- Trạng thái: Chấp nhận (người học duyệt 2026-10-30, chọn A + B + C); phần C đã hiện thực, kiểm trên runner sau khi bản chart có
  nó được promote lên stg (mục Kiểm chứng sau); A và B làm ở giai đoạn 7

## Các lựa chọn (bản đầy đủ)

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

## Kiểm chứng (bảng đầy đủ)

| Giả định | Phép kiểm | Kết quả |
| --- | --- | --- |
| Rule đúng: cháy sau 10 phút `Degraded`, đếm liền qua đổi nhãn, không cháy khi hồi trong 8 phút; ticket sau 30 phút `OutOfSync` hay `Suspended`; không series thì không cháy; Application bị gỡ (series hết) hay đang xoá (`operation="delete"`) không page | `make slo-check` (`promtool test rules`, `svp-alerts.test.yaml`) | Đạt (2026-10-30, trên máy; ca đang xoá đỏ khi bỏ bộ lọc `operation`) |
| Prometheus thấy mọi Application qua PodMonitor và policy mới, cả cụm Synced/Healthy thì không cảnh báo nào cháy | Bước `gitops-argocd-metrics` của kịch bản `gitops` (`verify.yml`); bước tự bỏ qua khi chart stg đang chạy chưa có PodMonitor | Chưa kiểm: chart có PodMonitor (`fa5af94`) tới `envs/stg/charts.yaml` ở commit `cb7ebf2` của `svp-gitops` (2026-10-30), nên bước không còn tự bỏ qua; chưa có lượt `gitops` nào sau đó. Commit ghim không có trong bản clone thì bước đỏ, không bỏ qua |
| Cảnh báo cháy thật khi một Application hỏng trên cluster | Chưa có diễn tập | Chưa kiểm |
