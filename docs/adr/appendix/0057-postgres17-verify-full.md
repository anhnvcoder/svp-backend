# Phụ lục ADR-0057: PostgreSQL 17 ở RDS, CloudNativePG, compose và CI; mọi client nối `sslmode=verify-full` với CA của nền tảng; compose có Postgres riêng; RDS lớp M ở prd với CMK, storage autoscaling và tham số ghi log; không proxy kết nối

Phụ lục của [ADR-0057](../0057-postgres17-verify-full.md): bảng phương án, version và giá đã tra, nguồn. Mọi nguồn đọc ngày 2026-11-11.

## Phương án

| Mục | Phương án | Trạng thái ngành | Được | Mất | Nguồn |
| --- | --- | --- | --- | --- | --- |
| Major | 15 | Còn support, cũ nhất trong ba | Không đổi gì | Hết standard support RDS 2028-02-29; extended support tính phí | [N1] |
| Major | **17** | Hiện hành, chín muồi (ra 2024-09) | Standard support RDS tới 2030-02-28; Aurora có bản LTS 17.7 | Một năm support ít hơn 18 | [N1], [N3] |
| Major | 18 | Mới (ra 2025-09, RDS 2025-11) | Support tới 2031-02-28 | Aurora 18 từ 2026-06, chưa LTS; ít thời gian chạy production trong ngành | [N1], [N3] |
| Engine | **RDS for PostgreSQL** | Hiện hành | Cùng engine với local, CNPG; single-AZ cho stg | Failover Multi-AZ một standby chậm hơn Aurora | [N2] |
| Engine | Aurora PostgreSQL | Hiện hành | Storage chia sẻ ba AZ, failover nhanh, đọc mở rộng | Khác engine với local; lớp nhỏ nhất `db.t4g.medium`; thêm phí I/O hay Aurora I/O-Optimized | [N3] |
| TLS | `require` | Cũ cho production | Không cần CA | Không kiểm danh tính server | [N5] |
| TLS | `verify-ca` | Hiện hành | Kiểm CA | Không kiểm tên: cert nào cùng CA cũng qua | [N5] |
| TLS | **`verify-full`** | Hiện hành, mức khuyên của libpq khi cần chống MITM | Kiểm CA và tên | Phải nối đúng tên cert mang, phải có file CA | [N5], [N6] |
| compose | Postgres native của máy | Đường cũ của lab | Không thêm container | Không TLS, khác major, chung dự án khác | — |
| compose | Nâng native lên 17, bật TLS | — | Một Postgres trên máy | Đụng dự án khác dùng chung | — |
| compose | **Container `postgres` riêng** | Hiện hành (cùng cách với Valkey của 0053) | Cùng major, TLS, CA với cloud | Thêm container, volume | — |
| Proxy | RDS Proxy | Hiện hành | Gom kết nối ngắn, failover nhanh hơn | Phí theo vCPU của instance; secret mỗi role hay IAM; cert ACM khác CA RDS; ghim phiên với `SET`, `PREPARE`, khoá advisory mức phiên | [N10] |
| Proxy | PgBouncer trong cluster | Hiện hành | Gom kết nối, không phí AWS | Thêm hop tự vận hành, TLS hai chặng; chế độ transaction không giữ khoá advisory mức phiên của Job migrate | [N11] |
| Proxy | **Nối thẳng, pgxpool** | Hiện hành cho ít pod, pool dài hạn | Không thêm thành phần | Failover RDS phải chờ DNS và pool nối lại | — |

## Version đã tra

Output lệnh chỉ đọc người học chạy ngày 2026-11-11, profile `anhnv-stg`, region `ap-southeast-1` [N4]:

- `aws rds describe-db-engine-versions --engine postgres --engine-version 17`: 17.5, 17.6, 17.7, 17.8, 17.9, 17.10, 17.11.
- `aws rds describe-orderable-db-instance-options` cho PostgreSQL 17 (người học lọc ở 17.6): `db.m7g` large tới 16xlarge, `db.t4g` micro tới
  2xlarge, mọi lớp `MultiAZCapable`. Lớp ở minor RDS chọn khi tạo (`engine_version = "17"`) kiểm khi buổi stg tạo instance.
- Image: `docker.io/library/postgres:17.11-trixie` có trên Docker Hub (cập nhật 2026-11-06), `ghcr.io/cloudnative-pg/postgresql:17.11-minimal-trixie`
  có trên GHCR (manifest index trả 200), đọc 2026-11-11.

## Giá instance

Price List API của AWS, `AmazonRDS`, `ap-southeast-1`, bản công bố 2026-10-29, PostgreSQL on-demand mỗi giờ:

| Lớp | Single-AZ | Multi-AZ |
| --- | --- | --- |
| `db.t4g.small` (2 vCPU, 2 GiB) | $0,051 | $0,102 |
| `db.t4g.medium` (2 vCPU, 4 GiB) | $0,102 | $0,203 |
| `db.m7g.large` (2 vCPU, 8 GiB) | $0,234 | $0,468 |

Buổi prd 4 giờ thêm ~$1,06 so với `db.t4g.medium` Multi-AZ.

## Nguồn

- [N1] Release calendar for Amazon RDS for PostgreSQL: <https://docs.aws.amazon.com/AmazonRDS/latest/PostgreSQLReleaseNotes/postgresql-release-calendar.html>
- [N2] RDS DB instance class types: <https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/Concepts.DBInstanceClass.Types.html>
- [N3] Release calendars for Aurora PostgreSQL: <https://docs.aws.amazon.com/AmazonRDS/latest/AuroraPostgreSQLReleaseNotes/aurorapostgresql-release-calendar.html>
- [N4] Lệnh chỉ đọc người học chạy ngày 2026-11-11 (mục "Version đã tra").
- [N5] PostgreSQL 17, libpq SSL support: <https://www.postgresql.org/docs/17/libpq-ssl.html>
- [N6] Using SSL/TLS to encrypt a connection to a DB instance: <https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/UsingWithRDS.SSL.html>
- [N7] Amazon RDS storage autoscaling: <https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/USER_PIOPS.Autoscaling.html>
- [N8] Turning on query logging for RDS for PostgreSQL: <https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/USER_LogAccess.Concepts.PostgreSQL.Query_Logging.html>
- [N9] PostgreSQL 17, Error reporting and logging: <https://www.postgresql.org/docs/17/runtime-config-logging.html>
- [N10] Avoiding pinning an RDS Proxy: <https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/rds-proxy-pinning.html>
- [N11] PgBouncer, SQL feature map for pooling modes: <https://www.pgbouncer.org/features.html>
