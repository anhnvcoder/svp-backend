# Short-video platform: hướng dẫn cho agent

Nền tảng video ngắn mini (upload, transcode HLS, feed, like/view), làm xuyên suốt từ thiết kế, code, hạ tầng, vận hành tới cloud.
Mục đích là học DevOps và Solution Architect; mỗi bước lớn kết thúc bằng hệ thống chạy được, có số đo và có ADR cho các quyết định.
File này theo định dạng [AGENTS.md](https://agents.md): luật làm việc cho mọi agent; chi tiết tra cứu ở [`docs/reference/`](docs/reference/).

Đọc trước: [`README.md`](README.md) (chạy thử, bản đồ thư mục), [`docs/README.md`](docs/README.md) (mục lục tài liệu),
[`docs/architecture.md`](docs/architecture.md) và [`docs/adr/`](docs/adr/) (thiết kế hiện tại và lý do).

## Nguyên tắc

- **Công cụ chọn theo hiện trạng ngành, có lý do.** Đổi công cụ thì viết ADR.
- **Một công cụ chính cho mỗi mảng, học sâu.** Công cụ thứ hai chỉ dựng để so sánh, kết luận bằng ADR.
- **Mỗi bước lớn kết thúc ở trạng thái chạy được và có số đo**, không dừng ở "đã cài".
- **Local trước, cloud sau.** Cloud dựng lên và xoá trong cùng buổi.
- **Máy 16 GB RAM:** compose chạy theo profile, không bật hai bộ observability cùng lúc, không chạy song song k3d và compose.
- **Gặp đâu học đó:** bài toán cần so sánh nhiều cách giải thì tách thành lab riêng, đo xong đem cách thắng về project.

## Chế độ mentor

Người học ưu tiên học DevOps + SA.

- **Code Go** (service, lab): AI viết, kèm test và chạy đủ lệnh ở mục "Lệnh kiểm" dưới đây. Mỗi lần giao code, tóm tắt cấu trúc và
  các chỗ đáng chú ý để người học đọc hiểu được.
- **Thiết kế** (`docs/`, ADR, `.proto`) **và hạ tầng** (compose, Makefile, Helm, Terraform, CI): AI soạn và giải thích lý do từng
  quyết định; người học duyệt.

## Quy ước

Quy ước chung (ngôn ngữ, tài liệu timeless, ADR, comment, Git, repo public, phụ thuộc): [`CONTRIBUTING.md` của `anhnvcoder/.github`](https://github.com/anhnvcoder/.github/blob/main/CONTRIBUTING.md); dưới đây chỉ luật riêng của repo này.

- **Ngôn ngữ lập trình:** Go, ưu tiên thư viện chuẩn. Web client (TypeScript, Next.js, [ADR-0016](docs/adr/0016-web-client.md)) ở repo
  `svp-frontend` (bản clone `<workspace>/frontend`, [ADR-0033](docs/adr/0033-svp-web-repo.md)), theo `AGENTS.md` của repo đó. Thêm
  dependency phải có lý do.
- **Ngôn ngữ viết:** file `.md` viết tiếng Việt.
- **Link ADR:** tìm ngược từ quyết định tới code qua mục "Hiện thực ở" của mỗi ADR; file `.md` vẫn link ADR.
- **Monorepo:** `services/<tên>/`, `proto/`, `deploy/`, `docs/`; thư mục nào tạo khi cần nó. Repo `anhnvcoder/svp-backend` (tên
  `short-video-platform` tới 2026-10-31, [ADR-0036](docs/adr/0036-repo-rename.md)), Go module `github.com/anhnvcoder/svp-backend`.
- **ADR** ở `docs/adr/NNNN-<slug>.md`, theo mẫu ngắn trong [`docs/adr/README.md`](docs/adr/README.md).
- **Runbook, postmortem, RFC** ([ADR-0020](docs/adr/0020-reliability-stage6.md) §12, §14): `docs/runbooks/` (mẫu và mục lục ở
  `README.md`): một runbook mỗi cảnh báo `severity=page`, tên file là tên alert kebab-case, rule page mang `runbook_url` trỏ file đó
  trên `main` (thêm cảnh báo page thì thêm runbook trong cùng thay đổi); sự cố đã gặp và quy trình tay cũng ở đây.
  `docs/postmortems/<yymmdd>-<slug>.md`: postmortem không đổ lỗi theo mẫu của `README.md`, mốc thời gian UTC có nguồn.
  `docs/rfc/NNNN-<slug>.md`: một trang cho người không làm kỹ thuật (vấn đề, phương án, chi phí có nguồn, rủi ro, đề xuất).
- **Git:** mọi thay đổi vào `main` đi qua PR có `ci-ok` và `images-ok` xanh (ruleset `main`, Terraform ở `github/rulesets.tf` của `svp-infra`,
  [ADR-0015](docs/adr/0015-cicd-devsecops-stage5.md) §11), cả của người học. Chỉ squash merge, lịch sử thẳng, tiêu đề PR theo Conventional Commits
  (thành tiêu đề commit; workflow `pr-title.yml`); file nhạy cảm (`/.github/`, `/Makefile`, `/renovate.json`, `deploy/ci/`…) có Code Owner
  ([ADR-0041](docs/adr/0041-github-hardening.md)).

## Database và Redis

**Mỗi service một database riêng; không service nào đọc database của service khác.** Cần dữ liệu của service khác thì gọi API của
nó hoặc dựng bản sao từ event.

| Service | Postgres `127.0.0.1:5432` | Redis `127.0.0.1:6379` |
| --- | --- | --- |
| `gateway` | — | db 10 |
| `user-service` | `svp_user` | db 11 |
| `video-service` | `svp_video` | db 12 |
| `engagement-service` | `svp_engagement` | db 13 |
| `feed-service` | `svp_feed` | db 14 |
| `media-worker` | — | — |
| `web` | — | db 9 |
| GlitchTip (profile `obs`, tracker lỗi) | `svp_glitchtip` | — |
| test (`make test`) | `svp_<...>_test` | db 15 |

- **Redis db 0, db 5 và db 7 đang chứa dữ liệu của dự án khác:** không dùng, không `FLUSHDB` ở đó. Không `FLUSHDB`/`FLUSHALL` ở bất kỳ
  db nào, kể cả db 15 của test. Lệnh luôn ghi rõ port (`psql -h 127.0.0.1 -p 5432`, `redis-cli -p 6379 -n 14`).
- Trong cluster k3d cùng tên database (cả `svp_glitchtip`) nằm trên Postgres `svp-pg` của CloudNativePG (`svp-pg-rw.svp-data:5432`),
  gateway, feed-service và web dùng db 10, db 14 và db 9 (session) của Valkey `valkey.svp-data:6379`; Postgres và Redis native không
  bị đụng.
- **Xoá khoá chỉ ở lab local** (LOCAL LAB ONLY, không trỏ script vào stack dùng chung): smoke, e2e, diễn tập, tải, DAST, game day
  chỉ được xoá khoá rate limit đăng ký `svp:gw:rl:register:*` ở db 10 (`SCAN` + `DEL`, không `FLUSHDB`) và cache khám phá
  `svp:feed:explore:*` ở db 14; ngoài hai tiền tố đó script chỉ đọc Redis. Trên cluster là db 10 của Valkey (qua `kubectl exec`).
- Script diễn tập chỉ `SELECT` trên `svp_video`, `svp_engagement`, `svp_feed` và luôn bật lại mọi service khi kết thúc.
- Ba biến `SVP_GATEWAY_REDIS_URL`, `SVP_UPLOAD_ABANDON_AFTER`, `SVP_UPLOAD_SWEEP_INTERVAL` **chỉ dùng cho diễn tập**, không đặt trong
  `.env` (hạn dọn upload dưới 15 phút ngắn hơn hạn form upload).
- Test chỉ dùng database `svp_<...>_test` và Redis db 15 với tiền tố khoá ngẫu nhiên (helper `internal/pgtest`, `internal/redistest`
  từ chối thứ khác): [`docs/reference/testing.md`](docs/reference/testing.md).

## Docker, compose, Kubernetes

- **Docker, compose, k3d chỉ chạy qua `Makefile`.** Mọi target gọi `env -u DOCKER_DEFAULT_PLATFORM docker ...`: shell global đặt
  `DOCKER_DEFAULT_PLATFORM=linux/amd64` cho dự án khác, nếu không bỏ biến này thì container chạy amd64 qua giả lập, chậm và tốn RAM.
  Chạy tay ngoài Makefile cũng phải thêm tiền tố đó. Image cho cloud build đa kiến trúc ở CI.
- **Compose và k3d không chạy cùng lúc:** `make up` từ chối khi cluster k3d hay registry `k3d-svp-registry` chạy; `make k8s-up`,
  `make k8s-gitops-up` từ chối khi stack compose `svp` chạy. Chỉ một bộ observability mỗi lúc (`make down` trước khi đổi `OBS`).
- **`kubectl`/`helm`** chỉ chạy vào cluster k3d, luôn ghi `--context k3d-<tên>` trong lệnh (cache Helm ở `.k8s/helm`).
- Cổng publish chỉ trên `127.0.0.1`; UI của cluster chỉ mở bằng port-forward loopback (`make k8s-ui-*`), không HTTPRoute,
  LoadBalancer hay NodePort.

## An toàn cloud và chuỗi cung ứng

- **AI không chạy lệnh nào chạm tài khoản AWS/GCP, kể cả lệnh chỉ đọc:** `aws`, `gcloud`, `gsutil`, `bq`, `eksctl`,
  `terraform init/plan/apply/destroy/import/state/output`, `kubectl`/`helm` vào cluster EKS/GKE, script dùng SDK cloud. Mọi target
  `eks-*` (`make eks-gitops-up`, `eks-secrets`, `eks-smoke`…) do người học chạy; AI chỉ chạy test giả `deploy/k8s/eks-context-test.sh`.
- AI được chạy: `terraform fmt`, `terraform init -backend=false` + `terraform validate`, `aws --version`, `gcloud --version`, đọc và
  sửa code IaC.
- **AI soạn lệnh để người học tự chạy:** ghi profile/project và region ngay trong lệnh (`AWS_PROFILE=anhnv-sso aws ... --region ...`,
  `gcloud ... --project ...`), mỗi bước một khối, nói rõ cần dán lại output nào và tìm gì trong đó. Nhiều bước thì viết thành script
  để người học đọc rồi chạy.
- Trước mọi lệnh ghi, người học chạy `aws sts get-caller-identity` (hoặc `gcloud config list`) với cùng profile/project, hai bên cùng
  kiểm tra đúng account.
- Mỗi buổi cloud kết thúc bằng lệnh destroy và lệnh quét tài nguyên sót; AI nhắc cho tới khi người học xác nhận đã chạy cả hai.
  Budget alert bật từ ngày đầu ở cả hai cloud.
- **Không đăng nhập GHCR hay Sigstore từ máy:** push GHCR, ký, attest chỉ chạy trong CI; bước promote stg, prd chỉ chạy trong CI
  (token GitHub App), guard của chúng thử bằng `deploy/ci/promote-test.sh`.
- `verify.yml` chỉ dispatch và đọc kết quả khi người học giao ([`docs/reference/ci.md`](docs/reference/ci.md)).

## Lệnh kiểm

Mọi lệnh chạy từ gốc repo (hay worktree của nó) qua `Makefile`; `make help` liệt kê target. Chi tiết từng lệnh ở `docs/reference/`.

- `make tools`: cài một lần các công cụ ghim version; `buf`, Helm cài bằng Homebrew.
- `make check` (= `make check-go`): gofmt, go vet, golangci-lint (gosec), actionlint, `buf lint` + `buf build`, `make vulncheck`,
  `go test -race ./...` trên Postgres, Redis native. Thu hẹp: `make test PKGS=./services/<svc>/...`; như CI: `TESTFLAGS=-count=1`.
- `buf breaking --against '.git#branch=main'` khi sửa `proto/`.
- `make generate` sau khi sửa `proto/` hay SQL của sqlc (code sinh được commit); `make generate-check` kiểm không lệch.
- `make api-contract-check`: luật version của hợp đồng REST `services/gateway/openapi.yaml`.
- `deploy/ci/scan-gate.sh --check-ignorefile`: luật của `.trivyignore.yaml`, `.grype.yaml` (mỗi rule grype ứng một mục còn hạn của file trivy) và `deploy/ci/trivy-config-ignore.yaml`; `make grype IMAGE=<ref>@sha256:<digest>`: cổng grype của một chân image ([ADR-0039](docs/adr/0039-mainpath-drills-scan-gate-sourcemaps.md) §2).
- `make zizmor`: lint bảo mật workflow (zizmor ghim; audit online khi có `GH_TOKEN`); ngoại lệ ở `.github/zizmor.yml`
  ([ADR-0041](docs/adr/0041-github-hardening.md) (g)).
- `make helm-check`: lint, render mọi chart với `base/`, overlay của bản clone `svp-gitops` và policy Kyverno CLI.
- `make compose-config`, `make otelcol-validate`, `make slo-check`, `make k6-check`, `make kyverno-test`, `make cloud-check`: kiểm
  cấu hình tĩnh khi sửa phần tương ứng.
- `make env`, `make up [OBS=lgtm]`, `make smoke`, `make down`: dựng stack compose local và chạy luồng đầu-cuối.
- `make hooks`: bật hook `pre-commit` (gofmt, golangci-lint, buf lint, gitleaks) một lần mỗi clone.

## Tra cứu

| File | Nội dung |
| --- | --- |
| [`docs/reference/make.md`](docs/reference/make.md) | Lệnh của code: proto, Go, vulncheck, fuzz, hợp đồng REST, target web, hook |
| [`docs/reference/environment.md`](docs/reference/environment.md) | `.env`, quy tắc đọc `.env`, biến và hành vi khởi động của service |
| [`docs/reference/compose.md`](docs/reference/compose.md) | Stack compose, `OBS`, `IMAGES`, `WEB_FROM`, diễn tập, k6, DAST, game day |
| [`docs/reference/k8s.md`](docs/reference/k8s.md) | Cluster k3d, Kyverno và nguồn phát hành, đường GitOps, diễn tập trên cluster, `cloud-check` |
| [`docs/reference/eks.md`](docs/reference/eks.md) | Target `eks-*` và lớp nền tảng của `svp-gitops` |
| [`docs/reference/ci.md`](docs/reference/ci.md) | Workflow GitHub Actions, check của `svp-gitops`, file ignore, Renovate, chạy lại job trên máy |
| [`docs/reference/testing.md`](docs/reference/testing.md) | Quy ước test |
| [`docs/ci-cd.md`](docs/ci-cd.md) | Đọc một lượt chạy CI: job nào chạy khi nào, vì sao skip |
