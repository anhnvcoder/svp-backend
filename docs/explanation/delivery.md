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
  `deploy/k8s/lib.sh`; đổi đường build, quét, ký thì mọi service). Image `web` build, ký, promote ở CI của `svp-frontend` bằng cùng script
  ([ba repo](#ba-repo-và-hợp-đồng-api)); trivy quét cả gói npm của `node_modules` (ADR-0019 §1). Mỗi service build native trên
  runner amd64 và arm64, trivy quét tar cục bộ của từng kiến trúc: bí mật (mọi severity), lỗ hổng CRITICAL và HIGH có bản vá chặn
  **trước** push ([ADR-0070](../adr/0070-scan-gate-high-fixed.md)), HIGH chưa có bản vá chỉ báo (SARIF lên tab Security của `main`);
  ngoại lệ chỉ qua `.trivyignore.yaml` có lý do, tối đa 30 ngày. Push đúng image
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
  bao giờ ghi lùi) vào `envs/stg/images/<svc>.yaml` (tạo file khi service là
  [release mới](#release-mới-và-canary-grpc)) cùng commit chart vào `envs/stg/charts.yaml`, mở hay cập nhật một PR cuộn và bật
  auto-merge; PR tự merge khi `gitops-ok` xanh; Argo CD poll thấy commit, sync, gateway đi
  [canary](deployment.md#kubernetes-cục-bộ-k3d). Rollback stg là PR revert trong `svp-gitops`.
- **Admission** (ADR-0015 §8): Kyverno (admission controller + reports controller; version ghim ở `argocd/apps/components.json` của
  `svp-gitops`; admission controller một replica ở k3d, ba replica có PDB và trải zone trên EKS, `platforms/eks/kyverno.yaml`,
  [ADR-0056](../adr/0056-eks-platform-ha.md) §5), một `ImageValidatingPolicy` `svp-images` cho Pod ở namespace `svp`, kiểm theo
  thứ tự: prefix GHCR của repo và có digest (không gọi mạng), chữ ký đúng identity, attestation `vuln` đúng identity, đủ hai nền
  tảng, không CRITICAL, không quá 72 giờ; khi bật `requireProvenance` (overlay `envs/<env>/svp-policy.yaml` của `svp-gitops`, bật ở
  stg và prd) thêm provenance đúng identity, đúng `builder.id`, repository, ref, và `verify-release.sh` đối chiếu commit của nó với
  chứng chỉ. Đường GitOps Enforce (`Deny`, webhook `Fail`: Kyverno chết hay Sigstore, GHCR không tới được thì pod `svp` mới bị từ
  chối); đường dev Audit. Namespace khác không qua webhook. Image bên thứ ba (operator, dữ liệu, observability, Argo CD, Kyverno)
  ghim digest, kiểm tĩnh trong CI bằng bước 4 của `deploy/ci/gitops-check.sh` (`make helm-check`, check của `svp-gitops`), chưa
  kiểm chữ ký nhà cung cấp.
- **Thứ tự các phép của policy:** các phép chạy theo thứ tự và dừng ở phép đầu tiên sai, mỗi phép một message nêu image bị từ chối và,
  từ phép 2, nguồn của image. Phép 1 chỉ đọc pod nên từ chối image của registry cục bộ, của Docker Hub hay tên lạ dưới một prefix mà
  không hỏi registry nào; Kyverno chỉ xác minh image mà `matchImageReferences` chọn và cho mọi image khác đi qua. Điều đó chỉ đúng với
  image không glob nào khớp: Kyverno lấy mọi image được chọn từ registry của nó trước mọi phép, và registry từ chối (repository không
  tồn tại thì GHCR trả `DENIED`) làm đánh giá lỗi thay vì ra message của phép 1. Vì vậy `matchImageReferences` có hai glob mỗi tên được
  phát hành (`<imagePrefix><tên>@*`, `<imagePrefix><tên>:*`; glob kiểu gobwas không có dấu phân tách, `*` khớp cả `/`, `:`, `@`),
  không một glob mỗi prefix: `<imagePrefix>*` để pod có tên lạ dưới prefix tới GHCR trước
  ([lý do](../reference/k8s.md#kyverno-và-nguồn-phát-hành)). Image của một tên
  được phát hành mà không có digest khớp glob `:*` và bị `verifyDigest` từ chối sớm hơn ("does not have a digest"), trước khi Kyverno tra
  tag. Với `requireProvenance`, bốn phép thêm đứng sau sáu phép đầu cho mọi nguồn như nhau: image thiếu provenance chỉ bị từ chối khi đã
  qua mọi phép khác, nên message thiếu provenance không che lỗi nào khác. Nguồn của một image được chọn trong CEL theo prefix nó bắt đầu
  bằng: các prefix đã được kiểm không lồng nhau nên nhiều nhất một nguồn khớp, và mỗi phép xác minh chỉ gọi attestor của nguồn đó (`&&` và
  `?:` không tính vế bị bỏ qua). Payload của một attestation là cả statement in-toto nên đường dẫn bắt đầu ở `.predicate`;
  `extractPayload` chỉ đọc sau khi `verifyAttestationSignatures` đã xác minh nó trong cùng lần đánh giá (phép 3 đứng trước cho `vuln`,
  phép 7 cho provenance). Mỗi image vì vậy tốn một lần xác minh thứ ba khi Kyverno chưa có trong cache. Hai định dạng chữ ký được
  Kyverno tự phân biệt theo từng image nên policy không nêu tên chúng; image có một bundle thì chỉ đọc qua bundle, nên một bản phát
  hành không bao giờ trộn hai định dạng, và trong bundle mọi attestation của identity cũng tính là chữ ký cho phép 2. Định dạng cũ còn
  được nhận chừng nào một bản phát hành trong `envs/stg/images/` hay `envs/prd/images/` của `svp-gitops` còn mang nó (rollback cũng có
  thể tới một bản như vậy); hết bản thì các comment nhắc nó bỏ đi, và rollback về một bản như vậy cần quyết định khác.
- **Timeout của policy:** `webhookConfiguration.timeoutSeconds` là 30 giây, mức tối đa API server cho (mặc định của Kyverno là 10). Một
  lần xác minh chưa có cache tới TUF của Sigstore và GHCR; Rekor không được gọi vì policy không đặt `ctlog`, nên Kyverno v1.19.1 kiểm
  bằng chứng transparency log nhúng trong Sigstore bundle ngoại tuyến. Một chữ ký mất 6–8 giây trên cluster của lab (định dạng cũ); với
  image dạng bundle Kyverno lấy mọi bundle của digest cho mỗi lần xác minh, và CLI không cache mất 36–46 giây so với 14–16 giây của định
  dạng cũ. Tuổi tối đa của attestation (`maxAttestationAge`, một CEL duration) là 72 giờ: rescan hằng ngày làm mới nó, nên 72 giờ chịu
  được hai lượt chạy lỡ.
- **Policy sẵn sàng:** script coi policy `svp-images` (hay policy tạm của diễn tập) sẵn sàng khi Kyverno đã biên dịch nó
  (`status.conditionStatus.ready`) và `kyverno-resource-validating-webhook-cfg` có một webhook cho nó: webhook có `failurePolicy` của
  policy (hay giá trị gọi hàm nêu, `Fail` hoặc `Ignore`), `objectSelector` của policy, và rule mà `namespaceSelector` mang phép khớp
  namespace `svp` của policy (Kyverno AND nó với selector của ConfigMap của chính nó). Policy có `webhookConfiguration.timeoutSeconds`
  riêng (`svp-images` và mọi policy tạm của diễn tập) có webhook riêng, `ivpol.validate.kyverno.svc-fail-finegrained-<policy>`
  (`-ignore-` khi Audit); script vẫn tìm webhook theo cái nó chọn chứ không theo tên đó, vì tên thuộc quyền Kyverno đổi
  (`image_policy_ready` của `deploy/k8s/lib.sh`).
- **Bảng nguồn phát hành:** `files/sources.json` của chart `svp-policy` là chỗ duy nhất khai mọi nguồn (trường và nguồn hiện có ở
  [`reference/k8s.md`](../reference/k8s.md#kyverno-và-nguồn-phát-hành)). Nó nằm trong chart chứ không ở overlay nên một nguồn thêm hay
  bỏ tới stg trước prd cùng `revision` của chart, và không môi trường nào đổi được. Identity keyless khai trong đó là của `images.yml`
  trên `main` của repo nguồn: SAN của chứng chỉ Fulcio là `server_url` cộng `job_workflow_ref`, nên lượt chạy ở nhánh khác hay của
  workflow khác bị từ chối. Policy nhận đúng các image này với đúng các identity này, và script đọc cùng file, nên cái script kiểm
  chính là cái admission kiểm. Luật của bảng viết một lần trong template (`deploy/ci/sources-test.sh`); script không kiểm lại chúng
  và chỉ giữ hai luật về prefix (`release_sources`, hai hàm chọn nguồn), vì bảng có thể chưa qua render nào: lý do ở
  [`reference/k8s.md`](../reference/k8s.md#kyverno-và-nguồn-phát-hành). `release_sources` còn fail khi REV không phải commit của clone này
  hay là commit từ trước khi có bảng: không môi trường nào ghim commit như vậy nữa nên nguồn duy nhất của nó không được dựng lại từ
  values của thời đó; ghim commit mới hơn. Bảng của commit cũ có thể còn nguồn nghỉ hưu, không có `promoter` (repo đã đổi tên, nguồn kế
  thừa là nguồn khác): các bản phát hành ký dưới tên cũ vẫn được nhận chừng nào một môi trường còn chạy chúng, nhưng không gì build,
  promote hay rescan cho nguồn đó. Mọi nguồn của bảng working tree đều có `promoter` (`deploy/ci/sources-test.sh`).
- **Đọc file image của service:** `values_field FIELD` (`deploy/k8s/lib.sh`) đọc `image.FIELD` (`repository`, `tag`, `digest`) từ file
  values của một service và in không nháy, `""` khi rỗng. Nó chỉ đọc đúng dạng các file này có: một dòng `FIELD: <giá trị>` (thụt hai dấu cách) trong khối
  `image:` cấp cao nhất, giá trị trần hay trong nháy kép, không comment sau nó, đúng dạng của FIELD (`repository` `[0-9a-z.:/_-]*`, `tag`
  rỗng hay 12 hex thường là một commit, `digest` rỗng hay `sha256:<64 hex>`). Dạng khác thì fail và nêu vấn đề trên stderr thay vì đoán,
  vì kết quả đi tới registry, cosign và git; mã thoát 3 là không có dòng đó, 4 là dòng đó hai lần, 5 là giá trị sai dạng.
  `release_image SERVICE WHERE` đọc file image của SERVICE từ stdin (WHERE nêu nó trong message, như `envs/stg/images/gateway.yaml at
  1a2b3c4d5e6f`) và in `REPOSITORY@DIGEST` của bản phát hành mà file nêu, khi cluster GitOps kéo được nó: `image.digest` đã đặt (PR
  promote ghi), `image.repository` là image của SERVICE ở một nguồn phát hành có xuất bản SERVICE (`release_source_of`, bảng của working
  tree), và GHCR phục vụ manifest đó cho một lần kéo ẩn danh. Không thì fail và nêu nguyên nhân; không tạo gì. Bản phát hành có chữ ký và
  attestation `vuln` còn mới không là việc kiểm của `deploy/ci/verify-release.sh`.
- **Diễn tập admission controller chết:** ca (g) của `make drill-k8s-supplychain` làm Deployment của Kyverno giữ replica nhưng pod bị
  dừng và pod thay thế không lịch được (strategy `Recreate` và `nodeSelector` mà không node nào có), như khi nó crash hay node mất. Không
  scale về 0, vì Kyverno v1.19.1 xoá mọi cấu hình webhook của nó khi dừng mà Deployment đòi 0 replica (`IsGoingDown`,
  `pkg/utils/runtime/utils.go`), và khi đó mọi pod đi qua. Pod của `svp` bị từ chối (webhook fail closed), pod ở namespace `svp-probe`
  (tạo cho ca bằng template dùng chung, Pod Security `restricted`, ngoài phạm vi webhook) được nhận; giữa các lần thử Deployment vẫn muốn
  replica của nó mà không có pod Ready. Cuối ca, kể cả khi một bước lỗi, Deployment được đặt lại và Ready; trên cluster GitOps sync tự động
  của Argo CD tắt trước (Application gốc `svp-root`, rồi Application `kyverno`) để Argo CD không hoàn tác thay đổi giữa ca, và bật lại
  `kyverno` trước. Webhook của policy (selector, `failurePolicy`, rule) sau khi Kyverno trở lại giống như trước. Image gửi là bản phát
  hành đã ký mà một pod `svp` chạy, không thì image của registry cục bộ (đường dev). Hàm, đầu vào và dòng kết luận ở `deploy/k8s/drills/supplychain/lib.sh`.
- **Image chưa ký của diễn tập:** `unsigned_image` dùng giá trị `unsigned` khi được cho, không thì `drill-unsigned` mới nhất dưới
  prefix của nguồn `backend` trên GHCR (`deploy/ci/ghcr-digest.sh newest`, ẩn danh; dòng lỗi cuối ở `$work/unsigned.err`), rỗng khi
  không có. CI đẩy nó không chữ ký và không attestation nên không gì trên GHCR trỏ tới nó. Không dùng manifest nền tảng của index một bản
  phát hành đã ký: trong Sigstore bundle, attestation của bản đó trỏ cả tới từng manifest nền tảng và Kyverno tính chúng là chữ ký, nên nó
  qua phép chữ ký rồi bị từ chối muộn hơn, ở attestation `vuln`; các ca b, h và i khi đó phụ thuộc định dạng.
- **Renovate** (ADR-0015 §10): App Mend cho repo này và `svp-gitops`, mở PR hằng tuần cho Go module, action (SHA), base image, công
  cụ của `Makefile` (repo này), chart upstream, image ghim trong `base/`, bản checker (`svp-gitops`, bỏ qua `envs/**`); chờ bản
  phát hành 3 ngày; repo này tự merge khi `ci-ok`, `images-ok` xanh chỉ `digest`, `pinDigest` của base image và image của chart
  (cùng tag, digest mới) và `patch`, `digest` của image compose; còn lại (mọi cập nhật Go module, patch tag của base image và image
  chạy trong cluster, và mọi PR của `svp-gitops`) duyệt tay ([ADR-0041](../adr/0041-github-hardening.md) (i), thay một phần
  [ADR-0035](../adr/0035-renovate-automerge.md)). Nhóm `postgres` gom image Postgres của compose, job test của CI và CloudNativePG vào một PR
  cho minor, patch, digest, không tự merge, để mọi nơi giữ cùng `x.y` ([ADR-0057](../adr/0057-postgres17-verify-full.md) §1). Add-on EKS và AMI
  không đi qua Renovate (datasource cần credential AWS): nâng tay theo runbook nâng minor của `svp-infra`
  ([ADR-0056](../adr/0056-eks-platform-ha.md) §8); chart và image Karpenter qua Renovate của `svp-gitops` như component khác.
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
- **Một bản phát hành = một digest mỗi service + một commit chart**, đi qua stg rồi mới tới prd (như Freight của Kargo). `charts.yaml` mang
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

## Phát hành checker

Vì sao: [ADR-0077](../adr/0077-versioned-gitops-checker.md). Quy trình tay ở
[`runbooks/gitops-checker-release.md`](../runbooks/gitops-checker-release.md); workflow ở [`reference/ci.md`](../reference/ci.md).

Check bắt buộc `gitops-ok` của `svp-gitops` chạy **checker** của repo code: `deploy/ci/gitops-check.sh` và các file nó đọc trong `deploy/ci/`
(policy Rego, policy Kyverno CLI, `values-check.sh`, `verify-release.sh`, `common.sh`, `cluster-values.example.yaml`). Checker là thứ duy nhất
của repo code có semver: mỗi bản là một tag `gitops-check-v<semver>` bất biến, `svp-gitops` ghim version cùng commit của tag, và đổi bản
đi bằng PR như mọi dependency.

```mermaid
sequenceDiagram
    actor Learner as người học
    participant Main as main của svp-backend
    participant Release as release.yml (release-please)
    participant RelPR as PR phát hành
    participant Renovate as Renovate (Mend)
    participant BumpPR as PR nâng ghim ở svp-gitops
    participant Check as check.yml của svp-gitops
    Learner->>Main: squash merge PR feat(ci) đổi deploy/ci
    Main->>Release: push main
    Release->>RelPR: mở hay cập nhật bằng token App: CHANGELOG, manifest
    RelPR->>RelPR: ci-ok, images-ok (không build image)
    Learner->>RelPR: Code Owner duyệt, merge
    RelPR->>Release: push main
    Release->>Main: tag gitops-check-v semver, GitHub Release
    Note over Main: ruleset gitops-check-tags: tag không sửa, không xoá
    Renovate->>Main: đọc tag mới và commit của nó (github-tags)
    Renovate->>BumpPR: CHECKER_VERSION và CHECKER_COMMIT trong một PR
    BumpPR->>Check: pull_request
    Check->>Check: tag trỏ đúng CHECKER_COMMIT, rồi checker bản mới trên cây
    Learner->>BumpPR: đọc changelog, Code Owner duyệt, merge
```

- **Bản và mức tương thích.** release-please đọc tiêu đề commit (Conventional Commits, tiêu đề PR thành commit squash): `feat` ra minor,
  `fix`, `perf` ra patch, `!` hay `BREAKING CHANGE` ra major; chỉ commit đổi file dưới `deploy/ci` được đếm. Mỗi bản là một PR phát hành qua cổng
  như mọi PR, nên tag chỉ trỏ commit đã qua `ci-ok`, `images-ok` và duyệt của Code Owner.
- **Token App, không `GITHUB_TOKEN`.** PR do `GITHUB_TOKEN` mở không chạy CI, nên PR phát hành dùng token 1 giờ của App `svp-release-please`
  (chỉ repo này, `contents`, `pull_requests` write); khoá App ở environment `release`, chỉ `main` dùng được.
- **Ghim cả version lẫn commit.** Version nói mức tương thích cho người duyệt và cho Renovate (major ở PR riêng); commit là thứ check thật sự
  checkout. Bước khớp tag đỏ khi hai thứ lệch nhau; tag bất biến nên commit đã ghim không dời.
- **Expand–contract.** Đổi hợp đồng giữa checker và cây `svp-gitops` đi bằng ba PR, mỗi PR qua cổng có sẵn: repo code nhận cả dạng cũ lẫn mới
  (bản minor; CI repo code chạy checker `--worktree` với `main` của `svp-gitops`, nên dạng cũ còn được kiểm), `svp-gitops` nâng ghim rồi đổi cây,
  repo code bỏ dạng cũ (bản major) và `svp-gitops` nâng. Thứ tự sai thì một trong hai cổng đỏ, không cần ghim tạm hay nâng tay.
- **Phạm vi phiên bản.** Image service giữ tag theo commit và digest: build một lần, promote cùng digest, mỗi commit `main` là một bản ứng viên,
  người tiêu thụ là GitOps của chính hệ thống. Chart giữ ghim commit trong `envs/<env>/charts.yaml`, đi cùng image. Package release-please là cả
  `deploy/ci`, nên script không thuộc checker cũng ra bản (thêm một PR Renovate vô hại); file check đọc ở commit ghim mà nằm ngoài `deploy/ci`
  (`Makefile`; `deploy/k8s/lib.sh`) chỉ tới `svp-gitops` ở bản phát hành kế tiếp. Danh sách service không nằm trong số đó: check lấy nó từ bảng nguồn
  ở commit mà `envs/<env>/charts.yaml` ghim.
- **Cái giá.** Thêm một App (khoá xoay tay), một environment, một workflow, một ruleset; mỗi bản thêm một PR phát hành ở repo code và một PR
  Renovate ở `svp-gitops`, tới trong vài giờ sau tag (Mend chạy 4 giờ một lượt).

## Release mới và canary gRPC

Vì sao: [ADR-0072](../adr/0072-pod-operations.md), [ADR-0025](../adr/0025-gitops-config-repo.md),
[ADR-0037](../adr/0037-mainpath-standard-tools.md) §6. Luật và lệnh ở [`reference/ci.md`](../reference/ci.md#gitops-checksh-values-checksh-và-policy-kyverno);
đọc một lượt chạy ở [`ci-cd.md`](../ci-cd.md#12-push-hay-merge-vào-main).

Một **release mới** là service của **tập build** (group `default` của `deploy/docker-bake.json`) mà revision stg hoặc prd đang ghim
(`envs/<env>/charts.yaml`) chưa build. Cluster chưa chạy nó, nên `envs/<env>/images/<svc>.yaml` chưa thể có: digest của nó chỉ có sau
khi `images.yml` build và ký. Cơ chế không cho service dựng và ghim digest bằng tay, và cũng không bỏ luật "mỗi service một file image":
chỉ đúng chỗ thiếu file của service mà revision đã ghim không build thì được phép, và chỉ đến khi promote tạo file.

```mermaid
sequenceDiagram
    participant PR as backend PR
    participant Images as images.yml
    participant Ghcr as package GHCR
    participant Check as gitops-check.sh --worktree
    participant Promote as job promote
    participant Gitops as svp-gitops
    actor Learner as người học
    participant PromotePrd as job promote-prd
    participant Argo as Argo CD
    participant Rollout as Argo Rollouts
    PR->>Check: chart, bake, sources.json, svp-gitops main
    Check-->>PR: note envs/stg, envs/prd chưa có file image của service mới
    PR->>Images: merge vào main, thêm service đổi bảng image nên build mọi service
    Images->>Images: build, quét, ký mọi image của tập build
    Images->>Ghcr: đẩy image: package của service mới private
    Learner->>Ghcr: bật public ngay sau lượt đầu
    Images->>Promote: digest của từng service đã ký
    Promote->>Gitops: PR bot/promote-stg: tạo envs/stg/images/svc.yaml, charts.yaml
    Note over Gitops,Ghcr: check kéo ẩn danh nên cần package public
    Gitops-->>Promote: gitops-ok xanh: danh sách service từ bảng ở revision mới, tự merge
    Learner->>PromotePrd: dispatch promote_prd với stg_ref, duyệt environment promote-prd
    PromotePrd->>Gitops: PR bot/promote-prd tạo envs/prd/images/svc.yaml
    Learner->>Gitops: Code Owner duyệt, merge PR prd
    Note over Gitops: component của service chỉ vào argocd/apps/components.json<br/>khi mọi env của nền tảng đã có file image
    Gitops->>Argo: root, values: envs/env/images và base
    Argo->>Rollout: Rollout của release có canary (gRPC: chia theo số pod)
    Rollout->>Rollout: 25%, chờ, 50%, chờ, gate, AnalysisRun đọc Prometheus
```

- **Cổng trong PR của backend.** `gitops-check.sh --worktree` chạy ở CI backend với `main` của `svp-gitops` và chart của working tree
  thay `revision`. Luật "mỗi service một file image" nằm ở policy Rego (`envs.rego`): file thiếu của service mà revision env ghim
  không build là cảnh báo, in thành dòng `note`; mọi thiếu khác vẫn đỏ.
- **Cổng trong PR của `svp-gitops`.** Check theo revision vẫn đòi đủ một file mỗi service mà revision của env build. PR promote
  của stg nâng `revision` lên commit build service mới và tạo file trong cùng PR. Checker ở bản đang ghim lấy danh sách service mà
  file image của env được có từ bảng nguồn ở revision đó (`values-check.sh`, nhánh promote prd của `author.rego`), không từ bản checker,
  nên check xanh mà không cần phát hành checker mới ([phát hành checker](#phát-hành-checker)). File bị xoá của service mà revision
  env ghim không build, `values-check.sh` ghi thành dòng `note` (rollback, service nghỉ hưu); thêm hay sửa file đó thì đỏ.
- **Package GHCR public.** Lượt `images.yml` đầu tạo package của service mới ở trạng thái private, mà check của `svp-gitops` kéo ẩn
  danh. Người học bật public cho package ngay sau lượt đó, không đợi buổi stg ([`svp-gitops-setup.md`](../runbooks/svp-gitops-setup.md), C1);
  chưa bật thì PR promote đỏ, và mọi bump stg dồn trong PR đó.
- **prd do người học kéo.** Job `promote` chỉ ghi stg. Người học dispatch `images.yml` với `promote_prd` và `stg_ref`, duyệt
  environment `promote-prd`; job `promote-prd` mở PR `bot/promote-prd` không auto-merge, Code Owner duyệt rồi merge.
- **Promote tạo file.** `promote` ghi file image của mỗi service vừa ký; file chưa có thì `promote_image_file` (`deploy/ci/common.sh`)
  viết khối comment đầu file như các file khác rồi khối `image`. `promote-prd` chép file của stg ở `stg_ref`, bỏ qua service mà stg
  ở commit đó chưa có file, và tạo file prd của service đã có. Lượt không build service mới thì không tạo file.
- **Rollback prd.** `promote-prd` không xoá file, luật tác giả cấm bot xoá. Lùi về `stg_ref` trước lúc service mới có file prd thì file đó
  còn lại và check đỏ; người học mở PR của mình xoá `envs/prd/images/<svc>.yaml`, check ghi dòng `note` cho file đó
  ([`svp-gitops-setup.md`](../runbooks/svp-gitops-setup.md), C4).
- **Component.** Chart `svp-policy` liệt kê nguồn phát hành của service ngay từ PR backend (`files/sources.json`), để Kyverno nhận
  chữ ký. Component của release vào `argocd/apps/components.json` chỉ khi mọi env của nền tảng có file image, ở PR `svp-gitops` sau.

Canary của release gRPC đi theo cùng đường phát hành, không có Envoy phía trước để chia request. Chart `svp-service` bật Rollout cho
release `protocol: grpc` có `canary: true` và không `httpRoute.host`; Rollout không có `trafficRouting`, nên Argo Rollouts đặt trọng số
bằng số pod: ReplicaSet canary chiếm phần trọng số của replica (làm tròn lên, ít nhất một pod), ReplicaSet stable giữ phần còn lại,
Service `<release>` chọn pod của cả hai. Các bước như HTTP: 25 %, chờ, 50 %, chờ, bước phân tích chặn rồi 100 %.

- **Đo ở pod canary.** AnalysisTemplate lấy hash của ReplicaSet canary (`podTemplateHashValue: Latest`) và hỏi Prometheus về
  `rpc_server_call_duration_seconds` của đúng pod đó (`k8s_pod_name=~"<release>-<hash>-.*"`, thuộc tính pod do chart đặt qua downward
  API): tỉ lệ lời gọi lỗi phía server (mã `UNKNOWN`, `INTERNAL`, `UNAVAILABLE`, `DATA_LOSS`, `DEADLINE_EXCEEDED`) và p99. Dưới 30 lời gọi
  trong phút gần nhất thì kết quả là Inconclusive: canary dừng chờ người, không được thăng cấp. Ngưỡng là `canaryLimits` của release.
- **Cái giá của chia theo pod.** Client gRPC giữ kết nối, nên tải tới canary theo kết nối chứ không theo request: phần tải gần đúng
  trọng số nhờ server đóng kết nối định kỳ (`MaxConnectionAge`), client nối lại và rải lên pod mới. Một service ít được gọi sẽ ít lời
  gọi hơn ngưỡng và dừng ở Inconclusive. Service mesh (chưa dựng; lựa chọn ở [ADR-0042](../adr/0042-caller-identity-grpc.md)) chia
  theo request và thay cơ chế này.
- **Chuyển sang Rollout.** `canary: true` đổi `kind` của workload cùng tên từ Deployment sang Rollout. Mọi Application của chart
  `svp-service` trong `svp-gitops` đặt `PruneLast=true`: Argo CD xoá Deployment cũ sau cùng, khi Rollout mới đã Healthy, nên release
  luôn có pod sẵn sàng trong lúc chuyển. Đường dev (`make k8s-up`) dựng cụm từ đầu và không cần cơ chế này.

## Ba repo và hợp đồng API

Vì sao: [ADR-0033](../adr/0033-svp-web-repo.md), [ADR-0036](../adr/0036-repo-rename.md),
[ADR-0037](../adr/0037-mainpath-standard-tools.md) §6. Cài đặt GitHub ở
[`runbooks/svp-frontend-setup.md`](../runbooks/svp-frontend-setup.md).

Web client nằm ở repo riêng để mô phỏng team FE và team BE riêng (hệ thống một người không cần tách; cái giá ở ADR-0033 mục 11).

```mermaid
flowchart LR
    subgraph be["repo svp-backend (backend)"]
        spec["services/gateway/openapi.yaml<br/>info.version semver"]
        beimg["images.yml: image Go,<br/>job contract"]
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
  (`deploy/helm/svp-policy/files/sources.json`: `backend` các service Go dưới `ghcr.io/anhnvcoder/svp-backend/`, `web` chỉ
  `ghcr.io/anhnvcoder/svp-frontend/web`); Kyverno chọn attestor theo prefix, check của `svp-gitops` giới hạn file mỗi bot được đổi
  (luật tác giả hẹp, đọc từ bảng nguồn). Identity ký và prefix image mang tên repo ([ADR-0036](../adr/0036-repo-rename.md)), nên
  image dưới tên repo cũ (`short-video-platform`, `svp-web`) bị policy từ chối. Danh sách build của backend (`built_services`)
  tách khỏi danh sách bản triển khai (`svp_services`, thêm web) mà promote prd, rescan đọc.
- **Script CI dùng chung:** `svp-frontend` checkout `deploy/ci/` của backend ở commit ghim `.backend-commit` (chỗ ghim duy nhất,
  Renovate nâng) và chạy với `SVP_CODE_ROOT` trỏ cây của nó; logic build, quét, ký, attest, rescan chỉ có một bản; promote là bước
  `yq` + `gh pr` trong `images.yml` của mỗi repo ([ADR-0037](../adr/0037-mainpath-standard-tools.md) §6).
- **Kiểm chéo:** job `stack` của `svp-frontend` dựng compose của backend ở commit stg chạy với image stg theo digest
  (`make up IMAGES=stg WEB_FROM=clone`) và chạy e2e của PR; job `stack` của backend chạy web bản stg và e2e của `svp-frontend` ở
  commit đó. Cả hai chỉ báo; e2e không chặn một PR backend làm hỏng web mà oasdiff không thấy.
