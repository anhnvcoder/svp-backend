# Độ tin cậy: SLO, tải, backup, probe và vận hành

Trang này trả lời: hệ thống hứa gì (SLO), kiểm lời hứa đó bằng tải và diễn tập nào, phục hồi dữ liệu ra sao, và cái gì đo được trên
máy 16 GB, cái gì chạy trên runner CI, cái gì cần cloud. Số đo đầy đủ ở mục Kết quả của
[ADR-0020](../adr/0020-reliability-stage6.md); lệnh ở [`reference/compose.md`](../reference/compose.md),
[`reference/k8s.md`](../reference/k8s.md).

Phần chạy được trên máy 16 GB chạy local; phần cần máy lớn hơn (k3d nặng, observability dưới tải, diễn tập đầy đủ) chạy trên runner
CI ([kiểm chứng trên runner](#kiểm-chứng-trên-runner)); phần cần dịch vụ cloud chờ cluster AWS
([chưa đo trên cloud](#chưa-đo-trên-cloud)).

## SLO

Vì sao: [ADR-0011](../adr/0011-observability-stage3.md), [ADR-0020](../adr/0020-reliability-stage6.md).

Sáu SLO bằng Sloth ([`deploy/observability/slo/svp-slos.yaml`](../../deploy/observability/slo/svp-slos.yaml)): bốn của backend
(`feed-availability`, `feed-latency`, `upload-init-availability`, `video-ready-latency`) và hai của web.

- `web-availability`: 99,9% response của server web không 5xx, trên histogram
  `http_server_request_duration_seconds{service_name="web"}` (mọi response, kể cả probe và asset, vì histogram không có nhãn route
  nên SLI lạc quan hơn tỷ lệ lỗi của trang), cảnh báo page và ticket.
- `web-inp`: 75% lượt có INP ≤ 200 ms từ RUM ([quan sát web](observability.md#web)), chỉ ticket (ngân sách lỗi 25% làm cửa sổ
  page không bao giờ chạm).
- Chưa có SLO độ trễ SSR tới khi histogram có route.

## Tải

Vì sao: [ADR-0020](../adr/0020-reliability-stage6.md), quy mô mục tiêu ở [`capacity.md`](capacity.md).

Kịch bản k6 ở `deploy/k6/` chạy bằng image ghim (`K6_IMAGE`), mỗi request mang tag `route` là template, trùng nhãn route của
gateway và RUM nên số phía k6 và phía server ghép được. Pool user và tốc độ tính từ bảng rate limit để kịch bản không tự chặn mình
(429 đếm riêng là lỗi cỡ kịch bản).

- Profile `local` (~24 req/s, compose) chỉ kiểm kịch bản đúng cỡ và cho một mốc độ trễ ở tải rất nhẹ, **không kết luận năng lực**.
- `ci` chạy trong job `stack` của CI.
- `cloud` là Job Indexed 20 pod trong cluster, 1 000 req/s feed, chạy trên cluster cloud; bản thu nhỏ `k6-cloud-mini` là bài lab
  `drills/` của `svp-labs`.

## Backup và phục hồi Postgres

Vì sao: [ADR-0020](../adr/0020-reliability-stage6.md), [ADR-0021](../adr/0021-deferred-verification-stage6b.md) D20. Quy trình
tay ở [`runbooks/postgres-restore.md`](../runbooks/postgres-restore.md).

Trên k3d, Cluster CloudNativePG `svp-pg` lưu WAL liên tục và backup cơ sở hằng ngày qua plugin Barman Cloud (sidecar trong pod
Postgres, controller ở `cnpg-system`) vào bucket `pg-backups` của object store trong cluster, bằng user `svp-pg-backup` riêng chỉ
có quyền bucket đó. Mỗi lần phục hồi ghi vào một thế hệ lưu trữ mới (`serverName`), vì Job phục hồi từ chối lưu WAL vào nơi đã có
WAL. PodMonitor đưa `cnpg_*`, `barman_cloud_*` vào Prometheus; cảnh báo `PostgresWALArchivingFailing` (page) và
`PostgresBackupTooOld` (ticket).

- **Nơi lưu:** plugin Barman Cloud lưu WAL và backup cơ sở, từ sidecar trong pod Postgres, vào bucket `pg-backups` của object store
  `s3` trong cluster bằng user `svp-pg-backup`, có policy chỉ cho bucket đó (`deploy/s3/pg-backup-policy.json`, do Job `s3-init`
  tạo; không service nào có user này). Secret key của nó lấy từ `.env` (`SVP_PG_BACKUP_S3_SECRET_KEY`) vào Secret `pg-backup-s3`
  (`deploy/k8s/secrets.sh`). Bucket nằm cùng cluster, cùng ổ với dữ liệu, và store ở đây không có KMS: đủ để lab diễn tập phục hồi
  (WAL, điểm trong thời gian, các thế hệ lưu trữ) và đo RTO, RPO của nó, không phải một bản sao sống sót khi cluster mất. Trong
  bucket mỗi thế hệ lưu trữ có prefix riêng, là `serverName` của plugin (`postgres.backup.serverName`). Với `postgres.mode:
  external` chart không tạo backup: Postgres được quản lý giữ backup của chính nó.
- **Lịch backup cơ sở:** mỗi ngày lúc 03:00 UTC (cron của CloudNativePG có trường giây ở đầu), và một lần ngay khi object được tạo,
  để cluster mới có điểm phục hồi trong vài phút thay vì tới 03:00 kế tiếp (`PostgresBackupTooOld` cháy khi không có backup nào
  trong một giờ). Object `ScheduledBackup` `svp-pg-daily` là hook (weight 1) sau các Job init: CloudNativePG khởi `Backup` tức thì
  trên primary Ready đầu tiên và không bao giờ thử lại lần đã thất bại, trong khi bucket `pg-backups` và login `svp-pg-backup` chỉ có sau khi Job `s3-init` chạy,
  sau khi tài nguyên thường của release sẵn sàng (Argo CD: PostSync, hook theo thứ tự weight). Là tài nguyên thường thì `Backup` của
  nó sẽ đua với Job đó trên cluster mới và thất bại vĩnh viễn. Mỗi lần upgrade hay sync tạo lại object; CloudNativePG khi đó không
  lấy thêm `Backup` tức thì thứ hai khi object của lần đầu còn (nó nhận lại object đó), và `make k8s-up` tự lấy một backup cơ sở
  khi thế hệ đang chạy chưa có (`pg_base_backup` trong `deploy/k8s/install.sh`). Các `Backup` nó tạo không thuộc object nào, để việc
  tạo lại object hay xoá Cluster khi phục hồi ([runbook](../runbooks/postgres-restore.md)) không xoá chúng; plugin xoá những `Backup`
  của Cluster đang chạy mà chính sách retention đã xoá khỏi bucket. Không object nào của bucket bị xoá trừ bởi chính sách đó.
- **Nâng chart `svp-data` sau phục hồi:** `pg_backup_sets` trong `deploy/k8s/rotate.sh` đặt `pg_server` về thế hệ lưu trữ của Cluster
  `svp-pg` đang chạy (giá trị state `pgServerName` của `deploy/k8s/helmfile.yaml.gotmpl`). Mỗi lần phục hồi tạo lại `svp-pg` lưu vào
  thế hệ mới (`postgres.backup.serverName`), còn mặc định của chart là thế hệ đầu: nâng cấp không có giá trị này sẽ trỏ việc lưu WAL
  của Cluster đã phục hồi về thế hệ nó phục hồi từ đó, nơi archive không rỗng, và việc lưu sẽ lỗi. Cluster mới, hay Cluster tạo trước
  khi có backup (chưa có `serverName`), để giá trị rỗng: mặc định của chart. Cluster không còn mà `Backup` của nó còn nghĩa là nó bị
  xoá sau khi đã có dữ liệu (một lần phục hồi dừng giữa chừng): chart sẽ tạo một database rỗng thay chỗ, nên script dừng trước khi
  nâng chart `svp-data`. Script cũng dừng với Cluster đang được phục hồi (`bootstrap.recovery` đã đặt, chưa Ready): nâng cấp sẽ bỏ
  `bootstrap.recovery` và `externalClusters`, mà chart chỉ render trên dòng lệnh của chính lần phục hồi, trong khi lần phục hồi còn
  đọc chúng.
- **Diễn tập khôi phục** (bài lab `drills/` của `svp-labs`) xoá Cluster và ổ rồi dựng lại cùng tên từ backup: RTO đo trên máy
  151 s (`MODE=latest`, một lượt) và 85, 126 s (`MODE=pitr`, hai lượt; ADR-0020 "Restore RTO/RPO"); trên runner CI (4 vCPU, không
  so với máy) `latest` 95,2 và 92,8 s, `pitr` 80,8 và 84,3 s.
- **RPO:** lượt `latest` không dòng nào ghi trong phút cuối trở lại (RPO ≥ 60 s), vì Postgres chỉ lưu segment WAL đã đóng: RPO tới
  `archive_timeout` (5 phút) cộng thời gian lưu, cả khi tắt êm.
- **Giới hạn:** backup cùng cluster, cùng ổ với dữ liệu, không mã hoá lúc nghỉ: chỉ đúng cho lab. Compose dùng Postgres native
  chung nên không backup. Cloud dùng backup tự động và PITR của RDS ([chưa đo trên cloud](#chưa-đo-trên-cloud)). Plugin đọc được
  mọi Secret của cluster dev (RBAC của chart) và quyền của operator ở `cnpg-system` bị thu hẹp để không leo sang plugin
  ([`threat-model.md`](../threat-model.md) BAK-1).

## Khởi động và probe

Vì sao: [ADR-0020](../adr/0020-reliability-stage6.md), [ADR-0044](../adr/0044-grpc-readiness.md).

- Service có Postgres thử lại kết nối lúc khởi động 30 s chỉ với lỗi mạng, nên pod mới trên k3d (bị từ chối một lần ngay sau khi
  lên) không restart.
- Probe của chart nới thời hạn (liveness 5 s, readiness 2 s;
  [`deploy/helm/svp-service/templates/deployment.yaml`](../../deploy/helm/svp-service/templates/deployment.yaml)) để node bận CPU
  không làm kubelet giết pod còn sống.
- Readiness của bốn service gRPC hỏi tên health `readiness`: một vòng nền ping pool Postgres của service mỗi 2 s (timeout 1 s), 3
  lần lỗi liên tiếp thì NOT_SERVING, một lần qua là SERVING, nên pod không tới được database rời Service và pod mới chỉ vào Service
  khi database trả lời.
- Liveness, startup, healthcheck của compose và `/readyz` của gateway giữ health tổng `""`, không phụ thuộc database: restart không
  chữa được database chết.

## Hạn ghi của Like và Unlike

Vì sao: [ADR-0031](../adr/0031-chaos-findings-feed-engagement-tempo.md) §2.

Phần Postgres của Like và Unlike ở engagement-service có hạn 1 s (`writeTimeout` trong
`services/engagement-service/internal/server/server.go`), tính cả thời gian chờ kết nối của pool ghi. Mỗi thao tác là một câu lệnh
chạy ở chế độ mặc định của pgx: chuẩn bị câu lệnh một lần cho mỗi kết nối rồi giữ lại. Số round trip vì vậy phụ thuộc kết nối:

- kết nối đã chạy câu lệnh này: một round trip;
- kết nối chạy câu lệnh lần đầu: hai (chuẩn bị, rồi thực thi);
- kết nối mới: thêm TCP connect và khởi động Postgres cùng xác thực, tức vài round trip nữa;
- kết nối rảnh quá 1 s: pool ping thêm một round trip trước khi giao kết nối.

Với mỗi round trip 200 ms, kết nối có sẵn trả lời trong 200 đến 600 ms, nằm gọn trong hạn, còn kết nối mới thì không. Khi đó người
gọi nhận `UNAVAILABLE` sau 1 s, thay vì chờ hết hạn gọi 3 s của gateway.

## Vận hành

Vì sao: [ADR-0020](../adr/0020-reliability-stage6.md) §12, §14.

- [`runbooks/`](../runbooks/) có một runbook cho mỗi cảnh báo page (`runbook_url` trên rule, link đi kèm thông báo) và runbook cho
  các sự cố đã gặp; [`postmortems/`](../postmortems/) theo mẫu không đổ lỗi; RFC một trang cho người không làm kỹ thuật ở
  [`rfc/`](../rfc/).
- Game day trên compose (`gameday` của bài lab `drills/` của `svp-labs`: tắt engagement-service dưới tải k6, người trực chỉ theo runbook); lượt đầu cảnh báo sau
  75 s, hồi phục sau 184 s, postmortem ở
  [`postmortems/261024-gameday-engagement-down.md`](../postmortems/261024-gameday-engagement-down.md).
- Job `stack` của CI dựng compose trên runner và chạy smoke, e2e web, k6 `ci`, Lighthouse ở mọi PR, chỉ báo, ngoài `ci-ok`.

## Kiểm chứng trên runner

Vì sao: [ADR-0021](../adr/0021-deferred-verification-stage6b.md), [ADR-0039](../adr/0039-mainpath-drills-scan-gate-sourcemaps.md) §1.

Những gì máy 16 GB không chạy nổi chạy trên runner GitHub `ubuntu-24.04` (4 vCPU, 16 GB, amd64, VM mới mỗi job) bằng workflow
`verify.yml`: dispatch tay một kịch bản, `compose-obs` hay `gitops`, và lịch hằng tuần trên `main` chạy cả hai, mỗi kịch bản dựng
bằng đúng target `make` của máy. Workflow chỉ giữ regression của bản phát hành (smoke, threat model, supply chain, test object
store); các kịch bản đo một lần là bài lab `drills/` của `svp-labs`: `dev-k3d`, `web-canary`, `k6-cloud-mini`, `chaos`, `velero`.
Không secret; cổng đĩa của `verify-host.sh` dừng lượt trước khi thiếu chỗ; artifact chỉ theo danh sách cho phép, quét giá trị bí
mật. Số của runner (amd64, không VM) chỉ so với ngân sách và ngưỡng, không thay số của máy.

Kết luận từ các lượt đo, còn áp dụng (số đo và lượt chạy ở ADR-0017, 0020, 0021, 0031):

- RAM đỉnh của đường dev và RAM nghỉ của đường GitOps (7 510 MiB ở 60 s, phần chênh phần lớn là Argo CD) vượt ngân sách của laptop.
- Canary web promote và abort đúng với hai bản build thật; ngưỡng p99 canary của web 250 ms.
- k6 thu nhỏ đạt tới 2 pod (110 req/s); mức 4 pod chạm trần CPU của runner.
- Chaos Mesh: tắt broker Kafka trong cluster 5 phút (đo trên broker trước khi đổi sang `apache/kafka`,
  [ADR-0053](../adr/0053-msk-elasticache-valkey.md)) và kill pod gateway giữ SLO. Hai phát hiện (feed-service một replica mất pod thì feed 5xx;
  engagement-service chậm 200 ms thì like hết hạn) và Tempo OOM sửa theo
  [ADR-0031](../adr/0031-chaos-findings-feed-engagement-tempo.md), kiểm lại đạt.
- Velero đích RustFS phục hồi giữ offset (RTO 58 s).
- LCP mobile mô phỏng sát ngưỡng 2,5 s trên runner mà chưa ổn định: Lighthouse là tín hiệu hồi quy, chuẩn là RUM p75 (ADR-0020,
  Kết quả "LCP").

## Chưa đo trên cloud

Vì sao: [ADR-0020](../adr/0020-reliability-stage6.md), [ADR-0034](../adr/0034-aws-stage7.md).

Cần dịch vụ cloud nên chạy ở cluster AWS ([`deployment.md`](deployment.md#aws)): k6 1 000 req/s, Chaos Mesh trên EKS, diễn tập
phục hồi RDS, Velero với S3 và snapshot EBS, hạn 50 ms của Valkey trên ElastiCache, khởi động lại một broker MSK khi đang ghi
không mất event và failover ElastiCache không làm service lỗi quá timeout của nó (buổi prd, ADR-0053 mục Xác nhận). Job k6 của phần này kiểm schema bằng
`make cloud-check` (manifest Chaos Mesh, Velero lấy từ bài lab khi cần).
