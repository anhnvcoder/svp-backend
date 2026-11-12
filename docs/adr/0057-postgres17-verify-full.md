# 0057. PostgreSQL 17 ở RDS, CloudNativePG, compose và CI; mọi client nối `sslmode=verify-full` với CA của nền tảng; compose có Postgres riêng; RDS lớp M ở prd với CMK, storage autoscaling và tham số ghi log; không proxy kết nối

- Trạng thái: Chấp nhận
- Ngày: 2026-11-11
- Người quyết: người học (major 17, Postgres compose riêng, không proxy, giữ RDS không Aurora: duyệt cùng kế hoạch), AI đề xuất số và cấu hình
  theo chuẩn ngành

## Bối cảnh và vấn đề

- [0034](0034-aws-stage7.md) Câu 17 A giữ PostgreSQL 15 cho khớp local; 15 hết standard support trên RDS ngày 2028-02-29 [N1]. RDS prd chạy lớp T
  (`db.t4g.medium`), khoá KMS của AWS, không storage autoscaling, parameter group chỉ có `rds.force_ssl`.
- Client nối `sslmode=require`: mã hoá nhưng không kiểm cert server; trên EKS client gọi tên `svp-pg-rw` (ExternalName) mà cert RDS không mang.
- compose dùng Postgres native của máy (Homebrew, không TLS, chung với dự án khác): đường code client local khác cloud, trái luật managed/local
  của [0053](0053-msk-elasticache-valkey.md) §1. [0055](0055-environment-matrix.md) §2 xếp version, parameter group, TLS, CMK vào nhóm phải giống.

## Yếu tố quyết định

- Một major còn support lâu, có ở RDS `ap-southeast-1` và ở image local; local chạy cùng major và cùng TLS với cloud.
- Client kiểm danh tính server ở mọi nền tảng (chống MITM trong VPC, trong cluster) với một chuỗi kết nối, khác nhau chỉ ở dữ liệu.
- Lớp production cho prd [N2]; key, log, storage đủ để vận hành và điều tra; chi phí buổi có lý do.

## Phương án đã cân nhắc

Được, mất và nguồn: [phụ lục](appendix/0057-postgres17-verify-full.md#phương-án).

- Major: giữ 15 (hết support sớm nhất); **17** (support RDS tới 2030-02-28, có bản Aurora LTS 17.7 [N1], [N3]); 18 (tới 2031-02-28, chưa có Aurora
  LTS, ra Aurora 2026-06).
- Engine: **RDS for PostgreSQL**; Aurora PostgreSQL (storage chia sẻ ba AZ, failover nhanh; tối thiểu `db.t4g.medium`, giá instance và I/O cao hơn,
  khác engine với local và CNPG).
- TLS: giữ `require`; **`verify-full` với CA của nền tảng**; `verify-ca` (kiểm CA, không kiểm tên).
- Postgres compose: giữ native của máy; nâng native lên 17 và bật TLS (đụng dự án khác); **container `postgres` riêng của compose**.
- Proxy: RDS Proxy; PgBouncer trong cluster; **nối thẳng, pool pgxpool của service**.

## Kết quả quyết định

Chọn các phương án in đậm. Cái giá: lớp M ở prd đắt hơn lớp T, compose thêm một container, `make test` còn chạy Postgres native khác major (§4).

### 1. PostgreSQL 17

- RDS `engine_major_version = "17"`, family `postgres17`; minor do RDS chọn và tự nâng (`auto_minor_version_upgrade`), ở `ap-southeast-1` có 17.5
  tới 17.11 lúc quyết [N4].
- Image local và CI ghim **17.11**, bản mới nhất RDS có [N4]: `docker.io/library/postgres:17.11-trixie` (compose, service Postgres của job
  `make test`) và `ghcr.io/cloudnative-pg/postgresql:17.11-minimal-trixie` (CNPG của k3d), ghim digest. Hai image cùng `x.y`; Renovate gom chúng
  vào một nhóm `postgres` ở `renovate.json` (một PR cho minor, patch, không tự merge; major chờ duyệt).
- Vì sao không 18: 17 có Aurora LTS, giữ đường sang Aurora mở; 18 mới ra Aurora tháng 6/2026, chưa LTS. Một năm support ít hơn 18 là cái giá.
- Postgres native của máy (`127.0.0.1:5432`, Homebrew 15, dùng chung) không đổi: chỉ `make test` dùng nó; lệch major với CI (17) chấp nhận vì test
  không dùng tính năng riêng của 17, CI bắt lỗi trên 17.

### 2. TLS tới Postgres

- Mọi client (bốn service, Job migrate, GlitchTip, Job `pg-bootstrap`) nối `sslmode=verify-full&sslrootcert=/etc/svp-ca/ca.crt` [N5]; chuỗi giống
  nhau ở compose, k3d, EKS, chỉ khác host và nội dung file.
- Host là tên cert server mang: compose `postgres`; k3d `svp-pg-rw.svp-data`; EKS địa chỉ RDS (`cluster.rdsAddress`), không phải ExternalName
  `svp-pg-rw`.
- File CA: local là CA local của `make env` (`backend/.local/ca/ca.crt`, đã dùng cho Kafka, Valkey: 0053 §11); EKS là bundle CA của RDS cho
  `ap-southeast-1` (<https://truststore.pki.rds.amazonaws.com/ap-southeast-1/ap-southeast-1-bundle.pem>) trong Secret `rds-ca` (khoá `ca.crt`) ở
  namespace `svp`, `svp-obs`, `svp-data`. Bundle chỉ chứa root CA, như RDS khuyên (cert server xoay tự động) [N6].
- Server: RDS `ca_cert_identifier = "rds-ca-rsa2048-g1"` (mặc định của RDS, ghi rõ để plan thấy) [N6]; CNPG và Postgres compose dùng cert server ký bởi
  CA local, sinh thêm bởi `make env` (file mới), SAN `postgres`, `svp-pg-rw`, `svp-pg-rw.svp-data`, `svp-pg-rw.svp-data.svc`,
  `svp-pg-rw.svp-data.svc.cluster.local`, `localhost`.

### 3. Postgres compose

Container `postgres` (image §1, TLS §2, volume dữ liệu riêng, không publish cổng host vì `127.0.0.1:5432` là Postgres native) thay Postgres native
cho service, migrator, GlitchTip của compose, như tiền lệ Valkey (0053 §8). Database và role như bảng của `AGENTS.md`, tạo bởi script bootstrap
chạy trong container. Script trên host chạm nó bằng `docker compose … exec postgres psql …` qua Makefile. Job `stack`/`compose` của CI bỏ service
Postgres của runner; job `make test` giữ service Postgres (image §1).

### 4. Khác biệt local buộc phải có

Dữ liệu, không nhánh code: CA local thay CA của RDS (§2); một instance CNPG, một container compose thay instance RDS; `make test` trên Postgres
native 15 không TLS (helper `internal/pgtest` chỉ nhận database `svp_<...>_test`).

### 5. RDS chuẩn

| Khoá | stg | prd | Lý do |
| --- | --- | --- | --- |
| Lớp | `db.t4g.small` | **`db.m7g.large`** | Lớp T chỉ cho dev, test [N2]; M7g Graviton cho production. Cả hai có cho PostgreSQL 17 ở `ap-southeast-1` [N4] |
| `allocated_storage` | 20 GiB | 20 GiB | Như hiện có |
| `max_allocated_storage` | 40 GiB | 100 GiB | Bật storage autoscaling; trần ≥ 26 % trên mức cấp để không nhận cảnh báo sát trần [N7] |

- KMS key customer managed do module tạo (alias `alias/svp-<env>-rds`, rotation bật, deletion window 7 ngày, key policy mặc định): `kms_key_id` của storage, `performance_insights_kms_key_id`,
  `master_user_secret_kms_key_id`. Đổi CMK hay major buộc tạo lại instance: chấp nhận vì env dựng mới mỗi buổi.
- Export log `postgresql`, `upgrade` ở cả hai env (0055 §2), retention theo env.

### 6. Tham số ghi log

Parameter group `postgres17` của module, cùng ở hai env, thêm vào `rds.force_ssl = 1` [N8], [N9]:

| Tham số | Giá trị | Ghi gì |
| --- | --- | --- |
| `log_min_duration_statement` | `1000` (ms) | Câu lệnh chạy từ 1 s |
| `log_lock_waits` | `1` | Chờ khoá quá `deadlock_timeout` (1 s) |
| `log_temp_files` | `10240` (kB) | File tạm từ 10 MiB (sort, hash tràn `work_mem`) |
| `log_autovacuum_min_duration` | `1000` (ms) | Autovacuum chạy từ 1 s |
| `log_connections`, `log_disconnections` | `1` | Mỗi kết nối, phiên; pool dài hạn nên ít dòng |
| `log_parameter_max_length` | `0` | Không ghi giá trị bind kèm dòng log câu lệnh; mặc định `-1` ghi đủ (email, hash mật khẩu của user-service) [N9] |

Giá trị bind không vào log (JWT-8 của [threat model](../threat-model.md)): dòng log chậm chỉ có câu lệnh với `$1`, `$2`;
`log_parameter_max_length_on_error` giữ mặc định `0` (dòng lỗi không kèm giá trị bind) [N9]. `log_statement` giữ `none`: `ddl` sẽ ghi
`CREATE ROLE … PASSWORD` của bootstrap vào log [N8].

### 7. Proxy kết nối

Không dùng RDS Proxy hay PgBouncer: service giữ pool dài hạn (pgxpool) từ ít pod, không có nhiều kết nối ngắn. RDS Proxy thêm đường xác thực
(secret mỗi role hay IAM) và cert từ ACM thay CA của RDS [N6], khác local; PgBouncer thêm một hop tự vận hành. Khoá advisory của service ở mức
transaction, RDS Proxy không ghim [N10]; Job migrate giữ khoá advisory mức phiên của goose (`internal/dbmigrate`): qua RDS Proxy nó ghim kết nối
[N10], qua PgBouncer chế độ transaction khoá không giữ được [N11]. Chọn proxy sau này thì service không phải sửa code, Job migrate nối thẳng
instance.

### Hệ quả

- Tốt: support tới 2030; một chuỗi kết nối kiểm tên server ở mọi nền tảng; compose chạy TLS như cloud; prd lớp production, key và log riêng.
- Xấu: instance prd Multi-AZ $0,468/giờ thay $0,203 của `db.t4g.medium` (phụ lục); thêm cert, Secret `rds-ca`, container compose; `make test` lệch major với CI.
- Xem lại khi: tổng `max_conns` của các pool vượt nửa `max_connections`; thời gian nối lại sau failover ở buổi prd vượt ngân sách SLO; 18 có
  Aurora LTS; cần Aurora (failover dưới 30 s, storage ba AZ).

## Xác nhận

- Lúc quyết chưa hiện thực. Kiểm tĩnh: `make test` của `svp-infra` (major, lớp, CMK, tham số, `ca_cert_identifier`), `make helm-check` (chuỗi
  `verify-full`, Secret `rds-ca`, `pg-bootstrap`), CI backend với Postgres 17, `verify.yml` kịch bản `compose-obs` và `dev-k3d` (TLS local).
- Buổi stg: service, migrate, GlitchTip nối RDS qua `verify-full`; log chậm có ở CloudWatch, không kèm dòng `Parameters:`; lớp
  `db.t4g.small` tạo được ở minor RDS chọn.

## Hiện thực ở

- `svp-infra`: `aws/modules/rds/` (major, CMK, autoscaling, parameter group, CA), `aws/envs/<env>/<env>.tfvars` (lớp, trần storage).
- Repo code: `deploy/compose/` (container `postgres`, cert), `deploy/compose/local-ca.sh`, chart `svp-data` (CNPG, `pg-bootstrap`), chart
  `svp-cluster` (Secret `rds-ca`, `DATABASE_URL`), CI (`.github/workflows/`), `renovate.json`.
- `svp-gitops`: `platforms/eks/svp-cluster.yaml` (bundle CA), `platforms/eks/svp-cluster.values.tpl` (host RDS), `platforms/eks/<service>.yaml`.

## Nguồn

Đọc 2026-11-11; đủ [N1]–[N11] ở phụ lục. [N1] <https://docs.aws.amazon.com/AmazonRDS/latest/PostgreSQLReleaseNotes/postgresql-release-calendar.html>,
[N5] <https://www.postgresql.org/docs/17/libpq-ssl.html>, [N6] <https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/UsingWithRDS.SSL.html>,
[N8] <https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/USER_LogAccess.Concepts.PostgreSQL.Query_Logging.html>.

## Thông tin thêm

Phụ lục: [`appendix/0057-postgres17-verify-full.md`](appendix/0057-postgres17-verify-full.md) (bảng phương án, version đã tra, nguồn).
