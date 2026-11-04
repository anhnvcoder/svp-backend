# 0046. Session BFF của web có idle timeout 7 ngày và absolute timeout 30 ngày tường minh, không chỉ dựa vào hạn refresh token

- Trạng thái: Chấp nhận
- Ngày: 2026-11-02
- Người quyết: AI (đề xuất, chốt con số), người học (uỷ quyền)

## Bối cảnh và vấn đề

Web client giữ session phía server ở Redis, cookie chỉ mang `sid` ([0016](0016-web-client.md) §5). OWASP ASVS 5.0.0 (bản ổn định hiện
hành) đòi thời hạn session do chính ứng dụng áp, có tài liệu và lý do: 7.1.1 (ghi idle, absolute và lý do lệch NIST SP 800-63B), 7.3.1
(inactivity timeout), 7.3.2 (absolute lifetime), 7.4.1 (hết hạn thì session không dùng được nữa ở backend). Các mục này thay §3.3 của v4.

**Hiện trạng** (code `svp-frontend` ở commit `e81f4c8`, user-service ở repo này):

- Khoá session hết hạn cùng refresh token: `create` đặt `PXAT refresh_expires_at`
  ([`server/session.ts:138-152`](https://github.com/anhnvcoder/svp-frontend/blob/e81f4c8f43e61b3cfc76a2828203f0c290e08986/server/session.ts#L138-L152)),
  `compareAndSet` đẩy mốc đó sau mỗi lần refresh ([`:181-190`](https://github.com/anhnvcoder/svp-frontend/blob/e81f4c8f43e61b3cfc76a2828203f0c290e08986/server/session.ts#L181-L190)).
- User-service cho refresh token trượt `RefreshTTL` 14 ngày tính từ lần xoay, không quá `RefreshFamilyTTL` 30 ngày sau login
  ([`refresh.go:25-32`](../../services/user-service/internal/server/refresh.go), cắt ở `FamilyExpiresAt` trong `Refresh`).
- Web chỉ refresh khi một request đến lúc access token (1 giờ, `authtoken.TTL`) còn dưới 30 giây
  ([`server/session-access.ts:40-41, 90-92`](https://github.com/anhnvcoder/svp-frontend/blob/e81f4c8f43e61b3cfc76a2828203f0c290e08986/server/session-access.ts#L90-L92));
  không có thao tác "chạm" nào khác.
- Cookie `Max-Age` cố định 30 ngày, đặt một lần lúc login
  ([`server/session.ts:15-17`](https://github.com/anhnvcoder/svp-frontend/blob/e81f4c8f43e61b3cfc76a2828203f0c290e08986/server/session.ts#L15-L17),
  `server/auth-actions.ts:63`).

Tức là đã có idle khoảng 14 ngày (tính từ lần xoay cuối, không từ lần dùng cuối) và absolute 30 ngày, nhưng **ngầm**: 0016 §5 ghi hai số đó
như hệ quả của hạn refresh token; web không có dòng code hay test nào giữ chúng, và chúng đổi theo hằng số của một service khác.

## Yếu tố quyết định

- ASVS 7.3.1, 7.3.2: thời hạn do ứng dụng giữ session áp, theo phân tích rủi ro có ghi lại; OWASP Session Management Cheat Sheet: áp ở server.
- Mức AAL: user-service chỉ có mật khẩu (một yếu tố), nên mọi session tối đa là **AAL1** (AAL2 đòi đa yếu tố). Tác hại khi lộ session là
  đăng video, like, follow dưới tên người dùng; không có thanh toán. NIST SP 800-63B-4 ở AAL1: absolute **SHALL** có, **SHOULD** ≤ 30 ngày;
  idle **MAY**, không bắt buộc.
- Ứng dụng video ngắn cho người tiêu dùng: người dùng quay lại theo ngày hay theo tuần, đăng nhập lại mỗi lần là cái giá người dùng thấy rõ.
- Không ghi Redis mỗi request (một feed gọi nhiều route API), không làm hỏng refresh single-flight và compare-and-set đang có.
- Không đổi hằng số của user-service (hợp đồng chung với mọi client).

## Phương án đã cân nhắc

**Nơi áp thời hạn**

| Phương án | Được | Mất |
| --- | --- | --- |
| A. Giữ ngầm qua hạn refresh token (hiện trạng) | Không đổi code | Không đạt ASVS 7.3.x như một quyết định của web; idle tính từ lần xoay; đổi `RefreshTTL` là đổi session web mà không ai thấy |
| **B. Tường minh trong session store của BFF (chọn)** | Con số nằm ở web, có test; không phụ thuộc hằng số repo khác; vẫn bị chặn trên bởi hạn refresh token | Thêm một field, một script Redis, mỗi giờ tối đa một lệnh ghi mỗi session |
| C. Hạ `RefreshTTL` của user-service xuống bằng idle | Một chỗ cho mọi client | Đổi hợp đồng chung cho một nhu cầu của web; idle vẫn tính từ lần xoay; mobile hay client khác sau này chịu chung idle của web |

**Idle timeout**

| Con số | Được | Mất |
| --- | --- | --- |
| 1 giờ (AAL2 của NIST, cheat sheet 15–30 phút cho ứng dụng ít rủi ro) | Session bỏ quên hết nhanh | Đăng nhập lại gần như mỗi lần mở app; mức đó dành cho AAL2, app này chỉ đạt AAL1 |
| 1 ngày | Ngắn | Người dùng cách ngày phải đăng nhập lại |
| **7 ngày (chọn)** | Người dùng hằng tuần không phải đăng nhập lại; cửa sổ của session bỏ quên trên máy dùng chung còn một nửa so với hiện trạng; dưới `RefreshTTL` một tuần nên web quyết định, không phải user-service | Người dùng thưa hơn một tuần đăng nhập lại |
| 14 ngày (bằng `RefreshTTL`) | Không đổi trải nghiệm hiện tại | Idle web trùng hằng số repo khác, đổi bên đó là lệch; cửa sổ bỏ quên dài gấp đôi |

**Ghi lần dùng gần nhất**

| Cách | Được | Mất |
| --- | --- | --- |
| Mỗi request | Chính xác tới request | Một lệnh ghi Redis mỗi request; tăng `ver` thì lần refresh đang bay thua compare-and-set và thu hồi họ token |
| **Khi lần ghi trước cũ hơn 1 giờ (chọn)** | Tối đa một lệnh ghi mỗi giờ mỗi session; sai số ≤ 1 giờ trên 7 ngày (< 1%); khi đang dùng liên tục, lần refresh mỗi giờ đã ghi luôn | Idle thật có thể ngắn hơn 7 ngày tối đa 1 giờ |
| Chỉ khi refresh (gần hiện trạng) | Không thêm lệnh ghi | Request trong giờ đầu sau một lần refresh không tính là dùng; idle phụ thuộc hạn access token |

## Kết quả quyết định

Chọn **B** với các con số sau, áp trong `SessionStore` theo đồng hồ `now` tiêm vào như hiện nay:

- **Absolute 30 ngày** tính từ `created_at` (field đã có): bằng trần SHOULD của NIST cho AAL1 và bằng `RefreshFamilyTTL`. Không gia hạn bằng
  hoạt động; hết thì đăng nhập lại.
- **Idle 7 ngày** tính từ field mới `last_used_at` (ISO 8601 như các mốc khác). Session ghi bởi code cũ thiếu field này thì lấy `created_at`
  làm lần dùng: lỗi về phía đăng xuất, không giữ session mà web không biết lần dùng cuối.
- **Hạn khoá Redis** (`PXAT`) ở `create`, `compareAndSet` và khi ghi lần dùng là mốc sớm nhất trong `refresh_expires_at`,
  `last_used_at + 7 ngày`, `created_at + 30 ngày`. Hằng số user-service giữ nguyên; nếu bên đó đổi, mốc sớm nhất vẫn đúng.
- **Ghi lần dùng:** khi đọc được session hợp lệ mà `last_used_at` cũ hơn **1 giờ**, ghi `last_used_at = now` và hạn khoá mới bằng một script
  Lua: chỉ ghi khi khoá còn và `ver` còn bằng bản đã đọc, **không tăng `ver`**, để lần refresh đang bay (compare-and-set theo `ver`) không
  thua và không thu hồi họ token. `compareAndSet` của refresh cũng đặt `last_used_at = now` (refresh chỉ chạy khi có request). Ghi lần dùng
  lỗi thì request vẫn tiếp; lần sau thử lại.
- **Hết idle hay absolute = đăng xuất:**
  - Thường khoá đã do Redis tự xoá (hạn khoá là mốc sớm nhất): `get` trả null như session không tồn tại. Refresh token chỉ nằm trong khoá
    đó nên không còn gì để thu hồi; họ token hết hạn ở user-service sau tối đa 14 ngày từ lần xoay cuối, không ai còn giữ token.
  - Đọc được khoá đã quá mốc (khoá ghi bởi code cũ, lệch đồng hồ app với Redis): xoá bằng compare-and-delete và **gọi `/auth/logout`**
    best-effort với refresh token của nó, như `SessionAccess.end` đang làm khi gateway từ chối token.
  - Sau đó như mọi session không còn: trang cần đăng nhập redirect `/login?next=<trang>` (`requireSession`), route API trả 401
    `UNAUTHENTICATED`, trang công khai hiện như chưa đăng nhập.
- **Cookie `Max-Age`** = số giây còn lại tới mốc absolute (`created_at + 30 ngày - now`, làm tròn lên) lúc đặt cookie, tính từ session, không
  từ hằng số riêng. Hôm nay cookie chỉ đặt lúc login nên giá trị là 30 ngày; chỗ nào đặt lại cookie về sau cũng dùng cùng hàm. Cookie sống
  lâu hơn idle không sao: `sid` không còn khoá là chưa đăng nhập (ASVS 7.4.1 giữ ở server, cookie chỉ là con trỏ).

### Hệ quả

- Tốt: ASVS 7.1.1, 7.3.1, 7.3.2 có con số, lý do và test ở web; idle tính từ lần dùng thật; session web không đổi khi user-service đổi hằng số.
- Tốt: refresh token của session bỏ quên rời Redis sau 7 ngày thay vì tới 14 ngày.
- Xấu: người dùng thưa hơn một tuần phải đăng nhập lại; lần đầu chạy bản mới, session thiếu `last_used_at` tạo hơn 7 ngày trước bị đăng xuất.
- Xấu: thêm tối đa một lệnh ghi Redis mỗi giờ mỗi session đang dùng; idle trễ tối đa 1 giờ so với lần dùng thật.
- Không giải: kẻ chiếm được `sid` và dùng đều đặn giữ được session tới absolute (cheat sheet nêu đúng giới hạn này của idle); absolute 30
  ngày và cookie `HttpOnly`, `__Host-` là thứ chặn.
- Xem lại khi: thêm yếu tố xác thực thứ hai (AAL2: absolute ≤ 24 giờ, idle ≤ 1 giờ, cần "nhớ đăng nhập" riêng); thêm thao tác nhạy cảm
  (đổi email, mật khẩu: xác thực lại theo ASVS 7.5.1); số đo cho thấy phần lớn người dùng quay lại thưa hơn 7 ngày.

## Xác nhận

Chưa kiểm: hiện thực ở `svp-frontend` kèm test Vitest (Redis db 15, tiền tố ngẫu nhiên): quá idle thì null và khoá bị xoá; dùng trong idle
thì kéo dài tới tối đa absolute; quá absolute dù đang dùng thì null; lần dùng không ghi quá một lần mỗi giờ và không tăng `ver`; refresh
song song với lần ghi lần dùng không thu hồi họ token; hạn khoá bằng mốc sớm nhất trong ba mốc; `Max-Age` đúng absolute còn lại; session thiếu
`last_used_at`; khoá quá mốc đọc được thì xoá và gọi `/auth/logout`. `make check` của `svp-frontend` xanh.

## Hiện thực ở

Repo `svp-frontend`:

- `server/session.ts`: field `last_used_at`, kiểm idle và absolute trong `get`, hạn khoá mốc sớm nhất, script ghi lần dùng, `Max-Age` của cookie.
- `server/session-access.ts`: ghi lần dùng có giới hạn tần suất, xoá và thu hồi session quá mốc.
- `server/auth.ts`: `signIn` trả `Max-Age` tính từ session; `signOut` đọc cả session đã quá mốc mà Redis chưa xoá.
- `server/auth-actions.ts`: cookie lúc login lấy `Max-Age` từ session.
- `server/session.test.ts`, `server/session-access.test.ts`, `server/auth.test.ts`: test của các mục trên; `server/testing/bff.ts`:
  đồng hồ tiêm vào `SessionStore` của test.

## Nguồn

Truy cập ngày 2026-11-02.

| Nguồn | Link | Nội dung dùng |
| --- | --- | --- |
| OWASP ASVS 5.0.0 (phát hành 2025-05-30), V7 Session Management | <https://github.com/OWASP/ASVS/blob/v5.0.0_release/5.0/en/0x16-V7-Session-Management.md> | 7.1.1 ghi idle, absolute và lý do lệch NIST; 7.3.1 inactivity timeout, 7.3.2 absolute lifetime "according to risk analysis and documented security decisions" (L2); 7.4.1 hết hạn thì vô hiệu ở backend (L1); 7.5.1 xác thực lại trước thao tác nhạy cảm |
| NIST SP 800-63B-4 (Final, 2025-07-31) | <https://pages.nist.gov/800-63-4/sp800-63b.html#aal1reauth>, `#aal2reauth`, `#aal3reauth`; trang công bố <https://csrc.nist.gov/pubs/sp/800/63/b/4/final> | AAL1 §2.1.3: overall timeout SHALL có, SHOULD ≤ 30 ngày; inactivity MAY. AAL2 §2.2.3: ≤ 24 giờ, idle ≤ 1 giờ, đòi đa yếu tố. AAL3 §2.3.3: ≤ 12 giờ, idle ≤ 15 phút. Session §5.2 |
| OWASP Session Management Cheat Sheet | <https://cheatsheetseries.owasp.org/cheatsheets/Session_Management_Cheat_Sheet.html> | Mọi session có idle và absolute, áp ở server; idle 15–30 phút cho ứng dụng ít rủi ro (session thường, không "nhớ đăng nhập"); idle không chặn kẻ chiếm session dùng đều; xoá cookie không vô hiệu bản sao bị lấy |
| RFC 9700 §4.14.2 | <https://www.rfc-editor.org/rfc/rfc9700.html> | Refresh token xoay vòng; dùng lại thì thu hồi (lý do ghi lần dùng không được làm hỏng refresh single-flight) |
