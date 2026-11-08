# Phụ lục ADR-0053: Kafka và Redis của stg, prd là Amazon MSK provisioned và ElastiCache for Valkey; compose và k3d chạy cùng phần mềm, cùng đường code của client: SCRAM-SHA-512 trên TLS cổng 9096, user ACL Valkey theo db và tiền tố

Phụ lục của [ADR-0053](../0053-msk-elasticache-valkey.md): bảng phương án, chi tiết rút khỏi ADR (xếp theo §), phép thử access string, chi phí H_k, O_k,
trần C của stg và prd, nguồn. Mọi nguồn đọc ngày 2026-11-08 trừ khi ghi khác. Giá: bảng giá AWS cho `ap-southeast-1`; đơn vị và công thức theo
[ADR-0048](../0048-prd-aws.md) §10.

## Phương án

### Kafka cloud

| Phương án | Trạng thái ngành | Cỡ stg / prd | Broker (USD/giờ) stg / prd | Xác thực, quyền | Được | Mất |
| --- | --- | --- | --- | --- | --- | --- |
| Redpanda trong cluster ([0049](../0049-kafka-prd.md)) | Thông dụng; hãng khuyên Operator cho production (0049) | 1 / 3 pod | ~0 / 0,004 (PVC) | SCRAM-SHA-256, ACL | Không dịch vụ AWS mới, rẻ nhất | Tự vận hành broker có trạng thái trên EKS; phần mềm khác MSK; trái §1 |
| **MSK provisioned, broker Standard** | Thông dụng | 2 × `kafka.t3.small` / 3 × `kafka.m7g.large` | 0,1156 / 0,765 [N13] | SCRAM-SHA-512 qua Secrets Manager, ACL Kafka [N4], [N5] | Managed, KRaft, Kafka 4.1 [N1]; local chạy cùng phần mềm | Mật khẩu qua Secrets Manager với KMS key riêng; dựng, gỡ hàng chục phút |
| MSK Express | Mới (2024), hiện hành | không có cỡ nhỏ / 3 × `express.m7g.large` | — / 1,53 (+ $0,0125/GB ghi) [N13] | Như Standard | Không quản lưu trữ; Kafka 4.2 chỉ có trên Express [N1] | Gấp đôi Standard cùng cỡ, quá cỡ cho lab |
| MSK Serverless | Hiện hành | 1 cluster | 0,9375 + $0,001875/partition-giờ [N13] | Chỉ IAM, không ACL Kafka [N11] | Không chọn cỡ | Đổi xác thực và mô hình quyền; local không có tương đương |

### Xác thực Kafka

| Phương án | Hiện thực ở từng client | Được | Mất |
| --- | --- | --- | --- |
| **SCRAM-SHA-512 trên TLS** | Broker Apache Kafka lưu SCRAM trong metadata log, `kafka-storage format --add-scram`, `kafka-configs` [N25]; MSK: secret `AmazonMSK_*` [N4]; franz-go `pkg/sasl/scram` [N29]; KEDA `sasl: scram_sha512` [N23]; Collector `mechanism: SCRAM-SHA-512` [N24] | Một cơ chế ở compose, k3d, EKS; giữ ACL theo service | Quản mật khẩu; KMS key customer managed bắt buộc [N4]; đổi mật khẩu tới 10 phút mới tới broker [N4] |
| IAM qua EKS Pod Identity | franz-go `pkg/sasl/aws` [N29]; KEDA `sasl: oauthbearer`, `saslTokenProvider: aws_msk_iam` [N23]; Collector `AWS_MSK_IAM_OAUTHBEARER` [N24] | Không mật khẩu dài hạn | ACL Kafka và `allow.everyone.if.no.acl.found` không có tác dụng với danh tính IAM [N11]: quyền thành IAM policy; local không có IAM: hai cơ chế |
| mTLS | Cần AWS Private CA (0049) | Không mật khẩu | Private CA tính tiền theo tháng; local cần CA cấp cert client mỗi service |

### Kafka local

| Phương án | Được | Mất |
| --- | --- | --- |
| Giữ Redpanda | Nhẹ RAM; không đổi chart | Phần mềm khác MSK: cấu hình, công cụ `rpk`, không có `min.insync.replicas` (0049 §2): cái chạy ở local không phải cái chạy trên cloud |
| Strimzi trên k3d | Cách chuẩn chạy Kafka trên Kubernetes, Apache 2.0, CNCF incubating (0049) | KafkaUser (xác thực `scram-sha-512`), KafkaTopic và cluster CA do operator quản [N28]; cloud không chạy operator, compose không có operator: ba đường cho user, topic, CA; thêm CRD và controller |
| **Image chính thức `apache/kafka` 4.1.2** | Cùng phần mềm, cùng `x.y` với MSK [N27]; một bộ cấu hình và một script init cho compose, k3d | JVM nặng hơn Redpanda; tự viết StatefulSet, init |

### Redis cloud và phân vùng

| Phương án | Giá (USD/giờ) stg / prd | Được | Mất |
| --- | --- | --- | --- |
| ElastiCache Serverless | ~0,0101 (tối thiểu 0,1 GB × $0,101/GB-giờ) + $0,0027/triệu ECPU [N19] / theo dùng | Rẻ nhất cho stg, không chọn cỡ | Chạy cluster mode, chỉ nhận client có TLS [N18]: client cluster khác client standalone của local |
| Node-based, cluster mode bật | Như dòng dưới (một shard) | Scale ngang; từ Valkey 9.0 có nhiều db (`cluster-databases`) [N14], [N17] | Client cluster (`redis.NewClusterClient`, `createCluster`), khoá của một script cùng slot; local phải chạy cluster nhiều primary |
| **Node-based, cluster mode tắt** | 0,0192 (1 × `cache.t4g.micro`) / 0,3152 (2 × `cache.m7g.large`) [N19] | Client standalone như local, db 0–15 | Không scale ngang (dữ liệu dưới 64 MB như local, không cần) |
| **Giữ db 9/10/14, ACL `db=`, tiền tố** | | Không đổi URL, code, bảng db của `AGENTS.md`; hai lớp ranh giới (db, tiền tố) | Cần Valkey 9.1 [N14] |
| Dồn về db 0, chỉ tiền tố | | Chạy cả với Valkey cũ | Đổi URL của gateway, feed-service, web và bảng db của `AGENTS.md`; Redis native db 0 có dữ liệu dự án khác |

### Xác thực Redis

| Phương án | Được | Mất |
| --- | --- | --- |
| AUTH token | Một mật khẩu | Client nào có token cũng toàn quyền [N15] |
| IAM | Không mật khẩu dài hạn | Token 15 phút ký SigV4 trong client, kết nối tự ngắt sau 12 giờ [N20]; local không có IAM |
| **User RBAC (ACL Valkey)** | Quyền theo user; cùng access string ở aclfile local và ElastiCache [N15], [N21] | Quản mật khẩu từng user |

### Vận hành

| Phương án | Được | Mất |
| --- | --- | --- |
| Pod tạm `kubectl run` mỗi lần | Không pod thường trực giữ mật khẩu | Mỗi lần phải qua PSA restricted, NetworkPolicy của `svp-data`, policy image; mỗi script tự dựng một kiểu |
| **Deployment `svp-ops` thường trực** | Một đường, render và kiểm được như mọi workload | Một pod giữ mật khẩu `svp-admin` và `svp-ops` thường trực (giảm thiệt hại ở §13) |

## Chi tiết rút khỏi ADR

### 2. Kafka cloud: MSK provisioned

- Bảng phiên bản [N1]: 3.9.x (Recommended) phát hành ở MSK 2025-04-21; 4.0.x 2025-05-16; 4.1.x 2025-10-15; 4.2.x 2026-07-15, "currently available on MSK
  Express brokers only"; các bản từ 3.8.x không có ngày hết hỗ trợ. MSK đánh dấu 3.9.x "Recommended" (bản cuối có cả ZooKeeper và KRaft, hỗ trợ mở
  rộng ít nhất hai năm); ADR chọn 4.1.x vì là bản mới nhất cho broker Standard, chỉ KRaft như broker local, và có image `apache/kafka` cùng `x.y`.
  Cluster KRaft tạo từ 4.1 không có DNS endpoint của controller [N10]. MSK tự lên bản vá trong dòng 4.1.x [N1].
- Chuỗi API: trang phiên bản chỉ bảo chọn "version 4.1.x" ở console, CLI, SDK [N1]; trang KRaft chỉ nêu chuỗi của 3.7 ("you should use 3.7.x.kraft as the
  version" với `CreateCluster`, `CreateClusterV2`; `3.7.x` là ZooKeeper) [N10]. Chuỗi của 4.1 là `4.1.x.kraft`: hằng `KafkaVersion.V4_1_X_KRAFT` của AWS
  CDK v2.275.0 (`aws-msk-alpha`; dòng 4.x chỉ có hằng `_KRAFT`) và test `TestNormalizeKafkaVersion` của provider 6.71.0 nhận `4.1.x.kraft` [N32].
  Chưa kiểm trên AWS: `CreateCluster` nhận chuỗi này với `kafka.t3.small`, và `kafka_versions` của `aws_msk_configuration` nhận cùng chuỗi (ADR, "Xác nhận" (a)).
- Cỡ broker [N2]: "Use T3 brokers for low-cost development, if you are testing small to medium streaming workloads, or if you have low-throughput
  streaming workloads"; "M7g and M5 brokers ... are recommended for production workloads". Partition khuyên mỗi broker: `kafka.t3.small` 300 [N3].
  Đếm của stg: 4 topic × 3 partition + 4 DLQ × 1 = 16, cộng 50 của `__consumer_offsets` (mặc định `offsets.topic.num.partitions`), RF 2 trên hai broker
  nên mỗi broker giữ ~66 bản.
- Lưu trữ mỗi broker tối thiểu 1 GiB, tối đa 16384 GiB [N12]; 10 GiB đủ cho vài GB mỗi buổi với hạn giữ 7 và 14 ngày của script.
- Cổng: 9092 plaintext, 9094 TLS, 9096 SASL/SCRAM, 9098 IAM [N7]. Khi dùng SCRAM, MSK bật TLS cho mọi lưu lượng client–broker [N4].
- At-rest: không chỉ khoá thì MSK dùng khoá AWS quản [N8]; module dùng KMS key customer managed vốn đã cần cho secret SCRAM, một khoá mỗi env.
- Log: broker log và authorizer log tới CloudWatch Logs, S3 hay Firehose; MSK không tự tạo đích [N9]. `logging_info` của `aws_msk_cluster` ở provider
  6.71.0 chỉ có `broker_logs` [N22], nên authorizer log không bật bằng Terraform.
- Cert: "Amazon MSK brokers use public AWS Certificate Manager certificates. Therefore, any truststore that trusts Amazon Trust Services also trusts
  the certificates of Amazon MSK brokers" [N8]; MSK gia hạn mỗi 13 tháng, cluster Standard ở `MAINTENANCE` trong lúc đó, vẫn đọc ghi được [N8].

### 5. User Kafka và mô hình quyền

Bảng ACL (literal), như `deploy/helm/svp-data/files/kafka-users.sh` cộng hai user mới của ADR:

| User | ACL |
| --- | --- |
| `svp-user-service` | WRITE `user.follows.v1` |
| `svp-video-service` | WRITE `video.lifecycle.v1`, `media.transcodes.v1.dlq`; READ `media.transcodes.v1`; READ group `video-service` |
| `svp-engagement-service` | WRITE `engagement.views.v1`, `engagement.views.v1.dlq`; READ `engagement.views.v1`; READ group `engagement-service` |
| `svp-feed-service` | WRITE `user.follows.v1.dlq`, `video.lifecycle.v1.dlq`; READ `user.follows.v1`, `video.lifecycle.v1`; READ group `feed-service` |
| `svp-media-worker` | WRITE `media.transcodes.v1`, `video.lifecycle.v1.dlq`; READ `video.lifecycle.v1`; READ group `media-worker` |
| `svp-keda` | DESCRIBE `video.lifecycle.v1`; DESCRIBE group `media-worker` |
| `svp-otelcol` (mới) | DESCRIBE 8 topic của script; DESCRIBE group `video-service`, `engagement-service`, `feed-service`, `media-worker` |
| `svp-admin` | ALL trên CLUSTER, TOPIC `*`, GROUP `*`, TRANSACTIONAL_ID `*` (cấp đầu tiên) |

- KIP-679 [N26]: từ Kafka 2.8 `InitProducerId` được cấp khi principal có WRITE trên một topic bất kỳ, `IDEMPOTENT_WRITE` bị bỏ dần từ 3.0; producer
  idempotent của service không cần quyền cluster.
- Kafka [N25]: tài nguyên không có ACL nào khớp thì chỉ super user được dùng, trừ khi `allow.everyone.if.no.acl.found=true`; có ACL thì ACL được áp như
  thường. MSK đặt khoá này `true` mặc định và cấu hình broker là super user [N5]; `super.users` không nằm trong danh sách thuộc tính cấu hình được [N6].
  Trước ACL đầu tiên, chưa tài nguyên nào có ACL nên `svp-admin` tạo được ACL; sau ACL wildcard của nó, mọi topic, group, transactional id và cluster
  đều có ACL.
- Secret SCRAM của MSK [N4]: chỉ SCRAM-SHA-512; tối đa 1000 user; bắt buộc KMS key customer managed (không khoá mặc định, không khoá bất đối xứng);
  gắn tối đa 10 secret mỗi lượt `BatchAssociateScramSecret`; tên tiền tố `AmazonMSK_`; cùng account và region; MSK gắn resource policy vào secret, không
  sửa; đổi secret mất tới 10 phút mới tới broker; bỏ user không đóng kết nối đang mở; xoay vòng chỉ đổi mật khẩu, MSK chỉ đọc `AWSCURRENT`.
  `aws_msk_scram_secret_association` giữ độc quyền các secret gắn vào cluster [N22].

### 6. Replication và độ bền

| Khoá | local | stg | prd | Lý do |
| --- | --- | --- | --- | --- |
| `default.replication.factor` | 1 | 2 | 3 | Mặc định MSK: 2 khi 2 AZ, 3 khi 3 AZ [N6] |
| `min.insync.replicas` | 1 | 1 | 2 | Mặc định MSK: 1 khi 2 AZ, 2 khi 3 AZ [N6] |
| `offsets.topic.replication.factor` | 1 | 2 | 3 | Không có trong bảng mặc định của MSK, nên là 3 của Apache Kafka; "Internal topic creation fails until the cluster size meets this replication factor requirement" [N6] |
| `transaction.state.log.replication.factor` | 1 | 2 | 3 | Như dòng trên [N6] |
| `transaction.state.log.min.isr` | 1 | 1 | 2 | Bằng `min.insync.replicas` của env |

### 9. User Valkey và access string

Lệnh mỗi client gửi, đọc từ code:

| Client | Lúc nối | Lệnh | Code |
| --- | --- | --- | --- |
| go-redis 9.23.0 (gateway, feed-service) | `HELLO 3 AUTH <user> <pw>`, rồi pipeline `SELECT <db>`, `CLIENT SETINFO LIB-NAME`, `CLIENT SETINFO LIB-VER`; `CLIENT MAINT_NOTIFICATIONS` tắt trong `redisx` | gateway: `EVALSHA`, `EVAL` khi NOSCRIPT (script GCRA gọi `TIME`, `GET`, `SET … PX`), `SET … PX … NX`, `DEL`; feed-service: `GET`, `SET … EX` | `redis.go` (`initConn`) [N31]; `internal/redisx/redisx.go`, `services/gateway/internal/ratelimit/ratelimit.go`, `services/feed-service/internal/server/server.go` |
| node-redis 6.3.0 (web) | `HELLO 3 AUTH`, `SELECT 9`, `CLIENT SETINFO LIB-VER`, `LIB-NAME` (bỏ qua lỗi), `CLIENT MAINT_NOTIFICATIONS ON moving-endpoint-type …` (chế độ `auto`, bỏ qua lỗi) | `EVAL` (compare-and-set: `GET`, `SET … PXAT`; compare-and-delete và nhả lease: `GET`, `DEL`), `SET … NX PX`, `GET`, `DEL`, `EXISTS` | `@redis/client` `dist/lib/client/index.js` (`#getHandshakeCommands`) [N31]; `server/redis.ts`, `server/session.ts` của `svp-frontend` |
| `valkey-cli` 9.1.3 (CLI vận hành) | `AUTH <user> <pw>`, `SELECT <db>` (thấy bằng `MONITOR`) | `SCAN 0 MATCH <mẫu> COUNT 10`, `DEL`, `GET`, `MGET` (drill RL-1 đọc mọi khoá login-email ở db 10 để đo độ trải quyết định), `TIME`, `PTTL`, `PING` (cả `--latency`) | `deploy/compose/lib.sh`, `deploy/k8s/drills/threats/` (`rl-1/chainsaw-test.yaml`: `MGET`), `docs/runbooks/` |

Phép thử 2026-11-08: image `docker.io/valkey/valkey:9.1.3-alpine@sha256:bf09d58e96d6b4524a15396b65b242bbe18beebbcc15a04d8ee75ddac62fae0b`,
`env -u DOCKER_DEFAULT_PLATFORM docker run --rm --network none`, `valkey-server --aclfile` với năm dòng của ADR §9 (mật khẩu giả) và một user quản trị
để nạp khoá mẫu; mọi lệnh bằng `valkey-cli --user <user>`, mật khẩu qua `REDISCLI_AUTH`.

- `ACL LIST` trả bốn user đúng chuỗi của ADR (thêm `#<sha256>` của mật khẩu) và `user default off resetchannels -@all`.
- Được nhận: `HELLO 3 AUTH`; `CLIENT SETINFO`; gateway `EVAL` script gọi `TIME`, `GET`, `SET … PX`, `EVALSHA` (NOSCRIPT), `SET … PX … NX`, `DEL` ở
  db 10; feed-service `GET`, `SET … EX` ở db 14; web `EVAL` gọi `GET`, `SET … PXAT`, `DEL`, `SET … NX PX`, `EXISTS` ở db 9; `svp-ops` `PING`, `TIME`,
  `--scan --pattern`, `PTTL`, `GET` ở db 9 và 10, `DEL` một khoá `svp:gw:rl:register:*` ở db 10 và `svp:feed:explore:*` ở db 14, `--latency`.
- Bị từ chối (NOPERM): gateway `GET` khoá ngoài `svp:gw:*`, `SELECT 14`, lệnh khoá khi còn ở db 0, script gọi `FLUSHDB` hay đọc khoá ngoài tiền tố,
  `KEYS`, `PING`; feed-service `SELECT 10`, `DEL`; web `EVALSHA`, `SELECT 10`; `svp-ops` `DEL` khoá `svp:gw:rl:login-ip:*`, khoá register ở db 14, khoá
  explore ở db 10, session web ở db 9, `SET`, lệnh khoá ở db 0, `GET` khoá ngoài `svp:*`, `FLUSHDB`, `KEYS`; không đăng nhập: `NOAUTH`. `ACL LOG` ghi lý
  do `command` 9 lần, `database` 7, `key` 5.
- `CLIENT MAINT_NOTIFICATIONS`: `ERR unknown subcommand` (Valkey không có lệnh con này), ở mọi user; node-redis bỏ qua.
- `svp-ops` `--scan` ở db 10 trả cả khoá `other:key` nằm ngoài `~svp:*`, còn `GET other:key` bị NOPERM: SCAN không lọc theo mẫu khoá.
- Thử lại sau khi thêm `+mget` cho `svp-ops` (cùng image, cùng cách chạy): `ACL LIST` trả nguyên chuỗi mới; `svp-ops` `MGET` hai khoá
  `svp:gw:rl:login-email:*` ở db 10 và một khoá `svp:web:*` ở db 9 được; `MGET` kèm `other:key` (lý do `key`), `MGET` ở db 0 (`database`) bị NOPERM;
  `svp-gateway` `MGET` bị NOPERM (`command`); `GET`, `PTTL`, `--scan`, `TIME`, `PING` của `svp-ops` vẫn được, `DEL` khoá login-email, `SET` vẫn bị từ chối.

Valkey [N21]: lệnh không cần xác thực (AUTH, HELLO, RESET) không gỡ được khỏi user; SELECT, SWAPDB, MOVE, COPY … DB bị kiểm theo `db=`; FLUSHALL cần
`alldbs`; kết nối mới ở db 0 dù user không được vào db 0, để AUTH rồi SELECT; selector có `db=` riêng. ElastiCache [N15]: không đặt mật khẩu trong access
string; phải có `on` hay `off` (thiếu là `off`); không dùng `reset`; lệnh bị cấm hay đổi tên làm lỗi; selector, `%R~`, `%W~`, `|` cho lệnh con từ 7.0;
`db=` từ Valkey 9.1; user group engine VALKEY không cần user `default` và tắt nó khi gắn; RBAC chỉ gắn cho cache có TLS in-transit; tối đa 100 user mỗi
group, 1000 user. Chưa kiểm trên AWS: ElastiCache nhận `client|setinfo`, `resetchannels`, selector chứa `db=` và trả lại chuỗi không viết lại (ADR,
"Xác nhận" (a)).

### 11. CA local và cách client tin nó

- `make env` sinh một lần, không ghi đè, vào `backend/.local/ca/` (gitignore; khoá mode 600): `ca.crt`, `ca.key`, cert server cho Kafka và Valkey ký bởi CA
  đó, SAN gồm `kafka`, `kafka.svp-data`, `kafka.svp-data.svc`, `kafka.svp-data.svc.cluster.local`, bốn tên tương ứng của `valkey`, và `localhost`.
- compose: container một lần `tls-init` (image Valkey của ADR §8, `user: "0"`) đọc `backend/.local/ca/` bind-mount chỉ đọc, `install` cert và khoá vào
  volume `svp-tls` với owner là uid của image server (`apache/kafka`, Valkey; uid đọc từ Dockerfile của image, ghi trong compose kèm nguồn), khoá 0400,
  cert 0444; `kafka`, `valkey` mount volume đó chỉ đọc và `depends_on` `tls-init` xong; `ca.crt` (0644) bind-mount thẳng vào client. Chạy được trên Docker
  Desktop macOS và runner Linux (khoá trên host thuộc uid của runner).
- k3d: nạp thành Secret qua `deploy/k8s/secrets.sh` (đường dev) và nguồn của store `kubernetes` của ESO (đường GitOps), mount `defaultMode: 0440` với
  `fsGroup` của pod; ExternalSecret của chúng không render trên nền tảng eks.
- Go trên Linux đọc thêm các file của `SSL_CERT_DIR` cạnh bundle hệ thống; Go trên macOS bỏ qua `SSL_CERT_FILE`, `SSL_CERT_DIR`, nên test của `internal/kafkax`
  nạp CA của test qua hook chưa export, chỉ đặt từ file `_test.go`. Node: `NODE_EXTRA_CA_CERTS=/etc/svp-ca/ca.crt`.
  Nguyên văn câu cuối của ADR §11: "Ngoại lệ duy nhất có code: test của `internal/kafkax` nạp CA qua hook chưa export, chỉ từ `_test.go`."

### 12. Mật khẩu và Secret trên cluster

- Mọi nền tảng (chart `svp-cluster`, `files/external-secrets.yaml`; `deploy/k8s/secrets.sh` của đường dev tạo cùng danh sách): `svp-data/kafka-admin`
  (`SVP_KAFKA_ADMIN_PASSWORD` ← `kafka-admin`; Job `kafka-init`, broker local); `svp-data/svp-ops` (`SVP_KAFKA_ADMIN_PASSWORD` ← `kafka-admin`,
  `SVP_VALKEY_OPS_PASSWORD` ← `valkey-users`); `svp-obs/otelcol-kafka` (`password` ← `kafka-users/SVP_KAFKA_OTELCOL_PASSWORD`); `keda/keda-kafka`
  (← `kafka-users/SVP_KAFKA_KEDA_PASSWORD`); `REDIS_URL` trong `svp/gateway-env`, `svp/feed-service-env`, `svp/web-env` (←
  `valkey-users/SVP_VALKEY_<X>_PASSWORD`); `KAFKA_SASL_*` của `svp/<service>-env` như nay.
- Chỉ khi broker và Valkey chạy trong cluster (k3d), bằng cơ chế `enabledBy: <khoá>` sẵn có của chart: `svp-data/kafka-users` (Job init tạo user),
  `svp-data/valkey-acl` (aclfile từ `valkey-users` và access string của ADR §9), cert và khoá của CA local cho `kafka`, `valkey` và `ca.crt` cho client ở
  `svp`, `svp-data`, `svp-obs`, `keda`. Bỏ `redpanda-bootstrap`, `redpanda-superusers`.
- Entry mỗi namespace trên eks (`namespace_entries` của module `external-secrets`): `keda` [`kafka-users`], `svp` thêm `valkey-users`, `svp-data`
  [`kafka-admin`, `pg-roles`, `pg-superuser`, `valkey-users`], `svp-obs` thêm `kafka-users`.
- Nguồn mật khẩu trên EKS: ephemeral `random_password` của provider `hashicorp/random` (đã có trong lock qua module `rds`; `length = 32`, `special = false`),
  không phải `aws_secretsmanager_random_password` vì mock provider của `terraform test` chưa nhận ephemeral của provider AWS. Ghi qua `secret_string_wo` với
  `secret_string_wo_version` và `aws_elasticache_user.passwords_wo` với `passwords_wo_version` [N22]; `special = false` bỏ mọi dấu câu, gồm `@`, `/`, `:`,
  `#`, `%`, `"` mà URL, JAAS và aclfile cần thoát.
- Đổi mật khẩu: tăng `_wo_version` rồi apply; MSK đồng bộ tới 10 phút [N4], kết nối mới của pod chưa restart có thể bị từ chối: chấp nhận.

### 13. CLI vận hành

- `svp-kafka <tool> [args]` chạy `kafka-<tool>.sh` của image `apache/kafka` với `--bootstrap-server "$KAFKA_BROKERS"` và file client properties tạm (mode
  600, xoá khi thoát) đăng nhập `svp-admin` SCRAM-SHA-512 SSL từ `SVP_KAFKA_ADMIN_PASSWORD`, truststore PEM `SVP_CA_FILE` khi biến đặt. `svp-valkey [args]`
  chạy `valkey-cli --tls --user svp-ops -h "$VALKEY_HOST" -p 6379` (`--cacert "$SVP_CA_FILE"` khi đặt), mật khẩu qua `REDISCLI_AUTH` từ
  `SVP_VALKEY_OPS_PASSWORD`.
- `SVP_AS_USER=<user>`: wrapper đăng nhập user đó, mật khẩu là dòng đầu của stdin (`IFS= read -r`), phần còn lại của stdin chuyển nguyên cho công cụ;
  script trên host lấy mật khẩu từ nguồn đang giữ nó (compose: `.env`; k3d, EKS: Secret của chính client) rồi đưa qua `exec -i`.
- Đường tuyệt đối `/opt/svp/bin/` trong mọi container chạy wrapper: compose bind-mount `backend/deploy/ops/` chỉ đọc, chart mount ConfigMap thành thư mục
  đó (`defaultMode: 0555`), không che công cụ nào của image.
- Pod `svp-ops`: nhãn `app.kubernetes.io/name: svp-ops`, PSA restricted (non-root, drop ALL, seccomp RuntimeDefault, root FS chỉ đọc với `emptyDir` `/tmp`),
  `automountServiceAccountToken: false`, không Service, không ingress; egress chỉ tới Kafka 9096 và Valkey 6379 (pod `kafka`, `valkey` ở mode `cluster`,
  `cluster.dbCidrs` ở mode `external`); image ghim digest; namespace `svp-data` nằm ngoài policy `svp-images` (chỉ `svp`).
- Nguyên văn đoạn ADR §13 trước khi rút gọn: "Đường duy nhất để script, drill, runbook, lệnh buổi chạm Kafka, Valkey (không `rpk`, `redis-cli` trên host hay
  `kubectl run`): `/opt/svp/bin/svp-kafka` (Kafka CLI của §3, `svp-admin`), `/opt/svp/bin/svp-valkey` (`valkey-cli --tls --user svp-ops`) ở `deploy/ops/`,
  chạy trong container `kafka`, `valkey` của compose và Deployment `svp-ops` của chart `svp-data` ở k3d, EKS; `SVP_AS_USER` đăng nhập user thường cho phép
  kiểm quyền. Đánh đổi: một pod thường trực giữ mật khẩu `svp-admin`, `svp-ops`, đổi lấy một đường kiểm được; giảm bằng PSA restricted, không token
  ServiceAccount, không Service, egress chỉ 9096, 6379."

### 14. Hợp đồng `cluster.*` thêm

`kafkaBrokers` = output `bootstrap_brokers` của module `msk` (`bootstrap_brokers_sasl_scram` [N22], chuỗi `host:9096,…`, kiểm
`^<host>:9096(,<host>:9096)*$`), `valkeyHost` = output `primary_endpoint_address` của module `elasticache`; sinh ở `cluster_values` hai root env, kiểm ở
`gitops-bridge` và `$shapes` của `argocd/apps/templates/applications.yaml`, ví dụ ở `deploy/ci/cluster-values.example.yaml`, đọc ở `platforms/eks/*.values.tpl`.

### 16. Buổi: thời gian và chi phí

- MSK: trang trạng thái chỉ nói cluster ở `CREATING` tới `ACTIVE`, `DELETING` khi xoá, không có thời lượng [N12]; trang tạo cluster cũng vậy. Terraform
  `aws_msk_cluster` chờ mặc định 120 phút cho tạo, cập nhật, xoá; `aws_elasticache_replication_group` 60 phút tạo, 40 phút cập nhật, 45 phút xoá [N22].
- Thứ tự buổi giữ như 0048 §6: apply root env (EKS, RDS, MSK, ElastiCache, secret song song theo đồ thị phụ thuộc; MSK, ElastiCache chỉ phụ thuộc
  subnet, security group, KMS key) → `make eks-secrets` → apply root gitops. Secret SCRAM tới broker trong tới 10 phút sau khi gắn [N4]: Job `kafka-init`
  thử lại ít nhất 10 phút trước khi đỏ.
- Giả định thời gian của ADR §16 là phép kiểm (a) của buổi stg; số đo có ngày ghi vào mục "Kiểm chứng" dưới đây khi buổi chạy.
- Nguyên văn hai bullet của ADR §16 trước khi rút gọn:
  - Tài liệu không ghi thời gian dựng, gỡ [N12]. **Giả định**, đo ở buổi stg: MSK dựng ≤ 45, gỡ ≤ 30 phút; ElastiCache ≤ 20, ≤ 15; song song với EKS trong apply
    của root env nên buổi dài thêm ~30 phút apply, ~20 phút destroy, vừa trần 4 giờ vì phần đo có mốc cắt 3 giờ. `sweep.sh` liệt kê MSK, ElastiCache, secret sót.
  - Công thức 0048 §10, giá `ap-southeast-1` [N13], [N19], [N30], bảng ở phụ lục. **stg:** H_k ~$0,144/giờ (2 × $0,0578 + $0,0192 + phần nhỏ), O_k ~$0,06;
    buổi ~$3,0 với node Spot (~$2,4 của 0034 §12 + 4 × H_k + O_k), ~$3,7 on-demand, dưới trần $5. **prd:** H_k ~$1,09/giờ (3 × $0,255 + 2 × $0,1576 + phần
    nhỏ), O_k ~$0,22: **C = 4 × (0,90 + 1,09) + 2,8 + 0,22 ≈ $11,0**, thay ~$6,6 của 0049. R không đổi: KMS key ở `PendingDeletion`, secret xoá ngay.

## Chi phí

Đơn vị theo ADR-0048 §10: T = 4 giờ; H theo giờ khi env chạy; O theo lượng dùng trong một buổi; R theo tháng, không cộng vào trần; tháng 730 giờ. Lượng
dùng mỗi buổi giả định như 0049 (ước lượng): ghi 2 GB, đọc 4 GB; phần client đi qua AZ khác là 1/2 ở stg (2 AZ), 2/3 ở prd (3 AZ).

### stg

| Hạng mục | Lượng | Giá | Nguồn | USD/giờ |
| --- | --- | --- | --- | --- |
| Broker `kafka.t3.small` | 2 | $0,0578/broker-giờ | [N13] | 0,1156 |
| EBS của broker | 2 × 10 GB | $0,12/GB-tháng | [N13] | 0,0033 |
| Node Valkey `cache.t4g.micro` | 1 | $0,0192/node-giờ | [N19] | 0,0192 |
| KMS key customer managed của module `msk` | 1 | $1/tháng | [N30] | 0,0014 |
| Secret (8 `AmazonMSK_*`, `valkey-users`) | 9 | $0,40/secret-tháng | [N30] | 0,0049 |
| **H_k** | | | cộng các dòng trên | **0,144** |

| Hạng mục (theo buổi) | Lượng (ước lượng) | Giá | Nguồn | USD/buổi |
| --- | --- | --- | --- | --- |
| Dữ liệu giữa AZ của client Kafka | (2 + 4) GB × 1/2 = 3 GB | $0,01/GB mỗi chiều | AmazonEC2 như phụ lục ADR-0048 (đọc 2026-11-05) | 0,06 |
| Sao chép giữa broker | | $0: "not charged for data transfer used for replication between brokers" | [N13] | 0 |
| Valkey giữa AZ | vài chục MB | node không tính, ứng dụng $0,01/GB | [N19] | ~0 |
| **O_k** | | | | **0,06** |

Buổi stg trước ADR này ~$2,2–2,4 với node Spot, ~$3,0–3,1 on-demand ([0034](../0034-aws-stage7.md) §12, giá đọc 2026-10-31). Thêm 4 × H_k + O_k =
$0,64: **~$2,8–3,0 Spot, ~$3,6–3,7 on-demand**, dưới trần $5 của 0034. Pod Redpanda, Valkey rời node nhưng số node không đổi, nên không bớt gì.

### prd

| Hạng mục | Lượng | Giá | Nguồn | USD/giờ |
| --- | --- | --- | --- | --- |
| Broker `kafka.m7g.large` | 3 | $0,255/broker-giờ | [N13] | 0,765 |
| EBS của broker | 3 × 10 GB | $0,12/GB-tháng | [N13] | 0,0049 |
| Node Valkey `cache.m7g.large` | 2 (primary, replica) | $0,1576/node-giờ | [N19] | 0,3152 |
| KMS key customer managed của module `msk` | 1 | $1/tháng | [N30] | 0,0014 |
| Secret (8 `AmazonMSK_*`, `valkey-users`) | 9 | $0,40/secret-tháng | [N30] | 0,0049 |
| **H_k** | | | cộng các dòng trên | **1,091** |

| Hạng mục (theo buổi) | Lượng (ước lượng) | Giá | Nguồn | USD/buổi |
| --- | --- | --- | --- | --- |
| Dữ liệu giữa AZ của client Kafka | (2 + 4) GB × 2/3 = 4 GB | $0,01/GB mỗi chiều | AmazonEC2 như phụ lục ADR-0048 (đọc 2026-11-05) | 0,08 |
| Broker log tới CloudWatch Logs | ~0,2 GB (log INFO của 3 broker trong 4 giờ) | $0,70/GB vended log, 10 TB đầu | [N30] | 0,14 |
| Sao chép giữa broker, Valkey giữa AZ | | $0; ứng dụng tới Valkey $0,01/GB, vài chục MB | [N13], [N19] | ~0 |
| **O_k** | | | | **0,22** |

H₀ = ~0,90 USD/giờ, O₀ = ~2,8 USD/buổi (phụ lục ADR-0048, "Chi phí"):

**C = 4 × (H₀ + H_k) + O₀ + O_k = 4 × (0,90 + 1,091) + 2,8 + 0,22 = 7,964 + 3,02 ≈ $11,0 mỗi buổi**, thay ~$6,6 của ADR-0049 (Redpanda: H_k 0,004,
O_k 0,16).

### R

Không đổi (~$4,6/tháng, phụ lục ADR-0048, "R"): KMS key của module `msk` vào `PendingDeletion` khi destroy, không tính tiền lúc chờ xoá (bảng R của 0048);
secret xoá với `recovery_window_in_days = 0`; log group của prd xoá cùng root env.

## Kiểm chứng

Chưa có buổi nào. Phép kiểm (a)–(h) ở mục "Xác nhận" của ADR; lệnh, output và số đo có ngày ghi ở đây.

Nguyên văn dòng cuối mục "Xác nhận" của ADR trước khi rút gọn: "Kết quả có ngày vào phụ lục; mục này đổi bullet trên thành một dòng kết luận mỗi env."

## Nguồn

Đọc 2026-11-08.

- [N1] Amazon MSK, supported Apache Kafka versions: <https://docs.aws.amazon.com/msk/latest/developerguide/supported-kafka-versions.html>
- [N2] Amazon MSK, broker sizes: <https://docs.aws.amazon.com/msk/latest/developerguide/broker-instance-sizes.html>
- [N3] Amazon MSK, best practices (partition mỗi broker): <https://docs.aws.amazon.com/msk/latest/developerguide/bestpractices.html>
- [N4] Amazon MSK, sign-in credentials (SASL/SCRAM): <https://docs.aws.amazon.com/msk/latest/developerguide/msk-password-howitworks.html>,
  <https://docs.aws.amazon.com/msk/latest/developerguide/msk-password-limitations.html>, <https://docs.aws.amazon.com/msk/latest/developerguide/msk-password-tutorial.html>,
  <https://docs.aws.amazon.com/msk/latest/developerguide/msk-password-users.html>, <https://docs.aws.amazon.com/msk/latest/developerguide/msk-password-rotation.html>
- [N5] Amazon MSK, Apache Kafka ACLs: <https://docs.aws.amazon.com/msk/latest/developerguide/msk-acls.html>
- [N6] Amazon MSK, default và custom configuration: <https://docs.aws.amazon.com/msk/latest/developerguide/msk-default-configuration.html>,
  <https://docs.aws.amazon.com/msk/latest/developerguide/msk-configuration-properties.html>
- [N7] Amazon MSK, port information: <https://docs.aws.amazon.com/msk/latest/developerguide/port-info.html>
- [N8] Amazon MSK, encryption: <https://docs.aws.amazon.com/msk/latest/developerguide/msk-encryption.html>,
  <https://docs.aws.amazon.com/msk/latest/developerguide/msk-working-with-encryption.html>
- [N9] Amazon MSK, logging: <https://docs.aws.amazon.com/msk/latest/developerguide/msk-logging.html>
- [N10] Amazon MSK, metadata management (KRaft): <https://docs.aws.amazon.com/msk/latest/developerguide/metadata-management.html>
- [N11] Amazon MSK, IAM access control và Serverless: <https://docs.aws.amazon.com/msk/latest/developerguide/iam-access-control.html>,
  <https://docs.aws.amazon.com/msk/latest/developerguide/serverless.html>
- [N12] Amazon MSK, cluster states và quota: <https://docs.aws.amazon.com/msk/latest/developerguide/msk-cluster-states.html>,
  <https://docs.aws.amazon.com/msk/latest/developerguide/limits.html>
- [N13] Giá MSK: <https://pricing.us-east-1.amazonaws.com/offers/v1.0/aws/AmazonMSK/current/ap-southeast-1/index.json> (phát hành 2026-11-04),
  <https://aws.amazon.com/msk/pricing/>
- [N14] Amazon ElastiCache, engine versions (Valkey 9.1: ACL theo db; 9.0: nhiều db ở cluster mode): <https://docs.aws.amazon.com/AmazonElastiCache/latest/dg/engine-versions.html>
- [N15] Amazon ElastiCache, Role-Based Access Control: <https://docs.aws.amazon.com/AmazonElastiCache/latest/dg/Clusters.RBAC.html>
- [N16] Amazon ElastiCache, in-transit encryption: <https://docs.aws.amazon.com/AmazonElastiCache/latest/dg/in-transit-encryption.html>
- [N17] Amazon ElastiCache, engine parameters (họ `valkey9`, `maxmemory-policy`): <https://docs.aws.amazon.com/AmazonElastiCache/latest/dg/ParameterGroups.Engine.html>
- [N18] Amazon ElastiCache, core components (Serverless chạy cluster mode), node types, chọn cỡ node:
  <https://docs.aws.amazon.com/AmazonElastiCache/latest/dg/WhatIs.corecomponents.html>, <https://docs.aws.amazon.com/AmazonElastiCache/latest/dg/CacheNodes.SupportedTypes.html>,
  <https://docs.aws.amazon.com/AmazonElastiCache/latest/dg/CacheNodes.SelectSize.html>
- [N19] Giá ElastiCache: <https://pricing.us-east-1.amazonaws.com/offers/v1.0/aws/AmazonElastiCache/current/ap-southeast-1/index.json> (phát hành
  2026-10-28), <https://aws.amazon.com/elasticache/pricing/>
- [N20] Amazon ElastiCache, IAM authentication: <https://docs.aws.amazon.com/AmazonElastiCache/latest/dg/auth-iam.html>
- [N21] Valkey, ACL: <https://valkey.io/topics/acl/>
- [N22] Provider Terraform `hashicorp/aws` 6.71.0 (version của `infra/aws/envs/stg/.terraform.lock.hcl`), `website/docs/` ở tag `v6.71.0`:
  `r/msk_cluster`, `r/msk_configuration`, `r/msk_scram_secret_association`, `r/elasticache_replication_group`, `r/elasticache_user`,
  `r/elasticache_user_group`, `r/secretsmanager_secret_version`: <https://github.com/hashicorp/terraform-provider-aws/tree/v6.71.0/website/docs>;
  provider `hashicorp/random` 3.9.1 (lock của hai root), ephemeral `random_password` (`length`, `special`):
  <https://github.com/hashicorp/terraform-provider-random/blob/v3.9.1/docs/ephemeral-resources/password.md>
- [N23] KEDA 2.21, Apache Kafka scaler: <https://keda.sh/docs/2.21/scalers/apache-kafka/>
- [N24] OpenTelemetry Collector contrib 0.164.0, `kafkametricsreceiver`: <https://github.com/open-telemetry/opentelemetry-collector-contrib/blob/v0.164.0/receiver/kafkametricsreceiver/README.md>,
  <https://github.com/open-telemetry/opentelemetry-collector-contrib/blob/v0.164.0/receiver/kafkametricsreceiver/documentation.md>
- [N25] Apache Kafka 4.1, SASL (SCRAM trong metadata log, `kafka-storage format --add-scram`) và authorization (`StandardAuthorizer`,
  `allow.everyone.if.no.acl.found`, `super.users`): <https://kafka.apache.org/41/security/authentication-using-sasl/>,
  <https://kafka.apache.org/41/security/authorization-and-acls/>
- [N26] KIP-679: <https://cwiki.apache.org/confluence/display/KAFKA/KIP-679%3A+Producer+will+enable+the+strongest+delivery+guarantee+by+default>
- [N27] Docker Hub, `apache/kafka` tags (4.1.2 ngày 2026-03-17, 4.4.0 ngày 2026-10-22): <https://hub.docker.com/r/apache/kafka/tags>
- [N28] Strimzi, deploying and managing (KafkaUser SCRAM-SHA-512, cluster CA): <https://strimzi.io/docs/operators/latest/deploying>
- [N29] franz-go v1.22.2: `pkg/sasl/scram` (`AsSha512Mechanism`), `pkg/kgo/config.go` (`DialTLSConfig`), `pkg/sasl/aws`:
  <https://github.com/twmb/franz-go/tree/v1.22.2/pkg/sasl>, <https://github.com/twmb/franz-go/blob/v1.22.2/pkg/kgo/config.go>
- [N30] Giá CloudWatch (vended log, phát hành 2026-11-04), KMS (phát hành 2026-10-26), Secrets Manager (phát hành 2026-09-11):
  <https://pricing.us-east-1.amazonaws.com/offers/v1.0/aws/AmazonCloudWatch/current/ap-southeast-1/index.json>,
  <https://pricing.us-east-1.amazonaws.com/offers/v1.0/aws/awskms/current/ap-southeast-1/index.json>,
  <https://pricing.us-east-1.amazonaws.com/offers/v1.0/aws/AWSSecretsManager/current/ap-southeast-1/index.json>
- [N31] Code client: go-redis v9.23.0 `redis.go` (`initConn`): <https://github.com/redis/go-redis/blob/v9.23.0/redis.go>; node-redis `@redis/client` 6.3.0
  `dist/lib/client/index.js` (`#getHandshakeCommands`), `enterprise-maintenance-manager.js`: <https://www.npmjs.com/package/@redis/client/v/6.3.0>
- [N32] Chuỗi `kafka_version` của MSK: AWS CDK v2.275.0 (phát hành 2026-10-26) `packages/@aws-cdk/aws-msk-alpha/lib/cluster-version.ts` (`V4_1_X_KRAFT`):
  <https://github.com/aws/aws-cdk/blob/v2.275.0/packages/@aws-cdk/aws-msk-alpha/lib/cluster-version.ts>; provider `hashicorp/aws` 6.71.0
  `internal/service/kafka/cluster_test.go` (`TestNormalizeKafkaVersion`): <https://github.com/hashicorp/terraform-provider-aws/blob/v6.71.0/internal/service/kafka/cluster_test.go>
