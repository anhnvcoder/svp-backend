# 0070. Cổng quét image chặn CRITICAL và HIGH có bản vá

- Trạng thái: Chấp nhận
- Ngày: 2026-11-14
- Người quyết: người học, AI đề xuất

## Bối cảnh và vấn đề

- Cổng quét trước push chặn bí mật mọi mức và CRITICAL còn lại sau file ignore, kể cả chưa có bản vá; HIGH chỉ báo qua
  SARIF và job summary, MEDIUM, LOW chỉ nằm trong report JSON ([0015](0015-cicd-devsecops-stage5.md) §6,
  [0030](0030-devsecops-supplement.md) §6, cờ của công cụ theo [0039](0039-mainpath-drills-scan-gate-sourcemaps.md) §2).
- 0015 §6 loại "chặn cả HIGH" vì base Alpine + ffmpeg hay có HIGH chưa có bản vá: mọi phát hành sẽ đứng vì việc ngoài
  tầm tay. Cái giá nó ghi là HIGH có bản vá chỉ hiện ở báo cáo, có thể nằm lâu nếu không ai đọc; nó hẹn xem lại khi HIGH
  có bản vá còn mở quá 30 ngày.
- HIGH có bản vá là lỗ hổng nặng mà một lần bump module, gói hay base image sửa được. Để nó qua cổng thì sửa phụ thuộc
  vào người đọc SARIF.

## Yếu tố quyết định

- Không image nào lên registry khi lỗ hổng nặng của nó sửa được bằng một bump.
- Phát hành không đứng vì lỗ hổng chưa ai vá (lý do của 0015 §6 vẫn đúng).
- Một nghĩa cho trivy và grype, tính từ chính report đã có; không lượt quét thứ hai, không cờ lọc làm mất CRITICAL.
- Không đổi điều kiện admission và rescan: một HIGH mới công bố không được làm pod mới bị từ chối.

## Phương án đã cân nhắc

Trạng thái ngành, được, mất, nguồn: [phụ lục](appendix/0070-scan-gate-high-fixed.md#phương-án).

- Giữ chỉ chặn CRITICAL: HIGH có bản vá vẫn lên registry, sửa nhờ người đọc báo cáo.
- Chặn mọi HIGH: chặt nhất, nhưng HIGH chưa vá của Alpine, Debian làm phát hành đứng (lý do loại của 0015 §6).
- **Chặn CRITICAL và HIGH có bản vá**: chặn đúng phần sửa được; HIGH chưa vá vẫn chỉ báo.
- Chặn theo EPSS hay KEV: grype có `epss`, `knownExploited` trong JSON nhưng trivy không; áp cho cả hai máy quét cần
  thêm nguồn dữ liệu. Để sau.

## Kết quả quyết định

Chọn chặn CRITICAL và HIGH có bản vá, vì nó chặn mọi lỗ hổng nặng sửa được bằng bump mà không đặt lại vấn đề HIGH chưa
vá mà 0015 §6 đã tránh.

### 1. Luật chặn

Image bị chặn trước push khi trivy hoặc grype, sau file ignore, thấy:

- (a) bất kỳ CRITICAL nào, có bản vá hay không, như hiện nay;
- (b) HIGH có bản vá. trivy: mục `Severity == "HIGH"` có `Status == "fixed"` trong JSON của
  `trivy convert --format json` (cùng `--ignorefile`); grype: mục `vulnerability.severity == "High"` có
  `vulnerability.fix.state == "fixed"` trong `grype.json`.

Bước (b) chạy sau (a), trên cùng report. Bí mật giữ luật hiện có. HIGH chưa có bản vá chỉ báo (SARIF, job summary);
MEDIUM, LOW chỉ nằm trong report JSON và attestation `vuln`. Luật áp ở chân image `.github/actions/image-leg/` và ở các
chế độ trivy, grype của `deploy/ci/scan-gate.sh` (`make grype`). Hai máy quét dùng DB và cách khớp khác nhau, nên mỗi
cái chặn riêng: một trong hai thấy là đủ.

Ngoại lệ duy nhất ở `image-leg` là chân `drill-vulnerable`: output `allow-critical` của `deploy/ci/image-guard.sh` cho
qua cả (a) lẫn (b), không bao giờ bí mật. Image đó (`deploy/ci/drill/vulnerable.Dockerfile`) cố ý mang lỗ hổng để
diễn tập Kyverno từ chối, không phát hành; (b) chặn nó thì diễn tập admission không còn image để thử.

### 2. Tính từ trường của report, không cờ lọc

`Status` của trivy là `fixed` đúng khi mục có `FixedVersion`; `fix.state` của grype là một trong `fixed`, `not-fixed`,
`wont-fix`, `unknown` (nguồn ở [phụ lục](appendix/0070-scan-gate-high-fixed.md#trường-có-bản-vá-ở-version-ghim)). Không
dùng `--ignore-unfixed` của trivy hay `--only-fixed` của grype: cả hai bỏ mọi mục chưa vá ở mọi mức, kể cả CRITICAL mà
(a) phải chặn. `trivy convert` cũng không nhận `--ignore-unfixed`. Đọc trường trên report đã có giữ một lần quét mỗi máy
quét mỗi chân.

### 3. Ngoại lệ

Luật hiện có của `.trivyignore.yaml` (hạn ≤ 30 ngày, `statement`, `purls`) và `.grype.yaml` (mỗi rule ứng một mục trivy
còn hạn). Ngoại lệ cho HIGH có bản vá chỉ khi build không cài được bản vá (ví dụ bản vá chỉ có ở nhánh Alpine sau);
`statement` nêu version có bản vá và vì sao chưa dùng được. Có bản vá trong cùng nhánh base (bản vá của base hay gói)
thì bump, không ngoại lệ.

### 4. Ngày đổi luật

HIGH có bản vá đang có ở các image của `main` được sửa trong cùng thay đổi bật luật: bump module, gói hay base image;
ngoại lệ có hạn theo §3 chỉ cho mục không cài được bản vá. Luật chặn ngay, không có thời gian chỉ báo trước. Danh sách
lúc đổi luật và cách xử lý từng mục ở [phụ lục](appendix/0070-scan-gate-high-fixed.md#nền-quét).

### 5. Admission, attestation và rescan không đổi

- Policy Kyverno `svp-images` vẫn chỉ từ chối attestation `vuln` có CRITICAL; `deploy/ci/vuln-predicate.sh` không đổi.
- Rescan hằng ngày (`deploy/ci/rescan.sh`) gọi `scan-gate.sh --allow-critical`; cờ đó cho qua cả (a) lẫn (b), nên rescan
  vẫn attest kết quả thật và chỉ đỏ khi có CRITICAL. Nếu (b) chặn rescan attest, attestation quá 72 giờ và Kyverno từ
  chối pod mới của image đang chạy, chỉ vì một HIGH công bố sau ngày build.
- HIGH có bản vá xuất hiện sau ngày build hiện ở code scanning qua SARIF của rescan; Renovate mở PR bump, và PR đó qua
  cổng của §1.

### 6. svp-frontend

Chân image `web` của `svp-frontend` dùng chính action `image-leg` của commit backend ghim ở `.backend-commit` của repo
đó. Luật mới áp cho chân web khi PR Renovate `backend-commit` kéo một commit backend có thay đổi này; chân web đỏ vì
HIGH có bản vá thì sửa ở `svp-frontend` (bump base image, gói, hay ngoại lệ theo §3) trước khi PR đó merge.

### Hệ quả

- Tốt: HIGH sửa được bằng bump không lên registry; cổng nói đúng một nghĩa ở trivy, grype và ở hai repo dùng
  `image-leg`; admission, rescan giữ nguyên nên không có đường làm pod đang chạy bị từ chối vì HIGH.
- Xấu: một PR không liên quan có thể đỏ vì DB của trivy hay grype vừa có bản vá cho một HIGH; sửa bằng bump hay ngoại lệ
  trước khi merge. Cổng build và admission khác luật: image đã phát hành có thể mang HIGH có bản vá tới lượt build sau.
  Hai máy quét có thể bất đồng về `fixed`; bất kỳ cái nào thấy là chặn.
- Xem lại khi: HIGH có bản vá làm đỏ quá 2 PR không liên quan một tháng; ngoại lệ cho HIGH gia hạn quá 2 lần; trivy có
  trường EPSS hay KEV trong report.

## Xác nhận

- Đã kiểm ngày 2026-11-14 trên mã nguồn ở version ghim trong `Makefile` (trivy 0.76.0, grype 0.121.0): tên và giá trị
  của `Status`, `fix.state`, cờ của `trivy convert`, hành vi của `--ignore-unfixed`, `--only-fixed`
  ([phụ lục](appendix/0070-scan-gate-high-fixed.md#trường-có-bản-vá-ở-version-ghim)).
- Còn lại: test của `scan-gate.sh` và của bước (b) ở `image-leg` với fixture có HIGH `fixed`, HIGH chưa vá, CRITICAL
  chưa vá, cả với `allow-critical`; một lượt `images.yml` xanh trên PR bật luật; chân web ở PR Renovate
  `backend-commit` của `svp-frontend`.

## Hiện thực ở

- `.github/actions/image-leg/action.yml`: bước (b) của trivy và grype ở chân image của hai repo (§1).
- `deploy/ci/image-guard.sh`: output `allow-critical` chỉ cho `drill-vulnerable`, cho qua (a) và (b) (§1).
- `deploy/ci/scan-gate.sh`: chế độ trivy và `--grype` (`make grype`), `--allow-critical` cho qua (a) và (b) (§1, §5).
- `.trivyignore.yaml`, `.grype.yaml`: ngoại lệ (§3).
- Hiện trạng: [`reference/ci.md`](../reference/ci.md), [`ci-cd.md`](../ci-cd.md),
  [`explanation/delivery.md`](../explanation/delivery.md).

## Nguồn

- NIST SP 800-190 §4.1.1, Application Container Security Guide: <https://doi.org/10.6028/NIST.SP.800-190>
- Trivy v0.76.0: <https://github.com/aquasecurity/trivy/tree/v0.76.0>; Grype v0.121.0:
  <https://github.com/anchore/grype/tree/v0.121.0>
- File và dòng đã đọc: [phụ lục](appendix/0070-scan-gate-high-fixed.md#nguồn).

## Thông tin thêm

Phụ lục: [`appendix/0070-scan-gate-high-fixed.md`](appendix/0070-scan-gate-high-fixed.md) (bảng phương án, trường "có
bản vá" ở version ghim, cờ lọc không dùng, nền quét lúc đổi luật, nguồn).

ADR này chỉnh [0015](0015-cicd-devsecops-stage5.md) §6, [0030](0030-devsecops-supplement.md) §6,
[0039](0039-mainpath-drills-scan-gate-sourcemaps.md) §2.
