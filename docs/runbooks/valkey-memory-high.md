# valkey-memory-high

- Severity: `page`. Alarm CloudWatch `svp-<env>-valkey-memory-high` của module `elasticache` (`infra/aws/modules/elasticache/alarms.tf`), chỉ ở AWS (stg, prd).
- Chuẩn bị biến `ENV`, `N` và hàm `awsx`: [README](README.md#alarm-của-dịch-vụ-managed-rds-msk-elasticache). Mọi lệnh AWS do người học chạy.
  Lệnh Valkey đi qua `svp-valkey` ([ADR-0053](../adr/0053-msk-elasticache-valkey.md) §13) trong Deployment `svp-ops` của namespace `svp-data`
  (context của cluster `$ENV`).

## Ý nghĩa và tác động tới người dùng

`DatabaseMemoryUsagePercentage` của ElastiCache for Valkey `svp-<env>` (lấy node cao nhất) vượt ngưỡng, đủ số chu kỳ của
[ADR-0058](../adr/0058-managed-data-operations.md) §2 (ngưỡng ở đó, lý do ở §3). Chính sách bộ nhớ là `noeviction` ([ADR-0053](../adr/0053-msk-elasticache-valkey.md)): khi đầy 100 %
Valkey không xoá khoá nào để lấy chỗ mà **từ chối lệnh ghi** (`OOM command not allowed`). Alarm báo trước điểm đó.

Khi chạm 100 %: gateway ghi bộ đếm rate limit không được, rơi về giới hạn trong bộ nhớ của từng pod
([rate-limit-fallback-active.md](rate-limit-fallback-active.md)); web không ghi được session mới (đăng nhập lỗi); feed-service không ghi cache khám phá nên mọi
request `explore` đi thẳng Postgres ([explore-cache-redis-timeout.md](explore-cache-redis-timeout.md)). Dưới 100 % mọi thứ vẫn chạy.

## Kiểm tra nhanh (5 phút)

Compose, k3d: không có alarm này (ADR-0058 §2 chỉ đặt alarm cho dịch vụ managed); lệnh `svp-valkey` bước 3 dùng được cả hai
(compose `dc exec -T valkey`, k3d `kubectl --context k3d-svp -n svp-data exec deploy/svp-ops -c valkey --`).

AWS (người học chạy):

```sh
# 1. Trạng thái, cỡ node, số node
awsx elasticache describe-replication-groups --replication-group-id "$N" --query 'ReplicationGroups[0].[Status,CacheNodeType,MemberClusters]'
# 2. Bộ nhớ 3 giờ qua (phần trăm, node -001 là node đầu; đổi theo MemberClusters ở bước 1)
awsx cloudwatch get-metric-statistics --namespace AWS/ElastiCache --metric-name DatabaseMemoryUsagePercentage --dimensions Name=CacheClusterId,Value="$N-001" --start-time "$(date -u -v-3H +%FT%TZ)" --end-time "$(date -u +%FT%TZ)" --period 300 --statistics Maximum --query 'sort_by(Datapoints,&Timestamp)[].[Timestamp,Maximum]' --output text
# 3. Số khoá mỗi db và khoá không có TTL (svp-ops chỉ đọc khoá svp:*): db 10 gateway, 14 feed-service, 9 web
kubectl --context <context của cluster $ENV> -n svp-data exec deploy/svp-ops -c valkey -- /opt/svp/bin/svp-valkey -n 14 --scan --pattern 'svp:feed:explore:*' | wc -l
kubectl --context <context của cluster $ENV> -n svp-data exec deploy/svp-ops -c valkey -- /opt/svp/bin/svp-valkey -n 9 --scan --pattern 'svp:web:*' | wc -l
kubectl --context <context của cluster $ENV> -n svp-data exec deploy/svp-ops -c valkey -- /opt/svp/bin/svp-valkey -n 10 --scan --pattern 'svp:gw:*' | wc -l
# 4. Một khoá mẫu có TTL không (-1 là không hết hạn); đổi <khoá> theo kết quả scan
kubectl --context <context của cluster $ENV> -n svp-data exec deploy/svp-ops -c valkey -- /opt/svp/bin/svp-valkey -n 14 PTTL '<khoá>'
```

Đọc: bước 2 tăng đều là khoá tích tụ, tăng vọt là một loại khoá mới hay tải bất thường; bước 3 cho nhóm khoá nhiều nhất (đếm bằng `SCAN`, tốn
vài giây); bước 4 `-1` nghĩa là khoá sống mãi. `svp-ops` không có `INFO` hay `MEMORY USAGE`, nên kích thước từng khoá chỉ đọc gián tiếp qua số lượng.

## Nguyên nhân thường gặp

1. **Khoá thiếu TTL** (bước 4 `-1`): lỗi code hay đường mới quên đặt hạn; bộ nhớ chỉ lên. Sửa ở service sở hữu khoá.
2. **Tải thật tăng** (session, cache khám phá, rate limit theo số người dùng): bước 3 một nhóm khoá lớn dần theo lưu lượng, bước 2 theo giờ cao điểm.
3. **Cỡ node không đủ** cho tải đã dự tính: dùng thật lớn hơn ước lượng; cỡ node stg nhỏ hơn prd nên stg chạm trước (`valkey_node_type` ở tfvars).
4. **Một client ghi khoá không tiền tố `svp:`**: `svp-ops` không thấy, nhưng metric thấy; ACL của service chỉ cho tiền tố riêng của nó (ADR-0053 §11), nên hiếm.

## Giảm thiểu

Ghi, người học quyết sau `awsx sts get-caller-identity`:

- **Xoá cache khám phá** (cache của feed-service, dựng lại từ Postgres, chỉ tốn tải đọc): `svp-valkey -n 14 --scan --pattern 'svp:feed:explore:*'` rồi `DEL` từng
  khoá (ACL của `svp-ops` chỉ cho `DEL` đúng tiền tố này và `svp:gw:rl:register:*` ở db 10). Không đụng khoá rate limit: nó là giới hạn chống lạm dụng.
- **Nâng cỡ node**: đổi `valkey_node_type` ở tfvars rồi `apply` ở `infra/aws/envs/<env>`. Ở prd thay đổi chờ cửa sổ bảo trì (`apply_immediately` `false`,
  ADR-0058 §5); khẩn cấp thì chỉ khi người học chấp nhận áp ngay một lần (`awsx elasticache modify-replication-group … --apply-immediately`, rồi tfvars cho khớp).
  Đổi cỡ có thể làm failover ngắn.
- Không `FLUSHDB` hay `FLUSHALL` (ACL cũng chặn): mất session và bộ đếm rate limit của mọi người dùng.

## Khôi phục và xác nhận

```sh
awsx cloudwatch describe-alarms --alarm-names "$N-valkey-memory-high" --query 'MetricAlarms[0].StateValue'
awsx elasticache describe-replication-groups --replication-group-id "$N" --query 'ReplicationGroups[0].Status'
```

`StateValue` về `OK`, bước 2 của "Kiểm tra nhanh" dưới ngưỡng của ADR-0058 §2, trạng thái `available`. Rate limit không còn ở chế độ dự phòng
([rate-limit-fallback-active.md](rate-limit-fallback-active.md)): `RateLimitFallbackActive` hết.

## Leo thang

- Bộ nhớ về lại ngưỡng trong vòng một ngày sau khi xoá cache: nguyên nhân là khoá thiếu TTL hay cỡ node; sửa code hay đổi cỡ, ghi ADR chỉnh 0053 nếu đổi cỡ,
  postmortem ([mẫu](../postmortems/README.md)).
- Đã 100 % và `RateLimitFallbackActive` hay lỗi đăng nhập ở web: xoá cache khám phá ngay để có chỗ, rồi chuyển sang
  [rate-limit-fallback-active.md](rate-limit-fallback-active.md).
- Slow-log (`/aws/elasticache/$N/slow-log`, [ADR-0058](../adr/0058-managed-data-operations.md) §5) có lệnh `KEYS`, `SMEMBERS` trên khoá lớn: báo service sở hữu.

## Liên kết

- Dashboard: CloudWatch → Alarms `svp-<env>-valkey-memory-high`; ElastiCache → `svp-<env>` → Monitoring; `svp-pipeline` (rate limit).
- ADR: [ADR-0058](../adr/0058-managed-data-operations.md) §2, §3, §5; [ADR-0053](../adr/0053-msk-elasticache-valkey.md).
- Diễn tập: không có (không đổ đầy Valkey ở stg có chủ đích; buổi stg kiểm bằng `set-alarm-state`, ADR-0058 phần Xác nhận).
