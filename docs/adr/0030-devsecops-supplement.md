# 0030. DevSecOps bổ sung: govulncheck chặn lỗ hổng Go mà code gọi tới, fuzz native cho 10 hàm parse, Schemathesis và CodeQL chỉ báo, grype quét SBOM syft của mọi image trước push; không Semgrep/Opengrep, không ZAP

- Trạng thái: Chấp nhận
- Ngày: 2026-10-28
- Người quyết: người học (duyệt ADR, gồm mục 6, và phần hạ tầng)

## Bối cảnh và vấn đề

- Hai dòng "để sau" của [ADR-0015](0015-cicd-devsecops-stage5.md) §12: govulncheck và DAST; job `stack` của `ci.yml` có từ
  [ADR-0020](0020-reliability-stage6.md) §15, nên điều kiện của DAST đã có. Người học giao ngày 2026-10-28 "xem best practice như nào thì làm" và
  chốt công cụ: `govulncheck` vào `make check` (chặn PR), fuzz native của Go (seed trong `make test`), Schemathesis theo
  `services/gateway/openapi.yaml` ở job `stack` (chỉ báo), CodeQL **default setup** bằng cài đặt repo; không Semgrep/Opengrep, không ZAP.
- Lỗ hổng lúc quyết (govulncheck v1.9.0): GO-2026-6809 (`crypto/x509`, sửa ở go1.27.3) mức symbol qua `internal/objstore`; CI ghim
  `go-version: 1.27.3` mà hai Dockerfile còn `golang:1.27.2-trixie`, nên image phát hành mang lỗ hổng mà govulncheck trên CI không thấy.
  Nguyên nhân gốc: `go.mod` chỉ khai `go 1.27` ([ADR-0007](0007-go-monorepo-toolchain-and-stage1-scope.md) phần module), không gì buộc ba nơi
  dùng cùng một Go. `golang.org/x/net` v0.60.0 (GO-2026-6866, GO-2026-6860) và `golang.org/x/crypto` v0.58.0 (GO-2026-5932, không có bản vá):
  code không gọi.
- Image web distroless cài `node` không qua dpkg: trivy không thấy runtime Node.js; syft thấy `node 26.12.0` (`pkg:generic/node@26.12.0` +
  CPE) nhưng SBOM đã attest không được đối chiếu với cơ sở dữ liệu lỗ hổng nào.
- Ràng buộc: repo public (SC-9); CI trung lập nền tảng ([ADR-0023](0023-ci-platform-neutral.md)); chỉ action của GitHub và
  `sigstore/cosign-installer`, ghim SHA (ADR-0015 §11); công cụ ghim version hay image, Renovate đọc được; máy 16 GB; `go.mod` không có thư viện YAML.

## Yếu tố quyết định

- Chặn đúng lỗ hổng chạm được từ code, ít báo giả; ngoại lệ có lý do, có hạn, review qua PR.
- Image phát hành mang đúng thứ đã quét: bản Go của phép quét mã nguồn, danh sách gói đã attest.
- Không YAML chỉ chạy trên GitHub, không action bên thứ ba; log và artifact public không mang bí mật.
- Chi phí runner, RAM hợp với lab một người.

## Phương án đã cân nhắc

- §1 giữ trivy + Dependabot: loại.
- §1 govulncheck chặn mọi mức: loại.
- §1 govulncheck chỉ báo: loại.
- §1 govulncheck `-mode binary`: loại.
- §1 exit 3 của chế độ chữ: loại.
- §1 **chặn mức symbol qua gate đọc `-format json` + tệp ngoại lệ có hạn**: chọn.
- §1 một Go cho máy, CI, image: dòng `toolchain` (image `GOTOOLCHAIN=local` bỏ qua): loại.
- §1 một Go cho máy, CI, image: directive làm sàn (image trên sàn lọt): loại.
- §1 một Go cho máy, CI, image: quét theo tag của Dockerfile: loại.
- §1 một Go cho máy, CI, image: script so ba nơi: loại.
- §1 một Go cho máy, CI, image: **directive `go 1.27.3` là bản phát hành, gate so `FROM golang:`**: chọn.
- §2 lịch fuzz trong `verify.yml`: loại.
- §2 OSS-Fuzz: loại.
- §2 ClusterFuzzLite: loại.
- §2 **fuzz native, seed trong `make test`, `make fuzz` chạy tay**: chọn.
- §3 ZAP API scan: loại.
- §3 Schemathesis `--checks all`: loại.
- §3 Schemathesis token qua `-H Authorization`: loại.
- §3 **Schemathesis theo `openapi.yaml`, image ghim digest**: chọn.
- §4 advanced setup (`codeql.yml`): loại.
- §4 CodeQL CLI trong `Makefile` (giấy phép): loại.
- §4 **default setup bằng cài đặt repo**: chọn.
- §6 giữ trivy một mình: loại.
- §6 `trivy sbom` (không khớp CPE): loại.
- §6 grype đọc lại `image.tar`: loại.
- §6 `.grype.yaml` riêng: loại.
- §6 **grype trên chính SBOM syft**: chọn.

Bảng được mất từng phương án, trạng thái ngành có nguồn: [phụ lục](appendix/0030-devsecops-supplement.md).

## Kết quả quyết định

Chọn phương án nêu ở mỗi dòng trên. Recipe, quy tắc gate, bảng target fuzz, cờ và lệnh đủ chi tiết ở [phụ lục](appendix/0030-devsecops-supplement.md). Dòng chi tiết rút khỏi các § ở [mục "Chi tiết rút khỏi ADR"](appendix/0030-devsecops-supplement.md#chi-tiết-rút-khỏi-adr).

### 1. govulncheck

- Ghim `GOVULNCHECK_VERSION := v1.9.0` (`# renovate: datasource=go depName=golang.org/x/vuln`), `make tools` cài; `make vulncheck` nằm trong
  `check-go` trước `test` (`check-go: fmt-check vet lint actionlint buf-lint vulncheck test`); không sửa workflow; không vào hook `pre-commit`.
- Gate `tools/vulngate/` (Go, chỉ thư viện chuẩn) đỏ khi: `config.protocol_version` khác `v1.0.0` hay output hỏng; một dòng `FROM golang`
  không có tag đủ ba số hay khác `config.go_version`, hoặc không có dòng `FROM golang` nào; lỗ hổng mức symbol không có ngoại lệ hợp lệ (in trace).
  Mức module, package chỉ dòng `INFO`.
- **Một bản Go phát hành** (chỉnh ADR-0007 phần module): `go.mod` `go 1.27.3`, không dòng `toolchain`; hai Dockerfile
  `golang:1.27.3-trixie@sha256:…`; `setup-go` giữ `go-version: 1.27.3`, gate không đọc workflow; `renovate.json` thêm rule
  `{"matchManagers": ["gomod"], "matchDepNames": ["go"], "matchDepTypes": ["golang"], "rangeStrategy": "bump"}` để một PR đổi directive,
  `setup-go` và image `golang` cùng lúc. Image dưới directive không build được, trên directive thì `check` đỏ.
- GO-2026-6809 sửa bằng directive và hai Dockerfile; `x/net` để Renovate nâng; GO-2026-5932 chỉ đếm ở `INFO`.

### 2. Fuzz native của Go

- Seed chạy trong `make test` (có `-race`); `testdata/fuzz/FuzzXxx/` chỉ chứa input tái hiện lỗi đã sửa hay seed cố ý.

### 3. Schemathesis (DAST theo OpenAPI)

- `make dast` trên stack `make up` đang chạy, không khởi động gì; **LOCAL LAB ONLY:** xoá `svp:gw:rl:register:*` ở Redis db 10 trước và sau;
  user thử mới, token trong `SVP_DAST_TOKEN` (không in, không trên dòng lệnh); container trên mạng `svp_web`; hạn cả lượt **10 phút**; exit theo
  Schemathesis (0, 1, 2), quá hạn hay lộ bí mật là 1.
- Job `stack`: bước `make dast` (`continue-on-error: true`, `timeout-minutes: 15`) chạy cuối, artifact `dast`; ngoài `ci-ok` (ADR-0020 §15).

### 4. CodeQL default setup

- Bật bằng `gh api -X PATCH …/code-scanning/default-setup` (`state=configured`, `query_suite=default`, `threat_model=remote`,
  `runner_type=standard`, ngôn ngữ `actions`, `go`, `javascript-typescript`), người điều phối chạy. Chỉ báo: không rule code scanning trong ruleset
  `main`; cảnh báo giả dismiss kèm lý do; gosec vẫn là cổng chặn; job `sarif` không đổi.
- `sha_pinning_required` chặn workflow động thì không nới cài đặt: tắt default setup, đưa lựa chọn lại cho người học.
- Autobuild Go chạy `make` không đối số của commit được quét trong job có `security-events: write`, chỉ với PR từ nhánh của repo: **chấp nhận ở
  lab** vì CodeQL chỉ báo và `main` chỉ nhận PR có `ci-ok`, `images-ok`; token có quyền ngoài `security-events` thì không chấp nhận: tắt,
  chuyển advanced setup `build-mode: manual` với lệnh build cố định.

### 5. Không Semgrep/Opengrep, không ZAP; threat model; GitLab

- Không Semgrep/Opengrep: gosec và CodeQL đã phủ, công cụ thứ ba thêm luồng cảnh báo mà không phủ mảng mới. Không ZAP: JVM nặng, quy tắc cho ứng dụng có HTML; Schemathesis đọc đúng contract JSON. Ánh xạ threat model (dòng mới cho govulncheck, target fuzz vào cột "Kiểm bằng") và bảng tương đương GitLab ở phụ lục; sửa `docs/threat-model.md` là việc riêng.

### 6. grype trên SBOM syft

- `grype_sbom` của `common.sh`, gọi từ `build-image.sh` ngay sau syft: `grype sbom:/out/sbom.spdx.json`; thư mục làm việc và `HOME` là tmpfs trống (không đọc cấu hình grype); DB tải được hoặc chân đỏ (`GRYPE_DB_REQUIRE_UPDATE_CHECK=true`, DB build quá 5 ngày bị từ chối); cache theo ngày `grype-db-<ngày>`.
- Cổng `scan-gate.sh --grype`: Critical còn lại sau ngoại lệ → exit 1, High trở xuống chỉ đếm, `--allow-critical` chỉ cho `drill-vulnerable`; `build-image.sh` chạy cả hai cổng rồi mới dừng, một cổng đỏ là chân đỏ, không push.
- Ngoại lệ tái dùng `.trivyignore.yaml` (khớp `id` hay id liên quan và `purls`); mục hết hạn làm cổng grype đỏ kể cả với report sạch.

### Hệ quả

- Tốt: lỗ hổng Go được gọi tới chặn PR, image Go build bằng đúng bản đã quét; mười parser có tính chất kiểm bằng fuzz; contract `openapi.yaml` được kiểm với gateway thật mỗi lượt `stack`; CodeQL cho Go, TypeScript, workflow không thêm YAML; mọi image qua thêm một DB lỗ hổng trên đúng SBOM đã attest, thấy runtime ngoài trình quản lý gói.
- Xấu: `make check-go` cần mạng; nâng Go đổi bốn chỗ trong một PR; `tools/vulngate` và tệp ngoại lệ phải giữ; fuzz thật chỉ chạy tay; DAST dài thêm tới 10 phút, 429 mất độ phủ; cấu hình CodeQL ngoài git, job CodeQL chạy `make` của PR nội bộ; grype thêm vài giây mỗi chân, cache DB ~480 MB mỗi entry, có thể chặn Critical mà trivy không xếp Critical.
- Xem lại khi (đủ ở phụ lục): DB lỗi quá 2 lượt `main` một tháng; ngoại lệ gia hạn quá 2 lần; `make fuzz` tìm ra lỗi; token CodeQL có quyền ngoài `security-events`; 429 trên 50 % ở một operation trong 5 lượt `stack`; 20 lượt `dast` xanh; grype chặn lỗ hổng mà bản đang chạy cũng có.

## Xác nhận

- PR #28, SHA `d58e67d`, 2026-10-29: `ci.yml` 40804508919, `images.yml` 40804508815, CodeQL 40804504269 xanh, `ci-ok` và `images-ok` đạt.
- govulncheck: trước khi sửa `FAIL GO-2026-6809 stdlib@v1.27.2 (fixed in v1.27.3)`; sau: `ok govulncheck: no called vulnerability`.
- Fuzz: `make fuzz FUZZTIME=60s` 10 phút 34 s, không target nào tìm ra lỗi. Schemathesis: 4 lỗi tìm ra và sửa; job `stack` 20/20 operation, 0 lỗi.
- CodeQL: `GITHUB_TOKEN` chỉ ghi `security-events`, default setup giữ bật. grype: 14 chân qua cổng; CVE-2026-58016 (glib, 2026-10-30) có ngoại lệ.
- Kiểm sau push, số đo đủ và lệch so với quyết định: phụ lục.

## Hiện thực ở

Mã web ở repo `svp-frontend` ([ADR-0033](0033-svp-web-repo.md)); danh sách đủ ở phụ lục.

- `Makefile` (`GOVULNCHECK_VERSION`, `GRYPE_IMAGE`, `SCHEMATHESIS_IMAGE`, `make vulncheck`, `make fuzz`, `make grype`), `renovate.json`, `go.mod`, `deploy/docker/service.Dockerfile`, `deploy/docker/media-worker.Dockerfile`, `tools/vulngate/` (mục 1).
- `fuzz_test.go` ở `internal/pagetoken/`, `internal/authtoken/`, `internal/objstore/`, `services/gateway/internal/httpx/`, `services/user-service/internal/server/` (mục 2); `deploy/dast/`, `.github/workflows/ci.yml` (mục 3); cài đặt repo GitHub (mục 4).
- `deploy/ci/common.sh`, `.github/actions/image-leg/` (thay `build-image.sh` đã xoá), `deploy/ci/scan-gate.sh`, `deploy/ci/changed-services.sh`, `.github/workflows/images.yml` (mục 6).
- Hiện trạng: [`explanation/delivery.md`](../explanation/delivery.md), [`reference/ci.md`](../reference/ci.md), [`ci-cd.md`](../ci-cd.md), [`threat-model.md`](../threat-model.md).

## Nguồn

Danh sách [N1]–[N44] có ghi chú ở phụ lục.

- [govulncheck](https://pkg.go.dev/golang.org/x/vuln/cmd/govulncheck), [Go Toolchains](https://go.dev/doc/toolchain), [Go Fuzzing](https://go.dev/doc/security/fuzz/).
- [Schemathesis CLI](https://schemathesis.readthedocs.io/en/stable/reference/cli/), [CodeQL default setup](https://docs.github.com/en/code-security/code-scanning/enabling-code-scanning/configuring-default-setup-for-code-scanning), [grype](https://github.com/anchore/grype/blob/v0.121.0/README.md).

## Thông tin thêm

Phụ lục: [`appendix/0030-devsecops-supplement.md`](appendix/0030-devsecops-supplement.md) (tiêu đề và trạng thái gốc, bối cảnh, bảng lựa chọn và
nguyên văn quyết định từng mục, số đo, threat model, GitLab, kết quả kiểm có id lượt chạy, nguồn).

ADR này chỉnh [ADR-0007](0007-go-monorepo-toolchain-and-stage1-scope.md) phần module (directive `go` có số patch) và ADR-0015 §3, §6, §12.

### Chỉnh bởi

- §6: [0039](0039-mainpath-drills-scan-gate-sourcemaps.md): grype đọc `.grype.yaml` với `--fail-on critical` thay áp `.trivyignore.yaml` bằng jq; mục hết hạn bị bắt ở phép kiểm file của job `config`.
- §6: [0070](0070-scan-gate-high-fixed.md): cổng grype chặn thêm High có `vulnerability.fix.state == "fixed"`, trừ `drill-vulnerable` (`allow-critical`); High chưa có bản vá vẫn chỉ đếm.
