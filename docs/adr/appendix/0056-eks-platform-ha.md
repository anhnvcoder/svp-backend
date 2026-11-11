# Phụ lục ADR-0056: Node EKS do Karpenter tự quản cấp trên một nhóm node hệ thống on-demand; Envoy và Kyverno chạy HA, trải theo zone; log control plane đủ năm loại; add-on và AMI ghim version

Phụ lục của [ADR-0056](../0056-eks-platform-ha.md): bảng phương án, bảng tính nhóm node hệ thống, nguồn version và nguồn. Mọi nguồn đọc ngày
2026-11-11.

## Phương án

| Phương án | Trạng thái ngành | Phí | Công vận hành | Chuyển cloud | Nguồn |
| --- | --- | --- | --- | --- | --- |
| Managed node group + Cluster Autoscaler | Cũ cho EKS mới: vẫn được hỗ trợ, ngành chuyển sang Karpenter | Chỉ EC2 | Một node group mỗi loại instance; scale theo Auto Scaling group, không theo zone của pod | Cao: Cluster Autoscaler chạy ở mọi cloud | [N1] |
| EKS Auto Mode | Hiện hành, mới (GA 2024-12) | EC2 cộng phí quản lý; ví dụ của trang giá là 12 % giá EC2, ~$0,01224/giờ mỗi `m7g.large` ở Singapore (phụ lục 0034, Câu 7) | Thấp: AWS chạy Karpenter, LBC, EBS CSI, Pod Identity agent; controller không xem, không chỉnh được | Thấp: chỉ EKS | [N4] |
| **Karpenter tự quản + managed node group hệ thống** | Hiện hành, mặc định của EKS Best Practices cho autoscale node | Chỉ EC2 (node group hệ thống on-demand) | Giữ chart, IAM, SQS, nâng version theo bảng compatibility | Trung bình: lõi ở `kubernetes-sigs/karpenter`, provider AWS và Azure (AKS Node Auto Provisioning); GKE có cơ chế riêng | [N1], [N5] |
| Karpenter trên Fargate | Hiện hành, phương án thay trong Best Practices | Fargate theo vCPU-giờ | Không node hệ thống cho Karpenter, nhưng add-on, Argo CD vẫn cần node trước khi Karpenter lên | Như Karpenter | [N1] |

## 3. Nhóm node hệ thống: bảng tính

Những gì phải chạy trước khi Karpenter có node đầu tiên: add-on EKS, DaemonSet, Argo CD (bootstrap), Karpenter và component wave 0 (Argo CD đồng bộ
wave 1 chỉ khi wave 0 khoẻ). Request lấy từ values của `svp-gitops` hay mặc định chart, add-on; chart không đặt request thì ghi 0 (pod vẫn dùng tài
nguyên, buổi stg đo bằng `kubectl describe node`).

| Pod | Replica | Request mỗi replica | Tổng | Nguồn số |
| --- | --- | --- | --- | --- |
| Karpenter controller | 2 | 1 CPU, 1 Gi | 2 000m, 2 048 Mi | [N7] |
| CoreDNS (add-on) | 2 | 100m, 70 Mi | 200m, 140 Mi | mặc định add-on |
| metrics-server (add-on) | 1 | 100m, 200 Mi | 100m, 200 Mi | mặc định add-on |
| EBS CSI controller (add-on) | 2 | 6 container × 10m, 40 Mi | 120m, 480 Mi | mặc định add-on |
| Envoy Gateway controller | 1 | 100m, 256 Mi | 100m, 256 Mi | mặc định chart, `base/envoy-gateway.yaml` chỉ đặt limit |
| External Secrets controller | 1 | 10m, 64 Mi | 10m, 64 Mi | `base/external-secrets.yaml` |
| Argo CD, cert-manager | — | không đặt | 0 | mặc định chart |
| **Cộng (không DaemonSet)** | | | **2 530m, 3 188 Mi** | |

DaemonSet mỗi node: `aws-node` 25m, `kube-proxy` 100m, EBS CSI node 3 × 10m, 40 Mi: **155m, 120 Mi** (mặc định add-on; `nodeExporter` tắt ở
`base/kube-prometheus-stack.yaml`).

Allocatable của `m7g.large` (2 vCPU, 8 GiB) theo công thức reserve của AMI EKS AL2023 [N17]: CPU 2 000m − 70m = 1 930m; bộ nhớ 8 192 Mi −
(255 Mi + 11 Mi × 110 pod) − 100 Mi eviction = 6 627 Mi.

| Env | Node | CPU mỗi node | % allocatable | Bộ nhớ mỗi node | % allocatable |
| --- | --- | --- | --- | --- | --- |
| stg | 2 | 2 530 / 2 + 155 = 1 420m | 74 % | 3 188 / 2 + 120 = 1 714 Mi | 26 % |
| prd | 3 | 2 530 / 3 + 155 ≈ 1 000m | 52 % | 3 188 / 3 + 120 ≈ 1 183 Mi | 18 % |

CPU là ràng buộc (mỗi node một replica Karpenter 1 CPU). `c7g.large` (2 vCPU, 4 GiB) cũng vừa CPU nhưng còn ~2,5 GiB allocatable cho mọi pod
khác đặt lên nhóm này trước khi Karpenter có node; `m7g.large` giữ cùng loại với node cũ. `m7g.xlarge` gấp đôi giá cho phần CPU chỉ cần khi có
thêm controller vào nhóm.

## 8. Nguồn version

Output lệnh chỉ đọc người học chạy ngày 2026-11-11, profile `anhnv-stg`, region `ap-southeast-1`:

- `aws eks describe-addon-versions --kubernetes-version 1.36` (bản mặc định / mới nhất): `vpc-cni` `v1.22.4-eksbuild.14` /
  `v1.23.3-eksbuild.1`; `kube-proxy` `v1.36.0-eksbuild.65`; `coredns` `v1.14.7-eksbuild.35`; `eks-pod-identity-agent` `v1.4.1-eksbuild.3`;
  `aws-ebs-csi-driver` `v1.67.2-eksbuild.1`; `metrics-server` `v0.9.0-eksbuild.14`.
- `aws ssm get-parameter --name /aws/service/eks/optimized-ami/1.36/amazon-linux-2023/arm64/standard/recommended/release_version`: `1.36.5-20261107`.
  Alias của EC2NodeClass dùng phần ngày: `al2023@v20261107` [N9].
- Karpenter: release `v1.15.1` (2026-10-23) trên GitHub `aws/karpenter-provider-aws`, bảng compatibility: Kubernetes 1.36 cần ≥ 1.13, 1.37 cần
  1.15.x [N5].

## Nguồn

- [N1] EKS Best Practices, Karpenter: <https://docs.aws.amazon.com/eks/latest/best-practices/karpenter.html>
- [N2] EKS Best Practices, Running highly-available applications: <https://docs.aws.amazon.com/eks/latest/best-practices/application.html>
- [N3] EKS Best Practices, Cluster upgrades: <https://docs.aws.amazon.com/eks/latest/best-practices/cluster-upgrades.html>
- [N4] Amazon EKS pricing (EKS Auto Mode): <https://aws.amazon.com/eks/pricing/>
- [N5] Karpenter, Compatibility: <https://karpenter.sh/docs/upgrading/compatibility/>
- [N6] Karpenter chart values v1.15.1: <https://github.com/aws/karpenter-provider-aws/blob/v1.15.1/charts/karpenter/values.yaml>
- [N7] Karpenter, Getting Started with Karpenter: <https://karpenter.sh/docs/getting-started/getting-started-with-karpenter/>
- [N8] Karpenter, NodePools: <https://karpenter.sh/docs/concepts/nodepools/>
- [N9] Karpenter, Disruption: <https://karpenter.sh/docs/concepts/disruption/>; NodeClasses: <https://karpenter.sh/docs/concepts/nodeclasses/>
- [N10] Amazon VPC CNI, prefix delegation: <https://docs.aws.amazon.com/eks/latest/best-practices/prefix-mode-linux.html>
- [N11] Envoy Gateway, Customize EnvoyProxy (`envoyHpa`): <https://gateway.envoyproxy.io/docs/tasks/operations/customize-envoyproxy/>
- [N12] Envoy Gateway API, `KubernetesPodDisruptionBudgetSpec`: <https://gateway.envoyproxy.io/docs/api/extension_types/>
- [N13] Kyverno, Installation methods (High Availability): <https://kyverno.io/docs/installation/methods/>; chart values:
  <https://github.com/kyverno/kyverno/blob/main/charts/kyverno/values.yaml>
- [N14] Karpenter, Scheduling (topology spread): <https://karpenter.sh/docs/concepts/scheduling/>
- [N15] EKS Best Practices, Auditing and logging: <https://docs.aws.amazon.com/eks/latest/best-practices/auditing-and-logging.html>
- [N16] Amazon EKS control plane logs: <https://docs.aws.amazon.com/eks/latest/userguide/control-plane-logs.html>
- [N17] amazon-eks-ami, `nodeadm`, reserve của kubelet (`getCPUMillicoresToReserve`, `getMemoryMebibytesToReserve`): <https://github.com/awslabs/amazon-eks-ami/blob/main/nodeadm/internal/kubelet/config.go>
