# Stack compose, diễn tập, tải, DAST, game day

Loại tài liệu (Diátaxis): **reference**, tra cứu khi cần một lệnh hay một quy tắc cụ thể; luật làm việc ở [`AGENTS.md`](../../AGENTS.md).

## Stack compose

- `make up` / `make smoke` / `make down`: dựng stack compose profile `core` (`tls-init` (cert và khoá của CA local vào volume `svp-tls`), Postgres `postgres` và bootstrap role, database trong nó, Kafka `kafka` + `kafka-init` (topic, user, ACL),
  Valkey `valkey`, object store `s3` (RustFS, [ADR-0022](../adr/0022-local-object-store-minio-replacement.md)) + job `s3-init` tạo
  bucket, user, policy, CORS, migrate, gateway, user-service, video-service, media-worker, engagement-service,
  feed-service, web client `web`), chạy luồng đầu-cuối qua gateway ở `127.0.0.1:8080` (gồm refresh token, dùng lại token
  cũ thì cả họ bị thu hồi, logout, follow, hồ sơ: handle tự chọn, trùng handle 409, handle sinh `u_…`, `GET`/`PATCH /me`
  không có email, `followed_by_me`, danh sách video theo tác giả chỉ tác giả thấy video chưa `READY`, tạo video với
  `Idempotency-Key` rồi gọi lặp cùng khoá nhận lại đúng `video_id` đó, upload video bằng presigned POST lên object store, chờ `READY`, tải HLS và thumbnail, output HLS bất biến
  ([ADR-0029](../adr/0029-immutable-media-versions.md): master ở `media/<id>/<version>/master.m3u8`, version là `event_id` của
  `video.uploaded`, biến thể và thumbnail dưới thư mục lần thử `<version>/<attempt>/`; master, một playlist biến thể, một segment
  và thumbnail mang `Cache-Control: max-age=31536000, immutable`), `GET /public/videos/{id}` không token 200 với video `READY`
  và một 404 cho video chưa `READY` lẫn id ngẫu nhiên, video vào feed following và explore kèm `author`, like/unlike, lượt
  xem, unfollow), rồi gỡ stack (giữ volume). Gateway dùng Valkey db 10 (rate limit), feed-service db 14 (cache feed
  khám phá), web db 9 (session), mỗi client một user riêng qua `rediss://<user>:<mật khẩu>@valkey:6379/<db>` (**Kafka và Valkey** dưới). Object store chỉ nhận CORS từ `http://localhost:3001` và
  `http://localhost:3002`, theo bucket (`s3-init` đặt `PutBucketCors`: `uploads` chỉ `POST`, `media` chỉ `GET`, `HEAD`; danh
  sách toàn cục `RUSTFS_CORS_ALLOWED_ORIGINS` rỗng nên bucket khác không có header CORS; WEB-10): mở web bằng
  `127.0.0.1:3001` thì đăng nhập được nhưng không phát và không tải video lên được. Cổng publish chỉ trên `127.0.0.1`: 8080 gateway, 3001 web (mở
  bằng `http://localhost:3001`), 9000 object store (API S3; console tắt, không cổng 9001); Postgres, Kafka và Valkey không publish cổng nào. Xem object bằng
  `curl --aws-sigv4` chạy trong container `s3`, không mở cổng nào thêm. `make ps` và `make logs SVC=<tên>` để xem. Trước khi chạy, `make smoke` và `make drill-obs-threats`
  xoá khoá rate limit đăng ký theo IP `svp:gw:rl:register:*` ở db 10 của Valkey (`SCAN` + `DEL`, không `FLUSHDB`) qua CLI vận hành
  `svp-valkey` chạy trong container `valkey` (user `svp-ops`; không cần `redis-cli` trên máy), vì mọi request đi ra từ một IP bridge của Docker và
  vài lần chạy trong một giờ sẽ cạn burst 20. Việc xoá này **chỉ dùng ở lab local**, không trỏ script vào stack dùng
  chung. Smoke luôn đòi master có version và kiểm đủ `Cache-Control` (mọi bản phát hành ghi key có version từ
  [ADR-0029](../adr/0029-immutable-media-versions.md); biến chuyển tiếp `SVP_SMOKE_LEGACY_MEDIA` đã bỏ, [ADR-0037](../adr/0037-mainpath-standard-tools.md) §4).
- Postgres, Kafka và Valkey là container của stack (**Postgres**, **Kafka và Valkey** dưới); mỗi client có role, user và database, db
  hay khoá riêng nên không service nào đọc dữ liệu của service khác. Postgres native `127.0.0.1:5432` không thuộc stack: chỉ `make test` dùng nó. Redis native
  `127.0.0.1:6379` không thuộc stack: chỉ `make test` (db 15) và `make dev` của web dùng nó. Không service lõi nào phụ thuộc service
  của `obs`. Cổng publish chỉ trên loopback của host: gateway, web client (3001), API S3 của object store (9000) và, khi có `obs`,
  Grafana (3000), Alertmanager (9093), GlitchTip (8000). Cổng gRPC nằm trong mạng compose
  ([threat model](../threat-model.md) IN-2); Collector (4317) và Prometheus (9090), Tempo (3200), Loki (3100), Pyroscope (4040) của LGTM
  cũng vậy, từ host đọc chúng qua datasource proxy của Grafana.
- Ba mạng. `default` chứa mọi thứ trừ media-worker và web. `worker` (internal, không route ra ngoài) chỉ chứa media-worker, Kafka,
  object store và Collector, nên worker chạy ffmpeg trên file người dùng tải lên không tới được gateway, service gRPC, Postgres,
  LGTM hay internet (threat model FF-4, FF-5); Collector ở đó chỉ nhận telemetry, không làm proxy cho worker. `web` chỉ chứa web,
  gateway và, khi có `obs`, GlitchTip và Collector: server Next render mọi trang thay cho trình duyệt, nên code chạy được trong đó
  (lớp RCE của React Server Components, CVE-2025-55182) chỉ tới được API HTTP của gateway, tracker lỗi nó báo tới và Collector nó gửi
  telemetry tới. Nó không tới được service gRPC (chúng kiểm access token của người gọi nhưng không kiểm container nào gọi,
  [ADR-0042](../adr/0042-caller-identity-grpc.md), nên code trong web cầm token của một phiên sẽ gọi chúng như user đó, vượt
  rate limit và kiểm đầu vào của gateway; threat model IN-2), không tới được Kafka hay object store theo
  tên compose; Valkey thì tới được, nhưng user `svp-web` của nó chỉ chạm db 9 và `svp:web:*`. Mạng `web` không internal vì Docker không
  publish cổng của container chỉ gắn vào mạng internal. Docker Desktop phân giải `host.docker.internal` ở mọi container, nên code chạy
  trong web vẫn tới được cổng loopback của host (cổng 9000 của object store, khi có `obs` Grafana, Alertmanager, GlitchTip, và mọi thứ
  khác nghe ở đó). Chấp nhận ở lab compose (threat model WEB-13); bản k3d đóng bằng NetworkPolicy.
- Web client mở bằng `http://localhost:3001`, là `APP_ORIGIN` mà redirect sau đăng nhập và form của cookie dựa theo.
  `http://127.0.0.1:3001` cũng đăng nhập được, với cookie phiên riêng (trình duyệt gửi `Sec-Fetch-Site: same-origin` ở đó, kiểm CSRF
  chấp nhận trước khi so `Origin`), nhưng không phát và không tải video lên được vì CORS của bucket chỉ cho origin `localhost`.
- **Postgres** ([ADR-0057](../adr/0057-postgres17-verify-full.md) §3): container `postgres`, image PostgreSQL 17 ghim digest (`x-postgres-image`
  của `compose.yaml`), cùng major với RDS; chạy bằng user `postgres` (uid 999) của image, root chỉ đọc, dữ liệu ở volume `postgres-data`, không
  publish cổng. TLS bằng cert `postgres.crt` của CA local (`tls-init` chép vào `svp-tls`); `deploy/postgres/pg_hba.conf` từ chối mọi kết nối mạng
  không TLS (như `rds.force_ssl` của RDS), kết nối TLS đăng nhập bằng mật khẩu SCRAM, socket Unix trong container chỉ cho user hệ điều hành
  cùng tên (`peer`). Service, migrate và GlitchTip nối `postgres:5432` với `sslmode=verify-full&sslrootcert=/etc/svp-ca/ca.crt` (mount `ca.crt`),
  kiểm cả CA lẫn tên trong cert; migrate và `glitchtip-init` chờ `postgres` khoẻ (healthcheck `pg_isready` qua TLS verify-full tới tên `postgres`).
  - `make db-bootstrap` (`make up`, `make glitchtip-init` gọi nó): bật `postgres` (cùng `tls-init`) nếu chưa chạy và chờ khoẻ, rồi chạy
    `deploy/postgres/bootstrap.sql` cho từng database bằng `docker compose … exec -T postgres psql` dưới user `postgres` qua socket; máy không cần
    `psql`. Mật khẩu role đọc từ `.env` theo luật của `dotenv.sh`, tới psql qua biến môi trường mà dòng lệnh chỉ nêu tên (`-e NAME`), không bao giờ
    ở dòng lệnh hay output. Mật khẩu superuser `SVP_COMPOSE_PG_SUPERUSER_PASSWORD` (do `make env` sinh) chỉ được đặt khi image khởi tạo volume rỗng.
  - Script trên máy chạm Postgres compose chỉ bằng `docker compose … exec -T postgres psql …` qua Makefile (tiền tố
    `env -u DOCKER_DEFAULT_PLATFORM`), không `psql -h 127.0.0.1 -p 5432`: cổng đó là Postgres native của máy.
  - Stack bắt đầu rỗng: dữ liệu dev ở Postgres native không chuyển sang, `make up` tạo role, database và schema mới trong container. Database
    `svp_*` cũ ở Postgres native còn nguyên; không script nào xoá hay sửa chúng.
- **Kafka và Valkey** ([ADR-0053](../adr/0053-msk-elasticache-valkey.md)): chạy cùng phần mềm, cổng và xác thực với MSK và ElastiCache for Valkey.
  - `tls-init` (một lần, uid 0) chép cert, khoá của CA local và aclfile của Valkey từ `.local/` (CA do `make env` sinh, aclfile do `make up` ghi từ mật khẩu của `.env`) vào volume
    `svp-tls` với owner là uid của image server, khoá mode 0400; `postgres`, `kafka`, `valkey` mount volume đó chỉ đọc và chờ `tls-init` xong.
    Client chỉ cần `ca.crt` (công khai) tại `/etc/svp-ca/ca.crt`: service Go đặt `SSL_CERT_DIR=/etc/svp-ca`, web `NODE_EXTRA_CA_CERTS`, công cụ
    Kafka và `valkey-cli` đặt `SVP_CA_FILE`. Chạy được cả trên Docker Desktop macOS và runner Linux. `make env` sinh CA một lần, không ghi
    đè; thiếu thì `make up` dừng và bảo chạy `make env`.
  - `kafka`: image `apache/kafka`, một tiến trình KRaft (broker và controller), `SASL_SSL` SCRAM-SHA-512 cổng `kafka:9096` (cổng SCRAM của MSK),
    ACL bật, không tự tạo topic; listener controller và liên broker là PLAINTEXT bind `localhost`. Một broker nên mọi replication factor và
    `min.insync.replicas` là 1 (gồm ba khoá nội bộ `offsets.topic.replication.factor`, `transaction.state.log.*`). `kafka-init`
    (`deploy/kafka/kafka-init.sh`, cũng là Job `kafka-init` của chart `svp-data`) đăng nhập `svp-admin`, cấp `svp-admin` ALL trên mọi tài nguyên,
    tạo topic (không truyền replication factor: topic lấy mặc định của broker), user (mật khẩu từ `.env`) và ACL từng user; service có Kafka chờ nó xong.
    Idempotent: chạy lại giữ topic, đặt lại mật khẩu user, ACL đã có thì không đổi.
  - `valkey`: image Valkey, TLS cổng `valkey:6379` (không cổng thường), aclfile với `svp-gateway` (db 10, `svp:gw:*`), `svp-feed-service` (db 14,
    `svp:feed:*`), `svp-web` (db 9, `svp:web:*`) và `svp-ops`; `default` tắt; không lưu đĩa, `maxmemory` 64 MB, `noeviction`.
  - **CLI vận hành**, đường duy nhất để script chạm hai thứ này: `deploy/ops/svp-kafka` và `svp-valkey`, mount chỉ đọc vào `/opt/svp/bin` của container
    `kafka`, `valkey`. Từ máy: `env -u DOCKER_DEFAULT_PLATFORM docker compose --env-file .env -f deploy/compose/compose.yaml --profile core exec -T valkey
    /opt/svp/bin/svp-valkey -n 10 --scan --pattern 'svp:gw:rl:register:*'` (`exec -T kafka /opt/svp/bin/svp-kafka topics --list`, và `consumer-groups`,
    `acls`, `configs`…). `svp-kafka <công cụ> …` chạy `kafka-<công cụ>.sh` đăng nhập `svp-admin`; `svp-valkey …` chạy `valkey-cli --tls` đăng nhập
    `svp-ops` (đọc `svp:*` ở db 9, 10, 14, `DEL` chỉ trên `svp:gw:rl:register:*` ở db 10 và `svp:feed:explore:*` ở db 14: đúng luật xoá khoá
    của `AGENTS.md`). `SVP_AS_USER=<user>` (`exec -T valkey env SVP_AS_USER=<user> /opt/svp/bin/svp-valkey …`) đăng nhập user khác để thử quyền của nó, mật khẩu là dòng đầu của stdin; mật khẩu
    không bao giờ ở dòng lệnh hay output. Helper của script là `valkey_cli` trong `deploy/compose/lib.sh`. `deploy/ops/ops-test.sh` thử hai wrapper không cần broker hay server (CI chạy nó).
  - Replication factor khác 1 chỉ có trên MSK (stg 2, prd 3), nơi `aws_msk_configuration` đặt; topic đã có giữ số replica nó có.
- Job `s3-init` chạy với image của object store: `curl` của nó ký từng request (SigV4) bằng user root và gọi API S3 cùng API quản trị
  của RustFS (`/rustfs/admin/v3`, nhận JSON thường). Idempotent: chạy lại giữ bucket và object, đặt lại secret key và policy của
  user, bucket policy và CORS theo đúng script và môi trường của nó. Không in secret.
- `make up OBS=lgtm|elastic|off` (ADR-0011 §9–10, ADR-0012). Không đặt `OBS`: chỉ `core`, SDK telemetry bật nhưng không có
  Collector để tới (export lỗi bị bỏ, không làm service lỗi). `OBS=lgtm` thêm profile `obs`: `otelcol` (Collector, không
  publish), `lgtm` (Grafana `127.0.0.1:3000` cùng Prometheus, Loki, Tempo, Pyroscope trong một container),
  `alertmanager` (`127.0.0.1:9093`), `glitchtip` (`127.0.0.1:8000`), chạy `make glitchtip-init` trước. `OBS=elastic`
  thêm `obs-elastic` thay cho `obs`: Elasticsearch, Kibana (`127.0.0.1:5601`), APM Server, `otelcol-elastic`; chỉ để so
  sánh, không cảnh báo hay GlitchTip. `OBS=off`: chỉ `core`, telemetry tắt hẳn (`OTEL_SDK_DISABLED=true`, Pyroscope và
  Sentry rỗng), mốc đo overhead; target diễn tập dựng lại service trên stack này vẫn giữ tắt. **Chỉ một bộ observability
  mỗi lúc:** `make up` từ chối khi container của profile nó không chọn đang chạy, báo chạy `make down` trước; `make down`,
  `make ps`, `make logs` gồm mọi profile. Grafana anonymous Admin và Kibana không đăng nhập chỉ chấp nhận vì chỉ publish
  trên loopback (OPS-2).
- `make up IMAGES=stg`, `WEB_FROM=clone|stg|image` [`WEB_IMAGE=ghcr.io/<repository>@sha256:<digest>`]
  ([ADR-0033](../adr/0033-svp-web-repo.md) §6, §7; `compose_images` của `deploy/k8s/lib.sh` đặt biến image mà
  `deploy/compose/compose.yaml` đọc): không đặt `IMAGES` thì sáu service backend build từ working tree, một lượt bằng
  `docker buildx bake -f deploy/docker-bake.json` (bảng image dùng chung với `make k8s-up` và CI,
  [ADR-0050](../adr/0050-bash-to-standard-tools.md)) thành `svp/<service>:dev` trước compose; compose không tự build service backend
  (`pull_policy: never`), nên `docker compose up` lẻ cần image do `make up` build; `IMAGES=stg` chạy
  bản phát hành stg của sáu service (bốn job migrate cùng image) theo digest của `envs/stg/images/` trong bản clone `svp-gitops` như
  đang có (không fetch), không build Go. `WEB_FROM` không đặt hay `stg`: bản web của stg theo digest (nên `make up` cần bản clone
  `svp-gitops` và mạng tới GHCR); `clone`: build web từ thư mục web (`web_dir`, mục `make web-clone` của [`k8s.md`](k8s.md)); `image`: `WEB_IMAGE`.
  Mỗi bản của stg phải là repository của một nguồn phát hành có service đó
  (bảng nguồn của working tree) và GHCR cho kéo ẩn danh (`WEB_IMAGE` cũng phải kéo ẩn danh được); `make up` `docker pull` từng digest
  theo kiến trúc máy trước khi dựng (kéo không được thì dừng trước khi chạy gì), bản phát hành chạy với `pull_policy: never`, có bản
  phát hành thì sáu service của `IMAGES=stg` không bake, `--build` chỉ còn cho web khi `WEB_FROM=clone`. Giá trị sai (`IMAGES` khác `stg`, `WEB_IMAGE` thiếu `WEB_FROM=image`, tag
  thay digest) thì dừng nêu lý do. Chế độ này cho job e2e: target diễn tập dựng lại service bằng `compose up --no-deps` không mang
  biến của `make up` (sẽ chạy image `svp/<service>:dev` của lần bake trước thay bản phát hành), nên `make drill-obs-threats` (`deploy/compose/drills/common.sh`) từ chối
  chạy khi một service mà diễn tập dừng hay dựng lại chạy image `ghcr.io/…` (web bản phát hành không chặn: không diễn tập nào dựng lại
  web), nêu service và lệnh dựng lại (`make down`, rồi `make up` không `IMAGES`),
  trước khi đụng gì. Web chạy bản phát hành thì
  `make web-sourcemaps` từ chối (bản đó build ở CI với build id riêng). Job `stack` của CI `svp-frontend` chạy
  `make up IMAGES=stg WEB_FROM=clone` (lượt PR #1 của `svp-frontend`,
  [41108867928](https://github.com/anhnvcoder/svp-frontend/actions/runs/41108867928): `smoke` qua, e2e xanh).
- `make compose-config`: kiểm file compose hợp lệ cho `core`, `core`+`obs`, `core`+`obs-elastic` và `OBS=off`, với image mà
  `IMAGES`, `WEB_FROM`, `WEB_IMAGE` chọn như `make up` (không kéo image; bản phát hành vẫn hỏi GHCR có cho kéo ẩn danh), chỉ bằng `config --quiet` (không in file đã điền secret);
  sạch là không in gì.
- `make glitchtip-init`: migrate và khởi tạo GlitchTip (admin, organization và project `svp`, API token chỉ đọc, token tải
  source map `svp-sourcemaps` scope `project:releases`), thêm `SENTRY_DSN`, `SENTRY_AUTH_TOKEN`, `SENTRY_ORG`,
  `SENTRY_PROJECT`, `SENTRY_API_URL`, `SENTRY_SOURCEMAPS_TOKEN` vào `.env` khi còn thiếu hay rỗng;
  idempotent, không đổi giá trị đã đặt. `make up OBS=lgtm` tự gọi nó. Database `svp_glitchtip` trên Postgres compose, hai
  role `svp_glitchtip_migrator`, `svp_glitchtip_app` do bootstrap Postgres của `make up` tạo. Job `glitchtip-init` trong compose chạy
  cùng việc đó (migrate `svp_glitchtip`, rồi tạo admin, organization, team, project `svp` và token API của diễn tập) và chỉ in số
  đếm; `glitchtip` chỉ khởi động sau khi nó thành công. `make glitchtip-init` chạy nó thêm một lần, gắn thư mục output để lấy DSN và
  token cho `.env` (`deploy/observability/glitchtip/init.sh`). Migrate và `createcachetable` đi qua role migrator vì role app không
  tạo được bảng.
- `make otelcol-validate`: `validate` của Collector ghim (`--network none`) cho cấu hình `obs`, cấu hình `obs-elastic`
  (file `deploy/observability/elastic/otelcol-config.yaml` ghép đè lên file `obs`) và cấu hình của cluster k3d
  (`deploy/observability/otelcol/k8s-config.yaml`); chạy lại sau khi sửa một trong ba.
- `make slo`: sinh `deploy/observability/prometheus/rules/slo-generated.yaml` từ `deploy/observability/slo/svp-slos.yaml`
  bằng Sloth; file sinh được commit, chạy lại sau khi sửa spec. `make slo-check`: promtool của image LGTM ghim, không
  mạng: `check config` cho cấu hình Prometheus và hai file rule, rồi `test rules` (`svp-alerts.test.yaml`).
- `make test-stack`: `go test -race -count=1 -v` trên stack đang chạy (`make up`), đặt các biến `SVP_TEST_*` cho object store, nên integration test của `internal/objstore` chạy thật thay vì SKIP (gồm ca multipart CRC32 bằng user thử
  `svp-objstore-probe`, dạng header qua `http://` và dạng trailer qua proxy TLS của test; `Cache-Control` lưu và trả lại khi GET
  ẩn danh, ghi có điều kiện `If-None-Match: *` chỉ một lần thành công, user của media-worker đọc và liệt kê được `media/`). Chỉ ba secret S3 (hai service và
  user thử) lấy từ `.env`; endpoint,
  access key, `SVP_TEST_POSTGRES_URL` và `SVP_TEST_REDIS_URL` cố định trong `deploy/compose/compose.mk` và
  `Makefile`. Thu hẹp bằng `PKGS=` như `make test`, `TESTFLAGS` thêm cờ.
- `make clean-data`: gỡ stack (mọi profile) và xoá volume của nó (database và role của Postgres compose, topic, user và ACL của Kafka, bucket
  của object store `s3-data`, thư mục tạm của media-worker, dữ liệu LGTM, silence của Alertmanager, chỉ mục Elasticsearch); Postgres native
  của máy không bị đụng; volume của project mà compose không còn khai được giữ và in ra. Chỉ chạy khi cần làm lại dữ liệu từ đầu.
- Diễn tập compose đo một lần (`drill-kill-worker`, `drill-duplicates`, `drill-duplicates-feed`, `drill-engagement-down`,
  `drill-rate-limit`, `drill-upload-cleanup`, `drill-alert-to-sentry`, `measure-ready`, `measure-freshness`, `measure-explore-cache`,
  game day) không còn ở repo này: bản đóng băng cùng [`tools/fakefollows/`](https://github.com/anhnvcoder/svp-labs/tree/main/drills/svp-backend/tools/fakefollows/) và cách chạy lại ở commit ghim là bài lab
  [`drills/` của `svp-labs`](https://github.com/anhnvcoder/svp-labs/tree/main/drills) ([ADR-0039](../adr/0039-mainpath-drills-scan-gate-sourcemaps.md) bảng 1,
  [ADR-0050](../adr/0050-bash-to-standard-tools.md)); số đo và id lượt chạy giữ ở ADR của từng diễn tập.
- `make drill-obs-threats`: diễn tập các dòng threat model về telemetry, chỉ trên stack `make up OBS=lgtm`, cần
  GlitchTip đã khởi tạo (`SENTRY_DSN`, `SENTRY_AUTH_TOKEN` trong `.env`, do `make up OBS=lgtm` hay `make glitchtip-init`
  ghi; script chỉ nhận `SENTRY_API_URL=http://127.0.0.1:8000`, không cổng loopback nào khác). Kiểm: JWT-8 (trace, log, event GlitchTip của request login/feed/follow, cả lúc user-service tắt, không có email, mật
  khẩu, token), UP-8 (`video created`, `upload completed` có `user_id`, `video_id`, `trace_id`), OPS-1 (`/debug/pprof/`,
  `/metrics` trả 404; project publish đúng 6 cổng loopback, gồm web 3001 và `s3` 9000, không 9001), RL-2 (gateway dựng lại với Valkey `.invalid` thì metric
  `store="fallback"` > 0 và cảnh báo `RateLimitFallbackActive` trong 4 phút), WEB-9 (web trên compose: email, token,
  sid, `?next=`, chữ ký presigned từ form của web, `/rum` và `/monitoring` không có trong GlitchTip, Tempo, Loki, Prometheus;
  đối chứng có dữ liệu của web). **Telegram tuỳ chọn:** người học tự tạo bot
  và điền `SVP_ALERT_TELEGRAM_BOT_TOKEN`, `SVP_ALERT_TELEGRAM_CHAT_ID` vào `.env`; có đủ cả hai thì Alertmanager gửi cảnh
  báo `severity=page` tới `api.telegram.org` (ngoại lệ hẹp về mạng ngoài của lab); thiếu thì không gửi gì.

## Tải k6

- Tải k6 ([ADR-0020](../adr/0020-reliability-stage6.md) §2), target ở `deploy/k6/k6.mk`, k6 chỉ chạy bằng
  `K6_IMAGE` ghim của `Makefile` (không dùng k6 cài trên máy). `make k6-check`: `k6 inspect --execution-requirements` của
  `deploy/k6/main.js` với từng profile (`local`, `ci`, `cloud`), `--network none`, sạch là không in gì. `make load-local`
  (profile `local`, ~24 req/s giữ 5 phút, threshold theo SLO gồm độ trễ) và `make load-ci` (profile `ci`, vài req/s 60 s, chỉ
  threshold lỗi; job `stack` của CI dùng): trên stack `make up` đang chạy (`OBS=lgtm` để đọc phía server trong Prometheus), có
  video `READY` (`make smoke` tạo); từ chối trừ khi container gateway và web của project compose `svp` chạy và không node hay
  registry nào của cluster k3d `svp` chạy, không bao giờ khởi động gì; container k6 vào mạng `svp_web`, gọi
  `http://gateway:8080` và `http://web:3001` (`Host`, `Origin` là `http://localhost:3001`, là `APP_ORIGIN` mà kiểm tra Server Action
  của Next và kiểm CSRF của web so với); gateway thấy địa chỉ riêng của container k6, tách khỏi container web, nên hai bên không
  chung bucket rate limit theo IP; `K6_NO_USAGE_REPORT` đặt vì nếu không k6 báo mỗi lượt chạy tới server usage của Grafana; tóm tắt ở
  `.k6/<profile>-<time>/summary.json` (gitignore; từ `handleSummary`, không `setup_data`), cùng `machine.json` (CPU và bộ nhớ của VM
  Docker, nguồn điện); thư mục được grep, có token, cookie hay mật khẩu trong đó thì lượt chạy thất bại; exit 0 khi mọi threshold
  đạt, ngược lại 1 (in kèm exit status của k6). **LOCAL LAB ONLY:** cả hai xoá khoá `svp:gw:rl:register:*` ở db 10 bằng
  `SCAN` + `DEL` như `make smoke`, vì pool đăng ký từ một địa chỉ của container k6; không trỏ script vào stack dùng chung.
- Kịch bản `deploy/k6/main.js` chạy kịch bản API của `api.js` và kịch bản web của `web.js` trong một tiến trình k6, theo tốc độ của
  profile mà `SVP_K6_PROFILE` chọn (`local`, `ci`, `cloud`; `lib/config.js`). Biến môi trường: `SVP_K6_PROFILE`; `SVP_API_URL`
  (gateway), `SVP_WEB_URL` (địa chỉ k6 gọi tới web client) và `SVP_WEB_ORIGIN` (origin người dùng mở web, gửi làm `Host` và `Origin`);
  `SVP_K6_HOLD` và `SVP_K6_RAMP` (thời gian giữ tốc độ đầy đủ và thời gian tăng dần tới đó, mặc định theo profile; số nguyên kèm
  `s`, `m` hay `h`); `SVP_K6_RESULTS` (thư mục ghi `summary.json`; không đặt thì ra stdout); `SVP_K6_PODS` và
  `SVP_K6_FORWARDED_FOR` (chỉ Job cloud).
- Mọi tốc độ trong `lib/config.js` tính theo phút, nên route dưới một request mỗi giây (`POST /videos`) không cần tốc độ lẻ. Tốc độ
  của profile `cloud` là tổng của cả Job: k6 chia chúng cho `pods` tiến trình bằng `--execution-segment`, còn mỗi pod đăng ký pool
  user riêng trong `setup()` (một pool cho mỗi địa chỉ nguồn). `SVP_K6_PODS` (chỉ profile `cloud`, 1 tới 20) chạy Job với ít pod hơn
  20 của thiết kế, mỗi pod giữ tải của một pod thiết kế: mọi tốc độ thành tổng thiết kế nhân `SVP_K6_PODS / 20`, nên cỡ pool và tốc
  độ theo user giữ nguyên.
- Cỡ pool giữ mọi giới hạn theo user và theo địa chỉ của gateway ngoài tầm với, bất kể route, lớp và khoá: `users` đăng ký và đăng
  nhập một lần ở gateway (burst đăng ký 20 mỗi địa chỉ, burst đăng nhập 30), `webSessions` trong số đó đăng nhập thêm một lần qua
  form của web; tốc độ đọc của một user dưới 10/s và `POST /videos` của nó dưới 3 upload mở mỗi 15 phút của video-service. `pods`
  là số tiến trình k6 chia tốc độ, mỗi tiến trình một pool riêng: số theo user chỉ đúng khi từng pod chạy phần của nó (`setup()` kiểm
  các execution segment với số đó).
- Số iteration một executor arrival-rate được chạy cùng lúc tính theo pod rồi nhân `pods`: khoảng 300 ms công việc cho mỗi request
  đang bay trước khi nó khởi thêm VU, và chỗ cho độ trễ tăng tới 2 s trước khi bỏ iteration (`dropped_iterations` khi đó báo). k6 chia
  VU cho các execution segment như chia tốc độ, và chỉ cấp iteration của một scenario cho segment nhận được ít nhất một `maxVUs` của
  nó: nếu tính trên tổng của Job, route chậm (`POST /videos`, tối đa 3 VU) sẽ chạy trên 3 trong 20 pod với 36 user của chúng thay vì
  cả 240, và pod không có VU cấp sẵn bỏ iteration đầu tiên trong lúc khởi một VU.
- `turn(data)` (`api.js`) cho user của iteration này và, với route cần, video của nó. User trong pool lần lượt theo thứ tự
  (`iterationInInstance` đếm iteration của scenario trong instance này, nên trên pod cloud, chỉ chạy execution segment của nó, lượt
  vẫn đi hết pool của chính pod). Video tiến sau mỗi lượt của cùng một user, từ offset riêng: nếu lấy từ iteration chia dư cho số
  video như user, hai thứ quay đồng bộ và một user chỉ thấy `videos / gcd(users, videos)` video (5 trong 30 với 12 user), lặp lại
  các cặp (user, video) mà RL-3 chặn ở gateway.
- Job k6 trên cluster cloud (`deploy/k6/cloud/`): 20 pod profile `cloud`, 1 000 request feed mỗi giây (tổng 1 250 req/s) giữ ít nhất
  10 phút. Người học chạy với context kubectl của cluster cloud, không từ `make`; cần `kubectl` và `jq`; context `k3d-*` (laptop
  16 GB) bị từ chối trước mọi lệnh kubectl. `render.sh` in manifest ra stdout (namespace `svp-load`, ConfigMap `svp-k6-scripts` chứa
  script của `deploy/k6/` như trong working tree, Job Indexed của `job.yaml.in`), không chạm cluster và không đọc `.env`;
  `run.sh` áp output đó và `make cloud-check` kiểm nó (chạy `render.sh` không đối số). Image là `K6_IMAGE` đọc từ `Makefile` gốc: một nơi ghim k6
  cho `make load-local`, CI và Job này, Renovate chỉ cập nhật dòng đó.
- Đối số của `deploy/k6/cloud/run.sh --context <ctx> --domain <domain> start|logs|delete` (`render.sh` nhận cùng các cờ, trừ
  `--context`, và thêm `--envoy-ip`):
  - `--domain`: host công khai của web (API ở `api.<domain>`), như listener và certificate của Envoy đặt tên (mặc định của
    `render.sh` là `svp.invalid`, chỉ cho kiểm tĩnh). `--envoy-ip`: ClusterIP của Service Envoy, nơi tên công khai phân giải tới
    trong pod (mặc định `192.0.2.1`, địa chỉ tài liệu, chỉ cho kiểm tĩnh).
  - `--forwarded-for`: chỉ khi cluster tin 2 hop `X-Forwarded-For` (load balancer trước Envoy); mỗi pod ghi IP của nó vào đó như
    load balancer sẽ làm (threat model RL-7).
  - `--ca-file`: file PEM của CA ký certificate Envoy, khi một CA riêng ký (Envoy sau load balancer giữ certificate công khai); pod
    tin CA đó thêm vào root mà image có, không thay chúng. Chỉ nhận certificate, file chứa khoá riêng bị từ chối. Không có cờ thì
    pod tin root của image.
  - `--pods`: 1 tới 20 pod (mặc định 20), mỗi pod giữ tải của một pod thiết kế nên tổng co theo số pod (`lib/config.js`,
    `SVP_K6_PODS`). `--ramp`, `--hold`: thời gian tăng và giữ, như `2m` (mặc định 10m mỗi cái); đặt một trong hai thì hạn của Job
    tính theo độ dài lượt chạy thay vì mặc định 3600 s.
  - `start`: tìm ClusterIP của Service Envoy của Gateway `svp`, render manifest và áp chúng (namespace, ConfigMap, Job `svp-k6`);
    từ chối khi đã có Job `svp-k6`. `logs`: sau khi Job kết thúc, dòng tóm tắt của từng pod vào `.k6/cloud-<time>/pod-<i>.json` và
    một bảng của chúng; exit 1 khi số pod của Job khác số completion, một pod không in tóm tắt hay một tóm tắt có thứ giống token,
    cookie hay mật khẩu (khi đó nó bị xoá). `delete`: xoá namespace `svp-load` (Job, pod và log của chúng).
- Trước `start`: stack chạy trên cluster cloud với ít nhất 30 video `READY` (ít hơn thì hầu hết lượt xem dừng ở luật một-mỗi-phút
  của gateway, RL-3), không gì khác đang tải nó, và số hop tin cậy của gateway đã quyết (RL-1). Theo dõi bằng
  `kubectl --context <ctx> -n svp-load get pods -w`, dashboard SLO của Grafana và 429 của gateway (`svp_rate_limited` trong tóm tắt
  của mỗi pod phải bằng 0). Đạt: ở mọi pod mọi threshold đạt và `dropped_iterations` bằng 0; p95, p99 phía server đọc từ
  Prometheus trong cửa sổ giữ được ghi cùng số của các pod làm kết quả lượt chạy. Dừng sớm bằng `run.sh --context <ctx> --domain
  <domain> delete`.
- `deploy/k6/cloud/job.yaml.in` là mẫu mà `render.sh` điền (`@K6_IMAGE@`, `@DOMAIN@`, `@ENVOY_IP@`, `@FORWARDED_FOR@`,
  `@SCRIPT_ITEMS@`, `@PODS@`, `@DEADLINE@`, `@RAMP@`, `@HOLD@`); nó không phải manifest đứng một mình (đuôi `.yaml.in`, `make
  cloud-check` không đọc nó mà kiểm output của `render.sh`). Namespace `svp-load` nằm ngoài `svp` nên policy image của Kyverno không
  áp, và chạy dưới PSA restricted. 20 pod của một Job Indexed, mỗi pod chạy execution segment riêng của profile `cloud`: k6 chia tốc
  độ, mỗi pod đăng ký pool riêng từ IP pod của nó (không khoá rate limit nào bị xoá trên cloud). 20 là `pods` của profile `cloud`
  trong `lib/config.js`, nơi tính VU và pool theo pod; `setup()` từ chối lượt chạy với số segment khác. Ít pod hơn (`render.sh
  --pods`) giữ các dòng đánh dấu `@PODS@`: `SVP_K6_PODS` báo số pod cho script, tốc độ co theo nó, mỗi pod giữ tải của một pod thiết
  kế. Dòng `@RAMP@`, `@HOLD@` chỉ còn khi có `render.sh --ramp`, `--hold`. Pod gọi Service của Envoy trong cluster: `hostAliases`
  trỏ tên công khai vào ClusterIP của nó, nên TLS kiểm certificate thật còn tải không đi qua load balancer công khai hay internet.
- Dòng `@CA@` của `job.yaml.in` chỉ còn khi có `render.sh --ca-file`, cho Envoy mà một CA riêng ký (CA của cluster sau load balancer
  giữ certificate công khai): chúng mount ConfigMap `svp-k6-ca` và trỏ `SSL_CERT_FILE` vào nó. k6 không có cờ cho CA; `crypto/x509`
  của Go, mà k6 dùng trên Linux, đọc file đó thay file bundle của image nhưng vẫn đọc mọi file certificate trong `/etc/ssl/certs` và
  `/etc/pki/tls/certs` (chỉ `SSL_CERT_DIR` mới thay các thư mục đó). Vì vậy CA riêng được tin thêm vào root mà image có ở các thư mục
  ấy, không thay chúng. TLS vẫn được kiểm, không bao giờ bị bỏ qua.

## DAST

- `make dast` (DAST theo OpenAPI, [ADR-0030](../adr/0030-devsecops-supplement.md) §3, target ở
  `deploy/dast/dast.mk`, logic ở `deploy/dast/run.sh`, cấu hình `deploy/dast/schemathesis.toml`): Schemathesis chỉ bằng
  `SCHEMATHESIS_IMAGE` ghim của `Makefile`, trên stack `make up` đang chạy (`core` là đủ); từ chối khi gateway không chạy, mạng
  `svp_web` không có hay cluster k3d chạy, không bao giờ khởi động gì. Chờ `/readyz` để stack còn đang khởi động không bị báo là lỗi
  API. Đăng ký và đăng nhập một user thử qua `http://127.0.0.1:8080` (token chỉ trong môi trường, không in, không nằm trên dòng lệnh;
  vào container bằng `-e SVP_DAST_TOKEN` không kèm giá trị, docker đọc từ môi trường), container
  vào `svp_web` gọi `http://gateway:8080` với 20 operation của `services/gateway/openapi.yaml` (trừ `/healthz`, `/readyz`), phase
  `examples`, `coverage`, `fuzzing`, check không 5xx, status, content type, schema và header của response, `ignored_auth`,
  `negative_data_rejection`; `--rate-limit 5/s`, `--max-examples 25`, seed ngẫu nhiên (`SVP_DAST_SEED=<n>` chạy lại seed của
  `report.json`), hạn cả lượt 10 phút (`SVP_DAST_TIMEOUT`, gồm pull image; quá hạn thì script dừng container và kill docker client, vì macOS không có
  `timeout(1)`). Container có địa chỉ riêng nên bucket rate limit theo IP của nó tách khỏi bước đăng ký ở trên và mọi bước khác. Mọi output của Schemathesis vào `.dast/<time>/schemathesis.log` (mode 700,
  gitignore; cùng `junit.xml`, `requests.har` mang body của response, không bao giờ rời máy), terminal chỉ có tóm tắt in từ
  `report.json` và `summary.json` (phân bố status, tỷ lệ 429) sau khi hai tệp qua phép dò bí mật (JWT, token, cookie, chữ ký
  presigned, chính token của lượt); exit theo Schemathesis (0 đạt, 1 check trượt, 2 không chạy được), quá hạn hay lộ bí mật là 1.
  Một lượt ~3 phút 40 s, làm cạn rate limit theo IP và theo user: chạy sau các bước khác. **LOCAL LAB ONLY:** xoá khoá
  `svp:gw:rl:register:*` ở db 10 trước và sau lượt như `make smoke`.

## Game day

- Game day trên compose ([ADR-0020](../adr/0020-reliability-stage6.md) §13: tắt engagement-service dưới tải k6, người trực chỉ theo
  runbook `docs/runbooks/circuit-breaker-open.md`) chạy ở bài lab [`drills/` của `svp-labs`](https://github.com/anhnvcoder/svp-labs/tree/main/drills) (`make gameday` ở commit ghim);
  postmortem của lượt đã chạy ở `docs/postmortems/`.

## Giới hạn của script diễn tập

- `drill-obs-threats` dừng user-service và dựng lại gateway với cấu hình diễn tập qua `SVP_GATEWAY_REDIS_URL` rồi trả về mặc
  định, luôn bật lại mọi service khi kết thúc; biến này **chỉ dùng cho diễn tập**, không đặt trong `.env`. Không đọc database nào;
  trên Valkey chỉ xoá `svp:gw:rl:register:*` ở db 10 (như ở trên, qua CLI vận hành) và đọc session của chính user diễn tập ở db 9. Nó đọc Prometheus,
  Tempo, Loki qua datasource proxy của Grafana, API Alertmanager và API GlitchTip bằng token chỉ đọc, không in giá trị nào của `.env`.
- Trước diễn tập, `obs_preflight` (`deploy/compose/drills/common.sh`) đợi tối đa 60 s để metric của gateway xuất hiện trên stack vừa
  dựng. Gateway xuất metric mỗi 15 s (`internal/telemetry`), lần đầu một chu kỳ sau khi nó khởi động (reader định kỳ của OpenTelemetry
  SDK xuất ở mỗi tick, không xuất lúc khởi động), và `make up --wait` trả về vài giây sau khi gateway chạy, nên diễn tập chạy ngay
  sau đó chưa thấy mẫu nào. 60 s chứa bốn chu kỳ xuất, cộng batch của Collector (1 s) và việc nhận dữ liệu của LGTM.
- `obs_report` in các dòng WARN về đường đi của metric gateway tới Prometheus. Với `otelcol`, `lgtm` và gateway: trạng thái, health,
  số lần restart và số giây từ khi container khởi động; với `lgtm` còn số giây từ khi script chạy của nó ghi `/tmp/ready` (khi
  Collector riêng của nó nghe ở 4317) và số dòng log là mẫu mà Prometheus của nó từ chối; log của Collector dưới dạng số đếm (lỗi
  export theo nguyên nhân, tuổi của lỗi đầu tiên và mới nhất, dòng từ chối hay bỏ dữ liệu, từ chối vì bộ nhớ); số cảnh báo
  "telemetry export failed" gateway đã ghi. Sau đó là tuổi của mẫu mới nhất của `go_goroutine_count` (metric mà preflight đọc) trong
  Prometheus của từng service Go, và tên các metric `go_` của gateway ở đó. Chỉ tên và số, không bao giờ một dòng log của container:
  dòng kết luận của diễn tập tới artifact công khai của `verify.yml`. Hàm này không bao giờ thất bại.
