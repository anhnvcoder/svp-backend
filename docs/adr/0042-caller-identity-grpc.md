# 0042. Service gRPC tự kiểm access token mà gateway chuyển tiếp, bỏ `x-user-id`; mTLS giữa service bằng Istio ambient, dựng ở EKS, chưa dựng ở k3d

- Trạng thái: Chấp nhận
- Ngày: 2026-11-02
- Người quyết: AI (đề xuất), người học (uỷ quyền)

## Bối cảnh và vấn đề

[0006](0006-contract-ids-and-event-envelope.md) §5 chọn phương án C: gateway kiểm JWT rồi đặt `user_id` vào metadata gRPC `x-user-id`, service
tin giá trị đó (`internal/callerid`); kênh gateway → service là gRPC plaintext. Hệ quả ở [threat model](../threat-model.md) §4.5: **ai gửi được
gRPC tới service là giả được mọi người dùng** (IN-2).

- k3d, EKS: chart `svp-cluster` chặn hai chiều mọi pod của `svp`, NetworkPolicy của chart `svp-service`
  (`templates/networkpolicy.yaml`) chỉ cho các peer trong `ingressFrom` vào cổng của service: cổng gRPC chỉ gateway vào được. IN-3 (kẻ tấn công
  đứng ở chỗ NetworkPolicy cho phép, hay nghe lén mạng nội bộ) chấp nhận tới khi có mesh: Istio ambient đã được chọn rồi dời vì RAM
  ([0020](0020-reliability-stage6.md), mục dời).
- compose: không có lớp nào giữa các container cùng mạng `default`, mà mạng này chứa mọi container trừ media-worker và web (Redpanda, object
  store, Collector, LGTM, GlitchTip, job migrate): container nào trong đó bị chiếm cũng gọi thẳng service với `x-user-id` bất kỳ.
- Chỉ gateway gọi gRPC; các service không gọi nhau (`grpc.NewClient` chỉ có ở gateway và health check), nên danh tính đi đúng một chặng.

Ràng buộc: JWT-10 (chỉ user-service giữ khoá ký Ed25519; gateway giữ khoá công khai `JWT_VERIFY_KEYS`, nguồn `jwt-verify` có ở mọi môi trường:
`.env`, `deploy/k8s/secrets.sh`, ExternalSecret); máy 16 GB: cluster GitOps nghỉ 6,93 GiB (mốc cắt 6,5 GiB), lúc đỉnh VM Docker 9,7 GiB chỉ
còn 1,06 GiB `MemAvailable`, lượt đo trên runner vượt ngân sách cả nghỉ lẫn đỉnh ([0017](0017-gitops-capacity-media-worker-max2.md));
[0037](0037-mainpath-standard-tools.md): đường chính một đường thẳng, khác biệt nền tảng là dữ liệu; stg, prd dựng rồi xoá trong buổi; EKS
stg 3 node `m7g.large` 8 GiB (`aws/envs/stg/stg.tfvars` của `svp-infra`, [N10]).

## Yếu tố quyết định

- Giả danh tính phải cần một bí mật mà pod bị chiếm trong mạng không có, ở compose, k3d và EKS như nhau.
- Không thêm khoá ký hay secret; giữ JWT-10.
- Không thêm thành phần thường trực trên máy 16 GB.
- Một đường thẳng: cùng code, cùng biến ở mọi môi trường ([0037](0037-mainpath-standard-tools.md)).
- Công cụ, mẫu theo hiện trạng ngành, có nguồn.

## Phương án đã cân nhắc

Nguồn đọc ngày 2026-11-02; bảng trạng thái ngành, RAM và ưu nhược từng phương án ở phụ lục.

- **1a.** mTLS do mesh Istio ambient (ztunnel mỗi node, istiod, istio-cni) [N3], [N4]: mTLS, danh tính workload, AuthorizationPolicy không đổi code;
  không có ở compose, request mặc định thêm ~3,2 GiB trên k3d đã vượt ngân sách, không mang danh tính người dùng.
- **1b.** mTLS do mesh Linkerd (sidecar mỗi pod) [N5]: không có stable mã nguồn mở, sidecar ở mọi pod, cùng giới hạn compose.
- **2.** SPIFFE/SPIRE [N6]: SVID X.509 xoay tự động; hai thành phần mới, TLS trong code mọi service, compose cần Docker socket.
- **3.** cert-manager cấp chứng chỉ từng service [N7]: dùng cert-manager có sẵn; csi-driver-spiffe còn 0.x, code tự nạp và xoay chứng chỉ.
- **4.** Token nội bộ do gateway ký [N1], [N2], [N8]: gateway (thành phần ra internet) giữ khoá ký được mọi danh tính, trái JWT-10.
- **5.** Service tự kiểm access token gốc gateway chuyển tiếp trong `authorization: Bearer` [N1], [N2]: không khoá, secret hay thành phần mới,
  mọi môi trường như nhau; token tới thêm process, không xác thực service gọi, CPU ~42 µs mỗi RPC có người gọi.

## Kết quả quyết định

Chọn **5** cho lớp ứng dụng ở mọi môi trường; **1a** (Istio ambient) cho lớp kênh, chưa dựng; NetworkPolicy hiện có giữ làm lớp mạng.

1. **Lớp ứng dụng.** Gateway, sau khi `RequireAuth` kiểm token, dựng metadata gRPC từ đầu chỉ với `authorization: Bearer <chính token đó>`
   (IN-1 giữ: không chép header nào của client); route không xác thực không gửi `authorization`. Mỗi service gRPC kiểm bằng `authtoken.Verifier`
   như gateway (chữ ký EdDSA, `iss`, `aud`, hạn, cùng `Leeway`) với `JWT_VERIFY_KEYS`, lấy `sub` làm người gọi. `x-user-id` bỏ hẳn: không đọc,
   không dự phòng. Mọi kiểu sai (thiếu, sai chữ ký, hết hạn, kid lạ) cùng `UNAUTHENTICATED`, cùng reason `UNAUTHENTICATED_CALLER`, cùng message;
   chi tiết chỉ vào log. `aud` vẫn là `svp-api`: bốn service hiện thực chính API đó, không nới audience để chuyển tiếp được ([N1]).
   **Lý do chính:** giả danh tính giờ cần khoá ký của user-service, thứ không pod nào khác giữ; không khoá mới, không secret mới (khoá công
   khai, nguồn có sẵn), JWT-10 giữ; compose được che như cluster.
2. **Điều OWASP nói.** Bản hiện hành ([N1], 2026-10-03) coi phương án 5 ("External Identity Propagation") là hợp lý khi các service cùng hồ sơ
   kiểm và token dành cho chúng, và ưu tiên assertion nội bộ do issuer được chỉ định khi ngữ cảnh đi qua nhiều ranh giới service hay nhiều
   cơ chế xác thực ngoài; bản trước ([N2], commit `4908e7b`) gọi việc dùng lại access token ngoài là "highly insecure". Ở đây chọn 5 vì: một
   cơ chế xác thực ngoài, một chặng, mọi service cùng hồ sơ kiểm; issuer nội bộ hoặc là gateway (phương án 4: trái JWT-10, đúng điều OWASP
   bảo tránh), hoặc là thành phần mới (token exchange với user-service làm STS); token lộ ở service dùng được đúng như lộ ở gateway (cùng
   `aud`, hạn 1 giờ). Cả hai bản đều đòi xác thực **service gọi** riêng: mục 4. Trích dẫn đầy đủ: phụ lục.
3. **Ngữ nghĩa `callerid.Methods` giữ nguyên.** RPC public bỏ qua `authorization`. RPC có người gọi tuỳ chọn: không có `authorization` thì
   không có người gọi; có mà sai thì `UNAUTHENTICATED`, không bao giờ phục vụ như gọi ẩn danh.
4. **Lớp kênh: Istio ambient, chưa dựng.** k3d không dựng: cluster đã vượt ngân sách RAM, request mặc định của Istio thêm ~3,2 GiB. Dựng ở buổi
   EKS có lớp nền tảng của `svp-gitops`: istiod, ztunnel, istio-cni, namespace `svp` vào ambient, AuthorizationPolicy chỉ cho ServiceAccount
   của gateway vào cổng gRPC (đóng IN-3, xác thực service gọi), đo RAM thật trên node. compose không có lớp kênh (Istio cần Kubernetes), chấp
   nhận vì lớp ứng dụng đã che compose. NetworkPolicy giữ nguyên làm lớp mạng.
5. **Chuyển một bước, không bản tương thích.** Gateway mới chỉ gửi `authorization`, service mới chỉ đọc nó. Đổi `internal/callerid` thì
   `changed-services.sh` build cả sáu image (`internal/` là đường image của mọi service), nên mọi image ra cùng một lần promote; rollback cũng
   mọi image một lần. **Cửa sổ lỗi:** bản promote tới một môi trường đang chạy thì lúc pod cũ và mới lẫn nhau (gateway mới gọi service cũ hay
   ngược lại) mọi RPC có người gọi trả `UNAUTHENTICATED`, ra client là 401; web BFF xoá phiên khi gặp 401 nên người dùng web bị đăng xuất; 401
   không vào phân tích 5xx của canary gateway nên canary không tự huỷ. Cửa sổ kéo tới khi Argo CD sync xong mọi Deployment và canary gateway.
   Chấp nhận vì stg, prd dựng rồi xoá trong buổi (lần dựng mới chỉ có pod mới), compose `make up` tạo lại mọi container, còn một bản tương thích
   sẽ giữ lỗ hổng mở thêm một bản phát hành và thêm một nhánh `if` ([0037](0037-mainpath-standard-tools.md)).

### Hệ quả

- Tốt: pod bị chiếm trong mạng, kể cả ở compose, không giả được người dùng khác nếu không có token của họ; không secret, không khoá mới;
  không thành phần thường trực mới; một đường cho mọi môi trường.
- Xấu:
  - Token bearer tới thêm bốn process, thêm chỗ lộ ([N1]): token không bao giờ vào log, span, message lỗi; test khẳng định điều này.
  - Kênh vẫn plaintext tới khi có Istio: ai nghe lén được mạng nội bộ đọc được token (hạn 1 giờ cộng leeway) của người đang gọi. Token vốn đã đi
    plaintext từ Envoy tới gateway trong cluster (không có `BackendTLSPolicy`); trước đây không cần nghe lén cũng giả được mọi người.
  - Không xác thực service gọi: một pod có token hợp lệ (của tài khoản kẻ tấn công tự đăng ký) gọi thẳng service bằng chính danh tính đó, bỏ
    qua rate limit và kiểm đầu vào của gateway. k3d, EKS: NetworkPolicy chặn; compose: không, chấp nhận tới khi có lớp kênh.
  - CPU: ~42 µs mỗi RPC có người gọi; ở 1 000 req/s, mỗi RPC kiểm token tốn ~4 % một core.
  - Xoay khoá: khoá công khai mới phải tới gateway **và** bốn service (cùng nguồn `jwt-verify`, mỗi pod nạp lại biến) trước khi user-service ký
    bằng kid mới; service nào chưa có kid mới trả 401 và web đăng xuất người dùng ([runbook](../runbooks/jwt-key-rotation.md)).
  - Token sát hạn qua được gateway có thể hết hạn ở service vài mili giây sau: client nhận 401 như token hết hạn.
- Xem lại khi: buổi EKS dựng lớp nền tảng (dựng Istio ambient theo mục 4, số RAM ghi ở ADR của buổi đó); một service gọi service khác (token
  người dùng không còn đủ: token exchange RFC 8693 hay Transaction Tokens [N8]); có cơ chế xác thực ngoài thứ hai (assertion nội bộ); hệ thống
  cấp loại JWT thứ hai bằng cùng khoá (kiểm thêm `typ`, RFC 8725 §3.11 [N9]); có môi trường chạy lâu dài với người dùng thật (thay đổi kiểu này
  cần bản tương thích).

## Xác nhận

- Chi phí kiểm (Apple M2, Go 1.27.3): ed25519 38,3 µs/op; parse và kiểm JWT với tuỳ chọn parser của `authtoken.NewVerifier` 42,2–42,8 µs/op,
  40 alloc (lệnh benchmark: phụ lục).
- Test `internal/callerid`: token hợp lệ đặt `sub`; `x-user-id` giả không token, sai chữ ký, hết hạn, kid lạ, sai `iss` hay `aud`, hai giá trị
  `authorization` cùng ra `UNAUTHENTICATED`; RPC public bỏ qua; người gọi tuỳ chọn thiếu thì ẩn danh, sai thì `UNAUTHENTICATED`; log không chứa
  token. Test gateway: metadata chỉ có `authorization` của token đã kiểm, `x-user-id` của client không đi tiếp.
- `make check`; `make smoke` trên compose; render `svp-cluster` với External Secrets bật có `JWT_VERIFY_KEYS` ở năm Secret.
- Chưa kiểm: k3d và EKS với khoá từ External Secrets, xoay khoá theo runbook, chi phí trên Graviton, cửa sổ lỗi lúc rollout.

## Hiện thực ở

- `internal/callerid/callerid.go`: interceptor kiểm token trong `authorization`, `Methods` (mục 1, 3); `callerid_test.go`;
  `internal/callerid/calleridtest/`: token ký bằng khoá thử cho test của các service.
- `services/gateway/internal/httpx/`: `middleware.go` (`RequireAuth` giữ token đã kiểm), `httpx.go` (`OutgoingContext` dựng metadata
  chỉ với `authorization`) (mục 1).
- `services/{video,engagement,feed}-service/internal/server/server.go` (`CallerInterceptor` nhận verifier),
  `services/{user,video,engagement,feed}-service/cmd/<service>/main.go` (nạp `JWT_VERIFY_KEYS`, gắn interceptor) (mục 1).
- `proto/svp/{user,video,engagement,feed}/v1/*_service.proto`: comment danh tính người gọi.
- `deploy/compose/compose.yaml`, `deploy/k8s/secrets.sh`, `deploy/helm/svp-cluster/files/external-secrets.yaml`: `JWT_VERIFY_KEYS` cho bốn service.
- `docs/runbooks/jwt-key-rotation.md`: khoá công khai mới tới gateway và bốn service (Hệ quả).
- `deploy/helm/svp-service/templates/networkpolicy.yaml`: lớp mạng giữ nguyên (mục 4).

## Nguồn

Đọc ngày 2026-11-02.

- [N1] OWASP, "Identity Propagation Patterns Cheat Sheet" (commit `e7d1b47`, 2026-10-03):
  <https://cheatsheetseries.owasp.org/cheatsheets/Identity_Propagation_Patterns_Cheat_Sheet.html>
- [N2] OWASP, "Microservices Security Cheat Sheet", bản hiện hành: <https://cheatsheetseries.owasp.org/cheatsheets/Microservices_Security_Cheat_Sheet.html>;
  bản trước 2026-10-03 (commit `4908e7b`, 2025-07-25, mục "Identity propagation"):
  <https://github.com/OWASP/CheatSheetSeries/blob/4908e7b2281ac9560388df1e16a7f752b9aef6e0/cheatsheets/Microservices_Security_Cheat_Sheet.md>
- [N3] Istio, "Fast, Secure, and Simple: Istio's Ambient Mode Reaches General Availability in v1.24" (2024-11-07):
  <https://istio.io/latest/blog/2024/ambient-reaches-ga/>; bản phát hành: <https://github.com/istio/istio/releases>
- [N4] Istio, "Performance and Scalability": <https://istio.io/latest/docs/ops/deployment/performance-and-scalability/>; request mặc định ở tag
  1.31.3: chart istiod, ztunnel, istio-cni (link: phụ lục)
- [N5] Linkerd, "Releases and Versions": <https://linkerd.io/releases/>; bản edge: <https://github.com/linkerd/linkerd2/releases>
- [N6] CNCF, SPIRE: <https://www.cncf.io/projects/spire/>; bản phát hành và attestor `docker`: phụ lục
- [N7] CNCF, cert-manager: <https://www.cncf.io/projects/cert-manager/>; csi-driver-spiffe: <https://cert-manager.io/docs/usage/csi-driver-spiffe/>
- [N8] IETF, draft-ietf-oauth-transaction-tokens-11: <https://datatracker.ietf.org/doc/html/draft-ietf-oauth-transaction-tokens-11>
- [N9] RFC 8725, JSON Web Token Best Current Practices, §3.11: <https://www.rfc-editor.org/rfc/rfc8725#section-3.11>
- [N10] AWS, Amazon EC2 M7g: <https://aws.amazon.com/ec2/instance-types/m7g/>

## Thông tin thêm

Phụ lục: [`appendix/0042-caller-identity-grpc.md`](appendix/0042-caller-identity-grpc.md) (dòng trạng thái lúc chốt, hai bảng phương án với
trạng thái ngành và RAM, trích dẫn OWASP đầy đủ, ưu nhược từng phương án, lệnh benchmark, nguồn đầy đủ).
