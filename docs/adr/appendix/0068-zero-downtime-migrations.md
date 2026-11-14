# Phụ lục ADR-0068: Migration Postgres không downtime: expand/contract mỗi bước một release, schema phục vụ cả bản trước; `lock_timeout` 2 s ở runner; luật file migration theo khoá; squawk lint trong CI; diễn tập đổi tên cột bằng test Go

Phụ lục của [ADR-0068](../0068-zero-downtime-migrations.md): bảng phương án, khoá theo lệnh, version squawk đã kiểm, số đo diễn tập, nguồn. Mọi
nguồn đọc ngày 2026-11-14; số sao, ngày phát hành đọc từ API GitHub cùng ngày.

## Phương án

| Mục | Phương án | Trạng thái ngành | Được | Mất | Nguồn |
| --- | --- | --- | --- | --- | --- |
| Đổi schema | **Luật expand/contract viết tay trên goose** | Hiện hành: parallel change, cách GitLab và đa số đội dùng với công cụ migration SQL | Giữ goose, `embed`, advisory lock, Job `migrate`; mỗi bước là SQL đọc được, review được | Người viết phải theo luật; đổi tên tốn sáu release; cần lint và test để giữ luật | [N17], [N18] |
| Đổi schema | pgroll | Mới (v0.16.3, 2026-09-08; chưa 1.0; ~6,6 nghìn sao) | Tự tạo schema version bằng view và trigger, bản cũ và mới chạy cùng lúc trong một migration | Thay goose; migration viết JSON/YAML; app phải đặt `search_path` theo version; thêm trạng thái của pgroll trong database | [N13] |
| Đổi schema | Reshape | Mới, một người giữ (v0.11.2, 2026-09-09; ~1,9 nghìn sao) | Cùng ý với pgroll, migration TOML | Thay goose; cộng đồng nhỏ; app cũng đặt `search_path` theo version | [N14] |
| Lint | **squawk** | Hiện hành (v2.72.0, 2026-11-08; ~1,3 nghìn sao; phát hành vài tuần một lần) | Luật riêng cho khoá Postgres; image chính thức trên GHCR; `squawk-ignore` theo câu; MIT hoặc Apache-2.0 | Không đọc chú thích goose (cần §10 của ADR); image chỉ `linux/amd64` | [N8], [N9], [N19] |
| Lint | Atlas `migrate lint` | Hiện hành, nhưng chỉ cho Atlas Pro từ v0.38 | Phân tích có database dev, nhiều engine | Cần `atlas login` và gói trả phí; gắn với Atlas làm công cụ migration | [N15] |
| Lint | eugene | Mới, ít người dùng (0.8.3, 2026-03-11; ~70 sao) | Lint và chế độ trace chạy migration trên Postgres tạm để thấy khoá thật | Một người giữ, phát hành thưa; không có image chính thức | [N16] |
| Lint | Chỉ review tay | Cũ | Không thêm công cụ | Sót câu khoá bảng; không chặn được ở CI | — |
| `lock_timeout` | **Ở runner, mọi kết nối** (runtime parameter của pgx) | Hiện hành; squawk khuyên đặt ở kết nối (`PGOPTIONS='-c lock_timeout=1s'`) | Mọi migration có ngưỡng, kể cả file quên; một chỗ đọc lại và log | Ngưỡng khác phải đặt trong file; luật squawk đòi `SET` trong file phải tắt | [N1], [N12] |
| `lock_timeout` | `SET` trong từng file | Hiện hành (mặc định của squawk) | Thấy ngay trong file | File quên thì không có; `SET` phiên của file `NO TRANSACTION` lan sang file kế | [N2], [N3], [N10] |
| `lock_timeout` | `ALTER ROLE <migrator> SET lock_timeout` | Hiện hành | Áp cả phiên tay của role migrator | Trạng thái nằm trong database, tạo bởi script bootstrap khác nhau ở compose, CNPG, RDS; không thấy trong code của runner | [N1] |
| Contract | Cùng release với expand, trong PreSync | — | Một release | Phá bất biến hai bản: pod N-1 chạy trên schema đã mất cột nó dùng | — |
| Contract | Hook PostSync của release mới | Hiện hành trong Argo CD cho việc sau sync | Chạy sau khi pod mới khoẻ | N-1 là đích quay lại nhưng schema đã contract; thêm một loại hook; contract không thành PR riêng | [N21] |
| Contract | **Release riêng sau đó** | Hiện hành (parallel change) | Một cơ chế (Job PreSync); contract là PR review được; giữ bất biến hai bản | Thêm release, chờ bản trước ra prd | [N18] |

## Khoá theo lệnh

Theo tài liệu PostgreSQL 17 [N6], [N4], [N20], [N11] và mã nguồn [N24]. "Chặn" là chặn đọc (`ACCESS SHARE`) hay ghi (`ROW EXCLUSIVE`)
của app trong lúc giữ khoá. Một yêu cầu khoá đang chờ cũng chặn mọi yêu cầu xung đột đến sau nó, nên DDL chờ `ACCESS EXCLUSIVE` làm cả
`SELECT` xếp hàng [N12]: đó là lý do có ngưỡng ở runner, dưới hạn 3 s của request; cận dưới của nó ở
[Ngưỡng của runner và autovacuum](#ngưỡng-của-runner-và-autovacuum).

| Lệnh | Khoá trên bảng | Chặn | Quét hay viết lại | Luật của ADR |
| --- | --- | --- | --- | --- |
| `ADD COLUMN` không default hay default không volatile | `ACCESS EXCLUSIVE` | Đọc, ghi (ngắn) | Không | §3 (1) |
| `ADD COLUMN` default volatile | `ACCESS EXCLUSIVE` | Đọc, ghi suốt lượt viết lại | Viết lại bảng và index | Cấm, §6 (g) |
| `ALTER COLUMN TYPE` (trừ đổi binary coercible) | `ACCESS EXCLUSIVE` | Đọc, ghi suốt lượt viết lại | Viết lại bảng và index | Cấm, §6 (g) |
| `RENAME COLUMN` | `ACCESS EXCLUSIVE` | Đọc, ghi (ngắn) | Không, nhưng code N-1 hỏng | Cấm, §3 |
| `DROP COLUMN` | `ACCESS EXCLUSIVE` | Đọc, ghi (ngắn) | Không (cột chỉ bị ẩn) | Chỉ (5b) |
| `ALTER COLUMN SET NOT NULL` | `ACCESS EXCLUSIVE` | Đọc, ghi suốt lượt quét | Quét, trừ khi có `CHECK` valid chứng minh không có NULL | §6 (d) file 3 |
| `ALTER COLUMN DROP NOT NULL` | `ACCESS EXCLUSIVE` | Đọc, ghi (ngắn) | Không | (5a) |
| `ADD CONSTRAINT … CHECK … NOT VALID` | `ACCESS EXCLUSIVE` | Đọc, ghi (ngắn) | Không | §6 (c), (d) file 1 |
| `ADD CONSTRAINT … FOREIGN KEY … NOT VALID` | `SHARE ROW EXCLUSIVE` trên hai bảng | Ghi (ngắn) | Không | §6 (c) |
| `VALIDATE CONSTRAINT` | `SHARE UPDATE EXCLUSIVE` | Không | Quét | §6 (c), (d) file 2 |
| `ADD CONSTRAINT … UNIQUE USING INDEX` | `ACCESS EXCLUSIVE` | Đọc, ghi (ngắn) | Không | §6 (e) |
| `DROP CONSTRAINT` | `ACCESS EXCLUSIVE` | Đọc, ghi (ngắn) | Không | §6 (d) file 3 |
| `CREATE INDEX` | `SHARE` | Ghi suốt lượt dựng | Quét | Chỉ bảng mới tạo |
| `CREATE INDEX CONCURRENTLY` | `SHARE UPDATE EXCLUSIVE` | Không | Hai lượt quét, chờ transaction | §6 (a) |
| `DROP INDEX` | `ACCESS EXCLUSIVE` | Đọc, ghi (ngắn) | Không | Thay bằng `CONCURRENTLY` |
| `DROP INDEX CONCURRENTLY` | `SHARE UPDATE EXCLUSIVE` [N24], chờ transaction xung đột | Không | Không | §6 (a) |
| `UPDATE` một lô | `ROW EXCLUSIVE` và khoá dòng | Ghi đúng các dòng của lô | Theo lô | §7 |

`SET NOT NULL` bỏ quét chỉ khi check valid không bị xoá trong cùng lệnh [N6]: file 3 của §6 (d) viết `SET NOT NULL` và `DROP CONSTRAINT` bằng hai câu
`ALTER TABLE`. Nhiều lệnh con trong một `ALTER TABLE` lấy khoá mạnh nhất trong số chúng [N6].

### Hai điểm kiểm theo tài liệu

- `SET LOCAL` ngoài transaction block: "emits a warning and otherwise has no effect" [N2]. File `-- +goose NO TRANSACTION` không ở trong
  transaction block, nên ngưỡng riêng của nó phải là `SET` phiên rồi `RESET`. goose lấy một `*sql.Conn` cho cả lượt `Up` (`initialize` trong
  `provider_run.go` của v3.29.0) [N3], nên `SET` phiên không `RESET` áp cho mọi migration sau nó trong lượt.
- CIC và `lock_timeout`: tài liệu nói `lock_timeout` áp cho từng lượt lấy khoá, cả khoá ngầm, trên "table, index, row, or other database object"
  [N1]; CIC "must wait for all existing transactions that could potentially modify or use the index to terminate", và sau lượt quét thứ hai
  "must wait for any transactions that have a snapshot … predating the second scan to terminate" [N4]: lượt chờ sau gồm mọi transaction của
  cả database có snapshot cũ hơn, kể cả transaction trên bảng khác. Mã nguồn `indexcmds.c` của nhánh 17 chờ bằng `WaitForLockers` và
  `VirtualXactLock`, tức lấy khoá trên virtual transaction id của transaction kia [N5], nên lượt chờ chịu `lock_timeout`. Hết hạn thì CIC lỗi
  và để lại index `INVALID` [N4], lý do của `DROP INDEX CONCURRENTLY IF EXISTS` đứng trước.

### Ngưỡng của runner và autovacuum

Autovacuum giữ `SHARE UPDATE EXCLUSIVE` trên bảng nó đang dọn; khoá này xung đột với `ACCESS EXCLUSIVE` của `ALTER TABLE`, với `VALIDATE`
và CIC [N11]. Tài liệu nói một yêu cầu khoá xung đột với autovacuum sẽ ngắt nó, trừ autovacuum chống wraparound (tên truy vấn trong
`pg_stat_activity` kết thúc bằng `(to prevent wraparound)`) [N22]. Lúc ngắt nằm ở `ProcSleep` của `proc.c` [N23]: tiến trình chờ khoá chỉ kiểm
deadlock khi timer `deadlock_timeout` hết, lượt kiểm đó mới thấy autovacuum chặn và gửi tín hiệu huỷ. `lock_timeout` là timer riêng; hết cùng
lúc hay trước `deadlock_timeout` thì lỗi `55P03` được ném trước khi autovacuum bị huỷ, và lượt thử lại gặp lại đúng autovacuum đó.

- Cận dưới: lớn hơn `deadlock_timeout`. Mặc định 1 s; parameter group của RDS (`aws/modules/rds` của `svp-infra`) không đặt nó, compose và
  CNPG cũng giữ mặc định. 2 s để autovacuum bị huỷ ở giây thứ nhất và DDL còn khoảng một giây lấy khoá.
- Cận trên: dưới hạn 3 s mỗi lời gọi của gateway, vì mọi request đến sau trên bảng xếp hàng sau DDL đang chờ.
- Autovacuum chống wraparound không bị huỷ: DDL lỗi `55P03` ở mọi lượt cho tới khi nó xong; đó là đúng, vì huỷ nó làm database tiến gần
  wraparound. Người vận hành chờ nó xong rồi sync lại.

### Ngưỡng của file CIC

`SET lock_timeout = '30s'`. Lượt chờ của CIC giữ `SHARE UPDATE EXCLUSIVE`, khoá này không xung đột với `ACCESS SHARE`, `ROW EXCLUSIVE` của
app [N11], nên chờ lâu không chặn đọc ghi; chỉ DDL khác, `VACUUM`, `ANALYZE` trên bảng phải đợi. Lượt chờ cuối của CIC gồm mọi transaction
có snapshot cũ hơn trong cả database, không chỉ trên bảng ("Hai điểm kiểm theo tài liệu"), nên ngưỡng tính theo transaction dài nhất của
database. Transaction của request bị bó bởi hạn 3 s mỗi lời gọi của gateway; 30 s gấp mười lần, nên lỗi `55P03` ở đây báo một transaction
không thuộc request (phiên tay, sao lưu, truy vấn phân tích, việc nền chạy lâu) cần người xem. `activeDeadlineSeconds: 300` của Job vẫn là
trần của cả lượt chạy.

## squawk

Kiểm ngày 2026-11-14:

- Bản mới nhất: **v2.72.0**, phát hành 2026-11-08 (<https://github.com/sbdchd/squawk/releases/tag/v2.72.0>) [N8].
- Image chính thức `ghcr.io/sbdchd/squawk`, tag **`2.72.0`** (không tiền tố `v`; cũng có `2.72`, `latest`), manifest index
  `sha256:b7c8c1ad82439744e676c0c0b2447d95ea0866f72ae1f4095d8653dfc89db916`, đọc bằng registry API của GHCR không đăng nhập [N19]. Index chỉ
  có `linux/amd64` (cộng một manifest attestation); trên máy arm64 container chạy giả lập. `ENTRYPOINT ["squawk"]`, user `squawk`, `WORKDIR /data`
  (Dockerfile của repo).
- Giấy phép: MIT hoặc Apache-2.0 (`LICENSE-MIT`, `LICENSE-APACHE`).
- Cấu hình: `.squawk.toml` có `pg_version`, `excluded_rules`, `excluded_paths`, `assume_in_transaction`; comment `-- squawk-ignore <rule>[, …]`
  áp cho câu ngay dưới, `-- squawk-ignore-file`, `-- squawk-disable-assume-in-transaction` theo file [N9].
- Luật mặc định: mọi luật trừ nhóm opt-in (`Rule::is_opt_in` của `crates/squawk_linter/src/lib.rs` ở tag v2.72.0) [N10].
  `require-lock-timeout` và `require-statement-timeout` bật mặc định; `require-timeout-settings` là bí danh cũ của cả hai, opt-in.
  `ban-drop-constraint` bật mặc định.
- Luật dự kiến báo câu mà ADR bắt buộc, theo tài liệu từng luật của v2.72.0: `ban-drop-not-null` ((5a)), `ban-drop-column` ((5b), Down),
  `adding-not-nullable-field` (`SET NOT NULL` của §6 (d) file 3), `ban-drop-constraint` (`DROP CONSTRAINT` của file 3), `ban-drop-table` (Down).
  Luật thật sự báo lấy từ output lint, ghi ở `.squawk.toml` và comment cạnh câu.

## Số đo diễn tập

Hai lượt `make migration-drill` (ba test `TestRenameDrill*` của `internal/dbmigrate`, không `-race`) ngày 2026-11-14 trên Postgres native của
máy phát triển, **PostgreSQL 15.19** (Homebrew): lượt mặc định nạp 1 000 000 dòng, lượt thứ hai cùng lệnh với `SVP_DRILL_ROWS=3000000`. Job của
CI chạy cùng test với Postgres 17 và 20 000 dòng, nên số ở đây là số của Postgres 15 trên một máy, không phải của RDS: pod là goroutine, không
có mạng hay PgBouncer. Cột "thao tác" là số đọc và ghi của mọi pod trong lúc migration và lúc hai bản chạy cùng nhau ở bước đó; "lỗi" là bản
trước / bản mới; p99 và max là độ trễ của client trong lúc migration chạy.

`TestRenameDrill`, sáu release của §3, 1 000 000 dòng (cả lượt 31,4 s):

| Bước | Migration | Thao tác | Lỗi | p99 | max |
| --- | --- | --- | --- | --- | --- |
| (1) expand | 9 ms | 28 312 | 0 / 0 | 3,372 ms | 3,372 ms |
| (2) ghi kép | 6 ms | 28 174 | 0 / 0 | 403 µs | 422 µs |
| (3) backfill, `NOT NULL` | 3,215 s | 113 555 | 0 / 0 | 636 µs | 154,511 ms |
| (4) đọc cột mới | 9 ms | 29 136 | 0 / 0 | 320 µs | 464 µs |
| (5a) `DROP NOT NULL` | 10 ms | 29 456 | 0 / 0 | 657 µs | 999 µs |
| (5b) `DROP COLUMN` | 11 ms | 28 742 | 0 / 0 | 1,007 ms | 1,217 ms |

Cùng test, 3 000 000 dòng (cả lượt 81,1 s; lượt này chỉ ghi max của bước (3)):

| Bước | Migration | Thao tác | Lỗi | p99 | max |
| --- | --- | --- | --- | --- | --- |
| (1) expand | 12 ms | 26 426 | 0 / 0 | 6,365 ms | — |
| (2) ghi kép | 8 ms | 28 104 | 0 / 0 | 328 µs | — |
| (3) backfill, `NOT NULL` | 10,475 s | 334 374 | 0 / 0 | 613 µs | 177,403 ms |
| (4) đọc cột mới | 9 ms | 27 130 | 0 / 0 | 537 µs | — |
| (5a) `DROP NOT NULL` | 10 ms | 27 100 | 0 / 0 | 788 µs | — |
| (5b) `DROP COLUMN` | 10 ms | 27 746 | 0 / 0 | 1,018 ms | — |

`TestRenameDrillNaive` (`RENAME COLUMN` trong một release): 1 000 000 dòng, migration 9 ms, 28 608 thao tác, **15 292 lỗi** ở pod bản trước và
0 ở bản mới; 3 000 000 dòng, 11 ms, 28 626 thao tác, **15 885 lỗi** và 0. Lỗi đầu là `42703 column "title" does not exist`.

`TestRenameDrillLockTimeout` (một transaction giữ `ACCESS SHARE` 4 s trong lúc migration expand chạy), 1 000 000 dòng:

| Ca | Migration | Thao tác | Lỗi client | p99 | max |
| --- | --- | --- | --- | --- | --- |
| `lock_timeout` của runner | 2,094 s, lỗi `55P03` | 99 | 0 | 2,086 s | 2,086 s |
| chạy lại sau khi giao dịch kết thúc | 8 ms | 103 174 | 0 | 678 µs | 731 µs |
| đối chứng: `lock_timeout = 0` trong file | 4,012 s | 104 | 4 (quá hạn 3 s) | 3,002 s | 3,002 s |

Lượt 3 000 000 dòng cho cùng hình: runner lỗi `55P03` sau 2,13 s, 0 lỗi client; chạy lại 11 ms; đối chứng 4,009 s, 4 lỗi quá hạn.

Đọc bảng: sáu release không lỗi nào ở cả hai bản; p99 của client trong lúc backfill dưới 1 ms (max 154,511 ms và 177,403 ms: lô giữ khoá dòng
ngắn); `RENAME COLUMN` làm bản trước lỗi gần như mọi thao tác. Với ngưỡng khoá, migration lỗi sau 2,09–2,13 s, trong hạn 3 s của request, và
client không lỗi; không có ngưỡng, migration chờ 4 s và request quá hạn.

Chi phí backfill tuyến tính: bước (3) với 3 000 000 dòng mất 10,475 s, gấp 3,26 lần 3,215 s của 1 000 000 dòng, tức khoảng 3,5 s mỗi triệu
dòng trên máy này. Cách cũ chọn lại `WHERE b IS NULL ORDER BY id LIMIT n` từ đầu bảng mỗi lô, đo qua `make test` (có `-race`) trên cùng máy,
cùng Postgres: 17,1 s và 3 m 37,8 s, gấp 12,7 lần cho 3 lần số dòng. Giới hạn ước theo `activeDeadlineSeconds: 300` của Job: 300 s chia
3,5 s mỗi triệu dòng là khoảng 85 triệu dòng với bảng hẹp như `items`, khi bước (3) là migration duy nhất của lượt. Đây là bậc độ lớn, không
phải cam kết: dòng rộng hơn, nhiều index, tải thật, RDS và lượt chạy có nhiều migration đều làm nó nhỏ đi; bảng tới cỡ chục triệu dòng thì
đo trên bản sao trước, hay chọn lệnh riêng của ADR §7. Cái chưa đo: khoá của bảng lớn trên RDS với tải thật; stg và prd bắt đầu rỗng.

## Nguồn

- [N1] PostgreSQL 17, Client Connection Defaults (`lock_timeout`): <https://www.postgresql.org/docs/17/runtime-config-client.html>
- [N2] PostgreSQL 17, `SET`: <https://www.postgresql.org/docs/17/sql-set.html>
- [N3] goose v3.29.0, `provider_run.go`: <https://github.com/pressly/goose/blob/v3.29.0/provider_run.go>; `-- +goose NO TRANSACTION` ở README
  của goose: <https://github.com/pressly/goose>
- [N4] PostgreSQL 17, `CREATE INDEX` (Building Indexes Concurrently): <https://www.postgresql.org/docs/17/sql-createindex.html>
- [N5] PostgreSQL, `src/backend/commands/indexcmds.c` nhánh `REL_17_STABLE`:
  <https://github.com/postgres/postgres/blob/REL_17_STABLE/src/backend/commands/indexcmds.c>
- [N6] PostgreSQL 17, `ALTER TABLE`: <https://www.postgresql.org/docs/17/sql-altertable.html>
- [N7] PostgreSQL 17, `DO`: <https://www.postgresql.org/docs/17/sql-do.html>
- [N8] squawk: <https://github.com/sbdchd/squawk>
- [N9] squawk, CLI: <https://squawkhq.com/docs/cli>; luật: <https://squawkhq.com/docs/rules>
- [N10] squawk v2.72.0, `crates/squawk_linter/src/lib.rs`:
  <https://github.com/sbdchd/squawk/blob/v2.72.0/crates/squawk_linter/src/lib.rs>
- [N11] PostgreSQL 17, Explicit Locking: <https://www.postgresql.org/docs/17/explicit-locking.html>
- [N12] squawk, Applying migrations safely: <https://squawkhq.com/docs/safe_migrations>
- [N13] pgroll: <https://github.com/xataio/pgroll>, <https://pgroll.com/docs>
- [N14] Reshape: <https://github.com/fabianlindfors/reshape>
- [N15] Atlas, Verifying migration safety (`migrate lint`): <https://atlasgo.io/versioned/lint>
- [N16] eugene: <https://github.com/kaaveland/eugene>
- [N17] GitLab, Avoiding downtime in migrations: <https://docs.gitlab.com/development/database/avoiding_downtime_in_migrations/>
- [N18] Martin Fowler, Parallel Change: <https://martinfowler.com/bliki/ParallelChange.html>
- [N19] Package `squawk` trên GHCR: <https://github.com/sbdchd/squawk/pkgs/container/squawk>
- [N20] PostgreSQL 17, `DROP INDEX`: <https://www.postgresql.org/docs/17/sql-dropindex.html>
- [N21] Argo CD, Resource Hooks: <https://argo-cd.readthedocs.io/en/stable/user-guide/resource_hooks/>
- [N22] PostgreSQL 17, Routine Vacuuming, §24.1.6 The Autovacuum Daemon: <https://www.postgresql.org/docs/17/routine-vacuuming.html>
- [N23] PostgreSQL, `src/backend/storage/lmgr/proc.c` nhánh `REL_17_STABLE` (`ProcSleep`):
  <https://github.com/postgres/postgres/blob/REL_17_STABLE/src/backend/storage/lmgr/proc.c>
- [N24] PostgreSQL, `src/backend/catalog/index.c` nhánh `REL_17_STABLE` (`index_drop`):
  <https://github.com/postgres/postgres/blob/REL_17_STABLE/src/backend/catalog/index.c>
