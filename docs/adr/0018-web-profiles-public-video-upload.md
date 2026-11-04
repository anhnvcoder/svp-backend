# 0018. Handle không đổi và tên hiển thị ở user-service, danh sách video theo tác giả, route công khai `GET /public/videos/{id}` có rate limit theo IP, upload từ trình duyệt

- Trạng thái: Chấp nhận
- Ngày: 2026-10-22

## Bối cảnh và vấn đề

- [ADR-0016](0016-web-client.md) §11 chỉ chốt khung của phần B: upload XHR, `/v/:id` công khai có Open Graph, hồ sơ tối thiểu và "Video của tôi", CORS MinIO đúng origin web, Lighthouse. Phần B cần backend mới ở ba service và gateway, nên ADR này chốt contract trước khi viết code: RPC, field, REST, mã lỗi, giới hạn, lớp rate limit, route web. Chỗ nào thiếu thì sửa ADR trước.
- user-service chỉ giữ email, hash mật khẩu và follow, không có gì hiển thị được thay cho người dùng (email là dữ liệu riêng, JWT-8); video-service chỉ đọc từng video (`GetVideo`, cần caller) và video chưa `READY` chỉ tác giả thấy (UP-3); mọi route trừ `/auth/*` cần Bearer, mọi RPC trừ `Register`, `Login`, `Refresh`, `Logout` cần caller ([ADR-0006](0006-contract-ids-and-event-envelope.md) §5), nhưng link chia sẻ mở từ app chat cho người chưa đăng nhập cần một đường đọc không xác thực.
- Gateway ghép `stats` bằng một `GetStats` cho cả trang, hạn 100 ms, không retry ([ADR-0009](0009-engagement-feed-stage2b.md) §9); feed p99 < 150 ms ([architecture §2](../architecture.md)). Upload: presigned POST hạn 15 phút, ≤ 500 MiB, tối đa 3 video `UPLOADING` trong 15 phút mỗi user (`TOO_MANY_UPLOADS`), job dọn chuyển video bỏ dở sang `FAILED` sau 1 giờ ([ADR-0010](0010-redis-ratelimit-cache-resilience-stage2c.md) §5); MinIO community chỉ có CORS toàn cục, mặc định `*` (WEB-10).
- Ràng buộc: contract chỉ **thêm** field và RPC (`buf breaking` sạch); `make smoke`, diễn tập, k6 và seed e2e chạy không đổi; không thêm dependency Go, gói npm chỉ trong danh sách ADR-0016 §10; máy 16 GB. Hiện trạng đầy đủ (mã thiết kế M20–M41, D03–D11): phụ lục.

## Yếu tố quyết định

Contract chỉ thêm; luật "chỉ tác giả thấy video chưa `READY`" nằm một chỗ; link chia sẻ mở được khi chưa đăng nhập mà không nới luật đó; ghép tác giả trong ngân sách 100 ms của gateway; không dependency mới; backend upload không đổi.

## Phương án đã cân nhắc

- §1 **A handle duy nhất, chọn lúc đăng ký, không đổi**
- §1 B handle đổi được (link cũ gãy hoặc cần bảng chuyển hướng)
- §1 C không handle (URL hồ sơ là UUID, tên trùng nhau)
- §2 **A đổi được, mặc định bằng handle, không event**
- §2 B bắt buộc nhập lúc đăng ký (client cũ phải đổi)
- §2 C phát event để service khác giữ bản sao tên (event, consumer, bảng bản sao chưa ai cần)
- §3 **A ba RPC** (đọc nhiều hồ sơ không cần caller, đọc theo handle và đổi tên cần caller)
- §3 B thêm `GetMe` riêng
- §3 C đọc theo handle không cần caller (cần chế độ caller tuỳ chọn)
- §4 **A RPC ở video-service, keyset `created_at`, `video_id`**
- §4 B ở feed-service (chỉ có video `READY`)
- §4 C `OFFSET` (lệch trang)
- §5 **A gateway ghép một `GetProfiles` mỗi trang song song `GetStats`**
- §5 B feed-service giữ bản sao hồ sơ
- §5 C gọi tuần tự hay có retry (vượt 100 ms)
- §6 **A route riêng `/public/...`**
- §6 B `GET /videos/{id}` nhận cả request không token
- §6 C web đọc bằng tài khoản dịch vụ (credential dài hạn ở web)
- §8 **A XHR tự viết gửi presigned POST**
- §8 B `fetch` stream (chỉ Chromium, không tiến độ thật)
- §8 C multipart hay resumable (Uppy, tus; là phương án khi cần resume)
- §10 **A `@lhci/cli` local trên stack compose**
- §10 B job CI (cần dựng cả stack trên runner, dời sang giai đoạn 6)

Phân tích được/mất từng phương án: [phụ lục](appendix/0018-web-profiles-public-video-upload.md).

## 1. Handle

Chọn **A**, handle không đổi được ở 5b.

- **Dạng người chọn:** sau chuẩn hoá khớp `^[a-z][a-z0-9_]{2,29}$` (3–30 ký tự) và **không** khớp `^u_[0-9a-f]{12}$` (dạng sinh tự động). Chuẩn hoá: `strings.TrimSpace`, rồi hạ chữ thường **chỉ cho `A`–`Z`** (không dùng `strings.ToLower`: dấu Kelvin `K` U+212A thành `k`); ký tự ngoài ASCII làm handle sai dạng. Không có danh sách handle cấm (WEB-17). Rỗng sau khi trim nghĩa là **không gửi**: service sinh handle.
- **Lưu trữ** (migration mới của user-service, có `Down`): `handle` là `text NOT NULL`, `CONSTRAINT users_handle_key UNIQUE (handle)`, `CONSTRAINT users_handle_check CHECK (handle ~ '^[a-z][a-z0-9_]{2,29}$')`; `display_name` là `text NOT NULL`, `CONSTRAINT users_display_name_check CHECK (char_length(display_name) BETWEEN 1 AND 50)`. User cũ backfill `'u_' || right(id::text, 12)` trong cùng migration; trigger `BEFORE INSERT` `users_fill_profile` giữ bản trước chạy được lúc rollout (từng bước, ca biên: phụ lục).
- **Lỗi:** sai dạng → `INVALID_ARGUMENT`, reason **`INVALID_HANDLE`** → 400; đã có chủ → `ALREADY_EXISTS`, reason **`HANDLE_ALREADY_TAKEN`** → 409. `Register` kiểm theo thứ tự email, mật khẩu, handle, tên hiển thị, **trước khi** hash mật khẩu; hai `Register` song song cùng handle do ràng buộc unique quyết.

## 2. Tên hiển thị

Chọn **A**.

- **Luật** (user-service kiểm ở `Register` và `UpdateDisplayName`): UTF-8 hợp lệ; `strings.TrimSpace`; **1–50 rune** (`utf8.RuneCountInString`); không chứa ký tự điều khiển Cc, U+2028, U+2029, ký tự định dạng Cf (gồm ký tự bidi U+202A–U+202E, U+2066–U+2069: WEB-18), code point default-ignorable khác và ô Braille trống U+2800. Ngoại lệ: ZWJ U+200D và variation selector được nhận cho emoji ghép nhưng không tính là ký tự hiện: tên phải có ít nhất một ký tự hiện không phải khoảng trắng. Danh sách đầy đủ và lý do: phụ lục.

## 3. API hồ sơ

Chọn **A**. Contract ở `proto/svp/user/v1/user_service.proto`:

- `RegisterRequest` thêm `handle = 3`, `display_name = 4`; `Profile { user_id = 1; handle = 2; display_name = 3; }`, **không bao giờ có email**.
- **`GetProfiles(user_ids)` → `profiles`**: **không cần caller** (`PublicMethods`); tối đa 50 id UUID chuẩn, id không có user bị bỏ qua; lỗi `INVALID_ARGUMENT` `TOO_MANY_USER_IDS` (> 50), `INVALID_USER_ID`.
- **`GetProfileByHandle(handle)` → `profile`, `followed_by_me`**: **cần caller**; handle chuẩn hoá như §1; `NOT_FOUND` `USER_NOT_FOUND` cả khi chuỗi không thể là handle (không trả `INVALID_ARGUMENT`).
- **`UpdateDisplayName(display_name)` → `profile`**: **cần caller**, **idempotent**; lỗi `INVALID_DISPLAY_NAME`, `USER_NOT_FOUND`.

REST (gateway, mọi route cần Bearer, lớp theo `user_id`):

| Route | Lớp | RPC | Trả |
| --- | --- | --- | --- |
| `GET /me` | `read` | `GetProfiles([caller])`, hạn chung 3 s | 200 `Profile`; không có hồ sơ → 404 `USER_NOT_FOUND` |
| `PATCH /me` | `write` | `UpdateDisplayName` | 200 `Profile`; body `{"display_name": "..."}`, field lạ → 400 `INVALID_JSON`, > 64 KiB → 413 |
| `GET /profiles/{handle}` | `read` | `GetProfileByHandle` | 200 `UserProfile` (`user_id`, `handle`, `display_name`, `followed_by_me`); 404 `USER_NOT_FOUND` |

## 4. Danh sách video theo tác giả

Chọn **A**. Contract ở `proto/svp/video/v1/video_service.proto`:

- **`ListAuthorVideos(author_id, page_size, page_token)` → `videos`, `next_page_token`**: **cần caller**; tác giả → video mọi trạng thái, người khác → chỉ `READY` (cùng luật `GetVideo`, UP-3). Lỗi `INVALID_ARGUMENT` `INVALID_AUTHOR_ID`, `INVALID_PAGE_SIZE`, `INVALID_PAGE_TOKEN`.
- **Cursor** cùng định dạng [phân trang feed](../reference/contracts.md#phân-trang-feed), field 1 là `created_at`, gói `internal/pagetoken`; dài quá 64 ký tự thì từ chối trước khi giải mã; **không ký** (PG-1). **`page_size`:** 0 → 10, > 50 → 50, âm → `INVALID_PAGE_SIZE`; web hỏi 18; đọc `page_size + 1` dòng.
- REST (Bearer, lớp `read`; `cursor`, `page_size`; trả `VideoPage` gồm `items`, `next_cursor`): `GET /users/{user_id}/videos` (video `READY` của người đó; `user_id` là chính caller thì như `/me/videos`) và `GET /me/videos` (mọi video của caller). Item là `Video` kèm `author` và `stats`; video chưa `READY` có số đếm 0.

## 5. Tác giả trong response

Chọn **A**, áp cho item của `GET /feed/following`, `GET /feed/explore`, `GET /users/{user_id}/videos`, `GET /me/videos`, `GET /videos/{video_id}`, `GET /public/videos/{video_id}`.

- **Một** `GetProfiles` với các `author_id` **đã khử trùng** của trang, chạy **song song** với `GetStats`; mỗi lời gọi hạn **100 ms** riêng (`statsTimeout`), không retry. Lỗi hay quá hạn → mọi item vắng `author`, log WARN `served without authors`. `author` = `{user_id, handle, display_name}`; mọi field mới tuỳ chọn.

## 6. Route công khai `GET /public/videos/{video_id}`

Chọn **A**.

- **Không đọc Bearer** (token sai cũng bỏ qua, không 401). Thứ tự: rate limit lớp `public` theo IP **trước** mọi lời gọi; `GetPublicVideo`; rồi `GetProfiles` và `GetStats` song song (100 ms), `GetStats` **không** gửi `x-user-id`.
- **`GetPublicVideo(video_id)` → `video`**: **không cần caller**, chỉ trả video `READY`; id sai dạng, không có video, `UPLOADING`/`PROCESSING`/`FAILED` → **cùng** `NOT_FOUND` `VIDEO_NOT_FOUND`.
- **Response** `PublicVideo`: field của `FeedItem`, `author`, `stats` kiểu `PublicVideoStats` (`view_count`, `like_count`, **không** `liked_by_me`). Mọi ca không xem được là 404 `VIDEO_NOT_FOUND` cùng `detail`.
- **Rate limit lớp `public`** (thêm vào bảng lớp của ADR-0010 §2), đóng mềm như `register`, `login`, `refresh` (RL-2); vượt ngưỡng → 429 `RATE_LIMITED` có `Retry-After`, metric `svp.ratelimit.decisions` có `class="public"`:

  | Lớp | Route | Khoá | Redis tốt | Redis lỗi |
  | --- | --- | --- | --- | --- |
  | `public` | `GET /public/videos/{video_id}` | IP | 120/phút, burst 60 | đóng mềm: 60/phút, burst 30 |

## 7. Route web

| Route | Đăng nhập | Việc |
| --- | --- | --- |
| `/upload` | cần | tải lên (mục 8), M20–M32, D05–D06 |
| `/me` | cần | "Video của tôi" (M33–M34, D09): hồ sơ của mình (avatar, tên hiển thị, `@handle`), mọi video mọi trạng thái từ `GET /me/videos`, đổi tên hiển thị (Server Action gọi `PATCH /me`), đăng xuất |
| `/u/{handle}` | cần | hồ sơ người khác (M35–M37, D10) từ `GET /profiles/{handle}` rồi `GET /users/{user_id}/videos`; nút theo dõi theo `followed_by_me`, `aria-pressed` |
| `/v/{id}` | **không** | trang chia sẻ (M38–M40, D04, D11): SSR + Open Graph |

- `/u/{handle}`: web hạ `A`–`Z`, khác `{handle}` thì chuyển hướng về chữ thường; không khớp `^[a-z][a-z0-9_]{2,29}$` hay 404 `USER_NOT_FOUND` → trang 404 riêng; handle của chính mình → chuyển hướng `/me`. `/v/{id}`: `{id}` phải là UUID chuẩn, sai → 404 không gọi gateway; không có cookie phiên → `GET /public/videos/{id}` (không Bearer, không chạm Redis); có phiên → `GET /videos/{id}` bằng token của phiên, chỉ hiện khi `READY`; 429 → màn M40 đếm ngược theo `Retry-After`, lỗi khác → M41.

## 8. Upload từ trình duyệt

Chọn **A** (thiết kế `web/design/UploadFlow.dc.html`).

- **Kiểm trước khi gửi** (mềm, `ffprobe` ở media-worker mới là chuẩn): `size` ≤ 524 288 000 byte (500 MiB) → M21; `file.type` bắt đầu bằng `video/` (rỗng thì đoán theo đuôi `.mp4`, `.mov`, `.webm`) → M22; thời lượng ≤ 180 s → M23, trình duyệt không đọc được metadata thì **vẫn cho gửi**; tiêu đề 1–200 ký tự sau trim → M26.
- **Gửi:** `POST /api/videos` (`title`, `size_bytes`, `content_type`) → `upload_url`, `form_fields`, `expires_at`; **kiểm `new URL(upload_url).origin === UPLOAD_ORIGIN`** trước khi gửi, sai thì báo lỗi, không gửi byte nào; `FormData` với `form_fields` trước, `file` cuối; `XMLHttpRequest` `POST`, không `withCredentials`; `upload.onprogress` cho % và tốc độ (làm request thành preflight CORS).
- **429 `TOO_MANY_UPLOADS`** → M24, không thử lại; 429 `RATE_LIMITED` → chờ `Retry-After`; 401 → `/login?next=/upload`. **Huỷ** = `abort()`, video vẫn chiếm một trong 3 lượt tải trong 15 phút. **Xong:** `POST /api/videos/{id}/complete`, thử lại được; **chờ xử lý:** poll `GET /api/videos/{id}` (2 s, nhân 1,5, trần 10 s) tới `READY` (M31) hay `FAILED` (M32).

## 9. CORS của MinIO (WEB-10)

**Bị thay một phần bởi [0022](0022-local-object-store-minio-replacement.md)**: store là RustFS, CORS đặt theo bucket bằng `PutBucketCors` ở job `s3-init` (`uploads` chỉ `POST`, `media` chỉ `GET`, `HEAD`, cùng origin web), danh sách toàn cục để rỗng; `http://127.0.0.1:3001` vẫn không nằm trong danh sách. Quyết định lúc đầu (nguyên văn ở phụ lục): service `minio` đặt `MINIO_API_CORS_ALLOW_ORIGIN=http://localhost:3001,http://localhost:3002`, toàn cục cho mọi bucket; origin chuẩn là `http://localhost:3001`; k3d làm ở phần C; S3 hay CloudFront ở giai đoạn 7 có CORS theo bucket.

## 10. Lighthouse

Chọn **A** ở 5b; chuyển vào CI cùng e2e ở giai đoạn 6 (ADR-0016 §11).

- **Kết quả và quyết định (2026-10-22):** chưa đạt LCP ≤ 2 500 ms dưới throttling mô phỏng ở cả hai trang, CLS và TBT đạt; lhci **giữ** ngưỡng, `make web-lighthouse` chưa chặn PR; việc tiếp dời sang giai đoạn 6 (thumbnail nhỏ hơn, bớt font tải sớm, poster của video kế chỉ tải sau LCP). Ràng buộc của cách truyền cookie (`extraHeaders` tới mọi origin): phụ lục.

## 11. Ngân sách bundle

Hai lớp như ADR-0016 §10 (`web/.size-limit.json`, `make web-check`, gzip, kB là 1000 byte); `/v/[id]` dùng cùng player và cách tải lười với feed nên cùng ngân sách, `/upload` chỉ có form và XHR nên như login:

| Route | Lớp 1: JS của route trên runtime của Next | Lớp 2: tải lần đầu |
| --- | --- | --- |
| `/v/[id]` (player hls.js light tải lười, như feed) | ≤ 200 kB | ≤ 330 kB |
| `/upload` (XHR tự viết, không gói mới) | ≤ 80 kB | ≤ 210 kB (≤ 200 kB tới phần B; nới ở phần C cùng login, [ADR-0019](0019-web-k3d-supply-chain-observability.md) §12) |

## 12. Tổng hợp contract

Gồm ba bảng: RPC mới hay đổi (caller, retry `UNAVAILABLE`, breaker không tính `DEADLINE_EXCEEDED`), route REST mới hay đổi (xác thực, lớp rate limit, kiểu trả) và mã lỗi mới (`INVALID_HANDLE`, `HANDLE_ALREADY_TAKEN`, `INVALID_DISPLAY_NAME`, `USER_NOT_FOUND`, `INVALID_AUTHOR_ID`, `INVALID_PAGE_SIZE`, `INVALID_PAGE_TOKEN`, `VIDEO_NOT_FOUND`, `TOO_MANY_USER_IDS`, `INVALID_USER_ID`). Bảng đủ ở phụ lục; nguồn hiện hành là `proto/` và `services/gateway/openapi.yaml`.

## Kết quả quyết định

Chọn các phương án in đậm ở "Phương án đã cân nhắc" và triển khai theo §1–§12.

### Hệ quả

- Tốt:
  - Hồ sơ có link ổn định; web hiện tên và `@handle` ở feed, hồ sơ, trang chia sẻ mà feed-service không đổi.
  - Link video mở được khi chưa đăng nhập, có Open Graph, mà luật video chưa `READY` (UP-3) không nới.
  - Upload thẳng từ trình duyệt tới storage, có tiến độ, thử lại, huỷ; backend upload không đổi.
  - Contract chỉ thêm: smoke, diễn tập, k6 chạy như cũ.
- Xấu:
  - Route không xác thực đầu tiên ngoài `/auth/*`; ở compose mọi khách chung một bucket rate limit.
  - Mỗi trang thêm một lời gọi song song tới user-service (user-service vào đường đọc feed); user-service chậm thì thiếu tên.
  - `callerid` có thêm chế độ caller tuỳ chọn.
  - Handle không đổi được; user cũ và user đăng ký qua API không chọn handle mang handle `u_…`.
  - Liệt kê handle (WEB-16) và mạo danh bằng tên hiển thị (WEB-17) chấp nhận ở lab.
  - Huỷ hay form hết hạn để lại video `UPLOADING` chiếm một lượt tải trong 15 phút.
  - CORS MinIO toàn cục; mở web bằng `127.0.0.1:3001` thì không phát, không tải lên được.
  - Lighthouse chưa chặn PR, một lượt mỗi trang.
- Xem lại khi:
  - Có người dùng thật: danh sách handle cấm, đổi handle có chuyển hướng, xác minh tài khoản (cùng JWT-6).
  - p99 của feed vượt 150 ms vì ghép tác giả, hay user-service thành nút cổ chai của đường đọc: bản sao hồ sơ ở feed-service (phương án B mục 5) hay cache hồ sơ.
  - Cần resume upload (clip dài hơn, mạng di động): multipart (phương án C mục 8).
  - Giai đoạn 6: Lighthouse vào CI cùng e2e. Giai đoạn 7: CDN trước route công khai, CORS theo bucket.

## Xác nhận

Đo ngày 2026-10-22: e2e 68/68 pass trên Chromium và WebKit (`make measure-web`), `make smoke` 58 bước pass, `make check` xanh, size-limit trong ngân sách (`/v/[id]` 174,25 / 305,52 kB, `/upload` 64,25 / 195,52 kB), Lighthouse LCP chưa đạt (§10). Bảng số đo đủ, điều kiện đo và các việc chưa kiểm: phụ lục, mục "Kết quả phần B".

## Hiện thực ở

Từ 2026-10-31 mã web ở repo `svp-frontend` ([ADR-0033](0033-svp-web-repo.md)): mỗi đường `web/<x>` dưới đây là `<x>` của repo đó; target `web-check` là `make check` của `svp-frontend`, `web-lighthouse` còn ở `Makefile` repo này, gọi `make lighthouse` của bản clone.

- Handle và tên hiển thị (§1, §2): `services/user-service/migrations/00005_add_user_profile.sql`, `services/user-service/internal/server/`; phía web `web/features/profile/` (`display-name.ts`, `api.ts`), `web/server/profile-actions.ts`.
- Danh sách video theo tác giả (§4): `services/video-service/internal/server/server.go`, `services/video-service/migrations/00005_index_author_videos.sql`, `internal/pagetoken/`.
- Tác giả trong response (§5): `services/gateway/internal/api/api.go`, `services/gateway/cmd/gateway/main.go` (retry của `GetProfiles`, đổi tên hiển thị).
- Route công khai (§6): `services/gateway/internal/api/api.go` (`getPublicVideo`), lớp `public` của `services/gateway/internal/ratelimit/ratelimit.go`, `services/gateway/openapi.yaml`, `GetStats` không cần caller ở `services/engagement-service/internal/server/server.go`; trang `web/app/v/[id]/page.tsx`, `web/server/video-page.ts`, `web/features/feed/share-screen.tsx`.
- Route web (§7): `web/app/(main)/u/[handle]/page.tsx`, `web/server/profile-page.ts`, `web/server/auth-state.ts`, `web/server/api-proxy.ts`, `web/features/feed/api.ts`.
- Upload từ trình duyệt và CORS (§8, §9): `web/features/upload/`, `UPLOAD_ORIGIN` ở `deploy/compose/compose.yaml`; CORS theo bucket ở `deploy/s3/init.sh` (bị thay một phần bởi [0022](0022-local-object-store-minio-replacement.md)).
- Lighthouse và ngân sách bundle (§10, §11): `web/lighthouse/run.sh`, target `web-lighthouse`, `web-check` của `Makefile`.
- Kiểm: `deploy/compose/smoke.sh`, `web/e2e/` (`profile.e2e.ts`, `share.e2e.ts`, `upload.e2e.ts`, `measure-upload.e2e.ts`, `security.e2e.ts`, `fixtures.ts`), `web/server/auth.test.ts`, `web/features/profile/display-name.test.ts`.

## Nguồn

- XMLHttpRequest Standard (preflight khi có listener upload): <https://xhr.spec.whatwg.org/>; RFC 8216 §4 (kiểu MIME playlist HLS): <https://www.rfc-editor.org/rfc/rfc8216>; Open Graph: <https://ogp.me/>.
- RFC 9111 §3.5 (cache chung và `Authorization`): <https://www.rfc-editor.org/rfc/rfc9111#section-3.5>. Bảng kiểm chứng đủ (UUIDv7 trong Go, CORS của MinIO, 404 bị cache): phụ lục, mục "Kiểm chứng".

## Thông tin thêm

Phụ lục: [`appendix/0018-web-profiles-public-video-upload.md`](appendix/0018-web-profiles-public-video-upload.md) (trạng thái gốc, bối cảnh đầy đủ, kiểm chứng, phân tích phương án, chi tiết §1–§10, bảng tổng hợp contract §12, kết quả phần B, mục "Chi tiết rút khỏi ADR").

### Chỉnh bởi

- §9: [0022](0022-local-object-store-minio-replacement.md): CORS toàn cục của MinIO bị thay một phần, CORS theo bucket trên RustFS, cùng origin web.
