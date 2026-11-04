# 0016. Web client Next.js 16 với BFF và session phía server, refresh token xoay vòng có phát hiện dùng lại

- Trạng thái: Chấp nhận
- Ngày: 2026-10-21

## Bối cảnh và vấn đề

- Tới giai đoạn 5, client duy nhất là `curl`, k6 và trang thử HLS; web client nằm ngoài phạm vi ([architecture §1](../architecture.md#1-mục-tiêu-và-phạm-vi): "thêm sau thì viết ADR"). Giai đoạn 5b thêm một web client mức production cho luồng F1–F7: đăng ký, đăng nhập, feed dọc phát HLS, like, lượt xem, follow, rồi upload và trang chia sẻ, chạy trên compose và k3d, đi qua pipeline của giai đoạn 5 ([ADR-0015](0015-cicd-devsecops-stage5.md)).
- Access token là JWT EdDSA hạn **1 giờ**, **không có refresh token** ([threat model JWT-3](../threat-model.md#41-jwt-và-đăng-nhập)); JWT-3 hẹn xem lại "khi có app client thật". Web là client đó: không thể bắt người dùng gõ lại mật khẩu mỗi giờ.
- Mọi route trừ register/login cần Bearer; rate limit `register`/`login` đếm theo IP, route khác theo `user_id` ([ADR-0010](0010-redis-ratelimit-cache-resilience-stage2c.md) §2); gateway bỏ `traceparent` của client ([ADR-0011](0011-observability-stage3.md)); `playlist_url`, `thumbnail_url` là URL tuyệt đối tới MinIO, khác origin với web. Số liệu từng điểm (cổng, dải pod, db Redis đã dùng): phụ lục.
- Ràng buộc: máy 16 GB, compose và k3d không chạy cùng lúc; repo public; mỗi dependency mới cần lý do (`CLAUDE.md`); chỉ action của GitHub và `sigstore/cosign-installer` được chạy trong CI (ADR-0015 §11).
- ADR này chốt những gì code của phần chuẩn bị backend và phần A cần làm theo mà không phải đoán: định dạng và vòng đời refresh token, contract gRPC và REST, session, cookie, CSRF, CSP, cổng, danh sách dependency. Phần B, C chỉ có quyết định khung (§11).

## Yếu tố quyết định

Token không bao giờ tới trình duyệt và thu hồi được; chặn CSRF và script lạ; contract chỉ thêm, client cũ (k6, smoke) không đổi; không thêm dependency ngoài danh sách; chạy trên máy 16 GB và repo public.

## Phương án đã cân nhắc

- §1 **A Next.js 16 App Router `output: 'standalone'`** (mặc định ngành, SSR cho OG, BFF trong app; mất: mọi trang render động, bề mặt RSC có CVE)
- §1 B React Router 8 framework mode (ít tài liệu, v8 mới ra 2026-06): loại
- §1 C SPA (Vite) + BFF Go (OG cần nhánh render thứ hai ở Go): loại
- §2 **A token mờ lưu hash, xoay mỗi lần dùng, dùng lại thì thu hồi cả họ**
- §2 B JWT dài hạn không lưu (không thu hồi được): loại
- §2 C token mờ không xoay (RFC 9700 §4.14.2): loại
- §2 D cửa sổ chồng (kẻ cắp dùng token cũ không bị phát hiện): loại
- §5 **A session ở Redis, cookie chỉ mang id**
- §5 B cookie JWE không trạng thái (không thu hồi, hai tab ghi đè nhau): loại
- §5 C Auth.js, Better Auth (trùng user-service hoặc chỉ còn vá bảo mật; phần cần là vài trăm dòng): loại

Phân tích được/mất từng phương án: [phụ lục](appendix/0016-web-client.md).

## 1. Framework và vị trí trong lộ trình

Chọn **A**: **Next.js 16 App Router, `output: 'standalone'`**, một package ở `web/` (một package pnpm, không workspace). Cái giá của A được xử lý như sau, không bỏ qua:

- Mọi trang render động (`dynamic` theo request vì nonce). Không ISR/PPR, nên **không cần** `cacheHandler` dùng chung.
- `images.unoptimized: true`: thumbnail đã do media-worker sinh; bỏ image optimizer và `sharp` khỏi bề mặt tấn công.
- Vá CVE: Renovate (manager npm, mục 10) cùng cảnh báo lỗ hổng mở PR ngay. pnpm kiểm tuổi phát hành cả lúc cài `--frozen-lockfile`, nên bản vá mới hơn 3 ngày cần ngoại lệ theo quy trình ở mục 10.

**Vị trí:** giai đoạn **5b**, giữa 5 và 6, vì web cần pipeline ký, quét, promote của giai đoạn 5; giai đoạn 6 (k6, chaos, SLO) đo cả web.

## 2. Refresh token (đóng JWT-3)

Mục này chỉnh [ADR-0006](0006-contract-ids-and-event-envelope.md) §5 ("MVP không có refresh token").

Chọn **A**, **không** cửa sổ chồng (D). Client duy nhất là BFF và BFF làm single-flight (mục 5). Cái giá là một response bị mất (timeout, mạng đứt sau khi user-service đã xoay) làm lần thử sau thành "dùng lại", và người dùng phải đăng nhập lại. Ca này hiếm và chỉ tốn một lần đăng nhập.

- **Định dạng:** 32 byte từ `crypto/rand`, base64url không padding (43 ký tự); database chỉ lưu `token_hash` = SHA-256 của 32 byte đã giải mã (không salt, không HMAC); token thô chỉ sống trong `secret.String`, không vào log, span, problem hay database (JWT-8).
- **Bảng `refresh_tokens`** ở `svp_user`: `id`, `family_id`, `user_id`, `token_hash`, `created_at`, `expires_at`, `family_expires_at`, `used_at`, `revoked_at` (kiểu, ràng buộc, index: phụ lục).
- **Hạn:** access token **1 giờ** (`authtoken.TTL`, giữ nguyên); mỗi refresh token **14 ngày trượt**; cả họ **trần 30 ngày** sau login (`expires_at` mới = `min(now + 14 ngày, family_expires_at)`). Ba hạn là hằng số trong code, không thêm biến môi trường.
- **Luồng:** login mở **họ mới**; refresh chạy trong **một transaction** `READ COMMITTED`, khoá theo họ bằng `pg_advisory_xact_lock`; token đã dùng mà bị trình lại thì thu hồi cả họ (log WARN `refresh token reused`) và trả lỗi chung; access token ký **trước khi commit**; logout thu hồi cả họ, idempotent. N request song song cùng một token: đúng một cái xoay được, đây là hành vi cố ý, lý do BFF phải single-flight. Từng bước: phụ lục.
- **Lỗi:** mọi ca thất bại của `Refresh` trả **một** lỗi: `UNAUTHENTICATED`, reason **`INVALID_REFRESH_TOKEN`**, message `invalid refresh token`; lỗi database → `INTERNAL`.

## 3. Contract gRPC

`proto/svp/user/v1/user_service.proto`, chỉ **thêm** field và RPC (số field cũ giữ nguyên, `buf breaking` sạch):

- `LoginResponse` thêm `refresh_token = 3` (string) và `refresh_expires_at = 4` (`google.protobuf.Timestamp`).
- `rpc Refresh(RefreshRequest) returns (RefreshResponse)`: `RefreshRequest{refresh_token = 1}`, `RefreshResponse{access_token = 1, expires_at = 2, refresh_token = 3, refresh_expires_at = 4}`.
- `rpc Logout(LogoutRequest) returns (LogoutResponse)`: `LogoutRequest{refresh_token = 1}`, `LogoutResponse{}`.
- Cả hai **không cần caller** (refresh token là thứ xác thực), nên vào `PublicMethods` của user-service. Comment proto ghi lỗi như các RPC hiện có; bỏ câu "There is no refresh token in the MVP".
- Gateway **không retry** `Refresh` (không idempotent: lần thử hai là dùng lại và thu hồi cả họ). `Logout` idempotent nên được thêm vào danh sách retry `UNAVAILABLE` như `Follow`, `Unfollow`.

## 4. Contract REST và rate limit `refresh`

Gateway làm theo; `services/gateway/openapi.yaml` ghi lại.

- `POST /auth/login` thêm `refresh_token`, `refresh_expires_at` (bắt buộc). `POST /auth/refresh`, body `{"refresh_token": "<token>"}` → 200 cùng schema với login; 401 `INVALID_REFRESH_TOKEN` cho mọi ca token không dùng được; thân không phải JSON hay có field lạ → 400. `POST /auth/logout`, cùng body → **204**, kể cả token lạ (idempotent); user-service lỗi → 5xx và BFF vẫn xoá phiên của mình.
- Cả hai **không cần Bearer**. Refresh token không bao giờ vào access log, span hay problem (JWT-8).
- **Rate limit:** class mới **`refresh`** (thêm vào bảng lớp của ADR-0010 §2) cho `/auth/refresh` và `/auth/logout`, khoá theo IP, kiểm **trước** khi đọc thân: Redis tốt 60/phút, burst 30; Redis lỗi đóng mềm 30/phút, burst 15. Vượt ngưỡng → 429 `RATE_LIMITED` có `Retry-After`; metric `svp.ratelimit.decisions` có `class="refresh"`. Bảng và lý do: phụ lục.

## 5. BFF: session, cookie, CSRF, proxy

Chọn **A**, tự viết. Mọi module đọc session, giữ token hay gọi gateway nằm ở `web/server/` và có `import 'server-only'`.

- **Biến môi trường** (chỉ đọc ở server, kiểm bằng `zod` lúc chạy): `GATEWAY_URL`, `REDIS_URL`, `APP_ORIGIN`, `MEDIA_ORIGIN`, `UPLOAD_ORIGIN` (bảng: phụ lục). Phần A **không có biến `NEXT_PUBLIC_*`**; `next.config` **không dùng khoá `env`**; `APP_ORIGIN` scheme `http` chỉ nhận host `localhost`.
- **Session** (Redis db 9 ở compose và máy, Valkey db 9 ở k3d): `sid` 32 byte `crypto.randomBytes`, khoá `svp:web:sess:<sha256(sid) hex>`; TTL = `refresh_expires_at` (`PEXPIREAT`): **idle timeout 14 ngày**, **hạn tuyệt đối 30 ngày**; mọi khoá `svp:web:` có TTL. Login tạo **sid mới** (chống fixation) và chỉ chuyển tới `next` cùng origin; logout là Route Handler `POST /logout`.
- **Cookie theo scheme của `APP_ORIGIN`:** `https` → `__Host-Http-svp_sid=<sid>; HttpOnly; Secure; Path=/; SameSite=Lax; Max-Age=2592000`; `http://localhost:<cổng>` (chỉ compose và `make web-dev`) → `svp_sid=<sid>; HttpOnly; Path=/; SameSite=Lax; Max-Age=2592000`, vì WebKit/Safari bỏ cookie `Secure` đặt từ `http://localhost` (WebKit bug 232088). `SameSite=Lax`, không `Strict`: mở link video từ app khác là điều hướng top-level; CSRF chặn ở lớp riêng.
- **CSRF** ở `proxy.ts`, cho mọi method trừ `GET` và `HEAD`: có `Sec-Fetch-Site` thì chỉ nhận `same-origin`; không có thì `Origin` phải bằng `APP_ORIGIN`; thiếu cả hai hay `Origin: null` → 403 `CSRF_REJECTED`. Không route nào đổi trạng thái bằng `GET`; không CORS ở web.
- **Proxy `/api/*`** (`web/app/api/[...path]/route.ts`): chỉ route trong danh sách cho phép khớp `openapi.yaml`, segment id là UUID chuẩn, URL gateway dựng từ `GATEWAY_URL` cố định (chống SSRF, WEB-7); chuyển `Content-Type`, `Accept`, `X-Forwarded-For` nguyên văn và `Authorization: Bearer` từ session, bỏ mọi header khác; thân tối đa 64 KiB; bỏ `Set-Cookie` của gateway, `Cache-Control: no-store`.
- **Refresh single-flight:** refresh khi `access_expires_at - 30 s < now`; trong process `Map<sha256(sid), Promise>`, giữa các replica `SET svp:web:lock:<sha256(sid)> <16 byte ngẫu nhiên> NX PX 5000`; gọi `/auth/refresh` với **timeout 4 s**; ghi session mới bằng compare-and-set (Lua, theo `ver`). 401 `INVALID_REFRESH_TOKEN` → xoá session; 429, 5xx, timeout → **giữ** session, **không tự thử lại**. Refresh không rõ kết quả: **fail-closed**, không cửa sổ chồng (cái giá đã nhận ở mục 2).

## 6. Header bảo mật và CSP

`proxy.ts` sinh nonce mỗi request (`crypto.randomBytes(16)`, base64), dựng CSP với nonce đó và đặt ở **cả request lẫn response**, vì Next lấy nonce từ header `Content-Security-Policy` **của request**. Root layout gọi `await connection()` để mọi trang render động; `matcher` chỉ bỏ file tĩnh, **không** bỏ `/api` hay request prefetch (proxy còn kiểm CSRF).

- Response mang CSP (`script-src 'self' 'nonce-<n>' 'strict-dynamic'`, không `'unsafe-inline'` ở bản build, `object-src 'none'`, `base-uri 'none'`, `frame-ancestors 'none'`), HSTS khi `APP_ORIGIN` là https, `Referrer-Policy: strict-origin-when-cross-origin`, `Permissions-Policy`, `Cross-Origin-Opener-Policy: same-origin`, `X-Content-Type-Options: nosniff`, `Cache-Control: private, no-store` cho HTML có session. Khối CSP đầy đủ: phụ lục.
- `next dev` thêm `'unsafe-eval'`; bản build không bao giờ có. Không thuộc tính `style` trong HTML do server render. Không `Cross-Origin-Embedder-Policy: require-corp` (chặn HLS và thumbnail khác origin). Trusted Types (report-only) để phần C.

## 7. Host và cổng

| Môi trường | Origin web | Cổng |
| --- | --- | --- |
| Compose, container `web` (profile `core`) | `http://localhost:3001` | publish `127.0.0.1:3001`, cổng trong container cũng 3001 |
| `make web-dev` trên máy | `http://localhost:3002` | `next dev` cổng 3002, trỏ gateway `127.0.0.1:8080` |
| k3d (phần C) | `https://svp.localhost:8443` | HTTPRoute `svp.localhost` qua Envoy; thêm SAN `svp.localhost` vào Certificate (wildcard `*.svp.localhost` không phủ tên gốc) |

Sửa so với dự kiến ban đầu (`127.0.0.1:3000`): Grafana của profile `obs` đã giữ `127.0.0.1:3000`. Origin là `localhost` (không `127.0.0.1`) vì trình duyệt coi `localhost` là ngữ cảnh an toàn. Lý do `web-dev` lấy 3002, API ở `api.svp.localhost`: phụ lục.

## 8. Feed, phát video, lượt xem, follow

- **Player:** `hls.js` bản light (`hls.js/dist/hls.light`), điều khiển React tự viết; kiểm `Hls.isSupported()` trước, chỉ khi không có MSE/MMS mới gán `video.src` native; không kiểm `canPlayType` HLS trước.
- **Feed dọc:** `scroll-snap-type: y mandatory`, mỗi item `100dvh`; **pool cố định 3 `<video>`** + 3 instance hls.js (trước, hiện tại, kế); bắt đầu `muted playsinline`; poster là `thumbnail_url`.
- **Lượt xem:** `POST /api/videos/{id}/views` sau **2 s phát thật**, tối đa một lần mỗi lần mount item; gateway đã chặn trùng 60 s (RL-3). **Like** lạc quan; `stats` vắng thì ẩn số đếm, không hiện 0.
- **Follow:** gateway không trả `followed_by_me`; feed "Đang theo dõi" coi mọi tác giả là đã follow, feed "Khám phá" hiện nút Theo dõi và đổi trạng thái sau khi bấm thành công; đọc trạng thái thật ở trang hồ sơ ([ADR-0018](0018-web-profiles-public-video-upload.md) §3).
- Phần A **ẩn** nút chia sẻ, mục Tải lên và Hồ sơ. Dữ liệu: `openapi-typescript` sinh `web/gen/api.d.ts` từ `services/gateway/openapi.yaml`, `openapi-fetch` ở cả server và client, TanStack Query cho feed vô hạn, like lạc quan, chờ `Retry-After` khi 429.

## 9. i18n, font, icon

- **i18n: `next-intl`**, tiếng Việt (mặc định) và tiếng Anh, **không tiền tố URL**; locale từ cookie `svp_locale`, rồi `Accept-Language`, rồi `vi`.
- **Font Be Vietnam Pro tự host bằng `next/font/local`** (woff2 commit kèm giấy phép OFL), không `next/font/google` (tải font lúc build, không ghim được).
- **Icon: `lucide-react`** (import từng icon), không thêm origin vào CSP. Thiết kế do người học làm bằng Claude Design (`web/design/`), token chép 1:1 vào `@theme` của Tailwind v4; component tính năng chỉ nhận props, không gọi API.

## 10. Dependency npm và công cụ

Mọi gói ghim version chính xác (`rangeStrategy: pin` của Renovate ở phần C; `pnpm add --save-exact`). Thêm gói ngoài danh sách cần hỏi trước. Phần A **chỉ cài gói của phần A**. Danh sách đầy đủ kèm lý do và version: phụ lục.

- **Phần A, runtime:** `next`, `react`, `react-dom`, `server-only`, `redis`, `zod`, `openapi-fetch`, `@tanstack/react-query`, `next-intl`, `hls.js`, `lucide-react`. **Dev, build, test:** `typescript` dòng **6.0** (không TS 7), `tailwindcss`, `eslint`, `prettier`, `openapi-typescript`, `vitest`, `@playwright/test`, `@axe-core/playwright`, `size-limit`. **Phần B:** `@lhci/cli` (upload là XHR tự viết, không thêm gói). **Phần C:** `@sentry/nextjs`, `@opentelemetry/*`, `web-vitals`, `sentry` (dev; [ADR-0019](0019-web-k3d-supply-chain-observability.md)).
- **Ngân sách bundle** (`web/.size-limit.json`, `make web-check` sau `next build`, gzip, kB là 1000 byte), hai lớp mỗi route:

  | Route | Lớp 1: JS của route trên runtime của Next | Lớp 2: tải lần đầu (runtime + lớp 1) |
  | --- | --- | --- |
  | Feed `/` (gồm hls.js light tải lười) | ≤ 200 kB | ≤ 330 kB |
  | Login `/login` | ≤ 80 kB | ≤ 210 kB (≤ 200 kB tới phần B; nới ở phần C, [ADR-0019](0019-web-k3d-supply-chain-observability.md) §12) |

- **Công cụ:** **Node 26** (`web/.nvmrc`, `engines`); **pnpm 12**, version ghim **một chỗ** là `packageManager` của `web/package.json`; máy dev, CI và Dockerfile cùng `npm install -g pnpm@<ver>` (Node 25 trở đi không kèm Corepack), CI **không** dùng `pnpm/action-setup`.
- **Chuỗi cung ứng** (`web/pnpm-workspace.yaml`): `minimumReleaseAge: 4320` (3 ngày, khớp Renovate), `strictDepBuilds: true`, `allowBuilds` chỉ gói thật cần script cài đặt, `trustPolicy: no-downgrade`, `blockExoticSubdeps: true`, `ignoredOptionalDependencies: [sharp]`; CI và Dockerfile cài bằng `--frozen-lockfile`. Ngoại lệ `trustPolicyExclude: [semver@6.3.1]` ghim đúng một version. Cây dev của `@lhci/cli` có lỗ hổng không vào image: xử lý theo thứ tự nâng gói cha, `overrides` khoá theo gói cha, rồi mới bỏ qua có hạn (`.trivyignore.yaml`).
- **CI** (`.github/workflows/ci.yml`): job `web` chạy `make web-install`, `make web-check`, `make web-generate-check` (Redis db 15 là service container); `ci-ok` cần đủ 7 job.

## 11. Phạm vi các phần và việc để sau

- **Phần chuẩn bị backend:** mục 2–4. **Phần A (compose):** mục 5–10, container `web` trong profile `core`; xong khi e2e xanh trên Chromium và WebKit, axe không lỗi serious/critical, console không vi phạm CSP, size-limit đạt, có số đo thời gian tới khung đầu và bộ nhớ container.
- **Phần B:** upload XHR, `/v/:id` công khai có OG, hồ sơ tối thiểu và "video của tôi", CORS MinIO đúng origin web, Lighthouse CI; chi tiết chốt ở [ADR-0018](0018-web-profiles-public-video-upload.md).
- **Phần C (k3d):** image distroless, ký, quét, Kyverno, promote; release Helm `web` (HTTPRoute `svp.localhost`, 2 replica, PDB, canary, NetworkPolicy); GlitchTip, OTel, RUM. **Gateway tin `traceparent` chỉ từ pod web**; chi tiết chốt ở [ADR-0019](0019-web-k3d-supply-chain-observability.md).
- **E2E trong CI:** giai đoạn 6, cùng "stack chạy trong CI" mà ADR-0015 §12 đã dời; 5b chạy e2e local, CI chạy lint, type, unit, size-limit và kiểm `web/gen/api.d.ts` không lệch. **MinIO community đã archive:** ngoài phạm vi 5b, quyết bằng ADR riêng ([0022](0022-local-object-store-minio-replacement.md)).

## Kết quả quyết định

Chọn các phương án in đậm ở "Phương án đã cân nhắc" và triển khai theo §1–§11: Next.js 16 BFF tự viết, session Redis không để token ra trình duyệt, refresh token xoay vòng không cửa sổ chồng, CSRF theo Fetch Metadata, CSP nonce, contract chỉ thêm.

### Hệ quả

- Tốt:
  - JWT-3 có thu hồi: logout và việc phát hiện dùng lại cắt được phiên; token bị lộ từ một nhánh bị phát hiện khi nhánh kia dùng.
  - Token không bao giờ ra trình duyệt; XSS không lấy được token (chỉ dùng được phiên trong lúc trang đang mở).
  - CSRF chặn bằng Fetch Metadata/Origin, không dựa vào SameSite; nonce + `strict-dynamic` chặn script lạ.
  - Contract chỉ thêm field và RPC, client cũ (k6, smoke) không phải đổi.
- Xấu:
  - Thêm dependency `redis` cho Node, db Redis 9, một bảng ở `svp_user`, và một transaction mỗi lần refresh.
  - Access token còn sống tới 1 giờ sau logout (JWT-3, phần chấp nhận); không có danh sách thu hồi theo `jti` của access token.
  - Response refresh bị mất làm người dùng phải đăng nhập lại (không cửa sổ chồng).
  - Ở compose mọi người dùng web chung bucket IP; cookie không `Secure` trên `http://localhost` và đi kèm mọi cổng của `localhost`.
  - Mọi trang render động; vá CVE của Next phải nhanh. Bảng `refresh_tokens` chưa có job dọn.
- Xem lại khi:
  - Log `refresh token reused` vượt 0,1% số lần refresh trong một ngày (single-flight hỏng hay mạng chập chờn): xét cửa sổ chồng ngắn.
  - Có client thứ hai không làm single-flight được (app di động): xét cửa sổ chồng hay ràng buộc token theo người gửi (DPoP).
  - Trước bài k6 của giai đoạn 6 hay khi `refresh_tokens` vượt 1 triệu dòng: làm job dọn.
  - Lên cloud (giai đoạn 7): IP client thật qua load balancer, Redis/Valkey có xác thực và TLS cho session.
  - WebKit sửa bug 232088: bỏ dạng cookie không tiền tố.

## Xác nhận

- Phần A đo ngày 2026-10-22: e2e 32/32 pass trên Chromium và WebKit, `make smoke` 45 bước pass (gồm refresh, dùng lại token → 401 `INVALID_REFRESH_TOKEN`, logout hai lần 204), `make check` xanh, size-limit trong ngân sách; phần B ở "Kết quả phần B" của [ADR-0018](0018-web-profiles-public-video-upload.md), phần C ở "Kết quả phần C" của [ADR-0019](0019-web-k3d-supply-chain-observability.md).
- Bảng số đo đủ (khung đầu, bộ nhớ, size-limit, liệt kê tài khoản WEB-12) và các việc chưa chạy: phụ lục, mục "Kết quả phần A".

## Hiện thực ở

Từ 2026-10-31 ([ADR-0033](0033-svp-web-repo.md)) mã web ở repo `svp-frontend`, gốc repo là thư mục `web/` cũ: mỗi đường `web/<x>` dưới đây là `<x>` của `svp-frontend`, `deploy/docker/web.Dockerfile` là `Dockerfile` ở gốc của nó. Target `web-install`, `web-dev`, `web-generate`, `web-check`, `web-lockfile-scan` thành `make install`, `dev`, `generate`, `check`, `lockfile-scan` của `Makefile` `svp-frontend`; `web-e2e` còn ở `Makefile` repo này, là wrapper gọi `make e2e` của bản clone (`web_dir` của `deploy/k8s/lib.sh`). Job `web` của `ci.yml` thành job `check` của `.github/workflows/ci.yml` của `svp-frontend`. §8: `gen/api.d.ts` sinh bằng `scripts/contract.sh` từ hợp đồng mà `api/contract.json` ghim. §10: `package.json`, `pnpm-workspace.yaml`, `renovate.json` của `svp-frontend`. Service `web` của `deploy/compose/compose.yaml` ở lại repo này (mặc định chạy bản phát hành stg); values `web` ở `base/services/web.yaml` của `svp-gitops`.

- Web client và BFF (§1, §5, §6, §8): `web/` (`proxy.ts`; `server/`: `session.ts`, `session-access.ts`, `auth.ts`, `csrf.ts`, `csp.ts`, `env.ts`, `gateway.ts`, `api-proxy.ts`; `features/feed/`; `app/logout/route.ts`).
- Refresh token (§2, §3): `services/user-service/internal/server/refresh.go`, `services/user-service/migrations/00004_create_refresh_tokens.sql`, `services/user-service/queries/refresh_tokens.sql`.
- Contract REST và lớp rate limit `refresh` (§4): `services/gateway/internal/api/api.go`, `services/gateway/internal/ratelimit/ratelimit.go`, `services/gateway/cmd/gateway/main.go` (Refresh không retry, Logout có), `services/gateway/openapi.yaml`.
- Host và cổng (§7): service `web` của `deploy/compose/compose.yaml`, `deploy/docker/web.Dockerfile`; trên k3d `deploy/k8s/values/services/web.yaml`.
- Dependency npm và công cụ (§10): `web/package.json`, `web/pnpm-workspace.yaml` (setting chuỗi cung ứng), target `web-*` của `Makefile`, job `web` của `.github/workflows/ci.yml`.
- Kiểm: `web/e2e/` (`fixtures.ts`, `stack.ts`, `security.e2e.ts`, `a11y.e2e.ts`, `first-frame.e2e.ts`), `web/playwright.config.ts`, `deploy/compose/smoke.sh` (refresh, dùng lại token cũ, logout).

## Nguồn

- RFC 9700 §4.14.2 (xoay refresh token): <https://www.rfc-editor.org/rfc/rfc9700.html>; RFC 6265 §8.5 (cookie không cách ly theo cổng): <https://www.rfc-editor.org/rfc/rfc6265#section-8.5>.
- Next.js CSP nonce: <https://nextjs.org/docs/app/guides/content-security-policy>; MDN `Set-Cookie`: <https://developer.mozilla.org/en-US/docs/Web/HTTP/Reference/Headers/Set-Cookie>.
- Danh sách nguồn kiểm chứng đầy đủ (bug WebKit, advisory CVE của Next, Corepack): phụ lục, mục "Kiểm chứng".

## Thông tin thêm

Phụ lục: [`appendix/0016-web-client.md`](appendix/0016-web-client.md) (trạng thái gốc, bối cảnh đầy đủ, kiểm chứng, phân tích phương án, chi tiết §2, §4–§11, kết quả phần A, mục "Chi tiết rút khỏi ADR").

### Chỉnh bởi

- §5: [0046](0046-web-session-lifetime.md): thời hạn session (idle, absolute, `Max-Age` của cookie).
- §6, §8, §11: [0018](0018-web-profiles-public-video-upload.md): chi tiết phần B (§6 origin upload, §8 trạng thái follow, §11 phạm vi).
- §6: [0019](0019-web-k3d-supply-chain-observability.md): Trusted Types dời.
- §7: [0019](0019-web-k3d-supply-chain-observability.md): chứng chỉ riêng cho `svp.localhost` thay SAN của chứng chỉ wildcard.
- §8: [0033](0033-svp-web-repo.md): `gen/api.d.ts` sinh từ hợp đồng đã phát hành, không từ file trong repo.
- §10: [0019](0019-web-k3d-supply-chain-observability.md): `@sentry/nextjs` chỉ ở server, thêm dev dependency `sentry` (CLI getsentry/cli), ngân sách tải lần đầu của login nới lên 210 kB.
- §10: [0033](0033-svp-web-repo.md): danh sách gói npm và Renovate của web ở `svp-frontend`.
- §11: [0019](0019-web-k3d-supply-chain-observability.md): cơ chế tin `traceparent`; phần cần cluster GitOps và RAM lớn hơn dời giai đoạn 7 (§12 của 0019).
- §11: [0022](0022-local-object-store-minio-replacement.md): CORS MinIO toàn cục, MinIO community thay bằng RustFS, CORS theo bucket.
- Vị trí `web/` và các target `web-*` từ 2026-10-31: [0033](0033-svp-web-repo.md).
