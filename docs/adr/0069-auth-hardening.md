# 0069. Cứng hoá xác thực: giới hạn đăng nhập theo tài khoản có cặp đã biết, header bảo mật ở gateway, access token 15 phút, chặn mật khẩu phổ biến hay đã lộ

- Trạng thái: Chấp nhận
- Ngày: 2026-11-14
- Người quyết: người học (access token 15 phút, ngân sách k6, danh sách SecLists NCSC), AI đề xuất lớp giới hạn, con số, header, cách kiểm

## Bối cảnh và vấn đề

- Login chỉ giới hạn theo IP (`login-ip`) và theo cặp (IP, email) (`login-email`) ([0010](0010-redis-ratelimit-cache-resilience-stage2c.md)
  §2): kẻ dò trải trên nhiều IP thử không giới hạn trên một tài khoản. Threat model JWT-4 không khoá tài khoản, vì khoá biến chống dò thành
  công cụ DoS chủ thật; hệ thống chưa có luồng khôi phục tài khoản (xác minh email, đặt lại mật khẩu).
- Gateway không đặt header bảo mật nào; response login, refresh mang token mà không có `Cache-Control: no-store`. Edge của stg, prd đặt
  header cho API ([0061](0061-edge-cloudfront-waf-acm.md) §6); compose, k3d và lưu lượng trong cluster thì không.
- Access token sống 1 giờ, không thu hồi được trước hạn ([0016](0016-web-client.md) §2, threat model JWT-3); refresh token xoay vòng đã có.
  Đăng ký nhận mọi mật khẩu đủ độ dài, kể cả mật khẩu phổ biến nhất.

## Yếu tố quyết định

- Chống dò phân tán trên một tài khoản mà kẻ xấu không khoá được chủ thật ở nơi chủ thật hay đăng nhập.
- Không gửi dữ liệu người dùng ra ngoài, không phụ thuộc mạng ngoài, không dependency mới, không đổi ACL Valkey; token lộ dùng được
  ít thời gian mà không tra trạng thái ở mỗi request, web không đổi logic.
- Theo chuẩn có nguồn (NIST SP 800-63B-4, OWASP Cheat Sheet, RFC 6749, 9111, 9700); chỗ lệch chuẩn ghi lý do.

## Phương án đã cân nhắc

Được, mất, trạng thái ngành và nguồn: [phụ lục](appendix/0069-auth-hardening.md#phương-án).

- Giới hạn login: khoá tài khoản sau N lần sai; chỉ giới hạn theo email trên mọi IP; **theo email, trừ cặp (IP, email) đã đăng nhập thành
  công**; CAPTCHA; device cookie.
- Header: **bộ tối thiểu của OWASP REST Security cho API JSON, đặt ở gateway**; đủ hai bảng của OWASP; chỉ edge đặt như hiện nay.
- Thu hồi access token: **access token 15 phút**; `tokens_valid_after` theo user với token 1 giờ; cả hai.
- Mật khẩu chặn: **danh sách cục bộ nhúng binary (SecLists NCSC 100k)**; range API của Have I Been Pwned (HIBP); Bloom filter Pwned Passwords.

## Kết quả quyết định

Chọn các phương án in đậm. Dưới đây là quyết định và con số mới; giá trị của các lớp đã có nằm ở code (mục Hiện thực ở).

### 1. Lớp `login-account`

- Lớp mới `login-account` ở `ratelimit.go`: **100 lượt mỗi 24 giờ, burst 10**; Valkey lỗi: **50 mỗi 24 giờ, burst 5** trong bộ nhớ. Id
  `EmailHash(email)` (32 ký tự hex đầu của SHA-256 email đã `TrimSpace` + `ToLower`), không có IP: một bucket cho email trên mọi IP.
  `login-email` giữ id `ip + ":" + EmailHash(email)`, cùng giá trị như trước.
- Thứ tự kiểm ở handler `login`: `login-ip` → giải body → `login-email` → cặp đã biết (§2)? nếu không: `login-account` → `Login` của
  user-service → thành công thì ghi cặp đã biết.
- Đếm GCRA nguyên tử trước `Login`, không hoàn lại khi thành công: kẻ dò song song không lách được giữa "xem" và "đếm". Email không có tài
  khoản cũng đếm như vậy, nên 429 `RATE_LIMITED` không cho biết email có tồn tại.
- Một lượt hồi mỗi 14,4 phút; khoá sống tối đa 144 phút. Từ IP chưa biết (Valkey khoẻ) kẻ dò lấy tối đa 110 lượt ngày đầu rồi 100 lượt/ngày một tài khoản,
  ít hơn hẳn số mật khẩu phổ biến mà §5 cấm đặt, nên các lượt đoán dễ nhất đều trượt.
- Lệch NIST: SP 800-63B-4 §3.2.2 đòi vô hiệu hoá authenticator sau tối đa 100 lần sai liên tiếp rồi bắt gắn lại. Chưa có luồng gắn lại
  nên vô hiệu hoá là khoá vĩnh viễn; lớp này giới hạn tốc độ thay vì khoá, cùng mục đích chống dò trực tuyến.

### 2. Cặp đã biết

- Cặp (IP, email) đã đăng nhập thành công từ IP đó trong **30 ngày** (bằng hạn cả họ refresh token): khoá
  `<prefix>login-known:<ClientIP>:<EmailHash>` (`svp:gw:login-known:…`, không dưới `rl:`), giá trị `1`. Login thành công thì
  `SET … EX 2592000`; trước `login-account` thì `GET`; cả hai trong `storeTimeout`, ACL `svp-gateway` hiện có đủ.
- `GET` lỗi: coi là chưa biết, đi tiếp `login-account`. `SET` lỗi: log WARN như lớp rate limit, response không đổi. Cặp đã biết vẫn qua
  `login-ip`, `login-email`.
- Đây là kỹ thuật risk-based theo IP của NIST SP 800-63B-4 §3.2.2 (bản 3 ghi rõ: chỉ nhận từ IP đã xác thực thành công trước đó), cùng ý
  với device cookie của OWASP nhưng theo IP thay vì theo client.
- Rủi ro chấp nhận: cuộc dò gửi ≥ 100 lượt mỗi ngày lấy hết lượt; trong lúc đó chủ thật ở IP chưa biết (mạng di động đổi IP, máy mới) không
  đăng nhập được, từ IP đã biết vẫn được. Gỡ tay: theo dõi metric quyết định của lớp, chặn nguồn ở WAF. Ở compose mọi request qua web chung
  IP của BFF, nên cặp đã biết ở đó là theo BFF.
- Dữ liệu cá nhân mới: (IP, SHA-256 email) sống 30 ngày. Băm không khoá như `login-email`: HMAC cần bí mật mới ở mọi môi trường, mỗi lần
  xoay xoá hết cặp đã biết, mà chỉ người đọc được Valkey (`svp-gateway`, `svp-ops`) mới dò ngược được email.

### 3. Header bảo mật ở gateway

Middleware `httpx.SecurityHeaders` bọc mọi response của gateway (cả `/healthz`, `/readyz`, 404, problem, 500 của `Recover`), đặt trước khi
handler chạy:

| Header | Giá trị | Vì sao |
| --- | --- | --- |
| `X-Content-Type-Options` | `nosniff` | OWASP REST Security: chặn trình duyệt đoán kiểu nội dung |
| `Content-Security-Policy` | `default-src 'none'; frame-ancestors 'none'` | OWASP REST Security (cả hai bảng); trùng policy `svp-<env>-api` của edge |
| `Cache-Control` | `no-store`; `getPublicVideo` thành công đặt `public, max-age=30` | RFC 6749 §5.1 (response mang token), OWASP REST Security |

Không đặt ở gateway: `Strict-Transport-Security`, `X-Frame-Options` (edge đặt, [0061](0061-edge-cloudfront-waf-acm.md) §6; XFO đã được
`frame-ancestors` thay), `Referrer-Policy`, `Permissions-Policy` (chỉ có tác dụng với HTML), `Pragma` (RFC 9111 §5.4 bỏ; lệch RFC 6749 §5.1
vốn đòi `Pragma: no-cache`), `X-XSS-Protection` (OWASP: không đặt), CORS (trình duyệt chỉ gọi BFF cùng origin). Policy api của edge
`override = true` ghi đè bằng cùng giá trị và không đặt `Cache-Control`. Bảng đủ: [phụ lục](appendix/0069-auth-hardening.md#header-theo-owasp).

### 4. Access token 15 phút và ngân sách k6

- `authtoken.TTL` = **15 phút**; `Leeway` giữ 30 s; hạn refresh token và hạn cả họ không đổi; không `tokens_valid_after`.
- `tokens_valid_after` buộc năm nơi kiểm JWT (gateway và bốn service gRPC, [0042](0042-caller-identity-grpc.md)) tra trạng thái user ở mỗi
  request hay giữ bản sao từ event, mà chưa có gì kích hoạt nó: không có RPC đổi mật khẩu, logout đã thu hồi cả họ refresh token. Access
  token ngắn kèm refresh token là cách RFC 9700 §4.14 tả.
- Web không đổi logic: BFF làm mới trước `expires_at` 30 s (`refreshEarlyMs` của `svp-frontend`).
- Cái giá: token lộ dùng được tối đa 15 phút 30 giây; mỗi phiên đang dùng refresh gấp 4, lớp `refresh` theo IP nhận gấp 4 lượt.
  Ngân sách k6: token của k6 cấp trong `setup()`, không làm mới. Mọi profile có `ramp + hold + rampDown ≤ 11m` (15 phút trừ `setupTimeout`
  3 phút của `deploy/k6/main.js`, trừ `gracefulStop` 30 s mặc định, làm tròn xuống); vượt, kể cả qua `SVP_K6_RAMP`, `SVP_K6_HOLD`, thì
  `deploy/k6/lib/config.js` dừng lúc khởi tạo và nêu hạn access token. Profile `cloud`: **ramp 3m, hold 7m, rampDown 1m**, cùng số ở
  `deploy/k6/cloud/render.sh`.

### 5. Danh sách mật khẩu chặn

- File nhúng (`go:embed`) `services/user-service/internal/password/blocklist.txt`, sinh bằng `blocklist.sh` từ danh sách NCSC 100k của
  SecLists ở commit ghim (đường file, sha256, giấy phép: [phụ lục](appendix/0069-auth-hardening.md#ghim-nguồn-danh-sách)): mỗi dòng một
  mục, chữ thường, sắp xếp theo byte, không trùng, độ dài trong giới hạn mật khẩu của `password.go`.
- Bị chặn khi `strings.ToLower(pw)` có trong danh sách, hay bằng chữ thường của email, của phần trước `@`, của handle người dùng chọn (khi
  không rỗng); so cả chuỗi, không so chuỗi con (NIST SP 800-63B-4 §3.1.1.2). Chỉ kiểm khi đặt mật khẩu (`Register`; chưa có RPC đổi mật
  khẩu); `Login` không kiểm.
- `Register` trả `INVALID_ARGUMENT`, reason `PASSWORD_BLOCKLISTED` (hằng `ReasonPasswordBlocklisted`), sau kiểm độ dài, trước kiểm handle;
  gateway trả 400 problem `code` `PASSWORD_BLOCKLISTED` qua ánh xạ sẵn có; web nêu lý do ở ô mật khẩu như NIST đòi (câu chữ vi, en:
  [phụ lục](appendix/0069-auth-hardening.md#mã-lỗi-mật-khẩu-chặn)).
- HIBP range API chỉ gửi 5 ký tự đầu của SHA-1, nhưng cần egress internet từ user-service, mở NetworkPolicy, chọn fail-open hay fail-closed
  khi HIBP lỗi; Bloom filter của toàn bộ Pwned Passwords tốn cỡ 180 MB mỗi 100 triệu hash và phải tải lại để cập nhật. NIST: danh sách
  quá lớn ít thêm an toàn vì dò trực tuyến đã bị §3.2.2 giới hạn; danh sách đủ cho khoảng một năm dò liên tục; dò lâu hơn thì metric và WAF chặn nguồn (§1).

### Hệ quả

- Tốt: dò phân tán từ IP chưa biết còn tối đa 100 lượt/ngày một tài khoản; chủ thật từ IP đã biết không bị khoá; response mang token không vào cache;
  header như nhau ở mọi môi trường; token lộ sống tối đa 15 phút 30 giây; mật khẩu phổ biến không đặt được; không dữ liệu nào rời hệ thống.
- Xấu: một khoá Valkey mỗi cặp đã biết, sống 30 ngày; người dùng ở IP mới bị chặn trong lúc tài khoản bị dò; refresh gấp 4; lượt `cloud`
  của k6 giữ tải 7 phút thay vì ≥ 10 phút; danh sách 100k không phủ mật khẩu lộ mới; tài khoản tạo trước đó giữ mật khẩu cũ. Lệch chuẩn đã
  biết: không vô hiệu hoá sau 100 lần sai (§1), không `Pragma` (§3), độ dài tối thiểu của `password.go` dưới 15 ký tự mà NIST SP
  800-63B-4 §3.1.1.2 đòi cho mật khẩu một yếu tố.
- Xem lại khi: có luồng khôi phục tài khoản hay MFA (vô hiệu hoá theo NIST, độ dài 15); có client không phải web (device cookie); metric
  của `login-account` cho thấy chủ thật bị 429; cần cắt phiên ngay (đổi mật khẩu, khoá tài khoản: `tokens_valid_after`); lượt k6 cần giữ
  tải quá 11 phút (VU tự làm mới token); chuyển sang IdP.

## Xác nhận

- `make test`: gateway (`login-account`, cặp đã biết, Valkey lỗi khi `GET`/`SET` trên Redis native db 15, thứ tự kiểm login, header trên
  mọi response kể cả 404, 500, `getPublicVideo`); `authtoken` (TTL 15 phút); user-service (danh sách sắp xếp, không trùng; chặn theo
  email, handle; reason `PASSWORD_BLOCKLISTED`). `blocklist.sh` chạy lại ra đúng file đã commit; `make api-contract-check`; `config.js`
  từ chối profile k6 vượt ngân sách.
- Buổi stg rồi prd: header của API, 400 `PASSWORD_BLOCKLISTED`, `expires_at` cách lúc cấp 15 phút, web còn đăng nhập sau 15 phút.

## Hiện thực ở

- `services/gateway/internal/ratelimit/`: `login-account` (`ratelimit.go`), `EmailHash`, `LoginEmailID` (`keys.go`), cặp đã biết
  (`known.go`) (§1, §2). `services/gateway/internal/api/api.go`: thứ tự kiểm login, bọc `SecurityHeaders`, `Cache-Control` của
  `getPublicVideo` (§1–§3). `services/gateway/internal/httpx/headers.go`: `SecurityHeaders` (§3).
- `internal/authtoken/authtoken.go` (`TTL`); `deploy/k6/lib/config.js`, `deploy/k6/cloud/render.sh`, `job.yaml.in` (ngân sách k6) (§4).
- `services/user-service/internal/password/` (`blocklist.txt`, `blocklist.sh`, `blocklist.go`, `password.go`),
  `services/user-service/internal/server/server.go`, `proto/svp/user/v1/user_service.proto` (§5).
- `services/gateway/openapi.yaml`: TTL, header, `PASSWORD_BLOCKLISTED`, 429 của `login-account`. `svp-frontend`: `messages/vi/auth.json`,
  `messages/en/auth.json`, `components/auth/auth-form.tsx` (§5).

## Nguồn

Đọc 2026-11-14; trích dẫn và đủ [A1]–[A12] ở [phụ lục](appendix/0069-auth-hardening.md#nguồn). [A1] <https://pages.nist.gov/800-63-4/sp800-63b.html>,
[A3] <https://cheatsheetseries.owasp.org/cheatsheets/REST_Security_Cheat_Sheet.html>, [A7] <https://www.rfc-editor.org/rfc/rfc6749#section-5.1>.

## Thông tin thêm

Phụ lục: [`appendix/0069-auth-hardening.md`](appendix/0069-auth-hardening.md) (bảng phương án, header theo OWASP, con số của
`login-account`, trích dẫn có mục, ghim nguồn danh sách).
