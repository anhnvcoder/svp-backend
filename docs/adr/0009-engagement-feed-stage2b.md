# 0009. Event follow qua outbox, lượt xem gom lô với offset trong Postgres, feed fan-out on write có khoá theo tác giả

- Trạng thái: Chấp nhận
- Ngày: 2026-10-11

## Bối cảnh và vấn đề

- Làm thật F2 (phần event), F5, F6, F7 của [architecture §1](../architecture.md#1-mục-tiêu-và-phạm-vi): user-service phát `user.followed` / `user.unfollowed`; engagement-service giữ like, nhận lượt xem và giữ bộ đếm; feed-service dựng read model từ event và trả feed; gateway thêm route feed, like, lượt xem. Redis, cache, rate limit, timeout/retry/circuit breaker thuộc [ADR-0010](0010-redis-ratelimit-cache-resilience-stage2c.md) (mục 14).
- NFR ([architecture §2](../architecture.md#2-ràng-buộc-và-yêu-cầu-phi-chức-năng)): **độ tươi** video `READY` vào feed follower p95 < 10 s; **đúng đắn** event gửi trùng không làm sai bộ đếm; **nhất quán** số lượt xem trễ tối đa ~1 phút, like của chính mình thấy ngay; **độ trễ** feed p99 < 150 ms tại 1.000 req/s tính cả ghép số đếm.
- Số liệu ([capacity](../explanation/capacity.md)): ~10.000 event lượt xem/giây, like ~10/s cao điểm; timeline ~2 triệu dòng/ngày, giữ 30 ngày ~60 triệu dòng (~7 GB); bản sao follow ~50 triệu cạnh; một video fan-out trung bình tới 2.000 follower, tài khoản lớn nhất 200k (A7). Ghi nóng nằm ở lượt xem: cập nhật từng dòng tranh khoá dòng của video viral.
- Đã chốt hướng ở ADR trước: outbox, at-least-once, `processed_events` cho consumer không tự idempotent (luật 1), produce thẳng khi không ghi database (luật 4) ([ADR-0003](0003-async-events-outbox.md)); fan-out on write, timeline 30 ngày, keyset (`published_at`, `video_id`) ([ADR-0005](0005-feed-fan-out-on-write.md)); topic theo luồng thực thể, envelope ([ADR-0006](0006-contract-ids-and-event-envelope.md)); relay một luồng nhờ advisory lock, consumer commit tay + DLQ trong `internal/kafkax` ([ADR-0008](0008-async-upload-pipeline-stage2a.md) mục 5, 7, 8). ADR này không sửa ADR nào; chỗ chỉnh chi tiết so với ADR-0005 ghi ở mục 6 và 7.
- Threat model: IN-4 (ai vào được Redpanda là phát được event giả), IN-5 (event hỏng không chặn partition), PG-1, PG-2 (page token); RL-3, RL-6 để ADR-0010. Ràng buộc máy như ADR-0008: Docker VM 7,65 GiB, 8 CPU; compose profile `core`; Postgres native `127.0.0.1:5432`.

## Yếu tố quyết định

Không mất event follow; bộ đếm lượt xem đúng một lần dù giao lại, với chi phí chống trùng không phình; ghi nóng ~10.000 event/s không thành 10.000 câu `UPDATE`/s; feed không sập theo service kém quan trọng hơn; fan-out không lệch khi follow, unfollow và `video.ready` chạy đồng thời; không thêm dependency.

## Phương án đã cân nhắc

- §1 **A outbox trong `svp_user`, relay `internal/outbox`**: ghi cạnh và event nguyên tử, giữ thứ tự mỗi cạnh; user-service thêm phụ thuộc Kafka và một relay, trễ thêm tối đa một chu kỳ poll (200 ms).
- §1 B commit rồi produce thẳng (dual write): crash giữa hai bước mất `user.followed`, bản sao follow thiếu cạnh vĩnh viễn: loại.
- §1 C feed-service gọi user-service lấy follower: ngược ADR-0005, fan-out 200k follower phải phân trang qua gRPC, feed-service lỗi theo user-service: loại.
- §2 **A bảng `likes` + `like_counts` đổi cùng transaction**: `GetStats` đọc một dòng mỗi video, đếm đúng tuyệt đối; thêm một bảng và một câu ghi mỗi like.
- §2 B `count(*)` lúc đọc: 10.000 lần đếm mỗi giây ở 1.000 req/s, video viral quét cả triệu mục index: loại.
- §2 C gom like theo lô qua event: like của chính mình phải thấy ngay, like ~10/s không đáng thêm topic và consumer: loại.
- §3 **A produce thẳng `view.recorded` (`acks=all`)**: đường ghi nóng không chạm Postgres; broker lỗi thì lượt xem lỗi, gửi lại sau khi quá hạn có thể thành hai lượt.
- §3 B `UPDATE view_counts` mỗi lượt xem: 10.000 `UPDATE`/s tranh khoá dòng của video viral: loại.
- §3 C qua outbox: thêm một lần ghi Postgres mỗi lượt xem chỉ để phát event (ADR-0003 luật 4): loại.
- §4 A `processed_events` theo `event_id`: ~864 triệu dòng/ngày chỉ để chống trùng, index phình: loại.
- §4 B chỉ bỏ `event_id` trùng trong một lô: giao lại xảy ra ở lô sau nên không chặn được trùng thật: loại.
- §4 C `UPDATE` từng event kèm `processed_events`: 10.000 transaction/s cộng toàn bộ chi phí của A: loại.
- §4 D Kafka transaction (exactly-once): chỉ nguyên tử khi đích ghi là Kafka, đích ở đây là Postgres: loại.
- §4 **E offset lưu trong Postgres cùng transaction với bộ đếm**: một transaction mỗi lô, chống trùng một dòng mỗi partition; đúng đắn dựa vào offset Kafka ổn định, phải viết consumer theo lô.
- §4 lô 500 record / 100 ms: trễ thêm thấp nhất; gấp 10 lần số transaction: loại.
- §4 **lô 5.000 record / 1 s**: ~2 transaction/s, trễ thêm ≤ 1 s; transaction lớn hơn, thử lại một lô tốn hơn.
- §4 lô 50.000 record / 10 s: ít transaction nhất; transaction dài giữ khoá lâu, thử lại rất tốn: loại.
- §5 **A ba bảng riêng (`view_counts`, `like_counts`, `likes`)**: lô lượt xem không làm `Like` chờ; ba câu đọc thay một.
- §5 B gộp vào `video_stats`: lô lượt xem và `Like` cùng khoá một dòng của video viral: loại.
- §6 khoá timeline **A `(user_id, published_at, video_id)`**: một index vừa chống trùng vừa phục vụ keyset; dựa vào `published_at` không đổi, unfollow phải join `videos`.
- §6 khoá timeline B `(user_id, video_id)` + index đọc: hai index, gấp đôi chi phí index lúc fan-out: loại.
- §6 khoá timeline C thêm `author_id`: thêm ~1 GB chỉ để unfollow không cần join: loại.
- §6 giữ 30 ngày **A lọc khi đọc + job dọn mỗi giờ**: đơn giản, idempotent, dòng quá hạn không lọt ra feed; job tìm dòng cũ bằng quét bảng.
- §6 giữ 30 ngày B partition theo ngày: dọn gần như miễn phí; thêm vận hành, chưa đáng ở ~60 triệu dòng: loại.
- §6 giữ 30 ngày C N dòng mới nhất mỗi người: không khớp "30 ngày" của ADR-0005 luật 2: loại.
- §7 **A `pg_advisory_xact_lock` theo tác giả**: tuần tự đúng thao tác cùng tác giả, không cần bảng; fan-out tài khoản lớn giữ khoá suốt đợt ghi.
- §7 B `SERIALIZABLE`: đợt fan-out 200k dòng bị huỷ và chạy lại khi đụng một follow: loại.
- §7 C khoá một dòng mỗi tác giả (bảng `authors`): thêm bảng chỉ để khoá: loại.
- §8 **A mã hoá tay bằng `protowire`**: đúng định dạng contract, gói đã có; không có schema viết ra.
- §8 B message `.proto` riêng: cần cấu hình `buf` sinh code thứ hai chỉ cho hai field: loại.
- §8 C JSON + base64url: token dài gần gấp đôi: loại.
- §9 **A một `GetStats` cho cả trang, 100 ms, không retry, lỗi thì bỏ `stats`**: SLO feed không phụ thuộc engagement-service; feed thiếu số đếm khi nó chậm.
- §9 B lỗi `GetStats` thì cả feed lỗi: feed sập theo service kém quan trọng hơn: loại.
- §9 C retry `GetStats`: ngân sách 100 ms không chứa nổi một lần thử lại: loại.
- §10 **A công cụ Go phát `user.followed` từ máy host**: đi đúng đường consumer thật; giả danh user-service, bản sao follow lệch tới khi dọn.
- §10 B ghi thẳng vào `svp_feed`: bỏ qua consumer, đo thiếu phần đáng đo: loại.
- §14 A làm cả Redis, cache, rate limit cùng lúc: không đo riêng được hiệu quả của cache và rate limit: loại.
- §14 **B dừng ở luồng follow → feed → like/xem có số đo**: chạy được, có mốc để so; route like, lượt xem tạm chưa có rate limit.

Phân tích được/mất từng phương án, ví dụ đua và SQL đầy đủ ở [phụ lục](appendix/0009-engagement-feed-stage2b.md).

## Kết quả quyết định

Chọn outbox cho event follow (§1), like đổi cùng transaction với bộ đếm (§2), lượt xem produce thẳng rồi gom lô 5.000 record / 1 s với offset lưu trong Postgres (§3, §4), ba bảng đếm riêng (§5), timeline khoá `(user_id, published_at, video_id)` giữ 30 ngày bằng lọc khi đọc và job dọn (§6), khoá advisory theo tác giả (§7), page token mã hoá tay bằng `protowire` (§8), gateway ghép số đếm trong 100 ms và bỏ `stats` khi lỗi (§9), vì không mất event follow, lượt xem đếm đúng một lần mà không thành 10.000 `UPDATE`/s, feed không sập theo engagement-service, fan-out không lệch khi follow, unfollow và `video.ready` chạy đồng thời, và không thêm dependency; từng phần ở §1–§14.

### 1. Event follow ở user-service

Chọn **A**. Migration `services/user-service/migrations/00003_create_outbox.sql` (schema như `services/video-service/migrations/00002_create_outbox.sql`); relay `outbox.NewRelay(pool, kafkaClient, logger)` chạy cạnh gRPC server; biến mới `KAFKA_BROKERS` (bắt buộc với `serve`), compose `redpanda:9092`.

- `Follow`: một transaction, `INSERT INTO follows ... ON CONFLICT DO NOTHING`; **chỉ khi ảnh hưởng 1 dòng** thì `outbox.Write(ctx, tx, "user.follows.v1", follower_id, ev)` với `svp.user.v1.FollowEvent` nhánh `user_followed`. `Unfollow`: `DELETE FROM follows WHERE follower_id = $1 AND followee_id = $2`; 1 dòng thì ghi nhánh `user_unfollowed`; 0 dòng không phát gì.
- Thứ tự: `INSERT`/`DELETE` trên dòng `follows` là bước khoá thực thể, chạy **trước** `outbox.Write`, nên `id` outbox tăng theo thứ tự commit (ADR-0008 mục 7). Chỉ cần giữ thứ tự trong một cạnh (`follower_id`, `followee_id`).

### 2. Like

Chọn **A**. Bảng `likes` (`PRIMARY KEY (video_id, user_id)`) và `like_counts` (`video_id` khoá chính, `like_count bigint NOT NULL CHECK (like_count >= 0)`) trong `svp_engagement`; DDL ở phụ lục.

- `Like`: một transaction, `INSERT INTO likes ... ON CONFLICT DO NOTHING`; chèn được 1 dòng thì `INSERT INTO like_counts VALUES ($1, 1) ON CONFLICT (video_id) DO UPDATE SET like_count = like_counts.like_count + 1`. `Unlike`: `DELETE FROM likes ...`; xoá được 1 dòng thì `UPDATE like_counts SET like_count = like_count - 1`.
- Khoá luôn theo thứ tự dòng `likes` trước, `like_counts` sau, nên không deadlock. `liked_by_me` đọc `likes` theo khoá chính, đồng bộ, nên người gọi thấy like ngay sau khi `Like` trả về.

### 3. Ghi lượt xem

Chọn **A**: `RecordView` produce `svp.engagement.v1.ViewEvent` (`event_id` UUIDv7, `occurred_at` lúc nhận request; nhánh `view_recorded` với `video_id` và `viewer_id` = người gọi) vào `engagement.views.v1`, key `video_id`, qua `kafkax.Produce` (mang `traceparent`), giới hạn **2 s**; producer franz-go mặc định idempotent, `acks=all`.

- Lỗi produce hoặc quá 2 s: `UNAVAILABLE`, message không lộ chi tiết broker; không chạm database. Gửi lại sau khi quá hạn có thể thành hai lượt (`RecordView` không idempotent theo contract; chặn lạm dụng bằng RL-3 ở ADR-0010).

### 4. Gom ghi lượt xem và chống đếm trùng

Chọn **E** và lô **tối đa 5.000 record hoặc 1 s** kể từ record đầu tiên, cái nào tới trước (3 instance mỗi cái một partition: ~3.333 event/s, ~1 transaction/s mỗi instance). Bảng `view_counts` (`video_id` khoá chính, `view_count bigint`, `updated_at`) và `consumer_offsets` (khoá chính `(consumer_group, topic, partition)`, `next_offset bigint`); DDL ở phụ lục. Một lô (group `engagement-service`, topic `engagement.views.v1`):

1. Record hỏng (không parse được, thiếu nhánh `view_recorded`, `video_id`/`viewer_id` không phải UUID) **luôn** bị trả về là "loại", kể cả khi offset đã áp dụng, để vào `engagement.views.v1.dlq` ít nhất một lần (`dlq-reason=permanent`); không chặn lô, offset vẫn tiến.
2. Mở transaction; theo partition tăng dần: chèn `consumer_offsets` với `next_offset = 0` nếu chưa có (`ON CONFLICT DO NOTHING`), rồi `SELECT next_offset ... FOR UPDATE`.
3. Topic bị tạo lại (`make clean-data` xoá volume Redpanda, Postgres native giữ `consumer_offsets`): chỉ xét partition có `next_offset` lưu lớn hơn offset cuối của partition trong lô + 1; với chúng, **sau khi** đã khoá dòng và **ở mỗi lần thử**, hỏi broker end offset hiện tại (`ListOffsets`, timestamp −1), không dùng high watermark của fetch. `next_offset` lưu > end offset: log WARN, đặt về offset của record đầu tiên của partition trong lô (chỗ duy nhất `next_offset` được hạ). Ngược lại là lô giao lại mà phần đã cộng vượt quá nó: giữ nguyên.
4. Bỏ record có `offset < next_offset`; cộng dồn phần còn lại theo `video_id` trong bộ nhớ.
5. Một câu cho cả lô, hai mảng sắp theo `video_id` để mọi transaction khoá dòng cùng thứ tự: `INSERT INTO view_counts (video_id, view_count) SELECT * FROM unnest($1::uuid[], $2::bigint[]) ON CONFLICT (video_id) DO UPDATE SET view_count = view_counts.view_count + EXCLUDED.view_count, updated_at = now()`.
6. `next_offset = GREATEST(next_offset, offset cuối của partition trong lô + 1)` (tính cả record bị loại; không đặt thẳng, vì lô giao lại có thể nhỏ hơn lô đã cộng), `updated_at = now()`; commit.
7. **Sau đó** kafkax đẩy record bị loại sang DLQ, rồi commit offset cao nhất mỗi partition lên Kafka.

- Đúng một lần dù giao nhiều lần: offset Kafka chưa tiến thì record giao lại, bước 4 lọc phần đã cộng, bước 6 không để `next_offset` lùi; hai instance cùng giữ một partition (rebalance) tuần tự nhờ `FOR UPDATE` ở `READ COMMITTED`; thứ tự khoá cố định (partition, rồi `video_id`) không khoá chéo.
- Lỗi tạm thời (Postgres, hỏi end offset): thử lại **cả lô**, backoff 0,5 s → trần 10 s có jitter, **không giới hạn số lần**, log WARN mỗi lần; không đẩy lô sang DLQ vì mất lượt xem, Redpanda giữ 7 ngày. Consumer theo lô bật `BlockRebalanceOnPoll`; đúng đắn dựa vào offset trong database, không dựa vào chặn rebalance.
- `internal/kafkax` **chỉ thêm API** (`NewClient`, `Produce`, `Consumer`, `ConsumerConfig`, `Handler`, `Permanent`, hằng số header giữ nguyên): consumer theo lô nhận cả lô, trả danh sách record bị loại (kèm lỗi) và `error`; hàm hỏi end offset dùng `kmsg.ListOffsetsRequest` `Timestamp = -1` gửi qua `(*kgo.Client).Request`. Header DLQ mới **`dlq-group`**: `video.lifecycle.v1.dlq` có hai group ghi (`media-worker`, `feed-service`). Lab `hot-counter` đo lại với các cách khác bằng k6 ở 10.000 event/s.

### 5. Đọc số đếm (`GetStats`)

Chọn **A**: ba bảng riêng (`view_counts`, `like_counts`, `likes`), đọc theo khoá chính; lô lượt xem không làm `Like` chờ. Tối đa **50** id (nhiều hơn, hay id không phải UUID: `INVALID_ARGUMENT`); trả theo thứ tự request, mỗi id một phần tử (id lặp thì trả lặp); id lạ: `view_count = 0`, `like_count = 0`, `liked_by_me = false`; ba câu `WHERE video_id = ANY($ids)` hoặc một câu `unnest($ids) WITH ORDINALITY ... LEFT JOIN`, không quét bảng.

### 6. Schema của feed-service

Chọn khoá timeline **A** và giữ 30 ngày **A**. Bảng trong `svp_feed` (DDL ở phụ lục): `follows` (khoá chính `(followee_id, follower_id)`, ngược chiều user-service vì feed-service hỏi theo tác giả), `videos` (index `(author_id, published_at DESC, video_id DESC)` cho backfill, `(published_at DESC, video_id DESC)` cho khám phá), `timeline` (khoá chính `(user_id, published_at, video_id)`).

- `videos` ghi `ON CONFLICT (video_id) DO NOTHING`: bản đầu thắng, `published_at` của một video không đổi, nên khoá timeline chống trùng được. `timeline` không có `author_id`: unfollow xoá bằng join `videos`. `created_at` của `timeline` dùng `clock_timestamp()` để đo độ dài một đợt fan-out.
- Giữ **30 ngày** (ADR-0005 luật 2): mọi câu đọc lọc `published_at > now() - interval '30 days'`; mỗi giờ một goroutine xoá theo lô vài nghìn dòng có `published_at < now() - interval '30 days'`, lặp tới khi hết; idempotent, chạy ở nhiều replica không sai. Không giới hạn số dòng mỗi người. Chỉnh chi tiết so với ADR-0005 luật 2: job dọn đi kèm lọc lúc đọc.

### 7. Xử lý event ở feed-service

Chọn **A**. Một consumer group **`feed-service`** (từng record) đọc `user.follows.v1` và `video.lifecycle.v1`. Không khoá thì ở `READ COMMITTED` có hai lỗi: video của người đã unfollow còn trong feed, và follower mới thiếu video vừa fan-out. Mọi thao tác chạm cạnh follow hay fan-out của tác giả X chạy trong một transaction mà **câu đầu tiên** là `SELECT pg_advisory_xact_lock(hashtextextended('feed-author:' || X, 0))`.

- **`user.followed`**: khoá theo `followee_id`; `INSERT INTO follows ... ON CONFLICT DO NOTHING`; backfill **luôn chạy** (kể cả khi cạnh đã có): `INSERT INTO timeline ... SELECT $follower_id, published_at, video_id FROM videos WHERE author_id = $followee_id AND published_at > now() - interval '30 days' ORDER BY published_at DESC, video_id DESC LIMIT 20 ON CONFLICT DO NOTHING`. Tối đa **20** video (hai trang feed; chỉnh chi tiết so với "vài chục video" của ADR-0005 luật 3).
- **`user.unfollowed`**: khoá theo `followee_id`; xoá cạnh; `DELETE FROM timeline t USING videos v WHERE t.user_id = $follower_id AND t.video_id = v.video_id AND v.author_id = $followee_id`.
- **`video.ready`**: kiểm field trước (`video_id`, `author_id` là UUID; `playlist_key`, `thumbnail_key` dạng `media/<video_id>/...`, mỗi đoạn `[A-Za-z0-9._-]` và không phải `.` hay `..`, qua `objstore.IsMediaKey`; có `published_at` và `duration`); sai thì `kafkax.Permanent` → `video.lifecycle.v1.dlq`. Rồi khoá theo `author_id`, ghi `videos` `ON CONFLICT (video_id) DO NOTHING`, fan-out **một câu** `INSERT INTO timeline ... SELECT f.follower_id, v.published_at, v.video_id FROM follows f JOIN videos v ON v.video_id = $video_id WHERE f.followee_id = $author_id ON CONFLICT DO NOTHING`. Tác giả không nhận video của mình vì không tự follow được (`follows_no_self_follow`).
- `video.uploaded`, nhánh `oneof` lạ hay rỗng: bỏ qua, commit (ADR-0006); payload không parse được: `kafkax.Permanent`.
- **Retry:** lỗi tạm thời (Postgres, Kafka) thử lại **không giới hạn**, backoff 0,5 s → trần 10 s; DLQ chỉ cho payload hỏng; đặt `MaxAttempts` = `math.MaxInt`, không đổi API kafkax. Partition bị chặn lúc Postgres lỗi là đúng ý: lag tăng, không mất gì.
- **Tài khoản lớn** (A7: 200k follower): giữ fan-out on write thuần (ADR-0005 phương án B), đo độ tươi ở 10.000 và 200.000 follower (mục 10). Xem lại khi p95 ở 200k vượt 10 s: chia fan-out thành nhiều transaction có điểm dừng, hoặc phương án C của ADR-0005.
- **Giới hạn đã biết:** phát lại phải giữ thứ tự partition (`rpk group seek` cả group); đẩy lại riêng một `user.followed` cũ từ DLQ có thể dựng lại cạnh đã unfollow (xem lại khi cần phát lại an toàn: tombstone cạnh kèm `occurred_at`). `BlockRebalance` với `RebalanceTimeout` 5 phút: Postgres lỗi lâu hơn, từ 2 replica, rebalance giữa chừng thì lần thử lại cũ của `user.followed` có thể áp sau `user.unfollowed` của chủ mới, cạnh quay lại; đóng hẳn cần kafkax dừng handler khi partition bị thu về.

### 8. Phân trang feed

Chọn **A**: token là base64url **không padding** của bytes protobuf mã hoá tay bằng `google.golang.org/protobuf/encoding/protowire` (field 1 `published_at` varint int64 micro giây Unix; field 2 `video_id` bytes đúng 16), ~36 ký tự, không file `.proto`, không ký ([contract](../reference/contracts.md#phân-trang-feed)).

- Token dài quá **64 ký tự** bị từ chối trước khi giải mã (PG-2); không phải base64url, protowire lỗi, thiếu field, sai kiểu wire hay `video_id` không đủ 16 byte: `INVALID_ARGUMENT`, reason **`INVALID_PAGE_TOKEN`**; field lạ bỏ qua. `page_size`: 0 → 10; > 50 → 50; âm → `INVALID_ARGUMENT`, reason **`INVALID_PAGE_SIZE`**.
- Đọc `page_size + 1` dòng: có dòng thừa thì `next_page_token` mã hoá (`published_at`, `video_id`) của dòng cuối trang, không thì rỗng. Feed following: từ `timeline` của người gọi (`user_id` từ `x-user-id`), lọc 30 ngày, nối `videos`; trang sau thêm `(published_at, video_id) < (...)`, `ORDER BY published_at DESC, video_id DESC`. Feed khám phá: từ `videos` (mọi video `READY`, không giới hạn 30 ngày), cùng keyset.

### 9. Gateway

Chọn **A**: một `GetStats` cho mọi `video_id` của trang (bỏ qua khi trang rỗng), timeout **100 ms** (p99 cả request feed là 150 ms), không retry; lỗi hay quá hạn thì trả trang **không có field `stats`** ở mọi item (vắng mặt, không phải số 0), log WARN; lỗi này không đi qua bảng mã lỗi.

- `GET /feed/following`, `GET /feed/explore`: Bearer JWT; query `cursor` (chuyển nguyên thành `page_token`) và `page_size`; trả `{"items": [...], "next_cursor": ""}`; mỗi item có `video_id`, `author_id`, `title`, `duration_ms`, `playlist_url`, `thumbnail_url`, `published_at` (như schema `Video` của `services/gateway/openapi.yaml`; URL = `MEDIA_PUBLIC_BASE_URL` + `/` + key) và `stats` (`view_count`, `like_count`, `liked_by_me`).
- `PUT`/`DELETE /videos/{video_id}/like` → 204; `POST /videos/{video_id}/views` → 202; lỗi đổi theo [mã lỗi gRPC sang HTTP](../reference/contracts.md#mã-lỗi-grpc-sang-http-ở-gateway) (`RecordView` `UNAVAILABLE` → 503). `/readyz` kiểm thêm feed-service, **không** kiểm engagement-service.
- Biến mới `FEED_SERVICE_ADDR` (mặc định `127.0.0.1:9104`), `ENGAGEMENT_SERVICE_ADDR` (mặc định `127.0.0.1:9103`), mặc định loopback như `USER_SERVICE_ADDR` (IN-2); compose đặt `feed-service:9104`, `engagement-service:9103`. Route mới ghi vào `services/gateway/openapi.yaml` cùng lúc với code.

### 10. Đo độ tươi

Chọn **A**: công cụ `tools/fakefollows` phát `user.followed` vào `user.follows.v1` ở `127.0.0.1:19092` cho N follower giả (UUIDv7 mới) của **một tác giả mới** mỗi lượt đo (không video cũ, nên không backfill); cuối buổi phát `user.unfollowed` cho đúng các id đó. Chỉ chạy trên stack local; comment ghi nó giả danh user-service (IN-4).

- Trước video đầu: chờ `SELECT count(*) FROM follows WHERE followee_id = $author` trên `svp_feed` bằng N (dọn thì chờ về 0). Mỗi video: **bắt đầu** là `published_at` trong `svp_video`; **kết thúc** là `max(created_at)` của N dòng timeline (poll `count(*)` mỗi 100 ms); hai mốc cùng đồng hồ Postgres.
- Số đo: **N = 10.000, 10 video** (số chính, so NFR p95 < 10 s) và **N = 200.000, 3 video** (A7, điểm dữ liệu). Fan-out là một câu trong một transaction nên số dòng nhảy 0 → N lúc commit; số đo không gồm chu kỳ poll hay thời gian đếm.

### 11. Topic và consumer group

Tạo thêm trong `deploy/redpanda/create-topics.sh` (cùng lý do ADR-0008 mục 5): `user.follows.v1` và `engagement.views.v1` (3 partition, replication 1, 7 ngày, `retention.ms=604800000`); `user.follows.v1.dlq` và `engagement.views.v1.dlq` (1 partition, replication 1, 14 ngày, `retention.ms=1209600000`). Group `feed-service` đọc `user.follows.v1`, `video.lifecycle.v1`, ghi DLQ `user.follows.v1.dlq`, `video.lifecycle.v1.dlq`; group `engagement-service` đọc `engagement.views.v1`, ghi `engagement.views.v1.dlq`. 3 partition: tối đa 3 instance song song, key `follower_id` / `video_id` giữ thứ tự theo thực thể.

### 12. Cổng, RAM, database

- `engagement-service` cổng gRPC `9103`, `feed-service` `9104`: không publish ra máy, chỉ trong mạng compose (IN-2); `mem_limit` 256 MB mỗi service. Tổng giới hạn stack ≈ 4,5 GB (redpanda 1,5 GB + minio 512 MB + media-worker 2 GB + hai service mới), dưới ~5 GB trên VM 7,65 GiB.
- Database `svp_engagement`, `svp_feed`, mỗi cái hai role `svp_<svc>_migrator` / `svp_<svc>_app`, tạo bằng `deploy/postgres/bootstrap.sh` (IN-6). Biến `.env` mới: `SVP_ENGAGEMENT_MIGRATOR_DB_PASSWORD`, `SVP_ENGAGEMENT_APP_DB_PASSWORD`, `SVP_FEED_MIGRATOR_DB_PASSWORD`, `SVP_FEED_APP_DB_PASSWORD`.
- Biến của hai service: `LISTEN_ADDR` (mặc định `127.0.0.1:9103` / `127.0.0.1:9104`, loopback khi chạy native; compose đặt `:9103` / `:9104`), `DATABASE_URL`, `KAFKA_BROKERS`; thiếu biến bắt buộc thì thoát ngay với lỗi nêu tên biến (ADR-0007).

### 13. Dependency và contract

**Không thêm dependency** (franz-go, pgx, sqlc, grpc, protobuf kể cả `protowire` đã có). `github.com/twmb/franz-go/pkg/kmsg` v1.14.0 đã ở `go.mod` dạng `// indirect`; kafkax import trực tiếp thì chỉ bỏ chú thích đó. Không dùng `pkg/kadm` (chưa có trong `go.mod`). **Không đổi `proto/`**: contract engagement, feed, user và event đủ cho ADR này.

### 14. Phạm vi phần B

Chọn **B**. Sang [ADR-0010](0010-redis-ratelimit-cache-resilience-stage2c.md): Redis; cache feed khám phá + singleflight (ADR-0005 luật 6); rate limit ở gateway gồm RL-3 và RL-6; timeout, retry, circuit breaker giữa service (ngoài timeout 100 ms của `GetStats` ở mục 9); job dọn upload bỏ dở và UP-7 (hẹn ở ADR-0008 mục 13); k6.

### Hệ quả

- Tốt: follow, unfollow tới feed-service không mất event, đúng thứ tự trong từng cạnh; bộ đếm lượt xem đúng một lần với chi phí chống trùng một dòng mỗi partition, ghi nóng ~1–2 transaction/s thay 10.000 `UPDATE`/s; like thấy ngay, số like đúng tuyệt đối; read model feed chịu event trùng, lệch thứ tự giữa hai topic và nhiều replica; feed vẫn phục vụ khi engagement-service lỗi (trang không có `stats`); độ tươi có số đo ở 10.000 và 200.000 follower.
- Xấu: user-service phụ thuộc Kafka và chạy thêm một relay. Đúng đắn bộ đếm dựa vào offset Kafka ổn định: topic tạo lại mà end offset ≥ `next_offset` lưu trước khi consumer đọc tới thì không phát hiện được, những lượt xem đầu bị bỏ (chỉ ở local sau `make clean-data`). Lô giao lại dưới offset đã lưu tốn thêm một `ListOffsets` trong lúc giữ khoá dòng. Consumer lượt xem và feed thử lại không giới hạn: Postgres lỗi lâu thì partition đứng, lag tăng.
- Xấu (tiếp): fan-out tài khoản lớn giữ khoá tác giả suốt đợt ghi, follow và unfollow tác giả đó chờ theo; job dọn timeline và phép đếm khi đo quét bảng `timeline` (cố ý không có index theo `published_at` hay `video_id`); `hashtextextended` là hàm nội bộ của Postgres, đổi hàm hash là đổi khoá, mọi replica phải đổi cùng lúc; `tools/fakefollows` giả danh user-service và để lại bản sao follow lệch tới khi chạy chế độ dọn. Chưa có Redis, cache, rate limit, breaker, job dọn upload bỏ dở, UP-7 (ADR-0010).
- Xem lại khi: p95 độ tươi ở 200.000 follower vượt 10 s; Redpanda trả topic ID trong fetch (lưu cùng offset); chạy Redpanda nhiều node (kiểm end offset không lùi khi đổi leader); cần phát lại DLQ `user.follows.v1` an toàn; job dọn timeline chạy quá 5 phút (partition `timeline` theo ngày hoặc index BRIN theo `published_at`); lag `engagement-service` vượt 1 phút (tăng lô, thêm instance tối đa 3 partition, hoặc so lại ở lab `hot-counter`); feed p99 vượt 150 ms vì ghép số đếm (xem lại timeout 100 ms và cache số đếm).

## Xác nhận

Đã kiểm ngày 2026-10-11 trước khi quyết (bảng lệnh và kết quả ở phụ lục): cổng 9103, 9104 trống; `go.mod` đủ dependency; API `ListOffsets` và offset khởi đầu của group mới trong franz-go; `hashtextextended` có trong Postgres 15; code hiện có của kafkax và outbox. Sau khi làm: test gom lô, `deploy/compose/smoke.sh`, diễn tập `duplicate-feed-events.sh` (event trùng không đếm hai lần), `engagement-down.sh` (feed vẫn chạy không `stats`), `measure-freshness.sh` (độ tươi ở 10.000 và 200.000 follower).

## Hiện thực ở

- Event follow qua outbox (§1): `services/user-service/internal/server/server.go`, `services/user-service/cmd/user-service/main.go`, `services/user-service/migrations/00003_create_outbox.sql`.
- Like, lượt xem gom theo lô, `GetStats` (§2–§5): `services/engagement-service/` (`internal/server/server.go`, `internal/server/views.go`, `migrations/`, `cmd/engagement-service/main.go`), gom lô ở `internal/kafkax/batch.go`.
- Feed-service (§6–§8, §11): `services/feed-service/` (`migrations/00001_create_feed.sql`, `queries/feed.sql`, `internal/projector/`, `internal/server/`, `cmd/feed-service/main.go`), page token ở `internal/pagetoken/`.
- Gateway ghép số đếm trong 100 ms (§9): `services/gateway/internal/api/api.go`.
- Đo độ tươi (§10; bản đóng băng ở bài lab `drills/` của `svp-labs`, [0050](0050-bash-to-standard-tools.md)): [`tools/fakefollows/`](https://github.com/anhnvcoder/svp-labs/tree/main/drills/svp-backend/tools/fakefollows/), [`deploy/compose/drills/measure-freshness.sh`](https://github.com/anhnvcoder/svp-labs/blob/main/drills/svp-backend/deploy/compose/drills/measure-freshness.sh).
- Topic, cổng, RAM (§11, §12): `deploy/redpanda/create-topics.sh`, `deploy/compose/compose.yaml`; trên k3d `deploy/k8s/values/services/user-service.yaml`, `engagement-service.yaml`, `feed-service.yaml` cùng thư mục.
- Diễn tập: `deploy/compose/smoke.sh`; [`deploy/compose/drills/duplicate-feed-events.sh`](https://github.com/anhnvcoder/svp-labs/blob/main/drills/svp-backend/deploy/compose/drills/duplicate-feed-events.sh), [`deploy/compose/drills/engagement-down.sh`](https://github.com/anhnvcoder/svp-labs/blob/main/drills/svp-backend/deploy/compose/drills/engagement-down.sh) (bản đóng băng ở bài lab `drills/` của `svp-labs`, [0050](0050-bash-to-standard-tools.md)); thí nghiệm cloud `deploy/k8s/cloud/chaos/c-redpanda-failure.yaml`.

## Thông tin thêm

Phụ lục: [`appendix/0009-engagement-feed-stage2b.md`](appendix/0009-engagement-feed-stage2b.md) (trạng thái gốc, bối cảnh đầy đủ, bảng kiểm chứng, phân tích phương án, DDL, các bước và ví dụ đua của §4 và §7, hệ quả đầy đủ).

### Chỉnh bởi

- §9: [0018](0018-web-profiles-public-video-upload.md): ghép thêm tác giả song song với số đếm.
- §4: [0045](0045-bounded-batch-retry.md): retry lượt xem: ngân sách 5 phút rồi DLQ thay thử lại không giới hạn.
