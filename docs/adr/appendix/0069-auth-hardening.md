# Phụ lục ADR-0069: Cứng hoá xác thực: giới hạn đăng nhập theo tài khoản có cặp đã biết, header bảo mật ở gateway, access token 15 phút, chặn mật khẩu phổ biến hay đã lộ

Phụ lục của [ADR-0069](../0069-auth-hardening.md): bảng phương án, header theo OWASP, con số của `login-account` và ngân sách k6, câu chữ
của mã lỗi, trích dẫn có mục, ghim nguồn danh sách mật khẩu. Mọi nguồn đọc ngày 2026-11-14.

## Phương án

| Mục | Phương án | Trạng thái ngành | Được | Mất | Nguồn |
| --- | --- | --- | --- | --- | --- |
| Login | Khoá tài khoản sau N lần sai | Hiện hành (NIST: vô hiệu hoá sau ≤ 100 lần sai liên tiếp rồi gắn lại; OWASP: account lockout) | Chặn cứng số lần dò mỗi tài khoản | Ai biết email là khoá được chủ thật; cần luồng mở khoá (đặt lại mật khẩu qua email) mà hệ thống chưa có | [A1], [A4] |
| Login | Chỉ giới hạn theo email trên mọi IP | Hiện hành (OWASP: đếm theo tài khoản, không theo IP) | Chặn dò phân tán; không lưu thêm gì | Kẻ dò giữ bucket thì chủ thật không đăng nhập được từ đâu cả | [A4] |
| Login | **Theo email, trừ cặp (IP, email) đã đăng nhập thành công** | Hiện hành (NIST bản 3: chỉ nhận từ IP đã xác thực trước đó; bản 4: risk-based theo IP) | Chặn dò phân tán; chủ thật vẫn vào từ IP đã biết; chỉ `GET`, `SET` trên Valkey sẵn có | Lưu (IP, hash email) 30 ngày; IP mới bị chặn khi tài khoản đang bị dò; NAT, BFF chung IP làm cặp rộng hơn một người | [A1], [A2] |
| Login | CAPTCHA | Hiện hành (NIST: bot detection challenge; OWASP: chỉ khi nghi ngờ) | Chặn bot tự động | Dịch vụ bên thứ ba hay tự làm, UI web, dependency mới; OWASP: có công cụ phá CAPTCHA | [A1], [A5] |
| Login | Device cookie | Hiện hành (OWASP community) | Theo client, không theo NAT; chủ thật có cookie hợp lệ không bị khoá | Cookie ký HMAC (bí mật mới), BFF giữ và chuyển cookie qua gateway, đổi hợp đồng REST; client không phải trình duyệt không có | [A6] |
| Header | **Bộ tối thiểu của OWASP REST Security cho API JSON, ở gateway** | Hiện hành | Như nhau ở mọi môi trường, cả trong cluster; `no-store` cho response mang token | Trùng một phần với edge | [A3], [A7] |
| Header | Đủ hai bảng của OWASP ở gateway | Hiện hành (OWASP: bảng HTML chỉ là phòng thủ chiều sâu) | Đủ danh sách | HSTS, XFO trùng edge; `Permissions-Policy`, `Referrer-Policy` vô tác dụng với JSON | [A3] |
| Header | Chỉ edge đặt | — | Không đổi code | compose, k3d, lưu lượng trong cluster không có header; edge không đặt `Cache-Control` | [A3] |
| Token | **Access token 15 phút** | Hiện hành (access token ngắn kèm refresh token) | Không thêm trạng thái hay lời gọi; web không đổi | Token lộ sống 15 phút 30 giây; refresh gấp 4; lượt k6 ngắn hơn | [A9] |
| Token | `tokens_valid_after` theo user, token 1 giờ | Hiện hành khi cần cắt phiên ngay | Cắt mọi token của user tức thì | Năm nơi kiểm JWT tra trạng thái mỗi request hay giữ bản sao từ event; chưa có sự kiện kích hoạt | — |
| Token | Cả hai | Hiện hành ở IdP lớn | Cửa sổ ngắn và cắt được ngay | Gộp cái giá của hai phương án khi chưa cần cắt ngay | — |
| Mật khẩu | **Danh sách cục bộ nhúng binary (SecLists NCSC 100k)** | Hiện hành (NIST: so với blocklist khi đặt mật khẩu) | Không gửi gì ra ngoài, không phụ thuộc mạng; kiểm trong bộ nhớ | Cỡ trăm KB trong repo, binary; không phủ mật khẩu lộ sau ngày ghim | [A1], [A12] |
| Mật khẩu | Range API k-anonymity của HIBP | Hiện hành, thông dụng nhất | Corpus đầy đủ, luôn mới; chỉ 5 ký tự đầu của SHA-1 rời máy | Egress internet từ user-service, NetworkPolicy; HIBP lỗi thì phải chọn fail-open hay fail-closed; thêm độ trễ cho `Register` | [A11] |
| Mật khẩu | Bloom filter của toàn bộ Pwned Passwords | Ít gặp | Offline, corpus đầy đủ ở ngày tải | Cỡ 180 MB mỗi 100 triệu hash (dưới); tải lại để cập nhật; dương giả chặn oan | [A11] |

## Header theo OWASP

Bảng thứ nhất của OWASP REST Security [A3] là header "should be included in all API responses that may be consumed by browser clients";
bảng thứ hai chỉ có tác dụng khi response được hiển thị như HTML.

| Header | OWASP khuyên | Gateway | Lý do |
| --- | --- | --- | --- |
| `Cache-Control` | `no-store` (bảng 1) | `no-store`; `getPublicVideo` thành công `public, max-age=30` | RFC 6749 §5.1 đòi cho response mang token [A7]; route công khai cần cache ngắn |
| `Content-Security-Policy` | `frame-ancestors 'none'` (bảng 1), `default-src 'none'` (bảng 2) | `default-src 'none'; frame-ancestors 'none'` | Trùng policy `svp-<env>-api` của edge, nên edge ghi đè không đổi giá trị |
| `Content-Type` | Theo nội dung (bảng 1) | Giữ như hiện có (`application/json`, `application/problem+json`) | Handler đã đặt |
| `Strict-Transport-Security` | Có (bảng 1) | Không | Chỉ có nghĩa trên HTTPS mà trình duyệt thấy; gateway sau Envoy, ALB; edge đặt (ADR-0061 §6) |
| `X-Content-Type-Options` | `nosniff` (bảng 1) | `nosniff` | Chặn MIME sniffing |
| `X-Frame-Options` | `DENY` (bảng 1, header cũ, đã được `frame-ancestors` thay) | Không | `frame-ancestors` đã đặt; edge đặt XFO cho trình duyệt cũ |
| `Permissions-Policy` | Tắt tính năng (bảng 2) | Không | Response JSON không chạy tính năng trình duyệt nào |
| `Referrer-Policy` | `no-referrer` (bảng 2) | Không | Response JSON không tạo request phụ; edge đặt `strict-origin-when-cross-origin` |
| `Pragma` | Không nhắc | Không | RFC 9111 §5.4 bỏ `Pragma` [A8]; RFC 6749 §5.1 vẫn đòi `Pragma: no-cache`: lệch có chủ ý |
| `X-XSS-Protection` | HTTP Headers: "Do not set this header or explicitly turn it off" [A10] | Không | Theo OWASP |
| CORS | "Disable CORS headers if cross-domain calls are not supported/expected" | Không | Trình duyệt chỉ gọi BFF cùng origin; BFF gọi gateway từ server |

## Con số

### Lớp `login-account`

GCRA với 100 lượt mỗi 24 giờ: khoảng phát `T` = 24 giờ / 100 = 14,4 phút; burst 10 cho phép `tat` đi trước `now` tối đa `T × 10` = 144
phút, cũng là `PEXPIRE` lớn nhất của khoá. Kẻ dò bắt đầu từ bucket trống lấy được 10 lượt ngay rồi một lượt mỗi 14,4 phút: 110 lượt trong
24 giờ đầu, 100 lượt mỗi 24 giờ sau đó, tối đa 3 010 lượt trong 30 ngày. NIST SP 800-63B-4 §3.2.2 chọn mốc 100 "to balance the likelihood of a
correct guess" [A1]; §3.1.1.2 nói blocklist "SHOULD be of sufficient size to prevent subscribers from choosing passwords that attackers are
likely to guess before reaching the attempt limit". Danh sách nhúng giữ hàng chục nghìn mục có độ dài hợp lệ của nguồn 99 840 dòng (số đúng:
`blocklist.sh`), nhiều hơn hẳn số lượt kẻ dò có trong 30 ngày; ở 100 lượt/ngày một cuộc dò dùng hết danh sách sau khoảng 465 ngày, nên
mốc thật là phản ứng theo metric và WAF, không phải kích thước danh sách. Mốc 100 chỉ áp cho IP chưa biết khi Valkey khoẻ: từ IP là cặp đã biết
(NAT chung, IP của BFF ở compose) lớp này bị bỏ qua, `login-email` cho khoảng 240 lượt/ngày mỗi IP; Valkey lỗi thì 50/ngày mỗi instance gateway.

Bộ đếm dự phòng (50 mỗi 24 giờ, burst 5) theo luật nửa ngưỡng của các lớp login khác, đếm riêng ở từng instance.

### Ngân sách k6

Token của k6 cấp trong `setup()` (tối đa `setupTimeout` 3 phút) rồi dùng tới hết lượt, cộng `gracefulStop` 30 s mặc định của executor:
15 phút − 3 phút − 30 s = 11 phút 30 giây, làm tròn xuống 11 phút cho `ramp + hold + rampDown`. Profile `cloud` 3 + 7 + 1 = 11 phút.

### Bloom filter

Số bit mỗi phần tử ở tỉ lệ dương giả `p` là `−ln p / (ln 2)²`: với `p` = 0,1% là 14,4 bit, khoảng 1,8 byte, nên 100 triệu hash cần
khoảng 180 MB; cỡ thật tăng theo số hash của corpus ở ngày tải.

## Mã lỗi mật khẩu chặn

Web hiện ở ô mật khẩu khi gateway trả `code` `PASSWORD_BLOCKLISTED`:

- vi: "Mật khẩu này quá phổ biến hoặc đã lộ trong các vụ rò rỉ dữ liệu. Hãy chọn mật khẩu khác."
- en: "This password is too common or has appeared in a data breach. Choose another one."

NIST SP 800-63B-4 §3.1.1.2: "the CSP SHALL require the subscriber to select a different secret and SHALL provide the reason for rejection" [A1].

## Trích dẫn

### NIST SP 800-63B-4

Bản 4 thay SP 800-63B ("This publication supersedes NIST Special Publication (SP) 800-63B"); trang HTML ghi "Tue, 26 Aug 2025" [A1].
Bản 3 đặt giới hạn lần thử ở §5.2.2, bản 4 ở §3.2.2; mật khẩu ở §3.1.1.1, §3.1.1.2.

- §3.2.2 Rate Limiting (Throttling): "the verifier SHALL limit consecutive failed authentication attempts using a specific authenticator on a
  single subscriber account to no more than 100 by disabling that authenticator"; "Authenticators that have been disabled SHALL be required to
  rebind to the subscriber account"; "The limit of 100 attempts is an upper bound, and agencies MAY impose lower limits."
- §3.2.2, kỹ thuật giảm khoá nhầm chủ thật ("Additional techniques MAY be used to reduce the likelihood that an attacker will lock the
  legitimate claimant out"): bot detection and mitigation challenge; chờ tăng dần "(e.g., 30 seconds up to an hour)"; "Leveraging other
  risk-based or adaptive authentication techniques … (e.g., the use of the claimant's IP address, geolocation, timing of request patterns, or
  browser metadata)". "When the subscriber successfully authenticates, the verifier SHOULD disregard any previous failed attempts".
- Bản 3 §5.2.2 [A2] có mục riêng: "Accepting only authentication requests that come from a white list of IP addresses from which the
  subscriber has been successfully authenticated before." Bản 4 gộp nó vào kỹ thuật risk-based theo IP ở trên.
- §3.1.1.2 Password Verifiers: "When processing a request to establish or change a password, verifiers SHALL compare the prospective secret
  against a blocklist that contains known commonly used, expected, or compromised passwords. The entire password SHALL be subject to
  comparison, not substrings or words that might be contained therein." Danh sách có thể gồm "Passwords obtained from previous breach
  corpuses", "Dictionary words", "Context-specific words, such as the name of the service, the username, and derivatives thereof".
- §3.1.1.2: "Excessively large blocklists are of little incremental security benefit because the blocklist is used to defend against online
  attacks, which are already limited by the throttling requirements described in Sec. 3.2.2."
- §3.1.1.2: "Verifiers and CSPs SHALL require passwords that are used as a single-factor authentication mechanism to be a minimum of 15
  characters in length", tối thiểu 8 khi chỉ dùng trong MFA; "SHOULD permit a maximum password length of at least 64 characters"; "SHALL NOT
  impose other composition rules". "Verifiers SHALL offer guidance to the subscriber to help the subscriber choose a strong password."

### OWASP

- Authentication Cheat Sheet, Account Lockout [A4]: "The counter of failed logins should be associated with the account itself, rather than the
  source IP address"; "care must be taken to prevent it from being used to cause a denial of service by locking out other users' accounts".
  Adaptive or Risk Based Authentication: dùng "device fingerprints, IP addresses, and remembered-device cookies as risk signals".
- Credential Stuffing Prevention Cheat Sheet [A5]: CAPTCHA "only require the user solve a CAPTCHA when the login request is considered
  suspicious or high risk"; IP "should not be used as the sole or primary defense"; Pwned Passwords là dịch vụ miễn phí để kiểm mật khẩu lộ.
- Slow Down Online Guessing Attacks with Device Cookies [A6]: "Temporary account lockout after several failed attempts is too simple of a
  target for DoS attacks against legitimate users"; cookie phân biệt "known/trusted and unknown/untrusted clients".
- REST Security Cheat Sheet, Security Headers và CORS [A3]: hai bảng ở [Header theo OWASP](#header-theo-owasp).

### RFC

- RFC 6749 §5.1 [A7]: "The authorization server MUST include the HTTP "Cache-Control" response header field … with a value of "no-store" in
  any response containing tokens, credentials, or other sensitive information, as well as the "Pragma" response header field … with a value
  of "no-cache"."
- RFC 9111 §5.4 [A8]: "this specification deprecates Pragma".
- RFC 9700 §4.14 Refresh Token Protection [A9]: refresh token "allow the authorization server to issue access tokens with a short lifetime
  and reduced scope". RFC 9700 không đặt con số hạn access token.

## Ghim nguồn danh sách

| Mục | Giá trị |
| --- | --- |
| Kho | SecLists ([A12]) |
| File | `Passwords/Common-Credentials/100k-most-used-passwords-NCSC.txt` |
| Commit ghim | `1a7bb9127eca9e6ff2fc0301c597fe6e16a0cb56` (commit cuối đổi file này, 2025-11-19, bỏ dòng trùng) |
| URL raw | <https://raw.githubusercontent.com/danielmiessler/SecLists/1a7bb9127eca9e6ff2fc0301c597fe6e16a0cb56/Passwords/Common-Credentials/100k-most-used-passwords-NCSC.txt> |
| sha256 file tải | `c2e5696882c603b76bb67a47ee970897e5a76fc4c3f5547abe3d0ca340c576e0` |
| Cỡ | 835 538 byte, 99 840 dòng, UTF-8, kết thúc dòng LF |
| Nguồn gốc | Danh sách 100 000 mật khẩu lộ hay dùng nhất do NCSC (UK) công bố tháng 4/2019, lấy từ dữ liệu của HIBP (theo tin cùng thời, [A12]) |

File sinh `blocklist.txt` (lọc theo độ dài, chữ thường, sắp xếp, bỏ trùng) và sha256 của nó do `blocklist.sh` giữ cùng file.

### Giấy phép

- SecLists: "MIT License", "Copyright (c) 2018 Daniel Miessler" (`LICENSE` của kho) [A12]. README không nói riêng về giấy phép của các danh
  sách bên thứ ba trong kho.
- NCSC: điều khoản của website "Content on the Websites is, unless stated otherwise, subject to Crown copyright"; dùng lại theo "Open
  Government Licence (OGL) v3.0", phải ghi nguồn và link OGL; ngoại lệ: "Where materials are stated to include material under licence from
  third parties, those materials are not licenced for re-use" [A12]. OGL v3.0 cho phép "copy, publish, distribute and transmit the
  Information" khi ghi nguồn [A12].
- HIBP: "there is no licencing or attribution requirements on the Pwned Passwords API"; "Pwned Passwords is free and open source for
  everyone to use" [A11].
- Bài blog gốc của NCSC (`/blog-post/passwords-passwords-everywhere`) đã gỡ và file gốc
  `https://www.ncsc.gov.uk/static-assets/documents/PwnedPasswordsTop100k.txt` trả 404; bài chỉ còn ở The National Archives và Wayback
  Machine, nên câu giấy phép riêng của bài (nếu có) chưa đọc được (bài đã gỡ, Wayback chặn bot).
- Kết luận: repo dùng danh sách NCSC 100k theo điều khoản mặc định của website NCSC (OGL v3.0, câu ghi nguồn ở dưới). Dữ liệu gốc từ HIBP,
  không có yêu cầu giấy phép hay ghi nguồn; bản phân phối qua SecLists theo MIT.
- Xem lại khi: bản lưu của bài blog ghi giấy phép khác OGL v3.0 hay ghi danh sách là tài liệu bên thứ ba không được dùng lại; khi đó đổi
  nguồn danh sách bằng một lần thay file dữ liệu, thiết kế của §5 không đổi.
- Ghi nguồn khi phân phối lại: "Contains public sector information licensed under the Open Government Licence v3.0", nguồn NCSC và HIBP,
  link SecLists ở commit ghim.

## Nguồn

- [A1] NIST SP 800-63B-4, Digital Identity Guidelines: Authentication and Authenticator Management:
  <https://pages.nist.gov/800-63-4/sp800-63b.html> (§3.1.1.1, §3.1.1.2, §3.2.2)
- [A2] NIST SP 800-63B (bản 3, đã bị thay), §5.2.2: <https://pages.nist.gov/800-63-3/sp800-63b.html>
- [A3] OWASP REST Security Cheat Sheet: <https://cheatsheetseries.owasp.org/cheatsheets/REST_Security_Cheat_Sheet.html>
- [A4] OWASP Authentication Cheat Sheet: <https://cheatsheetseries.owasp.org/cheatsheets/Authentication_Cheat_Sheet.html>
- [A5] OWASP Credential Stuffing Prevention Cheat Sheet:
  <https://cheatsheetseries.owasp.org/cheatsheets/Credential_Stuffing_Prevention_Cheat_Sheet.html>
- [A6] OWASP, Slow Down Online Guessing Attacks with Device Cookies:
  <https://owasp.org/www-community/Slow_Down_Online_Guessing_Attacks_with_Device_Cookies>
- [A7] RFC 6749, The OAuth 2.0 Authorization Framework, §5.1: <https://www.rfc-editor.org/rfc/rfc6749#section-5.1>
- [A8] RFC 9111, HTTP Caching, §5.4: <https://www.rfc-editor.org/rfc/rfc9111#section-5.4>
- [A9] RFC 9700, Best Current Practice for OAuth 2.0 Security, §4.14: <https://www.rfc-editor.org/rfc/rfc9700#section-4.14>
- [A10] OWASP HTTP Headers Cheat Sheet: <https://cheatsheetseries.owasp.org/cheatsheets/HTTP_Headers_Cheat_Sheet.html>
- [A11] Have I Been Pwned, Pwned Passwords: <https://haveibeenpwned.com/Passwords>; API v3 (mục giấy phép):
  <https://haveibeenpwned.com/API/v3>
- [A12] SecLists: <https://github.com/danielmiessler/SecLists>, `LICENSE`:
  <https://github.com/danielmiessler/SecLists/blob/1a7bb9127eca9e6ff2fc0301c597fe6e16a0cb56/LICENSE>; điều khoản website NCSC:
  <https://www.ncsc.gov.uk/section/about-this-website/terms-and-conditions>; Open Government Licence v3.0:
  <https://www.nationalarchives.gov.uk/doc/open-government-licence/version/3/>; tin về danh sách (ESET WeLiveSecurity, 2019-04-25):
  <https://www.welivesecurity.com/2019/04/25/23million-accounts-123456-password/>
