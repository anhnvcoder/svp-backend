# Kiến trúc short-video platform

Tổng quan hiện trạng của hệ thống theo [arc42](https://arc42.org/overview) rút gọn, sơ đồ theo [C4 model](https://c4model.com)
viết bằng Mermaid. Mỗi mục tóm tắt và trỏ tới trang chi tiết; lý do của từng quyết định nằm ở ADR trong [`adr/`](adr/).

## 1. Mục tiêu và phạm vi

Nền tảng video ngắn: người dùng upload video, hệ thống transcode ra HLS và đưa vào feed của người theo dõi; người xem phát video,
like và để lại lượt xem. Hệ thống chạy được trên máy (compose, cluster k3d) và trên AWS (EKS), cùng image, cùng chart.

| Mã | Chức năng |
| --- | --- |
| F1 | Đăng ký, đăng nhập bằng email + mật khẩu, nhận JWT |
| F2 | Follow, unfollow người dùng khác |
| F3 | Upload video tối đa 3 phút; hệ thống transcode ra HLS; trạng thái `UPLOADING → PROCESSING → READY` hoặc `FAILED` |
| F4 | Phát video bằng HLS, tự đổi chất lượng theo mạng |
| F5 | Feed "đang theo dõi": video mới nhất của người mình follow, phân trang bằng cursor |
| F6 | Feed "khám phá": video mới nhất toàn hệ thống, cho người chưa follow ai |
| F7 | Like, unlike; ghi lượt xem; hiện số lượt xem, số like và mình đã like chưa |

**Web client** (repo `svp-frontend`, [ADR-0016](adr/0016-web-client.md), [ADR-0018](adr/0018-web-profiles-public-video-upload.md)):
Next.js phục vụ F1–F7, thêm hồ sơ tối thiểu (handle không đổi, tên hiển thị đổi được), video theo tác giả, "Video của tôi" và
trang chia sẻ `/v/:id` mở được khi chưa đăng nhập. Web là BFF: trình duyệt chỉ gọi API qua web (file video thì tải lên và phát thẳng
với object storage), token không tới trình duyệt. k6 và curl gọi thẳng gateway.

**Ngoài phạm vi:** app di động, comment, tìm kiếm, gợi ý bằng ML, thông báo, xoá/sửa video, kiểm duyệt nội dung. Thêm thì viết ADR.

## 2. Ràng buộc và yêu cầu phi chức năng

**Ràng buộc:**

- Service viết bằng Go, ưu tiên thư viện chuẩn; một Go module cho cả repo ([ADR-0007](adr/0007-go-monorepo-toolchain-and-stage1-scope.md)).
- Mỗi service một database riêng, không service nào đọc database của service khác ([ADR-0001](adr/0001-service-boundaries-and-data-ownership.md)).
- Local trước, cloud sau: máy 16 GB RAM chạy compose hoặc k3d, không cả hai cùng lúc; tài nguyên cloud dựng và xoá trong cùng buổi.
- Repo công khai: không bí mật, account ID hay tên miền thật trong git; image chỉ build, ký và đẩy trong CI.
- Đường chính (stg, prd, CI) dùng công cụ chuẩn ngành; bản tự làm ở repo `svp-labs` ([ADR-0037](adr/0037-mainpath-standard-tools.md)).

**Yêu cầu phi chức năng** (hệ thống dùng event nên dữ liệu nhất quán sau cùng; "Độ tươi" và "Nhất quán" ghi rõ chấp nhận trễ bao
nhiêu; SLO và cảnh báo ở [`explanation/reliability.md`](explanation/reliability.md#slo)):

| Mảng | Yêu cầu | Đo ở đâu |
| --- | --- | --- |
| Độ trễ | Feed p99 < 150 ms tại 1.000 req/s | SLO `feed-latency` (bucket 150 ms của `http_server_request_duration_seconds` ở gateway); k6 theo SLO, 1.000 req/s bằng Job k6 trong cluster cloud |
| Sẵn sàng | Khởi tạo upload 99,9%; đọc feed 99,9%; trang web 99,9% | SLO `upload-init-availability`, `feed-availability` (5xx ở gateway), `web-availability` (5xx của server web) |
| Xử lý video | Video 1 phút sẵn sàng phát p95 < 2 phút kể từ lúc upload xong | SLO `video-ready-latency` (`svp_video_ready_duration_seconds`, `FAILED` luôn tính xấu); `measure-ready` của bài lab `drills/` của `svp-labs` |
| Độ tươi | Video `READY` xuất hiện trong feed follower p95 < 10 s | Histogram `svp_feed_freshness_seconds` trên dashboard; `measure-freshness` của bài lab `drills/` của `svp-labs` |
| Bền dữ liệu | Video đã `CompleteUpload` thì không mất; event không mất; database phục hồi được từ backup | Diễn tập kill worker; backup Postgres và diễn tập khôi phục đo RTO, RPO ([`explanation/reliability.md`](explanation/reliability.md#backup-và-phục-hồi-postgres)) |
| Đúng đắn | Event gửi trùng không làm sai bộ đếm, không transcode hai lần ra kết quả khác | Test nhận cùng event hai lần ở mỗi consumer |
| Nhất quán | Số lượt xem trễ tối đa ~1 phút; like của chính mình thấy ngay | — |
| Vận hành | Mọi request có `trace_id`; deploy không downtime; cảnh báo theo SLO | Trace OpenTelemetry, log có `trace_id`; canary; burn rate qua Alertmanager, runbook cho mọi cảnh báo page |
| Chi phí | Local trước; tài nguyên cloud dựng và xoá trong cùng buổi | Budget alert |

**Quy mô:** với 100k DAU, feed chỉ ~21 req/s lúc cao điểm; 1.000 req/s là mục tiêu tải có chủ ý cho k6. Tiền nằm ở egress
(~1,1 PB/tháng) nên CDN bắt buộc; ghi nóng nằm ở lượt xem (~10.000 event/s ở mục tiêu tải) nên gom ghi theo lô; transcode ít nhưng
nặng và dồn cục. Giả định và bảng tính: [`explanation/capacity.md`](explanation/capacity.md).

## 3. Ngữ cảnh

```mermaid
flowchart TB
    user["<b>Người dùng</b><br/>[Người]<br/>Xem feed, upload, like"]
    ops["<b>Người vận hành</b><br/>[Người]<br/>Dev, on-call"]
    svp["<b>Short-video platform</b><br/>[Hệ thống]<br/>Upload, transcode HLS, feed, like/view"]
    gh["<b>GitHub</b><br/>[SaaS]<br/>Code, CI, GHCR, repo svp-gitops"]
    sigstore["<b>Sigstore</b><br/>[SaaS]<br/>Chữ ký keyless, bằng chứng image"]
    chat["<b>Telegram</b><br/>[SaaS, tuỳ chọn]<br/>Kênh cảnh báo page"]

    user -->|"trình duyệt: web; tải HLS qua HTTPS"| svp
    ops -->|"Grafana, GlitchTip, Argo CD"| svp
    ops -->|"pull request"| gh
    svp -->|"Argo CD đọc cấu hình; kéo image đã ký"| gh
    svp -->|"Kyverno kiểm chữ ký"| sigstore
    svp -->|"gửi cảnh báo"| chat
    chat -->|"báo"| ops
```

Bộ quan sát (Grafana LGTM, GlitchTip) tự host bên trong hệ thống; trên AWS có thêm RDS, S3, CloudFront ([mục 7](#7-triển-khai)).

## 4. Chiến lược giải pháp

| Quyết định | Vì sao |
| --- | --- |
| Sáu service theo ranh giới nghiệp vụ, mỗi service một database | [ADR-0001](adr/0001-service-boundaries-and-data-ownership.md) |
| REST/JSON ở biên (gateway), gRPC bên trong, contract quản lý bằng `buf`, ID là UUIDv7 | [ADR-0002](adr/0002-sync-rest-edge-grpc-internal.md), [ADR-0006](adr/0006-contract-ids-and-event-envelope.md) |
| Event qua Redpanda, transactional outbox, at-least-once + consumer idempotent + DLQ; lượt xem gom theo lô, offset trong Postgres | [ADR-0003](adr/0003-async-events-outbox.md), [ADR-0009](adr/0009-engagement-feed-stage2b.md), [ADR-0045](adr/0045-bounded-batch-retry.md) |
| Upload thẳng lên object storage bằng presigned POST, transcode bất đồng bộ ra HLS, output bất biến theo version | [ADR-0004](adr/0004-direct-upload-and-hls.md), [ADR-0029](adr/0029-immutable-media-versions.md) |
| Feed dựng sẵn khi ghi (fan-out on write), Redis chỉ cache trang đầu feed khám phá | [ADR-0005](adr/0005-feed-fan-out-on-write.md), [ADR-0010](adr/0010-redis-ratelimit-cache-resilience-stage2c.md) |
| Rate limit GCRA bằng Redis, retry và circuit breaker cho lời gọi gRPC ở gateway | [ADR-0010](adr/0010-redis-ratelimit-cache-resilience-stage2c.md) |
| JWT ký ở user-service, kiểm ở gateway và ở mỗi service; refresh token xoay; session BFF ở Redis | [ADR-0016](adr/0016-web-client.md), [ADR-0042](adr/0042-caller-identity-grpc.md), [ADR-0046](adr/0046-web-session-lifetime.md) |
| Web client Next.js ở repo riêng, hợp đồng REST có version | [ADR-0016](adr/0016-web-client.md), [ADR-0033](adr/0033-svp-web-repo.md) |
| OpenTelemetry qua Collector tới Grafana LGTM, GlitchTip cho lỗi, SLO bằng Sloth | [ADR-0011](adr/0011-observability-stage3.md), [ADR-0012](adr/0012-elastic-vs-grafana-stage3.md) |
| Cùng chart chạy trên k3d và EKS, Envoy Gateway, dữ liệu trong cluster (trên AWS: RDS, S3 managed) | [ADR-0014](adr/0014-kubernetes-local-stage4.md), [ADR-0034](adr/0034-aws-stage7.md) |
| Build một lần, ký keyless, Kyverno chỉ nhận image đã ký; mọi env chạy cùng digest qua `svp-gitops` và Argo CD; secret từ kho ngoài git bằng External Secrets Operator | [ADR-0015](adr/0015-cicd-devsecops-stage5.md), [ADR-0024](adr/0024-multi-environment.md), [ADR-0025](adr/0025-gitops-config-repo.md), [ADR-0026](adr/0026-secrets-gitops.md), [ADR-0040](adr/0040-sigstore-bundle-actions-attest.md) |

## 5. Khối

Mức container của C4. Nét liền là gọi đồng bộ, nét đứt là event qua Redpanda.

```mermaid
flowchart LR
    browser["<b>Trình duyệt, k6, curl</b>"]
    subgraph svp["Short-video platform"]
        web["<b>web</b><br/>[Next.js, Node]<br/>Trang, BFF: session, CSRF, CSP, proxy /api/*"]
        gw["<b>gateway</b><br/>[Go, net/http]<br/>JWT, rate limit, ghép dữ liệu"]
        us["<b>user-service</b><br/>[Go, gRPC; Postgres svp_user]<br/>Tài khoản, follow, hồ sơ"]
        vs["<b>video-service</b><br/>[Go, gRPC; Postgres svp_video]<br/>Metadata, vòng đời video"]
        mw["<b>media-worker</b><br/>[Go + ffmpeg]<br/>Transcode HLS"]
        es["<b>engagement-service</b><br/>[Go, gRPC; Postgres svp_engagement]<br/>Like, view, bộ đếm"]
        fs["<b>feed-service</b><br/>[Go, gRPC; Postgres svp_feed]<br/>Read model feed"]
        bus[["<b>Redpanda</b><br/>[Kafka API]"]]
        obj[("<b>Object storage</b><br/>[RustFS / S3]<br/>bucket uploads, media")]
        cdn["<b>CDN</b><br/>[CloudFront]<br/>chỉ có trên cloud"]
        redis[("<b>Redis</b>")]
    end

    browser -->|"HTML, /api/*, cookie svp_sid;<br/>POST /monitoring, /rum"| web
    browser -->|"POST file bằng presigned URL;<br/>GET HLS (local: thẳng object store)"| obj
    browser -->|"GET HLS, thumbnail"| cdn
    browser -->|"k6, curl: REST/JSON"| gw
    web -->|"REST/JSON + Bearer"| gw
    web -->|"session, khoá refresh (db 9)"| redis
    cdn --> obj

    gw -->|"rate limit"| redis
    gw -->|gRPC| us
    gw -->|gRPC| vs
    gw -->|gRPC| es
    gw -->|gRPC| fs

    vs -->|"ký URL, HEAD"| obj
    mw -->|"đọc file gốc, ghi HLS"| obj
    fs -->|"cache feed khám phá"| redis

    us -.->|"user.followed, user.unfollowed"| bus
    vs -.->|"video.uploaded, video.ready"| bus
    bus -.->|"video.uploaded"| mw
    mw -.->|"transcode.completed, transcode.failed"| bus
    bus -.->|"transcode.*"| vs
    es -.->|"view.recorded"| bus
    bus -.->|"view.recorded"| es
    bus -.->|"user.*, video.ready"| fs
```

Mỗi service chỉ đọc ghi database của mình; event về một thực thể chỉ do service sở hữu thực thể đó phát
([ADR-0001](adr/0001-service-boundaries-and-data-ownership.md)). gateway và media-worker không có database; feed-service giữ bản
sao follow và video `READY` dựng từ event; hồ sơ công khai không phát event, gateway ghép lúc đọc.

| Event | Phát | Key (partition) | Nhận | Để làm gì |
| --- | --- | --- | --- | --- |
| `user.followed` | user-service (outbox) | `follower_id` | feed-service | Thêm cạnh vào bản sao, đưa video gần đây của người được follow vào timeline |
| `user.unfollowed` | user-service (outbox) | `follower_id` | feed-service | Xoá cạnh, bỏ video của người đó khỏi timeline |
| `video.uploaded` | video-service (outbox) | `video_id` | media-worker | Bắt đầu transcode |
| `transcode.completed` | media-worker | `video_id` | video-service | Báo kết quả: các bản HLS, thời lượng, thumbnail |
| `transcode.failed` | media-worker | `video_id` | video-service | Báo lỗi; video-service chuyển `FAILED` và dọn file (bước bù của saga) |
| `video.ready` | video-service (outbox) | `video_id` | feed-service | Video phát hành, kèm đủ metadata để feed không phải gọi lại |
| `view.recorded` | engagement-service (produce thẳng) | `video_id` | engagement-service | Hàng đệm cho lượt xem; consumer gom theo lô rồi cộng vào bộ đếm |

`video.ready` do video-service phát vì nó sở hữu video; media-worker chỉ báo kết quả job. Không có `video.failed`, `like.toggled`
vì chưa service nào cần nhận ([ADR-0003](adr/0003-async-events-outbox.md)). Schema ở [`proto/`](../proto/), topic và envelope ở
[`reference/contracts.md`](reference/contracts.md#topic).

## 6. Runtime

### 6.1 Upload tới khi vào feed

```mermaid
sequenceDiagram
    participant C as Client
    participant GW as gateway
    participant VS as video-service
    participant S3 as Object storage
    participant RP as Redpanda
    participant MW as media-worker
    participant FS as feed-service

    C->>GW: POST /videos (title, size, content_type), Idempotency-Key tuỳ chọn
    GW->>VS: InitUpload
    VS-->>C: video_id (UPLOADING), URL và field của presigned POST (hết hạn 15 phút)
    C->>S3: POST file gốc (form kèm policy đã ký)
    C->>GW: POST /videos/{id}/complete
    GW->>VS: CompleteUpload
    VS->>S3: HEAD: kiểm kích thước, content type
    VS->>VS: 1 transaction: PROCESSING + outbox video.uploaded
    VS-->>C: 202, PROCESSING
    VS--)RP: relay phát video.uploaded
    RP--)MW: video.uploaded
    MW->>S3: tải file gốc, ffmpeg, ghi HLS vào media/{video_id}/{version}/{attempt}/
    MW--)RP: transcode.completed
    RP--)VS: transcode.completed
    VS->>VS: 1 transaction: READY + outbox video.ready
    VS--)RP: relay phát video.ready
    RP--)FS: video.ready
    FS->>FS: lưu bản sao video, ghi theo lô vào timeline của từng follower
```

Saga dạng choreography: mỗi service nghe event rồi làm phần của mình. Transcode lỗi thì media-worker phát `transcode.failed`,
video-service chuyển `FAILED` và xoá file dở dang. Mọi bước chịu được event trùng: media-worker ghi output theo version (`event_id`
của `video.uploaded`), master tạo một lần bằng `If-None-Match: *` ([ADR-0029](adr/0029-immutable-media-versions.md));
video-service chỉ chuyển trạng thái một chiều; feed-service ghi timeline với khoá chính chống trùng.

### 6.2 Đọc feed

Gateway kiểm JWT và rate limit, lấy trang video kèm object key và page token từ feed-service, rồi gọi song song `GetStats` của
engagement-service và `GetProfiles` của user-service, mỗi lời gọi timeout 100 ms, không retry. Hai service đó chậm hay lỗi thì feed
vẫn trả về, chỉ thiếu `stats` hay `author` (graceful degradation, [ADR-0018](adr/0018-web-profiles-public-video-upload.md) §5);
danh sách video theo tác giả và trang một video ghép cùng cách. Chống quá tải và lỗi lan ([ADR-0010](adr/0010-redis-ratelimit-cache-resilience-stage2c.md)):

- **Rate limit** GCRA theo lớp route; Redis lỗi thì lớp `read`, `write` mở, các lớp còn lại đóng mềm bằng bộ đếm trong bộ nhớ
  (ngưỡng từng lớp ở [`reference/contracts.md`](reference/contracts.md#rest-ở-gateway)).
- **Cache khám phá:** chỉ trang đầu, TTL 5 s, không xoá chủ động; Redis lỗi hay quá 50 ms thì đọc Postgres, không báo lỗi.
- **Retry và circuit breaker** ở gateway, một breaker mỗi service đích: lời gọi idempotent thử lại khi `UNAVAILABLE` trong hạn
  3 s; breaker mở thì lỗi ngay không gọi mạng (feed trả trang không `stats`, like trả 503). `GetStats`, `GetProfiles` không
  retry và `DEADLINE_EXCEEDED` của chúng không mở breaker.

### 6.3 Ghi lượt xem

`POST /videos/{id}/views`: engagement-service phát `view.recorded` lên Redpanda (`acks=all`) rồi trả 202, không chạm database.
Consumer của nó gom lô tối đa 5.000 record hoặc 1 s, cộng dồn theo `video_id`, ghi cả lô bằng một câu `INSERT ... ON CONFLICT DO
UPDATE` vào `view_counts`. Bảng `consumer_offsets` giữ offset từng partition, cập nhật trong cùng transaction với bộ đếm, nên lô giao
lại chỉ cộng phần chưa cộng ([ADR-0009](adr/0009-engagement-feed-stage2b.md)). Lỗi tạm thời thử lại trong ngân sách 5 phút rồi
chép lô sang `engagement.views.v1.dlq` ([ADR-0045](adr/0045-bounded-batch-retry.md), [runbook](runbooks/kafka-dlq-records.md)).
Like đi đường đồng bộ: bảng `likes` và `like_counts` đổi trong cùng transaction, nên like của chính mình thấy ngay.

### 6.4 Xác thực

user-service cấp JWT ký bằng khoá riêng; gateway kiểm chữ ký bằng khoá công khai, rồi chuyển tiếp chính access token xuống service
trong gRPC metadata `authorization`; mỗi service kiểm lại bằng `JWT_VERIFY_KEYS` và lấy người gọi từ `sub`
([ADR-0042](adr/0042-caller-identity-grpc.md)). Login trả thêm refresh token mờ (user-service chỉ lưu SHA-256), xoay mỗi lần dùng;
trình lại token đã dùng thì cả họ bị thu hồi ([ADR-0016](adr/0016-web-client.md)). Session của web có idle và absolute timeout
([ADR-0046](adr/0046-web-session-lifetime.md)).

```mermaid
sequenceDiagram
    participant B as Trình duyệt
    participant W as web (BFF)
    participant R as Redis db 9
    participant G as gateway
    participant U as user-service
    B->>W: POST form đăng nhập (Server Action, kiểm CSRF)
    W->>G: POST /auth/login
    G->>U: Login
    U-->>W: access token, refresh token (họ mới)
    W->>R: session mới (khoá sha256(sid))
    W-->>B: Set-Cookie svp_sid (HttpOnly), 303
    W->>R: access token sắp hết hạn: SET khoá refresh NX (single-flight giữa replica)
    W->>G: POST /auth/refresh
    G->>U: Refresh (một transaction, khoá theo họ)
    U-->>W: cặp token mới, token cũ đánh dấu đã dùng
    W->>R: compare-and-set session
```

Refresh không rõ kết quả thì BFF giữ session và không thử lại trong request đó. Access token đã cấp sống tới hết hạn (JWT-3 của
[`threat-model.md`](threat-model.md#41-jwt-và-đăng-nhập)).

## 7. Triển khai

| Nơi | Dùng để | Dữ liệu | Chi tiết |
| --- | --- | --- | --- |
| Compose trên máy | Đường dev chính, smoke, diễn tập | Postgres, Redis native của máy; Redpanda, RustFS trong compose | [Compose](explanation/deployment.md#compose) |
| Cluster k3d | Cùng chart như cloud: Envoy Gateway, NetworkPolicy, canary, Kyverno, đường GitOps | CloudNativePG, Valkey, Redpanda, RustFS trong cluster | [k3d](explanation/deployment.md#kubernetes-cục-bộ-k3d) |
| EKS trên AWS | stg và prd, dựng bằng Terraform của `svp-infra` | RDS PostgreSQL, S3 + CloudFront; Redpanda, Valkey trong cluster | [AWS](explanation/deployment.md#aws) |

Image đi từ CI tới cluster qua `svp-gitops` và Argo CD ([`explanation/delivery.md`](explanation/delivery.md)). Sơ đồ AWS sinh từ
spec của `svp-infra`: [stg](https://github.com/anhnvcoder/svp-infra/blob/main/docs/diagrams/svp-aws-stg.png),
[prd](https://github.com/anhnvcoder/svp-infra/blob/main/docs/diagrams/svp-aws-prd.png),
[luồng](https://github.com/anhnvcoder/svp-infra/blob/main/docs/diagrams/svp-aws-flows.png).

## 8. Khái niệm xuyên suốt

- **Contract:** [`proto/`](../proto/), REST ở [`services/gateway/openapi.yaml`](../services/gateway/openapi.yaml); topic, page token,
  mã lỗi gRPC sang HTTP, route: [`reference/contracts.md`](reference/contracts.md).
- **Idempotency:** mọi consumer chịu được event trùng; `POST /videos` nhận `Idempotency-Key` ([ADR-0043](adr/0043-idempotency-key.md)).
- **Quan sát:** OpenTelemetry Collector, lỗi ở GlitchTip, RUM của web: [`explanation/observability.md`](explanation/observability.md).
- **Bảo mật:** [`threat-model.md`](threat-model.md); chuỗi cung ứng: [`explanation/delivery.md`](explanation/delivery.md#cicd-và-chuỗi-cung-ứng).
- **Độ tin cậy:** SLO, tải, backup, probe ([ADR-0044](adr/0044-grpc-readiness.md)): [`explanation/reliability.md`](explanation/reliability.md),
  [`runbooks/`](runbooks/).

## 9. Quyết định

Danh sách ADR, trạng thái và tóm tắt một dòng: [`adr/README.md`](adr/README.md).

## 10. Rủi ro và nợ kỹ thuật

Danh sách đầy đủ kèm lý do chấp nhận và điều kiện xem lại: [mục 6 của `threat-model.md`](threat-model.md#6-rủi-ro-chấp-nhận).

- **Chưa đo trên cloud:** k6 1.000 req/s, chaos trên EKS, diễn tập phục hồi RDS, hạn 50 ms của Redis
  ([`explanation/reliability.md`](explanation/reliability.md#chưa-đo-trên-cloud)); NFR độ trễ chưa có số đo ở tải mục tiêu.
- **Không có mTLS giữa gateway và service gRPC:** token chuyển tiếp đi plaintext trong cluster, NetworkPolicy là lớp chặn duy nhất;
  Istio ambient là phương án tuỳ chọn, chưa dựng (IN-2, IN-3, [mục 4.5](threat-model.md#45-mức-tin-cậy-giữa-các-service)).
- **Độ tươi feed chưa thành SLO:** local quá ít event để burn rate có nghĩa; chỉ có histogram trên dashboard.
- **Kyverno một replica:** nó chết thì webhook từ chối mọi pod `svp` mới tới khi nó lên lại (SC-1, SC-7).
- **Lab local:** backup trên k3d cùng ổ với dữ liệu, không mã hoá lúc nghỉ (BAK-1); RustFS là dự án trẻ, nhiều advisory.
- **Like, lượt xem cho `video_id` không tồn tại** làm `svp_engagement` phình dần: chặn cần bản sao video ở engagement-service (RL-6).
- **Không có cổng tự động "bộ prd = bộ stg đã kiểm"** khi promote (GIT-4); build provenance đạt SLSA Build L2, không L3.

## 11. Câu hỏi mở

- **Vì sao lệnh GET cache khám phá thỉnh thoảng quá hạn 50 ms trên Redis local**, và hạn đó có giữ được trên cloud không: chưa
  kết luận; dấu hiệu và cách đọc ở [`runbooks/explore-cache-redis-timeout.md`](runbooks/explore-cache-redis-timeout.md).
