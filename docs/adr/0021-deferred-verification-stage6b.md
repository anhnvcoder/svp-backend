# 0021. Kiểm chứng dồn chạy trên runner GitHub Actions `ubuntu-24.04` bằng workflow `verify.yml` chạy tay và theo lịch tuần, mỗi lượt một kịch bản; Argo CD đọc repo qua HTTPS ẩn danh

- Trạng thái: Chấp nhận
- Ngày: 2026-10-24
- Người quyết: người học (nơi chạy A/B, lịch hằng tuần); các quyết định còn lại theo đề xuất của ADR này

## Bối cảnh và vấn đề

- Mọi dòng "kiểm sau" hay "dời" của [ADR-0017](0017-gitops-capacity-media-worker-max2.md), [ADR-0019](0019-web-k3d-supply-chain-observability.md),
  [ADR-0020](0020-reliability-stage6.md) mà máy 16 GB không chạy nổi (hai media-worker cùng transcode, RAM nghỉ (b) của đường GitOps, image `web` đã ký trên
  cluster GitOps, k6 tải lớn, Chaos Mesh, Velero, thay object store, ngưỡng page `RateLimitFallbackActive`, LCP) cần nơi chạy không tốn tiền, môi trường
  sạch, lặp lại được, không chạm tài khoản AWS/GCP. **Xong khi** mỗi dòng có kết quả đo hay lý do còn lại. Người học chốt: **(A)** runner chuẩn của repo public là
  mặc định, **(B)** VM thuê theo giờ chỉ khi A thật sự không đủ.
- Ràng buộc: repo công khai nên log và artifact của mọi lượt ai cũng đọc, kể cả khi job đỏ; `workflow_dispatch` chỉ chạy khi file có trên nhánh mặc định; máy 16 GB
  chỉ kiểm tĩnh. Hiện trạng: job `stack` của `ci.yml` đã dựng compose `core` trên `ubuntu-24.04`, chưa job nào dựng k3d; script k3d viết cho macOS; `run.sh`,
  `drill-restore.sh` từ chối `k3d-*`; Argo CD đọc repo bằng deploy key SSH; `RateLimitFallbackActive` cháy giả dưới tải; `trivy-config` chưa có đường bỏ qua có hạn;
  lockfile npm chưa có cổng. Bảng kiểm chứng ngày 2026-10-24 và bản đồ dòng dời ở [phụ lục](appendix/0021-deferred-verification-stage6b.md).

## Yếu tố quyết định

- Miễn phí, mỗi lượt một VM sạch; lượt đỏ tách được lỗi code với giới hạn runner (tiêu chí "runner đủ" đo được); không secret, log và artifact công khai nên lọc fail-closed;
  dùng đúng target `make` sẵn có; số đo so với ngân sách và ngưỡng, không thay số của máy.

## Phương án đã cân nhắc

- Nơi chạy: **A runner chuẩn** (chọn)
- Nơi chạy: B VM thuê theo giờ (khi A trượt hai lượt)
- Nơi chạy: runner lớn (cần gói trả phí): loại
- Nơi chạy: self-hosted trên máy (máy 16 GB là thứ thiếu, chạy code của ref dispatch): loại
- Workflow: job trong `ci.yml`: loại
- Workflow: environment bảo vệ cho mọi job: loại
- Workflow: matrix: loại
- Workflow: **workflow thứ ba `workflow_dispatch` cộng lịch tuần, mỗi kịch bản một lượt**: chọn
- Artifact: không artifact: loại
- Artifact: tải mọi thứ: loại
- Artifact: mã hoá bằng khoá của người học: loại
- Artifact: **danh sách cho phép, quét theo giá trị và mẫu, file nghi thì bỏ**: chọn
- Argo CD đọc repo: deploy key trong environment: loại
- Argo CD đọc repo: token GitHub App: loại
- Argo CD đọc repo: **HTTPS ẩn danh**
- Velero: Kopia node-agent: loại
- Velero: chỉ resource: loại
- Velero: object store thứ hai: loại
- Velero: **CSI hostpath, phạm vi Redpanda**
- k6: ngoài cluster: loại
- k6: một tốc độ cố định: loại
- k6: **Job Indexed, số pod là mức tải**
- Misconfig: vào `.trivyignore.yaml`: loại
- Misconfig: comment tại chỗ: loại
- Misconfig: dismiss: loại
- Misconfig: **tệp riêng**
- Lockfile: Renovate: loại
- Lockfile: `pnpm audit`: loại
- Lockfile: **trivy `fs`**
- Page rate limit: giữ rule: loại
- Page rate limit: chỉ thêm `for`: loại
- Page rate limit: nâng hạn 50 ms: loại
- Page rate limit: **tỷ lệ dự phòng theo instance**

Phân tích từng phương án ở phụ lục.

## Tên chốt

Code, cấu hình và tài liệu dùng đúng các tên này; đổi tên nào thì sửa ADR này trước. Bảng đầy đủ ở phụ lục.

- Workflow `.github/workflows/verify.yml` (`name: verify`), input `scenario` (`compose-obs`, `dev-k3d`, `gitops`, `web-canary`, `k6-cloud-mini`, `chaos`, `velero`) và `targets` (rỗng là mọi bước; vào `verify-run.sh` qua `SVP_VERIFY_TARGETS`); job `compose`, `k3d`, `gitops`, `record-stg`; runner `ubuntu-24.04` (amd64); `concurrency` group `verify-<kịch bản>` (lịch: `verify-schedule`), `cancel-in-progress: false`.
- Script `deploy/ci/verify-host.sh`, `verify-run.sh <kịch bản>`, `verify/<kịch bản>.sh`, `verify-sample.sh`, `verify-mask.sh env|cluster`, `verify-collect.sh`; kết quả ở `$RUNNER_TEMP/verify/` (`SVP_VERIFY_OUT`); artifact `verify-<kịch bản>`, `retention-days: 30`; `/etc/hosts`: `127.0.0.1 svp.localhost api.svp.localhost s3.svp.localhost`.
- Chặn tai nạn: `ci_hosted_runner` của `deploy/ci/platform.sh` (chế độ `github`) mở `run.sh`, `drill-restore.sh` trên `k3d-svp`; phủ chỉ cho runner ở `deploy/k8s/cloud/runner/` (`csi/`, `velero/`, `chaos-mesh/`); Velero: bucket `velero`, user `svp-velero`, Secret `velero/velero-s3`, `SVP_K8S_RUNNER_CSI=1`.
- CI: `deploy/ci/trivy-config-ignore.yaml`, `make web-lockfile-scan`; cảnh báo `RateLimitFallbackActive` (page), `RateLimitFallbackElevated` (ticket).

## Kết quả quyết định

Chọn các phương án in đậm ở "Phương án đã cân nhắc" và triển khai theo §1–§12: runner chuẩn `ubuntu-24.04` chạy workflow `verify.yml` mỗi kịch bản một lượt, artifact qua danh sách cho phép, Argo CD đọc repo qua HTTPS ẩn danh.

### 1. Nơi chạy và loại runner

- **A cho mọi kịch bản.** B chỉ cho một dòng khi kịch bản của nó trượt tiêu chí "runner đủ" (§2) **hai lượt liền vì tài nguyên** (lượt đầu trượt chạy lại một lần trước), ghi lý do vào Kết quả.
- **Runner `ubuntu-24.04` amd64**, ghi rõ label, không `ubuntu-latest`: công cụ CI ghim cho amd64, job `stack` đã chứng minh compose và Playwright, image phát hành là index đa kiến trúc nên cluster GitOps kéo chân amd64 của đúng digest đã ký. Số đo là số amd64, không thay số của máy.
- Ngoại lệ arm64: RAM nghỉ (b) đo trên amd64 trong ±0,3 GiB quanh 6,5 GiB thì chạy thêm một lượt `dev-k3d` trên `ubuntu-24.04-arm`; khi đó ghim thêm sha256 Helm linux-arm64 cạnh `HELM_LINUX_AMD64_SHA256` và cho `ci-tools` nhận `Linux aarch64`.
- B: Ubuntu 24.04 amd64, ít nhất 8 vCPU, 32 GB RAM, 100 GB SSD, nhà cung cấp do người học chọn; người học cài công cụ như bước setup của `verify.yml`, chạy `deploy/ci/verify-run.sh <kịch bản>` rồi `verify-collect.sh`, chép thư mục đã lọc về, xoá VM trong ngày, ghi chi phí vào Kết quả. AI soạn lệnh, không chạy lệnh chạm nhà cung cấp.

### 2. Tiêu chí "runner đủ": đĩa, RAM, CPU, thời gian

- **Đĩa** (`verify-host.sh`, trước mọi target): cần trống ít nhất `need + 15% dung lượng + 2 GiB`, `need` là **16 GiB** cho `compose-obs`, **30 GiB** cho kịch bản k3d (sau lượt đầu: 1,25 × mức dùng cao nhất đo được). Thiếu thì xoá bộ công cụ cài sẵn không dùng (`/usr/local/lib/android`, `/usr/share/dotnet`, `/opt/ghc`, `/usr/local/.ghcup`, `/opt/hostedtoolcache/CodeQL`), vẫn thiếu thì dừng trước mọi build. Sampler ghi chỗ trống mỗi 30 s; dưới `15% + 1 GiB` thì `verify-run.sh` dừng ở target kế với lý do "disk".
- **RAM** theo ADR-0014 §2: tổng MEM USAGE `docker stats --no-stream` của `k3d-svp-*`, `k3d-svp-registry`, 6 mẫu cách 10 s lấy trung vị; nghỉ là 60 s sau khi mọi pod Ready, đỉnh là 6 mẫu liền khi đủ `maxReplicaCount` (2) worker cùng transcode (sampler đếm pod media-worker có tiến trình `ffmpeg` trong cgroup); thêm lần đo nghỉ cuối kịch bản. Máy runner: `MemAvailable`, swap, `OOMKilled`, dòng OOM của kernel.
- **"RAM (b)"** áp riêng từng đường ở điểm 60 s: MEM USAGE trừ `active_file` dưới 6,5 GiB và tổng pod không quá 4,7 GiB là đạt; trên 6,5 GiB thì cắt theo ADR-0014 §2 và ADR-0017 điểm 2 hay ghi nhận như (c), người học quyết. Chỉ `gitops` đóng "RAM (b)" của đường GitOps; `dev-k3d` chỉ kết luận cho đường dev.
- **CPU:** 4 vCPU không phải "node đủ CPU" của ADR-0020 §9: PASS là bằng chứng mạnh, FAIL (c) không nói gì về thiết kế và dòng đó sang B (VM 8 vCPU). Sampler ghi `/proc/stat` mỗi 5 s; không dùng PSI làm bằng chứng nghẽn.
- **Thời gian:** job `compose` 120 phút, `k3d` và `gitops` 330 phút; setup 20 phút, 25 phút cho bước gom sau cùng; bước kịch bản `compose` 75, `k3d` 285 phút (job `gitops`: bước kịch bản 175, `Waiting for a release on main` 115). Mỗi target `make` dưới `timeout` riêng, không quá mốc "bắt đầu job + hạn job − 25 phút".
- **"Runner đủ"** (mọi điều phải đạt): cổng đĩa; xong trong hạn; `MemAvailable` thấp nhất ≥ 2 GiB; không OOM; chỗ trống ≥ ngưỡng chạy. `compose-obs`: không container nào restart ngoài lần dựng lại chủ động. K3d: k3s server giữ `RestartCount` và `StartedAt`, không node `NotReady`, không `Evicted`, `EvictionThresholdMet`, `FreeDiskSpaceFailed`. `gitops` (KEDA): mỗi lượt `drill-k8s-keda` có ≥ 6 mẫu liền 2 worker cùng transcode. `k6-cloud-mini`, `chaos`: pod k6 không bị throttle CPU quá 5% chu kỳ.
- So với máy: đúng/sai của diễn tập so được; RAM so với ngân sách (6,5 / 8,7 GiB, 4,7 GiB pod); thời gian và độ trễ k6 không; LCP so với ngưỡng 2 500 ms kèm `benchmarkIndex`.

### 3. Workflow `verify.yml`

- **Workflow thứ ba, `workflow_dispatch` cộng lịch tuần**, tách khỏi `ci-ok`, `images-ok`; input `scenario`, `targets` vào script chỉ qua `env:` và `verify-run.sh` kiểm lại bằng `case`. Mỗi lượt đúng một kịch bản, mỗi nhóm một job (`compose`, `k3d`, `gitops`).
- **Lịch** `cron: "37 0 * * 6"` (00:37 UTC thứ Bảy), chạy `compose-obs`, `dev-k3d`, `gitops` song song, mọi bước, `SVP_VERIFY_SCHEDULED=true`. Lượt lịch **không chờ phát hành** (`wait-release`, `measure-gitops` in lý do rồi qua); ca (c), (l) của `drill-k8s-supplychain` quá tuổi tối đa của policy thì SKIP kèm `NOTE` (chỉ ở lượt lịch, `gitops_stale`), lượt dispatch giữ nguyên. Job dài nhất xong trước 06:17 UTC, trước `dora.yml` (09:17 UTC, [0028](0028-dora-metrics.md) §8).
- **`record-stg`** ghi bản ghi stg khi bước kịch bản của `gitops` xanh và `release-set.json` có trong artifact, chỉ trên `main`; `targets` bỏ một bước kiểm (trừ `wait-release`, `measure-gitops`) thì `release-set` `skipped`, không ghi.
- **Ref:** chỉ `refs/heads/main` hay `refs/heads/feat/stage6b-*` (lịch: chỉ `main`); chặn tai nạn, không phải ranh giới bảo mật. PR đưa `verify.yml` vào `main` merge trước lượt dispatch đầu; AI dispatch `gh workflow run verify.yml --ref <nhánh> -f scenario=<tên>` và đọc `gh run view`, `gh run download`; lượt kế của một kịch bản chỉ dispatch khi lượt trước xong.
- **Quyền:** `permissions: {}` đầu file; `compose`, `k3d` `contents: read`; `gitops` thêm `actions: read`, `pull-requests: read`; không secret, không environment, trừ `record-stg` (environment `promote`, token App chỉ `deployments` write trên `svp-gitops`, [0025](0025-gitops-config-repo.md) §6); `GH_TOKEN: ${{ github.token }}` chỉ ở bước gọi `gh`; action ghim SHA, `persist-credentials: false`, không `pull_request_target`, `workflow_run`.
- **`concurrency: { group: verify-${{ inputs.scenario || github.event_name }}, cancel-in-progress: false }`**: hai kịch bản chạy song song, cùng kịch bản tuần tự.
- **Dừng sớm và chọn bước:** bước dựng không `ok` thì mọi bước sau `skipped` (`infrastructure step failed`); `targets` rỗng là mọi bước, bước không chọn `skipped` (`not in targets`); tên lạ hay ký tự ngoài `a-z`, `0-9`, `-`, khoảng trắng thì `verify-run.sh` exit 2 trước khi dựng gì; bước đọc kết quả của bước khác phải được chọn cùng nó; lượt chọn bước không thay lượt đủ kịch bản.
- **Job `compose`** theo mẫu job `stack` (service container Postgres/Redis, `make ci-bridge-check`, Playwright Chromium; `verify-host.sh` đặt `kernel.apparmor_restrict_unprivileged_userns=0` để giữ sandbox của Chrome). **Job `k3d`, `gitops`:** không service container, `make tools ci-tools`, Playwright Chromium và WebKit, kubectl của image runner (dừng khi lệch quá một minor so với k3s 1.36), `verify-host.sh` ghi ba tên vào `/etc/hosts` và kiểm `getent ahosts` chỉ trả `127.0.0.1`.
- Không dọn gì ngoài runner (VM huỷ cùng job; kịch bản vẫn chạy lệnh gỡ của buổi cloud); lệnh chỉ có ở macOS đổi sang dạng chạy cả hai nơi; Docker Hub kéo ẩn danh, không token, gặp `429 Too Many Requests` thì ghi vào Kết quả.

### 4. Log và artifact công khai

- **Biện pháp chính:** script không in bí mật: không `set -x`, `env`/`printenv`, in `.env`, `docker compose config` thiếu `--quiet`, `kubectl get secret` ra stdout, `make logs`/`kubectl logs` của service vào log job (lỗi thì chỉ `make ps`, `make k8s-status`, `kubectl get events`).
- **Mask:** `verify-mask.sh env` sau `make env` và sau **mỗi** target: giá trị biến `.env` có tên kết thúc `PASSWORD`, `SECRET`, `SECRET_KEY`, `TOKEN`, `_KEY`, `_KEYS` hay `SENTRY_DSN`, dài ≥ 8; `verify-mask.sh cluster` cho Secret của `svp`, `svp-data`, `svp-obs`, `argocd`, `velero`.
- **Danh sách cho phép** (`verify-collect.sh`, mỗi file ≤ 5 MiB): log từng target đã lọc, JSON và bảng của `.k8s/drills/*.json`, `.k6/*/summary.json`, JSON `measure-*`, báo cáo Lighthouse đã lọc cookie, `error-context.md` của Playwright đỏ, mẫu sampler, bảng RAM, `make k8s-status`, `kubectl get events -A`, `df`. **Cấm:** `.env`, kubeconfig, `.k8s/ca.*`, `.k8s/helm/`, `.k8s/drills/threats-*.log`, trace, video, ảnh, HAR, báo cáo HTML của Playwright, `machine.json` của k6, thư mục ẩn, mọi log của service.
- **Dòng log:** bỏ bản ghi JSON (`"msg"`, `"level"`) và access log; đuôi 40 dòng của container hạ tầng bên thứ ba không Ready chỉ khi namespace nằm trong `log_tail_namespaces` (`svp-data` trừ Postgres của CloudNativePG, `svp-obs` trừ GlitchTip, `cnpg-system`, `keda`, `argo-rollouts`, `kyverno`, `cert-manager`); không bao giờ log của `svp`, `envoy-gateway-system`, `kube-system`, `argocd`.
- **Quét trước khi chép** (fail-closed): theo giá trị bí mật (thô và base64) và theo mẫu (JWT neo `header.payload.`, `svp_sid`, `Bearer` kèm dấu cách, `Set-Cookie`, khoá riêng PEM); khớp thì bỏ file và ghi `::warning::<đường dẫn>: <tên luật>`; không dựng được danh sách giá trị của cluster thì chỉ chép file do runner ghi. `files.txt` kê file chép và file bỏ; bước gom, lọc, tải chạy `if: always()`.

### 5. Chia phần và bản đồ dòng dời

- Phần 1: việc tĩnh (§9, §10, §11), `compose-obs`, `dev-k3d`; phần 2: object store thay MinIO ([0022](0022-local-object-store-minio-replacement.md)); phần 3: `gitops`, `web-canary`, `k6-cloud-mini`, `chaos`, `velero`; phần 4: tách `svp-gitops` ([0025](0025-gitops-config-repo.md)).
- Mỗi dòng dời có kịch bản và tiêu chí đạt viết trước (D1–D27, bảng ở phụ lục): D1 hai lượt `drill-k8s-keda N=9` PASS, mỗi lượt ≥ 6 mẫu liền 2 worker, đỉnh (a) dưới 8,7 GiB; D2 RAM (b) theo §2; D3, D4 cluster GitOps chạy `web` đã ký và Kyverno từ chối web chưa ký (ca (a)–(i) PASS); D5 source map của image CI map về `turbopack:///[project]/…`; D6, D14, D18 canary web (bản tốt promote, bản lỗi abort, mỗi client tải lại ≤ 2 lần, action 409 trên 10% thì mở ADR khoá Server Action); D11 mức k6 cao nhất đạt; D12 ba thí nghiệm Chaos Mesh; D13 Velero giữ offset; D16 `RateLimitFallbackActive`; D17 LCP median ≤ 2 500 ms; D26 `measure-gitops` exit 0, pod mới `restartCount` 0.
- Chuyển giai đoạn cloud (EKS) vì lý do kèm theo: k6 20 pod 1 250 req/s, version EKS và kernel AL2023, Pod Identity của Velero, "pod `svp` phục hồi qua Kyverno", e2e `upload_url` lạ origin (D27) ngoài phần 1.

### 6. Đường GitOps trên runner (hiện thực ở phần 3)

- **Argo CD đọc repo qua HTTPS ẩn danh trên cả runner và máy**, một URL (`repoURL` của `deploy/argocd/apps/values.yaml`, `sourceRepos` của AppProject `svp`, `repo_url` của `gitops.sh`); `gitops.sh` không tạo Secret repo, `make k8s-gitops-up` bỏ `ARGOCD_DEPLOY_KEY`; đường GitOps không cần secret nào. Chỉnh ADR-0014 §12.
- **Bản phát hành trong lúc cluster chạy:** trước dispatch `gitops`, một thay đổi không đổi hành vi của một service có Postgres đã merge, `images.yml` đã mở PR promote xanh, chưa merge; bước riêng `Waiting for a release on main` (`bash deploy/ci/verify/gitops.sh release`) đọc `git ls-remote origin refs/heads/main` mỗi 30 s, tối đa 90 phút; `main` đổi thì `make measure-gitops REV=<sha>` lặp tới khi exit khác 2 (tối đa 20 phút); `merged_at` của PR promote đọc bằng `gh api` (`GH_TOKEN` chỉ ở bước này). Hết 90 phút không có push thì bước FAIL "no release".
- **Ca web chưa ký:** `SUPPLYCHAIN_UNSIGNED` là digest manifest con `linux/amd64` của web đang phát hành (chữ ký gắn với digest index nên rule chữ ký phải từ chối); ca (c) cần `drill-vulnerable` có attestation dưới 72 giờ (`images.yml -f drill=true`).
- **Source map của image CI:** job build web của `images.yml` xuất artifact `web-sourcemaps-<arch>` kèm `image-digest` ở lượt phát hành; job `gitops` chọn lượt có `image-digest` bằng manifest con `linux/amd64` của digest web đang chạy, tải bằng `actions: read` rồi đẩy lên GlitchTip của cluster. Không lượt khớp: nhánh `feat/stage6b-*` ghi `skipped` kèm lý do (e2e không `SVP_E2E_GLITCHTIP=1`, `SVP_WEB_OBS_SKIP_ERRORS=<lý do>` bỏ riêng phép kiểm `errors`), trên `main` là FAIL.
- RAM và KEDA: nghỉ ở 60 s ngay sau `k8s-gitops-up`, hai lượt `drill-k8s-keda N=9`, nghỉ cuối kịch bản. Thời lượng: dựng 20–30 phút, diễn tập khoảng 90 phút.

### 7. Chaos Mesh và Velero trên k3d của runner (hiện thực ở phần 3)

- **Điều kiện mở:** `run.sh`, `drill-restore.sh` nhận `k3d-svp` chỉ khi `ci_hosted_runner` exit 0 và `uname -s` là `Linux`, kiểm trước mọi lệnh `kubectl`; script không tự đọc biến `GITHUB_*`. Chặn tai nạn cho máy 16 GB, không phải ranh giới bảo mật. Ở chế độ này `run.sh` thêm CA `.k8s/ca.crt`, origin `https://svp.localhost:8443`, request CPU 250m và limit 1 CPU cho pod k6.
- **Chaos Mesh:** chart ghim như ADR-0020 §7, phủ ở `deploy/k8s/cloud/runner/chaos-mesh/` (`chaosDaemon.runtime: containerd`, `socketPath: /run/k3s/containerd/containerd.sock`); namespace `chaos-mesh` PSA `privileged` chỉ trong job; `clusterScoped: false`; controller bỏ `remotecluster` và 14 `<kind>-remote-apply`; trước (b) có bản thử nạp `sch_netem` và NetworkChaos thử, không nạp được thì bản thử FAIL và (b) không chạy. **Mỗi thí nghiệm một lượt k6 riêng** ở một nửa mức cao nhất đạt (1 pod), cửa sổ ổn định 5 phút ngay trước lỗi, từ lúc Job chạy tới hết tải dưới 55 phút (token sống 1 giờ). Cuối kịch bản chạy lệnh gỡ của buổi cloud (`helm uninstall`, xoá namespace, xoá CRD `chaos-mesh.org`) và kiểm không còn gì.
- **Velero:** `make k8s-up` với Redpanda trên StorageClass của driver CSI hostpath (đè chỉ trong job), driver, snapshot CRD và controller ghim digest ở namespace PSA `privileged` riêng; VolumeSnapshotClass nhãn `velero.io/csi-volumesnapshot-class: "true"`, `deletionPolicy: Retain`; Velero 1.18.4, plugin AWS, BackupStorageLocation tới object store trong cluster (`s3Url` nội bộ, `s3ForcePathStyle`), Secret `velero/velero-s3`.
- **BAK-2:** bucket `velero`, user `svp-velero` chỉ bucket đó, không user service nào tới được; khoá sinh ngẫu nhiên trong job, mask ngay; backup `excludedResources: [secrets]` và `drill-restore.sh` dừng trước khi xoá nếu danh sách resource trong bucket có Secret; namespace `velero` không nằm trong backup; hết kịch bản `drill-restore.sh sweep` rồi gỡ Velero.
- **Phạm vi diễn tập:** chế độ chỉ cho k3d của runner: backup `svp-data` lọc theo nhãn Redpanda, chỉ xoá StatefulSet và PVC của Redpanda (không xoá namespace), bỏ bước Argo CD khi cluster không có; giả thuyết, bước 5 và RTO giữ như ADR-0020 §6.

### 8. k6 thu nhỏ, ngưỡng p99 canary, HPA và `resources` của web

- **Mức tải:** Job k6 profile `cloud` với 1, 2, 4, 8 pod (5%, 10%, 20%, 40% của 1 250 req/s; feed 50, 100, 200, 400 req/s), mỗi pod 12 user và đúng tốc độ mỗi pod của ADR-0020 §2; mỗi mức 2 phút lên, giữ 10 phút, 1 phút xuống; giữa hai mức xoá khoá `svp:gw:rl:register:*` ở Valkey db 10 (**LOCAL LAB ONLY**); dừng ở mức đầu tiên trượt; cần ≥ 30 video `READY`. **Tải lớn nhất nơi chạy chịu được** là mức cao nhất mà mọi threshold đạt, `dropped_iterations` 0 và runner đủ (§2).
- **`canaryLimits.p99Ms` của web:** biên bucket nhỏ nhất trong {250, 500, 1000, 2500} ms không nhỏ hơn 2 × `p99_E` (p99 upstream Envoy của cluster stable route `web` trong cửa sổ giữ của mức cao nhất đạt); kết quả 500 thì giữ nguyên; `web-canary` phải promote bản tốt với ngưỡng mới.
- **HPA web** khi CPU trung bình pod web ≥ 50% limit hay p99 k6 route web > 2 lần p99 ở 1 pod: `minReplicas: 2`, `maxReplicas: 4`, mục tiêu CPU 70% của request, request CPU bằng CPU trung bình mỗi pod ở mức 1 pod; không đủ điều kiện thì giữ 2 replica cố định.
- **`resources` của web:** limit bộ nhớ = max(384 Mi, làm tròn lên bội 64 Mi của 1,5 × working set cao nhất); request = làm tròn lên bội 32 Mi của trung vị nghỉ, tối thiểu 128 Mi; limit CPU 1, lên 2 khi throttle CFS > 5% ở mức cao nhất đạt. Phần 1 áp với số của `dev-k3d` (e2e), phần 3 áp lại với số k6 (chỉ tăng).

### 9. Bỏ qua có hạn cho cảnh báo `trivy-config` (chỉnh ADR-0015 §2, §6)

- Tệp riêng `deploy/ci/trivy-config-ignore.yaml`, chỉ khoá gốc `misconfigurations`; mỗi mục `id`, `paths` bắt buộc, `statement`, `expired_at` **tối đa 90 ngày** (misconfig chỉ đổi khi repo đổi, không có bản vá upstream). `make trivy-config` truyền `--ignorefile`; `scan-gate.sh --check-ignorefile` kiểm cả hai tệp ở job `config` của mọi PR; `trivy-config` vẫn chỉ báo. Chỉ lựa chọn có chủ đích mới vào tệp.

### 10. Cổng quét lỗ hổng `web/pnpm-lock.yaml`

- `make web-lockfile-scan`: `trivy fs --scanners vuln --include-dev-deps --format json` bằng `TRIVY_IMAGE` ghim, `--ignorefile .trivyignore.yaml`, `scan-gate.sh` quyết: **CRITICAL chặn**, HIGH trở xuống chỉ báo; chạy ở job `web` của `ci.yml`, SARIF `trivy-lockfile-web`; bỏ qua chỉ qua `.trivyignore.yaml` (`purls` `pkg:npm/...`, ≤ 30 ngày). Ca âm (lockfile có CRITICAL đã biết) phải làm target exit ≠ 0.

### 11. `RateLimitFallbackActive`: page khi Redis mất hẳn, không page khi quá hạn lẻ tẻ

- **`RateLimitFallbackActive` (page)** theo từng instance gateway trên `svp_ratelimit_decisions_total{service_name="gateway"}`, **`for: 1m`**, cháy khi một trong hai nhánh đúng: nhánh tăng, `increase(...{store="fallback"}[2m])` trên `increase(...[2m])` **≥ 0,5** và `increase(...{store="fallback"}[2m])` **≥ 3**; nhánh series mới sinh (`X unless X offset 2m`) cùng hai ngưỡng trên giá trị của chúng.
- **`RateLimitFallbackElevated` (ticket):** tỷ lệ dự phòng trong 30 phút ≥ 0,01 và ≥ 30 quyết định dự phòng. Quá hạn lẻ tẻ (khoảng 0,25%) không page, không ticket.
- Giữ RL-2: `drill-obs-threats` dựng lại gateway với Redis không tới được, ba login sai, đòi page trong Alertmanager **trong 240 s**. Test promtool (a)–(h) ở `svp-alerts.test.yaml`; runbook `docs/runbooks/rate-limit-fallback-active.md` theo điều kiện mới. Chỉnh ADR-0011 §8.

### 12. Threat model

- Thêm **SC-11** (workflow `verify.yml`, runner, log và artifact công khai, công cụ đặc quyền trên runner) và **SC-12** (Argo CD đọc repo qua HTTPS ẩn danh) ở mục 4.8 của [`docs/threat-model.md`](../threat-model.md); cập nhật **OPS-4**, **BAK-2**; dòng "kiểm khi chạy" cho phần chỉ kiểm được trên runner.

### Hệ quả

- Tốt: việc dời chạy được không cần cloud, không tốn tiền, trên môi trường sạch, bằng một lệnh dispatch; "runner đủ" đo được tách lỗi code với giới hạn runner; không secret ở job dựng và kiểm; script và manifest cloud được chạy thật một lần trước buổi tính tiền; cảnh báo misconfig có đường bỏ qua có hạn; page `RateLimitFallbackActive` chỉ khi Redis mất thật.
- Xấu: workflow thứ ba và các script `deploy/ci/verify-*.sh` phải giữ quy ước của ADR-0015; log và artifact công khai, bộ lọc không bắt giá trị đã biến đổi; số đo của runner là amd64, 4 vCPU, không thay số của máy; runner không phải "node đủ CPU" cho hai worker 2 CPU (D1 có thể sang B); Velero thử phạm vi hẹp hơn cloud, Chaos Mesh, Velero, driver CSI chạy đặc quyền trong cluster tạm; đường GitOps cần repo còn public; lượt lịch chạy dù không ai đọc; tuần nào `release-set` đỏ hay artifact `web-sourcemaps-amd64` hết hạn thì không có bản ghi stg.
- Xem lại khi: một dòng trượt tiêu chí runner hai lượt liền (chạy trên B); repo thành private hay GitHub giới hạn git ẩn danh (Argo CD quay lại deploy key); pull từ node k3d gặp 429 (xét token Docker Hub chỉ đọc, ghi vào ADR trước); `ubuntu-24.04` bị bỏ hay đổi (đo lại cổng đĩa và RAM); bộ lọc bỏ oan nhiều file (thu hẹp mẫu theo loại file); tiêu chí "runner đủ" của k6 chưa tách OOM của pod khỏi OOM của máy và chưa xét CPU máy; Tempo dưới tải, hai phát hiện của Chaos Mesh và tỷ lệ action 409 của canary web (ADR-0031, ADR-0019 §1).

## Xác nhận

- Kiểm trên runner, mỗi lượt có mã lượt chạy ở phụ lục: `compose-obs` (lượt 1–8), `dev-k3d` (lượt 1–10), `gitops`, `web-canary`, `k6-cloud-mini`, `chaos`, `velero`; mọi giả định của bảng "Kiểm chứng sau" có kết quả đạt hay ghi lý do.
- Kiểm tĩnh: `make slo-check` (promtool (a)–(h)), `make trivy-config` 18 → 0 kết quả, `make web-lockfile-scan` với ca âm, `deploy/ci/verify-collect-test.sh`.
- Không đạt, ghi số: RAM nghỉ cuối và đỉnh (a) của đường GitOps; mức k6 cao nhất đạt 2 pod; LCP của `/` chưa ổn định dưới 2 500 ms (chuẩn là RUM p75).
- Chưa kiểm, sau merge: lượt lịch đầu có job `gitops`, `record-stg` và bước chờ phát hành trên `main` của `svp-gitops`.

## Hiện thực ở

- Workflow, tiêu chí "runner đủ", bộ lọc (§2–§5): `.github/workflows/verify.yml`, `deploy/ci/verify-host.sh`, `verify-run.sh`, `verify-sample.sh`, `verify-mask.sh`, `verify-collect.sh`, `verify-collect-test.sh`, `deploy/ci/verify/<kịch bản>.sh`; `log_tail_namespaces`, `unready_report` của `deploy/k8s/lib.sh`; adapter `ci_hosted_runner` ở `deploy/ci/platform.sh` ([0023](0023-ci-platform-neutral.md)).
- Đường GitOps (§6): `deploy/argocd/apps/values.yaml`, `deploy/argocd/project.yaml`, `deploy/k8s/gitops.sh`, `deploy/ci/gitops-sourcemaps.sh`, `deploy/ci/build-image.sh`, `.github/workflows/images.yml`, `deploy/k8s/drills/{gitops,keda,supplychain,web-obs,web-canary}.sh`; từ phần 4 cấu hình ở repo `svp-gitops`, `deploy/ci/record-stg.sh`, `deploy/ci/release-set.sh`.
- Chaos Mesh, Velero, k6 (§7, §8): `deploy/k8s/cloud/runner/`, `deploy/k8s/cloud/chaos/`, `deploy/k8s/cloud/velero/drill-restore.sh`, `deploy/k6/cloud/{render,run}.sh`, `deploy/k8s/cloud/charts.json`.
- Cổng CI và cảnh báo (§9–§11): `deploy/ci/trivy-config-ignore.yaml`, `deploy/ci/scan-gate.sh`, `Makefile`, `deploy/observability/prometheus/rules/svp-alerts.yaml`, `svp-alerts.test.yaml`; cổng lockfile nay là `make lockfile-scan` của `svp-frontend`.
- Hiện trạng: [`reference/ci.md`](../reference/ci.md), [`explanation/delivery.md`](../explanation/delivery.md), [`explanation/reliability.md`](../explanation/reliability.md), runbook [`rate-limit-fallback-active.md`](../runbooks/rate-limit-fallback-active.md); danh sách file theo phần ở phụ lục.

## Nguồn

- Runner GitHub: <https://docs.github.com/en/actions/reference/runners/github-hosted-runners>; giới hạn: <https://docs.github.com/en/actions/reference/limits>
- Image runner: <https://github.com/actions/runner-images/blob/main/images/ubuntu/Ubuntu2404-Readme.md>; Docker Hub: <https://docs.docker.com/docker-hub/usage/pulls/>

## Thông tin thêm

Phụ lục: [`appendix/0021-deferred-verification-stage6b.md`](appendix/0021-deferred-verification-stage6b.md) (tiêu đề và dòng trạng thái gốc, phân tích phương án, bảng kiểm chứng, tên chốt, bản đồ D1–D27, bảng "Kiểm chứng sau", kết quả từng lượt chạy, hiện thực theo phần).

### Chỉnh bởi

- §7: [0022](0022-local-object-store-minio-replacement.md): đích object store của Velero và BAK-1 trong cluster đổi từ MinIO sang RustFS; Velero kiểm trên RustFS và đạt.
- §5: [0029](0029-immutable-media-versions.md): kịch bản `compose-obs` thêm `drill-duplicates`, `drill-kill-worker`, ba test integration của output bất biến.
- §6: [0026](0026-secrets-gitops.md), [0027](0027-slsa-build-provenance.md), 0029: kịch bản `gitops` thêm bước `gitops-external-secrets`, ca `l` của `drill-k8s-supplychain`, `k8s-smoke` với `SVP_SMOKE_LEGACY_MEDIA=1` tới khi media-worker phát hành ghi key có version.
- §3, §6: [0025](0025-gitops-config-repo.md), [0024](0024-multi-environment.md) §8: job `record-stg` có environment `promote`; Argo CD và kịch bản `gitops` đọc `svp-gitops`; bước chờ phát hành theo dõi `main` của `svp-gitops`.
- §5, §7: [0031](0031-chaos-findings-feed-engagement-tempo.md) §3: step `tempo-ingest-*` ở `k6-cloud-mini`, `chaos`; sampler lấy thêm `svp-obs` vào `pods.tsv`.
- §3, §6, §10: [0033](0033-svp-web-repo.md): mã web từ `make web-clone` (`web_ref`, `WEB_FROM=clone`), kéo image `web-sourcemaps`, cổng lockfile ở `svp-frontend`, job `stack` của `ci.yml`.
- §2, §3, §6, §7, §8: [0039](0039-mainpath-drills-scan-gate-sourcemaps.md): một phần bị thay: sampler `verify-sample.sh`; `verify.yml` còn `gitops` và `compose-obs` thu gọn (cả hai lịch tuần), bỏ job `k3d`, `web_ref`, clone `svp-frontend`; bỏ bước source map, e2e web, KEDA, RAM, chờ phát hành, `measure-gitops`; kịch bản `chaos`, `velero`, `k6-cloud-mini`, `web-canary` thành bài lab.
