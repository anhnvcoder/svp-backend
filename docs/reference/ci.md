# CI trên GitHub Actions, `svp-gitops`, Renovate

Loại tài liệu (Diátaxis): **reference**, tra cứu khi cần một lệnh hay một quy tắc cụ thể; luật làm việc ở [`AGENTS.md`](../../AGENTS.md).

## Workflow và cổng

- CI trên GitHub Actions ([ADR-0015](../adr/0015-cicd-devsecops-stage5.md)); workflow
  `verify.yml` kiểm chứng trên runner ([ADR-0021](../adr/0021-deferred-verification-stage6b.md)); `scorecard.yml` và `pr-title.yml` do
  [ADR-0041](../adr/0041-github-hardening.md) thêm. Năm workflow (DORA không còn workflow riêng:
  bài lab `dora/` của `svp-labs`, [ADR-0037](../adr/0037-mainpath-standard-tools.md) §1), mọi action
  ghim SHA commit, `permissions: {}` ở đầu file và quyền khai theo job; mọi job của lượt `pull_request` (cả PR từ fork)
  chỉ có `contents: read` và không secret; không `pull_request_target`, `workflow_run`. CI trung lập nền tảng
  ([ADR-0023](../adr/0023-ci-platform-neutral.md)): YAML chỉ nối bước, logic ở `Makefile` và `deploy/ci/`. Script đọc thẳng biến
  của GitHub Actions và gọi `gh` ([ADR-0037](../adr/0037-mainpath-standard-tools.md) §2): output vào
  `$GITHUB_OUTPUT`, tóm tắt vào `$GITHUB_STEP_SUMMARY` (helper `step_output`, `step_summary`, `step_summary_tee` của
  `deploy/ci/common.sh`), mask `::add-mask::`, cảnh báo `::warning::`, file tạm ở `$RUNNER_TEMP`, repo, commit và workflow của
  lượt từ `GITHUB_SERVER_URL`, `GITHUB_REPOSITORY`, `GITHUB_SHA`, `GITHUB_WORKFLOW_REF` (`run_repo_url`, `run_builder_id`). Chạy
  trên máy (không có biến nào) thì output và tóm tắt in ra stdout, không mask, file tạm ở `/tmp`, lượt là của repo của `code_root`
  (mục "Script CI cho cây của nguồn khác" dưới đây) ở `HEAD` với workflow `local`; lệnh ghi qua API của GitHub (dispatch) chỉ
  được in ra. CI trên GitLab là bài lab của `svp-labs`:
  - `.github/workflows/ci.yml` (PR, push `main`, dispatch): `check` (`make check-go TESTFLAGS=-count=1`, Postgres và
    Redis native là service container trên `127.0.0.1`, ffmpeg), `generate` (`make generate-check`), `buf` (`buf breaking` so với
    merge-base của PR, `main` trước push, hay merge-base với `origin/main` khi dispatch), `api-contract` (luật version của hợp đồng
    REST, [ADR-0033](../adr/0033-svp-web-repo.md) §1: `make api-contract-check BASE=<base>` với base tính như job `buf`, rồi
    `deploy/ci/contract-test.sh`), `config`
    (đủ lịch sử, `make gitops-clone` và `SVP_GITOPS_DIR` ở `env` của job; `make regal-lint`, `make conftest-verify`, `deploy/ci/scan-gate.sh --check-ignorefile`,
    test của script pipeline image trong job giả của Actions và trên máy (`deploy/ci/plan-test.sh`, `image-guard-test.sh` (guard và
    bước của ba composite action, đọc từ file action, docker giả), `image-gate-test.sh` (bước cổng của `image-leg` bằng trivy, syft,
    grype, conftest ghim thật trên fixture `deploy/ci/testdata/image-gate/`), `scan-gate-test.sh`,
    `vuln-predicate-test.sh`, `sign-image-test.sh` (hàm bundle của `common.sh` trên registry giả), `rescan-test.sh`,
    `verify-release-test.sh` cùng `values-check.sh`, `changed-services-test.sh`), `deploy/ci/promote-test.sh`
    (guard của hai job promote, danh sách bản phát hành của rescan),
    `deploy/ci/verify-collect-test.sh`, test các bước của `verify.yml` (`deploy/ci/verify-steps/steps-test.sh`, `supplychain-test.sh`,
    `admission-metrics-test.sh`, `objstore-test.sh`), `deploy/k8s/drills/run-test.sh` (cùng `new-values.sh` của diễn tập `reloader`), `deploy/k8s/rotate-test.sh`, `make chainsaw-lint`,
    `deploy/k8s/drills/gitops/gitops-test.sh`, `deploy/helm/svp-data/files/kafka-init-test.sh` và `deploy/ops/ops-test.sh` (script init Kafka và hai wrapper CLI vận hành với công cụ giả, không broker), `make slo-check`, `make otelcol-validate`, `make env`
    rồi `make compose-config`, `deploy/observability/glitchtip/dotenv-test.sh`,
    `make helm-check`, `deploy/ci/sources-test.sh`, `deploy/ci/gitops-check-test.sh "$SVP_GITOPS_DIR"`, `make k6-check`,
    `make cloud-check`),
    `gitleaks` (toàn lịch sử, `--redact`), `trivy-config` (chỉ báo), `zizmor` (lint bảo mật workflow, mục dưới),
    `dependency-review` (chỉ lượt `pull_request`: `actions/dependency-review-action` ghim SHA, `contents: read`,
    `fail-on-severity: high`, không `allow-licenses`; chặn dependency có lỗ hổng ngay lúc PR thêm vào,
    [ADR-0041](../adr/0041-github-hardening.md) (k)), `docs` (`make docs-check`: markdownlint-cli2 và lychee offline, image ghim digest,
    không mạng), `sarif` (chỉ `main`), check tổng `ci-ok` (cần đủ 11 job,
    trừ `sarif` và `stack`; `dependency-review` `skipped` ngoài lượt `pull_request` vẫn xanh; job `changes` chia PR theo vùng
    (tài liệu, `proto/`, hợp đồng REST, `.github/`, thứ stack compose chạy; `Makefile`, `*.mk`, `ci.yml` đổi thì chạy hết) và job
    nào PR không đụng vùng của nó thì skip, `ci-ok` nhận các skip đó; job khác `skipped` thì đỏ; job `web` cũ ở CI của
    `svp-frontend` từ khi web tách repo). Job `stack` (ADR-0020 §15; **chỉ báo, ngoài `ci-ok`**, không chặn merge; xem lại
    khi 20 lượt liên tiếp xanh, không lượt đỏ do môi trường, thì đưa vào `ci-ok`): `ubuntu-24.04`, tối đa 45 phút,
    `contents: read`, không secret; Postgres là service container publish trên `127.0.0.1` và IP bridge `172.17.0.1`
    (`make ci-bridge-check` dừng job khi gateway của network `bridge` khác địa chỉ đó; chỉ cho CI; Kafka và Valkey là container của stack compose,
    không publish cổng), gói apt
    `postgresql-client ffmpeg jq`, rồi `make gitops-clone`, `make web-clone` (commit của bản web stg; `SVP_GITOPS_DIR`,
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
    `verify.yml`, mọi test `*-test.sh`, `gitops-check.sh` cùng `values-check.sh`, `verify-release.sh`, policy `gitops-policies/` (chỉ check `svp-gitops`,
    `make k8s-gitops-up` và diễn tập chạy hai script này),
    `contract.sh`, `ghcr-digest.sh`: không job image nào đọc chúng), `deploy/k8s/lib.sh` hay dòng
    `TRIVY_IMAGE`/`SYFT_IMAGE`/`GRYPE_IMAGE`/`COSIGN_IMAGE` của `Makefile` hay một file dưới `.github/actions/image-*/` thì cả sáu;
    fixture `deploy/ci/testdata/` không build gì; chân `web` trong checkout này bị guard từ chối trước khi build). Base: push `main` so với lượt
    push `main` thành
    công cuối (lượt dispatch không đẩy base, nên thay đổi chỉ dispatch đã phát hành, như push GitHub không chạy workflow,
    được build lại ở push kế); PR so với merge-base với nhánh base; dispatch so với merge-base với `origin/main` (trên
    `main` là chính HEAD, nên không build gì), input `services` (`all` hay tên cách bằng khoảng trắng) ghi đè phép so. Mỗi
    service hai chân amd64, arm64 build native,
    cổng quét chạy **trước** push, một dòng tóm tắt mỗi lần quét
    trong summary của job ([ADR-0039](../adr/0039-mainpath-drills-scan-gate-sourcemaps.md) §2; mỗi chân là composite action
    `.github/actions/image-leg` ([ADR-0050](../adr/0050-bash-to-standard-tools.md)), các bước gọi thẳng `docker buildx build`, trivy, syft,
    grype bằng image ghim của `Makefile`, verdict là mã thoát của công cụ, guard ở `deploy/ci/image-guard.sh`; bước đầu chạy
    `scan-gate.sh --check-ignorefile`): trivy (báo cáo JSON mọi mức, cũng là nguồn của attestation `vuln` và SARIF) đọc lại hai lần bằng
    `trivy convert --exit-code`: bí mật mọi severity (không `--severity`, vì `--severity CRITICAL` giấu một bí mật HIGH), rồi lỗ hổng với `--severity
    CRITICAL --ignorefile .trivyignore.yaml`; grype ([ADR-0030](../adr/0030-devsecops-supplement.md) §6) quét SBOM syft của chân đó với `--fail-on critical`
    và `.grype.yaml` của cây được quét (`-c`), thấy cả binary ngoài trình quản lý gói (như `node` của image web, ở cổng của `svp-frontend`) mà
    trivy không thấy. Chặn: bí mật, và CRITICAL còn lại sau ngoại lệ (cả chưa có bản vá) ở báo cáo trivy hay grype; cho qua CRITICAL chỉ
    với image diễn tập `drill-vulnerable` (guard tính từ tên image) và rescan (`scan-gate.sh --allow-critical`), không bao giờ cho bí mật; HIGH trở xuống chỉ đếm (`(trivy): CRITICAL n, HIGH n, secrets n`,
    `(grype): Critical n, High n, excepted by .grype.yaml n`). Mã thoát 5 của `trivy convert` là có phát hiện, mã khác không đọc được báo cáo (thoát 2); grype
    `--fail-on` thoát 2 và vẫn ghi output. Hai file ngoại lệ được kiểm như ở mục `.trivyignore.yaml` dưới đây. DB grype cache theo ngày
    (`SVP_GRYPE_CACHE`), SARIF category `grype-image-<svc>-<arch>/` (chỉ HIGH, CRITICAL) lên tab Security ở `main`; push lên `ghcr.io/anhnvcoder/svp-backend/<svc>`
    đúng bản đã quét, ghép index, ký keyless bằng cosign kèm attestation `vuln` (kết quả trivy của hai nền tảng; attestation,
    Kyverno và rescan hằng ngày không đọc grype), SBOM syft mỗi nền tảng, mỗi thứ là một Sigstore bundle (referrer của
    digest; [ADR-0040](../adr/0040-sigstore-bundle-actions-attest.md)), và **build provenance** (chỉ bản phát hành, không image
    diễn tập): composite action `.github/actions/image-index` ghép index, `.github/actions/image-sign` ký và attest `vuln`, SBOM bằng
    cosign ghim `COSIGN_IMAGE` (guard `image-guard.sh sign` quyết trước loại nào cần ghi, output `repository`, `digest`,
    `provenance=true|false`); bước
    `actions/attest` (ghim SHA; `subject-digest` là digest index, `push-to-registry: true`; `attestations: write` chỉ ở job `sign`) chạy sau
    chúng khi `provenance=true`, dựng predicate SLSA v1 từ claim của token OIDC của lượt (`builder.id`, workflow, commit); trước khi ký gì
    guard đòi `builder.id` bằng `subject` của nguồn phát hành của lượt trong `sources.json`, không thì không ký. Bundle không có
    `--replace`: job chạy lại (Re-run failed jobs) liệt kê referrer của từng digest trước và chỉ ghi loại chưa có; digest đã có `.sig` định
    dạng cũ thì bị từ chối. Mức SLSA là Build L2 (không L3: attest chạy trong job của chính workflow build). Lượt phát hành đầu ở định dạng
    bundle chưa chạy: **kiểm sau push** (ADR-0040 mục Xác nhận); rồi
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
    nào, nên lượt đỏ); đọc PR bot lỗi thì vẫn quét `main` và `values_ref` rồi mới đỏ. Rescan theo nguồn (mục `rescan.sh` bên dưới): lượt của repo này chỉ quét và attest bản của nguồn `backend`; không repo nào attest bản của repo khác. Rescan theo định dạng đang có trên digest (`release_format` của `common.sh`):
    digest định dạng cũ (`.sig`, `.att`; stg và prd tới bản phát hành bundle đầu) `cosign attest --replace` như khi build; digest bundle
    attest `vuln` mới rồi gỡ mọi `vuln` bundle khác của digest bằng `oras manifest delete` (`replace_vuln_bundle`; ORAS ghim, quyền
    `packages: write` của job; không tin mã thoát của GHCR, đọc lại danh sách referrer, rồi cosign phải xác minh đúng một `vuln`; chữ
    ký, provenance, SBOM không bao giờ bị gỡ), vì Kyverno đọc bundle cuối danh sách referrer chứ không bundle mới nhất. `-f drill=true` đẩy ba image
    diễn tập `drill-vulnerable`, `drill-unsigned`, `drill-no-provenance` (hai cái ký và attest `vuln`: `drill-vulnerable` với
    `--allow-critical`, `drill-no-provenance` không CRITICAL; không image diễn tập nào có provenance; rescan hằng ngày không đụng). **Hợp đồng API** ([ADR-0033](../adr/0033-svp-web-repo.md) §1): job `contract` (mọi lượt build trên `main`: push, hay
    dispatch không `rescan`, `drill`, `promote_prd`; cùng nhóm concurrency không huỷ của build; quyền `contents: read`,
    `packages: write`, `id-token: write`) chạy `deploy/ci/contract.sh publish`: đẩy spec thành OCI artifact
    `ghcr.io/anhnvcoder/svp-backend/api/gateway:<info.version>` bằng ORAS (`ORAS_IMAGE` ghim; `artifactType`
    `application/vnd.anhnvcoder.svp.api-contract.v1`, một layer `application/vnd.oai.openapi`), ký keyless digest đó bằng cosign
    định dạng cũ với identity của nguồn `backend`; trước khi đẩy đòi lượt ký được bằng identity đó (`run_builder_id`). Tag đã có cùng
    layer thì để nguyên (thiếu chữ ký thì ký bù), tag có nội dung khác thì đỏ, không ghi đè. `contract.sh publish --dry-run` đọc
    registry ẩn danh và chỉ in việc sẽ làm. Lượt phát hành thật đầu và package `api/gateway` public: **kiểm sau push**. **Promote prd** ([ADR-0037](../adr/0037-mainpath-standard-tools.md) §6): dispatch
    `-f promote_prd=true [-f stg_ref=<main|SHA đủ 40 hex>]` trên `main` (một mình, không kèm `services`, `rescan`, `values_ref`, `drill`;
    `plan` bỏ qua mọi job khác) chạy job `promote-prd` (environment `promote-prd`, người học duyệt trước khi job chạy, token App `contents`, `pull_requests` write): bước shell
    chép giá trị khối `image` của cả bảy `envs/stg/images/*.yaml` và ba khoá của `envs/stg/charts.yaml` ở commit `stg_ref` của
    `svp-gitops` (mặc định `main`; commit cũ hơn là rollback) vào cùng file dưới `envs/prd/` bằng `yq -i` (comment của file prd giữ nguyên),
    đặt `gitopsRevision` của `envs/prd/charts.yaml` bằng chính commit đó (**ghim**: prd render `argocd/apps`, `base/`, `platforms/` ở commit stg đã
    chạy, `envs/prd/` đọc ở `main`; ADR-0048 §7), nhánh `bot/promote-prd`, mở PR không auto-merge (Code Owner duyệt), bảng trong mô tả có
    thêm dòng `gitopsRevision`. Rollback là một lượt với `stg_ref` cũ: PR đặt lại ghim cùng image, chart của commit đó. Environment `promote-prd` ([ADR-0041](../adr/0041-github-hardening.md) (d)): người duyệt là
    người học, `prevent_self_review = false` (người dispatch là người duyệt duy nhất), admin không bypass, chỉ nhánh `main`; khoá App ở đây là khoá
    riêng thứ hai của `svp-gitops-promoter`, `promote` của stg giữ nguyên. Reject thì không PR prd nào mở. Hai guard của `common.sh` chạy ở bước
    riêng trước khi tạo token App: `promote_stg_ref` chỉ nhận `main` hay SHA đủ 40 hex của một commit trên `main` của `svp-gitops` (nhánh,
    SHA ngắn, commit ngoài `main` bị từ chối); `promote_stg_evidence` (**bằng chứng stg**) đọc mọi trang commit status của commit đó
    (`gh api --paginate --slurp`, `GITHUB_TOKEN` của job, repo public) và đòi status mới nhất (id lớn nhất) của context `argocd/stg` là
    `success`, thứ Argo CD Notifications của stg ghi khi đồng bộ xong và Healthy ([ADR-0032](../adr/0032-argocd-deploy-status.md));
    `failure`, `pending`, không có status, hay lỗi API đều đỏ. Hệ quả: buổi prd cần buổi stg đã đồng bộ đúng commit sẽ promote. Cổng còn
    lại là duyệt environment `promote-prd` rồi duyệt của Code Owner trên PR prd. Check tổng `images-ok` (gồm `contract`; dispatch promote prd: `plan` skipped vẫn xanh). Provenance định dạng cũ trên bản phát hành
    đang chạy ở stg, prd đã kiểm (bảy bản của `6ca2d8a`, `cosign verify-attestation --type slsaprovenance1` và lượt `gitops` 40954609229);
    bản phát hành bundle: **kiểm sau push**, gồm đo admission thật (ADR-0040 mục 6). Đã kiểm ngày
    2026-10-30 với `promote.sh`, `promote-prd.sh` cũ: lần promote stg đầu và auto-merge của PR bot (PR #4, #5, #6 của `svp-gitops`, lượt
    `images.yml` 40984668411 trên `2d9dab0`), promote prd (lượt 41022346853, PR #7 `523ba34`, người học duyệt); bước shell thay chúng:
    **kiểm sau push**. Rescan đọc `svp-gitops` (lượt 41018158008: 14 digest của stg và prd, 28/28 qua cổng quét).
  - **zizmor** ([ADR-0041](../adr/0041-github-hardening.md) (g)): `make zizmor` chạy zizmor `ZIZMOR_IMAGE` (image chính thức ghim `tag@sha256`,
    `# renovate:` ngay trên dòng) với `--persona=regular` trên cả repo, repo gắn chỉ đọc; mọi finding chặn (mã thoát 11–14). Có `GH_TOKEN` thì
    thêm audit online (impostor commit, action có lỗ hổng), không thì offline; CI truyền `GITHUB_TOKEN` của job, chỉ `contents: read`.
    `ZIZMOR_FORMAT=github` cho annotation, `ZIZMOR_SARIF=<đường dẫn>` ghi SARIF (không chặn; job `zizmor` đẩy artifact cho job `sarif`, category
    `zizmor`). Ngoại lệ ở `.github/zizmor.yml` (`rules.<id>.ignore`), mỗi mục một comment lý do. Job nằm trong `ci-ok`, không thêm check bắt buộc.
  - `.github/workflows/scorecard.yml` ([ADR-0041](../adr/0041-github-hardening.md) (g)): OpenSSF Scorecard khi push `main`, hằng tuần và khi đổi
    branch protection cổ điển; `publish_results: true` (kết quả công khai ở API Scorecard), SARIF lên code scanning; không `repo_token`
    (Branch-Protection đọc ruleset bằng `GITHUB_TOKEN`). Không phải check của PR. Luật workflow của Scorecard (không `env` mức workflow, chỉ job
    Scorecard có `id-token: write`, chỉ gồm action được duyệt) ở [`ci-cd.md`](../ci-cd.md) mục 3. `ossf/scorecard-action` có trong pattern Actions của repo
    (`github/repositories.tf` của `svp-infra`). Lượt đầu trên `main` xanh và có kết quả ở API Scorecard: **kiểm sau áp**.
  - `.github/workflows/pr-title.yml` ([ADR-0041](../adr/0041-github-hardening.md) (h)): job `pr-title` kiểm tiêu đề PR theo Conventional Commits
    bằng `[[ =~ ]]` của bash (tiêu đề vào script qua `env`, `permissions: {}`), chạy khi `opened`, `edited`, `reopened`, `synchronize`; chạy trước
    bộ tiêu đề thử của ADR (đạt, không đạt) để regex hỏng đỏ mọi PR chứ không chỉ vài PR. Tiêu đề thành tiêu đề commit squash. `pr-title`
    thành check bắt buộc của ruleset `main` chỉ sau khi xanh trên một PR người và một PR bot: **kiểm sau áp**.
  - `.github/workflows/verify.yml` ([ADR-0021](../adr/0021-deferred-verification-stage6b.md), thu gọn ở
    [ADR-0039](../adr/0039-mainpath-drills-scan-gate-sourcemaps.md) §1; không check bắt buộc nào, không chạy ở PR): kiểm trên runner `ubuntu-24.04`
    những gì máy 16 GB không chạy nổi, bằng đúng target `make` như trên máy. Trigger: `workflow_dispatch` (chỉ người có quyền ghi; ref
    `main` hay `feat/stage6b-*`, ref khác dừng ở bước đầu) và lịch hằng tuần trên `main` (00:37 UTC thứ Bảy, 07:37 giờ Việt Nam; cả hai kịch bản
    song song, mọi bước). Ba kịch bản, mỗi kịch bản một job (`dev-k3d` chỉ dispatch); lượt lịch đầu sau khi thu gọn: **kiểm sau push**.
    - `compose-obs` (job `compose`, hạn 155 phút): `make up OBS=lgtm`, `make smoke`, `make drill-obs-threats`, rồi `test-stack-objstore`
      (`deploy/ci/verify-steps/objstore.sh`: `make test-stack PKGS=./internal/objstore/...`, một ca SKIP là đỏ, gồm ba test của output bất
      biến): nơi duy nhất test `internal/objstore` chạy thật thay vì SKIP.
    - `gitops` (job `gitops`, hạn 250 phút): `make k8s-gitops-up` (vai stg; `make gitops-clone` trước; `GITOPS_REV` là SHA của `origin/main` trong
      bản clone, nên cluster ở yên commit đó suốt các bước kiểm, PR promote merge giữa chừng không đổi gì), `make drill-k8s-gitops` (ba test
      Chainsaw ở `deploy/k8s/drills/gitops/`: `gitops-env` (overlay stg có trong Application `gateway` và trên mọi pod gateway đang chạy, kiểm khai
      báo), `gitops-external-secrets` (ExternalSecret của cluster đúng bằng danh sách `files/external-secrets.yaml` của chart `svp-cluster` ở
      commit Application `argocd/svp-cluster` chạy chart đó, mỗi cái `Ready`, Secret đích đúng type và đúng tên key, không đọc giá trị; entry có
      `enabledBy`, như `argocd/argocd-notifications-secret`, chỉ được đòi khi Application đó liệt kê ExternalSecret của nó, tức Argo CD render nó
      từ values cluster chạy, dòng `not wanted` khi không), `gitops-argocd-metrics` (trong 180 s Prometheus thấy `argocd_app_info` của mọi
      Application, đều Synced và Healthy, không cảnh báo `ArgoCDApplication*` nào cháy; chart Application `svp-observability` đang chạy chưa có
      PodMonitor của Argo CD thì nói vậy và qua); cả hai đọc chart ở commit của lịch sử repo này nên checkout lấy đủ lịch sử),
      `gitops-admission-metrics` (`deploy/ci/verify-steps/admission-metrics.sh`: số đo thời gian admission của lượt sync đầu, chạy trước smoke và
      diễn tập để histogram chỉ chứa lượt sync đầu; điều kiện của
      [ADR-0040](../adr/0040-sigstore-bundle-actions-attest.md) mục 6: 20 s lần không cache, hạn webhook 30 s. Các histogram và cách đọc ở mục `verify-steps/admission-metrics.sh` bên dưới; thiếu metric thì dòng `NOTE`, bước không đỏ),
      `make k8s-smoke` (chặt, không biến chuyển tiếp), `make drill-k8s-reloader` (xoay credential qua External Secrets, mục của nó ở
      [`k8s.md`](k8s.md); các bước sau chạy trên credential mới), `drill-k8s-supplychain` (`deploy/ci/verify-steps/supplychain.sh` gọi
      `make drill-k8s-supplychain`; ảnh chưa ký của ca (b), (h), (i) là digest mới nhất của
      `drill-unsigned` (không chữ ký, không attestation nên không có hạn 72 giờ); ca (l) là digest mới nhất của `drill-no-provenance` dưới
      prefix của `backend`, lấy như ca (c) lấy `drill-vulnerable`; cả ba do `deploy/ci/ghcr-digest.sh` đọc ẩn danh từ GHCR, không đọc được thì ca SKIP (trừ `drill-unsigned`: drill tự tra lại) và bước đỏ sau drill; chỉ ở lượt lịch, `SVP_VERIFY_SCHEDULED=true`,
      image của ca (c) hay (l) có attestation `vuln` quá 72 giờ thì không đưa cho drill: ca đó SKIP kèm dòng `NOTE` nêu tuổi và lệnh dispatch
      dựng lại image diễn tập (`-f drill=true`), mọi ca khác vẫn phải PASS; lượt dispatch quá hạn là đỏ, nên (c), (l) chỉ được chứng minh ở lượt
      dispatch sau lượt đó), `make drill-k8s-threats`.
    - `dev-k3d` (job `dev-k3d`, hạn 210 phút, chỉ dispatch, [ADR-0050](../adr/0050-bash-to-standard-tools.md) mục 6): đường dev như trên
      máy, `make k8s-up` (sáu image build trên runner bằng bake, web là bản phát hành stg, `make gitops-clone GITOPS_REF=<gitops_ref>`
      trước), `make k8s-smoke`, `make drill-k8s-reloader`, `drill-k8s-supplychain` (như kịch bản `gitops`, với `SUPPLYCHAIN_ENFORCE_TMP=1`:
      policy Audit của đường dev sang Enforce cho từng ca rồi trả lại, và ca (k), ca chỉ đường dev chạy được). Input `gitops_ref`: `main`
      (mặc định) hay SHA đủ 40 hex của `svp-gitops`, để chạy với nhánh chưa merge; khác thì job đỏ trước khi dựng gì, không in lại giá trị.
    - Đã rời `verify.yml`, nay là bài lab `drills/` của `svp-labs` (cả script diễn tập compose, [ADR-0050](../adr/0050-bash-to-standard-tools.md)): bản đo một lần của kịch bản `dev-k3d` (RAM, KEDA, PDB, canary, backup), các kịch bản `web-canary`, `k6-cloud-mini`, `chaos`, `velero`, phần còn lại của `compose-obs` (load-local,
      Lighthouse, `drill-duplicates`, `drill-kill-worker`, `drill-upload-cleanup`, `measure-upload`, `drill-alert-to-sentry`, đường quay lại
      `object-store-roundtrip`), bước chờ phát hành và `measure-gitops`, `verify-sample.sh`, `verify-tempo.sh`. Số đo và id lượt chạy ở các ADR 0014, 0017, 0019, 0020, 0021, 0022, 0031. Bản clone
      `svp-frontend`, Node, pnpm, Playwright và image source map không còn trong workflow; `web_ref` không còn là input.
    Dispatch và đọc kết quả (AI được chạy, chỉ khi người học giao): `gh workflow run verify.yml --ref <main|feat/stage6b-…>
    -f scenario=<compose-obs|gitops|dev-k3d> [-f targets='<bước> …'] [-f gitops_ref=<main|SHA>]` (`targets` rỗng là mọi bước, bước dựng luôn chạy; tên bước là
    `SVP_VERIFY_STEP_NAMES` của job và cột đầu của `results.tsv`, ví dụ `targets='k8s-smoke drill-k8s-supplychain'`; tên lạ hay ký tự ngoài
    `a-z`, `0-9`, `-`, khoảng trắng thì job đỏ trước khi dựng gì; chỉ lọc, không tự thêm bước: `drill-k8s-threats`, `drill-k8s-reloader` cần
    `k8s-smoke` đi cùng),
    `gh run view <id> --log`, `gh run download <id> -n verify-<kịch bản>`. Mỗi target là một bước Actions, id là tên target, `timeout-minutes`
    riêng; output vào `$RUNNER_TEMP/verify/logs/<bước>.log`, không vào log job; bước sau bước dựng chạy khi bước dựng xanh dù bước giữa đỏ, và
    bị bỏ khi bước dựng đỏ; job đỏ khi một bước đã chạy đỏ. Hạn job đủ cho 20 phút cài đặt, tổng `timeout-minutes` của các bước và 25 phút cho
    các bước cuối (bảng kết quả, lọc, tải artifact, gỡ), chạy `always()` khi kiểm ref qua, kể cả khi huỷ hay quá giờ. Mỗi lượt chạy
    `make gitops-clone` (`main` của `svp-gitops`, `gitops_ref` ở `dev-k3d`, ẩn danh) và đặt `SVP_GITOPS_DIR` tới bản clone cho mọi bước sau;
    cả ba kịch bản chạy image web của bản phát hành stg. Mọi job chỉ `contents: read`, không secret hay environment; `concurrency` một lượt mỗi
    kịch bản. Script: `deploy/ci/verify-host.sh` (cổng đĩa, `/etc/hosts` cho ba tên `*.svp.localhost`, lệch version kubectl), các bước ở
    `deploy/ci/verify-steps/` (`steps.sh check|table`: kiểm `targets`, bảng `results.tsv` từ outcome của từng bước; `supplychain.sh`,
    `admission-metrics.sh`, `objstore.sh`; mỗi script một test cạnh nó), `verify-mask.sh` (`::add-mask::` giá trị bí mật của `.env` sau `make
    env` và sau bước dựng, cùng Secret trong cluster ở namespace `svp`, `svp-data`, `svp-obs`, `argocd`, `svp-secrets`), bước "New values of
    drill-k8s-reloader" của job `gitops` và `dev-k3d` (trước bước dựng: `deploy/k8s/drills/reloader/new-values.sh` sinh giá trị mới vào
    file 600 ở `$RUNNER_TEMP/verify-reloader`, mask từng giá trị lúc sinh, diễn tập đọc qua `SVP_DRILL_NEW_VALUES`), `verify-collect.sh`
    (artifact `verify-<kịch bản>`, giữ 30 ngày: chỉ kết quả máy đọc theo danh sách cho phép: `results.tsv`, `scenario`, `df-before.txt`, dòng kết
    luận của `drill-obs-threats`, số đo admission, `k8s-state.json` khi `make k8s-up` đỏ, `.k8s/drills/{*.xml,*-skips.tsv,*.json,traffic-*.log}` gồm report JUnit của diễn tập Chainsaw và `<diễn tập>-skips.tsv` (mỗi
    dòng một ca SKIP kèm lý do, dòng cuối `total`: report JUnit tính bước SKIP là xanh nên file này mới cho biết ca nào bị bỏ; quét bí mật như file
    khác); output của các bước khác không bao giờ lên; quét theo giá trị bí mật đã biết và theo mẫu (JWT, Bearer, `Set-Cookie`, khoá riêng, cookie phiên), file
    nghi bị bỏ kèm `::warning::`, `files.txt` liệt kê file giữ và bỏ). `deploy/ci/verify-collect-test.sh` chạy trên máy và ở job `config` (giá
    trị giả, `docker`/`kubectl` giả, không mạng).
  - DORA là bài lab `dora/` của `svp-labs` ([ADR-0037](../adr/0037-mainpath-standard-tools.md) §1, thay [ADR-0028](../adr/0028-dora-metrics.md)):
    `dora.yml`, `dora.sh`, `dora-test.sh` đã rời repo này; front matter của `docs/postmortems/` vẫn là dữ liệu cho bài lab đó.
  - **`svp-gitops`** (`https://github.com/anhnvcoder/svp-gitops`, public, không secret; [ADR-0025](../adr/0025-gitops-config-repo.md),
    quy trình tay ở [`docs/runbooks/svp-gitops-setup.md`](../runbooks/svp-gitops-setup.md)): `base/` (values gốc của chart upstream,
    `argo-cd.yaml`, `services/<svc>.yaml` không khối `image`), `envs/{stg,prd}/` (overlay, `svp-policy.yaml`, `charts.yaml` ghim
    commit chart của repo này cùng hai giá trị dẫn xuất, riêng prd có thể thêm `gitopsRevision`, `images/<svc>.yaml` chỉ khối `image`),
    `argocd/` (`project.yaml`, `bootstrap.json`, chart app-of-apps `apps/` với `components.json`, root hai tầng `root/`), `CODEOWNERS` (`*` của người học, `/envs/stg/` không chủ),
    `renovate.json` (chart upstream, image ghim trong `base/`, commit checker; bỏ qua `envs/**`). Check: `.github/workflows/check.yml`
    (PR và push `main`, chỉ quyền đọc, không secret) checkout repo này (`anhnvcoder/svp-backend`) ở `CHECKER_COMMIT` (SHA đủ, một chỗ
    trong workflow; đổi bằng PR ở `svp-gitops`) rồi chạy `deploy/ci/gitops-check.sh <cây> <base>`, bản rút gọn
    ([ADR-0037](../adr/0037-mainpath-standard-tools.md) §4–§6; bước 1b "bộ prd = payload một bản ghi stg", 1c dạng cũ (tiếp quản, đọc
    qua adapter), luật tổ tiên và đường cho cây chưa có `platforms/` hay commit chưa có bảng nguồn đã bỏ): (1) cây và `charts.yaml` (khoá,
    `revision` trên `main` repo này, hai giá trị dẫn xuất tính lại; `gitopsRevision` chỉ ở prd, 40 hex, cây có nó thì phải có
    `argocd/root/Chart.yaml`, và script kiểm bằng git trong bản clone `svp-gitops` (cần đủ lịch sử, `origin/main`) rằng nó là commit có
    trong clone, trên `origin/main` và chứa `argocd/apps/Chart.yaml`), mỗi `envs/<env>/images/<svc>.yaml` là `<imagePrefix><svc>` của một
    nguồn có `<svc>` trong bảng nguồn ở `revision` của env; lớp nền tảng theo khoá `platforms` của `components.json` (thiếu hay sai dạng
    là đỏ, tên nền tảng khớp thư mục `platforms/`); luật tác giả hẹp viết từ bảng nguồn (dưới đây); (2) render root theo env × nền tảng
    của `platforms` × kiến trúc (mọi `targetRevision` vào `svp-gitops` phải tên đầy đủ), với giá trị `cluster` của nền tảng `eks` là
    `deploy/ci/cluster-values.example.yaml` (đứng thay annotation `svp.io/cluster-values` mà GitOps Bridge đặt lên cluster Secret, đủ khoá
    của hợp đồng, gồm map `externalSecretsRoles`). Cây có `argocd/root` thì render hai tầng như Argo CD: tầng 1 `argocd/root` của cây phải ra
    đúng một Application `svp-apps`, nguồn `argocd/apps` của `svp-gitops` ở commit ghim (không ghim: `refs/heads/main`), cùng giá trị đó ở
    `valuesObject.targetRevision`; tầng 2 là `argocd/apps` với `valuesObject` đó. Ở root hai tầng `envs/<env>/` không là file values: tầng 1
    chuyển nội dung, `valuesObject` của mỗi Application phải bằng overlay < file image của `envs/<env>/` trên cây < phần mẫu
    `.values.tpl` sinh ra (lấy từ lượt render tầng 2 thứ hai với nội dung overlay, image để rỗng), gộp như Helm (`*` của jq); mọi nguồn
    `svp-gitops` của một Application cùng một `targetRevision` (repo-server của Argo CD từ chối file values trỏ một repo ở hai revision). Env có
    ghim render riêng trên `git archive` của commit ghim (`argocd/`, `base/`, `platforms/`, bootstrap Argo CD; các bước 2–4 cũng vậy) với
    `envs/<env>/` của cây: mọi nguồn `svp-gitops` của tầng 2 ở commit ghim, mọi file values qua `$values/` ở commit đó (đọc ở revision khác là
    đỏ), chart repo này ở `revision` của `charts.yaml` trên cây; env không ghim render trên cây như trước; (3) chart repo ở `revision` của env với `base/`,
    `platforms/` và overlay, External Secrets qua kubeconform (số ExternalSecret, SecretStore mỗi env × nền tảng theo dữ liệu, như
    `make helm-check`), render của nền tảng không `localHosts` không nêu `svp.localhost` (grep cả
    render và policy `no-lab-hosts`); (4) mọi image ghim digest bằng policy `images-pinned` (dưới đây; ref ngoài tầm policy vẫn qua phép
    quét của script), render có overlay không đổi version image của render nó chồng lên; (5) `values-check.sh --gitops` cho file image đổi
    (chữ ký, `vuln`, provenance env đòi; provenance có thì tag là 12 hex của commit nó nêu). Check tổng `gitops-ok`. Tag image không còn
    phải là tổ tiên của `revision`, PR prd không còn so bản ghi (cổng prd là duyệt environment `promote-prd` ở repo code rồi duyệt của Code Owner). `CHECKER_COMMIT` là một commit trên
    `main` repo này; `check.yml` của commit checker cũ còn `deployments: read` và `GH_TOKEN` cho bước 1b: PR prd đỏ cho tới khi nâng
    `CHECKER_COMMIT` lên commit có bản rút gọn, cùng PR bỏ hai thứ đó. **Luật tác giả hẹp** (bước 1 khi có base; tác giả
    `pull_request.user.login` và người gửi `sender.login` đọc thẳng từ `GITHUB_EVENT_PATH`, trên máy `SVP_CHANGE_REQUEST_AUTHOR` đóng vai
    tác giả): bot `<promoter>[bot]` của nguồn N chỉ đổi `envs/{stg,prd}/images/<svc>.yaml` với `<svc>` thuộc `services` của N (bảng ở
    `revision` env ghim sau thay đổi); bot của `backend` đổi thêm `envs/{stg,prd}/charts.yaml` và mọi file `envs/prd/images/` (promote prd
    chép cả bộ, gồm web); không bot nào xoá file; bot `[bot]` không phải promoter (Renovate) không đổi gì dưới `envs/`; người gửi là bot
    khác tác giả thì đỏ; tác giả hay người gửi không đọc được thì đỏ; PR của người không bị giới hạn; không base hay không phải PR thì
    một dòng `skip`. Lý do: `/envs/stg/` không Code Owner nên PR bot tự merge, bỏ hẳn luật thì khoá App lộ đổi được `charts.yaml` hay
    overlay stg mà không ai duyệt (GIT-6). **Policy conftest của cây** (`deploy/ci/gitops-tree-policies/`, Rego, một package mỗi
    file: `layout.rego` file của root chart và bootstrap, `argocd/apps/values.yaml` không đặt `cluster`; `envs.rego` thư mục env,
    `charts.yaml`, `images/`; `platforms.rego` lớp nền tảng và luật overlay của file nền tảng; `author.rego` luật tác giả hẹp; input và
    helper ở `lib.rego`; ca âm ở `*_test.rego`): luật của bước 1 viết một lần ở đây. Bước 1 của `gitops-check.sh` chỉ dựng input, một tài
    liệu JSON: mục và nội dung file của cây; với mỗi env, `revision` có là commit trên `main` repo này không (không thì một dòng `FAIL`),
    hai giá trị commit đó dẫn xuất và bảng nguồn ở commit đó (git đọc); tác giả, người gửi và file đổi từ base của PR. Rồi nó chạy
    `conftest test` bằng `CONFTEST_IMAGE` ghim (`--network none`, `--read-only`, uid của người gọi, policy và input mount chỉ đọc);
    conftest không trả lời, hay một package không có kết quả nào (policy không biên dịch, package đổi tên), là đỏ. `gitops-check.sh
    --tree <cây> [<base>]` chạy riêng bước 1. **Policy Kyverno CLI** (`deploy/ci/gitops-policies/`: `images-pinned.yaml`,
    `no-lab-hosts.yaml`, `ValidatingPolicy` CEL; fixture đạt và hỏng ở `test/<policy>/`): `gitops-check.sh` render rồi đưa manifest cho
    `kyverno apply` bằng `KYVERNO_CLI_IMAGE` ghim của `Makefile` (cùng minor với Kyverno của cluster, `--network none`), message
    `<file>: <Kind> <ns>/<name>: <message>`; `make kyverno-test` chạy `kyverno test` của thư mục đó; `gitops-check.sh --policy
    images-pinned|no-lab-hosts FILE...` áp một policy lên manifest có sẵn. Ba ruleset (Terraform ở `github/rulesets.tf` của `svp-infra`): `main` (PR chỉ squash, lịch sử thẳng, `gitops-ok` bắt buộc, cấm xoá và force push, không ai
    bypass), `owners` (duyệt của Code Owner; vai admin bypass chỉ ở chế độ `pull_request`, có bản ghi), `tags` (cấm tạo, sửa, xoá tag;
    chỉ admin bypass), cộng dồn: PR bot chỉ đổi `envs/stg/` tự merge, PR prd và Renovate cần người học duyệt, PR của người học trên file
    có chủ merge bằng bypass `owners` mà vẫn cần `gitops-ok`. Đã kiểm: commit khởi tạo `55258e1`, commit thêm check `a84e26d`, lượt
    `check` đầu 40902199532 xanh (token chỉ `Contents: read`), ba ruleset `active` (2026-10-29); PR bot chỉ đổi `envs/stg/` tự merge đã kiểm ngày 2026-10-30 (PR #4, #5, #6). **Không đạt:** PR của người học đổi file có chủ merge được không
    cần duyệt và không có bản ghi bypass (PR thử #8 ở trạng thái `CLEAN`, PR #3 có rule suite `pass`): GitHub coi tác giả PR kiêm Code Owner duy nhất là
    đã thoả `require_code_owner_review`, nên người học không tự kiểm mình bằng duyệt, kiểm tự động `gitops-ok` là lớp chặn còn lại; luật vẫn áp lên PR của người
    khác, ca âm cho PR của bot chưa có (việc mở: App thứ hai).
  - Cài đặt GitHub của repo là code ở `github/` của `svp-infra` ([ADR-0041](../adr/0041-github-hardening.md)). Ruleset `main`: PR (0 approval: tác
    giả không tự duyệt PR của mình, lab một người), check bắt buộc `ci-ok`, `images-ok` chỉ nhận từ app GitHub Actions (`pr-title` thêm vào sau khi
    xanh trên một PR người và một PR bot), chỉ squash (`allowed_merge_methods = ["squash"]`, chặn cả khi cài đặt repo bị mở lại; commit lấy
    `PR_TITLE` + `PR_BODY`), `required_linear_history`; `strict_required_status_checks_policy` giữ `false` (bật thì mỗi PR, cả PR bot tự merge, phải
    cập nhật nhánh và build lại image sau mỗi merge; merge queue chỉ có ở repo của organization; lượt CI trên `main` sau merge bắt xung đột ngữ nghĩa).
    Ruleset `owners` đòi duyệt Code Owner (`require_code_owner_review`; vai admin bypass chỉ ở chế độ `pull_request`, có bản ghi) trên file có chủ ở
    `CODEOWNERS` (`/CODEOWNERS`, `/.github/`, `/renovate.json`, `/Makefile`, `/.trivyignore.yaml`, `/.grype.yaml`, `/deploy/ci/`,
    `/deploy/helm/svp-policy/`); file khác không chủ để PR Renovate tự merge vẫn chạy, và không file nào vừa được tự merge vừa có Code Owner. Cài
    đặt của ADR-0015 §11: quyền mặc định của `GITHUB_TOKEN` chỉ đọc và **không** "Allow GitHub Actions to create and approve pull requests"
    (không workflow nào mở hay duyệt PR bằng `GITHUB_TOKEN`; PR promote dùng token App); Actions chỉ cho action của GitHub, `sigstore/cosign-installer`
    và `ossf/scorecard-action`, ghim SHA bắt buộc; duyệt workflow của PR fork cho mọi người ngoài; secret scanning + push protection; Dependabot
    alerts. Package GHCR public do người học bật (ADR-0015 §5, §11). Áp theo thứ tự cài đặt repo, ruleset (chưa có `pr-title`), environment
    `promote-prd` với khoá thứ hai, rồi merge `CODEOWNERS`, workflow, `renovate.json`: **kiểm sau áp**. Quyền deploy không còn ở repo này: push vào
    `main` không đổi cluster nào, chỉ PR vào `svp-gitops` đổi được thứ đang chạy; environment `promote` (stg) và `promote-prd` (prd) của repo này
    giữ khoá App, chỉ job trên `main` khai chúng (`promote` và `promote-prd` của `images.yml`), không job `pull_request` nào.
  - CodeQL **default setup** ([ADR-0030](../adr/0030-devsecops-supplement.md) §4): bật bằng cài đặt repo, không file workflow
    trong repo (GitHub dựng và giữ workflow động "CodeQL"); ngôn ngữ `actions`, `go`, `javascript-typescript`, query suite
    `default`, threat model `remote`; quét mỗi push `main`, PR từ nhánh của repo (không PR từ fork) và hằng tuần. **Chỉ báo:**
    không là check bắt buộc, cảnh báo ở tab Security (giả thì dismiss kèm lý do), gosec vẫn là cổng chặn. Job CodeQL chạy `make`
    không đối số của commit được quét (autobuild Go), token chỉ có quyền ghi `security-events` (đọc từ log ngày 2026-10-29).
    Lệnh bật, tắt và đọc kết quả (người học chạy) ở [`docs/ci-cd.md`](../ci-cd.md) mục 7.
  - Chạy lại một job trên máy, từ gốc repo: `make check-go TESTFLAGS=-count=1`; `make generate-check`;
    `buf breaking --against '.git#ref=<base>'`; `make api-contract-check BASE=<base>`, `deploy/ci/contract-test.sh`;
    `make conftest-verify`, `deploy/ci/scan-gate.sh --check-ignorefile`,
    `deploy/ci/plan-test.sh`, `image-guard-test.sh`, `image-gate-test.sh`, `scan-gate-test.sh`, `vuln-predicate-test.sh`,
    `sign-image-test.sh`, `rescan-test.sh`,
    `verify-release-test.sh`, `changed-services-test.sh`, `make slo-check`,
    `deploy/ci/promote-test.sh`,
    `make otelcol-validate`, `make compose-config`, `deploy/observability/glitchtip/dotenv-test.sh`, `make helm-check`, `make kyverno-test`, `deploy/ci/sources-test.sh`,
    `deploy/ci/gitops-check-test.sh ../gitops` (test của policy cây qua `make conftest-verify`, rồi ca của phần bash và render), `make k6-check`,
    `make cloud-check`; check của `svp-gitops` trên bản clone: `deploy/ci/gitops-check.sh ../gitops` (cần mạng tới repo chart, GHCR;
    ~5 phút); `gitleaks git --redact --no-banner`; `make trivy-config`; một chân image (build, quét, cổng) chỉ chạy trong Actions
    (job `build-nopush` của PR), bước của nó thử trên máy bằng `deploy/ci/image-guard-test.sh`, `image-gate-test.sh`; riêng cổng grype của
    một chân: `make grype IMAGE=<ref>@sha256:<digest>
    [ARCH=amd64|arm64]` (syft ghim đọc image từ registry, ẩn danh) hay `make grype SBOM=<đường tuyệt đối tới SPDX JSON>`, in số
    gói và binary ngoài trình quản lý gói; bước `dast` của job `stack`: `make dast` trên stack `make up`; service nào sẽ build: `deploy/ci/changed-services.sh <base>
    HEAD`; bộ lọc artifact của `verify.yml`: `deploy/ci/verify-collect-test.sh`; các bước của nó: `deploy/ci/verify-steps/*-test.sh`; diễn tập
    gitops không cluster: `deploy/k8s/drills/gitops/gitops-test.sh`. Push GHCR, ký, attest chỉ chạy
    trong CI: không đăng nhập GHCR hay Sigstore từ máy. Bước promote stg, prd
    chỉ chạy trong CI (token App); guard của chúng thử bằng `deploy/ci/promote-test.sh`.
  - **Script CI cho cây của nguồn khác** ([ADR-0033](../adr/0033-svp-web-repo.md) §5): CI của một nguồn phát hành khác (`svp-frontend`)
    gọi composite action `./.backend/.github/actions/image-*` và chạy `deploy/ci/*.sh` từ checkout ghim `.backend/` của repo này, với
    `code-root` (`SVP_CODE_ROOT`) trỏ checkout của chính nó. `common.sh` có hai gốc:
    `script_root` (checkout này: `lib.sh`, image ghim của `Makefile`, bảng nguồn) và `code_root` (`SVP_CODE_ROOT` nếu đặt, phải là
    thư mục; không thì checkout này). Nguồn của lượt là nguồn có `repository` bằng `run_repo_url` (`use_build_source`; repo không có
    trong bảng thì không build, đẩy hay ký gì); image phải thuộc `services`/`drillImages` của nguồn đó, đẩy dưới prefix của nó, nhãn
    OCI theo nguồn; HEAD của `code_root` phải bằng commit của lượt (`check_code_tree`). Cây repo khác: `Dockerfile` và context ở gốc,
    phải có `Dockerfile`, `pnpm-lock.yaml`, `.trivyignore.yaml`, `.grype.yaml` (cổng quét đọc file của cây đang build; thiếu một file là cây sai, không phải cây không ngoại lệ); `plan.sh` build mọi service
    của nguồn mỗi lượt, không base, `promote_charts=false`. Trên máy, repo của lượt (`run_repo_url`) đọc từ origin
    github.com của `SVP_CODE_ROOT` (không có origin đó thì lỗi), commit là HEAD của nó. Composite action nhận cây khác qua input
    `code-root` (thành `SVP_CODE_ROOT` của bước); ca của chân, index và chữ ký web từ cây khác ở `deploy/ci/image-guard-test.sh`.
    Image source map `web-sourcemaps` không còn ([ADR-0039](../adr/0039-mainpath-drills-scan-gate-sourcemaps.md) §3): `image-leg` không xuất
    source map; tải source map lúc build vào tracker chạy lâu dài làm khi có tracker đó. Digest mới nhất của image diễn tập
    lấy bằng `deploy/ci/ghcr-digest.sh newest IMAGE` (đọc GHCR ẩn danh bằng ORAS ghim `ORAS_IMAGE`: `oras repo tags`, `oras resolve`).
  - `make helm-check` (`deploy/ci/gitops-check.sh --worktree`, cùng script với check của `svp-gitops`; cần bản clone `../gitops`
    hay `SVP_GITOPS_DIR`): `helm lint` và `helm template` mọi chart của working tree với `base/` của bản clone (`HELM_*_HOME` trong
    thư mục tạm), cộng overlay và file image của từng môi trường `envs/<stg|prd>/` ([ADR-0024](../adr/0024-multi-environment.md);
    prd chỉ render) và root chart `argocd/apps` của bản clone theo env × nền tảng × kiến trúc node (từ chối `targetRevision` tên ngắn
    vào `svp-gitops`; env nào trên nền tảng nào đọc từ khoá `platforms` của `components.json`, hôm nay stg trên `k3d`, `eks`, prd chỉ
    `eks`; `cluster` của `eks` lấy từ `deploy/ci/cluster-values.example.yaml`; render của nền tảng không `localHosts`, tức `eks`, không
    được nêu `svp.localhost`: grep cả render và policy `no-lab-hosts`); chart của working tree đứng thay `revision` của mọi env, nên không kiểm
    revision, giá trị dẫn xuất hay bản phát hành (việc của check `svp-gitops`);
    Secret của đường GitOps ([ADR-0026](../adr/0026-secrets-gitops.md)): render gốc của `svp-cluster` (đường dev) không có
    ExternalSecret hay SecretStore; mỗi env × nền tảng đúng số tính từ `files/external-secrets.yaml` với values đã ghép: một
    ExternalSecret mỗi entry, trừ entry `inClusterObjectStore` khi `s3.mode` là `external` và entry `enabledBy` khi khoá đó của
    `externalSecrets` không `true`, một SecretStore mỗi namespace của chúng (hôm nay stg trên `k3d` 28 và 4, stg và prd trên `eks` 25 và 4;
    `argocdNotifications` bật thêm một mỗi loại ở `argocd`; trên k3d provider `kubernetes`; trên eks provider `aws` và không còn `svp-secrets`), qua kubeconform `-strict` (`KUBECONFORM_IMAGE`, `--network none`) theo schema sinh từ CRD của
    chart External Secrets đúng version `components.json` ghim (provider `crd` bỏ khỏi schema SecretStore vì openapi2jsonschema
    sinh sai; không store nào dùng nó); cuối cùng mọi image (`helm template --include-crds` mọi component với values
    `base/` và Argo CD theo `bootstrap.json`, rồi Argo CD với `platforms/<platform>/argo-cd.yaml` của mỗi nền tảng có file đó) phải ghim đúng một `@sha256:` theo policy `images-pinned` của `deploy/ci/gitops-policies/`
    (Kyverno CLI `KYVERNO_CLI_IMAGE`, `--network none`; ref image ngoài các field policy đọc vẫn qua phép quét của script), image của
    render có overlay phải bằng render nó chồng lên (bước 4 của `gitops-check.sh`). Cần Docker và mạng tới mọi repo
    chart. `make trivy-config`: trivy quét cấu hình Dockerfile, chart, chỉ báo,
    trừ các mục của `deploy/ci/trivy-config-ignore.yaml` (dưới đây). Cổng `--fs` của lockfile không còn trong `scan-gate.sh`
    ([ADR-0039](../adr/0039-mainpath-drills-scan-gate-sourcemaps.md) §2): `svp-frontend` chạy `trivy fs` rồi `trivy convert --exit-code 1 --severity CRITICAL --ignorefile`
    trong `Makefile` của nó. `make renovate-check`: `renovate-config-validator --strict` trong `RENOVATE_IMAGE` ghim, không mạng. trivy, syft,
    grype, cosign, Renovate, k6, Schemathesis, kubeconform, Kyverno CLI, conftest, Regal, oasdiff, ORAS, yq chạy trên máy chỉ bằng image ghim
    digest của `Makefile` (`TRIVY_IMAGE`, `SYFT_IMAGE`, `GRYPE_IMAGE`, `COSIGN_IMAGE`, `RENOVATE_IMAGE`, `K6_IMAGE`, `SCHEMATHESIS_IMAGE`,
    `KUBECONFORM_IMAGE`, `KYVERNO_CLI_IMAGE`, `CONFTEST_IMAGE`, `REGAL_IMAGE`, `OASDIFF_IMAGE`, `ORAS_IMAGE`, `YQ_IMAGE`; yq của bước promote và của phép
    kiểm tệp ngoại lệ), không cài;
    `make kyverno-test`: `kyverno test` của `deploy/ci/gitops-policies/` (fixture đạt, hỏng mỗi policy; `gitops-check-test.sh` gọi nó);
    `make regal-lint`: Regal (linter của dự án OPA, `REGAL_IMAGE`, luật ở `.regal/config.yaml`) trên hai thư mục policy đó, chạy ngay
    trước `make conftest-verify` ở job `config`; `make regal-fix` sửa các lỗi có sửa tự động;
    `make conftest-verify`: `conftest verify` của `deploy/ci/ignorefile-policies/` (mỗi ca âm của luật tệp ngoại lệ là một test `*_test.rego`,
    hôm nay cố định) và của `deploy/ci/gitops-tree-policies/` (mỗi ca âm của luật cây `svp-gitops`, trên một cây viết trong test;
    `gitops-check-test.sh` gọi nó);
    govulncheck là công cụ Go ghim `GOVULNCHECK_VERSION`, cài bằng `make tools`. Riêng cosign, script (`cosign_` của `deploy/ci/common.sh`) dùng `cosign`
    trên PATH trước nếu có (job `contract`, `rescan` cài bằng `sigstore/cosign-installer`), không có thì `COSIGN_IMAGE`; action
    `image-sign` ký bằng `COSIGN_IMAGE`.
  - `.trivyignore.yaml` và `.grype.yaml` ở gốc repo ([ADR-0039](../adr/0039-mainpath-drills-scan-gate-sourcemaps.md) §2; cổng của image và `make grype` đọc; mỗi
    repo nguồn có hai tệp riêng ở gốc cây của nó, mục `@lhci/cli` của web ở `svp-frontend`; hiện có một mục: `CVE-2026-58016` của `glib` trong
    image `media-worker`, chưa có bản vá, ffmpeg không nạp `libgio` nơi có lỗi, [ADR-0030](../adr/0030-devsecops-supplement.md) §6).
    `.trivyignore.yaml`: chỉ phần `vulnerabilities`; mỗi mục có `id`, `statement` (lý do), `expired_at` không quá 30 ngày sau ngày chạy và `purls`
    mà purl nào cũng có `@version` (trivy đọc purl không version là mọi version của gói); không `paths`; thêm qua PR; bí mật không bỏ qua được.
    trivy tự bỏ mục hết hạn. `.grype.yaml`: grype đọc cả file (`-c`) và không đọc hạn, nên file chỉ cho một dạng: khoá `ignore` ở gốc, mỗi rule có
    đủ và chỉ có `vulnerability`, `include-aliases: true` (che match grype báo bằng GHSA khi rule ghi CVE), `package.name`, `package.version`, và
    ứng đúng một mục còn hạn của `.trivyignore.yaml` (cùng id, cùng version, `package.name` là tên của purl như grype gọi gói, kể cả namespace
    như scope npm hay đường dẫn module Go, trừ apk, deb, rpm chỉ lấy đoạn cuối; mỗi ký tự `.*+?[](){}|^$\` của tên thoát bằng `\`, ví dụ
    `socket\.io-parser`, vì grype đọc tên có ký tự meta là regex neo hai đầu). Giá trị YAML thường mà grype đọc thành null, bool hay số
    (`1.10`, `null`, `017`) phải đặt trong dấu nháy đơn, cả `yes`, `no`, `on`, `off` (parser của conftest đọc YAML 1.1); giá trị dạng ngày
    (`2026-1-2`) bị từ chối kể cả trong nháy, vì file đã parse không còn dấu nháy; gói mà tên grype bỏ namespace (maven) không có ngoại lệ grype, CRITICAL của nó vẫn chặn.
    Khoá nào khác bị từ chối (`only-notfixed`, `ignore-wontfix`, rule thiếu `package`…: che CRITICAL không cần mục ngoại lệ, không hạn).
    Vì grype không đọc hạn, mục hết hạn (từ đúng ngày `expired_at`) làm job `config` đỏ ở mọi PR thay vì cổng grype của từng chân; cổng của image chạy
    cùng phép kiểm file nhưng không kiểm hạn. `deploy/ci/trivy-config-ignore.yaml` (chỉ `make trivy-config` đọc,
    [ADR-0021](../adr/0021-deferred-verification-stage6b.md) §9): các misconfiguration bỏ qua có thời hạn; `scan-gate.sh --check-ignorefile` kiểm nó cùng hai file kia
    ở job `config`, file sai luật làm job đỏ ở mọi PR. Luật và cách chạy ở mục `scan-gate.sh` bên dưới.
  - Renovate: GitHub App Mend, repo này và `svp-gitops` (người học cài, **kiểm sau push**); `renovate.json`: sáng thứ Bảy giờ Việt
    Nam, `minimumReleaseAge` 3 ngày (trừ cảnh báo lỗ hổng); tự merge hẹp ([ADR-0041](../adr/0041-github-hardening.md) (i), thay một phần
    [ADR-0035](../adr/0035-renovate-automerge.md); auto-merge của GitHub, squash, khi `ci-ok`, `images-ok` xanh; repo phải bật "Allow
    auto-merge"): `digest`, `pinDigest` của base image và image của chart (cùng tag, digest mới) và `patch`, `digest` của image compose. Duyệt tay: mọi
    cập nhật Go module (cả `digest` và directive `go`), patch tag của base image và image chạy trong cluster, action và image của
    workflow (`.github/` có chủ), image công cụ ghim trong `Makefile` (`/Makefile` có chủ), nhóm `tools`, `cosign`, minor, major; không đụng
    `deploy/ci/drill/`, `gen/`; luật npm, Node, Sentry của web ở
    `renovate.json` của `svp-frontend` (cùng lịch); values của
    chart nền tảng, version chart trong `components.json`, bản cài Argo CD và digest phát hành ở `svp-gitops`, do `renovate.json` của
    repo đó quản (bỏ qua `envs/**`). Ghim mới trong `Makefile`, `lib.sh` hay values bên thứ ba theo dạng của
    ADR-0015 §10 (chú thích `# renovate: datasource=… depName=…` ngay trên dòng khi manager có sẵn không đọc được).

### Script của các bước `verify.yml`

Các script này chạy trong job của `verify.yml` (kịch bản, bước và artifact ở mục "Job theo từng workflow" của [`ci-cd.md`](../ci-cd.md)).

- **`verify-host.sh compose-obs|gitops`** kiểm và chuẩn bị máy (runner `ubuntu-24.04`, hay VM Linux thuê thay nó) trước mọi target `make`. Thiếu gì thì
  fail kèm số liệu, để một lượt sẽ chết sau hàng giờ vì thiếu đĩa hay thiếu tên dừng ngay ở đây. Chỉ chạy trên Linux (`df` của GNU). Ghi tên kịch bản vào
  `$SVP_VERIFY_OUT/scenario` cho `verify-collect.sh`. Ba việc:
  1. Đĩa: chỗ trống của filesystem chứa thư mục dữ liệu Docker phải bằng ít nhất phần kịch bản cần thêm (mức theo kịch bản ở đầu script: bản đo lần chạy
     đầu của `compose-obs` nhân 1,25; với `gitops` là image phát hành, image của khoảng 40 container bên thứ ba trong containerd store của hai node
     và volume) cộng 15% dung lượng cộng 2 GiB. Mức 15% giữ kubelet dưới ngưỡng dọn image mặc định (85%). Thiếu thì xoá các bộ công cụ của image runner
     mà repo không dùng (Android, .NET, GHC, CodeQL; không xoá Go của hosted tool cache mà `setup-go` dùng), đo lại, vẫn thiếu thì fail. `df` và
     `docker system df` ghi vào `$SVP_VERIFY_OUT/df-before.txt` và log.
  2. Chỉ k3d: dòng `127.0.0.1 svp.localhost api.svp.localhost s3.svp.localhost` trong `/etc/hosts` (diễn tập gọi Envoy theo các tên đó, k3d chỉ publish
     `127.0.0.1:8443`, nên một tên còn phân giải ra `::1` gây kết nối bị từ chối hay lỗi); rồi `getent ahosts` của từng tên phải ra `127.0.0.1` và
     không gì khác.
  3. Chỉ k3d: `kubectl` của máy lệch tối đa một minor so với k3s của cluster (`K3S_IMAGE_TAG` của `Makefile`), theo chính sách version skew của kubectl.
- **`verify-mask.sh env|cluster`** mask giá trị bí mật của một lượt trong log job và giữ chúng ở thư mục riêng cho `verify-collect.sh` dò artifact. Repo public
  nên log cũng public, đỏ hay không: mask là lớp thứ hai, sau luật không script nào in bí mật.
  - `env`: giá trị của `.env` có tên kết thúc bằng `PASSWORD`, `SECRET`, `SECRET_KEY`, `TOKEN`, `_KEY` hay `_KEYS`, và `SENTRY_DSN`, đọc theo luật của
    `deploy/observability/glitchtip/dotenv.sh` (không bao giờ `source`). Lần gọi đầu của job còn mask một marker ngẫu nhiên và in `mask-check: <marker>`, để log
    thô cho thấy mask hoạt động mà không cần biết bí mật nào.
  - `cluster`: mọi giá trị của mọi Secret ở namespace `svp`, `svp-data`, `svp-obs`, `argocd`, `svp-secrets` (nguồn mà External Secrets Operator dựng Secret của
    đường GitOps) của cluster `k3d-svp`; giá trị nhiều dòng thì mỗi dòng một mục, giá trị nhị phân thì mỗi đoạn giữa các ký tự điều khiển. Mỗi lần đọc có hạn
    thời gian; cluster không trả lời thì danh sách giữ nguyên như cũ.
  - Mỗi giá trị được giữ nguyên dạng và cả dạng base64 (dạng của chính Secret, cũng là cái một bản dump JSON hiện). Chỉ giá trị từ 8 ký tự: giá trị ngắn hơn
    (`svp`, một cổng, tên user bốn chữ) không phải bí mật đáng kể, mà mask hay dò nó sẽ che hay bỏ nửa log và mọi file nhắc tới nó. Cùng lý do, danh sách của cluster bỏ các
    khoá vốn giữ định danh: `username`, `user`, `dbname`, `host`, `port`, chứng chỉ công khai `ca.crt`, `tls.crt`, `sasl` và `tls` của KEDA (một cơ chế, một chế độ), và
    mọi khoá có tên kết thúc `username`, `_user` hay `-user` (`KAFKA_SASL_USERNAME`, `S3_ROOT_USER`, `admin-user` của Grafana), `email` (`GLITCHTIP_ADMIN_EMAIL`), `_key_id`
    (`ACCESS_KEY_ID`, tên user S3) hay `_kid` (`JWT_SIGNING_KID`, id công khai của khoá). Diễn tập in các tên đó (`drill-k8s-threats` nêu user Kafka và `svp-admin` trong
    kết luận), và `deploy/k8s/secrets.sh` không bao giờ lưu mật khẩu, khoá hay token dưới khoá như vậy. Secret kiểu `helm.sh/release.v1` cũng bỏ: giá trị là cả
    release nén, một dòng hàng megabyte, còn credential của cluster đến từ `deploy/k8s/secrets.sh` chứ không từ values của chart.
  - Đầu ra: một dòng `::add-mask::` trên stdout ở GitHub Actions (runner ẩn nó; trên máy không in) cho mỗi giá trị chưa mask trong job (mask hai lần vô hại), và một dòng cố
    định nói số lượng. Không bao giờ `set -x` ở đây: vết sẽ in mọi giá trị. Các giá trị ghi vào `$SVP_VERIFY_SECRETS` (mặc định `verify-secrets` trong `$RUNNER_TEMP`, `/tmp`
    trên máy; mode 700): `env.values` và `cluster.values`, mỗi dòng một giá trị, mode 600, không bao giờ tải lên. Mỗi danh sách chỉ lớn thêm: một lần gọi cộng
    phần nó đọc vào phần các lần trước đã giữ, nên một Secret được tạo lại giữa lượt với giá trị mới vẫn được dò trong file ghi trước đó. Lượt không đọc được nguồn thì
    thoát 1 và để danh sách như cũ (`verify-collect.sh` rồi quyết định được chép gì).
  - `SVP_VERIFY_REPO` (mặc định checkout này) và `SVP_VERIFY_ENV_FILE` (mặc định `.env` của nó) cho `verify-collect-test.sh` trỏ nó vào `.env` giả; `kubectl` là cái trên `PATH`.
  - Cách tách một giá trị: mỗi giá trị theo dạng đã lưu (base64) và đã giải mã; nguyên khi một dòng, từng dòng (bỏ khoảng trắng hai đầu) khi nhiều dòng. Giá trị giải mã bị cắt ở
    mọi ký tự điều khiển chứ không chỉ newline: một mask là một dòng của log job, một `\r` hay ký tự điều khiển khác trong nó làm vỡ dòng và phần còn lại không được mask.
    Cũng cắt ở U+FFFD, thứ `jq` giải một byte không phải UTF-8 thành: một mảnh chứa nó không bao giờ khớp byte mà log hay file hiện. Giá trị nhị phân (config gzip) vì vậy bị cắt thành
    nhiều mảnh ngắn; mask các mảnh đó vô hại, còn dạng đã lưu (base64 thuần) vẫn được mask nguyên. Điểm cắt là các code point mà `[[:cntrl:]]` của `jq` khớp (U+0000–001F,
    U+007F–009F) và U+FFFD, mỗi cái đổi thành newline rồi tách, thời gian tỉ lệ với giá trị: `splits()` của `jq` với regex chạy trong thời gian tăng theo bình phương, hàng phút với một giá trị
    nhị phân 200 KiB.
- **`verify-k8s-state.sh`** ghi trạng thái cluster `k3d-svp` vào `$SVP_VERIFY_OUT/k8s-state.json` khi `make k8s-up` của job `dev-k3d` đỏ: log của bước
  dựng ở lại runner, nên artifact chỉ nhận phần máy đọc này. Bước "Mask what the build step added" gọi nó sau `verify-mask.sh cluster` (outcome của
  `k8s-up` qua `env:`), trong cùng hạn 3 phút, nên ngân sách `timeout-minutes` của job không đổi. Chỉ lấy trường trạng thái, không spec, log hay
  termination message: pod (namespace, tên, phase, điều kiện chưa đạt; mỗi container và init container: `ready`, `restartCount`, lý do waiting,
  lý do và exit code của lần kết thúc hiện tại và trước đó), Job (số đang chạy, xong, lỗi; điều kiện), event `Warning` (reason, số lần, lần cuối, đối tượng,
  message với mọi giá trị của `env.values`, `cluster.values` thay bằng `***`), release Helm (namespace, tên, revision, trạng thái, chart, lần cập nhật).
  `kubectl`, `helm` chỉ với context `k3d-svp`, mỗi lần đọc của `kubectl` hạn 10 giây; đọc không được thì thoát 1, không ghi file, bước vẫn xanh.
  `verify-collect.sh` dò file lại như mọi file đọc từ cluster.
- **`verify-collect.sh`** dựng artifact công khai của một lượt: chép file của danh sách cho phép vào `$SVP_VERIFY_ARTIFACT` (mặc định `verify-artifact` trong `$RUNNER_TEMP`, `/tmp` trên máy), mỗi file
  chỉ sau khi dò, rồi in vào log job bản tóm tắt chỉ lấy từ các bản chép. Ai cũng đọc được artifact và log của repo public, nên nó đóng khi nghi ngờ: file không chắc thì bỏ, kèm cảnh báo
  (annotation trên GitHub) nêu file và luật, không bao giờ nêu đoạn khớp.
  - Danh sách cho phép là kết quả máy đọc, không bao giờ output của một bước (có thể trích log của service hay container bên thứ ba, mà artifact không được giữ; nó ở lại runner). Từ kết quả của lượt
    (`$SVP_VERIFY_OUT`, mặc định `verify` trong `$RUNNER_TEMP`, không bao giờ tải cả thư mục): file ghi ngay trên runner là `results.tsv` (bảng bước, `steps.sh`), `scenario`,
    `df-before.txt` (`verify-host.sh`); file đọc từ stack hay cluster là `logs/drill-obs-threats.log`, trong đó chỉ dòng kết luận (`ok`, `PASS`, `FAIL`, `SKIP`, `WARN` và dòng đóng
    "drill-obs-threats: all checks passed"; không dòng log JSON hay trích access log) vào artifact, dưới tên `logs/drill-obs-threats.verdicts.log`, `logs/gitops-admission-metrics.log`
    (các dòng tóm tắt của `admission-metrics.sh`) và `k8s-state.json` (`verify-k8s-state.sh`). Mọi file khác ở đó (output của mọi bước khác) được liệt kê trong `files.txt` là `not-allowed`.
  - Từ checkout (đều đọc từ stack hay cluster): `.k8s/drills/*.xml` (report JUnit của mỗi diễn tập Chainsaw), `*-skips.tsv` (danh sách ca SKIP và lý do: report JUnit tính SKIP là qua),
    `*.json` và `traffic-*.log` (mỗi dòng một thời điểm, user, route, status, độ trễ). Mọi thứ khác dưới chỗ đó được liệt kê `not-allowed`: log của mỗi diễn tập Chainsaw và mọi log service không bao giờ
    vào; file ẩn bị bỏ bằng luật riêng kèm cảnh báo. Phần còn lại của checkout (`.env`, kubeconfig, `.k8s/ca.*`, `.k8s/helm/`) không được nhìn tới.
  - Một ứng viên bị từ chối khi nó ẩn, không phải file thường (một link có thể trỏ tới `.env`), quá 5 MiB, hay khớp một luật sau (`grep -a`: file nhị phân đọc như text): `secret-value`
    (một giá trị của `env.values` hay `cluster.values` ở `$SVP_VERIFY_SECRETS`, xem `verify-mask.sh`: mọi bí mật của `.env` và mọi giá trị Secret của cluster, dạng thô và base64, từ 8 ký tự; cả hai danh sách
    được đọc lại ở đây, của cluster khi nó còn chạy); `jwt` (`eyJ<8+>.eyJ<8+>.`, header và payload của JWT hay JWS; `eyJ` đứng riêng cũng có trong base64 của ảnh chụp mà Lighthouse nhúng, không có dấu
    chấm); `session-cookie` (`svp_sid`; trong dòng kết luận của `drill-obs-threats` là `svp_sid` không theo sau bởi dấu cách, xem `rule` dưới); `bearer` (chuỗi "Bearer " kèm dấu cách); `set-cookie`
    (`Set-Cookie`); `private-key` (`-----BEGIN ... PRIVATE KEY-----`).
  - File đọc từ stack hay cluster chỉ được chép khi mọi danh sách nó cần đã đọc được: của `.env` luôn, của cluster nữa trừ kịch bản `compose-obs`. Danh sách không đọc được (`.env` phá luật của nó, cluster chết
    trước khi Secret được đọc một lần) chỉ để lại file ghi ngay trên runner (`no-secret-list`). Danh sách của cluster giữ mọi giá trị đọc được khi cluster còn chạy, nên cluster đã mất vẫn còn một danh sách.
  - Artifact gồm `files.txt` (mọi ứng viên: giữ, hay bỏ kèm luật), các kết quả dưới tên của chúng, và file của checkout dưới `k8s-drills/` (`upload-artifact` bỏ thư mục ẩn như `.k8s`). Log job nhận một số đếm, và với mỗi
    bước không `success` là phần cuối các dòng kết luận của nó khi chúng đã vào artifact. Thoát 0 dù bỏ gì; thoát 1 chỉ khi không dựng được thư mục artifact. `SVP_VERIFY_REPO` trỏ nó vào cây khác cho `verify-collect-test.sh`.
  - Hàm `rule FILE [KIND]` in luật dò đầu tiên mà FILE vi phạm, không in gì khi sạch. `KIND` là `verdicts` (các dòng kết luận của `drill-obs-threats`, câu chữ của chính diễn tập) thì luật `session-cookie` hẹp lại: mục của web client nêu cookie phiên
    bằng văn xuôi, tên theo sau là dấu cách ("session cookie `__Host-Http-svp_sid` in the drill's cookie jar"), và không dạng nào mà một cookie được ghi lại đặt giá trị ngay sau tên và một dấu cách (header là `name=value`, cookie jar
    `name<TAB>value`, JSON `"name": ..., "value": ...`). Vậy ở đó `svp_sid` theo sau bởi ký tự khác, hay kết thúc dòng, vẫn bị từ chối; ở mọi file khác, `svp_sid` ở đâu cũng bị từ chối.
- **`verify-steps/steps.sh check|table`** (`SVP_VERIFY_STEP_NAMES` của job liệt kê các bước theo thứ tự; `targets` của dispatch chỉ tới đây qua `SVP_VERIFY_TARGETS`, rỗng ở lượt lịch: mọi bước).
  - `check`, trước khi dựng gì: mọi tên trong `SVP_VERIFY_TARGETS` (cách nhau bằng khoảng trắng) là một bước của job, kể cả bước dựng (luôn chạy); ký tự ngoài `a-z`, `0-9`, `-` và khoảng trắng, hay tên job không có, thì thoát 2.
    Danh sách bị từ chối không bao giờ in lại: log của job đọc dòng bắt đầu bằng `::` như một lệnh. Việc lọc là `if:` của từng bước (tên có trong `targets`, outcome của bước dựng là `success`); script không thêm gì vào cái dispatch nêu, nên một
    bước đọc kết quả của bước khác (`drill-k8s-threats` đọc video READY của `k8s-smoke`) phải được nêu cùng.
  - `table`, khi các bước đã chạy (outcome nào cũng vậy): `$SVP_VERIFY_OUT/results.tsv`, mỗi bước của `SVP_VERIFY_STEP_NAMES` một dòng theo thứ tự, dạng `bước outcome ghi chú`, cũng in vào log. Outcome là của chính bước, lấy từ `SVP_VERIFY_STEPS`
    (context `steps` của job dạng JSON, `toJSON(steps)`): `success`, `failure` (cả bước quá `timeout-minutes`), `cancelled` hay `skipped`; `absent` khi job không có bước id đó. Ghi chú của bước skipped nói lý do: `not in targets`, `build step failed`
    hay `not run` (lượt bị huỷ, hay một bước trước bước dựng đỏ). Chỉ outcome của mỗi bước được đọc từ JSON đó, không bao giờ một output. `SVP_VERIFY_OUT` mặc định `verify` trong `$RUNNER_TEMP` (`/tmp` trên máy).
- **`verify-steps/steps-test.sh`** thử `steps.sh` và hình dạng các job của `verify.yml` mà nó dựa vào, đọc dưới dạng JSON bằng `yq` (`YQ_IMAGE` của `Makefile`, qua Docker không mạng). Chạy trên macOS và Linux: bash, `jq` và Docker; không mạng, không cluster.
  - `check`: danh sách rỗng, bước của job và bước dựng của nó qua; tên job không có (của job kia, tên mà kịch bản từng có) hay ký tự ngoài `a-z`, `0-9`, `-` và khoảng trắng thì thoát 2 mà không in lại danh sách.
  - `table`: mỗi bước của `SVP_VERIFY_STEP_NAMES` một dòng theo thứ tự với outcome từ context `steps`, lý do của bước skipped, `absent` cho id job không có, và không output của bước nào.
  - Workflow: ở mỗi job, các bước của `SVP_VERIFY_STEP_NAMES` theo đúng thứ tự đó, bước dựng không có `if:` sau bước kiểm `targets` và bước clone `svp-gitops`, mọi bước khác đúng `if:` theo tên của nó (không bị huỷ, bước dựng `success`,
    có trong `targets`), mỗi bước có `timeout-minutes` và output ra file riêng, không bước nào `continue-on-error`; không `${{ }}` trong `run:`; các bước mask, lập bảng, thu, tải lên và dọn dẹp chạy sau chúng với `always()` một khi bước kiểm ref đã qua;
    tổng `timeout-minutes` của các bước cộng 20 phút cài đặt và 25 phút cho các bước đó nằm trong `timeout-minutes` của job; giá trị mới của `drill-k8s-reloader` do một bước riêng sinh trước bước dựng của mỗi job chạy nó; job `dev-k3d`
    chỉ dispatch, `svp-gitops` clone ở `gitops_ref` mà một bước kiểm trước khi clone (`main` và SHA commit đủ qua, mọi thứ khác fail mà không in lại), bước supply chain của nó có `SUPPLYCHAIN_ENFORCE_TMP=1`. Cùng phép kiểm đó chạy trên các bản
    sao của workflow, mỗi bản bị hỏng một kiểu, và phải fail.
- **`verify-steps/supplychain.sh`** (bước `drill-k8s-supplychain`) chạy `make drill-k8s-supplychain` với các image nó cần. Ngoài phần ở mục job `gitops` phía trên: ca `c` và `l` chỉ qua khi attestation `vuln` của image diễn tập của chúng còn trong tuổi tối đa của policy
  (`imageVerification.maxAttestationAge` của chart `svp-policy`, 72 giờ), nên một lượt dispatch cần `images.yml -f drill=true` ít hơn mức đó trước nó, vì không file image nào của `svp-gitops` nêu image diễn tập và rescan hằng ngày không bao giờ attest lại. Không ai
  dispatch nó trước một lượt lịch (`SVP_VERIFY_SCHEDULED=true`, job chỉ đặt ở lượt lịch; giá trị khác là dispatch): ở đó image của ca `c` hay `l` có attestation `vuln` cũ hơn tuổi đó trừ một giờ bị bỏ ra (`c` rỗng, `l` là `none`: ca SKIP, không làm gì đỏ),
  kèm một dòng `NOTE` nêu ca, tuổi và lệnh dispatch. Tuổi được đọc như drill đọc: `scanFinishedOn` cũ nhất của các attestation mà cosign xác minh ẩn danh với danh tính của nguồn phát hành có prefix chứa image. Image không đọc được tuổi thì giữ: drill đọc lại và
  làm ca đỏ theo cái nó nhận. Lượt dispatch giữ cả hai bất kể tuổi. Ca `l` không có image thì nhận `none`, không bao giờ rỗng, vì rỗng thì drill hiểu là "tự tra". `SUPPLYCHAIN_ENFORCE_TMP` tới drill nguyên trạng: job `dev-k3d` đặt 1 để policy của đường dev (Audit) sang Enforce cho từng ca rồi trả
  lại, job `gitops` để trống (policy của nó đã Enforce).
- **`verify-steps/admission-metrics.sh`** (bước `gitops-admission-metrics`) ghi số đo thời gian admission của lượt sync đầu như bằng chứng (điều kiện ở ADR-0040 mục 6). Bước chạy ngay sau bước dựng, trước `k8s-smoke` và diễn tập, để histogram chỉ chứa lượt sync đầu. Các histogram
  (xem mục job `gitops` phía trên): từ apiserver (`kubectl get --raw /metrics`) `apiserver_admission_webhook_admission_duration_seconds` của webhook `ivpol.*` trong `kyverno-resource-validating-webhook-cfg`, histogram đó chỉ có bucket 10, 25 và `+Inf`; từ Kyverno
  (port-forward Service `kyverno-svc-metrics` ra một cổng trống của `127.0.0.1` trong khoảng 19100–19120, vì `NetworkPolicy` default-deny của namespace chặn proxy của apiserver) `kyverno_admission_review_duration_seconds` và, cho policy `svp-images`,
  `kyverno_image_validating_policy_execution_duration_seconds` (nhãn `policy_name`; `svp-policy` là tên chart và webhook). Mỗi histogram cộng qua mọi tập nhãn của series được hỏi, vì nó được tách theo nhãn mà câu hỏi không hỏi. Thiếu metric, bucket hay cổng là dòng `NOTE`: phép đo là bằng chứng chứ không phải cổng, bước
  không bao giờ đỏ. `kubectl`, `curl`, `nc` là các lệnh trên `PATH`; `kubectl` luôn trên context `k3d-svp`.
- **`verify-steps/objstore.sh`** (bước `test-stack-objstore` của job `compose`) chạy test của object store trên object store của stack (`make test-stack PKGS=./internal/objstore/...`, `go test -race -count=1 -v`): nơi duy nhất chúng chạy thay vì skip. Output của nó được đếm: bước đỏ khi `make test-stack` thoát khác 0, khi `go test` báo `FAIL`,
  khi bất kỳ test hay subtest nào `SKIP` (một ca bị skip không chứng minh gì về store), hay khi một trong các test tích hợp (presigned POST, quyền của worker và của video-service, `DeletePrefix`, multipart với CRC32, `Cache-Control` đọc lại ẩn danh, tạo một lần duy nhất, worker liệt kê và đọc `media/`) không `PASS`, mỗi cái được nêu tên. `make` là cái trên `PATH`; chạy từ gốc repo, stack đang lên.

### Quy ước và hàm dùng chung của `common.sh`

`deploy/ci/common.sh` giữ các helper dùng chung của script pipeline image dưới `deploy/ci/`. Source nó chỉ định nghĩa, không chạy gì. Nó source `deploy/k8s/lib.sh` để lấy danh sách service, Dockerfile của mỗi service và đường dẫn mà mỗi image được build
từ đó, nên CI và `make k8s-up` không bất đồng về chúng. Viết cũng chạy được trên bash 3.2 (script được thử trên macOS trước khi chạy trên runner Ubuntu). Luật mọi script giữ: docker chạy không có `DOCKER_DEFAULT_PLATFORM` (image phải là kiến trúc của chính runner, không giả lập),
trivy và syft chạy từ image ghim ở `Makefile`, không gì in bí mật (trivy che bí mật trong phát hiện; script in luật, file và dòng, không bao giờ in báo cáo thô).

Môi trường chạy: script chạy trong GitHub Actions và đọc thẳng biến của nó; trên máy, nơi không biến nào được đặt, một output hay một dòng tóm tắt được in ra thay vào, và lượt là của repo của `code_root` ở `HEAD`, workflow `local`.

- **`step_output KEY VALUE`** trao VALUE (một dòng) cho các bước và job sau dưới KEY (`$GITHUB_OUTPUT`). Trên máy không dùng `>>/dev/stdout`: trên Linux nó mở lại file mà stdout đang trỏ tới, và dòng script in tiếp theo ghi đè lên dòng vừa nối.
- **`run_repo_url`**: địa chỉ web của repo mà lượt này thuộc về. Trên máy là repo này trên GitHub, hay, khi `SVP_CODE_ROOT` nêu checkout của repo khác, của checkout đó, đọc từ remote `origin` ở github.com như một job của repo đó sẽ thấy; checkout không có origin như vậy thì
  lỗi, vì không thể gọi tên repo mà không đoán. Lỗi in origin đã bỏ userinfo: một URL có thể mang credential (`https://user:token@host/...`).
- **Image diễn tập admission trong `common.sh`.** Image của repo này nằm dưới `ghcr_prefix` (`deploy/k8s/lib.sh`), của mọi nguồn phát hành dưới `imagePrefix` của nguồn đó (`release_sources` của `lib.sh`). Các image chỉ build để diễn tập admission không chart nào chạy và
  không file image nào của `svp-gitops` nêu, nên rescan hằng ngày không bao giờ attest lại chúng. Danh sách đó cũng là `drillImages` của nguồn `backend` mà policy nhận dưới prefix của nó (`deploy/ci/verify-release-test.sh` kiểm hai bên khớp).
- **`use_release_source SOURCE`** đặt, từ SOURCE (một nguồn phát hành dạng JSON gọn, `release_source` của `deploy/k8s/lib.sh`): `source_name`, `sign_issuer` và `sign_subject` (danh tính keyless mà mọi chữ ký và attestation của image của nguồn phải mang: OIDC issuer của nền tảng CI,
  và workflow ký bản phát hành trên `main`), cùng `provenance_repository` và `provenance_ref` (cái mà workflow của build provenance phải nêu). Kyverno kiểm cùng các giá trị đó; `files/sources.json` của chart `svp-policy` là nơi duy nhất để đổi chúng. Fail trừ khi danh tính và repository mỗi cái là một URL `https://` và ref là một `refs/...` không có khoảng trắng.
- **`_require_provenance WHERE [OVERLAY]`** đọc một file values của chart `svp-policy` từ stdin và in `true` hay `false`, giá trị của dòng `requireProvenance: ...` (thụt hai dấu cách) trong khối `imageVerification` ở cấp cao nhất, hay không in gì khi không có dòng đó. Chỉ dạng đó được đọc (giá trị trần, không dấu nháy hay comment theo sau);
  một dòng khác nêu `requireProvenance` thì fail, nêu WHERE, thay vì đoán Kyverno nhận gì. Khi có OVERLAY, file không được có gì khác (trừ dòng trống và comment): một overlay đặt khoá khác của policy làm Kyverno kiểm thứ mà không script nào ở đây đọc.
- **`provenance_required [REV [ENV [DIR]]]`** in `true` khi chart `svp-policy` kiểm build provenance (`requireProvenance`) ở môi trường ENV của cấu hình triển khai DIR (một cây `svp-gitops`; mặc định `gitops_dir` của `deploy/k8s/lib.sh` khi rỗng) ở commit REV (như DIR trên đĩa khi REV rỗng), `false` nếu không, từ
  các file mà Argo CD trao cho chart ở đó: `deploy/helm/svp-policy/values.yaml` của repo này ở commit mà `envs/ENV/charts.yaml` ghim, rồi `envs/ENV/svp-policy.yaml` khi có. Không có ENV: `true` khi có môi trường nào của `envs/` bật nó, vì image phát hành giống nhau ở mọi môi trường; chỉ `values.yaml` của working tree khi DIR không có môi trường nào.
  `charts.yaml` ghim một commit từ trước khi có khoá đó thì đọc là `false`. Fail, không in gì ra stdout, khi một file không đúng dạng mà `_require_provenance` đọc, hay khi `charts.yaml` không nêu commit nào của bản clone này có chart: bên gọi phải dừng ở đó, không đọc nó như `false`.
- **`release_source_in REPOSITORY [REV [ENV [DIR]]]`** in, dạng JSON gọn, nguồn phát hành mà REPOSITORY là một bản phát hành của nó (`<imagePrefix><service>` của một nguồn mà `services` nêu `<service>`: `release_source_of` của `deploy/k8s/lib.sh`) trong bảng mà chart `svp-policy` đọc nơi `provenance_required` đọc values: ở môi trường ENV của DIR ở REV,
  bảng của repo này ở commit mà `envs/ENV/charts.yaml` ghim (`release_sources`, từ chối commit từ trước khi có bảng). Không có ENV thì mọi môi trường của `envs/`, tất cả phải nhận REPOSITORY với cùng một nguồn và danh tính; bảng của working tree khi DIR không có môi trường nào. Fail, không in gì ra stdout, trong các trường hợp còn lại.
- **`tag_provenance_mismatch TREE CHECKED PROVENANCE_ENVS`** in mỗi vấn đề một dòng, không in gì khi mọi bản phát hành khớp nhau. CHECKED là output của `values-check.sh --gitops` trên TREE (một cây `svp-gitops`): một dòng `check <file>` cho mỗi file image đã xác minh, rồi dòng `ok` của bản phát hành đó từ `verify-release.sh`. PROVENANCE_ENVS liệt kê (cách nhau bằng khoảng trắng) các môi trường mà policy đòi provenance
  (`provenance_required`). Một bản phát hành được kiểm ở một môi trường như vậy phải nêu commit của provenance của nó ("provenance of `<commit>` by") và `image.tag` trong file của nó phải là commit đó. Dòng `ok` không nêu commit đọc được ở nơi cần provenance cũng là một vấn đề, không bao giờ là một lần qua: một dòng của `verify-release.sh` bị viết lại không được để mọi bản phát hành qua mà không kiểm.
- **`promote_image_row SERVICE REPOSITORY TAG DIGEST`** in một hàng của bảng trong PR promote (Service, Commit, Image). REPOSITORY là `ghcr.io/<owner>/<repo>/<name>`; cột commit liên kết tới TAG trong repo đó, cột image liên kết tới trang package của nó, digest cắt còn 12 chữ số hex để đọc (digest đầy đủ ở lại trong commit message).
- **`yq_ [NAME=VALUE...] ARGS...`** chạy `yq` ghim (`YQ_IMAGE` của `Makefile`) với ARGS, không mạng, bằng user của người gọi, với thư mục hiện tại làm thư mục làm việc (nên `yq -i` sửa file ở đó, gọi bằng đường dẫn tương đối) và stdin chuyển qua (không bao giờ gọi nó trong vòng lặp đọc danh sách từ stdin: docker sẽ đọc phần còn lại của danh sách). Mỗi `NAME=VALUE` đứng đầu chỉ đặt trong môi trường của riêng nó, cho
  `strenv(NAME)` trong biểu thức: một giá trị không bao giờ thành một phần của biểu thức.
- **`provenance_absent ISSUER SUBJECT IMAGE`**: trạng thái 0 khi cosign xác minh được các attestation của danh tính đó trên IMAGE (`REPOSITORY@DIGEST`) và không cái nào là build provenance (câu trả lời "none of the attestations matched the predicate type" của cosign, cái mà một bản phát hành từ trước khi CI attest provenance trả lời, vì nó mang `vuln`), 1 khi có một cái, 2 khi cosign không nói được (registry hay Sigstore ngoài tầm với,
  hay không có attestation nào của danh tính đó), dòng cuối của nó trên stderr. Chỉ câu trả lời đó của cosign mới tính là không có provenance: một lỗi không bao giờ tính.
- **`check_provenance_statement DIGEST`** đọc một statement in-toto (payload đã giải mã của một attestation provenance) từ stdin và kiểm cái mà Kyverno kiểm khi `requireProvenance` bật: loại predicate là SLSA v1, subject là DIGEST, `runDetails.builder.id` là subject ký, `buildDefinition.externalParameters.workflow` là repository và ref của `provenance_source`, và `resolvedDependencies` nêu đúng một commit nguồn (40 hex).
  In commit đó khi mọi thứ đúng, vấn đề đầu tiên nếu không (trạng thái 1). Cần đặt nguồn phát hành của image trước (`sign_identity` và `provenance_source` với tên của nó, hay `use_release_source`), vì Kyverno kiểm mỗi image theo nguồn của chính nó.
- **Cache DB của trivy và grype.** `trivy_cache` và `grype_cache` là thư mục mà mỗi công cụ giữ DB (CI lưu bằng `actions/cache`, một khoá mỗi ngày).
- **`trivy_scan_args`**: cờ quét, giống nhau cho cổng build và cho rescan: lỗ hổng và bí mật, mọi severity, JSON. File ignore chỉ được truyền khi nó tồn tại (trivy fail khi file không có); nơi gọi mount nó ở `/ignore.yaml`.
- **`grype_sbom DIR [ARGS...]`** chạy grype ghim trên `DIR/sbom.spdx.json` (tài liệu SPDX mà syft ghi, không bao giờ quét lại image) với ARGS (`scan-gate.sh --grype` truyền `--fail-on critical`) và ghi `DIR/grype.json`, `DIR/grype.sarif.raw`; thoát như grype (2 khi có match từ `--fail-on` trở lên). Chạy bằng user của người gọi, có mạng chỉ để tải DB. DB phải được tải hay
  kiểm tra cập nhật phải thành công (`GRYPE_DB_REQUIRE_UPDATE_CHECK`), và phép kiểm của chính grype rằng DB build không quá năm ngày vẫn bật: không bao giờ quét với DB không rõ tuổi. Cấu hình duy nhất grype đọc là `.grype.yaml` của cây đang build, truyền bằng `-c`: thư mục làm việc và `HOME` là tmpfs rỗng nên không file nào khác của grype tới được phép quét. `scan-gate.sh` giữ file đó theo luật của nó.
- **`grype_sarif DIR CATEGORY`** ghi `DIR/grype.sarif` từ `DIR/grype.sarif.raw`: chỉ các match HIGH và CRITICAL, như SARIF của trivy giữ (grype đã bỏ các match mà `.grype.yaml` che), dưới CATEGORY. grype đặt tên rule là `<vulnerability>-<package name>` và kết quả của nó không mang purl, nên một kết quả được giữ khi bất kỳ match nào của rule đó là High hay Critical.
- **`oci_labels [SOURCE]`** in nhãn OCI của commit ở `HEAD` của `code_root` dạng `key=value`: repository của nguồn phát hành SOURCE (`backend` khi rỗng), commit, và giờ commit theo UTC, để cùng một commit luôn ra cùng nhãn dù build lúc nào.
- **`verify_signature REPOSITORY DIGEST`**: đúng khi `REPOSITORY@DIGEST` mang chữ ký của danh tính của nguồn phát hành có prefix chứa REPOSITORY (`source_of_repository`; `sign_issuer` và `sign_subject` được để đặt theo nó).
- **Sigstore bundle và referrer.** Một bản phát hành được ký và attest bằng Sigstore bundle (`cosign sign` và `attest`, `actions/attest`), mỗi bundle là một OCI referrer của digest mà nó nói về; GHCR không có referrers API, nên client giữ danh sách trong tag dự phòng `sha256-<hex>` (OCI distribution spec 1.1). Các bản phát hành ký trước đó giữ định dạng cũ
  của cosign, một image `.sig` và một image `.att` bên cạnh digest (tag `sha256-<hex>.sig` và `.att`), và cùng các lệnh cosign xác minh được cả hai. Một digest không bao giờ mang cả hai: khi đã có một bundle, Kyverno và cosign chỉ đọc bundle và từ chối cái thiếu ở đó.
- **`bundle_referrers IMAGE`** in một dòng `<digest> <predicate type>` cho mỗi referrer là Sigstore bundle của IMAGE (`REPOSITORY@DIGEST`); không in gì khi không có. Type là annotation `dev.sigstore.bundle.predicateType` của referrer trong danh sách khi nó có (bundle của `actions/attest` có), nếu không là cái chính bundle nói (`bundle_type`): trên GHCR bundle của cosign không mang annotation trong danh sách.
  Fail thay vì bỏ sót một type. Không xác minh: nó nói cái có ở đó, không bao giờ cái được tin.
- **`replace_vuln_bundle REPOSITORY DIGEST PREDICATE`**: ngoài cách làm ở mục job `rescan`, GHCR không xoá manifest qua registry API (`oras manifest delete` trả "unsupported", thoát 1), nhưng `oras` đã ghi lại tag dự phòng khi đó, thứ gỡ bundle khỏi danh sách (manifest của nó ở lại trong package, không tag); nên mã thoát không được tin và danh sách được đọc lại: chỉ bundle `vuln` mới được còn, và cosign phải xác minh đúng một attestation `vuln` của
  danh tính nguồn phát hành của bản đó (`sign_issuer`, `sign_subject` đặt trước). Cái được giữ là cái mà lần gọi này vừa ghi (bundle `vuln` không có trong danh sách trước nó), không bao giờ cái được chọn theo điều một bundle chưa xác minh tự nói. Chỉ bundle `vuln` bị gỡ: không bao giờ chữ ký, SBOM hay provenance. Trong vài giây digest mang hai: `verify-release.sh` từ chối nó khi đó, Kyverno đọc cái nào cũng được (cả hai còn trong tuổi). Fail nêu cái sai; cần `docker login` (`registry_oras`) và `id-token` của job (`cosign attest`).
- **`check_index REPOSITORY DIGEST DIR DIR`**: đúng khi `REPOSITORY@DIGEST`, đọc lại từ registry, là một index đúng hai manifest, `linux/amd64` và `linux/arm64`, mà digest là các file `digest` của hai DIR (mỗi nền tảng một thư mục, nêu trong file `platform`), và khi DIGEST đúng là digest của các byte đó. Cái được ký và attest khi đó đúng là cái đã quét.
- **`attest_max_age`**: attestation `vuln` cũ nhất mà một bản phát hành được mang khi vào `main`, tính bằng giây: 48 giờ, chừa ít nhất 24 giờ trước giới hạn 72 giờ của Kyverno cho merge và sync. Chỉ diễn tập hạ nó, qua `SVP_ATTEST_MAX_AGE` (`<số>s`, `m` hay `h`; không bao giờ đặt trong `.env`).

### Cấu hình mẫu và image diễn tập

- **`deploy/ci/cluster-values.example.yaml`** là ví dụ giá trị `cluster` của Application gốc `svp-root` trên nền tảng `eks`: cái phụ thuộc tài khoản AWS hay một phiên, không bao giờ vào git. Output `cluster_values` của repo hạ tầng cho map thật, bootstrap GitOps đặt nó lên root, và các template `platforms/eks/<tên>.values.tpl` của `svp-gitops` biến nó thành values của từng component.
  `deploy/ci/gitops-check.sh` render nền tảng `eks` với file này thay vào, nên mọi khoá của hợp đồng có ở đây, mỗi khoá một giá trị đúng dạng mà không gọi tên gì thật: dải riêng tư (RFC 1918), dải địa chỉ tài liệu (RFC 5737) cho địa chỉ công khai, định danh và tài khoản toàn số 0, tên miền dành riêng `example` (RFC 2606), và tài khoản giả `111111111111` trong ARN của các role.
  Thêm một khoá vào hợp đồng thì thêm nó ở đây, vào output đó, vào các template và vào bảng của hợp đồng.
- **`deploy/ci/drill/vulnerable.Dockerfile`** (`drill-vulnerable`): image build chỉ để diễn tập admission. Nó không bao giờ được chạy: không chart nào trỏ tới nó, và Kyverno phải từ chối nó vì attestation `vuln` đã ký của nó liệt kê lỗ hổng CRITICAL. Build qua cùng pipeline hai kiến trúc như các service, nên các phát hiện CRITICAL là khác biệt duy nhất với một bản phát hành.
  Base cố ý cũ và giữ cũ (Renovate bỏ qua thư mục này): Alpine 3.12.0 (2020), ghim bằng digest của index đa kiến trúc, mà trivy báo CRITICAL trên cả `linux/amd64` và `linux/arm64` (apk-tools CVE-2021-36159, OpenSSL CVE-2021-3711, zlib CVE-2022-37434). Không thêm bí mật nào: cổng bí mật vẫn áp cho image này.

### Script của pipeline image

- **`image-guard.sh`** là guard của các action `image-leg`, `image-index`, `image-sign`; mỗi subcommand chạy ở một điểm của pipeline:
  - `leg IMAGE ARCH OUT`: trước khi build một chân (action `image-leg`);
  - `trivy-report LABEL OUT`: trước cổng trivy, `OUT/trivy.json` là một báo cáo `trivy image`;
  - `grype-summary LABEL OUT`: sau grype, số đếm và các match Critical của `OUT/grype.json`;
  - `sarif IMAGE ARCH OUT`: SARIF của cả hai lượt quét, một category cho mỗi image và kiến trúc;
  - `push IMAGE ARCH OUT`: trước khi push, in tag để đẩy image đã quét; `pushed IMAGE ARCH OUT`: sau khi push, manifest đọc lại mang config đã quét;
  - `index IMAGE LEGS`: trước khi ghép index (action `image-index`); `index-check IMAGE LEGS OUT`: sau đó, index đọc lại có đúng hai manifest đã quét;
  - `sign IMAGE OUT`: trước khi ký (action `image-sign`): cái cần ghi, và predicate `vuln`.

  Luật mà mọi subcommand giữ: IMAGE là service hay image diễn tập của nguồn phát hành mà repo chạy job thuộc về (`use_build_source` của `common.sh`); code là của `code_root` (`SVP_CODE_ROOT`, input `code-root` của các action: checkout của `svp-frontend` trong lượt của nó) và `HEAD` của nó là commit của lượt (`check_code_tree`); cả hai được kiểm trước khi gọi docker. Cái được đẩy là cái đã quét: config digest của manifest đã đẩy là `ImageID` của báo cáo trivy.
  Index có đúng hai manifest đã quét; cái được ký và attest là index đọc lại. Chỉ `drill-vulnerable` được qua CRITICAL (`allow-critical`); bí mật chặn mọi image. Một bản phát hành chỉ được ký khi workflow của lượt là danh tính của nguồn của nó; mỗi bundle (chữ ký, SBOM, `vuln`, provenance) chỉ được ghi khi digest chưa có bundle loại đó, và một digest ở định dạng cũ của cosign (`.sig`) bị từ chối.
- **`plan.sh`** là job đầu của `images.yml`: quyết định lượt này làm gì và trao cho các job sau bằng output (`step_output` của `common.sh`; stdout trên máy). Output: `mode` (`build`, `rescan` hay `drill`); `images` (mảng JSON image cần build: service đổi khi build, image diễn tập khi drill); `legs` (ma trận JSON `{"include": [{image, arch, runner}]}`,
  mỗi image trên amd64 và arm64, runner native); `has_images` (`true` hay `false`); `base` (commit mà thay đổi được so, `""` khi không dùng được cái nào); `promote_charts` (`true` ở lượt build của `main` không build image nào mà đổi cái chart của repo này đọc, một file dưới `deploy/helm/` hay file mà một symlink ở đó trỏ tới, như
  `deploy/observability/otelcol/k8s-config.yaml`, kể từ `base`: job `promote` vẫn chạy và dời chart mà stg chạy, `envs/stg/charts.yaml` của `svp-gitops`, tới commit này); `values_ref` (input dispatch `values_ref` đã kiểm, chỉ ở rescan: một ref của `svp-gitops`, hay một commit của repo này từ trước khi `svp-gitops` giữ các bản phát hành).
  - Input chỉ đến từ môi trường, không bao giờ nội suy vào script: `EVENT_NAME`, `GIT_REF` (`github.ref`), `PR_BASE_REF` (`github.base_ref`), `INPUT_SERVICES`, `INPUT_RESCAN`, `INPUT_DRILL`, `INPUT_VALUES_REF`, `LAST_SUCCESS_SHA` (`head_sha` mà job `last-success` đọc từ Actions API, có thể rỗng).
  - Chế độ: `rescan` khi lịch hay dispatch `rescan=true`; `drill` khi dispatch `drill=true`; còn lại `build`. Cả hai input cùng lúc, `rescan` hay `drill` ngoài `main`, `services` ngoài `build`, hay `values_ref` ngoài `rescan` thì từ chối (lượt đỏ), không đoán. Base của build không bao giờ là `github.event.before`, vì nó mất thay đổi của một lượt chờ bị thay và của một lượt đã đỏ.
  - Cây của repo khác (`SVP_CODE_ROOT`, `code_root` của `common.sh`, không phải checkout này: CI của một nguồn phát hành khác chạy script này từ checkout ghim của repo này): cả cây là code của image của nó, nên một lượt build mọi service của nguồn phát hành mà lượt build cho (`use_build_source`; `HEAD` của cây phải là commit của lượt), không base, không so sánh; input `services` chỉ được nêu các service đó (hay `all`). Một lượt drill build `drillImages` của nó và bị từ chối khi nó không có;
    chart là của repo này nên `promote_charts` giữ `false`. Với cả hai kiểu cây, lượt phải thuộc repo của một nguồn phát hành và `HEAD` của cây là commit của nó: một job của nguồn khác quên `SVP_CODE_ROOT` dừng ở đây, không ra một plan dựng từ diff của checkout này.
- **`changed-services.sh BASE HEAD`** in, trên một dòng theo thứ tự chữ cái, các service mà image phải build cho các thay đổi từ commit BASE tới commit HEAD; lý do ra stderr. Ngoài danh sách ở mục `images.yml` phía trên:
  - Đổi bảng image (`deploy/docker-bake.json`) tính theo target: target của một service đổi (so dưới dạng JSON giữa hai commit) thì build service đó; mọi thay đổi khác của bảng (group `default`, một target không service nào của hai commit nêu, bất cứ gì ngoài các target), hay một bảng mà BASE không có, là thay đổi của pipeline.
  - Pipeline là `.github/workflows/images.yml`, các composite action nó build, quét và ký (`.github/actions/image-*/`), và mọi thứ dưới `deploy/ci/` trừ các file mà không job image nào đọc. Các file không tính: `trivy-config-ignore.yaml` (chỉ `make trivy-config` đọc, nên gia hạn một mục của nó, cứ nhiều nhất 90 ngày, không phát hành gì), script của các lượt kiểm chứng của `verify.yml` (`verify-host.sh`, `verify-mask.sh`, `verify-collect.sh`, script của các bước dưới `deploy/ci/verify-steps/`,
    `ghcr-digest.sh` mà bước và diễn tập supply chain gọi), mọi test `*-test.sh` (do các job của `ci.yml` và máy dev chạy) và fixture của test dưới `testdata/`, script của check `svp-gitops` (`gitops-check.sh`, mà check `svp-gitops` và `make helm-check` chạy, cùng `values-check.sh` và `verify-release.sh` mà chỉ nó, `make k8s-gitops-up` và diễn tập chạy), policy Kyverno `gitops-policies/` và policy conftest `gitops-tree-policies/`, `contract.sh` (luật version và phát hành hợp đồng
    API của gateway: job `contract` của `images.yml` chạy nó nhưng nó không build hay promote image nào), và các policy conftest của file ignore `ignorefile-policies/` (cổng áp dụng chúng, nhưng job `config` kiểm các file đó bằng chúng ở mọi PR, như khi chính các file đổi). Các helper mà `deploy/ci/` source từ `deploy/k8s/lib.sh` vẫn tính (`docker_`, `values_field`, `ghcr_prefix`, bảng image), và các dòng của `Makefile` ghim image mà cổng chạy (`TRIVY_IMAGE`, `SYFT_IMAGE`, `GRYPE_IMAGE`, `COSIGN_IMAGE`);
    thay đổi khác của `Makefile` không tính. Nhờ vậy PR Renovate hằng tuần nâng các công cụ đó build và quét mọi image với trivy hay grype mới trước khi merge, thay vì để rescan hằng ngày trên `main` gặp nó đầu tiên. Cái giá cũng ở `main`: thay đổi như vậy phát hành lại cả sáu image (và mở PR promote của chúng) dù không code service nào đổi.
  - Chỉ so sánh khi BASE là HEAD hay tổ tiên của nó. BASE rỗng, toàn số 0, clone này không biết, hay không so được với HEAD (force push, lịch sử viết lại): cả sáu; build thừa tốn phút runner, bỏ sót một thay đổi thì phát hành một image thiếu nó. HEAD là tổ tiên thật của BASE (một lượt cũ chạy lại sau khi lượt mới hơn đã thành công): không gì cả, lượt mới hơn đã build mọi thay đổi tới commit của nó.

### Quét lại, cổng quét và file ngoại lệ

- **`rescan.sh`** quét lại các image đã phát hành mỗi ngày: một bản phát hành sạch lúc build, mà lỗ hổng mới được công bố hằng ngày và Kyverno chỉ nhận attestation `vuln` trong 72 giờ, nên mọi digest đã phát hành được quét lại với DB mới nhất và attestation được thay. Một digest giữ định dạng nó được ký: định dạng cũ của cosign (`.sig`, `.att`) được thay attestation `vuln` ở định dạng đó bằng `--replace` như lúc build; Sigstore bundle nhận một bundle `vuln` mới và mọi bundle `vuln` cũ bị gỡ (`replace_vuln_bundle`
  của `common.sh`). Không bao giờ định dạng kia: một digest mang cả hai chỉ được đọc theo bundle. Nhánh định dạng cũ bỏ khi không môi trường nào nêu một digest như vậy.
  - `rescan.sh scan-index REPOSITORY DIGEST OUT`: đọc index `REPOSITORY@DIGEST` từ registry, tìm hai manifest của nó (`linux/amd64`, `linux/arm64`) và quét MỖI cái từ registry với cờ của cổng (trivy đọc một nền tảng mỗi lần quét, nên quét index không chứng minh gì về arm64). Ghi `OUT/amd64` và `OUT/arm64` theo bố cục mà `vuln-predicate.sh` đọc và in hai digest manifest.
  - `rescan.sh run [--source NAME] OUT GITOPS_DIR [VALUES_REF]` (chỉ CI: nó attest): NAME phải là nguồn phát hành của repo chạy job (`use_build_source`), và job phải là workflow mà nguồn đó ký (`run_builder_id` so với subject của nó); kiểm trước khi đọc gì, vì attestation `vuln` bị thay bất kể ai ký bản cũ (`cosign attest --replace`, hay bundle `vuln` cũ bị gỡ), nên một lượt của repo này nêu nguồn của repo khác (hay quên `--source`) sẽ thay
    attestation của nguồn đó bằng danh tính của nó, và Kyverno rồi từ chối mọi pod mới của các bản đó. Với mỗi bản phát hành mà `list` in: digest rỗng thì bỏ qua; repository khác image của service thuộc nguồn NAME (`backend`, repo này, khi không nêu; `deploy/helm/svp-policy/files/sources.json` của checkout này), digest sai dạng, hay digest không có chữ ký của `images.yml` của nguồn đó trên `main` thì không được attest và làm lượt đỏ; nên bất kể một ref liệt kê gì, chỉ digest mà workflow đang chạy đã ký trên `main` mới có attestation mới: không repo nào attest
    bản của repo khác. Mỗi digest còn lại được quét (`scan-index`), predicate dựng bằng `vuln-predicate.sh --allow-critical` và attest làm attestation `vuln` duy nhất của digest, ở định dạng nó được ký, nên attestation luôn chứa kết quả thật: một CRITICAL tìm thấy hôm nay được ghi lại (Kyverno rồi từ chối pod mới vì nó, không vì một attestation cũ) và làm lượt đỏ, lượt đỏ gửi mail cho chủ repo. Một bí mật tìm thấy hôm nay không bao giờ được attest: nó làm lượt đỏ trước khi ghi gì, như lúc build. SARIF của các digest của `main` của `svp-gitops` ra `OUT/sarif` cho tab Security. Image diễn tập không ở file image nào nên không bao giờ được quét lại.
  - `rescan.sh list [--source NAME] GITOPS_DIR [VALUES_REF]` in các bản phát hành mà một lượt của nguồn NAME quét lại, mỗi dòng một bản: service, repository, digest (cả hai rỗng khi chưa phát hành) và nơi đọc, cách nhau bằng tab. Đọc như dữ liệu bằng `git show`, không chạy: `image.repository` và `image.digest` của `envs/<env>/images/<service>.yaml` ở mọi môi trường của `svp-gitops`, ở `main`
    của nó, ở nhánh promote của nguồn đó (`bot/promote-stg` cho `backend`, `bot/promote-stg-<NAME>` với nguồn khác) khi PR của nó đang mở ở đó (PR của app promoter của nguồn, không bao giờ của một fork từ nhánh trùng tên), và ở `VALUES_REF` khi có (một nhánh, một commit đủ hay `refs/pull/<n>/head` của `svp-gitops`). File nêu bản phát hành của nguồn khác bị bỏ khỏi tập kèm một dòng stderr (CI của nguồn đó rescan nó); file dưới prefix của không nguồn nào được liệt kê, nên lượt đỏ vì nó. Chỉ với `backend`, một
    `VALUES_REF` mà `svp-gitops` không có, và là một commit đủ của repo này từ trước khi `svp-gitops` giữ các bản phát hành, thì được đọc ở đó, từ `deploy/k8s/values/services/<service>.yaml`; mọi bản phát hành lịch sử đó nêu nằm dưới prefix mà repo này có trước khi đổi tên, không nguồn nào của bảng còn nêu nó, nên lượt đỏ vì nó. `GITOPS_DIR` là clone `svp-gitops` (của CI, từ `make gitops-clone`): các ref được fetch vào đó dưới `refs/svp/rescan/`, ẩn danh; PR đang mở được hỏi host của repo bằng token của chính job, một lần đọc repo public.
    Fail, sau khi in mọi bản phát hành nó đọc được, khi một file không đọc được hay host không nói PR có đang mở không (`main` và `VALUES_REF` vẫn được liệt kê); fail ngay khi `VALUES_REF` không phải cái nào trong hai thứ trên.
- **`scan-gate.sh`** là cổng quét ngoài pipeline image (các chân của pipeline gate trong composite action `.github/actions/image-leg`, mã thoát của chính các scanner được đọc trong các bước của nó), cùng các luật của file ignore mà hai bên dùng chung. Phán quyết là của chính scanner, từ cờ của chúng; script này chọn cờ, đọc mã thoát và in một dòng mỗi lần quét cho summary của job.
  - `scan-gate.sh [--allow-critical] LABEL REPORT`: rescan hằng ngày (`deploy/ci/rescan.sh`, với `--allow-critical`: nó ghi kết quả thật). REPORT là JSON của `trivy image --scanners vuln,secret` với mọi severity và `.trivyignore.yaml` (bản ghi mà attestation `vuln` và SARIF được làm từ); LABEL gọi tên image trong output (`gateway linux/amd64`). `trivy convert` đọc nó hai lần: lỗ hổng với `--severity CRITICAL --ignorefile .trivyignore.yaml --exit-code`, bí mật với `--exit-code` và không `--severity` (bộ lọc severity giấu một bí mật HIGH). Mỗi lượt chỉ nhận phần riêng của nó trong báo cáo, nên không bên nào đếm phát hiện của bên kia.
  - `scan-gate.sh --grype LABEL DIR`: `make grype` (`grype_check` của `common.sh`). Chạy grype (`grype_sbom` của `common.sh`) trên `DIR/sbom.spdx.json`, một SBOM SPDX do syft ghi, với `--fail-on critical` và `.grype.yaml`, và ghi `DIR/grype.json`, `DIR/grype.sarif.raw`. syft tìm được thứ cài không qua trình quản lý gói, như binary `node` của image web, thứ mà trivy không liệt kê.
  - `scan-gate.sh --check-ignorefile`: kiểm luật của `.trivyignore.yaml` và `.grype.yaml` (`check_ignorefiles`; chính các luật ở `deploy/ci/ignorefile-policies/`), không cần image hay báo cáo, và của `deploy/ci/trivy-config-ignore.yaml`, các misconfiguration mà `make trivy-config` bỏ qua. Job `config` của `ci.yml` chạy nó ở mọi PR và push, và mỗi chân `image-leg` cũng chạy nó trước khi build.
  - Chặn (thoát 1) khi: có bí mật bất kể severity (một package công khai và chữ ký của nó không rút lại được, nên bí mật đã đẩy một lần là lộ vĩnh viễn; không có cách nào vòng qua: `.trivyignore.yaml` chỉ được giữ lỗ hổng, và không bao giờ truyền `--skip-files`, `--skip-dirs` hay `--secret-config` cho trivy); bất kỳ lỗ hổng CRITICAL nào còn lại sau các ngoại lệ, đã có bản vá ở upstream hay chưa, trong báo cáo của trivy hay của grype (`--allow-critical` cho CRITICAL qua trong báo cáo trivy, ở rescan, không bao giờ cho bí mật qua);
    một file ignore phạm luật của nó (một mục hết hạn là ngoại lệ, chỉ `--check-ignorefile` đỏ vì nó). HIGH trở xuống chỉ được báo: số đếm trong summary của job, chi tiết trong SARIF. Thoát 2: không đọc hay chạy được quét (REPORT không phải báo cáo `trivy image`, trivy hay grype lỗi, không tải được DB grype). In số đếm và, với phát hiện chặn, bảng CRITICAL của trivy và luật, file, dòng của mỗi bí mật: không bao giờ đoạn khớp (trivy vẫn che bí mật trong phát hiện của nó; báo cáo thô không bao giờ in).
  - Các ngoại lệ là của cây đang quét (`code_root` của `common.sh`): của checkout này, hay của checkout repo khác nêu bởi `SVP_CODE_ROOT` (CI của nó chạy script này từ checkout ghim của repo này), nơi cả hai file phải có: một cây thiếu chúng là cây sai, không phải cây không có ngoại lệ.
  - `check_ignorefiles live|gate`: luật của `.trivyignore.yaml` và `.grype.yaml` của cây (mỗi file khi có) và, ở chế độ `live` (job `config`), của cả `deploy/ci/trivy-config-ignore.yaml`. Luật là policy conftest trên file đã parse, viết và giải thích ở `deploy/ci/ignorefile-policies/` (test bằng `make conftest-verify`), chạy trên các file cùng lúc (`--combine`: mỗi rule của `.grype.yaml` phải là một mục của `.trivyignore.yaml`). Ở `live` một mục hết hạn phạm luật; các cổng của một báo cáo (rescan, `make grype`) để việc đó cho trivy, nơi bỏ mục hết hạn. Hai phép kiểm ở lại đây vì policy không làm được: không mapping nào của một file có khoá hai lần (parser của conftest giữ khoá sau, trivy và grype từ chối file; `yq` thấy mọi khoá) và mỗi path của `trivy-config-ignore.yaml` là một file của repo. conftest và `yq` chạy từ image mà `Makefile` ghim (`CONFTEST_IMAGE`, `YQ_IMAGE`), không mạng, bằng user của người gọi, file mount chỉ đọc. In một dòng `FAIL` cho mỗi luật bị phạm; ở `live`, một dòng `ok` khi không có.
- **`deploy/ci/trivy-config-ignore.yaml`**: các phát hiện của `make trivy-config` là lựa chọn có chủ đích, bỏ qua có thời hạn. Phát hiện sửa được mà không đổi hành vi thì được sửa, không liệt kê ở đây. `make trivy-config` truyền file này cho `trivy config` bằng `--ignorefile`; cổng image không bao giờ đọc nó, nên không gì ở đây cho một lỗ hổng hay bí mật qua. Luật được kiểm ở mọi PR bằng `deploy/ci/scan-gate.sh --check-ignorefile` (job `config`
  của `ci.yml`): chỉ phần `misconfigurations`; mỗi mục có `id` (`DS-...`, `KSV-...`), các `paths` nó áp dụng (một id không bao giờ bị bỏ qua cho cả repo), một `statement` nêu lý do và `expired_at` (yyyy-mm-dd) nhiều nhất 90 ngày sau ngày kiểm. Một misconfiguration chỉ đổi khi repo đổi, nên 90 ngày thay vì 30 của một lỗ hổng. Tới `expired_at` trivy bỏ mục và phát hiện hiện lại ở lượt kế của `main`.
  - Lý do của các mục HEALTHCHECK: Kubernetes và compose kiểm sức khoẻ chứ không phải image: Kubernetes bỏ qua `HEALTHCHECK`, và compose cho mỗi container cái riêng (`/app healthcheck` cho các service Go, một fetch `/healthz` bằng `node` cho web client, không có cho các container migrate chạy một lần, là image service chạy với lệnh `migrate`, và không có cho `media-worker`, một consumer không có cổng). Một `HEALTHCHECK` trong image sẽ bắt đầu kiểm trong các container hiện không có,
    các container migrate bị đánh dấu unhealthy khi chúng chạy. Image diễn tập không bao giờ chạy.
  - Lý do của mục image chart dữ liệu: image của các chart dữ liệu đến từ publisher upstream của chúng, ghim bằng digest của index đa kiến trúc (bước 4 của `deploy/ci/gitops-check.sh`, Renovate đề xuất mỗi digest mới). Check chỉ tin ECR, GCR và ACR, nên tin một registry ở đây nghĩa là chép image vào một registry riêng, một quyết định riêng.

### `verify-release.sh` và `contract.sh`

- **`verify-release.sh [--gitops DIR] [--rev REV] [--env ENV] REPOSITORY DIGEST`**: đúng khi bản phát hành `REPOSITORY@DIGEST` được vào một môi trường của cấu hình triển khai: REPOSITORY là `<imagePrefix><service>` của một nguồn phát hành mà `services` nêu `<service>`, DIGEST mang một chữ ký và đúng một attestation `vuln` của `images.yml` của nguồn đó trên `main`, và attestation đó phủ `linux/amd64` và `linux/arm64`, không liệt kê CRITICAL và không quá 48 giờ tuổi
  (`SVP_ATTEST_MAX_AGE` trong diễn tập). 48 giờ chừa ít nhất 24 trước khi Kyverno từ chối pod mới ở 72. Ẩn danh: không cần token, nên một job PR (`contents: read`) và một máy chạy được; cosign từ `PATH`, không thì `COSIGN_IMAGE`.
  - Policy của một môi trường là chart `svp-policy` ở commit mà `envs/ENV/charts.yaml` của nó ghim, ở môi trường ENV (mọi môi trường khi không có `--env`) của cấu hình triển khai DIR (một cây `svp-gitops`; `gitops_dir` của `deploy/k8s/lib.sh` khi không có `--gitops`) ở commit REV (DIR như trên đĩa khi không có `--rev`). Bảng nguồn phát hành của nó quyết định nguồn, nên cả danh tính, của REPOSITORY (`release_source_in` của `common.sh`), như Kyverno chọn attestor theo prefix.
  - Khi policy kiểm build provenance (`requireProvenance`: `values.yaml` của nó, rồi `envs/ENV/svp-policy.yaml`, `provenance_required` của `common.sh`), bản phát hành còn phải mang đúng một attestation provenance cùng danh tính qua được cái Kyverno kiểm (`builder.id`, repository và ref của workflow của nguồn nó), mà commit nguồn là commit mà chứng chỉ của chữ ký nêu (`cosign --certificate-github-workflow-sha`): một provenance khai commit khác với lượt đã ký nó bị từ chối.
  - Cùng các lệnh cosign đọc một bản phát hành ký bằng Sigstore bundle (provenance do `actions/attest` ghi) và một bản ở định dạng cũ của cosign (image `.sig`, `.att`), nên bản phát hành của cả hai qua khi các môi trường còn chạy bản cũ; một digest chỉ mang một định dạng (`release_format` của `common.sh`).
- **`contract.sh`**: hợp đồng REST của gateway, `services/gateway/openapi.yaml`, như một bản phát hành có version: web client build type của nó từ một version đã phát hành và ký, không từ một file của repo này. Hai lệnh:
  - `contract.sh check BASE`: check của PR (`make api-contract-check`, job `api-contract` của `ci.yml`). So spec của working tree với spec ở commit BASE, theo byte và bằng oasdiff (`OASDIFF_IMAGE` của `Makefile`, không mạng, `$ref` ngoài bị từ chối), và fail khi luật version ghi ở đầu spec bị phạm: `info.version` của một bên không phải `MAJOR.MINOR.PATCH`; file đổi mà `info.version` không lớn hơn ở BASE; oasdiff thấy một breaking change mà major không đổi (từ `1.0.0`; dưới đó mọi thay đổi có thể break, như semver cho phép)
    hay version giảm (các check `api-version-not-bumped`, `api-major-version-not-bumped` và `api-version-decreased` của nó, nâng từ INFO lên ERR ở đây); changelog của oasdiff không rỗng (một operation, một field, một giá trị enum...) mà chỉ PATCH tăng. BASE toàn số 0 (một push tạo nhánh), hay BASE không có spec: không có gì để so, một dòng trong summary của job và thoát 0. Changelog ra log và summary của job.
  - `contract.sh publish [--dry-run]`: bản phát hành, chỉ trên `main`. Đẩy spec như một OCI artifact (`ORAS_IMAGE` của `Makefile`) tới `<ghcr_prefix>/api/gateway:<info.version>`, rồi ký digest đó keyless bằng cosign ở định dạng cũ (`--new-bundle-format=false`; image thì ký bằng Sigstore bundle) (danh tính của nguồn phát hành `backend` trong `files/sources.json` của chart `svp-policy`, đọc bằng `sign_identity` của `common.sh`, cái mà Kyverno và mọi bên xác minh đọc). Một version không bao giờ được phát hành hai lần: tag đã chứa đúng file này (cùng digest layer) được để nguyên, chỉ ký nếu thiếu chữ ký; tag chứa gì khác thì fail và không ghi gì (phải phát hành version kế tiếp). Trước khi đẩy gì, lượt phải là cái ký được với danh tính đó (`run_builder_id`), nên một lượt của workflow khác, một nhánh hay một máy không bao giờ đẩy một version mà nó không ký được. `--dry-run` đọc registry không credential và chỉ nói việc sẽ làm. Khi không phải dry run cần `docker login` tới registry và `id-token` của job (cosign trên `PATH`).
    Hai lượt không được phát hành cùng lúc: phép kiểm ở trên và lần đẩy là hai request, nên workflow chạy chúng lần lượt (nhóm concurrency không huỷ trên `main`). Viết cũng chạy được trên bash 3.2 (macOS).

### `gitops-check.sh`, `values-check.sh` và policy Kyverno

- **`gitops-check.sh GITOPS_DIR [BASE]`** là check của một cây của repo triển khai `svp-gitops` (`base/`, `envs/`, `argocd/`), chạy bởi workflow của repo đó từ một checkout của repo này ở một commit ghim, và trên máy với một bản clone. Thoát 0 khi mọi bước qua; mỗi bước in một dòng cho mỗi thứ nó kiểm, dòng `FAIL` ra stderr. Năm bước và các chế độ riêng lẻ (`--tree`, `--policy`) đã mô tả ở mục
  `svp-gitops` phía trên; chi tiết còn lại:
  - `gitops-check.sh --worktree GITOPS_DIR` là cùng phép render trên một bản clone `svp-gitops` (`main`, trong CI), với chart của working tree của repo này đứng thay `revision` của mọi môi trường: cái `make helm-check` chạy khi chart đổi trước khi merge. Bước 1 khi đó chỉ kiểm hình dạng của `charts.yaml` và các file image, vì `revision` chúng ghim và cái dẫn xuất từ nó là check riêng của `svp-gitops`, và bước 5 (các image phát hành, là của `svp-gitops`) bỏ qua.
  - Bước 1 dựng input cho policy: một tài liệu JSON gồm các mục và nội dung file của cây; với mỗi môi trường, `revision` có là một commit trên `origin/main` của repo này không (không thì một dòng `FAIL`), hai giá trị mà commit đó dẫn xuất (`podSecurityVersion` của `deploy/helm/svp-cluster/values.yaml`, sha256 của `deploy/observability/otelcol/k8s-config.yaml`) và bảng nguồn phát hành ở commit đó (`release_sources` của `deploy/k8s/lib.sh`; một revision từ trước khi có bảng đó thì fail); và, với BASE,
    PR: tác giả (`pull_request.user.login` của sự kiện ở `GITHUB_EVENT_PATH`; trên máy, nơi `GITHUB_EVENT_NAME` không đặt, `SVP_CHANGE_REQUEST_AUTHOR`), người gửi của sự kiện (`sender.login`) và, với PR của một bot, các file đổi từ BASE tới HEAD. Tác giả hay người gửi không đọc được thì fail; không có BASE, hay với một lượt không phải PR, luật in một dòng skip. Một `conftest` không trả lời, hay không có kết quả nào từ một policy, làm bước fail. Một bản phát hành có được ký, và build từ commit mà tag của nó nêu không, là việc của bước 5.
    Một môi trường ghim một commit của `svp-gitops` (`gitopsRevision` của `charts.yaml`; chỉ prd, theo các policy) cần commit đó trong GITOPS_DIR, một clone có lịch sử: nằm trên `origin/main`, chứa `argocd/apps/Chart.yaml` (không thì một dòng `FAIL`).
  - Bước 2: root chart nhận `platform` làm value, và trên `eks` thêm `cluster` từ `deploy/ci/cluster-values.example.yaml`, dạng mà GitOps Bridge đặt với giá trị thật của phiên (annotation `svp.io/cluster-values` của cluster Secret), không bao giờ vào git (bước 1 giữ `argocd/apps/values.yaml` và các file của `platforms/` ở mức không đặt cái nào). Cái mà root render từ một template `<tên>.values.tpl` bị giữ theo luật của một overlay: không `image`, `canary` hay `httpRoute.name` cho một release của chart `svp-service` (`envs/<env>/images/` nêu image của nó). Root fail khi một overlay hay một file image phạm luật của nó.
    Root sinh một Application cho mỗi component chạy trên nền tảng, mỗi cái đọc các file values `base/` (và `archValues` của kiến trúc của nó) < `platforms/<platform>/<tên>.yaml` < `envs/<env>/<tên>.yaml` < `envs/<env>/images/<tên>.yaml` mà có, theo thứ tự đó (gọi tên không kèm ref của nguồn), rồi một `valuesObject` đúng khi `platforms/<platform>/<tên>.values.tpl` có. Mọi nguồn nó đọc từ `svp-gitops` nêu một ref đầy đủ (`refs/heads/<nhánh>`) hay một commit làm `targetRevision`,
    không bao giờ một tên ngắn mà Argo CD có thể phân giải thành tag cùng tên. Argo Rollouts nhận đúng một plugin traffic router trên mỗi kiến trúc, asset build cho nó, cả hai thuộc một release. `gitops-check.sh --root GITOPS_DIR` chạy riêng bước 1 và 2 (test của chúng, không mạng).
  - Bước 4: render bằng `helm template --include-crds` mọi component của `components.json` với values `base/` của nó (chart upstream ở version ghim, chart của repo này ở mỗi revision; một component không chạy trên k3d, nền tảng của đường dev, thì dùng values của nền tảng của nó), và Argo CD như `argocd/bootstrap.json` cài nó, rồi lại với `argo-cd.yaml` của mỗi nền tảng, như `deploy/k8s/gitops.sh` cài nó ở đó. Policy `images-pinned` giữ mọi image của các render đó theo đúng một digest. Dưới policy, một phép quét text của các render (`image_refs`) tìm mọi tham chiếu image khác không có digest làm nó fail như ngoài policy.
    Mỗi môi trường chạy các image build một lần cho `base`: mỗi component có values của một nền tảng (`platforms/<platform>/`) được render lại với chúng, và render đó không chạy phiên bản khác (tag hay digest) của một image mà `base` chạy, dù nó có thể chạy ít hơn hay khác (object store của cloud thay cho của cluster, một controller của cloud); mỗi component có overlay ở `envs/<env>/` được render lại với nó sau đó, và các image của render đó, gồm cả bảy image service, phải đúng là của render mà nó thêm lên (của nền tảng, nếu không thì của `base`), so trên các image mà `image_refs` đọc.
  - Bước 5: `deploy/ci/values-check.sh --gitops` trên các file image đổi từ commit BASE tới HEAD của GITOPS_DIR (mọi file khi không có BASE): bản phát hành đã ký, attestation `vuln`, và build provenance mà policy của môi trường đòi. Với bản phát hành đã kiểm provenance, `image.tag` phải là 12 hex của commit mà provenance nêu (`tag_provenance_mismatch` của `common.sh`); ở môi trường đòi provenance, một lần kiểm bản phát hành không nêu commit provenance cũng fail.
  - GITOPS_DIR chỉ được đọc, không bao giờ ghi: mọi thứ khác xảy ra trong một thư mục tạm. Cần bash, git, `jq`, helm, docker và mạng (kho chart, GHCR) và, không có `--worktree`, lịch sử của repo này tới mọi revision (clone đầy đủ, đã fetch `origin/main`). Có BASE thì GITOPS_DIR phải là đỉnh của repo git riêng của nó.
- **`values-check.sh --gitops DIR BASE`** là check bản phát hành của một cây `svp-gitops`, nơi các image phát hành là `envs/<env>/images/<service>.yaml` (`gitops-check.sh` chạy nó trong check của repo đó; bootstrap của đường GitOps cũng chạy). Với mỗi file như vậy của repo git của DIR đã đổi từ commit BASE tới HEAD, một `image.digest` không rỗng phải nêu một bản phát hành được vào môi trường đó:
  repository của service của một nguồn phát hành mà policy của môi trường đó nhận (`release_source_in` của `common.sh`: bảng của chart `svp-policy` ở commit mà `envs/<env>/charts.yaml` ghim), ký bởi `images.yml` của nguồn đó trên `main`, một attestation `vuln` phủ cả hai nền tảng, không CRITICAL, không quá 48 giờ tuổi, và một attestation build provenance khi chart `svp-policy` kiểm provenance ở môi trường đó (`verify-release.sh --gitops DIR --env <env>`: `values.yaml` của chart ở commit mà `envs/<env>/charts.yaml` ghim, rồi
  `envs/<env>/svp-policy.yaml` của DIR, như Argo CD trao chúng cho chart). Mọi file image của một môi trường mà policy của nó đã đổi từ BASE (`envs/<env>/svp-policy.yaml` hay `envs/<env>/charts.yaml`: `policy_values_paths` của `common.sh`) cũng được kiểm, vì cái mà mọi bản phát hành ở đó phải mang có thể đã đổi: PR bật provenance fail khi một bản phát hành của môi trường đó không có nó. Mọi file image của mọi môi trường khi BASE rỗng (DIR khi đó không cần là repo git).
  Kyverno nhận attestation tới 72 giờ, nên một digest vào một môi trường cùng với một cái cũ hơn (một PR promote gộp, một revert về digest cũ) sẽ bị từ chối pod mới; check này bắt nó trước khi merge. Không dùng token. Khi fail, in lệnh dispatch `images.yml` của repo code làm mới attestation `vuln` của các bản phát hành mà `svp-gitops` nêu.
- **`gitops-policies/images-pinned.yaml`**: mọi image mà một manifest đã render nêu được ghim bằng đúng một digest, `image:tag@sha256:<64 hex>` hay `image@sha256:<64 hex>`: một tag có thể bị đẩy lại sang nội dung khác, một digest thì không. Kyverno chỉ kiểm các image phát hành của namespace `svp` lúc admission, nên các image của namespace nền tảng được giữ theo digest của chúng trên render, bởi `deploy/ci/gitops-check.sh` với Kyverno CLI (`kyverno apply`, không cluster). Các image phát hành cũng qua: một render chỉ của `base/` cho chúng tag và digest giữ chỗ. Nơi một image được đọc:
  - mỗi container, init container và ephemeral container của một pod template (Pod, CronJob, và mọi kind có `spec.template.spec`: Deployment, StatefulSet, DaemonSet, ReplicaSet, Job, Rollout của Argo Rollouts): `image`; giá trị của một mục `env` mà tên nói nó giữ một image (`OPERATOR_IMAGE_NAME`, `RELATED_IMAGE_FOO`); trong giá trị `env`, `args` và `command`, một cờ mà tên chứa "image" (`--acme-http01-solver-image=...`) và bất cứ gì có dạng `registry/path:tag` hay `registry/path@sha256:...` với host registry có dấu chấm (`--prometheus-config-reloader=quay.io/...`);
  - một khoá của `spec` kết thúc bằng `image`, `Image` hay `imageName` có giá trị chuỗi (`spec.image` của Prometheus và Alertmanager, `spec.imageName` của Cluster của CloudNativePG);
  - mỗi giá trị của `data` của một ConfigMap: giá trị của khoá mà tên nói nó giữ một image (`SIDECAR_IMAGE`), và trong text (một file cấu hình mà operator đọc, như `envoy-gateway.yaml` của Envoy Gateway) các dòng `image: ...`, `imageName: ...`, `<gì đó>Image: ...`, `FOO_IMAGE: ...`, các cờ và dạng `registry/path:tag` ở trên.

  Một tên nói nó giữ một image: một tên env hay khoá viết hoa có từ `IMAGE` hay `IMAGES`, một cờ có "image"; không phải một thiết lập của image (`..._PULL_POLICY`, `..._TAG`, `--image-pull-secrets`), và chỉ cho giá trị có dạng image (có `/`, `:` hay `@`, hay một tên trần như `alpine`; không phải số hay boolean: `--imageVerifyCacheMaxSize=1048576`). Chỗ khác không được đọc ở đây; `deploy/ci/gitops-check.sh` quét text của render tìm mọi tham chiếu image còn thiếu digest và nêu nó là ngoài policy này.
- **`gitops-policies/no-lab-hosts.yaml`**: một render cho nền tảng mà render không được nêu `*.svp.localhost` của lab (không có `localHosts` trong khoá `platforms` của `argocd/apps/components.json` của `svp-gitops`) nêu một host thật ở nơi traffic vào và nơi một service được báo địa chỉ của chính nó: `deploy/ci/gitops-check.sh` đưa Kyverno CLI (`kyverno apply`, không cluster) chỉ các render của những nền tảng đó, sau phép `grep` cả text của chúng tìm `svp.localhost`.
  Được đọc: `spec.hostnames` của HTTPRoute, GRPCRoute, TLSRoute; `spec.listeners[].hostname` của Gateway; `spec.rules[].host` và `spec.tls[].hosts` của Ingress; giá trị `env` của mỗi container của pod template (Pod, CronJob và mọi kind có `spec.template.spec`), thứ mà values của chart biến thành thiết lập của một service (`APP_ORIGIN`, `MEDIA_ORIGIN`).
- **`gitops-check-test.sh`**: các ca âm của `deploy/ci/gitops-check.sh` và của root chart `argocd/apps` của một cây `svp-gitops`. Luật trên file của cây (bước 1) là policy conftest, mỗi ca của chúng là một test của `deploy/ci/gitops-tree-policies/` (`make conftest-verify`, chạy trước ở đây); script này kiểm cái mà script làm quanh chúng và các luật cần một render, một công cụ hay git. Mỗi ca đổi một thứ trong một bản sao mới của TREE (không có commit mà một môi trường ghim) và phải fail với message riêng của nó;
  root cũng được render riêng (`helm template`; với root hai tầng `argocd/root`, tầng 1 rồi `argocd/apps` với values của nó), vì Argo CD dựa vào việc render fail chứ không vào check. TREE có thể có root một tầng hay hai tầng.
  - Phần về ghim của prd (`gitopsRevision` của `envs/prd/charts.yaml`) và root hai tầng (`gitops-check.sh --root`, bước 1 và 2, không mạng) chạy trên một bản sao của TREE được làm thành repo git: commit A0 chỉ có `base/`, commit A trên đó (cuối của `origin/main`) cả cây với root hai tầng, tầng 1 `argocd/root` trao nội dung của `envs/<env>/` cho tầng 2 `argocd/apps`, nơi đặt một overlay và một file image vào `valuesObject` của Application của chúng; working tree rồi ghim prd vào A, như promote prd ghi. Một cây đã có root hai tầng giữ chart riêng của nó; một cây từ trước đó được cho các chart thế chỗ có hình dạng mà check giữ chúng theo: một tầng 1 viết ở đây,
    và `argocd/apps` của nó đọc overlay và file image từ values của tầng đó thay vì như các file values. Các ca dưới đây chỉ sửa một trong hai chart ở nơi cả hai hình dạng giữ cùng text (`platforms` của một component, nguồn có ref `values`, ref `$values/`), hay ghi lại render của tầng 1 rồi đổi nó. Được kiểm: prd render `argocd/apps`, `base/` và `platforms/` ở A còn stg render cây, nên một thay đổi của chúng chỉ tới stg;
    một commit mà clone không có, một commit ngoài `main`, một commit không có `argocd/apps`, một tên nhánh và một cây không phải repo git đều fail trước mọi render; tầng 1 phải ra `svp-apps` ở commit ghim và trao `envs/prd/` của cây; tầng 2 phải đọc mọi file values ở commit ghim, qua các nguồn của `svp-gitops` ở một revision: một nguồn thứ hai ở `main`, thứ mà Argo CD từ chối, fail.
  - Phần về tác giả của một PR chạy `gitops-check.sh --tree DIR BASE` trên repo nháp, như một máy chạy nó (`env -i`, để không có biến của một job CI nào). Cây được làm thành repo git mà commit đầu a0 ghim `k3` ở cả hai môi trường với các bản phát hành của các nguồn của working tree; mỗi ca commit một thay đổi lên trên a0. Tác giả là `SVP_CHANGE_REQUEST_AUTHOR`, hay `pull_request.user.login` và `sender.login` của một file sự kiện, như workflow của `svp-gitops` trao chúng (`GITHUB_EVENT_NAME`, `GITHUB_EVENT_PATH`).

### Policy Rego

#### Policy của cây `svp-gitops` (`deploy/ci/gitops-tree-policies/`)

Một package mỗi file (`gitops.layout`, `gitops.envs`, `gitops.platforms`, `gitops.author`), ca âm ở `*_test.rego` (`make conftest-verify`). `deploy/ci/gitops-check.sh` chạy chúng bằng `conftest test` trên một tài liệu JSON mà nó dựng từ cây, từ repo code và từ PR (bước 1 của check). Input và helper ở `lib.rego`:

- `worktree`: `true` cho `gitops-check.sh --worktree`, nơi working tree của repo code đứng thay `revision` của mọi môi trường, nên `revision` và các giá trị mà `charts.yaml` dẫn xuất từ nó không được kiểm (check của chính `svp-gitops` kiểm);
- `tree`: mọi mục của cây trừ `.git`, theo đường từ đỉnh: `type`, đường đó phân giải ra gì (file, dir hay other, như `test -f` và `test -d` của shell thấy), `link` (đích của một symlink) và `text` (nội dung file);
- `charts`: theo môi trường, cái mà commit mà `envs/<env>/charts.yaml` ghim cho ra: `revision`, `podSecurityVersion` (của `deploy/helm/svp-cluster/values.yaml` ở đó) và `collectorConfigSha256` (sha256 của `deploy/observability/otelcol/k8s-config.yaml` ở đó); một môi trường mà `revision` không phải commit trên `main` của repo code bị bỏ khỏi đây, và script nêu lý do;
- `sources`: theo môi trường, `revision` (rỗng khi có `worktree`) và `sources`, bảng nguồn phát hành (`deploy/helm/svp-policy/files/sources.json`) của repo code ở revision đó, của working tree khi có `worktree`; bị bỏ khi không đọc được, và script nêu lý do;
- `pull_request`: chỉ với một PR: `author` và `sender` (login: ai mở nó, ai gây ra sự kiện đang kiểm) và, với một PR của bot, `changes: [{status, path}]`, các file mà `git diff --name-status --no-renames` liệt kê từ base của nó;
- `data.gitops_check`: `environments` (`["prd", "stg"]`) và `services` (bảy service có image phát hành).

**`layout.rego`**: bố cục của cây: các file mà root chart `argocd/apps` và bootstrap đọc, và các thiết lập của những file đó mà không render nào cho thấy.

- `argocd/apps/Chart.yaml`, `values.yaml`, `templates/applications.yaml`, `components.json`, `argocd/project.yaml` và `argocd/bootstrap.json` là file; `argocd/apps/files/envs` là symlink tới `../../../envs`, qua đó root chart đọc `envs/`.
- `components.json` là JSON với một danh sách component, `external-secrets` trong đó (bước 3 của check xác thực External Secrets của chart `svp-cluster` theo CRD của nó); component `svp-policy` không nêu file values nào, vì các check bản phát hành đọc thiết lập của nó chỉ từ values của chart và `envs/<env>/svp-policy.yaml`.
- `argocd/bootstrap.json` cài chart `argo-cd` của `https://argoproj.github.io/argo-helm` với một file values của cây.
- `argocd/apps/values.yaml` là một map YAML không đặt value `cluster` (cùng lắm một map rỗng): chỉ bootstrap đặt nó, từ values của phiên (output `cluster_values` của repo hạ tầng), không bao giờ vào git.
- Phần bash liệt kê cây không đi vào một symlink tới thư mục, nên cái nằm sau một link sẽ không bị luật nào kiểm (một overlay của `platforms/<platform>` link tới thư mục khác). Hai link mà root chart cần là các link tới thư mục duy nhất mà cây được có, cùng link của root hai tầng tới `envs/` (`argocd/root` đọc `envs/<env>/` qua nó); đích của chúng, `envs/` và `platforms/`, được liệt kê ở chỗ của chúng.

**`envs.rego`**: các môi trường: `envs/` có đúng một thư mục mỗi môi trường (`prd` và `stg`), và trong mỗi cái:

- `charts.yaml` có đúng các khoá `revision`, `podSecurityVersion` và `collectorConfigSha256`, mỗi khoá một dòng (script đọc chúng bằng `sed`). `revision` là commit đầy đủ (40 hex) của repo code mà chart của nó môi trường chạy; `podSecurityVersion` và `collectorConfigSha256` bằng cái mà commit đó cho ra (`input.charts`, script dẫn xuất bằng git). Với `input.worktree` chỉ các khoá được kiểm.
- Chỉ `envs/prd/charts.yaml` được thêm `gitopsRevision`, commit đầy đủ (40 hex) của repo này (`svp-gitops`) mà prd render `argocd/apps`, `base/` và `platforms/` ở đó trong khi `envs/prd/` của chính nó đọc ở `main`; chỉ promote prd ghi nó, là commit của `main` mà stg đã chạy. stg theo `main` và không bao giờ ghim. Root hai tầng `argocd/root` là thứ đọc khoá này, nên một cây đặt nó phải có root đó. Commit có nằm trên `main` của repo này và có `argocd/apps` không thì script kiểm bằng git.
- `images/` có đúng một file mỗi service, `<service>.yaml`, mỗi file chỉ là khối image: không dòng cấp cao nào ngoài `image:`, và `image.repository`, `tag`, `digest` mỗi cái đúng một dòng của khối, như `values_field` của `deploy/k8s/lib.sh` đọc chúng (các job promote và `values-check.sh` đọc file theo cách đó). Repository là của service đó ở đúng một nguồn phát hành của bảng ở revision của môi trường (`input.sources`), tức một bản phát hành mà policy của môi trường đó nhận; `tag` và `digest` được đặt. Bản phát hành có được ký, và build từ commit mà tag của nó nêu không, là bước 5 của check (`values-check.sh`).
- Không overlay `envs/<env>/<tên>.yaml` hay file image nào đặt một giá trị `null`, `{}` hay `[]`, ở độ sâu nào: root trao nội dung của chúng cho các Application của `argocd/apps` trong `valuesObject`, và health check của một Application (`argoproj.io_Application` của `base/argo-cd.yaml`) so spec nó đọc với spec mà controller đã so, bằng Lua, nơi `null` là một khoá bị bỏ còn `{}` và `[]` là một bảng rỗng. Một thay đổi như vậy sẽ để Application `Healthy` trên status của spec trước, và root báo commit mới đã triển khai trước khi nó chạy.
- Hàm `image(path)` đọc `image.repository`, `tag` và `digest` của một file image như `values_field` của `deploy/k8s/lib.sh` đọc chúng: mỗi cái đúng một dòng `<khoá>: <giá trị>` (thụt hai dấu cách) trong khối `image:` cấp cao nhất, giá trị trần hay trong nháy kép và đúng dạng của khoá (`""` khi rỗng); undefined khi một cái không như vậy.

**`platforms.rego`**: lớp nền tảng. Khoá `platforms` của `argocd/apps/components.json` ánh xạ mỗi nền tảng tới các môi trường chạy trên nó (`envs`, mỗi môi trường `prd` và `stg` trên ít nhất một nền tảng) và liệu render của nó có được nêu `*.svp.localhost` của lab không (`localHosts`, `false` khi bỏ); `platforms` của một component, khi đặt, liệt kê các nền tảng của map đó, mỗi cái một lần (không có `platforms`: mọi nền tảng). `platforms/` có đúng một thư mục mỗi nền tảng của map (và `README.md`),
và `argocd/apps/files/platforms` là symlink tới nó. Mỗi file của `platforms/<platform>/` là `README.md`, `argo-cd.yaml` (values của Argo CD của nền tảng, sau `argocd/bootstrap.json`), hay `<tên>.yaml` hoặc `<tên>.values.tpl` với `<tên>` là một component chạy trên nền tảng đó. Một file `platforms/<platform>/*.yaml` bị giữ theo luật của một overlay: một map YAML không đặt khoá `cluster` (cái phụ thuộc cluster tới một component qua template `<tên>.values.tpl`, từ value `cluster` của root), và với một release của chart `svp-service` không `image`, `canary` hay `httpRoute.name`
(image của một release là `envs/<env>/images/<tên>.yaml`, và mọi nền tảng chạy `canary` của `base`). Cái mà các template render được kiểm trên render của root (bước 2 của check).

**`author.rego`**: tác giả của một PR (`input.pull_request`). PR của một bot merge không qua duyệt ở nơi không Code Owner nào sở hữu file (`envs/stg/`), nên một token của bot, bị lộ hay bị dùng sai, chỉ được đổi cái mà bot đó promote. Mỗi file mà PR của một bot (login kết thúc bằng `[bot]`) đổi được xét theo bảng nguồn phát hành của revision mà môi trường của nó ghim (`input.sources`): bot `<promoter>[bot]` của nguồn N đổi `envs/stg/images/<svc>.yaml` và `envs/prd/images/<svc>.yaml` với `<svc>` trong `services` của N;
bot của `backend`, nơi repo của nó giữ các chart, đổi thêm `envs/stg/charts.yaml`, `envs/prd/charts.yaml` và mọi file image của `envs/prd/images/` (promote prd chép cả bộ của stg, gồm cả web); không gì khác, và không bot nào như vậy xoá file. Một bot không promote nguồn nào (Renovate) không đổi gì dưới `envs/`. PR của một người không bị giới hạn ở đây. Một bot gây ra sự kiện (người gửi: ai mở PR hay push commit đang kiểm) mà khác tác giả thì fail, vì các file được phép là của tác giả.

#### Policy của file bỏ qua của cổng quét (`deploy/ci/ignorefile-policies/`)

`lib.rego` giữ helper dùng chung của các policy (package `trivyignore`, `grypeignore`, `configignore`). `deploy/ci/scan-gate.sh` chạy chúng bằng `conftest test --combine`, nên `input` là một danh sách `{path, contents}`, mỗi file được truyền một mục, và trao `data.scan_gate`: `today` (yyyy-mm-dd, UTC) và `live` (`true` ở job `config`, `false` ở các cổng image). `make conftest-verify` chạy test cạnh chúng (`*_test.rego`). Hình dạng của mỗi file ở mục `.trivyignore.yaml` và `.grype.yaml` phía trên; phần dưới là lý do của các luật.

- **`trivyignore.rego`**: chỉ phần `vulnerabilities` được phép (`vulnerabilities: []` khi không có ngoại lệ), vì định dạng của trivy còn có `secrets`, `misconfigurations` và `licenses`, mà trivy sẽ áp dụng, nên một bí mật có thể bị cho qua. Hạn 30 ngày để không ngoại lệ nào sống lâu hơn mà không qua một thay đổi đã duyệt khác. Package `packages` trao các purl của các mục cho luật của `.grype.yaml`, mỗi rule của nó phải là một trong số đó.
- **`grypeignore.rego`**: grype đọc cả file, và nhiều khoá nó biết để lọt một CRITICAL mà không có mục và ngày nào (`only-fixed`, `only-notfixed` và `ignore-wontfix` ở gốc, `vex-documents`, một rule chỉ nêu `fix-state` hay `package.type`, hay một rule không có `package`); một khoá nó không biết thì nó bỏ qua không một lời. Vì vậy file chỉ giữ dạng sau, mọi thứ khác bị từ chối:

  ```yaml
  ignore:                            # khoá gốc duy nhất, một danh sách (ignore: [] khi không có ngoại lệ)
    - vulnerability: CVE-2026-12345  # đúng các khoá này trong một rule
      include-aliases: true          # phủ match mà grype báo dưới một id liên quan (GHSA của CVE)
      package:
        name: ffmpeg                 # đúng name và version
        version: 8.0.1-r0
  ```

  - `vulnerability`, `name` và `version` phải là chuỗi YAML (lý do ở mục `.grype.yaml` phía trên: `null` bị grype bỏ khỏi rule, nên rule phủ mọi lỗ hổng, package hay version; số bị đọc thành text khác; ngày làm grype không khởi động); mỗi giá trị là text thường (chữ, số và `@._:+~/-`, tên sau khi bỏ escape). Trong nháy một giá trị như vậy là text, nhưng dạng ngày (`2026-1-2`) bị từ chối kể cả trong nháy vì file đã parse không còn hiện dấu nháy. `1:20` là text với mọi parser ở đây (không có cơ số 60); `yes` là text với grype nhưng là bool với parser mà conftest đọc file (YAML 1.1), nên tên `yes` được đặt trong nháy.
  - `package.name` là tên của purl với mỗi ký tự `.*+?[](){}|^$\` escape bằng `\`: tên đó phủ đúng một package của nó dù grype đọc nó như regex neo hai đầu hay như text. Viết cách khác thì bị từ chối kể cả khi có mục đúng tên đó (`.*` phủ mọi package ở version đó, `mini.*` và `minimis[t]` phủ `minimist`), và không được khớp với các mục.
  - Tên của một purl là cái grype gọi package của nó, kèm namespace (một scope npm, một đường module Go), trừ package của một bản phân phối (apk, deb, rpm), nơi namespace là bản phân phối. Một rule cho `foo` sẽ phủ cả `foo` không scope, một rule cho `net` phủ mọi package tên `net`.
  - Mỗi rule phải là đúng một purl của một mục của `.trivyignore.yaml`: cùng id, tên của purl như grype gọi package, cùng version; ở `live` (job `config`), của một mục còn hiệu lực. Nên grype không bao giờ có ngoại lệ mà trivy không có, cùng lý do và ngày của nó ở đó.
- **`configignore.rego`** (luật của `deploy/ci/trivy-config-ignore.yaml`): hạn `expired_at` tối đa 90 ngày thay vì 30 của một lỗ hổng, vì một misconfiguration chỉ đổi khi repo đổi. `paths` là đường tương đối trơn của một file (chữ, số, `._/-`; không pattern, không `.` hay `..`), để một id không bao giờ bị bỏ qua cho cả repo. Mỗi path là một file của repo (không phải thư mục, thứ sẽ phủ cả một cây, không phải một file đã mất) thì `deploy/ci/scan-gate.sh` kiểm sau các luật này: Rego không thấy file. Các luật còn lại (chỉ phần `misconfigurations`, mỗi mục có đúng `id`, `paths`, `statement`, `expired_at`) ở mục `trivy-config-ignore.yaml` phía trên.
