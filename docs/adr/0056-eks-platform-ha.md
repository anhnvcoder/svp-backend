# 0056. Node EKS do Karpenter tự quản cấp trên một nhóm node hệ thống on-demand; Envoy và Kyverno chạy HA, trải theo zone; log control plane đủ năm loại; add-on và AMI ghim version

- Trạng thái: Chấp nhận
- Ngày: 2026-11-11
- Người quyết: người học (Karpenter trong bảng công cụ chốt của lộ trình; ma trận stg/prd của [0055](0055-environment-matrix.md)), AI đề xuất
  phần còn lại theo chuẩn ngành

## Bối cảnh và vấn đề

- [0034](0034-aws-stage7.md) Câu 7 A chạy một managed node group cố định Graviton (Spot ở stg), hẹn Karpenter cho prd; [0048](0048-prd-aws.md)
  để Karpenter ra ngoài phạm vi. Node cố định không theo pod đang chờ; controller nền tảng nằm trên Spot ở stg.
- Ingress Envoy một replica, không HPA, không PDB; Kyverno một replica với webhook fail-closed; pod không trải theo zone: mất một node hay một AZ
  là mất ingress hay mất admission.
- Add-on EKS lấy bản mới nhất lúc plan: stg và prd có thể chạy bản khác nhau. Log control plane: stg không có, prd thiếu `controllerManager`,
  `scheduler`. [0055](0055-environment-matrix.md) §2 xếp version, HA nền tảng và loại log vào nhóm phải giống.
- Ràng buộc như 0034: buổi tối đa 4 giờ, dựng và gỡ trong buổi; AI không chạy lệnh chạm account.

## Yếu tố quyết định

- Chuẩn ngành cho EKS production: EKS Best Practices Guide (Karpenter, reliability, cluster upgrades) [N1]–[N3].
- Node theo yêu cầu của pod, controller nền tảng không chạy trên Spot hay trên node mà chính Karpenter quản [N1].
- Mất một AZ không mất ingress và admission; stg, prd cùng version; học được controller và IAM của nó (không giấu trong dịch vụ).
- Gỡ trong buổi luôn kết thúc: không node nào Karpenter tạo còn sót khi `terraform destroy`.

## Phương án đã cân nhắc

Trạng thái ngành, phí, công vận hành, khả năng chuyển cloud: [phụ lục](appendix/0056-eks-platform-ha.md#phương-án).

- Giữ managed node group, thêm Cluster Autoscaler: quen thuộc, nhưng mỗi loại instance một node group, scale theo node group [N1].
- EKS Auto Mode: AWS chạy Karpenter, LB, EBS thay mình; phí quản lý ~12 % giá EC2 mỗi node [N4]; giấu đúng phần lab muốn học; chỉ AWS.
- **Karpenter tự quản** trên một managed node group hệ thống nhỏ: chọn instance theo pod đang chờ, consolidation, interruption Spot; controller
  và IAM do mình giữ; lõi ở `kubernetes-sigs`, có provider AWS và Azure.
- Controller Karpenter trên Fargate thay node group hệ thống: không node nào để giữ, nhưng còn add-on, Argo CD cần node trước khi Karpenter lên.

## Kết quả quyết định

Chọn Karpenter tự quản trên nhóm node hệ thống, vì nó đạt cả bốn yếu tố với giá chỉ là công vận hành một controller. Các § dưới ghi số mà
code đọc; số liệu tính và nguồn từng số: phụ lục.

### 1. Controller Karpenter

- Chart `oci://public.ecr.aws/karpenter/karpenter` **1.15.1** (bản mới nhất; EKS 1.36 cần ≥ 1.13, 1.15 cũng chạy 1.37 cho lần nâng minor
  sau [N5]); image ghim digest. Namespace `kube-system`, SA `karpenter`. IAM, SQS, EventBridge bằng submodule `karpenter` của module `eks`
  (cùng 21.29.0), Pod Identity bằng association của submodule. Tên suy từ tên cluster, nguyên văn, không hậu tố ngẫu nhiên (EC2NodeClass suy
  tên role từ đó): hàng đợi `svp-<env>-karpenter`, role node `svp-<env>-karpenter-node`, role controller `svp-<env>-karpenter`; tag
  `karpenter.sh/discovery = svp-<env>` trên subnet private và security group của node.
- Hai replica (mặc định chart: anti-affinity theo hostname, trải zone `DoNotSchedule`, nodeAffinity tránh node có nhãn `karpenter.sh/nodepool`
  [N6]); request bằng limit, **1 CPU, 1 Gi** mỗi replica như hướng dẫn cài [N7]. `settings.clusterName = svp-<env>`, `settings.interruptionQueue
  = svp-<env>-karpenter`.

### 2. NodePool và EC2NodeClass

Một NodePool `default` và một EC2NodeClass `default` [N8], [N9]; mọi giá trị ở `platforms/eks/svp-cluster.yaml` theo mức prd; stg ghi đè đúng phần
giảm ở `envs/stg/svp-cluster.yaml` (prd không có overlay: lớp nền tảng là chuẩn, overlay chỉ giữ phần khác).

| Khoá | Giá trị | Chỗ giữ |
| --- | --- | --- |
| Kiến trúc, họ | `arm64`; `instance-category` c, m, r; `instance-generation` > 6; `instance-size` large, xlarge, 2xlarge | chung |
| AMI | alias `al2023@v20261107` (§8) | chung |
| Node | IMDSv2 hop 1; gốc gp3 30 GiB mã hoá; `kubelet.maxPods` 110 (prefix delegation, instance < 30 vCPU [N10]); tag `Project=svp` | chung |
| `expireAfter` | `720h` (mặc định [N8]) | chung |
| `terminationGracePeriod` | **`10m`** (§9) | chung |
| `consolidationPolicy`, `consolidateAfter` | `WhenEmptyOrUnderutilized`, `5m` (không xoay node theo từng nhịp scale của KEDA) | chung |
| `karpenter.sh/capacity-type` | stg `spot`; prd `on-demand` | nền tảng (prd), stg ghi đè |
| `limits` | stg `cpu: 16`, `memory: 64Gi`; prd `cpu: 32`, `memory: 128Gi` | nền tảng (prd), stg ghi đè |
| Ngân sách disruption | stg `nodes: "50%"`; prd `nodes: "1"` | nền tảng (prd), stg ghi đè |

`limits` là trần chi phí: node group cũ có 6 vCPU (3 × `m7g.large`); stg chừa chỗ cho k6, prd cho bậc tải 1 000 req/s
([0020](0020-reliability-stage6.md)).
Spot của stg chọn từ nhiều họ và cỡ cho Price Capacity Optimized [N1]; interruption đi qua hàng đợi SQS, báo trước 2 phút [N9].

### 3. Nhóm node hệ thống

Managed node group `system` thay group `default`: **`m7g.large`** on-demand ở cả hai env, `ami_release_version` §8, IMDSv2 hop 1, gốc gp3 30 GiB,
không taint; min = desired = số AZ, **max = 2 × số AZ** (chỗ để scale tay; không gì tự scale group này). Cỡ theo tổng request của những gì phải
chạy trước khi Karpenter có node: add-on EKS, DaemonSet, Argo CD, Karpenter, component wave 0. Tổng ~2,5 vCPU, ~3,1 GiB ngoài DaemonSet; stg hai
node dùng ~74 % CPU allocatable mỗi node, prd ~52 % (bảng tính: phụ lục §3). CPU là ràng buộc vì mỗi node giữ một replica Karpenter 1 CPU.

### 4. Envoy HA

EnvoyProxy `svp`: `envoyHpa` min 2, **max 4**, CPU **60 %** (ví dụ của tài liệu Envoy Gateway [N11]; request CPU của proxy giữ như chart);
`envoyPDB` `minAvailable: 1` [N12]; trải theo §6. Giống nhau ở k3d và EKS (max 4 vừa máy 16 GB). HPA cần metrics-server: add-on ở EKS, có sẵn ở k3s.

### 5. Kyverno HA

Chỉ nền tảng `eks` (`platforms/eks/kyverno.yaml`): admission controller **3 replica** (ví dụ HA của Kyverno [N13]), PDB `maxUnavailable: 1`
(chart chỉ bật PDB, mặc định `minAvailable: 1` cho phép mất hai trong ba), trải theo §6. Reports controller giữ một replica: nó không nằm trên
đường admission.

### 6. Trải zone

`topologySpreadConstraints` trên `topology.kubernetes.io/zone`, `maxSkew: 1`, `whenUnsatisfiable: ScheduleAnyway` [N2], đứng trước ràng buộc
`kubernetes.io/hostname`; áp cho service (`spreadAcrossNodes: true`), Envoy, Kyverno. `ScheduleAnyway`: khi một AZ hết chỗ, pod vẫn chạy ở AZ còn
lại thay vì Pending; Karpenter coi ràng buộc này là ưu tiên khi chọn zone cho node mới [N14].

### 7. Log control plane

Năm loại `api`, `audit`, `authenticator`, `controllerManager`, `scheduler` ở cả hai env [N15], [N16]; retention theo env (`<env>.tfvars`, nhóm được
giảm của 0055 §3).

### 8. Ghim version nền tảng

Đọc 2026-11-11 bằng lệnh chỉ đọc của người học ở `ap-southeast-1`; `aws-guardduty-agent` đọc 2026-11-12 từ bảng hỗ trợ của tài liệu
GuardDuty, cùng lệnh tra như add-on khác (phụ lục §8):

| Thành phần | Version ghim |
| --- | --- |
| `vpc-cni` | `v1.23.3-eksbuild.1` |
| `kube-proxy` | `v1.36.0-eksbuild.65` |
| `coredns` | `v1.14.7-eksbuild.35` |
| `eks-pod-identity-agent` | `v1.4.1-eksbuild.3` |
| `aws-ebs-csi-driver` | `v1.67.2-eksbuild.1` |
| `metrics-server` | `v0.9.0-eksbuild.14` |
| `aws-guardduty-agent` | `v1.17.3-eksbuild.2` |
| AMI AL2023 EKS arm64 | `ami_release_version = "1.36.5-20261107"`; alias EC2NodeClass `al2023@v20261107` |

- Bản mới nhất tương thích của mỗi add-on, không bản mặc định: hướng dẫn nâng cluster khuyên giữ add-on ở bản mới nhất [N3]. Hai nơi của AMI
  (node group hệ thống, EC2NodeClass) cùng một bản phát hành; khoá AMI ở production theo [N1].
- Renovate không cập nhật add-on và AMI: datasource `aws-eks-addon`, `aws-machine-image` cần credential AWS; release GitHub của
  `awslabs/amazon-eks-ami` chỉ cho ngày, không cho chuỗi `1.36.<patch>-<ngày>` của node group. Bước nâng ở runbook `eks-upgrade.md` của
  `svp-infra`. Chart và image Karpenter đi qua Renovate như component khác.

### 9. Gỡ trong buổi

`terminationGracePeriod` 10 phút là trần drain một node: quá trần Karpenter xoá pod còn lại và tắt instance dù PDB chặn [N9]. 10 phút vừa trần 30
phút của bước gỡ trong buổi 4 giờ. `pre-destroy.sh` giữ `karpenter` tới cuối, xoá NodePool rồi EC2NodeClass khi controller còn chạy, chờ tới khi
hết NodeClaim và instance, **giới hạn chờ 15 phút** (10 phút drain cộng thời gian tắt instance), quá hạn thì đỏ.

### 10. Nâng minor EKS

Thứ tự theo hướng dẫn nâng [N3], ở runbook `eks-upgrade.md`: kiểm Karpenter hỗ trợ minor mới [N5] (nâng chart trước nếu cần) → merge PR đổi alias
AMI của EC2NodeClass → control plane → add-on lên bản của §8 → node group hệ thống lên cùng bản AMI (Karpenter thay node theo drift, theo ngân
sách §2) → stg trước, prd sau một buổi stg xanh. Alias đổi trước vì Karpenter chỉ chọn AMI của minor mà control plane đang chạy (docs "Managing
AMIs": <https://karpenter.sh/docs/tasks/managing-amis/>): ngày mới có bản cho cả hai minor thì node thay theo thứ tự đúng; để alias cũ qua lúc
nâng, Karpenter drift sang AMI `1.N+1` của ngày cũ, hay hết AMI nếu ngày cũ chưa có bản đó.

### Hệ quả

- Tốt: node theo pod đang chờ, Spot của stg có interruption handling; controller nền tảng trên on-demand; ingress, admission, service sống qua
  mất một node hay một AZ; stg và prd chạy cùng bản add-on, AMI.
- Xấu: thêm một controller, IAM, SQS, EventBridge phải giữ; node group hệ thống tốn on-demand cả ở stg (~$0,10/giờ mỗi `m7g.large`, giá ở phụ lục 0034);
  nâng add-on và AMI là việc tay; log control plane thêm phí ingest.
- Xem lại khi: request trên nhóm hệ thống vượt 80 % allocatable của một node; Spot stg thiếu chỗ quá một lần mỗi buổi; EKS Auto Mode cho xem
  và chỉnh controller hay phí giảm dưới 5 %; Renovate có datasource AMI không cần credential.

## Xác nhận

- Lúc quyết chưa hiện thực. Kiểm tĩnh: `make test` của `svp-infra` (tên Karpenter, add-on ghim, node group), `make helm-check` (NodePool, HPA,
  PDB, trải zone render), check render của `svp-gitops`.
- Buổi stg: Karpenter dựng node Spot cho pod Pending, interruption giả lập thay node, `kubectl describe node` đo request thật của nhóm hệ thống
  so phụ lục §3, `pre-destroy.sh` xoá hết NodeClaim trong 15 phút. Buổi prd: drain một AZ, ingress và admission vẫn trả lời.

## Hiện thực ở

- `svp-infra`: `aws/modules/eks/` (node group hệ thống, add-on, submodule Karpenter, log), `aws/modules/network/` (tag discovery),
  `aws/envs/<env>/<env>.tfvars`, `aws/scripts/pre-destroy.sh`, `sweep.sh`, `docs/runbooks/eks-upgrade.md`.
- Repo code: chart `svp-cluster` (NodePool, EC2NodeClass, `templates/gateway.yaml`), chart `svp-service` (trải zone).
- `svp-gitops`: `argocd/apps/components.json` (component `karpenter`), `platforms/eks/svp-cluster.yaml`, `platforms/eks/kyverno.yaml`,
  `envs/stg/svp-cluster.yaml`.

## Nguồn

Đọc 2026-11-11; đủ [N1]–[N18] ở phụ lục. [N1] <https://docs.aws.amazon.com/eks/latest/best-practices/karpenter.html>,
[N5] <https://karpenter.sh/docs/upgrading/compatibility/>, [N9] <https://karpenter.sh/docs/concepts/disruption/>,
[N11] <https://gateway.envoyproxy.io/docs/tasks/operations/customize-envoyproxy/>, [N13] <https://kyverno.io/docs/installation/methods/>.

## Thông tin thêm

Phụ lục: [`appendix/0056-eks-platform-ha.md`](appendix/0056-eks-platform-ha.md) (bảng phương án, bảng tính nhóm node hệ thống, nguồn version).

### Chỉnh bởi

- §3, §5: [0062](0062-ecr-registry-ci-oidc.md): role node (group `system`, node Karpenter) thêm `ecr:BatchImportUpstreamImage`, `ecr:CreateRepository` trên repo pull-through cache; Kyverno thêm policy mutate `svp-registry-mirror` (`failurePolicy: Ignore`), admission controller có Pod Identity chỉ đọc repo phát hành.
- §3: [0065](0065-argocd-eks-capability.md): Argo CD trên `eks` chạy ở control plane của AWS (EKS Capability), không còn pod Argo CD trên node `system` khi thay đổi hiện thực; tới đó §3 giữ nguyên.
