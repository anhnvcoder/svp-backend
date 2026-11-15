# Phụ lục ADR-0072: Vận hành pod: phát lại DLQ, chặn quá tải, timeout Postgres, drain worker, canary gRPC

Phụ lục của [ADR-0072](../0072-pod-operations.md): bảng phương án, bảng của từng §, nguồn. Nguồn đọc ngày 2026-11-15 trừ khi dòng
nguồn ghi ngày khác; số đo và lệnh lấy từ phần hiện thực, chạy ngày 2026-11-14 và 2026-11-15.

## Phương án

| § | Phương án | Trạng thái ngành | Được | Mất | Nguồn |
| --- | --- | --- | --- | --- | --- |
| 1 | **Lệnh Go riêng `dlq-replay`, release và user Kafka riêng** | — | Chép nguyên byte; lọc partition, offset, thời gian, group; dry-run; danh tính chỉ đọc DLQ, ghi topic gốc; metric | Thêm image, release, user Kafka, user MSK, repo ECR; cần cơ chế §2 | — |
| 1 | Lệnh con của service có sẵn (feed-service, media-worker) | — | Không image mới | User của service đó được ghi topic của service khác: phá ACL theo service ([0053](../0053-msk-elasticache-valkey.md) §5) | — |
| 1 | `svp-admin` qua `svp-ops` | — | Pod và quyền đã có | User có mọi quyền chạy lệnh ghi; công cụ trong pod là Kafka CLI | — |
| 1 | Kafka CLI `console-producer` | Có sẵn trong mọi bản Kafka | Không thêm gì | Mỗi dòng stdin một record: value protobuf nhị phân (có byte xuống dòng) và header không chép nguyên được | [N1] |
| 1 | MirrorMaker 2 | Công cụ chép dữ liệu giữa các cluster Kafka, chạy trên Kafka Connect | Chép liên tục, giữ dòng chảy | Topic đích mặc định mang tiền tố alias của cluster nguồn; thêm worker Connect; không phải chép một khoảng record về topic gốc trong cùng cluster | [N2] |
| 2 | **Luật suy từ bảng nguồn ở revision env ghim** | — | Một đường cho service cũ và mới; ngoại lệ tự hết | Luật kiểm phức tạp hơn; PR promote đầu tiên chờ `CHECKER_COMMIT` mới | — |
| 2 | Cờ hay nhánh chế độ "service mới" trong check, promote | — | Dễ viết | Nhánh phải nhớ gỡ; trái một đường thẳng của [0037](../0037-mainpath-standard-tools.md) | — |
| 2 | Tạo `envs/<env>/images/<svc>.yaml` bằng tay trước promote | — | Không đổi code | File đầu không có digest đã ký; một PR người mỗi env | — |
| 3 | **Giới hạn in-flight trong gateway** | — | Phủ cả đường qua Envoy và BFF; 503 có span, metric, route | Giới hạn tĩnh, phải đo lại khi tải hay `maxReplicas` đổi | — |
| 3 | Adaptive concurrency của Envoy | Filter của Envoy; Envoy Gateway v1.9 không có kiểu API cho nó, chỉ EnvoyPatchPolicy ("unstable", mặc định tắt) | Tự chỉnh giới hạn theo latency mẫu | Vá xDS không giữ được qua version; không phủ BFF | [N3], [N4] |
| 3 | Circuit breaker của BackendTrafficPolicy | Có ở Envoy Gateway v1.9 | API ổn định | Vượt giới hạn request đồng thời thì xếp hàng, chỉ 503 khi hàng chờ tràn; mặc định 1024; bộ đếm không đồng bộ giữa process Envoy; không phủ BFF | [N5] |
| 4 | **`ALTER ROLE … IN DATABASE … SET` cho role app** | Cài đặt theo role và database của PostgreSQL | Một script cho compose, CloudNativePG, RDS; database của app bên thứ ba không bị đặt | Chỉ áp khi đăng nhập | [N6], [N7] |
| 4 | Tham số cấp instance (parameter group, `postgresql.conf`) | — | Một chỗ mỗi instance | Áp cả GlitchTip và migrator; ba nơi cấu hình khác nhau | [N7] |
| 4 | `SET` ở mỗi kết nối trong code | — | Thấy trong code | Mỗi service tự nhớ; phiên tay của role app không có | — |
| 5 | **`DATABASE_MAX_CONNS` mỗi env theo ngân sách** | — | Tổng kết nối tính được trước | Tính lại khi đổi replica hay cỡ instance | [N22], [N24] |
| 5 | Mặc định `max(4, số CPU)` | Mặc định của pgxpool | Không cấu hình | Cỡ pool theo node, không theo database | — |
| 5 | RDS Proxy, PgBouncer | — | — | Đã loại ở [0057](../0057-postgres17-verify-full.md) §7 | — |
| 6 | **Drain có hạn rồi giao lại** | — | Transcode gần xong không làm lại; không vượt trần node | Job dài hơn hạn vẫn làm lại | — |
| 6 | Huỷ ngay | — | Dừng nhanh | Transcode gần xong làm lại từ đầu | — |
| 6 | Chờ xong không hạn | — | Không job nào làm lại | Vượt trần drain node 10 phút ([0056](../0056-eks-platform-ha.md) §9): Karpenter xoá pod giữa chừng | — |
| 7 | **Alpine làm rootfs, gỡ shell và `apk`, chạy trên `scratch`** | — | Không image nền mới; ffmpeg do Alpine build và vá; máy quét vẫn đọc gói Alpine | CSDL còn ghi gói đã gỡ | [N8], [N9] |
| 7 | Giữ Alpine nguyên ([0008](../0008-async-upload-pipeline-stage2a.md) §9) | — | Không đổi | Shell và `apk` cho ai chiếm được process | — |
| 7 | Distroless + ffmpeg tĩnh của bên thứ ba | — | Image nhỏ | Image nền mới; binary không thuộc gói nào nên máy quét không thấy version ffmpeg | — |
| 7 | Chainguard `ffmpeg` | Trả phí | Không shell, vá nhanh | Registry trả 403 cho kéo ẩn danh (thử 2026-11-14) | — |
| 8 | **Rollout không `trafficRouting`** | Canary cơ bản của Argo Rollouts: số pod theo trọng số | Không cần mesh; cùng nhịp phân tích với HTTP | Trọng số gần đúng | [N10] |
| 8 | Chờ mesh | — | Chia theo request | Bốn service không có canary tới khi có mesh | — |
| 8 | Chỉ rolling update | — | Không đổi | Không phân tích, không tự abort | — |
| 8 | **`PruneLast=true`** | Sync option của Argo CD | Deployment cũ chỉ bị xoá khi tài nguyên khác Healthy | Application `svp-service` mang thêm option | [N15] |
| 8 | `workloadRef` | Cách chuyển của tài liệu Argo Rollouts | Rollout dùng template của Deployment có sẵn | Chart phải giữ Deployment 0 replica mãi | [N16] |
| 8 | Sync thường | — | Không đổi | Deployment bị xoá cùng lượt tạo Rollout: service không có pod sẵn sàng tới khi pod Rollout lên | — |
| 10 | **Equal jitter, đánh dấu dòng lỗi vĩnh viễn** | Equal jitter: một biến thể backoff có jitter | Không thử lại cùng nhịp; một dòng hỏng không chặn service | Event của dòng bị đánh dấu không gửi tới khi khôi phục | [N20], [N25] |
| 10 | Giữ nguyên | — | Không đổi | Một dòng quá lớn chặn mọi dòng sau | — |
| 11 | **`contextcheck`, `spancheck`** | Linter của golangci-lint | Bắt context không kế thừa, span không đóng | Một số `nolint` có lý do | [N21] |
| 11 | Thêm `paralleltest` | Linter của golangci-lint | Test chạy song song | 100 file test phải sửa, nhiều test dùng chung database và biến package | [N21] |

## §1 Chạy lại cùng khoảng

Mỗi bản phát lại mang `event_id` cũ ở offset mới.

| Consumer (topic) | Bỏ bản trùng | Bằng chứng |
| --- | --- | --- |
| video-service (`media.transcodes.v1`) | Có: chuyển trạng thái một chiều (`MarkVideoReady` chỉ từ `PROCESSING`) | `transcode.go` (doc `HandleTranscode`); `TestSameTranscodeRecordTwiceChangesNothing`, `TestTranscodeCompletedTwiceEmitsOnce` |
| feed-service (`user.follows.v1`, `video.lifecycle.v1`) | Có: `ON CONFLICT DO NOTHING`, xoá | `projector.go`; `TestSameRecordTwiceChangesNothing` |
| media-worker (`video.lifecycle.v1`) | Có: master playlist đã có thì không transcode, phát lại kết quả đã lưu | `TestHandleValidUploadTwiceGivesSameResult`, `TestHandleRedeliveryAfterMasterPublishesStoredResult`, `TestUploadedAgainSettlesTheRecord` |
| engagement-service (`engagement.views.v1`) | **Không**: khử trùng theo offset (`consumer_offsets.next_offset`), không theo `event_id` | `views.go` (doc `ViewsConsumerConfig`): bản phát lại có offset mới nên được đếm; chạy lại cùng khoảng đếm hai lần |

feed-service: phát lại riêng lẻ một `user.followed` cũ sau `user.unfollowed` dựng lại cạnh
(`TestOldFollowReplayedAfterUnfollowRestoresEdge`): lỗi thứ tự đã biết ([0045](../0045-bounded-batch-retry.md) §5), không phải lỗi bản
trùng.

## §2 Việc tay quanh Release mới

- **Package GHCR public.** Lượt `images.yml` đầu trên `main` tạo package `svp-backend/<svc>` ở trạng thái private. Check của `svp-gitops`
  kéo ẩn danh (`deploy/ci/verify-release.sh`), nên PR `bot/promote-stg` có file mới vẫn đỏ sau khi `CHECKER_COMMIT` nâng, không tự merge, và
  mọi bump stg dồn trong PR đó. Người học bật public ngay sau lượt đó, không đợi buổi stg; không có API đổi visibility
  ([`svp-frontend-setup.md`](../../runbooks/svp-frontend-setup.md) C1).
- **Rollback prd.** `promote-prd` chỉ tạo hay sửa file, luật tác giả (`gitops.author`) cấm PR có tác giả là bot xoá
  file, kể cả commit người đẩy lên đó. Lùi `stg_ref` về trước lúc release có file prd thì file đó còn lại và check của PR bot đỏ
  ("exactly one file per service"). PR rollback là PR của người học, có xoá `envs/prd/images/<svc>.yaml`
  ([`svp-gitops-setup.md`](../../runbooks/svp-gitops-setup.md) C4).
- `rescan` bỏ qua service chưa có file image; `promote` và `promote-prd` viết khối comment đầu file như các file khác; component của
  release vào `argocd/apps/components.json` khi mọi env của nền tảng đã có file image.

## §4 Deadline quanh Postgres

`git grep context.WithTimeout` ở `services/`, `internal/` của commit `1bf1a3f`.

| Đường | Deadline | Dài nhất trong đó |
| --- | --- | --- |
| gateway → RPC; handler transcode của video-service | `callTimeout` 3 s (stats 100 ms); 10 s | Câu < 3 s, transaction ngắn |
| Relay outbox `sendBatch`; `cleanup` | `postgresTimeout` 5 s mỗi chặng, produce 10 s; 30 s cả lượt | Hở trong transaction ≤ 10 s; `DELETE` 1 000 dòng mỗi câu |
| Sweep upload của video-service; lô lượt xem của engagement-service | 30 s cả transaction | Hở < 30 s (`Delete` S3, `EndOffsets` trong transaction) |
| Projector của feed-service (publish, follow, unfollow) | `handlerTimeout` 30 s | `FanOutVideo`, chờ `LockAuthor` có thể > 5 s: transaction tự nới tới 30 s |
| Prune của feed-service | `pruneTimeout` 2 phút | `DeleteExpiredTimeline` quét bảng: mỗi lô một transaction, nới tới 2 phút |

Kiểm trên Postgres của compose: `make db-bootstrap` hai lượt, `pg_db_role_setting` của bốn role `svp_<svc>_app` có
`{statement_timeout=5s,idle_in_transaction_session_timeout=30s}` đúng database, GlitchTip và migrator không có; đặt tay giá trị khác
thì lượt sau ghi đè. `bootstrap.sql` chạy bằng role tạm `LOGIN CREATEROLE CREATEDB` không superuser cũng đặt được: role có
`CREATEROLE` đổi được mặc định của role mà nó có ADMIN OPTION [N7], và role `CREATEROLE` không superuser tạo role nào thì tự có ADMIN
OPTION trên role đó [N28]. Feed-service tự nới bằng `SELECT set_config('statement_timeout', $1, true)`: `is_local = true` chỉ áp trong
transaction [N27]; `SET` không nhận tham số bind. Ba test (`TestTransactionSetsItsStatementTimeout`,
`TestAuthorTxOutlastsRoleStatementTimeout`, `TestPruneBatchOutlastsRoleStatementTimeout`) đỏ khi bỏ `set_config`.

## §5 Ngân sách kết nối

`max_connections` của RDS for PostgreSQL là `LEAST({DBInstanceClassMemory/9531392}, 5000)` [N22]; `DBInstanceClassMemory` nhỏ hơn bộ
nhớ của lớp vì hệ điều hành và RDS giữ một phần. CloudNativePG `svp-pg`: `postgres.yaml` không đặt `max_connections`, nên là mặc định
100 của PostgreSQL 17, với `superuser_reserved_connections` 3 [N24].

| Postgres | Bộ nhớ lớp [N23] | `max_connections` | 80 % |
| --- | --- | --- | --- |
| stg, RDS `db.t4g.small` | 2 GiB | tối đa 225 theo bộ nhớ lớp; ngưỡng 186 (90 %) của `class_alarm_thresholds` ở `aws/modules/rds/alarms.tf` (svp-infra) ⇒ 186 ÷ 0,9 ≈ 207 | 165 |
| stg, CloudNativePG `svp-pg` (cụm GitOps k3d) | — | 100 | **80** |
| prd, RDS `db.m7g.large` | 8 GiB | tối đa 901 theo bộ nhớ lớp; ngưỡng 745 (90 %) của `alarms.tf` ⇒ 745 ÷ 0,9 ≈ 828 | **662** |

Pod tối đa mỗi service (`base/services`, `envs/<env>` của `svp-gitops`; `platforms/eks` không đặt lại), cộng 1 pod khi rollout
(maxSurge 25 % làm tròn lên 1) hay canary (25 % của tối đa 4 pod là 1):

| Env | user | video | engagement | feed (`hpa.maxReplicas`) | Pod tối đa |
| --- | --- | --- | --- | --- | --- |
| stg | 1 + 1 | 1 + 1 | 1 + 1 | 2 + 1 | 9 |
| prd | 2 + 1 | 2 + 1 | 2 + 1 | 2 + 1 | 12 |

Dự phòng mỗi env, 26 kết nối: Job migrate 4 × 2 = 8 (khoá phiên của goose và kết nối migration), `svp-ops` 2, GlitchTip 10 (một pod
granian có worker nhúng; trên `svp-pg` ở k3d, trên RDS ở EKS), superuser 3, operator, nội bộ RDS và `pg-bootstrap` 3.

| Env | `DATABASE_MAX_CONNS` | Tổng | Trần (80 %) |
| --- | --- | --- | --- |
| stg | 6 (engagement đọc 3, ghi 3) | 6 × 9 + 26 = 80 | 80 (k3d quyết; RDS 165) |
| prd | 10 (engagement đọc 5, ghi 5) | 10 × 12 + 26 = 146 | 662 (đủ chỗ cho ~63 pod 10 kết nối) |

Chưa đo: GlitchTip dùng tối đa 10 kết nối, mỗi Job migrate 2 (giả định); CloudNativePG không tự đặt `max_connections` (kiểm bằng
`svp-pg video -c 'SHOW max_connections'` trên cụm GitOps k3d). Kích thước pool trong metric: `pgxpool_max_connections` (nhãn
`service_name`, `db_client_connection_pool_name` cho pool đọc, ghi của engagement-service), dashboard `svp-use`. Đường dev k3d (mặc
định 10, 5 pod cộng 4 pod rollout) có thể chạm 90 kết nối cộng dự phòng trên 100 của `svp-pg` khi mọi service cùng rollout; đường dev
giữ mặc định.

## §7 Bằng chứng image

Build ngày 2026-11-14 bằng `env -u DOCKER_DEFAULT_PLATFORM docker buildx bake -f deploy/docker-bake.json media-worker --set
media-worker.platform=linux/<arch> … --load`, `linux/arm64` và `linux/amd64`, cả hai xanh (image local, đã xoá).

| Điều kiện | Kết quả (cả hai kiến trúc) |
| --- | --- |
| Không shell, không `apk` | `docker run --entrypoint /bin/sh <img> -c true`: `stat /bin/sh: no such file or directory`; cùng kết quả với `/sbin/apk`, `/bin/busybox`; `docker export` + `tar -tv`: không file `sh`, `ash`, `bash`, `dash`, `busybox`, `apk`, `libapk*`, không symlink tới busybox |
| ffmpeg chạy | `--entrypoint ffmpeg … -version`: `ffmpeg version 8.1.3`; `ffprobe version 8.1.3`; có demuxer `mov,mp4,…`, `matroska,webm`, mọi decoder của whitelist, encoder `libx264`, `aac`, `mjpeg`, muxer `hls`, `mpegts`, `image2`, filter `scale`, `split` |
| Người dùng | `docker image inspect`: `65532:65532`, `["/app"]`; `work/` chủ `65532 65532` `drwxr-x---` |
| Transcode mẫu | Test binary của `services/media-worker/internal/transcode` (`go test -c`) chạy trong image với `--read-only --tmpfs /tmp:size=1g --cap-drop ALL --security-opt no-new-privileges:true --user 65532:65532`: 18/18 PASS, không SKIP |
| Máy quét | Trivy ghim của `Makefile` (`image --input`, `--list-all-pkgs`, arm64): `alpine 3.24.4`, 122 gói, thấy `ffmpeg 8.1.3-r0`, `ffmpeg-libavcodec 8.1.3-r0`, `x264-libs 0.164.3108-r1`, `busybox 1.37.0-r31`, `busybox-binsh`, `apk-tools 3.0.9-r0`; 0 lỗ hổng không dùng ignorefile |

`busybox`, `busybox-binsh`, `apk-tools` còn trong CSDL `/lib/apk/db/installed` dù file đã gỡ: CVE của chúng vẫn được báo (cái giá ở §7
của ADR). `make trivy-config`: không phát hiện nào ở `media-worker.Dockerfile`.

## §8 Nhãn metric gRPC

`otelgrpc` v0.72.0 (`go.mod`), `stats_handler.go` đọc ngày 2026-11-14 [N26]: khi `OTEL_SEMCONV_STABILITY_OPT_IN` rỗng (mặc định) chỉ
ghi `rpc.server.call.duration` (giây, bucket 5 ms tới 10 s); mã trả về ở thuộc tính `rpc.response.status_code` (semconv v1.43.0) dạng
chữ (`OK`, `INTERNAL`, …). Trong Prometheus là `rpc_server_call_duration_seconds` với nhãn `rpc_response_status_code` (khớp dashboard
`svp-red`); health check bị lọc ở `internal/grpcserver`. otelgrpc tự coi lỗi server gồm cả `UNIMPLEMENTED`; query canary chỉ đếm năm
mã ở §8 của ADR.

## §10 Mã lỗi của relay

`pkg/kerr/kerr.go` của franz-go v1.22.2 (`go.mod`), đọc ngày 2026-11-14 ở module cache [N25].

| Mã | Retriable | Relay | Lý do |
| --- | --- | --- | --- |
| `MESSAGE_TOO_LARGE` (10) | false | Đánh dấu dòng | Record quá cỡ broker hay client nhận; lỗi phía client bọc `kerr.MessageTooLarge` (`pkg/kgo/producer.go`, `pkg/kgo/sink.go`), `errors.Is` khớp cả hai |
| `INVALID_RECORD` (87) | false | Đánh dấu dòng | Broker kiểm record và từ chối |
| `CORRUPT_MESSAGE` | true (`kerr.go:78`) | Thử lại cả lô | Retriable |
| `TOPIC_AUTHORIZATION_FAILED` | false | Thử lại cả lô | Do quyền, sửa quyền thì dòng đi được |
| `RECORD_LIST_TOO_LARGE` | false | Thử lại cả lô | Do cỡ cả lô |
| `INVALID_TIMESTAMP` | false | Thử lại cả lô | Do đồng hồ lệch: client đóng dấu record lúc gửi |

Lỗi của broker gán cho mọi record của lô partition (`pkg/kgo/sink.go`), còn `kafkax.Produce` chỉ trả lỗi đầu: lô gặp lỗi vĩnh viễn
được gửi lại từng dòng, và chỉ dòng vẫn lỗi khi đi một mình bị đánh dấu; dòng đầu lô đã ghi được thì ghi lần nữa (at-least-once như
sau mọi lô lỗi). Test (`internal/outbox/failed_test.go`, lỗi giả của `kfake`): dòng quá lớn bị đánh dấu, dòng sau cùng key vẫn gửi;
`INVALID_RECORD` cả lô chỉ đánh dấu dòng gây lỗi; `NOT_ENOUGH_REPLICAS`, `TOPIC_AUTHORIZATION_FAILED`, `CORRUPT_MESSAGE` rollback,
không đánh dấu. Pod bản trước (đọc `published_at IS NULL`) vẫn gặp dòng đã đánh dấu và lỗi cả lô như cũ tới khi nó dừng; vì thế index
cũ `outbox_unpublished_idx` giữ tới release sau.

## Nguồn

Đọc 2026-11-15 trừ khi ghi khác.

- [N1] Apache Kafka, Quickstart: <https://kafka.apache.org/quickstart> ("By default, each line you enter will result in a separate
  event being written to the topic").
- [N2] Apache Kafka 4.1, Geo-Replication (Cross-Cluster Data Mirroring):
  <https://kafka.apache.org/41/operations/geo-replication-cross-cluster-data-mirroring/> ("MirrorMaker is based on the Kafka Connect
  framework"; "the topic foo in the source cluster us-west would be replicated to a topic named us-west.foo").
- [N3] Envoy, Adaptive Concurrency:
  <https://www.envoyproxy.io/docs/envoy/latest/configuration/http/http_filters/adaptive_concurrency_filter> ("dynamically adjusts the
  allowed number of requests that can be outstanding (concurrency)", "using latency sampling of completed requests").
- [N4] Envoy Gateway v1.9, EnvoyPatchPolicy: <https://gateway.envoyproxy.io/v1.9/tasks/extensibility/envoy-patch-policy/> ("this API
  is unstable and the outcome may change across versions", "By default EnvoyPatchPolicy is disabled"); mục lục kiểu của API reference
  <https://gateway.envoyproxy.io/v1.9/api/extension_types/> không có kiểu cho adaptive concurrency.
- [N5] Envoy Gateway v1.9, Circuit Breakers: <https://gateway.envoyproxy.io/v1.9/tasks/traffic/circuit-breaker/> ("When this threshold
  is met, requests will be queued", "overflowing requests will be terminated with a 503 status code", "(1024)", "counters are not
  synchronized across different Envoy processes").
- [N6] PostgreSQL 17, Client Connection Defaults: <https://www.postgresql.org/docs/17/runtime-config-client.html>
  (`statement_timeout`: "Abort any statement that takes more than the specified amount of time";
  `idle_in_transaction_session_timeout`: "Terminate any session that has been idle … within an open transaction").
- [N7] PostgreSQL 17, ALTER ROLE: <https://www.postgresql.org/docs/17/sql-alterrole.html> ("Role-specific variable settings take
  effect only at login"; "database-role-specific settings override role-specific ones, which in turn override database-specific ones";
  quyền đổi mặc định của role có ADMIN OPTION).
- [N8] Trivy, Alpine Linux: <https://trivy.dev/latest/docs/coverage/os/alpine/> ("Trivy detects packages that have been installed
  through `apk`").
- [N9] Grype: <https://github.com/anchore/grype> (quét SBOM của Syft, `grype sbom:./sbom.json`; "Supports major OS package ecosystems
  (Alpine, …"); Syft: <https://github.com/anchore/syft> ("Alpine (apk)").
- [N10] Argo Rollouts, FAQ: <https://argoproj.github.io/argo-rollouts/FAQ/> ("In the absence of a traffic routing provider, Argo
  Rollouts manages the replica counts of the canary/stable ReplicaSets to achieve the desired canary weights"); Canary:
  <https://argoproj.github.io/argo-rollouts/features/canary/>.
- [N11] Argo Rollouts, Rollout Specification: <https://argoproj.github.io/argo-rollouts/features/specification/> (`steps`: "Skipped
  upon initial deploy of a rollout"; `valueFrom.podTemplateHashValue`: "rollouts-pod-template-hash value of either the Stable
  ReplicaSet or the Latest ReplicaSet").
- [N12] gRPC A9, Server-side Connection Management: <https://github.com/grpc/proposal/blob/master/A9-server-side-conn-mgt.md>
  (`MAX_CONNECTION_AGE`: "can force the client to periodically reconnect to a L4 LB which allows spreading load more quickly";
  `MAX_CONNECTION_AGE_GRACE`: "for outstanding RPCs to complete").
- [N13] gRPC, Custom Load Balancing Policies: <https://grpc.io/docs/guides/custom-load-balancing/> ("By default the `pick_first`
  policy will be used", "uses the first one it can connect to").
- [N14] OpenTelemetry, SDK Environment Variables: <https://opentelemetry.io/docs/specs/otel/configuration/sdk-environment-variables/>
  (`OTEL_RESOURCE_ATTRIBUTES`: "Key-value pairs to be used as resource attributes").
- [N15] Argo CD, Sync Options: <https://argo-cd.readthedocs.io/en/stable/user-guide/sync-options/> (`PruneLast=true`: pruning "as a
  final, implicit wave", "after the other resources have been deployed and become healthy").
- [N16] Argo Rollouts, Migrating to Rollouts: <https://argoproj.github.io/argo-rollouts/migrating/> ("Reference an existing Deployment
  from a Rollout using `workloadRef` field", "scale it down to zero and reference it from the Rollout resource").
- [N17] Kubernetes, Pod Topology Spread Constraints:
  <https://kubernetes.io/docs/concepts/scheduling-eviction/topology-spread-constraints/> (đọc 2026-11-14: `minDomains` chỉ với
  `DoNotSchedule`, lớn hơn 0; node thiếu nhãn `topologyKey` bị bỏ qua).
- [N18] Kubernetes, Define Dependent Environment Variables:
  <https://kubernetes.io/docs/tasks/inject-data-application/define-interdependent-environment-variables/> (đọc 2026-11-14: thứ tự
  trong `env` quyết định `$(VAR)` có được thay không).
- [N19] Karpenter, Scheduling: <https://karpenter.sh/docs/concepts/scheduling/> (`topologyKey` Karpenter hỗ trợ gồm
  `topology.kubernetes.io/zone`).
- [N20] Marc Brooker, AWS Architecture Blog, "Exponential Backoff And Jitter" (2015-03-04):
  <https://aws.amazon.com/blogs/architecture/exponential-backoff-and-jitter/> (Equal Jitter: "always keep some of the backoff and
  jitter by a smaller amount").
- [N21] golangci-lint, Linters: <https://golangci-lint.run/docs/linters/> (`contextcheck`: "Check whether the function uses a
  non-inherited context"; `spancheck`: "Checks for mistakes with OpenTelemetry/Census spans"; `paralleltest`: "Detects missing usage
  of t.Parallel()").
- [N22] Amazon RDS, Quotas and constraints: <https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/CHAP_Limits.html>
  (`max_connections` của RDS for PostgreSQL).
- [N23] Amazon RDS, DB instance class summary:
  <https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/Concepts.DBInstanceClass.Summary.html> (bộ nhớ của `db.t4g.small`,
  `db.m7g.large`).
- [N24] PostgreSQL 17, Connections and Authentication: <https://www.postgresql.org/docs/17/runtime-config-connection.html>
  (`max_connections` mặc định 100, `superuser_reserved_connections` 3).
- [N25] franz-go v1.22.2, `pkg/kerr/kerr.go`: <https://pkg.go.dev/github.com/twmb/franz-go@v1.22.2/pkg/kerr> (đọc 2026-11-14 ở module
  cache: cờ retriable của từng mã).
- [N26] otelgrpc v0.72.0, `stats_handler.go`:
  <https://pkg.go.dev/go.opentelemetry.io/contrib/instrumentation/google.golang.org/grpc/otelgrpc@v0.72.0> (đọc 2026-11-14 ở module
  cache).
- [N27] PostgreSQL 17, System Administration Functions: <https://www.postgresql.org/docs/17/functions-admin.html> (`set_config` với
  `is_local` = `true` như `SET LOCAL`).
- [N28] PostgreSQL 17, Role Attributes: <https://www.postgresql.org/docs/17/role-attributes.html> (role `CREATEROLE` không superuser
  tạo role mới thì tự có ADMIN OPTION trên nó).
