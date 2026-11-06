# Architecture Decision Records

ADR là **nhật ký lý do** của repo, theo ý của Michael Nygard ("Documenting Architecture Decisions", 2011) và mẫu MADR 4: mỗi
ADR ghi một quyết định, bối cảnh lúc quyết, các phương án đã cân nhắc và cái giá phải trả, để người đọc sau hiểu **vì sao**, không
chỉ thấy **cái gì**. ADR không phải tài liệu cần đọc để dùng repo: người mới bắt đầu ở [`README.md`](../../README.md) và `docs/`.
ADR cũ được rút về khuôn dưới đây: quyết định giữ nguyên, chi tiết và lịch sử kiểm chứng ở [phụ lục](#phụ-lục); đảo một quyết định thì
viết ADR mới.

## Khi nào viết

- Quyết định khó đảo ngược hoặc ảnh hưởng nhiều service: ranh giới service, giao thức, cách lưu dữ liệu, chọn công cụ.
- Đổi công cụ đã chốt trong plan, hoặc kết luận một bài so sánh (ví dụ Elastic với Grafana).
- Không viết cho chi tiết hiện thực đổi được trong một buổi.

## Quy ước

- Tên file `NNNN-<slug>.md`, số tăng dần, không dùng lại số.
- Trạng thái là đúng một giá trị: **Đề xuất** (chờ duyệt) → **Chấp nhận**; về sau có thể thành **Bị thay bởi `[NNNN](NNNN-<slug>.md)`**
  hoặc **Bỏ**. `Ngày` là ngày quyết. ADR vẫn đứng nhưng có một phần được ADR sau chỉnh thì trạng thái giữ **Chấp nhận**, mỗi chỉnh
  một dòng `- §N: [NNNN](NNNN-<slug>.md): <chỉnh gì>` dưới `### Chỉnh bởi` trong `## Thông tin thêm` (ADR không đánh số § thì
  thay `§N` bằng tên mục bị chỉnh, ADR đánh nhãn (a)…(k) thì dùng nhãn).
- ADR đã chấp nhận không sửa nội dung quyết định. Đổi ý thì viết ADR mới và cập nhật trạng thái ADR cũ.
- Code không nhắc ADR (comment tự nói lý do), nên mỗi ADR có mục **Hiện thực ở** liệt kê file và thư mục hiện thực quyết định
  của nó, để tìm ngược từ quyết định tới code; thêm hay dời file hiện thực thì sửa mục này trong cùng thay đổi.
- ADR nêu vấn đề, ngày và người quyết, không dùng nhãn tiến độ của dự án ("giai đoạn N", "phần M") làm ngữ cảnh chính.
- Giới hạn 150 dòng; ADR có từ 10 mục § trở lên (heading đánh số) tối đa 200 dòng. Mục `## Xác nhận` tối đa 10 dòng.
- Phân tích phương án chi tiết, số đo, lệnh đã chạy, id lượt chạy và lịch sử kiểm chứng có ngày chuyển sang phụ lục.
  Giữ nguyên số mục § và chữ heading của chúng, vì "ADR-NNNN §N" được tham chiếu khắp repo.

### Phụ lục

`docs/adr/appendix/<cùng tên file ADR>` giữ nguyên văn phần chuyển ra khỏi ADR, xếp theo §. Phụ lục là lịch sử nên được giữ ngày và
nhãn tiến độ. Dòng đầu là `# Phụ lục ADR-NNNN: <tiêu đề ADR>`, câu thứ hai link về ADR; ADR link phụ lục ở `## Thông tin thêm`.
Link tương đối trong đoạn chuyển sang phải sửa theo thư mục mới. Chỉ ADR có phần chuyển ra mới có phụ lục.

## Mẫu

```markdown
# NNNN. <Quyết định, viết thành một mệnh đề>

- Trạng thái: Đề xuất | Chấp nhận | Bị thay bởi [NNNN](NNNN-<slug>.md) | Bỏ
- Ngày: YYYY-MM-DD
- Người quyết: <tên hoặc vai>

## Bối cảnh và vấn đề

Vấn đề cần giải, ràng buộc, số đo liên quan. Chi tiết dài để ở phụ lục hay docs/ và link sang.

## Yếu tố quyết định

- <tiêu chí đo được hoặc ràng buộc: chi phí, độ trễ, độ phức tạp vận hành>

## Phương án đã cân nhắc

- <phương án A>: <một dòng: được gì, mất gì>
- <phương án B>: <một dòng>

## Kết quả quyết định

Chọn <phương án>, vì <lý do gắn với yếu tố quyết định>.

### Hệ quả

- Tốt: ...
- Xấu: ...
- Xem lại khi: <điều kiện đo được>

## Xác nhận

Cách kiểm quyết định đã được làm đúng: test, số đo, lệnh. Chưa kiểm thì ghi rõ việc còn lại.

## Hiện thực ở

- `<đường dẫn>`: <phần nào của quyết định>

## Nguồn

- <link chính thức>

## Thông tin thêm

Phụ lục: [`appendix/NNNN-<slug>.md`](appendix/NNNN-<slug>.md) (chỉ khi có phần chuyển ra).

### Chỉnh bởi

- §N: [NNNN](NNNN-<slug>.md): <chỉnh gì>
```

## Danh sách

| ADR | Quyết định | Trạng thái |
| --- | --- | --- |
| [0001](0001-service-boundaries-and-data-ownership.md) | Chia hệ thống thành 6 service theo ranh giới nghiệp vụ, mỗi service sở hữu một database | Chấp nhận |
| [0002](0002-sync-rest-edge-grpc-internal.md) | REST/JSON ở biên, gRPC bên trong, contract Protobuf quản lý bằng buf | Chấp nhận |
| [0003](0003-async-events-outbox.md) | Event qua Redpanda; transactional outbox; at-least-once với consumer idempotent và DLQ | Chấp nhận |
| [0004](0004-direct-upload-and-hls.md) | Client upload thẳng lên object storage bằng presigned POST; transcode bất đồng bộ ra HLS | Chấp nhận |
| [0005](0005-feed-fan-out-on-write.md) | Feed dựng sẵn khi ghi (fan-out on write) trong Postgres của feed-service; Redis chỉ cache key nóng | Chấp nhận |
| [0006](0006-contract-ids-and-event-envelope.md) | Contract nội bộ: ID là UUIDv7, event bọc theo topic của luồng thực thể, proto đặt ở `proto/svp/<domain>/v1` | Chấp nhận |
| [0007](0007-go-monorepo-toolchain-and-stage1-scope.md) | Một Go module cho cả monorepo, công cụ ghim ở Makefile, cấu hình bằng biến môi trường, phạm vi đầu tiên thu về luồng đồng bộ | Chấp nhận |
| [0008](0008-async-upload-pipeline-stage2a.md) | Luồng upload bất đồng bộ: franz-go, aws-sdk-go-v2, outbox có khoá relay, media-worker trên alpine + ffmpeg | Chấp nhận |
| [0009](0009-engagement-feed-stage2b.md) | Event follow qua outbox, lượt xem gom lô với offset trong Postgres, feed fan-out on write có khoá theo tác giả | Chấp nhận |
| [0010](0010-redis-ratelimit-cache-resilience-stage2c.md) | Redis không bắt buộc cho rate limit GCRA và cache feed khám phá, timeout/retry/circuit breaker ở gateway, job dọn upload bỏ dở | Chấp nhận |
| [0011](0011-observability-stage3.md) | OpenTelemetry qua Collector riêng tới LGTM, GlitchTip tự host, Pyroscope và cảnh báo SLO bằng Sloth | Chấp nhận |
| [0012](0012-elastic-vs-grafana-stage3.md) | Giữ Grafana LGTM là bộ observability chính; Elastic 9.5.5 qua APM Server chỉ là profile so sánh | Chấp nhận |
| [0013](0013-kafka-metadata-min-age.md) | Mọi client franz-go đặt `MetadataMinAge` 1 s thay mặc định 5 s | Chấp nhận |
| [0014](0014-kubernetes-local-stage4.md) | Chạy cả hệ thống trên Kubernetes local: k3d với Helm, Envoy Gateway, dữ liệu trong cluster, Argo CD và canary bằng Argo Rollouts | Chấp nhận |
| [0015](0015-cicd-devsecops-stage5.md) | CI/CD và chuỗi cung ứng image: GitHub Actions ghim SHA, image đa kiến trúc trên GHCR, trivy chặn trước push, SBOM syft, ký keyless cosign, Kyverno chỉ nhận image đã ký và sạch, promote bằng PR GitOps, Renovate | Chấp nhận |
| [0016](0016-web-client.md) | Web client Next.js 16 với BFF và session phía server, refresh token xoay vòng có phát hiện dùng lại | Chấp nhận |
| [0017](0017-gitops-capacity-media-worker-max2.md) | media-worker tối đa 2 replica và tiêu chí ổn định (c): k3s server không restart trong diễn tập KEDA | Chấp nhận |
| [0018](0018-web-profiles-public-video-upload.md) | Handle không đổi và tên hiển thị ở user-service, danh sách video theo tác giả, route công khai `GET /public/videos/{id}` có rate limit theo IP, upload từ trình duyệt | Chấp nhận |
| [0019](0019-web-k3d-supply-chain-observability.md) | Web chạy trên k3d và đi qua chuỗi cung ứng như sáu service, gateway tin trace context khi mọi đường vào đã bỏ của client, lỗi trình duyệt tới GlitchTip qua route cùng origin, OTel ở server Next và RUM web-vitals | Chấp nhận |
| [0020](0020-reliability-stage6.md) | Độ tin cậy chia hai phần: phần chạy được trên máy (k6 theo SLO bằng image ghim, SLO web, backup/restore Postgres bằng CloudNativePG và plugin Barman Cloud có RTO/RPO đo trên k3d, runbook, game day, RFC, stack trong CI) và phần đo thật (k6 tải lớn và 1 000 req/s, Chaos Mesh, Velero, hai media-worker) chỉ viết và kiểm tĩnh | Chấp nhận |
| [0021](0021-deferred-verification-stage6b.md) | Kiểm chứng dồn chạy trên runner GitHub Actions `ubuntu-24.04` bằng workflow `verify.yml` chạy tay và theo lịch tuần, mỗi lượt một kịch bản; Argo CD đọc repo qua HTTPS ẩn danh | Chấp nhận |
| [0022](0022-local-object-store-minio-replacement.md) | Object store của đường local (compose và k3d) đổi từ MinIO (image Chainguard) sang RustFS, CORS theo bucket, tên trung tính `s3`; MinIO Chainguard là đường quay lại | Chấp nhận |
| [0023](0023-ci-platform-neutral.md) | CI trung lập nền tảng: YAML của nền tảng chỉ nối bước, logic ở `Makefile` và `deploy/ci/`, mọi chỗ đọc ngữ cảnh CI hay gọi API nền tảng đi qua adapter `deploy/ci/platform.sh` (hiện thực GitHub Actions và chạy trên máy), identity ký viết ở một chỗ; bảng ánh xạ GitHub ↔ GitLab (gitlab.com và self-managed) | Bị thay bởi [0037](0037-mainpath-standard-tools.md) |
| [0024](0024-multi-environment.md) | Nhiều môi trường dev, stg, prd: build một lần, mọi env chạy cùng digest đã ký, khác biệt chỉ ở overlay values mỗi env mà Argo CD chọn theo giá trị `env` của root Application; k3d đóng vai stg, prd chỉ render và kiểm tĩnh tới khi có cluster cloud | Chấp nhận |
| [0025](0025-gitops-config-repo.md) | Cấu hình triển khai chuyển sang repo public `svp-gitops` (values gốc, overlay và digest của mỗi env, manifest Argo CD), PR promote mở bằng GitHub App chỉ cài trên repo đó; chart vẫn ở repo code và mỗi env ghim commit chart của nó cùng bộ digest | Chấp nhận |
| [0026](0026-secrets-gitops.md) | Secret của đường GitOps (stg, prd) do External Secrets Operator dựng từ một kho nguồn ngoài git: ở stg trên k3d là namespace nguồn `svp-secrets` đọc qua provider `kubernetes`, ở prd là AWS Secrets Manager hay GCP Secret Manager; đường dev giữ `make k8s-secrets` từ `.env` | Chấp nhận |
| [0027](0027-slsa-build-provenance.md) | SLSA build provenance cho bảy image phát hành bằng predicate SLSA v1 do repo dựng, `cosign attest --type slsaprovenance1` định dạng cũ trên digest index, Kyverno kiểm provenance trên đường GitOps, bật theo bậc | Bị thay bởi [0040](0040-sigstore-bundle-actions-attest.md) |
| [0028](0028-dora-metrics.md) | DORA metrics của lab tính bằng script của repo từ bằng chứng đã triển khai (bản ghi Deployment `success` của stg), không từ merge; số là của stg lab, thiếu mẫu ghi "chưa đủ dữ liệu", không xếp hạng theo mức DORA | Bị thay bởi [0037](0037-mainpath-standard-tools.md) |
| [0029](0029-immutable-media-versions.md) | Output HLS bất biến theo version: `media/<video_id>/<version>/…` với version là `event_id` của `video.uploaded`, mỗi lần thử ghi thư mục riêng và master chỉ tạo một lần, `Cache-Control: max-age=31536000, immutable`; CMAF (fMP4) chỉ đánh giá, làm khi chạm transcode | Chấp nhận |
| [0030](0030-devsecops-supplement.md) | DevSecOps bổ sung: govulncheck chặn lỗ hổng Go mà code gọi tới, fuzz native cho 10 hàm parse, Schemathesis và CodeQL chỉ báo, grype quét SBOM syft của mọi image trước push; không Semgrep/Opengrep, không ZAP | Chấp nhận |
| [0031](0031-chaos-findings-feed-engagement-tempo.md) | Sửa ba phát hiện của Chaos Mesh và k6 trên runner: feed-service luôn hai replica, engagement-service lỗi nhanh có kiểm soát khi Postgres chậm hay mất, Tempo tự giới hạn bộ nhớ, không sampling | Chấp nhận |
| [0032](0032-argocd-deploy-status.md) | Argo CD báo ngược trạng thái triển khai: cảnh báo Prometheus ngay, commit status và tin nhắn khi có cluster chạy lâu dài | Chấp nhận |
| [0033](0033-svp-web-repo.md) | Web client tách sang repo `svp-web` với hợp đồng OpenAPI có version, nguồn phát hành và identity ký riêng, mọi nguồn khai ở một file của chart `svp-policy` | Chấp nhận |
| [0034](0034-aws-stage7.md) | Biến thể AWS chạy trên EKS ở Singapore; hạ tầng là Terraform trong repo riêng `svp-infra` (module `terraform-aws-modules` bọc mỏng, mỗi env một cấu hình gốc, stg cắt chi phí và prd chuẩn production chỉ khác ở biến); RDS PostgreSQL và S3 + CloudFront là dịch vụ managed, Redpanda, Valkey và observability chạy trong cluster; khác biệt k3d/EKS là lớp `platforms/` của `svp-gitops` cùng giá trị theo cluster do bootstrap đặt; NLB L4 giữ IP client trước Envoy, TLS Let's Encrypt DNS-01, `X-Forwarded-For` giữ 1 hop | Chấp nhận |
| [0035](0035-renovate-automerge.md) | Renovate tự merge bản patch và digest của Go module, gói npm, base image và image dịch vụ khi `ci-ok`, `images-ok` xanh, ở repo backend và `svp-web`; action, công cụ ghim, commit backend, hợp đồng API, minor, major giữ duyệt tay | Chấp nhận |
| [0036](0036-repo-rename.md) | Đổi tên repo `short-video-platform` → `svp-backend`, `svp-web` → `svp-frontend`: image chuyển sang prefix mới mang tên repo; bảng nguồn của lượt chuyển giữ hai nguồn cũ ở dạng nghỉ hưu (được nhận, không ai phát hành) để stg, prd đi qua bằng PR bot như mọi bản phát hành, rồi gỡ khi prd chạy bộ bản mới | Chấp nhận |
| [0037](0037-mainpath-standard-tools.md) | Đường chính theo công cụ chuẩn, một đường thẳng: DORA và CI trung lập nền tảng rời đường chính, promote bằng bước Actions `yq` + `gh pr`, bỏ bản ghi stg, check của `svp-gitops` rút gọn, khác biệt nền tảng là dữ liệu | Chấp nhận |
| [0038](0038-s3-bucket-names.md) | Tên bucket S3 của `svp-infra` theo `<tên>-<account>-<region>`, không phần ngẫu nhiên | Chấp nhận |
| [0039](0039-mainpath-drills-scan-gate-sourcemaps.md) | Diễn tập đo một lần và kịch bản runner thành bài lab, `verify.yml` còn hai kịch bản tuần; cổng quét bằng cờ của trivy, grype; bỏ image source map | Chấp nhận |
| [0040](0040-sigstore-bundle-actions-attest.md) | Chữ ký, `vuln`, SBOM và provenance của image phát hành sang Sigstore bundle trong một bản phát hành mỗi nguồn; provenance bằng `actions/attest`; rescan gỡ bundle `vuln` cũ; revert nếu admission thật vượt hạn | Chấp nhận |
| [0041](0041-github-hardening.md) | Siết cài đặt GitHub và chuỗi CI của mọi repo: Code Owner trên đường nhạy cảm, chỉ squash với lịch sử thẳng, environment `promote-prd` có người duyệt, Scorecard, zizmor, dependency review, lint tiêu đề PR, Renovate tự merge hẹp lại | Chấp nhận |
| [0042](0042-caller-identity-grpc.md) | Service gRPC tự kiểm access token mà gateway chuyển tiếp, bỏ `x-user-id`; mTLS giữa service bằng Istio ambient, dựng ở EKS, chưa dựng ở k3d | Chấp nhận |
| [0043](0043-idempotency-key.md) | `POST /videos` nhận `Idempotency-Key`; khoá thành `request_id` lưu cùng transaction với video ở video-service | Chấp nhận |
| [0044](0044-grpc-readiness.md) | Readiness của service gRPC là tên health `readiness`, do vòng nền ping Postgres của service đặt; liveness, startup giữ health tổng | Chấp nhận |
| [0045](0045-bounded-batch-retry.md) | Consumer theo lô thử lại trong ngân sách 5 phút rồi chép cả lô sang DLQ; consumer feed giữ thử lại không giới hạn | Chấp nhận |
| [0046](0046-web-session-lifetime.md) | Session BFF của web có idle timeout 7 ngày và absolute timeout 30 ngày tường minh, không chỉ dựa vào hạn refresh token | Chấp nhận |
| [0047](0047-pr-title-required-condition.md) | `pr-title` thành check bắt buộc ở một repo khi `pr-title.yml` đã trên `main` và đã xanh ở ít nhất một PR, không đòi PR bot | Chấp nhận |
| [0048](0048-prd-aws.md) | prd trên AWS: AWS Organizations với account `svp-stg`, `svp-prd` và management chỉ để quản trị; prd chuẩn production từ cùng module với stg; bootstrap EKS bằng GitOps Bridge ở root Terraform riêng; Secret của EKS từ Secrets Manager; prd ghim commit `svp-gitops` mà stg đã chạy | Chấp nhận |
| [0049](0049-kafka-prd.md) | Kafka của prd là Redpanda trong cluster bằng chart và component `redpanda` của stg: ba broker mỗi AZ một, replication factor 3 với `acks=all` (đa số Raft thay `min.insync.replicas=2`), mỗi broker nửa core | Chấp nhận |
| [0050](0050-bash-to-standard-tools.md) | Bash tự viết của đường chính nhường cho công cụ chuẩn: bootstrap EKS bằng GitOps Bridge, diễn tập bằng Chainsaw, kiểm cấu hình bằng JSON Schema và conftest, đường dev k3d bằng helmfile và Reloader; bỏ adapter CI và đường quay lại MinIO | Chấp nhận |
| [0051](0051-dns-prd-apex.md) | Zone gốc `aws.<miền>` của lab ở account `svp-prd`, zone `stg.aws.<miền>` là zone con do zone prd uỷ quyền; management không còn hosted zone | Chấp nhận |

## Chuẩn áp dụng

- Nygard, "Documenting Architecture Decisions" (2011): <https://www.cognitect.com/blog/2011/11/15/documenting-architecture-decisions>
- MADR 4.0 (Markdown Architectural Decision Records): <https://adr.github.io/madr/>
