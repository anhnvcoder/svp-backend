# rds-storage-low

- Severity: `page`. Alarm CloudWatch `svp-<env>-rds-storage-low` của module `rds` (`infra/aws/modules/rds/alarms.tf`), chỉ ở AWS (stg, prd).
- Chuẩn bị biến `ENV`, `N` và hàm `awsx`: [README](README.md#alarm-của-dịch-vụ-managed-rds-msk-elasticache). Mọi lệnh AWS do người học chạy.

## Ý nghĩa và tác động tới người dùng

Dung lượng trống của RDS `svp-<env>` (`FreeStorageSpace`, thấp nhất trong chu kỳ) dưới ngưỡng phần trăm của dung lượng cấp phát, đủ số chu kỳ
của [ADR-0058](../adr/0058-managed-data-operations.md) §2. Cửa sổ của alarm dài hơn cửa sổ kích của storage autoscaling, nên alarm chỉ kêu khi
autoscaling không tăng được: đã chạm trần `max_allocated_storage`, hay đang trong thời gian chờ giữa hai lần tăng, hay thiếu quyền (số và lý do:
[ADR-0057](../adr/0057-postgres17-verify-full.md) §5, [ADR-0058](../adr/0058-managed-data-operations.md) §3).

Hết đĩa thì RDS chuyển sang `storage-full` và ngừng nhận kết nối ghi: bốn service có Postgres (user, video, engagement, feed) và GlitchTip lỗi,
gateway trả 5xx cho mọi request cần chúng. Khi còn trống thì mọi thứ vẫn chạy: đây là báo trước.

## Kiểm tra nhanh (5 phút)

Compose, k3d: không có (đĩa của container `postgres` và PVC của CNPG không có alarm này).

AWS (người học chạy):

```sh
# 1. Trạng thái, dung lượng cấp, trần autoscaling
awsx rds describe-db-instances --db-instance-identifier "$N" --query 'DBInstances[0].[DBInstanceStatus,AllocatedStorage,MaxAllocatedStorage,StorageType]'
# 2. Dung lượng trống 3 giờ qua (byte, theo 5 phút)
awsx cloudwatch get-metric-statistics --namespace AWS/RDS --metric-name FreeStorageSpace --dimensions Name=DBInstanceIdentifier,Value="$N" --start-time "$(date -u -v-3H +%FT%TZ)" --end-time "$(date -u +%FT%TZ)" --period 300 --statistics Minimum --query 'sort_by(Datapoints,&Timestamp)[].[Timestamp,Minimum]' --output text
# 3. Autoscaling đã tăng chưa, hay RDS ghi lỗi gì
awsx rds describe-events --source-type db-instance --source-identifier "$N" --duration 1440 --query 'Events[].[Date,Message]' --output text
# 4. WAL, slot replication giữ đĩa (RDS không có replica thì slot do chính người học tạo, thường là không có)
awsx cloudwatch get-metric-statistics --namespace AWS/RDS --metric-name TransactionLogsDiskUsage --dimensions Name=DBInstanceIdentifier,Value="$N" --start-time "$(date -u -v-3H +%FT%TZ)" --end-time "$(date -u +%FT%TZ)" --period 300 --statistics Maximum --query 'sort_by(Datapoints,&Timestamp)[].[Timestamp,Maximum]' --output text
# 5. Log PostgreSQL gần đây (tham số ghi log: ADR-0057 §6)
awsx logs tail "/aws/rds/instance/$N/postgresql" --since 1h
```

Đọc: bước 1 `AllocatedStorage` bằng `MaxAllocatedStorage` là chạm trần; bước 3 có dòng nói về storage autoscaling thì autoscaling đã chạy (lần tăng
kế phải chờ); bước 2 dốc xuống đều là dữ liệu ghi nhiều, dốc đứng là một thao tác lớn (index, bảng tạm, `COPY`). Console: RDS → `svp-<env>` →
Monitoring (Database Insights) cho câu lệnh nặng.

## Nguyên nhân thường gặp

1. **Chạm trần `max_allocated_storage`** (bước 1 hai số bằng nhau): dữ liệu thật sự lớn hơn dự tính, hay một bảng phình (outbox không dọn,
   `engagement` ghi lượt xem).
2. **Đang chờ giữa hai lần tăng**: autoscaling chỉ tăng lại sau thời gian chờ của RDS kể từ lần chỉnh dung lượng trước (nguồn ở
   [ADR-0058](../adr/0058-managed-data-operations.md) §3); bước 3 thấy lần tăng gần đây.
3. **File tạm hay WAL lớn** (bước 4 cao, log có `temporary file`): câu lệnh sort hay hash tràn `work_mem`, migrate tạo index trên bảng lớn.
4. **Dữ liệu chết chưa được dọn**: autovacuum chạy chậm (log `automatic vacuum` dài, [rds-txid-wraparound.md](rds-txid-wraparound.md)).

## Giảm thiểu

Chỉ tăng đĩa mới cứu ngay được; xoá dữ liệu không nhanh hơn và autovacuum không trả đĩa cho OS. Bước ghi, người học quyết sau
`awsx sts get-caller-identity`:

- **Tăng trần và cấp phát ngay**: đặt `max_allocated_storage` (tfvars của root, theo quy tắc trần so với mức cấp của ADR-0057 §5) rồi `apply` ở
  `infra/aws/envs/<env>`; cần ngay thì `awsx rds modify-db-instance --db-instance-identifier "$N" --allocated-storage <GiB> --max-allocated-storage <GiB> --apply-immediately`
  rồi sửa tfvars cho khớp. Sau lần chỉnh này RDS buộc chờ trước lần chỉnh kế (cả lần của autoscaling), và dung lượng không bao giờ giảm.
- Dừng nguồn ghi nếu đĩa sắp hết trước khi kịp tăng: giảm replica của service ghi nhiều hay tạm dừng Job migrate đang chạy
  (`kubectl` với context của cluster `$ENV`, người học chạy).
- Không xoá hàng tay để lấy chỗ: ghi bù (WAL) lớn hơn chỗ lấy lại, và mất dữ liệu.

## Khôi phục và xác nhận

```sh
awsx rds describe-db-instances --db-instance-identifier "$N" --query 'DBInstances[0].[DBInstanceStatus,AllocatedStorage]'
awsx cloudwatch describe-alarms --alarm-names "$N-rds-storage-low" --query 'MetricAlarms[0].StateValue'
```

Trạng thái `available`, `StateValue` về `OK` (email OK tới cùng đích với email ALARM), và dung lượng trống trên ngưỡng của ADR-0058 §2 ở bước 2 của "Kiểm tra
nhanh". Service nối lại: dashboard `svp-slo` không còn cháy, `make k8s-smoke` tương đương ở EKS là `eks-smoke` do người học chạy.

## Leo thang

- Trạng thái `storage-full`: instance không ghi được, tăng dung lượng ngay (Giảm thiểu), không reboot. `storage-optimization`: RDS đang
  tối ưu sau lần tăng, instance vẫn dùng được; chờ. Một trong hai kéo dài quá một giờ thì mở case với AWS Support.
- Dung lượng tăng liên tục mà không có thao tác lớn: nghi một bảng phình (outbox không dọn). Điều tra ở service sở hữu bảng, mở postmortem
  ([mẫu](../postmortems/README.md)).
- Chạm trần ở prd mà dữ liệu hợp lệ: đây là quyết định kích cỡ (đổi trần, hay lưu trữ lâu hơn ở chỗ khác), ghi ADR chỉnh 0057 §5.
- Snapshot cuối và backup tự động mã hoá bằng CMK của module: xem README module `rds` về lịch xoá key sau `destroy`.

## Liên kết

- Dashboard: CloudWatch → Alarms `svp-<env>-rds-storage-low`; RDS → Monitoring (Database Insights); `svp-slo` (ảnh hưởng người dùng).
- ADR: [ADR-0057](../adr/0057-postgres17-verify-full.md) §5; [ADR-0058](../adr/0058-managed-data-operations.md) §2, §3.
- Diễn tập: không có (không tái hiện được hết đĩa ở stg có chủ đích; buổi stg kiểm bằng `set-alarm-state` tới email, ADR-0058 phần Xác nhận).
