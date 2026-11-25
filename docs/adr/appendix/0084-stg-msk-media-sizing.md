# Phụ lục ADR-0084: MSK của stg 2 × `kafka.m7g.large`, media của stg pay-as-you-go: AWS từ chối T3 cho KRaft, web ACL media cho gói Free

Phụ lục của [ADR-0084](../0084-stg-msk-media-sizing.md): lỗi nguyên văn, câu trích tài liệu AWS, bảng giá và số đo của buổi stg
2026-11-24. Nguồn của lỗi và số đo: nhật ký buổi (ghi chép cục bộ của người học, dòng thời gian của thư mục buổi) và mô tả svp-infra #71.

## Lỗi nguyên văn

Lần apply env đầu tiên của buổi stg, 2026-11-24:

| API | Tài nguyên (module) | Lỗi |
| --- | --- | --- |
| `CreateCluster` (`4.1.x.kraft`) | `aws_msk_cluster.this` (`msk`) | `Unsupported InstanceType specified` với `kafka.t3.small` |
| `CreateSubscription` | `aws_pricingplanmanager_subscription.media` (`media`) | `svp-stg-media` "not eligible for this subscription tier" |
| `RegisterScalableTarget` | `aws_appautoscaling_target.storage` (`msk`) | `Minimum capacity cannot be greater than 1` |

## Tài liệu MSK về T3 và KRaft

Đọc 2026-11-24.

- [N1] trang KRaft: "From Apache Kafka version 3.7.x on Amazon MSK, you can create clusters that use KRaft mode instead of ZooKeeper
  mode." Trang không nói loại broker nào dùng được với KRaft.
- [N2] trang cỡ broker liệt kê `kafka.t3.small` trong cỡ Standard, không chú thích KRaft. "Use T3 brokers for low-cost development, if you
  are testing small to medium streaming workloads, or if you have low-throughput streaming workloads that experience temporary spikes in
  throughput." "M7g and M5 brokers have higher baseline throughput performance than T3 brokers and are recommended for production
  workloads." "M7g brokers offer improved price performance relative to comparable M5 instances."
- Trang version Kafka không nêu giới hạn loại broker cho KRaft hay 4.x. Không trang nào nói T3 không dùng được với KRaft: lỗi của API là
  nguồn duy nhất.

## Điều kiện web ACL của gói Free

Đọc 2026-11-24 ở [N3] (bảng tính năng của gói) và [N4].

- Số luật, Free 5, Pro 25, Business 50, Premium 75: "Total number of security rules you can create and enable in your WAF configuration,
  including both custom rules and AWS Managed Rules." Trang không nói một nhóm luật managed tính là một luật hay số luật bên trong, không
  nêu tên nhóm luật managed nào.
- "WAF request logs": ô của Free trống, Pro trở lên có ("Access detailed AWS WAF request logs to understand security and delivery traffic
  patterns."). Trang giá: "Logging" Free không có. "AWS WAF log delivery to Amazon S3" nằm trong "Additional features that can affect your
  pricing plan"; trang không nói Free có nhận nó hay không.
- Không hỗ trợ ở gói nào: "Rule Groups" (nhóm luật tự tạo), Partner Managed Rules, Account Creation Fraud Prevention, Account Takeover
  Protection. Free có "IP-based rate limiting", chặn theo địa lý; không có CAPTCHA, custom response, Bot Control.
- "You must have an AWS WAF Web ACL associated with your distribution if you're using a pricing plan." Web ACL đã gắn distribution khác thì
  không đăng ký được; trang không đòi web ACL do gói tạo.
- Không trang nào (cả hướng dẫn Pricing Plan Manager) có câu lỗi "not eligible" hay mô tả lỗi của `CreateSubscription`.

Web ACL `svp-stg-media` lúc bị từ chối (module `waf` của `svp-infra`): luật `rate-limit-per-ip` (rate-based), `aws-ip-reputation`
(`AWSManagedRulesAmazonIpReputationList`), `aws-common` (`AWSManagedRulesCommonRuleSet`, không override), `aws-known-bad-inputs`
(`AWSManagedRulesKnownBadInputsRuleSet`); logging configuration tới bucket `aws-waf-logs-…` của `svp-log-archive`, che `authorization`,
`cookie`. Bốn luật cấp web ACL dưới hạn 5; nhóm `CommonRuleSet` gồm nhiều luật bên trong. Ứng viên: log WAF (Free không có "WAF request
logs") và cách đếm nhóm luật managed. Chưa thử tách: mỗi phép thử là một lần apply trên account.

## Giá MSK

Price List [N5] `AmazonMSK`, `ap-southeast-1`, bản phát hành 2026-11-17T19:45:58Z, đọc 2026-11-24 (khoá `usagetype` `APS1-Kafka.<loại>`,
giá on-demand theo broker-giờ). Tháng 730 giờ.

| Loại broker | USD/broker-giờ | 2 broker, USD/giờ | Buổi 4 giờ | 730 giờ |
| --- | --- | --- | --- | --- |
| `kafka.t3.small` | 0,0578 | 0,1156 | 0,46 | 84,39 |
| `kafka.m7g.large` | 0,255 | 0,51 | 2,04 | 372,30 |
| `kafka.m5.large` | 0,263 | 0,526 | 2,10 | 383,98 |

- `kafka.m7g.large` thay `kafka.t3.small` ở stg: +$0,394 mỗi giờ, +$1,58 mỗi buổi 4 giờ, +$287,91 mỗi 730 giờ.
- H_k của stg ở bảng chi phí phụ lục 0053: 0,144 − 0,1156 + 0,51 = **~$0,538 mỗi giờ**. prd không đổi: 3 × 0,255 = 0,765.
- Buổi stg so với trần $5 của [0034](../0034-aws-stage7.md): phụ lục 0053 ghi buổi ~$2,8–3,0 Spot, ~$3,6–3,7 on-demand (đã gồm 4 × H_k
  cũ); cộng $1,58 của MSK thành ~$4,4–4,6 Spot, ~$5,2–5,3 on-demand. Media thêm ~$0,05.

## Giá media pay-as-you-go

Giá đọc ở phụ lục [0061](0061-edge-cloudfront-waf-acm.md) (bảng giá, phần chi phí edge), cùng nguồn [N6]:

| Khoản | Giá | Media stg |
| --- | --- | --- |
| Web ACL `svp-stg-media`: $5 ACL + 4 luật × $1 | $9 mỗi tháng | ~$0,0123 mỗi giờ, ~$0,05 mỗi buổi 4 giờ |
| Request WAF | $0,60 mỗi triệu | vài chục nghìn request mỗi buổi: dưới một cent |
| Log chuẩn v2 (giao S3, chuyển Parquet) | $0,25 + $0,049 mỗi GB | vài MB mỗi buổi: dưới một cent |
| CloudFront request, GB ra Internet | hạn mức miễn phí của account mỗi tháng (1 TB, 10 triệu request) | $0 trong hạn mức |

## Số đo buổi

Buổi stg 2026-11-24, người học chạy theo runbook:

| Bước | Số đo | So với giả định |
| --- | --- | --- |
| MSK 2 × `kafka.m7g.large` dựng (`CreateCluster` tới `ACTIVE`) | 24m54s | 0053 §16: ≤ 45 phút |
| Smoke (`measure.sh stg --smoke`) | 52 s | |
| Pre-destroy (luật AMP, workload, EBS, node Karpenter) | ~15 phút | |
| Gỡ root gitops | 5 tài nguyên, 47 s | |
| Gỡ root env (gồm MSK, không đo riêng) | 394 tài nguyên, ~17 phút | 0053 §16: MSK gỡ ≤ 30 phút |
| Cả buổi, `session-start` tới quét xong | 4h29m, gồm ~1 giờ sửa apply đỏ và deadlock wave ([0083](../0083-istio-wave-eks.md)) | |

Media stg: `curl -sI` có header `Origin` của web tới một playlist trả HTTP/2 200 với `access-control-allow-origin` bằng origin đó. Sau
destroy, danh sách subscription của Pricing Plan Manager rỗng.

## Nguồn

Như mục Nguồn của ADR; đọc 2026-11-24.

- [N1] <https://docs.aws.amazon.com/msk/latest/developerguide/kraft-intro.html>
- [N2] <https://docs.aws.amazon.com/msk/latest/developerguide/broker-instance-sizes.html>
- [N3] <https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/flat-rate-pricing-plan.html>
- [N4] <https://aws.amazon.com/cloudfront/pricing/>
- [N5] <https://pricing.us-east-1.amazonaws.com/offers/v1.0/aws/AmazonMSK/current/ap-southeast-1/index.json>
- [N6] <https://aws.amazon.com/waf/pricing/>
- Hướng dẫn Pricing Plan Manager: <https://docs.aws.amazon.com/PricingPlanManager/latest/UserGuide/plan-management.html>
