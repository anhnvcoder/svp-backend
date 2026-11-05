# Phụ lục ADR-0049: Kafka của prd là Redpanda trong cluster bằng đúng chart và component `redpanda` của stg: ba broker mỗi AZ một, topic replication factor 3 với `acks=all` (đa số Raft 2/3 thay `min.insync.replicas=2`), mỗi broker nửa core để vừa ba node của prd

Phụ lục của [ADR-0049](../0049-kafka-prd.md): bảng phương án, chi tiết rút khỏi ADR (xếp theo §), đo sức chứa, chi phí H_k, O_k, trần C và nguồn.
Mọi nguồn đọc ngày 2026-11-05. Giá: bảng giá AWS cho `ap-southeast-1`; đơn vị và công thức theo [ADR-0048](../0048-prd-aws.md) §10.

## Phương án

Cỡ tối thiểu đạt yêu cầu: 3 broker ở 3 AZ, replication factor 3, ghi `acks=all` chỉ thành công khi ít nhất 2 bản đã nhận. Lượng dùng mỗi buổi giả định
(ước lượng, như O₀ của ADR-0048): ghi 2 GB, đọc 4 GB; client ở 3 AZ nên ~2/3 lưu lượng client đi qua AZ khác.

### Cỡ, giá, trần buổi

| Phương án | Trạng thái ngành | Cỡ tối thiểu đạt yêu cầu | H_k (USD/giờ) | O_k (USD/buổi) | C (USD/buổi) | Dựng / xoá trong buổi |
| --- | --- | --- | --- | --- | --- | --- |
| **Redpanda, chart `redpanda` hiện có** | Thông dụng; hãng khuyên Operator cho production [N3] | 3 pod `cores: 500m`, PVC gp3 10 GiB mỗi pod | 0,004 | 0,16 | **~6,6** | Cùng Argo CD, vài phút (ước lượng); PVC xoá trước destroy như PVC khác |
| Redpanda Operator v26.2.5 (2026-10-23 [N17]) | Hiện hành, hãng khuyên cho production [N3] | Như trên + Deployment operator | 0,004 | 0,16 | ~6,6 | Như trên; thêm CRD và operator cài trước |
| Apache Kafka qua Strimzi 1.3.1 (2026-11-04 [N17]) | Thông dụng, CNCF incubating từ 2024-02-08 [N10] | 3 node KRaft hai vai (controller + broker), PVC gp3, Cluster Operator, Entity Operator | 0,004 (ước lượng: PVC; request JVM có thể cần node thứ tư) | 0,16 | ~6,6 (+$0,41 mỗi node thêm trong 4 giờ) | Như trên; thêm CRD và operator |
| MSK provisioned, Standard `kafka.m7g.large` × 3 | Thông dụng | 3 broker, 10 GB EBS mỗi broker; SCRAM cần KMS key riêng và 7 secret `AmazonMSK_*` | 0,775 | 0,08 | ~9,6 | Tạo, xoá: chục phút (ước lượng; AWS không ghi số, timeout mặc định của Terraform 120 phút [N16]) |
| MSK provisioned, Standard `kafka.t3.small` × 3 | Chỉ cho dev, thử tải nhỏ [N18] | | 0,173 + như trên | | không xét: AWS khuyên M5/M7g cho production [N18] | |
| MSK Express `express.m7g.large` × 3 | Mới (2024), hiện hành | 3 broker (Express chỉ có cấu hình 3 AZ [N19]), lưu trữ trả theo dùng | 1,535 | 0,105 | ~12,6 | Như Standard (ước lượng) |
| MSK Serverless | Hiện hành | 1 cluster, 16 partition | 0,968 | 0,50 | ~10,8 | Vài phút (ước lượng) |

Cách tính từng ô: mục "Chi phí" dưới đây.

### Tích hợp và vận hành

| Phương án | Xác thực; đổi code, chart | Bước (1) đổi password admin Kafka | Topic, user, ACL | Giấy phép | Công vận hành | Ảnh hưởng stg | Account prd, SCP | Sức chứa 3 node `m7g.large` |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| **Redpanda chart** | SCRAM-SHA-256 như nay; không đổi code; chart `svp-data` thêm tham số replica và admin host, `svp-cluster` thêm policy giữa broker (§1) | Không đổi: `redpanda_admin` đặt qua Admin API của `redpanda-0`, user nằm trong kho SASL của cluster [N9] | Job `redpanda-init` như nay, `-r 3` ở prd | Community: Redpanda BSL; không bán Redpanda như dịch vụ; tự sang Apache 2.0 sau 4 năm [N7]; rack awareness, SASL, ACL không thuộc danh sách enterprise [N7] | Tự lo: nâng version, rolling restart, PVC theo AZ | Không: stg giữ 1 broker 1 core | Không dịch vụ AWS mới | Vừa với 500m mỗi broker (~5,35 / 5,79 vCPU); không vừa với 1 core (~6,85) (§4) |
| Redpanda Operator | Như trên; `auth` trong CR `Redpanda` | Như trên | CRD `Topic`, `User` (ACL) thay Job | Operator: BSL cho phần lõi, RCL cho phần enterprise [N17] | Operator lo decommission, rolling; thêm controller và CRD cluster-scoped (AppProject) | Phải đổi cả stg (một công cụ mỗi mảng) | Như trên | Thêm request của operator vào dư ~0,44 vCPU (chưa đo) |
| Strimzi | SCRAM chỉ SHA-512 [N11]: `kafkax` đang ghim `AsSha256Mechanism`; `secrets.sh`, `redpanda_admin` viết lại theo KafkaUser | Secret của KafkaUser do operator quản: luồng `secrets.sh` đổi hẳn | CRD `KafkaTopic`, `KafkaUser` | Apache 2.0 | Operator lo rolling; JVM, KRaft | Phải đổi stg; compose vẫn Redpanda: hai phần mềm | Như trên | JVM cần nhiều RAM, CPU hơn Redpanda cùng tải (chưa đo) |
| MSK Standard | SCRAM chỉ SHA-512, bật TLS client–broker [N6], [N20]: `kafkax` thêm TLS và SHA-512; IAM qua `sasl/aws` của franz-go [N12]; mTLS cần AWS Private CA [N21] | Ghi secret `AmazonMSK_<user>` trong Secrets Manager (KMS key riêng), MSK đồng bộ định kỳ [N20]; không có bước vào broker | Topic, ACL bằng Kafka API (`rpk` dùng được); user là secret gắn bằng `aws_msk_scram_secret_association` [N16] | Dịch vụ AWS | AWS lo broker, vá; người học lo cấu hình, version | Stg vẫn Redpanda (hai phần mềm) hay MSK ở stg (C stg tăng ~$3) | Region được SCP cho phép; thêm SG, subnet, KMS key | Giải phóng 1 vCPU của pod Redpanda |
| MSK Express | Như Standard (tài liệu Express không nêu giới hạn xác thực riêng; chưa kiểm) | Như Standard | Như Standard; `min.insync.replicas` khoá ở 2, RF 3 [N14] | Dịch vụ AWS | Ít nhất trong MSK: không quản lưu trữ, không cửa sổ bảo trì [N19] | Như Standard | Như Standard | Như Standard |
| MSK Serverless | Chỉ IAM, không ACL Kafka [N8]: mỗi service một role Pod Identity, `kafkax` dùng `sasl/aws`; bỏ SCRAM, Secret `kafka-users` | Không còn password | Topic bằng Kafka API; quyền bằng IAM policy | Dịch vụ AWS | Ít nhất | Như Standard | Có ở Singapore [N8] | Như Standard |

Độ bền tương đương ở mọi phương án: Kafka (Strimzi, MSK) đặt `min.insync.replicas=2` (MSK 3 AZ mặc định RF 3 [N14]); Redpanda không có thuộc tính đó
[N1], dùng đa số Raft [N2] (§2).

Mạng: mọi phương án chạy trong cluster cần NetworkPolicy cho broker gọi nhau có sẵn trước khi broker chạy (`svp-data` chặn hai chiều từ wave 1; Redpanda:
§1); MSK nằm ngoài cluster, client cần egress tới địa chỉ của MSK (`externalPeers` của chart `svp-service`) và security group.

## Chi tiết rút khỏi ADR

### 1. Cài đặt và mạng giữa broker

- Render chart 26.2.4 với `base/redpanda.yaml`, ba replica và `cores: 500m`: không có `kind: NetworkPolicy`; `seed_servers` là ba broker ở cổng 33145,
  `empty_seed_starts_cluster: false` (broker chờ đủ seed mới lập cluster), `podManagementPolicy: Parallel`, startup probe đọc `/v1/status/ready` tới
  120 lần cách 10 giây. Thiếu cổng 33145 giữa broker thì cả ba không Ready, StatefulSet không Healthy.
- Health của Application con (`base/argo-cd.yaml`) giữ root ở wave 3 tới khi Redpanda Healthy, nên policy đặt ở chart `svp-data` (wave 4) không bao
  giờ được áp. Chart `svp-cluster` (wave 1) đã giữ policy cho các chart không tự mang (Kyverno, External Secrets, Envoy) và policy chặn của
  namespace mà `redpanda-peers` nới ra.
- `redpanda-peers`: `podSelector` `app.kubernetes.io/name: redpanda`, `app.kubernetes.io/instance: redpanda` (nhãn mà policy `redpanda` của `svp-data`
  dùng), `policyTypes: [Ingress, Egress]`, vào từ và ra tới cùng nhãn đó ở TCP 33145, 9644.
- 9644 giữa broker: phần `rpk` của `redpanda.yaml` liệt kê `admin_api.addresses` của cả ba broker; sidecar (`--redpanda-yaml`, `--watch-users` đặt
  superuser) và `rpk` trong hook §5 dùng danh sách đó. Init container `redpanda-configurator` đọc nhãn zone qua API Kubernetes (§3): pod đã có nhãn
  `svp-kube-api: allow` nên `allow-kube-api` của `svp-cluster` mở đường đó.
- 9092 giữa broker: chỉ `pandaproxy_client` và `schema_registry_client` (client nội bộ của HTTP proxy, schema registry) trỏ tới ba broker; hai dịch vụ
  không mở cho ai (policy `redpanda` của `svp-data`), nên không mở.
- Collector: `deploy/observability/otelcol/k8s-config.yaml` scrape `static_configs` chỉ `redpanda-0`; Service `redpanda` là headless (`clusterIP: None`,
  `publishNotReadyAddresses: true`), nên tìm broker qua DNS của nó cho đủ mọi broker với một cấu hình. Policy của `svp-observability` đã mở 9644 tới mọi pod
  Redpanda theo nhãn.

### 2. Độ bền ghi

- `acks=all` của Redpanda: "The producer receives an acknowledgment after the majority of (implicitly, all) replicas acknowledge the message",
  mỗi bản ghi fsync trước khi xác nhận [N2]. Với RF 3, đa số là 2: mất một broker vẫn ghi được, mất hai thì ghi dừng, đúng như `min.insync.replicas=2`.
- Danh sách thuộc tính topic của Redpanda không có `min.insync.replicas` [N1], nên Job tạo topic không đặt thuộc tính đảm bảo ghi nào.
- franz-go v1.22.2: `acks` mặc định `AllISRAcks()`, ghi idempotent bật mặc định [N12]; `internal/kafkax` không đặt `RequiredAcks` hay
  `DisableIdempotentWrite`.
- `internal_topic_replication_factor` mặc định 3 [N4]; render chart 26.2.4 với `base/redpanda.yaml` và ba replica có `default_topic_replications: "3"`
  trong `.bootstrap.json.in` (một replica: không đặt, mặc định 1 [N4]).

### 3. Trải AZ và lưu trữ

- Render chart với ba replica: `topologySpreadConstraints` theo `topology.kubernetes.io/zone` (`ScheduleAnyway`) và anti-affinity theo node là mặc định
  của chart; `base/redpanda.yaml` đặt cả hai về `null` vì một broker. Overlay prd đặt lại anti-affinity theo node như chart, còn spread theo zone đặt
  cứng: `maxSkew: 1`, `whenUnsatisfiable: DoNotSchedule`, `minDomains: 3` ([Kubernetes: topology spread](https://kubernetes.io/docs/concepts/scheduling-eviction/topology-spread-constraints/):
  `ScheduleAnyway` chỉ ưu tiên giảm skew; [AWS: ASG cân AZ](https://docs.aws.amazon.com/autoscaling/ec2/userguide/ec2-auto-scaling-availability-zone-balanced.html)
  dựng sang AZ khác khi thiếu capacity). Phép kiểm của buổi prd: node của ba broker ở ba zone khác nhau; bố cục node 2/1/0 thì broker thứ ba `Pending`.
- `rackAwareness.enabled` đọc nhãn zone của node qua API Kubernetes trong init container `redpanda-configurator` (cần ServiceAccount có quyền `get`
  node, chart tạo khi `serviceAccount.create` và `rbac.enabled`), ghi `redpanda.rack`. Rack awareness không thuộc danh sách tính năng enterprise [N7].
- Cluster mới nhận license dùng thử enterprise 30 ngày [N7]; cluster của buổi sống vài giờ nên luôn trong hạn dùng thử; quyết định không dựa vào tính
  năng enterprise nào (Continuous Data Balancing…).

### 4. Sức chứa

Allocatable mỗi node `m7g.large` (2 vCPU, 8 GiB; prefix delegation của VPC CNI bật ở module `eks` của `svp-infra` (`aws/modules/eks/addons.tf`),
managed node group chặn ở 110 pod cho instance dưới 30 vCPU (README của module) [N13]): CPU 2 000m − kube-reserved (6 % core đầu + 1 % core thứ hai
= 70m) = 1 930m; bộ nhớ 8 192 MiB − phần kernel giữ (ước lượng ~300 MiB) − kube-reserved (11 × 110 + 255 = 1 465 MiB) − eviction 100 MiB ≈ 6 320 MiB
(~6,2 GiB) [N13]. Ba node: **5,79 vCPU, ~18,5 GiB, 330 pod**.

Request cộng từ `helm template` mọi component chạy trên eks của `components.json` (svp-gitops `main`, 2026-11-05) cho prd × eks: values `base/` <
`platforms/eks/` < `envs/prd/` < `envs/prd/images/` < `valuesObject` của root `argocd/apps` render với fixture `deploy/ci/cluster-values.example.yaml`;
replica theo `replicas`, chỗ trống thì `minReplicas` của HPA hay `minReplicaCount` của ScaledObject; container chỉ có `limits` tính request bằng limit;
Argo CD theo `argocd/bootstrap.json` với `base/argo-cd.yaml` và `platforms/eks/argo-cd.yaml`.

| Nhóm | CPU request | Bộ nhớ request |
| --- | --- | --- |
| Workload của `svp-gitops` trừ Redpanda (41 pod; Argo CD, cert-manager không đặt request) | 2 690m | 3 388 MiB |
| Prometheus, Alertmanager (CR của kube-prometheus-stack), Envoy proxy (EnvoyProxy của `svp-cluster`) | 160m | 472 MiB |
| Addon EKS (CoreDNS 2 × 100m, `kube-proxy`, `aws-node`, EBS CSI, metrics-server, Pod Identity agent) | ~1 000m (ước lượng) | ~1 400 MiB (ước lượng) |
| **Cộng, chưa có Redpanda** | **~3 850m** | **~5 260 MiB** |
| + 1 broker 1 core (stg, base hiện tại) | ~4 850m | ~6 540 MiB |
| + 3 broker 1 core | **~6 850m > 5 790m: không vừa** | ~9 100 MiB |
| **+ 3 broker 500m (chọn)** | **~5 350m ≤ 5 790m** | **~9 100 MiB / ~18,5 GiB** |

Số pod: ~44 pod workload, 3 broker và ~15 pod addon, DaemonSet (ước lượng): ~62, dưới 330.

Dư CPU khi chọn 500m: ~0,44 vCPU. Request tính cho trạng thái nghỉ; đo tải thêm node theo O₀ của ADR-0048 (`aws eks update-nodegroup-config`), canary của
Rollouts thêm pod tạm. Render `cores: 500m` của chart 26.2.4: `limits.cpu: 500m`, `--smp=1`, `overprovisioned: true` (chart tự bật khi dưới 1 core).
Giữ 1 core mỗi broker thì cần node thứ tư thường trực (+$0,102/giờ, đổi `desired` của mức prd).

### 5. Vòng đời broker

Script `postStart.sh`, `preStop.sh` của chart 26.2.4 gọi Admin API bằng `curl` không credential (cờ duy nhất thêm vào là TLS); với
`admin_api_require_auth: true` mọi lệnh đó bị từ chối, `preStop` thử tới hết thời gian hook, broker dừng mà chưa rời leadership. Overlay prd thay hai hook
bằng lệnh `rpk` có credential: `preStop` `rpk cluster maintenance enable <id> --wait`, `postStart` `rpk cluster maintenance disable <id>` [N5]; id
broker đọc bằng `rpk` với cùng credential; hook giữ giới hạn thời gian như chart (một nửa `terminationGracePeriodSeconds`). `rpk` dùng `admin_api.addresses`
của cả ba broker trong `redpanda.yaml`, nên hook cần 9644 giữa broker (§1).

### 6. Xác thực, topic, user, secret

- Job `redpanda-init`: `RPK_ADMIN_HOSTS` liệt kê ba broker (`redpanda-<0..2>.redpanda.svp-data.svc.cluster.local:9644`) để `rpk security user` vẫn
  chạy khi một broker mất; `RPK_BROKERS` giữ Service `redpanda` (bootstrap).
- Đổi password admin (bước (1)): user SCRAM là "stored credential within Redpanda … in the internal SASL credential store" [N9], một kho của
  cluster; `redpanda_admin` của `deploy/k8s/secrets.sh` đặt nó qua `redpanda-0` và dùng được nguyên văn khi có ba broker.

## Chi phí

Đơn vị theo ADR-0048 §10: T = 4 giờ; H theo giờ khi prd chạy; O theo lượng dùng trong một buổi; R theo tháng, không cộng vào trần; tháng 730 giờ.

### H_k: theo giờ khi prd chạy (phương án chọn)

| Hạng mục | Lượng | Giá | Nguồn, ngày đọc | USD/giờ |
| --- | --- | --- | --- | --- |
| EBS gp3 cho PVC Redpanda | 3 × 10 GiB | $0,096/GB-tháng | AmazonEC2 `index.csv` như ADR-0048 (phát hành 2026-11-04), đọc 2026-11-05 | 0,004 |
| Node thêm | 0 (vừa 3 node, §4) | $0,102/giờ | trang giá EC2 on-demand như ADR-0048, đọc 2026-11-05 | 0 |
| **H_k** | | | | **0,004** |

### O_k: theo lượng dùng trong một buổi (phương án chọn)

| Hạng mục | Giả định lượng (ước lượng) | Giá | Nguồn, ngày đọc | USD/buổi |
| --- | --- | --- | --- | --- |
| Dữ liệu giữa AZ: sao chép | 2 GB ghi × 2 bản ở AZ khác = 4 GB | $0,01/GB mỗi chiều | AmazonEC2 `index.csv` như ADR-0048, đọc 2026-11-05 | 0,08 |
| Dữ liệu giữa AZ: client | (2 GB ghi + 4 GB đọc) × 2/3 = 4 GB | $0,01/GB mỗi chiều | như trên | 0,08 |
| **O_k** | | | | **0,16** |

### Trần buổi prd

H₀ = ~0,90 USD/giờ, O₀ = ~2,8 USD/buổi (phụ lục ADR-0048, "Chi phí"):

**C = 4 × (H₀ + H_k) + O₀ + O_k = 4 × (0,90 + 0,004) + 2,8 + 0,16 = 3,616 + 2,96 = 6,576 ≈ $6,6 mỗi buổi.**

R (giữ giữa các buổi) không đổi: ~$4,6/tháng (phụ lục ADR-0048, "R"); Kafka không để lại gì giữa các buổi (PVC xoá khi gỡ).

### Phương án khác

Giá MSK: <https://pricing.us-east-1.amazonaws.com/offers/v1.0/aws/AmazonMSK/current/ap-southeast-1/index.json> (phát hành 2026-11-04), đọc 2026-11-05.
SCRAM của MSK cần KMS key riêng ($1/tháng = 0,0014/giờ, giá KMS như ADR-0048) và 7 secret `AmazonMSK_*` (6 user + `svp-admin`, $0,40/secret-tháng =
0,0038/giờ, giá Secrets Manager như ADR-0048). MSK không tính phí dữ liệu sao chép giữa broker [N15]; client trả dữ liệu giữa AZ như thường.

| Phương án | H_k: cách tính | H_k | O_k: cách tính | O_k | C = 4 × (0,90 + H_k) + 2,8 + O_k |
| --- | --- | --- | --- | --- | --- |
| MSK Standard | 3 × $0,255 broker-giờ + 30 GB × $0,12/GB-tháng ÷ 730 (0,0049) + KMS 0,0014 + secret 0,0038 | 0,775 | client giữa AZ 4 GB × $0,02 | 0,08 | 9,58 ≈ 9,6 |
| MSK Standard `t3.small` | 3 × $0,0578 = 0,173 | | | | không xét (dev) |
| MSK Express | 3 × $0,51 broker-giờ + lưu trữ $0,12/GB-tháng (~0) + KMS + secret | 1,535 | ghi 2 GB × $0,0125 + client giữa AZ 0,08 | 0,105 | 12,65 ≈ 12,6 |
| MSK Serverless | $0,9375 cluster-giờ + 16 partition × $0,001875 | 0,968 | vào 2 GB × $0,125 + ra 4 GB × $0,0625 | 0,50 | 10,77 ≈ 10,8 |
| Redpanda Operator | như chart (operator không thêm node, chưa đo) | 0,004 | như chart | 0,16 | 6,58 ≈ 6,6 |
| Strimzi | PVC như chart; nếu JVM cần node thứ tư thì + $0,102 | 0,004 (0,106) | như chart | 0,16 | 6,58 (6,99) |

## Nguồn

Đọc 2026-11-05.

- [N1] Redpanda, topic properties (không có `min.insync.replicas`; `replication.factor`): <https://docs.redpanda.com/current/reference/properties/topic-properties/>
- [N2] Redpanda, configure producers (`acks=all`: đa số bản, fsync trước khi xác nhận): <https://docs.redpanda.com/current/develop/produce-data/configure-producers/>
- [N3] Redpanda, Kubernetes deployment overview ("The Redpanda Operator is the recommended option for production deployment"): <https://docs.redpanda.com/current/deploy/redpanda/kubernetes/k-deployment-overview/>
- [N4] Redpanda, cluster properties (`internal_topic_replication_factor` mặc định 3, `default_topic_replications` mặc định 1): <https://docs.redpanda.com/current/reference/properties/cluster-properties/>
- [N5] `rpk cluster maintenance enable` / `disable`: <https://docs.redpanda.com/current/reference/rpk/rpk-cluster/rpk-cluster-maintenance-enable/>, <https://docs.redpanda.com/current/reference/rpk/rpk-cluster/rpk-cluster-maintenance-disable/>
- [N6] Amazon MSK, giới hạn SCRAM (chỉ SCRAM-SHA-512, KMS key riêng, tiền tố `AmazonMSK_`): <https://docs.aws.amazon.com/msk/latest/developerguide/msk-password-limitations.html>
- [N7] Redpanda, licenses and enterprise features (BSL, RCL, danh sách enterprise, license dùng thử 30 ngày): <https://docs.redpanda.com/current/get-started/licensing/overview/>
- [N8] Amazon MSK Serverless (chỉ IAM, không ACL Kafka; region): <https://docs.aws.amazon.com/msk/latest/developerguide/serverless.html>
- [N9] Redpanda, Kubernetes authentication (kho credential SASL nội bộ, bootstrap user): <https://docs.redpanda.com/current/manage/kubernetes/security/authentication/k-authentication/>
- [N10] CNCF landscape, Strimzi (incubating từ 2024-02-08): <https://github.com/cncf/landscape/blob/master/landscape.yml>
- [N11] Strimzi, configuring (xác thực listener `scram-sha-512`): <https://strimzi.io/docs/operators/latest/configuring.html>
- [N12] franz-go v1.22.2: `pkg/kgo/config.go` (`acks: AllISRAcks()`), `pkg/sasl/aws` (AWS_MSK_IAM): <https://github.com/twmb/franz-go/blob/v1.22.2/pkg/kgo/config.go>, <https://github.com/twmb/franz-go/tree/v1.22.2/pkg/sasl/aws>
- [N13] Amazon EKS AMI, `nodeadm/internal/kubelet/config.go` (kube-reserved CPU theo khoảng, bộ nhớ `11 × maxPods + 255` MiB, eviction `memory.available` 100Mi): <https://github.com/awslabs/amazon-eks-ami/blob/main/nodeadm/internal/kubelet/config.go>; EC2 instance types (`m7g.large`: 2 vCPU, 8 GiB): <https://docs.aws.amazon.com/ec2/latest/instancetypes/gp.html>; số pod mỗi node khi bật prefix delegation (110): README của module `aws/modules/eks` trong `svp-infra`
- [N14] Amazon MSK, cấu hình mặc định (RF 3 khi 3 AZ) và cấu hình chỉ đọc của Express (`min.insync.replicas` 2): <https://docs.aws.amazon.com/msk/latest/developerguide/msk-default-configuration.html>, <https://docs.aws.amazon.com/msk/latest/developerguide/msk-configuration-express-read-only.html>
- [N15] Amazon MSK pricing (không tính phí dữ liệu sao chép giữa broker): <https://aws.amazon.com/msk/pricing/>
- [N16] Provider Terraform `aws`: `aws_msk_cluster` (timeout tạo, xoá mặc định 120 phút), `aws_msk_scram_secret_association`: <https://github.com/hashicorp/terraform-provider-aws/blob/main/website/docs/r/msk_cluster.html.markdown>, <https://github.com/hashicorp/terraform-provider-aws/blob/main/website/docs/r/msk_scram_secret_association.html.markdown>
- [N17] Bản phát hành: Redpanda Operator và chart (`operator/v26.2.5`, `charts/redpanda/v26.2.5`, 2026-10-23; giấy phép ở `licenses/`): <https://github.com/redpanda-data/redpanda-operator/releases>; Strimzi 1.3.1 (2026-11-04): <https://github.com/strimzi/strimzi-kafka-operator/releases>
- [N18] Amazon MSK broker sizes (T3 cho dev, M5/M7g cho production): <https://docs.aws.amazon.com/msk/latest/developerguide/broker-instance-sizes.html>
- [N19] Amazon MSK Express brokers (chỉ 3 AZ, không cửa sổ bảo trì): <https://docs.aws.amazon.com/msk/latest/developerguide/msk-broker-types-express.html>
- [N20] Amazon MSK, SASL/SCRAM qua Secrets Manager (bật TLS client–broker, đồng bộ định kỳ): <https://docs.aws.amazon.com/msk/latest/developerguide/msk-password-howitworks.html>, <https://docs.aws.amazon.com/msk/latest/developerguide/msk-password.html>
- [N21] Amazon MSK, mutual TLS (cần AWS Private CA): <https://docs.aws.amazon.com/msk/latest/developerguide/msk-authentication.html>
