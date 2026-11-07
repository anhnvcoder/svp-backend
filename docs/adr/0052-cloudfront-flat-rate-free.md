# 0052. CloudFront của media ở stg và prd chạy trên gói flat-rate Free, có web ACL WAF

- Trạng thái: Chấp nhận
- Ngày: 2026-11-07
- Người quyết: người học (2026-11-07: distribution media của stg và prd đăng ký gói CloudFront flat-rate Free thay pay-as-you-go)

## Bối cảnh và vấn đề

- [0034](0034-aws-stage7.md) Câu 19 chọn pay-as-you-go cho CloudFront: hạn mức miễn phí 1 TB và 10 triệu request mỗi tháng đủ cho lab; phương án
  flat-rate bị để lại vì bắt buộc web ACL WAF và chưa kiểm với tên `*.cloudfront.net`. §9 đặt `PriceClass_200`.
- [0048](0048-prd-aws.md) cho prd một web ACL (module `waf`, chỉ root prd gọi, §3, §4); stg không có WAF (ngoại lệ trivy AWS-0011 ở module `media`).
  Ở phương án "Edge prd", 0048 loại "CloudFront flat-rate plan (mới, theo tháng, không theo buổi)". Lý do đó không còn đúng: gói Free giá $0 [N2],
  huỷ có hiệu lực ngay [N1], nên dựng và gỡ theo buổi được như mọi tài nguyên khác.
- Pay-as-you-go không có trần: một trận tràn request vượt hạn mức miễn phí được tính tiền theo GB và request; web ACL của prd tính phí theo giờ
  (~$5 mỗi ACL và $1 mỗi luật mỗi tháng [N5]).
- Account `svp-stg`, `svp-prd` đã được AWS xác minh dùng CloudFront; người học đã tạo thử ở console một distribution gói Free và nó chạy.
- Ràng buộc như 0034, 0048: repo public, AI không chạy lệnh chạm account, buổi dựng và gỡ trong ngày.

## Yếu tố quyết định

- Chi phí của edge mỗi buổi: $0 và không có phí vượt hạn mức, kể cả khi bị tràn request.
- WAF ở edge cho cả hai env, stg giống prd (0048 §3 giữ khác biệt của hai root env trong một danh sách đóng; WAF ra khỏi danh sách đó).
- Giới hạn tính năng của gói không chặn cấu hình đang dùng (OAC, cache policy managed, HTTPS, HTTP/3, IPv6).
- Gỡ được hết trong buổi, quét được phần sót.

## Phương án đã cân nhắc

In đậm là lựa chọn.

- Giữ pay-as-you-go (0034 Câu 19, 0048): không giới hạn tính năng; stg không WAF, web ACL của prd tính theo giờ, lưu lượng vượt hạn mức tính tiền.
- **Gói Free cho cả stg và prd:** $0, không phí vượt, gói phủ web ACL; bị giới hạn tính năng, tối đa 3 gói Free mỗi account, phải có web ACL.
- Gói Pro ($15 mỗi tháng mỗi distribution [N2]): thêm access log, nhiều tính năng hơn; tính theo tháng, lab không cần phần thêm đó.

## Kết quả quyết định

Chọn gói Free cho distribution media của cả hai env: đạt chi phí $0 có trần và WAF ở cả hai env mà không đổi cấu hình phát video. Cái giá: giới hạn
tính năng của gói (dưới đây), CORS `*` cho media, và hạn 3 gói Free mỗi account.

### 1. Sự thật của gói Free

Đọc 2026-11-07 ở [N1], giá ở [N2]:

- Free $0, Pro $15 mỗi tháng. Free gồm 1 triệu request và 100 GB mỗi tháng; "Usage allowances are not hard limits", "you will not incur overage
  charges"; vượt nhiều và kéo dài thì "your traffic delivery might be adjusted"; email báo ở 50, 80, 100 % hạn mức.
- Distribution có gói phải gắn một web ACL WAF, không gỡ được khi còn gói; tài nguyên gắn distribution có gói chỉ dùng cho distribution đó.
- Gói phủ "The AWS WAF web ACL, custom rules, AWS Managed Rules, and request fees for the web ACL associated with your distribution"; CAPTCHA
  tạo bằng JavaScript API và giao log WAF tới S3 tính riêng.
- Free tối đa 5 luật WAF (luật tự viết cộng AWS Managed Rules); có rate limit theo IP, chặn theo địa lý; không có lọc theo header, regex,
  CAPTCHA, challenge, quản lý bot. "Rule Groups" (nhóm luật tự tạo) nằm ở mục không hỗ trợ.
- Custom cache policy, custom origin request policy: từ Business; "Custom response header rules": Business, Premium, còn Free có "Default response
  header rules"; access log: từ Pro; OAC, HTTP/3, IPv6: mọi gói; Free tối đa 5 cache behavior.
- Không hỗ trợ khi có gói: `ForwardedValues` và legacy cache settings, OAI, real-time log, field-level encryption, continuous deployment, dedicated
  IP, Anycast IP list.
- Mỗi gói một distribution, tối đa một apex domain; tối đa 3 gói Free mỗi account, không tăng được; account đang dùng AWS Free Tier không đăng ký được.
- Gói Free huỷ có hiệu lực ngay; không xoá được distribution còn gói.
- `price_class`: trang không nói. Quan sát ở một dự án khác (gói Free, 2026-11-04): khi đăng ký gói AWS tự đổi distribution sang "Use all edge
  locations" (`PriceClass_All`), Terraform phải đặt `PriceClass_All` thì `plan` mới `No changes`.

### 2. Gói ở cả hai env

Module `media` của `svp-infra` tạo `aws_pricingplanmanager_subscription.media` (`hashicorp/aws` từ 6.69.0 [N4], module đòi `~> 6.69`): `plan_family =
"CloudFront"`, `plan_tier = "FREE"`, `resource_arns` là distribution và web ACL (họ CloudFront đòi đúng một mỗi loại); không đặt `approval_mode` (gói
Free kích hoạt ngay) và `usage_level`. Giá trị enum theo docs của resource [N4] và mô hình API `pricing-plan-manager` 2025-08-05 của AWS CLI 2.38.1.
API chỉ có endpoint `us-east-1`, region SCP của 0048 §1 đã cho phép. Không thêm biến chọn gói: cả hai env dùng Free.

### 3. Web ACL ở stg và prd

Module `waf` (scope `CLOUDFRONT`, provider `aws.us_east_1`, tên `svp-<env>-media`; một luật rate-based theo IP, `AWSManagedRulesCommonRuleSet`,
`AWSManagedRulesKnownBadInputsRuleSet`) được gọi ở `waf.tf` của **cả hai** root env; `web_acl_arn` của module `media` thành bắt buộc, ngoại lệ trivy
AWS-0011 bỏ. Ba luật dưới hạn 5. **Giả định:** mỗi nhóm luật managed của AWS tính là một luật và được nhận, vì gói phủ "AWS Managed Rules" còn
"Rule Groups" không hỗ trợ được hiểu là nhóm luật tự tạo; kiểm khi `CreateSubscription` nhận web ACL ở buổi đầu.

### 4. CORS của media bằng policy managed

Gói Free không có response headers policy tự viết, nên policy `<bucket media>-cors` (origin của web) nhường cho policy managed `Managed-SimpleCORS`
[N3]: CloudFront thêm `Access-Control-Allow-Origin: *` vào mọi câu trả lời cho request CORS đơn giản. Policy này không đè header của origin, mà
distribution không chuyển header nào của viewer tới bucket (không origin request policy), nên S3 không thấy `Origin` và không trả header CORS
của nó. Distribution vẫn chỉ `GET`, `HEAD`; CORS theo bucket của `uploads`, `media` (`cors_allowed_origins`) giữ nguyên. **Giả định:** policy managed
thuộc "Default response header rules" của gói Free; kiểm khi apply. Cái giá: mọi site đọc được playlist, segment, thumbnail cross-origin. Chấp nhận
vì media công khai (ai có link đều xem, threat model UP-6), bất biến, và request không mang credential (player không gửi cookie hay header); threat
model ghi nó ở "Rủi ro chấp nhận".

### 5. `price_class` cố định

Module `media` đặt `price_class = "PriceClass_All"` (giá gói không đổi theo vùng), bỏ biến `price_class` của module và `media_price_class` của hai root
cùng dòng của nó trong `stg.tfvars`, `prd.tfvars`. Theo quan sát ở §1, không phải câu của tài liệu AWS; kiểm bằng `plan` lần hai sau apply.

### 6. Thứ tự gỡ và quét

- Terraform theo tham chiếu: subscription → distribution → web ACL.
- Tay: huỷ gói, đọc lại `list-subscriptions` tới khi không còn phần tử mang ARN đó, tắt rồi xoá distribution, rồi OAC, rồi web ACL.
- `sweep.sh` liệt kê gói còn sót (`us-east-1`) ngay trước distribution. Web ACL và distribution tồn tại vài phút trước khi gói có hiệu lực và
  sau khi huỷ: khoảng đó tính pay-as-you-go; web ACL sót lại sau khi gói huỷ tính theo giờ [N5], nên sweep phải bắt nó.

### 7. Route 53 ngoài gói

Gói cho phép gắn hosted zone để gói phủ phí zone [N1]; không gắn: zone ở baseline mỗi account ([0051](0051-dns-prd-apex.md)) giữ pay-as-you-go,
và media dùng tên `*.cloudfront.net` (0034 Câu 18), không tên nào trong zone (YAGNI).

### Hệ quả

- Tốt: edge $0 mỗi buổi, không phí vượt kể cả khi bị tràn request; stg có WAF như prd, hai root khác nhau ít hơn; bớt một ngoại lệ trivy.
- Xấu: CORS `*` cho media; không custom cache policy, response header tự viết, access log, Bot Control; tối đa 5 luật WAF; tràn kéo dài làm
  giao hàng bị điều chỉnh thay vì bị tính tiền; distribution phát ở mọi edge; gỡ tay phải huỷ gói trước.
- Rủi ro: mỗi account tối đa 3 gói Free. **Giả định** chỉ gói còn hiệu lực bị đếm (trang không nói); mỗi buổi tạo rồi huỷ một gói và lần thử ở
  console đã dùng một, nên giả định sai lộ ra ở buổi thứ 3–4 của mỗi account: apply đỏ ở `aws_pricingplanmanager_subscription.media` với
  `ServiceQuotaExceededException` (nhận theo tên lỗi; câu của mô hình API: "You have reached the maximum number of subscriptions allowed for your
  account") thì destroy, không thử lại, mở case AWS Support.
- Xem lại khi: một tháng vượt 1 triệu request hay 100 GB (email 80 %); cần custom cache policy, response header tự viết hay access log; có video
  riêng tư, URL hay cookie ký; hạn 3 gói chặn một buổi.

## Xác nhận

- Lúc quyết chưa kiểm trên AWS. Đã kiểm khi hiện thực: `make check` của `svp-infra` (test mocked của module `media`, `waf`; `validate`, `tflint`,
  `trivy` của hai root, self-test `sweep.sh`), `make docs-check` của repo này. Test mocked không chứng minh giá trị enum đúng.
- Buổi stg đầu tiên rồi buổi prd (người học chạy theo runbook): (a) trước apply `list-subscriptions` rỗng, `get-account-plan-state` cho `PAID`;
  (b) plan có `module.media.aws_pricingplanmanager_subscription.media` (`plan_tier = "FREE"`) và `module.waf.aws_wafv2_web_acl.this`; (c) sau apply
  `get-subscription` cho `ACTIVE`, `FREE`, `resourceArns` là distribution và web ACL (enum, số luật, tên `*.cloudfront.net` được nhận), `plan` lần hai
  `No changes`; (d) `curl -sI -H 'Origin: https://<domain>'` tới `master.m3u8` có `access-control-allow-origin: *`, web phát được video; (e) sau destroy
  `list-subscriptions` rỗng, `sweep.sh <env>` sạch.
- Kết quả: lệnh và output có ngày ở phụ lục của ADR này; mục này đổi bullet trên thành một dòng kết luận mỗi env.

## Hiện thực ở

- `svp-infra`: `aws/modules/media/cloudfront.tf`, `aws/modules/media/variables.tf`, `aws/modules/media/README.md` (§2, §4, §5); `aws/modules/waf/main.tf`,
  `aws/envs/stg/waf.tf`, `aws/envs/prd/waf.tf`, `aws/envs/stg/providers.tf` (§3); `aws/envs/stg/main.tf`, `aws/envs/prd/main.tf`,
  `aws/envs/stg/variables.tf`, `aws/envs/prd/variables.tf`, `aws/envs/stg/stg.tfvars`, `aws/envs/prd/prd.tfvars` (§3, §5); `aws/scripts/sweep.sh`,
  `docs/runbooks/session-stg.md`, `docs/runbooks/session-prd.md` (§6).

## Nguồn

Đọc 2026-11-07.

- [N1] <https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/flat-rate-pricing-plan.html>
- [N2] <https://aws.amazon.com/cloudfront/pricing/>
- [N3] <https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/using-managed-response-headers-policies.html>
- [N4] <https://raw.githubusercontent.com/hashicorp/terraform-provider-aws/main/website/docs/r/pricingplanmanager_subscription.html.markdown>
- [N5] <https://aws.amazon.com/waf/pricing/> (đọc 2026-11-05, bảng giá ở phụ lục của [0048](0048-prd-aws.md))
