# 0049. Kafka của prd là Redpanda trong cluster bằng đúng chart và component `redpanda` của stg: ba broker mỗi AZ một, topic replication factor 3 với `acks=all` (đa số Raft 2/3 thay `min.insync.replicas=2`), mỗi broker nửa core để vừa ba node của prd

- Trạng thái: Bị thay bởi [0053](0053-msk-elasticache-valkey.md)
- Ngày: 2026-11-05
- Người quyết: AI theo giao của người học (2026-11-05)

## Bối cảnh và vấn đề

- Stg chạy một broker Redpanda trong cluster ([0014](0014-kubernetes-local-stage4.md) §5, [0034](0034-aws-stage7.md) Câu 11 A); Câu 11 B (MSK) hẹn xét
  khi prd cần độ bền. [0048](0048-prd-aws.md) dựng prd chuẩn production (3 AZ, node on-demand `m7g.large` min 3 / desired 3 / max 6, không autoscaler node).
- Kafka của prd phải chịu mất một AZ mà không mất event đã xác nhận: 3 broker trải 3 AZ, replication factor 3, ghi chỉ thành công khi ít nhất 2 bản
  đã nhận; giữ SASL/ACL theo service của 0014 §5 và client franz-go hiện tại.
- Ràng buộc: buổi tối đa 4 giờ, dựng và gỡ trong buổi, chi phí có nguồn ([0048](0048-prd-aws.md) §10); SCP chỉ cho `ap-southeast-1`, `us-east-1`.

## Yếu tố quyết định

- Đạt độ bền trên mà không đổi code của service; stg và prd cùng phần mềm, một công cụ mỗi mảng.
- Trần buổi C và công vận hành; dựng, xoá trong buổi bằng đường đã có (Argo CD, Job tạo topic và user).
- Vừa sức chứa ba node của prd: số đo request, không ước theo cảm giác.

## Phương án đã cân nhắc

Trạng thái ngành tại 2026-11-05; in đậm là lựa chọn. Bảng đủ cột, giá và nguồn: [phụ lục](appendix/0049-kafka-prd.md#phương-án).

- **Redpanda bằng chart `redpanda` hiện có** (thông dụng): C ~$6,6; không thêm tài nguyên AWS; Redpanda khuyên Operator cho production [N3].
- Redpanda Operator (hiện hành, được hãng khuyên [N3]): thêm controller, CRD; CRD `Topic`, `User` thay Job; đổi cả stg.
- Apache Kafka qua Strimzi 1.3 (CNCF incubating [N10]): SCRAM chỉ SHA-512 [N11] (đổi `kafkax`), JVM nặng hơn, compose vẫn Redpanda.
- Amazon MSK provisioned, broker Standard `kafka.m7g.large` × 3: C ~$9,6; SCRAM chỉ SHA-512 qua Secrets Manager với KMS key riêng, bật TLS [N6];
  đổi `kafkax` (TLS, SHA-512), user tạo bằng Terraform; stg khác prd.
- MSK Express `express.m7g.large` × 3: C ~$12,6; mạnh cho tải lớn, quá cỡ cho lab.
- MSK Serverless: C ~$10,8; chỉ IAM, không ACL Kafka [N8]: đổi xác thực của mọi service và mô hình quyền.

## Kết quả quyết định

Chọn Redpanda bằng chart và component `redpanda` của stg: đạt độ bền cần có với cùng phần mềm, cùng SCRAM-SHA-256, cùng Job của chart `svp-data`,
không thêm dịch vụ AWS và rẻ nhất (C ~$6,6 so với ~$9,6 của MSK rẻ nhất). Cái giá: tự vận hành ba broker có trạng thái (PVC theo AZ, rolling
restart, nâng version), CPU hẹp, lệch khuyến nghị Operator của hãng. Chi tiết và số đo: [phụ lục](appendix/0049-kafka-prd.md#chi-tiết-rút-khỏi-adr).

### 1. Cài đặt và mạng giữa broker

- Component `redpanda` của `components.json` (chart `redpanda` 26.2.4, values `base/redpanda.yaml`, wave 3) như stg; prd thêm overlay
  `envs/prd/redpanda.yaml` của `svp-gitops`. Stg và compose giữ một broker, không đổi.
- Namespace `svp-data` chặn hai chiều từ wave 1 (chart `svp-cluster`), chart `redpanda` không tạo NetworkPolicy. Ba broker phải gọi nhau ở RPC TCP 33145
  (seed, Raft, sao chép; chưa gặp đủ seed thì không lập cluster) và Admin API TCP 9644 (sidecar và hook §5 dùng danh sách admin của cả ba broker).
- Policy `redpanda-peers` mở đúng hai cổng đó, vào và ra, giữa các pod Redpanda của `svp-data`, ở chart `svp-cluster` (wave 1) như policy của Kyverno,
  External Secrets, Envoy. Không đặt ở `svp-data` (wave 4): root chỉ sang wave 4 khi Redpanda Healthy, broker thiếu policy không bao giờ Ready. Render ở
  mọi nền tảng; một broker thì chỉ mở cho chính nó. Kafka TCP 9092 giữa broker không mở: chỉ client nội bộ của HTTP proxy và schema registry dùng, hai
  dịch vụ không ai gọi.
- Collector scrape `/public_metrics` của mọi broker, tìm qua DNS của Service headless `redpanda` thay target tĩnh `redpanda-0` (một cấu hình cho một
  hay ba broker): mỗi broker chỉ xuất số đo của chính nó.

### 2. Độ bền ghi

- Ba broker (`statefulset.replicas: 3`); mọi topic của Job tạo topic (8 topic, cả DLQ) replication factor 3 ở prd, mặc định 1 (compose, stg). Topic đã
  có thì Job không đổi replica (idempotent như hiện nay).
- Không đặt `min.insync.replicas`: Redpanda không có thuộc tính topic này [N1]; mỗi partition là một nhóm Raft, `acks=all` trả lời khi đa số bản
  (2/3) đã ghi và fsync [N2], tương đương `replication.factor=3` + `min.insync.replicas=2` của Kafka. Producer franz-go mặc định `acks=all`, idempotent
  [N12]; code không đặt khác.
- Topic nội bộ (`__consumer_offsets`…) theo `internal_topic_replication_factor` mặc định 3 [N4]; chart đặt `default_topic_replications: 3` khi có ba broker.

### 3. Trải AZ và lưu trữ

Mỗi AZ đúng một broker, là ràng buộc cứng: overlay prd đặt `topologySpreadConstraints` theo `topology.kubernetes.io/zone` với `maxSkew: 1`,
`whenUnsatisfiable: DoNotSchedule`, `minDomains: 3` (mặc định của chart là `ScheduleAnyway`, chỉ ưu tiên, nên khi ASG dựng node ở A, A, B vì một AZ
thiếu capacity, hai broker cùng AZ và mất AZ đó là mất quorum); khi chỉ có hai AZ, broker thứ ba ở `Pending` thay vì chạy sai bố cục. Anti-affinity
theo node của chart giữ nguyên. Rack awareness của chart (`rackAwareness`, nhãn zone; cần quyền `get` node) để ba bản của mỗi partition nằm ở ba AZ. PVC 10 GiB trên StorageClass mặc định `gp3` của nền tảng eks. Volume EBS gắn
một AZ: broker mất node chỉ lên lại ở AZ đó; trong lúc chờ, hai broker còn lại giữ đa số. PodDisruptionBudget `maxUnavailable: 1` (mặc định của chart).

### 4. Sức chứa

Mỗi broker `resources.cpu.cores: 500m` (chart đặt `--smp=1`, overprovisioned), bộ nhớ như stg (`--memory=1G`, giới hạn 1280Mi). Ba node `m7g.large`
cho ~5,79 vCPU allocatable [N13]; request của mọi pod prd với ba broker nửa core ~5,35 vCPU, với ba broker một core ~6,85 vCPU (không vừa); bộ nhớ
~9,1 / ~18,5 GiB. Đo đầy đủ: phụ lục §4. Node thêm khi đo tải vẫn theo [0048](0048-prd-aws.md) (O₀).

### 5. Vòng đời broker

Admin API đòi xác thực (`admin_api_require_auth`, 0014 §5), nên hook `postStart`/`preStop` của chart (curl không credential) bị thay trong overlay prd
bằng `rpk cluster maintenance disable|enable --wait` [N5] chạy với `svp-admin` (biến `RPK_USER`, `RPK_PASS` từ Secret `redpanda-bootstrap`, như Job
init): broker rời leadership trước khi dừng, rolling restart không làm partition mất đa số. `rpk` gọi admin host của cả ba broker, qua policy §1.

### 6. Xác thực, topic, user, secret

- SASL SCRAM-SHA-256, user và ACL theo service, superuser `svp-admin`: như 0014 §5; Job `redpanda-init` của `svp-data` giữ nguyên, nhận admin host
  của cả ba broker để vẫn chạy khi một broker mất.
- Bước (1) của cập nhật secret ([0048](0048-prd-aws.md) §5) không đổi: user SCRAM nằm trong kho credential SASL của cluster [N9], đặt qua Admin API
  của `redpanda-0`; `redpanda-0` không chạy thì script dừng trước khi ghi gì, như hiện nay.

### 7. Chi phí

H_k ~$0,004/giờ (PVC gp3 3 × 10 GiB; không node thêm), O_k ~$0,16/buổi (dữ liệu giữa AZ của sao chép và client, ước lượng). Trần buổi prd
**C = 4 × (H₀ + H_k) + O₀ + O_k = 4 × (0,90 + 0,004) + 2,8 + 0,16 ≈ $6,6**; R không đổi (~$4,6/tháng, 0048 §10). Bảng: phụ lục, mục "Chi phí".

### Hệ quả

- Tốt: một phần mềm Kafka cho compose, stg, prd; không đổi code; chart `svp-data` thêm tham số, `svp-cluster` thêm một NetworkPolicy; dựng và gỡ cùng
  cluster; không tài nguyên AWS mới.
- Xấu: tự vận hành broker có trạng thái; CPU broker hẹp (nửa core, chung node với service) và dư CPU của cluster chỉ ~0,4 vCPU; lệch khuyến nghị
  Operator của Redpanda; giấy phép BSL (không được bán Redpanda như dịch vụ [N7], lab không vướng).
- Xem lại khi: chart `redpanda` bị hãng ngừng hay cần CRD `Topic`/`User` (sang Operator); tải đo ở prd cần hơn nửa core mỗi broker hay node thêm
  thường trực; cần dữ liệu Kafka sống qua buổi hay người thứ hai vận hành (MSK); chi phí thực đo lệch quá 50 %.

## Xác nhận

- Lúc quyết chưa hiện thực. Đã kiểm: `helm template` chart `redpanda` 26.2.4 với `base/redpanda.yaml` và ba replica, với `cores: 500m` (phụ lục §4);
  request cộng từ render mọi component của prd × eks.
- Còn lại: render của check `svp-gitops` cho prd (ba broker, rack awareness, hook có credential, policy `redpanda-peers`); test `rpk` giả của Job
  (replica 1 mặc định, 3 ở prd); buổi prd: ba broker Ready ở ba AZ, `rpk topic describe` thấy 3 replica, xoá một pod broker khi đang ghi mà không mất
  event.

## Hiện thực ở

- Repo code: `deploy/redpanda/create-topics.sh` (replication factor là tham số), `deploy/helm/svp-data/` (value replica, admin host của ba broker),
  `deploy/helm/svp-cluster/templates/networkpolicies.yaml` (policy `redpanda-peers`, §1), `deploy/observability/otelcol/k8s-config.yaml` (scrape mọi broker).
- `svp-gitops`: `envs/prd/redpanda.yaml` (§2–§5), `envs/prd/svp-data.yaml` (§2, §6).

## Nguồn

Đọc 2026-11-05; đủ [N1]–[N21] và giá ở phụ lục. [N1] <https://docs.redpanda.com/current/reference/properties/topic-properties/>,
[N2] <https://docs.redpanda.com/current/develop/produce-data/configure-producers/>,
[N3] <https://docs.redpanda.com/current/deploy/redpanda/kubernetes/k-deployment-overview/>,
[N6] <https://docs.aws.amazon.com/msk/latest/developerguide/msk-password-limitations.html>.

## Thông tin thêm

Phụ lục: [`appendix/0049-kafka-prd.md`](appendix/0049-kafka-prd.md) (bảng phương án, chi tiết từng §, đo sức chứa, chi phí H_k, O_k, trần C, nguồn).
