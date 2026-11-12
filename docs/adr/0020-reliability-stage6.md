# 0020. Độ tin cậy chia hai phần: phần chạy được trên máy (k6 theo SLO bằng image ghim, SLO web, backup/restore Postgres bằng CloudNativePG và plugin Barman Cloud có RTO/RPO đo trên k3d, runbook, game day, RFC, stack trong CI) và phần đo thật (k6 tải lớn và 1 000 req/s, Chaos Mesh, Velero, hai media-worker) chỉ viết và kiểm tĩnh

- Trạng thái: Chấp nhận
- Ngày: 2026-10-24
- Người quyết: người học (chia hai phần, job `stack` ngoài `ci-ok`, kiểm chứng dồn trước buổi cloud); phần còn lại theo đề xuất của ADR này

## Bối cảnh và vấn đề

- Lộ trình đặt cho độ tin cậy: kịch bản k6 theo SLO (báo p95/p99), Chaos Mesh (kill pod, làm chậm mạng, tắt Redpanda), diễn tập backup/restore (Postgres + Velero), runbook, game day + postmortem, tuỳ chọn Istio ambient. **Xong khi:** có báo cáo tải, báo cáo chaos và RTO đo thật của lần restore. Máy 16 GB (Apple M2) không chịu đo tải hay chaos trên k3d ([ADR-0017](0017-gitops-capacity-media-worker-max2.md)): tối đa một buổi k3d đường dev, compose một lượt mỗi phép kiểm; repo công khai; mọi lệnh chạm AWS do người học chạy.
- Hiện trạng lúc quyết: bốn SLO của [ADR-0011](0011-observability-stage3.md) §8 chỉ ở gateway và video-service, web chỉ có RUM; gateway có 8 lớp rate limit theo IP hay `user_id` ([ADR-0010](0010-redis-ratelimit-cache-resilience-stage2c.md) §2) mà k6 từ một địa chỉ sẽ chạm trước hệ thống; Postgres trên k3d là CloudNativePG `svp-pg` image `minimal`, chưa backup, chưa `cnpg_*`; probe dùng hạn mặc định 1 s; pod mới có Postgres restart một lần vì lần nối đầu bị từ chối; hạn 50 ms của lệnh Redis chưa có p99 dưới tải; chưa có kịch bản tải, kiểm schema manifest hay job dựng stack trong CI; LCP mobile chưa đạt ([ADR-0018](0018-web-profiles-public-video-upload.md)).
- Bảng kiểm version, digest và source (k6, kubeconform, CloudNativePG, plugin Barman Cloud, Chaos Mesh, Velero, Next, OTel) ở [phụ lục](appendix/0020-reliability-stage6.md#kiểm-chứng-đã-kiểm-ngày-2026-10-24).

## Yếu tố quyết định

- Phần học không cần tải lớn phải xong trên máy; buổi cloud tính tiền theo giờ chỉ còn chạy lệnh đã viết, kiểm tĩnh sẵn.
- Một bản công cụ ghim cho máy, CI và cluster; không bí mật nào ra kết quả hay artifact công khai; không nới rate limit hay quyền để đo.
- Phục hồi giống cách dịch vụ managed làm (bản sao vật lý + WAL, PITR), RTO/RPO đo được; tiêu chí đạt viết trước khi đo.

## Phương án đã cân nhắc

- §1 làm hết ở local (máy không chịu, số chỉ nói về laptop)
- §1 dời hết sang cloud (buổi tính tiền vừa viết vừa chạy)
- §1 **chia hai**
- §2 k6: **image `grafana/k6` ghim digest**
- §2 k6: Homebrew (không ghim)
- §2 k6: `go install` (build nặng, cluster vẫn cần image)
- §2 k6: k6 Cloud (SaaS)
- §2 k6: k6-operator (thêm CRD)
- §2 k6: tải từ laptop
- §3 SLO web: **SLI 5xx trên mọi response**
- §3 SLO web: SLI lọc theo route
- §3 SLO web: SLO độ trễ SSR
- §3 SLO web: span metric
- §3 SLO web: preload OTel
- §3 SLO web: `spanmetrics` của Collector
- §3 SLO web: **nạp lại `http` ngay sau `sdk.start()`**
- §3 SLO web: INP **chỉ ticket** thay vì page
- §5 backup: `pg_dump` trên compose
- §5 backup: `barmanObjectStore` (deprecated)
- §5 backup: **plugin Barman Cloud**
- §5 backup: plugin làm sidecar của operator
- §5 backup: snapshot PVC
- §5 backup: diễn tập ra Cluster tên khác
- §6 Velero: không Velero
- §6 Velero: **CSI snapshot của EBS, không data mover**
- §6 Velero: data mover Kopia
- §6 Velero: file-system backup
- §6 Velero: giữ Secret trong backup
- §7 chaos: **Chaos Mesh 2.8.5 `clusterScoped: false`**
- §7 chaos: Chaos Mesh mặc định
- §7 chaos: Litmus
- §7 chaos: `kubectl` bằng tay
- §7 chaos: AWS FIS
- §8 `helm template`
- §8 `--dry-run=server`
- §8 kubeconform + CRDs-catalog
- §8 **kubeconform `-strict` với schema sinh từ CRD đúng bản ghim**
- §10 probe: giữ 1 s
- §10 probe: nới mọi probe như nhau
- §10 probe: **nới liveness và startup, readiness vừa đủ**
- §13 tắt feed-service
- §13 **tắt engagement-service**
- §14 chỉ ADR
- §14 **RFC một trang cạnh ADR**
- §15 `stack` trong `ci-ok`
- §15 **`stack` chỉ báo**
- §15 workflow thứ ba

Bảng được/mất ở [phụ lục](appendix/0020-reliability-stage6.md).

## Tên chốt

Code, cấu hình, diễn tập và tài liệu dùng đúng các tên này; đổi tên nào thì sửa ADR này trước. Bảng đầy đủ (giá trị, digest) ở [phụ lục](appendix/0020-reliability-stage6.md#tên-chốt).

- Image `K6_IMAGE`, `KUBECONFORM_IMAGE` (`Makefile`); target `make k6-check`, `load-local`, `load-ci`, `cloud-check`, `drill-k8s-backup` (`MODE=latest|pitr`), `gameday`, `gameday-mark M=<mốc>`, `gameday-end`.
- k6: `deploy/k6/main.js`, `lib/`, `load.sh`, `deploy/k6/cloud/` (`job.yaml.in`, `render.sh`, `run.sh`); biến `SVP_K6_PROFILE` (`local`, `ci`, `cloud`), `SVP_API_URL`, `SVP_WEB_URL`, `SVP_WEB_ORIGIN`, `SVP_K6_RESULTS`, `SVP_K6_HOLD`, `SVP_K6_FORWARDED_FOR` (không tiền tố `K6_`); tag `route`, `app`, `phase`; metric `svp_rate_limited`; kết quả `.k6/<profile>-<yyyymmddThhmmssZ>/summary.json`.
- SLO `web-availability` (`WebAvailabilityBudgetBurn`), `web-inp` (`WebINPBudgetBurn`); cảnh báo `PostgresWALArchivingFailing` (page), `PostgresBackupTooOld` (ticket) nhóm `postgres-backup`.
- Backup: component `plugin-barman-cloud` (`cnpg-system`, wave 3); bucket `pg-backups`, user `svp-pg-backup`, `SVP_PG_BACKUP_S3_SECRET_KEY`, Secret `svp-data/pg-backup-s3`; ObjectStore `svp-pg-backup`; ScheduledBackup `svp-pg-daily`; value `postgres.backup.serverName`; database diễn tập `svp_drill`; PodMonitor `svp-pg`.
- Tài liệu `docs/runbooks/`, `docs/postmortems/`, `docs/rfc/0001-reliability.md`; job `stack` (artifact `lighthouse`, `k6-summary`); `deploy/k8s/cloud/` (`charts.json`, `values/`, `chaos/`, `velero/`); namespace `svp-load`, `chaos-mesh`, `velero`; `CLOUD_K8S_VERSION`.

## Kết quả quyết định

Chọn chia hai phần, vì phần chạy được trên máy (k6 nhỏ, SLO web, backup Postgres, runbook, game day, RFC, CI) không cần tải lớn, còn tải, chaos, Velero chỉ có nghĩa trên cluster đủ tài nguyên; mỗi § dưới giữ quyết định, chi tiết và các lần sửa có ngày ở phụ lục.

### 1. Hai phần, mỗi phần có "Xong khi" riêng

- Phần local đóng khi: `make k6-check` sạch và một lượt `make load-local` trên `make up OBS=lgtm` (p95/p99 theo route phía k6 và server, tỷ lệ 5xx, 429 = 0, `dropped_iterations`, điều kiện máy, câu "không kết luận năng lực"); `web-availability`, `web-inp` trong spec Sloth, `make slo-check` sạch; quy tắc §4 áp; `make drill-k8s-backup` PASS hai lượt liền trên cluster dev (`MODE=latest` rồi `MODE=pitr`) có RTO, RPO; không pod nào restart, log thử lại có số lần (§10, §11); runbook cho mọi cảnh báo `severity=page` và mẫu postmortem; một buổi `make gameday` dưới tải k6 có postmortem; RFC; job `stack` chạy ở lượt PR đầu; LCP mobile `/` và `/v/{id}` ≤ 2 500 ms (median 3 lượt `make web-lighthouse`); `make cloud-check` sạch, ca cố ý hỏng FAIL.
- "Xong khi" của lộ trình (báo cáo tải, báo cáo chaos, RTO đo thật) đạt trọn khi phần đo thật chạy: k6 1 000 req/s (§2), Chaos Mesh (§7), Velero (§6), hai media-worker cùng transcode và RAM nghỉ (§9). Mỗi mục ghi sẵn lệnh và tiêu chí đạt; mọi lệnh chạm cloud do người học chạy với context của cluster cloud ghi trong lệnh; script cloud từ chối context `k3d-*` và context rỗng trước khi làm gì.
- Phần đo thật chia tiếp: không cần dịch vụ AWS/GCP thì chạy ở kiểm chứng dồn ([ADR-0021](0021-deferred-verification-stage6b.md): k6 thu nhỏ, ba thí nghiệm Chaos Mesh, Velero đích object store trong cluster, hai media-worker, RAM nghỉ, ngưỡng p99 canary và HPA web, thay MinIO, ngưỡng page `RateLimitFallbackActive`); cần cloud thì ở buổi EKS (k6 1 000 req/s bằng Job 20 pod, diễn tập phục hồi RDS, Velero với S3 và snapshot EBS, R2/CDN, hạn 50 ms của Redis managed). Các § dưới giữ thiết kế viết cho cluster cloud; phần đổi cho runner ghi ở ADR-0021.

### 2. k6: image ghim, kịch bản theo SLO, ba profile, user và rate limit

- **`K6_IMAGE := grafana/k6:2.3.0@sha256:…`** ghim digest, dòng `# renovate: datasource=docker depName=grafana/k6`; v2 thay v1.8.2 (nhánh v1 chỉ còn vá bảo mật): không `k6/experimental/redis`, `http.get(url, params)` đúng hai tham số.
- Kịch bản `deploy/k6/`: module `api` (feed khám phá và following, like, lượt xem, `POST /videos`) và `web` (`/` đã đăng nhập, `/v/{id}` khách, `/login`) chạy chung qua `main.js`, profile bằng `SVP_K6_PROFILE`; tag `route` là template, trùng `http_route` của gateway và `route` của RUM. `http.setResponseCallback(http.expectedStatuses({ min: 200, max: 499 }))`: `http_req_failed` chỉ đếm 5xx và lỗi kết nối; 429 đếm riêng vào `svp_rate_limited`; mỗi request có `check`.
- Pool user không tự chặn mình: `local` 20 user, `ci` 5, target xoá khoá `register` trước (**LOCAL LAB ONLY**); `cloud` Job Indexed 20 pod, mỗi pod đăng ký 12 user (pool 240), không xoá khoá nào; nếu chốt 2 hop proxy thì mỗi pod tự ghi `X-Forwarded-For: <IP pod>`. Tốc độ: `local` `ramping-arrival-rate` 30 s lên, giữ 5 phút (feed 9 + 7 req/s); `ci` `constant-arrival-rate` 60 s; `cloud` 10 phút lên, giữ ≥ 10 phút, 1 phút xuống, pod i nhận `--execution-segment` thứ i của 20, feed **1 000 req/s** (550 + 450, tổng khoảng 1 250 req/s), `/v/[id]` dưới 2 req/s mỗi IP. Không seed user thẳng vào `svp_user`; **không thêm cờ tắt rate limit vào gateway**. Bảng route → lớp → khoá và cỡ từng profile ở phụ lục.
- Threshold (`local`, `cloud`; `ci` chỉ dòng lỗi): `http_req_failed` `rate<0.001` cho feed, `/videos`, web; `http_req_duration` `p(99)<150` cho feed; like, lượt xem chỉ ngưỡng lỗi; `svp_rate_limited` `count==0`, `checks{phase:load}` `rate>0.999`, `dropped_iterations` `count==0`. Kết quả ghi cả p95/p99 phía server.

### 3. SLO của web

- **`web-availability` 99,9%**: error là `http_server_request_duration_seconds_count{service_name="web"}` có mã `5..`, total là mọi response của server web; `WebAvailabilityBudgetBurn` page và ticket, có runbook. Histogram là `http.server.request.duration` của instrumentation http, có được nhờ nạp lại `http` qua hook ngay sau `sdk.start()` (một dòng trong `web/server/telemetry/otel.ts`, giữ bằng `http-server.test.ts`). Span metrics của Tempo chỉ để ghi số độ trễ theo route.
- **`web-inp` 75%** lượt có INP ≤ 200 ms (bucket 0,2 của `svp_web_vital_inp_seconds`), `page_alert.disable: true`, chỉ ticket `WebINPBudgetBurn`; không lượt RUM nào thì không ra tỷ lệ giả.
- Ngưỡng p99 canary của web (`canaryLimits.p99Ms: 500`) và HPA web giữ, quyết lại theo số k6 tải lớn.

### 4. Hạn 50 ms của lệnh Redis

Lượt k6 local trên `make up OBS=lgtm` đọc p99 lệnh Redis (`db_client_connections_use_time_milliseconds`, `type="command"`) của gateway (db 10) và feed-service (db 14), số lệnh `context_timeout`, đối chiếu log `cache=timeout`. **Quy tắc:** p99 local < 25 ms và không lệnh nào quá hạn thì giữ 50 ms; ngược lại ghi số và quyết lại trên Redis managed của cloud. Không đổi code.

### 5. Backup/restore Postgres: CloudNativePG + plugin Barman Cloud, diễn tập DR tại chỗ trên k3d

- **Plugin Barman Cloud** chart 0.8.1 (v0.15.1), component `plugin-barman-cloud` wave 3 (sau cert-manager, `cloudnative-pg`, trước `svp-data`), cả đường dev và GitOps; image plugin, sidecar ghim `tag: v0.15.1@sha256:…`, `replicaCount: 1`, requests 20m/64Mi, limit bộ nhớ 256Mi. **Giữ ClusterRole của chart** (manager cache cả cluster, không cờ thu hẹp): plugin đọc được mọi Secret, ghi ở BAK-1, `drill-k8s-threats` in ngoại lệ kèm lý do.
- Đích: bucket riêng `pg-backups` (job init tạo sẵn), user riêng `svp-pg-backup` chỉ có quyền bucket đó, secret key sinh bằng `make env`, vào Secret bằng `secrets.sh`, không in; compose không đổi. Cluster `svp-pg`: plugin `isWALArchiver: true` với `barmanObjectName: svp-pg-backup`, `serverName` từ value; `archive_timeout` giữ 5 phút; sidecar requests 50m/128Mi, limit 256Mi.
- **Thế hệ lưu trữ:** mỗi lần phục hồi một `serverName` mới `svp-pg-<yymmddhhmmss>`, nguồn là thế hệ đang chạy, PITR trong một thế hệ; Cluster phục hồi dựng bằng chính chart `svp-data`; `install.sh` đọc `serverName` của Cluster đang chạy và truyền `--set`, dừng trước khi nâng chart khi Cluster còn đang phục hồi. Argo CD tự sửa về git nên diễn tập **chỉ cho đường dev**.
- **`make drill-k8s-backup`** (chỉ `k3d-svp`, **LOCAL LAB ONLY**): ghi dòng đánh dấu vào `svp_drill.markers` mỗi giây 60 s sau khi có `Backup` `completed` và `ContinuousArchiving` True (thiếu thì dừng trước khi xoá); `MODE=pitr` ép `pg_switch_wal()` với mục tiêu ở giữa; xoá Cluster và PVC; **T0** dựng lại cùng tên bằng `bootstrap.recovery`; restart một lần 4 service có Postgres và GlitchTip; **T1** `k8s-smoke` qua; **RTO = T1 − T0**, **RPO** = lúc xoá − `written_at` lớn nhất còn lại; `pitr` đạt khi dòng cuối ≤ mục tiêu và cách dưới 1 s; rồi `Backup` thế hệ mới; JSON ở `.k8s/drills/` ghi `forced_wal_switch`, WAL cuối đã lưu, số dòng mất. Hai lượt liền (`latest` rồi `pitr`) PASS chứng minh thế hệ lưu trữ; dừng giữa chừng thì script in trạng thái và lệnh tay. Không bao giờ xoá backup. RPO thật do `archive_timeout` (5 phút) cộng thời gian lưu quyết định, cả khi tắt êm.

### 6. Velero (chỉ cluster cloud)

- Velero chỉ giữ **PV trong cluster** (trước hết của Redpanda) và việc dựng lại một namespace bị xoá nhầm, đo RTO; dữ liệu managed có backup riêng, trạng thái cluster nằm trong git, Secret tạo lại từ nguồn nên không vào backup.
- Chart, image, cấu hình và diễn tập `drill-restore.sh` (bước, RTO, lệnh cài và gỡ): [phụ lục](appendix/0020-reliability-stage6.md#chi-tiết-rút-khỏi-adr).

### 7. Chaos Mesh (chỉ cluster cloud)

- Chart `chaos-mesh` 2.8.5, image `controllerManager`, `chaosDaemon` ghim digest, pause của `pod-failure` là `registry.k8s.io/pause:3.10.2@sha256:…` (đa kiến trúc); người học cài bằng `helm`, không qua Argo CD. Namespace `chaos-mesh` PSA `privileged` chỉ trên cluster cloud, tạo và xoá trong buổi; `chaosDaemon.runtime: containerd`, `chaosDaemon.socketPath: /run/containerd/containerd.sock`. Tạo namespace có nhãn `pod-security.kubernetes.io/enforce=privileged` trước, `helm --kube-context <ctx> upgrade --install chaos-mesh chaos-mesh/chaos-mesh --version 2.8.5`, mỗi thí nghiệm `kubectl --context <ctx> apply`; cuối buổi gỡ chart, xoá namespace và CRD `chaos-mesh.org`.
- Ba thí nghiệm dưới tải k6 `cloud`, mỗi cái sau 5 phút ổn định: **(a)** `pod-kill` `mode: one` `gracePeriod: 0` cho gateway rồi feed-service, giả thuyết feed 5xx < 0,1% trong 10 phút, p99 ≤ 150 ms ngoài 30 s đầu, pod thay Ready dưới 60 s; **(b)** `NetworkChaos` `delay` 200 ms jitter 20 ms `mode: all` `direction: to` không `target`, 5 phút trên engagement-service, giả thuyết feed 200 (`stats` vắng), 5xx < 0,1%, p99 ≤ 150 ms, like, lượt xem không 5xx, `CircuitBreakerOpen` không cháy (p99 feed vượt 150 ms là phát hiện về ngân sách độ trễ của ADR-0010, không phải lỗi thí nghiệm); **(c)** `pod-failure` `mode: all` 5 phút ở `svp-data` (tắt Redpanda) với 3 upload, giả thuyết `POST /videos` và `complete` vẫn nhận, feed giữ SLO, lượt xem lỗi đếm riêng, sau đó outbox rút hết, mọi video `READY` đúng một lần, DLQ không tăng, lag về 0.

### 8. Kiểm tĩnh manifest cloud bằng kubeconform

- `KUBECONFORM_IMAGE := ghcr.io/yannh/kubeconform:v0.8.0@sha256:…` ghim, Renovate theo dõi. `make cloud-check` (không cần cluster, `.env`): render mọi chart của `deploy/k8s/cloud/charts.json`, Job k6 (`render.sh`), `chaos/`, `velero/`; sinh schema CRD từ CRD của đúng bản ghim bằng `/openapi2jsonschema`; `kubeconform -strict -summary -kubernetes-version $(CLOUD_K8S_VERSION)` với schema Kubernetes ở commit ghim, không `-ignore-missing-schemas` (kind không có schema là FAIL); kiểm thêm mọi thí nghiệm có `duration` và `selector.namespaces` (không rỗng, không `kube-system`), mọi image ghim `@sha256:`.

### 9. Hai media-worker cùng transcode và RAM nghỉ (chỉ cluster cloud)

Dùng lại `make drill-k8s-keda N=9` (tối đa 2 replica, ADR-0017) với context của cluster cloud (thêm tham số context và host cho `deploy/k8s/drills/`), media-worker trên node pool riêng (taint và toleration), service ở node pool khác; một lượt chung node để so là tuỳ chọn. **Đạt:** KEDA lên 2 replica, có cửa sổ cả 2 worker cùng transcode, mỗi video `READY` đúng một lần trong hạn 15 phút, scale down một pod đang transcode êm, không node nào NotReady và API server trả lời suốt diễn tập; ghi p50/p95 tới `READY` và CPU của node. RAM nghỉ: 60 s sau khi mọi pod Ready, `kubectl top` so với bảng ngân sách ADR-0014 §2; chỉnh `resources` của web (ADR-0019 §12). Xem lại `maxReplicaCount` theo CPU của node, tối đa bằng số partition.

### 10. Probe của chart `svp-service`

Cho cả nhánh HTTP và gRPC, trong template: liveness `timeoutSeconds: 5` (`periodSeconds: 10`, `failureThreshold: 3`); readiness `timeoutSeconds: 2` (`periodSeconds: 5`); startup gRPC `timeoutSeconds: 2`, `failureThreshold: 30` (60 s). Không thứ gì khác phụ thuộc hạn probe (Envoy theo EndpointSlice, canary đọc metric Envoy).

### 11. Thử lại kết nối Postgres lúc khởi động

`internal/pgpool` (`New`) và `internal/dbmigrate` (`Up`) thử lại **chỉ cho lỗi mạng** (từ chối kết nối, quá hạn dial, mất kết nối lúc bắt tay); không thử lại lỗi xác thực (`28P01`, `28000`), database không có (`3D000`), URL sai, TLS bị từ chối, tên miền không phân giải. Cửa sổ 30 s (nhỏ hơn 60 s startup probe), chờ 250 ms rồi gấp đôi tới tối đa 2 s, mỗi lần vẫn bị `ConnectTimeout` 5 s chặn; context bị huỷ thì dừng ngay. Log WARN `database not reachable, retrying` (`attempt`, `error`, không URL, mật khẩu) và INFO `database connected after retries` (`attempts`, `elapsed_ms`). Quy tắc bỏ pod restart của `measure-gitops` giữ nguyên.

### 12. Runbook và postmortem

`docs/runbooks/README.md` với mẫu cố định (Ý nghĩa và tác động; Kiểm tra nhanh 5 phút cho compose và k3d; Nguyên nhân thường gặp; Giảm thiểu; Khôi phục và xác nhận; Leo thang; Liên kết; lệnh theo quy ước của `AGENTS.md`); **một runbook mỗi cảnh báo `severity=page`**, tên file là tên alert kebab-case, cộng runbook cho sự cố đã gặp và quy trình tay; `runbook_url` = `https://github.com/anhnvcoder/svp-backend/blob/main/docs/runbooks/<file>.md` trên mọi rule page (spec Sloth và `svp-alerts.yaml`). Postmortem không đổ lỗi theo `docs/postmortems/README.md`, file `docs/postmortems/<yymmdd>-<slug>.md`.

### 13. Game day trên compose

Tắt engagement-service để `CircuitBreakerOpen` cháy dưới tải nền k6 `local` (`SVP_K6_HOLD` dài hơn, chờ 2 phút ổn định), trên `make up OBS=lgtm` có video `READY`: `make gameday` (T0 dừng container, T1 khi cảnh báo có trong Alertmanager), người trực xử lý **chỉ theo runbook** `circuit-breaker-open.md`, ghi mốc bằng `make gameday-mark M=diagnosed|mitigated|recovered`, `make gameday-end` dừng tải và luôn trả stack về như trước buổi (container tải `svp-gameday-k6`; dừng trước T0 thì không bật container nào); chỉ dừng, bật container của project, Redis chỉ các thao tác xoá được phép. Postmortem viết từ mốc thật, chỗ runbook thiếu sửa sau buổi.

### 14. RFC cho người không làm kỹ thuật

RFC một trang cạnh ADR: `docs/rfc/README.md` (mẫu: Vấn đề, Phương án, Chi phí, Rủi ro, Đề xuất, Quyết định cần từ người đọc) và `docs/rfc/0001-reliability.md`; không thuật ngữ chưa giải thích, mọi con số có nguồn hay ghi rõ là ước lượng.

### 15. Stack chạy trong CI

- Job `stack` trong `ci.yml`, **không vào `ci-ok`**, `ubuntu-24.04`, `permissions: contents: read`, không secret, action ghim SHA; Postgres, Redis là service container publish trên `127.0.0.1` và `172.17.0.1`, không trên mọi interface. Bước: `make env`, `make up`, `make smoke`, `make web-e2e`, `make load-ci` (chỉ threshold lỗi), `make web-lighthouse` chỉ báo, `make down` ở `if: always()`; `.env` dùng một lần, không in, không upload; gói apt của Ubuntu, không action bên thứ ba. Artifact chỉ `lighthouse` (đã lọc cookie) và `k6-summary`. `make k6-check`, `make cloud-check` vào job `config`. Xem lại khi 20 lượt `stack` liên tiếp xanh: đưa vào `ci-ok`.

### 16. Việc tồn

- LCP mobile `/` và `/v/{id}` ≤ 2 500 ms (median 3 lượt), giảm byte trước LCP, không nới CSP, CLS < 0,1 và TBT < 200 ms giữ đạt. `emailPattern` của `web/server/sentry/scrub.ts` sửa cho tuyến tính, không để lọt email nào bản cũ che (WEB-9). Thay MinIO cho đường local bằng ADR riêng ([0022](0022-local-object-store-minio-replacement.md)).

### 17. Threat model

[`docs/threat-model.md`](../threat-model.md) thêm BAK-1 (backup Postgres, plugin đọc mọi Secret, đường leo quyền từ operator và cách chặn ở §5), BAK-2 (Velero), RL-7 (xoá khoá rate limit, pool user của k6), SC-10 (job `stack` trên repo công khai), OPS-4 (Chaos Mesh), rủi ro chấp nhận mới, IN-3 theo §16.

### Hệ quả

- Tốt: kịch bản tải theo đúng SLO bằng một bản k6 ghim; lần đầu có SLO cho web, runbook cho mọi cảnh báo page, backup Postgres có phục hồi đã diễn tập với RTO/RPO đo được và cảnh báo lưu WAL; phần đo thật là lệnh và manifest đã kiểm schema, tiêu chí viết trước; pod không restart lúc khởi động.
- Xấu: plugin Barman Cloud đọc được mọi Secret của cluster dev (BAK-1); backup cùng cluster, cùng ổ, không mã hoá lúc nghỉ; diễn tập DR chỉ cho đường dev; job `stack` thêm 15–25 phút mỗi PR mà không chặn merge; số tải local không kết luận năng lực; Chaos Mesh, Velero cần đặc quyền lớn trong buổi đo; Velero không giữ event ghi sau lần backup cuối; `make cloud-check` cần mạng.
- Xem lại khi: histogram web có nhãn route (thêm SLO độ trễ SSR); RUM đủ lượt thật (cảnh báo INP); plugin có cờ giới hạn namespace (thu hẹp RBAC); CloudNativePG 1.31 phát hành (nâng operator cùng plugin); một pod k6 rơi iteration (thêm pod hay k6-operator); 20 lượt `stack` xanh; Redpanda còn trong cluster cloud (độ bền event bằng replication hay Kafka managed).

## Xác nhận

- Phần local đạt (bảng "Xong khi" của §1) trừ LCP: k6 không 429, không 5xx; SLO web có series trên compose và k3d; `make drill-k8s-backup` `latest` rồi `pitr` PASS trên cùng cluster; 0 restart; mọi rule page có `runbook_url`; game day có postmortem; job `stack` xanh ở lượt PR đầu; `make cloud-check` sạch.
- Hạn 50 ms (§4): p99 dưới 25 ms nhưng game day thấy lệnh quá hạn, nên ghi số và quyết lại trên Redis managed.
- LCP mô phỏng chưa đạt ổn định; người học chốt Lighthouse là tín hiệu hồi quy, chuẩn chất lượng là RUM p75.
- Trên runner ([ADR-0021](0021-deferred-verification-stage6b.md)): k6 thu nhỏ đạt tới 2 pod, Velero giữ offset, Chaos Mesh (a), (b), (c) đạt sau [ADR-0031](0031-chaos-findings-feed-engagement-tempo.md), hai media-worker đạt. Chưa kiểm: 20 pod k6, Pod Identity của Velero, version EKS.
- Số đo, RTO/RPO, mã lượt chạy ở [phụ lục](appendix/0020-reliability-stage6.md#kết-quả) và bảng [Kiểm chứng sau](appendix/0020-reliability-stage6.md#kiểm-chứng-sau).

## Hiện thực ở

- k6 (§2): `deploy/k6/` (`main.js`, `api.js`, `web.js`, `lib/`, `load.sh`, `k6.mk`), `deploy/k6/cloud/` (`render.sh`, `job.yaml.in`, `run.sh`). SLO web và cảnh báo (§3): `deploy/observability/slo/svp-slos.yaml`, `deploy/observability/prometheus/rules/svp-alerts.yaml`.
- Backup và phục hồi Postgres (§5): `deploy/helm/svp-data/templates/backup.yaml`, `deploy/helm/svp-data/values.yaml`, `deploy/k8s/values/plugin-barman-cloud.yaml`, `deploy/helm/svp-observability/templates/postgres.yaml`, `deploy/s3/init.sh`, `deploy/k8s/secrets.sh` (biến của `deploy/compose/compose.mk`), `deploy/k8s/install.sh`, `deploy/k8s/lib.sh`, `deploy/k8s/drills/backup.sh`, `deploy/k8s/drills/threats/bak-1/`, `deploy/ci/trivy-config-ignore.yaml`.
- Velero, Chaos Mesh, kubeconform (§6–§8): `deploy/k8s/cloud/` (`chaos/`, `velero/`, `values/`, `check.sh`, `charts.json`), `cloud-check` của `deploy/k8s/k8s.mk`, `renovate.json`.
- Probe (§10): `deploy/helm/svp-service/templates/deployment.yaml`. Thử lại Postgres (§11): `internal/pgretry/`, `internal/pgpool/`, `internal/dbmigrate/`.
- Game day (§13; bản đóng băng ở bài lab `drills/` của `svp-labs`, [0050](0050-bash-to-standard-tools.md)): [`deploy/compose/drills/gameday.sh`](https://github.com/anhnvcoder/svp-labs/blob/main/drills/svp-backend/deploy/compose/drills/gameday.sh), [`deploy/compose/compose.mk`](https://github.com/anhnvcoder/svp-labs/blob/main/drills/svp-backend/deploy/compose/compose.mk) (trích đoạn target). Job `stack` (§15): `.github/workflows/ci.yml`, `ci-bridge-check` của `Makefile`.
- Hiện trạng: [`explanation/reliability.md`](../explanation/reliability.md), [`reference/compose.md`](../reference/compose.md), [`reference/k8s.md`](../reference/k8s.md), runbook [`postgres-restore.md`](../runbooks/postgres-restore.md).

## Thông tin thêm

Phụ lục: [`appendix/0020-reliability-stage6.md`](appendix/0020-reliability-stage6.md) (tiêu đề và dòng trạng thái gốc, bảng kiểm version và source, tên chốt đầy đủ, bảng được/mất từng §, bảng route → lớp → khoá, các lần sửa có ngày, bảng "Kiểm chứng sau", kết quả tải, Redis, LCP, game day, RTO/RPO, mục "Chi tiết rút khỏi ADR").

### Chỉnh bởi

- §2, §6, §7: [0021](0021-deferred-verification-stage6b.md): `render.sh --pods`, `--ramp`, `--hold` và chế độ runner của `run.sh`; Velero trên k3d của runner (CSI hostpath, đích object store trong cluster, chế độ runner của `drill-restore.sh`); Chaos Mesh trên k3d của runner, mỗi thí nghiệm một lượt k6.
- §3, §4, §16: [0021](0021-deferred-verification-stage6b.md): `canaryLimits.p99Ms` của web 500 → 250 ms theo số k6 thu nhỏ (§8 của 0021); điều kiện page mới của `RateLimitFallbackActive` (§11 của 0021); quyết định giữ `Suspense` của feed (Kết quả "LCP") đảo theo D17 của 0021.
- §5, Tên chốt, §16: [0022](0022-local-object-store-minio-replacement.md): đích backup là RustFS `s3.svp-data:9000` thay MinIO (bucket, user `svp-pg-backup`, policy giữ, policy ở `deploy/s3/pg-backup-policy.json`); việc tồn "Thay MinIO" đã hiện thực.
- §7: [0031](0031-chaos-findings-feed-engagement-tempo.md): feed-service hai replica kèm PDB cho (a); Like/Unlike một câu SQL, hạn ghi 1 s, 503 `DEPENDENCY_UNAVAILABLE` không thử lại, pool riêng cho `GetStats` cho (b); Tempo tự giới hạn bộ nhớ.
- §2, §5, §6, §7, §8, §9: [0039](0039-mainpath-drills-scan-gate-sourcemaps.md): một phần bị thay: chế độ runner của `deploy/k6/cloud/run.sh`, diễn tập `drill-k8s-backup`, Velero, Chaos Mesh trên k3d, hai media-worker và RAM thành bài lab; `make cloud-check` chỉ còn Job k6.
- §6, §7, Hệ quả: [0053](0053-msk-elasticache-valkey.md): Kafka, Redis của cluster cloud chạy ngoài cluster (Amazon MSK provisioned, ElastiCache for Valkey): Velero không còn PV Redpanda để giữ và bước "Redpanda healthy" của diễn tập không còn áp; thí nghiệm (c) `pod-failure` ở `svp-data` không còn tắt broker; điều kiện "Redpanda còn trong cluster cloud" của "Xem lại khi" đã được quyết bằng Kafka managed (prd ba broker ba AZ, RF 3, `min.insync.replicas` 2).
- §2, Tên chốt: [0061](0061-edge-cloudfront-waf-acm.md): pod k6 của profile `cloud` đặt `CloudFront-Viewer-Address: <IP pod>:0` thay `X-Forwarded-For` (gateway trên EKS tin header đó, không còn tin 2 hop); biến `SVP_K6_FORWARDED_FOR`, cờ `--forwarded-for` bỏ; pod tin CA nội bộ của Envoy.
