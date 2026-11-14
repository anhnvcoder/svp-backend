# Cluster EKS

Loại tài liệu (Diátaxis): **reference**, tra cứu khi cần một lệnh hay một quy tắc cụ thể; luật làm việc ở [`AGENTS.md`](../../AGENTS.md).

## Target `eks-*`

- Cluster EKS ([ADR-0034](../adr/0034-aws-stage7.md)), target `eks-*` ở `deploy/k8s/k8s.mk`: người học chạy (AI chỉ
  chạy test giả `deploy/k8s/eks-context-test.sh`, `deploy/k8s/aws-secrets-test.sh`), `CONTEXT=svp-stg|svp-prd` là alias của cluster
  trong kubeconfig (`aws eks update-kubeconfig --alias`, trong lệnh của output `kubeconfig_command`, mục API dưới), script nhận qua `SVP_KUBE_CONTEXT` (`kc`/`hc` của `deploy/k8s/lib.sh`: không
  đặt là `k3d-svp`, tên khác thì dừng trước mọi lệnh; chỉ `aws-secrets.sh`, `glitchtip-init.sh` được vào cluster cloud; `gitops.sh`,
  `secrets.sh` và hàm chỉ của k3d như registry, tạo cluster, CA, diễn tập từ chối `svp-*`); không qua `k8s-exclusive`. Argo CD và root
  của cluster EKS do root Terraform `aws/gitops/<env>` của `svp-infra` dựng (mẫu GitOps Bridge,
  [ADR-0050](../adr/0050-bash-to-standard-tools.md)), không còn target `eks-*` nào bootstrap. **LOCAL LAB ONLY:** `eks-smoke`,
  `eks-seed`, `eks-rl-reset` xoá khoá `svp:gw:rl:register:*` ở db 10 của ElastiCache của cluster đó, qua CLI vận hành (`svp-valkey` trong
  container `valkey` của Deployment `svp-ops`, user `svp-ops` mà ACL chỉ cho xoá đúng hai tiền tố của `AGENTS.md`), chỉ cho stg, prd của
  lab.
  - **API của cluster** ([ADR-0055](../adr/0055-environment-matrix.md) §2, §5): endpoint công khai tắt ở cả stg và prd; máy người học tới
    endpoint private qua tunnel SSM (module `ssm-bastion`, `ssm-bastion.tf` của root `aws/envs/<env>`: bastion ở subnet private, không inbound,
    không khoá SSH). Hai output của root: `api_tunnel_command` mở tunnel `127.0.0.1:<api_tunnel_port>` tới cổng 443 của endpoint và chạy tới
    khi dừng (cần Session Manager plugin của AWS CLI; một terminal riêng, `eval`), `kubeconfig_command` thêm context `svp-<env>` trỏ tunnel đó,
    vẫn kiểm cert theo host của endpoint (`--tls-server-name`). Cổng local theo env (`api_tunnel_port` của `<env>.tfvars`: stg `6444`, prd
    `6443`), nên một lệnh nhầm context không tới cluster kia; root `aws/gitops/<env>` đi cùng tunnel (`api_server_url` của
    `aws/gitops/<env>/<env>.tfvars`). Mọi target `eks-*` và lệnh `kubectl` vào EKS cần tunnel đang mở.
  - **Đường vào** ([ADR-0061](../adr/0061-edge-cloudfront-waf-acm.md) §4, giải thích ở [`edge.md`](../explanation/edge.md)): CloudFront, VPC
    origin, ALB internal và target group `svp-<env>-envoy` do root `aws/envs/<env>` tạo; cluster chỉ gắn Envoy vào target group đó. Values eks
    của chart `svp-cluster` (`platforms/eks/svp-cluster.yaml`, `svp-cluster.values.tpl`): Service `svp-envoy` kiểu `ClusterIP`,
    `TargetGroupBinding` `svp-envoy` (`envoy.targetGroupArn` từ khoá `cluster.edgeTargetGroupArn`), một listener `https` không hostname với Secret
    `svp-edge-tls` do issuer CA nội bộ `svp-ca` ký cho `<domain>` và `api.<domain>`, NetworkPolicy `envoy` nhận 10443 từ `cluster.edgeCidrs`
    (subnet edge) và namespace `svp-load`, 19003 chỉ từ `cluster.edgeCidrs`. AWS Load Balancer Controller không tạo load balancer nào, chỉ ghi
    địa chỉ pod Envoy vào target group. Không gì trong cluster ghi Route 53 hay xin cert công khai. Gateway lấy IP client từ
    `CloudFront-Viewer-Address` (`platforms/eks/gateway.values.tpl`, [`contracts.md`](contracts.md)).
  - **Postgres là Amazon RDS** ([ADR-0057](../adr/0057-postgres17-verify-full.md) §2): chart `svp-data` ở `postgres.mode: external`, không
    CloudNativePG; mọi client (bốn service, Job `migrate`, GlitchTip, Job `pg-bootstrap`) nối thẳng địa chỉ RDS `cluster.rdsAddress` (cert
    RDS mang tên đó) với `sslmode=verify-full&sslrootcert=/etc/svp-ca/ca.crt`: `platforms/eks/svp-cluster.values.tpl` đặt
    `externalSecrets.postgres` thành `<cluster.rdsAddress>:5432`, `pg-bootstrap` đọc `postgres.external.host`. File CA là bundle CA của RDS
    cho `ap-southeast-1`, nằm ở value `rdsCA.bundle` của chart `svp-cluster` (`platforms/eks/svp-cluster.yaml`); chart render từ đó Secret
    `rds-ca` (khoá `ca.crt`) ở `svp`, `svp-obs`, `svp-data`, không render khi value rỗng. Bốn service có Postgres đặt `localCA: rds-ca`
    (`platforms/eks/<service>.yaml`), GlitchTip và `pg-bootstrap` chọn `rds-ca` theo `postgres.mode`.
  - **Node** ([ADR-0056](../adr/0056-eks-platform-ha.md) §1–§3): nhóm node hệ thống `system` (managed node group on-demand của module `eks`,
    mỗi AZ một node) chạy add-on, Argo CD và controller Karpenter; mọi node khác do Karpenter tạo theo pod đang chờ. Controller là component
    `karpenter` của `argocd/apps/components.json` (chỉ nền tảng `eks`, namespace `kube-system`, values `base/karpenter.yaml` và
    `platforms/eks/karpenter.values.tpl`). NodePool `default` và EC2NodeClass `default` do chart `svp-cluster` render khi
    `karpenter.enabled` bật; các khoá còn lại bắt buộc khi bật (thiếu thì render dừng, nêu tên khoá): `clusterName` (từ `.values.tpl`, suy ra
    tag discovery `karpenter.sh/discovery` và role node `<clusterName>-karpenter-node`), `amiAlias`, `capacityTypes`, `limits`,
    `disruptionBudgets` (vào `spec.disruption.budgets`), `terminationGracePeriod`. `platforms/eks/svp-cluster.yaml` giữ giá trị mức prd;
    `envs/stg/svp-cluster.yaml` chỉ ghi đè phần stg giảm (capacity type, `limits`, ngân sách disruption); prd không có overlay. Giá trị và
    lý do: ADR-0056 §2, nhóm của từng khác biệt: [`environments.md`](../explanation/environments.md).
  - **Agent GuardDuty** ([ADR-0060](../adr/0060-org-detection-logging.md) §5): add-on EKS `aws-guardduty-agent` (DaemonSet mọi node, version ghim
    ở `aws/modules/eks/addons.tf` của `svp-infra` như add-on khác) gửi sự kiện runtime qua interface endpoint `guardduty-data` của VPC (module
    `network`, private DNS, security group TCP 443 từ CIDR VPC). Cả hai do Terraform tạo, không do GuardDuty tự quản: endpoint và security
    group GuardDuty tự tạo nằm ngoài state và chặn destroy VPC cuối buổi. Add-on chỉ `ACTIVE` khi node đã có; coverage của cluster đọc ở
    GuardDuty của account `svp-security` (Runtime Monitoring → EKS clusters), finding tới email theo
    [`security-alert.md`](../runbooks/security-alert.md).
  - Kafka là Amazon MSK và Valkey là Amazon ElastiCache ([ADR-0053](../adr/0053-msk-elasticache-valkey.md)); cả hai do Terraform của `svp-infra`
    tạo (module `msk`, `elasticache`), không có broker hay Valkey chạy trong cluster. Client nói với chúng như với `kafka` và `valkey` của compose
    và k3d: SASL_SSL SCRAM-SHA-512 cổng 9096 và `rediss://` cổng 6379, chỉ khác địa chỉ (hợp đồng `cluster` bên dưới) và CA: cert của MSK, ElastiCache
    nối về CA công khai của Amazon trong root hệ thống, không cần CA riêng; bốn service có Postgres mount `rds-ca` ở `/etc/svp-ca` và đặt
    `SSL_CERT_DIR=/etc/svp-ca` để thêm CA của RDS vào root đó. Mật khẩu của user Kafka, Valkey do Terraform sinh
    và ghi một lần cho cả MSK/ElastiCache lẫn entry Secrets Manager `svp/<env>/kafka-admin`, `kafka-users`, `valkey-users`; `make eks-secrets`
    không ghi ba entry này, chỉ kiểm chúng tồn tại. Chart `svp-data` chạy ở `kafka.mode: external`, `valkey.mode: external`: Job `kafka-init`
    (PostSync) tạo topic và ACL trên MSK, Deployment `svp-ops` là CLI vận hành; NetworkPolicy của hai pod đó chỉ mở tới `cluster.dbCidrs` (subnet
    database) cổng 9096, 6379 (`svp-ops` thêm 5432 tới RDS). Lệnh vận hành mẫu:
    `kubectl --context svp-<env> -n svp-data exec deploy/svp-ops -c kafka -- /opt/svp/bin/svp-kafka topics --list`; đọc RDS bằng role app,
    phiên chỉ đọc:
    `kubectl --context svp-<env> -n svp-data exec deploy/svp-ops -c postgres -- /opt/svp/bin/svp-pg feed -c 'SELECT count(*) FROM follows'`.
  - Nguồn của mọi Secret trên EKS là AWS Secrets Manager, entry `svp/<env>/<entry>` region `ap-southeast-1` (vỏ entry không giá trị do
    module `external-secrets` của `svp-infra` tạo); `make eks-secrets`, `make eks-glitchtip-init` ghi giá trị với `AWS_PROFILE` của
    account env (biến ở [`environment.md`](environment.md)). Mỗi lệnh `aws` ghi `--profile` và `--region` ngay trong lệnh; trước lần đọc
    hay ghi entry đầu tiên, account của `AWS_PROFILE` (`sts get-caller-identity`) phải bằng `SVP_AWS_STG_ACCOUNT_ID` hay
    `SVP_AWS_PRD_ACCOUNT_ID` của env, không thì dừng. Mỗi entry một `put-secret-value --secret-string file://<file>`, file JSON trong
    thư mục `mktemp -d` mode 700 xoá khi thoát: giá trị không qua đối số, stdout, stderr.
  - `AWS_PROFILE=anhnv-<env> make eks-secrets CONTEXT=svp-<env>` (`deploy/k8s/aws-secrets.sh`): entry và key đọc từ render
    ExternalSecret của chart `svp-cluster` (`files/external-secrets.yaml`, object store managed, `externalSecrets.argocdNotifications`
    bật): `pg-superuser` (`SVP_PG_SUPERUSER_PASSWORD` từ biến môi trường `SVP_RDS_MASTER_PASSWORD`, bắt buộc, không đọc `.env`),
    `pg-roles`, `jwt-signing`, `jwt-verify`, `web`, `obs`, `argocd-notifications` (key đặt tên như `.env`,
    giá trị từ `.env`; hai biến Telegram tuỳ chọn, rỗng thì ghi rỗng), không `s3-root`, `s3-users`, và không `kafka-admin`, `kafka-users`,
    `valkey-users` (của Terraform; chỉ kiểm chúng đã có, nên apply root `aws/envs/<env>` trước); `glitchtip-runtime` ghi ba key
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
  - `make eks-smoke CONTEXT=… DOMAIN=<domain>`: `deploy/compose/smoke.sh https://api.<domain>` với `SVP_STACK=eks`, qua CloudFront với cert
    ACM công khai (bỏ `CURL_CA_BUNDLE`).
  - `make eks-seed CONTEXT=… DOMAIN=<domain>`: `deploy/k8s/eks-seed.sh`, 4 user × 8 video ngắn qua API công khai, chờ mọi video
    `READY`, `GET /feed/explore` phải có ≥ 30 (dữ liệu cho k6 profile `cloud`).
  - `make eks-transcode-timing CONTEXT=… DOMAIN=<domain> CLIP=<file> N=<n>`:
    `deploy/compose/transcode-timing.sh https://api.<domain>` với `SVP_STACK=eks` (script và output ở
    [`compose.md`](compose.md)): đo giây từ complete tới `READY` của từng lần upload qua MediaConvert; xoá khoá rate
    limit đăng ký như `eks-smoke`.
  - `make eks-rl-reset CONTEXT=…`: chỉ xoá khoá rate limit đăng ký như trên, chạy trước mỗi bậc k6 (pod sau có thể nhận lại IP của
    pod trước).
  - `S3_CREDENTIALS` của video-service, media-worker: `static` (mặc định, `S3_ACCESS_KEY_ID`, `S3_SECRET_ACCESS_KEY`) hay `container`
    (EKS Pod Identity: `AWS_CONTAINER_CREDENTIALS_FULL_URI`, `AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE`, hai biến khoá tĩnh phải không
    đặt); `S3_PATH_STYLE` `true` (mặc định, store local) hay `false` (virtual-hosted, cho S3); giá trị khác thì service không khởi động.
  - Lớp nền tảng của `svp-gitops`: root hai tầng, `svp-root` (chart `argocd/root`) render Application `svp-apps` (chart
    `argocd/apps`), nhận `platform` (`k3d` hay `eks`) và trên EKS `cluster` (hợp đồng khoá ở `deploy/ci/cluster-values.example.yaml`,
    trên EKS lấy từ annotation của cluster Secret mà root `aws/gitops/<env>` tạo; hai khoá của edge: `edgeTargetGroupArn` (output
    `target_group_arn` của module `edge`) và `edgeCidrs` (danh sách CIDR của subnet edge); hai khoá của MSK, ElastiCache: `kafkaBrokers`, chuỗi
    `host:9096,host:9096,…` là output `bootstrap_brokers` của module `msk`, và `valkeyHost`, host không cổng là `primary_endpoint_address` của module
    `elasticache`, mà `platforms/eks/*.values.tpl` đọc để đặt `KAFKA_BROKERS`, host của Valkey trong `REDIS_URL`, `kafka.brokers` và `valkey.host`
    của `svp-data`, `SVP_OTELCOL_KAFKA_BROKERS` của Collector; ba khoá của transcode: `mediaconvertQueueArn`,
    `mediaconvertRoleArn`, `transcodeEventsQueueUrl`, output `queue_arn`, `role_arn`, `events_queue_url` của module
    `transcode`, mà `platforms/eks/media-worker.values.tpl` đọc để đặt ba biến của lệnh con `mediaconvert`
    ([`environment.md`](environment.md#biến-và-hành-vi-khởi-động-của-service))); values đọc theo thứ tự `base/` <
    `platforms/<platform>/<tên>.yaml` < `envs/<env>/` < `envs/<env>/images/` < `valuesObject` sinh từ
    `platforms/<platform>/<tên>.values.tpl`; Argo CD (không là component) đọc `base/argo-cd.yaml` rồi
    `platforms/<platform>/argo-cd.yaml` khi có (`gitops.sh` cài trên k3d, `gitops-check.sh` render cùng thứ tự); revision không có
    `platforms/` thì `k8s-gitops-up` và check của `svp-gitops` dừng ([ADR-0037](../adr/0037-mainpath-standard-tools.md) §4); env nào chạy
    trên nền tảng nào và render của nền tảng nào được nêu `*.svp.localhost` đọc từ khoá `platforms` của `argocd/apps/components.json`
    (§5); `k8s-gitops-up` đặt `platform=k3d`.

## Trình tự buổi

Lệnh `terraform` và script buổi ở `svp-infra` (`aws/scripts/`); mỗi bước xong mới sang bước sau:

1. Apply root `aws/envs/<env>` (cluster, RDS, MSK, ElastiCache, vỏ entry Secrets Manager; mật khẩu Kafka, Valkey được sinh và ghi trong cùng apply).
2. `AWS_PROFILE=anhnv-<env> make eks-secrets CONTEXT=svp-<env>`: nguồn có trước Argo CD.
3. Mở tunnel tới API (output `api_tunnel_command`, terminal riêng) và thêm context (output `kubeconfig_command`); chỉ prd: PR promote prd
   đã merge trước bước này.
4. Apply root `aws/gitops/<env>` (Argo CD, AppProject, cluster Secret, root).
5. Chờ Application `svp-observability` Healthy:
   `kubectl --context svp-<env> -n argocd wait applications.argoproj.io/svp-observability --for=jsonpath='{.status.health.status}'=Healthy --timeout=30m`.
6. `AWS_PROFILE=anhnv-<env> make eks-glitchtip-init CONTEXT=svp-<env>`.
7. `argocd app wait svp-root --sync --health` (CLI `argocd` qua port-forward tới `argocd-server`).

## Đổi secret của env đang chạy

Sửa `.env` (hay `SVP_RDS_MASTER_PASSWORD`), rồi một lệnh; cluster phải tới được (tunnel mở, không thì dừng trước mọi lệnh ghi):

```sh
AWS_PROFILE=anhnv-<env> make eks-secrets CONTEXT=svp-<env>
```

Lệnh làm trọn một lượt xoay credential theo cùng thứ tự với `make k8s-secrets` trên k3d (`deploy/k8s/rotate.sh`,
[ADR-0050](../adr/0050-bash-to-standard-tools.md) mục 5); người vận hành không sync, không restart gì:

1. Cluster phải chạy Reloader (và workload opt in theo tên Secret của chúng), không thì dừng trước mọi lệnh ghi
   (`FAIL  cluster svp-<env> is not ready for a change of credentials: <lý do>`).
2. Ghi mọi entry của `.env` (trừ `glitchtip-runtime`, đã có giá trị; trừ ba entry Kafka, Valkey của Terraform).
3. `force-sync` các ExternalSecret của `svp-data`.
4. Một sync của Application `svp-data` (hook PostSync `pg-bootstrap` đặt mật khẩu mới trong Postgres, `kafka-init` đăng nhập MSK bằng `svp-admin`
   và đặt lại topic, ACL), chờ đúng lượt sync đó `Succeeded`; `Failed`, `Error` hay quá 600 giây thì dừng, ExternalSecret của client chưa dựng
   lại: client restart trước khi Job đặt mật khẩu mới thì đăng nhập bằng mật khẩu hệ thống chưa có.
5. `force-sync` mọi ExternalSecret còn lại; Reloader restart workload có Secret đổi: Deployment bằng rolling update, Rollout `gateway`,
   `web` bằng `spec.restartAt` (không tạo revision, nên không thành canary). Script không chờ bước này.

Mật khẩu của user Kafka, Valkey không sinh bằng lệnh này mà ở Terraform: tăng `msk_password_version` (Kafka) hay `valkey_password_version`
(Valkey) của root env, apply, rồi chạy `aws/scripts/bootstrap.sh <env> secrets` của `svp-infra` (gọi lệnh trên với mật khẩu master RDS). Thiếu
lượt này thì cluster giữ mật khẩu cũ: ExternalSecret có `refreshPolicy: OnChange`, không tự đọc lại entry. MSK áp secret mới tới broker trong
tối đa 10 phút, và kết nối mới của pod chưa restart có thể bị từ chối trong khoảng đó (ADR-0053 §12).

Dòng cần thấy, theo thứ tự: `ok    ExternalSecrets of the server built again from their source`, `ok    init Jobs of svp-data done (sync of Application svp-data Succeeded)`,
`ok    ExternalSecrets of the clients built again from their source`, `ok    Reloader restarts each workload whose Secret changed`. Một
dòng `FAIL` thì sửa nguyên nhân rồi chạy lại đúng lệnh trên: lượt nào cũng làm đủ các bước, gồm init còn thiếu của lượt trước. Theo dõi
restart:

```sh
AWS_PROFILE=anhnv-<env> kubectl --context svp-<env> get pods -A -w
```
