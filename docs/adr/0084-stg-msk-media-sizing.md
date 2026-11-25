# 0084. MSK của stg 2 × `kafka.m7g.large`, media của stg pay-as-you-go: AWS từ chối T3 cho KRaft, web ACL media cho gói Free

- Trạng thái: Chấp nhận
- Ngày: 2026-11-24
- Người quyết: người học (2026-11-24, trong buổi stg: đổi hai giá trị để apply xanh, svp-infra #71), AI đề xuất và ghi lý do

## Bối cảnh và vấn đề

- [0053](0053-msk-elasticache-valkey.md) §2 cho stg 2 × `kafka.t3.small` (prd 3 × `kafka.m7g.large`) với Kafka `4.1.x.kraft`;
  [0058](0058-managed-data-operations.md) §4 hẹn: API từ chối T3 thì dừng, viết ADR chỉnh.
- [0052](0052-cloudfront-flat-rate-free.md), [0061](0061-edge-cloudfront-waf-acm.md) §1 để distribution media của stg trên gói
  CloudFront flat-rate Free (`aws_pricingplanmanager_subscription.media`) với web ACL `svp-stg-media`: một luật rate-based theo IP, ba
  nhóm luật managed (`AmazonIpReputationList`, `CommonRuleSet`, `KnownBadInputsRuleSet`) và log WAF tới bucket của `svp-log-archive`
  ([0060](0060-org-detection-logging.md)).
- Lần apply env đầu tiên của buổi stg (2026-11-24) đỏ ở hai chỗ đó: `CreateCluster` trả "Unsupported InstanceType specified" với
  `kafka.t3.small`; `CreateSubscription` trả web ACL `svp-stg-media` "not eligible for this subscription tier". Cùng buổi,
  `RegisterScalableTarget` từ chối sàn storage autoscaling bằng cỡ volume. Lỗi nguyên văn: [phụ lục](appendix/0084-stg-msk-media-sizing.md).
- Tài liệu không báo trước: trang cỡ broker vẫn liệt kê `kafka.t3.small`, trang KRaft không nói loại broker [N1], [N2]; trang gói không
  nêu điều kiện nào của web ACL ứng câu lỗi [N3].

## Yếu tố quyết định

- Buổi stg apply xanh với cùng dịch vụ, version, cách xác thực như prd ([0055](0055-environment-matrix.md)); prd không đổi.
- Chi phí thêm mỗi buổi có nguồn; không đổi version Kafka hay phần mềm local (0053 §1).
- Không tốn thêm buổi trả tiền chỉ để dò điều kiện của gói.

## Phương án đã cân nhắc

- MSK stg: **2 × `kafka.m7g.large`** (loại của prd, API nhận); 2 × `kafka.m5.large` (nhận cho KRaft, đắt hơn m7g mỗi giờ, M7g giá trên hiệu
  năng tốt hơn [N2]); giữ T3 bằng Kafka 3.9 ZooKeeper (Kafka 4 bỏ ZooKeeper, lệch 4.1 KRaft của local, trái 0053 §1); MSK Express hay
  Serverless (đã loại ở 0053).
- Media stg: **pay-as-you-go như prd** (`media_flat_rate_free = false`); giữ gói Free và thử sửa web ACL (bỏ log WAF, bớt luật) cho tới
  khi được nhận (chưa biết điều kiện nào gây lỗi, mỗi lần thử là một lần apply trả tiền; bỏ log WAF trái 0060); gói Pro ($15 mỗi tháng
  mỗi distribution [N4]: có log WAF, 25 luật; tính theo tháng, chưa chứng minh nhận web ACL này).

## Kết quả quyết định

Chọn các phương án in đậm, vì là giá trị duy nhất đã được API nhận trong buổi, đưa stg về đúng cấu hình của prd ở hai chỗ, với chi phí thêm
đo được. Cái giá: MSK stg đắt hơn ~$0,39 mỗi giờ; mất edge $0 có trần của media stg.

### 1. MSK của stg

- `msk_broker_instance_type = "kafka.m7g.large"` ở `stg.tfvars`, cũng là mặc định của biến module `msk`; validation của module chỉ nhận
  broker Standard họ m5, m7g, m8g (`CreateCluster` từ chối họ T3 với version KRaft).
- Số broker (2, một mỗi AZ), RF 2, min ISR 1, trần dung lượng 20 GiB của stg giữ như 0053 §6, 0058 §4. prd giữ 3 × `kafka.m7g.large`.

### 2. Sàn của storage autoscaling

`aws_appautoscaling_target` của module `msk` đặt `min_capacity = 1` ở mọi env: Application Auto Scaling từ chối sàn khác cho
`kafka:broker-storage:VolumeSize`. Volume giữ cỡ lúc tạo (10 GiB), policy không thu nhỏ (`disable_scale_in`), nên hành vi của 0058 §4
không đổi.

### 3. Media của stg

`media_flat_rate_free = false` ở `stg.tfvars` như prd: không subscription gói Free; response headers policy `svp-stg-media` (CORS chỉ
origin của web, HSTS, nosniff) và log chuẩn v2 tới bucket log CloudFront của `svp-log-archive`. Đo ở buổi: `access-control-allow-origin`
bằng origin của web. Không env nào còn đăng ký gói; đường gói Free (biến `flat_rate_free` của module `media`) còn trong code, không env
nào bật.

### 4. Vì sao gói Free từ chối web ACL: chưa chứng minh

Trang gói [N3] nói: Free tối đa 5 "security rules ... including both custom rules and AWS Managed Rules"; "WAF request logs" chỉ có từ Pro;
"Rule Groups" không hỗ trợ ở gói nào. Trang không nói một nhóm luật managed tính là một luật hay số luật bên trong, không có câu lỗi nào
của `CreateSubscription`. Hai ứng viên khớp tài liệu: logging configuration của web ACL (log WAF tới S3) và cách đếm ba nhóm luật managed
(giả định của 0052 §3). Không tách được hai ứng viên mà không apply thêm trên account, nên nguyên nhân để ngỏ; câu trích đủ ở phụ lục.

### 5. Chi phí

Giá `ap-southeast-1` của Price List [N5], bảng ở phụ lục: broker `kafka.m7g.large` $0,255, `kafka.t3.small` $0,0578 mỗi broker-giờ. stg
2 broker: $0,51 mỗi giờ, thêm $0,394 so với T3 (~$1,58 mỗi buổi 4 giờ); H_k của stg ở 0053 §16 thành ~$0,538 mỗi giờ. Buổi stg 4 giờ nên
~$4,4–4,6 với node Spot, ~$5,2–5,3 on-demand (phép cộng ở phụ lục): on-demand vượt trần $5 của [0034](0034-aws-stage7.md), Spot sát trần;
"dưới trần $5" ở 0053 §16 hết đúng. Media pay-as-you-go thêm phí cố định của web ACL media ($5 ACL + 4 luật = $9 mỗi tháng [N6], ~$0,05
mỗi buổi); request, GB và log vài MB trong hạn mức miễn phí hay dưới một cent. Ước theo tháng chạy 24/7: trang chi phí của `svp-infra` dẫn
từ phụ lục này.

### 6. ADR cũ

Chỉnh (dòng `### Chỉnh bởi`): 0053 §2, §16, Hệ quả, Xác nhận; 0058 §4, Xác nhận; 0052 §2–§4, Hệ quả; 0055 §2, §3; 0061 §1, §14; 0066
(Bối cảnh); 0073 (Bối cảnh, Yếu tố quyết định). 0052 giữ Chấp nhận: WAF ở cả hai env, `PriceClass_All` (§5) và cách gỡ gói (§6) vẫn
đúng. 0049 đã bị thay bởi 0053, không chỉnh.

### Hệ quả

- Tốt: buổi stg apply xanh; MSK, edge media của stg giống prd hơn (cùng loại broker, cùng log chuẩn và response headers policy).
- Xấu: MSK stg đắt gấp ~4,4 lần mỗi giờ; media stg mất giá $0 có trần (lưu lượng vượt hạn mức miễn phí tính tiền); MSK dựng 24m54s ở buổi;
  nguyên nhân lỗi gói Free chưa rõ; đường gói Free trong module `media` không còn env nào chạy.
- Xem lại khi: MSK nhận lại một loại rẻ hơn cho KRaft; AWS ghi điều kiện web ACL của gói Free, hay cần gói cho media (khi đó thử đúng
  điều kiện đó, ADR mới); lưu lượng media của stg vượt hạn mức miễn phí.

## Xác nhận

- Buổi stg 2026-11-24 (người học chạy): apply env xanh với hai giá trị này; MSK `ACTIVE` sau 24m54s; smoke qua MSK, CDN xanh; media trả
  `access-control-allow-origin` bằng origin của web; destroy, `sweep.sh` sạch, không subscription nào còn. Số đo: phụ lục.
- Kiểm tĩnh: `make test` của `svp-infra` (`aws/modules/msk`: giá trị stg 2 × `kafka.m7g.large`, validation từ chối T3, sàn 1;
  `aws/modules/media`).

## Hiện thực ở

- `svp-infra`: `aws/envs/stg/stg.tfvars` (§1, §3); `aws/modules/msk/variables.tf`, `main.tf`, `tests/validation.tftest.hcl`, `README.md`
  (§1, §2); `aws/modules/media/cloudfront.tf` (§3); `docs/handbook/15-cost.md` (§5).
- Repo này: `docs/explanation/environments.md`, `edge.md`, `docs/threat-model.md` (§3).

## Nguồn

Đọc 2026-11-24; câu trích ở phụ lục.

- [N1] MSK, KRaft mode: <https://docs.aws.amazon.com/msk/latest/developerguide/kraft-intro.html>
- [N2] MSK, broker sizes: <https://docs.aws.amazon.com/msk/latest/developerguide/broker-instance-sizes.html>
- [N3] CloudFront, flat-rate pricing plans: <https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/flat-rate-pricing-plan.html>
- [N4] CloudFront pricing: <https://aws.amazon.com/cloudfront/pricing/>
- [N5] Price List `AmazonMSK`, `ap-southeast-1`:
  <https://pricing.us-east-1.amazonaws.com/offers/v1.0/aws/AmazonMSK/current/ap-southeast-1/index.json>
- [N6] AWS WAF pricing: <https://aws.amazon.com/waf/pricing/> (bảng ở phụ lục của [0061](0061-edge-cloudfront-waf-acm.md))

## Thông tin thêm

Phụ lục: [`appendix/0084-stg-msk-media-sizing.md`](appendix/0084-stg-msk-media-sizing.md) (lỗi nguyên văn, câu trích tài liệu, bảng giá,
số đo buổi).
