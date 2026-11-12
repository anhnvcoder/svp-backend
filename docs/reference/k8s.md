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
  trong cluster bằng user riêng `svp-pg-backup`, [ADR-0020](../adr/0020-reliability-stage6.md) §5), Kafka (StatefulSet `kafka`,
  image `apache/kafka`, `kafka.svp-data.svc.cluster.local:9096` SASL_SSL SCRAM-SHA-512, ACL; Job `kafka-init` tạo topic, user, ACL), Valkey
  (Deployment `valkey`, TLS cổng 6379, user ACL theo db và tiền tố khoá), Deployment `svp-ops` (CLI vận hành, dưới), object store (RustFS, StatefulSet `s3`, `s3.svp-data:9000`, Job `s3-init`) nằm trong cluster: target của cluster k3d không đụng Postgres/Redis native. File sinh ra nằm ở
  `.k8s/` (gitignore). CA local cho client là Secret `local-ca` (file `ca.crt`) mount ở `/etc/svp-ca` (Go `SSL_CERT_DIR`, Node
  `NODE_EXTRA_CA_CERTS`, KEDA tham số `ca`, Collector `tls.ca_file`, Postgres `sslrootcert`). **TLS tới Postgres**
  ([ADR-0057](../adr/0057-postgres17-verify-full.md) §2): Cluster `svp-pg` phục vụ cert `postgres.crt` của CA local (`make env` sinh, SAN gồm
  `svp-pg-rw.svp-data`) qua Secret `pg-tls` (`kubernetes.io/tls`, nhãn `cnpg.io/reload`, dựng từ khoá `postgres.crt`, `postgres.key` của nguồn
  `local-tls`) ở `certificates.serverTLSSecret`, CA ở `serverCASecret: local-ca`; mọi client (service, Job `migrate`, GlitchTip, Job
  `pg-bootstrap`) nối `svp-pg-rw.svp-data:5432` với `sslmode=verify-full&sslrootcert=/etc/svp-ca/ca.crt`; service có Kafka đăng nhập SASL SCRAM-SHA-512 trên TLS bằng
  `KAFKA_SASL_USERNAME`, `KAFKA_SASL_PASSWORD` (đặt cả hai hay không biến nào): cả hai cùng có ở compose. Biến chỉ đặt ở cluster: gateway tin một hop
  `X-Forwarded-For` từ dải pod của Envoy qua `TRUSTED_PROXY_HOPS=1`, `TRUSTED_PROXY_CIDRS=10.42.0.0/16` (compose: không
  đặt, 0 hop; giá trị không hợp lệ thì gateway không khởi động); gateway `TRUST_TRACE_CONTEXT=true` (nhận
  `traceparent`/`tracestate` của request đến; `false` hay rỗng là mặc định, giá trị khác thì không khởi động) vì Envoy bỏ
  `traceparent`, `tracestate`, `baggage`, `sentry-trace` của client trên mọi route và chỉ Envoy, web vào được gateway
  (WEB-24). Web ([ADR-0019](../adr/0019-web-k3d-supply-chain-observability.md)):
  `GATEWAY_URL=http://gateway:8080`,
  `REDIS_URL=rediss://svp-web:<mật khẩu>@valkey.svp-data.svc.cluster.local:6379/9` (Secret `svp/web-env`), `APP_ORIGIN=https://svp.localhost:8443`, `MEDIA_ORIGIN`, `UPLOAD_ORIGIN`
  `https://s3.svp.localhost:8443` (object store chỉ nhận CORS từ `https://svp.localhost:8443`, theo bucket như compose), `SENTRY_ENVIRONMENT=k3d`,
  `SENTRY_DSN` từ Secret `svp/sentry`, `NEXT_SERVER_ACTIONS_ENCRYPTION_KEY` từ Secret `svp/web-env`; `SVP_BUILD_ID` là build arg
  chép thành `ENV` của image (12 hex của commit ở CI, `dev-` + hash nội dung context ở đường dev, rỗng ở compose), dùng làm
  `deploymentId`, `release` của GlitchTip và `service.version`. API server có PSA `restricted` mặc định cho mọi namespace
  trừ `kube-system` (`deploy/k8s/pod-security-admission.yaml`, mount từ đường của repo lúc tạo cluster, đọc lại mỗi lần
  node server khởi động): sửa `k3d.yaml` hay dời repo phải `make k8s-down && make k8s-up`, sửa file đó có hiệu lực ở lần
  khởi động sau; `make k8s-up` từ chối cluster tạo khi chưa có cấu hình này, hay khi nguồn mount không còn là file, khác
  file của repo hiện tại, hay version lệch `podSecurityVersion`. Probe của chart `svp-service` (ADR-0020 §10, cùng cho mọi
  release): liveness `timeoutSeconds: 5` (chu kỳ 10 s, 3 lần), readiness 2 (chu kỳ 5 s), startup của service gRPC 2 (chu kỳ
  2 s × 30 lần); media-worker không có probe. Probe gRPC: startup và liveness hỏi health tổng `""` (không phụ thuộc database),
  readiness hỏi tên health `readiness` (`grpc.service: readiness`), NOT_SERVING khi ping Postgres của service lỗi 3 lần liên tiếp
  ([ADR-0044](../adr/0044-grpc-readiness.md)): database của một service không tới được thì pod của nó NotReady, không restart.
- Nền tảng trên k3d so với EKS ([ADR-0056](../adr/0056-eks-platform-ha.md)): Envoy chạy như EKS (EnvoyProxy `svp` có HPA `envoyHpa` từ 2
  replica, PDB `envoyPDB`, trải zone rồi trải node; node k3d không có nhãn `topology.kubernetes.io/zone` nên chỉ ràng buộc node có tác dụng);
  Kyverno một replica của `base/kyverno.yaml` (ba replica chỉ ở `platforms/eks/kyverno.yaml`); không Karpenter (`karpenter.enabled` của chart
  `svp-cluster` tắt, node là hai node của k3d).

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
  bị phép 1 từ chối (prefix không thuộc nguồn nào), không bot nào tiếp quản file của nguồn nghỉ hưu nữa. `promoter` vẫn tuỳ chọn ở
  template; bảng ở `revision` mà env ghim còn có thể có nguồn không `promoter` (`envs/prd/charts.yaml` còn ở commit merge của PR đổi
  tên, bảng bốn nguồn): template của chính commit đó render nó, script đọc nguồn đó là nguồn nghỉ hưu. `promoter` không trùng giữa các
  nguồn có nó. Repo này chỉ build, ký, promote sáu image của nó
  (`built_services` của `deploy/k8s/lib.sh`); `svp_services` vẫn là bảy bản triển khai (gồm `web`), mà rescan, promote prd,
  check `svp-gitops`, `k8s/gitops.sh` đọc. Stg chạy web của repo `svp-frontend` từ 2026-10-30, prd từ 2026-10-31 (PR #22, #29 của `svp-gitops`). Policy: một glob mỗi tên được phát hành
  (`<imagePrefix><tên>@*`, `<imagePrefix><tên>:*`; không glob cả prefix: Kyverno kéo từ registry mọi image khớp glob trước mọi phép,
  nên tên lạ dưới một prefix bị từ chối bằng lỗi registry thay vì phép 1, lượt `verify.yml` 41081463084), một attestor mỗi nguồn; phép 1
  nhận `<imagePrefix><tên>@sha256:<64 hex>` với `<tên>` thuộc `services` hay `drillImages` của nguồn có prefix đó (đường
  `api/gateway`, `web-sourcemaps` không pod nào chạy được); các phép chữ ký, `vuln`, provenance chọn attestor của nguồn theo prefix
  của image, message nêu tên nguồn. Template từ chối lúc render bảng sai (prefix lồng nhau hay thiếu `/`, tên hay `promoter` trùng,
  `promoter` rỗng hay sai kiểu, một service ở hơn hai nguồn, giá trị có nháy, `\`, khoảng trắng). Script đọc cùng bảng: `release_sources [REV]` của
  `deploy/k8s/lib.sh` (commit chưa có bảng thì dừng, nêu commit; [ADR-0037](../adr/0037-mainpath-standard-tools.md) §4),
  `sign_identity`, `provenance_source`, `release_source_in` của `deploy/ci/common.sh`. Luật bảng chỉ viết một nơi, template
  ([ADR-0050](../adr/0050-bash-to-standard-tools.md)): `deploy/ci/sources-test.sh` (job `config`) đưa từng bảng hỏng qua render, phải
  bị từ chối đúng message, bảng của working tree render được. Script đọc bảng mà không kiểm lại luật, vì mọi bảng đường phát hành đọc
  đã render trước: bảng working tree ở job `config` (bắt buộc trước khi vào `main`), bảng ở `revision` env ghim (commit trên `main`) ở
  bước 3 của `gitops-check.sh` và ở Argo CD. Script chỉ giữ hai luật: `release_sources` kiểm mỗi `imagePrefix` là đường registry kết thúc `/` và không
  prefix nào bắt đầu bằng prefix khác, và hai hàm chọn nguồn theo prefix của image (`source_of_repository`, `release_source_of` của `lib.sh`) dừng khi hơn một
  nguồn khớp, để identity được chọn không tuỳ vào việc render đã chạy hay chưa (diễn tập, check trên máy đọc working tree như đang có). Kyverno thật chọn attestor
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

- `make k8s-up` / `make k8s-down` / `make k8s-status`: `k8s-up` tạo (hay khởi động) registry và cluster, build sáu image service Go
  một lượt bằng `docker buildx bake -f deploy/docker-bake.json` (bảng image, [ADR-0050](../adr/0050-bash-to-standard-tools.md)) và push
  tag `dev-<image ID>` (state value của helmfile trong file tạm, không ghi file của repo); web như `make up`: không đặt `WEB_FROM` hay `stg|image`
  [`WEB_IMAGE=…`] thì release `web` chạy bản phát hành đó theo digest (node kéo ẩn danh từ GHCR, policy Audit), `WEB_FROM=clone` thì
  build và push thêm image `web` từ thư mục web; `IMAGES` bị từ chối (chỉ của `make up`), cài
  `argocd/apps/components.json` của bản clone `svp-gitops` theo wave với values `base/` của nó (thư mục cấu hình, mục
  `make gitops-clone` dưới đây; không có thì in lệnh clone và dừng trước khi tạo gì) bằng helmfile (`HELMFILE_VERSION` của
  `Makefile`, `make tools`): `deploy/k8s/helmfile.yaml.gotmpl` biến danh sách đó thành release (component của đường dev, `needs` theo
  wave), glue `deploy/k8s/install.sh` chạy helmfile wave 0, 1, rồi `secrets.sh`, rồi các wave sau; điều release sau cần (chứng chỉ,
  webhook, Prometheus, policy, metrics API của KEDA, backup cơ sở, DSN của GlitchTip qua `glitchtip-init.sh`, Rollout `Healthy`) là hook
  postsync của release trước (`install.sh hook …`). Release lỗi thì helmfile không cài wave sau, in log lần migrate lỗi cuối và container
  chưa ready. Reloader (component `reloader`) cài cùng lượt; cluster chạy workload mà chưa có Reloader hay workload chưa opt in đúng
  bản render (cluster dựng trước) thì các wave sau chạy một lượt với Secret như cũ trước `secrets.sh`, xong mới đổi credential; cuối
  lượt Reloader phải chạy và được patch mọi workload opt in, không thì FAIL. Xuất CA ra `.k8s/ca.crt`. Với Postgres: giữ `serverName` (thế hệ lưu trữ) của Cluster `svp-pg` đang chạy (state value `pgServerName` của helmfile); từ
  chối nâng `svp-data` khi `svp-pg` đang phục hồi (`bootstrap.recovery` có mà chưa Ready) hay đã mất mà còn Backup của nó;
  sau `svp-data` chờ WAL lưu liên tục và thế hệ đang chạy có backup cơ sở (chưa có thì chụp một bản; cluster mới chờ thêm vài
  phút); idempotent, cần `.env` (`make env`), từ chối cluster do Argo CD quản (có Application
  `svp-root`). Khi pod template của gateway hay web (Argo Rollout) đổi, tức có canary, `k8s-up` tự chạy traffic diễn tập
  trong lúc
  canary rồi dừng, chờ Rollout `Healthy` có hạn; abort hay inconclusive thì FAIL kèm lệnh gỡ (**LOCAL LAB ONLY**: traffic
  xoá khoá rate limit đăng ký ở Valkey db 10 của cluster). `k8s-down` xoá cluster và registry (volume compose và Postgres
  native không bị đụng). `k8s-status` in container, node và pod mọi namespace trừ `kube-system`.
- `make k8s-secrets`, `make k8s-glitchtip-init`, `make k8s-ca`: chỉ cluster k3d (`secrets.sh`, `gitops.sh` từ chối context EKS; nguồn
  Secret trên EKS là Secrets Manager, `make eks-secrets` ở [`eks.md`](eks.md)). `k8s-secrets` tạo/cập nhật Secret từ `.env` bằng
  `kubectl apply` qua stdin, không in giá trị (gồm `svp/web-env` chỉ chứa `NEXT_SERVER_ACTIONS_ENCRYPTION_KEY`, phải là base64
  chuẩn của 32 byte, sai dạng thì dừng; `svp/<service>-env` của gateway và bốn service gRPC có `JWT_VERIFY_KEYS` (khoá công khai,
  [ADR-0042](../adr/0042-caller-identity-grpc.md)), khoá ký chỉ ở `user-service-env`; ExternalSecret của đường GitOps dựng cùng
  key từ nguồn `jwt-verify`; `svp-data/pg-backup-s3` là đăng nhập của user `svp-pg-backup` của object store, chỉ sidecar của
  plugin Barman Cloud trong pod Postgres đọc). Mỗi lần là **trọn một lượt xoay credential** (`deploy/k8s/rotate.sh`,
  [ADR-0050](../adr/0050-bash-to-standard-tools.md) mục 5), đủ ba bước dù giá trị nào đổi: (1) máy chủ: mật khẩu `svp-admin` của Kafka đổi
  thì đặt vào broker đang chạy trước (`kafka_admin` của `deploy/k8s/lib.sh`, qua `svp-kafka` của Deployment `svp-ops`; cần `kafka-0` và
  `svp-ops` chạy; không mật khẩu nào đăng nhập được thì dừng, không đổi Secret nào), apply Secret của `svp-data` (cả CA local, aclfile của
  Valkey), rồi chờ mọi pod của StatefulSet `s3` chạy với giá trị của `.env` và Ready, và Valkey nhận mật khẩu `.env` của từng user (Valkey
  chỉ đọc aclfile lúc khởi động; Reloader restart; so trong container qua `svp-valkey` với `SVP_AS_USER`, mật khẩu qua stdin, 300 s,
  hết hạn thì FAIL nêu Deployment `valkey`). Kafka không cần restart: user nằm trong broker; (2) Job init của `svp-data` đặt mật khẩu mới trong Postgres, object store và Kafka (đường dev: helmfile, chỉ release
  `svp-data`; cluster GitOps: một operation sync của Application `argocd/svp-data`, chờ `Succeeded`), lỗi thì dừng, Secret của client
  không đổi; release hay Application chưa có (lần dựng) thì bỏ bước này; (3) client: Secret của `svp`, `svp-obs`, `keda`; Reloader
  restart workload có Secret đổi, script không chờ, in lệnh `kubectl --context k3d-svp get pods -A -w` để theo dõi. Cùng `.env` thì
  không Secret nào đổi, không gì restart; lượt chạy lại sau một lượt chết giữa chừng làm nốt init còn thiếu. Trước khi ghi gì, từ chối
  cluster chạy workload của dự án mà chưa có Reloader, có workload chưa opt in theo đúng Secret của chart, hay (đường dev) Reloader không
  được patch nó: dòng `FAIL  cluster svp is not ready for a change of credentials: <lý do>`, `make k8s-up` cài chúng. Rollout đang
  canary lúc Secret của nó đổi thì để Reloader và Argo Rollouts xử lý như mọi restart. **Hai chế độ, chọn theo namespace `svp-secrets`:**
  cluster dev (không có namespace đó) nhận chính các Secret như trên; cluster GitOps dựng từ revision mà overlay stg bật
  `externalSecrets` của chart `svp-cluster` (có `svp-secrets`) chỉ nhận **nguồn**: mỗi entry của
  `deploy/helm/svp-cluster/files/external-secrets.yaml` một Secret ở `svp-secrets` (13 entry từ `.env` và CA local, key đặt tên như `.env`
  hay như file của `.local/ca/`, `local-tls` gồm cả `postgres.crt`, `postgres.key`:
  `pg-superuser`, `pg-roles`, `s3-root`, `s3-users`, `kafka-admin`, `kafka-users`, `valkey-users`, `local-ca`, `local-tls`, `jwt-signing`,
  `jwt-verify`, `web`, `obs`; entry thứ 14 `glitchtip-runtime` tạo rỗng khi chưa có và không bao giờ bị đổi ở đây; entry `argocd-notifications` chỉ khi chart
  bật `externalSecrets.argocdNotifications`, xem [`eks.md`](eks.md)), rồi khi ExternalSecret đã có thì dựng lại từ nguồn mới
  (`force-sync`, chờ `status.syncedResourceVersion` đổi và `Ready`; `es_force_sync` của `deploy/k8s/lib.sh`), các ExternalSecret của
  `svp-data` ở bước (1), các cái còn lại ở bước (3). External Secrets Operator ([ADR-0026](../adr/0026-secrets-gitops.md)) dựng các Secret của chart từ nguồn đó (k3d, gồm `svp-data/pg-tls`); cluster GitOps
  từ revision không có External Secrets thì nhận Secret như đường dev. `k8s-glitchtip-init` ghi DSN vào Secret
  `svp/sentry`, token API chỉ đọc vào `svp-obs/glitchtip-api` và token tải source map vào `svp-obs/glitchtip-sourcemaps`
  (không vào `.env`, không in; cluster có `svp-secrets`: ghi vào nguồn `svp-secrets/glitchtip-runtime` rồi `force-sync` ba
  ExternalSecret đó); `svp/sentry` đổi thì Reloader restart service đọc nó (Secret mới tạo thì không: `reloadOnCreate: false`,
  service nhận ở lần restart sau); idempotent, `k8s-up` tự gọi, không cần `.env`. `k8s-ca` ghi CA của chứng chỉ TLS ra
  `.k8s/ca.crt`.
- `make k8s-images`: build bảy image (sáu từ working tree bằng `docker buildx bake -f deploy/docker-bake.json`, `web` từ thư mục web
  `web_dir` với `SVP_BUILD_ID=dev-<hash nội dung>`) và push lên `127.0.0.1:5111` tag `dev-<image ID>` (đường dev).
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
  gateway, web cần traffic: `make k8s-traffic-start`), script không chờ; `GITOPS_REV` là SHA thì cluster ở yên đó. Đổi credential trên
  cluster này cũng là `make k8s-secrets` (chế độ GitOps ở trên): không bước tay, Reloader restart. Trước khi tạo gì, kiểm ở đúng revision đó cả 7 file `envs/stg/images/`: repository
  `<imagePrefix><svc>` của một nguồn phát hành có `<svc>` trong bảng nguồn ở commit `charts.yaml` của stg, manifest kéo ẩn danh được
  (package GHCR đã public), chữ ký và attestation `vuln` đúng identity của nguồn đó, không CRITICAL, không quá 48 giờ (`deploy/ci/values-check.sh --gitops` trên bản trích `envs/stg` của revision, gọi
  `verify-release.sh --gitops`, bằng `cosign` trên PATH, không có thì `COSIGN_IMAGE`; quá hạn thì in lệnh dispatch rescan), và khi
  `svp-policy` bật provenance cho stg (values của chart ở commit `charts.yaml` rồi `envs/stg/svp-policy.yaml`) thì đúng một
  attestation provenance qua cùng phép kiểm như Kyverno, có `gitCommit` bằng commit trong chứng chỉ của chữ ký
  (`--certificate-github-workflow-sha`; thiếu thì in lệnh dispatch build lại service đó);
  thiếu một điều là dừng, không tạo gì. Rồi tạo namespace (chart `svp-cluster` ở commit `charts.yaml`; overlay stg bật
  `externalSecrets` nên có cả `svp-secrets`) và Secret từ `.env` (chế độ của `make k8s-secrets` ở trên), cài Argo CD theo
  `argocd/bootstrap.json` (chart, version, values `base/argo-cd.yaml`, rồi `platforms/<platform>/argo-cd.yaml` khi revision có file
  đó; namespace `argocd`, PSA `restricted`) với plugin Gateway API
  của Argo Rollouts theo kiến trúc node (`nodeArch` đọc từ node, cluster lẫn kiến trúc thì dừng; bản amd64 ở
  `base/argo-rollouts-amd64.yaml`, cùng file helmfile của đường dev đọc), AppProject `svp` và `default` đã khoá
  (`argocd/project.yaml`), root `svp-root` (`env=stg`, chart `argocd/root` ở commit đã kiểm, render đúng một Application `svp-apps`
  của chart `argocd/apps`; `follow_branch` đổi `targetRevision` của root và value `targetRevision` của nó, revision của `svp-apps`
  khi env không ghim `gitopsRevision`); chờ mọi Application
  (`svp-root`, `svp-apps` và mỗi component) `Synced`, Healthy, sync cuối `Succeeded` (lỗi còn sau
  180 s thì dừng). Hết hạn chờ thì in trạng thái từng Application, tài nguyên chưa Healthy của nó (đọc thẳng từ cluster: Argo CD 3.x
  không ghi health của tài nguyên vào Application; workload theo pod ready, Job, PVC, condition của CR), condition của CR `Prometheus`,
  `Alertmanager`, đuôi log operator của kube-prometheus-stack và sự kiện, rồi dừng. kube-prometheus-stack trong `svp-gitops` có sync
  wave (CRD wave 0, operator 1, CR `Prometheus`/`Alertmanager` 2) vì operator chỉ dò CRD một lần lúc khởi động (lượt 40938235138
  kẹt bootstrap trước khi có wave). Component `external-secrets` của `components.json`
  (External Secrets Operator 2.14.0, namespace `external-secrets`, wave 0, values `base/external-secrets.yaml`: chỉ
  controller, không webhook, không cert-controller) có `gitopsOnly: true`, nên chỉ đường này cài, `make k8s-up` bỏ qua; chart
  `svp-cluster` với overlay k3d của `svp-gitops` render SecretStore `svp-store` (provider `kubernetes`, ServiceAccount `svp-secrets-reader` chỉ
  `get` theo tên đúng các entry namespace đó đọc), mỗi entry của `files/external-secrets.yaml` một ExternalSecret (đếm bằng `helm template` của chart với
  `platforms/k3d/svp-cluster.yaml`, `--show-only templates/external-secrets.yaml`, rồi `grep -c '^kind: ExternalSecret$'`; `refreshPolicy: OnChange`, mọi cái có `target.template`),
  namespace và NetworkPolicy của `svp-secrets`, ValidatingAdmissionPolicy `svp-external-secrets-writes` (controller chỉ ghi Secret
  ở bốn namespace đích, không bao giờ Secret token; ở `argocd` chỉ Secret Opaque `argocd-notifications-secret`, khi chart bật
  `externalSecrets.argocdNotifications`) và `svp-store-serviceaccount-pods`, `-tokens` (ở mọi namespace không pod nào
  chạy dưới `svp-secrets-reader`, không Secret nào giữ token của nó; controller lấy token bằng TokenRequest); overlay prd render
  store `aws` (Secrets Manager `svp/prd/<entry>`, role mỗi namespace, giá trị giữ chỗ tới khi có cluster EKS; controller thêm egress
  TCP 80 chỉ tới agent EKS Pod Identity `169.254.170.23/32`). Số đo cũ trên cluster, khi chart render 28 ExternalSecret: lượt `gitops` 40857855305 (28 ExternalSecret
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
- Diễn tập trên cluster là test Chainsaw ở `deploy/k8s/drills/<diễn tập>/` (nhãn `drill=<diễn tập>`, config chung `.chainsaw.yaml`,
  StepTemplate chung ở `templates/`). `make drill-k8s-threats`, `drill-k8s-supplychain`, `drill-k8s-gitops`, `drill-k8s-reloader` gọi
  `deploy/k8s/drills/run.sh <diễn tập>`: kiểm context trước (`SVP_KUBE_CONTEXT` trống hay `k3d-svp`, kubeconfig có context `k3d-svp`, API
  trả lời; sai thì dừng, không gọi cluster nào khác), rồi một lần `chainsaw test --kube-context k3d-svp --parallel 1` cho đúng một diễn tập
  (hai diễn tập không bao giờ chạy cùng lúc). Output vào `.k8s/drills/<diễn tập>-<UTC>.log`, report JUnit `.k8s/drills/<diễn tập>-<UTC>.xml`;
  target đỏ khi một test đỏ, không có report, hay số test trong report khác số test của thư mục (trừ test được bỏ có dòng `skip`).
  Chainsaw không SKIP lúc chạy: một ca SKIP là bước xanh có dòng `SKIP` kèm lý do trong log. Test chạy `script` dùng kubeconfig
  của người gọi và ghi `--context k3d-svp`. Kiểm tĩnh: `make chainsaw-lint`; glue: `deploy/k8s/drills/run-test.sh`.
- `make k8s-smoke`, `make drill-k8s-threats`: trên cluster đang chạy, qua Envoy với `.k8s/ca.crt` (thiếu thì chạy `make k8s-ca`;
  `k8s-smoke` dùng `deploy/compose/smoke.sh`, `drill-k8s-threats` chạy sau nó trên cùng cluster, mỗi mục một test ở
  `deploy/k8s/drills/threats/<ID>/`, ID threat model viết thường). Lần lượt: luồng đầu-cuối như `make smoke`;
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
  `argocd` và Secret token ở `svp` bị `svp-external-secrets-writes` từ chối (đối chứng: Opaque ở `svp` qua; cluster có ExternalSecret
  `argocd/argocd-notifications-secret` thêm: Opaque tên đó qua, Secret token tên đó và Opaque tên khác ở `argocd` bị từ chối, message
  nêu Secret duy nhất được ghi ở đó; không có thì một dòng `info`), quyền đọc mọi Secret
  của controller in thành ngoại lệ SEC-5 kèm lý do, không webhook của ESO, pod thử không mở được cổng metrics 8080 của controller;
  không ServiceAccount nào của `svp` tạo được ExternalSecret hay SecretStore, ClusterRole `view`/`edit`/`admin` không cấp gì trên
  `external-secrets.io`; mục `SEC-6-reader`, cùng điều kiện: dry run ở `svp-data` (namespace có `svp-secrets-reader`), pod chạy dưới
  ServiceAccount đó và Secret token của nó bị `svp-store-serviceaccount-pods`, `-tokens` từ chối đúng message, đối chứng cùng pod với
  `default` và Secret token của `default` được nhận; trên cluster không có External Secrets Operator hai test nhãn
  `requires=external-secrets` bị bỏ, mỗi test một dòng `skip`). `run.sh` đọc trước các giá trị Secret mà test dùng (7 user Kafka, `svp-feed-service` của Valkey, admin
  Grafana, 3 user object store; vào file quyền 600, xoá khi thoát, không bao giờ trên dòng lệnh; dưới 12 giá trị thì đỏ trước Chainsaw), dòng
  output chứa một giá trị không in ra terminal, rồi dò log và report: dòng nào chứa giá trị là đỏ, chỉ in số dòng. **LOCAL LAB ONLY:** cả hai target xoá khoá `svp:gw:rl:register:*` ở
  Valkey db 10 của cluster (qua `kubectl exec`). Các diễn tập đo một lần (KEDA và RAM, PDB, canary của gateway và của web, backup và PITR,
  `measure-canary`, `measure-gitops`, `drill-k8s-web-obs`) là bài lab `drills/` của `svp-labs`
  ([ADR-0039](../adr/0039-mainpath-drills-scan-gate-sourcemaps.md) §1); quy trình khôi phục Postgres bằng tay ở
  [`postgres-restore.md`](../runbooks/postgres-restore.md).
- `make drill-k8s-supplychain [SUPPLYCHAIN_UNSIGNED=<digest GHCR>] [SUPPLYCHAIN_VULNERABLE=<digest GHCR>]
  [SUPPLYCHAIN_NO_PROVENANCE=<digest GHCR>|none] [SUPPLYCHAIN_ENFORCE_TMP=1]` (mỗi ca một test ở `deploy/k8s/drills/supplychain/case-<chữ>/`;
  bốn biến thành values Chainsaw `unsigned`, `vulnerable`, `noProvenance`, `enforceTmp`; ảnh `drill-unsigned`, `drill-no-provenance` không
  truyền thì `run.sh` tra trên GHCR một lần cho mọi ca, tra lỗi thì để trống và in lý do; `vulnerable` không bao giờ tự tra;
  ba biến digest nhận `<imagePrefix><tên>@sha256:…` với `<tên>` thuộc `services` hay `drillImages` của nguồn có prefix đó, như phép 1
  của policy, cosign đọc bằng identity của nguồn có prefix đó như Kyverno chọn attestor): policy Kyverno của `svp`, mỗi ca
  một dòng PASS/FAIL/SKIP và chỉ PASS khi đúng message của rule cần từ chối; pod gửi bằng `--dry-run=server` (trừ ca b là
  Deployment thật, xoá sau). Ca: (a) bản phát hành đã ký, sạch được nhận, hai lần liền (lần hai từ cache); (b)
  `drill-unsigned` bị từ chối vì thiếu chữ ký (mặc định tự lấy digest mới nhất của `<imagePrefix của backend>drill-unsigned`,
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
  off"; mặc định tự lấy digest mới nhất của `<imagePrefix của backend>drill-no-provenance` (ẩn danh),
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
  nguồn khác `backend` mà pod `svp` chạy được nhận (chưa có thì SKIP). Đường dev là Audit nên diễn tập từ chối chạy trừ
  khi `SUPPLYCHAIN_ENFORCE_TMP=1`: chạy (k) trước mọi ca khác, mỗi ca còn lại nâng tạm `svp-policy` lên Enforce rồi trả Audit; trên
  đường dev chưa có image ký nên (a), (c), (f) và nửa nhận của (h) SKIP. Trên cluster GitOps (lượt 40954609229, nhánh PR-B):
  a–i và (l) PASS, (l) đúng message của phép provenance, (k) SKIP như thiết kế. Khi kết thúc mỗi test trả Kyverno, Argo CD sync, Audit về như cũ, xoá policy tạm, `svp-probe`, và so
  webhook với ảnh chụp đầu của nó; log và report JUnit `.k8s/drills/supplychain-<UTC>.log`, `.xml`. Không gọi API của gateway, không xoá
  khoá rate limit nào.
- `make drill-k8s-gitops`: các kiểm của cluster GitOps (`make k8s-gitops-up`), mỗi kiểm một test ở `deploy/k8s/drills/gitops/`; log và
  report JUnit `.k8s/drills/gitops-<UTC>.log`, `.xml`.
- `make drill-k8s-reloader`: xoay credential thật trên cluster dev hay GitOps (test `deploy/k8s/drills/reloader/rotate/`, cần
  `make k8s-smoke` chạy trước trên cùng cluster). Ghi giá trị mới vào `.env` (mật khẩu root object store, `svp-admin` của Kafka, role app
  Postgres của `video-service` và GlitchTip, user Kafka của `feed-service` và KEDA, admin Grafana, thêm một khoá verify của
  `tools/jwtkey` sau các khoá của `JWT_VERIFY_KEYS`, khoá Server Action của web), chạy `make k8s-secrets` một lần, rồi kiểm: Secret của
  mỗi giá trị có version mới; mỗi workload đọc Secret đổi (bảng "Secret → workload" ở `reloader.sh` của test) chỉ còn pod mới, Ready
  đủ replica, trong 300 s mỗi workload; workload khác không có pod mới; Rollout `gateway`, `web` giữ revision; Job init của `svp-data`
  chạy lại và `Succeeded`; mỗi giá trị một phép chức năng: giá trị mới được nhận, giá trị cũ bị từ chối khi kiểm được từ ngoài (bảng
  phép kiểm theo loại giá trị ở đầu test); rồi `make k8s-secrets` lần nữa với cùng `.env` không đổi Secret nào (trừ bản ghi release
  của Helm), không thay pod nào, Job init vẫn chạy và `Succeeded`; cuối cùng `make k8s-smoke` xanh. Giá trị mới ở lại `.env` (lượt đỏ
  giữa chừng: sửa nguyên nhân rồi `make k8s-secrets`); khoá verify thêm vào ở lại `JWT_VERIFY_KEYS`, khoá riêng của nó mất cùng diễn
  tập. Giá trị mới do `deploy/k8s/drills/reloader/new-values.sh` sinh, hay đọc từ file `SVP_DRILL_NEW_VALUES` (mode 600; bắt buộc
  trên GitHub Actions, nơi bước trước đã mask chúng); `run.sh` tìm giá trị cũ, mới và token API GlitchTip trong log và report. Log
  và report JUnit `.k8s/drills/reloader-<UTC>.log`, `.xml`. **LOCAL LAB ONLY:** `make k8s-smoke` cuối xoá khoá rate limit đăng ký ở
  Valkey db 10 của cluster.
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

## Cách các script của cluster làm việc

Phần này ghi vì sao các hàm và script ở `deploy/k8s/` làm như vậy; lệnh `make` và hành vi theo từng target ở mục trên. Thiết kế của chart ở
[`deployment.md`](../explanation/deployment.md#chart-helm-của-project).

### Tạo cluster và hàm dùng chung của `lib.sh`

- **File cấu hình API server là mount.** Mount là file trên máy ở đường mà cluster đã được tạo từ đó, và API server đọc lại nó mỗi lần node
  khởi động: mỗi `k3d cluster start`, và khi Docker tự khởi động node (restart policy `unless-stopped`, ví dụ sau khi Docker hay laptop khởi
  động lại), nên cluster đang chạy cũng được kiểm. Repo bị dời hay đổi tên, hay checkout không có file: Docker tạo một thư mục rỗng ở đường
  cũ, mount nó, và API server không bao giờ lên (`k3d cluster start` chỉ hết hạn sau 300 giây). File ở đó mà khác file của repo này thì sẽ
  bị đọc mà không kiểm. Cả hai trường hợp cluster được tạo lại từ checkout này; bản clone khác có cùng nội dung thì không sao.
- **Vì sao có `pod-security-admission.yaml`.** Namespace của lab đã mang nhãn Pod Security; file đặt `restricted` cho phần còn lại
  (`default`, `kube-public`, `kube-node-lease`, namespace tạo sau), nơi một controller được tạo pod ở mọi namespace (role của ACME solver của
  cert-manager) có thể khởi động pod đặc quyền có `hostPath` của node, tức root trên node, nơi giữ kubeconfig admin của k3s. File mount chỉ
  đọc vào node server bởi `deploy/k8s/k3d.yaml` và truyền cho API server bằng `--kube-apiserver-arg=admission-control-config-file` (k3s
  không có cờ PSA riêng và không ghi file như vậy). API server chỉ đọc lúc khởi động: thay đổi có hiệu lực ở cluster mới (`make k8s-down
  && make k8s-up`).
- **Đua địa chỉ với registry** (k3d v5.9.0). K3d dành địa chỉ trống đầu tiên của network cho container tools của nó chỉ trong bộ nhớ, trong
  khi Docker trao chính địa chỉ đó cho registry đang chạy khi k3d nối nó; node server khi đó có thể nhận địa chỉ mà container tools lấy ngay
  sau (luôn xảy ra khi image của nó còn đang kéo) và không khởi động được với "Address already in use" (`ClusterPrepNetwork` và
  `ClusterRun` trong `pkg/client/cluster.go`). Vì vậy registry được nối khi đang dừng: nó chỉ nhận địa chỉ khi khởi động lại, sau khi các
  node đã có địa chỉ. Cùng cuộc đua khi khởi động lại cluster có sẵn (`GatherEnvironmentInfo` và `GetHostIP`): trước khi khởi động node, k3d
  tạo lại container tools với địa chỉ trống đầu tiên của network, mà registry đang chạy có thể đang giữ, nên container tools lấy địa chỉ
  cố định của node server và server lỗi "Address already in use"; registry dừng trong lúc đó và khởi động sau các node.
- **Tạo cluster lỗi.** Khi lỗi, kể cả timeout, k3d xoá cái đã tạo (rollback), cả network `k3d-svp`; registry đã dừng vẫn nêu network đó và
  không bao giờ khởi động lại được ("network k3d-svp not found"), nên nó được gỡ khỏi network trước (lỗi chỉ có nghĩa k3d đã gỡ rồi). Lần
  chạy sau khi đó bắt đầu sạch. Một bước không có hạn: k3d tạo container tools của nó (kéo `k3d-tools` khi thiếu) trên một context không có
  `--timeout`, nên một lần kéo treo giữ lệnh này chờ. Lệnh không bị kill từ ngoài: k3d sẽ dừng giữa chừng mà không rollback, để lại một
  cluster dở dang khó dọn hơn một lần treo mà người dùng thấy. Khi treo: Ctrl-C, rồi `make k8s-down` và `make k8s-up`.
- **`secret NAMESPACE NAME TYPE KEY=VALUE...`** in một manifest Secret, kèm nhãn trong `$label` (`"key: value"`) khi lời gọi đặt nó
  (`label=... secret ...`). Giá trị được base64 qua pipe; không giá trị nào là đối số của chương trình nào. Dành cho `kc apply
  --server-side -f -` qua stdin: không giá trị nào qua file hay dòng lệnh, và apply server-side giữ chúng ngoài annotation
  `last-applied-configuration` mà apply phía client sẽ chép chúng vào. Giá trị rỗng được ghi `""` nên key của nó vẫn có: một ExternalSecret
  gọi tên nó nếu không sẽ lỗi vì key không tồn tại.
- **`es_force_sync [NAMESPACE/NAME...]`** làm External Secrets Operator dựng lại các ExternalSecret NAME (mọi ExternalSecret của cluster khi
  không nêu) từ store của chúng, và chờ tới 120 giây cho tới khi từng cái xong. `refreshPolicy` của chúng là `OnChange` (chart
  `svp-cluster`, `templates/external-secrets.yaml`): nguồn đổi chỉ tới Secret qua một thay đổi của ExternalSecret, ở đây là giá trị mới của
  annotation `force-sync`. ESO khi đó sync một lần và ghi `status.syncedResourceVersion` (`<generation>-<hash của nhãn và annotation>`), mới
  cùng annotation, ngay khi lần sync thành công, dù Secret nó dựng có khác cái đang có hay không: Secret không đổi được giữ nguyên (không
  `resourceVersion` mới, nên không pod nào restart vì nó). Chờ một `resourceVersion` mới của mọi Secret sẽ treo ở mỗi cái mà giá trị không
  đổi. ExternalSecret có generation đổi trong lúc đó (Argo CD áp revision khác) dừng việc chờ, vì lần sync thấy có thể là của spec đó;
  cái đã biến mất cũng vậy. Không in gì ngoài lỗi: `reason` và `message` của condition `Ready` của từng ExternalSecret chưa xong, mà ESO
  giữ ở mức an toàn để hiện.
- **Giá trị `.env` thành Secret** dùng chung bởi `secrets.sh` (cluster lab) và `aws-secrets.sh` (entry của AWS Secrets Manager của cluster
  EKS). Caller nạp `deploy/observability/glitchtip/dotenv.sh`, luật chặt mà chúng được đọc theo. `dotenv_read FILE VAR...` đọc mỗi VAR của
  FILE vào biến shell cùng tên, và tên những cái thiếu hay rỗng vào `dotenv_missing` (dấu cách đứng đầu, rỗng khi không có); fail với FILE
  vi phạm luật, và `dotenv_value` khi đó đã nêu dòng sai (không bao giờ giá trị) trên stderr.
  - `check_next_key`: `NEXT_SERVER_ACTIONS_ENCRYPTION_KEY`, như `dotenv_read` đọc. Next giải mã khoá Server Action bằng `atob` và nhập nó
    làm khoá AES-GCM thô lần đầu một action cần; `make env` ghi 32 byte (AES-256) base64 chuẩn. Giá trị sửa thành dạng khác thì script dừng
    ở đây, thay vì lỗi ở pod web sau đó, ở một request nào đó. Kiểm trên text, không trên cái `base64 -d` tạo ra: `base64 -d` của macOS cũng
    giải mã bảng chữ URL-safe (`-` và `_`), mà `atob` ném lỗi.
  - `check_notify_key FILE AGAIN`: đọc GitHub App của Argo CD Notifications (nó ghi commit status trên `svp-gitops`) từ `.env` FILE vào
    `SVP_ARGOCD_NOTIFY_APP_ID`, `SVP_ARGOCD_NOTIFY_INSTALLATION_ID` và `SVP_ARGOCD_NOTIFY_PRIVATE_KEY_B64`, và kiểm chúng; khi lỗi, message
    nêu AGAIN, lệnh chạy lại khi `.env` đã sửa (`make env` không tạo được khoá của GitHub App nên không ghi biến nào trong số đó). Id là số
    nguyên; khoá riêng là base64 chuẩn của file PEM trên một dòng, mà ExternalSecret giải mã. Các phép kiểm đọc giá trị mà không in.
  - `kafka_admin`: Kafka giữ credential SCRAM của `svp-admin` trong metadata của chính broker: `broker.sh` ghi nó một lần, lúc format volume
    rỗng từ Secret `kafka-admin`, và không bao giờ đọc Secret đó nữa. Mọi thứ đăng nhập `svp-admin` (Job `kafka-init`, CLI vận hành của
    `svp-ops`) lấy mật khẩu từ Secret khi khởi động, nên mật khẩu đổi chỉ ở Secret (hay nguồn của nó) sẽ khoá tất cả ngay khi chúng
    khởi động lại. Hàm đặt mật khẩu `.env` (`SVP_KAFKA_ADMIN_PASSWORD`) cho `svp-admin` vào broker trước khi Secret hay nguồn của nó được ghi:
    bước đầu của một lần đổi secret trên cluster lab (`secrets.sh`). Nó chạy `svp-kafka` của Deployment `svp-ops` (container `kafka`): đăng
    nhập bằng mật khẩu `.env`; khi lỗi thì bằng mật khẩu của Secret `kafka-admin`, rồi bằng mật khẩu mà `svp-ops` đang chạy, rồi đặt mật khẩu
    mới bằng `kafka-configs` và chờ đăng nhập được với nó (broker áp credential qua metadata log, chậm một nhịp). Chưa có volume `data-kafka-0`
    thì bỏ qua (broker sẽ format với Secret vừa ghi). Nó dừng script, trước khi ghi gì, khi mật khẩu đổi mà `kafka-0` hay `svp-ops` không chạy
    để nhận; message nêu `$again`, lệnh chạy lại script. Mật khẩu vào container qua stdin; mật khẩu mới nằm trong file mode 600 của container
    đó (không trên dòng lệnh). Trên EKS không có hàm này: `svp-admin` là secret `AmazonMSK_*` do Terraform sinh và gắn vào MSK (`eks.md`).
- **Root Application `argocd_root_app REPO_URL REVISION ENV CHART_REPO_URL`** in `svp-root` của đường GitOps dạng JSON cho `kc apply -f -`.
  Root của cluster EKS là cùng Application đó, do bootstrap của repo hạ tầng (một ApplicationSet trên Secret của cluster) tạo, ở
  `refs/heads/main`. Nó dựng bằng jq từ các giá trị `--arg`, nên revision và môi trường luôn là chuỗi JSON: một nhánh tên `2026`, `true`
  hay `1e3` viết vào YAML nguyên văn sẽ bị đọc là số hay boolean, mà CRD Application từ chối (`targetRevision` là chuỗi). REVISION là ref
  đầy đủ hay commit, không bao giờ tên ngắn (lý do ở mục `make k8s-gitops-up`: tên ngắn có thể phân giải sang tag cùng tên; Argo CD fetch
  mọi nhánh và tag, nên một tag tên `main` đẩy lên bằng token bị đánh cắp có thể được triển khai).
  - Nhãn `svp.io/notify=root` là cái mà các subscription của Argo CD Notifications chọn (`platforms/eks/argo-cd.yaml` của `svp-gitops`):
    chỉ root báo, một commit status `argocd/ENV` mỗi commit của `svp-gitops` cho cả môi trường. Nơi notifications tắt (k3d), nhãn chọn
    không gì.
  - Root so sánh bằng diff mặc định của Argo CD, không bằng server-side diff mà controller dùng cho mọi Application khác
    (`base/argo-cd.yaml` của `svp-gitops`): root áp các Application con phía client (không `ServerSideApply=true`), nên field của chúng
    thuộc một field manager có operation `Update`. Dry run server-side là một `Apply`, không bao giờ xoá field mà entry manager khác sở
    hữu: field bị xoá khỏi chart `argocd/root` (một `ignoreDifferences`, khối `retry`, `managedNamespaceMetadata`) sẽ ở lại trong
    Application dự đoán lẫn Application đang chạy, nên root vẫn `Synced` và con giữ field mãi. Diff mặc định so với annotation
    `kubectl.kubernetes.io/last-applied-configuration` của một apply phía client và thấy việc xoá. Các con áp object của chúng server-side
    (`ServerSideApply=true`), cho thứ mà server-side diff là đúng.
- **Báo cáo khi release không sẵn sàng.** `log_tail_namespaces` là các namespace mà log container được `unready_report` in, và là các namespace
  duy nhất mà dòng log được `deploy/ci/verify-collect.sh` giữ trong artifact công khai (và log job) của một lượt kiểm chứng: server của bên
  thứ ba, operator và controller, mà log nói về lần khởi động, cấu hình và peer của chúng (lỗi bộ nhớ của broker làm nó dừng, lỗi reconcile của
  một operator). Bỏ ra: `svp` (service của project, log có thể giữ dữ liệu người dùng),
  `envoy-gateway-system` (access log của Envoy proxy giữ path và query string của request, gồm chữ ký của upload presigned), `kube-system`
  và `argocd`. Trong số này, `unready_report` còn bỏ GlitchTip (access log giữ khoá công khai của DSN, lỗi của nó giữ event đã nhận) và
  mọi pod Postgres của CloudNativePG (một dòng lỗi trích câu lệnh đã lỗi, gồm giá trị).
  - `mark_log NAMESPACE < LOG` in từng dòng của LOG dạng `[NAMESPACE] LINE` (thụt bốn dấu cách), dạng mà `verify-collect.sh` dùng để nhận biết một log
    container được trích, và chỉ giữ cho các namespace của `log_tail_namespaces`: dòng không đánh dấu (panic của một service, không là
    record JSON) sẽ tới artifact công khai của một lượt kiểm chứng. Mọi dòng được đánh dấu bất kể byte (`LC_ALL=C`: `sed` từ chối byte
    không phải UTF-8 dưới locale UTF-8), dòng cuối kết thúc bằng newline dù LOG không (nếu không dòng in sau sẽ dính vào nó), và LOG rỗng
    không in gì.
  - `unready_report NAMESPACE`, sau một release không sẵn sàng, in ra stderr mỗi container của NAMESPACE chưa ready và mỗi init container
    chưa thoát 0: trạng thái, lần thử cuối kết thúc ra sao, và, với container mà log được phép hiện, các dòng cuối của log, và của lần thử
    trước khi nó đã restart. Helm chỉ nói "1 pods have failed", và kubelet chỉ giữ log của lần thử hiện tại và lần trước, nên container
    crash mỗi lần khởi động biến mất cùng lý do khi cluster mất: một lượt kiểm chứng trên máy bị vứt ngay sau đó không còn gì khác để hiện.
    Pod đã hoàn thành (Job) bị bỏ. Message của lần thử cuối cũng là một đuôi log khi `terminationMessagePolicy` của container là
    `FallbackToLogsOnError`, nên chỉ in ở nơi log được phép.
  - `gitops_timeout_report APPS`, khi việc chờ các Application của đường GitOps (APPS, mỗi dòng một tên) hết hạn, in ra stderr cái mà dòng
    trạng thái của Argo CD bỏ sót, để lượt chạy trên máy bị vứt ngay sau đó vẫn cho thấy vì sao: (a) mỗi Application của APPS chưa Healthy,
    và mỗi tài nguyên nó theo dõi chưa sẵn sàng, đọc từ cluster: Argo CD 3 giữ health của tài nguyên của một Application ngoài Application
    (trong cache riêng, trừ khi controller chạy với `--persist-resource-health`), và API của nó cần đăng nhập. Chỉ các kind của
    `health_kinds` được đọc, mỗi kind được phán bằng một luật gần với kiểm tra của Argo CD cho nó: Deployment, StatefulSet hay DaemonSet
    theo pod ready và updated và generation nó đã quan sát; Job theo condition `Complete` và `Failed`; PersistentVolumeClaim theo phase;
    kind khác theo các condition nói nó sẵn sàng (`Ready`, `Available`, ...) khi chúng không `True`, hay theo việc không có status nào. Cái
    không có là "missing"; (b) CRD của object Prometheus và Alertmanager, lúc chúng được tạo và lúc chúng `Established`; (c) condition của
    mọi object Prometheus và Alertmanager, hay việc nó không có condition: chưa controller nào reconcile nó; (d) mỗi container của pod
    Prometheus operator ở `svp-obs` (nhãn `app.kubernetes.io/component` của chart `kube-prometheus-stack`): lúc nó khởi động, và các dòng
    cuối của log, và của lần thử trước khi nó đã restart, đánh dấu như `unready_report`. Operator hỏi API server một lần, lúc khởi động,
    những CRD nào của nó được phục vụ, và không bao giờ khởi động controller của CRD đã thiếu lúc đó (nó log cảnh báo "resource ... not
    installed in the cluster"): một object Prometheus khi đó không bao giờ thành StatefulSet, không có event. Không gì ở đây đọc Secret.
    Mỗi bước không đọc được cluster in lý do và các bước khác vẫn chạy.
- **Bảng image `deploy/docker-bake.json`** là nơi duy nhất nêu các image mà repo này build từ cây của nó: sáu service Go mà CI của nó build, ký
  và promote (`web` là một trong bảy bản phát hành, nhưng nguồn và bản phát hành của nó là của `svp-frontend`). Nó là file Docker Bake: nhóm
  `default` liệt kê service theo thứ tự đường dev build chúng, và target `<service>` giữ Dockerfile, context, build argument và tag cục bộ
  của image, `svp/<service>:dev` (tên mà compose chạy nó). JSON thay vì HCL để script đọc bằng `jq` mà không cần `docker`; nằm dưới
  `deploy/` để test chép `deploy/` có nó. Nó được đọc một lần, khi `lib.sh` được nạp: `built_services`, `svp_services` và `dockerfile` trả
  lời từ nó, cho pipeline image của CI (`deploy/ci/plan.sh`, `changed-services.sh`, `image-guard.sh`, đưa action `image-leg` Dockerfile và
  context của nó) cũng như cho `make k8s-images`, `make k8s-up` và `make up` (`build_dev_images`, `compose_images`). Mọi context là gốc repo
  (`.`): bản build CI (`image-guard.sh`) và `image_paths` giả định điều đó, nên bảng có context khác dừng ở đây thay vì bị build theo hai
  cách. Bảng thiếu, không là JSON, hay nêu service không có target, Dockerfile hay context đó cũng làm script nạp nó dừng ở đây.
- **Tag của image dev.** `build_dev_images [SERVICE...]` (mặc định bảy cái của `svp_services`) build image từ working tree, những cái của
  bảng image bằng `bake_images`, `web` từ bản clone của `svp-frontend` (`build_web_image`), đẩy mỗi cái lên registry dưới dạng
  `127.0.0.1:5111/svp/<service>:dev-<12 hex đầu của image ID>`, và đặt `dev_tag_<service>` (với `-` của tên đổi thành `_`) thành tag đó; chạy sau
  `ensure_registry`. Build cache cho cùng image ID với cùng đầu vào, nên lượt chạy không đổi code cho cùng tag, pod template không đổi, và
  không ReplicaSet mới khởi động (và với release có canary, không canary nào). `web_build_id` in build id của image web ở đường dev (`SVP_BUILD_ID`, mà Next dùng làm
  `deploymentId` và server làm tên release): `dev-` và 12 chữ số hex đầu của SHA-256 của danh sách `<SHA-256 của nội dung> <đường>`, sắp
  theo đường, của mọi file mà context build `web_dir` gửi (theo `.dockerignore` của nó, không theo git: file `.DS_Store` mà git bỏ qua có
  tính, file được theo dõi mà `.dockerignore` loại thì không) cộng Dockerfile (`web_dockerfile`), mỗi đường tương đối với bản clone. Cùng
  context cho cùng id, nên build cache cho cùng image ID; mọi thay đổi của context cho id mới, nên hai bản build khác nhau không bao giờ
  chung một `deploymentId` qua file mà git không thấy. Symlink tính theo đường nó trỏ tới (context gửi nó nguyên dạng); mode của file
  không tính. Chỉ dạng mà `.dockerignore` của bản clone có được hiểu: mỗi dòng (trừ dòng trống và comment `#`) là mẫu tên một cấp gồm chữ,
  số, `.` `_` `-` `*` và `?`, mà như trong Docker chỉ khớp tên ở gốc context và loại cả cây của nó. Dòng khác thì fail và nêu tên nó, thay vì
  lệch khỏi cái Docker gửi mà không ai biết; dạng mới nghĩa là dạy hàm này cùng luật đó trong cùng thay đổi.

### Cài đặt: `install.sh`, `gitops.sh`, helmfile

- **`rollouts_plugin_check`.** Plugin traffic router Gateway API của Argo Rollouts là binary native, mà controller tải khi khởi động và thực
  thi ở lần reconcile đầu của một Rollout có canary. `base/argo-rollouts.yaml` ghim asset `linux-arm64`, cho node của một Mac; trên node
  amd64 (host Linux x86_64, như runner CI) binary đó không chạy được: controller lỗi khi khởi động plugin ở mọi lần reconcile, trước khi
  scale ReplicaSet của Rollout, nên gateway không bao giờ có pod. Ở đó file `archValues` mà `components.json` nêu cho amd64 được đọc sau nó,
  như đường GitOps, và thay plugin bằng asset của cùng bản phát hành build cho amd64. Hai file phải nêu cùng một bản phát hành, để bản
  phát hành mới không cập nhật một chỗ ghim mà bỏ chỗ kia: mỗi file giữ đúng một vị trí plugin, và các vị trí chỉ khác tên asset.
- **Theo dõi Job `migrate`.** Job `migrate` của chart `svp-service` restart container trong một pod (`restartPolicy: OnFailure`, xem chart), và
  khi Job lỗi, Job controller xoá pod đó cùng log của nó: Helm khi đó chỉ báo `BackoffLimitExceeded`. `watch_migrate NAMESPACE JOB OLD_UID
  LOG HELMFILE` chạy nền từ hook presync của release của một service trong lúc nó cài, và chép log của lần thử lỗi mới nhất của Job vào
  LOG mỗi 2 giây, khi pod còn đó; OLD_UID là Job của lượt trước, mà Helm thay, không được đọc. Nó kết thúc khi hook postsync dừng nó, hay
  khi tiến trình HELMFILE (helmfile, cha của các hook) đã hết.
- **`wait_rollout NAMESPACE NAME`.** Khi controller đã thấy generation hiện tại của Rollout, chờ tới khi nó `Healthy`: ngay lập tức khi
  upgrade không tạo revision mới (hay revision mà template là stable lại), không thì sau các bước của canary (25%, 60 giây, 50%, 60 giây,
  100%) cùng analysis nền, khoảng 3 phút. Fail khi canary bị abort (AnalysisRun của nó lỗi, hay một bước quá progress deadline) hay bị tạm
  dừng bởi AnalysisRun inconclusive, mà không bao giờ tự promote, và nêu AnalysisRun; cũng fail sau 900 giây, quá progress deadline 600
  giây. Mỗi lần lỗi trước hết in cách thoát (`way_out`). Dòng tiến trình và lần abort nêu AnalysisRun nền; lần tạm dừng inconclusive nêu
  run đang Inconclusive, của bước gate (`currentStepAnalysisRunStatus`) hay của nền, vì cả hai đều làm Rollout tạm dừng.
- **`pg_base_backup`**, sau chart `svp-data`, đảm bảo Postgres `svp-pg` archive WAL và thế hệ archive của nó có backup cơ sở để phục hồi.
  Trên cluster mới ScheduledBackup `svp-pg-daily` chụp bản đầu ngay (`immediate`; hook của chart, sau khi Job `s3-init` tạo bucket
  `pg-backups` và login của nó). Nhưng ở upgrade thêm plugin vào Cluster dựng trước nó, CloudNativePG khởi động Backup đó trên primary nào
  đang Ready, có thể vẫn là pod cũ, không có sidecar của plugin: Backup khi đó lỗi vĩnh viễn (CloudNativePG không bao giờ thử lại một
  Backup; lần chạy tiếp theo của lịch là 03:00 UTC). Vậy khi primary đã chạy sidecar và không Backup nào của `svp-pg` đang chạy, một thế hệ
  chưa có backup cơ sở thành công trong status của ObjectStore `svp-pg-backup` nhận một bản ở đây. Rồi WAL archiving phải chạy (condition
  `ContinuousArchiving`, mà WAL switch của một backup cơ sở đặt chậm nhất).
- **Traffic diễn tập lúc cài.** Gateway và web client là Rollout của Argo Rollouts: upgrade đổi pod template (code mới, hay giá trị mà một
  diễn tập để lại trong release) là revision mới, ra như canary chỉ khi Envoy đã đo đủ response của nó. Nên khi Rollout như vậy tồn tại và
  có canary phía trước (`canary_ahead`), traffic diễn tập (`deploy/k8s/drills/traffic.sh`, request cả hai) khởi động trước mỗi lượt helmfile
  của các wave sau wave 1 (lượt sau Secret, và trên cluster chưa sẵn sàng cho một lần đổi credential thì lượt trước chúng nữa:
  `sync_later`), mà hook postsync chờ từng Rollout (`wait_rollout`), và dừng khi lượt đó kết thúc, kể cả khi lỗi (cả trap `EXIT`). Upgrade
  không đổi template không tạo revision (tag dev theo image ID) và không khởi động traffic. Traffic đã chạy sẵn (`make k8s-traffic-start`)
  được dùng và để chạy; chỉ pid mà script này khởi động mới bị dừng. `canary_ahead NAMESPACE NAME` sai chỉ khi upgrade sắp tới của release
  NAME render Rollout NAME y hệt revision hiện tại của release và Rollout đó `Healthy`: không canary nào sẽ chạy, nên traffic không được
  khởi động (mỗi lần khởi động đăng ký user và xoá khoá rate limit đăng ký). Rollout khác ở bất kỳ điểm nào, hay đang canary, tạm dừng
  hay bị abort, tính là có canary phía trước, cũng như cái không render hay đọc được. Chart không đọc gì từ cluster, nên `helmfile template`
  của release, với state value mà sync nhận, render đúng cái upgrade sẽ render.
- **`gitops.sh`.** Mọi service được kiểm trước khi script dừng, nên một lượt chạy nêu mọi bản phát hành bị thiếu. `release_image`
  (`deploy/k8s/lib.sh`) đọc file image từ git và hỏi GHCR; `deploy/ci/values-check.sh --gitops` rồi kiểm chữ ký và attestation `vuln` của
  từng bản phát hành ẩn danh, với image `COSIGN_IMAGE` ghim khi cosign chưa cài, và build provenance của nó khi chart `svp-policy` kiểm nó
  ở môi trường này: trên bản sao của riêng `envs/$env` ở revision, nên bản phát hành của các môi trường khác không bị kiểm ở đây. Image
  phát hành, bản cài Argo CD và danh sách Application đến từ git ở đúng một commit đó, không bao giờ từ working tree, và Argo CD cũng dựng
  cluster ở commit đó, không ở nhánh: cái script này kiểm là cái Argo CD triển khai, kể cả khi một bản phát hành tới nhánh trong lúc đó (bản
  đó sẽ ra như canary, mà không traffic nào promote khi cluster còn được dựng). `SVP_ATTEST_MAX_AGE` chỉ cho diễn tập (không bao giờ trong
  `.env`): giới hạn ngắn hơn 48 giờ cho tuổi của attestation `vuln`.
  - Chart `svp-cluster` (wave 1) sở hữu namespace của project, nhưng hai thứ cần chúng sớm hơn: Secret, trước pod đầu tiên đọc một cái
    (wave 2), và Envoy Gateway (wave 0), bind Role ở mỗi namespace nó theo dõi (`base/envoy-gateway.yaml` của `svp-gitops`) và không sync
    được khi thiếu một cái. Nên namespace của values của `svp-cluster` được tạo ở đây từ template của chính nó, cùng nhãn Pod Security,
    như `install.sh`; apply của Argo CD cho `svp-cluster` sau đó thấy chúng nguyên như vậy. Chart là cái stg chạy, ở commit của
    `envs/stg/charts.yaml`, giải nén bằng `git archive` (không đọc working tree lẫn index), nên namespace khớp values Envoy Gateway mà Argo CD
    triển khai. Values của nền tảng và overlay của môi trường cho `svp-cluster`, khi revision có, cũng được đọc, theo thứ tự Argo CD đọc:
    khi `externalSecrets` bật, overlay thêm namespace `svp-secrets`, mà `secrets.sh` điền nguồn của Secret vào.
  - Secret của Argo CD Notifications: ExternalSecret của nó chỉ có khi `externalSecrets` bật và `argocdNotifications` bật (chart trước khoá
    này: tắt), nên `secrets.sh` chỉ khi đó ghi nguồn của nó và đòi biến của nó trong `.env`. Namespace `argocd`, nơi nó ở, được tạo sau,
    trước Argo CD; ExternalSecret tới sau nữa, cùng chart `svp-cluster` (wave 1), mà Argo CD sync khi đã cài. Controller notifications của
    Argo CD đọc Secret của nó mỗi khi nó đổi: không restart.
  - Pod Security `restricted` trên namespace `argocd` trước pod đầu tiên của Argo CD (mọi pod của chart đạt): Namespace của template của
    chart `svp-cluster`, như `install.sh` tạo của wave 0. Nó tồn tại trước helm, nên helm không có `--create-namespace`, mà apply của nó bỏ
    nhãn. Argo CD được cài như `argocd/bootstrap.json` ở revision nêu nó: một object dạng của một component của `components.json`, rồi
    values của nền tảng khi revision có, như `platforms/<platform>/<name>.yaml` của một component đứng sau file `base/` của nó (lớp nền
    tảng là dữ liệu: Argo CD Notifications chỉ ở nơi cluster chạy cả buổi).
  - `app_report` đọc các Application của namespace `argocd` và in một dòng mỗi tên của `$want_apps`: `ready NAME` (`Synced`, `Healthy` và
    sync cuối `Succeeded`: tiêu chí của health check cho Application trong `base/argo-cd.yaml` của `svp-gitops`, nên hook PostSync còn
    chạy hay lỗi thì chưa ready); `wait NAME(S/H/P)` (cái khác, với trạng thái sync, health và phase của sync cuối, `-` khi chưa đặt);
    `missing NAME` (root chưa tạo, wave sau); rồi, sau chúng, một dòng mỗi vấn đề Argo CD báo: `error NAME: ...` (condition có type kết
    thúc bằng `Error`: `ComparisonError` là repo không đọc được, revision hay path không tìm thấy; `InvalidSpecError`; `SyncError`...,
    hay sync `Failed` hay kết thúc `Error` khi hết lượt thử lại) và `retry NAME: ...` (sync lỗi và đang được thử lại, kèm message của
    Argo CD).
  - Mọi Application của `$want_apps` ready trong hạn. DSN của GlitchTip vào Secret `svp/sentry` khi `svp-observability` (wave 5) ready;
    Reloader restart các service (wave 7) đã khởi động trước khi DSN tới Secret `svp/sentry`, những cái khởi động sau thì đọc nó. Argo CD
    thử lại một phép so sánh lỗi ở mỗi lần poll (60 giây), nên lỗi được in khi nó lần đầu hiện, và việc chờ dừng khi lỗi đã được báo 180
    giây không đứt quãng (ba lần poll: không phải một lỗi thoáng qua như một lúc không có GitHub) thay vì chạy hết 1800 giây.
- **`helmfile.yaml.gotmpl`.** Chỉ `base/` của bản clone `svp-gitops` được đọc, không bao giờ `envs/`: đường dev tự build image. Component có
  `gitopsOnly` bị bỏ (Secret của đường dev đến từ `.env` qua `secrets.sh`), cũng như component mà `platforms` loại k3d (controller của
  cloud); không `platforms` nghĩa là mọi nền tảng. Một component là chart upstream (`repo` + `chart` + `version`; kho OCI của Helm viết
  `oci://...`) hay chart của repo này (`path`, đọc từ working tree này), với file values tuỳ chọn tương đối với gốc bản clone.
  `dev_helmfile` của `rotate.sh` chạy từng release một (`--concurrency 1`), điều mà wave của Argo CD không cần nhưng bộ nhớ của máy này cần.
  Release `reloader` cũng `needs` `argo-rollouts`, wave của riêng nó: chart của nó đọc từ cluster xem Rollout có tồn tại không.
  - Root GitOps cũng đọc `platforms/k3d/` của bản clone, file này chỉ `base/`: `base/` được viết cho k3d, cluster của đường dev, nên giá trị
    của k3d vào đó, được cả hai đường đọc. Một file dưới `platforms/k3d/` sẽ làm đường này cài thứ khác với cái Argo CD chạy trên k3d mà
    không ai hay, nên render lỗi với nó, trừ `README.md` và `svp-cluster.yaml` chỉ giữ `externalSecrets`: nguồn của Secret là của riêng
    đường GitOps, như `gitopsOnly` (đường dev áp chúng từ `.env`).
  - State value, do `dev_helmfile` đưa trên dòng lệnh hay trong file tạm, không bao giờ trong file của repo này: `gitopsDir` (bản clone
    `svp-gitops`; bắt buộc), `nodeArch` (`amd64` hay `arm64`, kiến trúc node của cluster `svp`; bắt buộc), `images` (`<release>:
    {repository, tag, digest}` mỗi release của chart `svp-service`: image dev mà `make k8s-up` vừa build, hay bản phát hành web mà
    `web_source` chọn; release thiếu thì lỗi ở lúc render của chart, nêu `image.repository is empty for release ...`) và `pgServerName`
    (thế hệ archive của Cluster `svp-pg` đang chạy, `pg_backup_sets` của `rotate.sh`; không đặt khi Cluster chưa có, nhận mặc định của
    chart).
  - Hook presync và postsync gọi `deploy/k8s/install.sh hook <event> <release> <namespace> <kind> <canaryRoute> <failed>` (`kind` là `service`
    cho release của chart `svp-service`, `component` cho phần còn lại; `failed` khi helm lỗi). Hook lỗi, như release lỗi, dừng helmfile trước
    wave sau, với status khác 0. Cả hai không chạy với `helmfile template`, mà không hỏi cluster nào.

### Secret

- **Secret của service ở `svp`:** một cái mỗi service, mỗi cái chỉ có cái mà pod của service đó dùng, nên một pod bị chiếm không lộ hơn
  credential của chính nó. `<service>-env` vào container của service làm biến môi trường; `<service>-migrate-env` giữ role migrator, chỉ
  cho Job `migrate`. Khoá ký JWT chỉ ở `user-service-env` (threat model JWT-10); gateway và bốn service gRPC nhận khoá công khai, mà xác
  minh access token do gateway chuyển tiếp nhưng không ký được cái nào ([ADR-0042](../adr/0042-caller-identity-grpc.md)). `web-env` giữ
  khoá Server Action của web client, đặt lúc chạy để khoá đang dùng không bao giờ nằm trong image công khai, và `REDIS_URL` của user Valkey
  `svp-web` (db 9, nơi nó giữ session; `gateway-env`, `feed-service-env` cũng mang `REDIS_URL` của user của chúng): các thiết lập khác của nó
  không bí mật (`base/services/web.yaml` của `svp-gitops`), DSN của nó đến từ Secret `sentry`. Secret phải tồn tại trong mọi trường hợp: chart `svp-service` đọc `<release>-env` bằng `envFrom`, không `optional`.
- **Mật khẩu của object store và Postgres.** Object store (RustFS) lấy mật khẩu root từ môi trường lúc khởi động, trong biến mà chart `svp-data`
  ánh xạ Secret `s3-root` tới; nó giữ bucket, user, policy, rule CORS và object khi khởi động với mật khẩu khác, và mật khẩu cũ không đăng
  nhập được nữa (đã kiểm trên image ghim). Valkey chỉ đọc aclfile (Secret `valkey-acl`) lúc khởi động; Kafka đã lấy mật khẩu `svp-admin` của `.env`
  (`kafka_admin`) và không cần restart. Reloader restart object store và Valkey khi Secret của chúng đổi; Job init và client đăng nhập bằng mật
  khẩu mới, nên chúng chờ điều đó. Postgres không cần restart: CloudNativePG tự đặt mật khẩu superuser đã đổi (Secret `pg-superuser` mang nhãn
  `cnpg.io/reload`).
- **`glitchtip-init.sh`.** Ba Secret mà nó ghi là giá trị của riêng GlitchTip, do Job init (`bootstrap.py`) của nó tạo: chúng không bao giờ
  vào `.env`, một file hay terminal; chúng được đọc bên trong pod GlitchTip qua ORM của nó và trở lại trên stdout vào một biến shell mà
  thôi. Secret `svp-obs/glitchtip-sourcemaps` (`SENTRY_SOURCEMAPS_TOKEN`, token API `svp-sourcemaps`: `project:releases`, mà `make
  k8s-web-sourcemaps` dùng) bị bỏ, kèm ghi chú, khi GlitchTip chưa có token đó (revision GitOps mà `bootstrap.py` có trước nó), để DSN vẫn
  tới service. Secret `svp/sentry` (`SENTRY_DSN`, host `glitchtip.svp-obs:8000`) là tham chiếu tuỳ chọn của năm service báo lỗi: tới khi nó
  tồn tại chúng chạy không có; `svp-obs/glitchtip-api` là token API chỉ đọc `svp-drill` (`event:read`, `project:read`). Trên cluster có
  `svp-secrets` giá trị vào `svp-secrets/glitchtip-runtime` (rỗng khi GlitchTip chưa có token đó); trên EKS vào entry
  `svp/<env>/glitchtip-runtime`, ghi bằng `aws_setup` và `aws_put_entry` (giá trị đi qua file mode 700, không bao giờ trên dòng lệnh); ba
  ExternalSecret dựng lại từ đó. Chỉ cần GlitchTip ready (Job init của nó đã chạy).
- **File `external-secrets.yaml` của chart `svp-cluster`** (`deploy/helm/svp-cluster/files/external-secrets.yaml`; `templates/external-secrets.yaml`
  render nó khi `externalSecrets.enabled`): mỗi Secret của đường GitOps một ExternalSecret, cùng tên, namespace, key và type với cái
  `secrets.sh` (25) và `glitchtip-init.sh` (3) áp ở đường dev, và `argocd-notifications-secret` chỉ của đường GitOps; hai danh sách phải khớp
  nhau, và comment của `secrets.sh` nói ai đọc từng Secret. File được Helm đọc bằng `.Files.Get`, nên các template trong đó là của External
  Secrets Operator (Go `text/template` với sprig), không của Helm. Mỗi Secret có:
  - `values`: cái store đọc, `NAME: ENTRY/KEY`, giá trị của key `KEY` của entry `ENTRY` của nguồn (Secret của namespace `svp-secrets` trên
    cluster lab, `svp/<env>/ENTRY` trong AWS Secrets Manager). Các entry nhóm biến của `.env` theo ai cần chúng, để Role (hay IAM policy)
    của store của một namespace chỉ nêu các entry mà namespace đó đọc;
  - `template`: key của Secret, mỗi key là một template trên các NAME của `values` (`.NAME`); `${postgres}` được Helm thay bằng
    `externalSecrets.postgres` trước. Không `template` thì key của Secret là các NAME của `values`, giá trị nguyên;
  - `type`, `labels` của Secret;
  - `inClusterObjectStore`: `true` thì Secret chỉ tồn tại khi object store là `s3` của chart `svp-data` (`s3.mode: cluster`); với store managed
    (`external`) không gì đăng nhập vào nó bằng khoá tĩnh;
  - `inClusterObjectStoreKeys`: các NAME của `values` và key của `template` bị bỏ với store managed: pod lấy credential từ EKS Pod Identity,
    và service từ chối khởi động với khoá tĩnh bên cạnh chúng;
  - `enabledBy`: khoá của `externalSecrets` render Secret: chỉ render khi khoá đó `true` (mặc định tắt), cho Secret mà đường dev không có
    bản tương ứng;
  - `sharedNamespace`: `true` thì namespace thuộc chart khác, mà Secret riêng của nó controller không được ghi; controller chỉ được ghi ở đó
    đúng Secret này, đúng type của nó (ValidatingAdmissionPolicy `svp-external-secrets-writes`).

  Mỗi ExternalSecret có `target.template`, ít nhất là type của nó: không có, ESO chép nhãn và annotation của ExternalSecret lên Secret, gồm
  annotation `force-sync` của `deploy/k8s/lib.sh`, và mỗi lần sync cưỡng bức sẽ cho Secret một `resourceVersion` mới vô ích (Reloader chỉ
  restart khi dữ liệu đổi). Entry `argocd` là Secret của Argo CD Notifications (`externalSecrets.argocdNotifications`), mà key của cấu hình
  service của nó (`$github-appID`...) nêu tên: GitHub App chỉ được ghi commit status trên `svp-gitops`, và bot Telegram của Alertmanager, rỗng
  khi không đặt. Khoá riêng của nó giữ ở base64 trên một dòng trong nguồn (`.env` không nhận giá trị nhiều dòng) và giải mã ở đây. Entry
  nguồn cũng giữ token của bot, nên store của `argocd` không đọc entry nào của `svp-obs`. Chart của Argo CD khi đó không tạo Secret tên đó
  (`notifications.secret.create: false` trong `svp-gitops`).

### Diễn tập và smoke

- **`*-skips.tsv`.** Report JUnit đếm bước SKIP là đạt, nên sau mỗi lần gọi `chainsaw`, danh sách các SKIP vào
  `.k8s/drills/<diễn tập>-skips.tsv`: mỗi dòng `<test><TAB><lý do>` cho mỗi dòng SKIP mà một test in (dòng dạng `SKIP  (<id>) <lý do>` trong
  khối STDOUT của một bước script, đọc từ log của chainsaw trước mọi bộ lọc; `<test>` là test Chainsaw đang chạy lúc đó) và cho mỗi test bị
  bỏ ở trên, rồi `total<TAB><n>`; file có cả khi n là 0, và cả khi chainsaw lỗi. Lý do chứa giá trị Secret của `threats` được thay bằng một
  dòng nói vậy.
- **Template `port-forward.yaml`** dùng như một bước của test cần nó, với các binding khác mặc định:
  `use: {template: ../../templates/port-forward.yaml, with: {bindings: [{name: forwardNamespace, value: svp-obs}, {name: forwardTarget,
  value: service/kps-prometheus}, {name: forwardPort, value: "19090"}, {name: forwardRemotePort, value: "9090"}, {name: forwardReadyPath,
  value: /-/ready}]}}`.
- **Giá trị mới của diễn tập Reloader** (`reloader/new-values.sh FILE`, FILE chưa được tồn tại, mode 600; mỗi dòng `NAME=value`). Mỗi giá trị có
  dạng mà `make env` cho biến của nó (`deploy/compose/compose.mk`): `SVP_S3_ROOT_PASSWORD` 20 byte ngẫu nhiên hex; `SVP_VIDEO_APP_DB_PASSWORD`,
  `SVP_GLITCHTIP_APP_DB_PASSWORD`, `SVP_GRAFANA_ADMIN_PASSWORD` 24 byte ngẫu nhiên hex; `SVP_KAFKA_ADMIN_PASSWORD`,
  `SVP_KAFKA_FEED_SERVICE_PASSWORD`, `SVP_KAFKA_KEDA_PASSWORD` 16 byte ngẫu nhiên hex (32 chữ và số, như Terraform sinh trên EKS);
  `NEXT_SERVER_ACTIONS_ENCRYPTION_KEY` base64 chuẩn của 32 byte ngẫu nhiên;
  `JWT_VERIFY_KEY_NEW` là `<kid>:<khoá công khai>` của một cặp khoá mới của `tools/jwtkey`, mà diễn tập thêm vào `JWT_VERIFY_KEYS` sau các
  khoá có sẵn (khoá ký giữ nguyên); `JWT_DRILL_SIGNING_KEY` là khoá riêng (seed) của cặp đó, mà diễn tập ký một token, không bao giờ vào
  `.env`. Trên GitHub Actions (`GITHUB_ACTIONS=true`) mỗi giá trị và base64 của nó bị mask ngay khi được tạo (dòng `::add-mask::` trên
  stdout, trước khi gì khác đọc giá trị): chạy trong bước mà output là log của job, không bao giờ cái gửi vào file. Nơi khác nó không in gì.
  Không bao giờ `set -x` ở đó: vết sẽ in mọi giá trị.
- **`reloader/rotate/reloader.sh`** là helper của test `reloader-rotate` (`make drill-k8s-reloader`). Mỗi script của test nạp nó từ thư mục của
  test, nơi Chainsaw chạy nó: `. ./reloader.sh`; viết cho bash 3.2 (`/bin/bash` của macOS). Môi trường cần `CALLER_KUBECONFIG` (kubeconfig của
  caller, rỗng là `~/.kube/config`; Chainsaw đặt `KUBECONFIG` thành bản sao cluster của nó, `templates/probe-up.yaml` nêu lý do), và
  `NEW_VALUES`, `OLD_VALUES`, `STATE_DIR`, các giá trị Chainsaw `newValues`, `oldValues` và `stateDir` của `deploy/k8s/drills/run.sh`: file
  giá trị mới và cũ (dòng `NAME=value`, mode 600) và thư mục riêng của test, mà `run.sh` xoá khi diễn tập kết thúc. Giá trị chỉ được đọc từ
  các file đó, không bao giờ từ dòng lệnh; nó rời máy này chỉ trên stdin của `kubectl exec` hay trong file cấu hình `curl` riêng của
  `$STATE_DIR`, xoá ngay; không gì ở đây in một giá trị, hay một token. `kubectl` luôn nêu context `k3d-svp`; `curl` lấy CA của cluster từ
  `CURL_CA_BUNDLE`, do `run.sh` đặt.
- **Bảng "Secret → workload"** của lần đổi credential: mỗi Secret mà thay đổi của nó restart một workload, và workload đó dạng
  Kind/namespace/name. Các Secret nó bỏ ra không restart gì: `pg-superuser` (CloudNativePG tự đặt mật khẩu), đầu vào của Job init của
  `svp-data` (`pg-roles`, `s3-users`, `kafka-users`, `pg-backup-s3`), `<service>-migrate-env` của Job `migrate`, `glitchtip-admin`, và của
  Alertmanager, mà nó đọc từ file. Viết từ bảng, không từ annotation của workload, để workload không opt in sẽ fail.
- **Đặt lại giới hạn đăng ký của smoke** (`reset_register_limit` của `deploy/compose/lib.sh`). **LOCAL LAB ONLY.** Mọi request của các script
  smoke tới gateway từ một địa chỉ bridge Docker, và mọi script đăng ký user mới, nên các lượt chạy trong một giờ dùng hết burst đăng ký
  20 mỗi IP. Hàm xoá các bucket đăng ký (`svp:gw:rl:register:*`) ở db 10 Valkey của gateway bằng `SCAN` + `DEL`, và không khoá nào khác
  (user `svp-ops` không xoá được khoá khác ở db 10); bản thân giới hạn không được nâng. Nó chạy qua CLI vận hành (`valkey_cli` của cùng file,
  `/opt/svp/bin/svp-valkey`), nơi `SVP_STACK` chọn: `compose` (mặc định), container `valkey` của stack compose; `k3d` (`make k8s-smoke`),
  container `valkey` của Deployment `svp-ops` trong cluster `svp`, context `k3d-svp` và không gì khác, vì gateway chạy trong cluster, sau
  Envoy, và đếm trong db 10 Valkey của cluster (Valkey không có địa chỉ trên host); `deploy/compose/smoke.sh` chạy cùng các bước với base
  `https://api.svp.localhost:8443` và `CURL_CA_BUNDLE=.k8s/ca.crt` để `curl` tin CA của cluster cho API lẫn storage. Với `SVP_STACK=eks`
  (`make eks-smoke`, `eks-seed`, `eks-rl-reset`) cùng việc chạy trong container `valkey` của Deployment `svp-ops` ở cluster EKS mà
  `SVP_KUBE_CONTEXT` nêu, `svp-stg` hay `svp-prd` và không gì khác: một cluster lab của project này, không bao giờ cái dùng chung; Valkey ở đó
  là ElastiCache, `svp-ops` nối tới nó bằng TLS với CA công khai của Amazon. `make eks-smoke` dùng base `https://api.<domain>` với chứng chỉ
  công khai (không `CURL_CA_BUNDLE`). Load balancer của EKS giữ địa chỉ của client, nên các lượt chạy từ một máy cũng chung một địa chỉ ở đó,
  và pod của một bài load test có thể nhận địa chỉ của các lượt trước. `SVP_AS_USER=<user>` làm `valkey_cli` đăng nhập user đó (mật khẩu là dòng
  đầu của stdin) để thử quyền của nó.
- **CLI vận hành trên cluster** (Deployment `svp-ops` của chart `svp-data`, namespace `svp-data`, một replica): hai container `kafka` (image
  `apache/kafka`) và `valkey` chạy `sleep infinity`, wrapper ở `/opt/svp/bin` (ConfigMap `svp-ops-bin`); lệnh
  `kubectl --context <ctx> -n svp-data exec deploy/svp-ops -c kafka -- /opt/svp/bin/svp-kafka …` và `-c valkey -- /opt/svp/bin/svp-valkey …`; k3d và
  EKS khác nhau chỉ ở context và giá trị biến (`KAFKA_BROKERS`, `VALKEY_HOST`). Secret `svp-ops` giữ `SVP_KAFKA_ADMIN_PASSWORD` và
  `SVP_VALKEY_OPS_PASSWORD`. Pod chạy PSA restricted, không token ServiceAccount, không Service, egress chỉ tới Kafka 9096 và Valkey 6379.
  Đăng nhập user thường (`SVP_AS_USER`): mật khẩu lấy từ Secret của chính client đó (`svp/<service>-env` khoá `KAFKA_SASL_PASSWORD` hay phần mật
  khẩu của `REDIS_URL`, `keda/keda-kafka`, `svp-obs/otelcol-kafka`) và đưa qua stdin của `kubectl exec -i`, không trên dòng lệnh.

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
