# 0053. Kafka và Redis của stg, prd là Amazon MSK provisioned và ElastiCache for Valkey; compose và k3d chạy cùng phần mềm, cùng đường code của client: SCRAM-SHA-512 trên TLS cổng 9096, user ACL Valkey theo db và tiền tố

- Trạng thái: Chấp nhận
- Ngày: 2026-11-08
- Người quyết: người học (2026-11-08: nguyên tắc managed/local, MSK và ElastiCache cho stg, prd); AI theo giao (phần còn lại, theo chuẩn ngành)

## Bối cảnh và vấn đề

- [0034](0034-aws-stage7.md) Câu 11 A chạy Redpanda, Valkey trong cluster EKS, hẹn xét MSK, ElastiCache khi prd cần độ bền; [0049](0049-kafka-prd.md) cho prd
  ba broker Redpanda. Chưa buổi stg nào chạy, nên đổi lúc này không phải chuyển dữ liệu. Người học chốt nguyên tắc §1 cho mọi cloud của dự án.
- Local lệch cloud: compose không SASL, Redis native không mật khẩu; k3d chạy Redpanda SCRAM-SHA-256 không TLS, Valkey không mật khẩu
  ([0014](0014-kubernetes-local-stage4.md) §4, §5, §14). MSK chỉ nhận SCRAM-SHA-512 và bật TLS khi dùng SCRAM [N4]: code xanh ở local có thể hỏng trên cloud.
- Ràng buộc như 0034, [0048](0048-prd-aws.md): repo public, AI không chạy lệnh chạm account, buổi tối đa 4 giờ, SCP chỉ `ap-southeast-1`, `us-east-1`.

## Yếu tố quyết định

- Một đường code client cho compose, k3d, EKS: cùng phần mềm hay giao thức, cùng xác thực, TLS, cổng; khác biệt chỉ là dữ liệu.
- Dịch vụ managed theo chuẩn ngành ở stg, prd; prd mất một AZ không mất event đã xác nhận; dựng, gỡ trong buổi; chi phí có nguồn.
- Quyền tối thiểu theo service giữ nguyên: ACL Kafka theo service (0014 §5), Redis theo db và tiền tố khoá.

## Phương án đã cân nhắc

Trạng thái ngành, giá, nguồn đọc 2026-11-08; in đậm là lựa chọn; được, mất và giá từng phương án: [phụ lục](appendix/0053-msk-elasticache-valkey.md#phương-án).

- Kafka cloud: Redpanda trong cluster (0049, tự vận hành, trái §1); **MSK provisioned, broker Standard**; MSK Express (quá cỡ, $0,51/broker-giờ [N13]);
  MSK Serverless (chỉ IAM, không ACL Kafka [N11]). Xác thực: **SCRAM-SHA-512 trên TLS** (local làm y hệt [N25]); IAM qua EKS Pod Identity (ACL không
  tác dụng với danh tính IAM [N11], local không có IAM).
- Kafka local: giữ Redpanda (khác phần mềm MSK); Strimzi trên k3d (KafkaUser, KafkaTopic, CA của operator [N28] là đường thứ ba chỉ có ở k3d);
  **image chính thức `apache/kafka`**.
- Redis cloud: Serverless, cluster mode bật (giao thức cluster [N18], client khác local standalone); **node-based, cluster mode tắt**; **giữ db 9/10/14
  với ACL `db=` [N15] cộng tiền tố `svp:<service>:`** hay dồn về db 0 chỉ với tiền tố; xác thực bằng AUTH token chung, IAM (token SigV4 15 phút [N20],
  local không có IAM) hay **user RBAC (ACL Valkey)**.
- Vận hành: pod tạm `kubectl run` mỗi lần; **Deployment `svp-ops` thường trực** (§13).

## Kết quả quyết định

Chọn các phương án in đậm: đạt §1 với dịch vụ managed ở stg, prd, client một đường code, quyền theo service ở cả Kafka và Redis. Cái giá: trần buổi prd
~$6,6 thành ~$11,0, stg thêm ~$0,6 (§16); quản mật khẩu; MSK dựng, gỡ lâu; một Deployment giữ mật khẩu vận hành (§13). Chi tiết: [phụ lục](appendix/0053-msk-elasticache-valkey.md#chi-tiết-rút-khỏi-adr).

### 1. Nguyên tắc managed/local

Luật chung cho mọi cloud của dự án (AWS bây giờ, GCP sau): trên cloud (stg, prd), cái gì ngành chạy managed thì dùng dịch vụ managed của cloud đó; local
(compose, k3d) không chép dịch vụ cloud nhưng chạy cùng phần mềm hay cùng giao thức và cùng đường code của client: cùng cơ chế xác thực, TLS, cổng. Chỗ
local buộc khác là dữ liệu cấu hình (giá trị, file, biến), không là nhánh `if` theo môi trường, và được ghi trong ADR (ở đây §17). Chọn theo chuẩn
ngành, không vì rẻ hay nhẹ. ADR của cloud sau áp luật này cho dịch vụ tương ứng.

### 2. Kafka cloud: MSK provisioned

- Broker Standard, Kafka 4.1.x: bản mới nhất cho broker Standard, có ở mọi region của MSK, MSK tự lên bản vá [N1]; Kafka 4 chỉ KRaft [N10]. Chuỗi API
  `kafka_version = "4.1.x.kraft"` (AWS CDK, test của provider [N32]; trang MSK không nêu chuỗi API của 4.1), `kafka_versions` của `aws_msk_configuration` cùng chuỗi.
  Số broker bằng số AZ: stg 2 × `kafka.t3.small`, prd 3 × `kafka.m7g.large` (T3 cho dev, tải thấp; M7g, M5 cho production [N2]); EBS 10 GiB mỗi broker.
- Private subnet của env (cùng subnet RDS); security group chỉ mở TCP 9096 từ node SG và cluster primary SG của EKS; `client_broker = "TLS"`,
  `in_cluster = true` [N22]; at-rest bằng KMS key customer managed của module (cũng khoá của secret SCRAM); chỉ SASL/SCRAM. `aws_msk_configuration`:
  `auto.create.topics.enable=false`, `allow.everyone.if.no.acl.found=true` (§5), khoá của §6. Broker log: prd tới CloudWatch Logs giữ 30 ngày, stg tắt.

### 3. Kafka local

Image chính thức `apache/kafka:4.1.2`, bản 4.1.x mới nhất (2026-03-17 [N27]), ghim digest, cùng `x.y` với §2 (nâng cả hai trong một thay đổi); một tiến
trình KRaft (broker + controller), `StandardAuthorizer` [N25]. compose: service `kafka`, init `kafka-init`; k3d: StatefulSet `kafka`, Job `kafka-init` ở
`svp-data` khi chart `svp-data` đặt `kafka.mode: cluster` (`external` trên eks). Không Strimzi; Redpanda (image, chart, `rpk`, `/public_metrics`) gỡ hết.

### 4. Listener Kafka và client

- Client nói SASL_SSL, SCRAM-SHA-512, cổng 9096 ở mọi môi trường (cổng SCRAM của MSK [N7]): compose `kafka:9096`, k3d `kafka.svp-data.svc.cluster.local:9096`,
  EKS `cluster.kafkaBrokers` (§14). Broker local quảng bá đúng địa chỉ đó (tên Service có trong SAN của CA local, §11); listener controller, liên broker
  của nó là PLAINTEXT bind `localhost`; không cổng host nào publish (bỏ `127.0.0.1:19092`).
- `internal/kafkax`: `KAFKA_SASL_USERNAME`, `KAFKA_SASL_PASSWORD` đều đặt thì SCRAM-SHA-512 (`AsSha512Mechanism`) trên TLS (`DialTLSConfig` [N29]), root
  của hệ thống, kiểm tên theo host broker; cả hai trống thì plaintext (chỉ test với `kfake`); chỉ một thì lỗi. Không biến bật, tắt TLS.

### 5. User Kafka và mô hình quyền

- User `svp-admin`, `svp-user-service`, `svp-video-service`, `svp-engagement-service`, `svp-feed-service`, `svp-media-worker`, `svp-keda`, `svp-otelcol`
  (mới). ACL của service, `svp-keda` như bảng của `deploy/helm/svp-data/files/kafka-users.sh` (literal, phụ lục §5); `svp-otelcol` chỉ DESCRIBE 8 topic,
  4 group `video-service`, `engagement-service`, `feed-service`, `media-worker`. Producer idempotent chỉ cần WRITE trên topic (KIP-679 [N26]).
- `allow.everyone.if.no.acl.found=true` ở mọi broker (mặc định MSK [N5]; MSK không cho đặt `super.users` [N6]); script init cấp `svp-admin` ALL trên
  CLUSTER, TOPIC `*`, GROUP `*`, TRANSACTIONAL_ID `*` trước mọi ACL khác, nên mọi tài nguyên có ACL và user khác chỉ có quyền được cấp [N25]; `super.users`
  của broker local chỉ `User:ANONYMOUS` của listener PLAINTEXT `localhost`.
- Local, broker giữ credential (`svp-admin` lúc `kafka-storage format --add-scram` [N25], user khác bằng `kafka-configs`); MSK: secret `AmazonMSK_svp-<env>-<user>`
  (JSON `username`, `password`, KMS key của §2) gắn bằng `aws_msk_scram_secret_association`, tới broker trong tối đa 10 phút [N4]. Topic, ACL ở mọi nơi
  do cùng script init (Kafka CLI của §3, `svp-admin`), bỏ bước tạo user khi `kafka.mode: external`; Job `kafka-init` thử lại ít nhất 10 phút.

### 6. Replication và độ bền

Topic lấy RF của broker: `default.replication.factor`/`min.insync.replicas` local 1/1, stg 2/1, prd 3/2 (mặc định MSK cho 2, 3 AZ [N6]), MSK đặt qua
`aws_msk_configuration` từ biến của root env, cùng `offsets.topic.replication.factor`, `transaction.state.log.replication.factor` bằng RF và
`transaction.state.log.min.isr` bằng min ISR (MSK để ba khoá này ở 3 của Kafka, topic nội bộ không tạo được khi ít broker hơn [N6]). `acks=all` idempotent
(0049 §2): prd mất một AZ không mất event đã xác nhận, vẫn ghi được; stg không hứa điều đó. Consumer vẫn idempotent ([0003](0003-async-events-outbox.md)).

### 7. Redis cloud: ElastiCache for Valkey

- Replication group node-based, cluster mode tắt, `engine = "valkey"`, `engine_version = "9.1"` (bản đầu có ACL `db=` [N14]); parameter group họ `valkey9`
  với `maxmemory-policy noeviction` (mặc định `volatile-lru` [N17]); không snapshot. `transit_encryption_mode = "required"` (RBAC cần TLS [N15]), at-rest
  bật; user group engine VALKEY với user của §9, không AUTH token, không IAM. Tên cluster vào log Certificate Transparency [N16]: chỉ `svp-<env>-…`.
- stg 1 node `cache.t4g.micro` (0,5 GiB [N18]); prd primary + replica `cache.m7g.large` (6,38 GiB [N18]) ở hai AZ, Multi-AZ, automatic failover (T4g chỉ
  hợp tải CPU luôn dưới mức nền [N18]). Private subnet của env; security group chỉ mở TCP 6379 từ node SG và cluster primary SG.

### 8. Redis local

Image Valkey đang ghim của `svp-data` (`docker.io/valkey/valkey:9.1.3-alpine`, cùng bản cho compose, cùng 9.1 với §7), TLS trên 6379 (CA local, §11),
aclfile với user của §9. compose có container `valkey` thay Redis native db 9/10/14, không publish cổng; script trên host chạm nó qua §13; test như §17.

### 9. User Valkey và access string

Nguyên văn cho aclfile (sau `user <tên>`, thêm `>…`) và `aws_elasticache_user.access_string`; `ACL LIST` của Valkey 9.1.3 trả lại đúng chuỗi; ElastiCache
nhận selector `(…)` và `db=` từ Valkey 9.1 [N15]. HELLO, AUTH luôn được phép [N21]; không client nào gửi PING; SCAN trả tên mọi khoá của db, không lọc theo
`~` (db 9, 10, 14 chỉ chứa `svp:*`). Lý do từng lệnh, đọc từ code client [N31], và phép thử: phụ lục §9.

- `svp-gateway`: `on ~svp:gw:* resetchannels db=10 -@all +select +client|setinfo +eval +evalsha +time +get +set +del`
- `svp-feed-service`: `on ~svp:feed:* resetchannels db=14 -@all +select +client|setinfo +get +set`
- `svp-web`: `on ~svp:web:* resetchannels db=9 -@all +select +client|setinfo +eval +get +set +del +exists`
- `svp-ops`: `on ~svp:* resetchannels db=9,10,14 -@all +select +ping +time +scan +get +mget +pttl (~svp:gw:rl:register:* resetchannels db=10 -@all +del) (~svp:feed:explore:* resetchannels db=14 -@all +del)`
- `default`: `off` (aclfile `user default off`); ElastiCache tự tắt `default` khi gắn user group engine VALKEY [N15], không tạo user này.

### 10. REDIS_URL

`rediss://<user>:<password>@<host>:6379/<db>` ở compose, k3d, EKS, trong Secret của service như `DATABASE_URL`; host qua placeholder `${valkey}` của template
ExternalSecret (chart `svp-cluster`; k3d `valkey.svp-data.svc.cluster.local`, EKS `cluster.valkeyHost`). `redisx`, client Node của web không đổi code.

### 11. CA local và cách client tin nó

`make env` sinh một lần vào `backend/.local/ca/` (gitignore) CA và cert server cho tên Service của `kafka`, `valkey` và `localhost`; compose chép cert, khoá
qua container `tls-init` vào volume với owner là uid của image server, k3d nạp thành Secret (phụ lục §11). Client tin CA qua dữ liệu: Go `SSL_CERT_DIR`, Node
`NODE_EXTRA_CA_CERTS`, Kafka CLI truststore PEM, `valkey-cli --cacert`, KEDA `ca`, Collector `tls.ca_file`; EKS không đặt gì (CA công khai [N8], [N16]).

### 12. Mật khẩu và Secret trên cluster

Biến `.env`, cũng là khoá của entry Secrets Manager: `SVP_KAFKA_*_PASSWORD` thêm `SVP_KAFKA_OTELCOL_PASSWORD`; `SVP_VALKEY_GATEWAY_PASSWORD`,
`SVP_VALKEY_FEED_SERVICE_PASSWORD`, `SVP_VALKEY_WEB_PASSWORD`, `SVP_VALKEY_OPS_PASSWORD` ở entry mới `svp/<env>/valkey-users`. EKS: Terraform sinh bằng
ephemeral `random_password` của `hashicorp/random` (`length = 32`, `special = false`), chỉ ghi qua đối số write-only (`secret_string_wo`, `passwords_wo` [N22]),
không vào plan, state; một giá trị vào cả secret `AmazonMSK_*` và entry `kafka-*`, user ElastiCache và `valkey-users`. Chỉ chữ và số vì mật khẩu chèn thẳng
vào `REDIS_URL`, JAAS, aclfile; `make eks-secrets` thôi ghi ba entry đó. Đổi: tăng `_wo_version` rồi apply. Cách đổi và Secret trên cluster: phụ lục §12.

### 13. CLI vận hành

Đường duy nhất để script, drill, runbook, lệnh buổi chạm Kafka, Valkey: `/opt/svp/bin/svp-kafka` (§3, `svp-admin`), `/opt/svp/bin/svp-valkey`
(`--user svp-ops`) ở `deploy/ops/`, chạy trong container `kafka`, `valkey` của compose và Deployment `svp-ops` ở k3d, EKS; `SVP_AS_USER` đăng nhập user
thường để kiểm quyền. Đánh đổi: một pod thường trực giữ mật khẩu `svp-admin`, `svp-ops`, đổi lấy một đường kiểm được (cách giảm: phụ lục §13).

### 14. Hợp đồng `cluster.*` thêm

`kafkaBrokers` = output `bootstrap_brokers` của module `msk` (`host:9096,…` [N22]), `valkeyHost` = output `primary_endpoint_address` của module
`elasticache`; sinh ở `cluster_values` của hai root env, kiểm ở `gitops-bridge` và `$shapes` của `applications.yaml`; dạng kiểm, ví dụ, nơi đọc: phụ lục §14.

### 15. Chỉ số lag và KEDA

- Collector dùng receiver `kafkametrics` (contrib 0.164.0, beta [N24]) đăng nhập `svp-otelcol` SCRAM-SHA-512 trên TLS ở mọi nơi, thay `/public_metrics`;
  dashboard, rule, runbook dùng `kafka.consumer_group.lag` [N24]. Biến: `SVP_KAFKA_OTELCOL_PASSWORD`, `SVP_OTELCOL_KAFKA_BROKERS`, `SVP_OTELCOL_KAFKA_CA_FILE` (rỗng trên eks).
- KEDA 2.21: Secret `keda/keda-kafka` có `sasl=scram_sha512`, `tls=enable`, `username=svp-keda`, `password`, `ca` chỉ ở local [N23].

### 16. Buổi: thời gian và chi phí

- Tài liệu không ghi thời gian dựng, gỡ [N12]. **Giả định**, đo ở buổi stg: MSK dựng ≤ 45, gỡ ≤ 30 phút; ElastiCache ≤ 20, ≤ 15; buổi dài thêm ~30 phút
  apply, ~20 phút destroy, vừa trần 4 giờ. `sweep.sh` liệt kê MSK, ElastiCache, secret sót.
- Công thức 0048 §10, giá `ap-southeast-1` [N13], [N19], [N30], bảng ở phụ lục. **stg:** H_k ~$0,144/giờ, buổi ~$3,0 với node Spot, ~$3,7 on-demand, dưới
  trần $5. **prd:** H_k ~$1,09/giờ, **C ≈ $11,0**, thay ~$6,6 của 0049. R không đổi.

### 17. Khác biệt local buộc phải có

Mỗi cái là dữ liệu, không nhánh code: CA local thay CA công khai của Amazon (§11); user Kafka do broker giữ thay secret gắn vào MSK (§5);
một broker, RF 1, min ISR 1 (§6), Valkey một node; `make test` của backend, web trên Redis native db 15 và `make dev` của web trên db 9,
không TLS, không user.

### Hệ quả

- Tốt: compose, k3d chạy cùng phần mềm, xác thực, TLS, cổng với stg, prd; IN-4, IN-7 thực thi cả ở compose; EKS không còn broker tự vận hành; prd chịu mất AZ.
- Xấu: trần buổi prd ~$11,0 (+$4,4), stg +$0,6; MSK dựng, gỡ hàng chục phút; đổi mật khẩu trên EKS chờ tới 10 phút; Kafka JVM nặng hơn Redpanda trên
  máy 16 GB; một pod giữ mật khẩu vận hành; CA local phải sinh và nạp; MSK Standard dừng ở Kafka 4.1 khi cộng đồng đã có 4.4.0 [N27].
- Xem lại khi: MSK có Kafka mới hơn cho broker Standard; MSK dựng + gỡ quá 75 phút hay buổi chạm trần 4 giờ; cần dữ liệu Kafka, Redis sống qua buổi;
  ElastiCache từ chối hay viết lại một access string của §9; dự án lên GCP (áp §1).

## Xác nhận

- Lúc quyết: năm access string chạy trên image Valkey 9.1.3 đang ghim, container không mạng: `ACL LIST` trả nguyên chuỗi, lệnh của client được nhận,
  lệnh, db, khoá ngoài quyền bị NOPERM (phụ lục §9). Chưa kiểm trên AWS; khi hiện thực: `make check` của `svp-infra` và repo này, `make helm-check`.
- Buổi stg: (a) apply nhận `kafka.t3.small` với `4.1.x.kraft` và SCRAM, Valkey 9.1 với năm access string; MSK `ACTIVE`, ghi phút dựng, gỡ; `plan` lần hai `No changes`;
  (b) service sản xuất, tiêu thụ qua SCRAM-SHA-512 TLS, smoke xanh; (c) `svp-kafka` với `SVP_AS_USER` một service bị từ chối trên topic mới không ACL;
  (d) `svp-valkey` với `SVP_AS_USER=svp-feed-service` không `SELECT 10`, với `svp-gateway` không đọc `svp:feed:*`; (e) lag hiện trên dashboard; (f) sweep sạch.
- Buổi prd: (g) khởi động lại một broker khi đang ghi không mất event; (h) failover Valkey không làm service lỗi quá timeout của nó.

## Hiện thực ở

- Repo code: `internal/kafkax/`, `docs/reference/environment.md` (§4, §11); `deploy/compose/`, `deploy/kafka/`, `deploy/valkey/`, `deploy/ops/`,
  `.env.example`, `Makefile` (§3, §8, §11, §13); `deploy/helm/svp-data/` (§3, §5, §6, §8, §13); `deploy/helm/svp-cluster/`, `deploy/k8s/` (§11–§13);
  `deploy/helm/svp-service/`, `deploy/ci/cluster-values.example.yaml` (§10, §14, §15); `deploy/observability/`, `deploy/helm/svp-observability/` (§15).
- `svp-infra`: `aws/modules/msk/` (§2, §5, §6), `aws/modules/elasticache/` (§7, §9), `aws/envs/stg/`, `aws/envs/prd/`, `aws/modules/external-secrets/`,
  `aws/modules/gitops-bridge/` (§6, §12, §14), `aws/scripts/`, `docs/runbooks/session-stg.md`, `session-prd.md` (§16). `svp-frontend`: `e2e/`,
  `Makefile`, CI (§8).
- `svp-gitops`: `argocd/apps/components.json`, `argocd/apps/templates/`, `base/`, `platforms/eks/`, `envs/prd/` (§2, §7, §12, §14, §15).

## Nguồn

Đọc 2026-11-08; đủ [N1]–[N32] và bảng giá ở phụ lục. [N1] <https://docs.aws.amazon.com/msk/latest/developerguide/supported-kafka-versions.html>, [N4] <https://docs.aws.amazon.com/msk/latest/developerguide/msk-password-limitations.html>, [N6] <https://docs.aws.amazon.com/msk/latest/developerguide/msk-default-configuration.html>, [N14] <https://docs.aws.amazon.com/AmazonElastiCache/latest/dg/engine-versions.html>, [N15] <https://docs.aws.amazon.com/AmazonElastiCache/latest/dg/Clusters.RBAC.html>, [N21] <https://valkey.io/topics/acl/>, [N32] <https://github.com/aws/aws-cdk/blob/v2.275.0/packages/@aws-cdk/aws-msk-alpha/lib/cluster-version.ts>.

## Thông tin thêm

Phụ lục: [`appendix/0053-msk-elasticache-valkey.md`](appendix/0053-msk-elasticache-valkey.md) (bảng phương án, chi tiết từng §, phép thử access string, chi phí, nguồn).

### Chỉnh bởi

- §2, §7: [0054](0054-data-subnet-tier.md): broker MSK và ElastiCache ở subnet database của VPC (cùng RDS, route table không `0.0.0.0/0`) thay private subnet của node.
