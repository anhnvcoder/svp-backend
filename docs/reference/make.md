# Lệnh `make`: code, hợp đồng, hook

Loại tài liệu (Diátaxis): **reference**, tra cứu khi cần một lệnh hay một quy tắc cụ thể; luật làm việc ở [`AGENTS.md`](../../AGENTS.md).

## Proto

Từ gốc repo, cho `proto/`:

- `buf lint` (phải sạch, không output) và `buf build -o /dev/null`.
- `buf breaking --against '.git#branch=main'` khi sửa `proto/`. **Chỉ dùng được sau khi `proto/` đã có trong một commit
  trên `main`**; trước đó buf báo "Module had no .proto files".

## Code Go

Cho code Go (`services/`, `internal/`, `tools/`), mọi lệnh chạy từ gốc repo qua `Makefile` (`make help`
liệt kê target):

- `make tools`: cài một lần các công cụ ghim version (`protoc-gen-go`, `protoc-gen-go-grpc`, `sqlc`, `golangci-lint`,
  `actionlint`, `gitleaks`, `govulncheck`, `sloth` sinh rule SLO, `k3d`, `chainsaw` chạy diễn tập k8s); `buf`, Helm cài bằng Homebrew (CI cài hai thứ đó bằng
  `make ci-tools`, chỉ chạy trên Linux amd64).
- `make generate`: chạy sau khi sửa `proto/` hoặc SQL của `sqlc`; code sinh ra (`gen/go`, code `sqlc`) được commit.
- `make generate-check`: chạy `make generate` trong bản sao tạm của working tree (file đã track và file chưa track không bị
  ignore, không `.env`), in file lệch và diff, exit ≠ 0 khi lệch; không bao giờ ghi vào working tree.
- `make api-contract-check [BASE=<ref>]` (mặc định `origin/main`; [ADR-0033](../adr/0033-svp-web-repo.md) §1, script
  `deploy/ci/contract.sh check`): luật version của hợp đồng REST `services/gateway/openapi.yaml` (client ở repo khác ghim theo version;
  luật viết ở comment đầu file, `info.version` hiện `1.0.0`). So spec của working tree với spec ở `BASE` theo byte và bằng oasdiff
  (`OASDIFF_IMAGE` ghim của `Makefile`, `--network none`, từ chối `$ref` ra ngoài); đỏ khi `info.version` một bên không phải
  `X.Y.Z`, file đổi mà version không lớn hơn, có breaking mà major giữ nguyên (từ `1.0.0`) hay version giảm (ba phép kiểm version
  của oasdiff nâng lên `err`), changelog có mục mà chỉ tăng patch. `BASE` toàn số 0 hay không có spec: một dòng summary, exit 0.
  Changelog in ra log và summary. Breaking đi ba bước: thêm cái mới (minor), chuyển client, bỏ cái cũ (major) khi không client nào
  của stg, prd còn dùng. `deploy/ci/contract-test.sh`: test của cả `check` (oasdiff thật) và `publish` (registry, cosign giả).
- `make check` = `make check-go`. `make check-go`: `gofmt`, `go vet`, `golangci-lint run` (gồm gosec),
  `actionlint` (mọi file của `.github/workflows/`), `buf lint` + `buf build`, `make vulncheck` (govulncheck, dưới đây),
  `go test -race ./...` (có integration test trên Postgres native `127.0.0.1:5432` qua
  `SVP_TEST_POSTGRES_URL` và Redis native db 15 qua `SVP_TEST_REDIS_URL`, mặc định `redis://127.0.0.1:6379/15` trong
  `Makefile`). Thu hẹp bằng `make test PKGS=./services/user-service/...`; `TESTFLAGS` thêm cờ cho `go test` của
  `make test`, `make cover`, `make check` (`make test TESTFLAGS=-count=1` chạy lại không dùng cache, như CI), `LINTFLAGS`
  thêm cờ cho golangci-lint của `make lint`.
- `make zizmor` ([ADR-0041](../adr/0041-github-hardening.md) (g)): lint bảo mật workflow bằng zizmor `ZIZMOR_IMAGE` (image chính thức ghim `tag@sha256`,
  repo gắn chỉ đọc) với `--persona=regular` trên cả repo; mọi finding làm lệnh thoát khác 0. Có `GH_TOKEN` thì chạy thêm audit online (impostor
  commit, action có lỗ hổng), không thì offline (mặc định trên máy). `ZIZMOR_FORMAT=github` in annotation của Actions, `ZIZMOR_SARIF=<đường dẫn>`
  ghi SARIF (không chặn). Ngoại lệ ở `.github/zizmor.yml`, mỗi mục một comment lý do. Không thuộc `make check`; CI chạy nó ở job `zizmor` của `ci.yml`.
- `make docs-check [DOCS='<file hay glob>']`: kiểm tĩnh mọi file Markdown. Chạy lần lượt markdownlint-cli2 (`MARKDOWNLINT_IMAGE`, luật
  ở `.markdownlint.yaml`, mỗi luật tắt hay chỉnh có comment lý do) và lychee `--offline --include-fragments` (`LYCHEE_IMAGE`, cấu hình ở
  `lychee.toml`; link nội bộ và anchor heading, link ra site khác không kiểm). Hai image chính thức ghim `tag@sha256`, chạy
  `--network none`, repo gắn chỉ đọc; link tương đối ra ngoài repo (tới `plans/`) báo lỗi. Cả hai công cụ luôn chạy; lệnh thoát khác 0 khi
  một trong hai báo lỗi. Mặc định là mọi `.md` git theo dõi và file mới chưa theo dõi; `DOCS` thu hẹp (đường dẫn tương đối gốc repo).
- `make helm-docs`, `make helm-docs-check`: `deploy/helm/svp-service/README.md` (bảng values của chart dùng chung bởi bảy release) sinh bởi
  helm-docs `HELM_DOCS_IMAGE` (image chính thức ghim `tag@sha256`, không mạng, chạy bằng uid của người gọi) từ `Chart.yaml`, comment `# --` của
  `values.yaml` và `README.md.gotmpl`. `make helm-docs` ghi file; `make helm-docs-check` gắn repo chỉ đọc, in thứ helm-docs sẽ ghi và đỏ khi
  `README.md` lệch (sửa mô tả ở `values.yaml` rồi chạy `make helm-docs`). `make helm-check` chạy `helm-docs-check` trước, nên job CI của nó kiểm luôn.

## Kiểm tra bổ sung của code Go

- `make cover`: `go test -race` như `make test` nhưng ghi coverage vào `cover.out` (đã gitignore) và in tổng; thu hẹp bằng
  `PKGS=`, xem từng dòng bằng `go tool cover -html=cover.out`.
- `make vulncheck` ([ADR-0030](../adr/0030-devsecops-supplement.md) §1, trong `make check-go` trước test, cần mạng tới
  `vuln.go.dev`, không biến bỏ qua): govulncheck `-format json ./...` bằng đúng Go của directive `go` trong `go.mod`
  (`GOTOOLCHAIN=go<directive>`; directive phải có số patch, `go 1.27.3`), rồi gate `tools/vulngate` quyết: lỗ hổng mức symbol
  (code gọi tới) đỏ, in id, module@version, bản sửa và trace; mức module, package chỉ một dòng `INFO`; mọi dòng `FROM golang:` của
  `deploy/docker/*.Dockerfile` phải mang đúng bản Go đã quét (lệch, tag không đủ ba số, hay không còn dòng nào là đỏ). Nâng Go thì
  cùng một PR đổi directive, hai Dockerfile và `go-version` của workflow. Ngoại lệ chỉ ở `.govulncheck-ignore.json` (gốc repo,
  chỉ tạo khi có mục đầu tiên; hiện không có): khoá `ignore`, mỗi mục đúng `id`, `module`, `version` (như frame đầu, `stdlib`
  cho thư viện chuẩn), `statement` có nội dung, `expired_at` sau hôm nay (UTC) và không quá 30 ngày; chỉ cho lỗ hổng chưa có bản
  vá (có bản vá thì nâng), mục trùng, hết hạn hay không còn khớp finding nào là đỏ.
- `make regal-lint` và `make regal-fix`: lint Rego của `deploy/ci/ignorefile-policies/` và `deploy/ci/gitops-tree-policies/` bằng Regal
  (linter của dự án OPA) từ image chính thức `REGAL_IMAGE` ghim `tag@sha256`, `--network none`, mỗi thư mục một lượt như
  `make conftest-verify`. `regal-lint` chỉ đọc, exit khác 0 khi có vi phạm (cả mức warning); `regal-fix` ghi vào hai thư mục
  các sửa tự động (`opa fmt`, danh sách ở `regal fix --help`), phần còn lại sửa tay. Luật ở `.regal/config.yaml`: mặc định, chỉ tắt
  hay chỉnh luật nào có lý do ghi ngay trong file (policy do conftest đọc: namespace theo package, `data.*` do `--data` đưa vào,
  độ dài dòng 200 vì thông điệp là một chuỗi không ngắt được). Không thuộc `make check`; CI chạy `make regal-lint` ở job
  `config`, hook `pre-commit` chạy khi commit đổi `*.rego`.
- `make chainsaw-lint` ([ADR-0050](../adr/0050-bash-to-standard-tools.md) mục 2): kiểm tĩnh các diễn tập Chainsaw dưới
  `deploy/k8s/drills/`, không cần cluster. Mỗi file YAML ở đó phải là đúng một trong ba loại: `chainsaw-test.yaml` (`chainsaw lint
  test`), `.chainsaw.yaml` (`chainsaw lint configuration`), StepTemplate dưới `templates/` (kubeconform `-strict` từ
  `KUBECONFORM_IMAGE`, `--network none`); file khác là lỗi, nêu tên file. `chainsaw lint` ở `CHAINSAW_VERSION` chỉ nhận `test` và
  `configuration`, nên schema StepTemplate của đúng tag đó chép vào `deploy/k8s/drills/.schemas/json/` (chạy offline), `.schemas/source`
  ghi URL nguồn và target đỏ khi tag trong URL khác `CHAINSAW_VERSION`: nâng version thì chép lại schema từ tag mới. Chainsaw ghim
  `CHAINSAW_VERSION` ở `Makefile` (`# renovate:`), cài bằng `make tools`. Cấu hình chung `deploy/k8s/drills/.chainsaw.yaml` (chạy
  tuần tự, report JUnit vào `.k8s/drills/`; context cluster và tên report là cờ của `chainsaw test`, không đặt được trong file);
  StepTemplate dùng chung ở `deploy/k8s/drills/templates/`: `probe-up.yaml` (namespace `svp-probe` cùng pod `probe`, tự xoá khi test
  kết thúc) và `port-forward.yaml` (port-forward loopback, dừng theo pid khi test kết thúc). Bước `script` của Chainsaw nhận
  `KUBECONFIG` là bản chép của cluster nó đang chạy (một context tên `chainsaw`), nên `kubectl` trong template đọc lại kubeconfig của
  người gọi (`env('KUBECONFIG')`) và luôn ghi `--context k3d-svp`; bước `apply`, `wait` dùng client của Chainsaw, nên `probe-up.yaml`
  dừng FAIL khi Chainsaw không chạy trên cùng server với context `k3d-svp` (thiếu `--kube-context k3d-svp`).
- `make fuzz [FUZZTIME=30s] [PKGS=…]` (ADR-0030 §2): chạy lần lượt mọi `FuzzXxx` (mỗi gói một `fuzz_test.go`: `pagetoken`,
  `authtoken`, `objstore`, `httpx` của gateway, `server` của user-service; 10 target) bằng `go test -fuzz`, không `-race`,
  dừng ở target đầu tiên đỏ và in đường dẫn input go ghi ra dưới `testdata/fuzz/<target>/`; seed chạy trong `make test`. Lỗi
  tìm ra thì sửa hàm và commit input đó (test đỏ trước khi sửa). Chỉ chạy tay, không có trong CI.

## Web client chạy từ checkout này

- Web client: mã, `make check`, sinh type từ hợp đồng, quét lockfile, `make dev` và quy ước test của web ở repo `svp-frontend`
  ([ADR-0033](../adr/0033-svp-web-repo.md)); backend chỉ chạy web trên stack và cluster của nó. Năm target cần mã web là wrapper
  gọi `Makefile` của thư mục web (`web_dir`, mục `make web-clone` của [`k8s.md`](k8s.md)) với `SVP_BACKEND_DIR` là checkout này, nên Node 26,
  pnpm và trình duyệt Playwright là của bản clone đó (`make install`, `pnpm exec playwright install chromium webkit` trong bản clone),
  kết quả ở `test-results/` của bản clone: `make web-e2e` (`make e2e`: Playwright trên Chromium và WebKit vào stack `make up`,
  `http://localhost:3001`), `make measure-web` (`make measure-web`: thời gian tới khung đầu sau khi vuốt, bộ nhớ container `web`),
  `make measure-upload` (`make measure-upload`: tải video ~100 MB qua `/upload`, thời gian tới `READY`), `make web-lighthouse`
  (`make lighthouse`: LCP 2 500 ms, CLS 0,1, TBT 200 ms; đỏ không chặn; không trỏ vào media origin có ghi log header, ADR-0018 §10),
  `make web-sourcemaps` (`make sourcemaps`: source map trình duyệt của đúng bản build mà container `web` của stack
  `make up OBS=lgtm WEB_FROM=clone` chạy lên GlitchTip `http://127.0.0.1:8000` bằng `SENTRY_SOURCEMAPS_TOKEN` của `.env`; web chạy bản
  phát hành `WEB_FROM=stg|image` thì từ chối: bản đó build ở CI với build id riêng). `SVP_E2E_EVIDENCE=<thư mục tuyệt đối>` và
  `SVP_E2E_GLITCHTIP=1` (sau khi tải source map) đi qua wrapper như cũ. **LOCAL LAB ONLY:** seed của e2e, mỗi worker Playwright,
  `measure-upload` và Lighthouse xoá khoá `svp:gw:rl:register:*` ở db 10 như `make smoke` (bằng script của checkout này). Web của
  compose nhận `SENTRY_DSN` (rỗng thì `/monitoring` trả 404), `SENTRY_ENVIRONMENT`, `x-telemetry-env` như service Go và
  `NEXT_SERVER_ACTIONS_ENCRYPTION_KEY` của `.env`; gateway compose đặt `TRUST_TRACE_CONTEXT=true` (chỉ loopback, WEB-24). Bản clone hay
  worktree cũ có `web/` (file bị ignore còn lại sau khi `web/` rời repo, như `node_modules/`, `.next/`): xoá bằng `rm -rf web`, nếu
  không `fmt-check` và `git status` thấy chúng.

## Git hook

- `make hooks`: bật git hook ở `.githooks/` một lần cho mỗi clone. `pre-commit` chạy `gofmt` trên file Go đã stage,
  `golangci-lint run`, `buf lint` và `gitleaks` trên thay đổi đã stage, thêm `make regal-lint` khi commit đổi file `*.rego`
  (cần Docker).
