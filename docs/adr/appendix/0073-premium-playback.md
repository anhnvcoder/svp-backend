# Phụ lục ADR-0073: Video premium: vé giả lập ở video-service, object dưới tiền tố `premium/` riêng, playlist do API kiểm vé và viết lại, segment qua signed URL CloudFront (key group hai khoá), bản xem thử công khai dưới `preview/`; local, k3d ký bằng presign S3

Phụ lục của [ADR-0073](../0073-premium-playback.md): phương án, sự thật AWS kèm câu trích, chi phí, kết quả buổi, nguồn. Mọi nguồn đọc ngày
2026-11-15 trừ khi ghi khác. Đường dẫn `aws/...` là của `svp-infra`. Số tiền là USD.

## Phương án

| Câu hỏi | Phương án | Trạng thái ngành | Được | Mất | Nguồn |
| --- | --- | --- | --- | --- | --- |
| Nơi giữ vé (§1) | **video-service, bảng `video_entitlements` của `svp_video`** | Hiện hành (dữ liệu quyền ở service giữ tài nguyên) | Một truy vấn kiểm vé, cờ premium, `READY`, tác giả; không gọi chéo mỗi playlist | video-service giữ thêm miền "mua" | [0001](../0001-service-boundaries-and-data-ownership.md) |
| Nơi giữ vé (§1) | user-service | Hiện hành | Miền người dùng gom một chỗ | Mỗi playlist thêm một RPC chéo service; user-service không biết video premium hay `READY` | — |
| Nơi giữ vé (§1) | Service entitlement riêng | Hiện hành ở nền tảng lớn (catalog, billing tách) | Tách miền rõ | Thêm service, database, chart, một chặng trên đường phát; YAGNI ở lab | — |
| Mua (§2) | **RPC ghi vé, không thanh toán** | — (bài tập) | Thử được mọi ca quyền | Ai đăng nhập cũng tự cấp vé | — |
| Mua (§2) | Cổng thanh toán ở chế độ test, webhook ghi vé | Hiện hành | Gần sản phẩm thật | Ngoài phạm vi của lộ trình (không thanh toán thật), thêm dịch vụ ngoài | — |
| Tách nội dung (§3) | **Tiền tố `premium/`, `preview/` cạnh `media/`** | Hiện hành (behavior, bucket policy theo path) | Behavior CloudFront, policy ẩn danh local, IAM chọn theo tiền tố | Cờ không đổi được sau upload; người nhận event kiểm key theo cờ | [N4] |
| Tách nội dung (§3) | Cùng `media/`, phân biệt bằng tag object | Hiện hành ở IAM (`s3:ExistingObjectTag`) | Không đổi bố cục | Behavior CloudFront chỉ chọn theo path pattern: không bắt chữ ký theo tag | [N4] |
| Bản xem thử (§3) | **Chép segment đầu của lần thử thành công** | Hiện hành (preview cắt từ bản đã mã hoá) | Cùng byte, không thêm phút transcode, cả hai đường ffmpeg, MediaConvert | Xem thử chỉ ở rendition thấp nhất; độ dài theo số segment (min(3, ⌊n/2⌋)), không theo thời lượng; video premium một segment không phát hành được | — |
| Bản xem thử (§3) | Job transcode riêng cho preview | Hiện hành | Chọn được chất lượng, độ dài tuỳ ý | Gấp đôi phút MediaConvert, một đường lỗi nữa | [0066](../0066-mediaconvert-transcode.md) |
| Phân quyền (§4) | **Playlist do API viết lại, segment là signed URL tuyệt đối** | Hiện hành (manifest manipulation) | Quyền theo người ở API; CDN chỉ kiểm chữ ký; mọi trình phát mang URL tuyệt đối | Mỗi lần đổi chất lượng một RPC tới video-service | [N2], [N12] |
| Phân quyền (§4) | Signed cookie | Hiện hành | Không viết lại playlist | Cookie phủ cả tên `media`; request của player phải mang credential cross-origin (`withCredentials`), mà `Access-Control-Allow-Origin: *` của `Managed-SimpleCORS` (gói Free) không dùng được với credential | [N1], [0052](../0052-cloudfront-flat-rate-free.md) §4 |
| Phân quyền (§4) | Lambda@Edge viết lại manifest | Hiện hành | Không qua API | Kiểm vé vẫn cần dữ liệu ở `svp_video`: hàm edge gọi lại API; Lambda@Edge tính tiền ngoài gói; thêm một runtime | [N7] |
| Phân quyền (§4) | CloudFront Functions viết lại manifest | Hiện hành cho request, header | Trong gói, độ trễ thấp | Không làm được: runtime không có network, không đọc body của request, nên không kiểm được vé ở `svp_video` | [N18] |
| Phân quyền (§4) | Token trong path (URI tương đối kế thừa token) | Hiện hành ở CDN khác | Không viết lại playlist con | CloudFront không kiểm token trong path: cần hàm edge tự viết, thêm một loại credential | [N1] |
| Phân quyền (§4) | Query nối bằng hook `xhrSetup` của hls.js | Hiện hành trong hls.js | Không đổi playlist | Chỉ hls.js có hook; HLS gốc của Safari, iOS không có | [N17] |
| Phân quyền (§4) | Signed URL chỉ trên master | — | Đơn giản | URI tương đối không mang query của master: playlist con, segment 403 | [N12], [N13] |
| Thuật toán (§6) | **RSA 2048, PKCS#1 v1.5, SHA-256** | Hiện hành (SHA-256 từ 2026-04) | Chữ ký tất định theo chuẩn, ở mọi bộ ký: cùng policy, cùng URL, cache trình duyệt dùng lại | Khoá, chữ ký (256 byte) lớn hơn ECDSA: URL segment dài hơn | [N3], [N6], [N19] |
| Thuật toán (§6) | ECDSA P-256 | Hiện hành | Khoá, chữ ký ngắn | Tất định chỉ khi bộ ký theo RFC 6979 (Go: `Sign` với `rand` là `nil`); bộ ký ngẫu nhiên cho mỗi lần hỏi một URL, mất cache trình duyệt | [N2], [N19] |
| Thuật toán (§6) | RSA SHA-1 (mặc định khi vắng `Hash-Algorithm`) | Cũ | Không thêm tham số | SHA-1 không còn khuyên dùng cho chữ ký | [N6] |
| Đường local (§6) | **Presign S3 `GET` từng segment** | Hiện hành (object riêng không CDN) | Cùng quyết định quyền, chạy trên RustFS bằng SDK đã có | Định dạng chữ ký CloudFront không chạy thật ở local | [N11] |
| Đường local (§6) | Giả CloudFront bằng Envoy (Lua, ext_authz) hay gateway | — | Cùng định dạng URL | Bộ kiểm tự viết chỉ chứng minh nó khớp bộ ký tự viết; thêm code ở biên | — |
| Khoá riêng (§8) | **`openssl` trên máy, Secrets Manager, External Secrets** | Hiện hành | Khoá không vào git, state; cùng đường với secret khác của EKS | Bước tay mỗi buổi (`new`, `activate`) | [N10] |
| Khoá riêng (§8) | `tls_private_key` của Terraform | Cũ cho production (HashiCorp không khuyên) | Một `apply` | Khoá nằm không mã hoá trong state; provider mới | [N16] |
| Khoá riêng (§8) | KMS ký (`RSASSA_PKCS1_V1_5_SHA_256`) | Hiện hành | Khoá không rời KMS | Mỗi chữ ký một lời gọi KMS (độ trễ, quota, phí); local khác đường hẳn; key chờ xoá 7–30 ngày, không hợp env theo buổi | [N14], [N15] |
| Bảo vệ bản sao | DRM (Widevine, FairPlay) | Hiện hành cho nội dung bản quyền | Chống chép nội dung đã tải | Máy chủ license, phí, mã hoá lúc transcode; không thay việc kiểm quyền tải | — |

## Sự thật AWS

Mỗi dòng là câu trích nguyên văn và mục ADR dựa vào nó.

- §4, §5 hạn [N2]: "CloudFront checks the expiration date and time in a signed URL at the time of the HTTP request." Thứ tự kiểm: "If the request
  meets the requirements in the policy statement, CloudFront does the standard operations: determines whether the file is already in the edge
  cache, forwards the request to the origin if necessary, and returns the file to the user." Khoá: "CloudFront supports signed URLs with RSA 2048
  and ECDSA 256 key signatures."
- §5 wildcard [N3]: "A trailing asterisk in the path section implies an asterisk in the query string section. For example,
  `http://example.com/hello*` is equivalent to `http://example.com/hello*\?*`." `Resource` là "The URL, including any query strings, but excluding
  the CloudFront `Policy`, `Signature`, `Key-Pair-Id`, and `Hash-Algorithm` parameters." [N2] cũng ghi "If you add a query string to a signed URL
  after signing it, the URL returns an HTTP 403 status": câu đó đúng khi `Resource` không phủ query (canned policy, URL chính xác); với `*` cuối
  của §5, query `svp_probe` của **Đo cache hit** khớp `Resource`. Buổi cloud kiểm điều này (lượt đo trả 200, không 403).
- §6 định dạng [N3]: "Remove all empty spaces (including tabs and newline characters) from the policy statement."; thay ký tự base64 "+" → "-",
  "=" → "_", "/" → "~"; `Hash-Algorithm`: "Supported values are `SHA1` and `SHA256`. If you don't specify this parameter, CloudFront defaults to
  `SHA1`." và "If you use SHA-256, you must include `&Hash-Algorithm=SHA256` in the signed URL."
- §6 SHA-256 [N6] (đăng 2026-04-01): "Previously, CloudFront signed URLs and signed cookies used SHA-1 exclusively for signature generation.";
  "To use SHA-256, include the Hash-Algorithm=SHA256 query parameter in your signed URLs"; "There is no additional cost to use SHA-256 signing."
- §7, §8 key group [N4]: "We recommend that you use trusted key groups"; "Signers are associated with cache behaviors. With this, you can require
  signed URLs or signed cookies for some files and not for others in the same distribution."; khoá "must be either an SSH-2 RSA 2048 or ECDSA 256
  key pair" và "must be in base64-encoded PEM format". Request khớp behavior đầu tiên theo path pattern.
- §7 chọn behavior [N20] (mục "Path normalization"): "CloudFront normalizes URI paths consistent with RFC 3986 and then matches the path with
  the correct cache behavior. After the cache behavior is matched, CloudFront sends the raw URI path to the origin."; "Some characters are
  normalized and removed from the path, such as multiple slashes (`//`) or periods (`..`)." RFC 3986 [N13]: §6.2.2.2 "These URIs should be
  normalized by decoding any percent-encoded octet that corresponds to an unreserved character, as described in Section 2.3."; §2.2 "URIs that
  differ in the replacement of a reserved character with its corresponding percent-encoded octet are not equivalent."; §6.2.2.3 "The complete
  path segments "." and ".." are intended only for use within relative references (Section 4.1) and are removed as part of the reference
  resolution process (Section 5.2)." Nên `%70remium/…` được khớp như `premium/…`; `premium%2F…` giữ `%2F`, không khớp `premium/*` mà rơi vào
  behavior mặc định, và S3 nhận path thô. Trang không nói S3 giải `%2F` ra sao: behavior mặc định mang signer, nên path nào sau chuẩn hoá
  không bắt đầu bằng `media/`, `preview/` đều cần chữ ký, S3 giải thế nào cũng vậy.
- §7 đoạn `..` trong key [N21]: "Object keys that contain relative path elements (for example, `../`) are valid if, when parsed left-to-right,
  the cumulative count of relative path segments never exceeds the number of non-relative path elements encountered."; "Many systems
  automatically resolve `.` and `..` references". `media/..%2Fpremium/…` sau chuẩn hoá vẫn có đoạn `..%2Fpremium` (không phải đoạn `..`),
  khớp `media/*` công khai, và S3 nhận path thô, giải thành `media/../premium/…`. Trang coi đó là một tên key hợp lệ, không nói GET giải `..`:
  hai behavior công khai giữ `premium/` riêng chỉ khi S3 đọc key theo nghĩa đen (không object nào, 403 vì OAC không có `ListBucket`). Phép kiểm
  là các ca `curl --path-as-is` (`premium%2F`, `%70remium/`, `media/..%2Fpremium/`, `preview/..%2Fpremium/`) của **Kiểm edge premium** ở
  buổi stg.
- §8 hạn mức [N5]: "Public keys in a single key group | 5"; "Key groups associated with a single cache behavior | 4"; "Key groups per AWS account |
  10". Thiết kế dùng một key group, 1–2 khoá.
- §8 xoay [N4] ("Rotating key pairs"): "Create a new key pair, and add the public key to a key group."; "Don't remove any existing public keys from the
  key group, or any key groups from the distribution yet. Only add the new ones."; "Update your application to create signatures using the
  private key from the new key pair."; "Wait until the expiration date has passed in URLs or cookies that were signed using the previous private
  key. Then remove the old public key from the key group."
- §7 gói Free [N7]: hàng "Signed URLs" ghi Yes ở Free, Pro, Business, Premium; "Number of cache behaviors": Free 5. Bảng "Unsupported features"
  không có key group hay signed URL. "Lambda@Edge can also be used with all plan tiers", "Lambda@Edge invocations are billed on a pay-as-you-go
  basis". Trang không có hàng riêng cho trusted key group: `CreateSubscription` và `apply` của buổi stg là phép kiểm (gói Free giữ distribution có
  behavior mang `trusted_key_groups`).
- §7 cache key [N8] (`Managed-CachingOptimized`, ID `658327ea-f89d-4fab-a63d-7e88639e58f6`): "Query strings included in the cache key: None.";
  "Cookies included in the cache key: None."; header chỉ có `Accept-Encoding` chuẩn hoá vì nén.
- §6 presign S3 [N11]: "the expiration time can be set as high as 7 days"; "IAM role credentials – The presigned URL expires when the role session
  expires, even if you specify a longer expiration time."; "presigned URLs are bearer tokens that grant access to those who possess them."
- §4 URI tương đối [N12] (RFC 8216 §4.1): "Any relative URI is considered to be relative to the URI of the Playlist that contains it." [N13] (RFC 3986
  §5.2.2): khi tham chiếu có path, `T.query = R.query`, query của URL gốc không được giữ.
- Phương án hls.js [N17]: "If `xhrSetup` is specified, the default loader will invoke it before calling `xhr.send()`."
- Phương án CloudFront Functions [N18]: bảng so sánh ghi hàng "Network access" là No ở CloudFront Functions, Yes ở Lambda@Edge, hàng "Access to
  the request body" cũng No, Yes; trang giới hạn: "The CloudFront Functions runtime environment doesn't support dynamic code evaluation, and it
  restricts access to the network, file system, environment variables, and timers."
- §6 thuật toán [N19] (`go doc`, Go 1.27): `rsa.SignPKCS1v15`: "This function is deterministic."; `ecdsa.PrivateKey.Sign`: "If random is not
  nil, the signature is randomized." và "If random is nil, Sign will produce a deterministic signature according to RFC 6979."

## Chi phí

| Mục | Giá | Một buổi 4 giờ mỗi env | Tháng không buổi | Nguồn |
| --- | --- | --- | --- | --- |
| CloudFront public key, key group | Trang giá không có dòng nào | 0 | 0 | [N9] |
| Signed URL, SHA-256 | Không phí thêm; request tính như request khác (prd), trong gói (stg) | 0 thêm | 0 | [N6], [N9] |
| Entry `svp/<env>/media-signing` | $0,40 mỗi secret mỗi tháng, tính theo giờ (ví dụ của trang: một giờ là 0,40 ÷ 720 = 0,00056) | ~0,002 | 0 (root env bị destroy) | [N10] |
| Lời gọi Secrets Manager (External Secrets đọc, script ghi) | $0,05 mỗi 10 000 lời gọi | < 0,001 | 0 | [N10] |

Ngưỡng của [0071](../0071-paid-features.md) §7: (a) không đạt ($0 tháng không buổi, < $1 mỗi buổi), nên không cờ trong `aws/paid-features.json`.

## Kết quả buổi

Chưa chạy. Buổi stg, prd ghi ở đây, có ngày: bảng ca âm của **Kiểm edge premium**, tỉ lệ trúng lượt 2–3 của V0, V1 (**Đo cache hit**), ca
`--wait-expiry`, một lượt **Xoay khoá ký**, `sweep.sh` sạch.

## Nguồn

- [N1] CloudFront, "Serve private content with signed URLs and signed cookies":
  <https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/PrivateContent.html>
- [N2] CloudFront, "Use signed URLs": <https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/private-content-signed-urls.html>
- [N3] CloudFront, "Create a signed URL using a custom policy":
  <https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/private-content-creating-signed-url-custom-policy.html>
- [N4] CloudFront, "Specify signers that can create signed URLs and signed cookies" (mục "Rotating key pairs"):
  <https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/private-content-trusted-signers.html>
- [N5] CloudFront, "Quotas" (mục key group): <https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/cloudfront-limits.html>
- [N6] AWS What's New, "Amazon CloudFront now supports SHA-256 for signed URLs and signed cookies" (2026-04-01):
  <https://aws.amazon.com/about-aws/whats-new/2026/04/amazon-cloudfront-sha-256-signed-urls/>
- [N7] CloudFront, flat-rate pricing plans: <https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/flat-rate-pricing-plan.html>
- [N8] CloudFront, "Use managed cache policies":
  <https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/using-managed-cache-policies.html>
- [N9] CloudFront pricing: <https://aws.amazon.com/cloudfront/pricing/>, <https://aws.amazon.com/cloudfront/pricing/pay-as-you-go/>
- [N10] AWS Secrets Manager pricing (giá đọc từ ví dụ của trang): <https://aws.amazon.com/secrets-manager/pricing/>
- [N11] S3, "Sharing objects with presigned URLs": <https://docs.aws.amazon.com/AmazonS3/latest/userguide/ShareObjectPreSignedURL.html>,
  <https://docs.aws.amazon.com/AmazonS3/latest/userguide/using-presigned-url.html>
- [N12] RFC 8216, HTTP Live Streaming, §4.1: <https://www.rfc-editor.org/rfc/rfc8216.html>
- [N13] RFC 3986, URI Generic Syntax, §5.2.2 (bản trang tải 2026-11-15 bị cắt trước mục này; câu ở trên theo văn bản chuẩn):
  <https://www.rfc-editor.org/rfc/rfc3986.html#section-5.2.2>; §2.2, §6.2.2 trích từ bản văn bản <https://www.rfc-editor.org/rfc/rfc3986.txt>
- [N14] AWS KMS, "Asymmetric key specs": <https://docs.aws.amazon.com/kms/latest/developerguide/asymmetric-key-specs.html>
- [N15] AWS KMS, "Delete an AWS KMS key": <https://docs.aws.amazon.com/kms/latest/developerguide/deleting-keys.html>
- [N16] Terraform provider `tls`, resource `tls_private_key`:
  <https://registry.terraform.io/providers/hashicorp/tls/latest/docs/resources/private_key>
- [N17] hls.js API, `xhrSetup`: <https://github.com/video-dev/hls.js/blob/master/docs/API.md>
- [N18] CloudFront, "Differences between CloudFront Functions and Lambda@Edge":
  <https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/edge-functions-choosing.html>; "Restrictions on CloudFront Functions":
  <https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/cloudfront-function-restrictions.html>
- [N19] Go 1.27, `crypto/rsa.SignPKCS1v15` và `crypto/ecdsa.PrivateKey.Sign` (đọc bằng `go doc`): <https://pkg.go.dev/crypto/rsa#SignPKCS1v15>,
  <https://pkg.go.dev/crypto/ecdsa#PrivateKey.Sign>
- [N20] CloudFront, "Cache behavior settings" (mục "Path normalization"):
  <https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/DownloadDistValuesCacheBehavior.html#path-normalization>
- [N21] S3, "Naming Amazon S3 objects" (mục "Object key naming guidelines", "Period-only path segments"):
  <https://docs.aws.amazon.com/AmazonS3/latest/userguide/object-keys.html>
