# CI trên GitHub Actions, `svp-gitops`, Renovate

Loại tài liệu (Diátaxis): **reference**, tra cứu khi cần một lệnh hay một quy tắc cụ thể; luật làm việc ở [`AGENTS.md`](../../AGENTS.md).

## Workflow và cổng

- CI trên GitHub Actions ([ADR-0015](../adr/0015-cicd-devsecops-stage5.md)); workflow
  thứ ba `verify.yml` kiểm chứng trên runner ([ADR-0021](../adr/0021-deferred-verification-stage6b.md)). Ba workflow (DORA không còn workflow riêng:
  bài lab `dora/` của `svp-labs`, [ADR-0037](../adr/0037-mainpath-standard-tools.md) §1), mọi action
  ghim SHA commit, `permissions: {}` ở đầu file và quyền khai theo job; mọi job của lượt `pull_request` (cả PR từ fork)
  chỉ có `contents: read` và không secret; không `pull_request_target`, `workflow_run`. CI trung lập nền tảng
  ([ADR-0023](../adr/0023-ci-platform-neutral.md)): YAML chỉ nối bước, logic ở `Makefile` và `deploy/ci/`; script có sẵn đọc
  ngữ cảnh CI hay gọi API của nền tảng (output, summary, mask, link lượt chạy, PR, dispatch) qua hàm `ci_*` của adapter
  `deploy/ci/platform.sh` (chế độ `github` trong Actions, `local` khi chạy script trên máy; CI khác thì dừng). Adapter
  **đóng băng** ([ADR-0037](../adr/0037-mainpath-standard-tools.md) §2): không thêm hàm `ci_*`; script mới đọc biến `GITHUB_*` và gọi `gh`
  trực tiếp; hàm bị xoá khi không còn script nào (ở cả hai repo) gọi nó; không còn `platform-guard.sh` kiểm điều này. CI trên GitLab là bài lab
  của `svp-labs`:
  - `.github/workflows/ci.yml` (PR, push `main`, dispatch): `check` (`make check-go TESTFLAGS=-count=1`, Postgres và
    Redis là service container trên `127.0.0.1`, ffmpeg), `generate` (`make generate-check`), `buf` (`buf breaking` so với
    merge-base của PR, `main` trước push, hay merge-base với `origin/main` khi dispatch), `api-contract` (luật version của hợp đồng
    REST, [ADR-0033](../adr/0033-svp-web-repo.md) §1: `make api-contract-check BASE=<base>` với base tính như job `buf`, rồi
    `deploy/ci/contract-test.sh`), `config`
    (đủ lịch sử, `make gitops-clone` và `SVP_GITOPS_DIR` ở `env` của job; `deploy/ci/scan-gate.sh --check-ignorefile`,
    `deploy/ci/platform-test.sh`, `deploy/ci/promote-test.sh` (guard của hai job promote, danh sách bản phát hành của rescan),
    `deploy/ci/provenance-predicate-test.sh`,
    `deploy/ci/verify-collect-test.sh`, `deploy/ci/sourcemaps-image-test.sh`, `make slo-check`, `make otelcol-validate`, `make env`
    rồi `make compose-config`, `deploy/observability/glitchtip/dotenv-test.sh`,
    `make helm-check`, `deploy/ci/sources-test.sh`, `deploy/ci/gitops-check-test.sh "$SVP_GITOPS_DIR"`, `make k6-check`,
    `make cloud-check`),
    `gitleaks` (toàn lịch sử, `--redact`), `trivy-config` (chỉ báo), `sarif` (chỉ `main`), check tổng `ci-ok` (cần đủ 7 job,
    trừ `sarif` và `stack`; job `web` cũ ở CI của `svp-frontend` từ khi web tách repo). Job `stack` (ADR-0020 §15; **chỉ báo, ngoài `ci-ok`**, không chặn merge; xem lại
    khi 20 lượt liên tiếp xanh, không lượt đỏ do môi trường, thì đưa vào `ci-ok`): `ubuntu-24.04`, tối đa 45 phút,
    `contents: read`, không secret; Postgres, Redis là service container publish trên `127.0.0.1` và IP bridge `172.17.0.1`
    (`make ci-bridge-check` dừng job khi gateway của network `bridge` khác địa chỉ đó; chỉ cho CI), gói apt
    `postgresql-client redis-tools ffmpeg jq`, rồi `make gitops-clone`, `make web-clone` (commit của bản web stg; `SVP_GITOPS_DIR`,
    `SVP_WEB_DIR` ở `env` của job), Node theo `.nvmrc` và pnpm theo `packageManager` của bản clone, `make install` và Playwright Chromium,
    WebKit trong bản clone, `make env`, `make up` (sáu service build từ PR, web là bản phát hành stg theo digest), `make smoke`,
    `make web-e2e` (e2e của `svp-frontend` ở commit của web stg), `make load-ci`, `make web-lighthouse` (đỏ không làm job đỏ), `make dast` (cuối cùng,
    hạn bước 15 phút, đỏ không làm job đỏ), `make ps` khi lỗi, `make down` luôn chạy; artifact chỉ `k6-summary`
    (`summary.json` đã grep bí mật), `lighthouse` (báo cáo đã lọc cookie) và `dast` (chỉ `report.json`, `summary.json`, dò bí
    mật lại trước khi chép; tệp nghi bị bỏ kèm `::warning::`). Trước `make web-lighthouse` job bỏ hạn chế AppArmor `kernel.apparmor_restrict_unprivileged_userns` của runner
    (Chrome của Playwright cần user namespace cho sandbox). Đã kiểm ngày 2026-10-24 (lượt PR
    [40133806424](https://github.com/anhnvcoder/svp-backend/actions/runs/40133806424), ba lần chạy liền xanh,
    quyền ở đầu log chỉ `Contents: read`, artifact chỉ hai loại).
  - `.github/workflows/images.yml` (PR, push `main`, dispatch, lịch hằng ngày): build sáu image service Go của repo này
    (`built_services`; image `web` build, ký, promote ở `images.yml` của `svp-frontend`), chỉ service đổi so với base
    (`deploy/ci/changed-services.sh`; đổi `images.yml`, `deploy/ci/` (trừ `trivy-config-ignore.yaml`, script và test của
    `verify.yml`, `platform-test.sh`, `promote-test.sh`, `gitops-check.sh` cùng `values-check.sh`, `verify-release.sh`, policy `gitops-policies/` (chỉ check `svp-gitops`,
    `make k8s-gitops-up` và diễn tập chạy hai script này),
    `gitops-check-test.sh`, `sources-test.sh`, `sourcemaps-image.sh` cùng test
    của nó: không job image nào đọc chúng), `deploy/k8s/lib.sh` hay dòng
    `TRIVY_IMAGE`/`SYFT_IMAGE`/`GRYPE_IMAGE`/`COSIGN_IMAGE` của `Makefile` thì cả sáu; `build-image.sh web` trong checkout này bị từ
    chối trước khi build). Base: push `main` so với lượt
    push `main` thành
    công cuối (lượt dispatch không đẩy base, nên thay đổi chỉ dispatch đã phát hành, như push GitHub không chạy workflow,
    được build lại ở push kế); PR so với merge-base với nhánh base; dispatch so với merge-base với `origin/main` (trên
    `main` là chính HEAD, nên không build gì), input `services` (`all` hay tên cách bằng khoảng trắng) ghi đè phép so. Mỗi
    service hai chân amd64, arm64 build native,
    trivy chặn bí mật (mọi severity) và CRITICAL **trước** push; grype ([ADR-0030](../adr/0030-devsecops-supplement.md) §6)
    quét SBOM syft của chân đó, cũng trước push: CRITICAL còn lại sau `.trivyignore.yaml` chặn (`--allow-critical` chỉ cho image
    diễn tập `drill-vulnerable`), HIGH trở xuống chỉ đếm, một hàng `(grype)` trong summary cạnh hàng trivy, thấy cả binary ngoài
    trình quản lý gói (như `node` của image web, ở cổng của `svp-frontend`) mà trivy không thấy; DB grype cache theo ngày (`SVP_GRYPE_CACHE`), SARIF category
    `grype-image-<svc>-<arch>/` chỉ lên tab Security ở `main`; push lên `ghcr.io/anhnvcoder/svp-backend/<svc>`
    đúng bản đã quét, ghép index, ký keyless bằng cosign kèm attestation `vuln` (kết quả trivy của hai nền tảng; attestation,
    Kyverno và rescan hằng ngày không đọc grype), SBOM syft mỗi nền tảng và **build provenance**
    ([ADR-0027](../adr/0027-slsa-build-provenance.md); chỉ bản phát hành, không image diễn tập): predicate SLSA v1 do
    `deploy/ci/provenance-predicate.sh` dựng chỉ từ hàm `ci_*` của `platform.sh` (`buildType` GitHub workflow/v1, workflow
    `ref`/`repository`/`path`, input `services` của dispatch khi có, commit, `builder.id`, `invocationId`), dựng và kiểm **trước**
    khi ký gì (`builder.id` phải bằng `subject` của nguồn phát hành của lượt trong `sources.json`, không thì không ký), attest `--type slsaprovenance1` định
    dạng cũ `--replace` trên digest index sau `vuln`; mức SLSA ghi trung thực là Build L1 (predicate do script của repo dựng); rồi
    **promote stg sang `svp-gitops`** ([ADR-0025](../adr/0025-gitops-config-repo.md) §2, §6): job `promote` (chỉ `main`,
    environment `promote` chỉ nhận deployment branch `main`, biến `SVP_GITOPS_APP_CLIENT_ID` và secret `SVP_GITOPS_APP_PRIVATE_KEY`
    của GitHub App `svp-gitops-promoter` chỉ cài trên `svp-gitops`) đổi khoá thành token 1 giờ bằng `actions/create-github-app-token`
    (ghim SHA; chỉ repo `svp-gitops`, chỉ `contents`, `pull_requests` write, thu hồi cuối job; `GITHUB_TOKEN` của job chỉ
    `contents: read`, mọi checkout `persist-credentials: false`), rồi bước shell trong YAML ([ADR-0037](../adr/0037-mainpath-standard-tools.md)
    §6; `promote.sh`, `promote-prd.sh` đã xoá) clone `svp-gitops` ẩn danh (token chỉ tới `gh` và push qua `gh auth setup-git`), dựng nhánh
    `bot/promote-stg` một commit của bot App trên `main` của repo đó, giữ file `envs/stg/` mà PR bot đang mở đã đổi, rồi `yq -i`
    (`yq_` của `deploy/ci/common.sh`, `YQ_IMAGE` ghim của `Makefile`, `--network none`) khối `image` của `envs/stg/images/<svc>.yaml` mỗi
    service vừa ký ở lượt này (repository `ghcr.io/anhnvcoder/svp-backend/<svc>` của `built_services`, tag 12 hex của commit lượt, một bản
    mỗi service, không thì đỏ trước push) và `envs/stg/charts.yaml` (`revision` = commit của lượt, hai khoá dẫn xuất `podSecurityVersion`,
    `collectorConfigSha256` tính từ đúng commit đó); comment của file giữ nguyên. Thứ tự giữ bằng nhóm `concurrency` không huỷ của build;
    guard `promote_not_behind` của `common.sh` từ chối lượt có commit là tổ tiên thật của `revision` ở `main` hay ở PR đang mở (chạy lại,
    dispatch commit cũ; bằng `revision` thì nhận). Push `--force-with-lease`, mở hay cập nhật PR (tiêu đề, mô tả liệt kê mọi bản nhánh
    đổi so với `main`) và bật auto-merge (squash, `--match-head-commit`); đọc lại PR sau push, PR đã merge hay đóng giữa chừng thì job đỏ.
    PR đang mở đọc bằng `promote_open_pr` (PR của App, `--limit 500`; `gh` lỗi hay danh sách đầy thì đỏ). Không đổi gì so với `main` thì
    không push. Repo này chỉ ghi file image của sáu service của nó; web do job `promote` của `svp-frontend` ghi (bước riêng của repo đó,
    nhánh `bot/promote-stg-web`, bot `svp-web-promoter`, chỉ `envs/stg/images/web.yaml`). PR chỉ đổi
    `envs/stg/` (không Code Owner) nên tự merge khi `gitops-ok` xanh, không ai duyệt. Lượt push `main` không build image nào mà đổi
    `deploy/helm/` hay file chart đó đọc qua symlink (`promote_charts` của `plan.sh`) vẫn chạy `promote`, chỉ ghi `charts.yaml`. Lượt PR
    chỉ build và quét (`build-nopush`); job `values-check` đã bỏ (digest không còn ở repo này; `values-check.sh --gitops` chạy trong
    check của `svp-gitops`). Dispatch `-f services=<tên…|all>` build, ký và promote lại các service đó ở commit được dispatch,
    `-f rescan=true [-f values_ref=<ref>]` quét lại mọi digest phát hành (lịch hằng ngày làm việc này): job `rescan` chạy
    `make gitops-clone` rồi `rescan.sh run`, tập digest là `envs/*/images/` của `svp-gitops` ở `main`, ở PR `bot/promote-stg` đang mở và
    ở `values_ref` (ref của `svp-gitops`, hay SHA đủ 40 hex của commit repo này trước khi tách, còn `deploy/k8s/values/services/`; trước
    đổi tên dùng cho ca (l) của `drill-k8s-supplychain`, nay không đường nào cần: mọi bản dưới đó ở prefix trước đổi tên, không thuộc nguồn
    nào, nên lượt đỏ); đọc PR bot lỗi thì vẫn quét `main` và `values_ref` rồi mới đỏ. Rescan theo nguồn: lượt của
    repo này chỉ quét và attest bản của nguồn `backend` (bảng nguồn của checkout); file ghi bản của nguồn khác bị bỏ khỏi tập, một dòng
    stderr (CI của nguồn đó rescan nó, `rescan.sh run|list --source <tên>`, nhánh bot `bot/promote-stg-<tên>`), file dưới prefix không
    thuộc nguồn nào vẫn vào tập nên lượt đỏ; không repo nào attest bản của repo khác. `rescan.sh run` đòi `--source` (mặc định
    `backend`) bằng nguồn của repo của lượt (`use_build_source`) và `ci_builder_id` bằng `subject` của nguồn đó, kiểm trước khi đọc gì
    (`cosign attest --replace` thay attestation `vuln` bất kể ai ký bản cũ: CI của `svp-frontend` quên `--source web` sẽ thay attestation của
    bản backend bằng identity `svp-frontend`). `-f drill=true` đẩy ba image
    diễn tập `drill-vulnerable`, `drill-unsigned`, `drill-no-provenance` (hai cái ký và attest `vuln`: `drill-vulnerable` với
    `--allow-critical`, `drill-no-provenance` không CRITICAL; không image diễn tập nào có provenance; rescan hằng ngày không đụng). **Hợp đồng API** ([ADR-0033](../adr/0033-svp-web-repo.md) §1): job `contract` (mọi lượt build trên `main`: push, hay
    dispatch không `rescan`, `drill`, `promote_prd`; cùng nhóm concurrency không huỷ của build; quyền `contents: read`,
    `packages: write`, `id-token: write`) chạy `deploy/ci/contract.sh publish`: đẩy spec thành OCI artifact
    `ghcr.io/anhnvcoder/svp-backend/api/gateway:<info.version>` bằng ORAS (`ORAS_IMAGE` ghim; `artifactType`
    `application/vnd.anhnvcoder.svp.api-contract.v1`, một layer `application/vnd.oai.openapi`), ký keyless digest đó bằng cosign
    định dạng cũ với identity của nguồn `backend`; trước khi đẩy đòi lượt ký được bằng identity đó (`ci_builder_id`). Tag đã có cùng
    layer thì để nguyên (thiếu chữ ký thì ký bù), tag có nội dung khác thì đỏ, không ghi đè. `contract.sh publish --dry-run` đọc
    registry ẩn danh và chỉ in việc sẽ làm. Lượt phát hành thật đầu và package `api/gateway` public: **kiểm sau push**. **Promote prd** ([ADR-0037](../adr/0037-mainpath-standard-tools.md) §6): dispatch
    `-f promote_prd=true [-f stg_ref=<main|SHA đủ 40 hex>]` trên `main` (một mình, không kèm `services`, `rescan`, `values_ref`, `drill`;
    `plan` bỏ qua mọi job khác) chạy job `promote-prd` (environment `promote`, token App `contents`, `pull_requests` write): bước shell
    chép giá trị khối `image` của cả bảy `envs/stg/images/*.yaml` và ba khoá của `envs/stg/charts.yaml` ở commit `stg_ref` của
    `svp-gitops` (mặc định `main`; commit cũ hơn là rollback) vào cùng file dưới `envs/prd/` bằng `yq -i` (comment của file prd giữ nguyên),
    nhánh `bot/promote-prd`, mở PR không auto-merge (Code Owner duyệt), mô tả nêu `stg_ref`. Guard `promote_stg_ref` của `common.sh` chỉ
    nhận `main` hay SHA đủ 40 hex của một commit trên `main` của `svp-gitops` (nhánh, SHA ngắn, commit ngoài `main` bị từ chối trước mọi
    lệnh `gh`). Không còn bản ghi stg: `stg_ref` chỉ bảo đảm bộ từng nằm trên `main` của `envs/stg/`, không bảo đảm stg đã chạy và smoke
    qua với đúng bộ đó; cổng là duyệt của Code Owner. Check tổng `images-ok` (gồm `contract`; dispatch promote prd: `plan` skipped vẫn xanh). Provenance trên bản phát hành
    thật đã kiểm (bảy bản của `6ca2d8a`, `cosign verify-attestation --type slsaprovenance1` và lượt `gitops` 40954609229). Đã kiểm ngày
    2026-10-30 với `promote.sh`, `promote-prd.sh` cũ: lần promote stg đầu và auto-merge của PR bot (PR #4, #5, #6 của `svp-gitops`, lượt
    `images.yml` 40984668411 trên `2d9dab0`), promote prd (lượt 41022346853, PR #7 `523ba34`, người học duyệt); bước shell thay chúng:
    **kiểm sau push**. Rescan đọc `svp-gitops` (lượt 41018158008: 14 digest của stg và prd, 28/28 qua cổng quét).
  - `.github/workflows/verify.yml` ([ADR-0021](../adr/0021-deferred-verification-stage6b.md); không check
    bắt buộc nào, không chạy ở PR): kiểm chứng trên runner `ubuntu-24.04` những gì máy 16 GB không chạy nổi, bằng đúng
    target `make` như trên máy. Trigger: `workflow_dispatch` (chỉ người có quyền ghi; ref `main` hay `feat/stage6b-*`, ref
    khác dừng ở bước đầu) và lịch hằng tuần trên `main` (00:37 UTC thứ Bảy, 07:37 giờ Việt Nam; `compose-obs`, `dev-k3d` và
    `gitops` song song, mọi bước; **kiểm sau push**). Kịch bản: `compose-obs` (job `compose`, hạn 120 phút: `make up OBS=lgtm`, `make smoke`,
    `make drill-duplicates`, `make drill-kill-worker`, `make drill-obs-threats`, `make load-local` dưới quan sát Alertmanager (`RateLimitFallbackActive` không được cháy),
    `make web-lighthouse` ×3 và median LCP, `make test-stack PKGS=./internal/objstore/...` (một ca SKIP là đỏ; gồm ba test của output bất biến),
    `make drill-upload-cleanup`, `make measure-upload` và RAM đỉnh của `s3` trong lúc đó (dưới 512 MiB), `make
    drill-alert-to-sentry` với Telegram SKIP, cuối cùng đường quay lại `object-store-roundtrip`: `make down`, `make
    object-store-copy TO=minio` vào volume mới của runner, rồi `make up` lần hai (init chạy lại trên store đã init) và `make
    smoke` trên RustFS) và `dev-k3d` (job `k3d`, hạn 330
    phút: `make k8s-up WEB_FROM=clone`, `make k8s-smoke`, RAM nghỉ, `make drill-k8s-threats`, `make drill-k8s-pdb`, `make drill-k8s-canary`,
    `make k8s-web-sourcemaps`, `SVP_E2E_GLITCHTIP=1 make k8s-web-e2e`, `make drill-k8s-web-obs`, `make drill-k8s-keda N=9` và
    RAM đỉnh, `make drill-k8s-backup` rồi `MODE=pitr`, RAM nghỉ cuối). Các kịch bản còn lại (chỉ dispatch, không vào lịch, trừ `gitops` vào lịch từ
    2026-10-30): `gitops` (job `gitops`, hạn 330 phút: bước `Find the source maps of the web image`, rồi bước kịch bản 175 phút: `make k8s-gitops-up`
    (vai stg; `make gitops-clone` trước; `GITOPS_REV` là SHA của `origin/main` trong bản clone, nên cluster ở yên commit đó suốt các bước
    kiểm, PR promote merge giữa chừng không đổi gì), `gitops-env` (overlay stg có trên pod
    gateway), `gitops-external-secrets` (ExternalSecret của cluster đúng bằng danh sách của chart, mỗi cái `Ready`, Secret đích đúng
    type và đúng tên key, không đọc giá trị), `gitops-argocd-metrics` (trong 180 s Prometheus thấy
    `argocd_app_info` của mọi Application, đều Synced và Healthy, không cảnh báo `ArgoCDApplication*` nào cháy; chart stg đang chạy
    chưa có PodMonitor của Argo CD thì nói vậy và qua), `make k8s-smoke` (chặt, không biến chuyển tiếp), RAM nghỉ,
    `make drill-k8s-supplychain` (ca
    chưa ký là manifest con `linux/amd64` của digest web đang chạy; ca (l) là digest mới nhất của `drill-no-provenance` dưới prefix
    của `backend`, lấy như ca (c) lấy `drill-vulnerable`, GHCR không trả thì bước đỏ nêu `drill-no-provenance`; chỉ ở lượt lịch, `SVP_VERIFY_SCHEDULED=true`,
    image của ca (c) hay (l) có attestation `vuln` quá 72 giờ thì không đưa cho drill: ca đó SKIP kèm dòng `NOTE` nêu tuổi và lệnh
    dispatch dựng lại image diễn tập (`-f drill=true`), mọi ca khác vẫn phải PASS; lượt dispatch quá hạn là đỏ, nên (c), (l) chỉ được chứng
    minh ở lượt dispatch sau lượt đó), `make drill-k8s-threats`, source map của image CI
    (`deploy/ci/gitops-sourcemaps.sh` chọn lượt `images.yml` có `image-digest` bằng manifest con đó; web của nguồn khác (`svp-frontend`)
    thì kéo ẩn danh image `<imagePrefix>web-sourcemaps:amd64-<64 hex của manifest đó>`, kiểm digest từng layer, chỉ nhận file thường
    và thư mục dưới `_next/`, không tải artifact của repo khác; trên nhánh `feat/stage6b-*`
    không có thì `skipped`, e2e không GlitchTip, `drill-k8s-web-obs` bỏ riêng `errors`; trên `main` thì FAIL), `make
    k8s-web-e2e`, `make drill-k8s-web-obs`, `make drill-k8s-keda N=9` hai lần mỗi lần kèm RAM đỉnh, RAM nghỉ cuối; rồi bước
    `Waiting for a release on main` 115 phút: trên `main` bật traffic diễn tập, chuyển root sang `refs/heads/main`
    (`deploy/k8s/gitops.sh follow main`, dòng `ok`/`note` vào log job; nhánh đã đi tiếp trong lúc ghim thì các commit đó chỉ triển
    khai lúc này, thời gian từ push sẽ tính cả lúc ghim nên không đo: một dòng `not measured` nêu hai commit và các bản phát hành trong
    đó, vòng chờ tính từ commit Argo CD vừa nhận), chờ tối đa 90 phút một commit của `main` `svp-gitops`
    đổi đúng một digest ở `envs/stg/images/` (bản phát hành tới bằng auto-merge của PR bot, không cần merge tay), `make
    measure-gitops`; trên nhánh hay ở lượt lịch thì `skipped`). Bản ghi stg (bước
    `release-set-before`, `release-set`, job `record-stg`, Deployment `stg` trên `svp-gitops`) đã bỏ
    ([ADR-0037](../adr/0037-mainpath-standard-tools.md) §6): promote prd chép `envs/stg/` của `svp-gitops` ở `stg_ref`. Lượt `gitops`
    40954609229 (nhánh PR-B, mọi bước) 17/17 target ok; lượt 41015270736 trên `main` 18/18 target ok; bước chờ phát hành trên `main`:
    chưa chạy, **kiểm sau push**), `web-canary` (`make k8s-up WEB_FROM=clone`, `make k8s-smoke`, `make drill-k8s-web-canary`), `k6-cloud-mini`
    (`make k8s-up`, seed ≥ 30 video `READY`, Job k6 profile `cloud` 1, 2, 4, 8 pod qua `run.sh --pods N`, mỗi mức lên 2 phút,
    giữ 10, xuống 1, dừng ở mức đầu tiên trượt; mỗi mức ghi số k6, khoá rate limit bằng số pod, p95/p99 phía server, CPU,
    throttle, working set của web; sau mỗi mức step `tempo-ingest-<n>`; **LOCAL LAB ONLY:** xoá khoá đăng ký giữa hai mức), `chaos` (`make k8s-up`, seed, cài Chaos
    Mesh với values phủ của runner (chỉ controller không multi-cluster; controller phải giữ cùng pod, 0 restart, không dòng
    `is forbidden` trong 150 s), bản thử NetworkChaos trên pod thử (nạp `sch_netem`, thiếu thì cài `linux-modules-extra-<kernel>`;
    không nạp được thì FAIL và (b) không chạy), thí nghiệm (a), (b), (c) (mỗi `apply` chờ webhook có endpoint Ready),
    mỗi thí nghiệm một lượt k6 1 pod riêng dưới 55 phút có cửa sổ ổn định 5 phút riêng, sau mỗi thí nghiệm step
    `tempo-ingest-chaos-<x>`, gỡ bằng lệnh của buổi cloud và kiểm không còn gì). Step `tempo-ingest-*` (`deploy/ci/verify-tempo.sh`,
    [ADR-0031](../adr/0031-chaos-findings-feed-engagement-tempo.md) §3) đọc cửa sổ giữ tải của step trước ở `k6-windows.tsv` (không
    có thì skip, kết quả không chặn step sau): đạt khi 0 span bị receiver của Collector từ chối hay lỗi, exporter `otlp_grpc/tempo`
    gửi lỗi hay không vào được hàng đợi, Tempo bỏ (`tempo_discarded_spans_total`), container `tempo` không khởi động lại trong cửa sổ,
    tìm và lấy được theo id một trace của gateway có ≥ 2 service, cạnh gateway → feed-service của service graph tăng; mức 8 pod chỉ ghi
    số; JSON ở `.k8s/drills/tempo-ingest-<nhãn>-<time>.json`; `velero` (`SVP_K8S_RUNNER_CSI=1 make k8s-up`, bucket và user `svp-velero`, cài Velero, kiểm NetworkPolicy, seed bằng
    smoke và fixture, `drill-restore.sh` chế độ runner, sweep, gỡ). Dispatch và đọc kết quả (AI được chạy, chỉ khi người
    học giao): `gh workflow run verify.yml --ref <main|feat/stage6b-…> -f
    scenario=<compose-obs|dev-k3d|gitops|web-canary|k6-cloud-mini|chaos|velero> [-f targets='<bước> …'] [-f web_ref=<nhánh hay
    SHA đủ 40 hex của svp-frontend>]` (`targets` rỗng là mọi bước, bước dựng luôn chạy; tên bước ở `results.tsv`), `gh run view <id> --log`,
    `gh run download <id> -n verify-<kịch bản>`. Mã web (e2e, Lighthouse, `measure-upload`, client canary, source map) là của bản clone
    `svp-frontend` ([ADR-0033](../adr/0033-svp-web-repo.md) §7): bước `Clone svp-gitops and svp-frontend` của mỗi job (`verify-run.sh --clones
    <kịch bản>`, trước bước cài Node) chạy `make gitops-clone` mọi kịch bản, rồi với kịch bản khai `web=1` (`compose-obs`, `dev-k3d`,
    `web-canary`, `gitops`) `make web-clone` (`SVP_GITOPS_DIR` là bản clone vừa làm) ở `web_ref` hay, rỗng (cũng là lượt lịch), commit của
    bản web stg, và in `web_dir=.web/svp-frontend`; clone lỗi thì không bước nào sau chạy. Node theo `.nvmrc`, pnpm theo `packageManager` của
    bản clone, `make install` và Playwright trong đó; bước kịch bản chạy lại `make gitops-clone` (`main` như lúc đó), export
    `SVP_GITOPS_DIR` tới đó và `SVP_WEB_DIR` tới bản clone web có sẵn (thiếu thì dừng, nêu lệnh `--clones`) cho mọi target. `dev-k3d`, `web-canary` build image web từ bản clone (`WEB_FROM=clone`), `compose-obs`, `gitops` chạy image web stg.
    `web_ref` cho kịch bản không có `web=1` thì dừng trước khi chạy gì; giá trị không phải SHA đủ hay tên nhánh hợp lệ thì dừng ở bước
    đầu như ref; chỉ origin `anhnvcoder/svp-frontend`, code của fork không tới được. Job `compose`, `k3d` chỉ `contents: read`; job `gitops` thêm `actions: read` (artifact source map) và
    `pull-requests: read` (`merged_at` của PR promote cho mốc push của `measure-gitops`), `GH_TOKEN` chỉ ở bước tìm source map
    và bước chờ phát hành; không job nào có secret hay environment; `concurrency` một lượt mỗi kịch bản. Trình tự mỗi kịch bản ở
    `deploy/ci/verify/<kịch bản>.sh` (bước dựng, hạn job mặc định, danh sách bước). Script `deploy/ci/verify-*.sh` (chạy được
    trên VM Linux thay runner):
    `verify-host.sh` (cổng đĩa, `/etc/hosts` cho ba tên `*.svp.localhost`, lệch version kubectl, hạn chế AppArmor, `sudo
    modprobe sch_netem` cho `chaos`), `verify-run.sh` (nạp trình tự của kịch bản, hạn mỗi target, output mỗi target vào file thay
    vì log job, dừng sớm khi bước dựng đỏ),
    `verify-sample.sh` (mẫu RAM, CPU, đĩa, `docker stats`, `memory.stat` của node, `kubectl top` mỗi container của namespace
    `svp`, `svp-data`, `cnpg-system`, `svp-obs` ở `pods.tsv`, số pod media-worker đang chạy `ffmpeg`,
    số restart của từng container compose, `cpu.stat` của pod k6 trong cửa sổ giữ ghi ở `k6-windows.tsv`;
    `runner.json`, `runner.txt` "runner đủ"), `verify-mask.sh` (`::add-mask::` giá trị bí mật của `.env` sau mỗi target và
    của Secret trong cluster, gồm `chaos-mesh`, `svp-load`, `velero`, `svp-secrets`), `verify-collect.sh` (artifact `verify-<kịch bản>`, giữ 30 ngày: chỉ file theo danh sách cho
    phép, quét theo giá trị bí mật đã biết và theo mẫu, file nghi bị bỏ kèm `::warning::`, `files.txt` liệt kê file giữ và
    bỏ; đầu ra target bỏ dòng log JSON, access log và dòng log container `    [<namespace>] …` ngoài `log_tail_namespaces` của
    `deploy/k8s/lib.sh`: chỉ đuôi log hạ tầng bên thứ ba mà `make k8s-up` in khi release không Ready, không bao giờ `svp`). `verify-collect.sh` lấy kết quả web ở `.web/svp-frontend/test-results` (cùng mẫu cho phép như cũ, vào
    `web-test-results/` của artifact). `deploy/ci/verify-collect-test.sh` chạy trên máy và ở job `config` (giá trị giả,
    `docker`/`kubectl` giả, không mạng).
  - DORA là bài lab `dora/` của `svp-labs` ([ADR-0037](../adr/0037-mainpath-standard-tools.md) §1, thay [ADR-0028](../adr/0028-dora-metrics.md)):
    `dora.yml`, `dora.sh`, `dora-test.sh` đã rời repo này; front matter của `docs/postmortems/` vẫn là dữ liệu cho bài lab đó.
  - **`svp-gitops`** (`https://github.com/anhnvcoder/svp-gitops`, public, không secret; [ADR-0025](../adr/0025-gitops-config-repo.md),
    quy trình tay ở [`docs/runbooks/svp-gitops-setup.md`](../runbooks/svp-gitops-setup.md)): `base/` (values gốc của chart upstream,
    `argo-cd.yaml`, `services/<svc>.yaml` không khối `image`), `envs/{stg,prd}/` (overlay, `svp-policy.yaml`, `charts.yaml` ghim
    commit chart của repo này cùng hai giá trị dẫn xuất, `images/<svc>.yaml` chỉ khối `image`), `argocd/` (`project.yaml`,
    `bootstrap.json`, chart app-of-apps `apps/` với `components.json`), `CODEOWNERS` (`*` của người học, `/envs/stg/` không chủ),
    `renovate.json` (chart upstream, image ghim trong `base/`, commit checker; bỏ qua `envs/**`). Check: `.github/workflows/check.yml`
    (PR và push `main`, chỉ quyền đọc, không secret) checkout repo này (`anhnvcoder/svp-backend`) ở `CHECKER_COMMIT` (SHA đủ, một chỗ
    trong workflow; đổi bằng PR ở `svp-gitops`) rồi chạy `deploy/ci/gitops-check.sh <cây> <base>`, bản rút gọn
    ([ADR-0037](../adr/0037-mainpath-standard-tools.md) §4–§6; bước 1b "bộ prd = payload một bản ghi stg", 1c dạng cũ (tiếp quản, đọc
    qua adapter), luật tổ tiên và đường cho cây chưa có `platforms/` hay commit chưa có bảng nguồn đã bỏ): (1) cây và `charts.yaml` (khoá,
    `revision` trên `main` repo này, hai giá trị dẫn xuất tính lại), mỗi `envs/<env>/images/<svc>.yaml` là `<imagePrefix><svc>` của một
    nguồn có `<svc>` trong bảng nguồn ở `revision` của env; lớp nền tảng theo khoá `platforms` của `components.json` (thiếu hay sai dạng
    là đỏ, tên nền tảng khớp thư mục `platforms/`); luật tác giả hẹp viết từ bảng nguồn (dưới đây); (2) render root theo env × nền tảng
    của `platforms` × kiến trúc (mọi `targetRevision` vào `svp-gitops` phải tên đầy đủ); (3) chart repo ở `revision` của env với `base/`,
    `platforms/` và overlay, External Secrets qua kubeconform, render của nền tảng không `localHosts` không nêu `svp.localhost` (grep cả
    render và policy `no-lab-hosts`); (4) mọi image ghim digest bằng policy `images-pinned` (dưới đây; ref ngoài tầm policy vẫn qua phép
    quét của script), render có overlay không đổi version image của render nó chồng lên; (5) `values-check.sh --gitops` cho file image đổi
    (chữ ký, `vuln`, provenance env đòi; provenance có thì tag là 12 hex của commit nó nêu). Check tổng `gitops-ok`. Tag image không còn
    phải là tổ tiên của `revision`, PR prd không còn so bản ghi (cổng prd là duyệt của Code Owner). `CHECKER_COMMIT` là một commit trên
    `main` repo này; `check.yml` của commit checker cũ còn `deployments: read` và `GH_TOKEN` cho bước 1b: PR prd đỏ cho tới khi nâng
    `CHECKER_COMMIT` lên commit có bản rút gọn, cùng PR bỏ hai thứ đó. **Luật tác giả hẹp** (bước 1 khi có base; tác giả
    `pull_request.user.login` và người gửi `sender.login` đọc thẳng từ `GITHUB_EVENT_PATH`, trên máy `SVP_CHANGE_REQUEST_AUTHOR` đóng vai
    tác giả): bot `<promoter>[bot]` của nguồn N chỉ đổi `envs/{stg,prd}/images/<svc>.yaml` với `<svc>` thuộc `services` của N (bảng ở
    `revision` env ghim sau thay đổi); bot của `backend` đổi thêm `envs/{stg,prd}/charts.yaml` và mọi file `envs/prd/images/` (promote prd
    chép cả bộ, gồm web); không bot nào xoá file; bot `[bot]` không phải promoter (Renovate) không đổi gì dưới `envs/`; người gửi là bot
    khác tác giả thì đỏ; tác giả hay người gửi không đọc được thì đỏ; PR của người không bị giới hạn; không base hay không phải PR thì
    một dòng `skip`. Lý do: `/envs/stg/` không Code Owner nên PR bot tự merge, bỏ hẳn luật thì khoá App lộ đổi được `charts.yaml` hay
    overlay stg mà không ai duyệt (GIT-6). **Policy Kyverno CLI** (`deploy/ci/gitops-policies/`: `images-pinned.yaml`,
    `no-lab-hosts.yaml`, `ValidatingPolicy` CEL; fixture đạt và hỏng ở `test/<policy>/`): `gitops-check.sh` render rồi đưa manifest cho
    `kyverno apply` bằng `KYVERNO_CLI_IMAGE` ghim của `Makefile` (cùng minor với Kyverno của cluster, `--network none`), message
    `<file>: <Kind> <ns>/<name>: <message>`; `make kyverno-test` chạy `kyverno test` của thư mục đó; `gitops-check.sh --policy
    images-pinned|no-lab-hosts FILE...` áp một policy lên manifest có sẵn. Ba ruleset (Terraform ở `github/rulesets.tf` của `svp-infra`): `main` (PR, `gitops-ok` bắt buộc, cấm xoá và force push, không ai
    bypass), `owners` (duyệt của Code Owner; vai admin bypass chỉ ở chế độ `pull_request`, có bản ghi), `tags` (cấm tạo, sửa, xoá tag;
    chỉ admin bypass), cộng dồn: PR bot chỉ đổi `envs/stg/` tự merge, PR prd và Renovate cần người học duyệt, PR của người học trên file
    có chủ merge bằng bypass `owners` mà vẫn cần `gitops-ok`. Đã kiểm: commit khởi tạo `55258e1`, commit thêm check `a84e26d`, lượt
    `check` đầu 40902199532 xanh (token chỉ `Contents: read`), ba ruleset `active` (2026-10-29); PR bot chỉ đổi `envs/stg/` tự merge đã kiểm ngày 2026-10-30 (PR #4, #5, #6). **Không đạt:** PR của người học đổi file có chủ merge được không
    cần duyệt và không có bản ghi bypass (PR thử #8 ở trạng thái `CLEAN`, PR #3 có rule suite `pass`): GitHub coi tác giả PR kiêm Code Owner duy nhất là
    đã thoả `require_code_owner_review`, nên người học không tự kiểm mình bằng duyệt, kiểm tự động `gitops-ok` là lớp chặn còn lại; luật vẫn áp lên PR của người
    khác, ca âm cho PR của bot chưa có (việc mở: App thứ hai).
  - Check bắt buộc của ruleset `main`: `ci-ok`, `images-ok`, chỉ nhận từ app GitHub Actions. Ruleset, năm cài đặt repo
    của ADR-0015 §11 (quyền mặc định của `GITHUB_TOKEN` chỉ đọc kèm "Allow GitHub Actions to create and approve pull
    requests"; Actions chỉ cho action của GitHub và `sigstore/cosign-installer`, ghim SHA bắt buộc; duyệt workflow của PR
    fork cho mọi người ngoài; secret scanning + push protection; Dependabot alerts) và package GHCR public do người học bật
    (ADR-0015 §5, §11): **kiểm sau push**. Quyền deploy không còn ở repo này: push vào `main` không đổi cluster nào, chỉ PR vào
    `svp-gitops` đổi được thứ đang chạy; environment `promote` của repo này giữ khoá App, chỉ hai job trên `main` khai nó
    (`promote`, `promote-prd` của `images.yml`), không job `pull_request` nào.
  - CodeQL **default setup** ([ADR-0030](../adr/0030-devsecops-supplement.md) §4): bật bằng cài đặt repo, không file workflow
    trong repo (GitHub dựng và giữ workflow động "CodeQL"); ngôn ngữ `actions`, `go`, `javascript-typescript`, query suite
    `default`, threat model `remote`; quét mỗi push `main`, PR từ nhánh của repo (không PR từ fork) và hằng tuần. **Chỉ báo:**
    không là check bắt buộc, cảnh báo ở tab Security (giả thì dismiss kèm lý do), gosec vẫn là cổng chặn. Job CodeQL chạy `make`
    không đối số của commit được quét (autobuild Go), token chỉ có quyền ghi `security-events` (đọc từ log ngày 2026-10-29).
    Lệnh bật, tắt và đọc kết quả (người học chạy) ở [`docs/ci-cd.md`](../ci-cd.md) mục 7.
  - Chạy lại một job trên máy, từ gốc repo: `make check-go TESTFLAGS=-count=1`; `make generate-check`;
    `buf breaking --against '.git#ref=<base>'`; `make api-contract-check BASE=<base>`, `deploy/ci/contract-test.sh`;
    `deploy/ci/scan-gate.sh --check-ignorefile`,
    `deploy/ci/platform-test.sh`, `deploy/ci/provenance-predicate-test.sh`, `deploy/ci/sourcemaps-image-test.sh`, `make slo-check`,
    `deploy/ci/promote-test.sh`,
    `make otelcol-validate`, `make compose-config`, `deploy/observability/glitchtip/dotenv-test.sh`, `make helm-check`, `make kyverno-test`, `deploy/ci/sources-test.sh`,
    `deploy/ci/gitops-check-test.sh ../gitops`, `make k6-check`,
    `make cloud-check`; check của `svp-gitops` trên bản clone: `deploy/ci/gitops-check.sh ../gitops` (cần mạng tới repo chart, GHCR;
    ~5 phút); `gitleaks git --redact --no-banner`; `make trivy-config`; một chân image (build, quét, cổng, không push):
    `deploy/ci/build-image.sh <svc> arm64 "$(mktemp -d)"`; riêng cổng grype của một chân: `make grype IMAGE=<ref>@sha256:<digest>
    [ARCH=amd64|arm64]` (syft ghim đọc image từ registry, ẩn danh) hay `make grype SBOM=<đường tuyệt đối tới SPDX JSON>`, in số
    gói và binary ngoài trình quản lý gói; bước `dast` của job `stack`: `make dast` trên stack `make up`; service nào sẽ build: `deploy/ci/changed-services.sh <base>
    HEAD`; bộ lọc artifact và sampler của `verify.yml`: `deploy/ci/verify-collect-test.sh`. Push GHCR, ký, attest chỉ chạy
    trong CI: không đăng nhập GHCR hay Sigstore từ máy. Bước promote stg, prd
    chỉ chạy trong CI (token App); guard của chúng thử bằng `deploy/ci/promote-test.sh`.
  - **Script CI cho cây của nguồn khác** ([ADR-0033](../adr/0033-svp-web-repo.md) §5): CI của một nguồn phát hành khác (`svp-frontend`)
    chạy `deploy/ci/*.sh` từ checkout ghim của repo này với `SVP_CODE_ROOT` trỏ checkout của chính nó. `common.sh` có hai gốc:
    `script_root` (checkout này: `lib.sh`, image ghim của `Makefile`, bảng nguồn) và `code_root` (`SVP_CODE_ROOT` nếu đặt, phải là
    thư mục; không thì checkout này). Nguồn của lượt là nguồn có `repository` bằng `ci_repo_url` (`use_build_source`; repo không có
    trong bảng thì không build, đẩy hay ký gì); image phải thuộc `services`/`drillImages` của nguồn đó, đẩy dưới prefix của nó, nhãn
    OCI theo nguồn; HEAD của `code_root` phải bằng commit của lượt (`check_code_tree`). Cây repo khác: `Dockerfile` và context ở gốc,
    phải có `Dockerfile`, `pnpm-lock.yaml`, `.trivyignore.yaml` (cổng quét đọc file của cây đang build); `plan.sh` build mọi service
    của nguồn mỗi lượt, không base, `promote_charts=false`. Trên máy (chế độ `local`), `ci_repo`, `ci_repo_url`, `ci_commit` đọc origin
    github.com và HEAD của `SVP_CODE_ROOT` (không có origin đó thì lỗi). Thử một chân web từ cây khác:
    `SVP_CODE_ROOT=<checkout svp-frontend> deploy/ci/build-image.sh web arm64 "$(mktemp -d)"`. Image source map của web nguồn khác
    (`gitops-sourcemaps.sh` kéo ẩn danh): `deploy/ci/sourcemaps-image.sh push [--dry-run] ARCH DIR`, `DIR` là thư mục
    `build-image.sh --sourcemaps-artifact` ghi (đúng `_next/` và `image-digest`, không link; sai thì đỏ trước khi đọc registry); đẩy
    `<imagePrefix>web-sourcemaps:<ARCH>-<64 hex của image-digest>` dưới prefix của nguồn của lượt (nguồn phải phát hành `web`,
    `web-sourcemaps` không được là tên trong `services`/`drillImages`) bằng ORAS ghim (`ORAS_IMAGE`), một layer tar+gzip của `_next/`,
    không ký; chỉ workflow ký của nguồn (`ci_builder_id`) đẩy, cần `docker login`. Tag đã có thì kéo layer (có đăng nhập), kiểm như
    `gitops-sourcemaps.sh`, so cây với `DIR/_next`: giống thì để nguyên, khác thì đỏ, không ghi đè. `--dry-run` đọc ẩn danh, chỉ in.
    Test `deploy/ci/sourcemaps-image-test.sh` (job `config`; docker giả trả lời ORAS, đọc lại bằng `image_maps` của
    `gitops-sourcemaps.sh`).
  - `make helm-check` (`deploy/ci/gitops-check.sh --worktree`, cùng script với check của `svp-gitops`; cần bản clone `../gitops`
    hay `SVP_GITOPS_DIR`): `helm lint` và `helm template` mọi chart của working tree với `base/` của bản clone (`HELM_*_HOME` trong
    thư mục tạm), cộng overlay và file image của từng môi trường `envs/<stg|prd>/` ([ADR-0024](../adr/0024-multi-environment.md);
    prd chỉ render) và root chart `argocd/apps` của bản clone theo env × nền tảng × kiến trúc node (từ chối `targetRevision` tên ngắn
    vào `svp-gitops`; env nào trên nền tảng nào đọc từ khoá `platforms` của `components.json`, hôm nay stg trên `k3d`, `eks`, prd chỉ
    `eks`; `cluster` của `eks` lấy từ `deploy/ci/cluster-values.example.yaml`; render của nền tảng không `localHosts`, tức `eks`, không
    được nêu `svp.localhost`: grep cả render và policy `no-lab-hosts`); chart của working tree đứng thay `revision` của mọi env, nên không kiểm
    revision, giá trị dẫn xuất hay bản phát hành (việc của check `svp-gitops`);
    Secret của đường GitOps ([ADR-0026](../adr/0026-secrets-gitops.md)): render gốc của `svp-cluster` (đường dev) không có
    ExternalSecret hay SecretStore, mỗi env đúng 28 ExternalSecret và 4 SecretStore (stg provider `kubernetes`; prd provider `aws`
    và không còn `svp-secrets`), qua kubeconform `-strict` (`KUBECONFORM_IMAGE`, `--network none`) theo schema sinh từ CRD của
    chart External Secrets đúng version `components.json` ghim (provider `crd` bỏ khỏi schema SecretStore vì openapi2jsonschema
    sinh sai; không store nào dùng nó); cuối cùng mọi image (`helm template --include-crds` mọi component với values
    `base/` và Argo CD theo `bootstrap.json`) phải ghim đúng một `@sha256:` theo policy `images-pinned` của `deploy/ci/gitops-policies/`
    (Kyverno CLI `KYVERNO_CLI_IMAGE`, `--network none`; ref image ngoài các field policy đọc vẫn qua phép quét của script), image của
    render có overlay phải bằng render nó chồng lên (bước 4 của `gitops-check.sh`). Cần Docker và mạng tới mọi repo
    chart. `make trivy-config`: trivy quét cấu hình Dockerfile, chart, chỉ báo,
    trừ các mục của `deploy/ci/trivy-config-ignore.yaml` (dưới đây). `scan-gate.sh --fs` (cổng của
    `trivy fs` trên lockfile: CRITICAL chặn, cả chưa có bản vá, HIGH trở xuống chỉ đếm; 0 gói đọc được là lỗi) không target nào của repo
    này gọi: `make lockfile-scan` của `svp-frontend` chạy nó từ checkout ghim. `make renovate-check`: `renovate-config-validator --strict` trong `RENOVATE_IMAGE` ghim, không mạng. trivy, syft,
    grype, cosign, Renovate, k6, Schemathesis, kubeconform, Kyverno CLI, oasdiff, ORAS, yq chạy trên máy chỉ bằng image ghim digest của
    `Makefile` (`TRIVY_IMAGE`, `SYFT_IMAGE`, `GRYPE_IMAGE`, `COSIGN_IMAGE`, `RENOVATE_IMAGE`, `K6_IMAGE`, `SCHEMATHESIS_IMAGE`,
    `KUBECONFORM_IMAGE`, `KYVERNO_CLI_IMAGE`, `OASDIFF_IMAGE`, `ORAS_IMAGE`, `YQ_IMAGE`; yq của bước promote), không cài;
    `make kyverno-test`: `kyverno test` của `deploy/ci/gitops-policies/` (fixture đạt, hỏng mỗi policy; `gitops-check-test.sh` gọi nó);
    govulncheck là công cụ Go ghim `GOVULNCHECK_VERSION`, cài bằng `make tools`. Riêng cosign, script (`cosign_` của `deploy/ci/common.sh`) dùng `cosign`
    trên PATH trước nếu có (CI cài bằng `sigstore/cosign-installer`), không có thì `COSIGN_IMAGE`.
  - `.trivyignore.yaml` ở gốc repo (cổng trivy và cổng grype của image, `make grype` đọc; mỗi repo nguồn có tệp riêng ở gốc cây
    của nó, mục `@lhci/cli` của web ở `svp-frontend`; hiện có một mục: `CVE-2026-58016` của `glib` trong image `media-worker`, chưa có bản vá,
    ffmpeg không nạp `libgio` nơi có lỗi, [ADR-0030](../adr/0030-devsecops-supplement.md) §6): chỉ phần `vulnerabilities`, mỗi mục có `id`, `statement` (lý do),
    `expired_at` không quá 30 ngày sau ngày chạy và `purls` đúng gói@version (cùng CVE ở gói hay version khác vẫn báo);
    thêm qua PR; bí mật không bỏ qua được. Cổng grype dùng cùng tệp: một mục che một match khi `id` bằng id của match hay một
    id liên quan (grype hay báo GHSA, CVE nằm ở liên quan) và một `purls` bằng purl của match sau khi bỏ qualifier, subpath và
    giải mã `%XX`; mục không có `purls` không che gì; **nghiêm hơn trivy:** một mục hết hạn (từ đúng ngày `expired_at`) làm cổng
    grype đỏ cả khi report sạch. `deploy/ci/trivy-config-ignore.yaml` (chỉ `make trivy-config` đọc,
    [ADR-0021](../adr/0021-deferred-verification-stage6b.md) §9): chỉ phần `misconfigurations`, mỗi mục có `id` (`DS-…`,
    `KSV-…`), `paths` bắt buộc (file có thật, không pattern, thư mục hay `..`), `statement` có nội dung và `expired_at` không
    quá 90 ngày; chỉ lựa chọn có chủ đích vào đây, cảnh báo sửa được thì sửa. `scan-gate.sh --check-ignorefile` kiểm cả hai
    file ở job `config`: file sai quy tắc làm job đỏ ở mọi PR.
  - Renovate: GitHub App Mend, repo này và `svp-gitops` (người học cài, **kiểm sau push**); `renovate.json`: sáng thứ Bảy giờ Việt
    Nam, `minimumReleaseAge` 3 ngày (trừ cảnh báo lỗ hổng), bản `patch`, `digest` của Go module, base image, image của compose, CI và
    chart của repo tự merge (auto-merge của GitHub, squash) khi `ci-ok`, `images-ok` xanh, action, nhóm `tools`, `cosign`, minor, major
    giữ duyệt tay ([ADR-0035](../adr/0035-renovate-automerge.md); repo phải bật "Allow auto-merge"), không đụng `deploy/ci/drill/`, `gen/`; luật npm, Node, Sentry của web ở
    `renovate.json` của `svp-frontend` (cùng lịch); values của
    chart nền tảng, version chart trong `components.json`, bản cài Argo CD và digest phát hành ở `svp-gitops`, do `renovate.json` của
    repo đó quản (bỏ qua `envs/**`). Ghim mới trong `Makefile`, `lib.sh` hay values bên thứ ba theo dạng của
    ADR-0015 §10 (chú thích `# renovate: datasource=… depName=…` ngay trên dòng khi manager có sẵn không đọc được).
