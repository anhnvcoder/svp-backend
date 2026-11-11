# msk-under-min-isr

- Severity: `page`. Alarm CloudWatch `svp-<env>-msk-under-min-isr` của module `msk` (`infra/aws/modules/msk/alarms.tf`), chỉ ở AWS (stg, prd).
- Chuẩn bị biến `ENV`, `N` và hàm `awsx`: [README](README.md#alarm-của-dịch-vụ-managed-rds-msk-elasticache). Mọi lệnh AWS do người học chạy.
  Lệnh Kafka đi qua `svp-kafka` ([ADR-0053](../adr/0053-msk-elasticache-valkey.md) §13) trong Deployment `svp-ops` của namespace `svp-data`
  (context của cluster `$ENV`).

## Ý nghĩa và tác động tới người dùng

`UnderMinIsrPartitionCount` (lấy broker cao nhất) lớn hơn 0, đủ số chu kỳ của [ADR-0058](../adr/0058-managed-data-operations.md) §2 (ngưỡng
và nguồn ở đó): có partition mà số replica đồng bộ (ISR) nhỏ hơn `min.insync.replicas` của topic. Cặp RF/min ISR theo env ở
[ADR-0053](../adr/0053-msk-elasticache-valkey.md) §6 (stg giảm theo [ADR-0055](../adr/0055-environment-matrix.md) §4); alarm kêu khi số
replica mất của một partition lớn hơn RF trừ min ISR.

Partition vẫn có leader và vẫn đọc được, nhưng producer dùng `acks=all` bị từ chối (`NotEnoughReplicas`): các service ghi event bị lỗi, outbox
của chúng đầy dần và event tới consumer chậm hay không tới (video đứng `PROCESSING`, follow không vào feed). Không mất record đã ack: đó là mục đích
của min ISR. Khác [msk-offline-partitions.md](msk-offline-partitions.md): ở đó không có leader và cả đọc lẫn ghi đều dừng.

## Kiểm tra nhanh (5 phút)

Compose, k3d: không có alarm này (một broker); lệnh `svp-kafka` của bước 3 dùng được cả hai.

AWS (người học chạy):

```sh
ARN=$(awsx kafka list-clusters-v2 --cluster-name-filter "$N" --query 'ClusterInfoList[0].ClusterArn' --output text)
# 1. Cluster và broker
awsx kafka describe-cluster-v2 --cluster-arn "$ARN" --query 'ClusterInfo.[State,StateInfo]'
awsx kafka list-nodes --cluster-arn "$ARN" --query 'NodeInfoList[].[BrokerNodeInfo.BrokerId,InstanceType]' --output text
# 2. Under-min-ISR và under-replicated theo broker 3 giờ qua (đổi Broker ID)
awsx cloudwatch get-metric-statistics --namespace AWS/Kafka --metric-name UnderMinIsrPartitionCount --dimensions Name="Cluster Name",Value="$N" Name="Broker ID",Value=1 --start-time "$(date -u -v-3H +%FT%TZ)" --end-time "$(date -u +%FT%TZ)" --period 60 --statistics Maximum --query 'sort_by(Datapoints,&Timestamp)[].[Timestamp,Maximum]' --output text
# 3. Partition nào và ISR hiện tại
kubectl --context <context của cluster $ENV> -n svp-data exec deploy/svp-ops -c kafka -- /opt/svp/bin/svp-kafka topics --describe --under-min-isr-partitions
kubectl --context <context của cluster $ENV> -n svp-data exec deploy/svp-ops -c kafka -- /opt/svp/bin/svp-kafka topics --describe --under-replicated-partitions
# 4. Log broker (nếu bật ở root)
awsx logs tail "/aws/msk/$N" --since 15m
```

Đọc: bước 3 mỗi dòng có `Replicas` và `Isr`; replica có trong `Replicas` mà không trong `Isr` là broker tụt lại hay mất. Cùng một broker thiếu ở nhiều
partition là broker đó (bảo trì, đĩa đầy, CPU); thiếu ngẫu nhiên là tải hay mạng.

## Nguyên nhân thường gặp

1. **Một broker đang khởi động lại hay vá** (`State` không phải `ACTIVE`): ISR tạm hụt, tự về khi broker bắt kịp.
2. **Broker tụt lại vì quá tải** (CPU, đĩa tới sát đầy): [msk-disk-high.md](msk-disk-high.md); alarm `msk-cpu-high`, `msk-under-replicated` (ticket) kêu trước.
3. **Mất AZ** (prd, một broker mỗi AZ): mất một AZ thì ISR vẫn đủ min ISR theo cặp RF/min ISR của prd nên chưa kêu; mất thêm broker thì kêu.
4. **Tải ghi tăng vọt** (burst upload, replay): follower không bắt kịp; ISR hẹp rồi tự phục hồi khi tải giảm.

## Giảm thiểu

- Chờ broker lên khi cluster đang bảo trì (bước 1): không đổi cấu hình cluster trong lúc đó.
- Giảm nguồn ghi nếu tải là nguyên nhân: tạm dừng Job hay replica service đẩy lượng lớn (kubectl của người học, context `$ENV`); consumer vẫn rút được.
- **Không hạ `min.insync.replicas` của topic** để producer chạy lại: nó bỏ đúng bảo đảm mà prd cần (một broker mất nữa là mất record đã ack).
  stg đã ở min ISR thấp nhất ([ADR-0055](../adr/0055-environment-matrix.md) §4), không còn gì để hạ.
- Đĩa đầy: [msk-disk-high.md](msk-disk-high.md).

## Khôi phục và xác nhận

```sh
awsx cloudwatch describe-alarms --alarm-names "$N-msk-under-min-isr" --query 'MetricAlarms[0].StateValue'
kubectl --context <context của cluster $ENV> -n svp-data exec deploy/svp-ops -c kafka -- /opt/svp/bin/svp-kafka topics --describe --under-min-isr-partitions
```

`StateValue` về `OK`, lệnh thứ hai không in partition nào. Rồi outbox của service cạn, lag về 0 theo
[kafka-consumer-lag-high.md](kafka-consumer-lag-high.md), `eks-smoke` do người học chạy.

## Leo thang

- Không hết sau khi cluster về `ACTIVE` quá 30 phút: mở case với AWS Support, ghi topic, partition, `Replicas` và `Isr`.
- Hai broker mất cùng lúc ở prd, hay `msk-offline-partitions` kêu theo: chuyển sang [msk-offline-partitions.md](msk-offline-partitions.md).
- Event bị từ chối quá thời gian giữ của outbox: record có thể mất ở phía service; ghi vào postmortem ([mẫu](../postmortems/README.md)).

## Liên kết

- Dashboard: CloudWatch → Alarms `svp-<env>-msk-under-min-isr`; MSK → cluster → Monitoring; `svp-pipeline`.
- ADR: [ADR-0058](../adr/0058-managed-data-operations.md) §2; [ADR-0053](../adr/0053-msk-elasticache-valkey.md) §6 (RF/min ISR theo env);
  [ADR-0055](../adr/0055-environment-matrix.md) §4.
- Diễn tập: buổi prd "mất broker" của [ADR-0055](../adr/0055-environment-matrix.md) §4.
