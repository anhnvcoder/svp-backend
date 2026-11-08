# Ước lượng quy mô

Trang này trả lời: hệ thống phải chịu bao nhiêu tải, lưu bao nhiêu dữ liệu, phát bao nhiêu băng thông, và các con số đó quyết
định thiết kế ra sao. Yêu cầu phi chức năng mà các con số phục vụ ở [`architecture.md`](../architecture.md#2-ràng-buộc-và-yêu-cầu-phi-chức-năng).

## Giả định

Vì sao: [ADR-0001](../adr/0001-service-boundaries-and-data-ownership.md), [ADR-0004](../adr/0004-direct-upload-and-hls.md),
[ADR-0005](../adr/0005-feed-fan-out-on-write.md).

P1–P3 là giả định gốc của dự án; A1–A8 là giả định của bản thiết kế này, sai thì sửa ở đây rồi tính lại.

| | Giả định |
| --- | --- |
| P1 | 100k người dùng hoạt động mỗi ngày (DAU) |
| P2 | Feed 1.000 request/giây lúc cao điểm |
| P3 | 1.000 video upload mỗi ngày, mỗi video tối đa 3 phút |
| A1 | Mỗi DAU xem 60 video/ngày, trung bình 20 s/video (20 phút/ngày) |
| A2 | Một trang feed 10 video, nên mỗi DAU gọi feed 6 lần/ngày |
| A3 | Cao điểm = 3 × trung bình |
| A4 | 5% lượt xem có like |
| A5 | Video trung bình 60 s; file gốc quay 1080p khoảng 10 Mbps, tức 75 MB |
| A6 | HLS 3 bản: 360p 0,8 Mbps + 720p 2,5 Mbps + 1080p 5 Mbps = 8,3 Mbps (62 MB cho video 60 s); người xem nhận trung bình 2,5 Mbps |
| A7 | 1 triệu tài khoản, mỗi tài khoản follow trung bình 50 người; video upload được fan-out tới trung bình 2.000 follower; tài khoản lớn nhất 200k follower |
| A8 | Một worker 2 vCPU transcode video 60 s ra 3 bản mất khoảng 60 s. Số đo trên máy local M2 (worker giới hạn 2 CPU, preset `veryfast`, video tổng hợp 60 s 1080p `testsrc2`, `measure-ready N=5` của bài lab `drills/` của `svp-labs`): `CompleteUpload` → `READY` p50 46,8 s, max 47,6 s, gồm tải file gốc, transcode, ghi HLS và hai chặng event |

P1 dùng để ước lượng dung lượng, băng thông, chi phí; P2 là mục tiêu tải cho k6, không suy ra từ P1 (xem
[Rút ra gì](#rút-ra-gì)).

Một ngày có 86.400 giây.

## Kết quả

Vì sao: [ADR-0005](../adr/0005-feed-fan-out-on-write.md) (timeline), [ADR-0009](../adr/0009-engagement-feed-stage2b.md) (lượt xem).

| Đại lượng | Cách tính | Kết quả |
| --- | --- | --- |
| Request feed | 100k × 6 / 86.400 | ~7 req/s trung bình, **~21 req/s** cao điểm |
| Lượt xem | 100k × 60 / 86.400 | ~70/s trung bình, ~210/s cao điểm |
| Lượt xem ở mục tiêu tải | 1.000 req/s × 10 video | **~10.000 event/s** |
| Like | 5% × 6 triệu = 300k/ngày | ~10/s cao điểm |
| Upload | 1.000 / 24 × 3 | ~125 video/giờ, khoảng **2 video/phút** cao điểm |
| Băng thông upload | 1.000 × 75 MB = 75 GB/ngày | ~7 Mbps trung bình, ~21 Mbps cao điểm |
| Transcode | 2 video/phút × 60 s/video | ~2 worker bận lúc cao điểm; cần **≥ 3** để chờ ít và giữ p95 < 2 phút; ban đêm gần 0 |
| Lưu trữ video | (75 + 62) MB × 1.000 | ~137 GB/ngày ≈ 4 TB/tháng ≈ **50 TB/năm** (giữ cả file gốc) |
| Egress phát video | 6 triệu × 20 s × 2,5 Mbps | ~37,5 TB/ngày ≈ **1,1 PB/tháng**; ~3,5 Gbps trung bình, ~10 Gbps cao điểm |
| Postgres: follow | 1 triệu × 50 cạnh, ~160 B/cạnh kể cả 2 index | ~8 GB, lưu 2 nơi (user-service và bản sao ở feed-service) |
| Postgres: timeline | 1.000 × 2.000 = 2 triệu dòng/ngày, giữ 30 ngày, ~110 B/dòng | 60 triệu dòng ≈ 7 GB |
| Postgres: video, like | video ~1 KB/dòng; like 300k dòng/ngày | video không đáng kể; like ~15 GB/năm |
| Kafka: lượt xem | 6 triệu × ~200 B, giữ 7 ngày | ~8 GB mỗi bản sao (prd RF 3 trên MSK: ~24 GB) |

## Rút ra gì

Vì sao: [ADR-0001](../adr/0001-service-boundaries-and-data-ownership.md), [ADR-0004](../adr/0004-direct-upload-and-hls.md),
[ADR-0005](../adr/0005-feed-fan-out-on-write.md), [ADR-0010](../adr/0010-redis-ratelimit-cache-resilience-stage2c.md).

1. **Hai giả định gốc không khớp nhau, và đã chốt cách dùng.** 100k DAU chỉ sinh ~21 req/s feed lúc cao điểm; 1.000 req/s
   tương ứng khoảng 5 triệu DAU với cùng hành vi. P1 (100k DAU) là giả định để ước lượng dung lượng, băng thông, chi phí;
   P2 (1.000 req/s) là **mục tiêu tải** cho k6, khoảng 50 lần cao điểm thật, đặt ra có chủ ý: ở 21 req/s một Postgres
   không cache cũng thừa sức, không còn gì để học về cache, singleflight, đo p99, gom ghi lượt xem. Không nâng DAU lên
   ~5 triệu cho khớp, vì khi đó egress phình lên ~55 PB/tháng (1,1 PB × 50) và mô hình chi phí mất ý nghĩa. Hệ quả:
   ở mục tiêu tải có ~10.000 event lượt xem/giây, lab `hot-counter` đo ở mức này. Các con số còn lại tính theo 100k DAU.
2. **Tiền nằm ở egress, không nằm ở service.** Dữ liệu phát ra mỗi tháng (1,1 PB) lớn gấp khoảng 275 lần dữ liệu lưu
   thêm (4 TB). CDN là bắt buộc; thứ đáng tối ưu nhất là bitrate ladder và tỉ lệ cache hit của CDN, không phải code Go.
   Feed vuốt thường tải trước vài video kế tiếp, nên egress thật còn cao hơn. Mô hình chi phí quy các con số này ra USD.
3. **Đọc metadata nhỏ.** Ngay ở 1.000 req/s, Postgres có index đúng vẫn chịu được. Cache dùng để chống **key nóng**
   (feed khám phá: mọi người đọc cùng một danh sách), không phải vì tổng tải ([ADR-0005](../adr/0005-feed-fan-out-on-write.md)).
4. **Ghi nóng nằm ở lượt xem.** ~10.000 event/s ở mục tiêu tải, dồn vào vài video viral: cập nhật từng dòng thì tranh
   khoá trên cùng một row. Cần gom ghi theo lô; lab `hot-counter` chọn cách cụ thể.
5. **Transcode ít nhưng nặng và dồn cục.** Tách worker riêng, KEDA scale theo độ trễ hàng chờ
   ([ADR-0001](../adr/0001-service-boundaries-and-data-ownership.md), [triển khai](deployment.md#kubernetes-cục-bộ-k3d)).
6. **Upload nhỏ về băng thông nhưng mỗi kết nối kéo dài.** Không cho file đi qua service; client đẩy thẳng lên object
   storage ([ADR-0004](../adr/0004-direct-upload-and-hls.md)).
