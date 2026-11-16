# Phụ lục ADR-0070: Cổng quét image chặn CRITICAL và HIGH có bản vá

Phụ lục của [ADR-0070](../0070-scan-gate-high-fixed.md): bảng phương án, trường "có bản vá" ở version ghim, cờ lọc không
dùng, nền quét lúc đổi luật, nguồn. Mọi nguồn đọc ngày 2026-11-14; mã nguồn đọc ở tag của version ghim trong `Makefile`
(`TRIVY_IMAGE` trivy 0.76.0, `GRYPE_IMAGE` grype 0.121.0).

## Phương án

| Phương án | Trạng thái ngành | Được | Mất | Nguồn |
| --- | --- | --- | --- | --- |
| Giữ chỉ chặn CRITICAL | Luật trước đây của repo này ([0015](../0015-cicd-devsecops-stage5.md) §6) | Không PR nào đỏ vì HIGH | HIGH sửa được bằng một bump vẫn lên registry; sửa nhờ người đọc SARIF | [N11], [N12] |
| Chặn mọi HIGH | Công cụ có sẵn: ngưỡng severity (`--exit-code` với `--severity HIGH,CRITICAL` của trivy, `--fail-on high` của grype) | Chặt nhất, một cờ | HIGH chưa có bản vá của Alpine, Debian làm mọi phát hành đứng; ngoại lệ thành thường trực | [N11], [N12] |
| **Chặn CRITICAL và HIGH có bản vá** | Công cụ có sẵn điều kiện có bản vá (`--ignore-unfixed`, `--only-fixed`), nhưng cho mọi mức; ở đây chỉ cho HIGH | Chặn đúng phần sửa được bằng bump; HIGH chưa vá vẫn chỉ báo | Một bước kiểm thứ hai đọc trường của report; PR có thể đỏ khi DB vừa có bản vá | [N1]–[N3], [N5], [N7]–[N9], [N11] |
| Chặn theo EPSS hay KEV | Đang lên: grype đưa KEV, EPSS vào report | Chặn theo rủi ro thật, ít chặn hơn | trivy không có trường EPSS, KEV trong report; grype có `epss`, `knownExploited`; cả hai máy quét cần thêm nguồn dữ liệu; KEV chỉ có lỗ hổng đã bị khai thác | [N10], [N13] |

## Trường "có bản vá" ở version ghim

### trivy 0.76.0

- Mỗi mục `Results[].Vulnerabilities[]` có trường `Status` kiểu `types.Status` của `trivy-db`, `json:",omitempty"` [N1].
  trivy 0.76.0 ghim `github.com/aquasecurity/trivy-db v0.0.0-20261012084708-cbebf2ecd6df` [N4].
- `types.Status` ghi ra JSON là chuỗi, một trong `unknown`, `not_affected`, `affected`, `fixed`, `under_investigation`,
  `will_not_fix`, `fix_deferred`, `end_of_life`; giá trị 0 là `unknown`, nên `omitempty` bỏ trường khi trạng thái không
  rõ [N2].
- `FillInfo` đặt `Status = fixed` khi mục có `FixedVersion`; không có thì giữ trạng thái nhà cung cấp đã ghi (ví dụ
  `will_not_fix` của Red Hat), hay đặt `affected` khi trạng thái là `unknown` [N3]. Vậy `Status == "fixed"` đúng khi và
  chỉ khi mục có `FixedVersion`. Mục không có trường `Status` không bằng `"fixed"` trong jq, nên được tính là chưa có
  bản vá.
- `trivy convert` đọc lại `Status` từ report bằng `UnmarshalJSON` của cùng kiểu [N2].
- Phần thông tin lỗ hổng nhúng trong mục (`types.Vulnerability` của `trivy-db`) không có trường EPSS hay KEV; trường
  `Severity` ở đó đánh dấu deprecated, giữ tới schema DB v3 [N13]. Cổng hiện có và bước (b) cùng đọc `Severity`: lên DB
  v3 thì đọc lại cả hai.

### grype 0.121.0

- `vulnerability.FixState` là một trong `fixed`, `not-fixed`, `wont-fix`, `unknown` [N7].
- JSON của grype ghi nó ở `matches[].vulnerability.fix.state`, cạnh `fix.versions` [N8]; severity ở
  `matches[].vulnerability.severity`, dạng `Critical`, `High` (cổng hiện có đã đọc như vậy, `deploy/ci/scan-gate.sh`).
- `VulnerabilityMetadata` của JSON có `knownExploited` (KEV) và `epss` [N10].

## Cờ lọc không dùng

- trivy: `--ignore-unfixed` là cách viết tắt của `--ignore-status` với mọi trạng thái trừ `fixed` [N5]: nó bỏ khỏi
  report mọi mục chưa có bản vá, ở mọi mức, nên CRITICAL chưa vá cũng mất và luật (a) không còn gì để chặn.
  [0015](../0015-cicd-devsecops-stage5.md) §6 đã loại nó vì cùng lý do.
- `trivy convert` chỉ nhận nhóm cờ global, `--scanners` và nhóm cờ report; nhóm cờ vulnerability (`--ignore-unfixed`,
  `--ignore-status`) không có ở lệnh này [N6]. Lọc theo bản vá trên report đã có chỉ làm được bằng trường `Status`.
- grype: `--only-fixed` (`only-fixed` trong cấu hình) bỏ mọi match của lỗ hổng chưa có bản vá [N9]. Lệnh [G4] ở
  [phụ lục 0039](0039-mainpath-drills-scan-gate-sourcemaps.md#xác-nhận) thấy nó bỏ một Critical chưa vá khỏi kết quả,
  nên không dùng ở cổng, và phép kiểm `.grype.yaml` từ chối khoá đó.
- Đọc trường trên report đã có giữ một lần quét mỗi máy quét mỗi chân: attestation `vuln` và SARIF vẫn đọc đúng report
  mà cổng đọc.

## Nền quét

HIGH có bản vá ở các image của `main` lúc bật luật, và cách xử lý từng mục (bump hay ngoại lệ theo §3 của ADR).

Quét ngày 2026-11-14 trên image ghim ở `envs/stg/images/` của `svp-gitops` (backend tag `a8da55c7858d`, web tag
`8a76df7d0342`), cả `linux/amd64` và `linux/arm64`: `make grype IMAGE=<ref>@<digest> ARCH=<arch>` (grype 0.121.0, kéo
GHCR ẩn danh) cho mọi image, và trivy 0.76.0 (`trivy image --scanners vuln` với `.trivyignore.yaml`) cho `gateway`,
`media-worker`. Hai máy quét cho cùng kết quả ở image backend; grype ghi lỗ hổng của x/net bằng id `GO-2026-6860`, trivy
bằng `CVE-2026-78661`.

| Image | CVE | Gói | Bản đang có | Bản vá | Cách xử lý |
| --- | --- | --- | --- | --- | --- |
| `gateway`, `user-service`, `video-service`, `engagement-service`, `feed-service`, `media-worker` | CVE-2026-78661 (`GO-2026-6860`) | `golang.org/x/net` | v0.61.0 | 0.62.0 | Bump `go get golang.org/x/net@v0.62.0` + `go mod tidy`; chỉ dòng `golang.org/x/net` của `go.mod` đổi, không module nào khác. `make vulncheck` sau bump không còn lỗ hổng của x/net |
| `web` (`svp-frontend`) | CVE-2026-76844, CVE-2026-85091 | `zlib1g` (Debian 13) | `1:1.3.dfsg+really1.3.1-1+b1` | `1:1.3.dfsg+really1.3.1-1+deb13u1` | Sửa ở `svp-frontend` (bump base image hay gói) trước khi PR Renovate `backend-commit` kéo luật này về chân web (§6 của ADR) |

- Không image nào có CRITICAL sau file ignore, và không HIGH có bản vá nào nằm ở base image hay Go stdlib của image
  backend: hai Dockerfile không đổi.
- `media-worker` còn 36 HIGH chưa có bản vá trong nhánh Alpine 3.24 (grype), chỉ báo. Stage runtime của
  `deploy/docker/media-worker.Dockerfile` chạy `apk upgrade` rồi `apk add ffmpeg` không ghim version, nên một build mới
  tự lấy bản vá khi nhánh 3.24 có nó, cùng lúc DB của máy quét ghi mục đó là có bản vá.
- Ngoại lệ hiện có của `glib` (CVE-2026-58016, `.trivyignore.yaml`) còn hạn, không đổi; không cần ngoại lệ mới.

## Nguồn

- [N1] trivy v0.76.0,
  [`pkg/types/vulnerability.go`](https://github.com/aquasecurity/trivy/blob/v0.76.0/pkg/types/vulnerability.go):
  `DetectedVulnerability` có `FixedVersion`, `Status types.Status`.
- [N2] trivy-db `cbebf2ecd6df`,
  [`pkg/types/status.go`](https://github.com/aquasecurity/trivy-db/blob/cbebf2ecd6df/pkg/types/status.go): danh sách
  `Statuses`, `MarshalJSON`, `UnmarshalJSON`.
- [N3] trivy v0.76.0,
  [`pkg/vulnerability/vulnerability.go`](https://github.com/aquasecurity/trivy/blob/v0.76.0/pkg/vulnerability/vulnerability.go):
  `FillInfo` đặt `fixed` theo `FixedVersion`.
- [N4] trivy v0.76.0, [`go.mod`](https://github.com/aquasecurity/trivy/blob/v0.76.0/go.mod): version của `trivy-db`.
- [N5] trivy v0.76.0,
  [`pkg/flag/vulnerability_flags.go`](https://github.com/aquasecurity/trivy/blob/v0.76.0/pkg/flag/vulnerability_flags.go):
  `--ignore-unfixed` thành `--ignore-status` mọi trạng thái trừ `fixed`.
- [N6] trivy v0.76.0, [`pkg/commands/app.go`](https://github.com/aquasecurity/trivy/blob/v0.76.0/pkg/commands/app.go):
  `NewConvertCommand`.
- [N7] grype v0.121.0,
  [`grype/vulnerability/fix.go`](https://github.com/anchore/grype/blob/v0.121.0/grype/vulnerability/fix.go): `FixState`.
- [N8] grype v0.121.0,
  [`grype/presenter/models/vulnerability.go`](https://github.com/anchore/grype/blob/v0.121.0/grype/presenter/models/vulnerability.go):
  `Fix` với `json:"state"`, `json:"versions"`.
- [N9] grype v0.121.0,
  [`cmd/grype/cli/options/grype.go`](https://github.com/anchore/grype/blob/v0.121.0/cmd/grype/cli/options/grype.go):
  `--only-fixed`, "ignore matches for vulnerabilities that are not fixed".
- [N10] grype v0.121.0,
  [`grype/presenter/models/vulnerability_metadata.go`](https://github.com/anchore/grype/blob/v0.121.0/grype/presenter/models/vulnerability_metadata.go):
  `knownExploited`, `epss`.
- [N11] NIST SP 800-190, Application Container Security Guide (2017), §4.1.1 Image vulnerabilities, ý 3: "Policy-driven
  enforcement; organizations should be able to create “quality gates” at each stage of the build and deployment process
  to ensure that only images that meet the organization's vulnerability and configuration policies are allowed to
  progress" (Chính sách cưỡng chế: tổ chức tạo được "cổng chất lượng" ở mỗi bước build và triển khai để chỉ image đạt
  chính sách lỗ hổng và cấu hình của tổ chức mới đi tiếp). <https://doi.org/10.6028/NIST.SP.800-190>
- [N12] [Phụ lục 0015 §6](0015-cicd-devsecops-stage5.md#6-quét-lỗ-hổng-và-bí-mật-trước-khi-push), bảng lựa chọn: lý do
  loại "chặn cả HIGH" và `--ignore-unfixed`.
- [N13] trivy-db `cbebf2ecd6df`,
  [`pkg/types/types.go`](https://github.com/aquasecurity/trivy-db/blob/cbebf2ecd6df/pkg/types/types.go): `Vulnerability`
  (`Severity` deprecated, không trường EPSS, KEV).
