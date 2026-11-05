# Cluster EKS

Loại tài liệu (Diátaxis): **reference**, tra cứu khi cần một lệnh hay một quy tắc cụ thể; luật làm việc ở [`AGENTS.md`](../../AGENTS.md).

## Target `eks-*`

- Cluster EKS ([ADR-0034](../adr/0034-aws-stage7.md)), target `eks-*` ở `deploy/k8s/k8s.mk`: người học chạy (AI chỉ
  chạy test giả `deploy/k8s/eks-context-test.sh`, `deploy/k8s/aws-secrets-test.sh`), `CONTEXT=svp-stg|svp-prd` là alias của cluster
  trong kubeconfig (`aws eks update-kubeconfig --alias`), script nhận qua `SVP_KUBE_CONTEXT` (`kc`/`hc` của `deploy/k8s/lib.sh`: không
  đặt là `k3d-svp`, tên khác thì dừng trước mọi lệnh; chỉ `aws-secrets.sh`, `glitchtip-init.sh` được vào cluster cloud; `gitops.sh`,
  `secrets.sh` và hàm chỉ của k3d như registry, tạo cluster, CA, diễn tập từ chối `svp-*`); không qua `k8s-exclusive`. Argo CD và root
  của cluster EKS do root Terraform `aws/gitops/<env>` của `svp-infra` dựng (mẫu GitOps Bridge,
  [ADR-0050](../adr/0050-bash-to-standard-tools.md)), không còn target `eks-*` nào bootstrap. **LOCAL LAB ONLY:** `eks-smoke`,
  `eks-seed`, `eks-rl-reset` xoá khoá `svp:gw:rl:register:*` ở Valkey db 10 của cluster đó (qua `kubectl exec`), chỉ cho stg, prd của
  lab.
  - Nguồn của mọi Secret trên EKS là AWS Secrets Manager, entry `svp/<env>/<entry>` region `ap-southeast-1` (vỏ entry không giá trị do
    module `external-secrets` của `svp-infra` tạo); `make eks-secrets`, `make eks-glitchtip-init` ghi giá trị với `AWS_PROFILE` của
    account env (biến ở [`environment.md`](environment.md)). Mỗi lệnh `aws` ghi `--profile` và `--region` ngay trong lệnh; trước lần đọc
    hay ghi entry đầu tiên, account của `AWS_PROFILE` (`sts get-caller-identity`) phải bằng `SVP_AWS_STG_ACCOUNT_ID` hay
    `SVP_AWS_PRD_ACCOUNT_ID` của env, không thì dừng. Mỗi entry một `put-secret-value --secret-string file://<file>`, file JSON trong
    thư mục `mktemp -d` mode 700 xoá khi thoát: giá trị không qua đối số, stdout, stderr.
  - `AWS_PROFILE=anhnv-<env> make eks-secrets CONTEXT=svp-<env>` (`deploy/k8s/aws-secrets.sh`): entry và key đọc từ render
    ExternalSecret của chart `svp-cluster` (`files/external-secrets.yaml`, object store managed, `externalSecrets.argocdNotifications`
    bật): `pg-superuser` (`SVP_PG_SUPERUSER_PASSWORD` từ biến môi trường `SVP_RDS_MASTER_PASSWORD`, bắt buộc, không đọc `.env`),
    `pg-roles`, `kafka-admin`, `kafka-users`, `jwt-signing`, `jwt-verify`, `web`, `obs`, `argocd-notifications` (key đặt tên như `.env`,
    giá trị từ `.env`; hai biến Telegram tuỳ chọn, rỗng thì ghi rỗng), không `s3-root`, `s3-users`; `glitchtip-runtime` ghi ba key
    rỗng chỉ khi entry chưa có version `AWSCURRENT`, không bao giờ ghi đè. Thiếu biến bắt buộc, khoá Server Action hay khoá GitHub App
    sai dạng (kiểm như `k8s-secrets`), entry chưa có (chưa apply root env) thì dừng trước mọi lệnh ghi. Lần đầu (`glitchtip-runtime`
    chưa có version) không hỏi cluster; lần sau là đổi secret của env đang chạy, xem dưới.
  - Argo CD Notifications ([ADR-0032](../adr/0032-argocd-deploy-status.md) A, B): chart `svp-cluster` render ExternalSecret
    `argocd/argocd-notifications-secret` (khoá `github-appID`, `github-installationID`, `github-privateKey` giải base64 trong template
    ESO, `telegram-token` là bot của Alertmanager, rỗng khi không đặt), SecretStore `svp-store` của namespace `argocd` chỉ khi values
    bật `externalSecrets.argocdNotifications` (mặc định tắt; store `aws` cần role `argocd` trong `externalSecrets.aws.roles`). Nguồn là
    entry `argocd-notifications` (ba biến chỉ cho EKS của `.env`: `SVP_ARGOCD_NOTIFY_APP_ID`, `SVP_ARGOCD_NOTIFY_INSTALLATION_ID`,
    `SVP_ARGOCD_NOTIFY_PRIVATE_KEY_B64` của GitHub App `svp-argocd-notifier`, [`environment.md`](environment.md), cùng
    `SVP_ALERT_TELEGRAM_BOT_TOKEN`); thiếu biến, id không phải số hay khoá không phải base64 chuẩn của một PEM đọc được (không
    passphrase) thì `eks-secrets` dừng, nêu tên biến, không in giá trị, không ghi entry nào. Xoay khoá:
    [`argocd-notifier-key-rotation.md`](../runbooks/argocd-notifier-key-rotation.md).
  - `AWS_PROFILE=anhnv-<env> make eks-glitchtip-init CONTEXT=svp-<env>`: như `k8s-glitchtip-init`, đọc DSN và token trong pod GlitchTip,
    ghi vào entry `svp/<env>/glitchtip-runtime` rồi `force-sync` ba ExternalSecret `svp/sentry`, `svp-obs/glitchtip-api`,
    `svp-obs/glitchtip-sourcemaps` và restart service khởi động khi chưa có DSN hiện tại; idempotent.
  - `make eks-smoke CONTEXT=… DOMAIN=<domain>`: `deploy/compose/smoke.sh https://api.<domain>` với `SVP_STACK=eks`, chứng chỉ công
    khai (bỏ `CURL_CA_BUNDLE`).
  - `make eks-seed CONTEXT=… DOMAIN=<domain>`: `deploy/k8s/eks-seed.sh`, 4 user × 8 video ngắn qua API công khai, chờ mọi video
    `READY`, `GET /feed/explore` phải có ≥ 30 (dữ liệu cho k6 profile `cloud`).
  - `make eks-rl-reset CONTEXT=…`: chỉ xoá khoá rate limit đăng ký như trên, chạy trước mỗi bậc k6 (pod sau có thể nhận lại IP của
    pod trước).
  - `S3_CREDENTIALS` của video-service, media-worker: `static` (mặc định, `S3_ACCESS_KEY_ID`, `S3_SECRET_ACCESS_KEY`) hay `container`
    (EKS Pod Identity: `AWS_CONTAINER_CREDENTIALS_FULL_URI`, `AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE`, hai biến khoá tĩnh phải không
    đặt); `S3_PATH_STYLE` `true` (mặc định, store local) hay `false` (virtual-hosted, cho S3); giá trị khác thì service không khởi động.
  - Lớp nền tảng của `svp-gitops`: root hai tầng, `svp-root` (chart `argocd/root`) render Application `svp-apps` (chart
    `argocd/apps`), nhận `platform` (`k3d` hay `eks`) và trên EKS `cluster` (hợp đồng khoá ở `deploy/ci/cluster-values.example.yaml`,
    trên EKS lấy từ annotation của cluster Secret mà root `aws/gitops/<env>` tạo); values đọc theo thứ tự `base/` <
    `platforms/<platform>/<tên>.yaml` < `envs/<env>/` < `envs/<env>/images/` < `valuesObject` sinh từ
    `platforms/<platform>/<tên>.values.tpl`; Argo CD (không là component) đọc `base/argo-cd.yaml` rồi
    `platforms/<platform>/argo-cd.yaml` khi có (`gitops.sh` cài trên k3d, `gitops-check.sh` render cùng thứ tự); revision không có
    `platforms/` thì `k8s-gitops-up` và check của `svp-gitops` dừng ([ADR-0037](../adr/0037-mainpath-standard-tools.md) §4); env nào chạy
    trên nền tảng nào và render của nền tảng nào được nêu `*.svp.localhost` đọc từ khoá `platforms` của `argocd/apps/components.json`
    (§5); `k8s-gitops-up` đặt `platform=k3d`.

## Trình tự buổi

Lệnh `terraform` và script buổi ở `svp-infra` (`aws/scripts/`); mỗi bước xong mới sang bước sau:

1. Apply root `aws/envs/<env>` (cluster, RDS, vỏ entry Secrets Manager).
2. `AWS_PROFILE=anhnv-<env> make eks-secrets CONTEXT=svp-<env>`: nguồn có trước Argo CD.
3. Chỉ prd: PR promote prd đã merge; mở tunnel tới API (output `api_tunnel_command`).
4. Apply root `aws/gitops/<env>` (Argo CD, AppProject, cluster Secret, root).
5. Chờ Application `svp-observability` Healthy:
   `kubectl --context svp-<env> -n argocd wait applications.argoproj.io/svp-observability --for=jsonpath='{.status.health.status}'=Healthy --timeout=30m`.
6. `AWS_PROFILE=anhnv-<env> make eks-glitchtip-init CONTEXT=svp-<env>`.
7. `argocd app wait svp-root --sync --health` (CLI `argocd` qua port-forward tới `argocd-server`).

## Đổi secret của env đang chạy

Cùng thứ tự như `make k8s-secrets` trên k3d. Sửa `.env` (hay `SVP_RDS_MASTER_PASSWORD`), rồi
`AWS_PROFILE=anhnv-<env> make eks-secrets CONTEXT=svp-<env>` làm bốn bước đầu (cluster phải tới được; prd: tunnel mở, không thì dừng
trước mọi lệnh ghi):

1. Mật khẩu superuser Redpanda đổi thì đặt vào broker đang chạy trước (`redpanda_admin` của `deploy/k8s/lib.sh`, dùng chung với
   `secrets.sh`; broker không chạy hay không nhận mật khẩu nào thì dừng, không ghi entry nào).
2. Ghi mọi entry (trừ `glitchtip-runtime`, đã có giá trị).
3. `force-sync` mọi ExternalSecret (`refreshPolicy: OnChange`), chờ từng cái dựng lại từ entry mới.
4. Broker nào còn chạy với mật khẩu superuser khác `.env` thì rolling restart StatefulSet `redpanda` và chờ xong; không broker nào thì
   in `skip` và không restart. Broker và sidecar đọc mật khẩu (`RPK_PASS`) từ environment chỉ lúc khởi động: từ bước 1, probe của sidecar
   gọi Admin API bằng mật khẩu cũ nhận 401, mọi broker NotReady, và Argo CD chỉ chạy hook PostSync của `svp-data` khi tài nguyên đã
   Healthy, nên bước này phải xong trước khi sync. Rolling update của StatefulSet thay từng broker (ordinal cao trước), chờ broker mới
   Ready rồi mới sang broker sau; prd ba broker luôn còn hai, đủ đa số Raft. Hook `preStop` của broker cũ không đăng nhập được để drain:
   partition do nó làm leader bầu leader mới, producer `acks=all` chờ và thử lại. Bước này lỗi (quá 300 giây mỗi broker) thì xem
   `AWS_PROFILE=anhnv-<env> kubectl --context svp-<env> -n svp-data get pods -l app.kubernetes.io/name=redpanda` rồi chạy lại lệnh trên.

Người vận hành làm tiếp, theo thứ tự:

1. Sync Application `svp-data` (Job init đặt mật khẩu mới trong Postgres, Redpanda) và chờ đúng lượt sync đó xong, gồm hook PostSync
   `pg-bootstrap`, `redpanda-init`: restart trước khi Job đặt mật khẩu mới thì pod mới đăng nhập bằng mật khẩu hệ thống chưa có:

   ```sh
   before=$(AWS_PROFILE=anhnv-<env> kubectl --context svp-<env> -n argocd get applications.argoproj.io svp-data -o jsonpath='{.status.operationState.startedAt}')
   AWS_PROFILE=anhnv-<env> kubectl --context svp-<env> -n argocd patch applications.argoproj.io svp-data --type merge -p '{"operation":{"sync":{}}}'
   until s=$(AWS_PROFILE=anhnv-<env> kubectl --context svp-<env> -n argocd get applications.argoproj.io svp-data \
       -o jsonpath='{.status.operationState.startedAt} {.status.operationState.phase}') &&
     [ "${s% *}" != "$before" ] && case "${s#* }" in Succeeded) true ;; Failed | Error) echo "STOP sync $s"; true ;; *) false ;; esac
   do sleep 5; done; echo "sync: $s"
   ```

   Dòng cuối phải là `sync: <thời điểm mới> Succeeded`. In `STOP` thì không sang bước 2: xem Job lỗi
   (`AWS_PROFILE=anhnv-<env> kubectl --context svp-<env> -n svp-data get jobs`), sửa rồi chạy lại bước 1.
2. Restart workload có Secret đổi: Deployment bằng `rollout restart`; Rollout `gateway`, `web` bằng `spec.restartAt` (không tạo
   revision, nên không thành canary):

   ```sh
   AWS_PROFILE=anhnv-<env> kubectl --context svp-<env> -n <namespace> rollout restart deployment/<tên>
   AWS_PROFILE=anhnv-<env> kubectl --context svp-<env> -n svp patch rollout <tên> --type merge -p "{\"spec\":{\"restartAt\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}}"
   ```
