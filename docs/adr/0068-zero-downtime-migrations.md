# 0068. Migration Postgres không downtime: expand/contract mỗi bước một release, schema phục vụ cả bản trước; `lock_timeout` 2 s ở runner; luật file migration theo khoá; squawk lint trong CI; diễn tập đổi tên cột bằng test Go

- Trạng thái: Chấp nhận
- Ngày: 2026-11-14
- Người quyết: người học (luật viết tay trên goose, squawk, ngưỡng ở runner, contract ở release riêng: duyệt cùng kế hoạch), AI đề xuất luật,
  ngưỡng và cách kiểm theo tài liệu PostgreSQL 17 và chuẩn ngành

## Bối cảnh và vấn đề

- Job `migrate` của mỗi service chạy như hook `pre-install,pre-upgrade` (Argo CD đọc là PreSync) trước khi pod mới thay pod cũ
  ([0014](0014-kubernetes-local-stage4.md) §10); goose chạy như thư viện trong `internal/dbmigrate`
  ([0007](0007-go-monorepo-toolchain-and-stage1-scope.md)). Pod bản cũ vẫn phục vụ trên schema mới suốt lúc migration chạy và lúc rolling update.
- Runner không đặt `lock_timeout`: một DDL chờ `ACCESS EXCLUSIVE` sau một transaction dài làm mọi câu đến sau trên bảng xếp hàng sau nó, request
  quá hạn 3 s của gateway. Chưa có luật nào cho index, ràng buộc, `NOT NULL`, đổi tên cột trên bảng đã có dữ liệu, và chưa có lint nào bắt chúng.
- Chỉ một migration (`user-service` 00005) có test chịu bản trước; nó thêm cột, backfill, `SET NOT NULL` và `UNIQUE` trong một transaction.

## Yếu tố quyết định

- Trong lúc migrate và rollout, bản cũ và bản mới đều đọc ghi được, không request nào lỗi vì schema hay vì chờ khoá quá hạn của client.
- Quay lại được bằng triển khai lại bản trước, không cần chạy migration ngược ở stg, prd.
- Luật kiểm bằng máy (lint, test) ở CI, không chỉ nhờ người review; không đổi công cụ migration đã chốt.
- Có số đo khoá và lỗi client từ một lượt diễn tập chạy được trên máy 16 GB và trong CI.

## Phương án đã cân nhắc

Trạng thái ngành, được, mất và nguồn: [phụ lục](appendix/0068-zero-downtime-migrations.md#phương-án).

- Cách đổi schema: **luật expand/contract viết tay trên goose**; pgroll (tự expand/contract bằng schema version và view, thay goose); Reshape
  (cùng ý, một người giữ).
- Lint: **squawk**; Atlas `migrate lint` (chỉ cho Atlas Pro từ v0.38); eugene (ít người dùng); chỉ review tay.
- Đặt `lock_timeout`: **ở runner, trên mọi kết nối**; `SET` trong từng file; `ALTER ROLE <migrator> SET lock_timeout`.
- Contract: cùng release với expand trong PreSync (phá §2); hook PostSync của release mới; **release riêng sau đó**.

## Kết quả quyết định

Chọn các phương án in đậm. Cái giá: một lần đổi tên cột tốn sáu release; mỗi file migration theo luật §6; thêm một image lint vào CI.

### 1. Release và cửa sổ chung

Release là một bản phát hành của một service: image và chart mới promote qua `svp-gitops`; Argo CD chạy Job `migrate` của nó xong mới thay pod.
Bốn service có database (user-, video-, engagement-, feed-service) ra bằng rolling update; canary Argo Rollouts chỉ có ở gateway và web, không có
database. Cửa sổ chung: từ lúc Job `migrate` của release N bắt đầu tới khi pod cuối của N-1 dừng. Trong cửa sổ đó code N-1 chạy trên schema của
N, rồi N-1 và N chạy cùng lúc.

### 2. Bất biến hai bản

Schema sau migration của release N phục vụ đúng cả code N-1 lẫn N: đọc, ghi, ràng buộc. Quay lại là triển khai lại N-1 qua `svp-gitops` (revert
commit promote; prd theo [0024](0024-multi-environment.md) §8); không bao giờ `goose down` ở stg, prd, phần `Down` chỉ cho local và test.
Migration lỗi hay sai thì fix forward bằng migration mới, không sửa file đã áp ở bất kỳ database nào. Chỉ quay lại được một release (N → N-1).

### 3. Bước expand/contract

Đổi tên cột `a` `NOT NULL` thành `b`, mỗi dòng một release; cột mới cùng nghĩa nhưng khác tên đi cùng các bước:

| Release | Migration | Code ghi | Code đọc |
| --- | --- | --- | --- |
| (1) expand | thêm `b` nullable, không default | `a` | `a` |
| (2) ghi kép | — | `a`, `b` | `a` |
| (3) backfill | chép `a` sang `b` theo §7, rồi `b` `NOT NULL` theo §6 (d) | `a`, `b` | `a` |
| (4) đọc cột mới | — | `a`, `b` (pod của (3) còn đọc `a`) | `b` |
| (5a) contract | `a` `DROP NOT NULL` | `b` | `b` |
| (5b) contract | `DROP COLUMN a` | `b` | `b` |

Contract chỉ chạy khi release trước nó không còn nhắc `a` ở bất kỳ env nào, tức đã ra prd. (5a) chỉ bỏ `NOT NULL` để code mới thôi ghi `a`
trong khi pod (4) còn ghi nó; (5b) xoá cột khi bản trước nó là (5a), không còn đọc ghi `a`.

### 4. Ngưỡng khoá

- `internal/dbmigrate` đặt `lock_timeout = '2s'` là runtime parameter của pgx trên mọi kết nối nó mở, nên mọi migration có nó, kể cả file quên
  đặt. 2 s nằm dưới hạn 3 s mỗi lời gọi của gateway: request xếp hàng sau một DDL đang chờ khoá vẫn xong trong hạn [N1].
- 2 s lớn hơn `deadlock_timeout` (mặc định 1 s; parameter group của RDS không đổi nó). Postgres chỉ huỷ autovacuum đang chặn một yêu cầu khoá
  khi lượt kiểm deadlock chạy, tức sau `deadlock_timeout` [N22], [N23]; ngưỡng bằng hay dưới nó làm DDL lỗi `55P03` trước khi autovacuum bị
  huỷ, ở mọi lượt thử lại. Autovacuum chống wraparound không bị huỷ: DDL chờ nó thì lỗi `55P03` là đúng (chi tiết ở
  [phụ lục](appendix/0068-zero-downtime-migrations.md#ngưỡng-của-runner-và-autovacuum)).
- Hết hạn: migration lỗi `55P03 lock_not_available`, transaction của nó rollback, Job restart container (`restartPolicy: OnFailure`,
  `backoffLimit: 3`) làm lượt thử lại; vẫn lỗi thì release lỗi trước khi pod mới thay pod cũ.
- File trong transaction cần ngưỡng khác tự `SET LOCAL lock_timeout`, kèm comment lý do. File `-- +goose NO TRANSACTION` thì `SET LOCAL` chỉ cảnh
  báo, không đổi gì [N2]; file đó viết `SET lock_timeout = '<n>s'` ở đầu và `RESET lock_timeout` ở cuối, vì goose chạy cả lượt `Up` trên một kết
  nối [N3], nên `SET` phiên không reset sẽ lan sang migration kế. Khoá tạo schema `goose` giữ ngưỡng riêng như trước.
- Đầu mỗi lượt `migrate` log một dòng `msg` `"migration settings"` có thuộc tính `lock_timeout` đọc lại bằng `SHOW lock_timeout`.

### 5. statement_timeout

Runner không đặt. Câu dài không giữ khoá xung đột với app (CIC, `VALIDATE`, backfill theo lô) không chặn ai; câu giữ `ACCESS EXCLUSIVE` lâu là thứ
§8 chặn; tổng thời gian đã có trần `activeDeadlineSeconds: 300` của Job. Chiều ngược lại, CIC phải chờ transaction đang mở: xử lý ở §6 (a).
`statement_timeout`, `idle_in_transaction_session_timeout` của role app là quyết định riêng về vận hành pod.

### 6. Luật file migration

Mọi file mới của `services/*/migrations/`; khoá từng lệnh theo tài liệu PostgreSQL 17 ở
[phụ lục](appendix/0068-zero-downtime-migrations.md#khoá-theo-lệnh).

- (a) Index trên bảng đã có: `CREATE [UNIQUE] INDEX CONCURRENTLY IF NOT EXISTS` trong file `-- +goose NO TRANSACTION`, ngay trước nó
  `DROP INDEX CONCURRENTLY IF EXISTS` cùng tên để lượt thử lại dọn index `INVALID` của lượt lỗi; xoá index cũng `CONCURRENTLY` [N4]. CIC chờ mọi
  transaction có thể dùng bảng, rồi ở lượt chờ cuối chờ mọi transaction có snapshot cũ hơn lượt quét thứ hai của cả database, kể cả trên bảng
  khác [N4]; lượt chờ là chờ khoá nên chịu `lock_timeout` [N1], [N5]: với ngưỡng của §4, một transaction 3 s ở bất kỳ đâu trong database làm
  CIC lỗi. File CIC đặt `SET lock_timeout = '30s'` ở đầu, `RESET lock_timeout` ở cuối (§4): lượt chờ của CIC giữ `SHARE UPDATE EXCLUSIVE`, không
  chặn đọc ghi của app; 30 s gấp mười hạn 3 s của request, nên chỉ transaction không thuộc một request (phiên tay, sao lưu, việc nền chạy lâu)
  mới làm nó lỗi; mỗi lượt chờ một transaction có hạn riêng, và trần 300 s của Job vẫn bó cả lượt chạy.
- (b) File `NO TRANSACTION` chỉ chứa câu chạy lại được (`IF [NOT] EXISTS`, `WHERE` của backfill) vì goose không rollback nó.
- (c) Khoá ngoại và `CHECK` mới trên bảng đã có: `ADD CONSTRAINT … NOT VALID`, rồi `VALIDATE CONSTRAINT` ở file sau.
- (d) `SET NOT NULL`, ba file: (1) `ADD CONSTRAINT … CHECK (b IS NOT NULL) NOT VALID`; (2) `VALIDATE CONSTRAINT`; (3) `SET NOT NULL` (Postgres bỏ
  quét bảng nhờ check đã valid [N6]) rồi `DROP CONSTRAINT` check đó bằng câu `ALTER TABLE` riêng, vì check bị xoá trong cùng lệnh thì không được
  dùng [N6]. goose bọc cả file trong một transaction; `ADD CONSTRAINT` lấy `ACCESS EXCLUSIVE` và giữ tới commit, nên `VALIDATE` (quét cả bảng, chỉ
  cần `SHARE UPDATE EXCLUSIVE`) cùng file sẽ chặn app suốt lượt quét; `lock_timeout` bó thời gian chờ lấy khoá, không bó thời gian giữ. Luật
  chung: câu lấy `ACCESS EXCLUSIVE` không cùng file với câu quét hay viết lại cả bảng.
- (e) `UNIQUE`: unique index theo (a), rồi `ADD CONSTRAINT … UNIQUE USING INDEX`.
- (f) `SET NOT NULL`, `UNIQUE`, `VALIDATE` không cùng file với backfill.
- (g) Không `ADD COLUMN` có default volatile, không đổi kiểu cột phải viết lại bảng [N6], không `RENAME` cột hay bảng mà code N-1 dùng: đi theo §3.
- (h) Migration đổi bảng đã có kèm test chạy SQL của release trước sau migration, theo khuôn `services/user-service/migrations/migrations_test.go`.

### 7. Backfill theo lô

File `-- +goose NO TRANSACTION`, một khối `DO` (trong `-- +goose StatementBegin`/`StatementEnd`) chia lô theo keyset trên khoá chính: mỗi lô
lấy id thứ 10 000 sau `last`, chạy `UPDATE … SET b = a WHERE id > last AND id <= <id đó> AND b IS NULL`, tiến `last` tới id đó rồi `COMMIT`;
dừng khi không còn id nào sau `last`. `DO` chạy ngoài transaction block mới được `COMMIT` [N7]. Mỗi lô chỉ đọc khoảng id của nó, nên chi phí
tuyến tính theo số dòng; chọn lại `WHERE b IS NULL ORDER BY id LIMIT n` từ đầu bảng mỗi lô thì bước qua mọi dòng đã chép, chi phí bình phương.
Mỗi lô giữ khoá dòng ngắn; lượt chạy lại bỏ dòng đã chép nhờ `b IS NULL`. Số đo và giới hạn ước theo trần của Job:
[phụ lục](appendix/0068-zero-downtime-migrations.md#số-đo-diễn-tập). Bảng lớn tới mức backfill vượt trần thời gian của Job thì backfill
chạy bằng lệnh riêng ngoài Job `migrate`, migration (3) chỉ còn phần ràng buộc; lệnh đó dựng khi có bảng đầu tiên cần nó.

### 8. Lint migration

- squawk [N8] chạy từ image chính thức `ghcr.io/sbdchd/squawk`, ghim tag và digest ở biến `SQUAWK_IMAGE` của `Makefile` với dòng `# renovate:`
  ngay trên, `--network none`, read-only, như `regal-lint`. Version đã kiểm: [phụ lục](appendix/0068-zero-downtime-migrations.md#squawk).
- `make migration-lint` lint mọi file `services/*/migrations/*.sql` và `internal/dbmigrate/testdata/*/*.sql`; CI chạy nó ở job `config` của
  `ci.yml`. Không vào `make check` vì cần Docker.
- `.squawk.toml` ở gốc repo: `pg_version` 17, luật mặc định của version ghim, `assume_in_transaction = true` (§10). Luật tắt hẳn chỉ những luật
  mâu thuẫn §4, §5: `require-lock-timeout`, `require-statement-timeout` (bật mặc định ở version ghim [N10]). Luật tắt, file loại trừ đều có comment
  lý do ngay trên.
- Câu mà §3, §6 bắt buộc nhưng squawk báo (`DROP NOT NULL` của (5a), `DROP COLUMN` của (5b), `SET NOT NULL` và `DROP CONSTRAINT` của §6 (d)) mang
  `-- squawk-ignore <rule>` ngay dòng trên kèm comment lý do [N9]; luật đó vẫn bật cho mọi câu khác. squawk không biết mục `-- +goose Down` và lint
  cả nó: câu của Down mà squawk báo mang `-- squawk-ignore <rule>` với lý do Down chỉ chạy ở local và test (§2). Down của file CIC là
  `DROP INDEX CONCURRENTLY IF EXISTS`.

### 9. Migration cũ

Không sửa file nào đã có: goose đã áp chúng ở mọi database đang có, sửa file không đổi gì ở đó và làm database lệch nhau. File lint báo lỗi vào
danh sách loại trừ của `.squawk.toml`, comment ghi luật báo, ở Up hay Down, và lý do chung: chạy lúc bảng mới tạo hay còn ít dòng; database stg,
prd bắt đầu rỗng (0024: không chép dữ liệu prd). Luật áp từ migration kế tiếp.

### 10. Kiểm transaction của file

Test Go `internal/dbmigrate/files_test.go` đọc mọi file của `services/*/migrations/` và `internal/dbmigrate/testdata/*/`: file có `CONCURRENTLY`
phải có `-- +goose NO TRANSACTION`; file có dòng đó phải có `CONCURRENTLY` hay `COMMIT` (§7); file có `VALIDATE CONSTRAINT` không chứa
`ADD CONSTRAINT` (§6 (d)); file `NO TRANSACTION` luôn mang `-- squawk-disable-assume-in-transaction` và ngược lại [N9]. squawk không đọc chú
thích goose, nên test này là nguồn đúng chung cho goose và squawk; nó báo tên file vi phạm.

### 11. Diễn tập đổi tên

- Test Go `internal/dbmigrate/drill_test.go`, migration ở `internal/dbmigrate/testdata/rename/` (thư mục phẳng, lint như migration thật). Bảng
  `items`, đổi `title` thành `name` theo §3; mỗi release áp bằng `dbmigrate.Up` (cùng §4) trên các file tới version cuối của release đó.
- "Pod" là goroutine chạy đúng SQL của một release (4 goroutine ghi, đọc liên tục, mỗi thao tác hạn 3 s); pod N-1 chạy suốt migration của N rồi
  chạy cùng pod N tới hết bước.
- Ba test: sáu release không lỗi client; một release `RENAME COLUMN` làm pod N-1 lỗi; một transaction giữ khoá 4 s làm migration lỗi `55P03`
  sau ngưỡng của §4 mà client không lỗi, lượt chạy lại thành công (đối chứng: không ngưỡng thì client lỗi quá hạn). `make test` nạp 20 000 dòng;
  `make migration-drill` nạp 1 000 000 dòng và in bảng số đo.
- Cái giá: không có mạng, PgBouncer, RDS hay pod thật; Postgres native của máy có thể khác major với CI. Pod thật chỉ được kiểm ở buổi stg, prd,
  và database ở đó rỗng nên buổi không đo được khoá trên bảng lớn.

### Hệ quả

- Tốt: release không lỗi vì schema hay chờ khoá; quay lại một release không cần `goose down`; luật kiểm bằng lint và test ở CI; có số đo diễn tập.
- Xấu: đổi tên cột tốn sáu release, `SET NOT NULL` ba file; mỗi lần squawk báo câu bắt buộc phải thêm `squawk-ignore` có lý do; image squawk chỉ
  có `linux/amd64`, trên máy arm64 chạy giả lập.
- Xem lại khi: một backfill vượt `activeDeadlineSeconds`; migration lỗi `55P03` lặp ở stg, prd; cần quay lại quá một release; pgroll ra 1.0 và
  được dùng rộng; squawk ngừng phát hành hay đổi giấy phép.

## Xác nhận

- `internal/dbmigrate` (test của runner): kết nối mang `lock_timeout` 2 s, migration chờ khoá lỗi `55P03`; `files_test.go` (§10).
- `make migration-lint` xanh trong job `config` của CI; `make test` chạy ba test diễn tập (§11) với 20 000 dòng.
- Số đo `make migration-drill` với 1 000 000 và 3 000 000 dòng: [phụ lục](appendix/0068-zero-downtime-migrations.md#số-đo-diễn-tập).
- Buổi stg rồi prd, sau release đầu tiên có runner mới: log Job `<svc>-migrate` của mỗi service có database có dòng `"migration settings"` với
  `lock_timeout` `2s` và `"migrations up to date"`; Application của Argo CD `Synced`/`Healthy`.

## Hiện thực ở

- `internal/dbmigrate/`: `lock_timeout` của runner và dòng log (§4), `files_test.go` (§10), `drill_test.go` (§11).
- `internal/dbmigrate/testdata/`: migration của diễn tập và ví dụ sai (§11).
- `.squawk.toml`: cấu hình squawk, luật tắt, migration cũ loại trừ (§8, §9).
- `Makefile`: `SQUAWK_IMAGE`, `migration-lint` (§8), `migration-drill` (§11).
- `.github/workflows/ci.yml`: bước `make migration-lint` của job `config` (§8).
- `docs/runbooks/schema-change.md`: cách viết một thay đổi schema theo §3, §6, §7.

## Nguồn

Đọc 2026-11-14; đủ [N1]–[N23] ở phụ lục. [N1] <https://www.postgresql.org/docs/17/runtime-config-client.html>,
[N4] <https://www.postgresql.org/docs/17/sql-createindex.html>, [N6] <https://www.postgresql.org/docs/17/sql-altertable.html>,
[N8] <https://github.com/sbdchd/squawk>, [N9] <https://squawkhq.com/docs/cli>.

## Thông tin thêm

Phụ lục: [`appendix/0068-zero-downtime-migrations.md`](appendix/0068-zero-downtime-migrations.md) (bảng phương án, khoá theo lệnh, version
squawk đã kiểm, số đo diễn tập, nguồn).
