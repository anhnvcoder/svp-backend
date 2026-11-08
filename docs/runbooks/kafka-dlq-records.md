# KafkaDLQRecords

- Severity: `page`. Rule: `deploy/observability/prometheus/rules/svp-alerts.yaml`, nhãn `service_name`, `group`, `topic`.
- Chuẩn bị biến `PROM`, `AM`, hàm `dc`: [README](README.md#chuẩn-bị-trong-terminal). Lệnh Kafka đi qua `svp-kafka` (Kafka CLI
  của image `apache/kafka`, đăng nhập `svp-admin`, [ADR-0053](../adr/0053-msk-elasticache-valkey.md) §13): compose trong container
  `kafka`, k3d và EKS trong Deployment `svp-ops` của namespace `svp-data`.

## Ý nghĩa và tác động tới người dùng

Trong 10 phút qua consumer group `group` của `service_name` đã chép ít nhất một record của `topic` sang dead-letter topic
`<topic>.dlq` rồi commit record gốc: consumer **bỏ qua** record đó. Hai lý do (header `dlq-reason`):

- `permanent`: handler báo record không bao giờ xử lý được (payload hỏng, sai schema, dữ liệu không hợp lệ);
- `retries-exhausted`: lỗi tạm kéo dài hết lượt thử (phụ thuộc chết lâu). Consumer theo record (video-service, media-worker) hết số
  lần thử của một record; consumer lượt xem của engagement-service (theo lô) thử lại cả lô trong ngân sách 5 phút rồi chép **mọi**
  record của lô sang DLQ ([ADR-0045](../adr/0045-bounded-batch-retry.md)). Projector của feed-service thử lại không giới hạn nên
  không bao giờ có `retries-exhausted`: sự cố dài của nó hiện ở `KafkaConsumerLagHigh`.

Mỗi record trong DLQ là một việc không xảy ra: video không thành `READY`/`FAILED` (`media.transcodes.v1`), video không được
transcode hay không vào feed (`video.lifecycle.v1`), follow không vào feed (`user.follows.v1`), lượt xem không được đếm
(`engagement.views.v1`). Số người dùng bị ảnh hưởng tối đa bằng số record.

Cảnh báo hết 10 phút sau record DLQ cuối cùng; nó không tự nói đã xử lý xong các record đó.

## Kiểm tra nhanh (5 phút)

Compose:

```sh
curl -sG "$AM/api/v2/alerts" --data-urlencode 'filter=alertname="KafkaDLQRecords"' | jq -c '.[] | [.labels.service_name, .labels.group, .labels.topic, .startsAt]'
# lý do, lỗi, topic/partition/offset gốc của từng record (service_name của cảnh báo)
make logs SVC=feed-service | grep 'kafka record sent to dead-letter topic'
# record đã ghi trước đó: các lần thử lỗi tạm
make logs SVC=feed-service | grep 'kafka handler failed, retrying'
# engagement-service: một dòng ERROR mỗi lô hết ngân sách (records, attempts, offsets theo partition, error)
make logs SVC=engagement-service | grep 'kafka batch sent to dead-letter topic'
# số record trong DLQ: offset cuối (high watermark) của partition 0, dạng topic:partition:offset
dc exec -T kafka /opt/svp/bin/svp-kafka get-offsets --topic user.follows.v1.dlq
# số record DLQ trong 1 giờ theo service, group, topic
curl -sG "$PROM/api/v1/query" --data-urlencode 'query=sum by (service_name, group, topic) (increase(svp_kafka_dlq_records_total[1h]))' | jq -c '.data.result[] | [.metric, .value[1]]'
```

k3d (EKS: cùng lệnh với context của cluster EKS, người học chạy):

```sh
kubectl --context k3d-svp -n svp logs -l app.kubernetes.io/name=feed-service --since=1h --tail=5000 | grep 'kafka record sent to dead-letter topic'
kubectl --context k3d-svp -n svp-data exec deploy/svp-ops -c kafka -- /opt/svp/bin/svp-kafka get-offsets --topic user.follows.v1.dlq
```

Dòng log có `trace_id`: mở trace đó trong Grafana Explore → Tempo để thấy lần xử lý lỗi. Dashboard `svp-pipeline` → "DLQ records
(per 10 min)".

## Nguyên nhân thường gặp

1. **Phụ thuộc chết lâu hơn số lần thử** (`retries-exhausted`): Postgres của service, object store `s3` (video-service, media-worker);
   với lượt xem là Postgres `svp_engagement` lỗi quá 5 phút. Dấu hiệu: nhiều record cùng lúc, lỗi kết nối trong `error`.
2. **Một lô độc** (`retries-exhausted`, chỉ consumer lượt xem): handler coi lỗi là tạm nhưng lô đó lỗi mãi (lỗi code, câu lệnh quá
   hạn vì lô quá lớn) trong khi database vẫn sống. Dấu hiệu: `error` giống nhau ở mọi lần thử, các lô sau đếm bình thường.
3. **Bản phát hành mới đọc sai event** (`permanent`): producer và consumer lệch schema, envelope sai
   ([ADR-0006](../adr/0006-contract-ids-and-event-envelope.md)). Dấu hiệu: bắt đầu ngay sau deploy, mọi record của một loại event.
4. **Một record hỏng lẻ** (`permanent`): dữ liệu ngoài dự kiến; một record, một lỗi giải mã hay kiểm dữ liệu.

## Giảm thiểu

- Nguyên nhân 1: khôi phục phụ thuộc; record mới sẽ không vào DLQ nữa.
- Nguyên nhân 2: sửa code hay giảm cỡ lô rồi deploy; lô đã vào DLQ **chưa phát lại được bằng CLI**: mục "Phát lại DLQ lượt xem" chỉ
  lập danh sách để ghi vào postmortem.
- Nguyên nhân 3: dừng deploy, quay về bản trước (compose: checkout bản trước rồi `make up OBS=lgtm`; GitOps: PR revert của
  commit promote, theo ruleset `main`).
- Record đã vào DLQ không tự chạy lại; dữ liệu gốc còn trong topic gốc (giữ 7 ngày, DLQ giữ 14 ngày, `deploy/kafka/kafka-init.sh`).

## Khôi phục và xác nhận

Xử lý lại record đã bỏ qua, **sau khi đã sửa nguyên nhân** và chỉ khi người trực quyết: handler của dự án idempotent (diễn
tập `drill-duplicates`, `drill-duplicates-feed` của bài lab `drills/` của `svp-labs` phát lại event mà không gì đổi), nên có thể đưa offset của group về
offset gốc ghi trong header/log (`dlq-topic`, `dlq-partition`, `dlq-offset`). `consumer-groups --reset-offsets` chỉ chạy khi group
không có member (`--state` báo `Empty`), và phát lại **mọi** record từ offset đó trên partition đó:

```sh
# compose, ví dụ group feed-service, record gốc user.follows.v1 partition 2 offset 1234 (lấy từ log ở trên)
dc stop feed-service
dc exec -T kafka /opt/svp/bin/svp-kafka consumer-groups --describe --group feed-service --state
# --dry-run trước, --execute khi NEW-OFFSET đúng
dc exec -T kafka /opt/svp/bin/svp-kafka consumer-groups --reset-offsets --group feed-service --topic user.follows.v1:2 --to-offset 1234 --dry-run
dc exec -T kafka /opt/svp/bin/svp-kafka consumer-groups --reset-offsets --group feed-service --topic user.follows.v1:2 --to-offset 1234 --execute
dc start feed-service
dc exec -T kafka /opt/svp/bin/svp-kafka consumer-groups --describe --group feed-service
```

Trên k3d cùng bước với `kubectl --context k3d-svp -n svp scale deployment/feed-service --replicas=0`, Kafka CLI qua
`kubectl --context k3d-svp -n svp-data exec deploy/svp-ops -c kafka -- /opt/svp/bin/svp-kafka …`, rồi scale lại số replica cũ (media-worker do
KEDA quản: ghim bằng annotation `autoscaling.keda.sh/paused-replicas` như diễn tập `drill-k8s-keda` của bài lab `drills/` của `svp-labs`, nhớ bỏ ghim). Các lệnh
reset offset trên k3d chưa chạy thử; `--reset-offsets --dry-run` đã thử trên một broker `apache/kafka` 4.1 tạm (2026-11-08).

**Không seek group `engagement-service`** (topic `engagement.views.v1`): handler đếm lượt xem bỏ qua mọi record dưới `next_offset`
đã lưu trong `svp_engagement` (bảng `consumer_offsets`, cùng transaction với bộ đếm), nên seek group về trước không đếm lại gì. Record
`permanent` của nó là payload không giải mã được: chạy lại cũng lỗi, lượt xem đó mất; ghi số record và `video_id` (nếu đọc được) vào
postmortem. Record `retries-exhausted` thì lập danh sách ở mục dưới đây (chưa phát lại được bằng CLI).

### Phát lại DLQ lượt xem

**Chưa phát lại được bằng CLI của dự án:** bước chép về topic gốc (bước 3 dưới đây) chưa có công cụ, nên mục này dừng ở danh sách
record cần phát lại (giữ file, ghi vào postmortem). Phần còn lại tả cách lập danh sách đó và điều kiện để phát lại khi có công cụ.

Ý định: chép record `retries-exhausted` của `engagement.views.v1.dlq` về `engagement.views.v1`. Record phát lại có offset mới, lớn hơn
`next_offset` đã lưu (offset không tiến khi lô lỗi), nên mỗi lượt xem được cộng đúng một lần
([ADR-0045](../adr/0045-bounded-batch-retry.md) §3). Thứ tự không quan trọng: lượt xem là phép cộng.

Chỉ phát lại khi đủ cả bốn điều kiện, thiếu một thì **không** phát lại (thiếu lượt xem còn hơn đếm hai lần), ghi vào postmortem:

- nguyên nhân đã hết: lô mới đếm được, không dòng `kafka batch sent to dead-letter topic` mới;
- record có `dlq-reason=retries-exhausted` (record `permanent` không bao giờ phát lại);
- offset gốc (`dlq-partition`, `dlq-offset`) nằm trong khoảng `offsets` của một dòng log ERROR `kafka batch sent to dead-letter
  topic`. Dòng log chỉ ghi **sau** commit: lô đã chép DLQ mà commit hỏng hay pod chết trước commit thì được giao lại, có thể đã được
  cộng ở lần giao sau, và không có dòng log. Log cũ hơn pod: Grafana Explore → Loki,
  `{service_name="engagement-service"} |= "kafka batch sent to dead-letter topic"`; Loki đã xoá thì không phát lại;
- trong hạn giữ của DLQ (14 ngày), và chưa phát lại lần nào: giữ file danh sách của lần phát lại, không chạy lại cùng danh sách.

Một lô có thể vào DLQ hai lần (chết sau khi chép, trước commit, rồi hết ngân sách lần nữa): bước 2 bỏ trùng theo (`dlq-topic`,
`dlq-partition`, `dlq-offset`), giữ bản đầu.

Compose (ví dụ: dòng log có `offsets="engagement.views.v1/0:1200-1399 engagement.views.v1/2:880-950"`; k3d: thay `dc exec -T kafka`
bằng `kubectl --context k3d-svp -n svp-data exec deploy/svp-ops -c kafka --`, log từ
`kubectl --context k3d-svp -n svp logs -l app.kubernetes.io/name=engagement-service --since=24h --tail=-1 | grep 'kafka batch sent to dead-letter topic'`):

```sh
# 1. khoảng offset gốc từ các dòng log ERROR, mỗi dòng "partition first last"
printf '%s\n' '0 1200 1399' '2 880 950' > views-replay.ranges
# 2. liệt kê record DLQ: offset trong DLQ (1 partition), partition và offset gốc; lọc lý do, khoảng, bỏ trùng. Header in
#    dạng khoá:giá trị cách dấu phẩy; dlq-error có thể chứa dấu phẩy nên mỗi khoá được tìm theo tên
dc exec -T kafka /opt/svp/bin/svp-kafka console-consumer --topic engagement.views.v1.dlq --partition 0 --offset earliest \
    --timeout-ms 10000 --property print.offset=true --property print.headers=true --property print.value=false 2>/dev/null |
  awk -F '\t' 'NR==FNR { split($0, r, " "); p[NR]=r[1]; lo[NR]=r[2]; hi[NR]=r[3]; n=NR; next }
    function h(k) { return match($2, "(^|,)" k ":[^,]*") ? substr($2, RSTART + (RSTART > 1) + length(k) + 1, RLENGTH - (RSTART > 1) - length(k) - 1) : "" }
    h("dlq-reason") == "retries-exhausted" && h("dlq-topic") == "engagement.views.v1" {
      part = h("dlq-partition") + 0; off = h("dlq-offset") + 0; ok = 0
      for (i = 1; i <= n; i++) if (part == p[i] + 0 && off >= lo[i] + 0 && off <= hi[i] + 0) ok = 1
      if (ok && !seen[part " " off]++) print substr($1, 8) "\t" part "\t" off
    }' views-replay.ranges - > views-replay.list
wc -l views-replay.list   # tối đa tổng (last - first + 1) của các khoảng; nhiều hơn là sai, dừng lại
```

Bước 1 và 2 đã thử trên một broker `apache/kafka` 4.1 tạm với record giả (2026-11-08). **Bước 3, chép key và value nguyên byte về topic
gốc, chưa có cách làm:** value là protobuf (thường bắt đầu bằng byte `0x0A`, tức xuống dòng), mà `console-consumer` và
`console-producer` của Kafka CLI đọc, ghi theo dòng văn bản, không có định dạng giữ nguyên byte; chép qua chúng làm hỏng record. Cho tới
khi dự án có công cụ chép byte: **không** phát lại, giữ `views-replay.list` (số record, offset trong DLQ) và ghi vào postmortem; DLQ giữ
record 14 ngày.

Xác nhận: không có dòng `dead-letter` mới, `TOTAL-LAG` về 0 (tổng cột `LAG` của `consumer-groups --describe`), thực thể bị ảnh hưởng đúng trạng thái (video `READY`, follow có
trong feed), cảnh báo hết sau 10 phút.

## Leo thang

- Record `permanent` do code: sửa handler hay producer, thêm test bằng chính payload đó (lấy từ DLQ, bỏ dữ liệu người dùng).
- Không chắc phát lại có an toàn (handler mới, chưa có diễn tập trùng lặp): không seek, ghi các id bị ảnh hưởng vào postmortem.
- Hơn vài record, hay ảnh hưởng tới video của người dùng: mở postmortem.

## Liên kết

- Dashboard: `svp-pipeline` (DLQ records, consumer lag).
- ADR: [ADR-0003](../adr/0003-async-events-outbox.md) (DLQ `<topic>.dlq`), [ADR-0011](../adr/0011-observability-stage3.md)
  §8 (rule), §11 (hạn ghi DLQ).
- Diễn tập tái hiện: chưa có diễn tập đưa record vào DLQ. Phát lại an toàn: `drill-duplicates`,
  `drill-duplicates-feed` của bài lab `drills/` của `svp-labs`.
