# Phụ lục ADR-0061: Edge của web, API, media ở stg và prd: CloudFront có WAF trước mọi tên, web và API qua VPC origin tới ALB internal ở tầng subnet edge riêng, cert ACM thay Let's Encrypt, DNS edge do Terraform; gateway lấy IP client từ `CloudFront-Viewer-Address`; chỉ media của stg giữ gói Free; CAA hai zone, DNSSEC và query log zone prd

Phụ lục của [ADR-0061](../0061-edge-cloudfront-waf-acm.md): phương án, giá trị đủ của từng §, bảng control FSBP, bảng luồng RCP, bảng giá và
nguồn, xếp theo §. Mọi nguồn đọc ngày 2026-11-12. Đường dẫn `aws/...`, `docs/...` không kèm repo là của `svp-infra`; `<log>`, `<stg>`, `<prd>` là id
account `svp-log-archive`, `svp-stg`, `svp-prd`; `<domain>` là tên zone của env, `<miền>` là tên miền cha của lab.

## Phương án

| Câu hỏi | Phương án | Trạng thái ngành | Được | Mất | Nguồn |
| --- | --- | --- | --- | --- | --- |
| Origin của web, API | **CloudFront VPC origin tới ALB internal** | Hiện hành, cách CloudFront tới origin ở subnet private | Origin không IP công khai, không đường từ Internet; SG chỉ CloudFront; không phí riêng cho VPC origin | Thêm ALB (~$0,033 mỗi giờ) và một chặng TLS; cert ACM region nhà | [N1], [N23] |
| | ALB public, SG theo prefix list origin-facing, header bí mật CloudFront gửi | Hiện hành, cách cũ trước VPC origin | Không cần subnet riêng | ALB có IP công khai; prefix list gồm mọi distribution của mọi khách AWS, nên phải thêm header bí mật và xoay nó | [N1] |
| | NLB qua VPC origin | Hiện hành cho NLB TCP | Giữ Envoy như hiện có | "Network Load Balancers with TLS listeners cannot be added as origins" [N1]; NLB TCP thì Envoy giữ cert công khai (Let's Encrypt hay ACM exportable) | [N1] |
| Số distribution | **Mỗi tên một (web, api, media)** | Hiện hành | Mỗi bề mặt một web ACL (Bot Control cho web, ATP cho api), header, cert, log riêng | Ba distribution mỗi env | [N16], [N17] |
| | Một distribution, behavior theo path | Hiện hành | Ít tài nguyên | Một web ACL cho cả web, API: Bot Control khi bật block chặn client API, ATP và Bot Control cùng tính phí mọi request | — |
| Bản ghi DNS edge | **Terraform của root env** | Hiện hành | Đích là CloudFront, Terraform biết khi tạo; bản ghi trong state, plan đọc được | Bỏ một công cụ trong bảng của lộ trình | — |
| | Giữ ExternalDNS | Hiện hành cho bản ghi trỏ Service, Ingress trong cluster | Không đổi | Cluster không còn địa chỉ công khai; hai chủ cùng ghi một zone | [0051](../0051-dns-prd-apex.md) §2 |
| IP client ở gateway | **`CloudFront-Viewer-Address`** | Header CloudFront dành cho việc này | Một giá trị do CloudFront đặt, đè giá trị viewer tự gửi; không phụ thuộc số hop | Cần code mới ở gateway; đúng chỉ khi mọi chặng sau CloudFront chỉ nhận từ chặng trước (§9) | [N2], [N31] |
| | Đếm hop `X-Forwarded-For` | Cách chung của mọi proxy | Code có sẵn | CloudFront, ALB, Envoy: ba hop; đường web (qua BFF) và k6 khác số hop; đổi một chặng thì bucket chung hay giả IP | threat model RL-1 |
| | `clientIPDetection` của Envoy Gateway | Hiện hành | Envoy tự đặt địa chỉ client | Logic tin IP ở cả Envoy và gateway; compose không có Envoy nên gateway vẫn cần đường riêng | — |
| Ai tới được Envoy | **Tầng subnet edge không pod, NetworkPolicy theo dải đó** | Tách tầng mạng (SEC05-BP01) | NetworkPolicy phân biệt được ALB với pod | Thêm một tầng subnet và NACL (không tốn tiền) | [N8] |
| | Envoy xoá header khi nguồn không phải ALB | — | Không thêm subnet | Lọc theo địa chỉ nguồn ở proxy là logic tin cậy thứ hai | — |
| | Chấp nhận pod giả IP | — | Không đổi gì | Trái RL-7 đã chốt | threat model RL-7 |
| Đo tải | **Job k6 trong cluster thẳng tới Envoy** | Cách của RL-7 | Không chạm WAF, rate limit theo IP | Pod k6 tự đặt header IP (ngoại lệ có giới hạn) | — |
| | Qua CloudFront | — | Đo cả edge | 1 250 req/s từ vài IP NAT chạm luật rate-based của WAF; tính phí request | — |
| TLS sau CloudFront | **ACM ở CloudFront, ALB; CA nội bộ cert-manager ở Envoy** | Hiện hành | Cert công khai tự gia hạn; ALB không kiểm cert target [N9] | Một CA nội bộ trên eks | [N9], [N13] |
| | Let's Encrypt giữ ở Envoy | Hiện hành | Không đổi chart | Cert công khai không ai kiểm sau ALB; CAA chỉ cho CA của Amazon; giới hạn phát hành của Let's Encrypt | [N12] |
| | Cert ACM exportable ở Envoy | Hiện hành | Một loại cert | $7 mỗi tên mỗi lần phát hành và gia hạn, khoá riêng ra khỏi ACM vào Secret | [N23] |
| Bot Control của web trước khi đo | **`override_action { count {} }` cộng `rule_action_override` `count` mọi luật** | Cách AWS triển khai nhóm mới, thêm chốt cho luật mới | Không gì của nhóm chặn, kể cả luật AWS thêm ở version sau; mọi luật được đánh giá, log đủ nhãn | Module giữ danh sách tên luật theo [N17]; tên sai bị bỏ qua không báo | [N17], [N33], [N34] |
| | Chỉ `override_action { count {} }` | — | Không cần danh sách luật | "This is not a good option for testing the rules in a rule group": luật block đầu tiên khớp dừng nhóm, thiếu nhãn để đo | [N33] |
| | Chỉ `rule_action_override` `count` từng luật | Cách AWS ghi để thử nhóm | Đủ nhãn | Luật AWS thêm ở version mặc định sau mang hành động của nó (Block), có thể chặn client kiểm | [N33], [N34] |
| | Block ngay, ngoại lệ cho client kiểm | Hiện hành khi đã có số đo | Chặn bot từ buổi đầu | Chưa có số đo; dấu hiệu nhận client kiểm phải đoán; client qua VPN, trình duyệt tự động bị chặn | [N17], [N32] |

## §1. Gói CloudFront

- Module `media`: biến bool `flat_rate_free` không mặc định; `true` tạo `aws_pricingplanmanager_subscription` (như [0052](../0052-cloudfront-flat-rate-free.md) §2),
  `Managed-SimpleCORS`, không access log; `false` không gói, policy `svp-<env>-media`, log v2. Root `media_flat_rate_free`: `stg.tfvars` `true`,
  `prd.tfvars` `false`.
- Lý do web, api của stg cũng pay-as-you-go: gói Free không có "Custom response header rules", access log, quản lý bot, quá 5 luật, mỗi gói một
  distribution, tối đa 3 gói Free mỗi account ([0052](../0052-cloudfront-flat-rate-free.md) §1, [N25]); ATP và Bot Control là luật có phí riêng. stg phải chạy
  đúng cấu hình edge của prd ([0055](../0055-environment-matrix.md) §2).
- Hiện trạng 2026-11-12 (người học đọc `pricing-plan-manager list-subscriptions`): stg 0 gói, prd 0 gói.

## §2. Distribution

| | `svp-<env>-web` | `svp-<env>-api` | `svp-<env>-media` |
| --- | --- | --- | --- |
| Module | `edge` | `edge` | `media` |
| Alias, cert | `<domain>` | `api.<domain>` | `media.<domain>` |
| Origin | VPC origin `svp-<env>-edge` (ALB) | VPC origin `svp-<env>-edge` (ALB) | S3 `media` + OAC |
| Viewer protocol | `redirect-to-https` | `redirect-to-https` | `https-only` |
| Method | mọi method | mọi method | `GET`, `HEAD` |
| Behavior mặc định | `Managed-CachingDisabled` + `Managed-AllViewerAndCloudFrontHeaders-2022-06` | như web | `Managed-CachingOptimized` |
| Behavior thêm | `/_next/static/*`: `Managed-CachingOptimized` + `Managed-AllViewerAndCloudFrontHeaders-2022-06` | — | — |
| Response headers | `svp-<env>-web` | `svp-<env>-api` | `Managed-SimpleCORS` (Free) hay `svp-<env>-media` |
| Web ACL | `svp-<env>-web` | `svp-<env>-api` | `svp-<env>-media` |
| Log v2 | có | có | chỉ khi `flat_rate_free = false` |

Chung: comment và tag `Name` bằng tên ở hàng đầu, `http_version = "http2and3"`, `is_ipv6_enabled = true`, `price_class = "PriceClass_All"`,
`ssl_support_method = "sni-only"`, `minimum_protocol_version` §5. Không custom cache policy.

- `Managed-AllViewerAndCloudFrontHeaders-2022-06` (id `33f36d7e-f396-46d9-90e0-52428a34d9dc`): mọi header của viewer, mọi cookie, mọi query, cộng
  21 header CloudFront phát hành tới 2022-06, trong đó `CloudFront-Viewer-Address` [N3].
- `Managed-CachingDisabled`: TTL 0/0/0, key không header, cookie, query. `Managed-CachingOptimized`: TTL tối thiểu 1 giây, mặc định 86 400, tối đa
  31 536 000; key không header (trừ `Accept-Encoding` chuẩn hoá), cookie, query [N4]. Origin request policy "separate from cache policies, which
  control the cache key" [N28]: chuyển Host tới origin không đưa Host vào key; mỗi distribution chỉ một tên nên không lẫn cache giữa tên.
- `/_next/static/*` là file có hash trong tên (build Next), cache được ở edge; trang và Server Action đi behavior mặc định, không cache.

## §3. Subnet edge và origin VPC

### Subnet edge

- Module `network`: `intra_subnets` của module `terraform-aws-modules/vpc` (route table chỉ route `local`), mỗi AZ một subnet,
  `cidrsubnet(cidrsubnet(var.cidr, 3, 7), 4, 8 + i)`: slot 8–13 trên 16 của khối 7; tầng public chiếm slot 0–5 trên 32 của khối đó, nên không chồng.
  Cỡ `/23` với VPC `/16`, `/27` với `/20`: ALB cần subnet "at least a `/27` bitmask ... and at least eight free IP addresses per subnet" [N8].
- Tag `Name` `svp-<env>-edge-<az>`; không `kubernetes.io/role/*`, `karpenter.sh/discovery`. VPC CNI cấp IP pod từ subnet của node, nên không node,
  không pod nào có địa chỉ trong dải này.
- NACL edge: vào chỉ từ CIDR VPC (`nacl_from_vpc`), ra như tầng khác. Output `edge_subnet_ids`, `edge_subnet_cidrs`.
- Tầng public bỏ `nacl_https` (TCP 443 từ Internet) và tag `kubernetes.io/role/elb`: không còn load balancer internet-facing; tầng public chỉ giữ NAT.

### Lưu lượng VPC origin

Tài liệu VPC origins [N1]:

- "You can use Application Load Balancers (ALBs), Network Load Balancers (NLBs), and EC2 instances in private subnets as VPC origins."
  "Network Load Balancers with TLS listeners cannot be added as origins."
- "CloudFront routes to your subnet by using a service-managed elastic network interface (ENI) that CloudFront creates after you define your VPC
  origin resource"; subnet cần "at least one available IPv4 address".
- "Inbound NACL rules are not evaluated for traffic from CloudFront to your VPC origin." Tài liệu không nêu địa chỉ nguồn mà origin thấy; cách mở SG
  thứ nhất là prefix list origin-facing của CloudFront. NACL edge (chỉ CIDR VPC) vì vậy không chặn lưu lượng CloudFront, bất kể địa chỉ nguồn.
- "You need to add an internet gateway to the VPC that has your VPC origin resources", gateway "is not used for routing traffic to origins inside
  the subnet": VPC có sẵn Internet gateway cho NAT.
- Origin là ALB: target nhận kết nối từ địa chỉ của ALB, IP client chỉ còn trong header [N29]. Mọi kết nối tới Envoy từ dải edge là của ALB; ENI
  của CloudFront trong dải đó chỉ nối tới origin của nó.

### Origin VPC

| Tài nguyên | Giá trị |
| --- | --- |
| `aws_lb` `svp-<env>-edge` | `internal = true`, `load_balancer_type = "application"`, mọi subnet edge, `drop_invalid_header_fields = true`, `desync_mitigation_mode = "defensive"`, `enable_deletion_protection = var.deletion_protection` |
| Security group ALB | Vào TCP 443 từ prefix list `com.amazonaws.global.cloudfront.origin-facing`; ra TCP 10443, 19003 tới SG node (`node_security_group_id` của module `eks`) |
| Rule SG node | Vào TCP 10443, 19003 từ SG ALB |
| Listener | HTTPS 443, cert §5, `ssl_policy` §5, action mặc định forward tới target group |
| Target group `svp-<env>-envoy` | `target_type = "ip"`, `protocol = "HTTPS"`, port 443, health check `HTTP` port 19003 path `/ready` |
| `aws_cloudfront_vpc_origin` `svp-<env>-edge` | `arn` của ALB, `http_port` 80, `https_port` 443, `origin_protocol_policy = "https-only"`, `origin_ssl_protocols` `TLSv1.2` |
| Root | `edge_alb_deletion_protection`: `prd.tfvars` `true`, `teardown.tfvars` `false`, `stg.tfvars` `false` |

- Prefix list, không security group `CloudFront-VPCOrigins-Service-SG`: tài liệu cho cả hai; group dịch vụ "can be done only after the VPC origin is
  created", "is further restrictive as it restricts the traffic only to your CloudFront distributions", và "should not be edited" [N1]: nằm ngoài
  state, có sau VPC origin, gỡ cuối buổi phụ thuộc dịch vụ xoá nó. ALB internal không có đường nào ngoài VPC origin của chính account, nên prefix
  list không mở thêm đường. Prefix list IPv4 vì VPC không có IPv6 [N1].
- `desync_mitigation_mode`: "The default is the defensive mode, which provides durable mitigation against HTTP desync while maintaining the
  availability of your application"; `strictest` chỉ nhận request đúng RFC 7230 [N8]. CloudFront kết thúc HTTP của viewer và dựng request mới tới
  origin, nên byte của viewer không tới ALB nguyên dạng; `strictest` chỉ thêm 400 cho request hợp lệ mà CloudFront chuyển. ELB.12 nhận `defensive`,
  `strictest` [N22].
- `drop_invalid_header_fields`: mặc định `false`, `true` thì header không hợp lệ bị bỏ thay vì tới target [N8] (ELB.4).
- Không tag `elbv2.k8s.aws/*` trên ALB, listener, target group: policy IAM của Load Balancer Controller (`aws/modules/eks/policies/aws-load-balancer-controller-v3.6.2.json`)
  cho `RegisterTargets` trên mọi `targetgroup/*/*` không điều kiện tag, còn `pre-destroy.sh` chờ tới khi hết LB, TG mang tag `elbv2.k8s.aws/cluster`.
- Không access log ALB (ELB.5), không web ACL regional trên ALB (ELB.16, ngoài FSBP): ALB chỉ nhận từ CloudFront, mọi request đã có ở log CloudFront
  và log WAF. Xem lại khi cần thời gian xử lý của target theo request (trường của access log ALB) hay ALB nhận nguồn khác CloudFront.

## §4. Envoy sau ALB

- Chart `svp-cluster`, values nền tảng eks ở `platforms/eks/` của `svp-gitops`: Service của EnvoyProxy `svp` kiểu `ClusterIP`, tên cố định `svp-envoy`
  (field tên Service của EnvoyProxy ở Envoy Gateway 1.9.3), không annotation Load Balancer Controller.
- `TargetGroupBinding` `svp-envoy`: namespace `envoy-gateway-system`, `targetType: ip`, `serviceRef` Service `svp-envoy` cổng 443, `targetGroupARN` từ
  `cluster.edgeTargetGroupArn`, không khối `networking` (rule SG do Terraform giữ, §3).
- ALB không gửi SNI trong TLS handshake tới target [N10]; "The load balancer does not validate these certificates. Therefore, you can use self-signed
  certificates or certificates that have expired" [N9]. Nên trên eks Gateway `svp` có một listener `https` HTTPS 443 không hostname, Secret
  `svp-edge-tls` do issuer CA nội bộ `svp-ca` ký cho `<domain>` và `api.<domain>`; HTTPRoute của web gắn `sectionName: https`; HTTPRoute vẫn chọn
  backend theo Host. k3d giữ hai listener `https`, `https-apex` như cũ. Danh sách listener và certificate là values theo nền tảng, không `if` theo tên
  nền tảng.
- Cổng container của listener 443 là 10443, readiness 19003, metrics 19001. NetworkPolicy `envoy`: nguồn của 10443 và nguồn của cổng health check là
  hai danh sách values (`ipBlock` hay `namespaceSelector`), không suy từ annotation; mặc định render như hiện có. eks: 10443 từ `cluster.edgeCidrs`
  và namespace `svp-load`, 19003 chỉ từ `cluster.edgeCidrs`, 19001 từ `svp-obs`.
- Load Balancer Controller ở wave 1 của `argocd/apps/components.json` cùng `svp-cluster`: không còn tạo load balancer, nhưng mang CRD và webhook của
  `TargetGroupBinding` mà `svp-cluster` render cùng wave; Argo CD sync được nhờ `SkipDryRunOnMissingResource` và retry
  (`argocd/apps/templates/applications.yaml`); đặt controller ở wave sau thì `TargetGroupBinding` của wave 1 thiếu CRD, wave 1 không xong.

### Hợp đồng cluster

| Khoá | Đổi | Giá trị |
| --- | --- | --- |
| `edgeTargetGroupArn` | thêm | ARN target group `svp-<env>-envoy` (output của module `edge`) |
| `edgeCidrs` | thêm | Danh sách CIDR subnet edge (`edge_subnet_cidrs`), như `dbCidrs` |
| `hostedZoneId` | bỏ | Không còn gì trong cluster ghi zone |
| `acmeEmail` | bỏ | Không còn Let's Encrypt ở stg, prd |

Cùng bộ khoá ở `cluster_values` của root `aws/envs/<env>`, validation của module `gitops-bridge`, fixture `deploy/ci/cluster-values.example.yaml`,
`deploy/helm/svp-cluster/ci/eks-example.yaml` của repo này, template `platforms/eks/` và bảng hợp đồng ở `README.md` của `svp-gitops`. Output
`cluster_values` bỏ `sensitive` nếu lý do duy nhất là `acmeEmail`.

## §5. Chứng chỉ và TLS

| Cert | Region | Tên | Thuật toán | Validation |
| --- | --- | --- | --- | --- |
| Viewer web | `us-east-1` | `<domain>` | `EC_prime256v1` | DNS, zone env |
| Viewer api | `us-east-1` | `api.<domain>` | `EC_prime256v1` | DNS, zone env |
| Viewer media | `us-east-1` | `media.<domain>` | `EC_prime256v1` | DNS, zone env |
| ALB | `ap-southeast-1` | `<domain>`, SAN `api.<domain>` | `EC_prime256v1` | DNS, dùng lại record của hai cert viewer |

- CloudFront: "make sure you request (or import) the certificate in the US East (N. Virginia) Region (`us-east-1`)"; "To use an ECDSA certificate in
  ACM to require HTTPS between viewers and CloudFront, use the prime256v1 or secp384r1 elliptic curve" [N6]. ACM: "ECDSA 256 bit (`EC_prime256v1`)"
  là thuật toán ACM phát hành mới được [N13]. ALB nhận cert ECDSA của ACM [N11].
- "Since the CNAME validation token works for any AWS Region, you can re-create the same certificate in multiple Regions" [N13]: record CNAME của
  `<domain>`, `api.<domain>` tạo một lần, cert `us-east-1` và cert region nhà cùng dùng.
- Origin request policy chuyển Host của viewer tới ALB, nên ALB chọn cert theo SNI là tên đó và CloudFront kiểm cert origin theo tên đó: cert ALB
  phủ `<domain>`, `api.<domain>`.
- Viewer: policy có `TLSv1.2_2018`, `TLSv1.2_2019`, `TLSv1.2_2021`, `TLSv1.2_2025` (nhận TLS 1.2 và 1.3), `TLSv1.3_2025` (chỉ TLS 1.3) [N5]; chọn
  `TLSv1.2_2025`: mới nhất nhận cả hai, nằm trong `securityPolicies` `TLSv1.2_2025,TLSv1.3_2025` của CloudFront.15 [N22]; `TLSv1.3_2025` cắt client
  chỉ TLS 1.2. Provider ghim phải nhận giá trị này; không thì dừng, không hạ.
- ALB: "AWS recommends implementing the new post-quantum TLS (PQ-TLS) based security policy `ELBSecurityPolicy-TLS13-1-2-Res-PQ-2025-09`" [N7]: TLS
  1.3, TLS 1.2, trao khoá lai post-quantum khi client hỗ trợ; nằm trong danh sách `sslPolicies` của ELB.17 [N22]. Mặc định của API là
  `ELBSecurityPolicy-2016-08` [N7], nên phải đặt tường minh.
- VPC origin tới ALB: `https-only`, `TLSv1.2` (CloudFront.10: không giao thức cũ tới origin).
- Envoy: issuer CA nội bộ `svp-ca` của cert-manager ký `svp-edge-tls`. Bỏ ở stg, prd: Let's Encrypt, ClusterIssuer ACME, role Pod Identity Route 53 của
  cert-manager, biến `acme_email`. k3d giữ CA local.

## §6. Response headers policy

| Header | `svp-<env>-web` | `svp-<env>-api` | `svp-<env>-media` (`flat_rate_free = false`) |
| --- | --- | --- | --- |
| `Strict-Transport-Security` | `max-age=63072000; includeSubDomains`, override `false` | như web, override `true` | như api |
| `X-Content-Type-Options` | `nosniff`, override `false` | `nosniff`, override `true` | `nosniff`, override `true` |
| `X-Frame-Options` | `DENY`, override `false` | `DENY`, override `true` | — |
| `Referrer-Policy` | `strict-origin-when-cross-origin`, override `false` | như web, override `true` | — |
| `Content-Security-Policy` | — (web đặt CSP có nonce) | `default-src 'none'; frame-ancestors 'none'`, override `true` | — |
| CORS | — | — | `Access-Control-Allow-Origin` = `cors_allowed_origins`, method `GET`, `HEAD`, không credential, origin override `true` |

- Web đặt `Content-Security-Policy` có nonce mỗi request, HSTS cùng giá trị khi `APP_ORIGIN` là https, `Referrer-Policy`, `X-Content-Type-Options`
  (`frontend/server/csp.ts`; `frame-ancestors 'none'` thay `X-Frame-Options`): `override = false` để edge chỉ điền header còn thiếu (trang lỗi
  của Envoy, file tĩnh) mà không đè header của web.
- Gateway không đặt header nào trong bảng: policy api là nguồn duy nhất, `override = true`. API trả JSON, nên CSP `default-src 'none'` không chặn gì.
- HSTS 2 năm, `includeSubDomains`, không `preload`: mọi tên dưới zone env đều HTTPS; `preload` đưa tên vào danh sách của trình duyệt, gỡ ra mất hàng
  tháng.
- `flat_rate_free = true` giữ `Managed-SimpleCORS` ([0052](../0052-cloudfront-flat-rate-free.md) §4).

## §7. Web ACL

| Ưu tiên | Luật | web | api | media | WCU |
| --- | --- | --- | --- | --- | --- |
| 0 | `rate-limit-per-ip` (rate-based theo IP, `rate_limit` của module, block) | có | có | có | 2 |
| 1 | `AWSManagedRulesAmazonIpReputationList` | có | có | có | 25 |
| 2 | `AWSManagedRulesCommonRuleSet` | có, `SizeRestrictions_BODY` = `count` | có | có | 700 |
| 3 | `AWSManagedRulesKnownBadInputsRuleSet` | có | có | có | 200 |
| 4 | `AWSManagedRulesBotControlRuleSet` (`COMMON`), cả nhóm `count`: `override_action { count {} }` và `rule_action_override` `count` mọi luật | có | — | — | 50 |
| 4 | `AWSManagedRulesATPRuleSet`, scope-down URI path `EXACTLY` `/auth/login` | — | có | — | 50 |
| | **Tổng** | 977 | 977 | 927 | |

WCU theo [N16], [N17], [N18]; dưới 1 500 WCU mặc định của web ACL, không phụ phí [N23]. Luật có phí theo request (Bot Control, ATP) đứng cuối để
request đã bị chặn không tới chúng. Mỗi luật `visibility_config` có metric CloudWatch (WAF.12). Ba ACL giống hệt ở stg và prd (nhóm phải giống của
[0055](../0055-environment-matrix.md)). Logging: bucket log WAF có sẵn của Log Archive ([0060](../0060-org-detection-logging.md) §9), che `authorization`,
`cookie`.

- IP reputation: `AWSManagedIPReputationList`, `AWSManagedReconnaissanceList` block; `AWSManagedIPDDoSList` count theo mặc định của nhóm [N18].
- Known bad inputs: mẫu thử của phép kiểm edge là chuỗi `${jndi:ldap://example.com/}` (`Log4JRCE_*`) [N18].
- ATP ở api: `login_path` `/auth/login`; `request_inspection` `payload_type = "JSON"`, username `/email`, password `/password` (JSON pointer, theo
  `Credentials` của `services/gateway/openapi.yaml`); `response_inspection` `status_code`: thành công `200`, thất bại `401` ("Unknown email or wrong
  password (`INVALID_CREDENTIALS`)" của spec); 400 (body sai), 413, 429, 5xx không phải kết quả đăng nhập nên không vào hai danh sách. "ATP response
  inspection is available only in protection packs (web ACLs) that protect CloudFront distributions" [N16]. Luật mặc định block, trong đó
  `VolumetricIpHigh` (hơn 20 request mỗi 10 phút mỗi IP) và `VolumetricIpFailedLoginResponseHigh` (hơn 10 lần thất bại mỗi 10 phút) [N16]:
  `make eks-smoke`, `make eks-seed` đăng nhập vài lần, dưới ngưỡng; k6 không qua CloudFront.
- Web không có ATP: form đăng nhập gửi Server Action (`POST /login` với header `Next-Action`), React gửi `FormData` dạng `multipart/form-data`; ATP chỉ
  có "JSON payload type" và "FORM_ENCODED payload type" [N16], áp vào `/login` thì `SignalMissingCredential` chặn mọi lần đăng nhập. Server Action gọi
  gateway trong cluster (`GATEWAY_URL`), không qua distribution api, nên ATP của api không thấy. Phần còn lại: rate limit `login` của gateway theo IP
  và theo IP cộng email, với IP của §9.
- Bot Control ở web, mức `COMMON`: mọi luật của mức này mặc định block; nhóm "doesn't block these verified bots" (trừ `CategoryAI`) [N17]. Chưa
  chặn gì cho tới khi đo: AWS khuyên "test and tune the rules in count mode with your production traffic before enabling them" và theo dõi nhãn,
  metric trước khi thêm ngoại lệ [N33]; lab chưa có số đo lưu lượng bot nào, còn client kiểm từ VPN, máy cloud (`SignalKnownBotDataCenter`) hay
  trình duyệt tự động (`SignalAutomatedBrowser`) [N17] sẽ bị chặn nếu bật block trước khi đo. Không scope-down: 10 triệu request đầu mỗi tháng miễn
  phí [N23], phí Bot Control giữ ở bảng giá. api, media không Bot Control: client của API là script, app; media là player.
- Cả nhóm ở `count`, hai mức trên luật nhóm của web ACL; mọi luật khác của ACL giữ hành động:
  - `rule_action_override` `count` cho từng luật mức `COMMON` của [N17] (luật `TGT_*` thuộc mức targeted, không bật): `CategoryAdvertising`,
    `CategoryAI`, `CategoryArchiver`, `CategoryContentFetcher`, `CategoryEmailClient`, `CategoryHttpLibrary`, `CategoryLinkChecker`,
    `CategoryMiscellaneous`, `CategoryMonitoring`, `CategoryPagePreview`, `CategoryScrapingFramework`, `CategorySearchEngine`, `CategorySecurity`,
    `CategorySeo`, `CategorySocialMedia`, `CategoryWebhooks`, `SignalAutomatedBrowser`, `SignalKnownBotDataCenter`, `SignalNonBrowserUserAgent`.
    Đây là cách AWS ghi để thử một nhóm: "overriding some or all of the rule actions to Count, to test and monitor a rule group's behavior before
    putting it into production"; quy trình Bot Control chọn "Override all rule actions" là Count, khi đó "AWS WAF evaluates requests against all of
    the rules in the rule group and only counts the matches that result" mà vẫn gắn nhãn [N33]. Log WAF có nhãn của mọi luật khớp, đủ để đo ngoại lệ.
  - `override_action { count {} }`: "Set it to count to override the result to count only" [N34]. Một mình mức này không đủ để đo: nó "doesn't alter
    how AWS WAF evaluates the rule group itself" [N33], nên luật block đầu tiên khớp dừng nhóm, luật sau không chạy, thiếu nhãn. Nó giữ cho luật AWS
    thêm ở version sau, chưa có trong danh sách trên, cũng không chặn: luật nhóm không ghim `version` (như các nhóm managed khác của module), nên AWS
    "keeps the version at the vendor's default when the vendor updates the managed rule group settings" [N34].
  - Giá: module `waf` giữ danh sách tên luật theo [N17]. Với nhóm managed, "AWS WAF silently ignores any override that uses an invalid rule name"
    [N34]: tên sai hay luật mới chưa có tên không làm apply lỗi, chỉ thiếu nhãn của luật đó; [N17] thêm luật thì thêm tên vào danh sách.
- Client kiểm của dự án và Bot Control (nhóm ở `count`, nên không client nào bị Bot Control chặn):

  | Client | Chạy từ | Tới | Bot Control |
  | --- | --- | --- | --- |
  | Phép kiểm edge (`curl -sI`, mẫu thử WAF) | Máy người học (log gateway phải ra IP công khai của máy đó) | web, api, media | web: gắn nhãn (`CategoryHttpLibrary`, `SignalNonBrowserUserAgent`, có thể `SignalKnownBotDataCenter` khi qua VPN), không chặn |
  | `make eks-smoke`, `make eks-seed` (`curl`) | Máy người học (`aws/scripts/measure.sh`) | `https://api.<domain>` (`deploy/k8s/k8s.mk`), URL media | Không: api, media không có Bot Control |
  | e2e Playwright (`make web-e2e`, job `stack` của CI) | Máy, runner | compose, k3d (`e2e/stack.ts` của `svp-frontend`) | Không qua CloudFront |
  | k6 profile `cloud` | Pod trong cluster | ClusterIP `svp-envoy` (§10) | Không qua CloudFront |

- Bật block (ADR mới, sau buổi stg, prd đã đọc nhãn bot trong log WAF): `override_action { none {} }`, bỏ override `count` của luật cần chặn;
  luật bắt client kiểm hay người dùng hợp lệ giữ `count`, rồi theo cách AWS ghi
  [N32] "add a label matching rule ... after the Bot Control managed rule group" khớp nhãn của luật đó và block, trừ client kiểm (`NotStatement`);
  dấu hiệu nhận client (IP set, header) lấy từ log đã đo.
- `SizeRestrictions_BODY` ("request bodies that are over 8 KB" [N18]) thành `count` chỉ ở web: báo lỗi trình duyệt tới `/monitoring` dài tới 32 KiB
  (`maxReportBytes` của `frontend/server/sentry/monitoring.ts`), web tự giới hạn ở đó. api không override: body dài nhất theo spec (tên 200 ký tự,
  mật khẩu 128) dưới 1 KB, gateway từ chối trên 64 KiB. Body CloudFront gửi WAF xét tối đa 16 KB mặc định [N19].
- Luật CommonRuleSet khác chặn luồng hợp lệ thì thấy ở log WAF (`terminatingRuleId`); thêm override phải có lý do ở đây.

## §8. Log edge

### Bucket log CloudFront

`svp-cloudfront-<log>-us-east-1` của root `aws/log-archive`, khuôn bucket Log Archive ([0060](../0060-org-detection-logging.md) §7): chặn public,
`BucketOwnerEnforced`, chỉ TLS, SSE-KMS key `alias/svp-log-archive` ở `us-east-1`, versioning (version cũ hết hạn sau 1 ngày), retention 90 ngày,
rule tiền tố `AWSLogs/<stg>/` 7 ngày (như bucket log WAF). Root env suy tên theo khuôn đó như `log_archive_buckets.waf`. Permission set
`SvpLogReader` (`aws/org/identity-center.tf`, `local.log_bucket_arns`) thêm bucket này để `anhnv-log-ro` đọc được (đã có `kms:ViaService`
`s3.us-east-1.amazonaws.com`).

### Giao chéo account

"CloudFront supports sending access logs to different AWS accounts (cross accounts)" [N14]. Luồng của tài liệu [N14], [N15]: account đích tạo delivery
destination và gắn delivery destination policy ("If you are delivering logs cross-account, you must use PutDeliveryDestinationPolicy in the destination
account"), account nguồn tạo delivery source và `CreateDelivery` tới ARN destination. Tài liệu không có luồng nào đặt destination ở account nguồn.

| Account, region | Tài nguyên | Giá trị |
| --- | --- | --- |
| `svp-log-archive`, `us-east-1` | `aws_cloudwatch_log_delivery_destination` `svp-cloudfront-<env>` (một mỗi env) | `destination_resource_arn` = `arn:aws:s3:::svp-cloudfront-<log>-us-east-1/AWSLogs/<account env>/CloudFront`, `output_format = "parquet"` |
| `svp-log-archive`, `us-east-1` | `aws_cloudwatch_log_delivery_destination_policy` | Principal `AWS` = account env đó, `logs:CreateDelivery` trên ARN destination đó |
| `svp-log-archive` | Bucket policy | `delivery.logs.amazonaws.com`: `s3:PutObject` trên `AWSLogs/*` với `s3:x-amz-acl` = `bucket-owner-full-control`, `aws:SourceOrgID` = org, `aws:SourceArn` khớp `arn:aws:logs:us-east-1:*:delivery-source:*` |
| `svp-log-archive`, `us-east-1` | Key policy `alias/svp-log-archive` | `delivery.logs.amazonaws.com`: `kms:Encrypt`, `kms:Decrypt`, `kms:ReEncrypt*`, `kms:GenerateDataKey*`, `kms:DescribeKey` với `aws:SourceOrgID` |
| env, `us-east-1` | `aws_cloudwatch_log_delivery_source` mỗi distribution có log | `log_type = "ACCESS_LOGS"`, `resource_arn` distribution, tên bằng tên distribution |
| env, `us-east-1` | `aws_cloudwatch_log_delivery` | `delivery_destination_arn` = `arn:aws:logs:us-east-1:<log>:delivery-destination:svp-cloudfront-<env>` (suy từ tên), `record_fields` dưới đây, `s3_delivery_configuration`: `suffix_path = "{DistributionId}/{yyyy}/{MM}/{dd}/{HH}"`, `enable_hive_compatible_path = true` |

- Tiền tố trong ARN đích: "the destination prefix replaces, rather than precedes, that default path" (`AWSLogs/<account>/CloudFront`) [N15]; ví dụ bucket
  có tiền tố cộng suffix ra `<bucket>/<tiền tố>/<suffix>/` [N14]. Mỗi env một tiền tố mang id account của nó, nên rule lifecycle stg khớp và account
  này không ghi được vào tiền tố của account kia. Đường thật của object (cách biến suffix hiện ở dạng Hive) kiểm ở buổi đầu.
- Module `edge`, `media` nhận ARN destination, không nhận ARN bucket; root env suy ARN đó từ tên, như `log_archive_buckets.waf`. Policy của mỗi
  destination cần id account env: root `aws/log-archive` có biến `prd_account_id` cạnh `stg_account_id`, cùng cách truyền (README của root).
- Bucket policy, key policy theo [N14] (`delivery.logs.amazonaws.com`, `bucket-owner-full-control`, `aws:SourceArn` của delivery source), thay
  `aws:SourceAccount` bằng `aws:SourceOrgID` như bucket log WAF, flow log.
- Không logging legacy: "Your bucket must have access control list (ACL) enabled" và giao bằng account `awslogsdelivery` [N14], trái
  `BucketOwnerEnforced`. Không real-time log (Kinesis, không cần).
- Định dạng Parquet và đường kiểu Hive như flow log ([0060](../0060-org-detection-logging.md) §9): Athena đọc cùng khuôn; Parquet có phí chuyển của
  CloudWatch [N14], [N23]. Định dạng chỉ đặt được lúc tạo destination [N14].
- Media của stg (gói Free) không có log: gói Free không gồm access log [N25]; FSBP CloudFront.5 FAILED ở đó, chấp nhận (§14).

### `record_fields`

Danh sách tường minh, cùng thứ tự, dùng chung ở module `edge` và `media`: danh sách `recordFields` của ví dụ trong tài liệu standard logging v2
(35 trường) [N14] trừ `cs(Cookie)`. Tài liệu không nói trường nào giao khi bỏ `recordFields` [N14], [N15], nên danh sách viết ra:

`date`, `time`, `x-edge-location`, `sc-bytes`, `c-ip`, `cs-method`, `cs(Host)`, `cs-uri-stem`, `sc-status`, `cs(Referer)`, `cs(User-Agent)`,
`cs-uri-query`, `x-edge-result-type`, `x-edge-request-id`, `x-host-header`, `cs-protocol`, `cs-bytes`, `time-taken`, `x-forwarded-for`,
`ssl-protocol`, `ssl-cipher`, `x-edge-response-result-type`, `cs-protocol-version`, `fle-status`, `fle-encrypted-fields`, `c-port`,
`time-to-first-byte`, `x-edge-detailed-result-type`, `sc-content-type`, `sc-content-len`, `sc-range-start`, `sc-range-end`, `c-country`,
`cache-behavior-path-pattern` (34 trường).

- `cs(Cookie)` bỏ: "CloudFront logs the cookies in all requests regardless of which cookies you choose to forward to the origin" [N14], tức cookie phiên
  của web; WAF cũng che `cookie`. Trường bắt buộc của nguồn (nếu có, `DescribeConfigurationTemplates` [N15]) phải có trong danh sách; apply lỗi
  thì thêm đúng trường đó, không thêm `cs(Cookie)`.
- `cs-uri-query`: api chỉ có `cursor`, `page_size` (`in: query` của `services/gateway/openapi.yaml`); web có `next` (một path nội bộ), `_rsc`
  (khoá cache của Next), `cursor`; media không query; upload presigned POST đi thẳng tới S3, không qua CloudFront. Không token nào trong query.
- `c-ip`, `x-forwarded-for` (giá trị viewer tự gửi), `cs(User-Agent)`, `cs(Referer)` là dữ liệu cá nhân hay do client đặt: giữ vì điều tra cần,
  retention như log WAF, chỉ `SvpLogReader` đọc.

## §9. IP client

### Header địa chỉ người xem

- "Contains the IP address of the viewer and the source port of the request", ví dụ `198.51.100.10:46532`; "CloudFront-Viewer-Address and
  CloudFront-Viewer-ASN can be added in an origin request policy, but not in a cache policy" [N2]. Origin request policy của §2 có nó [N3].
- IPv6: tài liệu không có ví dụ; giá trị quan sát được là địa chỉ IPv6 không ngoặc vuông, cổng sau dấu `:` cuối (`2001:…:60776`) [N24].
- Giá trị viewer tự gửi: "If the viewer request includes headers that have these names, and you configured CloudFront to add these headers using a
  cache policy or origin request policy, then CloudFront overwrites the header values that were in the viewer request" [N31]; "these names" là các
  header CloudFront của trang [N2], trong đó có `CloudFront-Viewer-Address`, và origin request policy của §2 thêm nó [N3]. Phép kiểm edge vẫn gửi
  `CloudFront-Viewer-Address` tự đặt và đọc log gateway: IP của máy người học là đạt; nếu header viewer tới cùng giá trị CloudFront (hai giá trị)
  thì gateway lấy địa chỉ kết nối (IP pod Envoy hay web), cũng lộ ra ở phép kiểm.

### IP client ở gateway

- Biến mới `TRUSTED_CLIENT_ADDRESS_HEADER` (tên header). Khi đặt: chỉ trên kết nối từ `TRUSTED_PROXY_CIDRS`, ClientAddr lấy IP từ header đó; đúng một
  giá trị; bỏ cổng ở dấu `:` cuối, nhận cả `[v6]:port`; thiếu, nhiều giá trị hay không parse được thì địa chỉ kết nối; không đọc `X-Forwarded-For`.
  Khởi động lỗi, nêu tên biến, khi `TRUSTED_PROXY_CIDRS` rỗng hay `TRUSTED_PROXY_HOPS` khác 0. Khi không đặt: hành vi `X-Forwarded-For` hiện có.
- compose, k3d không đặt; eks (`gitops/platforms/eks/gateway.values.tpl`): `TRUSTED_CLIENT_ADDRESS_HEADER: CloudFront-Viewer-Address`,
  `TRUSTED_PROXY_HOPS: "0"`, `TRUSTED_PROXY_CIDRS` là CIDR VPC (pod Envoy, web có IP trong VPC).
- Rate limit theo IP và `client.address` của span dùng chung ClientAddr, như hiện có.

### BFF chuyển header

Web chuyển nguyên header `cloudfront-viewer-address` của request tới (khi có) trong mọi lời gọi gateway, cạnh `x-forwarded-for` đang chuyển; không
đọc, không parse. Envoy chuyển header của CloudFront tới web như mọi header khác.

### Ai đặt được header gateway tin

| Chặng | Chỉ nhận từ | Giữ bằng |
| --- | --- | --- |
| gateway | Envoy, web | NetworkPolicy của gateway (có sẵn) |
| web | Envoy | NetworkPolicy của web (có sẵn) |
| Envoy | ALB (dải subnet edge), Job k6 (`svp-load`) | NetworkPolicy `envoy` (§4); không pod nào có IP ở dải edge (§3) |
| ALB | CloudFront | ALB internal, SG theo prefix list origin-facing (§3) |
| CloudFront | viewer | Đè `CloudFront-Viewer-Address` mà viewer tự gửi [N31] |

Ngoại lệ duy nhất là Job k6 (§10). Threat model RL-1, RL-7 tả chuỗi này.

## §10. Đo tải trong cluster

- Job k6 `svp-k6` (namespace `svp-load`, `deploy/k6/cloud/`, người học chạy trong buổi) đi thẳng tới ClusterIP của Service `svp-envoy`, không qua
  CloudFront, WAF: tải 1 250 req/s từ vài IP NAT chạm luật rate-based của WAF và mọi giới hạn theo IP.
- Mỗi pod đặt `CloudFront-Viewer-Address: <IP pod>:0` (downward API `status.podIP`) thay `X-Forwarded-For` 2 hop đã bỏ, nên mỗi pod một bucket như
  RL-7. Pod tin CA nội bộ của Envoy: `run.sh` đọc đúng khoá `ca.crt` của Secret `svp-edge-tls` (jsonpath, không in khoá riêng), truyền `--ca-file`.
  Cờ `--forwarded-for` và biến `SVP_K6_FORWARDED_FOR` bỏ (không cluster nào tin 2 hop).
- Chấp nhận: pod trong `svp-load` chọn được IP mà gateway tin. Namespace chỉ có trong buổi đo, do người học tạo; người khác không có quyền tạo
  namespace. Xem lại khi có người thứ hai được tạo namespace hay workload trong cluster.

## §11. DNS

### DNS env

Root `aws/envs/<env>`, sống và gỡ theo buổi: A và AAAA alias `<domain>` tới `svp-<env>-web`, `api.<domain>` tới `svp-<env>-api` (module `edge`),
`media.<domain>` tới `svp-<env>-media` (module `media`); record CNAME validation ACM, mỗi tên một lần (§5). Truy vấn alias không tính phí [N23].
ExternalDNS rời nền tảng eks (component, values, namespace, AppProject, role Pod Identity): không còn gì trong cluster ghi zone. Bảng công cụ của lộ
trình (dòng AWS có "Load Balancer Controller, ExternalDNS") nên bỏ ExternalDNS; Load Balancer Controller ở lại cho `TargetGroupBinding`.

### DNS zone

Module `account-baseline`, root `aws/accounts/<env>`, sống lâu.

- CAA ở đỉnh zone của cả hai env (`aws.<miền>`, `stg.aws.<miền>`): tám giá trị `0 issue "<ca>"`, `0 issuewild "<ca>"` với `<ca>` là `amazon.com`,
  `amazontrust.com`, `awstrust.com`, `amazonaws.com` ("one of the following four Amazon CAs" [N12]; `issuewild` không có CA của ACM thì ACM không phát
  hành wildcard [N12]). CA tìm CAA của một tên ngược lên tên cha tới khi gặp [N30], nên đỉnh mỗi zone là đủ; zone stg là zone riêng nên cần CAA riêng.
- DNSSEC (biến `dnssec_enabled`, chỉ prd `true`):
  - KMS key `us-east-1`, `customer_master_key_spec = "ECC_NIST_P256"`, `key_usage = "SIGN_VERIFY"`, `prevent_destroy` ("The customer managed key that
    you use with DNSSEC signing must be in the US East (N. Virginia) Region", "an asymmetric customer managed key with an ECC_NIST_P256 key spec" [N20]).
    Key bất đối xứng không xoay tự động.
  - Key policy theo [N20]: `dnssec-route53.amazonaws.com` được `kms:DescribeKey`, `kms:GetPublicKey`, `kms:Sign` với `aws:SourceAccount` = `<prd>`,
    `aws:SourceArn` khớp `arn:aws:route53:::hostedzone/*`; `kms:CreateGrant` với `kms:GrantIsForAWSResource` = `true`; quản trị key bởi IAM của account.
  - `aws_route53_key_signing_key` (`ACTIVE`) và `aws_route53_hosted_zone_dnssec`.
  - Alarm ở `us-east-1`, namespace `AWS/Route53`, dimension `HostedZoneId` [N20], theo luật "Alarm dịch vụ managed" của `svp-infra` (tên
    `svp-<env>-<alarm>`, tag `Severity`): `svp-prd-dnssec-internal-failure` (`DNSSECInternalFailure`, "1 if any object in the hosted zone is in an
    INTERNAL_FAILURE state") và `svp-prd-dnssec-ksk-action-needed` (`DNSSECKeySigningKeysNeedingAction`, "Number of key signing keys (KSKs) that have
    an ACTION_NEEDED state (due to KMS failure)"), Sum ≥ 1; cả hai `Severity = page`: KSK `ACTION_NEEDED` "eventually cause a zone outage", và Route
    53 khuyên alarm cho cả hai [N20]. Description mang URL runbook `https://github.com/anhnvcoder/svp-backend/blob/main/docs/runbooks/dnssec-internal-failure.md`,
    `…/dnssec-ksk-action-needed.md`. Gửi topic của module `alarms` (thêm biến `region` tuỳ chọn, mặc định region của provider) với email
    `alarm_email` (biến sensitive mới của `prd.auto.tfvars` root accounts).
  - Trước khi ký: hạ TTL lớn nhất của zone về 3 600 giây, hạ TTL và minimum của SOA, chờ hết TTL lớn nhất cũ; TTL của `DS` ở cha 300 giây để lùi
    nhanh [N20]. Runbook `edge-setup.md` ghi bước này.
- Query log (biến `query_log_enabled`, chỉ prd `true`): log group `us-east-1` ("The log group must be in the US East (N. Virginia) Region" [N21])
  tên `/aws/route53/<zone>`, retention 90 ngày (như log mạng của prd, [0060](../0060-org-detection-logging.md) §7), resource policy của CloudWatch Logs
  cho `route53.amazonaws.com` (`logs:CreateLogStream`, `logs:PutLogEvents` trên log group đó) với `aws:SourceAccount` = `<prd>`, `aws:SourceArn` của
  zone (khuôn chống confused deputy; trang query log chỉ nói cấp quyền và giới hạn 10 resource policy mỗi region [N21]). Route 53 không tính phí
  query log, chỉ phí CloudWatch Logs [N21].
- stg không DNSSEC, không query log: DNSSEC và query log cho "zone prd" (người học chốt); Route53.2 FAILED ở zone stg, chấp nhận (§14).

### Tắt ký DNSSEC

- Biến `dnssec_signing` (bool, mặc định `true`, chỉ có nghĩa khi `dnssec_enabled`) đặt `signing_status` của `aws_route53_hosted_zone_dnssec` là
  `SIGNING`/`NOT_SIGNING`; KSK luôn `ACTIVE`, key KMS giữ nguyên: đổi KSK sang `INACTIVE` cùng lượt apply bị Route 53 từ chối khi zone còn ký
  (Terraform cập nhật KSK trước tài nguyên phụ thuộc nó). Root `aws/accounts/prd` có biến `dnssec_signing` (mặc định `true`) truyền vào module.
- Đường lui (runbook alarm, `edge-setup.md`), theo thứ tự của tài liệu [N20]: gỡ `DS` của `aws` ở DNS cha, chờ TTL của `DS`, rồi
  `terraform apply -var dnssec_signing=false` ở `aws/accounts/prd`, sau đó PR đổi mặc định của root thành `false` để lượt apply sau không ký lại.
- Gỡ hẳn (hiếm): sau khi zone `NOT_SIGNING`, `terraform state rm` đúng địa chỉ key KMS và alias của nó (README module ghi địa chỉ), rồi
  `dnssec_enabled = false` (Terraform xoá DNSSEC của zone trước, KSK sau), rồi người học
  `aws kms schedule-key-deletion --pending-window-in-days 30 --region us-east-1`. Không bao giờ đặt `dnssec_enabled = false` khi key còn trong state
  (`prevent_destroy` làm plan lỗi).

### Chuỗi tin cậy

Hiện trạng 2026-11-12 (đọc bằng `dig` công khai): `DNSKEY` của `<miền>` rỗng, TLD không có `DS` của `<miền>`; zone `aws.<miền>` được uỷ quyền đúng.
`DS` của `aws` chỉ có nghĩa khi `<miền>` đã ký và TLD có `DS` của nó. Nhà cung cấp DNS cha cho thêm `DS` cho tên con. Người học chọn chuỗi đầy đủ:

1. Bật DNSSEC cho `<miền>` ở nhà cung cấp DNS cha, đặt `DS` của `<miền>` ở registrar của TLD; kiểm `dig +dnssec DS <miền>`.
2. Zone `aws.<miền>` ký ở Route 53 (§12 bước 2), chờ KSK `ACTIVE`, lấy `DS` (`aws route53 get-dnssec`).
3. Thêm `DS` `aws` (TTL 300) ở zone `<miền>`; kiểm `dig +dnssec aws.<miền>` có cờ `ad` qua resolver kiểm DNSSEC, `delv`.

Gỡ theo thứ tự ngược: `DS` `aws` ở zone cha trước (rồi Tắt ký), DNSSEC của `<miền>` sau.

## §12. Thứ tự áp lần đầu

Người học chạy, sau khi PR `svp-gitops` (values eks, bỏ ACME) và PR `svp-infra` merge; lệnh viết sẵn ở `docs/runbooks/edge-setup.md`:

1. `aws/log-archive` apply (bucket log CloudFront, delivery destination và policy), rồi `aws/org` apply (`SvpLogReader` đọc bucket mới).
2. `aws/accounts/stg`, `aws/accounts/prd` apply (CAA, query log, topic SNS và alarm, DNSSEC ký zone), xác nhận email SNS. CAA chặn Let's Encrypt, nên
   bước này chỉ sau khi PR `svp-gitops` bỏ issuer ACME đã merge.
3. Chuỗi tin cậy (§11): `<miền>` ký và có `DS` ở TLD; chờ KSK `ACTIVE`; thêm `DS` `aws` ở DNS cha; kiểm `dig +dnssec`, `delv`.
4. Buổi stg, prd theo runbook buổi, chạy phép kiểm edge.

Gỡ DNSSEC theo "Tắt ký DNSSEC" ở cùng runbook.

## §13. Chi phí edge

### Bảng giá

| Dịch vụ | Mục | Giá (USD) | Nguồn |
| --- | --- | --- | --- |
| WAF | Web ACL | 5,00 mỗi tháng, tính theo giờ | [N23] WAF ("Monthly fees are prorated hourly") |
| WAF | Luật hay nhóm luật managed | 1,00 mỗi tháng, tính theo giờ | [N23] WAF |
| WAF | Request | 0,60 mỗi triệu | [N23] WAF (ví dụ giá) |
| WAF | Bot Control `COMMON` | 10,00 mỗi tháng mỗi ACL; 1,00 mỗi triệu request sau 10 triệu đầu mỗi tháng | [N23] WAF |
| WAF | ATP | 10,00 mỗi tháng mỗi ACL; phí theo request phân tích (ví dụ giá: 1 000 mỗi triệu, tức 1 mỗi 1 000 lần đăng nhập; 10 000 request đầu miễn phí) | [N23] WAF |
| ALB | `ap-southeast-1` | 0,0252 mỗi giờ; 0,008 mỗi LCU-giờ | [N27] Price List `AWSELB` (phát hành 2026-11-11) |
| NLB (bỏ) | `ap-southeast-1` | 0,0252 mỗi giờ; 0,006 mỗi NLCU-giờ | [0048](../0048-prd-aws.md) phụ lục §10 |
| CloudFront | Pay-as-you-go miễn phí mãi | 1 TB ra Internet, 10 triệu request HTTP/HTTPS mỗi tháng | [N23] CloudFront |
| CloudFront | Vượt hạn mức (Mỹ, châu Âu / châu Á) | 0,085 / 0,120 mỗi GB; HTTPS 0,0100 / 0,0120 mỗi 10 000 | [N23] CloudFront |
| CloudFront | VPC origin | Không phí riêng | [N23] CloudFront |
| ACM | Cert công khai cho dịch vụ tích hợp | 0; exportable 7 mỗi tên mỗi lần phát hành | [N23] ACM |
| Route 53 | Truy vấn alias tới CloudFront; ký DNSSEC; query log | 0 (phí KMS, CloudWatch Logs riêng) | [N23] Route 53 |
| KMS | Key (đối xứng hay bất đối xứng) | 1,00 mỗi tháng, tính theo giờ | [N23] KMS |
| KMS | `Sign` bất đối xứng ECC | 0,15 mỗi 10 000 (ví dụ giá), không nằm trong hạn mức miễn phí | [N23] KMS |
| CloudWatch | Alarm độ phân giải chuẩn | 0,10 mỗi alarm mỗi tháng | [N23] CloudWatch |
| CloudWatch Logs | Ingest; lưu | 0,50 mỗi GB; 0,03 mỗi GB-tháng | [N23] CloudWatch (ví dụ giá) |
| CloudWatch vended log | Giao S3 `us-east-1`; chuyển Parquet | 0,25 mỗi GB; 0,049 mỗi GB | Price List `AmazonCloudWatch`, [0060](../0060-org-detection-logging.md) phụ lục §12 |
| S3 | Standard | 0,025 mỗi GB-tháng | [0060](../0060-org-detection-logging.md) phụ lục §12 |

### Thêm mỗi buổi

Một buổi 4 giờ (730 giờ mỗi tháng); CloudFront trong hạn mức miễn phí của account.

| Khoản | stg | prd |
| --- | --- | --- |
| WAF phí cố định: web ($5 ACL + 5 luật + $10 Bot Control = $20), api ($5 + 5 luật + $10 ATP = $20), media prd ($5 + 4 luật = $9; stg trong gói Free) × 4/730 | 0,22 | 0,27 |
| WAF request (~50 000 × 0,60/triệu), ATP (vài lần đăng nhập), Bot Control (dưới 10 triệu) | 0,03 | 0,03 |
| ALB: (0,0252 + ~1 LCU × 0,008) × 4 | 0,13 | 0,13 |
| Log v2 (~50 MB × (0,25 + 0,049)), query log prd (vài MB × 0,50) | 0,02 | 0,03 |
| Item Config của ~30 tài nguyên edge mới (tạo, xoá) × 0,003 | 0,09 | 0,09 |
| **Cộng** | **~0,5** | **~0,55** |
| NLB đã bỏ: (0,0252 + ~1 NLCU × 0,006) × 4 | −0,12 | −0,12 |

Khoản lớn nhất là phí cố định của WAF. Dưới ngưỡng $5 mỗi buổi.

### Lúc không buổi

| Khoản | Tháng (USD) |
| --- | --- |
| Key KMS DNSSEC (`us-east-1`, prd) | 1,00 |
| Key KMS của topic SNS alarm ở `us-east-1` (module `alarms`, prd) | 1,00 |
| `Sign` của Route 53 (vài nghìn mỗi tháng × 0,15/10 000) | < 0,05 |
| Hai alarm DNSSEC | 0,20 |
| Query log prd (truy vấn của resolver, vài MB) và lưu 90 ngày | < 0,05 |
| Bucket log CloudFront (dưới 1 GB) | < 0,05 |
| CAA, zone, Config, Security Hub của vài tài nguyên sống lâu | ~0,05 |
| **Cộng** | **~2,4** |

Dưới ngưỡng $5 mỗi tháng. Khoản lớn nhất là hai key KMS.

## §14. Khác biệt stg/prd

| Thành phần | stg | prd | Nhóm ([0055](../0055-environment-matrix.md)) | Lý do |
| --- | --- | --- | --- | --- |
| Distribution web, api; VPC origin; ALB; subnet edge; ba web ACL; cert ACM; TLS policy; response headers; log v2 của web, api; CAA | như prd | như bảng §2–§8 | Phải giống | stg phải chạy đúng edge của prd |
| Gói CloudFront của media | Free | pay-as-you-go | Được giảm | $0 mỗi buổi; mất: access log, header tự viết của media (kiểm ở buổi prd) |
| Access log media | không | có | Được giảm (theo gói) | Gói Free không có access log; CloudFront.5 FAILED ở stg |
| DNSSEC zone | không | có | Được giảm | Người học chốt "zone prd"; zone stg là zone con, không có `DS` thì không chuỗi tin cậy; kiểm ở prd |
| Query log zone | không | có | Được giảm | Như trên; Route53.2 FAILED ở stg |
| Deletion protection ALB | `false` | `true` (`teardown.tfvars` `false`) | Được giảm (bảo vệ xoá) | Như mọi bảo vệ xoá của stg |

Bảng đủ của mọi thành phần ở `docs/explanation/environments.md`.

## Phép kiểm edge

Runbook buổi kiểm:

- `curl -sI` web, api, media có HSTS, nosniff, cert ACM đúng tên, TLS ≥ 1.2.
- Tên ALB ra IP private.
- Mẫu thử KnownBadInputs nhận 403 ở web, api.
- Log gateway có IP công khai của máy người học, kể cả khi tự đặt `CloudFront-Viewer-Address`, `X-Forwarded-For`.
- Object mới trong bucket log CloudFront và bucket log WAF.
- `dig +dnssec` có cờ `ad`; `dig CAA`.
- Plan lần hai `No changes`; sau destroy `sweep.sh <env>` sạch.

## Bảng control FSBP

Control của Security Hub CSPM áp lên tài nguyên mới. "FSBP" là có trong chuẩn AWS Foundational Security Best Practices v1.0.0 [N22].

| Control | Tiêu đề (tóm tắt) | FSBP | Kết quả | Lý do |
| --- | --- | --- | --- | --- |
| CloudFront.1 | Có default root object | có | Chấp nhận (dự kiến FAILED) | web: `/` là trang chủ của Next; api không có `/`; media: bucket riêng tư, OAC, `/` trả lỗi của S3, không liệt kê |
| CloudFront.3 | Bắt buộc mã hoá khi truyền | có | Đạt | `redirect-to-https`, `https-only` |
| CloudFront.4 | Có origin failover | có | Chấp nhận | Một region, một ALB; failover origin cần origin thứ hai. Xem lại khi cần HA đa region |
| CloudFront.5 | Bật logging | có | Đạt ở web, api, media prd (kiểm control nhận log v2 ở buổi đầu); chấp nhận ở media stg | Media stg gói Free; logging legacy đòi ACL bucket, trái `BucketOwnerEnforced` |
| CloudFront.6 | Có WAF | có | Đạt | §7 |
| CloudFront.7 | Cert tự có | có | Đạt | Cert ACM mỗi alias |
| CloudFront.8 | Dùng SNI | có | Đạt | `sni-only` |
| CloudFront.9 | Mã hoá tới custom origin | có | Đạt | VPC origin `https-only` |
| CloudFront.10 | Không SSL cũ tới custom origin | có | Đạt | `TLSv1.2` |
| CloudFront.12 | Không trỏ S3 không tồn tại | có | Đạt | Bucket `media` cùng buổi |
| CloudFront.13 | OAC cho S3 | có | Đạt (media); không áp (web, api) | |
| CloudFront.15 | TLS policy khuyên dùng | có | Đạt | `TLSv1.2_2025` nằm trong `TLSv1.2_2025,TLSv1.3_2025` |
| CloudFront.16 | OAC cho Lambda URL | có | Không áp | Không Lambda |
| CloudFront.17 | Key group cho URL, cookie ký | có | Không áp | Không URL ký |
| WAF.10 | Web ACL có ít nhất một luật | có | Đạt | 4–5 luật |
| WAF.11 | Web ACL có logging | không | Đạt | Bucket log WAF |
| WAF.12 | Luật có metric CloudWatch | có | Đạt | `visibility_config` mọi luật |
| ACM.1 | Gia hạn trước 30 ngày | có | Đạt | ACM tự gia hạn cert DNS validation khi record còn |
| ACM.2 | Cert RSA ≥ 2 048 bit | có | Không áp | ECDSA P-256 |
| Route53.2 | Zone công khai ghi query log | có | Đạt ở prd; chấp nhận ở stg | §14 |
| ELB.1 | ALB chuyển HTTP sang HTTPS | có | Đạt | Không listener HTTP |
| ELB.4 | ALB bỏ header không hợp lệ | có | Đạt | `drop_invalid_header_fields = true` |
| ELB.5 | ALB bật logging | có | Chấp nhận | §3: mọi request đã ở log CloudFront, WAF |
| ELB.6 | Deletion protection | có | Đạt ở prd; chấp nhận ở stg | §14; `teardown.tfvars` tắt lúc gỡ |
| ELB.12 | Desync `defensive` hay `strictest` | có | Đạt | `defensive` |
| ELB.13 | Trải nhiều AZ | có | Đạt | Subnet edge mỗi AZ |
| ELB.16 | ALB gắn web ACL | không | Chấp nhận | WAF ở CloudFront |
| ELB.17 | Listener dùng policy khuyên dùng | có | Đạt | `ELBSecurityPolicy-TLS13-1-2-Res-PQ-2025-09` |
| ELB.18 | Listener dùng giao thức an toàn | có | Đạt | HTTPS |
| ELB.21 | Health check mã hoá | có | Chấp nhận | Readiness 19003 của Envoy chỉ HTTP, trong VPC từ dải edge tới pod, không dữ liệu nhạy cảm |
| ELB.22 | Target group mã hoá | có | Đạt | HTTPS 443 |
| EC2.21 | NACL không mở 22, 3389 từ Internet | có | Đạt | NACL edge chỉ nhận từ CIDR VPC |

Key KMS DNSSEC bất đối xứng: không xoay tự động; control xoay key của KMS chỉ xét key đối xứng.

## Bảng luồng RCP

Đối chiếu luồng mới với RCP `svp-data-perimeter` ([0059](../0059-org-structure-guardrails.md) §4, bảng ở phụ lục 0059): RCP phủ S3, KMS, Secrets
Manager, SQS, STS; luồng chạm dịch vụ khác nằm ngoài phạm vi RCP.

| Luồng | Principal | Tài nguyên | Qua nhờ |
| --- | --- | --- | --- |
| Giao log CloudFront v2 vào bucket log CloudFront | `delivery.logs.amazonaws.com` | S3, KMS `us-east-1` của `svp-log-archive` | Principal dịch vụ; `aws:SourceAccount` là stg, prd, nên `aws:SourceOrgID` là org |
| Tạo delivery tới destination của `svp-log-archive` | `SvpAdmin` của stg, prd (Terraform) | CloudWatch Logs `svp-log-archive` | Ngoài phạm vi RCP (CloudWatch Logs); delivery destination policy cho account env |
| Route 53 ký zone bằng key KMS | `dnssec-route53.amazonaws.com` | KMS `us-east-1` của prd | Principal dịch vụ; `aws:SourceAccount` là prd, trong org |
| Route 53 tạo grant trên key DNSSEC | `dnssec-route53.amazonaws.com` | KMS `us-east-1` của prd | Như dòng trên |
| CloudFront VPC origin tới ALB, ENI do dịch vụ quản | CloudFront | ELB, EC2 (ENI) | Ngoài phạm vi RCP |
| CloudFront dùng cert ACM `us-east-1`; ALB dùng cert ACM region nhà | CloudFront, ELB | ACM | Ngoài phạm vi RCP |
| Load Balancer Controller đăng ký target (`TargetGroupBinding`) | Role Pod Identity của controller | ELB | Ngoài phạm vi RCP; nhận role qua STS như dòng Pod Identity của 0059 |
| Query log Route 53 | `route53.amazonaws.com` | CloudWatch Logs `us-east-1` của prd | Ngoài phạm vi RCP |
| Alarm DNSSEC tới topic SNS mã hoá CMK `us-east-1` | `cloudwatch.amazonaws.com` | KMS `us-east-1` của prd | Principal dịch vụ; `aws:SourceAccount` trong org (như dòng alarm của 0059) |
| Ghi log WAF của ACL web, api | `delivery.logs.amazonaws.com` | S3, KMS `us-east-1` của `svp-log-archive` | Như dòng log WAF có sẵn của 0059 |
| Đọc log CloudFront | `SvpLogReader` | S3, KMS của `svp-log-archive` | Principal trong org |
| CloudFront OAC đọc `media` | `cloudfront.amazonaws.com` | S3 `media` | Như dòng có sẵn của 0059 |

Không luồng nào cần ngoại lệ RCP. Không access log ALB, nên vẫn không luồng nào cần `aws:PrincipalAccount`.

## Nguồn

- [N1] CloudFront, Restrict access with VPC origins: <https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/private-content-vpc-origins.html>;
  prefix list origin-facing: <https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/LocationsOfEdgeServers.html>
- [N2] CloudFront, Add CloudFront request headers: <https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/adding-cloudfront-headers.html>
- [N3] CloudFront, managed origin request policies: <https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/using-managed-origin-request-policies.html>
- [N4] CloudFront, managed cache policies: <https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/using-managed-cache-policies.html>
- [N5] CloudFront, supported protocols and ciphers between viewers and CloudFront:
  <https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/secure-connections-supported-viewer-protocols-ciphers.html>
- [N6] CloudFront, requirements for using SSL/TLS certificates: <https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/cnames-and-https-requirements.html>
- [N7] ALB, security policies: <https://docs.aws.amazon.com/elasticloadbalancing/latest/application/describe-ssl-policies.html>
- [N8] ALB, subnets và thuộc tính: <https://docs.aws.amazon.com/elasticloadbalancing/latest/application/application-load-balancers.html>;
  desync mitigation: <https://docs.aws.amazon.com/elasticloadbalancing/latest/application/edit-load-balancer-attributes.html>
- [N9] ALB, target groups (không kiểm cert target): <https://docs.aws.amazon.com/elasticloadbalancing/latest/application/load-balancer-target-groups.html>
- [N10] AWS re:Post, "Does ALB send SNI information in TLS handshake to a back-end server":
  <https://repost.aws/questions/QUOg0LUwafRFaorbsrYDP7xA/does-alb-send-sni-information-in-tls-handshake-to-a-back-end-server>
- [N11] ALB, SSL certificates: <https://docs.aws.amazon.com/elasticloadbalancing/latest/application/https-listener-certificates.html>
- [N12] ACM, CAA records: <https://docs.aws.amazon.com/acm/latest/userguide/setup-caa.html>
- [N13] ACM, DNS validation: <https://docs.aws.amazon.com/acm/latest/userguide/dns-validation.html>; thuật toán khoá:
  <https://docs.aws.amazon.com/acm/latest/userguide/acm-certificate.html>
- [N14] CloudFront, standard logging (v2): <https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/standard-logging.html>; trường log:
  <https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/standard-logs-reference.html>; logging legacy:
  <https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/standard-logging-legacy-s3.html>
- [N15] CloudWatch Logs, giao chéo account: <https://docs.aws.amazon.com/AmazonCloudWatch/latest/logs/vended-logs-crossaccount-example.html>; khoá
  object S3: <https://docs.aws.amazon.com/AmazonCloudWatch/latest/logs/AWS-logs-infrastructure-V2-S3.html>; API:
  <https://docs.aws.amazon.com/AmazonCloudWatchLogs/latest/APIReference/API_CreateDelivery.html>,
  <https://docs.aws.amazon.com/AmazonCloudWatchLogs/latest/APIReference/API_DescribeConfigurationTemplates.html>
- [N16] AWS WAF, ATP: <https://docs.aws.amazon.com/waf/latest/developerguide/aws-managed-rule-groups-atp.html>,
  <https://docs.aws.amazon.com/waf/latest/developerguide/waf-atp-rg-using.html>
- [N17] AWS WAF, Bot Control: <https://docs.aws.amazon.com/waf/latest/developerguide/aws-managed-rule-groups-bot.html>
- [N18] AWS WAF, baseline (Core rule set, Known bad inputs): <https://docs.aws.amazon.com/waf/latest/developerguide/aws-managed-rule-groups-baseline.html>;
  IP reputation: <https://docs.aws.amazon.com/waf/latest/developerguide/aws-managed-rule-groups-ip-rep.html>
- [N19] AWS WAF, body inspection limit: <https://docs.aws.amazon.com/waf/latest/developerguide/web-acl-setting-body-inspection-limit.html>
- [N20] Route 53, DNSSEC: <https://docs.aws.amazon.com/Route53/latest/DeveloperGuide/dns-configuring-dnssec.html>,
  <https://docs.aws.amazon.com/Route53/latest/DeveloperGuide/dns-configuring-dnssec-cmk-requirements.html>,
  <https://docs.aws.amazon.com/Route53/latest/DeveloperGuide/access-control-managing-permissions.html>,
  <https://docs.aws.amazon.com/Route53/latest/DeveloperGuide/dns-configuring-dnssec-enable-signing.html>,
  <https://docs.aws.amazon.com/Route53/latest/DeveloperGuide/dns-configuring-dnssec-disable.html>,
  <https://docs.aws.amazon.com/Route53/latest/DeveloperGuide/dns-configuring-dnssec-troubleshoot.html>; metric:
  <https://docs.aws.amazon.com/Route53/latest/DeveloperGuide/monitoring-hosted-zones-with-cloudwatch.html>
- [N21] Route 53, public DNS query logging: <https://docs.aws.amazon.com/Route53/latest/DeveloperGuide/query-logs.html>
- [N22] Security Hub CSPM, FSBP: <https://docs.aws.amazon.com/securityhub/latest/userguide/fsbp-standard.html>; control:
  <https://docs.aws.amazon.com/securityhub/latest/userguide/cloudfront-controls.html>, <https://docs.aws.amazon.com/securityhub/latest/userguide/waf-controls.html>,
  <https://docs.aws.amazon.com/securityhub/latest/userguide/acm-controls.html>, <https://docs.aws.amazon.com/securityhub/latest/userguide/route53-controls.html>,
  <https://docs.aws.amazon.com/securityhub/latest/userguide/elb-controls.html>
- [N23] Trang giá: <https://aws.amazon.com/waf/pricing/>, <https://aws.amazon.com/cloudfront/pricing/pay-as-you-go/>,
  <https://aws.amazon.com/certificate-manager/pricing/>, <https://aws.amazon.com/route53/pricing/>, <https://aws.amazon.com/kms/pricing/>,
  <https://aws.amazon.com/cloudwatch/pricing/>
- [N24] nginx ticket 2524 (giá trị IPv6 của `CloudFront-Viewer-Address`): <https://trac.nginx.org/nginx/ticket/2524>
- [N25] CloudFront, flat-rate pricing plans: <https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/flat-rate-pricing-plan.html>
- [N26] CloudFront, request and response behavior for custom origins:
  <https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/RequestAndResponseBehaviorCustomOrigin.html>
- [N27] AWS Price List API, ELB `ap-southeast-1`: <https://pricing.us-east-1.amazonaws.com/offers/v1.0/aws/AWSELB/current/ap-southeast-1/index.json>
  ("$0.0252 per Application LoadBalancer-hour", "$0.008 per used Application load balancer capacity unit-hour")
- [N28] CloudFront, control origin requests with a policy: <https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/controlling-origin-requests.html>
- [N29] ALB, HTTP headers (`X-Forwarded-For`): <https://docs.aws.amazon.com/elasticloadbalancing/latest/application/x-forwarded-headers.html>
- [N30] RFC 8659, DNS Certification Authority Authorization (CAA) Resource Record, §3: <https://www.rfc-editor.org/rfc/rfc8659#section-3>
- [N31] CloudFront, Lambda@Edge restrictions, mục "CloudFront headers" (CloudFront đè header cùng tên của viewer):
  <https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/lambda-at-edge-function-restrictions.html#lambda-at-edge-restrictions-cloudfront-headers>
- [N32] AWS WAF, Bot Control: "Example: Allow a specific blocked bot": <https://docs.aws.amazon.com/waf/latest/developerguide/waf-bot-control-example-allow-blocked-bot.html>;
  "Example: Creating an exception for a blocked user agent":
  <https://docs.aws.amazon.com/waf/latest/developerguide/waf-bot-control-example-user-agent-exception.html>
- [N33] AWS WAF, "Testing and deploying AWS WAF Bot Control": <https://docs.aws.amazon.com/waf/latest/developerguide/waf-bot-control-deploying.html>;
  "Rule group return action override to Count": <https://docs.aws.amazon.com/waf/latest/developerguide/web-acl-rule-group-override-options.html>
- [N34] AWS WAF API Reference, `Rule` (`OverrideAction`): <https://docs.aws.amazon.com/waf/latest/APIReference/API_Rule.html>;
  `ManagedRuleGroupStatement` (`RuleActionOverrides`, `Version`): <https://docs.aws.amazon.com/waf/latest/APIReference/API_ManagedRuleGroupStatement.html>;
  `RuleActionOverride`: <https://docs.aws.amazon.com/waf/latest/APIReference/API_RuleActionOverride.html>
