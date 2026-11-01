# Môi trường: `.env` và biến của service

Loại tài liệu (Diátaxis): **reference**, tra cứu khi cần một lệnh hay một quy tắc cụ thể; luật làm việc ở [`AGENTS.md`](../../AGENTS.md).

## `.env`

- `make env`: sinh `.env` local (mode 600, mật khẩu DB, mật khẩu root của object store `SVP_S3_ROOT_PASSWORD`, secret key S3 của
  từng service và của user thử `svp-objstore-probe` (`SVP_S3_PROBE_SECRET_KEY`, chỉ compose và `make test-stack`) ngẫu nhiên,
  khoá JWT mới, khoá Server Action của web `NEXT_SERVER_ACTIONS_ENCRYPTION_KEY` (base64 của 32 byte); thêm
  `GLITCHTIP_SECRET_KEY`, `GLITCHTIP_ADMIN_PASSWORD`, mật khẩu hai role `svp_glitchtip_*` và
  `GLITCHTIP_ADMIN_EMAIL=admin@svp.local`; cho cluster k3d, compose bỏ qua: `SVP_PG_SUPERUSER_PASSWORD`,
  `SVP_KAFKA_ADMIN_PASSWORD`, `SVP_KAFKA_KEDA_PASSWORD`, `SVP_KAFKA_<SERVICE>_PASSWORD` cho 5 service có Kafka,
  `SVP_GRAFANA_ADMIN_PASSWORD`, `SVP_PG_BACKUP_S3_SECRET_KEY` (user `svp-pg-backup` của backup Postgres; 20 byte hex
  như secret key S3 khác: 40 ký tự là độ dài secret key của AWS và giới hạn của MinIO, store của đường quay lại)). `.env` có
  sẵn thì chỉ bổ sung biến còn thiếu hoặc đang rỗng, không đổi giá trị đã đặt; `SVP_MINIO_ROOT_PASSWORD` của `.env` cũ còn đó
  thì không ai đọc.
- Quy tắc đọc `.env` (`deploy/observability/glitchtip/dotenv.sh`, dùng chung cho `make env`, `make test-stack`,
  `make glitchtip-init`, bootstrap Postgres và script diễn tập): mỗi dòng là dòng trống, comment `#` ở cột 1, hoặc
  `KEY=value` với `KEY` ở cột 1 và `=` ngay sau; giá trị trơn (ASCII in được, không khoảng trắng, nháy, `\`, `$`) hoặc nằm
  trong đúng một cặp nháy `"..."`/`'...'` bao ngoài, bỏ nháy khi đọc (`KEY=""` là rỗng). Dòng có `$`/`${`, khoảng trắng
  đầu dòng hay `export`, khoá lặp, giá trị nhiều dòng, CRLF, byte NUL → dừng, nêu `FILE:dòng:` và tên biến, không in giá
  trị, không ghi gì.

## Biến và hành vi khởi động của service

- **Service có Postgres thử lại kết nối lúc khởi động** (`internal/pgretry`, gọi từ `internal/pgpool.New` và
  `internal/dbmigrate.Up`; [ADR-0020](../adr/0020-reliability-stage6.md) §11): chỉ lỗi mạng (từ chối kết nối, quá hạn dial,
  mất kết nối lúc bắt tay, DNS quá hạn), trong cửa sổ 30 s, chờ 250 ms gấp đôi tới 2 s, mỗi lần vẫn bị hạn kết nối 5 s; lỗi xác
  thực, database không có, TLS bị từ chối, tên miền không có thì dừng ngay. Mỗi lần lỗi một dòng WARN `database not reachable,
  retrying` (`attempt`, `error`, không URL), nối được sau khi lỗi thì INFO `database connected after retries` (`attempts`,
  `elapsed_ms`).
- **engagement-service mở tối đa `DATABASE_MAX_CONNS` kết nối Postgres mỗi process** ([ADR-0031](../adr/0031-chaos-findings-feed-engagement-tempo.md)
  §2): số nguyên ≥ 2, không đặt thì 10, giá trị khác thì service không khởi động; chia hai pool cùng URL: pool đọc (chỉ `GetStats`)
  ⌊n/2⌋, pool ghi (Like, Unlike, consumer lượt xem) phần còn lại. Values k3d đặt `"10"`, compose không đặt. Like/Unlike có hạn
  Postgres 1 s phía server; hết hạn hay Postgres không tới được thì `UNAVAILABLE` + `DEPENDENCY_UNAVAILABLE`, gateway không thử lại
  (503 ngay). Service khác giữ pool mặc định của pgx.
