# 0045. Consumer theo lô thử lại trong ngân sách 5 phút rồi chép cả lô sang DLQ; consumer feed giữ thử lại không giới hạn

- Trạng thái: Chấp nhận
- Ngày: 2026-11-02
- Người quyết: AI đề xuất, người học uỷ quyền

## Bối cảnh và vấn đề

[0003](0003-async-events-outbox.md) luật 2: lỗi tạm thì thử lại có backoff, **giới hạn số lần**, hết lượt thì sang `<topic>.dlq`. Hai consumer
không theo luật đó, đều có lý do ở [0009](0009-engagement-feed-stage2b.md):

- `kafkax.BatchConsumer`, chỉ consumer lượt xem của engagement-service dùng: lỗi tạm thì thử lại **cả lô** với backoff 0,5 s → trần 10 s,
  không giới hạn, vì "đẩy lô sang DLQ là mất lượt xem".
- Projector của feed-service (`kafkax.Consumer` với `MaxAttempts = math.MaxInt`): giữ thứ tự follow/unfollow của một cạnh.

`kafkax.Consumer` của video-service (mặc định 5 lần) và media-worker (10 lần, backoff 1 s → 1 phút) đã có giới hạn rồi DLQ
`retries-exhausted`. Thử lại không giới hạn của consumer lượt xem có một kẽ hở: lỗi mà handler coi là tạm nhưng lặp lại mãi với đúng lô đó
(một lô độc: lỗi code, câu lệnh quá hạn vì lô) chặn partition vô thời hạn, lag tăng mãi. Lý do "mất lượt xem" cũng không còn đúng nếu DLQ
phát lại được về topic gốc mà đếm đúng một lần (mục 3 dưới đây).

## Yếu tố quyết định

- Không partition nào bị chặn vô thời hạn; không mất lượt xem; phát lại đếm đúng một lần.
- Không tự gửi vào DLQ vì một lần chập chờn ngắn (phát lại là việc tay).
- Thứ tự trong một key giữ nguyên ở consumer cần thứ tự.

## Phương án đã cân nhắc

Trạng thái ngành đọc ngày 2026-11-02 từ nguồn ở mục Nguồn.

| Phương án | Trạng thái | Nguồn | Ghi chú |
| --- | --- | --- | --- |
| A. Thử lại cả lô không giới hạn (như hiện nay) | hiện hành ("stop on error") | [N3] | Lô độc chặn partition mãi |
| B. Thử lại trong ngân sách, hết thì chép cả lô sang DLQ, commit, phát lại tay về topic gốc | hiện hành | [N3][N4] | Partition tiến; phát lại là việc tay |
| C. Retry topic không chặn (Uber 2018, Spring `@RetryableTopic`) rồi DLQ | hiện hành | [N1][N2] | Spring: "Non-blocking retries are not supported with Batch Listeners"; mất thứ tự |
| D. Hết ngân sách thì commit bỏ lô, không DLQ | cũ, không chấp nhận | — | Mất lượt xem |

## Kết quả quyết định

Chọn **B** cho `BatchConsumer`; feed giữ **A** như một ngoại lệ có chủ ý.

1. **Ngân sách theo thời gian, 5 phút.** `BatchConsumerConfig` có field ngân sách thử (mặc định 5 phút), tính từ lần thử đầu tiên lỗi của lô:
   không bắt đầu lần thử nào khi thời gian đã qua cộng lần chờ kế tiếp vượt ngân sách. Backoff giữ nguyên (0,5 s nhân đôi tới trần 10 s, ngẫu
   nhiên 50–100 %), nên 5 phút là khoảng 30–65 lần nếu mỗi lần lỗi nhanh; mỗi lần còn bị `HandlerTimeout` cắt (lượt xem: 30 s), nên lô giữ
   partition tối đa ~5,5 phút. `ViewsConsumerConfig` đặt rõ 5 phút.
   - Chọn thời gian, không số lần: một lần thử tốn từ vài mili giây (database từ chối kết nối) tới 30 s (quá hạn), nên cùng một số lần là từ
     vài phút tới hàng chục phút; thời gian nói thẳng sự cố dài bao lâu thì tự khỏi. `kafkax.Consumer` giữ `MaxAttempts`.
   - 5 phút: dài hơn sự cố ngắn thường gặp (Postgres khởi động lại, CloudNativePG đổi primary; thời gian chưa đo trên bản này); cảnh báo
     `KafkaConsumerLagHigh` (page sau 2 phút lag) báo trước khoảng 3 phút, người trực thấy sự cố trước khi record vào DLQ; lô độc chặn
     partition tối đa ~5,5 phút thay vì mãi mãi.
   - Ngân sách vượt `RebalanceTimeout` mặc định 60 s của consumer theo lô: rebalance xảy ra giữa lúc thử thì thành viên bị loại, như
     [0009](0009-engagement-feed-stage2b.md) đã chấp nhận (đúng đắn dựa vào offset trong database).
2. **Hết ngân sách.** Chép **mọi** record của lô sang `<topic>.dlq` với `dlq-reason=retries-exhausted` và các header `dlq-*` như `Consumer` (dùng
   chung code dead-letter), tăng `svp_kafka_dlq_records_total` (cảnh báo `KafkaDLQRecords` page), commit, **rồi** ghi một dòng log ERROR cho cả
   lô: số record, lỗi cuối, khoảng offset của từng partition. Produce DLQ hay commit lỗi → `Run` trả lỗi, lô không commit. Context huỷ giữa
   chừng → không DLQ, không commit.
3. **Phát lại đếm đúng một lần.** Lượt xem là phép cộng giao hoán, không cần thứ tự. Record phát lại từ `engagement.views.v1.dlq` về
   `engagement.views.v1` có offset mới, lớn hơn `next_offset` trong `consumer_offsets` (offset không tiến khi lô lỗi), nên được cộng đúng một
   lần. Luật cho runbook `docs/runbooks/kafka-dlq-records.md`:
   - chỉ phát lại sau khi nguyên nhân đã hết, chỉ record `dlq-reason=retries-exhausted` (record `permanent` là payload hỏng);
   - giữ nguyên byte của key, value (protobuf nhị phân) và header `event-type`;
   - chỉ record có offset gốc (`dlq-partition`, `dlq-offset`) nằm trong khoảng của một dòng log ở mục 2, và bỏ trùng theo (`dlq-topic`,
     `dlq-partition`, `dlq-offset`). Lý do: chép DLQ xong mà commit hỏng hay pod chết trước commit thì lô được giao lại và có thể được cộng (hay vào
     DLQ lần nữa); dòng log chỉ có sau commit, nên lô đã được cộng không bao giờ có dòng log, lô vào DLQ hai lần thì bỏ trùng. Không còn dòng
     log (Loki đã xoá) thì không phát lại: thiếu còn hơn đếm hai lần;
   - DLQ giữ 14 ngày, đó là hạn phát lại.
4. **Retry topic (C) bị loại** cho consumer theo lô: Spring Kafka không hỗ trợ nó với batch listener [N1]; lỗi của lượt xem là lỗi cả database
   nên record ở retry topic cũng lỗi, chỉ dời chỗ chờ; mỗi cấp chờ thêm một topic và một consumer.
5. **Feed giữ thử lại không giới hạn** (ngoại lệ có chủ ý của luật 2 của [0003](0003-async-events-outbox.md)): follow, unfollow của một cạnh cùng
   key phải áp đúng thứ tự; DLQ hay retry topic tách một event khỏi dòng của key, phát lại sau đó dựng lại cạnh đã unfollow (giới hạn đã biết ở
   [0009](0009-engagement-feed-stage2b.md)); Spring nói thẳng retry topic làm "lose Kafka's ordering guarantees" [N2], Confluent cũng vậy [N3].
   Sự cố dài được thấy qua `KafkaConsumerLagHigh`, không qua DLQ.
6. **Mỗi consumer có test nhận cùng event hai lần**, trạng thái không đổi ([0003](0003-async-events-outbox.md) đã đòi); danh sách ở Hiện thực ở.

### Hệ quả

- Tốt: không partition nào chặn quá ~5,5 phút ngoài feed; lượt xem không mất (DLQ 14 ngày, phát lại đếm một lần).
- Xấu: sự cố database dài hơn 5 phút chuyển lượt xem sang DLQ từng lô một; số đếm thiếu cho tới khi người trực phát lại theo runbook.
- Xấu: luật phát lại dựa vào dòng log; mất log thì phần đó không phát lại được (thiếu, không thừa).
- Xấu: hai kiểu giới hạn trong `kafkax` (thời gian cho lô, số lần cho từng record).
- Xem lại khi: có consumer theo lô thứ hai; sự cố thật cho thấy 5 phút ngắn hay dài; feed cần phát lại DLQ an toàn (tombstone cạnh kèm
  `occurred_at`, như [0009](0009-engagement-feed-stage2b.md) đã ghi).

## Xác nhận

Test kfake của `internal/kafkax`: handler lỗi mãi → sau ngân sách mọi record ở DLQ với header đúng, offset đã commit, metric tăng; lỗi rồi được
trước khi hết ngân sách → không gì vào DLQ; context huỷ giữa lúc thử → không DLQ, không commit; record bị từ chối vĩnh viễn trong lô thành
công vẫn `permanent`. Test của engagement-service: ngân sách của consumer lượt xem. Chưa kiểm lúc chấp nhận: các việc trên làm cùng phần hiện
thực; lệnh phát lại của runbook chưa chạy trên Redpanda.

## Ưu nhược từng phương án

- A: tốt là không bao giờ cần phát lại; xấu là lô độc chặn partition mãi, chỉ lag báo.
- B: như Kết quả quyết định và Hệ quả.
- C: tốt là partition không chặn khi lỗi theo record; xấu là không hợp consumer theo lô, mất thứ tự, thêm topic và consumer.
- D: xấu là mất lượt xem, không ai biết.

## Hiện thực ở

- `internal/kafkax/batch.go` (ngân sách, chép cả lô sang DLQ, dòng log sau commit), `batch_test.go`; `consumer.go` (code dead-letter
  dùng chung, không đổi).
- `services/engagement-service/internal/server/views.go` (`ViewsConsumerConfig`), `views_test.go` (`TestViewsConsumerConfigBoundsRetries`).
- `docs/runbooks/kafka-dlq-records.md` (phát lại DLQ lượt xem theo mục 3).
- Test nhận cùng event hai lần, theo consumer:
  - feed-service projector (`user.follows.v1`, `video.lifecycle.v1`): `services/feed-service/internal/projector/projector_test.go`
    (`TestVideoReadyTwiceKeepsFirst`, `TestReplayFollowUnfollowFollow`, `TestSameRecordTwiceChangesNothing`,
    `TestOldFollowReplayedAfterUnfollowRestoresEdge`);
  - video-service transcode (`media.transcodes.v1`): `services/video-service/internal/server/transcode_test.go`
    (`TestTranscodeCompletedTwiceEmitsOnce`, `TestTranscodeCompletedAfterFailedDeletesFilesAgain`, `TestSameTranscodeRecordTwiceChangesNothing`);
  - media-worker (`video.lifecycle.v1`, `video.uploaded`): `services/media-worker/internal/worker/worker_test.go`
    (`TestHandleValidUploadTwiceGivesSameResult`, `TestHandleRedeliveryAfterMasterPublishesStoredResult`,
    `TestHandleFailedUploadTwiceGivesSameResult`, `TestHandleOtherLifecycleEventsTwiceDoNothing`);
  - engagement-service lượt xem (`engagement.views.v1`): `services/engagement-service/internal/server/views_test.go`
    (`TestRedeliveredBatchCountsOnce`, `TestShorterRedeliveryKeepsNextOffset`).

## Nguồn

Truy cập 2026-11-02.

- [N1] Spring for Apache Kafka 4.1.2: [Non-Blocking Retries](https://docs.spring.io/spring-kafka/reference/retrytopic.html) ("Non-blocking
  retries are not supported with Batch Listeners").
- [N2] Spring for Apache Kafka: [How the Pattern Works](https://docs.spring.io/spring-kafka/reference/retrytopic/how-the-pattern-works.html)
  ("By using this strategy you lose Kafka's ordering guarantees for that topic").
- [N3] Gerardo Villeda, Confluent: [Error Handling Patterns for Apache Kafka Applications](https://www.confluent.io/blog/error-handling-patterns-in-kafka/)
  (2021-05-21): stop on error, dead letter queue, retry topic, giữ thứ tự.
- [N4] Ning Xia, Uber: [Building Reliable Reprocessing and Dead Letter Queues with Apache Kafka](https://www.uber.com/US/en/blog/reliable-reprocessing/)
  (2018-02-16).
