# 0007. Một Go module cho cả monorepo, công cụ ghim ở Makefile, cấu hình bằng biến môi trường, phạm vi đầu tiên thu về luồng đồng bộ

- Trạng thái: Chấp nhận
- Ngày: 2026-10-11

## Bối cảnh và vấn đề

- Bước viết Go đầu tiên làm `gateway`, `user-service`, `video-service` chạy local, mỗi service một database có migration, có unit test và integration test, lint, Docker multi-stage và compose. Module, cách sinh code, dependency, tên biến môi trường, cổng, cách nối database và image là nền của mọi service: đổi về sau là sửa tất cả cùng lúc. Code của bước này lấy tên biến, cổng, đường dẫn và version từ ADR này.
- Các quyết định trước để lại: cách đặt `go_package` ([ADR-0006](0006-contract-ids-and-event-envelope.md) mục 1), thư viện sinh UUIDv7 (ADR-0006 mục 2), OpenAPI viết tay hay sinh từ code ([ADR-0002](0002-sync-rest-edge-grpc-internal.md)).
- Ràng buộc: Go 1.27.2 (Homebrew), `buf` 1.73.0; Postgres 15 native ở `127.0.0.1:5432`, Redis native ở `6379`; máy 16 GB, compose chạy theo profile; các biện pháp của [threat model §5](../appendix/threat-model.md#tổng-hợp-theo-giai-đoạn-mục-5-cũ) cho bước này (JWT-1 tới JWT-3, JWT-5, JWT-7 tới JWT-10, UP-3, UP-8, RL-4, RL-5, IN-1, IN-2, IN-6, IN-8, SEC-1, SEC-2, OPS-1, OPS-3). Phạm vi lệch danh sách "Làm" của plan ở ba chỗ (Redis, outbox, presigned upload); §8 ghi lý do.

## Yếu tố quyết định

Clone xong build và test được chỉ với Go; một version dependency cho cả repo; ít dependency; `buf` chạy offline; ranh giới service do compiler và Postgres ép; bí mật không nằm trong repo hay image.

## Phương án đã cân nhắc

- §1 **A một `go.mod` ở gốc repo**: một `go.sum`, mọi service cùng version dependency; không nâng dependency cho riêng một service được.
- §1 B `go.work` + mỗi service một module: version độc lập theo service; phải tách module cho code sinh và code dùng chung, version lệch giữa service: loại.
- §2 A ghi tay `option go_package` trong từng file `.proto`: `protoc` thuần sinh đúng; contract gắn với module path của Go: loại.
- §2 **B managed mode trong `buf.gen.yaml`**: không sửa `proto/`, module path ở một chỗ; chỉ `buf generate` sinh đúng.
- §2 C remote plugin trên BSR: không phải cài plugin; sinh code phụ thuộc mạng và dịch vụ ngoài: loại.
- §2 **D plugin local, `go install` với version ghim**: chạy offline; máy dev và CI chạy `make tools` trước.
- §2 E không commit code sinh, sinh lúc build: repo gọn; clone xong không build được nếu chưa cài `buf` và plugin: loại.
- §2 **F commit code sinh**: clone xong là `go build`, `go test`; diff to hơn, quên sinh lại thì lệch contract.
- §3 A directive `tool` trong `go.mod`: không cần bước cài; `sqlc`, `golangci-lint` kéo hàng trăm module vào đồ thị của ứng dụng: loại.
- §3 **B ghim version trong `Makefile`, cài bằng `make tools`**: `go.mod` chỉ có dependency của ứng dụng; phải tự cập nhật version.
- §4 **A chỉ biến môi trường**: cùng một image chạy ở compose, k8s, cloud; không có cấu hình lồng nhau.
- §4 B file YAML + viper, koanf: cấu hình có cấu trúc; thêm dependency, bí mật vẫn đi đường riêng: loại.
- §5 A cổng `50051` cho mọi service: chạy native nhiều service thì đụng nhau: loại.
- §5 **B mỗi service một cổng cố định**: native và compose cùng số, nhìn cổng biết service.
- §6 A Postgres chạy trong compose: thêm container ăn RAM, dữ liệu local tách hai nơi: loại.
- §6 **B container nối ra Postgres native**: đúng ràng buộc máy; phụ thuộc cách Docker trỏ về máy host.
- §6 C một role mỗi service cho cả migration và chạy: service đang chạy có quyền `CREATE`, `DROP` bảng: loại.
- §6 **D hai role mỗi service, migrator và app**: service đang chạy không đổi được schema (IN-6); thêm một DSN phải quản lý.
- §7 A image có hệ điều hành (`alpine`, `debian-slim`): có shell để debug; thêm package phải vá, kẻ chiếm process có sẵn công cụ: loại.
- §7 B `scratch`: nhỏ nhất; thiếu chứng chỉ CA, `tzdata`, user không phải root: loại.
- §7 **C distroless `static`, bản `nonroot`**: có CA, `tzdata`, uid 65532, không shell; healthcheck phải do chính binary làm.
- §8 A làm đủ danh sách của plan, kể cả Redis: chưa có chỗ nào dùng Redis: loại.
- §8 **B làm luồng đồng bộ đầy đủ**: mọi thứ làm ra có test thật; `make up` ở bước đầu chưa upload được file.

## Kết quả quyết định

Chọn một `go.mod` ở gốc (§1 A), managed mode với plugin local và commit code sinh (§2 B + D + F), công cụ ghim ở `Makefile` (§3 B), biến môi trường (§4 A), mỗi service một cổng cố định (§5 B), Postgres native với hai role (§6 B + D), distroless `static` bản `nonroot` (§7 C) và phạm vi đầu tiên là luồng đồng bộ (§8 B), vì clone xong build và test được chỉ với Go, ít dependency, `buf` chạy offline, ranh giới service do compiler và Postgres ép, bí mật không nằm trong repo hay image; từng phần ở §1–§8.

### 1. Go module và bố cục thư mục

Chọn **A**: `go.mod` ở gốc, module `github.com/anhnvcoder/short-video-platform`, directive `go 1.27` (gói chuẩn `uuid` mới có từ Go 1.27, mục 3).
Bố cục (cây đầy đủ ở phụ lục): `proto/svp/<domain>/v1/` (ADR-0006), `gen/go/svp/<domain>/v1/` (code sinh, có commit), `internal/`,
`services/<svc>/cmd/<svc>/` (`main.go`), `services/<svc>/internal/`, `services/<svc>/sqlc.yaml`, `tools/<tên>/`, `deploy/docker/`,
`deploy/compose/`, `deploy/postgres/`, `docs/`.

Ngoài các thư mục `CLAUDE.md` đã liệt kê (`services/`, `proto/`, `deploy/`, `docs/`), thêm `gen/` (code sinh, không ai sửa tay), `internal/` ở gốc (code mà ít nhất hai service
cần; Go chỉ cho package nằm trong cây chứa thư mục `internal/` import nó; code chỉ một service dùng không đưa lên đây) và `tools/` (chương trình phụ trợ cho dev, không đóng vào image;
ví dụ `tools/jwtkey` sinh cặp khoá Ed25519 cho `make env`). Giải thích từng thư mục ở phụ lục.

Code riêng của một service nằm ở `services/<svc>/internal/`: Go cấm mọi package ngoài `services/<svc>/` import nó, nên gateway không import được
repository của user-service. Ranh giới của [ADR-0001](0001-service-boundaries-and-data-ownership.md) được compiler ép ở mức code; ở mức database thì ép bằng role (mục 6).

### 2. Sinh code từ proto

Chọn **B + D + F**.

- `buf.gen.yaml` v2 ở gốc repo, chạy bằng `buf generate` từ gốc: managed mode với `go_package_prefix` là `github.com/anhnvcoder/short-video-platform/gen/go`, hai plugin local `protoc-gen-go`, `protoc-gen-go-grpc` với `paths=source_relative`, ra `gen/go` (nội dung file ở phụ lục).
- Code ra ở `gen/go/svp/<domain>/v1/`, package `userv1`, `videov1`, `eventv1`... Không sửa `proto/`.
- Commit cả code sinh từ proto lẫn code `sqlc` sinh ra. `make generate` chạy `buf generate` rồi `sqlc generate`; CI chạy `make generate` rồi `git diff --exit-code` để bắt code lệch contract.

### 3. Dependency và công cụ

Version là bản ổn định mới nhất trên Go module proxy ngày 2026-10-11 (`go list -m -json <module>@latest`), mọi module khai báo `go` không cao hơn 1.27.2.
Bảng version, lý do và phương án đã loại ở phụ lục; version hiện hành ở `go.mod`.

- **Runtime:** `google.golang.org/grpc` (gồm `health`, `test/bufconn`), `google.golang.org/protobuf`, `google.golang.org/genproto/googleapis/rpc` (gói `errdetails`), `github.com/jackc/pgx/v5`, `github.com/pressly/goose/v3` (migration SQL dùng như thư viện, `embed` vào binary, lệnh con `<svc> migrate`), `github.com/golang-jwt/jwt/v5` (JWT-1, JWT-2), `golang.org/x/crypto` (`argon2`: JWT-7).
- **Thư viện chuẩn, không thêm dependency:** UUIDv7 bằng gói `uuid` của Go 1.27 (kiểm ở biên bằng `uuid.Parse` rồi bắt buộc `u.String() == s`, vì contract chỉ nhận dạng chuẩn 36 ký tự chữ thường); router `net/http.ServeMux` tự tạo bằng `http.NewServeMux`, không dùng `http.DefaultServeMux` (OPS-1); `log/slog` với `JSONHandler`; cấu hình bằng `os.Getenv` và một helper nhỏ trong `internal/`; test chỉ gói `testing`; `crypto/ed25519`, `embed`.
- **Redis driver: không thêm ở bước này** (mục 8); thêm `github.com/redis/go-redis/v9` khi có chỗ dùng.
- **Công cụ:** chọn **B**. `make tools` chạy `go install <module>@<version>` cho `protoc-gen-go` (cùng version với runtime `google.golang.org/protobuf`), `protoc-gen-go-grpc`, `sqlc` (build cần cgo và trình biên dịch C, vì parser Postgres là thư viện C `pg_query_go`), `golangci-lint` (cài bằng `go install` để build bằng chính Go 1.27.2, vì nó chỉ phân tích được module có `go` không mới hơn bản Go đã build nó), `gitleaks` (SEC-1). `buf` 1.73.0 cài qua Homebrew, không nằm trong `make tools`.

### 4. Cấu hình

Chọn **A**. Mỗi service chỉ đọc biến của mình, không có file cấu hình. Thiếu biến bắt buộc hoặc giá trị sai định dạng thì service thoát ngay lúc khởi động với lỗi nêu
tên biến (không in giá trị). Bảng biến, mặc định và ý nghĩa lúc quyết ở phụ lục; hiện hành ở [`reference/environment.md`](../reference/environment.md).

- **Lệnh `migrate`** của user-service và video-service cũng đọc `DATABASE_URL`: compose đưa URL của role migrator cho container migrate, URL của role app cho container chạy service (mục 6).
- **Bind mặc định `127.0.0.1`:** chạy native thì cổng gRPC không lộ ra mạng (IN-2). Trong container đặt `LISTEN_ADDR=:<cổng>` để nhận kết nối từ mạng của compose; compose chỉ publish gateway (mục 5).
- **Bí mật chỉ đưa vào lúc chạy** (SEC-2). Local dùng `.env` ở gốc repo (đã gitignore), do `make env` sinh: mật khẩu database ngẫu nhiên và một khoá Ed25519 mới (`tools/jwtkey`). `make env` không ghi đè `.env` đã có. `.env.example` chỉ có tên biến, không có giá trị (SEC-1). Chỉ user-service nhận khoá ký (JWT-10).
- **Test:** integration test đọc `SVP_TEST_POSTGRES_URL` (DSN superuser tới Postgres local ở `127.0.0.1:5432`) để tự tạo database riêng cho test. `make test` đặt giá trị local mặc định; chạy `go test` mà không đặt biến này thì integration test gọi `t.Skip`, unit test vẫn chạy.

### 5. Cổng

Chọn **B**: `gateway` HTTP 8080, `user-service` gRPC 9101, `video-service` gRPC 9102; service sau lấy số tiếp theo trong dải `91xx` (engagement-service, feed-service). Compose chỉ publish gateway,
và chỉ ở `127.0.0.1:8080` (IN-2), cổng gRPC không publish ra máy. Cổng quản trị (pprof, `/metrics`) để sau; bước này giữ OPS-1 bằng cách không dùng `http.DefaultServeMux`.

### 6. Compose nối Postgres native và role database

Chọn **B + D**.

- Container nối tới `host.docker.internal:5432` (Docker Desktop có sẵn tên này). Compose thêm `extra_hosts: ["host.docker.internal:host-gateway"]` để chạy được trên Linux.
- Mỗi service có database (`svp_user`, `svp_video`) như bảng trong `CLAUDE.md`, và hai role, đều `LOGIN`, không `SUPERUSER`, `CREATEDB`, `CREATEROLE`:
  - `svp_<svc>_migrator` sở hữu database `svp_<svc>` và chạy migration;
  - `svp_<svc>_app` chỉ có `CONNECT` trên database của mình và quyền DML (`SELECT`, `INSERT`, `UPDATE`, `DELETE`) trên bảng, cấp bằng `ALTER DEFAULT PRIVILEGES FOR ROLE svp_<svc>_migrator IN SCHEMA public`, nên bảng do migration tạo sau này tự có quyền; không tạo được bảng.
- Bảng version của goose nằm ở schema riêng `goose` (`goose.goose_db_version`), do role migrator tạo và sở hữu. Default privileges chỉ áp cho schema `public`, nên role app không đọc ghi được lịch sử migration: service bị chiếm cũng không làm lần `migrate` sau chạy lại hay bỏ qua migration. Nới default privileges ra ngoài `public` sẽ phá điều này.
- Thu quyền `CONNECT` của `PUBLIC` trên các database đó: role của service này không kết nối được database của service khác.
- Tạo idempotent (chạy lại không lỗi, không đổi gì) bằng `make db-bootstrap`, script ở `deploy/postgres/`, kết nối bằng superuser `postgres` local. Mật khẩu role lấy từ `.env`.

### 7. Docker và binary

Chọn **C**.

- Một Dockerfile multi-stage cho mọi service: `deploy/docker/service.Dockerfile`, chọn service bằng `ARG SERVICE`. Builder là `golang:1.27.x` ghim tag cụ thể (cùng bản Go của máy, hiện là 1.27.2); build `CGO_ENABLED=0`, `-trimpath`. Runtime là distroless `static` bản `nonroot` (uid 65532). Không có bí mật trong Dockerfile hay build arg (SEC-2).
- Mỗi service một binary ở `services/<svc>/cmd/<svc>/main.go`, lệnh con: `serve` (mặc định khi không có lệnh con); `migrate` (chạy migration goose rồi thoát, chỉ ở service có database); `healthcheck` (gọi health service gRPC, với gateway là endpoint HTTP, rồi thoát với mã 0 hoặc 1, vì distroless không có shell hay `curl`).
- Compose ở `deploy/compose/compose.yaml`, profile `core`; service migrate của mỗi service chạy một lần, service chính chờ nó xong. Target Docker nằm trong `deploy/compose/compose.mk`, được `Makefile` gốc `include`; mọi target gọi `env -u DOCKER_DEFAULT_PLATFORM docker ...` (`CLAUDE.md`).

### 8. Phạm vi giai đoạn 1

Chọn **B**: chỉ làm phần chạy được và test được mà không cần hạ tầng bất đồng bộ.

- **user-service:** `Register`, `Login`, `Follow`, `Unfollow` đầy đủ; **chưa phát event**.
- **video-service:** `InitUpload` tạo video `UPLOADING` và chỉ trả `video_id`; `upload_url`, `form_fields`, `expires_at` để trống vì chưa có object storage. Giới hạn "500 MB" của [ADR-0004](0004-direct-upload-and-hls.md) hiểu là 500 MiB, tức `500 << 20` = 524 288 000 byte. `CompleteUpload` trả `UNIMPLEMENTED` (cần `HEAD` lên storage và outbox). `GetVideo` đầy đủ, gồm luật hiển thị UP-3 (video chưa `READY` chỉ tác giả thấy, ADR-0006 mục 5). Presigned POST và `CompleteUpload` làm ở [ADR-0008](0008-async-upload-pipeline-stage2a.md).
- **gateway:** route REST, kiểm JWT (JWT-1, JWT-2), metadata gRPC dựng từ đầu (IN-1), đổi mã lỗi theo [bảng mã lỗi](../reference/contracts.md#mã-lỗi-grpc-sang-http-ở-gateway) (IN-8), timeout server và giới hạn kích thước thân request (RL-4). Chưa rate limit (RL-5, rủi ro đã chấp nhận).
- **Không dùng Redis ở bước này.** **Chưa tạo bảng outbox:** chưa có relay, chưa có event; ADR-0008 thêm migration goose cho bảng outbox cùng lúc với code ghi outbox trong cùng transaction.
- **OpenAPI viết tay** ở `services/gateway/openapi.yaml` (OpenAPI 3.1), trả lời câu hỏi để ngỏ của ADR-0002: gateway ghép dữ liệu nhiều service nên handler viết tay; sinh OpenAPI từ code cần thêm dependency (annotation hoặc framework). JSON ở biên dùng `snake_case`, khớp tên field trong proto.
- **`trace_id`:** gateway sinh `traceparent` W3C mới cho mỗi request (bỏ giá trị client gửi lên), truyền xuống qua metadata gRPC `traceparent`; service ghi `trace_id` vào log; thân lỗi trả `trace_id`. OpenTelemetry ([ADR-0011](0011-observability-stage3.md)) dùng đúng key này, nên chỉ thay chỗ sinh, không đổi đường truyền.

### Hệ quả

- Tốt: clone xong là build và test được chỉ với Go; Docker build không cần `buf`, plugin hay `sqlc`. Một version dependency cho cả repo; ranh giới giữa service được compiler ép (`internal/`) và Postgres ép (role). Lúc quyết định `go.mod` chỉ có 7 dependency trực tiếp, còn lại là thư viện chuẩn. Service đang chạy không đổi được schema, không kết nối được database của service khác; bí mật không nằm trong repo hay image. Mọi thứ làm ra đều có test thật, không có code chỉ để đánh dấu đã làm.
- Xấu: code sinh từ proto và `sqlc` nằm trong repo: diff to hơn, phải chạy `make generate` sau khi sửa proto hoặc SQL, CI kiểm lệch. Version công cụ ghim trong `Makefile` và dependency trong `go.mod` phải tự cập nhật tới khi có Renovate; build `sqlc` cần cgo. Redis lùi một bước; `make up` ở bước đầu chưa upload được file; `CompleteUpload` trả `UNIMPLEMENTED`. Các service tin `x-user-id` tới khi có mTLS (ADR-0006 mục 5); bước đầu chỉ dựa vào bind `127.0.0.1` và việc compose không publish cổng gRPC.
- Xem lại khi: một service cần version dependency khác hẳn các service còn lại (cân nhắc tách module), hoặc thời gian build CI của một thay đổi nhỏ vượt 10 phút; diff code sinh chiếm phần lớn review của các PR, hoặc CI bắt lệch `make generate` quá một lần mỗi tháng; một công cụ ghim ở `Makefile` chậm hơn bản mới nhất quá hai minor mà chưa có Renovate; cần cấu hình lồng nhau hoặc nhiều hơn khoảng 15 biến cho một service (cân nhắc file cấu hình).

## Xác nhận

`make generate-check` kiểm code sinh không lệch contract; `make check` chạy lint, `go test -race ./...` và `buf lint`; `make db-bootstrap` chạy lại không đổi gì.

## Hiện thực ở

- Một Go module, sinh code, dependency và công cụ ghim (§1–§3): `go.mod`, `buf.gen.yaml`, `services/*/sqlc.yaml` (ánh xạ cột `uuid` sang kiểu của dự án thay vì thêm module uuid bên thứ ba), target `generate`, `generate-check`, `tools` và các dòng ghim version của `Makefile`, `renovate.json`.
- Cấu hình bằng biến môi trường (§4): `internal/envcfg/`, `services/*/cmd/*/main.go`.
- Compose nối Postgres native và role database (§6): `deploy/compose/compose.yaml`, `deploy/postgres/bootstrap.sql`.
- Docker và binary (§7): `deploy/docker/service.Dockerfile`, lệnh con `migrate`/`serve` của `services/*/cmd/*/main.go`.
- Phạm vi đầu tiên (§8): `services/gateway/openapi.yaml` viết tay, `services/gateway/internal/httpx/middleware.go` (span HTTP mới không nhận trace context của client), giới hạn upload 500 MiB ở `services/video-service/internal/server/server.go`.

## Thông tin thêm

Phụ lục: [`appendix/0007-go-monorepo-toolchain-and-stage1-scope.md`](appendix/0007-go-monorepo-toolchain-and-stage1-scope.md) (trạng thái gốc, phân tích phương án, cây thư mục,
`buf.gen.yaml`, bảng dependency, bảng công cụ, bảng biến môi trường).

### Chỉnh bởi

- §1: [0030](0030-devsecops-supplement.md): directive `go 1.27` thành bản có số patch `go 1.27.3`, là bản Go mà govulncheck quét và mọi image Go build.
