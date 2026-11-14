# 0058. RDS, MSK, ElastiCache có CloudWatch alarm gửi SNS mã hoá CMK tới email, ngưỡng theo khuyến nghị của AWS; MSK tự tăng dung lượng broker; ElastiCache chờ cửa sổ bảo trì ở prd và gửi slow-log tới CloudWatch Logs

- Trạng thái: Chấp nhận
- Ngày: 2026-11-11
- Người quyết: người học (alarm managed bằng CloudWatch: duyệt cùng kế hoạch), AI đề xuất bảng alarm và số theo khuyến nghị của AWS

## Bối cảnh và vấn đề

- Cảnh báo hiện có đều ở Prometheus trong cluster ([0011](0011-observability-stage3.md), [0020](0020-reliability-stage6.md)); RDS, MSK,
  ElastiCache ([0034](0034-aws-stage7.md), [0053](0053-msk-elasticache-valkey.md)) không có alarm nào: đĩa broker đầy, storage RDS cạn, bộ nhớ Valkey
  đầy (`noeviction` làm lệnh ghi lỗi) không ai được báo.
- Dung lượng broker MSK cố định 10 GiB; ElastiCache áp mọi thay đổi ngay (`apply_immediately = true` cố định), không slow-log.
- [0055](0055-environment-matrix.md) §2 xếp bộ alarm và slow-log vào nhóm phải giống, §4 xếp `apply_immediately` stg vào nhóm giảm có điều kiện.

## Yếu tố quyết định

- Alarm của dịch vụ dữ liệu phải sống khi cluster EKS chết (chính lúc đó cần nhất).
- Ngưỡng có nguồn: trang "Recommended alarms" của CloudWatch [N1], best practices của MSK [N2]; mỗi alarm `page` có runbook.
- Không thêm thành phần tự vận hành chỉ để báo; chi phí theo buổi nhỏ.

## Phương án đã cân nhắc

Trạng thái ngành, được, mất: [phụ lục](appendix/0058-managed-data-operations.md#phương-án).

- **CloudWatch alarm → SNS → email**: dịch vụ AWS, sống độc lập với cluster; ngưỡng, tên ở Terraform cùng tài nguyên.
- Exporter (YACE hay `cloudwatch_exporter`) vào Prometheus của cluster, rule và Alertmanager như cảnh báo khác: một chỗ xem, nhưng cluster chết là
  mất alarm; trả phí `GetMetricData` mỗi lần scrape.
- Cả hai: alarm ở CloudWatch, metric cũng vào Grafana qua exporter: để sau, khi cần dashboard chung.

## Kết quả quyết định

Chọn CloudWatch alarm → SNS → email, vì chỉ cách này sống khi cluster chết và không thêm thành phần.

### 1. Tên, mức, đích

- Tên `svp-<env>-<alarm>`; tag `Severity=page|ticket`. Alarm `page` có `alarm_description` chứa
  `https://github.com/anhnvcoder/svp-backend/blob/main/docs/runbooks/<alarm>.md`, runbook cùng tên.
- `alarm_actions` và `ok_actions` tới SNS topic `svp-<env>-alarms` của module `alarms`: KMS key customer managed của module (alias
  `alias/svp-<env>-alarms`, rotation bật, 7 ngày), key policy thêm `kms:Decrypt`, `kms:GenerateDataKey*` cho `cloudwatch.amazonaws.com` với điều
  kiện `aws:SourceAccount` [N3]; subscription email từ biến `alarm_email` (không commit), người học xác nhận email.
- Alarm của mỗi dịch vụ ở module của dịch vụ đó (biến `alarm_topic_arn`). Metric theo broker hay theo node gộp thành một alarm bằng metric math
  `MAX` (tối đa 10 metric mỗi alarm [N4]): một alarm mỗi loại, tên không đổi theo số broker.
- Chu kỳ 60 s ở mọi alarm; `treat_missing_data` mặc định (`missing`). Cùng bộ ở stg và prd.

### 2. Bảng alarm

`N/M`: N điểm vượt trong M chu kỳ 60 s. Nguồn: [N1] cho RDS, ElastiCache (trang không có mục MSK), [N2] cho MSK.

| `<alarm>` | Dịch vụ, metric | Thống kê | Ngưỡng | N/M | Mức |
| --- | --- | --- | --- | --- | --- |
| `rds-storage-low` | RDS `FreeStorageSpace` | Minimum | < 10 % `allocated_storage` | 15/15 | page |
| `rds-txid-wraparound` | RDS `MaximumUsedTransactionIDs` | Average | > 1 000 000 000 | 1/1 | page |
| `rds-cpu-high` | RDS `CPUUtilization` | Average | > 90 % | 5/5 | ticket |
| `rds-memory-low` | RDS `FreeableMemory` | Average | < 25 % bộ nhớ lớp (stg 512 MiB, prd 2 GiB) | 15/15 | ticket |
| `rds-connections-high` | RDS `DatabaseConnections` | Average | > 90 % `max_connections`: stg 186, prd 745 (§3) | 5/5 | ticket |
| `rds-db-load-high` | RDS `DBLoad` | Average | > 2 (số vCPU của lớp, cả hai env) | 15/15 | ticket |
| `rds-read-latency-high` | RDS `ReadLatency` | p90 | > 0,02 s | 5/5 | ticket |
| `rds-write-latency-high` | RDS `WriteLatency` | p90 | > 0,02 s | 5/5 | ticket |
| `msk-disk-high` | MSK `KafkaDataLogsDiskUsed`, `MAX` các broker | Maximum | ≥ 85 % | 5/5 | page |
| `msk-offline-partitions` | MSK `OfflinePartitionsCount` | Maximum | > 0 | 1/1 | page |
| `msk-under-min-isr` | MSK `UnderMinIsrPartitionCount`, `MAX` các broker | Maximum | > 0 | 5/5 | page |
| `msk-under-replicated` | MSK `UnderReplicatedPartitions`, `MAX` các broker | Maximum | > 0 | 15/15 | ticket |
| `msk-cpu-high` | MSK `CpuUser` + `CpuSystem`, `MAX` các broker | Average | > 60 % | 15/15 | ticket |
| `msk-heap-high` | MSK `HeapMemoryAfterGC`, `MAX` các broker | Average | > 60 % | 5/5 | ticket |
| `valkey-memory-high` | ElastiCache `DatabaseMemoryUsagePercentage`, `MAX` các node | Average | > 80 % | 5/5 | page |
| `valkey-engine-cpu-high` | ElastiCache `EngineCPUUtilization`, `MAX` các node | Average | > 90 % | 5/5 | ticket |

### 3. Ngưỡng lệch hay chưa có số trong nguồn

- `rds-storage-low`: 15/15 thay 5/5 của [N1], vì storage autoscaling (0057 §5) kích khi còn ≤ 10 % trong 5 phút [N5]; alarm chỉ kêu khi tăng
  không xảy ra (chạm trần, đã tăng bốn lần trong 24 giờ). Ngưỡng tính theo `allocated_storage` lúc apply.
- `rds-memory-low`, `rds-db-load-high`: [N1] ghi "tuỳ tình huống", đề xuất 25 % bộ nhớ và số vCPU: lấy đúng các mức đó.
- `rds-connections-high`: 90 % của `max_connections` mặc định, `LEAST(DBInstanceClassMemory/9531392, 5000)` [N6]. `DBInstanceClassMemory` là bộ
  nhớ lớp trừ phần hệ thống giữ, ~92 % ở ví dụ lớp 8 GiB của [N6]: prd ~831 → 745, stg ~207 → 186. Lớp T giữ phần lớn hơn, nên buổi stg đọc
  `SHOW max_connections` và sửa số của stg nếu lệch.
- `valkey-memory-high`: [N1] để ngưỡng cho ứng dụng; 80 % vì `noeviction` làm lệnh ghi lỗi ở 100 % (rate limit, session).
- `msk-*`: [N2] cho mức (đĩa 85 %, CPU 60 %, heap 60 %); số chu kỳ chọn như alarm cùng loại của [N1].
- Chưa đặt: `CurrConnections`, `ReplicationLag` của ElastiCache ([N1] đòi baseline lịch sử, chưa có); `ActiveControllerCount` của MSK (controller
  KRaft do MSK quản).

### 4. MSK storage autoscaling

- `aws_appautoscaling_target` (`kafka:broker-storage:VolumeSize`, min = `broker_volume_size`) và policy target tracking
  `KafkaBrokerStorageUtilization` mức **60 %** (MSK khuyên 50–60 % [N7]), `disable_scale_in = true`. Trần mỗi broker: stg **20 GiB**, prd
  **100 GiB**.
- MSK tăng mỗi lần max(10 GiB, 10 %), tối đa một lần mỗi 6 giờ, không bao giờ giảm [N7], [N8]: stg (buổi 4 giờ) tăng được một lần, 10 → 20 GiB.
  `aws_msk_cluster` bỏ qua thay đổi `volume_size` (`lifecycle.ignore_changes`) để apply sau không tìm cách thu nhỏ.
- `kafka.t3.small` (stg): tài liệu không loại cỡ này khỏi autoscaling [N7]; buổi stg xác nhận bằng chính lần apply. API từ chối thì dừng, viết ADR
  chỉnh (không tắt riêng ở stg: nhóm phải giống).
- Policy tạo một alarm target tracking; xoá cluster trước policy để lại alarm đó [N7]: Terraform xoá policy trước cluster, `sweep.sh` liệt kê alarm sót.

### 5. ElastiCache bảo trì và slow-log

- Biến `apply_immediately`: prd `false` (thay đổi chờ cửa sổ bảo trì, plan prd hiện thay đổi chờ), stg `true` (0055 §4) [N9]. Cửa sổ
  `sun:18:00-sun:19:00` UTC (01:00–02:00 thứ Hai giờ Singapore) ở cả hai env.
- `log_delivery_configuration` loại `slow-log`, đích CloudWatch Logs, định dạng JSON [N10]; log group do module tạo, retention theo biến (stg 1, prd
  30 ngày như log khác). Ngưỡng slow-log giữ mặc định của engine (`slowlog-log-slower-than` 10 000 µs).

### Hệ quả

- Tốt: báo khi dữ liệu sắp đầy hay sắp hỏng, kể cả khi cluster chết; MSK không đầy đĩa trong buổi; prd không đổi cấu hình Valkey giữa giờ.
- Xấu: alarm ở CloudWatch, cảnh báo khác ở Alertmanager (hai chỗ); email là đích duy nhất; thêm một KMS key và ~16 alarm ($0,10 mỗi metric
  của alarm mỗi tháng theo trang giá [N4], alarm metric math tính từng metric); dung lượng MSK đã tăng không giảm.
- Xem lại khi: cần dashboard chung (thêm exporter); có baseline `CurrConnections`, `ReplicationLag`; có kênh on-call ngoài email; alarm `page` kêu
  sai quá một lần mỗi buổi.

## Xác nhận

- Lúc quyết chưa hiện thực. Kiểm tĩnh: `make test` của `svp-infra` (tên, tag, đích, ngưỡng, KMS policy, autoscaling, `apply_immediately`).
- Buổi stg: email xác nhận subscription; `aws cloudwatch set-alarm-state` một alarm `page` tới email, có URL runbook; slow-log có ở CloudWatch Logs;
  autoscaling MSK nhận policy trên `kafka.t3.small`; đo `max_connections` của lớp stg. Buổi prd: lớp prd, thay đổi Valkey chờ cửa sổ.

## Hiện thực ở

- `svp-infra`: `aws/modules/alarms/` (SNS, KMS, email), `aws/modules/rds/`, `aws/modules/msk/`, `aws/modules/elasticache/` (alarm, autoscaling,
  bảo trì, slow-log), `aws/envs/<env>/<env>.tfvars`, `aws/scripts/sweep.sh`.
- Repo code: `docs/runbooks/<alarm>.md` cho mỗi alarm `page`.

## Nguồn

Đọc 2026-11-11; đủ [N1]–[N10] ở phụ lục. [N1] <https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/Best_Practice_Recommended_Alarms_AWS_Services.html>,
[N2] <https://docs.aws.amazon.com/msk/latest/developerguide/bestpractices.html>, [N7] <https://docs.aws.amazon.com/msk/latest/developerguide/msk-autoexpand.html>.

## Thông tin thêm

Phụ lục: [`appendix/0058-managed-data-operations.md`](appendix/0058-managed-data-operations.md) (bảng phương án, nguồn).

### Chỉnh bởi

- §1: [0063](0063-managed-observability.md): topic `svp-<env>-alarms` thêm publisher AMP (`aps.amazonaws.com`, `sns:Publish`): luật và Alertmanager của AMP gửi cảnh báo qua topic này.
- §1: [0067](0067-backup-dr.md): alarm `backup-job-failed`, `backup-copy-failed` (`ticket`) là query Metrics Insights trên namespace `AWS/Backup`, chu kỳ 300 s, `treat_missing_data = notBreaching` thay chu kỳ 60 s, `missing`: AWS Backup đẩy metric mỗi 5 phút, chỉ khi có job.
