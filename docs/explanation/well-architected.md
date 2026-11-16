# Well-Architected review của hệ thống trên AWS

Trang này review hệ thống như code của bốn repo mô tả cho stg, prd trên AWS, theo sáu trụ cột của AWS Well-Architected Framework
[WAF]: Operational Excellence, Security, Reliability, Performance Efficiency, Cost Optimization, Sustainability. Mỗi trụ cột có các
câu hỏi của framework, hệ thống trả lời thế nào (trỏ ADR, runbook, code: trang không chép lại nội dung), rủi ro còn lại và việc đề
xuất. Đây là review bản thiết kế: điểm nào cần số đo thật ghi **đo ở buổi stg/prd chung** và trỏ mục "Xác nhận" hay mục đo của ADR
ghi phép đo đó; trang không nêu số chưa đo.

Thiết kế tổng thể ở [`architecture.md`](../architecture.md), khác biệt stg và prd ở [`environments.md`](environments.md), mối đe doạ ở
[`threat-model.md`](../threat-model.md).

## Cách đọc

- **Câu hỏi** lấy nguyên văn mã và tiêu đề ở trang câu hỏi của từng trụ cột ([OPS], [SEC], [REL], [PERF], [COST], [SUS]).
- **Mức rủi ro** theo cách của AWS Well-Architected Tool [WAT]: **High** (HRI) là lựa chọn kiến trúc hay vận hành mà AWS thấy có thể gây
  tác động tiêu cực đáng kể cho nghiệp vụ; **Medium** (MRI) cũng có thể gây tác động tiêu cực, ở mức nhẹ hơn. Ô "—" là không còn rủi ro đáng
  xếp với thiết kế hiện tại.
- **Mã rủi ro** `WA-n` dùng chung giữa bảng tổng kết và bảng của trụ cột. Rủi ro cần một quyết định mới ghi "đề xuất ADR"; trang không đổi
  ADR nào.
- Rủi ro đã chấp nhận ở threat model mang ID của nó (`JWT-3`, `SC-1`…); lý do chấp nhận và điều kiện xem lại ở
  [mục 6 của threat model](../threat-model.md#6-rủi-ro-chấp-nhận).

## Tổng kết rủi ro

| Mã | Câu hỏi | Rủi ro | Mức | Việc đề xuất |
| --- | --- | --- | --- | --- |
| WA-1 | REL 12, PERF 5 | SLO và yêu cầu độ trễ (feed p99 < 150 ms tại 1 000 req/s) chưa có số đo ở tải mục tiêu trên cloud | High | Chạy k6 profile `cloud` theo SLO: đo ở buổi stg/prd chung |
| WA-2 | REL 12, REL 13 | RTO, RPO và failover của dữ liệu managed chưa diễn tập trên cloud | High | Diễn tập PITR, object S3, failover RDS, Valkey, mất broker MSK, drain một AZ: đo ở buổi stg/prd chung |
| WA-3 | SEC 9 | Mesh Istio ambient mã hoá gRPC trong cluster và kiểm danh tính theo service account ([ADR-0075](../adr/0075-service-mesh.md)), nhưng chưa kiểm trên EKS thật: probe của kubelet tới pod trong mesh đến từ `169.254.7.127`, nguồn mà tài liệu network policy của VPC CNI không nói tới; telemetry OTLP ra `svp-obs` và compose nằm ngoài mesh | Medium | Buổi stg/prd chung: pod `svp` Ready sau khi vào mesh; đo độ trễ thêm của waypoint (p99 client trừ p99 server cùng method) |
| WA-4 | PERF 2, REL 7 | Waypoint cân tải gRPC theo request thay `pick_first` qua ClusterIP, nhưng chưa đo dưới tải k6 trên cloud: chia đều giữa pod và một chặng Envoy thêm vào mọi lời gọi | Medium | Đo ở buổi stg/prd chung cùng k6 profile `cloud` |
| WA-5 | REL 1 | Không có danh mục Service Quotas và cảnh báo theo quota; các giới hạn đã biết nằm rải trong ADR | Medium | Danh mục quota của mỗi account, kiểm trước buổi, alarm theo mức dùng quota; đề xuất ADR |
| WA-6 | OPS 5, OPS 6 | `plan` trên PR ([ADR-0076](../adr/0076-terraform-plan-infracost-pr.md)) chỉ chạy khi role OIDC chỉ đọc đã apply ở account env | Medium | Apply role, bật biến plan ở buổi cloud |
| WA-7 | OPS 6, SEC 11 | Không có cổng tự động "bộ prd = bộ stg đã kiểm" (GIT-4); provenance đạt SLSA Build L2, không L3 | Medium | Giữ chấp nhận tới điều kiện xem lại của GIT-4 |
| WA-8 | SEC 6 | Chữ ký của image bên thứ ba chưa kiểm ở admission (SC-1) | Medium | Kiểm chữ ký theo nhà cung cấp khi review bảo mật capstone |
| WA-9 | SEC 2 | Access token không thu hồi được trước hạn 15 phút (JWT-3) | Medium | Giữ chấp nhận tới khi có đổi mật khẩu hay khoá tài khoản |
| WA-10 | COST 3, COST 6 | Chi phí theo namespace chỉ gồm compute; số Spot của stg là trần giá on-demand; chi phí thật của một buổi chưa đo | Medium | Đo chi phí theo namespace và đối chiếu Cost Explorer: đo ở buổi stg/prd chung |
| WA-11 | COST 5 | Ước lượng Infracost trên PR ([ADR-0076](../adr/0076-terraform-plan-infracost-pr.md)) cần khoá API của người học; chưa so với hoá đơn thật | Medium | Tạo khoá, so ước lượng với Cost Explorer sau buổi |
| WA-12 | REL 13 | Mất cả region nằm ngoài phạm vi DR: không có bản nào ở region khác | Medium | Giữ chấp nhận tới điều kiện "Xem lại khi" của ADR-0067 |
| WA-13 | PERF 3, PERF 4 | Hạn 50 ms của cache khám phá trên Valkey và tỉ lệ cache hit của segment premium ở CloudFront chưa đo trên cloud | Medium | Đo ở buổi stg/prd chung |
| WA-14 | OPS 4, REL 6 | Độ tươi feed chưa thành SLO; profile (Pyroscope) và lỗi (GlitchTip) mất khi destroy cluster | Medium | SLO độ tươi khi có đủ event; quyết nơi giữ profile, lỗi qua destroy, đề xuất ADR |
| WA-15 | OPS 2, OPS 10 | Một người vận hành, không luân phiên trực; cảnh báo page chỉ tới email và Telegram | Medium | Chấp nhận ở quy mô lab; lịch trực và escalation khi có người thứ hai |
| WA-16 | SUS 1, SUS 6 | Chưa có mục tiêu và số đo bền vững; region chọn theo độ trễ và giá, không xét bền vững | Medium | Đặt số đo proxy (vCPU-giờ mỗi phút video, GB lưu mỗi video) trên dashboard chi phí |

Rủi ro High nằm ở Reliability, Performance Efficiency (WA-1, WA-2); Operational Excellence, Security, Cost Optimization,
Sustainability chỉ có rủi ro Medium.

## Operational Excellence

Câu hỏi theo [OPS].

| Câu hỏi | Hệ thống trả lời | Rủi ro |
| --- | --- | --- |
| OPS 1. How do you determine what your priorities are? | Mục tiêu, ràng buộc và yêu cầu phi chức năng ở [mục 1, 2 của `architecture.md`](../architecture.md); mỗi quyết định là một ADR có yếu tố quyết định ([`adr/README.md`](../adr/README.md)) | — |
| OPS 2. How do you structure your organization to support your business outcomes? | Ba repo theo vai trò (code, cấu hình triển khai, hạ tầng: [ADR-0025](../adr/0025-gitops-config-repo.md), [ADR-0034](../adr/0034-aws-stage7.md)); Code Owner trên đường nhạy cảm ([ADR-0041](../adr/0041-github-hardening.md)) | WA-15 |
| OPS 3. How does your organizational culture support your business outcomes? | Postmortem không đổ lỗi ([`postmortems/`](../postmortems/)), RFC một trang cho người không làm kỹ thuật ([`rfc/`](../rfc/)), ADR có "Xem lại khi" | — |
| OPS 4. How do you implement observability in your workload? | OpenTelemetry đủ ba tín hiệu, RUM của web, SLO bằng Sloth ([ADR-0011](../adr/0011-observability-stage3.md), [`observability.md`](observability.md)); trên eks vào AMP, CloudWatch Logs, X-Ray ([ADR-0063](../adr/0063-managed-observability.md)); uptime từ ngoài vào ([ADR-0074](../adr/0074-cost-uptime.md)) | WA-14 |
| OPS 5. How do you reduce defects, ease remediation, and improve flow into production? | Check `ci-ok`, `images-ok` bắt buộc trên `main`, test `-race` trên Postgres và Redis thật, cổng quét ([`ci-cd.md`](../ci-cd.md), [`delivery.md`](delivery.md)) | WA-6 |
| OPS 6. How do you mitigate deployment risks? | Build một lần, cùng digest qua `svp-gitops` và Argo CD; canary web, gateway và canary gRPC theo request qua waypoint ([ADR-0072](../adr/0072-pod-operations.md), [ADR-0075](../adr/0075-service-mesh.md)); prd ghim commit stg đã chạy, environment `promote-prd` có người duyệt ([ADR-0048](../adr/0048-prd-aws.md), [ADR-0041](../adr/0041-github-hardening.md)); migration expand/contract ([ADR-0068](../adr/0068-zero-downtime-migrations.md)) | WA-6, WA-7 |
| OPS 7. How do you know that you are ready to support a workload? | Một runbook cho mỗi cảnh báo page ([`runbooks/README.md`](../runbooks/README.md)); game day có postmortem; kịch bản `verify.yml` trên runner ([`reliability.md`](reliability.md)) | — |
| OPS 8. How do you utilize workload observability in your organization? | Cảnh báo burn rate đa cửa sổ mang `runbook_url`; dashboard theo service, SLO, chi phí, uptime ([`observability.md`](observability.md)) | — |
| OPS 9. How do you understand the health of your operations? | Trạng thái deploy của Argo CD về commit status ([ADR-0032](../adr/0032-argocd-deploy-status.md)), runbook khi Application hỏng ([`argocd-application-degraded.md`](../runbooks/argocd-application-degraded.md)); DORA rời đường chính vì env không sống đủ lâu để số có nghĩa ([ADR-0037](../adr/0037-mainpath-standard-tools.md) §1) | — |
| OPS 10. How do you manage workload and operations events? | Alertmanager của AMP gửi SNS email ([ADR-0063](../adr/0063-managed-observability.md)); CloudWatch alarm của dữ liệu managed sống độc lập với cluster ([ADR-0058](../adr/0058-managed-data-operations.md)); cảnh báo bảo mật theo [`security-alert.md`](../runbooks/security-alert.md) | WA-15 |
| OPS 11. How do you evolve operations? | Phát hiện của game day, chaos thành ADR sửa ([ADR-0031](../adr/0031-chaos-findings-feed-engagement-tempo.md)); mỗi ADR có điều kiện xem lại | — |

Việc đề xuất:

- **WA-6:** `plan` trên PR theo [ADR-0076](../adr/0076-terraform-plan-infracost-pr.md) (role OIDC chỉ đọc, environment `terraform-plan`, không
  `apply` từ CI); còn apply role và bật biến plan ở buổi cloud.
- **WA-14:** SLO độ tươi feed khi stg có đủ event để burn rate có nghĩa (lý do chưa có ở mục 10 của [`architecture.md`](../architecture.md));
  nơi giữ profile và lỗi qua destroy là đề xuất ADR, vì ADR-0063 đã chấp nhận cái giá đó.
- **WA-15:** khi có người thứ hai: lịch trực, escalation khi page không ai nhận, quyền theo vai trò.

## Security

Câu hỏi theo [SEC].

| Câu hỏi | Hệ thống trả lời | Rủi ro |
| --- | --- | --- |
| SEC 1. How do you securely operate your workload? | Org theo AWS SRA, mỗi env một account, management không chạy workload; SCP, RCP, declarative policy ở root ([ADR-0059](../adr/0059-org-structure-guardrails.md), [`aws-security.md`](aws-security.md)); threat model STRIDE xét lại mỗi bề mặt mới | — |
| SEC 2. How do you manage authentication for people and machines? | Người: IAM Identity Center, không IAM user, root tập trung ([ADR-0059](../adr/0059-org-structure-guardrails.md)); máy: Pod Identity, role OIDC của CI ([ADR-0062](../adr/0062-ecr-registry-ci-oidc.md)); người dùng: argon2id, JWT EdDSA, refresh xoay vòng ([`authentication.md`](authentication.md), [ADR-0069](../adr/0069-auth-hardening.md)) | WA-9 |
| SEC 3. How do you manage permissions for people and machines? | Permission set chỉ đọc mặc định ([`aws-security.md`](aws-security.md)); role External Secrets theo namespace; mỗi client một user ACL ở MSK, Valkey và một role Postgres riêng ([ADR-0053](../adr/0053-msk-elasticache-valkey.md), [ADR-0057](../adr/0057-postgres17-verify-full.md)); mỗi service một database ([ADR-0001](../adr/0001-service-boundaries-and-data-ownership.md)) | — |
| SEC 4. How do you detect and investigate security events? | GuardDuty, Security Hub CSPM, Config, Access Analyzer do `svp-security` quản; trail, flow log, log WAF về Log Archive ([ADR-0060](../adr/0060-org-detection-logging.md)); stg tắt Security Hub, Config theo cờ, kiểm bù ở [`paid-features.md`](paid-features.md) | — |
| SEC 5. How do you protect your network resources? | Ba tầng subnet, subnet database không route ra Internet ([ADR-0054](../adr/0054-data-subnet-tier.md)); CloudFront và WAF trước web, API, media, ALB internal qua VPC origin ([ADR-0061](../adr/0061-edge-cloudfront-waf-acm.md), [`edge.md`](edge.md)); API EKS chỉ endpoint private; endpoint interface ([ADR-0064](../adr/0064-interface-endpoints.md)); NetworkPolicy chặn mặc định | — |
| SEC 6. How do you protect your compute resources? | Pod Security `restricted`, image distroless nonroot, Kyverno chỉ nhận image đã ký và còn hạn quét ([`delivery.md`](delivery.md)); cổng quét chặn CRITICAL, HIGH có bản vá ([ADR-0070](../adr/0070-scan-gate-high-fixed.md)); Inspector quét repo cache của ECR ([ADR-0062](../adr/0062-ecr-registry-ci-oidc.md)) | WA-8 |
| SEC 7. How do you classify your data? | Tài sản cần bảo vệ và mức của chúng ở [mục 3 của threat model](../threat-model.md); dữ liệu người dùng chỉ ở database của service sở hữu và bucket `uploads`, `media` | — |
| SEC 8. How do you protect your data at rest? | RDS mã hoá bằng CMK ([ADR-0057](../adr/0057-postgres17-verify-full.md)); `uploads` SSE-KMS ([ADR-0067](../adr/0067-backup-dr.md) §8); bản backup ở account riêng, vault khoá governance ([`backup-dr.md`](backup-dr.md)) | — |
| SEC 9. How do you protect your data in transit? | Postgres `sslmode=verify-full`, MSK SCRAM trên TLS, Valkey TLS ([ADR-0057](../adr/0057-postgres17-verify-full.md), [ADR-0053](../adr/0053-msk-elasticache-valkey.md)); cert ACM ở edge ([ADR-0061](../adr/0061-edge-cloudfront-waf-acm.md)); gRPC trong cluster mã hoá bằng mTLS của mesh Istio ambient ([ADR-0075](../adr/0075-service-mesh.md), [mục 4.5 của threat model](../threat-model.md#45-mức-tin-cậy-giữa-các-service)) | WA-3 |
| SEC 10. How do you anticipate, respond to, and recover from incidents? | Runbook phân loại cảnh báo bảo mật ([`security-alert.md`](../runbooks/security-alert.md)); break-glass ([`aws-security.md`](aws-security.md)); khôi phục từ account `svp-backup` ([`rds-restore.md`](../runbooks/rds-restore.md), [`s3-restore.md`](../runbooks/s3-restore.md)) | — |
| SEC 11. How do you incorporate and validate the security properties of applications throughout the design, development, and deployment lifecycle? | Threat model theo bề mặt; gosec, govulncheck, gitleaks, zizmor, Scorecard, dependency review; SBOM, chữ ký keyless và provenance ([ADR-0015](../adr/0015-cicd-devsecops-stage5.md), [ADR-0040](../adr/0040-sigstore-bundle-actions-attest.md), [ADR-0041](../adr/0041-github-hardening.md)) | WA-7 |

Việc đề xuất:

- **WA-3:** mesh đã dựng theo [ADR-0042](../adr/0042-caller-identity-grpc.md): mTLS STRICT giữa mọi pod của `svp`,
  AuthorizationPolicy theo service account đúng các kênh gRPC đang có, NetworkPolicy giữ làm lớp mạng
  ([`architecture.md`](../architecture.md#65-request-grpc-qua-mesh)). Còn lại là phần chỉ cloud kiểm được: pod `svp` Ready trên
  EKS (nguồn probe, mục 7 của phụ lục) và độ trễ, RAM thêm của mesh, đo ở buổi stg/prd chung.
- **WA-8, WA-9:** giữ chấp nhận; điều kiện xem lại của SC-1 và JWT-3 ở [mục 6 của threat model](../threat-model.md#6-rủi-ro-chấp-nhận).

## Reliability

Câu hỏi theo [REL].

| Câu hỏi | Hệ thống trả lời | Rủi ro |
| --- | --- | --- |
| REL 1. How do you manage Service Quotas and constraints? | Vài giới hạn đã biết ghi ở ADR của dịch vụ: ba gói CloudFront Free mỗi account ([ADR-0052](../adr/0052-cloudfront-flat-rate-free.md)), chu kỳ luật và token của AMP, AMG ([ADR-0063](../adr/0063-managed-observability.md)); chưa có danh mục chung, chưa có cảnh báo theo mức dùng | WA-5 |
| REL 2. How do you plan your network topology? | VPC đa AZ (prd ba, stg hai), NAT mỗi AZ ở prd, ba tầng subnet ([ADR-0054](../adr/0054-data-subnet-tier.md), [`environments.md`](environments.md)); API AWS qua endpoint interface ([ADR-0064](../adr/0064-interface-endpoints.md)) | — |
| REL 3. How do you design your workload service architecture? | Sáu service theo ranh giới nghiệp vụ, mỗi service một database ([ADR-0001](../adr/0001-service-boundaries-and-data-ownership.md)); event qua Kafka với outbox ([ADR-0003](../adr/0003-async-events-outbox.md)) | — |
| REL 4. How do you design interactions in a distributed system to prevent failures? | Consumer idempotent, `Idempotency-Key` cho `POST /videos` ([ADR-0043](../adr/0043-idempotency-key.md)); hợp đồng gRPC, REST có version (`buf breaking`, `make api-contract-check`); rate limit GCRA ([ADR-0010](../adr/0010-redis-ratelimit-cache-resilience-stage2c.md)) | — |
| REL 5. How do you design interactions in a distributed system to mitigate or withstand failures? | Deadline mỗi lời gọi, retry có ngân sách, circuit breaker, graceful degradation của feed ([mục 6.2 của `architecture.md`](../architecture.md)); chặn quá tải ở gateway ([ADR-0072](../adr/0072-pod-operations.md)); retry có trần rồi DLQ ([ADR-0045](../adr/0045-bounded-batch-retry.md)) | — |
| REL 6. How do you monitor workload resources? | SLO và burn rate ([`reliability.md`](reliability.md#slo)); CloudWatch alarm của RDS, MSK, ElastiCache ([ADR-0058](../adr/0058-managed-data-operations.md)); probe từ ngoài vào ([ADR-0074](../adr/0074-cost-uptime.md)) | WA-14 |
| REL 7. How do you design your workload to adapt to changes in demand? | HPA, KEDA cho pod; Karpenter cho node ([ADR-0056](../adr/0056-eks-platform-ha.md)); pod gRPC mới nhận lời gọi ngay vì waypoint chia theo request; ước lượng quy mô ở [`capacity.md`](capacity.md) | WA-4 |
| REL 8. How do you implement change? | GitOps qua `svp-gitops` và Argo CD ([ADR-0025](../adr/0025-gitops-config-repo.md)); canary; migration không downtime ([ADR-0068](../adr/0068-zero-downtime-migrations.md)); output media bất biến theo version ([ADR-0029](../adr/0029-immutable-media-versions.md)) | — |
| REL 9. How do you back up data? | PITR gốc của RDS, AWS Backup hằng ngày cho RDS và hai bucket, copy sang account `svp-backup`; chỉ dữ liệu không dựng lại được ([ADR-0067](../adr/0067-backup-dr.md) §1, [`backup-dr.md`](backup-dr.md)) | — |
| REL 10. How do you use fault isolation to protect your workload? | Mỗi env một account; pod và node trải theo zone ([ADR-0056](../adr/0056-eks-platform-ha.md), [ADR-0072](../adr/0072-pod-operations.md)); breaker một cái mỗi service đích | — |
| REL 11. How do you design your workload to withstand component failures? | prd: RDS Multi-AZ, MSK một broker mỗi AZ với RF 3 và min ISR 2, Valkey primary và replica khác AZ, Envoy, Kyverno HA ([`architecture.md`](../architecture.md), [ADR-0056](../adr/0056-eks-platform-ha.md)); readiness gRPC theo database ([ADR-0044](../adr/0044-grpc-readiness.md)) | WA-2 |
| REL 12. How do you test reliability? | Chaos, game day, Velero đo trên compose, k3d và runner ([`reliability.md`](reliability.md)); phép đo cần cloud liệt kê ở [mục "Chưa đo trên cloud"](reliability.md#chưa-đo-trên-cloud) | WA-1, WA-2 |
| REL 13. How do you plan for disaster recovery (DR)? | Mục tiêu RTO, RPO theo loại sự cố ([ADR-0067](../adr/0067-backup-dr.md) §2); runbook khôi phục; mất region ngoài phạm vi (§12) | WA-2, WA-12 |

Việc đề xuất:

- **WA-1:** k6 profile `cloud` (Job trong cluster, 1 000 req/s feed, [`reliability.md`](reliability.md#tải)) dưới SLO; chặn quá tải và pool
  kết nối dưới tải thật là phép đo của mục "Xác nhận" của [ADR-0072](../adr/0072-pod-operations.md). Đo ở buổi stg/prd chung.
- **WA-2:** diễn tập PITR và object S3 theo [ADR-0067](../adr/0067-backup-dr.md) §9, §10 (tiêu chí đạt viết trước); failover RDS, Valkey và mất
  broker MSK theo kiểm bù của [ADR-0055](../adr/0055-environment-matrix.md) §4; drain một AZ theo mục "Xác nhận" của
  [ADR-0056](../adr/0056-eks-platform-ha.md). Đo ở buổi stg/prd chung.
- **WA-5:** một danh mục quota mỗi account (dịch vụ, giá trị mặc định, giá trị cần, nguồn), kiểm trước mỗi buổi; alarm theo mức dùng quota cho
  những quota chặn được buổi. Đề xuất ADR.
- **WA-12:** giữ chấp nhận; điều kiện xem lại ở mục "Hệ quả" của [ADR-0067](../adr/0067-backup-dr.md).

## Performance Efficiency

Câu hỏi theo [PERF].

| Câu hỏi | Hệ thống trả lời | Rủi ro |
| --- | --- | --- |
| PERF 1. How do you select appropriate cloud resources and architecture for your workload? | Ước lượng tải, dữ liệu, băng thông trước khi chọn ([`capacity.md`](capacity.md)); dịch vụ managed cho dữ liệu và transcode ([ADR-0053](../adr/0053-msk-elasticache-valkey.md), [ADR-0057](../adr/0057-postgres17-verify-full.md), [ADR-0066](../adr/0066-mediaconvert-transcode.md)); mỗi ADR so phương án | WA-1 |
| PERF 2. How do you select and use compute resources in your workload? | Node Graviton do Karpenter chọn theo pod đang chờ ([ADR-0056](../adr/0056-eks-platform-ha.md)); requests, limits bắt buộc; HPA, KEDA; waypoint cân tải gRPC theo request ([ADR-0075](../adr/0075-service-mesh.md)) | WA-4 |
| PERF 3. How do you store, manage, and access data in your workload? | Feed dựng sẵn khi ghi ([ADR-0005](../adr/0005-feed-fan-out-on-write.md)); lượt xem gom theo lô ([ADR-0009](../adr/0009-engagement-feed-stage2b.md)); Valkey cache trang đầu feed khám phá ([ADR-0010](../adr/0010-redis-ratelimit-cache-resilience-stage2c.md)); ngân sách kết nối Postgres ([`capacity.md`](capacity.md)) | WA-13 |
| PERF 4. How do you select and configure networking resources in your workload? | CDN bắt buộc vì egress là phần lớn tải ([`capacity.md`](capacity.md)); CloudFront cho web, API, media ([ADR-0061](../adr/0061-edge-cloudfront-waf-acm.md), [ADR-0052](../adr/0052-cloudfront-flat-rate-free.md)); segment premium từ CDN qua signed URL ([ADR-0073](../adr/0073-premium-playback.md)) | WA-13 |
| PERF 5. How do your organizational practices and culture contribute to performance efficiency in your workload? | SLO độ trễ, k6 theo SLO, RUM và Lighthouse làm tín hiệu hồi quy ([`reliability.md`](reliability.md)) | WA-1 |

Việc đề xuất:

- **WA-4:** waypoint L7 cân tải gRPC theo request; cơ chế và cái gì hỏng khi mesh hỏng ở
  [`reliability.md`](reliability.md#mesh-cân-tải-và-khi-mesh-hỏng). `MaxConnectionAge` ([`deployment.md`](deployment.md#vòng-đời-pod)) còn
  cho compose, nơi không có mesh. Đo mức chia đều và độ trễ thêm dưới k6 ở buổi stg/prd chung.
- **WA-13:** hạn 50 ms của cache khám phá trên ElastiCache (câu hỏi mở ở mục 11 của [`architecture.md`](../architecture.md),
  [`explore-cache-redis-timeout.md`](../runbooks/explore-cache-redis-timeout.md)) và cache hit của segment premium theo
  [ADR-0073](../adr/0073-premium-playback.md) §9. Đo ở buổi stg/prd chung.

## Cost Optimization

Câu hỏi theo [COST].

| Câu hỏi | Hệ thống trả lời | Rủi ro |
| --- | --- | --- |
| COST 1. How do you implement cloud financial management? | Budget mỗi account và của cả org ([ADR-0048](../adr/0048-prd-aws.md) §2); Cost Anomaly Detection, tag phân bổ chi phí ([ADR-0060](../adr/0060-org-detection-logging.md)); mỗi ADR có mục chi phí có nguồn | — |
| COST 2. How do you govern usage? | SCP chặn region ngoài danh sách ([ADR-0048](../adr/0048-prd-aws.md)), tag policy ([ADR-0059](../adr/0059-org-structure-guardrails.md)); dịch vụ tốn tiền có cờ theo account ([ADR-0071](../adr/0071-paid-features.md), [`paid-features.md`](paid-features.md)) | — |
| COST 3. How do you monitor your cost and usage? | Chi phí compute theo namespace, service bằng OpenCost; phần còn lại ở Cost Explorer theo tag ([`cost-and-uptime.md`](cost-and-uptime.md)) | WA-10 |
| COST 4. How do you decommission resources? | Env dựng và destroy trong cùng buổi, kèm quét tài nguyên sót ([ADR-0048](../adr/0048-prd-aws.md) §9); bước gỡ của Karpenter, ACK trước destroy ([ADR-0056](../adr/0056-eks-platform-ha.md), [ADR-0063](../adr/0063-managed-observability.md)) | — |
| COST 5. How do you evaluate cost when you select services? | Mục chi phí của từng ADR theo Price List có ngày đọc (ví dụ [ADR-0064](../adr/0064-interface-endpoints.md), [ADR-0074](../adr/0074-cost-uptime.md) §11) | WA-11 |
| COST 6. How do you meet cost targets when you select resource type, size and number? | stg chỉ giảm cỡ, số lượng, dự phòng, retention ([ADR-0055](../adr/0055-environment-matrix.md)); `limits` của NodePool là trần chi phí ([ADR-0056](../adr/0056-eks-platform-ha.md)) | WA-10 |
| COST 7. How do you use pricing models to reduce cost? | Spot cho node workload của stg, on-demand ở prd ([ADR-0056](../adr/0056-eks-platform-ha.md)); gói CloudFront flat-rate Free cho media của stg ([ADR-0061](../adr/0061-edge-cloudfront-waf-acm.md)); không cam kết dùng dài hạn vì env sống theo buổi | — |
| COST 8. How do you plan for data transfer charges? | Egress chiếm phần lớn nên media đi qua CDN ([`capacity.md`](capacity.md)); API AWS qua endpoint thay NAT ([ADR-0064](../adr/0064-interface-endpoints.md)) | — |
| COST 9. How do you manage demand, and supply resources? | Karpenter consolidation gỡ node rỗng hay thừa ([`deployment.md`](deployment.md)); KEDA theo lag consumer cho media-worker; MediaConvert queue on-demand ([ADR-0066](../adr/0066-mediaconvert-transcode.md)) | — |
| COST 10. How do you evaluate new services? | Quyết định đổi công cụ hay dịch vụ đi qua ADR có phương án, chi phí, "Xem lại khi" ([`adr/README.md`](../adr/README.md)) | — |
| COST 11. How do you evaluate the cost of effort? | Đường chính dùng công cụ chuẩn thay script tự viết ([ADR-0037](../adr/0037-mainpath-standard-tools.md), [ADR-0050](../adr/0050-bash-to-standard-tools.md)) | — |

Việc đề xuất:

- **WA-10:** đo chi phí theo namespace trong buổi và đối chiếu tổng với Cost Explorer sau buổi, theo mục "Xác nhận" và §11 của
  [ADR-0074](../adr/0074-cost-uptime.md); ADR-0048 xem lại khi chi phí đo lệch ước lượng quá 50 %. Đo ở buổi stg/prd chung. Giá Spot gần
  thật cho stg là điều kiện "Xem lại khi" của ADR-0074.
- **WA-11:** Infracost trên PR theo [ADR-0076](../adr/0076-terraform-plan-infracost-pr.md), gồm cờ của `aws/paid-features.json`; còn tạo khoá
  API và so ước lượng với hoá đơn thật sau buổi.

## Sustainability

Câu hỏi theo [SUS].

| Câu hỏi | Hệ thống trả lời | Rủi ro |
| --- | --- | --- |
| SUS 1 How do you select Regions for your workload? | `ap-southeast-1` chọn vì gần người dùng giả định, đổi lại giá cao hơn ([ADR-0034](../adr/0034-aws-stage7.md) Câu 4); bền vững không là yếu tố quyết định | WA-16 |
| SUS 2 How do you align cloud resources to your demand? | Env chỉ sống trong buổi; node theo pod đang chờ và consolidation ([ADR-0056](../adr/0056-eks-platform-ha.md)); pod co giãn theo tải | — |
| SUS 3 How do you take advantage of software and architecture patterns to support your sustainability goals? | Việc nặng chạy bất đồng bộ và gom lô (transcode, lượt xem: [ADR-0004](../adr/0004-direct-upload-and-hls.md), [ADR-0009](../adr/0009-engagement-feed-stage2b.md)); feed dựng một lần khi ghi; cache ở CDN | — |
| SUS 4 How do you take advantage of data management policies and patterns to support your sustainability goals? | Chỉ backup dữ liệu không dựng lại được; bản gốc `uploads` sang lớp lưu trữ archive theo lifecycle ([ADR-0067](../adr/0067-backup-dr.md) §1); retention ngắn ở stg ([ADR-0055](../adr/0055-environment-matrix.md)) | — |
| SUS 5 How do you select and use cloud hardware and services in your architecture to support your sustainability goals? | Node Graviton ([ADR-0056](../adr/0056-eks-platform-ha.md)); dịch vụ managed cho dữ liệu và transcode | — |
| SUS 6 How do your organizational processes support your sustainability goals? | Chưa có mục tiêu hay số đo bền vững | WA-16 |

Việc đề xuất:

- **WA-16:** đặt số đo proxy theo trụ cột Sustainability [SUS] từ metric đã có: vCPU-giờ cấp phát mỗi phút video đã transcode (OpenCost,
  `svp_video_ready_duration_seconds`), GB lưu mỗi video (S3); hiện trên dashboard chi phí. Region giữ như ADR-0034.

## Nguồn

Trang AWS đọc ngày 2026-11-15; Framework là bản phát hành ngày 6 tháng 11 năm 2024 ghi trên trang [WAF].

| Nhãn | Nguồn |
| --- | --- |
| [WAF] | AWS Well-Architected Framework: <https://docs.aws.amazon.com/wellarchitected/latest/framework/welcome.html> |
| [OPS] | Operational excellence, câu hỏi và best practice: <https://docs.aws.amazon.com/wellarchitected/latest/framework/a-operational-excellence.html> |
| [SEC] | Security, câu hỏi và best practice: <https://docs.aws.amazon.com/wellarchitected/latest/framework/a-security.html> |
| [REL] | Reliability, câu hỏi và best practice: <https://docs.aws.amazon.com/wellarchitected/latest/framework/a-reliability.html> |
| [PERF] | Performance efficiency, câu hỏi và best practice: <https://docs.aws.amazon.com/wellarchitected/latest/framework/a-performance-efficiency.html> |
| [COST] | Cost optimization, câu hỏi và best practice: <https://docs.aws.amazon.com/wellarchitected/latest/framework/a-cost-optimization.html> |
| [SUS] | Sustainability, câu hỏi và best practice: <https://docs.aws.amazon.com/wellarchitected/latest/framework/a-sustainability.html> |
| [WAT] | AWS Well-Architected Tool, Workloads: High Risk Issues (HRIs) and Medium Risk Issues (MRIs): <https://docs.aws.amazon.com/wellarchitected/latest/userguide/workloads.html> |
