# 0065. Argo CD trên eks chuyển sang EKS Capability cho Argo CD: AWS chạy và giữ HA, đăng nhập qua IAM Identity Center với vai trò theo nhóm, không tài khoản local; hiện thực ở thay đổi riêng, tới đó giữ Argo CD tự cài

- Trạng thái: Chấp nhận
- Ngày: 2026-11-13
- Người quyết: người học (prd là production chuẩn ngành, stg chạy như prd), AI đề xuất sau khi đường Dex SAML bị loại

## Bối cảnh và vấn đề

- Trên eks, Argo CD do root `aws/gitops/<env>` của `svp-infra` cài bằng chart `argo-cd` (module `gitops-bridge`, `argocd/bootstrap.json` của
  `svp-gitops`): mỗi thành phần một replica, Dex tắt, đăng nhập `admin` với mật khẩu khởi tạo, UI chỉ qua port-forward loopback (OPS-2 của
  [threat model](../threat-model.md)). Mất node chạy controller hay repo-server là dừng đồng bộ; mọi người dùng chung một tài khoản.
- prd cần: Argo CD HA, đăng nhập bằng danh tính của Identity Center (MFA, thu hồi tập trung), vai trò theo nhóm, không mật khẩu dùng chung.
- Identity Center chỉ làm IdP SAML 2.0 cho ứng dụng ngoài; OAuth của nó chỉ dành cho trusted identity propagation [N3]. Argo CD tự cài vì vậy
  cần Dex với connector SAML [N4], mà trang connector đó ghi: "The SAML connector is unmaintained, likely vulnerable to authentication bypass
  vulnerabilities … under consideration for deprecation" [N5].
- Ràng buộc: env sống trong buổi tối đa 4 giờ, dựng lại từ đầu mỗi buổi; Identity Center là instance của org ở account management
  ([0059](0059-org-structure-guardrails.md)); k3d giữ Argo CD tự cài; AI không chạy lệnh chạm account.

## Yếu tố quyết định

- Không thành phần xác thực nào mang cảnh báo bảo mật upstream chưa giải.
- Danh tính và nhóm lấy thẳng từ Identity Center; không mật khẩu, không khoá ký nào do lab giữ.
- HA không đòi lab tự giữ (redis-ha cần ít nhất ba node khác nhau [N6]).
- Manifest của `svp-gitops` giữ một đường cho k3d và eks; chi phí mỗi buổi nhỏ so với cluster.

## Phương án đã cân nhắc

Trạng thái ngành, được, mất, nguồn: [phụ lục](appendix/0065-argocd-eks-capability.md#phương-án). In đậm là lựa chọn.

- **(A) EKS Capability cho Argo CD**: AWS chạy Argo CD ngoài node, đăng nhập Identity Center, HA và vá do AWS [N1]; đổi cách cài, đích Application.
- (B) Argo CD tự cài, HA của chart, `oidc.config` tới Cognito user pool làm SP SAML của Identity Center: không Dex; thêm Cognito, có thể cả
  Lambda pre-token để đưa nhóm thành mảng mà Argo CD đọc [N7]; HA tự giữ như (C).
- (C) Argo CD tự cài, HA của chart, Dex SAML với Identity Center, chấp nhận rủi ro có ghi: theo trang Identity Center của Argo CD [N4];
  connector bị upstream cảnh báo [N5].
- (D) Giữ hiện trạng (một replica, `admin`, port-forward): không đạt yếu tố nào ở prd.

## Kết quả quyết định

Chọn (A), vì nó là cách duy nhất đạt cả ba yếu tố đầu mà lab không giữ thêm thành phần xác thực nào: Identity Center cấp danh tính, AWS giữ HA,
không tài khoản local. Chi tiết từng mục, luồng đăng nhập, bảng phương án: phụ lục, cùng số §.

### 1. Cách chạy

- Mỗi cluster eks một capability loại `ARGOCD` (resource `aws_eks_capability`, có từ provider AWS 6.25.0 [N8]; lock của `svp-infra` cao hơn),
  namespace `argocd`, `delete_propagation_policy = RETAIN`. Argo CD chạy ở control plane của AWS, không trên node; mở rộng, vá, nâng cấp do AWS [N1].
- Capability role tin `capabilities.eks.amazonaws.com` và không có policy IAM nào: Notifications đọc Secret trong cluster (§5), repo
  `svp-gitops` công khai nên không cần credential Git [N9].
- k3d giữ Argo CD tự cài từ `argocd/bootstrap.json`. Khác biệt là dữ liệu theo nền tảng: eks không cài release Argo CD, không `if`.

### 2. Đăng nhập và vai trò

- `aws_idc` trỏ instance Identity Center của org (`idc_instance_arn`, `idc_region`) [N8]. Capability chỉ nhận Identity Center, không người dùng
  local [N10]; vai trò toàn cục lấy từ `rbac_role_mapping`, không từ `argocd-rbac-cm` [N2].
- **Nhóm nền tảng** của Identity Center: `svp-platform-admins` → `ADMIN`, thấy mọi Application không cần project role; `svp-platform-viewers` →
  `VIEWER`. `VIEWER` không thấy Application nào khi thiếu project role [N12], nên AppProject `svp` thêm role `viewer` với một policy
  `p, proj:svp:viewer, applications, get, svp/*, allow` và `groups` là id nhóm viewers.
- Id nhóm không vào git: `argocd/project.yaml` giữ role, policy và `groups` rỗng; `gitops-bridge` (đã áp AppProject từ file đó) điền `groups` từ
  biến `platform_viewer_group_id`, capability đọc `platform_admin_group_id`, `platform_viewer_group_id`; mỗi root nhận chúng ở `<env>.auto.tfvars`
  không commit, như vai trò AMG ([0063](0063-managed-observability.md)). k3d áp file như cũ: role không nhóm, không tác dụng.
- Không bước "tắt `admin`": cluster dựng lại mỗi buổi và capability không có đăng nhập local từ buổi đầu. Không tạo token tài khoản (tối đa 12 giờ
  [N12]): không công việc nào gọi API Argo CD từ ngoài. Thứ tự kiểm SSO, phép kiểm thành công và thất bại, break-glass: phụ lục §2.

### 3. Đường vào UI

UI và API ở địa chỉ riêng của capability (`server_url`, `*.eks-capabilities.<region>.amazonaws.com`), sau đăng nhập Identity Center [N13]. Không
endpoint VPC `eks-capabilities`: endpoint đó không nhận endpoint policy [N13], và người học không có đường mạng vào VPC ngoài phiên SSM. Port-forward
loopback (OPS-2) không còn ở eks; threat model đổi cùng thay đổi hiện thực.

### 4. Quyền trên cluster

Capability role có access entry tự tạo nhưng không quyền Kubernetes nào [N9]; gắn access policy `AmazonEKSClusterAdminPolicy` phạm vi cluster.
Argo CD cài cả nền tảng (CRD, ClusterRole, ClusterRoleBinding, webhook, namespace); quyền tạo ClusterRoleBinding đã tương đương cluster-admin, như
ClusterRole `*` của controller tự cài hiện nay. Giới hạn thật là AppProject `svp` (namespace và loại cluster-scoped được phép) của `svp-gitops`.
Tài liệu khuyên không dùng policy này ở production [N9]: chấp nhận có lý do (phụ lục §4).

### 5. Manifest của `svp-gitops`

- Đích Application và AppProject đổi `server: https://kubernetes.default.svc` thành `name: in-cluster`: Argo CD tự cài có sẵn tên đó, capability
  cần Secret cluster tên `in-cluster` mang ARN cluster (không nhận `kubernetes.default`) [N9]. Một đường cho cả hai nền tảng.
- AppProject tự định nghĩa (`svp`) thêm `spec.sourceNamespaces: [argocd]`: capability bắt buộc trường này kể cả cho namespace chính [N20].
- Health Lua của `base/argo-cd.yaml` giữ: capability nhận `resource.customizations.*`, luôn tắt `useOpenLibs` [N14]; Lua hiện có không gọi `os`, `io`.
- Notifications: ConfigMap mang nhãn `eks.amazonaws.com/managed-notifications: "enabled"`; `github`, `telegram` có trong danh sách hỗ trợ;
  `$<khoá>` đọc Secret `argocd-notifications-secret` cùng namespace [N15]. Secret đó giữ như hiện nay: ExternalSecret của `svp-cluster` chọn
  từng trường của entry JSON `svp/<env>/argocd-notifications` và giải base64 khoá riêng GitHub App. Không đặt ARN làm giá trị khoá: capability
  thay ARN bằng cả SecretString, không chọn trường JSON [N15], nên mỗi khoá sẽ nhận cả JSON.

### 6. Điều thay đổi hiện thực phải kiểm trước

Region `ap-southeast-1` (Price List có SKU, chưa tạo thử); Identity Center của org ở account management, region khác, dùng từ cluster của account
thành viên; Argo Rollouts (health `Rollout`, canary); Lua chạy không `useOpenLibs`; timeout sync cố định 120 s [N2] với hook PostSync và wave dài;
bootstrap qua `gitops-bridge`; project role `viewer` (hai trang AWS tả `VIEWER` khác nhau [N11], [N12]); dịch vụ `github` của Notifications
với GitHub App và khoá PEM nhiều dòng trong Secret (trang không có ví dụ trường); `argocdUrl` của Notifications. Một điểm trượt mà không có
cách sửa trong tài liệu thì quay lại (C) bằng ADR mới.

### 7. Tới khi hiện thực

Argo CD trên eks giữ như Bối cảnh: một replica, `admin`, port-forward. Không dựng HA tự quản hay Dex tạm thời: cả hai bị (A) thay ngay sau đó.

### 8. Chi phí

Price List `AmazonEKS` `ap-southeast-1` (phát hành 2026-11-11): $0,03642 mỗi giờ capability, $0,001803 mỗi Application-giờ [N16]. Buổi 4 giờ với
~27 Application: ~$0,34 mỗi env; lúc không buổi $0 (capability gỡ cùng cluster). Thay đổi này: $0 (chưa hiện thực). Bảng: phụ lục §8.

### Hệ quả

- Tốt: Argo CD HA và được vá mà lab không giữ pod nào; đăng nhập bằng Identity Center, vai trò theo nhóm, không mật khẩu dùng chung; bớt pod nền
  tảng trên node phải chạy trước Karpenter ([0056](0056-eks-platform-ha.md)); capability role không có policy IAM nào.
- Xấu: Argo CD trên eks và k3d khác nhau (bản, tính năng: không CMP, không UI extension, timeout cố định [N2]); phiên bản do AWS chọn; UI ở endpoint
  công khai có xác thực; capability role là cluster-admin; tới khi hiện thực, prd vẫn chạy hiện trạng (D).
- Xem lại khi: một điểm của §6 trượt; dùng tới CMP hay timeout sync dài hơn; có VPN vào VPC (UI qua endpoint `eks-capabilities`); chia AppProject
  theo đội (thu quyền §4); ARN trong Secret Notifications chọn được trường JSON (bỏ ExternalSecret).

## Xác nhận

- Lúc quyết chưa hiện thực. Thay đổi hiện thực kiểm từng điểm của §6 trên account sandbox trước, rồi ở buổi stg:
  thành viên `svp-platform-admins` đăng nhập `server_url`, thấy `svp-root` Healthy và sync được; thành viên `svp-platform-viewers` thấy (nhờ
  project role `viewer`) nhưng sync bị từ chối; người ngoài hai nhóm không vào được; không form đăng nhập `admin`.
- Commit status `argocd/<env>` trên `svp-gitops` vẫn ghi khi root Healthy; `sweep.sh <env>` không còn capability.

## Hiện thực ở

Chưa hiện thực. Hiện trạng (D): `svp-infra` `aws/modules/gitops-bridge/`, `aws/gitops/<env>/`; `svp-gitops` `argocd/bootstrap.json`,
`base/argo-cd.yaml`, `platforms/eks/argo-cd.yaml`, `argocd/project.yaml`. Nhóm: `svp-infra` `aws/org/identity-center.tf`.

## Nguồn

Đọc 2026-11-13; đủ [N1]–[N16] ở phụ lục. [N1] <https://docs.aws.amazon.com/eks/latest/userguide/argocd.html>,
[N2] <https://docs.aws.amazon.com/eks/latest/userguide/argocd-comparison.html>, [N5] <https://dexidp.io/docs/connectors/saml/>.

## Thông tin thêm

Phụ lục: [`appendix/0065-argocd-eks-capability.md`](appendix/0065-argocd-eks-capability.md) (phương án, luồng đăng nhập, kiểm SSO và break-glass,
quyền, chi phí, bảng control Security Hub, bảng luồng SCP, RCP, nguồn).
