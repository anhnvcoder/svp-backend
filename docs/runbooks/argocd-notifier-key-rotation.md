# Xoay khoá GitHub App `svp-argocd-notifier`

- Quy trình làm tay, không có cảnh báo. Làm định kỳ, hay **ngay** khi nghi khoá riêng của App bị lộ (SEC-8 của
  [threat model](../threat-model.md)).
- Trạng thái: viết theo mã, chưa chạy thử; chạy lần đầu ở buổi EKS cùng phép kiểm của
  [ADR-0032](../adr/0032-argocd-deploy-status.md) (mục Kiểm chứng sau).
- **Không ghi giá trị nào** (khoá `.pem`, base64 của nó, token) vào repo, issue, PR hay chat. App ID và installation ID là định
  danh, không bí mật.

## Ý nghĩa và tác động tới người dùng

Argo CD Notifications ghi commit status `argocd/<env>` lên commit của `svp-gitops` bằng GitHub App `svp-argocd-notifier` (quyền chỉ
**Commit statuses: Read and write**, cài chỉ trên `svp-gitops`). Khoá riêng của App đi theo đường:

`.env` (`SVP_ARGOCD_NOTIFY_APP_ID`, `SVP_ARGOCD_NOTIFY_INSTALLATION_ID`, `SVP_ARGOCD_NOTIFY_PRIVATE_KEY_B64` = base64 một dòng của
file `.pem`) → `make eks-secrets` (`deploy/k8s/secrets.sh`) ghi nguồn `svp-secrets/argocd-notifications` → External Secrets Operator
dựng `argocd/argocd-notifications-secret` (khoá `github-appID`, `github-installationID`, `github-privateKey` đã giải base64,
`telegram-token`) → controller notifications của Argo CD đọc lại Secret mỗi khi nó đổi, không cần restart.

Chỉ cluster mà chart `svp-cluster` bật `externalSecrets.argocdNotifications` có Secret này (nền tảng `eks`); cluster k3d và đường dev
không có. Người dùng sản phẩm không thấy gì. Giữa lúc xoá khoá cũ và lúc Secret có khoá mới, commit status không được ghi (lỗi
nằm trong log của controller notifications); triển khai vẫn chạy, cảnh báo `ArgoCDApplication*` vẫn cháy qua Prometheus.

## Kiểm tra nhanh (5 phút)

Không in `.env`, không in khoá. `<ctx>` là alias của cluster (`svp-stg`):

```sh
# ba biến có trong .env (đếm, không in)
grep -c '^SVP_ARGOCD_NOTIFY_[A-Z_]*=.' .env                                     # 3
# App chỉ cài trên svp-gitops
gh api /user/installations --jq '.installations[]|select(.app_slug=="svp-argocd-notifier")|.id'
gh api /user/installations/<installation id>/repositories --jq '.repositories[].full_name'   # chỉ anhnvcoder/svp-gitops
# ExternalSecret Ready, Secret đủ bốn khoá (tên khoá, không giá trị)
kubectl --context <ctx> -n argocd get externalsecrets.external-secrets.io argocd-notifications-secret
kubectl --context <ctx> -n argocd get secret argocd-notifications-secret -o json | jq -r '.data | keys[]'
# lỗi gọi GitHub của controller notifications
kubectl --context <ctx> -n argocd logs deploy/argocd-notifications-controller --since=30m | grep -i -E 'github|401|403' | tail
```

Trang App https://github.com/settings/apps/svp-argocd-notifier, mục **Private keys**, cho biết có mấy khoá và ngày tạo từng khoá.

## Nguyên nhân thường gặp

Lý do xoay khoá:

1. Định kỳ: khoá dài hạn, không tự hết hạn.
2. Nghi lộ: khoá `.pem` còn nằm trong Downloads, `.env` bị chép đi, máy bị xâm nhập, hay một bản dump Secret của `argocd` rời cluster.
3. Status không còn được ghi: log controller có `401` (khoá đã xoá trên GitHub hay sai App ID), `403` hay `404` (App bị gỡ khỏi
   `svp-gitops`, mất quyền commit status).

## Giảm thiểu

**Nghi khoá lộ:** kẻ có khoá chỉ ghi được commit status giả lên `svp-gitops`, không ghi nội dung, nhánh hay PR, và `gitops-ok` là
check bắt buộc gắn với app GitHub Actions nên status giả không merge được gì (SEC-8). Chặn ngay: trang App → **Install App** →
cài đặt trên `anhnvcoder` → **Suspend** (mọi token của App ngừng chạy, status bị dừng tới khi unsuspend), rồi xoay khoá như dưới
(xoá khoá cũ ngay ở bước 1), rồi **Unsuspend**.

**Xoay định kỳ** (khoá mới chạy trước khi bỏ khoá cũ, không gián đoạn):

1. Trang App → **Private keys** → **Generate a private key**; GitHub tải file `.pem` xuống. Nghi lộ thì xoá luôn khoá cũ ở đây.
2. Ghi vào `.env` (mode 600) bằng trình soạn, thay giá trị `SVP_ARGOCD_NOTIFY_PRIVATE_KEY_B64` bằng output của
   `base64 < <file>.pem | tr -d '\n'` (`.env` không nhận giá trị nhiều dòng); xoá file `.pem`.
3. `make eks-secrets CONTEXT=<ctx>`: kiểm khoá (base64 chuẩn, PEM đọc được, không passphrase; sai thì dừng, không đổi Secret nào), ghi
   nguồn rồi dựng lại mọi ExternalSecret và chờ `Ready`.
4. Xác nhận như mục dưới, rồi mới xoá khoá cũ ở **Private keys** (xoay định kỳ).

## Khôi phục và xác nhận

- `kubectl --context <ctx> -n argocd get externalsecrets.external-secrets.io argocd-notifications-secret`: `Ready True`, thời điểm
  refresh sau bước 3.
- Lượt sync kế tiếp (hay một promote) ghi status mới: `gh api repos/anhnvcoder/svp-gitops/commits/<sha>/statuses --jq
  '.[] | select(.context | startswith("argocd/")) | {context, state, created_at}'` có dòng sau giờ xoay.
- Log controller notifications không còn `401`.

## Leo thang

- Status sai mà không rõ ai ghi (dòng `argocd/<env>` lạ trong lệnh `statuses`, `creator` là App): coi như khoá lộ, Suspend, mở
  postmortem ([mẫu](../postmortems/README.md)).
- `make eks-secrets` dừng ở kiểm khoá dù đã làm đúng bước 2: tạo khoá mới, không sửa tay base64.
- Gỡ hẳn: trang App → **Install App** → **Uninstall**, rồi **Advanced** → **Delete GitHub App**; tắt
  `externalSecrets.argocdNotifications` ở `svp-gitops` để chart không đòi Secret.

## Liên kết

- [ADR-0032](../adr/0032-argocd-deploy-status.md) (A, B), [ADR-0026](../adr/0026-secrets-gitops.md) (Secret qua External Secrets).
- Threat model SEC-5, SEC-6, SEC-8.
- `make drill-k8s-threats` SEC-5 kiểm controller ESO chỉ ghi được Secret này ở `argocd`; không có diễn tập xoay khoá.
