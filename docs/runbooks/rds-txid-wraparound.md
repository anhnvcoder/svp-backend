# rds-txid-wraparound

- Severity: `page`. Alarm CloudWatch `svp-<env>-rds-txid-wraparound` của module `rds` (`infra/aws/modules/rds/alarms.tf`), chỉ ở AWS (stg, prd).
- Chuẩn bị biến `ENV`, `N` và hàm `awsx`: [README](README.md#alarm-của-dịch-vụ-managed-rds-msk-elasticache). Mọi lệnh AWS do người học chạy.

## Ý nghĩa và tác động tới người dùng

`MaximumUsedTransactionIDs` của RDS `svp-<env>` vượt ngưỡng của [ADR-0058](../adr/0058-managed-data-operations.md) §2 (ngưỡng và nguồn ở đó):
số transaction ID đã dùng kể từ lần VACUUM đóng băng (freeze) gần nhất. Không gian transaction ID của PostgreSQL có hạn; tới sát giới hạn đó nó
từ chối mọi lệnh ghi để không mất dữ liệu cũ, và chỉ phục hồi được bằng VACUUM chạy một mình, nhiều giờ.

Khi alarm kêu thì người dùng chưa mất gì: ngưỡng nằm xa giới hạn chặn ghi. Đây là báo trước dài ngày, nhưng một autovacuum bị kẹt
không tự khỏi, nên là `page`.

## Kiểm tra nhanh (5 phút)

Compose, k3d: không có alarm này (database nhỏ, tuổi transaction chưa bao giờ tới mức đó); câu SQL ở bước 2 dùng được ở compose
(`dc exec -T postgres psql -U postgres -d <database> -X -c '…'`) và k3d.

AWS (người học chạy):

```sh
# 1. Tuổi transaction hiện tại và xu hướng 24 giờ qua (theo giờ)
awsx cloudwatch get-metric-statistics --namespace AWS/RDS --metric-name MaximumUsedTransactionIDs --dimensions Name=DBInstanceIdentifier,Value="$N" --start-time "$(date -u -v-24H +%FT%TZ)" --end-time "$(date -u +%FT%TZ)" --period 3600 --statistics Maximum --query 'sort_by(Datapoints,&Timestamp)[].[Timestamp,Maximum]' --output text
# 2. Autovacuum có chạy không, bảng nào bị bỏ lại: dòng "automatic vacuum" và "automatic aggressive vacuum" trong log
awsx logs tail "/aws/rds/instance/$N/postgresql" --since 6h --filter-pattern '"automatic"'
# 3. Có gì chặn vacuum không: transaction mở lâu, slot replication
awsx cloudwatch get-metric-statistics --namespace AWS/RDS --metric-name OldestReplicationSlotLag --dimensions Name=DBInstanceIdentifier,Value="$N" --start-time "$(date -u -v-6H +%FT%TZ)" --end-time "$(date -u +%FT%TZ)" --period 3600 --statistics Maximum --output text
```

Truy vấn SQL (cần đường tới RDS trong VPC, ví dụ một pod trong cluster `$ENV`; người học dựng) cho từng database, thứ tự đáng sợ nhất:

```sql
SELECT datname, age(datfrozenxid) FROM pg_database ORDER BY 2 DESC;
SELECT c.oid::regclass, age(c.relfrozenxid) FROM pg_class c WHERE c.relkind IN ('r','m','t') ORDER BY 2 DESC LIMIT 10;
SELECT pid, now() - xact_start AS open_for, state FROM pg_stat_activity WHERE xact_start IS NOT NULL ORDER BY xact_start LIMIT 5;
SELECT slot_name, active FROM pg_replication_slots;
```

Đọc: `age` tăng tới gần ngưỡng của alarm mà log không có autovacuum chạy là autovacuum bị chặn hay không kịp. Transaction mở nhiều giờ (câu 3) hay slot
không hoạt động (câu 4) giữ ID cũ nên VACUUM không đóng băng được.

## Nguyên nhân thường gặp

1. **Transaction mở rất lâu** (bước SQL 3): kết nối rò, Job chạy dài, `idle in transaction`.
2. **Slot replication không dùng** giữ ID cũ (bước SQL 4, `OldestReplicationSlotLag` cao): replica hay công cụ đã tắt mà slot còn.
3. **Autovacuum chạy nhưng không kịp** trên bảng ghi nhiều (log `automatic aggressive vacuum` kéo dài, bảng `engagement`): cấu hình mặc định
   quá nhẹ cho tải.
4. **Autovacuum bị tắt hay hỏng trên một bảng** (`autovacuum_enabled = false`): không có dòng log cho bảng đó.

## Giảm thiểu

- Chấm dứt thứ chặn: kết thúc transaction mở lâu (`SELECT pg_terminate_backend(<pid>)`), xoá slot không dùng
  (`SELECT pg_drop_replication_slot('<tên>')`). Cả hai ghi lên database: người học quyết, ghi lại pid hay slot.
- `VACUUM (FREEZE, VERBOSE) <bảng>` trên bảng có `age(relfrozenxid)` cao nhất (SQL bước 2), từng bảng một, giờ thấp tải: nó đọc cả bảng nên tốn I/O.
  Không `VACUUM FULL`: khoá bảng và chậm hơn mà không cần cho việc này.
- Nâng tốc độ autovacuum (`autovacuum_vacuum_cost_limit` trong parameter group `postgres17` của module) là thay đổi tham số của
  hạ tầng: đi qua ADR chỉnh và `apply`, không `modify-db-parameter-group` tay. Cùng một parameter group ở stg và prd
  ([ADR-0055](../adr/0055-environment-matrix.md) §2).

## Khôi phục và xác nhận

Chạy lại bước 1 của "Kiểm tra nhanh": `MaximumUsedTransactionIDs` giảm sau khi VACUUM xong (giảm theo bậc, không tức thì). Alarm về `OK`:

```sh
awsx cloudwatch describe-alarms --alarm-names "$N-rds-txid-wraparound" --query 'MetricAlarms[0].StateValue'
```

## Leo thang

- Số vẫn tăng dù đã gỡ nguyên nhân và VACUUM đang chạy: ghi sắp bị chặn, mở case với AWS Support ngay (PostgreSQL tự chạy autovacuum chống
  wraparound khi gần giới hạn, nhưng nó cũng bị chặn bởi đúng các nguyên nhân trên), ghi mốc thời gian cho postmortem
  ([mẫu](../postmortems/README.md)).
- Lặp lại sau khi đã dọn nguyên nhân: tham số autovacuum chưa đủ cho tải, cần đo và ADR chỉnh.
- Ghi đã bị chặn (`database is not accepting commands`): VACUUM đơn người dùng, dài và khó trên RDS, làm cùng AWS Support; khôi phục từ
  snapshot là phương án sau cùng (mất dữ liệu sau snapshot).

## Liên kết

- Dashboard: CloudWatch → Alarms `svp-<env>-rds-txid-wraparound`; RDS → Monitoring.
- ADR: [ADR-0058](../adr/0058-managed-data-operations.md) §2, §3; [ADR-0057](../adr/0057-postgres17-verify-full.md) §6 (log autovacuum từ 1 s).
- Diễn tập: không có.
