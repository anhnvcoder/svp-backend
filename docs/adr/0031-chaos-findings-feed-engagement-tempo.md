# 0031. Sửa ba phát hiện của Chaos Mesh và k6 trên runner: feed-service luôn hai replica, engagement-service lỗi nhanh có kiểm soát khi Postgres chậm hay mất, Tempo tự giới hạn bộ nhớ, không sampling

- Trạng thái: Chấp nhận
- Ngày: 2026-10-29
- Người quyết: người học (duyệt đề xuất của ADR này)

## Bối cảnh và vấn đề

Kịch bản `chaos` và `k6-cloud-mini` của [ADR-0021](0021-deferred-verification-stage6b.md) trên runner `ubuntu-24.04` (4 vCPU, amd64;
Chaos Mesh và Job k6 trên k3d của runner, [ADR-0020](0020-reliability-stage6.md) §7) cho ba phát hiện:

- **feed-service một replica** (HPA 1–2 theo CPU 70 %, không PDB, [ADR-0014](0014-kubernetes-local-stage4.md) §10): kill pod duy nhất
  thì feed 5xx 0,28 % trong 10 phút (giả thuyết < 0,1 %), vì thử lại của gateway khi `UNAVAILABLE` chờ tổng khoảng 0,15 s, hết trước 2 s
  không có pod nào Ready. Gateway (2 replica) qua lần kill với feed 5xx 0.
- **engagement-service khi Postgres chậm** (`NetworkChaos` `delay` 200 ± 20 ms, không `target`): feed giữ, breaker không mở, nhưng like lỗi
  18,5 %, p99 bằng `callTimeout` 3 s của gateway (504). Like/Unlike là transaction 4 round trip nối tiếp; pool pgx mặc định max(4, NumCPU)
  dùng chung với `GetStats` mà gateway cắt ở 100 ms, nên mỗi `GetStats` hết hạn đóng một kết nối và pool phải dựng lại trong khi Like chờ
  `Acquire` (phần 1–3 s là suy luận, chưa đo). Mục tiêu của (b) ở ADR-0020 §7: feed sống, like và view không 5xx chậm, breaker chỉ mở khi
  engagement-service hỏng thật.
- **Tempo OOM** (Tempo 3.1.0 single binary có metrics-generator, limit 768 Mi): pod `OOMKilled` duy nhất ở hai lượt chaos (k6 1 pod sau
  thời gian dài) và ở mức 4 pod của `k6-cloud-mini`; runner còn RAM. Không sampler nào (giữ mọi trace); thiếu chuỗi RAM và metric ingest.

Số của từng lượt, mã lượt chạy và bảng kiểm source thư viện (grpc-go, pgx, puddle, otelpgx) ở
[phụ lục](appendix/0031-chaos-findings-feed-engagement-tempo.md#bối-cảnh).

## Yếu tố quyết định

- Sống sót khi mất một pod feed; lỗi nhanh có kiểm soát thay vì 504 chậm; breaker không mở oan và vẫn mở khi engagement-service chết.
- Không mất trace dưới tải diễn tập (diễn tập tìm trace của đúng một request); ngân sách RAM của cluster trên máy 16 GB; ít code tự viết.

## Phương án đã cân nhắc

- §1 feed-service: A giữ HPA 1–2.
- §1 **B HPA 2–2, PDB `minAvailable: 1`, ưu tiên trải hai node như gateway**.
- §1 C HPA 2–N: ngoài phạm vi, ngân sách RAM.
- §1 D cân bằng tải phía client ngay: đổi chart và dial, cần ADR riêng.
- §1 E trải cứng: pod thay có thể Pending.
- §1 F gateway thử lại lâu hơn: vượt p99 150 ms, nhân tải khi feed chết thật.
- §2 số round trip của Like: A giữ transaction 4 câu.
- §2 **B một câu SQL (CTE), giữ chế độ thực thi mặc định của pgx**.
- §2 C một câu với `QueryExecModeExec`: đổi cách mã hoá tham số của mọi câu.
- §2 cách ly `GetStats`: D chỉ tăng pool.
- §2 E hạn `Acquire` cộng `statement_timeout`.
- §2 F semaphore cho `GetStats`: constructor của puddle chạy tiếp, phức tạp hơn.
- §2 **G hai pool tách ngân sách, tổng tường minh**.
- §2 H cancel request của pgx: thêm kết nối mỗi lần huỷ.
- §2 hạn và lỗi: I hạn theo method ở gateway: không dừng việc ở Postgres.
- §2 **J hạn ghi phía server, lỗi Postgres là lỗi phụ thuộc không thử lại**.
- §3 Tempo: A chỉ nâng limit.
- §3 **B cấu hình Tempo chặn từng phần giữ bộ nhớ, cộng trần ingest**.
- §3 C head sampling ở SDK: làm diễn tập hụt trace.
- §3 D tail sampling ở Collector: làm diễn tập hụt trace.
- §3 E tắt metrics-generator.
- §3 F tiêu chí "runner đủ" bỏ qua OOM ở `svp-obs`: che lỗi.

Phân tích từng phương án ở [phụ lục](appendix/0031-chaos-findings-feed-engagement-tempo.md#1-feed-service-luôn-hai-replica).

## Kết quả quyết định

Chọn **B** cho §1, **B**, **G**, **J** cho §2, **B** cho §3, vì đó là cách hẹp nhất đạt từng mục tiêu ở trên mà không thêm
sampling hay code tự viết. Dòng chi tiết rút khỏi các § ở [mục "Chi tiết rút khỏi ADR"](appendix/0031-chaos-findings-feed-engagement-tempo.md#chi-tiết-rút-khỏi-adr).

### 1. feed-service luôn hai replica

- Values gốc của feed-service (đường dev `make k8s-up` và đường GitOps cùng đọc): `hpa.minReplicas: 2`, `hpa.maxReplicas: 2`,
  `cpuUtilization` giữ 70, `pdb.minAvailable: 1`, `spreadAcrossNodes: true`. Overlay prd ([ADR-0024](0024-multi-environment.md)) giữ
  `hpa.minReplicas: 2`, `pdb`, `spreadAcrossNodes` theo chính sách riêng của prd, dù nay trùng gốc.
- Trải node là ưu tiên, không bảo đảm (`whenUnsatisfiable: ScheduleAnyway`): hai pod có thể cùng node. `maxReplicas` giữ 2 vì phạm vi
  (sống sót khi mất một pod) và RAM của cluster dev; HPA nay không co giãn, giữ để nâng tối đa khi có số tải.

### 2. engagement-service lỗi nhanh có kiểm soát khi Postgres chậm hay mất

- **Like/Unlike một câu SQL** (CTE: insert hay delete dòng `likes`, rồi đổi `like_counts` chỉ khi dòng thật sự đổi) thay transaction
  `Begin`/2 câu/`Commit`. Câu đơn vẫn nguyên tử; thứ tự khoá `likes` → `like_counts` giữ như migration; like hai lần đếm một, unlike khi
  chưa like không đổi gì. Chế độ `QueryExecModeCacheStatement` của pgx v5.11.0 giữ: kết nối ấm 1 round trip (rảnh quá 1 s thêm 1 ping),
  câu lần đầu trên kết nối 2, kết nối mới thêm dial, TLS và SCRAM; dưới trễ 200 ms là 0,2–0,6 s trên kết nối có sẵn, kết nối mới ≥ 1,2 s.
- **Hạn ghi phía server 1 s** cho phần Postgres của Like/Unlike, tính cả chờ kết nối của pool, dưới `callTimeout` 3 s của gateway. Hết
  hạn của chính nó, hay **Postgres không tới được**, thì trả `UNAVAILABLE` kèm `ErrorInfo` `DEPENDENCY_UNAVAILABLE` và trailer
  `grpc-retry-pushback-ms: -1`, để retry policy của gateway không thử lại; gateway trả 503 ngay; breaker không tính vì có `ErrorInfo`.
  "Không tới được" gồm lỗi lúc mở kết nối (refused, timeout, cắt lúc bắt tay), lỗi sau khi đã nối (EOF, reset, lỗi đọc hay ghi socket)
  và SQLSTATE lớp `08` hay `57P01`–`57P03`. Phân loại nằm ở engagement-service; luật thử lại lúc khởi động của `internal/pgretry` giữ
  nguyên (`Retryable` chỉ nhận `*pgconn.ConnectError`). Hạn của người gọi hết trước thì giữ như cũ (`DEADLINE_EXCEEDED`, `CANCELLED`);
  lỗi khác vẫn `INTERNAL`.
- **Hai pool tách ngân sách, tổng tường minh:** engagement-service đọc `DATABASE_MAX_CONNS` = tổng kết nối Postgres của một process, số
  nguyên ≥ 2, không đặt thì 10, giá trị khác thì service không khởi động; values của k3d đặt `"10"`, compose không đặt. Pool **đọc** (chỉ
  `GetStats`) có ⌊n/2⌋ kết nối, pool **ghi** (Like, Unlike, consumer lượt xem) có phần còn lại; cùng URL, cùng role. Đúng vì puddle v2.2.2
  tính cả kết nối đang dựng vào `MaxConns` của từng pool, nên churn của `GetStats` nằm trong chỗ của pool đọc. `internal/pgpool` nhận kích
  thước và tên pool qua tuỳ chọn; service khác gọi như cũ; số liệu otelpgx phân biệt hai pool bằng thuộc tính tên.
- **Đảo một phần [ADR-0010](0010-redis-ratelimit-cache-resilience-stage2c.md) §4:** bulkhead "không thêm" (nay hai pool ở
  engagement-service) và timeout "một hạn chung" (nay thêm hạn ghi 1 s cho Like/Unlike); "Mã `UNAVAILABLE` vẫn được retry" không còn
  đúng với Like/Unlike. Phần còn lại của §4 giữ.

### 3. Tempo tự giới hạn bộ nhớ, không sampling

- Cấu hình Tempo 3.1.0 chặn từng phần giữ bộ nhớ; tham số, giá trị và phép tính ở `deploy/k8s/values/tempo.yaml`. metrics-generator giữ.
  `limits.memory` nâng tối đa 1 Gi, chỉ khi phép tính cần; `requests.memory` giữ 128 Mi.
- **Trần ingest đặt trên tốc độ span ở k6 4 pod, có biên**, nên tới mức đó Tempo không từ chối span.
- **Tiêu chí mất dữ liệu**, ở mọi thí nghiệm chaos và các mức 1, 2, 4 pod của `k6-cloud-mini`: 0 span bị Collector từ chối ở receiver
  (`otelcol_receiver_refused_spans`), 0 span exporter gửi lỗi hay không vào được hàng đợi, 0 span bị Tempo từ chối; span bị từ chối tính là
  có thể mất. Mức 8 pod chỉ ghi số.
- **Tempo còn thu và đọc được**, mỗi cửa sổ giữ tải: tìm thấy trace của gateway bắt đầu trong cửa sổ, lấy được trace đó theo id, cạnh
  gateway → feed-service của service graph có tốc độ > 0; working set đỉnh của `tempo` dưới limit, 0 OOM. Sampler của runner lấy thêm
  `svp-obs` vào `pods.tsv`.
- **Không sampling** (C, D bị loại vì diễn tập tìm trace của đúng một request); quyết lại khi đo 1 000 req/s trên cloud.

### Hệ quả

- Tốt: mất một pod feed-service còn một pod phục vụ; Postgres chậm hay mất thì like trả 503 trong khoảng 1 s thay vì 504 sau 3 s, feed
  và lượt xem chạy tiếp; kích thước pool không đổi theo máy, `GetStats` không lấy kết nối của Like; Tempo có trần bộ nhớ thay vì OOM lặp.
- Xấu: feed-service thêm một pod kể cả lúc nghỉ, hai pod có thể cùng node, tải có thể lệch. Like gặp lỗi Postgres tạm thời không còn
  được gateway thử lại (client thử lại; Like/Unlike idempotent). Postgres chậm 1–3 s: like 503 thay vì thành công chậm; Postgres treo
  thì mỗi like chờ đủ 1 s. Mỗi 503 có pushback âm trừ một token của `retryThrottling`. `GetStats` vắng `stats` khi Postgres chậm hay pool
  đọc đầy, pool đọc dựng lại kết nối liên tục. Like dùng tối đa phần ghi (5 trên 10). Tempo từ chối span khi tốc độ vượt trần.
- Xem lại khi: (a) feed-service lại 5xx quá 0,1 %, cần quá 2 replica hay hai pod lệch tải rõ (bước kế là cân bằng tải phía client, ADR
  riêng); Like trả `DEPENDENCY_UNAVAILABLE` lúc Postgres khoẻ hay chờ kết nối của pool ghi (`pgxpool.*`) gần 1 s (xem lại hạn và cách
  chia ⌊n/2⌋); đổi Postgres (RDS, pooler, nhiều replica: xem lại `DATABASE_MAX_CONNS`); Tempo còn OOM hay từ chối span ở mức 1, 2, 4 pod
  (xem lại trần, limit, rồi sampling); đo 1 000 req/s (quyết sampling và cỡ Tempo).

## Xác nhận

- Lượt runner 2026-10-29: `chaos` 11/11 bước, runner đủ mọi tiêu chí (`no_oom=true`); `dev-k3d` 14/14 bước gồm `drill-k8s-pdb` mở rộng;
  `k6-cloud-mini` hai lượt, mức 1, 2 đạt, `tempo-ingest-*` đạt ở mọi mức.
- §1 đạt: (a) feed-service 5xx 0, `drill-k8s-pdb` 201 rồi 429, hai pod ở hai node. §2 đạt: (b) like + view 5xx 0, breaker đóng.
  §3 đạt: không OOM, 0 span bị từ chối hay bỏ, đọc lại được trace.
- Còn mở: tải lệch giữa hai pod feed (một pod khoảng gấp đôi pod kia), biên bộ nhớ của Tempo ở mức 4 pod mỏng, `pgxpool.*` chưa đo.
  Số và mã lượt chạy ở [phụ lục](appendix/0031-chaos-findings-feed-engagement-tempo.md#kết-quả).

## Hiện thực ở

- feed-service hai replica (§1): `deploy/k8s/values/services/feed-service.yaml` (HPA, PDB, trải node); giả thuyết của
  `deploy/k8s/cloud/chaos/a-pod-kill-feed-service.yaml`; diễn tập drain ở `deploy/k8s/drills/pdb.sh`, target `drill-k8s-pdb` của
  `deploy/k8s/k8s.mk`.
- engagement-service lỗi nhanh (§2): `services/engagement-service/` (`queries/likes.sql`, code sinh ở `internal/store/`, hạn ghi, phân loại
  lỗi và hai pool ở `internal/server/` và `cmd/engagement-service/`); kích thước và tên pool ở `internal/pgpool/`; proxy giả Postgres chậm
  ở `internal/pgretry/pgretrytest/`; `DATABASE_MAX_CONNS` ở `deploy/k8s/values/services/engagement-service.yaml`; test retry và breaker
  của gateway ở `services/gateway/cmd/gateway/main_test.go`; giả thuyết của `deploy/k8s/cloud/chaos/b-network-delay-engagement.yaml`.
- Tempo (§3): giới hạn bộ nhớ và trần ingest, kèm phép tính, ở `deploy/k8s/values/tempo.yaml`; phép kiểm của runner ở
  `deploy/ci/verify-tempo.sh`, step của kịch bản `chaos`, `k6-cloud-mini` (nay là bài lab `drills/` của `svp-labs`, [0039](0039-mainpath-drills-scan-gate-sourcemaps.md) §1), namespace `svp-obs` của
  `pods.tsv` ở `deploy/ci/verify-sample.sh`, bộ lọc artifact ở `deploy/ci/verify-collect.sh`, `deploy/ci/verify-collect-test.sh`.
- Hiện trạng: [`explanation/reliability.md`](../explanation/reliability.md), [`explanation/observability.md`](../explanation/observability.md).

## Thông tin thêm

Phụ lục: [`appendix/0031-chaos-findings-feed-engagement-tempo.md`](appendix/0031-chaos-findings-feed-engagement-tempo.md) (dòng trạng
thái gốc, bối cảnh có số, bảng kiểm source thư viện, phân tích phương án, kết quả từng lượt runner).

### Chỉnh bởi

- §1, §3: [0039](0039-mainpath-drills-scan-gate-sourcemaps.md): một phần bị thay: kiểm chứng bằng `drill-k8s-pdb` (§1) và
  `verify-tempo.sh` (§3) thành bài lab; PDB và giới hạn của Tempo giữ.
