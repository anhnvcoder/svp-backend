# 0061. Edge của web, API, media ở stg và prd: CloudFront có WAF trước mọi tên, web và API qua VPC origin tới ALB internal ở tầng subnet edge riêng, cert ACM thay Let's Encrypt, DNS edge do Terraform; gateway lấy IP client từ `CloudFront-Viewer-Address`; chỉ media của stg giữ gói Free; CAA hai zone, DNSSEC và query log zone prd

- Trạng thái: Chấp nhận
- Ngày: 2026-11-12
- Người quyết: người học (prd pay-as-you-go, stg giữ gói Free; chuỗi tin cậy DNSSEC đầy đủ), AI đề xuất thiết kế và giá trị theo tài liệu AWS

## Bối cảnh và vấn đề

- Web, API vào cluster qua NLB internet-facing do Load Balancer Controller tạo từ Service của Envoy, TLS Let's Encrypt DNS-01 ở Envoy, ExternalDNS
  ghi zone ([0034](0034-aws-stage7.md) §5, [0051](0051-dns-prd-apex.md) §2): không WAF, không L7 trước Envoy (threat model AWS-4). Media qua
  CloudFront `*.cloudfront.net` gói Free cả hai env ([0052](0052-cloudfront-flat-rate-free.md)): không access log, không header tự viết.
- Rà theo Well-Architected, Security Hub FSBP, CIS v5.0.0, AWS SRA thấy thiếu: WAF, IP reputation cho web, API; cert do AWS quản; TLS policy khuyên
  dùng; access log CloudFront (CloudFront.5); CAA; DNSSEC, query log (Route53.2).
- DNS cha `<miền>` (2026-11-12) chưa ký, TLD không có `DS` của nó; nhà cung cấp DNS cha cho thêm `DS` cho tên con. Hai account không còn gói CloudFront.
- Ràng buộc: repo public, AI không chạy lệnh chạm account, env sống trong buổi tối đa 4 giờ, stg chạy như prd ([0055](0055-environment-matrix.md)).

## Yếu tố quyết định

- Chỉ CloudFront (qua WAF) tới được Envoy (Well-Architected SEC05, SEC06); rate limit theo IP thật của người xem, không pod nào chọn được
  IP mà gateway tin (threat model RL-1, RL-7).
- Cert do AWS phát hành, gia hạn; TLS theo policy AWS khuyên (FSBP CloudFront.15, ELB.17); mỗi bản ghi DNS một chủ.
- stg giống prd trừ dự phòng (0055); thêm dưới $5 mỗi buổi và dưới $5 mỗi tháng lúc không buổi.

## Phương án đã cân nhắc

Trạng thái ngành, được, mất, nguồn: [phụ lục](appendix/0061-edge-cloudfront-waf-acm.md#phương-án). In đậm là lựa chọn.

- Origin: **VPC origin tới ALB internal**; ALB public chỉ nhận prefix list CloudFront cộng header bí mật (IP công khai, header phải xoay); NLB qua
  VPC origin (loại: VPC origin không nhận NLB có listener TLS [N1]; NLB TCP thì Envoy phải giữ cert công khai).
- Distribution: **mỗi tên một** (web, api, media); một distribution nhiều behavior (một web ACL chung cho web và API).
- ExternalDNS: **bỏ, bản ghi edge do Terraform**; giữ (hai chủ cùng ghi một zone, đích không còn là Service trong cluster).
- IP client: **header `CloudFront-Viewer-Address`**; đếm hop `X-Forwarded-For` (ba hop, đổi theo đường đi); `clientIPDetection` của Envoy (tin IP ở hai chỗ).
- Ai tới được Envoy: **tầng subnet edge không pod + NetworkPolicy**; Envoy xoá header khi nguồn không phải ALB (lọc theo nguồn ở proxy); chấp nhận
  pod giả IP (trái RL-7).
- Đo tải: **trong cluster, thẳng tới Envoy**; qua CloudFront (rate-based của WAF và giới hạn theo IP chặn tải từ vài IP NAT).
- TLS sau CloudFront: **ACM ở CloudFront, ALB; CA nội bộ ở Envoy**; Let's Encrypt ở Envoy (cert công khai thừa, CAA chặn); cert ACM exportable
  ($7 mỗi tên mỗi lần phát hành [N23], khoá riêng ra khỏi ACM).

## Kết quả quyết định

Chọn các phương án in đậm, vì chỉ CloudFront có đường vào, WAF và log đứng trước mọi request, cert và DNS là tài nguyên trong state. Cái giá: một
ALB và một tầng subnet nữa mỗi env, logic IP client mới ở gateway, phí WAF theo giờ. Giá trị đủ từng mục và lý do: phụ lục, cùng số §.

### 1. Gói CloudFront

Distribution media của stg giữ gói flat-rate Free (biến `flat_rate_free` của module `media`, root `media_flat_rate_free`: stg `true`, prd
`false`). Mọi distribution khác (media prd; web, api cả hai env) pay-as-you-go: gói Free không có response headers policy tự viết, access log,
ATP, Bot Control, quá 5 luật, mỗi gói một distribution, tối đa 3 gói mỗi account [N25]; web, api của stg phải chạy đúng edge của prd.

### 2. Distribution

Mỗi env `svp-<env>-web` (alias `<domain>`), `svp-<env>-api` (`api.<domain>`), `svp-<env>-media` (`media.<domain>`): `http2and3`, IPv6,
`PriceClass_All`, `sni-only`, §5, §7. Web, api (module mới `edge`): origin là VPC origin, `redirect-to-https`, mọi method, behavior mặc định
`Managed-CachingDisabled` + origin request policy `Managed-AllViewerAndCloudFrontHeaders-2022-06` (mọi header viewer kể cả Host, cookie, query,
có `CloudFront-Viewer-Address` [N3]); web thêm `/_next/static/*` với `Managed-CachingOptimized` [N4] và cùng origin request policy (Envoy định
tuyến theo Host; origin request policy không vào cache key [N28]). Không custom cache policy. Media giữ S3 + OAC, `https-only`. Mỗi tên một
distribution vì một distribution gắn đúng một web ACL: web cần Bot Control, api cần ATP.

### 3. Subnet edge và origin VPC

- **Subnet edge** (module `network`): tầng thứ tư, mỗi AZ một subnet kiểu `intra_subnets`, `cidrsubnet(cidrsubnet(var.cidr, 3, 7), 4, 8 + i)`
  (`/23` ở `/16`, `/27` ở `/20`, đủ `/27` của ALB [N8]); không tag `kubernetes.io/role/*`, `karpenter.sh/discovery`: không node, không pod. NACL
  edge vào chỉ từ CIDR VPC. Tầng public bỏ TCP 443 từ Internet và tag `kubernetes.io/role/elb`: chỉ còn NAT.
- NACL inbound không xét lưu lượng CloudFront tới VPC origin [N1], nên NACL edge không chặn nó; ALB là proxy, target thấy địa chỉ của ALB [N29]:
  mọi kết nối tới Envoy từ dải edge là của ALB.
- **Origin VPC** (module `edge`): ALB internal `svp-<env>-edge` ở subnet edge; security group chỉ nhận TCP 443 từ prefix list
  `com.amazonaws.global.cloudfront.origin-facing` [N1] (không chọn group `CloudFront-VPCOrigins-Service-SG`: do dịch vụ tạo, ngoài state); listener
  HTTPS 443, `drop_invalid_header_fields = true`, `desync_mitigation_mode = "defensive"` (mặc định của AWS [N8]); deletion protection là biến (prd
  `true`, `teardown.tfvars` và stg `false`); target group `svp-<env>-envoy` kiểu `ip`, HTTPS 443, health check HTTP 19003 `/ready`;
  `aws_cloudfront_vpc_origin` `svp-<env>-edge`, `https-only`, TLSv1.2; rule SG ALB tới SG node TCP 10443, 19003. Không tag `elbv2.k8s.aws/*`.
- Không access log ALB (ELB.5), không WAF regional (ELB.16): ALB chỉ nhận từ CloudFront, mọi request đã ở log CloudFront và WAF.

### 4. Envoy sau ALB

- Service của EnvoyProxy `svp` kiểu `ClusterIP`, tên `svp-envoy`, không annotation Load Balancer Controller; `TargetGroupBinding` `svp-envoy`
  (`envoy-gateway-system`, `targetType: ip`, cổng 443, `targetGroupARN` từ `cluster.edgeTargetGroupArn`, không khối `networking`).
- ALB không gửi SNI tới target [N10], không kiểm cert target [N9]: Gateway `svp` trên eks có một listener `https` không hostname, Secret
  `svp-edge-tls` do issuer CA nội bộ `svp-ca` ký; k3d giữ hai listener. Listener, certificate là values theo nền tảng.
- NetworkPolicy `envoy`: nguồn cổng 10443 và cổng health check là values; eks: 10443 từ `cluster.edgeCidrs` và namespace `svp-load`, 19003 chỉ từ
  `cluster.edgeCidrs`. Load Balancer Controller giữ wave 1: mang CRD, webhook của `TargetGroupBinding` mà `svp-cluster` render cùng wave.
- **Hợp đồng cluster:** `cluster_values` thêm `edgeTargetGroupArn`, `edgeCidrs`, bỏ `hostedZoneId`, `acmeEmail`.

### 5. Chứng chỉ và TLS

- **Chứng chỉ viewer:** mỗi distribution một cert ACM `us-east-1` [N6], đúng một tên là alias, DNS validation, ECDSA P-256 `EC_prime256v1`
  (CloudFront nhận prime256v1 [N6], ACM phát hành được [N13]).
- **Chứng chỉ ALB:** cert ACM region nhà cho `<domain>` + SAN `api.<domain>`, ECDSA P-256 [N11]; record CNAME validation của một tên dùng cho
  mọi region [N13], tạo một lần.
- **Chính sách TLS viewer:** `TLSv1.2_2025` cho cả ba distribution: mới nhất nhận TLS 1.2 và 1.3 [N5], CloudFront.15 nhận [N22].
- **Chính sách TLS ALB:** `ELBSecurityPolicy-TLS13-1-2-Res-PQ-2025-09`, policy AWS khuyên [N7], ELB.17 nhận [N22].
- Envoy dùng CA nội bộ của cert-manager. Let's Encrypt, ClusterIssuer ACME, role Route 53 của cert-manager, `acme_email` rời stg, prd; k3d giữ CA local.

### 6. Response headers policy

Policy tự viết `svp-<env>-web`, `svp-<env>-api`: HSTS `max-age=63072000; includeSubDomains`, nosniff, `X-Frame-Options: DENY`,
`Referrer-Policy: strict-origin-when-cross-origin`; CSP `default-src 'none'; frame-ancestors 'none'` chỉ ở api. Web tự đặt CSP có nonce và vài
header (`frontend/server/csp.ts`): policy web `override = false`; gateway không đặt header nào: policy api `override = true`. Media `flat_rate_free
= false` dùng `svp-<env>-media` (CORS theo `cors_allowed_origins` cho `GET`, `HEAD`, HSTS, nosniff), `true` giữ `Managed-SimpleCORS`.

### 7. Web ACL

- Ba ACL mỗi env (`svp-<env>-web`, `-api`, `-media`), mỗi cái gắn đúng distribution cùng tên, giống hệt ở stg và prd: rate-based theo IP đầu tiên,
  `AWSManagedRulesAmazonIpReputationList`, `AWSManagedRulesCommonRuleSet`, `AWSManagedRulesKnownBadInputsRuleSet`; log về bucket log WAF, che
  `authorization`, `cookie`.
- api thêm ATP cho `POST /auth/login`: JSON, `/email`, `/password`; response inspection (chỉ có ở CloudFront [N16]) thành công `200`, thất bại `401`
  (spec của gateway); scope-down đúng path đó.
- Web không ATP: đăng nhập là Server Action, body multipart, ATP chỉ đọc JSON, form-urlencoded [N16]; phần còn lại là rate limit đăng nhập của
  gateway theo IP của §9. `SizeRestrictions_BODY` (8 KB [N18]) thành `count` ở web vì báo lỗi trình duyệt tới `/monitoring` dài tới 32 KiB.
- Web thêm Bot Control mức `COMMON` [N17], chỉ gắn nhãn, đo trước khi chặn [N33]: `override_action { count {} }` (nhóm không chặn gì, kể cả
  luật AWS thêm sau) cộng `rule_action_override` `count` từng luật (mọi luật chạy, đủ nhãn) [N34]; luật khác giữ hành động; bật block: ADR mới [N32].

### 8. Log edge

- Standard logging v2 (vended log) cho mọi distribution pay-as-you-go tới **bucket log CloudFront** `svp-cloudfront-<log>-us-east-1` của
  `aws/log-archive` (khuôn bucket Log Archive của [0060](0060-org-detection-logging.md) §7); không real-time, không logging legacy [N14].
- Giao chéo account theo tài liệu [N14], [N15]: root `aws/log-archive` (`us-east-1`) giữ delivery destination `svp-cloudfront-<env>` (đích là
  bucket với tiền tố `AWSLogs/<account env>/CloudFront`) và policy `logs:CreateDelivery` cho đúng account env đó; account env tạo delivery source
  `ACCESS_LOGS` và delivery (module `edge`, `media` nhận ARN destination, không nhận ARN bucket; root env suy ARN từ tên).
- `record_fields` tường minh: trường của tài liệu trừ `cs(Cookie)` (phụ lục §8); `cs-uri-query` không mang token. Parquet, đường kiểu Hive.

### 9. IP client

- **Header địa chỉ người xem:** `CloudFront-Viewer-Address` `<ip>:<cổng>` [N2]; IPv6 không ngoặc, cổng sau dấu `:` cuối [N24]. CloudFront đè
  giá trị viewer gửi khi origin request policy thêm header đó [N31]; phép kiểm edge vẫn kiểm.
- **IP client ở gateway:** biến `TRUSTED_CLIENT_ADDRESS_HEADER`; khi đặt, chỉ trên kết nối từ `TRUSTED_PROXY_CIDRS`, IP từ header (một giá trị, bỏ cổng
  ở dấu `:` cuối, nhận `[v6]:port`; khác thì địa chỉ kết nối), không đọc `X-Forwarded-For`; khởi động lỗi khi `TRUSTED_PROXY_CIDRS` rỗng hay
  `TRUSTED_PROXY_HOPS` khác 0. eks đặt header này, hop `0`, CIDR VPC; compose, k3d không đặt.
- **BFF chuyển header:** web chuyển nguyên `cloudfront-viewer-address` trong mọi lời gọi gateway, cạnh `x-forwarded-for`.
- Ai đặt được header gateway tin: gateway nhận từ Envoy, web; web từ Envoy; Envoy từ ALB và `svp-load`; ALB từ CloudFront; CloudFront đè header viewer [N31].

### 10. Đo tải trong cluster

Job k6 `svp-k6` (`svp-load`) đi thẳng tới ClusterIP của `svp-envoy`, không qua CloudFront, WAF (1 250 req/s từ vài IP NAT chạm rate-based và giới
hạn theo IP); mỗi pod đặt `CloudFront-Viewer-Address: <IP pod>:0`, nên mỗi pod một bucket như RL-7; pod tin CA nội bộ của Envoy (`ca.crt` của
Secret `svp-edge-tls`); cờ `--forwarded-for` bỏ. Chấp nhận: namespace chỉ có trong buổi đo, do người học tạo.

### 11. DNS

- **DNS env** (root env, theo buổi): alias A, AAAA của ba tên tới distribution của nó, record validation ACM. ExternalDNS rời nền tảng eks; đề xuất
  bỏ nó khỏi bảng công cụ của lộ trình.
- **DNS zone** (`account-baseline`, sống lâu): CAA ở đỉnh zone cả hai env, `issue`, `issuewild` cho `amazon.com`, `amazontrust.com`, `awstrust.com`,
  `amazonaws.com` [N12] (CA tìm CAA ngược lên tên cha [N30]). Chỉ prd: DNSSEC (key KMS `us-east-1` `ECC_NIST_P256`, KSK, hai alarm page
  `svp-prd-dnssec-internal-failure`, `svp-prd-dnssec-ksk-action-needed` có runbook [N20]) và query log (log group `us-east-1` [N21], 90 ngày).
- **Tắt ký DNSSEC:** biến `dnssec_signing` đặt `NOT_SIGNING`, key và KSK giữ; gỡ `DS` ở DNS cha trước. Không đặt `dnssec_enabled = false` khi key
  KMS còn trong state.
- Chuỗi tin cậy: `<miền>` ký ở DNS cha và có `DS` ở TLD trước, rồi mới thêm `DS` của `aws`; gỡ theo thứ tự ngược.

### 12. Thứ tự áp lần đầu

Sau khi PR bỏ Let's Encrypt của `svp-gitops` và PR `svp-infra` merge, người học theo runbook `edge-setup.md`: (1) `aws/log-archive` rồi `aws/org`;
(2) `aws/accounts/stg`, `aws/accounts/prd`, xác nhận email SNS (CAA chặn Let's Encrypt, nên chỉ khi không cluster nào còn xin cert ACME);
(3) ký `<miền>` và đặt `DS` ở TLD, chờ KSK `ACTIVE`, thêm `DS` `aws` ở DNS cha, kiểm `dig +dnssec`, `delv`; (4) buổi stg, prd.

### 13. Chi phí edge

Theo trang giá, Price List (đọc 2026-11-12; bảng ở phụ lục): buổi 4 giờ thêm ~$0,5 ở stg, ~$0,55 ở prd, trừ NLB đã bỏ (~$0,12); khoản lớn nhất
là phí cố định theo giờ của WAF (ACL, luật, ATP, Bot Control), rồi ALB ~$0,13; CloudFront trong hạn mức miễn phí. Lúc không buổi ~$2,4 mỗi tháng
(hai key KMS `us-east-1` của DNSSEC và topic alarm, hai alarm, query log).

### 14. Khác biệt stg/prd và ADR cũ

Được giảm ở stg: gói Free và không access log của media, không DNSSEC, không query log, ALB không deletion protection; mọi thứ khác của edge phải
giống (0055). ADR cũ chỉnh (dòng `### Chỉnh bởi`): 0020 §2, 0034 §5, 0048 §4, §6, 0051 §2, 0052, 0054, 0055 §2, §3, 0059 §4, §5, §10, 0060 §7.

### Hệ quả

- Tốt: không còn load balancer internet-facing; mọi request qua WAF và có log; cert tự gia hạn, hết giới hạn của Let's Encrypt; IP người xem thật ở
  rate limit; DNS edge trong state; zone prd ký; stg chạy đúng edge của prd.
- Xấu: thêm ALB, tầng subnet, ba web ACL mỗi env, một chặng TLS; Bot Control chỉ gắn nhãn, chưa chặn bot; IP client đúng chỉ khi mọi chặng của §9
  giữ; Job k6 tự chọn IP; không access log ALB; health check HTTP (ELB.21); DNSSEC thêm alarm page, đường gỡ nhiều bước, phụ thuộc DNS cha.
- Xem lại khi: phép kiểm thấy `CloudFront-Viewer-Address` tự đặt tới gateway (dừng buổi, quyết lại); log WAF có request hợp lệ bị chặn; sau buổi
  stg, prd đã đọc nhãn bot trong log WAF (bật block Bot Control bằng ADR mới kèm ngoại lệ đã đo); người khác tạo được namespace; cần failover
  origin (CloudFront.4) hay access log ALB; lưu lượng tháng vượt hạn mức miễn phí của CloudFront.

## Xác nhận

- Lúc quyết chưa hiện thực. Kiểm tĩnh: `make check` của `svp-infra` (test mocked `edge`, `media`, `waf`, `network`, `account-baseline`, `log-archive`),
  `make check`, `make helm-check` của repo này, `make docs-check`. Phép kiểm edge: [phụ lục](appendix/0061-edge-cloudfront-waf-acm.md#phép-kiểm-edge).

## Hiện thực ở

- `svp-infra`: `aws/modules/edge/` (§2–§5, §8, §11), `aws/modules/media/` (§1, §2, §5, §6, §8), `aws/modules/waf/` (§7), `aws/modules/network/` (§3),
  `aws/modules/account-baseline/`, `aws/modules/alarms/`, `aws/accounts/` (§11), `aws/log-archive/`, `aws/org/identity-center.tf` (§8),
  `aws/envs/<env>/`, `aws/modules/gitops-bridge/`, `aws/gitops/` (§4), `aws/scripts/`, `docs/runbooks/edge-setup.md` (§11, §12).
- Repo này: `services/gateway/` (§9), `deploy/helm/svp-cluster/` (§4), `deploy/k6/cloud/` (§10), `docs/runbooks/dnssec-*.md` (§11).
- `svp-frontend`: `server/` (§9). `svp-gitops`: `platforms/eks/`, `base/aws-load-balancer-controller.yaml` (§4, §5, §11).
- Tài liệu: `docs/explanation/environments.md` (§14), `docs/threat-model.md` (§9, §10).

## Nguồn

Đọc 2026-11-12; đủ [N1]–[N34] ở phụ lục. [N1] <https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/private-content-vpc-origins.html>

## Thông tin thêm

Phụ lục: [`appendix/0061-edge-cloudfront-waf-acm.md`](appendix/0061-edge-cloudfront-waf-acm.md) (phương án, giá trị đủ từng §, bảng header,
luật WAF, trường log, bảng control FSBP, bảng luồng RCP, bảng giá và chi phí, phép kiểm edge, nguồn).

### Chỉnh bởi

- §6: [0069](0069-auth-hardening.md): gateway đặt nosniff, CSP, Cache-Control; policy api override = true ghi đè cùng giá trị.
