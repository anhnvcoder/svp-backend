# Phụ lục ADR-0007: Một Go module cho cả monorepo, công cụ ghim ở Makefile, cấu hình bằng biến môi trường, phạm vi đầu tiên thu về luồng đồng bộ

Phụ lục của [ADR-0007](../0007-go-monorepo-toolchain-and-stage1-scope.md): phần chuyển ra khỏi ADR, giữ nguyên văn và xếp theo §: phân tích phương án chi tiết,
bảng và khối cấu hình, số đo, lệnh đã chạy. Đây là lịch sử, nên giữ ngày và nhãn tiến độ của lúc ghi.

<!-- markdownlint-disable MD052 -->

## Tiêu đề và trạng thái ghi lúc chốt

Tiêu đề gốc: 0007. Một Go module cho cả monorepo, công cụ ghim ở Makefile, cấu hình bằng biến môi trường, phạm vi giai đoạn 1 thu về luồng đồng bộ

- Trạng thái: Chấp nhận; phần module (directive `go 1.27` thành bản có số patch `go 1.27.3`, là bản Go mà govulncheck quét và
  mọi image Go build) chỉnh bởi [0030](../0030-devsecops-supplement.md)
- Ngày: 2026-10-11

## 1. Go module và bố cục thư mục

### Các lựa chọn về module

#### A. Một `go.mod` ở gốc repo

- Được: một `go.sum`; mọi service dùng cùng version dependency, nên các service deploy cùng một commit chạy cùng code thư
  viện; code sinh từ proto và code dùng chung import thẳng, không cần `replace`; `go test ./...` từ gốc chạy hết.
- Mất: không nâng dependency cho riêng một service được; `go.mod` chứa hợp các dependency của mọi service (binary chỉ link
  gói nó import, nên image không phình).

#### B. `go.work` + mỗi service một module

- Được: version dependency độc lập theo service; ranh giới module rõ.
- Mất: phải tách thêm module cho code sinh từ proto và code dùng chung, kèm `replace` hoặc gắn tag version cho chúng; các
  service lệch version dependency dù deploy cùng commit; nhiều `go.sum` phải cập nhật. Lợi ích hay được nêu, "chỉ build
  service có thay đổi" ở CI (giai đoạn 5), làm được bằng lọc đường dẫn mà không cần tách module.

### Quyết định về module

Chọn **A**: `go.mod` ở gốc, module `github.com/anhnvcoder/short-video-platform`, directive `go 1.27` (gói chuẩn `uuid` mới
có từ Go 1.27, mục 3).

```text
go.mod, go.sum, Makefile
buf.yaml, buf.gen.yaml
proto/svp/<domain>/v1/        contract (ADR-0006)
gen/go/svp/<domain>/v1/       code sinh từ proto, có commit
internal/                     code dùng chung giữa các service
services/<svc>/cmd/<svc>/     main.go
services/<svc>/internal/      code riêng của service
services/<svc>/sqlc.yaml      cấu hình sqlc của service
tools/<tên>/                  công cụ cho dev, không deploy
deploy/docker/, deploy/compose/, deploy/postgres/
docs/
```

Ngoài các thư mục `CLAUDE.md` đã liệt kê (`services/`, `proto/`, `deploy/`, `docs/`), thêm ba thư mục:

- `gen/`: tách code sinh khỏi code viết tay, không ai sửa tay trong đó. Cấp `gen/go/` chừa chỗ cho ngôn ngữ khác nếu có (ví
  dụ Python cho phần ML).
- `internal/` ở gốc: code mà ít nhất hai service cần (đọc biến môi trường, log, interceptor đọc `x-user-id`, kiểm UUID, ký
  và kiểm JWT). Go chỉ cho package nằm trong cây chứa thư mục `internal/` import nó: mọi thứ trong repo dùng được, module
  ngoài thì không. Code chỉ một service dùng không đưa lên đây.
- `tools/`: chương trình phụ trợ cho dev, không đóng vào image (ví dụ `tools/jwtkey` sinh cặp khoá Ed25519 cho `make env`).

## 2. Sinh code từ proto

### Các lựa chọn về gắn package Go cho proto

#### A. Ghi tay `option go_package` trong từng file `.proto`

- Được: `protoc` thuần cũng sinh đúng; đọc proto là thấy package Go.
- Mất: contract vốn trung lập ngôn ngữ bị gắn với module path của Go; đổi module path phải sửa mọi file proto; với luật
  breaking `FILE`, đổi `go_package` bị tính là thay đổi phá vỡ.

#### B. Managed mode trong `buf.gen.yaml`

- Được: không sửa `proto/`; module path nằm ở một chỗ.
- Mất: chỉ `buf generate` sinh đúng; muốn biết package Go phải đọc `buf.gen.yaml`.

### Các lựa chọn về plugin

#### C. Remote plugin trên BSR

- Được: không phải cài plugin.
- Mất: mỗi lần sinh code phụ thuộc mạng và một dịch vụ ngoài, trong khi ADR-0006 giữ `buf` chạy offline, không dùng BSR.

#### D. Plugin local, cài bằng `go install` với version ghim

- Được: chạy offline; version nằm trong `Makefile` của repo.
- Mất: máy dev và CI phải chạy `make tools` trước.

### Các lựa chọn về code sinh ra

#### E. Không commit, sinh lúc build

- Được: repo gọn, không có diff code sinh.
- Mất: clone xong không build được nếu chưa cài `buf` và plugin; Docker build phải cài chúng; review không thấy contract đổi
  làm code đổi gì.

#### F. Commit code sinh ra

- Được: clone xong là `go build`, `go test` chạy được; Docker build chỉ cần Go; diff cho thấy code sinh thay đổi.
- Mất: diff to hơn; sửa proto mà quên sinh lại thì code lệch contract.

### Quyết định về sinh code

Chọn **B + D + F**.

- `buf.gen.yaml` v2 ở gốc repo, chạy bằng `buf generate` từ gốc:

  ```yaml
  version: v2
  managed:
    enabled: true
    override:
      - file_option: go_package_prefix
        value: github.com/anhnvcoder/short-video-platform/gen/go
  plugins:
    - local: protoc-gen-go
      out: gen/go
      opt: paths=source_relative
    - local: protoc-gen-go-grpc
      out: gen/go
      opt: paths=source_relative
  ```

## 3. Dependency và công cụ

### Các lựa chọn và quyết định về dependency runtime

| Module | Version | Vì sao cần | Đã cân nhắc |
| --- | --- | --- | --- |
| `google.golang.org/grpc` | `v1.84.0` | Server và client gRPC (ADR-0002). Gói `health` (health service chuẩn, dùng cho healthcheck của compose và probe gRPC của k8s ở giai đoạn 4) và `test/bufconn` (test gRPC qua bộ nhớ, không mở cổng) nằm sẵn trong module này | ConnectRPC (ADR-0002 đã loại) |
| `google.golang.org/protobuf` | `v1.36.12` | Runtime của code sinh từ proto | — |
| `google.golang.org/genproto/googleapis/rpc` | `v0.0.0-20261005182115-fad411399dd8` | Gói `errdetails` để gắn `google.rpc.ErrorInfo` vào status (architecture §8.4). Module này không gắn tag, nên version là pseudo-version | Tự định nghĩa message lỗi: lệch chuẩn `google.rpc`, `grpcurl` và client gRPC chung không hiểu |
| `github.com/jackc/pgx/v5` | `v5.11.0` | Driver Postgres: pool `pgxpool`, kiểu `uuid`/`timestamptz`; gói `stdlib` cho goose chạy qua `database/sql`. Code `sqlc` sinh ra dùng pgx/v5 | `lib/pq` (ở chế độ bảo trì); chỉ `database/sql` (mất pool và kiểu dữ liệu riêng của pgx) |
| `github.com/pressly/goose/v3` | `v3.28.0` | Migration SQL dùng **như thư viện**: file `.sql` nhúng vào binary bằng `embed`, chạy bằng lệnh con `<svc> migrate`; image distroless không cần thêm CLI. Mỗi migration chạy trong một transaction, lỗi thì rollback sạch | golang-migrate (cũng nhúng được, nhưng migration lỗi để database ở trạng thái `dirty`, phải sửa tay bằng `force`); Atlas (khai báo schema mong muốn rồi tự tính diff: thêm một mô hình và một CLI ngoài trọng tâm của lộ trình) |
| `github.com/golang-jwt/jwt/v5` | `v5.3.1` | Ký và kiểm JWT. Thư viện JWT phổ biến nhất của Go; có `WithValidMethods` (JWT-1), `WithIssuer`, `WithAudience`, `WithExpirationRequired` (JWT-2), `WithLeeway` (lệch đồng hồ 30 giây); hỗ trợ EdDSA với khoá `crypto/ed25519` | Tự viết bằng thư viện chuẩn (ít dependency nhưng tự gánh mọi ca biên của một ranh giới bảo mật); `lestrrat-go/jwx`, `go-jose` (bề mặt API lớn hơn nhiều so với nhu cầu ký/kiểm một loại token) |
| `golang.org/x/crypto` | `v0.58.0` | Gói `argon2` cho argon2id (threat model §4.1, JWT-7); thư viện chuẩn chưa có | bcrypt (threat model §4.1 đã loại) |

Dùng thư viện chuẩn, không thêm dependency:

- **UUIDv7:** gói chuẩn `uuid` của Go 1.27 (`uuid.NewV7`, `uuid.Parse`, `UUID.String`). Cân nhắc `github.com/google/uuid`
  (`v1.6.0`): làm được việc tương tự nhưng là thêm một dependency. `uuid.Parse` nhận cả dạng `{…}`, `urn:uuid:…`, dạng không
  gạch và chữ hoa, trong khi contract chỉ nhận dạng chuẩn 36 ký tự chữ thường (ADR-0006 mục 2). Kiểm ở biên bằng
  `u, err := uuid.Parse(s)` rồi bắt buộc `u.String() == s` (`String` luôn trả chữ thường có gạch).
- **Router REST:** `net/http.ServeMux` (pattern có method và wildcard từ Go 1.22, ví dụ `GET /v1/videos/{id}`). Cân nhắc
  chi, gin, echo: gateway có ít route, không cần middleware của framework; mux tự tạo bằng `http.NewServeMux`, không dùng
  `http.DefaultServeMux` (OPS-1).
- **Log:** `log/slog` với `JSONHandler`.
- **Cấu hình:** `os.Getenv` + một helper nhỏ trong `internal/`, không thư viện config (mục 4).
- **Test:** chỉ gói `testing`, không thư viện assert.
- **Ed25519, nhúng file:** `crypto/ed25519`, `embed`.

**Redis driver: không thêm ở giai đoạn 1** (mục 8). Giai đoạn 2 thêm `github.com/redis/go-redis/v9` (bản mới nhất ngày
2026-10-11 là `v9.23.0`; chốt version lúc thêm).

### Các lựa chọn về cách ghim công cụ

#### A. Directive `tool` trong `go.mod` (Go 1.24+)

- Được: version công cụ nằm trong `go.mod`, chạy bằng `go tool <tên>`, không cần bước cài.
- Mất: dependency của công cụ vào chung đồ thị module của ứng dụng. `sqlc` và `golangci-lint` kéo hàng trăm module vào
  `go.mod`/`go.sum`, và có thể ép nâng version dependency mà service đang dùng.

#### B. Ghim version trong `Makefile`, cài bằng `make tools`

- Được: `go.mod` chỉ chứa dependency của ứng dụng; mỗi công cụ build bằng chính Go 1.27.2 của máy.
- Mất: phải tự cập nhật version trong `Makefile` (tới khi có Renovate ở giai đoạn 5); máy dev và CI chạy `make tools` trước.

### Quyết định về công cụ

Chọn **B**. `make tools` chạy `go install <module>@<version>` cho từng công cụ:

| Công cụ | `go install` | Ghi chú |
| --- | --- | --- |
| `protoc-gen-go` | `google.golang.org/protobuf/cmd/protoc-gen-go@v1.36.12` | Cùng version với runtime `google.golang.org/protobuf` |
| `protoc-gen-go-grpc` | `google.golang.org/grpc/cmd/protoc-gen-go-grpc@v1.6.2` | Module riêng, version riêng với `grpc` |
| `sqlc` | `github.com/sqlc-dev/sqlc/cmd/sqlc@v1.31.1` | Parser Postgres của sqlc là thư viện C (`pg_query_go`), nên build cần cgo và trình biên dịch C (máy có clang của Xcode Command Line Tools; CI cần `gcc`) |
| `golangci-lint` | `github.com/golangci/golangci-lint/v2/cmd/golangci-lint@v2.14.0` | Hỗ trợ go1.27 từ v2.13.0 (CHANGELOG). Tài liệu golangci-lint khuyên cài binary dựng sẵn; chọn `go install` để công cụ được build bằng chính Go 1.27.2, vì golangci-lint chỉ phân tích được module có `go` không mới hơn bản Go đã build nó |
| `gitleaks` | `github.com/zricethezav/gitleaks/v8@v8.30.1` | Quét bí mật trong git hook (SEC-1) |

`buf` 1.73.0 đã cài qua Homebrew từ giai đoạn 0 (ADR-0006), không nằm trong `make tools`.

## 4. Cấu hình

### Các lựa chọn về cấu hình

#### A. Chỉ biến môi trường (12-factor)

- Được: cùng một image chạy ở compose, k8s và cloud, chỉ đổi biến; bí mật đưa vào lúc chạy qua cơ chế sẵn có của từng nền
  tảng (`.env` của compose, Secret của k8s, External Secrets ở giai đoạn 7).
- Mất: không có cấu hình lồng nhau; giá trị nào cũng là chuỗi, phải tự parse và kiểm.

#### B. File cấu hình (YAML) + thư viện như viper, koanf

- Được: cấu hình có cấu trúc, có mặc định trong file.
- Mất: thêm dependency; file phải mount vào container; bí mật vẫn phải đi đường riêng, nên có hai nguồn cấu hình.

### Quyết định về cấu hình

Chọn **A**. Mỗi service chỉ đọc biến của mình, không có file cấu hình. Thiếu biến bắt buộc hoặc giá trị sai định dạng thì
service thoát ngay lúc khởi động với lỗi nêu tên biến (không in giá trị).

| Service | Biến | Mặc định | Ý nghĩa |
| --- | --- | --- | --- |
| `user-service` | `LISTEN_ADDR` | `127.0.0.1:9101` | Địa chỉ gRPC |
| `user-service` | `DATABASE_URL` | — (bắt buộc) | DSN Postgres tới `svp_user` |
| `user-service` | `JWT_SIGNING_KID` | — (bắt buộc) | `kid` ghi vào header token |
| `user-service` | `JWT_SIGNING_KEY` | — (bắt buộc) | Seed Ed25519 32 byte, mã hoá base64 chuẩn. Chỉ user-service nhận khoá ký (JWT-10) |
| `video-service` | `LISTEN_ADDR` | `127.0.0.1:9102` | Địa chỉ gRPC |
| `video-service` | `DATABASE_URL` | — (bắt buộc) | DSN Postgres tới `svp_video` |
| `gateway` | `LISTEN_ADDR` | `127.0.0.1:8080` | Địa chỉ HTTP |
| `gateway` | `USER_SERVICE_ADDR` | `127.0.0.1:9101` | Địa chỉ gRPC của user-service |
| `gateway` | `VIDEO_SERVICE_ADDR` | `127.0.0.1:9102` | Địa chỉ gRPC của video-service |
| `gateway` | `JWT_VERIFY_KEYS` | — (bắt buộc) | `<kid>:<base64 chuẩn của khoá công khai 32 byte>[,…]`; giữ được cả khoá cũ và khoá mới trong lúc đổi khoá (SEC-4) |

## 5. Cổng

### Các lựa chọn về cổng

#### A. Cổng gRPC quen thuộc `50051` cho mọi service

- Mất: chạy native nhiều service trên một máy thì đụng nhau, vẫn phải đánh số riêng.

#### B. Mỗi service một cổng cố định trong dải riêng

- Được: chạy native và trong compose dùng cùng số; nhìn cổng biết service.

### Quyết định về cổng

Chọn **B**:

| Service | Giao thức | Cổng |
| --- | --- | --- |
| `gateway` | HTTP | 8080 |
| `user-service` | gRPC | 9101 |
| `video-service` | gRPC | 9102 |

- Kiểm ngày 2026-10-11 bằng `lsof -nP -iTCP -sTCP:LISTEN`: không tiến trình nào nghe ở 8080, 9101, 9102.
- Service sau lấy số tiếp theo trong dải `91xx` (engagement-service, feed-service ở giai đoạn 2).
- Compose chỉ publish gateway, và chỉ ở `127.0.0.1:8080` (IN-2). Cổng gRPC không publish ra máy.
- Cổng quản trị (pprof, `/metrics`) để giai đoạn 3. Giai đoạn 1 giữ OPS-1 bằng cách không dùng `http.DefaultServeMux`.

## 6. Compose nối Postgres native và role database

### Các lựa chọn về Postgres cho compose

#### A. Postgres chạy trong compose

- Mất: thêm một container ăn RAM trong khi máy đã có Postgres native; dữ liệu local tách thành hai nơi.

#### B. Container nối ra Postgres native

- Được: đúng ràng buộc máy của plan (giai đoạn compose dùng Postgres/Redis native); chạy native hay trong compose dùng cùng
  database.
- Mất: phụ thuộc cách Docker trỏ về máy host.

### Các lựa chọn về role

#### C. Một role cho mỗi service, vừa chạy migration vừa chạy service

- Mất: service đang chạy có quyền `CREATE`, `DROP` bảng; bị chiếm thì xoá được schema của chính nó.

#### D. Hai role cho mỗi service: migrator và app

- Được: service đang chạy chỉ đọc ghi dữ liệu, không đổi được schema (IN-6).
- Mất: thêm role, thêm một DSN phải quản lý; bảng mới phải được cấp quyền cho role app (giải bằng default privileges).

## 7. Docker và binary

### Các lựa chọn về image runtime

#### A. Image có hệ điều hành (`alpine`, `debian-slim`)

- Được: có shell để debug, có `curl` cho healthcheck.
- Mất: thêm package phải vá lỗ hổng; kẻ chiếm được process có sẵn shell và công cụ.

#### B. `scratch`

- Được: nhỏ nhất.
- Mất: thiếu chứng chỉ CA, `tzdata`, user không phải root; phải tự chép vào.

#### C. distroless `static`, bản `nonroot`

- Được: có chứng chỉ CA, `tzdata`, user `nonroot` (uid 65532); không shell, không package manager.
- Mất: không `exec` vào container để debug được; healthcheck phải do chính binary làm.

## 8. Phạm vi giai đoạn 1

### Các lựa chọn về phạm vi

#### A. Làm đủ danh sách của plan, kể cả Redis

- Mất: thiết kế chưa có chỗ nào dùng Redis ở giai đoạn 1 (rate limit ở gateway và cache feed khám phá đều thuộc giai đoạn
  2). Thêm Redis bây giờ là tạo một chỗ dùng chỉ để đánh dấu đã làm: code giả, phải gỡ hoặc viết lại ở giai đoạn 2.

#### B. Làm luồng đồng bộ đầy đủ, để các phần cần storage và event cho giai đoạn 2

- Được: mọi thứ làm ra đều có test thật; giai đoạn 2 thêm Redis, MinIO, Redpanda cùng lúc với code thật sự cần chúng.
- Mất: `make up` của giai đoạn 1 chưa upload được file.
