# msk-offline-partitions

- Severity: `page`. Alarm CloudWatch `svp-<env>-msk-offline-partitions` của module `msk` (`infra/aws/modules/msk/alarms.tf`), chỉ ở AWS (stg, prd).
- Chuẩn bị biến `ENV`, `N` và hàm `awsx`: [README](README.md#alarm-của-dịch-vụ-managed-rds-msk-elasticache). Mọi lệnh AWS do người học chạy.
  Lệnh Kafka đi qua `svp-kafka` ([ADR-0053](../adr/0053-msk-elasticache-valkey.md) §13) trong Deployment `svp-ops` của namespace `svp-data`
  (context của cluster `$ENV`).

## Ý nghĩa và tác động tới người dùng

`OfflinePartitionsCount` của MSK `svp-<env>` lớn hơn 0 ở một điểm (ngưỡng và nguồn: [ADR-0058](../adr/0058-managed-data-operations.md) §2): có
partition không còn leader, nên không ai ghi hay đọc được partition đó. Điều này xảy ra khi mọi replica của partition cùng mất (broker chết, đĩa
hỏng, hay RF thấp: RF theo env ở [ADR-0053](../adr/0053-msk-elasticache-valkey.md) §6, stg giảm theo [ADR-0055](../adr/0055-environment-matrix.md)
§4), nên một điểm đủ để báo.

Người dùng thấy: các việc qua topic có partition đó đứng. Producer (`outbox-relay`, `media-worker`) lỗi hay chờ, consumer không nhận record, nên video
đứng `PROCESSING`, follow và lượt xem không tới feed và `stats`. Partition khác của cùng topic vẫn chạy, nên triệu chứng có thể lẻ tẻ theo khoá.

## Kiểm tra nhanh (5 phút)

Compose, k3d: không có alarm này (một broker, mất là mất cả stack); lệnh `svp-kafka` của bước 3 dùng được cả hai.

AWS (người học chạy):

```sh
ARN=$(awsx kafka list-clusters-v2 --cluster-name-filter "$N" --query 'ClusterInfoList[0].ClusterArn' --output text)
# 1. Cluster ACTIVE hay đang bảo trì, vá lỗi; broker nào còn
awsx kafka describe-cluster-v2 --cluster-arn "$ARN" --query 'ClusterInfo.[State,StateInfo]'
awsx kafka list-nodes --cluster-arn "$ARN" --query 'NodeInfoList[].[BrokerNodeInfo.BrokerId,BrokerNodeInfo.ClientVpcIpAddress,InstanceType]' --output text
# 2. Số partition offline và cùng lúc đĩa, CPU từng broker (đổi Broker ID)
awsx cloudwatch get-metric-statistics --namespace AWS/Kafka --metric-name OfflinePartitionsCount --dimensions Name="Cluster Name",Value="$N" --start-time "$(date -u -v-3H +%FT%TZ)" --end-time "$(date -u +%FT%TZ)" --period 60 --statistics Maximum --query 'sort_by(Datapoints,&Timestamp)[].[Timestamp,Maximum]' --output text
awsx cloudwatch get-metric-statistics --namespace AWS/Kafka --metric-name KafkaDataLogsDiskUsed --dimensions Name="Cluster Name",Value="$N" Name="Broker ID",Value=1 --start-time "$(date -u -v-3H +%FT%TZ)" --end-time "$(date -u +%FT%TZ)" --period 300 --statistics Maximum --output text
# 3. Partition nào, replica nào còn
kubectl --context <context của cluster $ENV> -n svp-data exec deploy/svp-ops -c kafka -- /opt/svp/bin/svp-kafka topics --describe --unavailable-partitions
# 4. Log broker (nếu bật ở root), ~15 phút gần nhất
awsx logs tail "/aws/msk/$N" --since 15m
```

Đọc: bước 1 `State` khác `ACTIVE` (`MAINTENANCE`, `REBOOTING_BROKER`) là MSK đang vá hay thay broker, và số partition offline thường tự về 0 khi
broker lên; thiếu một broker trong `list-nodes` hay bước 2 đĩa đầy là nguyên nhân chủ động; bước 3 cho biết `Leader: none` và `Isr` rỗng của từng
partition.

## Nguyên nhân thường gặp

1. **Broker đang khởi động lại** (vá, bảo trì, thay instance): `State` `REBOOTING_BROKER`. Partition mà replica cuối còn lại nằm trên broker đó
   (replica kia đã rời ISR trước) offline tới khi broker lên; tự hết.
2. **Đĩa broker đầy** ([msk-disk-high.md](msk-disk-high.md)): broker dừng, replica của nó rời ISR.
3. **Mất nhiều broker hay cả AZ hơn RF chịu được** (`list-nodes` thiếu broker): RF stg thấp hơn prd, nên ở stg mất một broker khi replica kia đã
   tụt ISR là offline; ở prd phải mất mọi replica của partition.
4. **Lỗi mạng giữa client và broker**: không gây offline partition, nhưng cùng triệu chứng người dùng: nếu `OfflinePartitionsCount` bằng 0
   thì đây không phải alarm này.

## Giảm thiểu

- Chờ MSK tự phục hồi khi `State` là bảo trì (bước 1): không xoá, không đổi cấu hình cluster trong lúc đó. Mọi cập nhật cluster bị từ chối khi nó
  đang bận.
- Đĩa đầy: làm theo [msk-disk-high.md](msk-disk-high.md) trước.
- **Không bật `unclean.leader.election.enable`** để ép partition có leader: nó chọn replica lệch ISR làm leader và **mất record đã ack**; đây là
  quyết định leo thang, không phải giảm thiểu.
- Producer không nên bị restart hàng loạt: chúng tự thử lại; restart chỉ thêm tải lên broker vừa lên (kiểm theo
  [kafka-consumer-lag-high.md](kafka-consumer-lag-high.md) sau khi partition có leader).

## Khôi phục và xác nhận

```sh
awsx cloudwatch describe-alarms --alarm-names "$N-msk-offline-partitions" --query 'MetricAlarms[0].StateValue'
kubectl --context <context của cluster $ENV> -n svp-data exec deploy/svp-ops -c kafka -- /opt/svp/bin/svp-kafka topics --describe --unavailable-partitions
```

`StateValue` về `OK`, lệnh thứ hai không in partition nào, `State` `ACTIVE`. Rồi lag về 0 theo [kafka-consumer-lag-high.md](kafka-consumer-lag-high.md)
và `eks-smoke` do người học chạy; outbox của các service ghi bù những event kẹt trong lúc offline.

## Leo thang

- Partition vẫn offline sau 30 phút kể từ khi cluster về `ACTIVE`: mở case với AWS Support; ghi lại topic, partition và broker cuối của ISR.
- Ép leader bằng `unclean.leader.election.enable` (mất record) chỉ khi chấp nhận mất và ghi lại topic, offset, thời điểm vào postmortem
  ([mẫu](../postmortems/README.md)).
- Mất một broker ở prd làm partition offline: cấu hình RF/ISR hay vị trí replica sai so với [ADR-0053](../adr/0053-msk-elasticache-valkey.md)
  §6, ADR chỉnh 0053; buổi prd có phép kiểm "mất broker" ([ADR-0055](../adr/0055-environment-matrix.md) §4).

## Liên kết

- Dashboard: CloudWatch → Alarms `svp-<env>-msk-offline-partitions`; MSK → cluster → Monitoring; `svp-pipeline`.
- ADR: [ADR-0058](../adr/0058-managed-data-operations.md) §2; [ADR-0053](../adr/0053-msk-elasticache-valkey.md) §6 (RF/min ISR theo env);
  [ADR-0055](../adr/0055-environment-matrix.md) §4.
- Diễn tập: buổi prd "mất broker" của [ADR-0055](../adr/0055-environment-matrix.md) §4.
