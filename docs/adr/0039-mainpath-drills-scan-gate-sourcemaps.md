# 0039. Diễn tập đo một lần và kịch bản runner thành bài lab, `verify.yml` còn hai kịch bản tuần; cổng quét bằng cờ của trivy, grype; bỏ image source map

- Trạng thái: Chấp nhận
- Ngày: 2026-11-01
- Người quyết: người học (duyệt), AI (đề xuất)

## Bối cảnh và vấn đề

[0037](0037-mainpath-standard-tools.md) đặt nguyên tắc: đường chính chỉ giữ cái bảo vệ bản phát hành hay cái buổi AWS dùng; bản tự làm thành bài
lab của `svp-labs`, dựng một lần, kết luận ở ADR. Bản đánh giá ngày 2026-10-31 (ghi chú học, không nằm trong repo) đếm ba khối còn lại chưa theo
nguyên tắc đó: diễn tập `deploy/k8s/drills/*.sh` (6 702 dòng), kịch bản runner của `verify.yml` (hơn 6 000 dòng), cổng quét `scan-gate.sh` cùng
hàm grype của `common.sh` (~390 dòng), script source map (~1 180 dòng, kể cả test); bảng đếm ở phụ lục. Phần lớn diễn tập đã trả lời xong câu hỏi của nó: số đo và id lượt chạy nằm ở ADR 0014, 0017, 0019, 0020, 0021, 0022, 0031. Chạy lại mỗi tuần
không bảo vệ bản phát hành nào mà tốn runner, kéo theo clone `svp-frontend`, Node, Playwright và một image source map chỉ để lượt `gitops` dùng.
Cổng quét tự viết lại luật mà trivy và grype có sẵn cờ.

## Yếu tố quyết định

- Đường chính chỉ giữ regression của bản phát hành và cái buổi AWS dùng ([0037](0037-mainpath-standard-tools.md)).
- Cổng quét giữ đúng nghĩa (bí mật mọi mức, CRITICAL sau ngoại lệ) bằng cờ có sẵn của công cụ, như tài liệu của chúng chỉ.
- Ngoại lệ có hạn, có lý do, không che được gì ngoài đúng gói và version đã khai.

## Phương án đã cân nhắc

- §1 A. Giữ mọi diễn tập, năm kịch bản runner, lịch tuần ba job: mỗi đổi ở chart, script chung kéo theo sửa diễn tập đã đo xong.
- §1 B. Giữ cái là regression của bản phát hành hay buổi AWS dùng; phần đo một lần thành bài lab đóng băng: chọn, bằng chứng cũ giữ ở ADR.
- §1 C. Viết lại diễn tập bằng kubescape + Chainsaw: việc lớn, để sau; bài lab so bash với Chainsaw.
- §1 D. Bỏ `verify.yml`, chỉ kiểm ở buổi AWS: mất kiểm admission Kyverno và chart trên GitOps giữa các buổi.
- §2 A. Giữ `scan-gate.sh` (jq tự đếm, grype dùng `.trivyignore.yaml` qua jq): luật chặt hơn công cụ ở (a), (e) nhưng tự giữ.
- §2 B. Cờ có sẵn: trivy `--exit-code 1 --severity CRITICAL` + `.trivyignore.yaml`; grype `--fail-on critical` + `.grype.yaml`: chọn.
- §2 C. Một máy quét (chỉ trivy): mất node binary của image web mà chỉ syft + grype thấy ([0030](0030-devsecops-supplement.md) §6).
- §2 D. Ngoại lệ bằng VEX (OpenVEX): thêm định dạng cho một mục ngoại lệ.
- §3 tracker chạy lâu dài: GlitchTip dịch vụ.
- §3 tracker chạy lâu dài: GlitchTip tự dựng.
- §3 tracker chạy lâu dài: Sentry SaaS.
- §3 tracker chạy lâu dài: Grafana Cloud Frontend Observability.
- §3 công cụ tải: `withSentryConfig` của `@sentry/nextjs`.
- §3 công cụ tải: `sentry-cli sourcemaps inject` + `upload`.

Image `web-sourcemaps` ([0033](0033-svp-web-repo.md) §7) tồn tại vì stg không chạy lâu dài; cách của ngành là tải map lúc build vào tracker chạy lâu dài.

## Kết quả quyết định

Chọn 1B, 2B, và bỏ image source map ngay; tracker để người học chọn. Dòng chi tiết rút khỏi các § ở [mục "Chi tiết rút khỏi ADR"](appendix/0039-mainpath-drills-scan-gate-sourcemaps.md#chi-tiết-rút-khỏi-adr).

### 1. Diễn tập và `verify.yml`

Bảng dưới là phạm vi của đường chính; dòng "chuyển" thành bài lab `drills/` của `svp-labs`, chép nguyên văn từ một commit
ghim của `svp-backend` (và `svp-frontend` cho canary web) nơi script còn chạy được, như bài `dora/` của 0037.

| Giữ ở đường chính | Vì sao |
| --- | --- |
| `deploy/compose/smoke.sh` (`make smoke`, `k8s-smoke`, `eks-smoke`) | Buổi AWS gọi `make eks-smoke` (`aws/scripts/measure.sh` của `svp-infra`, bước 1) |
| `drill-k8s-supplychain` | Bằng chứng duy nhất admission của Kyverno thật sự từ chối; mục `actions/attest` của 0037 §6 phải chạy lại nó |
| `drill-k8s-threats` | Regression các dòng threat model trên chart và policy, mỗi bản phát hành |
| `drill-obs-threats` | Không lộ PII trong telemetry (JWT-8, WEB-9) |
| `deploy/k8s/drills/traffic.sh`, `deploy/k8s/drills/lib.sh` | `make k8s-up` tự chạy traffic khi Rollout có canary (`deploy/k8s/install.sh`); thư viện của diễn tập còn lại |
| `deploy/k6/` | Buổi AWS chạy `deploy/k6/cloud/run.sh` (`measure.sh`, bước 3) |

| Chuyển sang `svp-labs/drills/` | Vì sao |
| --- | --- |
| `drill-k8s-keda` và RAM nghỉ, đỉnh | Số đo dung lượng của laptop và runner ([0017](0017-gitops-capacity-media-worker-max2.md)); đo lại trên EKS bằng k6 của buổi AWS |
| `drill-k8s-pdb` | Chứng minh một lần ([0031](0031-chaos-findings-feed-engagement-tempo.md) §1); PDB vẫn trong chart |
| `drill-k8s-canary`, `measure-canary`, `drill-k8s-web-canary` | Chứng minh phân tích canary abort; Rollout, AnalysisTemplate vẫn trong chart |
| `drill-k8s-backup` | DR CloudNativePG trên k3d ([0020](0020-reliability-stage6.md) §5); EKS dùng RDS; runbook `postgres-restore.md` giữ quy trình tay |
| `measure-gitops` và bước chờ phát hành | Đo thời gian giao hàng, cùng lý do DORA rời đường chính ở 0037 §1 |
| `drill-k8s-web-obs`, bước `gitops-sourcemaps`, `k8s-web-e2e` của kịch bản | e2e web chạy ở job `stack` của CI `svp-frontend`; `make k8s-web-e2e`, `k8s-web-sourcemaps` giữ là công cụ đường dev |
| Kịch bản `dev-k3d`, `web-canary`, `k6-cloud-mini`, `chaos`, `velero` | Đo một lần, số ở [0021](0021-deferred-verification-stage6b.md), 0020, 0031 |
| Phần còn lại của `compose-obs`: load-local và cảnh báo, Lighthouse ×3, `drill-duplicates`, `drill-kill-worker`, `drill-upload-cleanup`, `measure-upload` và RAM `s3`, `drill-alert-to-sentry`, `object-store-roundtrip` | Script diễn tập compose vẫn ở repo, chạy tay |
| `verify-sample.sh`, `verify-tempo.sh`; chế độ runner của `deploy/k6/cloud/run.sh` | Chỉ các kịch bản trên dùng |
| Manifest Chaos Mesh, Velero, overlay runner dưới `deploy/k8s/cloud/` | Velero cho EKS ở bảng chi phí của [0034](0034-aws-stage7.md) là việc 7b: quyết lại lúc đó, lấy từ bài lab |

`verify.yml` còn hai kịch bản, cả hai vào lịch tuần: **`gitops`** (`k8s-gitops-up`, `gitops-env`, `gitops-external-secrets`,
`gitops-argocd-metrics`, `k8s-smoke`, `drill-k8s-supplychain`, `drill-k8s-threats`) và **`compose-obs`** thu gọn (`up` `OBS=lgtm`, `smoke`,
`drill-obs-threats`, `test-stack-objstore`: nơi duy nhất test `internal/objstore` chạy thật thay vì SKIP). Bỏ job `k3d`, input `web_ref`, bước
clone `svp-frontend`, cài Node, pnpm, Playwright; job `gitops` chỉ còn `contents: read` (quyền `actions`, `pull-requests` chỉ bước tìm source
map và bước chờ phát hành dùng). `make cloud-check` chỉ còn Job k6. Bằng chứng đã ghi ở ADR cũ (số, id lượt chạy) giữ nguyên.

### 2. Cổng quét

Cổng bằng cờ (2B) giữ đúng nghĩa: chặn bí mật mọi mức và CRITICAL còn lại sau ngoại lệ (cả chưa có bản vá) trước push và attest; HIGH trở xuống
chỉ báo; `--allow-critical` chỉ cho `drill-vulnerable` và rescan, không bao giờ cho bí mật. Nguyên văn đủ điều kiện ở phụ lục.

- **trivy:** một lần quét JSON mọi mức như nay (attestation `vuln` và SARIF đọc nó); cổng lỗ hổng `--exit-code 1 --severity CRITICAL
  --ignorefile .trivyignore.yaml`, cổng bí mật `--scanners secret --exit-code 1` **không** `--severity` (`--severity CRITICAL` giấu một bí mật
  HIGH, cả ở `trivy convert`). Thư mục làm việc của container không phải cây repo: trivy tự đọc `trivy-secret.yaml` ở đó, file ấy tắt được rule bí mật.
- **grype:** `--fail-on critical` (exit 2) với `.grype.yaml` ở gốc cây được quét (`code_root` của `common.sh`: bản checkout này, hay bản
  checkout `svp-frontend` qua `SVP_CODE_ROOT`), truyền bằng `-c`; rule `ignore` theo `vulnerability` + `package.name`/`version`,
  `include-aliases: true`. Bỏ `grype_ignore_jq`, `trivyignore_json` và phần lọc SARIF tự viết.
- **Cái mất, vì sao chấp nhận được:** (a) grype không đọc hạn của rule, nên mục hết hạn làm job `config` đỏ (chặn merge qua `ci-ok`) thay vì
  cổng grype của mọi chân image; trivy tự bỏ mục hết hạn, rescan chỉ đọc trivy. (b) Khớp theo id liên quan GHSA↔CVE **giữ được** nhờ
  `include-aliases: true`. (c) Tóm tắt job còn một dòng mỗi chân (CRITICAL, HIGH, bí mật); chi tiết HIGH, CRITICAL ở SARIF trên `main`.
  (d) Cổng `--fs` lockfile của `svp-frontend` thành lệnh trivy có `--exit-code` trong `Makefile` của repo đó. (e) Sửa `.grype.yaml` là đổi
  cổng grype của chính cây đó; chấp nhận vì phép kiểm danh sách cho phép chạy ở `config` trên cùng thay đổi, còn ở PR `images.yml` chỉ build
  và quét, không push.
- Bí mật vẫn không bỏ qua được: ignore chỉ phần `vulnerabilities`, không `--skip-files`, `--skip-dirs`, `--secret-config` nào trỏ vào cây repo.

### 3. Source map và tracker chạy lâu dài

Bỏ ngay image `web-sourcemaps`, `sourcemaps-image.sh`, `gitops-sourcemaps.sh` (+ test), chế độ `--sourcemaps-artifact` của
`build-image.sh` và `SOURCEMAPS_DIR` của `make k8s-web-sourcemaps`: người dùng duy nhất (bước `gitops-sourcemaps` của kịch bản `gitops`) rời
đường chính ở mục 1. Hai việc còn cần của `gitops-sourcemaps.sh` (digest `linux/amd64` của web stg, digest mới nhất của image diễn tập) dời
vào một script nhỏ cho `drill-k8s-supplychain`. Tải source map lúc build vào tracker chạy lâu dài làm khi có tracker đó; tracker và công cụ
tải (§3 của Phương án đã cân nhắc): **người học chọn**, chưa chốt. `make web-sourcemaps`, `make k8s-web-sourcemaps` (build từ bản clone, tải lên GlitchTip local) giữ.

### Hệ quả

- Tốt: bớt phần lớn diễn tập k8s, kịch bản runner, `deploy/k8s/cloud/`, source map và cổng tự viết; lượt `verify.yml` không cần Node,
  Playwright, quyền đọc API; luật cổng là cờ người học gặp ở công ty.
- Xấu:
  - **Không còn ai chạy lại** KEDA, PDB, canary, DR, chaos, Velero, k6 trên runner: chart đổi làm hỏng chúng thì không ai biết tới buổi AWS hay
    tới khi chạy tay bài lab ở commit ghim. Canary web và gateway chỉ còn bằng chứng cũ.
  - `test-stack-objstore` và `drill-obs-threats` chỉ chạy mỗi tuần, không ở PR (như nay).
  - Cổng grype: mục quá hạn bị bắt ở `config` chứ không ở mọi chân image (a); `.grype.yaml` của cây đổi được cổng grype, chỉ phép kiểm danh
    sách cho phép ở `config` giữ nó (e); tóm tắt PR ít số hơn (c).
  - Không có source map cho lỗi trình duyệt của bản phát hành tới khi người học chọn tracker.
- Xem lại khi: có EKS stg chạy suốt buổi (đưa canary, KEDA vào buổi AWS); có tracker chạy lâu dài (bật tải lúc build); grype đọc được hạn của rule hay VEX đủ cho cả hai máy quét.

## Xác nhận

- Hành vi cờ của trivy 0.76.0, grype 0.121.0 (image ghim ở `Makefile`) chạy thử ngày 2026-11-01 trên `minimist@1.2.5` (CRITICAL), bí mật
  HIGH tạo tạm và `socket.io-parser@4.0.4`: [T1]–[T7], [G1]–[G5] ở phụ lục, cơ sở của mọi điều kiện ở §2 (`--severity` giấu bí mật HIGH,
  `include-aliases`, khoá grype che CRITICAL, regex của `package.name`).
- §1, §2 và phần bỏ image source map của §3 đã hiện thực ở `svp-backend`; tracker và công cụ tải source map (§3) còn chờ người học chọn.
- Chưa kiểm ở ngày viết: hành vi trên image thật và SBOM của syft (phần hiện thực chạy `make check` và một lượt `images.yml`).

## Hiện thực ở

Repo `svp-backend` (đường dẫn từ gốc repo):

- `deploy/k8s/drills/` (xoá `keda.sh`, `pdb.sh`, `canary.sh`, `web-canary.sh`, `backup.sh`, `gitops.sh`, `web-obs.sh`), target của chúng ở `deploy/k8s/k8s.mk`, `deploy/k8s/cloud/` (còn `check.sh` cho Job k6), `deploy/k8s/install.sh`, `deploy/k8s/lib.sh`, `deploy/helm/svp-data/`, `deploy/helm/svp-service/`, `renovate.json`, `Makefile` (mục 1).
- `.github/workflows/verify.yml` (hai kịch bản tuần `compose-obs`, `gitops`; mỗi target một bước từ [0050](0050-bash-to-standard-tools.md)), `deploy/ci/verify-steps/`, `verify-host.sh`, `verify-mask.sh`, `verify-collect.sh`; `deploy/ci/verify-sample.sh`, `verify-tempo.sh` (xoá); `deploy/k6/cloud/run.sh` (bỏ chế độ runner), `deploy/k6/cloud/render.sh` (mục 1).
- `deploy/ci/scan-gate.sh` (viết lại gọn), `.github/actions/image-leg/` (thay `build-image.sh` đã xoá), `deploy/ci/rescan.sh`, `deploy/ci/changed-services.sh`, `grype_sbom` của `deploy/ci/common.sh`, `deploy/ci/scan-gate-test.sh`, `.trivyignore.yaml`, `.grype.yaml`, `deploy/ci/trivy-config-ignore.yaml`, job `config` của `.github/workflows/ci.yml` (mục 2).
- `deploy/ci/sourcemaps-image.sh`, `gitops-sourcemaps.sh` (+ test, xoá), `deploy/ci/ghcr-digest.sh` (+ test), `deploy/k8s/drills/run.sh` (diễn tập supplychain), `deploy/observability/glitchtip/sourcemaps.sh` (bỏ `SOURCEMAPS_DIR`) (mục 3).

Repo khác:

- `svp-labs`: bài `drills/` (mục 1).
- `svp-frontend`: `.github/workflows/images.yml` (bỏ đẩy image source map), `Makefile` (`lockfile-scan` bằng cờ trivy), `.grype.yaml` (mục 2, 3).

## Nguồn

- Trivy: [Filtering](https://trivy.dev/latest/docs/configuration/filtering/), [Others](https://trivy.dev/latest/docs/configuration/others/), [Secret](https://trivy.dev/latest/docs/scanner/secret/); Grype: [README](https://github.com/anchore/grype), [tài liệu cấu hình](https://oss.anchore.com/docs/reference/grype/configuration/).
- Sentry: [Source Maps for Next.js](https://docs.sentry.io/platforms/javascript/guides/nextjs/sourcemaps/), [Sentry CLI for Browser JavaScript](https://docs.sentry.io/platforms/javascript/sourcemaps/uploading/cli/); GlitchTip: [source maps](https://glitchtip.com/documentation/error-tracking#source-maps), [Pricing](https://glitchtip.com/pricing); Grafana: [Frontend Observability](https://grafana.com/docs/grafana-cloud/monitor-applications/frontend-observability/).

## Thông tin thêm

Phụ lục: [`appendix/0039-mainpath-drills-scan-gate-sourcemaps.md`](appendix/0039-mainpath-drills-scan-gate-sourcemaps.md) (dòng trạng thái lúc chốt, bảng đếm dòng, bảng lựa chọn có trạng thái công cụ, nguyên văn quyết định §2, hệ quả có số dòng, lệnh đã chạy [T1]–[T7], [G1]–[G5], nguồn có ghi chú).

### Chỉnh bởi

- §1: [0050](0050-bash-to-standard-tools.md): `drill-k8s-supplychain`, `drill-k8s-threats` viết thành test Chainsaw (`deploy/k8s/drills/<diễn tập>/`, `make drill-k8s-*` qua `deploy/k8s/drills/run.sh`); runner của `verify.yml` thành từng bước Actions, artifact chỉ còn kết quả máy đọc.
