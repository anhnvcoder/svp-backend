# 0085. Buổi AWS chạy bằng `session.sh up|check|down` gọi các script bước có sẵn, script bước giữ nhỏ

- Trạng thái: Chấp nhận
- Ngày: 2026-11-25
- Người quyết: AI quyết thay người học theo uỷ quyền (2026-11-25: người học thấy ngợp với số lệnh của một buổi stg)

## Bối cảnh và vấn đề

- Một buổi của `svp-infra` là bảng Thứ tự 31 bước của `docs/runbooks/session-<env>.md`, cộng các bước chen giữa (tunnel, làm nóng cache,
  phép kiểm của bước 16): khoảng 30 lệnh của gần 20 script dưới `aws/scripts/`. `session.sh --print` chỉ in chuỗi lệnh, không chạy.
- Buổi stg đầu tiên kéo dài 4h29m từ `session-start` tới quét xong, gồm khoảng một giờ sửa apply đỏ và deadlock. Người học phải giữ thứ tự
  trong đầu, chép từng lệnh, nhớ bước nào đã xong sau mỗi lần sửa, và không trang nào nói script nào làm gì.
- Mỗi script bước đã kiểm account, ghi mốc vào `timeline.tsv` của buổi, có `--print` và test giả trong `session-test.sh`; các luật thứ tự
  (`tf.sh` từ chối `gitops plan --destroy` trước `pre-destroy-done`, `env destroy` trước `backup-drained`) nằm trong chính chúng.

## Yếu tố quyết định

- Người học chạy buổi bằng ít lệnh, biết đang ở bước nào, chạy tiếp được sau một bước đỏ mà không làm lại bước đã xong.
- Mọi apply, destroy vẫn qua plan lưu file mà người học đọc rồi tự gõ `yes`; không gì trả lời thay người.
- Không viết lại logic của script bước; một bước chạy tay hay qua lệnh gói cho cùng kết quả.
- Mọi hành vi thử được offline bằng lệnh giả, như các script hiện có.

## Phương án đã cân nhắc

- **Lệnh gói `up|check|down` trong `session.sh`, gọi script bước:** ba lệnh cho cả buổi, script bước giữ nguyên. Mất: thêm một lớp, test
  phải phủ thứ tự, câu hỏi và chạy tiếp.
- Giữ runbook là đường duy nhất: không thêm code; người học tiếp tục chép 30 lệnh và tự nhớ chỗ dở.
- Gộp mọi script vào một chương trình lớn (một CLI có lệnh con): một chỗ gọi, nhưng mất chạy lại riêng một bước, test lớn khó đọc, và
  logic thứ tự đã có trong từng script phải chuyển chỗ.
- Công cụ điều phối có sẵn (Make, Taskfile, `just`): khai báo phụ thuộc, nhưng không biết dừng hỏi sau plan, không đọc timeline để chạy tiếp
  từ chỗ dở; thêm một dependency cho việc bash đã làm được.

## Kết quả quyết định

Chọn lệnh gói trong `session.sh`, vì ba lệnh đủ cho cả buổi mà mỗi script bước vẫn nhỏ, chạy riêng và thử riêng được.

### 1. Ba lệnh

- `up <env>`: bước 1–15 của bảng Thứ tự, thêm `preflight.sh plugin` đầu tiên và làm nóng cache (`deploy/ci/image-list.sh` rồi
  `ecr-warm.sh`) sau `bootstrap.sh secrets`.
- `check <env>`: phép kiểm `lõi` đọc được bằng script, in bảng `PASS`/`FAIL`; phép `lõi` cần người của env đó (trình duyệt, hộp thư,
  bản phát hành qua `svp-gitops`, phép chưa có script) in dòng `HAND` trỏ tới trang kiểm. Chỉ đọc; không gọi lệnh ghi nào.
- `down <env>`: bước 20–31. Phép `chuẩn ngành` (thang k6, diễn tập 17–19) vẫn chạy tay theo runbook.
- `prd` dùng cùng cơ chế; bước tay của `session-prd.md` (đổi cờ, cổng promote, xoá snapshot cuối, trả cờ) là dòng `hand` trong danh sách
  bước: lệnh in trang và việc cần làm, chờ người học xác nhận.

### 2. Dừng hỏi và chạy tiếp

- Sau mỗi plan có file, lệnh in đường dẫn file text và dòng `Plan:`, chờ người học gõ `yes` ở terminal: apply một plan đã lưu không hỏi
  lại [N1], nên câu hỏi này là cổng người duy nhất. stdin không phải terminal (`-t 0` [N2]) thì `up`, `down` từ chối trước bước đầu.
- Bước cần API kiểm tunnel trước; tunnel chưa mở thì nhắc lệnh mở và hỏi lại.
- Mỗi bước xong ghi mốc `up <n>: <bước>` (hay `down <n>`) vào `timeline.tsv` có sẵn. Lần chạy sau đọc mốc cuối, bỏ bước đã xong, in bước bắt
  đầu. Bước plan không ghi mốc, bước apply của nó mới ghi: sau một apply đỏ hay một câu trả lời khác `yes` thì plan lại.
- Timeline trống thì không ghi mốc: `check-account.sh` mở nó bằng `session-start` như khi chạy tay, và `measure.sh` tính mốc 3 giờ từ đó.
  Các bước trước nó chỉ đọc hay hỏi người học, nên chạy lại khi lệnh dừng trước `check-account.sh`.
- Bước đỏ dừng cả lệnh, in lệnh `session.sh` chạy lại bước đó. Lệnh không gợi ý chạy riêng script của bước: bước chạy riêng không ghi mốc,
  nên `session.sh` chạy nó lần nữa.

### 3. Danh sách bước là dữ liệu

Mỗi bước một dòng: lệnh, env áp dụng, cần tunnel, file plan và file text của plan, script và đối số; mỗi phép tay của `check` một dòng có
cột env, vì trang kiểm của hai env có phép `lõi` khác nhau. Không nhánh theo tên env; env khác nhau ở cột env và ở `env_table` của
`lib.sh`, như các script bước.

### 4. Trang bản đồ script

`docs/reference/scripts.md` của `svp-infra` tả mỗi script theo cùng khuôn (làm gì, khi nào, lệnh, đầu vào, thay đổi trong AWS, output
đúng, đỏ thì làm gì, chạy lại có an toàn không, test), lấy từ code và comment đầu file.

### Hệ quả

- Tốt: một buổi `lõi` là ba lệnh; chỗ dở nằm trong timeline của buổi, không trong trí nhớ; script bước và runbook không đổi.
- Xấu: thêm một lớp phải giữ khớp với bảng Thứ tự (test so danh sách bước với bảng của runbook); test giả phải phủ thêm câu hỏi, chạy
  tiếp, tunnel và bước tay của prd; người học ít thấy từng lệnh hơn khi chạy qua lệnh gói (bù bằng `--print` và trang bản đồ).
- Xem lại khi: một bước cần quyết định khác `yes`/dừng (chọn nhánh), hay số bước tay của prd vượt số bước script; khi đó tách lệnh gói của
  prd hay đổi sang công cụ điều phối có sẵn.

## Xác nhận

- `make session-test` của `svp-infra`: thứ tự của `up`, `down` khớp bảng Thứ tự của `session-stg.md`, `session-prd.md`; hai lần hỏi; từ chối
  khi stdin không phải terminal; chạy tiếp từ mốc; dừng ở bước đỏ; nhắc tunnel; bước riêng của prd; `check-account.sh` thật mở timeline
  bằng một `session-start`; `check` chỉ đọc, đỏ đúng phép, dòng `HAND` theo env; `--print` giữ đầu ra cũ. `make shellcheck` trên
  `session.sh`, `session-test.sh`.
- Buổi stg sau: chạy `up`, `check`, `down` cả buổi; ghi số lần chạy tiếp và bước nào cần.

## Hiện thực ở

- `svp-infra`: `aws/scripts/session.sh` (§1, §2, §3), `aws/scripts/session-test.sh` (§1, §2); `docs/reference/scripts.md` (§4),
  `docs/reference/operations.md`, `docs/runbooks/README.md` (dẫn tới trang bản đồ).

## Nguồn

Đọc 2026-11-25.

- [N1] Terraform, "Command: apply" (saved plan, `-auto-approve`): <https://developer.hashicorp.com/terraform/cli/commands/apply>
- [N2] Bash Reference Manual, "Bash Conditional Expressions" (`-t fd`):
  <https://www.gnu.org/software/bash/manual/html_node/Bash-Conditional-Expressions.html>
