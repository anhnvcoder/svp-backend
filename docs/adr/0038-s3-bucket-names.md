# 0038. Tên bucket S3 của `svp-infra` theo `<tên>-<account>-<region>`, không phần ngẫu nhiên

- Trạng thái: Chấp nhận
- Ngày: 2026-11-01
- Người quyết: người học

## Bối cảnh và vấn đề

Tên bucket S3 là duy nhất toàn cầu, tối đa 63 ký tự, chữ thường [N1]. [ADR-0034](0034-aws-stage7.md) đặt tên bucket state
(`svp-tfstate-<8 hex>`) và hai bucket `uploads`, `media` (`<tiền tố>-uploads-<8 hex>`) bằng hậu tố `random_id`, với luật "không tên nào
ghép từ account ID" để không file commit hay output nào chứa account. Hậu tố ngẫu nhiên làm tên không nói gì: nhìn danh sách bucket hay
URL presigned không biết bucket thuộc account, region nào; tên chỉ biết sau `apply` đầu (provider `random` thêm vào hai thư mục chỉ vì nó).

## Yếu tố quyết định

- Tên duy nhất toàn cầu, biết lúc `plan`, đọc ra account và region.
- Account thật không nằm trong file commit nào (repo public).
- Theo cách AWS tự đặt tên bucket của chính nó.

## Phương án đã cân nhắc

- A. Giữ `<tên>-<8 hex>` ngẫu nhiên.
- B. `<tên>-<account>-<region>`.

## Kết quả quyết định

Chọn B cho mọi bucket của `svp-infra`: `svp-tfstate-<account>-<region>`, `<name_prefix>-uploads-<account>-<region>`,
`<name_prefix>-media-<account>-<region>`. Đây là quy ước của bucket do AWS tạo: bucket bootstrap của AWS CDK
`cdk-<qualifier>-assets-<account>-<region>` (ví dụ của trang: `cdk-hnb659fds-assets-012345678910-us-west-1`) [N2], bucket log của
Control Tower `aws-controltower-logs-<account>-<region>` (trang tài nguyên của Control Tower chỉ ghi tiền tố `aws-controltower-logs-*`) [N3].
Account vào tên lúc chạy, từ `var.account_id` (`TF_VAR_account_id`), nên luật "account không vào file commit" giữ nguyên; luật "tên không
ghép từ account ID" bỏ. `name_prefix` của module media tối đa 27 ký tự để `<prefix>-uploads-<12 số>-<region ≤ 14>` không quá 63.

### Hệ quả

- Tốt: tên đọc ra account và region; không cần provider `random` ở bootstrap và module media; tên biết lúc `plan`.
- Xấu: account ID lộ ra ngoài: tên bucket `uploads` nằm trong mọi URL form upload presigned trình duyệt thấy. AWS không coi account ID là
  bí mật [N4], và quyền vẫn do IAM, policy bucket quyết.
- Xấu: tên đoán được. Người khác tạo trước bucket cùng tên thì `apply` lỗi `BucketAlreadyExists`; chỉ chặn, không ghi nhầm (service đọc
  tên bucket từ output của bucket Terraform đã tạo).
- Xấu: bucket sót của một `destroy` dở trùng tên với lần `apply` sau; script quét sót (`aws/scripts/sweep.sh`) liệt kê nó theo tiền tố tên `svp-`, người học xoá trước khi `apply` theo runbook của buổi.
- Một lần: bucket state đã tạo dưới tên cũ phải chuyển state và xoá bucket cũ (người học chạy; các bước ở mô tả PR của thay đổi này).
- Xem lại khi: một bucket cần tên không theo account (bucket dùng chung nhiều account), hay AWS đổi khuyến nghị về account ID.

## Xác nhận

`make check` của `svp-infra` (validate, tflint với `terraform_unused_required_providers`) xanh khi bỏ `random_id` và provider `random`;
không file commit nào chứa account thật (ví dụ và test dùng `000000000000`). Chưa kiểm trên account: bước đổi tên bucket state và buổi
AWS stg do người học chạy.

## Ưu nhược từng phương án

### A. Hậu tố ngẫu nhiên

- Tốt: tên không lộ account; bucket sót không trùng tên với lần `apply` sau.
- Xấu: tên không nói gì; biết sau `apply`; thêm provider `random`.

### B. `<tên>-<account>-<region>`

- Tốt: như mục Kết quả quyết định.
- Xấu: như mục Hệ quả.

## Hiện thực ở

- `svp-infra` `aws/bootstrap/state.tf`: tên bucket state; `aws/bootstrap/README.md`: bảng tài nguyên.
- `svp-infra` `aws/modules/media/s3.tf`, `variables.tf` (`account_id`, `region`, giới hạn `name_prefix`); `aws/envs/stg/main.tf` truyền
  `account_id`, `region`.
- `svp-infra` `AGENTS.md`, `README.md`: luật tên bucket.
- `deploy/ci/cluster-values.example.yaml`: dạng `uploadsBucket`, `mediaBucket`.

## Nguồn

- [N1] [Amazon S3: General purpose bucket naming rules](https://docs.aws.amazon.com/AmazonS3/latest/userguide/bucketnamingrules.html)
- [N2] [AWS CDK: Bootstrapping your environment](https://docs.aws.amazon.com/cdk/v2/guide/bootstrapping-env.html)
- [N3] [AWS Control Tower: Resources created in shared accounts](https://docs.aws.amazon.com/controltower/latest/userguide/shared-account-resources.html)
- [N4] [AWS Account Management: View AWS account identifiers](https://docs.aws.amazon.com/accounts/latest/reference/manage-acct-identifiers.html)
