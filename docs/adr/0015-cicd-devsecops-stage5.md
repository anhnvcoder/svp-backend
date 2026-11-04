# 0015. CI/CD và chuỗi cung ứng image: GitHub Actions ghim SHA, image đa kiến trúc trên GHCR, trivy chặn trước push, SBOM syft, ký keyless cosign, Kyverno chỉ nhận image đã ký và sạch, promote bằng PR GitOps, Renovate

- Trạng thái: Chấp nhận
- Ngày: 2026-10-20
- Người quyết: người học (duyệt đề xuất của ADR này)

## Bối cảnh và vấn đề

- Cần GitHub Actions chỉ build service có thay đổi; image đa kiến trúc lên GHCR; quét bằng trivy, gosec, gitleaks; SBOM syft, ký cosign; Kyverno chỉ cho chạy image đã ký và đạt policy cơ bản; Renovate; đánh version; promote image qua pull request GitOps. **Xong khi** cluster từ chối image chưa ký hoặc có lỗ hổng nghiêm trọng. Threat model ([mục 5](../appendix/threat-model.md#tổng-hợp-theo-giai-đoạn-mục-5-cũ)): FF-8, SC-1, SC-2, SEC-1, SEC-2, JWT-10.
- Repo `anhnvcoder/short-video-platform` **public từ 2026-10-20**: runner chuẩn không tính phút, runner Linux arm64 dùng được, package GHCR public không tính dung lượng, tab Security nhận SARIF. Cái giá: mọi thứ được commit, mọi log, artifact, package ai cũng đọc được; PR từ fork chạy workflow của repo.
- Trước ADR: `make check` chỉ chạy trên máy; image phát hành build trên máy bằng `make k8s-release`, tag 12 hex của SHA commit, nằm trong registry k3d và mất cùng cluster ([ADR-0014](0014-kubernetes-local-stage4.md) §6, §12); image bên thứ ba và base image theo tag; version công cụ cập nhật tay.
- Ràng buộc RAM: đường GitOps nghỉ 7,03 GiB, đỉnh 8,10 GiB, ngưỡng đỉnh 8,7 GiB (ADR-0014 §2). trivy, syft, cosign, CLI Kyverno không cài vào máy: chạy bằng image ghim digest qua `docker run` trong `Makefile`. Số liệu tra ngày 2026-10-20; giả định chỉ kiểm được khi chạy thật ở mục Xác nhận.

## Yếu tố quyết định

- Action hay công cụ bị chiếm không đọc được secret của CI (SC-2); image chạy được truy về workflow và commit (SC-1).
- Repo public: PR fork không có quyền ghi hay secret; bí mật đã lên package public không thu hồi được.
- Cùng một tham chiếu công cụ ở máy dev và CI (image ghim digest); không thêm action bên thứ ba.
- Repo một người, máy 16 GB, runner miễn phí; `ci.yml` và `images.yml` mỗi cái dưới 10 phút.

## Phương án đã cân nhắc

- §1 một workflow chung: loại, vì token ghi hay secret rơi vào code chưa ai đọc
- §1 một workflow mỗi service (`paths:` làm check treo): loại, vì token ghi hay secret rơi vào code chưa ai đọc
- §1 action theo tag: loại, vì token ghi hay secret rơi vào code chưa ai đọc
- §1 lockfile workflow: loại, vì token ghi hay secret rơi vào code chưa ai đọc
- §1 action tiện ích bên thứ ba: loại, vì token ghi hay secret rơi vào code chưa ai đọc
- §1 `pull_request_target`: loại, vì token ghi hay secret rơi vào code chưa ai đọc
- §1 một job build chung `packages: write`: loại, vì token ghi hay secret rơi vào code chưa ai đọc
- §1 trivy/syft bằng action: loại, vì token ghi hay secret rơi vào code chưa ai đọc
- §1 trivy/syft tải release: loại, vì token ghi hay secret rơi vào code chưa ai đọc
- §2 một job tuần tự: loại
- §2 Postgres/Redis cài bằng `apt`: loại
- §2 gosec cài riêng: loại
- §2 `make generate` rồi `git diff`: loại
- §2 **nhiều job song song + job tổng**
- §3 `go list -deps`: loại
- §3 action lọc đường dẫn: loại
- §3 `paths:`: loại
- §3 base `github.event.before`: loại
- §3 `queue: max`: loại
- §3 **`image_paths` + lần thành công cuối**
- §4 QEMU: loại
- §4 cross-compile trong Dockerfile: loại
- §4 push rồi quét: loại
- §4 build hai lần: loại
- §4 OCI layout + `skopeo`: loại
- §4 **build native, `--load`, quét tar, so config digest**
- §5 semver theo service: loại
- §5 semver chung cả repo: loại
- §5 `latest`: loại
- §5 tag theo nhánh: loại
- §5 **12 hex SHA, triển khai theo digest**
- §6 chặn cả HIGH: loại
- §6 `--ignore-unfixed`: loại
- §6 `.trivyignore` dạng chữ: loại
- §6 **chặn CRITICAL và mọi bí mật, `.trivyignore.yaml` có lý do và hạn**
- §7 khoá cosign (KMS, file): loại
- §7 Notation: loại
- §7 ký theo tag: loại
- §7 quét index một lần: loại
- §7 SBOM gộp: loại
- §7 bundle mới: loại
- §7 **keyless định dạng cũ, `--replace`**
- §8 `ClusterPolicy` `verifyImages` (deprecated): loại
- §8 webhook mọi namespace: loại
- §8 kiểm chữ ký nhà cung cấp: loại
- §8 ký cả image dev: loại
- §8 **`ImageValidatingPolicy`**
- §9 ghi thẳng `main`: loại
- §9 Argo CD Image Updater: loại
- §9 một PR mỗi lượt build: loại
- §9 `workflow_dispatch` cho PR bot: loại
- §9 token App riêng: loại
- §9 **một PR cuộn người học merge**
- §10 Renovate self-hosted (`GITHUB_TOKEN`, PAT): loại
- §10 Dependabot: loại
- §10 automerge: loại
- §10 **App Mend Renovate, không automerge ở thời điểm quyết**
- §11 branch protection cổ điển: loại
- §11 không bảo vệ: loại
- §11 bắt 1 approval: loại
- §11 **ruleset 0 approval, bắt PR và check**

Bảng ưu nhược từng phương án: [phụ lục](appendix/0015-cicd-devsecops-stage5.md) (mục "Các lựa chọn" của mỗi §).

## Kết quả quyết định

Chọn một chuỗi từ commit tới pod, mỗi mắt xích kiểm được: ghim SHA và quyền theo job, build native và chỉ push đúng thứ đã quét, ký keyless theo digest index,
Kyverno kiểm chữ ký và attestation `vuln` ở admission, promote qua PR cuộn. Chi tiết từng § (điều kiện, lệnh, bảng version và digest) ở [phụ lục](appendix/0015-cicd-devsecops-stage5.md); dòng chi tiết rút khỏi các § ở [mục "Chi tiết rút khỏi ADR"](appendix/0015-cicd-devsecops-stage5.md#chi-tiết-rút-khỏi-adr).

### 1. Hai workflow, action ghim SHA, quyền tối thiểu (SC-2)

- Hai file `.github/workflows/ci.yml` và `images.yml`, mỗi file một check tổng (`ci-ok`, `images-ok`, hai check bắt buộc, §11); không workflow nào có `paths:` ở trigger.
- Không `pull_request_target`, không `workflow_run`. `permissions: {}` ở đầu mỗi file, mỗi job khai đúng quyền cần; **mọi job của lượt `pull_request` chỉ `contents: read`**. Job cần quyền ghi (`packages`, `id-token`, `security-events`, `contents`, `pull-requests`) hay `actions: read` là job riêng có `if:` khác `pull_request` và `github.ref == 'refs/heads/main'`; đường PR và đường `main` của build là hai job gọi chung một script (§4).
- Action ghim SHA commit đầy đủ kèm comment tag; chỉ action của GitHub và `sigstore/cosign-installer` (`cosign-release: v3.1.3`); không action tiện ích bên thứ ba.
- trivy 0.76.0, syft v1.54.1, cosign v3.1.3: image ghim digest (`TRIVY_IMAGE`, `SYFT_IMAGE`, `COSIGN_IMAGE`), `env -u DOCKER_DEFAULT_PLATFORM docker run`; mọi bản đã phát hành ít nhất 3 ngày. `make actionlint` (`ACTIONLINT_VERSION` v1.7.12) nằm trong `make check`. Runner `ubuntu-24.04`, `ubuntu-24.04-arm`, không `ubuntu-latest`.

### 2. `ci.yml`: đủ mục Kiểm tra của `CLAUDE.md`

- Job: `check` (`make check-go TESTFLAGS=-count=1 LINTFLAGS=…`, golangci-lint một lần kèm SARIF, gosec trong đó; Postgres `15.19`, Redis `8.8.3` là service container ghim digest map `127.0.0.1`; ffmpeg bằng `apt`; Go 1.27.2), `web`, `generate` (`make generate-check` trong bản sao tạm, không ghi working tree), `buf` (`buf breaking` so merge-base; push `main` so `github.event.before`), `config`, `gitleaks` (toàn lịch sử, `--redact`, phát hiện nào cũng đỏ), `trivy-config` (chỉ báo), `sarif` (chỉ trên `main`, chỉ job này có `security-events: write`).
- `ci-ok` `needs` bảy job kiểm, không gồm `sarif`; `if: always()`, đỏ khi job nào khác `success`, kể cả `skipped`. Contract chung của `ci-ok`, `images-ok`: `failure`, `cancelled` luôn đỏ; `skipped` chỉ nhận cho job trong bảng "bỏ qua hợp lệ" (`ci.yml`: không job nào; `images.yml`: bảng §4) khi job tổng tự tính lại điều kiện thấy đúng.

### 3. Chỉ build service có thay đổi

- Tập đường dẫn một image là `image_paths <svc>` của `deploy/k8s/lib.sh`; `deploy/ci/changed-services.sh <base> <head>` dùng đúng nó. Đổi `.github/workflows/images.yml`, bất cứ gì dưới `deploy/ci/`, `deploy/k8s/lib.sh`, hay dòng ghim `TRIVY_IMAGE`, `SYFT_IMAGE`, `COSIGN_IMAGE` của `Makefile` thì build lại cả sáu. Go test luôn toàn repo.
- Base của phép so: push `main` là `head_sha` của lượt `images.yml` push `main` thành công gần nhất (job `last-success`, `actions: read`); là tổ tiên của HEAD thì so `head_sha..HEAD`, HEAD là tổ tiên thật sự thì không build gì, không có hay không so được thì cả sáu. PR: merge-base với nhánh base. `workflow_dispatch`: merge-base với `origin/main`, input `services` ghi đè.

### 4. Image đa kiến trúc, build native, chỉ push đúng thứ đã quét

- Ma trận `service × arch`: `amd64` trên `ubuntu-24.04`, `arm64` trên `ubuntu-24.04-arm`. `build-nopush` (PR, `contents: read`) và `build` (chỉ `main`, `packages: write`) gọi chung `deploy/ci/build-image.sh`: `docker buildx build --load --provenance=false --sbom=false`, `docker save` ra tar, trivy và syft quét chính tar, `deploy/ci/scan-gate.sh`; chỉ khi đạt, `build` `docker push` `<12 hex>-<arch>`, đọc manifest trên GHCR và so `.config.digest` với `Metadata.ImageID` đã quét (lệch thì đỏ); ghi artifact của chân. Không bước nào đẩy gì lên GHCR trước bước push.
- Job `merge` (`packages: write`) ghép index bằng `docker buildx imagetools create` từ đúng hai digest con, kiểm đúng hai manifest `linux/amd64`, `linux/arm64`; digest index là thứ được ký, attest, promote. Manifest con đã push mà chưa ký bị Kyverno từ chối.
- Base image ghim `tag@sha256:<index>` (`golang:1.27.2-trixie`, `gcr.io/distroless/static-debian13:nonroot`, `alpine:3.24.2`); gói `ffmpeg` Alpine không ghim version; không dòng `# syntax=`. Login GHCR chỉ ở job có `packages: write`, bằng `docker login` với `GITHUB_TOKEN` qua `env:`. Bảng job và quyền của `images.yml` (contract của `images-ok`) ở phụ lục.

### 5. Tên, tag và version của image

- Tên `ghcr.io/anhnvcoder/short-video-platform/<svc>` cho 6 service và hai image diễn tập `drill-vulnerable`, `drill-unsigned`. Tag: index `<12 hex>`, manifest con `<12 hex>-amd64`, `<12 hex>-arm64`. Tag đổi được nên mọi chỗ triển khai trỏ **digest**.
- Version là 12 hex đầu SHA commit, không semver. Xem lại khi image có người tiêu thụ ngoài repo, hay nhiều môi trường cần ghi chú phát hành.

### 6. Quét lỗ hổng và bí mật, trước khi push

- Một lần quét mỗi kiến trúc trên tar: `trivy image --input <tar> --scanners vuln,secret --ignorefile .trivyignore.yaml --format json --output <report>`; `deploy/ci/scan-gate.sh` đọc báo cáo. **Bí mật:** bất kỳ phát hiện nào, mọi severity, thoát ≠ 0, không đường bỏ qua (ignorefile chỉ được khoá gốc `vulnerabilities`; không `--skip-files`, `--skip-dirs`, `--secret-config`). **Lỗ hổng:** `CRITICAL` sau ignorefile thoát ≠ 0, kể cả chưa có bản vá; HIGH và thấp hơn chỉ báo (SARIF, job summary). Thoát ≠ 0 thì không push, không ký, không attest.
- `.trivyignore.yaml` ở gốc, chỉ lỗ hổng: `id`, `statement`, `expired_at` (`yyyy-mm-dd`), phạm vi hẹp (`purls`, `paths`); hạn tối đa 30 ngày, thôi tác dụng 00:00 UTC; quy tắc của file kiểm ở mọi PR bằng `scan-gate.sh --check-ignorefile` ở job `config`.
- SARIF `trivy convert --format sarif --severity HIGH,CRITICAL`, category `trivy-image-<svc>-<arch>`, upload ở job `sarif` trên `main` và lượt rescan. Trivy DB chính, cache theo ngày; không tải được DB thì job đỏ. Quét image bỏ qua file nhị phân: gitleaks toàn lịch sử bắt bí mật ở mã nguồn (SEC-1, JWT-10). Xem lại khi HIGH có bản vá còn mở quá 30 ngày.

### 7. SBOM, chữ ký, attestation (SC-1)

- SBOM: syft đọc tar, `spdx-json`, một SPDX mỗi nền tảng, attest `--type spdxjson` trên **digest manifest con**; không SBOM trên index.
- cosign v3.1.3 **định dạng cũ** cho mọi lệnh ký và attest: `--new-bundle-format=false --use-signing-config=false`; `cosign sign` trên digest index; `cosign attest --replace --type vuln` trên digest index (lượt build và mỗi rescan), `--replace --type spdxjson` trên từng manifest con. Không trộn hai định dạng trên một digest.
- Identity: issuer `https://token.actions.githubusercontent.com`, subject `https://github.com/anhnvcoder/svp-backend/.github/workflows/images.yml@refs/heads/main`. `id-token: write` chỉ ở `sign`, `rescan` và job ký của image diễn tập.
- Predicate `vuln` cho index (`deploy/ci/vuln-predicate.sh`): `scanner.result.platforms` đúng hai phần tử `linux/amd64` rồi `linux/arm64`, mỗi phần tử có `digest` manifest con và toàn bộ báo cáo trivy; `metadata.scanFinishedOn` là lần quét cũ hơn; `predicateType` `https://cosign.sigstore.dev/attestation/vuln/v1`. Chỉ ký và attest khi cả hai nền tảng đạt cổng.
- Rescan hằng ngày (`schedule` cron `17 1 * * *` UTC, dispatch `rescan: true`, `deploy/ci/rescan.sh`): quét từng digest con từ GHCR bằng DB mới nhất, attest lại `vuln`; CRITICAL thì vẫn ghi kết quả thật và job đỏ. Digest vào `main` phải có attestation không quá 48 giờ (Kyverno nhận tới 72 giờ): `values-check`, kiểm của `gitops.sh`, rescan đọc cả PR cuộn.

### 8. Kyverno

- Một `ImageValidatingPolicy` cluster-scope `svp-images` ở chart `deploy/helm/svp-policy`: chỉ namespace `svp`, `pods` và `pods/ephemeralcontainers` (CREATE, UPDATE), không autogen, `mutateDigest: false`, `timeoutSeconds: 30`. GitOps: `Deny` + `failurePolicy: Fail`; dev: `Audit` + `Ignore` (cùng chart, `--set`).
- Thứ tự kiểm: (1) prefix `ghcr.io/anhnvcoder/short-video-platform/` + `@sha256:`; (2) chữ ký; (3) attestation `vuln`; (4) đủ hai nền tảng; (5) không CRITICAL; (6) tuổi `scanFinishedOn` ≤ `72h`.
- Kyverno lỗi hay không tới Sigstore, GHCR thì **đóng** trên GitOps. Scale về 0 hay gỡ Kyverno thì mở (Kyverno tự xoá webhook): chấp nhận, Argo CD self-heal trả `replicas` về 1.

### 9. Promote qua PR GitOps (thay `make k8s-release`)

- Job `promote` (`deploy/ci/promote.sh`, `main`, chế độ build): dựng lại nhánh bot `bot/promote` từ `origin/main`, ghi `image.repository`, `image.tag`, `image.digest` vào `deploy/k8s/values/services/<svc>.yaml`, mở hay cập nhật **một PR cuộn**; không bao giờ ghi lùi (chọn ứng viên có commit là hậu duệ). `git push --force-with-lease`; quyền `contents: write`, `pull-requests: write`, không `actions: write`.
- Cluster GitOps kéo image theo digest, ẩn danh; chart `svp-service` nhận `image.digest`; đường dev giữ registry k3d. Bỏ `make k8s-release`, `deploy/k8s/release.sh` và bước dựng lại image của `gitops.sh`; `gitops.sh` từ chối trước khi tạo cluster khi digest rỗng, repository lạ, manifest không đọc được ẩn danh hay attestation quá 48 giờ.

### 10. Renovate

- App Mend Renovate chỉ trên repo này; `renovate.json` phủ `gomod`, `dockerfile`, `github-actions` theo SHA và custom manager cho `Makefile`, `compose.mk`, `lib.sh`, `components.json`, `gitops.sh`, `k3d.yaml`, values; không đụng `deploy/k8s/values/services/` và `gen/`.

### 11. Bảo vệ `main` và cài đặt repo

- Ruleset `main` (`.github/rulesets/main.json`): `bypass_actors: []`; cấm xoá, cấm force push (`deletion`, `non_fast_forward`); `pull_request` với `required_approving_review_count: 0`; `required_status_checks` `ci-ok`, `images-ok` với `integration_id: 15368`, `strict_required_status_checks_policy: false`. Mọi thay đổi vào `main` qua PR, hoàn tác bằng PR revert.

### 12. Để giai đoạn sau

Chưa làm: đăng nhập AWS bằng OIDC và ECR, kiểm chữ ký nhà cung cấp image bên thứ ba, SLSA provenance, govulncheck, zizmor, DAST, webhook GitHub → Argo CD, chuyển sang bundle mới của cosign (khi Kyverno có #18049). Bảng lý do ở phụ lục.

### Hệ quả

- Tốt: mọi thay đổi vào `main` qua `ci-ok`, `images-ok`; image phát hành build trên runner sạch, nằm trên GHCR theo digest, có chữ ký keyless truy được về workflow và commit, SBOM mỗi nền tảng, kết quả quét hai kiến trúc làm mới hằng ngày; phát hành không còn chạy trên máy. Biện pháp cho FF-8, SC-1, SC-2, SEC-1, SEC-2, JWT-10.
- Xấu: mỗi phát hành thêm một PR promote phải duyệt và merge tay; phụ thuộc Sigstore công khai và GHCR (không tới được thì không phát hành, pod `svp` mới bị từ chối); Kyverno một replica `Fail` (chết thì không pod `svp` mới); `schedule` bị GitHub tắt sau 60 ngày không hoạt động thì attestation quá 72 giờ và pod mới bị từ chối; định dạng cũ của cosign dựa vào cờ deprecated; RAM thêm 0,13–0,16 GiB đo trên đường dev; Kyverno chạy ngoài dải test một minor.
- Xem lại khi: build CI một thay đổi nhỏ quá 10 phút; HIGH có bản vá mở quá 30 ngày; image có người tiêu thụ ngoài repo; Kyverno hỗ trợ Kubernetes 1.36 hay có #18049; cosign v4 ra; lên cluster cloud; RAM vượt ngưỡng ADR-0014 §2; runner Ubuntu 24.04 bị ngừng; có thêm người làm repo (1 approval, `strict_required_status_checks_policy`).

## Xác nhận

- Kiểm tĩnh và trên máy ngày 2026-10-20; kiểm sau push từ 2026-10-21 (PR #1 tới #6, hai cluster GitOps): 6 chân `arm64` xanh, config digest trên GHCR khớp `Metadata.ImageID`, mỗi image 1 chữ ký và 1 `vuln` trên index, `--replace` giữ 1 attestation sau hai rescan, `make drill-k8s-supplychain` đạt các ca nhận và từ chối, `ci.yml` 4,9–6,3 phút, `images.yml` một service 3,7 phút.
- Còn mở: lượt `schedule` đầu 2026-10-22; PR Renovate đổi SHA action; RAM cluster GitOps (số đo và tiêu chí (c) ở [ADR-0017](0017-gitops-capacity-media-worker-max2.md)).
- Bảng kiểm chứng đầy đủ: [phụ lục](appendix/0015-cicd-devsecops-stage5.md#kiểm-chứng-sau-phát-hành).

## Hiện thực ở

- Workflow, quyền, job của `ci.yml` (§1, §2): `.github/workflows/ci.yml`, `.github/workflows/images.yml`, target `check`, `generate-check` của `Makefile`.
- Chỉ build service đổi (§3): `deploy/ci/changed-services.sh`, `deploy/ci/last-success.sh`, `deploy/ci/plan.sh`.
- Image đa kiến trúc, quét trước khi push (§4–§6): `deploy/ci/build-image.sh`, `deploy/ci/push-image.sh`, `deploy/ci/merge-index.sh`, `deploy/ci/scan-gate.sh`, `deploy/ci/common.sh`, `deploy/docker/service.Dockerfile`, `deploy/docker/web.Dockerfile`, `.trivyignore.yaml`, image diễn tập `deploy/ci/drill/vulnerable.Dockerfile`.
- SBOM, chữ ký, attestation, rescan (§7): `deploy/ci/sign-image.sh`, `deploy/ci/vuln-predicate.sh`, `deploy/ci/rescan.sh`, `deploy/ci/verify-release.sh`.
- Kyverno (§8): `deploy/helm/svp-policy/` (`templates/imagevalidatingpolicy.yaml`, `values.yaml`), `deploy/k8s/values/kyverno.yaml`, namespace và NetworkPolicy của Kyverno ở `deploy/helm/svp-cluster/` (`values.yaml`, `templates/networkpolicies.yaml`), cách cài Audit/Enforce ở `deploy/k8s/install.sh`, `deploy/k8s/lib.sh`; diễn tập `deploy/k8s/drills/supplychain.sh`, `deploy/k8s/drills/threats.sh`.
- Promote qua PR GitOps (§9): `deploy/ci/promote.sh`, `deploy/ci/values-check.sh`, `deploy/k8s/values/services/`, `deploy/k8s/gitops.sh`, `deploy/k8s/drills/gitops.sh`, `deploy/k8s/install.sh` (đường dev không đọc digest phát hành).
- Renovate và ghim digest (§10): `renovate.json`, `deploy/k8s/check-image-digests.sh`; dòng ghim `# renovate:` ở `Makefile`, `deploy/k8s/lib.sh`, `deploy/k8s/k8s.mk` và values bên thứ ba ở `deploy/k8s/values/` (`argo-cd.yaml`, `argo-rollouts.yaml`, `cert-manager.yaml`, `cloudnative-pg.yaml`, `envoy-gateway.yaml`, `keda.yaml`, `kube-prometheus-stack.yaml`, `kyverno.yaml`, `loki.yaml`, `otel-collector.yaml`, `plugin-barman-cloud.yaml`, `pyroscope.yaml`, `tempo.yaml`).
- Bảo vệ `main` (§11): ruleset `main` ở `github/rulesets.tf` của `svp-infra`.
- Hiện trạng: [`explanation/delivery.md`](../explanation/delivery.md), [`reference/ci.md`](../reference/ci.md), [`ci-cd.md`](../ci-cd.md), runbook [`vuln-attestation-expired.md`](../runbooks/vuln-attestation-expired.md), [`kyverno-down.md`](../runbooks/kyverno-down.md).

## Thông tin thêm

Phụ lục: [`appendix/0015-cicd-devsecops-stage5.md`](appendix/0015-cicd-devsecops-stage5.md) (dòng trạng thái gốc với mọi ghi chú có ngày, bối cảnh đầy đủ, bảng lựa chọn, bảng version, SHA và digest, bảng kiểm chứng trước và sau phát hành).

### Chỉnh bởi

- §2: [0016](0016-web-client.md): job `web`, job `check` chạy `make check-go`, `ci-ok` bảy job.
- §8: [0017](0017-gitops-capacity-media-worker-max2.md): thứ tự cắt RAM, thiếu tiêu chí (c) thì đi thẳng tới media-worker tối đa 2.
- §3–§9: [0019](0019-web-k3d-supply-chain-observability.md): image thứ bảy `web` (context `web/`, `image_paths`, build arg `SVP_BUILD_ID`).
- §1, §2, §6: [0021](0021-deferred-verification-stage6b.md): workflow thứ ba `verify.yml` (chỉ dispatch và lịch tuần, ngoài check bắt buộc); `trivy-config` bỏ qua có hạn ở `deploy/ci/trivy-config-ignore.yaml`; cổng CRITICAL `make web-lockfile-scan`; tệp bỏ qua thứ hai chỉ `misconfigurations`, hạn tối đa 90 ngày, `scan-gate.sh --check-ignorefile` kiểm cả hai tệp.
- §3: [0021](0021-deferred-verification-stage6b.md), [0023](0023-ci-platform-neutral.md): file của `deploy/ci/` không job image nào đọc không build lại image.
- §1, §4, §9: [0021](0021-deferred-verification-stage6b.md) (2026-10-28): job `gitops` có `actions: read`; artifact `web-sourcemaps-<arch>` của chân `web`; cluster GitOps đọc repo qua HTTPS ẩn danh.
- §8, §9: [0024](0024-multi-environment.md): cluster GitOps đóng vai stg; Enforce trên stg và prd, Audit trên dev.
- §3, §6, §12: [0030](0030-devsecops-supplement.md): dòng `GRYPE_IMAGE` build lại cả bảy image; grype quét SBOM syft trước push cạnh trivy; govulncheck và DAST thôi để sau.
- §7, §8: [0027](0027-slsa-build-provenance.md): SLSA provenance `slsaprovenance1` trên digest index ở job `sign`; phép kiểm provenance khi bật trên đường GitOps.
- §7, §9, §10, §11: [0024](0024-multi-environment.md), [0025](0025-gitops-config-repo.md) (2026-10-30): rescan đọc `envs/*/images/` của `svp-gitops`; promote sang `svp-gitops` bằng token GitHub App, stg auto-merge, prd qua PR có duyệt, bỏ `values-check`; Renovate hai repo; ruleset, CODEOWNERS của `svp-gitops`.
- §3, §7, §9: [0033](0033-svp-web-repo.md) (2026-10-31): repo code build sáu image, job `contract`, rescan và promote theo nguồn.
- §10: [0035](0035-renovate-automerge.md): bản `patch`, `digest` tự merge.
- §6: [0039](0039-mainpath-drills-scan-gate-sourcemaps.md): bị thay một phần, cổng `scan-gate.sh` thay bằng cờ `--exit-code` của trivy, `--fail-on critical` của grype.
- §11: [0041](0041-github-hardening.md): chỉ squash, lịch sử thẳng, `CODEOWNERS` với ruleset `owners`, `can_approve_pull_request_reviews` tắt.
