# Cluster EKS

Loại tài liệu (Diátaxis): **reference**, tra cứu khi cần một lệnh hay một quy tắc cụ thể; luật làm việc ở [`AGENTS.md`](../../AGENTS.md).

## Target `eks-*`

- Cluster EKS ([ADR-0034](../adr/0034-aws-stage7.md)), target `eks-*` ở `deploy/k8s/k8s.mk`: người học chạy (AI chỉ
  chạy test giả `deploy/k8s/eks-context-test.sh`), `CONTEXT=svp-stg|svp-prd` là alias của cluster trong kubeconfig (`aws eks
  update-kubeconfig --alias`), script nhận qua `SVP_KUBE_CONTEXT` (`kc`/`hc` của `deploy/k8s/lib.sh`: không đặt là `k3d-svp`, tên khác
  thì dừng trước mọi lệnh; chỉ `gitops.sh`, `secrets.sh`, `glitchtip-init.sh` được vào cluster cloud, hàm chỉ của k3d như registry, tạo
  cluster, CA, diễn tập từ chối `svp-*`); không qua `k8s-exclusive`. **LOCAL LAB ONLY:** `eks-smoke`, `eks-seed`, `eks-rl-reset` xoá
  khoá `svp:gw:rl:register:*` ở Valkey db 10 của cluster đó (qua `kubectl exec`), chỉ cho stg, prd của lab.
  - `make eks-gitops-up CONTEXT=… CLUSTER_VALUES=<file> [GITOPS_REV=main]`: `deploy/k8s/gitops.sh` trên cluster EKS, bỏ registry,
    cluster k3d và bước theo nhánh (cluster ở yên SHA đã kiểm); `CLUSTER_VALUES` (JSON của `terraform output -json cluster_values`)
    thiếu khoá, sai kiểu hay `name` khác context thì dừng trước mọi `kubectl`; root nhận `platform=eks` và `cluster`; namespace theo
    values của Application `svp-cluster` trong bản render root (`valueFiles` theo thứ tự rồi `valuesObject`); không xuất CA.
  - `make eks-secrets CONTEXT=…`: chỉ ghi Secret nguồn ở `svp-secrets` (thiếu namespace đó thì dừng), `pg-superuser` lấy từ biến môi
    trường `SVP_RDS_MASTER_PASSWORD` (bắt buộc, không đọc `.env`, user `postgres`), không ghi `s3-root`, `s3-users` khi
    `SVP_OBJECT_STORE=external` (mặc định trên EKS; `eks-gitops-up` đặt theo `s3.mode` của values `svp-cluster`), rồi `force-sync`.
  - Argo CD Notifications ([ADR-0032](../adr/0032-argocd-deploy-status.md) A, B): chart `svp-cluster` render ExternalSecret
    `argocd/argocd-notifications-secret` (khoá `github-appID`, `github-installationID`, `github-privateKey` giải base64 trong template
    ESO, `telegram-token` là bot của Alertmanager, rỗng khi không đặt), SecretStore `svp-store` và ServiceAccount đọc nguồn của
    namespace `argocd` chỉ khi values bật `externalSecrets.argocdNotifications` (mặc định tắt; store `aws` cần role `argocd` trong
    `externalSecrets.aws.roles`). Khi đó `secrets.sh` ghi nguồn `svp-secrets/argocd-notifications` từ ba biến chỉ cho EKS của `.env`
    (`SVP_ARGOCD_NOTIFY_APP_ID`, `SVP_ARGOCD_NOTIFY_INSTALLATION_ID`, `SVP_ARGOCD_NOTIFY_PRIVATE_KEY_B64`: GitHub App
    `svp-argocd-notifier`, [`environment.md`](environment.md)) cùng `SVP_ALERT_TELEGRAM_BOT_TOKEN`; thiếu biến, id không phải số hay khoá
    không phải base64 chuẩn của một PEM đọc được (không passphrase) thì dừng, nêu tên biến, không in giá trị, không đổi Secret nào.
    `eks-gitops-up` bật theo values Argo CD đưa cho `svp-cluster` (`SVP_ARGOCD_NOTIFICATIONS=on|off` của `secrets.sh`); `eks-secrets`
    chạy riêng bật khi cluster có ExternalSecret đó. Xoay khoá: [`argocd-notifier-key-rotation.md`](../runbooks/argocd-notifier-key-rotation.md).
  - `make eks-glitchtip-init CONTEXT=…`: như `k8s-glitchtip-init`, ghi vào nguồn `svp-secrets/glitchtip-runtime`.
  - `make eks-smoke CONTEXT=… DOMAIN=<domain>`: `deploy/compose/smoke.sh https://api.<domain>` với `SVP_STACK=eks`, chứng chỉ công
    khai (bỏ `CURL_CA_BUNDLE`).
  - `make eks-seed CONTEXT=… DOMAIN=<domain>`: `deploy/k8s/eks-seed.sh`, 4 user × 8 video ngắn qua API công khai, chờ mọi video
    `READY`, `GET /feed/explore` phải có ≥ 30 (dữ liệu cho k6 profile `cloud`).
  - `make eks-rl-reset CONTEXT=…`: chỉ xoá khoá rate limit đăng ký như trên, chạy trước mỗi bậc k6 (pod sau có thể nhận lại IP của
    pod trước).
  - `S3_CREDENTIALS` của video-service, media-worker: `static` (mặc định, `S3_ACCESS_KEY_ID`, `S3_SECRET_ACCESS_KEY`) hay `container`
    (EKS Pod Identity: `AWS_CONTAINER_CREDENTIALS_FULL_URI`, `AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE`, hai biến khoá tĩnh phải không
    đặt); `S3_PATH_STYLE` `true` (mặc định, store local) hay `false` (virtual-hosted, cho S3); giá trị khác thì service không khởi động.
  - Lớp nền tảng của `svp-gitops`: root `argocd/apps` nhận `platform` (`k3d` hay `eks`) và trên EKS `cluster` (hợp đồng khoá ở
    `deploy/ci/cluster-values.example.yaml`); values đọc theo thứ tự `base/` < `platforms/<platform>/<tên>.yaml` < `envs/<env>/` <
    `envs/<env>/images/` < `valuesObject` sinh từ `platforms/<platform>/<tên>.values.tpl`; Argo CD (không là component) đọc
    `base/argo-cd.yaml` rồi `platforms/<platform>/argo-cd.yaml` khi có (`gitops.sh` cài, `gitops-check.sh` render cùng thứ tự);
    revision không có `platforms/` thì
    `k8s-gitops-up` và check của `svp-gitops` dừng ([ADR-0037](../adr/0037-mainpath-standard-tools.md) §4); env nào chạy trên nền tảng nào
    và render của nền tảng nào được nêu `*.svp.localhost` đọc từ khoá `platforms` của `argocd/apps/components.json` (§5);
    `k8s-gitops-up` đặt `platform=k3d`.
