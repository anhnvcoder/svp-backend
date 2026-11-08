# Cache khám phá: Valkey quá hạn 50 ms, `measure-explore-cache` chập chờn

- Không có cảnh báo riêng. Dấu hiệu: bài đo `measure-explore-cache` (bài lab `drills/` của `svp-labs`) đếm thừa lần đọc Postgres hay FAIL, log feed-service có WARN
  `read explore cache`, `FeedLatencyBudgetBurn` chỉ ở `/feed/explore`.
- Chuẩn bị biến `PROM`, hàm `dc`: [README](README.md#chuẩn-bị-trong-terminal). Lệnh vào Valkey đi qua `svp-valkey` (`valkey-cli --tls`,
  đăng nhập `svp-ops`, [ADR-0053](../adr/0053-msk-elasticache-valkey.md) §13): compose trong container `valkey`, k3d và EKS trong
  Deployment `svp-ops` của namespace `svp-data`.

## Ý nghĩa và tác động tới người dùng

feed-service cache trang đầu của feed khám phá ở Valkey db 14 (user `svp-feed-service`, khoá `svp:feed:explore:*`, TLS; TTL 5 s,
singleflight cho mỗi khoá). Mỗi lệnh Redis có hạn
**50 ms**: quá hạn hay lỗi thì đọc Postgres, không báo lỗi cho client ([ADR-0010](../adr/0010-redis-ratelimit-cache-resilience-stage2c.md) §3).
Hạn ngắn là có chủ đích: đường Redis phải thất bại nhanh để giữ p99 feed.

Người dùng: không thấy lỗi; request khám phá đọc Postgres nên chậm hơn một chút, Postgres nhận thêm truy vấn.

Sự cố đã gặp: ở trạng thái stack `core` có SDK telemetry bật mà không có Collector, 2 trong 7 lượt `measure-explore-cache` FAIL
vì một lần GET cache quá hạn 50 ms (WARN `read explore cache ... i/o timeout`), feed-service đọc Postgres theo đường dự phòng nên
đếm 2 lần đọc thay vì 1; hai trạng thái khác 0 trong 19 lượt. Nguyên nhân chưa kết luận. Bài đo nay đếm riêng lần đọc do cache
quá hạn: mỗi dòng `explore page loaded from database` có `cache=` (`miss`,
`timeout`, `error`) và `cache_write=`; đạt khi mọi lần đọc trừ một là do cache quá hạn.

## Kiểm tra nhanh (5 phút)

Compose:

```sh
# lý do mỗi lần đọc Postgres
make logs SVC=feed-service | grep 'explore page loaded from database'
make logs SVC=feed-service | grep 'read explore cache'
# Valkey: độ trễ (chỉ PING, Ctrl-C sau ~10 s)
dc exec valkey /opt/svp/bin/svp-valkey -n 14 --latency
# p99 lệnh Redis theo service (ms) và số lệnh quá hạn trong 15 phút
curl -sG "$PROM/api/v1/query" --data-urlencode 'query=histogram_quantile(0.99, sum by (le, service_name) (rate(db_client_connections_use_time_milliseconds_bucket{db_system="redis",type="command"}[5m])))' | jq -c '.data.result[] | [.metric.service_name, .value[1]]'
curl -sG "$PROM/api/v1/query" --data-urlencode 'query=sum by (service_name) (increase(db_client_connections_use_time_milliseconds_count{db_system="redis",error_type="context_timeout"}[15m]))' | jq -c '.data.result[] | [.metric.service_name, .value[1]]'
# máy đang bận không
env -u DOCKER_DEFAULT_PLATFORM docker stats --no-stream
```

k3d (Valkey trong cluster; EKS: cùng lệnh với context của cluster EKS, người học chạy, không có `top` của pod Valkey):

```sh
kubectl --context k3d-svp -n svp logs -l app.kubernetes.io/name=feed-service --since=15m --tail=3000 | grep -E 'explore page loaded from database|read explore cache'
kubectl --context k3d-svp -n svp-data exec -it deploy/svp-ops -c valkey -- /opt/svp/bin/svp-valkey -n 14 --latency
kubectl --context k3d-svp top nodes
```

Dashboard `svp-use` → "Redis pool (redisotel)": "Connection use time p95", "Pool misses, waits and timeouts".

## Nguyên nhân thường gặp

1. **Máy hay Docker VM bận**: feed-service và Valkey cùng chạy trong Docker VM; một khựng ngắn của VM là đủ vượt 50 ms. Hay gặp ở
   lượt đầu của buổi đo, khi máy chạy pin hay Low Power Mode.
2. **Bắt tay TLS của kết nối mới** (chưa gặp ở lab): pool phải mở kết nối mới (sau restart Valkey, hay pool cạn lúc burst) thì lệnh
   đầu chịu thêm bắt tay TLS và đăng nhập ACL; dấu hiệu: "Pool misses" tăng cùng lúc với `cache=timeout`.
3. **Telemetry không có Collector** (stack `core` không `OBS`): exporter của mỗi service phân giải lại DNS `otelcol` và chờ hết
   hạn 5 s mỗi kỳ; trùng thời điểm với lỗi ở trên nhưng chưa chứng minh là nguyên nhân.
4. **Thật sự có stampede** (lỗi code): lần đọc thừa có `cache=miss` mà không có `cache_write=timeout` ngay trước; bài đo FAIL
   đúng.

## Giảm thiểu

- Không có tác động tới người dùng cần giảm thiểu ngay.
- Đo lại khi máy yên: cắm sạc, tắt Low Power Mode, đóng bớt app; chạy bài đo trên `make up OBS=lgtm` hay `OBS=off`, không trên
  `core` có telemetry mà không Collector.
- **Không** nới hạn 50 ms tại chỗ, **không** `FLUSHDB` db 14. Bài đo tự xoá khoá `svp:feed:explore:*` ở db 14 trước khi đo.

## Khôi phục và xác nhận

Chạy lại bài đo `measure-explore-cache N=100` của bài lab `drills/` của `svp-labs` (compose, ở commit ghim theo README của bài; in tổng lần đọc, số
do timeout/miss/error, p50/p95 hai sóng; LOCAL LAB ONLY).

Đạt: tổng ≥ 1 và tổng − `timeout` − số dòng sau SET quá hạn ≤ 1. Số tham chiếu (compose `core`): sóng 1 p50 181,3 /
p95 203,0 ms, 1 lần đọc; sóng 2 p50 97,1 / p95 118,6 ms.

## Leo thang

- Lần đọc thừa không do Valkey quá hạn (nguyên nhân 4): lỗi singleflight hay TTL; sửa code, thêm test.
- Lệnh Redis quá hạn khi máy yên, hay p99 lệnh Redis ≥ 25 ms dưới tải k6: theo quy tắc của
  [ADR-0020](../adr/0020-reliability-stage6.md) §4 ghi số và quyết lại hạn 50 ms trên ElastiCache; không đổi code khi chưa có số đo đó.

## Liên kết

- Dashboard: `svp-use` (Redis pool), `svp-red` (p99 `/feed/explore`).
- ADR: [ADR-0010](../adr/0010-redis-ratelimit-cache-resilience-stage2c.md) §1 (timeout Redis), §3 (cache khám phá);
  [ADR-0020](../adr/0020-reliability-stage6.md) §4 (đo p99 Redis dưới k6).
- Diễn tập tái hiện: `measure-explore-cache N=100` của bài lab `drills/` của `svp-labs`; dưới tải `make load-local` (ADR-0020 §4).
