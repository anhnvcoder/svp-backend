# Phát hành: CI/CD, chuỗi cung ứng, ba repo và hợp đồng API

Trang này trả lời: một thay đổi đi từ pull request tới pod đang chạy qua những bước nào, ai được làm bước nào, cái gì chứng minh
image đang chạy là image đã build và quét, và ba repo `svp-backend`, `svp-frontend`, `svp-gitops` chia việc với nhau ra sao. Lệnh ở
[`reference/ci.md`](../reference/ci.md), [`reference/k8s.md`](../reference/k8s.md); đọc một lượt chạy CI ở [`ci-cd.md`](../ci-cd.md);
nơi image chạy ở [`deployment.md`](deployment.md).

## CI/CD và chuỗi cung ứng

Vì sao: [ADR-0015](../adr/0015-cicd-devsecops-stage5.md), [ADR-0027](../adr/0027-slsa-build-provenance.md),
[ADR-0040](../adr/0040-sigstore-bundle-actions-attest.md), [ADR-0041](../adr/0041-github-hardening.md).

Image phát hành build trên GitHub Actions, không trên máy: workflow build, quét, ký và đẩy lên GHCR; một PR trong repo `svp-gitops`
ghi digest vào values ([hai repo](#hai-repo-code-và-cấu-hình-triển-khai)); Argo CD đồng bộ; Kyverno chỉ cho pod của `svp` chạy
image đã ký và sạch. Đường dev `make k8s-up` giữ image `dev-*` chưa ký trong registry k3d, policy chạy Audit.

```mermaid
flowchart LR
    dev["Người học<br/>nhánh, PR"]
    renovate["App Renovate<br/>PR dependency"]
    subgraph gh["GitHub: repo public"]
        pr["Pull request"]
        checks["ci.yml: make check, generate-check,<br/>buf, config, gitleaks<br/>images.yml: build-nopush"]
        main["main<br/>ruleset: ci-ok, images-ok"]
        build["images.yml trên main<br/>build amd64 + arm64 → trivy<br/>→ push → index → ký, attest"]
        promote["job promote<br/>(token App)"]
        rescan["rescan hằng ngày"]
    end
    gitops["repo svp-gitops<br/>PR bot/promote-stg,<br/>gitops-ok, auto-merge"]
    ghcr[("GHCR<br/>image theo digest,<br/>Sigstore bundle")]
    sigstore["Sigstore công khai<br/>Fulcio, Rekor, TUF"]
    subgraph cluster["cluster GitOps svp"]
        argo["Argo CD<br/>poll git"]
        kyv["Kyverno svp-images<br/>Enforce, chỉ ns svp"]
        app["Pod của svp<br/>canary gateway"]
    end
    dev --> pr
    renovate --> pr
    pr --> checks
    checks -->|"xanh, merge"| main
    main --> build
    build -->|"push, Sigstore bundle"| ghcr
    build -->|"OIDC → chứng chỉ, log ký"| sigstore
    build --> promote
    promote -->|"envs/stg/images/, charts.yaml"| gitops
    rescan -->|"attestation vuln mới"| ghcr
    gitops -->|"image.digest"| argo
    main -->|"chart ở SHA của charts.yaml"| argo
    argo -->|"tạo pod"| kyv
    kyv -->|"chữ ký, attestation"| ghcr
    kyv -->|"khoá tin cậy TUF"| sigstore
    kyv -->|"nhận"| app
    app -->|"kéo theo digest"| ghcr
```

- **Workflow** (ADR-0015 §1, §2): `ci.yml` chạy đủ mục Kiểm tra (Go test trên Postgres và Redis là service container, lệch code
  sinh, `buf breaking`, cấu hình, chart, digest bên thứ ba, gitleaks toàn lịch sử); `images.yml` build image. Mỗi file một check
  tổng (`ci-ok`, `images-ok`), là hai check bắt buộc của ruleset `main`. Cổng CRITICAL cho lockfile npm của web nằm ở CI của
  `svp-frontend`. Workflow thứ ba `verify.yml` nằm ngoài check bắt buộc ([kiểm chứng trên runner](reliability.md#kiểm-chứng-trên-runner),
  [ADR-0021](../adr/0021-deferred-verification-stage6b.md)); logic của cả ba nằm ở `Makefile` và `deploy/ci/`
  ([ADR-0023](../adr/0023-ci-platform-neutral.md)), script đọc thẳng biến của GitHub Actions và gọi `gh` trực tiếp
  ([ADR-0037](../adr/0037-mainpath-standard-tools.md) §2). Luồng và job của từng workflow cho
  người mới: [`ci-cd.md`](../ci-cd.md). Mọi action ghim SHA commit và chỉ là action của GitHub hay của chính nhà cung cấp công cụ;
  trivy, syft chạy bằng image ghim digest. Mọi job của lượt PR, kể cả PR từ fork, chỉ có `contents: read` và không secret; quyền
  ghi (`packages`, `id-token`, `contents`, `pull-requests`, `security-events`) chỉ ở job chạy trên `main` với code đã qua PR.
- **Build** (ADR-0015 §3, §4, §6): chỉ service có thay đổi so với lần push `main` thành công cuối (tập đường dẫn `image_paths` của
  `deploy/k8s/lib.sh`; đổi đường build, quét, ký thì cả sáu). Image `web` build, ký, promote ở CI của `svp-frontend` bằng cùng script
  ([ba repo](#ba-repo-và-hợp-đồng-api)); trivy quét cả gói npm của `node_modules` (ADR-0019 §1). Mỗi service build native trên
  runner amd64 và arm64, trivy quét tar cục bộ của từng kiến trúc: bí mật (mọi severity) và lỗ hổng CRITICAL chặn **trước** push,
  HIGH chỉ báo (SARIF lên tab Security của `main`); ngoại lệ chỉ qua `.trivyignore.yaml` có lý do, tối đa 30 ngày. Push đúng image
  đã quét (so config digest), rồi ghép index đa kiến trúc `ghcr.io/anhnvcoder/svp-backend/<svc>:<12 hex commit>`.
- **Ký và attestation** (ADR-0015 §7): cosign keyless bằng OIDC của GitHub (chứng chỉ Fulcio, ghi Rekor; không khoá dài hạn), ký
  digest index với identity `images.yml@refs/heads/main`; attestation `vuln` trên index gộp kết quả quét hai nền tảng,
  SBOM SPDX của syft trên từng manifest con. Rescan hằng ngày quét lại mọi digest đang phát hành bằng DB mới và thay
  attestation `vuln` (rescan attest bundle mới rồi gỡ bundle `vuln` cũ). Chữ ký và attestation ở định dạng Sigstore bundle
  ([ADR-0040](../adr/0040-sigstore-bundle-actions-attest.md)); định dạng cũ (`.sig`, `.att`) chỉ còn cho bản phát hành cũ tới khi
  stg, prd hết digest cũ. Index của bản phát hành mang thêm attestation build provenance SLSA v1 do `actions/attest` sinh (workflow,
  ref, commit, lượt chạy), mức SLSA Build L2 (không L3).
- **Promote** (ADR-0015 §9, [ADR-0025](../adr/0025-gitops-config-repo.md) §2, §6): job `promote` dựng lại nhánh `bot/promote-stg` từ
  `main` của repo `svp-gitops` bằng token GitHub App, ghi `repository`, `tag`, `digest` của mọi service đã ký mà stg chưa chạy (không
  bao giờ ghi lùi) vào `envs/stg/images/<svc>.yaml` cùng commit chart vào `envs/stg/charts.yaml`, mở hay cập nhật một PR cuộn và bật
  auto-merge; PR tự merge khi `gitops-ok` xanh; Argo CD poll thấy commit, sync, gateway đi
  [canary](deployment.md#kubernetes-cục-bộ-k3d). Rollback stg là PR revert trong `svp-gitops`.
- **Admission** (ADR-0015 §8): Kyverno (admission controller 1 replica + reports controller; version ghim ở
  `argocd/apps/components.json` của `svp-gitops`), một `ImageValidatingPolicy` `svp-images` cho Pod ở namespace `svp`, kiểm theo
  thứ tự: prefix GHCR của repo và có digest (không gọi mạng), chữ ký đúng identity, attestation `vuln` đúng identity, đủ hai nền
  tảng, không CRITICAL, không quá 72 giờ; khi bật `requireProvenance` (overlay `envs/<env>/svp-policy.yaml` của `svp-gitops`, bật ở
  stg và prd) thêm provenance đúng identity, đúng `builder.id`, repository, ref, và `verify-release.sh` đối chiếu commit của nó với
  chứng chỉ. Đường GitOps Enforce (`Deny`, webhook `Fail`: Kyverno chết hay Sigstore, GHCR không tới được thì pod `svp` mới bị từ
  chối); đường dev Audit. Namespace khác không qua webhook. Image bên thứ ba (operator, dữ liệu, observability, Argo CD, Kyverno)
  ghim digest, kiểm tĩnh trong CI bằng bước 4 của `deploy/ci/gitops-check.sh` (`make helm-check`, check của `svp-gitops`), chưa
  kiểm chữ ký nhà cung cấp.
- **Renovate** (ADR-0015 §10): App Mend cho repo này và `svp-gitops`, mở PR hằng tuần cho Go module, action (SHA), base image, công
  cụ của `Makefile` (repo này), chart upstream, image ghim trong `base/`, commit checker (`svp-gitops`, bỏ qua `envs/**`); chờ bản
  phát hành 3 ngày; repo này tự merge khi `ci-ok`, `images-ok` xanh chỉ `digest`, `pinDigest` của base image và image của chart
  (cùng tag, digest mới) và `patch`, `digest` của image compose; còn lại (mọi cập nhật Go module, patch tag của base image và image
  chạy trong cluster, và mọi PR của `svp-gitops`) duyệt tay ([ADR-0041](../adr/0041-github-hardening.md) (i), thay một phần
  [ADR-0035](../adr/0035-renovate-automerge.md)).
- **Chi phí:** repo public nên runner (cả arm64) và package GHCR public không tính tiền; ngân sách thời gian mỗi workflow dưới 10
  phút. Kyverno thêm 0,13–0,16 GiB RAM: cluster dev nghỉ 6,40 GiB, đỉnh 7,92 GiB khi media-worker scale lên (cách đo ADR-0014 §2).

## Hai repo: code và cấu hình triển khai

Vì sao: [ADR-0025](../adr/0025-gitops-config-repo.md), [ADR-0037](../adr/0037-mainpath-standard-tools.md) §6,
[ADR-0041](../adr/0041-github-hardening.md). Cài đặt và quy trình tay ở [`runbooks/svp-gitops-setup.md`](../runbooks/svp-gitops-setup.md).

```mermaid
flowchart LR
    subgraph code["repo svp-backend (code)"]
        src["code, test, Dockerfile,<br/>chart deploy/helm/*"]
        img["images.yml: build, quét,<br/>ký, provenance"]
        ver["verify.yml: kịch bản gitops<br/>(dựng stg ở commit đã kiểm)"]
        env["environment promote<br/>(khoá App, chỉ main)"]
        envprd["environment promote-prd<br/>(khoá App thứ hai, người duyệt, chỉ main)"]
    end
    subgraph cfg["repo svp-gitops (cấu hình)"]
        base["base/ values gốc"]
        stg["envs/stg/: overlay,<br/>charts.yaml, images/"]
        prd["envs/prd/: overlay,<br/>charts.yaml, images/"]
        argo["argocd/: AppProject,<br/>bootstrap, app-of-apps"]
    end
    cluster["cluster stg<br/>(Argo CD)"]
    img -->|"PR bot/promote-stg, auto-merge"| stg
    img -->|"dispatch promote_prd, stg_ref:<br/>PR bot/promote-prd, duyệt environment rồi Code Owner duyệt"| prd
    ver -.->|"đọc main"| cfg
    env -.-> img
    envprd -.-> img
    cluster -->|"root, values: refs/heads/main"| cfg
    cluster -->|"chart: SHA của charts.yaml"| src
```

- **Ranh giới:** repo code giữ code, test, Dockerfile, chart Helm và CI build, quét, ký; `svp-gitops` (public, không secret) giữ
  mọi thứ quyết định cái gì chạy ở một env: values gốc (`base/`), overlay, commit chart (`envs/<env>/charts.yaml`) và digest
  (`envs/<env>/images/`) của mỗi env, bản cài và manifest Argo CD. Push vào `main` repo code không đổi cluster nào.
- **Một bản phát hành = bảy digest + một commit chart**, đi qua stg rồi mới tới prd (như Freight của Kargo). `charts.yaml` mang
  `revision` (commit repo code) cùng hai giá trị dẫn xuất (`podSecurityVersion`, `collectorConfigSha256`); check của `svp-gitops`
  tính lại chúng; bước promote stg của repo code giữ guard tổ tiên ([ADR-0037](../adr/0037-mainpath-standard-tools.md) §6).
- **Argo CD multi-source:** root `svp-root` và nguồn `ref: values` đọc `svp-gitops` ở `refs/heads/main` (tên đầy đủ, không bao giờ
  tên ngắn: tên ngắn có thể phân giải sang tag cùng tên; ruleset `tags` cấm tạo tag), nguồn chart đọc repo code ở SHA 40 hex.
- **Quyền:** stg tự động (PR của bot chỉ đổi `envs/stg/`, không Code Owner, tự merge sau `gitops-ok`); prd chỉ qua PR do bot mở
  chép `envs/stg/` của một commit trên `main` của `svp-gitops` (`stg_ref`), sau khi người học duyệt environment `promote-prd` của
  repo code (job dừng chờ, admin không bypass) rồi Code Owner duyệt PR; file chung cần Code Owner, người học tự merge bằng bypass
  ruleset `owners` (có bản ghi). Khoá App chỉ ở hai environment của repo code, mỗi nơi một khoá riêng: `promote` (stg) và
  `promote-prd` (prd); hai job trên `main` (`promote`, `promote-prd`) dùng khoá của mình với token 1 giờ, chỉ `contents`,
  `pull_requests` write ([ADR-0041](../adr/0041-github-hardening.md) (d)).
- **Không có bản ghi stg** ([ADR-0037](../adr/0037-mainpath-standard-tools.md) §6): cổng prd là duyệt environment `promote-prd` rồi
  duyệt của Code Owner; `stg_ref` không bảo đảm stg đã chạy và smoke qua với đúng bộ đó. Bản ghi trạng thái triển khai được chọn
  là Argo CD Notifications ([ADR-0032](../adr/0032-argocd-deploy-status.md) A, B), dựng khi có EKS stg chạy suốt buổi.
- **Đường dev:** đọc working tree của bản clone `svp-gitops` cạnh repo (`../gitops`, hay `SVP_GITOPS_DIR`), không tự clone hay
  fetch; CI clone ẩn danh bằng `make gitops-clone`. Thay đổi cần cả code lẫn cấu hình thành hai PR theo thứ tự (cấu hình tương
  thích bản cũ trước).
- **Ngân sách RAM của cluster GitOps** trên runner và lượt kiểm của đường hai repo: [ADR-0021](../adr/0021-deferred-verification-stage6b.md),
  [ADR-0025](../adr/0025-gitops-config-repo.md).

## Ba repo và hợp đồng API

Vì sao: [ADR-0033](../adr/0033-svp-web-repo.md), [ADR-0036](../adr/0036-repo-rename.md),
[ADR-0037](../adr/0037-mainpath-standard-tools.md) §6. Cài đặt GitHub ở
[`runbooks/svp-frontend-setup.md`](../runbooks/svp-frontend-setup.md).

Web client nằm ở repo riêng để mô phỏng team FE và team BE riêng (hệ thống một người không cần tách; cái giá ở ADR-0033 mục 11).

```mermaid
flowchart LR
    subgraph be["repo svp-backend (backend)"]
        spec["services/gateway/openapi.yaml<br/>info.version semver"]
        beimg["images.yml: sáu image,<br/>job contract"]
        ci["deploy/ci/*.sh, Makefile,<br/>bảng nguồn sources.json"]
    end
    subgraph fe["repo svp-frontend (web)"]
        pin["api/contract.json,<br/>.backend-commit"]
        feimg["images.yml: image web"]
    end
    subgraph cfg["repo svp-gitops"]
        stg["envs/stg/images/"]
    end
    ghcr["GHCR"]
    spec -->|"oasdiff ở PR,<br/>ORAS + cosign trên main"| ghcr
    ghcr -->|"make generate: digest,<br/>chữ ký nguồn backend"| pin
    ci -.->|"checkout ở commit ghim"| feimg
    beimg -->|"PR bot/promote-stg<br/>(svp-gitops-promoter)"| stg
    feimg -->|"PR bot/promote-stg-web<br/>(svp-web-promoter)"| stg
```

- **Ranh giới:** backend giữ service Go, hợp đồng REST, stack compose, cluster k3d, chart và script CI; `svp-frontend` giữ mã web,
  test Vitest và e2e, `Dockerfile` ở gốc, CI và image web; `svp-gitops` giữ cái gì chạy ở mỗi env
  ([hai repo](#hai-repo-code-và-cấu-hình-triển-khai)). Workspace trên máy: `backend/`, `frontend/` (bản clone `svp-frontend`),
  `gitops/` cạnh nhau; script của backend đọc mã web qua `web_dir` (`SVP_WEB_DIR` hay `../frontend`), `svp-frontend` đọc harness
  của backend qua `SVP_BACKEND_DIR` (mặc định `../backend`).
- **Hợp đồng:** `services/gateway/openapi.yaml` là nguồn duy nhất ([REST ở gateway](../reference/contracts.md#rest-ở-gateway)),
  `info.version` theo semver; `make api-contract-check` (job `api-contract`, bắt buộc ở PR) dùng oasdiff đòi tăng đúng mức (breaking
  là major, có changelog là minor). Mỗi version phát hành một lần bằng job `contract` của `images.yml` trên `main`: OCI artifact
  `ghcr.io/anhnvcoder/svp-backend/api/gateway:<version>` đẩy bằng ORAS, ký keyless, không ghi đè. `svp-frontend` ghim `repository`,
  `version`, `digest` ở `api/contract.json`; `make generate` kiểm digest, version, chữ ký của nguồn `backend` rồi mới sinh
  `gen/api.d.ts`. Breaking đi ba bước: thêm cái mới (minor), chuyển web, bỏ cái cũ (major).
- **Nguồn phát hành:** mỗi repo phát hành image dưới prefix riêng, ký bằng workflow của chính nó
  (`deploy/helm/svp-policy/files/sources.json`: `backend` sáu service Go dưới `ghcr.io/anhnvcoder/svp-backend/`, `web` chỉ
  `ghcr.io/anhnvcoder/svp-frontend/web`); Kyverno chọn attestor theo prefix, check của `svp-gitops` giới hạn file mỗi bot được đổi
  (luật tác giả hẹp, đọc từ bảng nguồn). Identity ký và prefix image mang tên repo ([ADR-0036](../adr/0036-repo-rename.md)), nên
  image dưới tên repo cũ (`short-video-platform`, `svp-web`) bị policy từ chối. Danh sách build của backend (`built_services`, sáu)
  tách khỏi danh sách bảy bản triển khai (`svp_services`) mà promote prd, rescan đọc.
- **Script CI dùng chung:** `svp-frontend` checkout `deploy/ci/` của backend ở commit ghim `.backend-commit` (chỗ ghim duy nhất,
  Renovate nâng) và chạy với `SVP_CODE_ROOT` trỏ cây của nó; logic build, quét, ký, attest, rescan chỉ có một bản; promote là bước
  `yq` + `gh pr` trong `images.yml` của mỗi repo ([ADR-0037](../adr/0037-mainpath-standard-tools.md) §6).
- **Kiểm chéo:** job `stack` của `svp-frontend` dựng compose của backend ở commit stg chạy với sáu image stg theo digest
  (`make up IMAGES=stg WEB_FROM=clone`) và chạy e2e của PR; job `stack` của backend chạy web bản stg và e2e của `svp-frontend` ở
  commit đó. Cả hai chỉ báo; e2e không chặn một PR backend làm hỏng web mà oasdiff không thấy.
