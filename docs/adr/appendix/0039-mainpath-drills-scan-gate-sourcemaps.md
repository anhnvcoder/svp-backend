# Phụ lục ADR-0039: Diễn tập đo một lần và kịch bản runner thành bài lab, `verify.yml` còn hai kịch bản tuần; cổng quét bằng cờ của trivy, grype; bỏ image source map

Phụ lục của [ADR-0039](../0039-mainpath-drills-scan-gate-sourcemaps.md): phần chuyển ra khỏi ADR, giữ nguyên văn và xếp theo mục: dòng trạng thái lúc chốt, bảng đếm dòng của bối cảnh, bảng lựa chọn có trạng thái công cụ, nguyên văn quyết định §2, hệ quả đầy đủ, các lệnh đã chạy [T1]–[T7], [G1]–[G5] và nguồn [N1]–[N10]. Đây là lịch sử, nên giữ ngày của lúc ghi.

## Trạng thái ghi lúc chốt

- Trạng thái: Chấp nhận (người học duyệt 2026-11-01); §1, §2 và §3 phần A (bỏ image source map) hiện thực ở `svp-backend`; còn người học chọn tracker, công cụ tải source map (§3)

## Bối cảnh

[0037](../0037-mainpath-standard-tools.md) đặt nguyên tắc: đường chính chỉ giữ cái bảo vệ bản phát hành hay cái buổi AWS dùng; bản tự làm thành bài
lab của `svp-labs`, dựng một lần, kết luận ở ADR. Bản đánh giá ngày 2026-10-31 (ghi chú học, không nằm trong repo) đếm ba khối còn lại chưa theo
nguyên tắc đó, đo bằng `wc -l` trên `main` lúc viết:

| Khối | Dòng |
| --- | --- |
| Diễn tập `deploy/k8s/drills/*.sh` | 6 702 |
| Kịch bản `deploy/ci/verify/*.sh` (riêng `chaos.sh` 2 691), `verify.yml`, `verify-sample.sh`, `verify-tempo.sh` | 5 273 + 585 + 558 |
| Cổng quét `scan-gate.sh`, hàm grype của `common.sh` (`grype_sbom`, `trivyignore_json`, `grype_ignore_jq`) | 342 + ~45 |
| Source map: `sourcemaps-image.sh`, `gitops-sourcemaps.sh` (+ test) | 190 + 317 (+ 289 + 384) |

Phần lớn diễn tập đã trả lời xong câu hỏi của nó: số đo và id lượt chạy nằm ở ADR 0014, 0017, 0019, 0020, 0021, 0022, 0031. Chạy lại mỗi tuần
không bảo vệ bản phát hành nào mà tốn runner, kéo theo clone `svp-frontend`, Node, Playwright và một image source map chỉ để lượt `gitops` dùng.
Cổng quét tự viết lại luật mà trivy và grype có sẵn cờ.

## Các lựa chọn

Trạng thái công cụ (**cũ**, **hiện hành**, **mới nổi**) lấy từ bản đánh giá; nguồn ở mục Nguồn, chỗ không có nguồn riêng ghi "không nguồn riêng",
chỗ chưa thử ghi "chưa kiểm". Hành vi của trivy 0.76.0, grype 0.121.0 (image `TRIVY_IMAGE`, `GRYPE_IMAGE` ghim ở `Makefile`) đã chạy thử ngày
2026-11-01, ghi [T…], [G…] ở mục Xác nhận.

### 1. Diễn tập và `verify.yml`

| Lựa chọn | Trạng thái | Ghi chú |
| --- | --- | --- |
| A. Giữ mọi diễn tập, năm kịch bản runner, lịch tuần ba job | tự làm | Mỗi đổi ở chart, script chung kéo theo sửa diễn tập đã đo xong |
| B. Giữ cái là regression của bản phát hành hay buổi AWS dùng; phần đo một lần thành bài lab đóng băng | hiện hành: cluster tạm kind/k3d trong CI cho kiểm tích hợp (không nguồn riêng) | Bằng chứng cũ giữ ở ADR |
| C. Viết lại diễn tập bằng kubescape + Chainsaw | hiện hành (bản đánh giá) | Việc lớn, để sau; bài lab so bash với Chainsaw |
| D. Bỏ `verify.yml`, chỉ kiểm ở buổi AWS | — | Mất kiểm admission Kyverno và chart trên GitOps giữa các buổi |

### 2. Cổng quét

| Lựa chọn | Trạng thái | Ghi chú |
| --- | --- | --- |
| A. Giữ `scan-gate.sh` (342 dòng, jq tự đếm, grype dùng `.trivyignore.yaml` qua jq) | tự làm | Luật chặt hơn công cụ ở hai điểm (a), (e) dưới |
| B. Cờ có sẵn: trivy `--exit-code 1 --severity CRITICAL` + `.trivyignore.yaml`; grype `--fail-on critical` + `.grype.yaml` | hiện hành [N1]\[N2]\[N4] | Cách tài liệu của hai công cụ chỉ |
| C. Một máy quét (chỉ trivy) | hiện hành (không nguồn riêng) | Mất node binary của image web mà chỉ syft + grype thấy ([0030](../0030-devsecops-supplement.md) §6) |
| D. Ngoại lệ bằng VEX (OpenVEX) | mới nổi (grype có hỗ trợ [N4]; trivy chưa kiểm) | Thêm định dạng cho một mục ngoại lệ |

### 3. Source map và tracker chạy lâu dài

Image `web-sourcemaps` ([0033](../0033-svp-web-repo.md) §7) tồn tại vì stg không chạy lâu dài: lượt `gitops` dựng GlitchTip trong cluster rồi tải map
của đúng image đang chạy. Cách của ngành là tải map lúc build vào tracker chạy lâu dài [N5]\[N6].

| Tracker | Trạng thái | Ghi chú |
| --- | --- | --- |
| GlitchTip dịch vụ (app.glitchtip.com) | hiện hành [N8] | Cùng giao thức Sentry như GlitchTip tự host của [0011](../0011-observability-stage3.md) |
| GlitchTip tự dựng trên máy chạy lâu dài | hiện hành | Thêm một máy phải vận hành |
| Sentry SaaS | hiện hành [N5] | 0011 chọn tự host |
| Grafana Cloud Frontend Observability | hiện hành [N9] | Plugin bundler của Faro chỉ hỗ trợ ứng dụng render phía client; Faro CLI hay cURL thì không giới hạn đó [N10] |

| Công cụ tải | Trạng thái | Ghi chú |
| --- | --- | --- |
| `withSentryConfig` của `@sentry/nextjs` | hiện hành [N5] | `@sentry/nextjs` đã là dependency của web; `next.config.ts` chưa dùng `withSentryConfig` |
| `sentry-cli sourcemaps inject` + `upload` (debug ID) | hiện hành [N6] | GlitchTip có `glitchtip-cli` cùng tên lệnh [N7]; hôm nay `deploy/observability/glitchtip/sourcemaps.sh` |

Không ghi giá: chưa có nguồn giá cho mức dùng của lab.

## Quyết định §2 nguyên văn

**Cổng quét bằng cờ (2B).** Cổng giữ đúng nghĩa: chặn bí mật mọi mức và CRITICAL còn lại sau ngoại lệ (cả chưa có bản vá) trước push và
attest; HIGH trở xuống chỉ báo; `--allow-critical` chỉ cho `drill-vulnerable` và rescan, không bao giờ cho bí mật.

- **trivy:** một lần quét JSON mọi mức như nay (attestation `vuln` và SARIF đọc nó); cổng là trivy với `--exit-code 1 --severity CRITICAL
  --ignorefile .trivyignore.yaml` cho lỗ hổng, và `--scanners secret --exit-code 1` **không** `--severity` cho bí mật: `--severity CRITICAL`
  giấu một bí mật HIGH, cả ở lệnh quét lẫn `trivy convert` [T1]\[T6]. Thư mục làm việc của container không phải cây repo, vì trivy tự đọc
  `trivy-secret.yaml` ở đó và file ấy tắt được rule bí mật [N3]\[T5].
- **grype:** `--fail-on critical` (exit 2, không phải 1 [G1]) với `.grype.yaml` ở gốc cây được quét (`code_root` của `common.sh`: bản
  checkout này, hay bản checkout `svp-frontend` qua `SVP_CODE_ROOT`), truyền bằng `-c`; rule `ignore` theo `vulnerability` +
  `package.name`/`version`, `include-aliases: true` [G2]. `package.name` là regex neo hai đầu khi tên có một trong `*+?[](){}|^$\`; tên chỉ
  có `.` thì so nguyên văn; `version` so nguyên văn [G5]. Bỏ `grype_ignore_jq`, `trivyignore_json` và phần lọc SARIF tự viết.
- **Phép kiểm file ignore** còn nhỏ, ở job `config`: mỗi mục `.trivyignore.yaml` có `id`, `statement`, `expired_at` trong ≤ 30 ngày và
  `purls` mà purl nào cũng có `@version` (trivy đọc purl không version là mọi version của gói [T7]), chỉ khoá `vulnerabilities` (trivy nhận
  mục `secrets:` và khoá lạ mà không báo [T4]). `.grype.yaml` kiểm theo danh sách cho phép: ở gốc chỉ khoá `ignore`; mỗi rule có đủ và chỉ
  có `vulnerability`, `include-aliases: true`, `package.name`, `package.version`, và khớp đúng một mục còn hạn của `.trivyignore.yaml` (cùng
  id, cùng version, `package.name` là tên trong purl với mỗi ký tự `.*+?[](){}|^$\` thoát bằng `\`: `socket\.io-parser`, `libstdc\+\+`).
  Tên thoát như vậy khớp đúng một gói dù grype đọc nó là regex hay nguyên văn [G5]; tên viết cách khác bị từ chối, nên cặp mục + rule soạn
  khéo (`pkg:npm/.*@1.2.5` với tên `.*`) không che được mọi gói cùng version. Từ chối hẳn tên có ký tự meta thì gọn hơn nhưng không ngoại
  lệ được gói có `.` hay `+` trong tên (đường dẫn module Go như `golang.org/x/net`, `libstdc++` của Alpine). Mọi khoá khác bị từ chối, kể cả
  khoá grype biết: `only-notfixed`, `only-fixed`, `ignore-wontfix` ở gốc, rule chỉ có `fix-state` hay `package.type`, rule thiếu `package`
  đều che CRITICAL không cần mục ngoại lệ, không hạn [G4]; `vex-documents` cùng loại (chưa kiểm); khoá lạ, cả `expired_at`, grype nhận mà
  không báo [G3]. `trivy-config-ignore.yaml` giữ luật của nó.
- **Cái mất, vì sao chấp nhận được:**
  (a) grype không đọc hạn của rule [G3], nên hạn chỉ nằm ở phép kiểm file: mục hết hạn làm job `config` đỏ thay vì cổng grype của mọi chân
  image. `config` chạy ở mọi PR và push lên `main`, `ci-ok` bắt buộc ở PR, nên không merge được gì tới khi mục được gia hạn hay xoá; chỉ một
  bản build từ chính push đó hay dispatch còn qua cổng grype với rule cũ. trivy tự bỏ mục hết hạn [T2], rescan chỉ đọc trivy.
  (b) Khớp theo id liên quan GHSA↔CVE **giữ được**: `include-aliases: true` che match grype báo bằng GHSA khi rule ghi CVE [G2]. trivy khớp
  đúng id nó báo, như nay [T3].
  (c) Bảng đếm đủ mức (MEDIUM, LOW, UNKNOWN, số match được ngoại lệ) trong tóm tắt job: còn một dòng mỗi chân (CRITICAL, HIGH, bí mật) đọc từ
  báo cáo; chi tiết HIGH, CRITICAL vẫn ở SARIF lên tab Security trên `main`.
  (d) Cổng `--fs` lockfile của `svp-frontend` thành lệnh trivy có `--exit-code` trong `Makefile` của repo đó.
  (e) grype nay đọc cấu hình từ cây được quét: hôm nay `grype_sbom` chạy ở `/tmp`, không `-c`, nên không đọc file cấu hình nào; với `-c`, sửa
  `.grype.yaml` là đổi cổng grype của chính cây đó. Chấp nhận được vì phép kiểm danh sách cho phép ở trên chạy ở `config` trên cùng thay đổi;
  ở PR và ref khác `main`, `images.yml` chỉ build và quét (`build-nopush`), không push, nên một `.grype.yaml` nới cổng không đẩy được image
  nào và không merge được khi `config` đỏ; `main` chỉ nhận file đã qua `config` ở PR. `svp-frontend` cùng cách: `ci.yml` của repo đó chạy
  `--check-ignorefile`, `images.yml` chỉ push trên `main`.
- Bí mật vẫn không bỏ qua được: ignore chỉ phần `vulnerabilities`, không `--skip-files`, `--skip-dirs`, `--secret-config` nào trỏ vào cây repo.

## Hệ quả

- Được (đếm trên `main` lúc viết): bớt 2 946 dòng diễn tập k8s, ~5 000 dòng kịch bản runner, sampler, `verify-tempo.sh` (chưa tính phần cắt
  của `compose-obs.sh`, `gitops.sh`), phần lớn 2 481 dòng của `deploy/k8s/cloud/`, ~1 180 dòng source map, phần lớn 342 dòng cổng; lượt
  `verify.yml` không cần Node, Playwright, quyền đọc API; luật cổng là cờ người học gặp ở công ty.
- Phải trả (nói thẳng):
  - **Không còn ai chạy lại** KEDA, PDB, canary, DR, chaos, Velero, k6 trên runner: chart đổi làm hỏng chúng thì không ai biết tới buổi AWS hay
    tới khi chạy tay bài lab ở commit ghim. Canary web và gateway chỉ còn bằng chứng cũ.
  - `test-stack-objstore` và `drill-obs-threats` chỉ chạy mỗi tuần, không ở PR (như nay).
  - Cổng grype: mục quá hạn bị bắt ở `config` chứ không ở mọi chân image (a); `.grype.yaml` của cây đổi được cổng grype, chỉ phép kiểm danh
    sách cho phép ở `config` giữ nó (e); tóm tắt PR ít số hơn (c).
  - Không có source map cho lỗi trình duyệt của bản phát hành tới khi người học chọn tracker.
- Xem lại khi: có EKS stg chạy suốt buổi (đưa canary, KEDA vào buổi AWS); có tracker chạy lâu dài (bật tải lúc build); grype đọc được hạn của rule
  hay VEX đủ cho cả hai máy quét.

## Xác nhận

Đã chạy ngày 2026-11-01 trên Mac arm64, `env -u DOCKER_DEFAULT_PLATFORM docker run --network none` image ghim, DB có sẵn; trivy `fs` trên
`package-lock.json` có `minimist@1.2.5` (CVE-2021-44906, CRITICAL) và một file khoá RSA tạo tạm (rule `private-key`, HIGH); grype `purl:` cùng
gói (báo `GHSA-xvch-5gv4-984h`, Critical, liên quan CVE-2021-44906) và `socket.io-parser@4.0.4` (báo `GHSA-qm95-pgcg-qqfq`, Critical, liên quan
CVE-2022-2421):

- [T1] `--scanners vuln,secret --severity CRITICAL --exit-code 1` chỉ với bí mật HIGH: exit 0. `trivy convert --exit-code 1 --severity CRITICAL`
  trên JSON chỉ có bí mật HIGH: exit 0, output không có bí mật; cùng lệnh không `--severity`: exit 1. Lỗ hổng CRITICAL: exit 1.
- [T2] Mục `.trivyignore.yaml` đúng id + purl còn hạn: exit 0; cùng mục `expired_at` đã qua: exit 1.
- [T3] Mục ghi `GHSA-xvch-5gv4-984h` khi trivy báo CVE: exit 1.
- [T4] Mục `secrets:` (`private-key`, `paths`) kèm khoá lạ `bogus`: bí mật bị bỏ qua, exit 0, không cảnh báo.
- [T5] `trivy-secret.yaml` có `disable-rules: [private-key]` ở thư mục làm việc, không cờ: exit 0; `--secret-config` trỏ file không có: exit 1.
- [T6] `trivy convert --exit-code 1 --severity CRITICAL --ignorefile` (mục `minimist@1.2.5`) trên JSON có cả lỗ hổng CRITICAL lẫn bí mật HIGH:
  exit 0, output không còn cả hai; không `--ignorefile`: exit 1.
- [T7] Mục CVE-2021-44906 còn hạn, `--exit-code 1 --severity CRITICAL`: purl `pkg:npm/minimist` (không version) che (exit 0);
  `pkg:npm/minimist@1.2.5` che (exit 0); `pkg:npm/minimist@1.2.4` không che (exit 1).
- [G1] `--fail-on critical`, không cấu hình: exit 2, log "discovered vulnerabilities at or above the severity threshold".
- [G2] Rule `vulnerability: CVE-2021-44906` + `package` name/version: không che (exit 2); thêm `include-aliases: true`: che (exit 0); rule bằng id
  GHSA: che; rule version `1.2.6`: không che.
- [G3] Rule có `expired_at: 2020-01-01` và khoá gốc lạ `bogus-key`: grype không báo gì, rule vẫn che (exit 0).
- [G4] Không có mục ngoại lệ nào cho `minimist@1.2.5`, cổng `--fail-on critical` vẫn exit 0 ("No vulnerabilities found") với `.grype.yaml` là
  `only-notfixed: true` (cả khi thêm `ignore: []`), `ignore-wontfix: fixed`, một rule chỉ `fix-state: fixed`, một rule chỉ `package.type: npm`,
  hay một rule `vulnerability` + `include-aliases` không `package`. `only-fixed: true` trên `vm2@3.9.19` bỏ `GHSA-g644-9gfx-q4q4` (Critical,
  chưa có bản vá) khỏi kết quả. `db.cache-dir` trong file không thắng biến `GRYPE_DB_CACHE_DIR` của lệnh (vẫn exit 2).
- [G5] Rule CVE-2021-44906 + `include-aliases: true` + version `1.2.5`, chỉ đổi `package.name`: `minimist`, `.*`, `mini.*`, `minimis[t]`,
  `minimist+`, `minimis.+`, `minimis(t)`, `minimist{1}`, `minimist|x`, `^minimis.`, `minimis\x74` che (exit 0); `minimis.`, `minimi.t`,
  `.inimist`, `minimis\.`, `minimist++`, `MINIMIST` không che (exit 2). Rule CVE-2022-2421 + `4.0.4`: `socket.io-parser` và
  `socket\.io-parser` che, `socketXio-parser` không. Tên `minimist`, chỉ đổi version: `1.2.5` che; `1.2.*`, `1\.2\.5`, `1.2.[0-9]`, `< 1.2.6`
  không che.

Chưa kiểm: hành vi trên image thật và SBOM của syft (card hiện thực chạy `make check` và một lượt `images.yml`).

## Nguồn

- [N1] Trivy: [Filtering](https://trivy.dev/latest/docs/configuration/filtering/) (`.trivyignore.yaml`: `vulnerabilities`, `secrets`,
  `expired_at`, `purls` chỉ cho lỗ hổng; đánh dấu thử nghiệm).
- [N2] Trivy: [Others](https://trivy.dev/latest/docs/configuration/others/) (`--exit-code 1 --severity CRITICAL`).
- [N3] Trivy: [Secret](https://trivy.dev/latest/docs/scanner/secret/) (mặc định đọc `trivy-secret.yaml` ở thư mục hiện tại, `--secret-config`).
- [N4] Grype: [README](https://github.com/anchore/grype) (OpenVEX), [tài liệu cấu hình](https://oss.anchore.com/docs/reference/grype/configuration/)
  (chưa đọc lại; hành vi `ignore`, `--fail-on` ở trên là lệnh đã chạy [G1]–[G5]).
- [N5] Sentry: [Source Maps for Next.js](https://docs.sentry.io/platforms/javascript/guides/nextjs/sourcemaps/) (`withSentryConfig`, tải lúc
  `next build`).
- [N6] Sentry: [Sentry CLI for Browser JavaScript](https://docs.sentry.io/platforms/javascript/sourcemaps/uploading/cli/) (`sourcemaps inject`,
  `upload`).
- [N7] GlitchTip: [Error Tracking, source maps](https://glitchtip.com/documentation/error-tracking#source-maps),
  [CLI, source maps](https://glitchtip.com/documentation/cli#source-maps).
- [N8] GlitchTip: [Pricing](https://glitchtip.com/pricing) (có bản dịch vụ; không ghi giá).
- [N9] Grafana: [Frontend Observability](https://grafana.com/docs/grafana-cloud/monitor-applications/frontend-observability/).
- [N10] Grafana: [Source map uploads](https://grafana.com/docs/grafana-cloud/monitor-applications/frontend-observability/configure/sourcemap-uploads/).

## Chi tiết rút khỏi ADR

Các dòng dưới đây nguyên văn từ ADR, rút ra để ADR không vượt giới hạn dòng; xếp theo mục của ADR.

### 2. Cổng quét

- **Phép kiểm file ignore** ở job `config`: mỗi mục `.trivyignore.yaml` có `id`, `statement`, `expired_at` trong ≤ 30 ngày, `purls` mà purl
  nào cũng có `@version`, chỉ khoá `vulnerabilities`. `.grype.yaml` theo danh sách cho phép: ở gốc chỉ khoá `ignore`; mỗi rule có đủ và chỉ có
  `vulnerability`, `include-aliases: true`, `package.name`, `package.version`, và khớp đúng một mục còn hạn của `.trivyignore.yaml` (cùng id,
  cùng version, `package.name` là tên trong purl với mỗi ký tự `.*+?[](){}|^$\` thoát bằng `\`). Mọi khoá khác bị từ chối, kể cả khoá grype
  biết (`only-notfixed`, `only-fixed`, `ignore-wontfix`, rule chỉ có `fix-state` hay `package.type`, rule thiếu `package`, `vex-documents`):
  chúng che CRITICAL không cần mục ngoại lệ. `trivy-config-ignore.yaml` giữ luật của nó.
