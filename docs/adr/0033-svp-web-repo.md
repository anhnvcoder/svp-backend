# 0033. Web client tách sang repo `svp-web` với hợp đồng OpenAPI có version, nguồn phát hành và identity ký riêng, mọi nguồn khai ở một file của chart `svp-policy`

- Trạng thái: Chấp nhận
- Ngày: 2026-10-30

## Bối cảnh và vấn đề

- **Yêu cầu:** ba repo `short-video-platform` (trong ADR này gọi là **backend**), `svp-web`, `svp-gitops`; hợp đồng API (OpenAPI của gateway) có version, kiểm breaking ở PR backend, web sinh type từ bản đã phát hành; e2e của web kéo image backend theo digest; CI và promote riêng của repo web dùng lại cơ chế PR sang `svp-gitops` của [ADR-0025](0025-gitops-config-repo.md); Renovate, ruleset, adapter CI ở cả hai repo; dọn `web/` khỏi backend, giữ lịch sử.
- **Lý do thật của việc tách:** mô phỏng tổ chức có team FE và team BE riêng, mỗi team một repo, một pipeline, một nhịp phát hành, nói chuyện qua hợp đồng API. Hệ thống một người làm **không cần** tách (monorepo đổi API và web trong một PR); mọi cái giá ở bảng "Tách web so với monorepo" của phụ lục được trả để học cách vận hành ranh giới đó.
- **Đã chốt trước:** ba repo public ở tài khoản cá nhân; người học tạo `svp-web` và cấp quyền GitHub App; lịch sử chuyển bằng `git filter-repo`; workspace: `frontend/` là bản clone `svp-web` cạnh `backend/` và `gitops/`.
- **Hiện trạng** (backend `main` ở `ec12f11`): `web/` và `deploy/docker/web.Dockerfile` nằm ở backend; `web` là image thứ bảy ([ADR-0019](0019-web-k3d-supply-chain-observability.md) §1) của `images.yml`; một nguồn phát hành duy nhất (`ghcr_prefix`, `imagePrefix`, `issuer`, `subject`, `provenanceRepository`, `provenanceRef` của `deploy/helm/svp-policy/values.yaml`, [ADR-0023](0023-ci-platform-neutral.md) §4); `gitops-check.sh`, `promote.sh`, `rescan.sh`, `release-set.sh`, `dora.sh` đều giả định mọi image là `ghcr_prefix/<svc>` với tag là tổ tiên của `revision` ([ADR-0025](0025-gitops-config-repo.md) §2); `info.version` của `services/gateway/openapi.yaml` là `0.1.0` từ đầu, không luật nào bắt tăng.
- **Ràng buộc:** CI trung lập nền tảng (ADR-0023: YAML chỉ nối bước, logic ở script, API nền tảng qua hàm `ci_*`); action chỉ của GitHub và `sigstore/cosign-installer`, ghim SHA ([ADR-0015](0015-cicd-devsecops-stage5.md) §11); công cụ mới phải có lý do và người học chọn; repo public (không secret, id cài đặt App hay token, ADR chỉ ghi tên biến); một cluster lab mỗi lúc, máy 16 GB.
- Hiện trạng ngành (đọc 2026-10-30, nguồn [W1]–[W20]) và chi tiết hiện trạng code: phụ lục, mục "Bối cảnh".

## Yếu tố quyết định

- Ranh giới giữa hai team là hợp đồng có version và chữ ký, kiểm bằng máy.
- Mỗi nguồn phát hành có prefix, identity, credential riêng, nhưng khai ở **một** chỗ mà policy và script cùng đọc; lộ khoá hay identity của một repo không ký hay promote được image của repo kia.
- Logic CI vẫn một bản (ADR-0023); mọi thay đổi chart và nguồn đi stg trước prd như digest (ADR-0025 §2).
- Mỗi bước chuyển lùi được, không lúc nào cluster từ chối bản đang chạy; repo public, máy 16 GB.

## Phương án đã cân nhắc

- §1 **A. oasdiff (image ghim digest) kiểm breaking + OCI artifact bằng ORAS ký cosign + semver máy kiểm**.
- §1 openapi-changes: mới nổi, không phép kiểm version.
- §1 openapi-diff: README chỉ ghi 3.0, cần JVM.
- §1 Optic: đã archive.
- §1 tự viết so sánh.
- §1 image `FROM scratch`.
- §1 GitHub Release + `cosign sign-blob`.
- §1 npm trên GitHub Packages: cần token cả gói public.
- §1 không phát hành.
- §2 **A. image `ghcr.io/anhnvcoder/svp-web/web` + `sources.json` trong chart + một policy `svp-images` nhiều attestor**.
- §2 giữ prefix cũ: hai identity ký cùng đường.
- §2 danh sách trong `values.yaml`: cần parser YAML.
- §2 mỗi repo tự khai identity.
- §2 mỗi nguồn một policy.
- §2 một attestor nhiều identity.
- §3 **A. luật theo nguồn (backend giữ luật tổ tiên; nguồn khác: tag là commit trên `main` của repo nguồn)**.
- §3 luật tổ tiên cho cả web: không có quan hệ tổ tiên.
- §3 một luật "tag là commit trên `main` của repo nguồn" cho mọi image: mất phép "image không mới hơn chart".
- §4 **A. nhánh bot riêng `bot/promote-stg-web`, App thứ hai `svp-web-promoter`, mỗi repo rescan image của mình**.
- §4 dùng chung nhánh: hai workflow ghi đè nhau.
- §4 dùng chung App: một khoá, tác giả PR như nhau.
- §4 backend quét mọi digest: attestation `vuln` sai identity.
- §5 **A. `svp-web` checkout backend ở commit ghim và chạy `deploy/ci/*.sh`**.
- §5 chép script: lệch dần.
- §5 reusable workflow hay CI/CD component: identity ký thành workflow của backend, logic vào YAML.
- §5 repo thứ tư `svp-ci`.
- §6 **A. e2e của `svp-web` trên compose backend ở `revision` với sáu image stg theo digest; backend chạy e2e của web stg (chỉ báo)**.
- §6 k3d GitOps mỗi PR: nặng.
- §6 mock MSW: không bắt lệch hành vi.
- §6 không chạy e2e web ở backend.
- §7 **A. web mặc định là image stg theo digest, `WEB_FROM=clone` build từ bản clone; source map thành image `web-sourcemaps` kéo ẩn danh**.
- §7 luôn đòi bản clone.
- §7 luôn image stg.
- §7 artifact lượt chạy bằng `GITHUB_TOKEN`: tài liệu nghiêng về không được.
- §7 token App hay PAT đọc `actions`.
- §7 bỏ qua phép kiểm.
- §8 **A. `git filter-repo`** (`--path`, `--path-rename`).
- §8 `git subtree split`: Dockerfile ngoài `web/` không đi theo.
- §8 không giữ lịch sử.
- §9 **A. brownfield, mỗi bước lùi được**.
- §9 cắt một lần: lỗi chỉ lộ sau merge, không ai phát hành được web trong lúc chờ.

Phân tích được/mất từng phương án, bảng "Cần người học chọn" và "Tách web so với monorepo": [phụ lục](appendix/0033-svp-web-repo.md).

## Quyết định

Chọn 1A (oasdiff, OCI artifact bằng ORAS, semver), 2A, 3A, 4A, 5A, 6A, 7A, 8A, 9A, 10. Sáu điểm người học chọn (người học duyệt 2026-10-30, chọn (a) ở cả sáu): công cụ kiểm breaking, nơi phát hành hợp đồng, App thứ hai, đường image (§1, §2, §4) và cách dùng công cụ đã có (script CI chung §5, source map §7); các điểm còn lại theo đề xuất thiết kế.

### 1. Hợp đồng API

- Spec ở backend, `services/gateway/openapi.yaml`, là nguồn duy nhất. **Luật version** (semver của `info.version`, comment đầu file spec): **major** khi oasdiff thấy ít nhất một thay đổi mức `ERR`; **minor** khi không có `ERR` nhưng `oasdiff changelog` có mục; **patch** khi file đổi mà changelog rỗng. PR đổi spec (theo byte) mà `info.version` không lớn hơn của base, version giảm, có breaking mà major không tăng, hay changelog có mục mà chỉ tăng patch: đỏ. Ở `0.y.z` luật major không nói gì. Breaking đi theo expand/contract: thêm (minor), web chuyển sang, bỏ cái cũ (major) khi web của stg và prd đều không còn dùng.
- **Kiểm ở PR backend:** `deploy/ci/contract.sh check`, `make api-contract-check BASE=<ref>`, job `api-contract` của `ci.yml` (vào `ci-ok`); oasdiff chạy bằng `OASDIFF_IMAGE` ghim digest, `--network none`; không dùng GitHub Action của oasdiff.
- **Phát hành:** job `contract` của `images.yml`, `deploy/ci/contract.sh publish`, ở mọi lượt build trên `main`: `info.version` chưa là tag của `ghcr.io/anhnvcoder/short-video-platform/api/gateway` thì đẩy file bằng ORAS (`ORAS_IMAGE` ghim), tag `<version>`, `artifactType` `application/vnd.anhnvcoder.svp.api-contract.v1`, một layer `application/vnd.oai.openapi`, ký keyless digest bằng cosign (identity `images.yml@refs/heads/main` của backend). Tag đã có với cùng layer thì bỏ qua (thiếu chữ ký thì ký bù); khác thì đỏ, không ghi đè.
- **Ở `svp-web`:** file ghim `api/contract.json` (`repository`, `version`, `digest`); `make generate` kéo artifact theo digest, `cosign verify` với identity nguồn `backend` đọc từ `sources.json` ở `BACKEND_COMMIT`, rồi sinh `gen/api.d.ts`; spec không commit vào `svp-web`. Renovate nâng `version` và `digest` bằng custom manager datasource `docker`; không được thì `make contract-bump VERSION=<x>`.

### 2. Image và nguồn phát hành

- Image web `ghcr.io/anhnvcoder/svp-web/web`; source map `ghcr.io/anhnvcoder/svp-web/web-sourcemaps` (§7); identity ký: issuer `https://token.actions.githubusercontent.com`, subject `https://github.com/anhnvcoder/svp-web/.github/workflows/images.yml@refs/heads/main`.
- **Một chỗ:** `deploy/helm/svp-policy/files/sources.json` của backend: mỗi nguồn có `name`, `repository`, `imagePrefix`, `services`, `drillImages`, `issuer`, `subject`, `provenanceRef`, `promoter` (hai nguồn `backend` và `web`; ví dụ đầy đủ ở phụ lục). `web` trong `services` của `backend` là **nguồn cũ** của lúc chuyển (§9). Rời `values.yaml`: `imagePrefix`, `issuer`, `subject`, `provenanceRepository`, `provenanceRef`; ở lại: `mode`, `namespace`, `maxAttestationAge`, `requireProvenance`, `name`, `objectSelector`. Template từ chối: tên nguồn trùng; prefix không kết thúc `/` hay là tiền tố của prefix khác; giá trị có nháy, `\`, xuống dòng; một service ở hơn hai nguồn; `promoter` trùng; `ref` không bắt đầu `refs/`.
- **Policy `svp-images`** (giữ tên): `matchImageReferences` một glob mỗi tên được phát hành (`<prefix><tên>@*`, `<prefix><tên>:*`); `attestors` một mục mỗi nguồn; phép 1: mỗi image của pod là `<prefix><tên>@sha256:<64 hex>` với `<tên>` thuộc `services` hay `drillImages` của nguồn có prefix đó; phép 2–10: xác minh với attestor của nguồn có prefix của nó (CEL chọn theo `startsWith`), provenance so `subject`, `repository`, `provenanceRef` của nguồn. Identity `svp-web` không ký được image dưới prefix backend và ngược lại. Nếu Kyverno không chọn attestor được theo cách này, lùi về mỗi nguồn một policy.
- **Script:** `release_sources` của `deploy/k8s/lib.sh` đọc `sources.json` bằng `jq` theo revision, có đường lùi cho revision chưa có file (§3); `sign_identity`, `provenance_source`, `verify-release.sh`, `release_image` nhận service hay prefix và tra nguồn; `maxAttestationAge` ở lại `values.yaml`. Đổi identity của một nguồn: PR backend thêm identity mới bên cạnh, chờ stg và prd chạy chart đó, đổi workflow repo nguồn, rồi gỡ identity cũ.
- **Chuyển tiếp và gỡ nguồn cũ:** web nhận từ cả hai nguồn cho tới khi prd chạy web của `svp-web`; gỡ là PR backend bỏ `web` khỏi `services` của `backend` (PR-3, §9), chỉ mở khi `envs/prd/images/web.yaml` ở `main` của `svp-gitops` đã là bản của `svp-web`. Sau khi gỡ, rollback web về digest dưới `short-video-platform/web` bị Kyverno từ chối ở phép 1: phải revert PR-3 trước.

### 3. Luật của `svp-gitops`

- `gitops-check.sh` đọc `sources.json` ở `revision` của `envs/<env>/charts.yaml`, rồi với mỗi `envs/<env>/images/<svc>.yaml`: `repository` là `<imagePrefix><svc>` của nguồn có `<svc>` trong `services`; nguồn `backend`: `tag` là tổ tiên của `revision` như nay; nguồn khác: `tag` (12 hex) là commit trên `main` của `repository` của nguồn, đọc từ bản clone đủ lịch sử (`SVP_SOURCE_DIR_<TÊN>` nếu đặt, không thì clone ẩn danh `--filter=blob:none`), và khi env bật provenance `gitCommit` bằng tag, `workflow.repository` bằng `repository` của nguồn. Web không có luật "không mới hơn chart" (cấu hình ở `base/services/web.yaml`, đi expand/contract qua values, ADR-0025 §3); không máy nào kiểm thứ tự đó cho web.
- **`revision` chưa có `sources.json`** (commit backend trước PR-1): `release_sources` dựng **một nguồn `backend`** từ chính cây đó (`imagePrefix`, `issuer`, `subject`, `provenanceRepository`, `provenanceRef` từ `values.yaml`; `services` là `svp_services` ở revision đó, gồm `web`; `drillImages` là `drill_images` của `common.sh`; `promoter` là `svp-gitops-promoter`), nên mọi luật y như trước. Mọi nơi đọc nguồn theo revision (`gitops-check.sh`, `verify-release.sh --gitops`, `release-set.sh`) đi qua cùng hàm. Đường lùi bỏ được khi không `revision` nào ở `main` của `svp-gitops` và không bản ghi stg nào mà promote prd còn chép tới trước PR-1.
- **Tác giả PR** (bot `<promoter>[bot]`, đọc qua hàm `ci_*` mới của `platform.sh` từ sự kiện PR, không qua tên nhánh; bảng nguồn của env chứa file bị đổi, ở `revision` của env đó **sau** thay đổi): luật chỉ chạy ở sự kiện PR (còn lại in `skip`); lượt PR không đọc được tác giả thì đỏ; `sender.login` là bot khác tác giả thì đỏ. Bot của nguồn N chỉ đổi `envs/stg/images/<svc>.yaml` với `<svc>` trong `services` của N, image **sau** thay đổi thuộc N, image **trước** thuộc N hay thuộc `backend` cùng `<svc>` (lần **tiếp quản**, một chiều từ `backend`). Bot của **nguồn chủ chart** (`backend`, cố định trong check) còn được đổi `envs/stg/charts.yaml`, mọi file `envs/prd/images/` và `envs/prd/charts.yaml` (nội dung prd kiểm bằng luật bản ghi stg, không bằng luật nguồn); `svp-web-promoter` không đổi file nào khác (`charts.yaml`, overlay, `envs/prd/`). Không bot nào xoá file; bot của một nguồn không đổi gì ngoài `envs/`. Bot `[bot]` không là `promoter` của nguồn nào (Renovate) không đổi gì dưới `envs/`; ngoài `envs/` nó vẫn đổi được (`renovate.json` của `svp-gitops` quản `base/`, `components.json`). PR của người học không bị giới hạn (bypass có ghi, ADR-0025 §7).
- `svp-gitops`: PR bump `CHECKER_COMMIT` lên commit có luật mới và thêm bước clone `svp-web` vào `check.yml`. **Không đổi:** chart `svp-service` của release `web` (ghim qua `charts.yaml`), bản ghi stg (payload bảy `repository@digest`) và job `record-stg`, promote prd chép cả bộ bảy; `release-set.sh` kiểm prefix theo nguồn. **DORA** ([ADR-0028](0028-dora-metrics.md)): lead time của web tính từ commit của `svp-web`.

### 4. Promote

- `svp-web` job `promote` của `images.yml`: chạy `promote.sh` của backend ở `BACKEND_COMMIT` với `--source web`: nhánh `bot/promote-stg-web`, chỉ ghi `envs/stg/images/web.yaml`, không đọc và không ghi `charts.yaml`; luật không lùi theo tổ tiên trên `main` của `svp-web`; `--force-with-lease`, đọc lại PR sau push, bật auto-merge (PR chỉ đổi `envs/stg/` nên tự merge khi `gitops-ok` xanh). Chế độ `--source` **không tra** ứng viên của nguồn khác: bỏ nó khỏi tập so tổ tiên, in dòng `takeover: web.yaml on main is <repository>:<tag> (source backend); first release of source web`; `repository` không thuộc nguồn nào vẫn là lỗi.
- Backend `promote.sh` chỉ xét service trong `svp_services` **và** có file ở `main` của `svp-gitops` đang ghi prefix backend; file ghi prefix nguồn khác để nguyên, không đỏ.
- **Credential:** App `svp-web-promoter` (người học tạo): `contents: write`, `pull_requests: write`, `metadata: read`; webhook tắt; chỉ cài trên `svp-gitops`. Khoá ở environment `promote` của `svp-web` (chỉ `main`, không người duyệt): biến `SVP_WEB_APP_CLIENT_ID`, secret `SVP_WEB_APP_PRIVATE_KEY`; token 1 giờ bằng `actions/create-github-app-token` ghim SHA, chỉ `svp-gitops`. `release-set.sh records` chỉ nhận bản ghi của App backend.
- **Rescan:** backend `rescan.sh` chỉ digest dưới prefix nguồn `backend`; `svp-web` chạy `rescan.sh --source web` hằng ngày với identity của nó. Không repo nào attest image của nguồn khác.

### 5. Script CI dùng chung

- Mỗi workflow của `svp-web` checkout backend ở `BACKEND_COMMIT` (SHA đủ, file `.backend-commit`; Renovate theo dõi bằng datasource `git-refs`) vào `.backend/` (gitignore) và chạy `build-image.sh`, `scan-gate.sh`, `sign-image.sh`, `provenance-predicate.sh`, `vuln-predicate.sh`, `promote.sh --source web`, `rescan.sh --source web`; ngữ cảnh CI qua `platform.sh` của checkout đó. Script backend thôi giả định repo của build là backend: repo, prefix đẩy, identity từ `ci_repo` và `sources.json`.
- Script riêng của `svp-web` source `platform.sh` từ `.backend/`, không chép; `platform-guard.sh` nhận thư mục gốc và chạy trên cây `svp-web` ở job `config`. Không reusable workflow: job ký chạy trong workflow của `svp-web`, identity ký là `svp-web/.github/workflows/images.yml@refs/heads/main`. Bảng ánh xạ GitLab cho phần mới: phụ lục.

### 6. Kiểm thử chéo

- **CI `svp-web`**, job `stack`: clone `svp-gitops` ở `main`, đọc `revision` của `envs/stg/charts.yaml` và sáu file image backend; checkout backend ở `revision`; `make up IMAGES=stg WEB_FROM=clone SVP_WEB_DIR=<checkout của PR>` (`compose_images` đặt biến image, `docker pull` trước rồi `pull_policy: never`, không build Go); chạy smoke, e2e và Lighthouse (chỉ báo); `make down` luôn chạy. Xét đưa vào `ci-ok` sau 20 lượt xanh liền không đỏ do môi trường.
- **CI backend:** job `web` của `ci.yml` bỏ; job `stack` chạy `make gitops-clone`, `make up` với web của stg theo digest, `smoke`, `load-ci`, `dast`, rồi `make web-clone` ở commit của web stg và `make web-e2e`, `make web-lighthouse` trên stack build từ PR; cả job vẫn chỉ báo.

### 7. Đường dev, runner, source map

- `web_dir` của `deploy/k8s/lib.sh`: `SVP_WEB_DIR` nếu đặt, không thì `<workspace>/frontend`; phải là bản clone `svp-web`, không thì in lệnh clone và dừng. `make web-clone [WEB_REF=…]` (CI) clone ẩn danh vào `.web/svp-web` (gitignore), mặc định commit của `tag` trong `envs/stg/images/web.yaml`.
- `make up`, `make k8s-up`: web mặc định là image của stg theo digest; `WEB_FROM=clone` build từ `web_dir`; `WEB_FROM=image WEB_IMAGE=<ghcr.io/…@sha256:…>` một bản cho sẵn. Target cần mã web (`web-e2e`, `measure-web`, `measure-upload`, `web-lighthouse`, `web-sourcemaps`, `k8s-web-e2e`, `k8s-web-sourcemaps`, `drill-k8s-web-canary`) giữ tên trong `Makefile` backend; bảy target đầu là wrapper sang `svp-web`, `drill-k8s-web-canary` vẫn là drill của backend. Mã test và đo ở `svp-web`; harness ở backend; `svp-web` tìm backend qua `SVP_BACKEND_DIR`. Kịch bản `verify.yml` (`compose-obs`, `dev-k3d`, `web-canary`, `gitops`) chạy `make web-clone` trước bước dựng; input `web_ref` đổi commit.
- **Source map:** mỗi chân build web của `svp-web` đẩy stage `sourcemaps` thành image `ghcr.io/anhnvcoder/svp-web/web-sourcemaps`, tag `<arch>-<hex của digest manifest con>`, bằng ORAS (`ORAS_IMAGE`); `gitops-sourcemaps.sh fetch` kéo ẩn danh theo manifest `linux/amd64` của digest đang chạy. Kéo không được: trên nhánh `skipped` (kèm `SVP_WEB_OBS_SKIP_ERRORS=<lý do>`), trên `main` `fail`. Không tải artifact chéo repo, không PAT.

### 8. Lịch sử

- Bản clone tạm, mới, của `main` backend ở commit S (§9), rồi `git filter-repo --path web/ --path deploy/docker/web.Dockerfile --path-rename web/: --path-rename deploy/docker/web.Dockerfile:Dockerfile` (`web/` thành gốc, Dockerfile ở gốc, context là gốc repo). Message nhắc `#<số>` viết lại thành `anhnvcoder/short-video-platform#<số>` (`--replace-message`). `commit-map` giữ làm bằng chứng ngoài repo. Người điều phối push lên `main` rỗng của `svp-web`; không viết lại lịch sử backend, backend bỏ `web/` bằng PR thường (PR-2).

### 9. Trình tự chuyển, đóng băng, cách lùi

1. ADR chấp nhận; người học tạo repo `svp-web` (public, rỗng), App `svp-web-promoter` cài trên `svp-gitops`, environment `promote`.
2. **PR-1 backend (chuẩn bị, web chưa rời):** `sources.json` hai nguồn (`web` ở cả hai), policy chọn attestor theo nguồn, script theo nguồn, job `api-contract` và `contract` (spec `1.0.0`), `IMAGES=stg` của compose, `web_dir`, `web-clone`, đường source map mới, `renovate.json` bỏ qua `web/**`. Merge; hợp đồng `1.0.0` được phát hành.
3. **Chụp lịch sử** ở commit S (sau PR-1), filter-repo, push `svp-web`. **Đóng băng:** từ S tới khi PR-2 merge, không merge thay đổi nào dưới `web/` hay `deploy/docker/web.Dockerfile` ở backend.
4. PR ở `svp-gitops`: bump `CHECKER_COMMIT` lên PR-1, thêm clone `svp-web` vào `check.yml`.
5. `svp-web`: CI xanh, ruleset và cài đặt (§10); bản phát hành đầu từ `main`, PR `bot/promote-stg-web` tự merge, stg chạy web của `svp-web`; lượt `gitops` của `verify.yml` trên `main` kiểm policy nhận web mới.
6. **PR-2 backend (cắt):** `git diff S origin/main -- web deploy/docker/web.Dockerfile` rỗng; xoá `web/`, `deploy/docker/web.Dockerfile`, job `web` của `ci.yml`; `built_services` (sáu) tách khỏi `svp_services` (bảy bản triển khai); target web thành wrapper; `renovate.json` bỏ luật của web. Merge: hết đóng băng.
7. Promote prd một bản ghi stg có web của `svp-web` (người học duyệt PR prd). 8. **PR-3 backend:** bỏ `web` khỏi `services` của nguồn `backend` (chỉ khi bước 7 đã merge).

Cách lùi: trước bước 5 không cluster nào đổi (PR-1 tương thích ngược); sau bước 5, trước PR-2: PR ở `svp-gitops` trả `envs/stg/images/web.yaml` về digest web của backend; sau PR-2, trước PR-3: revert PR-2 rồi như trên; sau PR-3: revert PR-3 trước. Không xoá `svp-web`; không viết lại lịch sử backend.

### 10. Repo `svp-web`

- Cây: gốc là web (`package.json`, `e2e/`, `lighthouse/`), `Dockerfile`, `Makefile`, `api/contract.json`, `.backend-commit`, `.github/workflows/ci.yml` (lint, test, build, `generate-check`, `lockfile-scan`, `platform-guard`, e2e chỉ báo), `.github/workflows/images.yml` (build hai kiến trúc, quét, ký, provenance, source map, promote, rescan hằng ngày), `renovate.json`, `README.md`. **Check tổng:** `ci-ok` và `images-ok`.
- **Ruleset `main`** (`github/rulesets.tf` của `svp-infra`): PR bắt buộc, `ci-ok` và `images-ok` từ app GitHub Actions, cấm xoá và force push, không bypass; 0 approval, không CODEOWNERS. **Cài đặt** như `svp-gitops` (ADR-0025 §7) và backend (ADR-0015 §11): `GITHUB_TOKEN` mặc định chỉ đọc; "Allow GitHub Actions to create and approve pull requests" **tắt**; Actions chỉ action của GitHub và `sigstore/cosign-installer` ghim SHA; secret scanning, push protection, Dependabot alerts, CodeQL (`actions`, `javascript-typescript`, [ADR-0030](0030-devsecops-supplement.md) §4); package `svp-web/web`, `svp-web/web-sourcemaps` public.
- **Renovate:** App Mend cài thêm `svp-web`; `renovate.json` mang các luật web của backend, action, `.backend-commit` (`git-refs`), `api/contract.json` (custom manager); lịch thứ Bảy, `minimumReleaseAge` 3 ngày, không automerge.

## Kết quả quyết định

Chọn các phương án in đậm ở "Phương án đã cân nhắc" và triển khai theo §1–§10: hợp đồng API có version và chữ ký làm ranh giới, nguồn phát hành khai ở `sources.json`, luật `svp-gitops` và credential theo nguồn, script CI dùng chung ở commit ghim, chuyển brownfield mỗi bước lùi được.

### Hệ quả

- Tốt: ranh giới FE/BE là hợp đồng kiểm breaking bằng máy, phát hành có chữ ký, web ghim theo digest; mỗi nguồn có prefix, identity, credential riêng nhưng khai một file; team BE chạy stack không cần mã FE, team FE kiểm với đúng backend của stg; bài học GitLab (script chung, multi-project, credential thứ hai).
- Xấu: đổi API mà web dùng thành ít nhất hai PR ở hai repo, breaking cần ba bước; thêm oasdiff, ORAS, một App, một khoá dài hạn ở environment của `svp-web`; web mất phép kiểm "image không mới hơn chart"; `svp-web` phụ thuộc `main` của backend qua `BACKEND_COMMIT` và `sources.json`; lịch sử web viết lại hash một lần, một cửa sổ đóng băng `web/`; e2e chéo chỉ báo nên PR backend làm hỏng web vẫn merge được nếu oasdiff không thấy.
- Xem lại khi: có người thứ hai ở mỗi team (CODEOWNERS và duyệt bắt buộc ở `svp-web`); Kyverno ghi rõ cách chọn attestor theo image; GitHub ghi rõ tải artifact chéo repo bằng `GITHUB_TOKEN`; có repo thứ ba dùng script chung (xét repo `svp-ci`); mang CI sang GitLab thật (ADR-0023).
- ADR cũ được chỉnh bởi ADR này ([ADR-0016](0016-web-client.md), [ADR-0019](0019-web-k3d-supply-chain-observability.md), [ADR-0021](0021-deferred-verification-stage6b.md), [ADR-0023](0023-ci-platform-neutral.md), [ADR-0025](0025-gitops-config-repo.md), [ADR-0027](0027-slsa-build-provenance.md), [ADR-0015](0015-cicd-devsecops-stage5.md), [ADR-0028](0028-dora-metrics.md)): mục và nội dung chỉnh ở phụ lục, mục "Hệ quả".

## Xác nhận

- Lượt thật theo §9 (2026-10-30): PR-1 merge (`28bf2ca`), hợp đồng `1.0.0` phát hành và kéo ẩn danh; bản phát hành đầu của `svp-web` (`8dd59c9`) ký đúng identity, PR #22 của `svp-gitops` tự merge, lượt `gitops` 18/18 bước, `k8s-web-e2e` 66 test, ca chéo nguồn của `drill-k8s-supplychain` PASS hai chiều, source map từ image `web-sourcemaps`.
- PR-2 (cắt `web/`) hiện thực 2026-10-31; nguồn web cũ gỡ 2026-11-01 trong bảng chuyển của [ADR-0036](0036-repo-rename.md) (bước 8 của §9).
- Chưa kiểm: Renovate nâng `api/contract.json` (chưa có version thứ hai), chạy lại job `contract` và PR đổi spec không tăng version trên lượt thật, PR kế dưới luật không lùi, rescan hai repo, lead time DORA của web. Bảng kiểm chứng và id lượt chạy: phụ lục.

## Hiện thực ở

- Hợp đồng (§1): `services/gateway/openapi.yaml`, `deploy/ci/contract.sh` (+ `contract-test.sh`), `Makefile` (`OASDIFF_IMAGE`, `ORAS_IMAGE`, `api-contract-check`), jobs `api-contract` của `ci.yml` và `contract` của `images.yml`.
- Nguồn phát hành (§2): `deploy/helm/svp-policy/files/sources.json`, `deploy/helm/svp-policy/templates/imagevalidatingpolicy.yaml`, `deploy/k8s/lib.sh` (`release_sources`), `deploy/ci/common.sh`, `deploy/ci/verify-release.sh`, `deploy/k8s/drills/supplychain.sh`.
- Luật `svp-gitops` (§3): `deploy/ci/gitops-check.sh` (+ test), `deploy/ci/platform.sh` (`ci_change_request_author`), `deploy/ci/release-set.sh`, `deploy/ci/dora.sh`; `.github/workflows/check.yml` của `svp-gitops` (`CHECKER_COMMIT`, clone `svp-web`).
- Promote, rescan, script chung (§4, §5): `deploy/ci/promote.sh` (`--source`), `deploy/ci/rescan.sh`, `deploy/ci/build-image.sh`, `deploy/ci/sign-image.sh`, `deploy/ci/platform-guard.sh`.
- Đường dev, source map, runner (§6, §7): `deploy/k8s/lib.sh` (`web_dir`, `web_clone`, `compose_images`), `deploy/compose/compose.mk` (`IMAGES`, `WEB_FROM`), `deploy/ci/sourcemaps-image.sh`, `deploy/ci/gitops-sourcemaps.sh`, `deploy/ci/verify-run.sh`, `.github/workflows/verify.yml`.
- Repo `svp-web` (§10) và cài đặt GitHub: [`docs/runbooks/svp-frontend-setup.md`](../runbooks/svp-frontend-setup.md). Danh sách file đầy đủ theo PR-1, PR-2: phụ lục, mục "Hiện thực ở".

## Nguồn

- oasdiff ([W1]–[W3]): <https://github.com/oasdiff/oasdiff>; ORAS ([W7]): <https://oras.land/docs/>; cosign ([W8]): <https://docs.sigstore.dev/cosign/signing/other_types/>; Kyverno `ImageValidatingPolicy` ([W13]): <https://kyverno.io/docs/policy-types/image-validating-policy/>; `git filter-repo` ([W19]): <https://github.com/newren/git-filter-repo>.
- Danh sách đầy đủ [W1]–[W20] kèm trích dẫn: phụ lục, mục "Nguồn".

## Thông tin thêm

Phụ lục: [`appendix/0033-svp-web-repo.md`](appendix/0033-svp-web-repo.md) (trạng thái và ghi chú tiến độ gốc, bối cảnh và hiện trạng ngành, mọi bảng lựa chọn, bảng "Cần người học chọn", kiểm chứng sau, kết quả theo lượt chạy, danh sách file hiện thực, nguồn).

### Chỉnh bởi

- §2, §3, §9: [0036](0036-repo-rename.md): tên repo (`svp-web` thành `svp-frontend`, repo backend thành `svp-backend`), prefix và identity của hai nguồn, check không đọc bản clone repo web, bước 8 của §9 (gỡ `web` khỏi nguồn backend cũ) làm trong bảng chuyển.
- §7: [0039](0039-mainpath-drills-scan-gate-sourcemaps.md): image `web-sourcemaps` và `gitops-sourcemaps.sh` bỏ; `verify.yml` thôi clone `svp-frontend` và input `web_ref` (bị thay một phần).
- §10: [0035](0035-renovate-automerge.md): Renovate của `svp-web`: bản `patch`, `digest` của gói npm, Node, base image và service container của CI tự merge khi `ci-ok`, `images-ok` xanh; action, `.backend-commit`, `api/contract.json`, minor, major giữ tay.
