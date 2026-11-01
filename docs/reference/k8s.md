# Cluster k3d, đường GitOps, diễn tập trên cluster

Loại tài liệu (Diátaxis): **reference**, tra cứu khi cần một lệnh hay một quy tắc cụ thể; luật làm việc ở [`AGENTS.md`](../../AGENTS.md).

## Cluster k3d

- Cluster k3d `svp` ([ADR-0014](../adr/0014-kubernetes-local-stage4.md)), target ở `deploy/k8s/k8s.mk`.
  Ràng buộc chung: chỉ chạy qua Makefile (`docker`/`k3d` với `env -u DOCKER_DEFAULT_PLATFORM`, `kubectl`/`helm` luôn
  `--context k3d-svp`, cache Helm ở `.k8s/helm`); `k3d` ghim cài bằng `make tools`. **Không chạy cùng compose:**
  `make k8s-up`, `k8s-gitops-up` từ chối khi stack compose `svp` đang chạy; `make up` từ chối khi node của
  cluster hay registry `k3d-svp-registry` đang chạy. Cổng chỉ trên `127.0.0.1`: API 6550, HTTPS của Envoy 8443
  (`api.svp.localhost`, `s3.svp.localhost` với chứng chỉ wildcard; web ở `svp.localhost`, listener `https-apex` với chứng
  chỉ riêng; đều phân giải về loopback), registry 5111. Postgres (CloudNativePG; backup cơ sở và WAL lưu
  liên tục qua plugin Barman Cloud, component `plugin-barman-cloud` ở `cnpg-system`, vào bucket `pg-backups` của object store
  trong cluster bằng user riêng `svp-pg-backup`, [ADR-0020](../adr/0020-reliability-stage6.md) §5), Valkey,
  Redpanda (SASL + ACL), object store (RustFS, StatefulSet `s3`, `s3.svp-data:9000`, Job `s3-init`) nằm trong cluster: target của cluster k3d không đụng Postgres/Redis native. File sinh ra nằm ở
  `.k8s/` (gitignore). Biến chỉ đặt ở cluster: service có Kafka đăng nhập SASL SCRAM bằng `KAFKA_SASL_USERNAME`,
  `KAFKA_SASL_PASSWORD` (đặt cả hai hay không biến nào; compose không đặt, broker không xác thực); gateway tin một hop
  `X-Forwarded-For` từ dải pod của Envoy qua `TRUSTED_PROXY_HOPS=1`, `TRUSTED_PROXY_CIDRS=10.42.0.0/16` (compose: không
  đặt, 0 hop; giá trị không hợp lệ thì gateway không khởi động); gateway `TRUST_TRACE_CONTEXT=true` (nhận
  `traceparent`/`tracestate` của request đến; `false` hay rỗng là mặc định, giá trị khác thì không khởi động) vì Envoy bỏ
  `traceparent`, `tracestate`, `baggage`, `sentry-trace` của client trên mọi route và chỉ Envoy, web vào được gateway
  (WEB-24). Web ([ADR-0019](../adr/0019-web-k3d-supply-chain-observability.md)):
  `GATEWAY_URL=http://gateway:8080`,
  `REDIS_URL=redis://valkey.svp-data:6379/9`, `APP_ORIGIN=https://svp.localhost:8443`, `MEDIA_ORIGIN`, `UPLOAD_ORIGIN`
  `https://s3.svp.localhost:8443` (object store chỉ nhận CORS từ `https://svp.localhost:8443`, theo bucket như compose), `SENTRY_ENVIRONMENT=k3d`,
  `SENTRY_DSN` từ Secret `svp/sentry`, `NEXT_SERVER_ACTIONS_ENCRYPTION_KEY` từ Secret `svp/web-env`; `SVP_BUILD_ID` là build arg
  chép thành `ENV` của image (12 hex của commit ở CI, `dev-` + hash nội dung context ở đường dev, rỗng ở compose), dùng làm
  `deploymentId`, `release` của GlitchTip và `service.version`. API server có PSA `restricted` mặc định cho mọi namespace
  trừ `kube-system` (`deploy/k8s/pod-security-admission.yaml`, mount từ đường của repo lúc tạo cluster, đọc lại mỗi lần
  node server khởi động): sửa `k3d.yaml` hay dời repo phải `make k8s-down && make k8s-up`, sửa file đó có hiệu lực ở lần
  khởi động sau; `make k8s-up` từ chối cluster tạo khi chưa có cấu hình này, hay khi nguồn mount không còn là file, khác
  file của repo hiện tại, hay version lệch `podSecurityVersion`. Probe của chart `svp-service` (ADR-0020 §10, cùng cho mọi
  release): liveness `timeoutSeconds: 5` (chu kỳ 10 s, 3 lần), readiness 2 (chu kỳ 5 s), startup của service gRPC 2 (chu kỳ
  2 s × 30 lần); media-worker không có probe.

## Kyverno và nguồn phát hành

- Kyverno ([ADR-0015](../adr/0015-cicd-devsecops-stage5.md) §8), cùng `ImageValidatingPolicy` `svp-images` (chart
  `deploy/helm/svp-policy`) trên hai đường, chỉ namespace `svp`: `make k8s-up` cài **Audit** (`failurePolicy: Ignore`,
  image `dev-*` chưa ký của registry k3d vẫn chạy, vi phạm ghi vào PolicyReport), `make k8s-gitops-up` **Enforce**
  (`Deny` + `Fail`: chỉ nhận image của một **nguồn phát hành** theo digest, ký keyless bởi `images.yml@refs/heads/main` của repo
  nguồn đó, có attestation `vuln` đủ hai nền tảng, không CRITICAL, không quá 72 giờ; Kyverno chết thì pod `svp` mới bị từ chối,
  namespace khác không qua webhook). **Nguồn phát hành** ([ADR-0033](../adr/0033-svp-web-repo.md) §2) khai một chỗ ở
  `deploy/helm/svp-policy/files/sources.json` (không ở `values.yaml`, không overlay nào đổi được; đi stg trước prd theo `revision` của
  chart): mỗi nguồn `name`, `repository`, `imagePrefix` (kết thúc `/`), `services`, `drillImages`, `issuer`, `subject`,
  `provenanceRef`, `promoter` (tuỳ chọn). Hiện hai nguồn: `backend` (repo này `anhnvcoder/svp-backend`, prefix
  `ghcr.io/anhnvcoder/svp-backend/`, sáu service Go, ba image diễn tập `drill-vulnerable`, `drill-unsigned`, `drill-no-provenance`, App
  `svp-gitops-promoter`) và `web` (`anhnvcoder/svp-frontend`, prefix `ghcr.io/anhnvcoder/svp-frontend/`, chỉ `web`, App `svp-web-promoter`);
  mọi nguồn của bảng working tree có `promoter` (`deploy/ci/sources-test.sh`). Hai **nguồn nghỉ hưu** của lượt đổi tên repo
  ([ADR-0036](../adr/0036-repo-rename.md) §3; `oldbackend` dưới tên `short-video-platform`, `oldweb` dưới tên `svp-web`, không `promoter`)
  đã gỡ khỏi bảng ngày 2026-11-01 (§4 bước 8), khi mọi file `envs/*/images/` của `svp-gitops` đã dưới hai prefix mới: bản trước đổi tên
  bị phép 1 từ chối (prefix không thuộc nguồn nào), không bot nào tiếp quản file của nguồn nghỉ hưu nữa. `promoter` vẫn tuỳ chọn ở hai nơi
  viết luật (template, `_release_sources_jq` của `lib.sh`) vì script đọc bảng ở `revision` mà env ghim (`envs/prd/charts.yaml` còn ở
  commit merge của PR đổi tên, bảng bốn nguồn); bỏ khi không env nào, không commit `envs/stg/` nào mà promote prd còn chép, trỏ commit có
  nguồn không `promoter`. `promoter` không trùng giữa các nguồn có nó. Repo này chỉ build, ký, promote sáu image của nó
  (`built_services` của `deploy/k8s/lib.sh`); `svp_services` vẫn là bảy bản triển khai (gồm `web`), mà rescan, promote prd,
  check `svp-gitops`, `k8s/gitops.sh` đọc. Stg chạy web của repo `svp-frontend` từ 2026-10-30, prd từ 2026-10-31 (PR #22, #29 của `svp-gitops`). Policy: một glob mỗi tên được phát hành
  (`<imagePrefix><tên>@*`, `<imagePrefix><tên>:*`; không glob cả prefix: Kyverno kéo từ registry mọi image khớp glob trước mọi phép,
  nên tên lạ dưới một prefix bị từ chối bằng lỗi registry thay vì phép 1, lượt `verify.yml` 41081463084), một attestor mỗi nguồn; phép 1
  nhận `<imagePrefix><tên>@sha256:<64 hex>` với `<tên>` thuộc `services` hay `drillImages` của nguồn có prefix đó (đường
  `api/gateway`, `web-sourcemaps` không pod nào chạy được); các phép chữ ký, `vuln`, provenance chọn attestor của nguồn theo prefix
  của image, message nêu tên nguồn. Template từ chối lúc render bảng sai (prefix lồng nhau hay thiếu `/`, tên hay `promoter` trùng,
  `promoter` rỗng hay sai kiểu, một service ở hơn hai nguồn, giá trị có nháy, `\`, khoảng trắng). Script đọc cùng bảng: `release_sources [REV]` của
  `deploy/k8s/lib.sh` (commit chưa có bảng thì dừng, nêu commit; [ADR-0037](../adr/0037-mainpath-standard-tools.md) §4),
  `sign_identity`, `provenance_source`, `release_source_in` của `deploy/ci/common.sh`. Luật bảng viết hai nơi (template,
  `_release_sources_check` của `lib.sh`): `deploy/ci/sources-test.sh` (job `config`) đưa từng bảng hỏng qua cả hai, phải bị cả hai
  từ chối đúng message, bảng của working tree qua cả hai. Kyverno thật chọn attestor
  theo prefix: lượt `verify.yml` `gitops` trên `main` 41112757906 (trước đổi tên, stg chạy web của nguồn `web` khi đó, dưới tên `svp-web`): ca (m)
  hai chiều identity bị từ chối đúng message nêu nguồn, bản web đang chạy được nhận. **Build provenance**
  ([ADR-0027](../adr/0027-slsa-build-provenance.md) §4): giá trị `imageVerification.requireProvenance` của chart (mặc định `false`,
  render giống hệt trước; repository và ref mà provenance phải nêu là `repository`, `provenanceRef` của nguồn trong `sources.json`)
  bật thì policy thêm attestation `provenance` và bốn phép kiểm sau sáu phép cũ, mỗi phép một message: provenance ký đúng identity
  của nguồn, `builder.id` bằng `subject` của nguồn, `workflow.repository` là repo của nguồn, `workflow.ref` là `provenanceRef` của
  nguồn (`refs/heads/main`); áp như nhau cho mọi nguồn. Chỉ bật bằng overlay `envs/<env>/svp-policy.yaml` của repo `svp-gitops` (đường GitOps), chứa đúng
  `imageVerification:` + `requireProvenance: true|false` (nội dung khác thì `verify-release.sh`, `values-check.sh`, `gitops.sh`
  dừng); **đã bật ở cả stg và prd** từ commit khởi tạo của `svp-gitops` (cả bảy bản phát hành của `6ca2d8a` mang provenance, ADR-0027
  §6); kịch bản `gitops` lượt 40954609229: policy `Deny` có kiểm provenance, ca (a) và (l) của `drill-k8s-supplychain` PASS. Đường
  dev giữ mặc định `false`. Rollback về digest trước provenance khi đã bật bị từ chối: trỏ bản có provenance hay tắt trước bằng PR ở
  `svp-gitops`. **Định dạng chữ ký** ([ADR-0040](../adr/0040-sigstore-bundle-actions-attest.md)): bản phát hành mới mang chữ ký,
  `vuln`, SBOM, provenance dạng Sigstore bundle (referrer của digest; provenance do `actions/attest`, predicate nêu `builder.id`,
  `workflow`, `gitCommit` như trước), bản đang chạy ở stg, prd còn định dạng cũ (`.sig`, `.att`). Kyverno chọn định dạng theo từng image
  nên cùng policy, cùng message nhận cả hai, không khai gì thêm; một digest không bao giờ mang cả hai (có một bundle thì Kyverno và cosign
  chỉ đọc bundle). Nhánh định dạng cũ (policy, `verify-release.sh`, rescan) bỏ khi `envs/*/images/` của `svp-gitops` không còn digest định
  dạng cũ. Xác minh bundle chậm hơn (CLI không cache 36–46 s so với 14–16 s) mà `timeoutSeconds` của policy là 30: admission thật của
  bản phát hành bundle đầu chưa đo, **kiểm sau push** ở lượt `verify.yml` `gitops` đầu tiên sau khi bản đó promote stg (hạn 20 s lần
  không cache, ADR-0040 mục 6).

## Lệnh của cluster

- `make k8s-up` / `make k8s-down` / `make k8s-status`: `k8s-up` tạo (hay khởi động) registry và cluster, build và push sáu
  image service Go tag `dev-<image ID>` (chỉ `--set`, không ghi file); web như `make up`: không đặt `WEB_FROM` hay `stg|image`
  [`WEB_IMAGE=…`] thì release `web` chạy bản phát hành đó theo digest (node kéo ẩn danh từ GHCR, policy Audit), `WEB_FROM=clone` thì
  build và push thêm image `web` từ thư mục web; `IMAGES` bị từ chối (chỉ của `make up`), cài
  `argocd/apps/components.json` của bản clone `svp-gitops` theo wave với values `base/` của nó (thư mục cấu hình, mục
  `make gitops-clone` dưới đây; không có thì in lệnh clone và dừng trước khi tạo gì) bằng
  `deploy/k8s/install.sh` (trong đó chạy `secrets.sh` sau `svp-cluster`, `glitchtip-init.sh` sau `svp-observability`),
  xuất CA ra `.k8s/ca.crt`. Với Postgres: giữ `serverName` (thế hệ lưu trữ) của Cluster `svp-pg` đang chạy bằng `--set`; từ
  chối nâng `svp-data` khi `svp-pg` đang phục hồi (`bootstrap.recovery` có mà chưa Ready) hay đã mất mà còn Backup của nó;
  sau `svp-data` chờ WAL lưu liên tục và thế hệ đang chạy có backup cơ sở (chưa có thì chụp một bản; cluster mới chờ thêm vài
  phút); idempotent, cần `.env` (`make env`), từ chối cluster do Argo CD quản (có Application
  `svp-root`) và cluster tạo khi object store còn là MinIO (StatefulSet `svp-data/minio`: in lệnh dựng lại `make k8s-down`,
  `make k8s-up`, không nâng tại chỗ). Khi pod template của gateway hay web (Argo Rollout) đổi, tức có canary, `k8s-up` tự chạy traffic diễn tập
  trong lúc
  canary rồi dừng, chờ Rollout `Healthy` có hạn; abort hay inconclusive thì FAIL kèm lệnh gỡ (**LOCAL LAB ONLY**: traffic
  xoá khoá rate limit đăng ký ở Valkey db 10 của cluster). `k8s-down` xoá cluster và registry (volume compose và Postgres
  native không bị đụng). `k8s-status` in container, node và pod mọi namespace trừ `kube-system`.
- `make k8s-secrets`, `make k8s-glitchtip-init`, `make k8s-ca`: `k8s-secrets` tạo/cập nhật Secret từ `.env` bằng
  `kubectl apply` qua stdin, không in giá trị (gồm `svp/web-env` chỉ chứa `NEXT_SERVER_ACTIONS_ENCRYPTION_KEY`, phải là base64
  chuẩn của 32 byte, sai dạng thì dừng; `svp-data/pg-backup-s3` là đăng nhập của user `svp-pg-backup` của object store, chỉ sidecar của
  plugin Barman Cloud trong pod Postgres đọc); mật khẩu superuser Redpanda đổi thì đặt vào broker đang chạy trước khi apply
  (cần `redpanda-0` chạy; Admin API không trả lời hay không nhận mật khẩu nào thì dừng, không đổi Secret nào), object store
  (Secret `s3-root`, `s3-users`) hay Redpanda chạy với mật khẩu khác `.env` thì restart; sau đó `make k8s-up` để Job init đặt mật khẩu mới và restart service
  có Secret đổi (cluster GitOps: các bước tay ở đầu `deploy/k8s/gitops.sh`). **Hai chế độ, chọn theo namespace `svp-secrets`:**
  cluster dev (không có namespace đó) nhận chính các Secret như trên; cluster GitOps dựng từ revision mà overlay stg bật
  `externalSecrets` của chart `svp-cluster` (có `svp-secrets`) chỉ nhận **nguồn**: mỗi entry của
  `deploy/helm/svp-cluster/files/external-secrets.yaml` một Secret ở `svp-secrets` (10 entry từ `.env`, key đặt tên như `.env`;
  entry thứ 11 `glitchtip-runtime` tạo rỗng khi chưa có và không bao giờ bị đổi ở đây), rồi khi ExternalSecret đã có thì dựng lại từng cái từ
  nguồn mới (`force-sync`, chờ `status.syncedResourceVersion` đổi và `Ready`; `es_force_sync` của `deploy/k8s/lib.sh`) trước khi
  restart như trên. External Secrets Operator ([ADR-0026](../adr/0026-secrets-gitops.md)) dựng 28 Secret từ đó; cluster GitOps
  từ revision không có External Secrets thì nhận Secret như đường dev. `k8s-glitchtip-init` ghi DSN vào Secret
  `svp/sentry`, token API chỉ đọc vào `svp-obs/glitchtip-api` và token tải source map vào `svp-obs/glitchtip-sourcemaps`
  (không vào `.env`, không in; cluster có `svp-secrets`: ghi vào nguồn `svp-secrets/glitchtip-runtime` rồi `force-sync` ba
  ExternalSecret đó), restart service khởi động
  khi chưa có DSN hiện tại; idempotent, `k8s-up` tự gọi, không cần `.env`. `k8s-ca` ghi CA của chứng chỉ TLS ra
  `.k8s/ca.crt`.
- `make k8s-images`: build bảy image (sáu từ working tree, `web` từ thư mục web `web_dir` với `SVP_BUILD_ID=dev-<hash nội dung>`) và
  push lên `127.0.0.1:5111` tag `dev-<image ID>` (đường dev).
  `make k8s-release` **đã bỏ**: image phát hành build, quét, ký trong CI (`images.yml`, [`ci.md`](ci.md)), job
  `promote` ghi khối `image` vào `envs/stg/images/<svc>.yaml` của repo `svp-gitops` (cùng `envs/stg/charts.yaml`) trên nhánh
  `bot/promote-stg` của repo đó và mở hay cập nhật một PR cuộn tự merge khi `gitops-ok` xanh (mục `images.yml` của [`ci.md`](ci.md)). Đường dev
  `make k8s-up` giữ registry k3d và tag dev (chỉ `--set`).
- **Thư mục cấu hình, `make gitops-clone [GITOPS_REF=main]`**
  ([ADR-0025](../adr/0025-gitops-config-repo.md) §3): cấu hình triển khai (values gốc `base/`, overlay và digest của mỗi env
  `envs/{stg,prd}/`, Argo CD `argocd/`) nằm ở repo public `svp-gitops`, không còn trong repo này; chart vẫn ở `deploy/helm/`. Mọi
  script đọc thư mục cấu hình qua `gitops_dir` của `deploy/k8s/lib.sh`: `SVP_GITOPS_DIR` nếu đặt, không thì `<workspace>/gitops`
  (thư mục `gitops/` cạnh `backend/`, tính từ `git rev-parse --git-common-dir` nên đúng cả từ worktree ở `.worktrees/`); thư mục đó
  không có hay không phải bản clone `svp-gitops` (gốc work tree, `origin` là `svp-gitops`) thì in lệnh
  `git clone https://github.com/anhnvcoder/svp-gitops.git <workspace>/gitops` và dừng. Đường dev đọc working tree của bản clone
  (`base/`, `components.json`), **không tự clone, không fetch, không đổi nhánh**; sửa thử base: sửa trong bản clone, `make k8s-up`,
  rồi mở PR ở `svp-gitops`. `make gitops-clone` (cho CI): clone ẩn danh, đủ lịch sử vào `.gitops/svp-gitops` (gitignore), có rồi thì
  fetch, rồi checkout `GITOPS_REF` (nhánh, mặc định `main`, hay SHA đủ 40 hex); bản clone có thay đổi chưa commit thì từ chối, bản
  clone dừng giữa chừng (chưa checkout) thì lượt sau làm tiếp; job cần cấu hình đặt `SVP_GITOPS_DIR` tới đó. Thay đổi chéo hai repo
  theo thứ tự: values mới dùng được với chart đang ghim merge ở `svp-gitops` trước, chart dùng values đó sau; bỏ value thì ngược
  lại. Cây, check và cổng của `svp-gitops`: [`ci.md`](ci.md).
- **Thư mục web, `make web-clone [WEB_REF=…]`** ([ADR-0033](../adr/0033-svp-web-repo.md) §7): web client
  ở repo `svp-frontend`; mọi script build hay đọc mã web qua `web_dir` của `deploy/k8s/lib.sh`: `SVP_WEB_DIR` nếu đặt, không thì
  `<workspace>/frontend`; thư mục đó phải là bản clone `svp-frontend` (gốc work tree, `origin` là `svp-frontend`), không thì in lệnh clone và
  dừng. Đọc working tree như đang có, không clone, fetch hay đổi nhánh. Dockerfile là `Dockerfile` ở gốc bản clone, context là gốc
  bản clone (`web_dockerfile`); `web_build_id` đọc cùng thư mục. Chỉ cần thư mục web khi có việc với mã web (`WEB_FROM=clone`,
  `k8s-images`, wrapper `web-*`); không thì web chạy bản phát hành stg. `make web-clone` (cho CI): clone ẩn
  danh đủ lịch sử vào `.web/svp-frontend` (gitignore), có rồi thì
  fetch, checkout `WEB_REF` (nhánh hay SHA đủ 40 hex; không đặt thì commit `tag` của `envs/stg/images/web.yaml` trong bản clone
  `svp-gitops`, chỉ khi web của stg là `<imagePrefix>web` của một nguồn phát hành `web` theo bảng nguồn, tức `web`, tag là commit của
  `svp-frontend`; không thì dừng và đòi `WEB_REF`); bản clone có thay
  đổi chưa commit thì từ chối; job đặt `SVP_WEB_DIR` tới đó.
- `make k8s-gitops-up [GITOPS_REV=main]`: đường GitOps (ADR-0014 §12, ADR-0015
  §9, [ADR-0025](../adr/0025-gitops-config-repo.md) §8), tạo cluster `svp` **mới** đóng vai stg
  ([ADR-0024](../adr/0024-multi-environment.md): `base/` cộng overlay `envs/stg/` và digest `envs/stg/images/` của `svp-gitops`,
  `gitops.sh` luôn đặt `env=stg` cho root, không có biến chọn env) mà Argo CD dựng từ GitHub qua HTTPS ẩn danh (không deploy key,
  không Secret repo; [ADR-0021](../adr/0021-deferred-verification-stage6b.md) §6): root `svp-root` và nguồn values đọc
  `svp-gitops`, chart `deploy/helm/*` đọc repo này ở commit `revision` của `envs/stg/charts.yaml`; kéo image từ GHCR theo digest, ẩn
  danh. `GITOPS_REV` là revision của `svp-gitops` trong thư mục cấu hình: nhánh của `origin` (đọc `refs/remotes/origin/<nhánh>` như lần
  fetch cuối, không `git fetch`) hay SHA đủ 40 hex. Cluster luôn **dựng ở đúng commit đã kiểm** (root và mọi nguồn values đọc SHA đó),
  nên PR promote merge giữa lúc dựng không đổi gì (lượt 40984138133 đỏ vì Argo CD theo nhánh, triển khai bản mới thành canary không
  traffic, `restartAt` của Rollout `web` không bao giờ Healthy); `GITOPS_REV` là nhánh thì sau vòng chờ root mới chuyển sang
  `refs/heads/<nhánh>` (Argo CD nhận tên đầy đủ, không bao giờ tên ngắn, vì tên ngắn có thể phân giải sang tag cùng tên; `follow_branch`,
  cũng chạy riêng được: `deploy/k8s/gitops.sh follow <nhánh>`): nhánh không đổi thì chỉ root sync, dòng `ok … follows refs/heads/…,
  still at <sha>`; nhánh đã đi tiếp thì một dòng `note` nêu hai commit, Argo CD triển khai bản mới như mọi lần phát hành (canary của
  gateway, web cần traffic: `make k8s-traffic-start`), script không chờ; `GITOPS_REV` là SHA thì cluster ở yên đó. `restart_workload`
  của `deploy/k8s/lib.sh` (restart sau khi Secret đổi, cả `glitchtip-init.sh`) gặp Rollout đang canary (pod template khác `stableRS`,
  pause, abort), trước hay giữa lúc restart, thì dừng ngay, nêu canary và cách gỡ, không chờ 300 s. Trước khi tạo gì, kiểm ở đúng revision đó cả 7 file `envs/stg/images/`: repository
  `<imagePrefix><svc>` của một nguồn phát hành có `<svc>` trong bảng nguồn ở commit `charts.yaml` của stg, manifest kéo ẩn danh được
  (package GHCR đã public), chữ ký và attestation `vuln` đúng identity của nguồn đó, không CRITICAL, không quá 48 giờ (`deploy/ci/values-check.sh --gitops` trên bản trích `envs/stg` của revision, gọi
  `verify-release.sh --gitops`, bằng `cosign` trên PATH, không có thì `COSIGN_IMAGE`; quá hạn thì in lệnh dispatch rescan), và khi
  `svp-policy` bật provenance cho stg (values của chart ở commit `charts.yaml` rồi `envs/stg/svp-policy.yaml`) thì đúng một
  attestation provenance qua cùng phép kiểm như Kyverno, có `gitCommit` bằng commit trong chứng chỉ của chữ ký
  (`--certificate-github-workflow-sha`; thiếu thì in lệnh dispatch build lại service đó);
  thiếu một điều là dừng, không tạo gì. Rồi tạo namespace (chart `svp-cluster` ở commit `charts.yaml`; overlay stg bật
  `externalSecrets` nên có cả `svp-secrets`) và Secret từ `.env` (chế độ của `make k8s-secrets` ở trên), cài Argo CD theo
  `argocd/bootstrap.json` (chart, version, values `base/argo-cd.yaml`; namespace `argocd`, PSA `restricted`) với plugin Gateway API
  của Argo Rollouts theo kiến trúc node (`nodeArch` đọc từ node, cluster lẫn kiến trúc thì dừng; bản amd64 ở
  `base/argo-rollouts-amd64.yaml`, cùng file `install.sh` của đường dev đọc), AppProject `svp` và `default` đã khoá
  (`argocd/project.yaml`), root `svp-root` (`env=stg`); chờ mọi Application `Synced`, Healthy, sync cuối `Succeeded` (lỗi còn sau
  180 s thì dừng). Hết hạn chờ thì in trạng thái từng Application, tài nguyên chưa Healthy của nó (đọc thẳng từ cluster: Argo CD 3.x
  không ghi health của tài nguyên vào Application; workload theo pod ready, Job, PVC, condition của CR), condition của CR `Prometheus`,
  `Alertmanager`, đuôi log operator của kube-prometheus-stack và sự kiện, rồi dừng. kube-prometheus-stack trong `svp-gitops` có sync
  wave (CRD wave 0, operator 1, CR `Prometheus`/`Alertmanager` 2) vì operator chỉ dò CRD một lần lúc khởi động (lượt 40938235138
  kẹt bootstrap trước khi có wave). Component `external-secrets` của `components.json`
  (External Secrets Operator 2.14.0, namespace `external-secrets`, wave 0, values `base/external-secrets.yaml`: chỉ
  controller, không webhook, không cert-controller) có `gitopsOnly: true`, nên chỉ đường này cài, `make k8s-up` bỏ qua; chart
  `svp-cluster` với overlay stg render SecretStore `svp-store` (provider `kubernetes`, ServiceAccount `svp-secrets-reader` chỉ
  `get` theo tên đúng các entry namespace đó đọc), 28 ExternalSecret (`refreshPolicy: OnChange`, mọi cái có `target.template`),
  namespace và NetworkPolicy của `svp-secrets`, ValidatingAdmissionPolicy `svp-external-secrets-writes` (controller chỉ ghi Secret
  ở bốn namespace đích, không bao giờ Secret token) và `svp-store-serviceaccount-pods`, `-tokens` (ở mọi namespace không pod nào
  chạy dưới `svp-secrets-reader`, không Secret nào giữ token của nó; controller lấy token bằng TokenRequest); overlay prd render
  store `aws` (Secrets Manager `svp/prd/<entry>`, role mỗi namespace, giá trị giữ chỗ tới khi có cluster EKS; controller thêm egress
  TCP 80 chỉ tới agent EKS Pod Identity `169.254.170.23/32`). Đã kiểm trên cluster: lượt `gitops` 40857855305 (28 ExternalSecret
  `Ready`) và 40954609229 (đọc `svp-gitops`, 26/26 Application Synced/Healthy, 28/28 ExternalSecret `Ready`).
  Đo thời gian từ merge tới pod Ready (`measure-gitops`) nay là bài lab `drills/` của `svp-labs`
  ([ADR-0039](../adr/0039-mainpath-drills-scan-gate-sourcemaps.md) §1).
- `make k8s-traffic-start` / `make k8s-traffic-stop`: traffic diễn tập chạy nền, 4 user, ~10 request/s vào
  `GET /feed/explore`, `/feed/following` qua `https://api.svp.localhost:8443` và ~4 request/s vào web
  `https://svp.localhost:8443` (`GET /login`, một asset `/_next/static/...`; dòng log `web-login`, `web-asset`), mỗi
  request một dòng ở
  `.k8s/drills/traffic-<time>.log`, chạy tới khi dừng (qua cả lúc push phát hành trên cluster GitOps); `stop` chỉ dừng
  đúng pid đã ghi và in số request theo status. **LOCAL LAB ONLY:** đăng ký user mới và xoá khoá rate limit đăng ký ở
  Valkey db 10 của cluster.
- `make k8s-smoke`, `make drill-k8s-threats`: trên cluster đang chạy, qua Envoy với `.k8s/ca.crt` (thiếu thì chạy `make k8s-ca`), script ở
  `deploy/k8s/drills/` (`k8s-smoke` dùng `deploy/compose/smoke.sh`). Lần lượt: luồng đầu-cuối như `make smoke`;
  các dòng Kubernetes của threat model, mỗi dòng có ca đối chứng (pod thử ở namespace `svp-probe` tạo rồi xoá,
  NetworkPolicy, ACL Kafka, PSA, `pg_hba`, RL-1 với `X-Forwarded-For` giả, pprof/metrics, UI không lộ, Grafana 401,
  RBAC: không ServiceAccount nào của `svp` đọc Secret hay pod, CloudNativePG và Envoy Gateway chỉ có quyền ở các
  namespace đã thu hẹp, ngoại lệ còn lại in kèm lý do) và các dòng web trên cluster (WEB-7, WEB-2, WEB-10,
  WEB-13, WEB-8; pod web ở FF-3, FF-4, IN-2; route `svp/web` ở OPS-2) và các dòng backup (BAK-1:
  request S3 có chữ ký qua Envoy, user `svp-pg-backup` chỉ tới `pg-backups`, user service không tới được bucket đó; operator
  CloudNativePG ở `cnpg-system` không tạo pod, không exec, không sửa Deployment, không lấy token cho ServiceAccount nào, kiểm bằng
  `kubectl auth can-i` và tạo thử dry run dưới tên operator mà policy `svp-cnpg-operator-secrets` từ chối; ngoại lệ RBAC của
  plugin Barman Cloud in kèm lý do) và các dòng External Secrets (SEC-5, SEC-6, SEC-7, chỉ trên cluster có External Secrets Operator,
  nơi khác in một dòng bỏ qua: ServiceAccount store mỗi namespace chỉ `get` đúng entry nguồn của namespace đó theo tên, không
  list/watch, không Secret nào khác (đối chứng: store của `svp` lấy được `pg-roles`, không lấy được `pg-superuser`), không kind
  `ClusterSecretStore`; controller chỉ lấy token cho ServiceAccount của store, dry run dưới tên controller ghi Secret Opaque ở
  `argocd` và Secret token ở `svp` bị `svp-external-secrets-writes` từ chối (đối chứng: Opaque ở `svp` qua), quyền đọc mọi Secret
  của controller in thành ngoại lệ SEC-5 kèm lý do, không webhook của ESO, pod thử không mở được cổng metrics 8080 của controller;
  không ServiceAccount nào của `svp` tạo được ExternalSecret hay SecretStore, ClusterRole `view`/`edit`/`admin` không cấp gì trên
  `external-secrets.io`; mục `SEC-6-reader`, cùng điều kiện: dry run ở `svp-data` (namespace có `svp-secrets-reader`), pod chạy dưới
  ServiceAccount đó và Secret token của nó bị `svp-store-serviceaccount-pods`, `-tokens` từ chối đúng message, đối chứng cùng pod với
  `default` và Secret token của `default` được nhận), log ở
  `.k8s/drills/threats-<time>.log` được dò các giá trị
  Secret đã đọc. Kết quả và JSON ở `.k8s/drills/`. **LOCAL LAB ONLY:** cả hai target xoá khoá `svp:gw:rl:register:*` ở
  Valkey db 10 của cluster (qua `kubectl exec`). Các diễn tập đo một lần (KEDA và RAM, PDB, canary của gateway và của web, backup và PITR,
  `measure-canary`, `measure-gitops`, `drill-k8s-web-obs`) là bài lab `drills/` của `svp-labs`
  ([ADR-0039](../adr/0039-mainpath-drills-scan-gate-sourcemaps.md) §1); quy trình khôi phục Postgres bằng tay ở
  [`postgres-restore.md`](../runbooks/postgres-restore.md).
- `make drill-k8s-supplychain [SUPPLYCHAIN_UNSIGNED=<digest GHCR>] [SUPPLYCHAIN_VULNERABLE=<digest GHCR>]
  [SUPPLYCHAIN_NO_PROVENANCE=<digest GHCR>|none] [SUPPLYCHAIN_ENFORCE_TMP=1]` (script `deploy/k8s/drills/supplychain.sh`;
  ba biến digest nhận `<imagePrefix><tên>@sha256:…` với `<tên>` thuộc `services` hay `drillImages` của nguồn có prefix đó, như phép 1
  của policy, cosign đọc bằng identity của nguồn có prefix đó như Kyverno chọn attestor): policy Kyverno của `svp`, mỗi ca
  một dòng PASS/FAIL/SKIP và chỉ PASS khi đúng message của rule cần từ chối; pod gửi bằng `--dry-run=server` (trừ ca b là
  Deployment thật, xoá sau). Ca: (a) bản phát hành đã ký, sạch được nhận, hai lần liền (lần hai từ cache); (b)
  `drill-unsigned` bị từ chối vì thiếu chữ ký (mặc định script tự lấy digest mới nhất của `<imagePrefix của backend>drill-unsigned`,
  ẩn danh, `SUPPLYCHAIN_UNSIGNED=<digest>` ghi đè, không tìm thấy thì SKIP; không dùng manifest con của một bản phát hành đã ký: với
  bundle, attestation của bản đó trỏ cả tới từng manifest con và Kyverno tính là chữ ký, nên manifest con qua phép chữ ký và bị từ chối
  ở phép `vuln`); (c) `drill-vulnerable` bị từ chối vì CRITICAL, ca này tự đọc
  `scanFinishedOn` bằng cosign và FAIL khi quá 72 giờ, nên chạy trong 72 giờ sau khi dispatch image diễn tập (`gh workflow
  run images.yml --ref main -f drill=true`, người học chạy); (d) image registry k3d và Docker Hub bị từ chối vì prefix,
  mỗi lần dưới 1 s; (e) image không digest; (f) attestation quá hạn (policy tạm tuổi tối đa 5 s); (g) admission
  controller không lịch được: pod `svp` bị từ chối, pod ở namespace thử `svp-probe` được nhận; (h) ephemeral container
  chưa ký (ảnh của (b); không có thì image registry k3d, từ chối vì prefix) bị từ chối, đã ký được nhận; (i) UPDATE image
  chưa ký bị từ chối; (k) đường keyless với image công khai của nhà cung cấp khác (đúng identity nhận, sai identity từ chối;
  chỉ trên dev); (l) image diễn tập `drill-no-provenance` (bản build sạch như `drill-unsigned`, ký và attest `vuln` (bundle) như bản phát hành, không attest provenance; [ADR-0036](../adr/0036-repo-rename.md) §6) bị từ
  chối đúng message của phép provenance, chỉ khi policy đang chạy kiểm provenance (có attestation `provenance`), không thì SKIP "policy
  off" (không hỏi GHCR); mặc định script tự lấy digest mới nhất của `<imagePrefix của backend>drill-no-provenance` (ẩn danh),
  `SUPPLYCHAIN_NO_PROVENANCE=<digest>` ghi đè, `none` làm ca SKIP; trước khi gửi pod, cosign (ẩn danh) kiểm image có chữ ký, đúng một
  `vuln` hai nền tảng không CRITICAL trong tuổi tối đa và không có provenance, không tìm thấy hay thiếu một điều thì FAIL kèm lệnh dispatch
  `gh workflow run images.yml --ref main -f drill=true` (người học chạy, trong 72 giờ trước lượt diễn tập); ca (a), (c), (f), (l) đọc
  được image bundle lẫn định dạng cũ bằng cùng lệnh cosign, Kyverno trả cùng message cho cả hai (với bundle, ca (c) đọc `vuln`
  cũ nhất khi rescan đang giữa attest và gỡ, ca (l) đòi đúng một); ảnh chưa ký của (b), (h), (i) là `drill-unsigned`, không gì
  trên GHCR trỏ tới nó ở định dạng nào; ca với image bundle **kiểm sau push** (chưa có image diễn tập bundle); (m)
  nguồn phát hành tách nhau, mỗi cặp nguồn A, B của bảng: image dưới prefix của A mang tên chỉ B phát hành bị từ chối đúng message của
  phép 1, không hỏi registry (không khớp glob nào; không có tên như vậy thì SKIP); bản
  phát hành của B mà pod `svp` chạy, gửi dưới bản sao tạm của policy đổi chéo issuer, subject của A và B (chỉ pod nhãn
  `svp-drill=supplychain-swap`, một bản sao mỗi cặp cho cả hai chiều, xoá ngay sau), bị từ chối đúng message phép chữ ký nêu nguồn B
  (chọn nhầm attestor của A thì gặp identity của B và lọt qua; không đặt digest của A dưới prefix của B: GHCR không có manifest đó,
  Kyverno kéo image khớp glob trước mọi phép nên chỉ nhận lỗi registry; chưa bản nào của B chạy trong `svp` thì SKIP); bản của mỗi
  nguồn khác `backend` mà pod `svp` chạy được nhận (chưa có thì SKIP). Đường dev là Audit nên script từ chối chạy trừ
  khi `SUPPLYCHAIN_ENFORCE_TMP=1`: chạy (k), nâng tạm `svp-policy` lên Enforce cho các ca còn lại rồi trả Audit; trên
  đường dev chưa có image ký nên (a), (c), (f) và nửa nhận của (h) SKIP. Trên cluster GitOps (lượt 40954609229, nhánh PR-B):
  a–i và (l) PASS, (l) đúng message của phép provenance, (k) SKIP như thiết kế. Khi kết thúc script trả Kyverno, Argo CD sync, Audit về như cũ, xoá policy tạm, `svp-probe`, và so
  webhook với ảnh chụp đầu; JSON ở `.k8s/drills/`. Không gọi API của gateway, không xoá khoá rate limit nào.
- `make k8s-ui-grafana`, `k8s-ui-prometheus`, `k8s-ui-alertmanager`, `k8s-ui-glitchtip`, `k8s-ui-argocd`: port-forward chỉ
  trên `127.0.0.1` (lần lượt 3000, 9090, 9093, 8000, 8081) trong lúc target chạy (Ctrl-C để đóng); không HTTPRoute,
  LoadBalancer hay NodePort nào cho UI (OPS-2). Grafana đăng nhập `admin` + `SVP_GRAFANA_ADMIN_PASSWORD`, GlitchTip bằng
  `GLITCHTIP_ADMIN_EMAIL`/`GLITCHTIP_ADMIN_PASSWORD`, Argo CD (cluster GitOps, chứng chỉ tự ký) `admin` với mật khẩu đọc
  bằng lệnh target in ra; Prometheus và Alertmanager không có đăng nhập nên chỉ mở khi forward đang chạy.
- `make k8s-web-sourcemaps`, `make k8s-web-e2e` ([ADR-0019](../adr/0019-web-k3d-supply-chain-observability.md)), trên
  cluster dev; wrapper gọi target `k8s-sourcemaps`, `k8s-e2e` của `Makefile` thư mục web như `web-e2e`:
  `k8s-web-sourcemaps` như `web-sourcemaps` với bản build mà cluster chạy (`web_build_id`) và token của Secret
  `svp-obs/glitchtip-sourcemaps`, qua port-forward riêng `127.0.0.1:8000`; cluster dev chạy bản phát hành `WEB_FROM=stg|image` thì từ chối
  (không có bản build để tải map); kiểm mọi chunk `/login` đang phục vụ có debug ID trong bộ map; `k8s-web-e2e` chạy e2e của web vào
  `https://svp.localhost:8443` (`e2e/k3d-e2e.sh` của `svp-frontend`: `SVP_STACK=k3d`, CA `.k8s/ca.crt`, cookie `__Host-Http-svp_sid` +
  `Secure`), `SVP_E2E_GLITCHTIP=1` đọc token chỉ đọc của Secret `svp-obs/glitchtip-api` vào môi trường của lượt chạy và tự mở
  forward `127.0.0.1:8000`, `SVP_E2E_EVIDENCE` như `web-e2e`; cổng bị chiếm thì dừng. Hai target là công cụ đường dev: e2e của web chạy ở
  job `stack` của CI `svp-frontend`; image source map không còn
  ([ADR-0039](../adr/0039-mainpath-drills-scan-gate-sourcemaps.md) §3). **LOCAL LAB ONLY:** `k8s-web-e2e` xoá khoá
  `svp:gw:rl:register:*` ở Valkey db 10 của cluster.

## Manifest cho cluster đo thật

- `make cloud-check` (ADR-0020 §8, [ADR-0039](../adr/0039-mainpath-drills-scan-gate-sourcemaps.md) §1, script `deploy/k8s/cloud/check.sh`): kiểm
  tĩnh Job k6 của cluster đo thật (EKS) không cần cluster hay `.env`: `deploy/k6/cloud/render.sh` in manifest (không đối số), rồi kubeconform
  `-strict` (`KUBECONFORM_IMAGE` ghim; schema Kubernetes `CLOUD_K8S_VERSION` của `deploy/k8s/k8s.mk` ở commit ghim; kind không có
  schema là FAIL, không `-ignore-missing-schemas`) và mọi image ghim đúng một `@sha256:` (không thấy image nào cũng là FAIL). Cần mạng (schema trên
  GitHub). `deploy/k6/cloud/render.sh --pods N` (mặc định 20, pod i chạy segment i/N, giữ phần tải mỗi pod của thiết kế 20 pod), `--ramp`,
  `--hold` (cú pháp `SVP_K6_HOLD`; hạn Job tính theo cả lượt khi đặt), `run.sh --pods N [--ramp D] [--hold D] start`. Lệnh chạy thật
  (`deploy/k6/cloud/run.sh`) do người học chạy với context của cluster đo ghi trong lệnh; script từ chối mọi context `k3d-*` và context
  rỗng trước mọi `kubectl`. Manifest Chaos Mesh, Velero và overlay runner không còn ở repo; Velero cho EKS quyết lại ở việc 7b
  ([ADR-0034](../adr/0034-aws-stage7.md)), lấy từ bài lab.
