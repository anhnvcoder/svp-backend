# Đổi khoá ký JWT theo `kid`

- Quy trình theo lệnh `make jwt-rotate`, không có cảnh báo. Làm định kỳ, hay **ngay** khi nghi khoá ký bị lộ (SEC-4, JWT-10 của
  [threat model](../threat-model.md)).
- Trạng thái: viết theo mã, chưa chạy thử; diễn tập đổi khoá khi có Secrets Manager
  ([ADR-0020](../adr/0020-reliability-stage6.md) §12). Bước 1 trên k3d (thêm một khoá verify, token của khoá đang ký vẫn hợp lệ) là
  một phần của `make drill-k8s-reloader` ([`k8s.md`](../reference/k8s.md)).

## Ý nghĩa và tác động tới người dùng

Access token là JWT Ed25519, hạn **15 phút** (`TTL` của `internal/authtoken`), header mang `kid`. user-service ký bằng
`JWT_SIGNING_KID` + `JWT_SIGNING_KEY`; gateway và bốn service gRPC (user, video, engagement, feed) kiểm bằng `JWT_VERIFY_KEYS`,
danh sách `kid:<public key base64>` cách nhau dấu phẩy, nên cả năm nhận được nhiều khoá cùng lúc. Gateway kiểm token của client,
mỗi service kiểm lại token gateway chuyển tiếp ([ADR-0042](../adr/0042-caller-identity-grpc.md)): khoá công khai mới phải tới
**cả năm** process trước khi user-service ký bằng `kid` mới. Service nào chưa có `kid` mới trả `UNAUTHENTICATED` cho mọi RPC có
người gọi, client nhận 401 và web đăng xuất người dùng. Refresh token là chuỗi ngẫu nhiên lưu ở user-service, không phải JWT: đổi khoá
đúng trình tự không làm mất phiên đăng nhập.

Đổi khoá đúng trình tự thì người dùng không thấy gì. Bỏ khoá cũ quá sớm (khi access token ký bằng nó chưa hết hạn, như nhánh
"Khi nghi lộ khoá" bên dưới) thì access token cũ bị 401 và người dùng web **phải đăng nhập lại**: web BFF không refresh sau 401
mà xoá phiên và thu hồi cả họ refresh token. Chỉ client gọi API thẳng, tự giữ refresh token, mới lấy được token mới bằng
`POST /auth/refresh` mà không đăng nhập lại.

Khoá nằm ở `.env` (compose đọc thẳng; k3d chép qua `make k8s-secrets` vào Secret `svp/user-service-env` cho khoá ký, khoá công
khai vào `svp/gateway-env` và `svp/<service>-env` của bốn service gRPC; cluster k3d có External Secrets nhận nguồn
`svp-secrets/jwt-signing`, `svp-secrets/jwt-verify`, cluster EKS nhận entry `svp/<env>/jwt-signing`, `svp/<env>/jwt-verify` của AWS
Secrets Manager, rồi ExternalSecret dựng các Secret đó). Không in `.env`, không in khoá.

## Kiểm tra nhanh (5 phút)

Trước khi đổi, xác nhận trạng thái hiện tại mà không in giá trị:

```sh
# số khoá gateway đang nhận và các kid (kid không bí mật; phần sau dấu ':' không in)
grep '^JWT_VERIFY_KEYS=' .env | cut -d= -f2- | tr ',' '\n' | cut -d: -f1
grep '^JWT_SIGNING_KID=' .env
# gateway và bốn service gRPC đang chạy
make ps                                                     # compose
kubectl --context k3d-svp -n svp get pods \
  -l 'app.kubernetes.io/name in (gateway,user-service,video-service,engagement-service,feed-service)'   # k3d
```

`kid` có dạng `<ngày UTC>-<8 hex>` (`tools/jwtkey`), nên cho biết khoá đã dùng bao lâu.

## Nguyên nhân thường gặp

Lý do đổi khoá:

1. **Định kỳ**: khoá dùng mãi thì lộ lúc nào không biết (SEC-4).
2. **Nghi lộ khoá ký**: `.env` hay Secret bị đọc, khoá lọt vào log, image hay commit (gitleaks, trivy chặn ở CI nhưng không chặn
   được mọi đường).

## Giảm thiểu

Đổi định kỳ, ba bước. Mỗi bước là một lệnh `make jwt-rotate STEP=<add|sign|drop>` sửa `.env` (`tools/jwtkey rotate`), rồi lệnh áp
dụng, rồi một lần chờ:

- Lệnh chỉ thay dòng của ba biến JWT, mọi dòng khác của `.env` giữ nguyên; ghi qua file tạm cùng thư mục rồi đổi tên, mode 600.
- Lệnh in `kid` liên quan và lệnh áp dụng tiếp theo, không in khoá, kể cả trong thông báo lỗi.
- **Khoá chờ** là file `.env.jwt-next` ở gốc repo (mode 600, git bỏ qua theo dòng `.env.*` của `.gitignore`): ba dòng của
  `tools/jwtkey` cho cặp khoá mới, giữ từ bước 1 tới bước 3.
- Phần chờ (pod Ready, rollout xong, 15 phút 30 giây) giữ tay: cần người đọc trạng thái pod và đồng hồ của token, lệnh không biết
  pod nào còn phục vụ hay token cuối cùng ký lúc nào.

**Bước 1. Gateway và bốn service gRPC nhận cả hai khoá.** Sinh cặp khoá mới vào khoá chờ, nối khoá công khai của nó vào sau
`JWT_VERIFY_KEYS`:

```sh
make jwt-rotate STEP=add
```

Output mong đợi: `add: JWT_VERIFY_KEYS of .env now also has kid <kid mới> (kids before: <kid cũ>); its signing key waits in
.env.jwt-next`, rồi lệnh áp dụng. Áp dụng trên compose (chỉ container có biến đổi, gateway và bốn service gRPC, được tạo lại):

```sh
make up OBS=lgtm
```

k3d (đường dev hay cluster GitOps) và EKS: một lệnh ghi Secret theo thứ tự xoay credential, rồi Reloader restart gateway (qua
`spec.restartAt`, từng pod, không revision mới nên không canary) và bốn service gRPC (rolling update của Deployment) vì Secret
`<service>-env` của chúng đổi ([ADR-0050](../adr/0050-bash-to-standard-tools.md) mục 5):

```sh
make k8s-secrets                                                 # k3d, cả cluster GitOps
AWS_PROFILE=anhnv-<env> make eks-secrets CONTEXT=svp-<env>       # EKS (prd: tunnel tới API mở; eks.md, "Đổi secret của env đang chạy")
```

Process chỉ đọc biến môi trường lúc khởi động, nên tới khi mọi pod của năm workload là pod mới và Ready, pod cũ (chỉ có khoá cũ) có
thể vẫn còn phục vụ. Lệnh không chờ restart; EKS dùng `--context svp-<env>` thay `--context k3d-svp` ở các lệnh kiểm dưới đây.

Gateway và service không khởi động khi `JWT_VERIFY_KEYS` sai dạng hay trùng `kid`. Trước khi sang bước 2, kiểm mọi pod của năm
workload đã Ready và khởi động sau lúc áp dụng (cột `START` muộn hơn lúc chạy lệnh trên; compose: `make ps`, cột thời gian tạo):

```sh
kubectl --context k3d-svp -n svp get pods \
  -l 'app.kubernetes.io/name in (gateway,user-service,video-service,engagement-service,feed-service)' \
  -o custom-columns='NAME:.metadata.name,START:.status.startTime,READY:.status.containerStatuses[*].ready'
```

**Bước 2. user-service ký bằng khoá mới.** Thay `JWT_SIGNING_KID`, `JWT_SIGNING_KEY` bằng hai dòng của khoá chờ:

```sh
make jwt-rotate STEP=sign
```

Output mong đợi: `sign: user-service of .env now signs with kid <kid mới> instead of <kid cũ>`. Áp dụng như bước 1 (compose tạo lại
user-service; k3d và EKS: Reloader restart user-service vì Secret `user-service-env` đổi), rồi chờ rollout của nó xong:

```sh
kubectl --context k3d-svp -n svp rollout status deployment/user-service --timeout=300s
```

Token mới mang `kid` mới, gateway và bốn service đã nhận nó từ bước 1; token cũ còn hợp lệ tới khi hết hạn.

**Bước 3. Bỏ khoá cũ**, sau khi user-service cuối cùng còn khoá cũ đã dừng ít nhất **15 phút 30 giây** (`TTL` cộng
`Leeway` của `internal/authtoken`: token còn được nhận tới lúc đó) cộng vài phút dư cho lệch đồng hồ. Lệnh bỏ mọi mục của
`JWT_VERIFY_KEYS` khác `kid` đang ký, rồi xoá khoá chờ:

```sh
make jwt-rotate STEP=drop
```

Output mong đợi: `drop: JWT_VERIFY_KEYS of .env keeps only kid <kid mới> (dropped: <kid cũ>); removed .env.jwt-next`. Áp dụng như
bước 1, rồi xác nhận theo mục dưới.

**Khi nghi lộ khoá:** chạy `STEP=add`, áp dụng, `STEP=sign`, áp dụng, rồi `STEP=drop` và áp dụng **ngay**, không chờ: mọi access token
ký bằng khoá cũ (kể cả token giả mạo) bị 401 từ lúc đó. Cái giá là người dùng web **phải đăng nhập lại**: BFF chỉ refresh khi access
token còn dưới 30 s (`server/session-access.ts` của repo `svp-frontend`), nên phiên có token cũ còn hạn lâu hơn gửi nó đi, gateway trả
401, và web coi phiên là hỏng (`server/feed.ts`, `server/api-proxy.ts` của `svp-frontend`: `SessionAccess.end`): xoá phiên và thu hồi cả
họ refresh token; trang feed chuyển về đăng nhập. Client gọi API thẳng và tự giữ refresh token thì gọi `POST /auth/refresh` sau 401 là
được token mới. Ghi lại thời điểm để đối chiếu log.

### Khi lệnh từ chối

Lệnh in `jwtkey: <lý do>`, exit khác 0 và không ghi file nào. Lý do nêu file, biến, số dòng hay thứ tự mục, không giá trị:

| Lý do bắt đầu bằng | Nghĩa | Làm gì |
| --- | --- | --- |
| `.env.jwt-next exists: a rotation is under way` | `add` khi khoá chờ đã có | Xoay dở: chạy tiếp `STEP=sign`, `STEP=drop` |
| `.env.jwt-next does not exist: no rotation under way` | `sign` hay `drop` khi chưa `add` | Bắt đầu bằng `STEP=add` |
| `JWT_SIGNING_KID of .env is already <kid>` | `sign` lần hai | Sang bước 3 |
| `JWT_VERIFY_KEYS of .env lacks the verify key of pending kid` | `.env` bị sửa tay sau `add` | Xoá `.env.jwt-next`, chạy lại `STEP=add` |
| `JWT_SIGNING_KID of .env is <kid cũ>, not pending kid` | `drop` khi chưa `sign` | Làm bước 2 trước |
| `.env lacks <biến> or has it empty`, `entry <n> of JWT_VERIFY_KEYS`, `set again`, `twice` | `.env` thiếu biến hay sai dạng | Sửa dòng được nêu rồi chạy lại bước |

## Khôi phục và xác nhận

```sh
grep '^JWT_VERIFY_KEYS=' .env | cut -d= -f2- | tr ',' '\n' | cut -d: -f1     # sau bước 3: chỉ còn kid mới
make smoke         # compose: đăng ký, đăng nhập (token kid mới), refresh, feed, RPC có người gọi ở cả bốn service (LOCAL LAB ONLY)
make k8s-smoke     # k3d
```

Trong log gateway và bốn service không có lỗi kiểm token tăng bất thường sau bước 2 và bước 3 (ngoài token cũ của client chưa
refresh); ở service đó là dòng INFO `caller token rejected`.

## Leo thang

- Gateway hay một service gRPC không khởi động sau bước 1: bỏ mục `<kid mới>:…` khỏi `JWT_VERIFY_KEYS` bằng trình soạn thảo (lệnh
  không có bước lùi), xoá `.env.jwt-next`, áp dụng lại; đọc log của process về lỗi đọc khoá.
- Người dùng bị 401 hàng loạt sau bước 2: gateway hay một trong bốn service chưa có khoá mới (bước 1 chưa áp dụng ở đó, hay pod
  cũ còn phục vụ; service có dòng `caller token rejected`); đưa khoá mới tới workload đó trước, không quay lại khoá ký cũ khi
  đang nghi lộ.
- Khoá bị lộ thật: mở postmortem; xét thêm thu hồi refresh token (đăng xuất mọi phiên) nếu kẻ lộ khoá có thể đã dùng nó.

## Liên kết

- [Threat model](../threat-model.md) SEC-4, JWT-10; [ADR-0020](../adr/0020-reliability-stage6.md) §12;
  [ADR-0016](../adr/0016-web-client.md) §2 (refresh token).
- [ADR-0042](../adr/0042-caller-identity-grpc.md) (service kiểm lại token gateway chuyển tiếp).
- Mã: `tools/jwtkey`, `internal/authtoken` (`TTL`, `ParseVerifyKeys`), `internal/callerid`, `deploy/k8s/secrets.sh`,
  `deploy/helm/svp-cluster/files/external-secrets.yaml`.
- Diễn tập: chưa có; diễn tập đổi khoá khi có Secrets Manager.
