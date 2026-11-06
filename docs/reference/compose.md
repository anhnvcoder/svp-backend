# Stack compose, diễn tập, tải, DAST, game day

Loại tài liệu (Diátaxis): **reference**, tra cứu khi cần một lệnh hay một quy tắc cụ thể; luật làm việc ở [`AGENTS.md`](../../AGENTS.md).

## Stack compose

- `make up` / `make smoke` / `make down`: dựng stack compose profile `core` (bootstrap Postgres, Redpanda + tạo topic,
  object store `s3` (RustFS, [ADR-0022](../adr/0022-local-object-store-minio-replacement.md)) + job `s3-init` tạo
  bucket, user, policy, CORS, migrate, gateway, user-service, video-service, media-worker, engagement-service,
  feed-service, web client `web`), chạy luồng đầu-cuối qua gateway ở `127.0.0.1:8080` (gồm refresh token, dùng lại token
  cũ thì cả họ bị thu hồi, logout, follow, hồ sơ: handle tự chọn, trùng handle 409, handle sinh `u_…`, `GET`/`PATCH /me`
  không có email, `followed_by_me`, danh sách video theo tác giả chỉ tác giả thấy video chưa `READY`, tạo video với
  `Idempotency-Key` rồi gọi lặp cùng khoá nhận lại đúng `video_id` đó, upload video bằng presigned POST lên object store, chờ `READY`, tải HLS và thumbnail, output HLS bất biến
  ([ADR-0029](../adr/0029-immutable-media-versions.md): master ở `media/<id>/<version>/master.m3u8`, version là `event_id` của
  `video.uploaded`, biến thể và thumbnail dưới thư mục lần thử `<version>/<attempt>/`; master, một playlist biến thể, một segment
  và thumbnail mang `Cache-Control: max-age=31536000, immutable`), `GET /public/videos/{id}` không token 200 với video `READY`
  và một 404 cho video chưa `READY` lẫn id ngẫu nhiên, video vào feed following và explore kèm `author`, like/unlike, lượt
  xem, unfollow), rồi gỡ stack (giữ volume). Gateway dùng Redis native db 10 (rate limit), feed-service db 14 (cache feed
  khám phá), qua `host.docker.internal:6379`; web dùng db 9 (session). Object store chỉ nhận CORS từ `http://localhost:3001` và
  `http://localhost:3002`, theo bucket (`s3-init` đặt `PutBucketCors`: `uploads` chỉ `POST`, `media` chỉ `GET`, `HEAD`; danh
  sách toàn cục `RUSTFS_CORS_ALLOWED_ORIGINS` rỗng nên bucket khác không có header CORS; WEB-10): mở web bằng
  `127.0.0.1:3001` thì đăng nhập được nhưng không phát và không tải video lên được. Cổng publish chỉ trên `127.0.0.1`: 8080 gateway, 3001 web (mở
  bằng `http://localhost:3001`), 9000 object store (API S3; console tắt, không cổng 9001), 19092 Redpanda (Kafka API). Xem object bằng
  `curl --aws-sigv4` chạy trong container `s3`, không mở cổng nào thêm. `make ps` và `make logs SVC=<tên>` để xem. `make smoke` và `make drill-obs-threats` cần
  `redis-cli` trên máy và Redis native đang chạy: trước khi chạy, script xoá khoá rate limit đăng ký theo IP
  `svp:gw:rl:register:*` ở db 10 (`SCAN` + `DEL`, không `FLUSHDB`), vì mọi request đi ra từ một IP bridge của Docker và
  vài lần chạy trong một giờ sẽ cạn burst 20. Việc xoá này **chỉ dùng ở lab local**, không trỏ script vào stack dùng
  chung. Smoke luôn đòi master có version và kiểm đủ `Cache-Control` (mọi bản phát hành ghi key có version từ
  [ADR-0029](../adr/0029-immutable-media-versions.md); biến chuyển tiếp `SVP_SMOKE_LEGACY_MEDIA` đã bỏ, [ADR-0037](../adr/0037-mainpath-standard-tools.md) §4).
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
  idempotent, không đổi giá trị đã đặt. `make up OBS=lgtm` tự gọi nó. Database `svp_glitchtip` trên Postgres native, hai
  role `svp_glitchtip_migrator`, `svp_glitchtip_app` do bootstrap Postgres của `make up` tạo.
- `make otelcol-validate`: `validate` của Collector ghim (`--network none`) cho cấu hình `obs`, cấu hình `obs-elastic`
  (file `deploy/observability/elastic/otelcol-config.yaml` ghép đè lên file `obs`) và cấu hình của cluster k3d
  (`deploy/observability/otelcol/k8s-config.yaml`); chạy lại sau khi sửa một trong ba.
- `make slo`: sinh `deploy/observability/prometheus/rules/slo-generated.yaml` từ `deploy/observability/slo/svp-slos.yaml`
  bằng Sloth; file sinh được commit, chạy lại sau khi sửa spec. `make slo-check`: promtool của image LGTM ghim, không
  mạng: `check config` cho cấu hình Prometheus và hai file rule, rồi `test rules` (`svp-alerts.test.yaml`).
- `make test-stack`: `go test -race -count=1 -v` trên stack đang chạy (`make up`), đặt các biến `SVP_TEST_*` cho object store
  và Redpanda, nên integration test của `internal/objstore` chạy thật thay vì SKIP (gồm ca multipart CRC32 bằng user thử
  `svp-objstore-probe`, dạng header qua `http://` và dạng trailer qua proxy TLS của test; `Cache-Control` lưu và trả lại khi GET
  ẩn danh, ghi có điều kiện `If-None-Match: *` chỉ một lần thành công, user của media-worker đọc và liệt kê được `media/`). Chỉ ba secret S3 (hai service và
  user thử) lấy từ `.env`; endpoint,
  access key, broker, `SVP_TEST_POSTGRES_URL` và `SVP_TEST_REDIS_URL` cố định trong `deploy/compose/compose.mk` và
  `Makefile`. Thu hẹp bằng `PKGS=` như `make test`, `TESTFLAGS` thêm cờ.
- `make clean-data`: gỡ stack (mọi profile) và xoá volume của nó (topic Redpanda, bucket của object store `s3-data`, thư mục
  tạm của media-worker, dữ liệu LGTM, silence của Alertmanager, chỉ mục Elasticsearch); Postgres native (cả `svp_glitchtip`)
  không bị đụng; volume của project mà compose không còn khai được giữ và in ra. Chỉ chạy khi cần làm lại dữ liệu từ đầu.
- Diễn tập compose đo một lần (`drill-kill-worker`, `drill-duplicates`, `drill-duplicates-feed`, `drill-engagement-down`,
  `drill-rate-limit`, `drill-upload-cleanup`, `drill-alert-to-sentry`, `measure-ready`, `measure-freshness`, `measure-explore-cache`,
  game day) không còn ở repo này: bản đóng băng cùng [`tools/fakefollows/`](https://github.com/anhnvcoder/svp-labs/tree/main/drills/svp-backend/tools/fakefollows/) và cách chạy lại ở commit ghim là bài lab
  [`drills/` của `svp-labs`](https://github.com/anhnvcoder/svp-labs/tree/main/drills) ([ADR-0039](../adr/0039-mainpath-drills-scan-gate-sourcemaps.md) bảng 1,
  [ADR-0050](../adr/0050-bash-to-standard-tools.md)); số đo và id lượt chạy giữ ở ADR của từng diễn tập.
- `make drill-obs-threats`: diễn tập các dòng threat model về telemetry, chỉ trên stack `make up OBS=lgtm`, cần
  GlitchTip đã khởi tạo (`SENTRY_DSN`, `SENTRY_AUTH_TOKEN` trong `.env`, do `make up OBS=lgtm` hay `make glitchtip-init`
  ghi; script chỉ nhận `SENTRY_API_URL=http://127.0.0.1:8000`, không cổng loopback nào khác). Kiểm: JWT-8 (trace, log, event GlitchTip của request login/feed/follow, cả lúc user-service tắt, không có email, mật
  khẩu, token), UP-8 (`video created`, `upload completed` có `user_id`, `video_id`, `trace_id`), OPS-1 (`/debug/pprof/`,
  `/metrics` trả 404; project publish đúng 7 cổng loopback, gồm web 3001 và `s3` 9000, không 9001), RL-2 (gateway dựng lại với Redis `.invalid` thì metric
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
  video `READY` (`make smoke` tạo); từ chối khi stack tắt hay cluster k3d chạy; container k6 vào mạng `svp_web`, gọi
  `http://gateway:8080` và `http://web:3001` (`Host`, `Origin` là `http://localhost:3001`); tóm tắt ở
  `.k6/<profile>-<time>/summary.json` (gitignore; không `setup_data`, token, cookie, mật khẩu, grep kiểm), exit ≠ 0 khi một
  threshold trượt. **LOCAL LAB ONLY:** cả hai xoá khoá `svp:gw:rl:register:*` ở db 10 như `make smoke`.

## DAST

- `make dast` (DAST theo OpenAPI, [ADR-0030](../adr/0030-devsecops-supplement.md) §3, target ở
  `deploy/dast/dast.mk`, logic ở `deploy/dast/run.sh`, cấu hình `deploy/dast/schemathesis.toml`): Schemathesis chỉ bằng
  `SCHEMATHESIS_IMAGE` ghim của `Makefile`, trên stack `make up` đang chạy (`core` là đủ); từ chối khi gateway không chạy, mạng
  `svp_web` không có hay cluster k3d chạy. Đăng ký và đăng nhập một user thử (token chỉ trong môi trường, không in), container
  vào `svp_web` gọi `http://gateway:8080` với 20 operation của `services/gateway/openapi.yaml` (trừ `/healthz`, `/readyz`), phase
  `examples`, `coverage`, `fuzzing`, check không 5xx, status, content type, schema và header của response, `ignored_auth`,
  `negative_data_rejection`; `--rate-limit 5/s`, `--max-examples 25`, seed ngẫu nhiên (`SVP_DAST_SEED=<n>` chạy lại seed của
  `report.json`), hạn cả lượt 10 phút (gồm pull image). Mọi output của Schemathesis vào `.dast/<time>/schemathesis.log` (mode 700,
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
  trên Redis chỉ xoá `svp:gw:rl:register:*` ở db 10 (như ở trên) và đọc session của chính user diễn tập ở db 9. Nó đọc Prometheus,
  Tempo, Loki qua datasource proxy của Grafana, API Alertmanager và API GlitchTip bằng token chỉ đọc, không in giá trị nào của `.env`.
