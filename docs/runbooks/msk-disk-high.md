# msk-disk-high

- Severity: `page`. Alarm CloudWatch `svp-<env>-msk-disk-high` của module `msk` (`infra/aws/modules/msk/alarms.tf`), chỉ ở AWS (stg, prd).
- Chuẩn bị biến `ENV`, `N` và hàm `awsx`: [README](README.md#alarm-của-dịch-vụ-managed-rds-msk-elasticache). Mọi lệnh AWS do người học chạy.
  Lệnh Kafka đi qua `svp-kafka` ([ADR-0053](../adr/0053-msk-elasticache-valkey.md) §13) trong Deployment `svp-ops` của namespace `svp-data`
  (context của cluster `$ENV`).

## Ý nghĩa và tác động tới người dùng

Đĩa dữ liệu của ít nhất một broker MSK `svp-<env>` (`KafkaDataLogsDiskUsed`, lấy broker cao nhất) vượt ngưỡng, đủ số chu kỳ của
[ADR-0058](../adr/0058-managed-data-operations.md) §2 (ngưỡng và nguồn ở đó). Storage autoscaling kéo đĩa lên khi dùng quá mức đích
(§4); alarm kêu nghĩa là nó không theo kịp, hay đã chạm trần `broker_volume_max_size`, hay đang trong thời gian chờ giữa hai lần tăng (nhịp
tăng tối đa của MSK ở §4).

Broker đầy đĩa thì dừng nhận ghi, rồi lỗi: producer (`outbox-relay` của các service, `media-worker`) bị từ chối, event không tới
consumer, video đứng `PROCESSING`, follow không vào feed ([kafka-consumer-lag-high.md](kafka-consumer-lag-high.md),
[background-loop-stalled.md](background-loop-stalled.md)). Còn dưới 100 % thì mọi thứ vẫn chạy.

## Kiểm tra nhanh (5 phút)

Compose, k3d: không có alarm này (broker local không có đĩa riêng cần theo dõi); lệnh `svp-kafka` của bước 4 dùng được cả hai (compose `dc exec -T kafka`, k3d `kubectl --context k3d-svp`).

AWS (người học chạy):

```sh
ARN=$(awsx kafka list-clusters-v2 --cluster-name-filter "$N" --query 'ClusterInfoList[0].ClusterArn' --output text)
# 1. Trạng thái cluster và dung lượng mỗi broker hiện tại
awsx kafka describe-cluster-v2 --cluster-arn "$ARN" --query 'ClusterInfo.[State,Provisioned.BrokerNodeGroupInfo.StorageInfo.EbsStorageInfo.VolumeSize]'
# 2. Đĩa mỗi broker 3 giờ qua (phần trăm; đổi Broker ID 1, 2, ...)
awsx cloudwatch get-metric-statistics --namespace AWS/Kafka --metric-name KafkaDataLogsDiskUsed --dimensions Name="Cluster Name",Value="$N" Name="Broker ID",Value=1 --start-time "$(date -u -v-3H +%FT%TZ)" --end-time "$(date -u +%FT%TZ)" --period 300 --statistics Maximum --query 'sort_by(Datapoints,&Timestamp)[].[Timestamp,Maximum]' --output text
# 3. Autoscaling đã làm gì
awsx application-autoscaling describe-scaling-activities --service-namespace kafka --resource-id "$ARN" --max-items 5 --query 'ScalingActivities[].[StartTime,StatusCode,Description]' --output text
```

```sh
# 4. Topic nào chiếm chỗ ở broker đầu tiên (byte, 5 topic lớn nhất); svp-kafka tự thêm địa chỉ broker và đăng nhập svp-admin
kubectl --context <context của cluster $ENV> -n svp-data exec deploy/svp-ops -c kafka -- /opt/svp/bin/svp-kafka log-dirs --describe | tail -n 1 | jq -r '[.brokers[0].logDirs[].partitions[] | {t: (.partition | sub("-[0-9]+$"; "")), s: .size}] | group_by(.t) | map({topic: .[0].t, bytes: (map(.s) | add)}) | sort_by(-.bytes) | .[:5][] | "\(.topic) \(.bytes)"'
```

Đọc: bước 1 `VolumeSize` bằng trần của root (`msk_broker_volume_max_size` trong tfvars) là chạm trần; bước 3 có hoạt động `Successful` gần đây nghĩa
là đã tăng và đang chờ lần kế; bước 4 cho topic lớn nhất.

## Nguyên nhân thường gặp

1. **Chạm trần autoscaling** (bước 1): dữ liệu thật sự cần nhiều hơn, hay retention của topic quá dài so với trần.
2. **Đang chờ giữa hai lần tăng** (bước 3): đĩa đầy nhanh hơn nhịp tăng tối đa của MSK (ADR-0058 §4).
3. **Một topic phình bất thường**: consumer không rút (retention không dọn khi segment còn được giữ), hay producer lặp (bước 4, lag cao ở
   [kafka-consumer-lag-high.md](kafka-consumer-lag-high.md)). Retention của topic do `kafka-init` đặt (`deploy/kafka/kafka-init.sh`).
4. **DLQ tích tụ** (`<topic>.dlq`, [kafka-dlq-records.md](kafka-dlq-records.md)): record lỗi không ai xử lý.

## Giảm thiểu

Ghi, người học quyết sau `awsx sts get-caller-identity`:

- **Tăng đĩa ngay** (không chờ autoscaling): `awsx kafka update-broker-storage --cluster-arn "$ARN" --current-version <CurrentVersion của describe-cluster-v2> --target-broker-ebs-volume-info '[{"KafkaBrokerNodeId":"ALL","VolumeSizeGB":<GiB lớn hơn>}]'`.
  Đĩa chỉ tăng, không giảm; sửa `broker_volume_max_size` ở tfvars cho khớp nếu vượt trần ([ADR-0058](../adr/0058-managed-data-operations.md) §4).
  Terraform bỏ qua thay đổi `volume_size`, nên lần `apply` sau không thu nhỏ.
- **Giảm retention của topic lớn nhất** (mất dữ liệu cũ của topic đó, cân với tốc độ consumer): `svp-kafka configs --alter --entity-type topics --entity-name <topic> --add-config retention.ms=<ms>`.
  Giá trị cũ ghi lại để trả về.
- Không xoá topic, không `consumer-groups --reset-offsets` để "lấy chỗ": mất event ([kafka-consumer-lag-high.md](kafka-consumer-lag-high.md)).

## Khôi phục và xác nhận

```sh
awsx cloudwatch describe-alarms --alarm-names "$N-msk-disk-high" --query 'MetricAlarms[0].StateValue'
```

`StateValue` về `OK`, đĩa mọi broker dưới ngưỡng của ADR-0058 §2 ở bước 2 của "Kiểm tra nhanh", `State` của cluster `ACTIVE`. Producer nối lại: lag về 0 theo
[kafka-consumer-lag-high.md](kafka-consumer-lag-high.md), `eks-smoke` do người học chạy.

## Leo thang

- Cluster ở `MAINTENANCE` hay `UPDATING` suốt quá một giờ sau lần tăng đĩa: mở case với AWS Support.
- Đĩa đầy trở lại trong vòng một ngày dù đã tăng: retention hay kích cỡ không khớp tải thật; đo tốc độ ghi, ADR chỉnh `broker_volume_max_size` và
  retention, postmortem ([mẫu](../postmortems/README.md)).
- Đã đầy 100 % và broker offline: chuyển sang [msk-offline-partitions.md](msk-offline-partitions.md).

## Liên kết

- Dashboard: CloudWatch → Alarms `svp-<env>-msk-disk-high`; MSK → cluster → Monitoring; `svp-pipeline` (lag consumer).
- ADR: [ADR-0058](../adr/0058-managed-data-operations.md) §2, §4; [ADR-0053](../adr/0053-msk-elasticache-valkey.md).
- Diễn tập: không có (buổi stg kiểm autoscaling nhận policy trên `kafka.t3.small`, ADR-0058 phần Xác nhận).
