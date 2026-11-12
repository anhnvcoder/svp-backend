# Năng lực của hệ thống và chuẩn ngành nó theo

Trang này liệt kê các năng lực kỹ thuật của nền tảng qua bốn repo (`svp-backend`, `svp-frontend`, `svp-gitops`, `svp-infra`), nhìn từ
góc DevSecOps và Solution Architect: hệ thống làm gì, vì sao, theo chuẩn nào, và hiện thực ở đâu. Mỗi mục chỉ một hai câu; mảng nào đã có
trang giải thích riêng thì mục ở đây link tới đó. Rủi ro đã chấp nhận ở [`threat-model.md`](../threat-model.md#6-rủi-ro-chấp-nhận).

Cột "Ở đâu" link tới ADR (vì sao) và code, chart, workflow (hiện thực). Link sang repo khác trỏ nhánh `main` của repo đó.

## Migration và triển khai không downtime

| Năng lực | Chuẩn | Ở đâu |
| --- | --- | --- |
| Migration có version bằng goose, chạy như thư viện; advisory lock của Postgres xếp hàng các lượt chạy đồng thời trên một database. | [goose](https://pressly.github.io/goose/), Postgres [advisory lock](https://www.postgresql.org/docs/current/explicit-locking.html#ADVISORY-LOCKS) | [`internal/dbmigrate`](../../internal/dbmigrate/dbmigrate.go) |
| Migration chạy một lần mỗi release bằng Job `migrate` (hook `pre-install`/`pre-upgrade`, Argo CD đọc là PreSync) với role migrator riêng; pod chạy dài chỉ giữ role app. Migration lỗi làm release lỗi trước khi pod mới thay pod cũ. | [Helm hooks](https://helm.sh/docs/topics/charts_hooks/), [Argo CD sync phases](https://argo-cd.readthedocs.io/en/stable/user-guide/sync-waves/), [least privilege (NIST)](https://csrc.nist.gov/glossary/term/least_privilege) | [`migrate.yaml`](../../deploy/helm/svp-service/templates/migrate.yaml), [Job `migrate`](deployment.md#svp-service) |
| Schema đổi theo expand/contract: bản cũ còn chạy trong lúc rollout ghi được vào schema mới (test ghi kiểu bản trước sau migration); quay lại bằng revert bản phát hành, không chạy migration `down`. | [Parallel change](https://martinfowler.com/bliki/ParallelChange.html) | [`user-service/migrations` test](../../services/user-service/migrations/migrations_test.go), [runbook deploy lỗi](../runbooks/argocd-application-degraded.md#giảm-thiểu) |
| Rollout không gián đoạn: PodDisruptionBudget khi có từ hai replica, HPA theo CPU, KEDA theo lag consumer; gateway và web ra canary bằng Argo Rollouts có AnalysisTemplate. | [Kubernetes disruptions](https://kubernetes.io/docs/concepts/workloads/pods/disruptions/), [Argo Rollouts canary](https://argoproj.github.io/argo-rollouts/features/canary/) | [HPA, PDB, KEDA, canary](deployment.md#svp-service), [ADR-0014](../adr/0014-kubernetes-local-stage4.md) |
| Build một lần, mọi env chạy cùng digest đã ký; env khác nhau chỉ ở overlay values. | [Twelve-Factor: build, release, run](https://12factor.net/build-release-run) | [ADR-0024](../adr/0024-multi-environment.md), [hai repo](delivery.md#hai-repo-code-và-cấu-hình-triển-khai) |

## Vòng đời pod và probe

| Năng lực | Chuẩn | Ở đâu |
| --- | --- | --- |
| SIGTERM: server gRPC chuyển health sang NOT_SERVING rồi `GracefulStop` có hạn 10 s; gateway HTTP `Shutdown`; web chờ `preStop` trước SIGTERM. | [Pod termination](https://kubernetes.io/docs/concepts/workloads/pods/pod-lifecycle/#pod-termination), [gRPC health checking](https://github.com/grpc/grpc/blob/master/doc/health-checking.md) | [`internal/grpcserver`](../../internal/grpcserver/grpcserver.go), [`deployment.yaml`](../../deploy/helm/svp-service/templates/deployment.yaml) |
| Readiness tách khỏi liveness: readiness gRPC là tên health `readiness`, do vòng nền ping Postgres đặt; liveness, startup giữ health tổng, không phụ thuộc database. | [Kubernetes probes](https://kubernetes.io/docs/concepts/configuration/liveness-readiness-startup-probes/) | [ADR-0044](../adr/0044-grpc-readiness.md), [khởi động và probe](reliability.md#khởi-động-và-probe) |
| Replica trải theo zone rồi theo node (`topologySpreadConstraints`, `ScheduleAnyway`): mất một AZ không mất mọi replica; chart từ chối release không đặt `resources`. | [Topology spread](https://kubernetes.io/docs/concepts/scheduling-eviction/topology-spread-constraints/), [EKS Best Practices: HA applications](https://docs.aws.amazon.com/eks/latest/best-practices/application.html) | [`svp-service/values.yaml`](../../deploy/helm/svp-service/values.yaml), [`deployment.yaml`](../../deploy/helm/svp-service/templates/deployment.yaml), [ADR-0056](../adr/0056-eks-platform-ha.md) §6 |

## Gọi giữa service

| Năng lực | Chuẩn | Ở đâu |
| --- | --- | --- |
| REST/JSON ở biên, gRPC bên trong, contract Protobuf quản bằng buf. | [buf](https://buf.build/docs/) | [ADR-0002](../adr/0002-sync-rest-edge-grpc-internal.md), [`proto/`](../../proto/) |
| Mỗi lời gọi gRPC từ gateway có deadline (3 s; 100 ms cho phần làm giàu không bắt buộc). | [gRPC deadlines](https://grpc.io/docs/guides/deadlines/) | [`gateway/internal/api`](../../services/gateway/internal/api/api.go) |
| Retry gRPC chỉ cho method idempotent, chỉ với `UNAVAILABLE`, backoff mũ, trong deadline của lời gọi, có retry throttling. | [gRFC A6](https://github.com/grpc/proposal/blob/master/A6-client-retries.md) | [`gateway/cmd/gateway`](../../services/gateway/cmd/gateway/main.go) |
| Circuit breaker mỗi backend (gobreaker), có metric trạng thái và cảnh báo. | [Circuit breaker](https://martinfowler.com/bliki/CircuitBreaker.html) | [`breaker`](../../services/gateway/internal/breaker/breaker.go), [runbook](../runbooks/circuit-breaker-open.md) |
| Rate limit GCRA bằng một script Lua trên Valkey, mỗi lệnh có hạn 50 ms. Khi Valkey lỗi, lớp đăng ký, đăng nhập, refresh, upload và route công khai chuyển sang GCRA trong bộ nhớ của từng instance với giới hạn bằng một nửa, có cảnh báo; lớp ghi, đọc và lượt xem cho request đi qua (fail open). Đăng nhập giới hạn theo IP và theo cặp (IP, email). | GCRA (ITU-T I.371), [OWASP ASVS 5.0](https://owasp.org/www-project-application-security-verification-standard/) | [`ratelimit`](../../services/gateway/internal/ratelimit/ratelimit.go), [ADR-0010](../adr/0010-redis-ratelimit-cache-resilience-stage2c.md), [threat model §4.4](../threat-model.md#44-rate-limit-ở-gateway) |
| Server gRPC giới hạn kích thước request (1 MiB) và keepalive. | [gRPC keepalive](https://grpc.io/docs/guides/keepalive/) | [`internal/grpcserver`](../../internal/grpcserver/grpcserver.go) |

## Hợp đồng API

| Năng lực | Chuẩn | Ở đâu |
| --- | --- | --- |
| Hợp đồng REST OpenAPI có version semver; oasdiff đòi tăng major khi đổi phá vỡ; phát hành thành bản ký để web dựng type từ đó. | [SemVer](https://semver.org), [OpenAPI](https://spec.openapis.org/oas/latest.html), [oasdiff](https://github.com/oasdiff/oasdiff) | [`openapi.yaml`](../../services/gateway/openapi.yaml), [`contract.sh`](../../deploy/ci/contract.sh), [ba repo và hợp đồng API](delivery.md#ba-repo-và-hợp-đồng-api) |
| `buf breaking` chặn thay đổi phá vỡ của proto. | [buf breaking](https://buf.build/docs/breaking/) | [`buf.yaml`](../../buf.yaml) |
| `POST /videos` nhận `Idempotency-Key`; khoá lưu cùng transaction với video, lần gửi lại trả đúng video cũ. | [draft-ietf-httpapi-idempotency-key-header](https://datatracker.ietf.org/doc/draft-ietf-httpapi-idempotency-key-header/) | [ADR-0043](../adr/0043-idempotency-key.md) |
| Phân trang bằng cursor keyset mờ (`page_size`, `page_token`, `next_page_token`). | [AIP-158](https://google.aip.dev/158) | [`internal/pagetoken`](../../internal/pagetoken/pagetoken.go), [phân trang feed](../reference/contracts.md#phân-trang-feed) |
| Lỗi REST là `application/problem+json` mang mã máy đọc được; lỗi gRPC mang `ErrorInfo`, gateway ánh xạ sang HTTP theo một bảng. | [RFC 9457](https://www.rfc-editor.org/rfc/rfc9457), [AIP-193](https://google.aip.dev/193) | [`httpx/problem.go`](../../services/gateway/internal/httpx/problem.go), [`internal/grpcerr`](../../internal/grpcerr/grpcerr.go), [mã lỗi](../reference/contracts.md#mã-lỗi-grpc-sang-http-ở-gateway) |
| Body JSON có trần kích thước, từ chối field lạ. | [OWASP REST Security](https://cheatsheetseries.owasp.org/cheatsheets/REST_Security_Cheat_Sheet.html) | [`httpx/json.go`](../../services/gateway/internal/httpx/json.go) |

## Event

| Năng lực | Chuẩn | Ở đâu |
| --- | --- | --- |
| Event ghi cùng transaction với dữ liệu vào bảng outbox; relay giữ advisory lock theo transaction để mỗi database chỉ một relay gửi. | [Transactional outbox](https://microservices.io/patterns/data/transactional-outbox.html) | [ADR-0003](../adr/0003-async-events-outbox.md), [`internal/outbox`](../../internal/outbox/relay.go) |
| At-least-once với consumer idempotent: `ON CONFLICT`, offset lưu trong cùng transaction với kết quả. | [Idempotent consumer](https://microservices.io/patterns/communication-style/idempotent-consumer.html) | [ADR-0009](../adr/0009-engagement-feed-stage2b.md), [topic](../reference/contracts.md#topic) |
| Lỗi tạm thử lại có backoff mũ và jitter rồi chép sang DLQ: consumer theo record giới hạn theo số lần (mặc định 5, media-worker 10), consumer theo lô của lượt xem giới hạn theo ngân sách 5 phút; lỗi `Permanent` vào DLQ ngay; consumer feed thử lại không giới hạn để giữ thứ tự. Cảnh báo DLQ và lag có runbook. | [Dead letter channel](https://www.enterpriseintegrationpatterns.com/patterns/messaging/DeadLetterChannel.html) | [ADR-0045](../adr/0045-bounded-batch-retry.md), [`kafkax` consumer](../../internal/kafkax/consumer.go), [batch](../../internal/kafkax/batch.go), [runbook DLQ](../runbooks/kafka-dlq-records.md), [runbook lag](../runbooks/kafka-consumer-lag-high.md) |
| Kafka trên cloud là Amazon MSK provisioned (KRaft, một broker mỗi AZ, replication theo env, `unclean.leader.election.enable=false`, không tự tạo topic); local chạy image chính thức `apache/kafka` cùng phiên bản. | [Apache Kafka](https://kafka.apache.org/documentation/), [Amazon MSK](https://docs.aws.amazon.com/msk/latest/developerguide/) | [ADR-0053](../adr/0053-msk-elasticache-valkey.md), [module `msk`](https://github.com/anhnvcoder/svp-infra/blob/main/aws/modules/msk/main.tf), [`server.properties`](../../deploy/kafka/server.properties) |
| Mọi client nói SASL_SSL, SCRAM-SHA-512 cổng 9096 ở compose, k3d và EKS: một đường code; mỗi service một user, ACL theo topic và group. | [Kafka security](https://kafka.apache.org/documentation/#security) | [`kafkax`](../../internal/kafkax/kafkax.go), [`kafka-init.sh`](../../deploy/kafka/kafka-init.sh) |
| Trace đi qua Kafka trong header của record. | [OTel messaging semconv](https://opentelemetry.io/docs/specs/semconv/messaging/) | [trace qua Kafka](observability.md#trace-qua-kafka) |

## Dữ liệu và cache

| Năng lực | Chuẩn | Ở đâu |
| --- | --- | --- |
| Mỗi service một database với cặp role migrator/app; không service nào đọc database của service khác. | [Database per service](https://microservices.io/patterns/data/database-per-service.html) | [ADR-0001](../adr/0001-service-boundaries-and-data-ownership.md), [`bootstrap.sql`](../../deploy/postgres/bootstrap.sql) |
| Postgres cloud là RDS for PostgreSQL 17, lớp production ở prd, mã hoá lúc nghỉ bằng KMS key riêng của module (cả Performance Insights và secret master), mật khẩu master do RDS quản, storage tự tăng tới trần theo env, tham số ghi log câu lệnh chậm, chờ khoá, autovacuum mà không ghi giá trị bind, Multi-AZ và thời hạn backup theo env; local chạy cùng major (container compose, CloudNativePG ở k3d lưu WAL liên tục và backup hằng ngày, có diễn tập phục hồi). | [AWS RDS best practices](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/CHAP_BestPractices.html), [PostgreSQL error reporting and logging](https://www.postgresql.org/docs/17/runtime-config-logging.html) | [ADR-0057](../adr/0057-postgres17-verify-full.md), [module `rds`](https://github.com/anhnvcoder/svp-infra/blob/main/aws/modules/rds/main.tf), [backup và phục hồi](reliability.md#backup-và-phục-hồi-postgres) |
| Mọi client Postgres nối `sslmode=verify-full`: kiểm cert server theo CA của nền tảng (CA local ở compose, k3d; bundle CA của RDS trên EKS) và theo tên host, một chuỗi kết nối ở mọi nơi; compose từ chối kết nối không TLS như `rds.force_ssl`. | [libpq SSL support](https://www.postgresql.org/docs/17/libpq-ssl.html), [RDS SSL/TLS](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/UsingWithRDS.SSL.html) | [ADR-0057](../adr/0057-postgres17-verify-full.md) §2, [TLS tới Postgres](deployment.md#tls-tới-postgres), [`rds-ca.yaml`](../../deploy/helm/svp-cluster/templates/rds-ca.yaml) |
| Cache và khoá là ElastiCache for Valkey (cluster mode tắt, TLS, user RBAC, `noeviction`, prd có replica khác AZ và failover, prd chờ cửa sổ bảo trì để đổi cấu hình, slow-log tới CloudWatch Logs); local chạy Valkey cùng phần mềm, cùng TLS và cùng access string. | [ElastiCache RBAC](https://docs.aws.amazon.com/AmazonElastiCache/latest/dg/Clusters.RBAC.html) | [ADR-0053](../adr/0053-msk-elasticache-valkey.md), [module `elasticache`](https://github.com/anhnvcoder/svp-infra/blob/main/aws/modules/elasticache/main.tf), [`aclfile.sh`](../../deploy/valkey/aclfile.sh) |
| User Valkey của mỗi service chỉ một db và một tiền tố khoá; user vận hành `svp-ops` đọc `svp:*` ở db 9, 10, 14 và chỉ xoá được hai tiền tố. Script và runbook chạm Kafka, Valkey chỉ qua CLI vận hành. | [Least privilege (NIST)](https://csrc.nist.gov/glossary/term/least_privilege) | [`aclfile.sh`](../../deploy/valkey/aclfile.sh), [`deploy/ops`](../../deploy/ops/svp-kafka), [threat model IN-10](../threat-model.md#45-mức-tin-cậy-giữa-các-service) |
| Dung lượng broker MSK tự tăng theo target tracking tới trần theo env, không bao giờ thu nhỏ; Terraform bỏ qua dung lượng đã tăng. | [MSK automatic scaling](https://docs.aws.amazon.com/msk/latest/developerguide/msk-autoexpand.html) | [ADR-0058](../adr/0058-managed-data-operations.md) §4, [module `msk`](https://github.com/anhnvcoder/svp-infra/blob/main/aws/modules/msk/main.tf) |
| RDS, MSK, ElastiCache ở tầng subnet database không route ra Internet; security group chỉ mở cổng của dịch vụ cho node EKS. | [AWS VPC subnets](https://docs.aws.amazon.com/vpc/latest/userguide/configure-subnets.html) | [ADR-0054](../adr/0054-data-subnet-tier.md), [module `network`](https://github.com/anhnvcoder/svp-infra/blob/main/aws/modules/network/main.tf) |
| Media HLS bất biến theo version (`media/<video_id>/<version>/`, master chỉ tạo một lần bằng `If-None-Match: *`), phát với `Cache-Control: max-age=31536000, immutable`; upload thẳng lên object storage. | [RFC 8246](https://www.rfc-editor.org/rfc/rfc8246) | [ADR-0029](../adr/0029-immutable-media-versions.md), [ADR-0004](../adr/0004-direct-upload-and-hls.md), [`worker`](../../services/media-worker/internal/worker/worker.go) |

## Observability và SLO

| Năng lực | Chuẩn | Ở đâu |
| --- | --- | --- |
| Trace, metric, log qua OpenTelemetry SDK tới một Collector riêng rồi tới Grafana LGTM; profile liên tục bằng Pyroscope; lỗi về GlitchTip (giao thức Sentry), có che email và JWT. | [OpenTelemetry](https://opentelemetry.io/docs/specs/otel/), [OTel semconv](https://opentelemetry.io/docs/specs/semconv/) | [ADR-0011](../adr/0011-observability-stage3.md), [`internal/telemetry`](../../internal/telemetry/telemetry.go), [`sentryx`](../../internal/sentryx/sanitize.go), [`observability.md`](observability.md) |
| Log JSON có cấu trúc (`slog`) mang `trace_id`. | [OTel logs data model](https://opentelemetry.io/docs/specs/otel/logs/data-model/) | [`internal/logx`](../../internal/logx/logx.go) |
| SLO khai báo bằng Sloth (danh sách ở `svp-slos.yaml`), cảnh báo burn rate đa cửa sổ (page 14,4x và 6x, ticket); rule viết tay có test. | [Google SRE workbook: alerting on SLOs](https://sre.google/workbook/alerting-on-slos/) | [`svp-slos.yaml`](../../deploy/observability/slo/svp-slos.yaml), [SLO](reliability.md#slo), [cảnh báo](observability.md#cảnh-báo) |
| Mỗi cảnh báo page có runbook (`runbook_url`); postmortem không đổ lỗi; RFC một trang. | [Google SRE book: postmortem culture](https://sre.google/sre-book/postmortem-culture/) | [`runbooks/`](../runbooks/README.md), [vận hành](reliability.md#vận-hành) |
| Lag consumer đọc bằng receiver `kafka_metrics` của Collector, đăng nhập user Kafka `svp-otelcol` chỉ có quyền DESCRIBE; cùng receiver và tên metric ở mọi môi trường. | [OTel Collector contrib](https://github.com/open-telemetry/opentelemetry-collector-contrib) | [`config.yaml`](../../deploy/observability/otelcol/config.yaml) (compose), [`k8s-config.yaml`](../../deploy/observability/otelcol/k8s-config.yaml) (cluster), [`svp-alerts.yaml`](../../deploy/observability/prometheus/rules/svp-alerts.yaml) |
| RUM của web (Web Vitals, INP) và SLO `web-inp`. | [Core Web Vitals](https://web.dev/articles/vitals) | [quan sát web](observability.md#web) |
| CloudWatch alarm cho RDS, MSK, ElastiCache, ngưỡng theo khuyến nghị của AWS, gửi SNS mã hoá bằng KMS key riêng tới email; sống độc lập với cluster; alarm page có runbook cùng tên. | [CloudWatch recommended alarms](https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/Best_Practice_Recommended_Alarms_AWS_Services.html), [MSK best practices](https://docs.aws.amazon.com/msk/latest/developerguide/bestpractices.html) | [ADR-0058](../adr/0058-managed-data-operations.md), [module `alarms`](https://github.com/anhnvcoder/svp-infra/blob/main/aws/modules/alarms/main.tf), [alarm của dịch vụ managed](observability.md#alarm-của-dịch-vụ-managed) |

## Xác thực và phân quyền

Chi tiết từng mối đe doạ và cách kiểm ở [threat model §4.1](../threat-model.md#41-jwt-và-đăng-nhập) và
[§4.5](../threat-model.md#45-mức-tin-cậy-giữa-các-service).

| Năng lực | Chuẩn | Ở đâu |
| --- | --- | --- |
| Mật khẩu băm argon2id với tham số của OWASP; đăng nhập trả cùng một lỗi và chạy hash giả khi không có user, nên không dò được email. | [OWASP Password Storage](https://cheatsheetseries.owasp.org/cheatsheets/Password_Storage_Cheat_Sheet.html), [OWASP Authentication](https://cheatsheetseries.owasp.org/cheatsheets/Authentication_Cheat_Sheet.html) | [`password`](../../services/user-service/internal/password/password.go) |
| Access token là JWT EdDSA (Ed25519) chọn khoá theo `kid`, cố định `alg`, `iss`, `aud`; user-service giữ khoá riêng, nơi kiểm chỉ giữ khoá công khai; xoay khoá theo runbook. | [RFC 8725](https://www.rfc-editor.org/rfc/rfc8725), [RFC 8037](https://www.rfc-editor.org/rfc/rfc8037) | [`internal/authtoken`](../../internal/authtoken/authtoken.go), [runbook xoay khoá](../runbooks/jwt-key-rotation.md) |
| Refresh token xoay vòng mỗi lần dùng, phát hiện dùng lại thì thu hồi cả họ, họ có hạn tuyệt đối. | [RFC 9700 §4.14](https://www.rfc-editor.org/rfc/rfc9700#section-4.14) | [`refresh.go`](../../services/user-service/internal/server/refresh.go), [ADR-0016](../adr/0016-web-client.md) |
| Service gRPC kiểm lại access token mà gateway chuyển tiếp, không tin header danh tính; kiểm quyền sở hữu video ở service. | [OWASP API1:2023 BOLA](https://owasp.org/API-Security/editions/2023/en/0xa1-broken-object-level-authorization/) | [ADR-0042](../adr/0042-caller-identity-grpc.md), [`internal/callerid`](../../internal/callerid/callerid.go) |
| Web là BFF: token chỉ ở server, trình duyệt giữ cookie `__Host-` HttpOnly; session có idle timeout 7 ngày và absolute timeout 30 ngày; chống CSRF bằng Fetch Metadata; CSP có nonce mỗi request. | [OWASP Session Management](https://cheatsheetseries.owasp.org/cheatsheets/Session_Management_Cheat_Sheet.html), [Fetch Metadata](https://www.w3.org/TR/fetch-metadata/), [CSP Level 3](https://www.w3.org/TR/CSP3/) | [ADR-0046](../adr/0046-web-session-lifetime.md), [`session.ts`](https://github.com/anhnvcoder/svp-frontend/blob/main/server/session.ts), [`csrf.ts`](https://github.com/anhnvcoder/svp-frontend/blob/main/server/csrf.ts), [`csp.ts`](https://github.com/anhnvcoder/svp-frontend/blob/main/server/csp.ts) |

## Xử lý input và upload

| Năng lực | Chuẩn | Ở đâu |
| --- | --- | --- |
| Upload thẳng lên bucket bằng presigned POST có ràng buộc kích thước và `Content-Type` `video/*`; server không tải URL do người dùng đưa (không SSRF). | [OWASP File Upload](https://cheatsheetseries.owasp.org/cheatsheets/File_Upload_Cheat_Sheet.html) | [ADR-0004](../adr/0004-direct-upload-and-hls.md), [threat model §4.2](../threat-model.md#42-presigned-post-và-bucket) |
| ffmpeg chỉ đọc protocol `file`, chỉ các demuxer và decoder trong danh sách cho phép. | [OWASP Input Validation](https://cheatsheetseries.owasp.org/cheatsheets/Input_Validation_Cheat_Sheet.html) | [`transcode`](../../services/media-worker/internal/transcode/transcode.go), [threat model §4.3](../threat-model.md#43-ffmpeg-đọc-file-người-dùng) |
| Query của service sinh bằng sqlc; SQL viết tay còn lại (outbox, migration) là chuỗi hằng có placeholder. Không câu SQL nào ghép input vào chuỗi. | [OWASP SQL Injection Prevention](https://cheatsheetseries.owasp.org/cheatsheets/SQL_Injection_Prevention_Cheat_Sheet.html) | [`make.md`](../reference/make.md), [`internal/outbox`](../../internal/outbox/relay.go) |

## Secrets

| Năng lực | Chuẩn | Ở đâu |
| --- | --- | --- |
| Secret của cluster do External Secrets Operator dựng từ AWS Secrets Manager (EKS, role theo namespace qua Pod Identity) hay namespace nguồn (k3d); không secret nào trong git. | [OWASP Secrets Management](https://cheatsheetseries.owasp.org/cheatsheets/Secrets_Management_Cheat_Sheet.html) | [ADR-0026](../adr/0026-secrets-gitops.md), [`external-secrets.yaml`](../../deploy/helm/svp-cluster/files/external-secrets.yaml), [module `external-secrets`](https://github.com/anhnvcoder/svp-infra/blob/main/aws/modules/external-secrets/main.tf) |
| Mật khẩu Kafka và Valkey trên EKS sinh bằng Terraform ephemeral, ghi qua đối số write-only: không vào plan hay state. | [Terraform ephemeral resources](https://developer.hashicorp.com/terraform/language/resources/ephemeral) | [ADR-0053](../adr/0053-msk-elasticache-valkey.md), [module `msk`](https://github.com/anhnvcoder/svp-infra/blob/main/aws/modules/msk/main.tf) |
| Kiểu `secret.String` che giá trị khi in ra log hay JSON. | [OWASP Logging](https://cheatsheetseries.owasp.org/cheatsheets/Logging_Cheat_Sheet.html) | [`internal/secret`](../../internal/secret/secret.go) |
| gitleaks quét toàn bộ lịch sử ở CI; hook `pre-commit` quét thay đổi đã stage. | [gitleaks](https://github.com/gitleaks/gitleaks) | [`ci.yml`](../../.github/workflows/ci.yml) |

## Chuỗi cung ứng

Đường đầy đủ từ PR tới pod ở [CI/CD và chuỗi cung ứng](delivery.md#cicd-và-chuỗi-cung-ứng).

| Năng lực | Chuẩn | Ở đâu |
| --- | --- | --- |
| Binary tĩnh `CGO_ENABLED=0 -trimpath` trên distroless `nonroot`; mọi image base, action và image công cụ ghim digest hay SHA. | [Distroless](https://github.com/GoogleContainerTools/distroless), [OpenSSF Scorecard: Pinned-Dependencies](https://github.com/ossf/scorecard/blob/main/docs/checks.md#pinned-dependencies) | [`service.Dockerfile`](../../deploy/docker/service.Dockerfile) |
| Image đa kiến trúc build trên CI; trivy chặn CRITICAL và mọi secret trước khi push. | [NIST SP 800-190](https://csrc.nist.gov/pubs/sp/800/190/final) | [`images.yml`](../../.github/workflows/images.yml), [`scan-gate.sh`](../../deploy/ci/scan-gate.sh), [ADR-0039](../adr/0039-mainpath-drills-scan-gate-sourcemaps.md) |
| SBOM SPDX bằng syft; ký keyless bằng Sigstore; attestation `vuln`, SBOM và provenance trong Sigstore bundle, mức SLSA Build L2. | [SLSA v1.0](https://slsa.dev/spec/v1.0/levels), [Sigstore](https://docs.sigstore.dev), [SPDX](https://spdx.dev) | [ADR-0027](../adr/0027-slsa-build-provenance.md), [ADR-0040](../adr/0040-sigstore-bundle-actions-attest.md) |
| Kyverno ở namespace `svp`: pod chỉ chạy image đã ký đúng nguồn, có attestation `vuln` không có CRITICAL và không cũ quá 72 giờ; stg, prd đòi thêm provenance. Đường GitOps chạy Enforce, đường dev chạy Audit cho bản build local không ký. | [Kyverno image verification](https://kyverno.io/docs/policy-types/image-validating-policy/) | [`imagevalidatingpolicy.yaml`](../../deploy/helm/svp-policy/templates/imagevalidatingpolicy.yaml), [`svp-policy/values.yaml`](../../deploy/helm/svp-policy/values.yaml), [overlay stg](https://github.com/anhnvcoder/svp-gitops/blob/main/envs/stg/svp-policy.yaml), [overlay prd](https://github.com/anhnvcoder/svp-gitops/blob/main/envs/prd/svp-policy.yaml) |
| Quét lại image đã phát hành hằng ngày và thay attestation `vuln`. | Continuous vulnerability management ([CIS Control 7](https://www.cisecurity.org/controls/continuous-vulnerability-management)) | [`images.yml`](../../.github/workflows/images.yml), [runbook](../runbooks/vuln-attestation-expired.md) |
| govulncheck chặn lỗ hổng Go mà code gọi tới; gosec trong golangci-lint; dependency-review trên PR; fuzz native cho các hàm parse. | [Go vulnerability management](https://go.dev/doc/security/vuln/) | [ADR-0030](../adr/0030-devsecops-supplement.md), [`make.md`](../reference/make.md) |
| Renovate mở PR cập nhật cho bản đã ra ít nhất 3 ngày. Tự merge khi check xanh chỉ có bản digest của image base, image của compose và image bên thứ ba của chart, và bản patch của image compose (chỉ chạy trên máy dev và CI); không bản tự merge nào sửa file có Code Owner; mọi thứ khác người đọc rồi merge. | [Renovate](https://docs.renovatebot.com) | [`renovate.json`](../../renovate.json), [ADR-0035](../adr/0035-renovate-automerge.md) |

## Hardening runtime

| Năng lực | Chuẩn | Ở đâu |
| --- | --- | --- |
| Namespace của dự án enforce Pod Security Standard `restricted`; container non-root, drop ALL, seccomp `RuntimeDefault`, root FS chỉ đọc, `automountServiceAccountToken: false`. | [Pod Security Standards](https://kubernetes.io/docs/concepts/security/pod-security-standards/) | [`namespaces.yaml`](../../deploy/helm/svp-cluster/templates/namespaces.yaml), [`svp-service/_helpers.tpl`](../../deploy/helm/svp-service/templates/_helpers.tpl) |
| NetworkPolicy chặn mặc định cả hai chiều, mỗi luồng mở riêng. | [Kubernetes NetworkPolicy](https://kubernetes.io/docs/concepts/services-networking/network-policies/) | [`networkpolicies.yaml`](../../deploy/helm/svp-cluster/templates/networkpolicies.yaml), [NetworkPolicy của obs](observability.md#networkpolicy) |
| Cổng publish chỉ trên loopback; UI của cluster chỉ mở bằng port-forward. | [OWASP Attack Surface Analysis](https://cheatsheetseries.owasp.org/cheatsheets/Attack_Surface_Analysis_Cheat_Sheet.html) | [threat model §4.8](../threat-model.md#48-bề-mặt-khác) |

## CI hardening

| Năng lực | Chuẩn | Ở đâu |
| --- | --- | --- |
| Workflow mặc định `permissions: {}`, mỗi job xin quyền của nó; action ghim SHA; checkout `persist-credentials: false`; job có `id-token` không dùng cache. | [GitHub Actions security hardening](https://docs.github.com/en/actions/security-guides/security-hardening-for-github-actions) | [`ci.yml`](../../.github/workflows/ci.yml), [`images.yml`](../../.github/workflows/images.yml) |
| zizmor lint bảo mật workflow; OpenSSF Scorecard chạy công khai. | [zizmor](https://docs.zizmor.sh), [OpenSSF Scorecard](https://scorecard.dev) | [`zizmor.yml`](../../.github/zizmor.yml), [`scorecard.yml`](../../.github/workflows/scorecard.yml) |
| Ruleset `main`: chỉ qua PR có check bắt buộc, chỉ squash, lịch sử thẳng; Code Owner trên đường nhạy cảm; ruleset viết bằng Terraform. | [GitHub rulesets](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-rulesets/about-rulesets) | [ADR-0041](../adr/0041-github-hardening.md), [`CODEOWNERS`](../../CODEOWNERS), [`rulesets.tf`](https://github.com/anhnvcoder/svp-infra/blob/main/github/rulesets.tf) |
| Promote stg, prd chỉ chạy trong CI bằng token GitHub App ngắn hạn, không credential trên máy. | [GitHub Apps](https://docs.github.com/en/apps) | [`images.yml`](../../.github/workflows/images.yml), [ADR-0037](../adr/0037-mainpath-standard-tools.md) |

## GitOps và hạ tầng

| Năng lực | Chuẩn | Ở đâu |
| --- | --- | --- |
| Repo cấu hình riêng `svp-gitops`; Argo CD kéo từ git, self-heal; mỗi thay đổi env là một PR có check `gitops-ok`. | [OpenGitOps](https://opengitops.dev) | [ADR-0025](../adr/0025-gitops-config-repo.md), [`applications.yaml`](https://github.com/anhnvcoder/svp-gitops/blob/main/argocd/apps/templates/applications.yaml) |
| Bootstrap EKS bằng GitOps Bridge: Terraform đưa giá trị cluster vào Argo CD, không script tự viết. | [GitOps Bridge](https://github.com/gitops-bridge-dev/gitops-bridge) | [ADR-0050](../adr/0050-bash-to-standard-tools.md), [`svp-infra` README](https://github.com/anhnvcoder/svp-infra/blob/main/README.md) |
| AWS Organizations với account riêng cho stg, prd và management chỉ để quản trị; SCP giới hạn region; organization trail; đăng nhập qua IAM Identity Center. | [AWS multi-account](https://docs.aws.amazon.com/whitepapers/latest/organizing-your-aws-environment/organizing-your-aws-environment.html) | [ADR-0048](../adr/0048-prd-aws.md), [`org-policies`](https://github.com/anhnvcoder/svp-infra/blob/main/aws/modules/org-policies/main.tf), [`audit-trail.tf`](https://github.com/anhnvcoder/svp-infra/blob/main/aws/org/audit-trail.tf) |
| Hạ tầng là Terraform với module chuẩn bọc mỏng; stg, prd cùng module khác tfvars; CI chỉ kiểm tĩnh (fmt, validate, tflint, trivy, `terraform test` trên provider giả), không credential. | [Terraform module structure](https://developer.hashicorp.com/terraform/language/modules/develop/structure) | [ADR-0034](../adr/0034-aws-stage7.md), [`svp-infra` README](https://github.com/anhnvcoder/svp-infra/blob/main/README.md) |
| CloudFront của media trên gói flat-rate Free có web ACL WAF. | [AWS WAF](https://docs.aws.amazon.com/waf/latest/developerguide/) | [ADR-0052](../adr/0052-cloudfront-flat-rate-free.md), [module `waf`](https://github.com/anhnvcoder/svp-infra/blob/main/aws/modules/waf/main.tf), [`cloudfront.tf`](https://github.com/anhnvcoder/svp-infra/blob/main/aws/modules/media/cloudfront.tf) |
| Node EKS do Karpenter tự quản tạo theo pod đang chờ (Graviton, consolidation, interruption Spot qua SQS), trên một managed node group hệ thống on-demand mỗi AZ một node; trần chi phí là `limits` của NodePool; gỡ trong buổi xoá hết node Karpenter trước `destroy`. | [EKS Best Practices: Karpenter](https://docs.aws.amazon.com/eks/latest/best-practices/karpenter.html), [Karpenter disruption](https://karpenter.sh/docs/concepts/disruption/) | [ADR-0056](../adr/0056-eks-platform-ha.md) §1–§3, §9, [`karpenter.yaml`](../../deploy/helm/svp-cluster/templates/karpenter.yaml), [`karpenter.tf`](https://github.com/anhnvcoder/svp-infra/blob/main/aws/modules/eks/karpenter.tf), [Karpenter](deployment.md#karpenter-node-theo-pod-đang-chờ) |
| Ingress Envoy có HPA từ hai replica, PDB, trải zone ở mọi nền tảng; admission Kyverno ba replica có PDB và trải zone trên EKS: mất một node hay một AZ không mất cổng vào hay admission. | [EKS Best Practices: Reliability](https://docs.aws.amazon.com/eks/latest/best-practices/application.html), [Kyverno HA](https://kyverno.io/docs/installation/methods/) | [ADR-0056](../adr/0056-eks-platform-ha.md) §4–§6, [`gateway.yaml`](../../deploy/helm/svp-cluster/templates/gateway.yaml), [`kyverno.yaml`](https://github.com/anhnvcoder/svp-gitops/blob/main/platforms/eks/kyverno.yaml) |
| Add-on EKS và AMI của node ghim version, cùng bản ở stg và prd; log control plane đủ năm loại; nâng minor theo runbook, stg trước prd. | [EKS Best Practices: Cluster upgrades](https://docs.aws.amazon.com/eks/latest/best-practices/cluster-upgrades.html) | [ADR-0056](../adr/0056-eks-platform-ha.md) §7, §8, §10, [`addons.tf`](https://github.com/anhnvcoder/svp-infra/blob/main/aws/modules/eks/addons.tf) |
| API Kubernetes chỉ có endpoint private ở cả stg và prd; máy vận hành tới nó qua tunnel Session Manager tới bastion không inbound, không khoá SSH, cổng local khác nhau theo env. | [EKS cluster endpoint](https://docs.aws.amazon.com/eks/latest/userguide/cluster-endpoint.html), [Session Manager](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager.html) | [module `ssm-bastion`](https://github.com/anhnvcoder/svp-infra/blob/main/aws/modules/ssm-bastion/main.tf), [API của cluster](../reference/eks.md#target-eks-) |
| stg chạy cùng dịch vụ, cấu hình, xác thực, mã hoá và giám sát với prd; chỉ dự phòng, cỡ, số lượng, retention, bảo vệ xoá được giảm, mỗi khác biệt là dữ liệu có lý do và chỗ kiểm bù. | [Twelve-Factor: dev/prod parity](https://12factor.net/dev-prod-parity), [AWS Well-Architected REL10](https://docs.aws.amazon.com/wellarchitected/latest/reliability-pillar/rel_fault_isolation_multiaz_region_system.html) | [ADR-0055](../adr/0055-environment-matrix.md), [`environments.md`](environments.md) |
| Zone DNS của env trong account của env, zone stg uỷ quyền từ zone prd. | [Route 53 subdomain delegation](https://docs.aws.amazon.com/Route53/latest/DeveloperGuide/dns-routing-traffic-for-subdomains.html) | [ADR-0051](../adr/0051-dns-prd-apex.md) |
| Mỗi buổi cloud kết thúc bằng destroy và quét tài nguyên sót chỉ đọc qua API, độc lập với state; budget alert ở mọi account. | [AWS cost optimization](https://docs.aws.amazon.com/wellarchitected/latest/cost-optimization-pillar/welcome.html) | [`sweep.sh`](https://github.com/anhnvcoder/svp-infra/blob/main/aws/scripts/sweep.sh) |

## Kiểm thử

Quy ước ở [`reference/testing.md`](../reference/testing.md).

| Năng lực | Chuẩn | Ở đâu |
| --- | --- | --- |
| `go test -race` trên Postgres và Redis thật (database `_test`, tiền tố khoá ngẫu nhiên); Kafka bằng broker trong bộ nhớ `kfake`. | [Go race detector](https://go.dev/doc/articles/race_detector) | [`internal/pgtest`](../../internal/pgtest/), [`internal/redistest`](../../internal/redistest/) |
| Fuzz native cho các hàm parse (JWT, page token, handle, email, địa chỉ client…; `make fuzz` liệt kê). | [Go fuzzing](https://go.dev/doc/security/fuzz/) | [`pagetoken` fuzz](../../internal/pagetoken/fuzz_test.go), [ADR-0030](../adr/0030-devsecops-supplement.md) |
| Hợp đồng: `buf breaking`, oasdiff, `make generate-check`; DAST Schemathesis trên stack của CI (chỉ báo). | [Schemathesis](https://schemathesis.readthedocs.io) | [`deploy/dast`](../../deploy/dast/run.sh) |
| Tải k6 bằng image ghim, tag `route` khớp nhãn của server; profile `ci` chạy trong job `stack` của CI (stack compose đầu-cuối, chỉ báo, không chặn merge) khi PR đổi code hay cấu hình mà stack dùng. | [k6](https://grafana.com/docs/k6/latest/) | [`deploy/k6`](../../deploy/k6/), [`ci.yml`](../../.github/workflows/ci.yml), [tải](reliability.md#tải) |
| Diễn tập trên cluster bằng Chainsaw (chuỗi cung ứng, threat model); policy Kyverno và conftest có test, Rego qua Regal; rule cảnh báo có test. | [Chainsaw](https://kyverno.github.io/chainsaw/) | [`deploy/k8s/drills`](../../deploy/k8s/drills/), [kiểm chứng trên runner](reliability.md#kiểm-chứng-trên-runner) |
| Module Terraform có `terraform test` trên provider giả, trong container không mạng. | [Terraform test](https://developer.hashicorp.com/terraform/language/tests) | [`svp-infra` README](https://github.com/anhnvcoder/svp-infra/blob/main/README.md) |
