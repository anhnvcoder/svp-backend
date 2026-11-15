# 0073. Video premium: vé giả lập ở video-service, object dưới tiền tố `premium/` riêng, playlist do API kiểm vé và viết lại, segment qua signed URL CloudFront (key group hai khoá), bản xem thử công khai dưới `preview/`; local, k3d ký bằng presign S3

- Trạng thái: Chấp nhận
- Ngày: 2026-11-15
- Người quyết: người học (2026-11-14: làm hết theo chuẩn ngành, AI tự quyết thiết kế), AI đề xuất

## Bối cảnh và vấn đề

- Mọi video đọc công khai: ai có link đều xem (threat model UP-6, "chấp nhận" vì chưa có video riêng tư); local, bucket `media` mở `s3:GetObject`
  ẩn danh trên `media/media/*` ([0008](0008-async-upload-pipeline-stage2a.md) §6), RustFS áp policy ẩn danh cho cả request có ký (BAK-1); stg,
  prd chỉ CloudFront qua OAC đọc bucket. [0052](0052-cloudfront-flat-rate-free.md) ghi "Xem lại khi: có video riêng tư, URL hay cookie ký".
- Bài video premium cần: chỉ người có vé xem đủ, mỗi vé một video, một mức chất lượng tối đa; người khác xem bản xem thử; không thanh toán thật.
- Bố cục HLS ([0029](0029-immutable-media-versions.md), [0066](0066-mediaconvert-transcode.md) §5): `media/<id>/<V>/master.m3u8` với URI
  biến thể tương đối `<A>/index_<rendition>.m3u8`, mọi object của lần thử phẳng trong `media/<id>/<V>/<A>/`, `Cache-Control` bất biến 1 năm.
  Trình phát giải URI tương đối theo URI của playlist chứa nó [N12], và phép giải đó lấy query của tham chiếu, không của gốc [N13]: chữ ký trên
  URL của master không theo xuống playlist con, segment.
- Media stg ở gói CloudFront flat-rate Free (`Managed-SimpleCORS`, tối đa 5 behavior), prd pay-as-you-go
  ([0061](0061-edge-cloudfront-waf-acm.md) §1, §6); video dài tối đa 180 s (0066).
- Ràng buộc: một database mỗi service; không dependency mới (Go, npm, provider Terraform, image); repo public; AI không chạy lệnh chạm account.

## Yếu tố quyết định

- Không ai thiếu vé đọc được object premium qua bucket, CDN hay API, kể cả khi đã có chữ ký của video, rendition khác (PRM-2, PRM-3, PRM-4).
- Cơ chế managed, chuẩn ngành của CDN đang dùng; chạy trên cả gói Free (stg) và pay-as-you-go (prd); không phí cố định thêm.
- Cache hit của video premium ngang video công khai: chữ ký không vào cache key.
- Phát được ở mọi trình phát HLS (hls.js và HLS gốc của Safari, iOS) không cần hook phía client.
- Local, k3d có đường tương đương chạy được không CloudFront; khoá riêng không vào git, state, log; xoay khoá không làm hỏng URL còn hạn.

## Phương án đã cân nhắc

Trạng thái ngành, được, mất, nguồn: [phụ lục](appendix/0073-premium-playback.md#phương-án). In đậm là lựa chọn.

- Nơi giữ vé: **video-service**; user-service (mỗi playlist một lời gọi chéo service); service entitlement riêng (thêm service, database).
- Phân quyền edge: **playlist do API viết lại, segment signed URL** (manifest manipulation); signed cookie (phủ cả tên `media`, cần CORS có
  credential mà `*` của gói Free không cho); Lambda@Edge viết lại manifest (kiểm vé vẫn phải gọi API, tính tiền ngoài gói); CloudFront Functions
  (không làm được: runtime không có network nên không đọc được vé [N18]); token trong path (CloudFront không kiểm, cần hàm edge tự viết); query
  qua hook `xhrSetup` của hls.js (HLS gốc không có hook).
- Tách nội dung: **tiền tố `premium/`, `preview/`**; cùng `media/` phân biệt bằng tag object (behavior CloudFront chỉ chọn theo path).
- Bản xem thử: **chép segment đầu của lần thử**; job transcode riêng (gấp đôi phút transcode, một đường lỗi nữa).
- Đường local: **presign S3**; giả CloudFront bằng Envoy hay gateway (bộ kiểm tự viết chỉ chứng minh nó khớp bộ ký tự viết).
- Khoá riêng: **sinh bằng `openssl` trên máy, giữ ở Secrets Manager**; `tls_private_key` (khoá nằm không mã hoá trong state [N16], thêm provider
  `tls`); KMS ký (mỗi chữ ký một lời gọi KMS, local khác đường hẳn, khoá chờ xoá tối thiểu 7 ngày [N15]).
- Bảo vệ bản sao: DRM (Widevine, FairPlay) chống chép nội dung đã tải, không thay việc kiểm quyền tải; máy chủ license, phí: ngoài phạm vi.

## Kết quả quyết định

Chọn các phương án in đậm: quyền xem kiểm ở một chỗ có đủ dữ liệu (video-service), CDN chỉ kiểm chữ ký bằng tính năng managed, chữ ký nằm trong
URL tuyệt đối nên trình phát nào cũng mang theo. Cái giá: mỗi lần đổi chất lượng một RPC tới video-service, hai đường ký (CloudFront, presign S3).
Thuật ngữ in đậm dưới đây có nghĩa đủ ở `docs/explanation/premium-playback.md`.

### 1. Video premium, gói, vé ở video-service

- Cờ `premium` chọn lúc `POST /videos` (vắng là `false`), lưu ở `videos.premium` của `svp_video`, không đổi sau đó: đổi phải chuyển object giữa
  tiền tố (§3), mất cache của bản cũ. Chỉ video premium có vé, bản xem thử, route phát premium.
- Gói `sd` < `hd` < `fhd` (proto `svp.video.v1.Tier`); rendition của gói: `sd` = `source`, `360p`; `hd` thêm `720p`; `fhd` mọi rendition.
- Vé: bảng `video_entitlements` (`user_id`, `video_id`, `tier`, `granted_at`, khoá `(user_id, video_id)`), migration chỉ thêm
  ([0068](0068-zero-downtime-migrations.md)); không hết hạn. Tác giả luôn có `fhd` không cần vé. Kiểm vé, cờ premium, `READY` và tác giả cùng một
  database nên mỗi playlist một truy vấn, không gọi chéo service; cái giá: video-service giữ thêm miền "mua".

### 2. Mua giả lập

RPC `GrantEntitlement(video_id, tier)`, REST `PUT /me/entitlements/{video_id}`: ghi đè `tier`, idempotent, không thanh toán. Video không có hay
chưa `READY` → `VIDEO_NOT_FOUND`; không premium → `VIDEO_NOT_PREMIUM`; caller là tác giả → `ALREADY_ENTITLED`; tier unspecified → `INVALID_TIER`.
Thanh toán thật (cổng thanh toán, webhook, hoàn tiền) là việc khác; khi có, nó gọi cùng đường ghi vé.

### 3. Tiền tố media và bản xem thử

- Object của video nằm dưới đúng một tiền tố của bucket media, cùng bố cục `<tiền tố><id>/<V>/…`: `media/` (video thường, công khai), `premium/`
  (mọi object của video premium, riêng), `preview/` (bản xem thử và thumbnail của video premium, công khai). Người nhận event kiểm key theo cờ.
- Bản xem thử: sau một lần thử thành công (ffmpeg và MediaConvert), media-worker chép min(3, ⌊n/2⌋) segment đầu của rendition thấp nhất (n là
  số segment của nó; segment 4 s nên tối đa 12 s, không quá nửa số segment) sang `preview/<id>/<V>/<A>/`, ghi playlist VOD của chúng, chép
  thumbnail, tạo master xem thử một lần, rồi master đầy đủ. Video premium một segment (tới 4 s) không có bản xem thử: lần thử thất bại vĩnh viễn,
  video `FAILED` với lý do `PREVIEW_TOO_SHORT`, nên video premium `READY` luôn có bản xem thử và bản đó không bao giờ là trọn video. Chép thay
  transcode lại: cùng byte, không thêm phút MediaConvert. Gateway không trả URL nào dưới `premium/`: `playlist_url` của video premium là master
  xem thử.

### 4. Playlist do API viết lại, segment từ CDN

- Route `GET /videos/{video_id}/playback/{file}` (Bearer, `no-store`; web gọi qua BFF cùng origin): `master.m3u8` → **Master đã lọc**: giữ biến
  thể thuộc gói của caller, URI đổi thành `<rendition>.m3u8` tương đối nên trình phát hỏi lại đúng route; `<rendition>.m3u8` → **Playlist đã ký**:
  mỗi URI segment thành URL tuyệt đối có chữ ký (§5, §6). Không vé → 403 `NOT_ENTITLED`; rendition ngoài gói → 403 `RENDITION_NOT_ENTITLED`.
- Playlist gốc bất biến nên video-service giữ cache trong bộ nhớ theo key; chữ ký thì không. Playlist khác dạng media-worker ghi (URI lạ,
  `#EXT-X-MAP`, `#EXT-X-KEY`) → `INTERNAL`, không ký mù.
- Đây là "manifest manipulation", cách các nền tảng video phát nội dung có quyền: quyền kiểm theo người ở API, CDN chỉ kiểm chữ ký từng segment.
  Signed URL chỉ trên master không đủ: URI tương đối mất query [N12], [N13].

### 5. Phạm vi và hạn chữ ký

- **Gói phạm vi chữ ký**: mỗi rendition một custom policy, `Resource` = `<base>/premium/<id>/<V>/<A>/index_<rendition>_*`; dấu `_` giữ `360p` khác
  `3600p`. Bố cục phẳng (0066 §5) nên phạm vi là tiền tố tên, cùng mức bảo vệ với thư mục mỗi rendition. Dấu `*` cuối phủ cả query: CloudFront coi
  `…hello*` như `…hello*\?*` [N3]; `Resource` so với URL đã bỏ `Policy`, `Signature`, `Key-Pair-Id`, `Hash-Algorithm` [N3].
- **Hạn chữ ký**: `exp` = bội nhỏ nhất của 900 s ≥ `now + duration + 5 phút`, tức hạn trong [duration + 5, duration + 20) phút. Với `cloudfront`,
  mọi lần hỏi cùng rendition trong một khung 15 phút nhận cùng URL: trình duyệt dùng lại cache HTTP, chữ ký không lộ thời điểm hỏi; presign `s3`
  (local) ký cả thời điểm hỏi (`X-Amz-Date`), nên mỗi lần hỏi một URL, chỉ hạn rơi vào cùng khung. CloudFront kiểm hạn lúc request bắt đầu [N2];
  tạm dừng quá hạn thì segment 403 và web hỏi lại playlist. Vé không hết hạn; "vé hết hạn" của bài là chữ ký quá hạn.

### 6. Bộ ký theo nền tảng

- Package `internal/mediasign`, một interface, chọn bằng `MEDIA_SIGNER` (bắt buộc, sai thì dừng lúc khởi động); khác biệt nền tảng là dữ liệu.
- `cloudfront` (EKS): policy JSON không khoảng trắng, RSA PKCS#1 v1.5 trên SHA-256, query `Policy`, `Signature`, `Key-Pair-Id`,
  `Hash-Algorithm=SHA256`, base64 thay `+`→`-`, `=`→`_`, `/`→`~` [N3]; SHA-256 thay SHA-1 mặc định, không thêm phí [N6]. Thư viện chuẩn Go,
  không SDK. RSA vì chữ ký PKCS#1 v1.5 tất định theo chuẩn, ở mọi bộ ký: cùng policy cho cùng URL (§5); ECDSA P-256 cho chữ ký ngắn hơn nhưng chỉ
  tất định khi bộ ký theo RFC 6979 (Go: `Sign` với `rand` là `nil`), bộ ký ngẫu nhiên cho mỗi lần hỏi một URL [N19].
- `s3` (compose, k3d): presign SigV4 `GET` từng segment, `ttl = exp − now`, host là endpoint công khai: chuẩn cho object riêng không CDN [N11]. Không
  giả CloudFront: định dạng chữ ký CloudFront kiểm bằng test Go (xác minh bằng khoá công khai) và ở buổi cloud.

### 7. Behavior premium, cache key, quyền object store

- Behavior mặc định của distribution media cần chữ ký (`trusted_key_groups`, signer gắn theo behavior [N4]); `media/*`, `preview/*` là hai
  `ordered_cache_behavior` công khai; ba behavior cùng GET, HEAD, `https-only`, `compress`, response headers policy theo `flat_rate_free`.
  Chặn mặc định vì CloudFront chọn behavior trên path đã chuẩn hoá theo RFC 3986 (`%70` thành `p`, `%2F` giữ nguyên) rồi gửi path thô [N20],
  S3 có thể giải `%2F`: `premium%2F…` tới key `premium/`. `media/..%2F…` khớp `media/*`, an toàn khi S3 không giải `..` [N21]; ca âm ở §9.
- Cache policy `Managed-CachingOptimized`: không query, cookie, header nào vào cache key [N8], nên mọi chữ ký của một segment trúng cùng mục cache.
  CloudFront kiểm chữ ký, policy trước, rồi mới tìm trong cache [N2] (PRM-8). Gói Free có signed URL [N7]; ba behavior dưới hạn 5.
- **Quyền object store**: ẩn danh (local) chỉ đọc tiền tố `media/`, `preview/` của bucket, không `premium/`, không `ListBucket`; OAC đọc cả
  ba tiền tố; video-service, media-worker mở quyền hiện có sang `premium/*`, `preview/*`, video-service thêm `GetObject` trên `premium/*`; role
  MediaConvert ghi `media/*`, `premium/*`. RustFS áp policy ẩn danh cho request có ký, nên chỉ việc không mở `premium/*` giữ nó riêng ở local.

### 8. Khoá ký, Secrets Manager, xoay

- **Khoá ký media**: module `media` nhận `signing_public_keys` (hai ô `a`, `b`, 1–2 khoá), tạo `aws_cloudfront_public_key` mỗi ô (tên kèm 8 hex của
  sha256 PEM, `create_before_destroy`) và một key group; key group nhận tới 5 khoá [N5]. Khoá RSA 2048, PEM: CloudFront nhận RSA 2048 hay
  ECDSA 256 [N4].
- **Script khoá ký** `aws/scripts/media-signing-key.sh` của `svp-infra`: `new <ô>` sinh khoá bằng `openssl` vào thư mục 700 ngoài repo, chỉ ghi khoá
  công khai vào `media-signing.auto.tfvars.json` (không track); `activate <ô>` ghi ID và khoá riêng vào **Entry khoá ký** `svp/<env>/media-signing`
  từ file, không giá trị nào trên dòng lệnh, stdout, rồi xoá file khoá riêng. External Secrets đưa vào Secret `video-service-env` khi chart
  `svp-cluster` bật `externalSecrets.mediaSigning`; Reloader khởi động lại video-service khi Secret đổi.
- **Xoay khoá ký** theo bước AWS [N4]: `new` ô kia, apply (key group hai khoá), `activate` ô kia, `aws/scripts/bootstrap.sh <env> secrets`
  (ExternalSecret `refreshPolicy: OnChange`: Secret chỉ đổi khi ép đồng bộ); URL ký bằng ô cũ dùng được tới hạn, ô cũ ở lại tới lần xoay sau.
  Lộ khoá: cùng bốn bước trên ô lộ, URL đã ký bằng nó hỏng: chấp nhận. Root env, entry bị destroy cuối buổi nên mỗi buổi khoá mới: `session.sh`
  chỉ in bước, người học chạy `new a` (bỏ ô `b` khỏi tfvars) trước `plan`, `activate a` sau `apply`; khoá riêng buổi trước hết dùng được.

### 9. Đo và kiểm

- **Phép kiểm local**: `deploy/compose/smoke.sh` (compose, `make k8s-smoke`, `make eks-smoke`) thêm luồng premium: xem thử công khai 200,
  `premium/` ẩn danh 403, không vé 403, vé `sd` chỉ thấy rendition của `sd` và phát được, rendition cao hơn 403, chữ ký V1 trên segment V2 403.
- **Kiểm edge premium**: `deploy/k8s/premium-edge-check.sh` (`make eks-premium-check`, người học chạy; self-test với `curl` giả trong CI) chỉ
  gọi API và CDN qua HTTPS: ca âm trên CDN (cả path mã hoá của §7, `curl --path-as-is`), `--wait-expiry` chờ qua `DateLessThan` rồi GET → 403.
- **Đo cache hit**: 3 lượt GET mọi segment 360p của V0 công khai ("trước") và V1 đã ký ("sau"), query `svp_probe` khác mỗi lượt, đếm `x-cache`
  của lượt 2–3. Kỳ vọng V1 ≈ V0. Không dựng cấu hình "query vào cache key" chỉ để đo: tỉ lệ đó suy ra được (mỗi URL một mục cache).

### 10. Chi phí

CloudFront public key, key group, signed URL, SHA-256 không có dòng giá [N6], [N9]; request đã ký tính như request khác (prd) hay nằm trong gói
(stg). Entry Secrets Manager $0,40 mỗi secret mỗi tháng tính theo giờ, $0,05 mỗi 10 000 lời gọi [N10]: một buổi 4 giờ ~$0,002 mỗi env, $0 lúc
không buổi (root env bị destroy). Theo ngưỡng của [0071](0071-paid-features.md) §7 (a) không đạt: không cờ. Bảng:
[phụ lục](appendix/0073-premium-playback.md#chi-phí).

### 11. ADR cũ

Dòng `### Chỉnh bởi` ở 0008 §4, §6, §9, [0009](0009-engagement-feed-stage2b.md) §6, §7, §9, 0018 §4, §6, 0029 §1, §2, §4,
[0048](0048-prd-aws.md) §5, 0052 §4 và Xem lại khi, 0061 §2, §8, 0066 §5, §8, §9. Threat model: UP-6 giữ cho video thường, video premium theo
`PRM-1`…`PRM-8` (mục 4.14).

### Hệ quả

- Tốt: video premium chỉ phát cho người có vé, theo gói; CDN kiểm chữ ký bằng tính năng managed, cache hit giữ như video công khai; mọi trình
  phát HLS phát được; đường local chạy được, cùng quyết định quyền; khoá riêng không vào git, state; xoay không gián đoạn; bản xem thử tối đa
  12 s, không quá nửa số segment (PRM-7).
- Xấu: mỗi lần đổi chất lượng một RPC tới video-service; URL đã ký chia sẻ được tới hạn (PRM-1, chấp nhận: hạn ≤ độ dài + 20 phút); bản xem
  thử đếm theo segment mà segment cuối có thể ngắn hơn 4 s, nên có thể quá nửa thời lượng (video 5 s cho xem 4 s đầu, video 13 s cho xem 8 s);
  video premium tới 4 s không phát hành được (`PREVIEW_TOO_SHORT`); log v2 của CloudFront (`cs-uri-query`, prd) và log WAF giữ query đã ký:
  chỉ ở Log Archive, hết hạn sau ≤ 20 phút cộng độ dài video; định dạng chữ ký CloudFront chỉ kiểm thật ở buổi cloud; cờ premium không đổi được
  sau upload; DRM ngoài phạm vi: người có vé chép được nội dung đã tải.
- Xem lại khi: cần thuê theo thời hạn (vé có hạn), thanh toán thật hay nội dung bản quyền đòi DRM; video dài vượt 180 s (hạn chữ ký dài theo); cần
  chặn chia sẻ URL theo IP (`AWS:SourceIp`); RPC playlist thành nút cổ chai của p99.

## Xác nhận

- Lúc quyết chưa hiện thực. Kiểm tĩnh và test: `make check` (test `internal/mediasign` xác minh chữ ký bằng khoá công khai, clock giả cho hạn;
  `internal/hls`; ca âm của video-service, gateway), `buf breaking`, `make api-contract-check`, `make helm-check`, `make docs-check`; `make check` của
  `svp-infra` (test mocked module `media`, `transcode`, `external-secrets`, `session-test`).
- `make smoke` một lần trên compose (**Phép kiểm local**).
- Buổi stg, prd (người học): `make eks-smoke`, **Kiểm edge premium** cả `--wait-expiry`, **Đo cache hit**, một lượt **Xoay khoá ký**, `sweep.sh`
  sạch; kết quả có ngày ở phụ lục.

## Hiện thực ở

- Repo này: `proto/svp/{video,media,feed}/v1/`, `gen/go/` (§1, §2, §4); `internal/objstore/` (§3, §6), `internal/mediasign/` (§5, §6),
  `internal/hls/` (§4); `services/video-service/` (§1, §2, §4–§6), `services/media-worker/` (§3), `services/feed-service/` (§3),
  `services/gateway/` (§2–§4); `deploy/s3/`, `deploy/compose/compose.yaml`, `deploy/compose/smoke.sh` (§6, §7, §9); `deploy/helm/svp-cluster/`,
  `deploy/k8s/aws-secrets.sh`, `deploy/k8s/premium-edge-check.sh`, `deploy/k8s/k8s.mk`, `.github/workflows/ci.yml` (§8, §9);
  `docs/explanation/premium-playback.md`, `docs/threat-model.md` (4.14), `docs/reference/contracts.md`, `docs/reference/environment.md`.
- `svp-infra`: `aws/modules/media/` (§7, §8), `aws/modules/transcode/` (§7), `aws/modules/external-secrets/`, `aws/envs/<env>/` (§8),
  `aws/scripts/` (`media-signing-key.sh`, `session.sh`, `sweep.sh`; §8), `docs/runbooks/media-signing-keys.md`, `session-stg.md`, `session-prd.md`
  (§8, §9), `docs/diagrams/` (§4, §7).
- `svp-gitops`: `base/services/video-service.yaml`, `platforms/eks/video-service.values.tpl`, `platforms/eks/svp-cluster.yaml` (§6, §8).
- `svp-frontend`: `features/`, `components/`, `app/`, `server/` (nhãn premium, xem thử, mua giả lập, phát qua BFF; §2, §4).

## Nguồn

Đọc 2026-11-15; đủ [N1]–[N21] kèm câu trích ở [phụ lục](appendix/0073-premium-playback.md#nguồn).
[N3] <https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/private-content-creating-signed-url-custom-policy.html>,
[N4] <https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/private-content-trusted-signers.html>,
[N6] <https://aws.amazon.com/about-aws/whats-new/2026/04/amazon-cloudfront-sha-256-signed-urls/>,
[N7] <https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/flat-rate-pricing-plan.html>.

## Thông tin thêm

Phụ lục: [`appendix/0073-premium-playback.md`](appendix/0073-premium-playback.md) (phương án, sự thật AWS kèm câu trích, chi phí, kết quả buổi, nguồn).
