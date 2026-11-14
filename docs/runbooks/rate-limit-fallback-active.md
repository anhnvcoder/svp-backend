# RateLimitFallbackActive

- Severity: `page`. Rule: `deploy/observability/prometheus/rules/svp-alerts.yaml`.
- Cùng file có `RateLimitFallbackElevated` (`ticket`, không page): mục "Vượt hạn lẻ tẻ" bên dưới.
- Chuẩn bị biến `PROM`, `AM`, hàm `dc`: [README](README.md#chuẩn-bị-trong-terminal).

## Ý nghĩa và tác động tới người dùng

Gateway đếm rate limit bằng **bộ đếm dự phòng trong bộ nhớ** vì Redis lỗi hay quá hạn 50 ms. Một lần quá hạn lẻ tẻ không phải
sự cố, nên cảnh báo dựa vào **tỷ lệ** quyết định dự phòng của **từng instance gateway** (nhãn `service_instance_id`), cháy khi
một trong hai nhánh đúng liên tục 1 phút (`for: 1m`):

- **Nhánh tăng:** trong 2 phút, `increase(svp_ratelimit_decisions_total{store="fallback"})` ≥ 0,5 lần `increase` của mọi store
  **và** ≥ 3 quyết định dự phòng. Redis mất hẳn thì mọi quyết định của instance là dự phòng (tỷ lệ 1).
- **Nhánh series mới sinh:** series không có mẫu cách đây 2 phút (gateway vừa khởi động, hay burst trước lần xuất metric đầu nên
  series sinh ra đã > 0 rồi đứng yên, `increase` bằng 0), cùng hai ngưỡng áp lên giá trị của chúng. Tắt khi series đủ 2 phút lịch sử.

Không cháy khi: vài lần quá hạn mỗi phút giữa hàng trăm quyết định (tỷ lệ vài phần nghìn); lưu lượng quá thấp (dưới 3 quyết định
dự phòng trong 2 phút); instance không có quyết định nào (0/0 không thoả điều kiện nào, chấp nhận: không có gì để cảnh báo). Tính
theo instance nên một pod mất Redis vẫn cháy dù pod kia khoẻ. Counter reset khi gateway khởi động lại không gây cháy giả hay bỏ
sót: `increase` coi reset là bắt đầu lại từ 0, còn instance mới sinh là series mới.

Redis của gateway là Valkey db 10, user `svp-gateway`, TLS: compose `valkey:6379`, k3d `valkey.svp-data.svc.cluster.local:6379`, EKS
ElastiCache for Valkey. Lệnh vào Valkey đi qua `svp-valkey` (`valkey-cli --tls`, đăng nhập `svp-ops`,
[ADR-0053](../adr/0053-msk-elasticache-valkey.md) §13): compose trong container `valkey`, k3d và EKS trong Deployment `svp-ops`.

Theo bảng của [ADR-0010](../adr/0010-redis-ratelimit-cache-resilience-stage2c.md) §2 (và các lớp thêm sau, khai cùng chỗ ở
`services/gateway/internal/ratelimit/ratelimit.go`):

- Lớp **đóng mềm** (`register`, `login-ip`, `login-email`, `login-account`, `upload`, `refresh`, `public`) đếm trong bộ
  nhớ của từng instance
  với ngưỡng bằng nửa: người dùng có thể nhận 429 `RATE_LIMITED` sớm hơn bình thường khi đăng ký, đăng nhập, làm mới phiên,
  tạo video, mở trang chia sẻ công khai.
- Lớp **mở** (`write`, `read`) cho qua không giới hạn; `view-once` chuyển tiếp mọi lượt xem, nên một lượt xem lặp trong 60 s
  có thể được đếm thêm (RL-3 tạm mất).
- Với nhiều instance gateway (k3d: 2 tới 4 pod) mỗi instance đếm riêng: giới hạn thật là ngưỡng × số instance.

Không có lỗi 5xx do việc này. Cùng lúc, cache khám phá của feed-service (Redis db 14) có thể cũng lỗi, khi đó mọi request
khám phá đọc Postgres: xem thêm [explore-cache-redis-timeout.md](explore-cache-redis-timeout.md).

## Kiểm tra nhanh (5 phút)

Compose:

```sh
# 1. Valkey trả lời không, độ trễ (Ctrl-C sau ~10 s; --latency chỉ gửi PING)
make ps | grep valkey
dc exec -T valkey /opt/svp/bin/svp-valkey -n 10 PING
dc exec valkey /opt/svp/bin/svp-valkey -n 10 --latency
# 2. Gateway nói gì: lỗi kết nối, quá hạn, hay tên miền .invalid (gateway còn cấu hình của diễn tập)
make logs SVC=gateway | grep 'rate limit store unavailable'
# 3. Quyết định theo store trong 5 phút (redis so với fallback)
curl -sG "$PROM/api/v1/query" --data-urlencode 'query=sum by (store) (increase(svp_ratelimit_decisions_total{service_name="gateway"}[5m]))' | jq -c '.data.result[] | [.metric.store, .value[1]]'
# 3b. Tỷ lệ dự phòng trong 2 phút theo instance, đúng số mà cảnh báo so với 0,5 (≥ 0,5 và ≥ 3 quyết định dự phòng thì cháy)
curl -sG "$PROM/api/v1/query" --data-urlencode 'query=sum by (service_instance_id) (increase(svp_ratelimit_decisions_total{service_name="gateway",store="fallback"}[2m])) / sum by (service_instance_id) (increase(svp_ratelimit_decisions_total{service_name="gateway"}[2m]))' | jq -c '.data.result[] | [.metric.service_instance_id, .value[1]]'
# 4. Lệnh Redis của gateway quá hạn (error_type="context_timeout") hay lỗi khác
curl -sG "$PROM/api/v1/query" --data-urlencode 'query=sum by (error_type) (increase(db_client_connections_use_time_milliseconds_count{service_name="gateway",db_system="redis"}[5m]))' | jq -c '.data.result[] | [.metric.error_type, .value[1]]'
```

k3d (EKS: cùng lệnh với context của cluster EKS, người học chạy; không có pod `valkey`, đọc trạng thái ElastiCache ở console):

```sh
kubectl --context k3d-svp -n svp-data get pods -l app.kubernetes.io/name=valkey -o wide
kubectl --context k3d-svp -n svp-data exec deploy/svp-ops -c valkey -- /opt/svp/bin/svp-valkey -n 10 PING
kubectl --context k3d-svp -n svp logs -l app.kubernetes.io/name=gateway --since=15m --tail=2000 | grep 'rate limit store unavailable'
curl -sG "$PROM/api/v1/query" --data-urlencode 'query=sum by (store) (increase(svp_ratelimit_decisions_total{service_name="gateway"}[5m]))' | jq -c '.data.result[] | [.metric.store, .value[1]]'
```

Dashboard `svp-pipeline` → "Rate limit decisions by store (RL-2)"; `svp-use` → "Redis pool (redisotel)" (pool miss, chờ,
timeout, thời gian dùng kết nối p95).

## Redis mất hay chỉ vượt hạn lẻ tẻ

Đọc bước 3b và bước 4: **Redis mất** thì tỷ lệ của instance gần 1, `PING` lỗi (hay tên miền `.invalid`), log bước 2 lặp liên tục.
**Vượt hạn lẻ tẻ** thì tỷ lệ chỉ vài phần nghìn (game day: khoảng 3 trên 1 200 quyết định mỗi phút), `PING` vẫn
`PONG`, bước 4 có vài `context_timeout`; loại này không page.

## Vượt hạn lẻ tẻ: `RateLimitFallbackElevated` (ticket)

Cháy khi trong 30 phút một instance có ≥ 1% quyết định trên bộ đếm dự phòng **và** ≥ 30 quyết định dự phòng; Redis mất lâu cũng
làm nó cháy, sau cảnh báo page. Không cần làm gì gấp: ghi số `context_timeout` và p99 lệnh Redis (bước 4, dashboard `svp-use`)
vào đánh giá hạn 50 ms của [ADR-0020](../adr/0020-reliability-stage6.md) §4. Nguyên nhân 3 bên dưới là thủ phạm thường gặp.

## Nguyên nhân thường gặp

1. **Diễn tập để lại cấu hình** (compose): `make drill-obs-threats` (và `drill-rate-limit` của bài lab `drills/` của `svp-labs`) dựng lại gateway với
   `SVP_GATEWAY_REDIS_URL` trỏ tên miền `.invalid` rồi trả về khi kết thúc; script bị ngắt giữa chừng thì gateway vẫn trỏ
   `.invalid`. Dấu hiệu: log bước 2 có `.invalid`, `svp-valkey PING` vẫn `PONG`.
2. **Container `valkey` dừng hay chưa healthy** (compose): `make ps` không `healthy`, `PING` lỗi.
3. **Valkey chậm hơn 50 ms**: máy bão hoà CPU (pin, Low Power Mode), Docker VM chậm. Dấu hiệu: `PING` được nhưng `--latency` có max
   cao, bước 4 có `context_timeout`.
4. **Valkey pod restart, chưa Ready, hay NetworkPolicy chặn** (k3d).
5. **Gateway bị Valkey từ chối đăng nhập** (mật khẩu `svp-gateway` trong `REDIS_URL` khác aclfile sau khi đổi mật khẩu, hay cert không
   tin được): log bước 2 có `WRONGPASS`, `NOPERM` hay lỗi TLS, `PING` của `svp-ops` vẫn `PONG`.

## Giảm thiểu

- Nguyên nhân 1: `make up OBS=lgtm` dựng lại gateway với `REDIS_URL` mặc định (biến diễn tập không nằm trong `.env`). Không
  đặt `SVP_GATEWAY_REDIS_URL` trong `.env`.
- Nguyên nhân 2: `make up OBS=lgtm` (dựng lại `tls-init`, `valkey` khi chúng dừng); **không** `FLUSHDB`/`FLUSHALL`. Trong lúc chờ,
  stack vẫn chạy với giới hạn đóng mềm: không cần làm gì thêm cho người dùng.
- Nguyên nhân 3: giảm tải máy (cắm sạc, tắt Low Power Mode, dừng việc nặng khác); không đổi hạn 50 ms.
- Nguyên nhân 4: `kubectl --context k3d-svp -n svp-data rollout restart deployment/valkey`. Valkey không lưu xuống đĩa
  (`--save ""`, `--appendonly no`): restart xoá mọi khoá rate limit, cache khám phá và **mọi phiên đăng nhập của web (db 9)**,
  người dùng web phải đăng nhập lại (compose: `dc restart valkey`, cùng hệ quả).
- Nguyên nhân 5: đổi mật khẩu theo đúng thứ tự của target (compose: `make up` ghi lại aclfile từ `.env` và tạo lại `valkey`, vì mật khẩu
  Valkey đổi thì cấu hình của container `valkey` đổi; k3d `make k8s-secrets`), rồi gateway restart với `REDIS_URL` mới.

## Khôi phục và xác nhận

```sh
# fallback không còn tăng, redis tăng
curl -sG "$PROM/api/v1/query" --data-urlencode 'query=sum by (store) (increase(svp_ratelimit_decisions_total{service_name="gateway"}[1m]))' | jq -c '.data.result[] | [.metric.store, .value[1]]'
curl -sG "$AM/api/v2/alerts" --data-urlencode 'filter=alertname="RateLimitFallbackActive"' | jq -c '.[] | [.status.state, .startsAt]'
make smoke        # compose (LOCAL LAB ONLY: xoá khoá svp:gw:rl:register:* ở db 10)
make k8s-smoke    # k3d
```

Cảnh báo hết khi cửa sổ 2 phút không còn đủ tỷ lệ và số quyết định dự phòng (khoảng 2 phút sau khi Redis hồi). Bộ đếm trong bộ nhớ không đồng bộ ngược về Redis: sau khi
hồi, người vừa bị giới hạn ở fallback được tính lại từ trạng thái Redis.

## Leo thang

- Valkey không lên được sau restart (log `make logs SVC=valkey`, `make logs SVC=tls-init`: cert, aclfile): stack chạy tiếp ở chế độ
  đóng mềm, ghi lại thời gian cho postmortem.
- Fallback kéo dài > 30 phút trên môi trường có người dùng thật: lớp mở (`write`, `read`) không còn giới hạn, đây là rủi ro
  lạm dụng (RL-2 của [threat model](../threat-model.md)); ở lab không có người dùng ngoài nên chỉ ghi nhận.
- Lệnh Redis quá hạn lặp lại khi máy không bận: ghi số `context_timeout` và p99 vào đánh giá hạn 50 ms của
  [ADR-0020](../adr/0020-reliability-stage6.md) §4.

## Liên kết

- Dashboard: `svp-pipeline` (Rate limit decisions by store), `svp-use` (Redis pool).
- ADR: [ADR-0010](../adr/0010-redis-ratelimit-cache-resilience-stage2c.md) §1–2, [ADR-0011](../adr/0011-observability-stage3.md)
  §8, [ADR-0020](../adr/0020-reliability-stage6.md) §4.
- Diễn tập tái hiện: `drill-rate-limit` của bài lab `drills/` của `svp-labs` (Redis không tới được: login vẫn bị giới hạn bằng bộ đếm dự phòng, feed, like,
  lượt xem vẫn chạy); `make drill-obs-threats` dòng RL-2 (metric `store="fallback"` > 0 và cảnh báo này trong 4 phút từ login đầu, cần
  `make up OBS=lgtm`).
