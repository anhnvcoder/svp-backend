# Stack compose, diễn tập, tải, DAST, game day

Loại tài liệu (Diátaxis): **reference**, tra cứu khi cần một lệnh hay một quy tắc cụ thể; luật làm việc ở [`AGENTS.md`](../../AGENTS.md).

## Stack compose

- `make up` / `make smoke` / `make down`: dựng stack compose profile `core` (bootstrap Postgres, Redpanda + tạo topic,
  object store `s3` (RustFS, [ADR-0022](../adr/0022-local-object-store-minio-replacement.md)) + job `s3-init` tạo
  bucket, user, policy, CORS, migrate, gateway, user-service, video-service, media-worker, engagement-service,
  feed-service, web client `web`), chạy luồng đầu-cuối qua gateway ở `127.0.0.1:8080` (gồm refresh token, dùng lại token
  cũ thì cả họ bị thu hồi, logout, follow, hồ sơ: handle tự chọn, trùng handle 409, handle sinh `u_…`, `GET`/`PATCH /me`
  không có email, `followed_by_me`, danh sách video theo tác giả chỉ tác giả thấy video chưa `READY`, upload video bằng
  presigned POST lên object store, chờ `READY`, tải HLS và thumbnail, output HLS bất biến
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
  `curl --aws-sigv4` chạy trong container `s3` (như `make drill-upload-cleanup`), không mở cổng nào thêm. `make ps` và `make logs SVC=<tên>` để xem. `make smoke` và mọi script diễn tập cần
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
  `deploy/compose/compose.yaml` đọc): không đặt `IMAGES` thì sáu service backend build từ working tree như trước; `IMAGES=stg` chạy
  bản phát hành stg của sáu service (bốn job migrate cùng image) theo digest của `envs/stg/images/` trong bản clone `svp-gitops` như
  đang có (không fetch), không build Go. `WEB_FROM` không đặt hay `stg`: bản web của stg theo digest (nên `make up` cần bản clone
  `svp-gitops` và mạng tới GHCR); `clone`: build web từ thư mục web (`web_dir`, mục `make web-clone` của [`k8s.md`](k8s.md)); `image`: `WEB_IMAGE`.
  Mỗi bản của stg phải là repository của một nguồn phát hành có service đó
  (bảng nguồn của working tree) và GHCR cho kéo ẩn danh (`WEB_IMAGE` cũng phải kéo ẩn danh được); `make up` `docker pull` từng digest
  theo kiến trúc máy trước khi dựng (kéo không được thì dừng trước khi chạy gì), bản phát hành chạy với `pull_policy: never`, có bản
  phát hành thì bỏ `--build` (service còn lại vẫn build). Giá trị sai (`IMAGES` khác `stg`, `WEB_IMAGE` thiếu `WEB_FROM=image`, tag
  thay digest) thì dừng nêu lý do. Chế độ này cho job e2e: target diễn tập dựng lại service bằng `compose up --no-deps` không mang
  biến của `make up` (sẽ build lại service đó từ working tree), nên mọi script diễn tập (`deploy/compose/drills/common.sh`) từ chối
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
  không bị đụng; volume của project mà compose không còn khai (`svp_minio-data`, dữ liệu MinIO trước khi đổi store, đường
  quay lại) được giữ và in ra. Chỉ chạy khi cần làm lại dữ liệu từ đầu.
- `make object-store-copy TO=s3|minio` (script `deploy/compose/object-store-copy.sh`, [ADR-0022](../adr/0022-local-object-store-minio-replacement.md)
  mục Cách chuyển): chép bucket `uploads`, `media` từ volume MinIO `svp_minio-data` sang volume RustFS `svp_s3-data` (`s3`)
  hay ngược lại (`minio`, đường quay lại), dựng tạm hai store trên network nội bộ không publish cổng (MinIO bằng image
  Chainguard ghim digest trong script, mật khẩu root ngẫu nhiên mỗi lượt), chép bằng `mc mirror` của image đó không
  `--remove`, không `--overwrite`, rồi kiểm key, kích thước, `Content-Type` hai phía. Từ chối khi stack compose hay cluster
  k3d đang chạy, container nào đang dùng một trong hai volume, còn video `PROCESSING` (`SELECT` trên `svp_video`), hay đích có
  key mà nguồn không có hoặc cùng key khác kích thước (không ghi gì); in key của video `READY` đã mất từ trước ở cả hai phía
  (không chặn). Không bao giờ xoá hay ghi đè object, không xoá volume nào; xoá ở đích hay xoá volume cũ là việc của người học.

## Diễn tập trên stack compose

- `make drill-kill-worker`, `make drill-duplicates`, `make measure-ready N=5`: diễn tập trên stack đang chạy, script ở
  `deploy/compose/drills/`. Lần lượt: kill media-worker giữa lúc transcode rồi kiểm video vẫn `READY` đúng một lần và master
  trỏ đúng một thư mục lần thử (thư mục của thumbnail); phát lại event bằng `rpk group seek` rồi kiểm không gì đổi: media-worker
  thấy master của version, không transcode (log `transcode output exists`), không object nào dưới `media/<id>/` thêm hay ghi lại
  (key và ETag, liệt kê bằng request có chữ ký trong container `s3`), `transcode.completed` phát lại giống từng byte; đo `CompleteUpload` → `READY` cho N video 60 s 1080p (p50, p95,
  max, CPU/RAM của media-worker).
- `make drill-duplicates-feed`, `make drill-engagement-down`, `make measure-freshness FOLLOWERS=10000 N=10`: diễn tập
  phần feed, cùng chỗ. Lần lượt: phát lại `view.recorded`, `user.followed`/`user.unfollowed` và `video.ready` bằng
  `rpk group seek` rồi kiểm bộ đếm và dòng feed không đổi; tắt engagement-service rồi kiểm circuit breaker của gateway mở
  (like trả 503 trong < 100 ms), feed vẫn 200 không có `stats`, bật lại thì breaker tự đóng và like trả 204; đo độ tươi
  `video.ready` → dòng timeline cuối cho N video (tối đa 10: một tác giả, burst upload 10) tới FOLLOWERS follower giả
  (`tools/fakefollows` phát `user.followed` vào Redpanda, dọn bằng `user.unfollowed` khi kết thúc).
- `make drill-rate-limit`, `make measure-explore-cache N=100`, `make drill-upload-cleanup`: diễn tập phần Redis, cache và
  job dọn, cùng chỗ. Lần lượt: vượt ngưỡng thì 429 `RATE_LIMITED` có `Retry-After`, mở quá 3 form upload thì 429
  `TOO_MANY_UPLOADS`, Redis không tới được (gateway dựng lại với `REDIS_URL` trỏ tên miền `.invalid`, Redis native không
  bị tắt) thì login vẫn bị giới hạn bằng bộ đếm dự phòng còn feed, like, lượt xem vẫn chạy; hai sóng N request đồng thời
  (mặc định 100, tối đa 150, sóng đầu lúc cache trống) chỉ đọc Postgres một lần, không kể lần đọc do Redis quá hạn 50 ms
  (dòng `explore page loaded from database` có `cache=timeout`, hoặc đứng ngay sau dòng có `cache_write=timeout`: SET
  quá hạn nên lần đọc sau không thấy trang; đạt khi tổng ≥ 1 và tổng − `timeout` − số dòng sau SET quá hạn ≤ 1, in tổng,
  `timeout`, `miss`, `error`, số dòng sau SET quá hạn), script xoá khoá `svp:feed:explore:*` ở db 14 trước khi đo; video
  bỏ dở quá hạn chuyển `FAILED` và object `uploads/<id>` bị xoá (mọi video khác nằm `UPLOADING` quá 20 s cũng bị dọn).
- `make drill-alert-to-sentry`, `make drill-obs-threats`: diễn tập quan sát và cảnh báo, chỉ trên stack `make up OBS=lgtm`, cần
  GlitchTip đã khởi tạo (`SENTRY_DSN`, `SENTRY_AUTH_TOKEN` trong `.env`, do `make up OBS=lgtm` hay `make glitchtip-init`
  ghi; script chỉ nhận `SENTRY_API_URL=http://127.0.0.1:8000`, không cổng loopback nào khác). Lần lượt: tắt feed-service,
  đo từ lúc cảnh báo page `FeedAvailabilityBudgetBurn` có trong Alertmanager (T1) tới khi trace (Tempo), dòng log (Loki)
  và event GlitchTip cùng một `trace_id` đều tìm thấy (T4), đạt khi T4 − T1 < 5 phút; trước khi tắt, script chờ cảnh báo
  của lần chạy trước resolve (tới khoảng 30 phút) và 31 s không có 5xx ở feed. Kiểm các dòng về telemetry của threat
  model: JWT-8 (trace, log, event GlitchTip của request login/feed/follow, cả lúc user-service tắt, không có email, mật
  khẩu, token), UP-8 (`video created`, `upload completed` có `user_id`, `video_id`, `trace_id`), OPS-1 (`/debug/pprof/`,
  `/metrics` trả 404; project publish đúng 7 cổng loopback, gồm web 3001 và `s3` 9000, không 9001), RL-2 (gateway dựng lại với Redis `.invalid` thì metric
  `store="fallback"` > 0 và cảnh báo `RateLimitFallbackActive` trong 4 phút), WEB-9 (web trên compose: email, token,
  sid, `?next=`, chữ ký presigned từ form của web, `/rum` và `/monitoring` không có trong GlitchTip, Tempo, Loki, Prometheus;
  đối chứng có dữ liệu của web). **Telegram tuỳ chọn:** người học tự tạo bot
  và điền `SVP_ALERT_TELEGRAM_BOT_TOKEN`, `SVP_ALERT_TELEGRAM_CHAT_ID` vào `.env`; có đủ cả hai thì Alertmanager gửi cảnh
  báo `severity=page` tới `api.telegram.org` (ngoại lệ hẹp về mạng ngoài của lab) và `drill-alert-to-sentry` kiểm số
  thông báo đã gửi; thiếu thì không gửi gì, bước đó SKIP. Có cả hai biến mà Alertmanager đang chạy chưa nạp receiver thì
  FAIL trước khi tắt service.

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

- `make gameday`, `make gameday-mark M=diagnosed|mitigated|recovered`, `make gameday-end` (game day, ADR-0020 §13, script
  `deploy/compose/drills/gameday.sh`): chỉ trên stack `make up OBS=lgtm` có video `READY`. `gameday` chạy suốt buổi ở một
  terminal: tải nền k6 `local` (container `svp-gameday-k6`, giữ `SVP_K6_HOLD`, mặc định 60 phút), chờ 2 phút ổn định, **T0**
  dừng engagement-service, **T1** khi `CircuitBreakerOpen` có trong Alertmanager; người trực xử lý theo runbook
  `docs/runbooks/circuit-breaker-open.md` và ghi mốc bằng `gameday-mark` ở terminal khác. `gameday-end` hay Ctrl-C: dừng tải,
  bật lại service (chỉ khi đã qua T0), ghi dòng thời gian, báo cáo và tóm tắt k6 ở `.k6/gameday-<time>/`. Container
  `svp-gameday-k6` còn sót thì `gameday` từ chối chạy và in lệnh xoá. Postmortem viết từ mốc thật ở `docs/postmortems/`.
  **LOCAL LAB ONLY:** xoá khoá `svp:gw:rl:register:*` ở db 10 như `make smoke`.

## Giới hạn của script diễn tập

- Script diễn tập dừng/khởi động container, chỉ `SELECT` trên `svp_video`, `svp_engagement`, `svp_feed`, và luôn bật lại
  mọi service khi kết thúc. Trên Redis, ngoài hai thao tác xoá ở trên (`svp:gw:rl:register:*` ở db 10,
  `svp:feed:explore:*` ở db 14) script chỉ đọc. `drill-rate-limit`, `drill-obs-threats` và `drill-upload-cleanup` dựng lại
  gateway hay video-service với cấu hình diễn tập qua `SVP_GATEWAY_REDIS_URL`, `SVP_UPLOAD_ABANDON_AFTER`,
  `SVP_UPLOAD_SWEEP_INTERVAL` rồi trả về mặc định; ba biến này **chỉ dùng cho diễn tập**, không đặt trong `.env` (hạn dọn
  upload dưới 15 phút ngắn hơn hạn form upload). Hai diễn tập quan sát (`drill-alert-to-sentry`, `drill-obs-threats`) đọc Prometheus, Tempo, Loki qua datasource proxy
  của Grafana, API Alertmanager và API GlitchTip bằng token chỉ đọc, không in giá trị nào của `.env`.
