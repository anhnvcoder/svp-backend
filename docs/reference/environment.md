# Môi trường: `.env` và biến của service

Loại tài liệu (Diátaxis): **reference**, tra cứu khi cần một lệnh hay một quy tắc cụ thể; luật làm việc ở [`AGENTS.md`](../../AGENTS.md).

## `.env`

- `make env`: sinh `.env` local (mode 600, mật khẩu DB (mật khẩu superuser của Postgres compose
  `SVP_COMPOSE_PG_SUPERUSER_PASSWORD`, chỉ đặt khi container khởi tạo volume rỗng, và mật khẩu role của bootstrap), mật khẩu root của object store `SVP_S3_ROOT_PASSWORD`, secret key S3 của
  từng service và của user thử `svp-objstore-probe` (`SVP_S3_PROBE_SECRET_KEY`, chỉ compose và `make test-stack`) ngẫu nhiên,
  khoá JWT mới, khoá Server Action của web `NEXT_SERVER_ACTIONS_ENCRYPTION_KEY` (base64 của 32 byte); thêm
  `GLITCHTIP_SECRET_KEY`, `GLITCHTIP_ADMIN_PASSWORD`, mật khẩu hai role `svp_glitchtip_*` và
  `GLITCHTIP_ADMIN_EMAIL=admin@svp.local`; mật khẩu Kafka và Valkey cho compose và cluster k3d (chỉ chữ và số, 32 ký tự,
  [ADR-0053](../adr/0053-msk-elasticache-valkey.md) §12): `SVP_KAFKA_ADMIN_PASSWORD` (user `svp-admin` của script init Kafka và của
  `svp-kafka`), `SVP_KAFKA_<SERVICE>_PASSWORD` cho 5 service có Kafka (`USER_SERVICE`, `VIDEO_SERVICE`, `ENGAGEMENT_SERVICE`,
  `FEED_SERVICE`, `MEDIA_WORKER`), `SVP_KAFKA_OTELCOL_PASSWORD` (Collector), `SVP_KAFKA_KEDA_PASSWORD` (chỉ k3d),
  `SVP_VALKEY_GATEWAY_PASSWORD`, `SVP_VALKEY_FEED_SERVICE_PASSWORD`, `SVP_VALKEY_WEB_PASSWORD`, `SVP_VALKEY_OPS_PASSWORD` (user
  `svp-ops` của `svp-valkey`); cho cluster k3d, compose bỏ qua: `SVP_PG_SUPERUSER_PASSWORD`,
  `SVP_GRAFANA_ADMIN_PASSWORD`, `SVP_PG_BACKUP_S3_SECRET_KEY` (user `svp-pg-backup` của backup Postgres; 20 byte hex
  như secret key S3 khác: 40 ký tự là độ dài secret key của AWS)). `.env` có
  sẵn thì chỉ bổ sung biến còn thiếu hoặc đang rỗng, không đổi giá trị đã đặt. Cùng lệnh sinh một lần **CA local** vào
  `.local/ca/` (gitignore, không ghi đè; khoá mode 600): `ca.crt`, `ca.key` và hai cert server ký bởi CA đó: `server.crt` cho Kafka,
  Valkey, `postgres.crt` cho Postgres (tên `postgres` của compose và Service `svp-pg-rw` của k3d với mọi dạng, cùng `localhost`). Clone
  đã có CA thì chỉ cert, khoá còn thiếu hay hết hạn được sinh lại; CA mất hay hết hạn thì sinh lại CA và cả hai cert.
  Trên EKS các mật khẩu Kafka, Valkey không lấy từ `.env`: Terraform của `svp-infra` sinh và ghi vào Secrets Manager.
- Người học tự đặt, `make env` không sinh (không tạo được khoá của GitHub App), chỉ cho cluster EKS có Argo CD Notifications
  ([`eks.md`](eks.md), [ADR-0032](../adr/0032-argocd-deploy-status.md)): `SVP_ARGOCD_NOTIFY_APP_ID`, `SVP_ARGOCD_NOTIFY_INSTALLATION_ID`
  (số của App `svp-argocd-notifier` và bản cài của nó trên `svp-gitops`), `SVP_ARGOCD_NOTIFY_PRIVATE_KEY_B64` (khoá riêng của App,
  `base64 < key.pem | tr -d '\n'`: `.env` không nhận giá trị nhiều dòng). `deploy/k8s/aws-secrets.sh` (`make eks-secrets`) đọc để ghi
  entry `argocd-notifications` của Secrets Manager, `deploy/k8s/secrets.sh` chỉ đọc khi chart `svp-cluster` của cluster k3d bật
  `externalSecrets.argocdNotifications`; compose không đọc.
- Không ở `.env`, đặt trong terminal của buổi AWS (không commit), cho `make eks-secrets` và `make eks-glitchtip-init`
  ([`eks.md`](eks.md)): `AWS_PROFILE` (profile SSO của account env: `anhnv-stg`, `anhnv-prd`), `SVP_AWS_STG_ACCOUNT_ID`,
  `SVP_AWS_PRD_ACCOUNT_ID` (id 12 chữ số của account env; script dừng trước mọi lệnh ghi khi account của `AWS_PROFILE` khác biến
  của env đó), `SVP_RDS_MASTER_PASSWORD` (chỉ `eks-secrets`: mật khẩu master của RDS, script buổi của `svp-infra` đọc từ AWS, thành
  key `SVP_PG_SUPERUSER_PASSWORD` của entry `pg-superuser`; không bao giờ đọc từ `.env`).
- Không ở `.env`, chỉ cho `make drill-k8s-reloader` ([`k8s.md`](k8s.md)): `SVP_DRILL_NEW_VALUES`, đường dẫn tới file giá trị mới
  (mode 600, mỗi dòng `NAME=value`, do `deploy/k8s/drills/reloader/new-values.sh` ghi); không đặt thì diễn tập tự sinh, trừ trên GitHub
  Actions, nơi biến này bắt buộc (bước trước của job đã mask từng giá trị). Diễn tập ghi giá trị mới vào `.env` và để lại đó.
- Quy tắc đọc `.env` (`deploy/observability/glitchtip/dotenv.sh`, dùng chung cho `make env`, `make test-stack`,
  `make glitchtip-init`, bootstrap Postgres và script diễn tập): mỗi dòng là dòng trống, comment `#` ở cột 1, hoặc
  `KEY=value` với `KEY` ở cột 1 và `=` ngay sau; giá trị trơn (ASCII in được, không khoảng trắng, nháy, `\`, `$`) hoặc nằm
  trong đúng một cặp nháy `"..."`/`'...'` bao ngoài, bỏ nháy khi đọc (`KEY=""` là rỗng). Dòng có `$`/`${`, khoảng trắng
  đầu dòng hay `export`, khoá lặp, giá trị nhiều dòng, CRLF, byte NUL → dừng, nêu `FILE:dòng:` và tên biến, không in giá
  trị, không ghi gì.

## Postgres, Kafka, Valkey và CA local

Mọi môi trường dùng cùng giao thức và cùng code của client; khác nhau chỉ ở giá trị biến
([ADR-0053](../adr/0053-msk-elasticache-valkey.md) §4, §10, §11, [ADR-0057](../adr/0057-postgres17-verify-full.md) §2).

- **`DATABASE_URL`** (bốn service có Postgres và Job migrate của chúng; GlitchTip cả `MAINTENANCE_DATABASE_URL`):
  `postgres://<role>:<mật khẩu>@<host>:5432/<database>?sslmode=verify-full&sslrootcert=/etc/svp-ca/ca.crt`. Client kiểm cert server theo CA
  của file đó và theo đúng host đã gọi, nên host là tên mà cert mang: compose `postgres`, k3d `svp-pg-rw.svp-data`, EKS địa chỉ RDS
  `cluster.rdsAddress`. File là CA local ở compose, k3d và bundle CA của RDS (Secret `rds-ca`) trên EKS. `make test` không đọc biến này:
  nó dùng `SVP_TEST_POSTGRES_URL` tới Postgres native không TLS ([`testing.md`](testing.md)).

- **`KAFKA_BROKERS`** (user, video, engagement, feed-service, media-worker): danh sách `host:port` cách dấu phẩy của listener SASL_SSL
  cổng 9096: compose `kafka:9096`, k3d `kafka.svp-data.svc.cluster.local:9096`, EKS giá trị `cluster.kafkaBrokers` (bootstrap SCRAM của
  MSK). Không cổng Kafka nào publish ra host.
- **`KAFKA_SASL_USERNAME`, `KAFKA_SASL_PASSWORD`** (`internal/kafkax`, đọc ở mọi client của process, cả producer dead-letter trong
  consumer): đều đặt thì client nối TLS (tối thiểu 1.2, root của hệ thống, kiểm tên cert theo host của broker) và đăng nhập
  SCRAM-SHA-512; cả hai trống thì plaintext không SASL, chỉ broker trong bộ nhớ của test nhận; chỉ một biến thì service không khởi
  động, lỗi nêu tên biến thiếu, không in giá trị. Không có biến bật, tắt TLS. Giá trị: user `svp-<service>` và mật khẩu
  `SVP_KAFKA_<SERVICE>_PASSWORD` (compose từ `.env`, cluster từ Secret `svp/<service>-env`). Broker từ chối mật khẩu hay bắt tay TLS
  (cert sai tên, CA lạ, broker không TLS) thì client log WARN/ERROR `kafka client: …` có địa chỉ broker và lỗi, không có mật khẩu.
- **`REDIS_URL`** (gateway db 10, feed-service db 14, web db 9): `rediss://<user>:<password>@<host>:6379/<db>` với user `svp-gateway`,
  `svp-feed-service`, `svp-web`; host compose `valkey`, k3d `valkey.svp-data.svc.cluster.local`, EKS `cluster.valkeyHost`. `rediss://` bật
  TLS kiểm tên theo host; lỗi đọc URL không chứa URL. `make test` (db 15) và `make dev` của web (db 9) vẫn dùng Redis native, không TLS,
  không user ([`testing.md`](testing.md)).
- **`SSL_CERT_DIR=/etc/svp-ca`** (container Go) và **`NODE_EXTRA_CA_CERTS=/etc/svp-ca/ca.crt`** (web): chỉ local (compose, k3d), cho
  client tin **CA local** cạnh root của hệ thống; `ca.crt` mount chỉ đọc. Trên EKS không đặt: cert của MSK, ElastiCache nối về CA công
  khai của Amazon. Go trên macOS bỏ qua `SSL_CERT_DIR`, nên biến này chỉ có tác dụng trong container Linux.
- **Collector** (receiver `kafkametrics`, user `svp-otelcol`): `SVP_KAFKA_OTELCOL_PASSWORD` (compose từ `.env`, cluster từ Secret
  `svp-obs/otelcol-kafka` khoá `password`), `SVP_OTELCOL_KAFKA_BROKERS` (địa chỉ như `KAFKA_BROKERS`), `SVP_OTELCOL_KAFKA_CA_FILE`
  (`/etc/svp-ca/ca.crt` ở local, rỗng trên EKS).
- **CLI vận hành** (`/opt/svp/bin/svp-kafka`, `/opt/svp/bin/svp-valkey` từ `deploy/ops/`, chạy trong container `kafka`, `valkey` của
  compose và Deployment `svp-data/svp-ops` của cluster): `svp-kafka` đọc `KAFKA_BROKERS` và `SVP_KAFKA_ADMIN_PASSWORD` (user
  `svp-admin`), `svp-valkey` đọc `VALKEY_HOST` và `SVP_VALKEY_OPS_PASSWORD` (user `svp-ops`, chuyển cho `valkey-cli` qua
  `REDISCLI_AUTH`); cả hai đọc `SVP_CA_FILE` (CA để tin, chỉ local). `SVP_AS_USER=<user>` đăng nhập user khác, mật khẩu là dòng đầu
  của stdin, phần còn lại chuyển nguyên cho công cụ. Mật khẩu chỉ ở biến của container hay stdin, không trên dòng lệnh.

## Biến và hành vi khởi động của service

- **Service có Postgres thử lại kết nối lúc khởi động** (`internal/pgretry`, gọi từ `internal/pgpool.New` và
  `internal/dbmigrate.Up`; [ADR-0020](../adr/0020-reliability-stage6.md) §11): chỉ lỗi mạng (từ chối kết nối, quá hạn dial,
  mất kết nối lúc bắt tay, DNS quá hạn), trong cửa sổ 30 s, chờ 250 ms gấp đôi tới 2 s, mỗi lần vẫn bị hạn kết nối 5 s; lỗi xác
  thực, database không có, TLS bị từ chối, tên miền không có thì dừng ngay. Mỗi lần lỗi một dòng WARN `database not reachable,
  retrying` (`attempt`, `error`, không URL), nối được sau khi lỗi thì INFO `database connected after retries` (`attempts`,
  `elapsed_ms`).
- **engagement-service mở tối đa `DATABASE_MAX_CONNS` kết nối Postgres mỗi process** ([ADR-0031](../adr/0031-chaos-findings-feed-engagement-tempo.md)
  §2): số nguyên ≥ 2, không đặt thì 10, giá trị khác thì service không khởi động; chia hai pool cùng URL: pool đọc (chỉ `GetStats`)
  ⌊n/2⌋, pool ghi (Like, Unlike, consumer lượt xem) phần còn lại. Values k3d đặt `"10"`, compose không đặt. Like/Unlike có hạn
  Postgres 1 s phía server; hết hạn hay Postgres không tới được thì `UNAVAILABLE` + `DEPENDENCY_UNAVAILABLE`, gateway không thử lại
  (503 ngay). Service khác giữ pool mặc định của pgx.
- **`JWT_VERIFY_KEYS` bắt buộc ở gateway và bốn service gRPC** (user, video, engagement, feed;
  [ADR-0042](../adr/0042-caller-identity-grpc.md)): khoá công khai Ed25519 dạng `kid:<base64 của 32 byte>` cách nhau dấu phẩy, cùng
  giá trị ở cả năm process (nguồn `jwt-verify`). Gateway kiểm access token của client bằng nó, mỗi service gRPC kiểm lại token gateway
  chuyển tiếp trong metadata `authorization`. Thiếu, rỗng, sai dạng (mục rỗng, base64 hỏng, khoá không đủ 32 byte, `kid` lặp) thì
  process không khởi động: log ERROR `<service> failed` nêu tên biến và lỗi, thoát mã 1 trước khi listen cổng gRPC; compose
  từ chối dựng container khi biến trống (`${JWT_VERIFY_KEYS:?run make env}`). Chỉ user-service có `JWT_SIGNING_KID`,
  `JWT_SIGNING_KEY`. Đổi khoá: [`jwt-key-rotation.md`](../runbooks/jwt-key-rotation.md).
- **media-worker chạy một trong hai lệnh con** (đối số của container, value `args` của chart `svp-service`): `serve`
  (mặc định, ffmpeg) hay `mediaconvert` (AWS Elemental MediaConvert, chỉ EKS;
  [`transcode.md`](../explanation/transcode.md)). `mediaconvert` đọc mọi biến của `serve` (`KAFKA_BROKERS`, `S3_*`,
  `WORK_DIR`, `OTEL_*`) và bắt buộc thêm `MEDIACONVERT_QUEUE_ARN` (ARN queue), `MEDIACONVERT_ROLE_ARN` (ARN role job
  chạy bằng), `TRANSCODE_EVENTS_QUEUE_URL` (URL hàng đợi SQS trạng thái job); cả ba ở region `S3_REGION`, cũng là region
  của client MediaConvert, SQS, và dùng credential của store (`S3_CREDENTIALS`). Trên EKS chúng đến từ khoá
  `mediaconvertQueueArn`, `mediaconvertRoleArn`, `transcodeEventsQueueUrl` của hợp đồng cluster. Thiếu, sai dạng hay
  khác region thì process không khởi động: log ERROR `media-worker failed` nêu tên biến (`… is malformed`,
  `… is not in the region S3_REGION names`), thoát mã 1. Lệnh con khác thì lỗi `unknown command`.
