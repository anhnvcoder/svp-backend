# 0081. Số tài nguyên mỗi root Terraform của svp-infra sinh từ plan giả offline, không viết tay

- Trạng thái: Chấp nhận
- Ngày: 2026-11-21
- Người quyết: người học (2026-11-21: chọn plan giả qua `terraform test`), AI đề xuất và so phương án

## Bối cảnh và vấn đề

Người học cần biết trước khi chạy một root Terraform của `svp-infra` nó tạo gì và bao nhiêu tài nguyên, để chạy một lần là đúng.
Bảng số viết tay ở runbook (N1 của `accounts-setup.md`…) lệch code mỗi khi root hay cờ chi phí đổi, nên người học phải sửa đi sửa lại
plan. Bảng của terraform-docs trong README của root liệt kê khai báo, không đếm bản của `for_each`, `count`, và không chia theo phần.
Repo public, CI không có credential AWS, nên số phải tính được mà không chạm account.

## Yếu tố quyết định

- Một nguồn sự thật: số đổi cùng code, lệch thì phép kiểm đỏ.
- Đếm đúng `for_each`, `count`, module lồng.
- Chạy được ở CI và trên máy mà không credential, không mạng ở lượt plan.
- Không đọc file cá nhân (`*.auto.tfvars`, `backend*.hcl`, `.envrc`, state).

## Phương án đã cân nhắc

- Bảng viết tay ở runbook: dễ đọc, nhưng lệch code và không có phép kiểm.
- terraform-docs: sinh từ code, nhưng đếm khai báo, không đếm `for_each`, `count`, không chia phần.
- Đếm tĩnh từ file `.tf`: không cần Terraform, nhưng không biết `for_each` theo giá trị, module lồng, `count` có điều kiện.
- `terraform plan` thật trên account: số đúng nhất, nhưng cần credential, không chạy được ở CI, và phản ánh trạng thái account.
- Plan giả qua `terraform test` với `mock_provider` trong container không mạng: đếm đủ `for_each`, `count`, module; offline; chạy ở CI.

## Kết quả quyết định

Chọn plan giả, vì chỉ phương án này vừa đếm đúng vừa chạy được ở CI mà không credential. `make inventory` chạy `terraform test` trên
bản chép của cây repo (đã bỏ mọi file cá nhân) với provider giả, lấy plan JSON, đếm theo phần, loại, hành động, rồi ghi
`docs/reference/inventory.md` và một sơ đồ D2 mỗi root (mỗi env). `make inventory-check` sinh vào thư mục tạm và đỏ, nêu file, khi bản
commit lệch. Runbook link tới trang sinh thay vì chép số.

### Hệ quả

- Tốt: một nguồn sự thật cho số tài nguyên; số lệch code thì CI đỏ; không credential, không phí; sơ đồ cùng nguồn với bảng.
- Xấu: mock không biết trạng thái thật, nên bảng là "account trống chạy lần đầu"; giá trị giả của data source phải giữ ở
  `ci/inventory/` và sửa khi root đổi; job `check-test` của CI chạy lâu thêm.
- Xem lại khi: `terraform test` đổi định dạng plan JSON, hay thời gian thêm của job `check-test` thành nút cổ chai của PR.

## Xác nhận

`make inventory` hai lượt liền ra cùng byte; `make inventory-check` xanh với bản commit, đỏ và nêu file khi sửa tay một số;
`make inventory-test` kiểm luật an toàn của bộ sinh (lượt plan `--network none`, không biến `AWS_*`, bản chép không chứa file cá nhân).
Số đo stg khớp 68 tài nguyên của runbook; prd 80 so với 79 của runbook cũ, khác một bản ghi uỷ quyền DNS do giá trị ví dụ.

## Hiện thực ở

- `svp-infra`: `ci/inventory.sh` (bộ sinh và phép kiểm), `ci/inventory-test.sh` (self-test), `ci/inventory/` (giá trị giả mỗi root),
  `Makefile` (`inventory`, `inventory-check`, `inventory-test`), `.github/workflows/check.yml` (job `check`),
  `docs/reference/inventory.md`, `docs/diagrams/inventory/` và `docs/diagrams/icons/` (trang, sơ đồ, icon sinh ra hay dùng).

## Nguồn

- `terraform test` và `mock_provider`: <https://developer.hashicorp.com/terraform/language/tests>
- terraform-docs: <https://terraform-docs.io>
