# Phụ lục ADR-0008: Luồng upload bất đồng bộ: franz-go, aws-sdk-go-v2, outbox có khoá relay, media-worker trên alpine + ffmpeg

Phụ lục của [ADR-0008](../0008-async-upload-pipeline-stage2a.md): phần chuyển ra khỏi ADR, giữ nguyên văn và xếp theo §: phân tích phương án chi tiết,
bảng và khối cấu hình, số đo, lệnh đã chạy. Đây là lịch sử, nên giữ ngày và nhãn tiến độ của lúc ghi.

<!-- markdownlint-disable MD052 -->

## Tiêu đề và trạng thái ghi lúc chốt

Tiêu đề gốc: 0008. Luồng upload bất đồng bộ của giai đoạn 2 phần A: franz-go, aws-sdk-go-v2, outbox có khoá relay, media-worker trên alpine + ffmpeg

- Trạng thái: Chấp nhận; §9 (đúng một replica media-worker) chỉnh bởi [0014](../0014-kubernetes-local-stage4.md) cho k8s; §6 (MinIO
  image Chainguard, `minio-init` bằng `mc`, console), tên `minio` và biến `SVP_MINIO_ROOT_PASSWORD` ở §11, cổng console ở §12
  bị thay một phần bởi [0022](../0022-local-object-store-minio-replacement.md) (RustFS, service `s3`, CORS theo bucket; user, policy và bucket policy của §6 giữ nguyên); §6 (policy của `svp-media-worker` thêm
  `GetObject` trên `media/media/*` và `ListBucket` theo tiền tố `media/*`), §8 (media-worker idempotent bằng master tạo có điều kiện
  thay cho ghi đè đường dẫn cố định; `drill-duplicates` kiểm không object nào bị ghi) và §10 (đường dẫn
  `media/<id>/<version>/<attempt>/`) chỉnh bởi [0029](../0029-immutable-media-versions.md)
- Ngày: 2026-10-11

## Kiểm chứng (đã kiểm ngày 2026-10-11)

| Kiểm gì | Lệnh | Kết quả |
| --- | --- | --- |
| Version module | `go list -m -json <module>@latest` trong thư mục tạm ngoài repo (đã xoá) | Bảng ở mục 1 và 2; mọi module khai báo `go` ≤ 1.26.0, build được bằng Go 1.27.2 |
| `PresignPostObject` | Đọc `presign_post.go` của `service/s3` v1.114.3 trong module cache; chạy thử một chương trình ký | Mục 2 |
| Redpanda | `env -u DOCKER_DEFAULT_PLATFORM docker pull redpandadata/redpanda:v26.2.4`, `docker run --rm --entrypoint rpk ... version` | arm64, `rpk` v26.2.4, build 2026-10-06 |
| alpine + ffmpeg | `docker run --rm alpine:3.24.2 sh -c 'apk add ffmpeg; ffmpeg -h full; ffmpeg -encoders'` | arm64; ffmpeg 8.1.2 (gói `ffmpeg` 8.1.2-r0); có `-format_whitelist`, `-codec_whitelist`, `-protocol_whitelist`; có encoder `libx264`, `aac` |
| MinIO chính thức | `docker manifest inspect minio/minio:latest`, `minio/mc:latest`, `quay.io/minio/minio:<tag>` | Docker Hub: `denied`; Quay: không có manifest hoặc đòi đăng nhập với mọi tag đã thử (mục 6) |
| MinIO thay thế | `docker pull cgr.dev/chainguard/minio@sha256:7df55d...`, `docker run --rm --network none ... --version` | arm64, MinIO `RELEASE.2026-09-22T19-25-18Z`, go1.27.2, image tạo 2026-10-10; có `/usr/bin/mc` và `/bin/sh`; chạy uid 65532 |
| Cổng | `lsof -nP -iTCP -sTCP:LISTEN` | Không tiến trình nào nghe ở 9000, 9001, 19092 |

## 1. Thư viện Kafka

### Các lựa chọn về thư viện Kafka

#### A. `github.com/twmb/franz-go`

- Được: thuần Go, build `CGO_ENABLED=0` và chạy trên distroless như service hiện có; producer idempotent và `acks=all` là
  mặc định; consumer group với commit tay (`kgo.DisableAutoCommit`, `CommitRecords`); heartbeat chạy nền nên handler chạy lâu
  không làm consumer bị loại khỏi group; phát triển đều, tài liệu Redpanda dùng nó cho Go. Có `kfake`, Kafka giả trong bộ nhớ
  (module riêng), để test consumer, producer và relay chạy trong `make check` mà không cần Docker.
- Mất: API cấp thấp hơn các thư viện "một hàm `ReadMessage`": vòng poll, commit, xử lý rebalance phải tự viết (gói
  `internal/kafkax`, mục 8). `kfake` không gắn tag, phải ghim pseudo-version.

#### B. `github.com/confluentinc/confluent-kafka-go`

- Được: bọc librdkafka, thư viện client Kafka trưởng thành nhất.
- Mất: cần cgo và librdkafka; phá image static distroless, build chéo kiến trúc ở CI phức tạp hơn.

#### C. `github.com/segmentio/kafka-go`

- Được: API đơn giản, thuần Go.
- Mất: consumer group hạn chế (khó kiểm soát commit và rebalance theo partition), phát triển chậm trong vài năm gần đây.

`IBM/sarama` cũng thuần Go nhưng API nặng và cấu hình mặc định dễ sai (producer không idempotent mặc định); không xét thêm.

### Quyết định về thư viện Kafka

Chọn **A**.

| Module | Version | `go` trong `go.mod` | Dùng ở |
| --- | --- | --- | --- |
| `github.com/twmb/franz-go` | `v1.22.1` | 1.26.0 | Producer (relay outbox, media-worker, DLQ), consumer group |
| `github.com/twmb/franz-go/pkg/kfake` | `v0.0.0-20261007040850-d3792b34935a` | 1.26.0 | Chỉ test. Không có tag nên version là pseudo-version; kéo `franz-go/pkg/kadm` v1.18.0 làm dependency gián tiếp |

## 2. Thư viện object storage

### Các lựa chọn về thư viện object storage

#### A. `github.com/aws/aws-sdk-go-v2/service/s3`

- Được: SDK chính chủ của S3; giai đoạn 7 dùng lại nguyên code, chỉ đổi cách lấy credential (credential chain, Pod
  Identity) và gọi thêm MediaConvert cùng SDK; GCS ở giai đoạn 8 nói được XML API tương thích S3 với HMAC key. Có
  `PresignPostObject` (đã kiểm, xem dưới).
- Mất: nhiều module nhỏ (`aws`, `credentials`, `service/s3` và các module nội bộ chúng kéo theo); mặc định của SDK hướng
  tới AWS (checksum mới, virtual-hosted style) nên phải chỉnh cho MinIO.

#### B. `github.com/minio/minio-go/v7` (`v7.3.0`, go 1.25.0)

- Được: một module, `PostPolicy` trưởng thành, chạy với MinIO, S3, GCS.
- Mất: lệch hệ sinh thái AWS ở giai đoạn 7 (credential chain, Pod Identity, MediaConvert vẫn phải dùng aws-sdk-go-v2, nên
  khi đó repo có hai SDK cho cùng một việc).

### Quyết định về thư viện object storage

Chọn **A**.

| Module | Version | `go` trong `go.mod` | Dùng |
| --- | --- | --- | --- |
| `github.com/aws/aws-sdk-go-v2` | `v1.47.3` | 1.24 | Gói `aws` (kiểu cấu hình, `aws.String`...) |
| `github.com/aws/aws-sdk-go-v2/credentials` | `v1.20.9` | 1.24 | `credentials.NewStaticCredentialsProvider` |
| `github.com/aws/aws-sdk-go-v2/service/s3` | `v1.114.3` | 1.24 | Client S3, `PresignClient` |

## 3. Hai endpoint cho storage

### Các lựa chọn về endpoint

#### A. Hai endpoint: nội bộ cho service, công khai cho URL trả client

- Được: service gọi MinIO qua mạng compose; client nhận URL mở được từ máy host; trên AWS hai biến cùng giá trị nên code
  không có nhánh riêng cho local.
- Mất: thêm một biến và một presign client thứ hai.

#### B. `host.docker.internal` cho cả hai phía

- Mất: container gọi được, nhưng máy host không phân giải tên này ổn định (tuỳ phiên bản Docker Desktop và cấu hình
  `/etc/hosts`), nên URL trả client lúc được lúc không.

#### C. `network_mode: host` cho service

- Mất: mất cô lập mạng của compose; cổng gRPC lộ ra máy (ngược IN-2).

## 4. Object key và bucket

### Các lựa chọn về key

#### A. Key trong contract là nguyên văn key trong bucket; bucket chọn theo tiền tố

- Được: không cắt ghép chuỗi ở đâu cả; key trong database, trong event, trong policy IAM theo tiền tố và đường dẫn CDN
  (giai đoạn 7: origin là bucket `media`, path = key) trùng nhau; nhìn key là biết object nằm ở đâu.
- Mất: tên bucket lặp trong đường dẫn (`media/media/...`) khi dùng path-style ở local.

#### B. Bỏ tiền tố khi ghi (`uploads/<id>` thành key `<id>` trong bucket `uploads`)

- Được: URL local gọn hơn.
- Mất: mọi chỗ đọc ghi phải nhớ cắt và ghép tiền tố; quên một chỗ là đọc sai object; policy IAM và đường dẫn CDN lệch key
  trong contract.

## 5. Redpanda

### Các lựa chọn về tạo topic

#### A. Bật auto-create, topic tự sinh khi produce lần đầu

- Mất: gõ sai tên topic là có topic mới lặng lẽ; số partition, retention lấy mặc định của broker; cấu hình topic không nằm
  trong repo.

#### B. Service tạo topic lúc khởi động (`kadm`)

- Mất: service cần quyền quản trị broker (ngược IN-4 ở giai đoạn 4); topology rải trong code nhiều service, ai khởi động
  trước thì cấu hình người đó thắng.

#### C. Tắt auto-create; container one-shot `redpanda-init` tạo topic bằng `rpk`

- Được: topology là hạ tầng, nằm ở một chỗ trong repo, giống Job k8s hay Terraform về sau; service chỉ cần quyền
  produce/consume.
- Mất: thêm một container one-shot; thêm topic phải sửa script init.

### Các lựa chọn về số partition

| | Được | Mất |
| --- | --- | --- |
| 1 partition | Đơn giản, thứ tự toàn cục | Chỉ một media-worker chạy được; không học được scale consumer |
| **3 partition** | Tối đa 3 media-worker song song, khớp "≥ 3 worker" ở [architecture §3.2](../../explanation/capacity.md#kết-quả) | Thứ tự chỉ trong một partition (đủ, vì key theo `video_id`, ADR-0003 luật 3) |
| 6+ partition | Dư chỗ scale | Thừa với tải hiện tại; tăng partition về sau thì được, giảm thì không |

## 6. MinIO

### Ghi chú chỉnh và điều kiện xem lại

**Bị thay một phần bởi [0022](../0022-local-object-store-minio-replacement.md)** (2026-10-25): object store của compose và k3d là RustFS, service `s3`; init viết lại (`deploy/s3/init.sh`, `curl --aws-sigv4` thay `mc`), CORS theo bucket, console tắt. Hai user service, `svp-pg-backup`, ba file policy và bucket policy ẩn danh của `media` giữ nguyên nội dung. Image MinIO Chainguard ghim digest chỉ còn trong bước chép `make object-store-copy`, làm đường quay lại. Phần dưới giữ nguyên như lúc quyết.

- Xem lại khi: digest đang ghim không pull được nữa; Chainguard đổi chính sách gói miễn phí; có lỗ hổng chưa vá ảnh hưởng cách dùng local (ví dụ lỗ hổng khai thác được từ chính máy host). Khi đó chuyển sang lựa chọn C bằng ADR mới.

### Bối cảnh riêng: MinIO ngừng phát hành image chính thức

Kiểm ngày 2026-10-11: `minio/minio` và `minio/mc` trên Docker Hub trả `denied`; `quay.io/minio/minio` không có manifest hoặc
đòi đăng nhập với mọi tag đã thử (`latest`, `RELEASE.2025-10-15T17-29-55Z`, `RELEASE.2025-09-07...`,
`RELEASE.2025-07-23...`, `RELEASE.2025-04-22...`). Theo báo cáo của bên thứ ba (issue `milvus-io/milvus#53430`, bài trên
byteiota.com, trang hỗ trợ IBM node 7289585): image trên Docker Hub bị xoá khoảng 2026-09-11, Quay bắt đầu đòi xác thực
khoảng 2026-09-24; repo GitHub của MinIO đã archive, bản community không còn nhận bản vá. Ghim `minio/minio:RELEASE.*`
như dự định ban đầu là không làm được.

### Các lựa chọn về image MinIO

#### A. `cgr.dev/chainguard/minio`, ghim digest

- Được: Chainguard build MinIO từ mã nguồn và vẫn cập nhật (bản đã kiểm: `RELEASE.2026-09-22T19-25-18Z`, go1.27.2, image tạo
  2026-10-10); chạy không root (uid 65532); có sẵn `mc` (`/usr/bin/mc`, version báo `DEVELOPMENT.GOGET` vì build bằng
  `go get`) và `/bin/sh`, nên `minio-init` dùng cùng image; API S3 và POST policy là của chính MinIO.
- Mất: gói miễn phí chỉ phát tag `latest`, nên phải ghim theo digest; cập nhật bằng cách đổi digest bằng tay; phụ thuộc chính
  sách của một nhà cung cấp.

#### B. `derklaro/minio:RELEASE.2025-10-15T17-29-55Z`

- Được: bản dựng lại bản community cuối cùng, có tag.
- Mất: một cá nhân dựng, không kiểm được nguồn; đóng băng ở bản cũ, không có bản vá. Loại.

#### C. Đổi sang object storage khác

SeaweedFS (`chrislusf/seaweedfs`), Garage (`dxflrs/garage:v2.1.0`), RustFS (`rustfs/rustfs`).

- Được: dự án còn phát triển, đều có image arm64.
- Mất: mỗi cái phải kiểm lại POST policy (`content-length-range`, khớp key chính xác), bucket policy ẩn danh và user IAM theo
  tiền tố trước khi dùng; thay đổi lớn, đáng một ADR riêng.

## 7. Outbox

### Các lựa chọn về cách relay lấy dòng

#### A. `SELECT ... FOR UPDATE SKIP LOCKED` (câu chữ của ADR-0003)

- Được: nhiều replica cùng relay song song, mỗi replica lấy một lô khác nhau.
- Mất: hai event cùng key có thể rơi vào hai lô ở hai replica; replica giữ lô sau có thể produce trước, nên event lệch thứ tự
  trên partition, vi phạm ADR-0003 luật 3 (ví dụ `video.ready` tới trước `video.uploaded` của cùng video).

#### B. Một relay tại một thời điểm, khoá bằng `pg_try_advisory_xact_lock`

- Được: dòng được gửi đúng thứ tự `id`, nên đúng thứ tự theo key (với bất biến ghi ở phần quyết định); không cần thêm
  hệ thống khoá nào ngoài Postgres; replica không giữ được khoá thì bỏ vòng đó, không chặn gì.
- Mất: thông lượng relay bằng một replica. Với vài event mỗi giây của luồng upload thì thừa.

- Bảng `outbox` nằm trong database của từng service, tạo bằng migration goose của service đó:

  ```sql
  CREATE TABLE outbox (
      id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
      event_id     uuid        NOT NULL UNIQUE,
      topic        text        NOT NULL,
      record_key   text        NOT NULL,
      payload      bytea       NOT NULL,              -- bytes của message bọc, ví dụ svp.video.v1.VideoEvent
      headers      jsonb       NOT NULL DEFAULT '{}', -- header Kafka, gồm traceparent
      created_at   timestamptz NOT NULL DEFAULT now(),
      published_at timestamptz
  );
  CREATE INDEX outbox_unpublished_idx ON outbox (id) WHERE published_at IS NULL;
  ```

## 8. Consumer

### Các lựa chọn về commit offset

#### A. Auto-commit định kỳ

- Mất: offset có thể được commit trước khi handler xong; worker chết giữa chừng là mất event (ngược tiêu chí "kill worker
  giữa chừng, video không mất" của giai đoạn 2).

#### B. Commit tay sau khi handler xong (at-least-once)

- Được: event chỉ được coi là xong khi tác dụng đã xảy ra; kết hợp handler idempotent thì trùng không gây sai.
- Mất: phải tự viết vòng xử lý, retry, DLQ.

### Các lựa chọn về retry

| | Được | Mất |
| --- | --- | --- |
| **Retry trong process có backoff, rồi DLQ** | Đơn giản; lỗi tạm thời ngắn (storage timeout) tự hết | Partition bị chặn trong lúc retry (mặc định tối đa ~7,5 s chờ; media-worker vài phút, mục 9) |
| Topic retry riêng (`<topic>.retry.N`) | Không chặn partition | Thêm topic và consumer; mất thứ tự theo key, mà thứ tự là luật 3 của ADR-0003 |

## 9. media-worker

### Các lựa chọn về image runtime

| | Được | Mất |
| --- | --- | --- |
| distroless `static` (như service) | Không shell, không package | Không có ffmpeg; chép ffmpeg vào thì phải chép cả thư viện động của nó |
| **`alpine` ghim tag + `apk add ffmpeg`** | Nhỏ; ffmpeg do Alpine build và vá; có `ffprobe` | Có shell và package manager trong image (bù bằng `read_only`, `cap_drop`, không root) |
| `debian-slim` + `apt install ffmpeg` | Bản ffmpeg phổ biến | Image nặng hơn nhiều (kéo theo hàng trăm thư viện) |
| ffmpeg static tải ngoài (ví dụ johnvansickle) | Bản ffmpeg mới nhất | Khó kiểm nguồn và chuỗi cung ứng; tự gánh cập nhật |

## 10. HLS và ffmpeg

### Các lựa chọn về độ dài segment

| | Được | Mất |
| --- | --- | --- |
| 2 s | Khởi phát nhanh nhất, đổi bitrate nhanh | Gấp đôi số object và request; playlist dài hơn |
| **4 s** | Ít object hơn một nửa; video ngắn vẫn khởi phát nhanh (segment đầu của 360p chỉ ~400 KB) | Đổi bitrate chậm hơn một nhịp |
| 6 s (mặc định cũ của Apple) | Ít object nhất | Khởi phát chậm thấy rõ với video 15–60 s |

### Các lựa chọn về preset `libx264`

| | Được | Mất |
| --- | --- | --- |
| `ultrafast` | Nhanh nhất | File to hơn rõ ở cùng chất lượng, tốn egress (khoản chi lớn nhất, architecture §3.3) |
| **`veryfast`** | Giữ được mục tiêu ~60 s cho video 60 s trên 2 vCPU (A8) | File to hơn `medium` một chút |
| `medium` (mặc định) | File nhỏ hơn | Chậm gấp vài lần, khó giữ p95 < 2 phút |

- Ladder theo cạnh ngắn (video dọc là chủ yếu, ADR-0004), bitrate theo A6:

  | Rendition | Cạnh ngắn | Bitrate video |
  | --- | --- | --- |
  | `360p` | 360 | 0,8 Mbps |
  | `720p` | 720 | 2,5 Mbps |
  | `1080p` | 1080 | 5 Mbps |

## 11. Cấu hình mới

### Các lựa chọn về cấu hình storage và broker

#### A. Biến môi trường như ADR-0007 mục 4

- Được: cùng một image chạy ở compose, k8s, cloud; đúng quy ước đã có.
- Mất: danh sách biến của video-service dài thêm.

#### B. Một biến URL gộp (ví dụ `S3_URL=http://key:secret@minio:9000/uploads`)

- Mất: trộn bí mật với địa chỉ; phải tự parse; không khớp cách SDK nhận cấu hình.

### Quyết định về cấu hình

Chọn **A**. Thiếu biến bắt buộc hoặc sai định dạng thì service thoát ngay lúc khởi động với lỗi nêu tên biến (không in giá
trị), như ADR-0007.

| Service | Biến | Mặc định | Ý nghĩa |
| --- | --- | --- | --- |
| `video-service` | `KAFKA_BROKERS` | — (bắt buộc) | Danh sách `host:port` cách nhau bởi dấu phẩy; compose `redpanda:9092` |
| `video-service` | `S3_ENDPOINT` | — (bắt buộc) | Endpoint S3 service gọi; compose `http://minio:9000` |
| `video-service` | `S3_PUBLIC_ENDPOINT` | = `S3_ENDPOINT` | Endpoint ghép vào `upload_url`; local `http://127.0.0.1:9000` |
| `video-service` | `S3_REGION` | `us-east-1` | Region ký SigV4 |
| `video-service` | `S3_ACCESS_KEY_ID` | — (bắt buộc) | Local `svp-video-service` |
| `video-service` | `S3_SECRET_ACCESS_KEY` | — (bắt buộc) | Local từ `SVP_VIDEO_S3_SECRET_KEY` |
| `video-service` | `S3_UPLOADS_BUCKET` | `uploads` | Bucket của tiền tố `uploads/` |
| `video-service` | `S3_MEDIA_BUCKET` | `media` | Bucket của tiền tố `media/` |
| `media-worker` | `KAFKA_BROKERS` | — (bắt buộc) | Như video-service |
| `media-worker` | `S3_ENDPOINT` | — (bắt buộc) | Như video-service (worker không ký URL nên không có `S3_PUBLIC_ENDPOINT`) |
| `media-worker` | `S3_REGION` | `us-east-1` | Như video-service |
| `media-worker` | `S3_ACCESS_KEY_ID` | — (bắt buộc) | Local `svp-media-worker` |
| `media-worker` | `S3_SECRET_ACCESS_KEY` | — (bắt buộc) | Local từ `SVP_MEDIA_WORKER_S3_SECRET_KEY` |
| `media-worker` | `S3_UPLOADS_BUCKET` | `uploads` | Như video-service |
| `media-worker` | `S3_MEDIA_BUCKET` | `media` | Như video-service |
| `media-worker` | `WORK_DIR` | `/work` | Thư mục tạm của job |
| `gateway` | `MEDIA_PUBLIC_BASE_URL` | — (bắt buộc) | Gốc URL phát (mục 4); local `http://127.0.0.1:9000/media` |

## 12. Cổng và RAM

### Các lựa chọn về cổng

#### A. Cổng mặc định của từng phần mềm, chỉ trên `127.0.0.1`

- Được: tài liệu, `mc`, `rpk` dùng mặc định là chạy; nhìn cổng biết phần mềm.
- Mất: đụng nếu máy có phần mềm khác dùng cùng cổng (đã kiểm: không có).

#### B. Dời vào dải riêng của project (ví dụ `92xx`)

- Mất: phải nhớ ánh xạ, đổi cấu hình mặc định của công cụ, không thêm lợi ích gì khi cổng đang trống.

## 13. Phạm vi phần A

### Các lựa chọn về phạm vi

#### A. Làm đủ mọi biện pháp giai đoạn 2 của luồng upload cùng lúc

- Mất: job dọn upload bỏ dở cần khoá phân tán (lab `distributed-cron-lock`), giới hạn số video `UPLOADING` đi cùng rate limit
  cần Redis; gộp vào làm phần A phình to, khó đo từng phần.

#### B. Phần A làm luồng upload chạy đầu-cuối có số đo; các phần cần Redis hoặc lab riêng làm ở phần sau

- Được: phần A kết thúc ở trạng thái chạy được (upload → HLS → `READY`/`FAILED`), đúng nguyên tắc của plan.
- Mất: trong khoảng giữa hai phần, upload bỏ dở và gọi `InitUpload` liên tục chưa bị chặn (chỉ chạy local, chấp nhận).
