# 0072. Vận hành pod: phát lại DLQ, chặn quá tải, timeout Postgres, drain worker, canary gRPC

- Trạng thái: Chấp nhận
- Ngày: 2026-11-14
- Người quyết: người học (làm hết theo chuẩn ngành, release mới `dlq-replay`, `PruneLast`), AI đề xuất thiết kế, số và nguồn

## Bối cảnh và vấn đề

Đối chiếu chuẩn ngành ngày 2026-11-08 ghi các lệch về vận hành pod:

- Record DLQ chỉ phát lại được bằng Kafka CLI: `console-producer` biến mỗi dòng stdin thành một record [N1], value nhị phân không qua.
- gateway không giới hạn request đồng thời, dừng không chờ rời endpoint; role app của Postgres không có timeout câu lệnh hay
  transaction; pool pgx `max(4, số CPU)` theo node, không theo `max_connections`.
- media-worker huỷ transcode đang chạy khi nhận SIGTERM, image có shell và `apk`; service gRPC không có canary; pod không trải theo
  zone; release HTTP không có startupProbe; relay outbox thử lại không jitter, một dòng broker từ chối vĩnh viễn chặn mọi dòng sau;
  `contextcheck`, `spancheck` tắt.

## Yếu tố quyết định

- Không dependency Go mới, không công cụ mới; mesh ([0042](0042-caller-identity-grpc.md) §4) dựng sau, thiết kế không giả định nó.
- Quyền tối thiểu: công cụ ghi topic của service khác có danh tính riêng.
- Một đường cho compose, k3d, EKS; khác biệt nền tảng là dữ liệu của `svp-gitops`; CI/CD không cờ, không nhánh chế độ.
- Quá tải thì từ chối nhanh, có đếm, không xếp hàng, trên mọi đường vào (cả BFF gọi thẳng trong cluster).
- Mọi giới hạn có số, tính từ nguồn ghi một chỗ (SLO, HPA, `max_connections`, trần drain node).

## Phương án đã cân nhắc

Trạng thái ngành, được, mất, nguồn: [phụ lục](appendix/0072-pod-operations.md#phương-án). In đậm là lựa chọn.

- §1: **lệnh Go, release và user Kafka riêng**; lệnh con của service có sẵn; `svp-admin` qua `svp-ops`; Kafka CLI; MirrorMaker 2.
- §2: **luật suy từ bảng nguồn ở revision env ghim**; cờ hay nhánh chế độ; tạo file image tay.
- §3: **giới hạn in-flight trong gateway**; adaptive concurrency của Envoy; circuit breaker của BackendTrafficPolicy.
- §4, §5: **timeout theo role và database**, theo instance, `SET` trong code; **pool theo ngân sách**, theo CPU, proxy kết nối.
- §6, §7: **drain có hạn**, huỷ ngay, chờ không hạn; **Alpine làm rootfs trên `scratch`**, Alpine nguyên, ffmpeg tĩnh, Chainguard.
- §8: **Rollout không `trafficRouting`**, chờ mesh, chỉ rolling update; **`PruneLast`**, `workloadRef`, sync thường.
- §10, §11: **equal jitter, đánh dấu dòng lỗi vĩnh viễn**, giữ nguyên; **`contextcheck`, `spancheck`**, thêm `paralleltest`.

## Kết quả quyết định

### 1. Lệnh phát lại DLQ

**Lệnh phát lại DLQ** là chương trình Go `services/dlq-replay`, release `dlq-replay` một replica không cổng: lệnh `standby` (mặc định)
chờ SIGTERM, không nối Kafka; người vận hành `exec` lệnh `replay` vào pod. `replay` đọc một topic `*.dlq` bằng gán partition trực tiếp
(không group, không commit), lọc theo partition, khoảng offset hay thời gian, header `dlq-group`, rồi produce từng record: key, value,
header nguyên byte và đúng thứ tự, bỏ header `dlq-*`; đích là header `dlq-topic` hay `--to`. `--dry-run` chỉ đọc; log không có key,
value, giá trị header. **User Kafka phát lại** `svp-dlq-replay`: `Read` bốn topic `*.dlq`, `Write` bốn topic gốc, không group.

- Lệnh con của service có sẵn buộc user của nó ghi topic của service khác ([0053](0053-msk-elasticache-valkey.md) §5); `svp-admin` có
  mọi quyền và vẫn là Kafka CLI; MirrorMaker 2 chép liên tục giữa hai cluster [N2]. Bản chép giữ `traceparent` gốc.
- **Chạy lại cùng khoảng**: consumer idempotent bỏ bản trùng (phụ lục) trừ `engagement.views.v1` (khử trùng theo offset
  [0045](0045-bounded-batch-retry.md) §3): mỗi khoảng một lần, lệnh cảnh báo; lượt xem gần đúng, không khử trùng theo `event_id`.

### 2. Release mới

**Tập build** là group `default` của `deploy/docker-bake.json`. **Release mới** là service của Tập build mà revision một env đang ghim
chưa build. Kiểm worktree chấp nhận env chưa có `envs/<env>/images/<svc>.yaml` của service đó; kiểm theo revision vẫn đòi đủ file cho
mọi service mà revision đó build; `promote`, `promote-prd` tạo file thiếu. Luật suy từ `sources.json` ở revision env ghim, không cờ, tự
hết khi env ghim revision đã build service: cơ chế mà [0066](0066-mediaconvert-transcode.md) §2 còn thiếu. Hai việc tay của người học
([phụ lục](appendix/0072-pod-operations.md#2-việc-tay-quanh-release-mới)): bật public package GHCR của release ngay sau lượt
`images.yml` đầu (check kéo ẩn danh); rollback prd về trước release thì xoá file prd của nó trong PR của người học (bot không xoá file).

### 3. Giới hạn in-flight gateway, preStop gateway

`httpx.LoadShed`: mỗi pod tối đa `MAX_IN_FLIGHT` request đang xử lý (mặc định 150), trừ `/healthz`, `/readyz`; quá thì trả ngay 503
`UNAVAILABLE`, `Retry-After: 1`, tăng `svp.gateway.requests.shed`, không xếp hàng. Nó nằm trong `Trace` (request bị chặn có span,
metric, route, SLO đếm là lỗi) và trước rate limit. 150 = ⌈1 000 req/s mục tiêu ([`capacity.md`](../explanation/capacity.md)) ÷ 4
`maxReplicas` × 0,15 s p99 SLO feed × 4⌉: request đồng thời bằng tốc độ nhân thời gian phục vụ, nhân 4 làm dư cho đuôi chậm.

- Adaptive concurrency của Envoy tự chỉnh giới hạn [N3], nhưng Envoy Gateway v1.9 chỉ cho dùng nó qua EnvoyPatchPolicy, API "unstable"
  [N4]; circuit breaker của BackendTrafficPolicy xếp hàng request vượt giới hạn, chỉ 503 khi hàng chờ tràn [N5]. Cả hai bỏ sót BFF của
  web, gọi gateway trong cluster không qua Envoy.
- **preStop gateway**: `preStopSleepSeconds: 5` như web ([0019](0019-web-k3d-supply-chain-observability.md) §2); 5 s +
  `shutdownTimeout` 10 s dưới grace 30 s.

### 4. Timeout role app

`bootstrap.sql` (compose qua `bootstrap.sh`, k3d và EKS qua `pg-bootstrap.sh`) đặt cho role app của `svp_user`, `svp_video`,
`svp_engagement`, `svp_feed` `ALTER ROLE <app> IN DATABASE <db> SET statement_timeout = '5s'`, `idle_in_transaction_session_timeout =
'30s'` [N6]; `svp_glitchtip` được `RESET` (app bên thứ ba); role migrator không đặt (có `lock_timeout` của
[0068](0068-zero-downtime-migrations.md)). Theo role, không theo instance: một script cho ba nền tảng; giá trị áp khi đăng nhập [N7],
kết nối đang mở giữ giá trị cũ.

- 5 s là deadline dài nhất code đặt cho một câu lệnh (`postgresTimeout` của relay; `callTimeout` 3 s của gateway ngắn hơn). Hai việc
  nền của feed-service tự nới bằng `set_config('statement_timeout', …, true)` ở câu đầu transaction: projector tới `handlerTimeout`,
  mỗi lô prune tới `pruneTimeout` ([0009](0009-engagement-feed-stage2b.md): fan-out tài khoản lớn, prune quét bảng). 30 s dài hơn mọi
  khoảng hở trong transaction của code. Bảng deadline: phụ lục.

### 5. Ngân sách kết nối

Mỗi pod mở tối đa `DATABASE_MAX_CONNS` kết nối (`pgpool.MaxConns`, mặc định 10, engagement-service ≥ 2 vì chia đọc/ghi; biến thắng
`pool_max_conns` của URL). Mỗi env: Σ bốn service `DATABASE_MAX_CONNS` × (replica tối đa + 1 pod rollout hay canary) + dự phòng (Job
migrate, `svp-ops`, GlitchTip, superuser) ≤ 80 % `max_connections` của mọi Postgres env đó chạy trên: stg 6 (RDS `db.t4g.small`, và
CloudNativePG 100 kết nối trên cụm GitOps k3d, chặt hơn), prd 10 (RDS `db.m7g.large`). 80 % để alarm 90 % của RDS
([0058](0058-managed-data-operations.md)) còn nghĩa. Công thức [N22], bảng: phụ lục. Giá trị ở `envs/<env>/` của `svp-gitops`.

### 6. Hạn drain media-worker, Grace media-worker

`kafkax.ConsumerConfig.DrainTimeout`: context huỷ thì consumer ngừng poll; record đang xử lý chạy tiếp (cả retry, backoff) bằng
context riêng tới khi xong (commit) hay hết hạn (huỷ, giao lại); record chưa bắt đầu không chạy; 0 là huỷ ngay, giá trị của mọi
consumer khác. media-worker (`serve` và `mediaconvert`) đặt **Hạn drain media-worker** 540 s; **Grace media-worker** 570 s, hạn drain
cộng 30 s đóng client, flush telemetry (`terminationGracePeriodSeconds`, `stop_grace_period` của compose), dưới trần drain node 10
phút của Karpenter ([0056](0056-eks-platform-ha.md) §9). Cái giá: job dài hơn hạn drain (ffmpeg tới 10 phút) làm lại; KEDA thu nhỏ chờ
tới 9,5 phút mỗi pod; message SQS bridge đang làm vẫn bỏ ngay (SQS giao lại).

### 7. Image media-worker

Stage `rootfs` từ Alpine đã ghim: `apk upgrade`, `apk add ffmpeg`, `/work` chủ 65532, rồi trong cùng `RUN` gỡ `apk`, `libapk`, mọi
applet và chính `busybox`. Runtime `FROM scratch` + `COPY --from=rootfs / /`, `/app`, `PATH`, `USER 65532:65532`: không shell, không
trình quản lý gói. CSDL `/lib/apk/db/installed` giữ lại để trivy, grype vẫn thấy gói Alpine [N8], [N9]; ffmpeg tĩnh của bên thứ ba
không thuộc gói nào nên máy quét không thấy version. Cái giá: CSDL vẫn ghi `busybox`, `apk-tools` đã gỡ nên CVE của chúng vẫn được báo
(build lại, không ignore); diễn tập dùng image công cụ ghim digest và pod đứng thay mang nhãn media-worker. Bằng chứng: phụ lục.

### 8. Canary gRPC

**Release canary** là release có `canary: true` ở `base/`. Release `protocol: grpc` canary là Rollout không `trafficRouting`: Argo
Rollouts đặt số pod canary theo trọng số [N10], cùng bước, nhịp đo, `failureLimit`, `inconclusiveLimit` với HTTP. Hai metric của
`rpc_server_call_duration_seconds` trên pod canary (`k8s_pod_name=~"<release>-<hash>-.*"`, hash từ `podTemplateHashValue: Latest`
[N11]) trong phút gần nhất: tỉ lệ lỗi server (`UNKNOWN`, `INTERNAL`, `UNAVAILABLE`, `DATA_LOSS`, `DEADLINE_EXCEEDED`) và p99; dưới 30
lời gọi thì Inconclusive; ngưỡng là `canaryLimits` của release.

- **Tuổi kết nối gRPC**: server đặt `MaxConnectionAge` 30 s, grace 10 s [N12]; gateway dùng `pick_first` qua ClusterIP (một kết nối,
  [N13]) nên nối lại đều đặn, tải trải sang pod mới, cả canary; grace ≥ `callTimeout` 3 s nên RPC đang chạy không bị cắt. Chia theo
  pod và kết nối chỉ gần đúng (release ít được gọi thường Inconclusive); mesh sẽ chia theo request.
- **Thuộc tính pod OTel**: chart đặt `SVP_POD_NAME`, `SVP_POD_NAMESPACE` (downward API) rồi `OTEL_RESOURCE_ATTRIBUTES` [N14], [N18];
  `internal/telemetry` gộp resource từ biến môi trường dưới `service.name`, `service.instance.id` của code.
- **Chuyển sang Rollout** (`kind` cùng tên đổi từ Deployment): Application của chart `svp-service` có `PruneLast=true`, Argo CD xoá
  Deployment cũ sau cùng, khi tài nguyên khác đã Healthy [N15]; Rollout mới tạo bỏ qua các bước [N11]; Service chọn theo nhãn chung
  nên hai bộ pod cùng nhận tải tới lúc xoá. `workloadRef` [N16] buộc chart giữ Deployment 0 replica mãi; cụm dev k3d dựng lại từ đầu.

### 9. zoneSpread, startupProbe HTTP

- **zoneSpread** `{whenUnsatisfiable, minDomains}` áp vào ràng buộc theo `topology.kubernetes.io/zone` khi `spreadAcrossNodes`; mặc
  định `ScheduleAnyway`, không `minDomains` (node k3d không có nhãn zone); schema chỉ nhận `minDomains` với `DoNotSchedule` [N17].
  Lớp `platforms/eks/` đặt `DoNotSchedule`, `minDomains` = số AZ (`cluster.dbCidrs`: stg 2, prd 3), đổi `ScheduleAnyway`
  của [0056](0056-eks-platform-ha.md) §6 ở service: pod chờ thay vì dồn vào một zone, Karpenter mở node theo ràng buộc đó [N19].
- **startupProbe HTTP**: release `protocol: http` có `startupProbe` `httpGet /healthz` (chu kỳ 2 s, timeout 2 s, 30 lần) như gRPC
  ([0020](0020-reliability-stage6.md) §10), nên liveness không giết pod khởi động chậm.

### 10. Backoff relay, lỗi vĩnh viễn của relay

- **Backoff relay**: chờ sau lỗi là giá trị nhân đôi (trần 10 s) lấy đều trong [½, 1] của nó (equal jitter [N20]), như backoff của
  `kafkax`: relay của nhiều replica không thử lại cùng nhịp.
- **Lỗi vĩnh viễn của relay**: lỗi produce mà `errors.Is` khớp `kerr.MessageTooLarge` hay `kerr.InvalidRecord`, mã do chính record gây
  ra và không retriable ở franz-go v1.22.2 (mã loại, lý do: phụ lục). Lô gặp lỗi đó gửi lại từng dòng; dòng vẫn lỗi một mình được ghi
  `failed_at`, `last_error` (≤ 512 ký tự) cùng transaction với dòng đã gửi; relay đọc `published_at IS NULL AND failed_at IS NULL` nên
  dòng sau đi tiếp; counter `svp.outbox.rows.failed`, cảnh báo page `OutboxRowsFailed` có runbook. Lỗi khác vẫn thử lại cả lô.
  Migration expand ([0068](0068-zero-downtime-migrations.md)): hai cột nullable, index partial mới `CONCURRENTLY`, index cũ giữ cho
  pod bản trước; khôi phục dòng lỗi bằng migration của bản sửa.

### 11. Linter thêm

`contextcheck` (context không kế thừa) và `spancheck` (lỗi dùng span OTel) bật trong `.golangci.yml` [N21]; chỗ cố ý tách context
(`context.WithoutCancel` khi dừng, commit, seed counter lúc khởi động) có `//nolint:contextcheck` kèm lý do. `paralleltest` không bật:
100 file test phải sửa, nhiều test dùng chung database và biến package; lợi là tốc độ, không phải đúng đắn.

### Hệ quả

- Tốt: phát lại DLQ nguyên byte bằng danh tính hẹp; service mới không cần nhánh tạm; quá tải thành 503 nhanh; câu treo tự kết thúc;
  kết nối tính trước; transcode gần xong không làm lại; media-worker không shell; gRPC có canary.
- Xấu: thêm image, release, user Kafka, user MSK, repo ECR, hai PR `svp-gitops`; PR promote đầu tiên có file mới đỏ tới khi
  `CHECKER_COMMIT` của `svp-gitops` nâng lên commit có luật mới; 150 có thể chặn sớm hay muộn; stg ở đúng trần 80 % trên
  CloudNativePG; KEDA thu nhỏ media-worker chậm; CVE của gói đã gỡ; event của dòng bị đánh dấu lệch thứ tự; pod service Pending khi
  một AZ hết chỗ hay Karpenter chưa mở được node ở zone đó (cái giá `ScheduleAnyway` của 0056 §6 tránh).
- Xem lại khi: k6 ở stg cho 503 trước SLO hay pod quá tải trước khi chặn; Envoy Gateway có API adaptive concurrency; mesh dựng; một
  env cần pod thêm mà ngân sách hết (tăng cỡ instance hay xét proxy, [0057](0057-postgres17-verify-full.md) §7); p99 transcode vượt
  hạn drain; CVE của gói đã gỡ nhiều hơn một lần mỗi tháng.

## Xác nhận

- `make test`: kfake của `dlq-replay` (lọc, chép nguyên byte, dry-run, dừng giữa chừng), drain, lỗi vĩnh viễn, jitter, `LoadShed` (trả
  chỗ khi panic, huỷ, hijack), `MaxConnectionAge`, resource OTel, `pgpool.MaxConns`, timeout tự nới; `make lint`.
- `make helm-check`, `make kyverno-test`, `rotate-test.sh`, `gitops-check-test.sh`, `promote-test.sh`: Rollout gRPC, zoneSpread,
  startupProbe, biến OTel, Release mới. Trên máy: `make db-bootstrap` hai lượt; image media-worker hai kiến trúc (phụ lục).
- Buổi stg: timeout, pool trên RDS, preStop, chặn quá tải dưới k6, ACL của `svp-dlq-replay` trên MSK, phát lại `--dry-run`; buổi kế:
  chuyển sang Rollout dưới k6 không đợt `UNAVAILABLE`, canary gRPC, zone; rồi prd. Chưa đo: `MAX_IN_FLIGHT` dưới tải thật; kết nối
  thật của GlitchTip; `max_connections` thật của CloudNativePG.

## Hiện thực ở

- §1: `services/dlq-replay/`, `deploy/kafka/kafka-init.sh`, `deploy/compose/`, `deploy/k8s/secrets.sh`,
  `deploy/helm/svp-cluster/files/external-secrets.yaml`, `deploy/helm/svp-data/templates/networkpolicies.yaml`; §2:
  `deploy/docker-bake.json`, `deploy/helm/svp-policy/files/sources.json`, `deploy/ci/`, `.github/workflows/images.yml`.
- §3–§7: `services/gateway/`, `deploy/postgres/`, `deploy/helm/svp-data/files/pg-bootstrap.sh`,
  `services/feed-service/internal/projector/`, `internal/pgpool/`, `internal/kafkax/consumer.go`, `services/media-worker/internal/`,
  `deploy/docker/media-worker.Dockerfile`, `deploy/k8s/drills/templates/`.
- §8–§11: `deploy/helm/svp-service/`, `deploy/k8s/install.sh`, `deploy/k8s/helmfile.yaml.gotmpl`, `internal/grpcserver/`,
  `internal/telemetry/`, `internal/outbox/`, `services/user-service/migrations/`, `services/video-service/migrations/`,
  `deploy/observability/prometheus/rules/svp-alerts.yaml`, `.golangci.yml`, `docs/runbooks/kafka-dlq-records.md`,
  `docs/runbooks/outbox-rows-failed.md`.
- `svp-gitops`: `base/services/`, `envs/stg/`, `envs/prd/` (`DATABASE_MAX_CONNS`), `argocd/apps/templates/applications.yaml`
  (`PruneLast`), `platforms/eks/` (`zoneSpread`). `svp-infra`: `aws/modules/msk/main.tf`, `aws/modules/registry/main.tf`,
  `github/scripts/github-app.py` (user MSK, repo ECR, package GHCR `dlq-replay`).

## Nguồn

Đọc 2026-11-15 trừ khi ghi khác; [N1]–[N28] kèm link và trích dẫn ở [phụ lục](appendix/0072-pod-operations.md#nguồn).

## Thông tin thêm

Phụ lục: [`appendix/0072-pod-operations.md`](appendix/0072-pod-operations.md) (phương án, bảng của §1, §2, §4, §5, §7, §8, §10, nguồn).
