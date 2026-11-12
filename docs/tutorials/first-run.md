# Chạy hệ thống lần đầu và đọc một trace

Loại tài liệu (Diátaxis): **tutorial**, làm theo từng bước từ đầu tới cuối; lệnh tra cứu ở [`docs/reference/`](../reference/).

Khi xong, bạn đã dựng cả nền tảng trên máy mình, chạy luồng upload video tới phát HLS qua gateway, rồi mở Grafana để xem đường đi của
một request qua gateway, các service, Postgres, Kafka và media-worker.

## Trước khi bắt đầu

Cần sẵn trên máy, version nằm ở nơi ghim chứ không chép lại đây:

- Docker, Go, `curl`, `jq`, `openssl`, `ffmpeg`; Postgres, Kafka và Valkey là container của stack, không cần cài: mục "Cài đặt" của
  [`README.md`](../../README.md); Go theo `go.mod`, image theo `Makefile`.
- Bản clone [`svp-gitops`](https://github.com/anhnvcoder/svp-gitops) cạnh repo này, trong thư mục `../gitops` (cũng ở
  mục đó của `README.md`): `make up` đọc digest của web client từ đó.
- Máy 16 GB RAM: không chạy cluster k3d cùng lúc (`make up` từ chối khi cluster chạy).

Lần đầu trên máy, `make up` build image của các service nên lâu hơn nhiều so với những lần sau (Docker còn cache).

## 1. Clone repo

```sh
git clone https://github.com/anhnvcoder/svp-backend.git
cd svp-backend
```

Từ đây mọi lệnh chạy ở gốc repo. Bạn sẽ thấy `Makefile`, `README.md` và các thư mục `services/`, `deploy/`, `docs/`.

## 2. Tạo file cấu hình

```sh
make env
```

Bạn sẽ thấy một dòng `wrote .env (mode 600)`. Lệnh sinh secret ngẫu nhiên vào `.env` (gồm mật khẩu của các role Postgres, user Kafka và Valkey)
và không bao giờ in giá trị của chúng. Nó cũng sinh một lần, vào `.local/ca/`, CA local và chứng chỉ server mà Postgres, Kafka (SASL_SSL, cổng 9096)
và Valkey (TLS, cổng 6379) dùng, để các service nói chuyện với chúng bằng TLS và tài khoản riêng, y như với RDS, MSK và ElastiCache trên cloud.
Với Postgres, service còn kiểm tên trong cert server (`sslmode=verify-full`).

## 3. Dựng stack cùng Grafana

```sh
make up OBS=lgtm
```

`OBS=lgtm` thêm bộ quan sát (Collector, Grafana cùng Tempo, Loki, Prometheus, Alertmanager, GlitchTip). Lệnh dựng container `postgres`
và tạo role, database trong nó, ghi file ACL của Valkey từ `.env`, build image, rồi dựng các container khác và chờ chúng khoẻ.

Bạn sẽ thấy từng dòng `bootstrap: database svp_… and roles … ok`, rồi danh sách container. Lệnh đã xong khi nó trả về dấu nhắc
và mọi container dài hạn (`gateway`, `user-service`, `video-service`, `media-worker`, `engagement-service`, `feed-service`,
`web`, `lgtm`, `otelcol`, `glitchtip`…) ở trạng thái `Healthy`, các job một lần (`…-migrate-…`, `s3-init`,
`tls-init`, `kafka-init`, `glitchtip-init`) ở trạng thái `Exited`; `postgres`, `kafka` và `valkey` ở `Healthy`.

Kiểm lại bằng:

```sh
make ps
```

Bạn sẽ thấy các container dài hạn ở cột trạng thái `Up … (healthy)` và các job một lần ở `Exited (0)`.

## 4. Chạy luồng đầu-cuối

```sh
make smoke
```

Script đăng ký hai user, tạo video, upload một video thử lên object store, chờ media-worker chuyển nó sang `READY`, tải HLS, rồi
thử feed, like, lượt xem và follow, tất cả qua gateway ở `127.0.0.1:8080`.

Bạn sẽ thấy mỗi bước một dòng bắt đầu bằng `ok`, trong đó có dòng `video READY after … s, playlist_url and thumbnail_url set`,
và dòng cuối là `smoke: all steps passed`. Một dòng không phải `ok` thì smoke dừng và exit khác 0.

## 5. Mở Grafana và tìm trace

Mở `http://localhost:3000` trên trình duyệt. Grafana ở đây không đòi đăng nhập vì chỉ nghe trên loopback.

1. Ở menu bên trái chọn **Explore**.
2. Ở ô chọn nguồn dữ liệu phía trên, chọn **Tempo**.
3. Chọn chế độ truy vấn **TraceQL** và dán truy vấn dưới đây vào ô query:

   ```text
   { resource.service.name = "gateway" && name = "POST /videos/{video_id}/complete" }
   ```

4. Bấm **Run query**.

Đây là request mà smoke gửi khi người dùng báo upload xong. Bạn sẽ thấy một bảng kết quả (Tempo cần vài chục giây để lập chỉ mục trace; chưa thấy gì thì chờ rồi bấm lại): mỗi dòng là một trace có cột
Trace ID, tên gốc `POST /videos/{video_id}/complete` và thời lượng, thường vài giây vì nó gồm cả lúc transcode. Chọn dòng có thời điểm
bắt đầu mới nhất; Grafana mở trace ở khung bên cạnh.

## 6. Đọc trace

Trace hiện thành cây các span, thụt vào theo cha-con, mỗi span là một thanh trên trục thời gian. Hãy đi từ trên xuống, ứng với
bảng dưới. Số mili giây trên máy bạn sẽ khác, nhưng hình dạng giống.

| Span (service) | Cho biết gì |
| --- | --- |
| `POST /videos/{video_id}/complete` (gateway) | Span gốc: request HTTP của client tới gateway, từ lúc nhận tới lúc trả `202`. Ngắn, vì gateway không chờ transcode. |
| `evalsha` (gateway) | Gateway hỏi Valkey xem request có vượt rate limit không; thuộc tính `db.system=redis`. |
| `svp.video.v1.VideoService/CompleteUpload` (gateway, rồi video-service) | Cùng một lời gọi gRPC nhìn từ hai phía: span client của gateway chứa span server của video-service. |
| `SELECT`, `S3.HeadObject` (video-service) | Đọc dòng video trong Postgres `svp_video`, rồi hỏi object store xem file đã tải lên thật chưa. Thuộc tính `db.query.text` cho thấy câu SQL. |
| `BEGIN`, `UPDATE`, `INSERT`, `COMMIT` (video-service) | Một transaction: đổi video sang `PROCESSING` và ghi event vào bảng `outbox` cùng lúc. Chưa có gì gửi lên Kafka: event nằm trong cùng transaction với dữ liệu (outbox, [ADR-0003](../adr/0003-async-events-outbox.md)). |
| `send video.lifecycle.v1` (video-service, `SPAN_KIND_PRODUCER`) | Bộ gửi outbox đẩy event lên topic Kafka `video.lifecycle.v1`, một lúc sau `COMMIT`. |
| `process video.lifecycle.v1` (feed-service, media-worker, `SPAN_KIND_CONSUMER`) | Hai consumer group đọc cùng event. Feed-service xong ngay; media-worker bắt đầu việc nặng. Trace nối được qua Kafka vì ID trace đi cùng message. |
| `check output`, `S3.ListObjectsV2` (media-worker) | Media-worker xem đã có output cho video này chưa, để xử lý lại cùng event thì không làm hai lần. |
| `download source`, `S3.GetObject` (media-worker) | Tải file gốc từ bucket `uploads`. |
| `transcode` với `ffprobe` và hai `ffmpeg` (media-worker) | Phần dài nhất của cả trace: `ffprobe` đọc thông tin video, `ffmpeg` đầu cắt ra HLS nhiều độ phân giải, `ffmpeg` sau tạo thumbnail. |
| `upload output`, các `S3.PutObject` (media-worker) | Ghi master playlist, playlist biến thể, segment và thumbnail vào bucket `media`. |
| `send media.transcodes.v1` (media-worker) | Báo kết quả transcode lên topic Kafka `media.transcodes.v1`. |
| `process media.transcodes.v1` (video-service) rồi `UPDATE`, `INSERT`, `COMMIT` | Video-service nhận kết quả, đổi video sang `READY` và lại ghi một event vào `outbox` trong cùng transaction. |
| `send video.lifecycle.v1`, rồi `process video.lifecycle.v1` (feed-service) và các `INSERT` vào `svp_feed` | Event `READY` quay lại topic; feed-service ghi video vào kho của nó và chép vào timeline của người đang follow tác giả (fan-out on write). |

Hãy thử vài việc để chắc bạn đọc được trace:

- Bấm vào span `UPDATE` đầu tiên của video-service và đọc `db.query.text`: câu SQL có `status = 'PROCESSING'`.
- Tìm span `transcode` và so thanh của nó với thanh gốc: gateway đã trả lời từ lâu trước khi nó xong, vì phần việc đó chạy bất đồng bộ
  qua Kafka.
- Đếm service trong trace: gateway, video-service, media-worker, feed-service. Đó là bốn trong sáu service Go đã tham gia
  một request duy nhất.

## 7. Gỡ stack

```sh
make down
```

Bạn sẽ thấy các container và network bị gỡ, lệnh exit 0. `make down` giữ volume nên dữ liệu còn nguyên cho lần `make up`
sau; muốn làm lại từ đầu thì dùng `make clean-data` ([`compose.md`](../reference/compose.md)).

## Đọc gì tiếp

- [`docs/reference/compose.md`](../reference/compose.md): các biến thể của `make up` (`OBS`, `IMAGES`, `WEB_FROM`) và mọi diễn tập chạy trên stack này.
- [`docs/architecture.md`](../architecture.md): vì sao các service chia như vậy và luồng upload, feed, like.
- [`docs/adr/`](../adr/): quyết định như outbox, event envelope.
