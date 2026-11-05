# 0019. Web chạy trên k3d và đi qua chuỗi cung ứng như sáu service, gateway tin trace context khi mọi đường vào đã bỏ của client, lỗi trình duyệt tới GlitchTip qua route cùng origin, OTel ở server Next và RUM web-vitals

- Trạng thái: Chấp nhận
- Ngày: 2026-10-22

## Bối cảnh và vấn đề

- [ADR-0016](0016-web-client.md) §11 chỉ chốt khung của phần web trên cluster: image distroless qua pipeline ký và quét, release Helm `web` (HTTPRoute `svp.localhost`, 2 replica, PDB, canary, NetworkPolicy), GlitchTip, OTel, RUM, và "gateway tin `traceparent` chỉ từ pod web". Web mới chỉ chạy ở compose; pipeline ([ADR-0015](0015-cicd-devsecops-stage5.md)) build sáu image Go.
- Hiện trạng code ảnh hưởng tới thiết kế (đọc 2026-10-22, bảng kiểm chứng ở phụ lục): wildcard `*.svp.localhost` không phủ tên gốc `svp.localhost`; chart `svp-service` ghi cứng tên HTTPRoute `api`, chỉ cho PDB khi `hpa.minReplicas` ≥ 2, ngưỡng canary cố định (p99 150 ms, 5xx 1%); gateway dùng propagator rỗng ([ADR-0011](0011-observability-stage3.md) §3) và pod Envoy, pod web cùng dải `10.42.0.0/16` nên không tách được nguồn theo dải như `TRUSTED_PROXY_CIDRS`; Next 16.4.2 sinh khoá Server Action ngẫu nhiên lúc build vào output công khai trên GHCR; ngân sách bundle gần hết (login 196,71/200 kB, upload 195,52/200 kB); Valkey của cluster không mật khẩu, không persistence, `noeviction`, 64 MB.
- Ràng buộc: máy 16 GB, tối đa một buổi k3d đường dev và một lượt compose `core`; cluster GitOps, canary dưới traffic, diễn tập đầy đủ và đo RAM chạy trên runner CI (§12). Repo và image công khai. Dependency npm chỉ trong danh sách ADR-0016 §10.

## Yếu tố quyết định

- Web đi cùng một chuỗi build, quét, ký, promote, admission như sáu service; Kyverno không đổi.
- Không đường vào gateway nào mang trace context do client ngoài đặt; image công khai không mang khoá đang dùng; không bí mật hay dữ liệu cá nhân trong span, event lỗi, số đo.
- Ngân sách bundle, 16 GB RAM, không thêm dependency ngoài danh sách; pod web theo FF-3, FF-4 như sáu service.

## Phương án đã cân nhắc

- §1 **web là image thứ bảy của cùng pipeline**
- §1 **build ID theo commit (CI) hay nội dung context (dev) làm `deploymentId`**
- §1 **khoá Server Action đặt lúc chạy từ Secret**
- §1 workflow riêng (hai đường ký giữ khớp)
- §1 build ID mặc định ngẫu nhiên (không làm được khoá tải lại, `release`)
- §1 khoá thật lúc build (nằm trong output công khai)
- §1 khoá cố định lúc build (nằm trong output công khai)
- §2 **release thứ bảy của chart `svp-service` + listener `https-apex` với chứng chỉ riêng**
- §2 chart riêng (lặp chart)
- §2 thêm SAN vào wildcard (trình duyệt gộp kết nối HTTP/2 sang `s3.svp.localhost`)
- §2 bỏ hostname của listener
- §3 **canary Argo Rollouts như gateway, ngưỡng riêng**
- §3 rolling update (không tự abort)
- §3 asset ở bucket/CDN giữ nhiều bản (CDN thuộc cloud)
- §5 **Valkey chung db 9**
- §5 ACL theo tiền tố khoá (ba mật khẩu)
- §5 Valkey riêng cho session (thêm workload)
- §7 **Envoy bỏ trace context + cờ `TRUST_TRACE_CONTEXT` ở gateway + NetworkPolicy**
- §7 tin theo dải nguồn
- §7 header bí mật giữa web và gateway
- §7 mTLS
- §8 **reporter tự viết ở trình duyệt, báo cáo JSON nhỏ, server dựng event, `@sentry/nextjs` chỉ ở server**
- §8 SDK Sentry ở trình duyệt (vượt ngân sách)
- §8 chỉ báo lỗi server
- §8 tunnel Sentry chuẩn
- §9 **debug ID của Turbopack, map từ một stage của cùng bản build, tải bằng CLI `sentry`**
- §9 release + URL
- §9 tải trong CI
- §9 `glitchtip-cli`
- §11 **`web-vitals` → `sendBeacon` cùng origin → histogram OTel**
- §11 SDK OTel trình duyệt
- §11 nhãn `rating`

Phân tích được/mất từng phương án, bảng kiểm chứng và bảng "Tên chốt": [phụ lục](appendix/0019-web-k3d-supply-chain-observability.md).

## 1. Image `web` trong chuỗi cung ứng

Chọn **image thứ bảy**, build ID theo commit hay nội dung, khoá đặt lúc chạy.

- `svp_services` thêm `web` **ở cuối**; `dockerfile web` là `deploy/docker/web.Dockerfile`, context `web/`, không build arg `SERVICE`; `image_paths web` là `web` và Dockerfile đó. Repository `ghcr.io/anhnvcoder/short-video-platform/web`, tag và digest như sáu image; Kyverno nhận theo prefix nên policy không đổi. Luật "đổi đường build, quét, ký thì build lại tất cả" (ADR-0015 §3) giữ nguyên.
- **Quét:** trivy `--scanners vuln,secret` như sáu image; SBOM syft liệt kê cùng các gói. Trivy chỉ thấy 14 gói `node-pkg` vì Turbopack gộp dependency của server vào chunk, nên CVE của chúng chỉ có lockfile `web/pnpm-lock.yaml` đỡ (cổng quét lockfile ở §12); CVE của runtime Node chưa xác nhận được, lớp đỡ là Renovate nâng digest base image.
- **`SVP_BUILD_ID`** (build arg, khai ngay trước `RUN pnpm build`): CI là 12 hex đầu của commit (bằng tag image, hai kiến trúc cùng id); đường dev k3d là `dev-` + 12 hex đầu SHA-256 trên nội dung đúng các file context nhận theo `web/.dockerignore` cộng Dockerfile (hàm `web_build_id` của `deploy/k8s/lib.sh`, không theo git); compose và `make web-check` để rỗng. `next.config.ts` đặt `deploymentId` bằng biến này; stage runtime chép thành `ENV SVP_BUILD_ID` làm `release` của GlitchTip và `service.version` của OTel. Chấp nhận: build lại không cache cùng id mà khác bundle thì Next không thấy lệch khi điều hướng, chỉ đường tải lại của §3 đỡ.
- **Khoá Server Action:** server đọc `NEXT_SERVER_ACTIONS_ENCRYPTION_KEY` lúc chạy (k3d Secret `svp/web-env`, compose `.env`; `make env` sinh base64 của 32 byte), **không** đặt lúc build, nên khoá thật không vào image. Cái giá: id action đổi mỗi build và theo kiến trúc, action gửi tới pod của bản build khác (canary, tab cũ) bị 409 và client tải lại một lần (§3). Không đặt khoá cố định lúc build vì không bỏ được đường tải lại; xem lại khi số đo cho thấy tải lại vì action là đáng kể (đo 2026-10-28: 22,6 %, mở việc xét khoá cố định bằng ADR riêng, chưa làm).

## 2. Release Helm `web`

Chọn **release thứ bảy của chart `svp-service`** và **listener `https-apex`**.

- **Biên vào:** Gateway `svp` thêm listener `https-apex` (cổng 443, hostname `svp.localhost`, value `apexHost`), TLS `Terminate` với Secret `svp-apex-tls` của Certificate `svp-apex` (`dnsNames: [svp.localhost]`, ClusterIssuer `svp-ca`, ECDSA P-256); Certificate wildcard giữ nguyên; client vẫn chỉ tin `.k8s/ca.crt`. Chỉnh dự kiến "thêm SAN" của ADR-0016 §7.
- **HTTPRoute** đặt tên theo `httpRoute.name` (mặc định tên release; gateway giữ `api`), listener chọn bằng `httpRoute.sectionName` (mặc định `https`, web `https-apex`); mọi chỗ trong chart suy từ tên route.
- **Workload:** `protocol: http`, port **3001**, probe `/healthz`; **2 replica cố định, không HPA**; PDB `minAvailable: 1` (chart nới luật: `hpa.minReplicas` ≥ 2 hoặc không HPA/KEDA và `replicas` ≥ 2); `spreadAcrossNodes: true`. Bảo mật pod như sáu service (non-root 65532, root fs chỉ đọc, drop ALL, seccomp `RuntimeDefault`, không token ServiceAccount, PSA `restricted`), không thư mục ghi được.
- **Resources:** request 100m / 128Mi, limit 1 CPU / 384Mi (đo lại trên runner giữ nguyên, §12). **Tắt êm:** `lifecycle.preStop.sleep` 5 s (`preStopSleepSeconds`), `terminationGracePeriodSeconds` 30 s.
- **Cài đặt:** `components.json` thêm `web` wave 7 sau `gateway`; Argo CD bỏ qua trọng số của route `web` như `api`. **Cache header:** `/_next/static/*` `public, max-age=31536000, immutable`; HTML và route qua proxy `private, no-store`.

## 3. Canary của web và lệch phiên bản

Chọn **canary Argo Rollouts**.

- `canary: true`, cùng bước của gateway (25%, 60 s, 50%, 60 s, bước gate, 100%), cùng hai AnalysisTemplate, cluster Envoy `httproute/svp/web/rule/0/backend/1`, đòi ít nhất 30 response không phải 4xx mỗi phút. Ngưỡng theo release (`canaryLimits`): 5xx < 1% cả hai; p99 web **< 500 ms** (gateway 150 ms), sau đó 250 ms (2026-10-28, [ADR-0021](0021-deferred-verification-stage6b.md) §8).
- Traffic diễn tập (`deploy/k8s/drills/traffic.sh`) thêm `GET /login` ~3 lần/s (`web-login`) và một file `/_next/static/...` ~1 lần/s (`web-asset`) qua `https://svp.localhost:8443`.
- **Lệch phiên bản:** điều hướng RSC do Next lo; Server Action (409, `UnrecognizedActionError`) và chunk (404, gồm `hls.js`) do **`reloadOnceOnSkew(error)`** (`web/features/monitoring/skew-reload.ts`) lo, **tải lại đúng một lần** mỗi build (khoá `sessionStorage` `svp:skew-reload:<deploymentId>`), gọi từ ba error boundary, listener `unhandledrejection` và nhánh `catch` của `loadHls()` trong `player-pool.ts`. Lỗi tải chunk `web-vitals` bị nuốt có chủ ý. Cái giá: mất nội dung form đang gõ và vị trí trong feed. 409 của action là 4xx nên không làm abort canary.

## 4. NetworkPolicy của web (đóng WEB-13 ở k3d)

- **Vào:** chỉ Envoy (`ingressFrom: [envoy]`), cổng 3001. **Ra:** gateway 8080, Valkey 6379, Collector 4317, GlitchTip 8000 (`egressTo: [gateway, valkey, collector, glitchtip]`), DNS; không Postgres, Redpanda, MinIO, gRPC, Pyroscope, API server hay internet.
- Phía đích: gateway `ingressFrom: [envoy, web]`; Valkey, Collector (`services.otlp`), GlitchTip (`services.errors`) nhận thêm web. Bảng "Luồng được mở" của ADR-0014 §3 thêm bốn dòng (Envoy → web 3001; web → gateway 8080; web → Valkey 6379; web → Collector 4317, GlitchTip 8000).
- Compose: thêm `otelcol` và `glitchtip` vào mạng `web`, **không** đưa `web` vào mạng `default`.

## 5. Session ở Valkey db 9 của cluster

Chọn **Valkey chung db 9**, không mật khẩu, NetworkPolicy mở cho web; mở rộng phần chấp nhận của IN-7 ở lab local.

- Session là JSON có access token và refresh token (ADR-0016 §5); khoá `svp:web:sess:<sha256(sid)>`. Pod feed-service bị chiếm ghi được session nên có thêm đường mới (WEB-22), chấp nhận ở lab một máy một người. Valkey không persistence: khởi động lại thì mất phiên; `noeviction`: đầy 64 MB thì ghi lỗi.
- Xem lại khi lên cloud: Redis/Valkey có AUTH, ACL theo client và TLS, hay instance riêng cho session; hoặc sớm hơn nếu feed-service thêm đường ra mới.

## 6. CORS của MinIO ở k3d (WEB-10)

Bị thay một phần bởi [0022](0022-local-object-store-minio-replacement.md): store là RustFS, Job `s3-init` đặt CORS theo bucket (`S3_CORS_ALLOWED_ORIGINS=https://svp.localhost:8443`, `uploads` chỉ `POST`, `media` chỉ `GET`, `HEAD`). Giữ nguyên: một origin (không `*`, không origin của `web-dev`); web đặt `MEDIA_ORIGIN` và `UPLOAD_ORIGIN` là `https://s3.svp.localhost:8443` (route `s3`), khớp `MEDIA_PUBLIC_BASE_URL` của gateway và `S3_PUBLIC_ENDPOINT` của video-service.

## 7. Trace context từ web tới gateway (chỉnh ADR-0011 §3 và cơ chế của ADR-0016 §11)

Chọn **Envoy bỏ trace context của client trên mọi route, gateway có công tắc, NetworkPolicy chỉ cho Envoy và web vào**.

- **Gateway:** `TRUST_TRACE_CONTEXT`. `false` hay rỗng (mặc định): propagator rỗng, mỗi request trace gốc mới. `true`: đọc `traceparent`, `tracestate` theo W3C TraceContext (không `baggage`); context sai dạng thì trace gốc mới. Cờ sampled của request đến **không được quyết**: propagator bọc đặt cờ sampled của context đọc được thành 1. Giá trị khác `true`/`false`: gateway không khởi động, lỗi nêu tên biến.
- **Envoy (k3d):** mọi HTTPRoute của chart `svp-service` (`api`, `web`) có `RequestHeaderModifier` mức rule `remove: [traceparent, tracestate, baggage, sentry-trace]`. **NetworkPolicy:** chỉ Envoy và web vào cổng 8080 của gateway.
- **Web chỉ inject, không extract:** `extract` bỏ mọi header đến, `inject` ghi `traceparent` của span hiện tại; request đến web luôn mở trace gốc mới.
- **Bật ở đâu:** k3d `true`; compose `true` (tiến trình trên máy chọn được trace id, chấp nhận ở lab, WEB-24); cloud chỉ bật khi biên vào bỏ các header này như Envoy.

## 8. Lỗi web tới GlitchTip

Chọn **reporter tự viết ở trình duyệt, báo cáo JSON nhỏ, server dựng event; `@sentry/nextjs` chỉ ở server**.

- **Trình duyệt** (`web/instrumentation-client.ts`, logic ở `web/features/monitoring/`): `error` và `unhandledrejection` của `window`, ba error boundary và nhánh `catch` của `loadHls()` gọi cùng hàm báo (sau `reloadOnceOnSkew` không tải lại); `POST /monitoring` (`fetch` `keepalive`, thân JSON `text/plain`: `name`, `message`, `stack`, `path` chỉ pathname, `debug_ids`); tối đa 10 báo cáo mỗi lần tải trang, bỏ trùng; 404 thì ngừng gửi. Client không biết DSN; không SDK Sentry trong bundle.
- **`POST /monitoring`** (`web/app/monitoring/route.ts`): `SENTRY_DSN` rỗng → 404; thân > 32 KiB → 413; sai schema zod → 400; quá **20 báo cáo mỗi phút** của tiến trình → 429; hợp lệ → dựng event, trả **202** ngay. Event: `platform: javascript`, tag `service=web`, `runtime=browser`, `route`, `release` = `SVP_BUILD_ID`, `debug_meta.images`; gửi bằng `captureEvent` qua cùng `beforeSend`, ngân sách riêng, không tính vào 60 event/phút của lỗi server.
- **Server** (`web/instrumentation.ts`, runtime Node): `@sentry/nextjs` `init` với `SENTRY_DSN`, `environment`, `release`; không tracing, session, Replay; `enableOpenTelemetrySetup: false`; `dataCollection` và integration mặc định tắt (trừ `linkedErrors`); không `withSentryConfig`; lỗi request qua `onRequestError`.
- **Che theo WEB-9**, một bộ luật (`beforeSend`, `beforeBreadcrumb`): bỏ `request` trừ `url` không query, `user`, `server_name`, cookie, header, thân, `extra`; che email, JWT, chuỗi base64url 43 ký tự và mọi query của URL; `upload_url`, `form_fields` không vào lỗi; tag `trace_id`, `span_id`; mỗi fingerprint 1 event/30 s, lỗi server 60 event/phút, báo cáo trình duyệt 20/phút.
- **Compose:** `SENTRY_DSN: ${SENTRY_DSN:-}` tới `glitchtip:8000` qua mạng `web`. **k3d:** `errorTracking: true` (Secret `svp/sentry`), `SENTRY_ENVIRONMENT=k3d`.

## 9. Source map

Chọn **debug ID của Turbopack, map xuất từ một stage của cùng bản build, tải bằng CLI `sentry`**.

- `next.config.ts`: `turbopack.debugIds: true`, `productionBrowserSourceMaps: true` cho mọi bản build. `web.Dockerfile`: sau `pnpm build`, chuyển `*.map` sang thư mục riêng, bỏ `//# sourceMappingURL=`; stage `sourcemaps` (`FROM scratch`) chỉ chứa thư mục đó, xuất bằng `docker build --target sourcemaps --output type=local`; script kiểm ít nhất một debug ID của map có trong chunk đang phục vụ.
- **Tải lên:** `make web-sourcemaps` (compose) và `make k8s-web-sourcemaps` (cluster, port-forward `127.0.0.1:8000`), script `deploy/observability/glitchtip/sourcemaps.sh`: `pnpm --dir web exec sentry sourcemap upload`, **không** `--no-rewrite` (GlitchTip bỏ artifact không có header `debug-id`).
- **CLI `sentry` 0.45.0** (getsentry/cli) thành dev dependency trực tiếp, ghim chính xác (thêm vào ADR-0016 §10); Renovate gom với `@sentry/nextjs` thành nhóm `sentry`. **Token ghi:** APIToken nhãn `svp-sourcemaps`, scope `project:releases` (compose `.env` `SENTRY_SOURCEMAPS_TOKEN`, k3d Secret `svp-obs/glitchtip-sourcemaps`).
- **Image phát hành (CI):** map của image GHCR từ chính lượt build, mỗi kiến trúc một bộ; hiện thực theo [ADR-0021](0021-deferred-verification-stage6b.md) §6.

## 10. OTel ở server Next

- `web/instrumentation.ts` (`NEXT_RUNTIME === "nodejs"`): `NodeSDK` với exporter OTLP gRPC trace và metric tới `OTEL_EXPORTER_OTLP_ENDPOINT` (rỗng: không dựng exporter), periodic reader **15 s**, resource `service.name=web`, `service.version` = `SVP_BUILD_ID`; instrumentation `http` và `undici`; propagator W3C TraceContext chỉ inject; sampler `parentbased_always_on` bọc trong sampler lọc đường. Dựng OTel trước `Sentry.init`.
- **Không dữ liệu nhạy cảm vào span:** không ghi header; bỏ query khỏi mọi thuộc tính URL bằng span processor `onStart`; không id người dùng, sid, token, `upload_url`. **Không span** cho `/healthz`, `/_next/static/*`, `/favicon.ico`, `/monitoring`, `/rum` (sampler bọc ngoài).
- Metric HTTP giữ tên mặc định, không nhãn route; rule và dashboard hiện có lọc `service_name="gateway"`. Log của web chỉ ra stdout; compose: `x-telemetry-env` và mạng `web`.

## 11. RUM

Chọn **`web-vitals` → `sendBeacon` cùng origin → histogram OTel**.

- **Client** (`web/features/rum/`): `onLCP`, `onINP`, `onCLS`, `onFCP`, `onTTFB`; **một beacon** khi trang chuyển `hidden` (không `pagehide`, vì lúc đó CLS và INP chưa chốt): `navigator.sendBeacon("/rum", …)` (`text/plain`), không được thì `fetch` `keepalive`. CLS chỉ đến từ Chromium (WebKit không có `layout-shift`).
- **`POST /rum`** (`web/app/rum/route.ts`): thân > **4 KiB** → 413; sai schema zod (`metrics` 1–5 mục, mỗi tên một lần) → 400; quá **600 beacon mỗi phút** → 429; hợp lệ → **204**. `path` map sang template trong danh sách đóng (`/`, `/following`, `/login`, `/register`, `/me`, `/upload`, `/u/[handle]`, `/v/[id]`), không khớp thì bỏ cả beacon; giá trị âm hay vượt trần (> 60 000 ms; CLS > 10) thì bỏ mục. Không ghi id người dùng, sid, URL đầy đủ, User-Agent.
- **Metric** (histogram OTel, explicit bucket qua View): `svp.web.vital.lcp`, `.fcp`, `.ttfb`, `.inp` (đơn vị `s`) và `.cls`; nhãn duy nhất ngoài resource là `route`, **không nhãn `rating`** (biên bucket trùng ngưỡng web.dev). Dashboard `svp-web` (uid `svp-web`): LCP, INP, CLS p75 theo route.
- **SLO INP p75: chưa** (mẫu chỉ từ e2e, ai cũng bơm được số, WEB-21); dashboard là chỉ báo, không là căn cứ cảnh báo.

## 12. Kiểm và dời

- **Kiểm trên máy:** kiểm tĩnh (`make check`, `generate-check`, `web-generate-check`, `buf breaking`, `compose-config`, `helm-check`, `check-image-digests.sh`, `otelcol-validate`, `slo-check`, `actionlint`), compose `core` một lượt (`make up`, `smoke`, `web-e2e` Chromium và WebKit), một buổi k3d đường dev (`make k8s-up`, `k8s-smoke`, `k8s-web-sourcemaps`, e2e qua `https://svp.localhost:8443`, rồi `make k8s-down`); script diễn tập chỉ `bash -n`.
- **Ngân sách bundle:** nới có chủ đích lớp tải lần đầu của login và upload từ 200 lên **210 kB** (lớp route 80 kB và route khác giữ nguyên), vì debug ID và RUM là mục tiêu, `web-vitals` nạp lười sau `load`; vượt 210 kB thì dừng và quyết bằng thay đổi ADR. ADR-0016 §10 và [ADR-0018](0018-web-profiles-public-video-upload.md) §11 ghi giới hạn mới.
- **Dời sang runner CI** ([ADR-0021](0021-deferred-verification-stage6b.md)): cluster GitOps với image web đã ký và Kyverno Enforce từ chối web chưa ký; source map của image CI; canary web dưới traffic; `drill-k8s-threats` và `drill-obs-threats` đủ (gồm các ca WEB); đo RAM và chỉnh `resources`; cổng CI quét lockfile npm (`make web-lockfile-scan` trong job `web`). Kết quả từng việc: phụ lục.
- **Không làm:** Trusted Types report-only (ADR-0016 §6), trace từ trình duyệt (SDK OTel trình duyệt 0.x), log OTLP của web, SLO cho web.

## Kết quả quyết định

Chọn các phương án in đậm ở "Phương án đã cân nhắc" và triển khai theo §1–§12: web là image thứ bảy của pipeline chung, release `web` trên chart `svp-service`, trace context tin được vì Envoy bỏ header của client, lỗi và số đo trình duyệt tới GlitchTip, Prometheus qua hai route cùng origin có schema đóng.

### Hệ quả

- Tốt: web qua cùng chuỗi build, quét (gồm gói npm), ký, promote, admission; một trace đi từ server Next qua gateway xuống service mà client ngoài không chen context được ở k3d; lỗi trình duyệt và server tới GlitchTip với stack đã map, qua một bộ luật che; số đo LCP, INP, CLS, FCP, TTFB theo route, nhãn đóng; WEB-13 đóng ở k3d.
- Xấu: chart chung thêm value (`httpRoute.name`, `httpRoute.sectionName`, `canaryLimits`, `preStopSleepSeconds`, PDB không HPA), thêm listener và Certificate; khoá Server Action trong Secret và `.env`, id action và bundle đổi theo build và kiến trúc nên action hay chunk tới bản khác làm trang tải lại một lần; hai endpoint không xác thực (`/monitoring`, `/rum`) nhận dữ liệu giả trong giới hạn; session trong Valkey chung không mật khẩu (WEB-22); compose tin trace context (WEB-24); lớp tải lần đầu login, upload nới lên 210 kB (còn ~5,5 và ~6,5 kB).
- Xem lại khi: lên cloud (Redis/Valkey có AUTH, ACL, TLS hay instance riêng cho session; biên vào bỏ trace context trước khi bật `TRUST_TRACE_CONTEXT`; asset ra bucket/CDN giữ nhiều bản); GlitchTip nhận map theo cách khác debug ID (xét bỏ polyfill, đỡ ~1,5 kB); có tải k6 thật (SLO INP p75, HPA, ngưỡng p99 canary theo số đo); số lần tải lại vì action đáng kể hay cluster có node khác kiến trúc (xét khoá cố định không bí mật lúc build, §1).

## Xác nhận

- Phần web đo 2026-10-23 và 2026-10-24: kiểm tĩnh xanh; Go 43 gói ok, Vitest 68 file 1 153 test; compose `core` `make smoke` 58 bước; k3d `make k8s-up` 715 s, `make k8s-smoke` 58 bước, `SVP_E2E_GLITCHTIP=1 make k8s-web-e2e` 70/70 với frame đã map; `make drill-k8s-web-obs` PASS (trace, RUM, lỗi).
- Việc dời (cluster GitOps, canary web, diễn tập, RAM, lockfile) đã chạy trên runner 2026-10-25 và 2026-10-28; số đo, id lượt chạy và bảng kết quả: phụ lục, §12 và mục "Kết quả phần C".

## Hiện thực ở

Từ 2026-10-30 ([ADR-0033](0033-svp-web-repo.md)) image `web` build, ký, promote ở CI của `svp-frontend`; từ 2026-10-31 mã web ở `svp-frontend` (mỗi đường `web/<x>` dưới đây là `<x>` của repo đó). Values của release `web` ở `base/services/web.yaml` của `svp-gitops`. Chi tiết theo §: phụ lục, mục "Hiện thực ở".

- Image, release, canary (§1–§3): `deploy/docker/web.Dockerfile`, `.github/actions/image-leg/` với `deploy/ci/image-guard.sh` (`SVP_BUILD_ID`), `deploy/k8s/k8s.mk`, `deploy/k8s/install.sh`, `deploy/k8s/values/services/web.yaml`, `deploy/helm/svp-service/`, `web/features/monitoring/skew-reload.ts`.
- NetworkPolicy, session, CORS (§4–§6): `deploy/k8s/values/services/web.yaml`, `deploy/helm/svp-data/templates/valkey.yaml`, `deploy/helm/svp-data/templates/s3.yaml`, `deploy/s3/init.sh`.
- Trace context (§7): `services/gateway/internal/httpx/middleware.go` (`TRUST_TRACE_CONTEXT`), `deploy/helm/svp-service/templates/httproute.yaml`, `deploy/k8s/values/services/gateway.yaml`.
- Lỗi, source map, OTel, RUM (§8–§11): `web/server/sentry/`, `web/features/monitoring/`, `web/instrumentation.ts`, `web/server/telemetry/`, `web/features/rum/`, `deploy/observability/glitchtip/`, `deploy/observability/grafana/dashboards/svp-web.json`.
- Kiểm (§12): `web/e2e/glitchtip.e2e.ts`, `deploy/k8s/drills/` (`threats.sh`, `traffic.sh`, `web-obs.sh`), `deploy/compose/drills/obs-threats.sh`.

## Nguồn

- Mã của Next 16.4.2, tài liệu GlitchTip và Sentry đã đọc lúc thiết kế (đường dẫn, dòng và URL): phụ lục, mục "Kiểm chứng".

## Thông tin thêm

Phụ lục: [`appendix/0019-web-k3d-supply-chain-observability.md`](appendix/0019-web-k3d-supply-chain-observability.md) (trạng thái và ghi chú tiến độ gốc, bối cảnh đầy đủ, kiểm chứng, tên chốt, phân tích phương án, chi tiết §1–§12, kết quả, hiện thực ở).

### Chỉnh bởi

- §1: [0033](0033-svp-web-repo.md): image `web` build, ký, promote ở CI của `svp-frontend` (đường `ghcr.io/anhnvcoder/svp-frontend/web`, `SVP_BUILD_ID` theo commit của `svp-frontend`; Kyverno chọn attestor theo nguồn phát hành).
- §3: [0021](0021-deferred-verification-stage6b.md): ngưỡng p99 canary của web 250 ms theo số k6.
- §6: [0022](0022-local-object-store-minio-replacement.md): CORS theo bucket trên RustFS, cùng origin `https://svp.localhost:8443` (bị thay một phần).
- §9: [0021](0021-deferred-verification-stage6b.md): source map của image CI hiện thực ở runner, artifact `web-sourcemaps-<arch>` của `images.yml`.
- §9: [0033](0033-svp-web-repo.md): source map của image CI là image `web-sourcemaps` trên GHCR thay artifact của lượt chạy.
- §9: [0039](0039-mainpath-drills-scan-gate-sourcemaps.md): source map của image CI và bước tải lên GlitchTip của cluster GitOps bỏ; tải lúc build chờ tracker chạy lâu dài (bị thay một phần).
