# 0050. Bash tự viết của đường chính nhường cho công cụ chuẩn: bootstrap EKS bằng GitOps Bridge, diễn tập bằng Chainsaw, kiểm cấu hình bằng JSON Schema và conftest, đường dev k3d bằng helmfile và Reloader; bỏ adapter CI và đường quay lại MinIO

- Trạng thái: Chấp nhận
- Ngày: 2026-11-05
- Người quyết: người học

## Bối cảnh và vấn đề

[0037](0037-mainpath-standard-tools.md) đặt luật: đường chính (stg, prd, CI) dùng công cụ chuẩn, bỏ tương thích ngược sau một bản phát
hành. Luật đó chỉ được áp cho promote, DORA và check của `svp-gitops`. Bash vẫn là nơi chứa phần lớn logic: lúc nhiều nhất là 101 file,
39 882 dòng; lúc kiểm kê còn 73 file, 25 271 dòng. Trong số đó:

- 6 864 dòng là test bash cho chính bash;
- bootstrap EKS (`gitops.sh`, `secrets.sh`) khoảng 1 000 dòng, chạy thật ở stg và prd;
- diễn tập k8s 3 366 dòng, `gitops-check.sh` 1 165 dòng, đường dev k3d (`install.sh` cùng phần cluster của `lib.sh`) khoảng 2 000 dòng.

Còn hai phần sót của luật cũ:

- adapter CI `platform.sh` đã đóng băng ([0037](0037-mainpath-standard-tools.md) §2) nhưng vẫn còn khoảng 84 lời gọi `ci_*`, cùng một
  file test 1 863 dòng;
- đường quay lại MinIO ([0022](0022-local-object-store-minio-replacement.md)) giữ `object-store-copy.sh` cùng test 913 dòng. Máy của
  người học không còn volume `svp_minio-data`.

Kiểm kê từng script, kèm phương án thay và công sức, nằm ở [phụ lục](appendix/0050-bash-to-standard-tools.md).

## Yếu tố quyết định

- Công cụ của đường chính phải là thứ gặp ở công ty, có người dùng và tài liệu ngoài lab.
- Logic khai báo được (cài chart, luật trên file, ca diễn tập) thì viết khai báo, không viết vòng lặp và hàm chờ bằng bash.
- Mỗi luật chỉ được viết một lần. Hiện bảng nguồn phát hành, kiểm bản phát hành, ghim digest và route Alertmanager đều đang có hai hay
  ba bản.
- Ca âm của test hiện có phải còn nguyên trong công cụ mới.

## Phương án đã cân nhắc

Trạng thái lấy tại ngày quyết; tên đậm là phương án được chọn.

1. **Bootstrap EKS.** Phương án:
   - A. **GitOps Bridge**: Terraform `helm_release` cài Argo CD và root app; metadata của cluster thành annotation của cluster Secret.
     Đây là mẫu hiện hành của EKS Blueprints [N1].
   - B. Giữ bash.
   - C. Argo CD Autopilot: cũ dần.
2. **Diễn tập k8s.** Phương án:
   - A. **Chainsaw** [N2]: hiện hành, của dự án Kyverno; ca khai báo apply, assert, expect lỗi admission.
   - B. kuttl: tiền thân, cũ dần.
   - C. Go e2e-framework: hiện hành, nhưng phải viết nhiều code.
   - D. Giữ bash.
3. **Kiểm cấu hình** (check `svp-gitops`, file ngoại lệ của cổng quét, bảng nguồn). Phương án:
   - A. **JSON Schema (`check-jsonschema`, `values.schema.json`) cho hình dạng file, conftest (Rego) cho luật chéo file** [N3]; ca âm giữ
     bằng `conftest verify`.
   - B. JSON Schema cùng Kyverno CLI: Kyverno hợp với manifest k8s hơn là với file YAML tuỳ ý.
   - C. Giữ bash.
4. **Đường dev k3d.** Phương án:
   - A. **helmfile cùng Reloader** [N4], [N5]: `helmfile sync` theo `needs` thay các wave cài tay; Reloader restart khi Secret đổi;
     `docker buildx bake` cho image dev.
   - B. Tilt: hợp với vòng sửa code liên tục trên cluster, nặng hơn.
   - C. Bỏ đường dev, chỉ dùng đường GitOps: vòng sửa rồi chạy chậm vì phải qua git.
   - D. Giữ bash.

## Kết quả quyết định

Chọn phương án A ở cả bốn mục. Ngoài ra:

1. **Bỏ hẳn adapter CI.** Script đọc biến `GITHUB_*` và gọi `gh` trực tiếp. Ngoài Actions thì output và summary in ra stdout, không che
   giá trị, không ghi gì qua API. Chi tiết này thay câu "đóng băng, xoá dần" của [0037](0037-mainpath-standard-tools.md) §2.
2. **Bỏ đường quay lại MinIO.** RustFS là object store duy nhất của đường local; khi cần đổi store thì dùng công cụ sao chép S3 chuẩn
   (`mc mirror`, `rclone`). Thay câu "MinIO Chainguard là đường quay lại" của [0022](0022-local-object-store-minio-replacement.md).
3. **Thứ tự làm**, mỗi bước là một PR mỗi repo, xanh rồi mới sang bước sau:
   - dọn những gì không cần công cụ mới (adapter, MinIO, `last-success.sh`);
   - bootstrap EKS, làm cùng môi trường prd;
   - kiểm cấu hình;
   - diễn tập;
   - pipeline image;
   - đường dev k3d;
   - diễn tập compose chuyển sang `svp-labs`.
4. **Bash còn lại là glue ngắn**: đọc `.env`, gọi công cụ theo thứ tự, guard context. Bản tự viết còn giá trị học thì chuyển sang
   `svp-labs` theo luật của [0039](0039-mainpath-drills-scan-gate-sourcemaps.md).

### Hệ quả

- Tốt:
  - đường chính đọc được bằng tài liệu của công cụ;
  - ước bỏ khoảng 16 000 dòng bash;
  - mỗi luật còn một bản.
- Xấu:
  - thêm sáu công cụ phải ghim và cập nhật: Terraform helm provider, Chainsaw, conftest, check-jsonschema, helmfile, Reloader;
  - Rego là ngôn ngữ mới;
  - mỗi bước đổi script dùng chung thì phải đổi cùng lượt ở `svp-frontend` (pipeline image) và `CHECKER_COMMIT` của `svp-gitops`;
  - bootstrap EKS chuyển sang Terraform nên người học chạy, AI chỉ soạn.
- Xem lại khi: một công cụ được chọn ngừng bảo trì; một bước tốn quá xa ước lượng trong phụ lục.

## Xác nhận

- Mỗi bước: các test của phần bị thay chuyển thành ca của công cụ mới, CI xanh, và số dòng bash giảm đúng như ước lượng.
- Bootstrap EKS: một buổi stg dựng được cluster từ `terraform apply` cùng Argo CD, không còn chạy `make eks-gitops-up`.

## Hiện thực ở

- Kế hoạch theo bước và kiểm kê: [phụ lục](appendix/0050-bash-to-standard-tools.md). Từng bước thêm file hiện thực vào đây khi merge.
- Bỏ adapter CI (mục 1): `deploy/ci/platform.sh`, `platform-test.sh` (xoá); script của `deploy/ci/`, `deploy/k8s/` đọc biến `GITHUB_*`
  và gọi `gh` trực tiếp, helper chung `step_output`, `step_summary`, `step_summary_tee`, `run_repo_url`, `run_builder_id` ở
  `deploy/ci/common.sh`; ca test chuyển sang `deploy/ci/plan-test.sh`, `scan-gate-test.sh`, `vuln-predicate-test.sh`,
  `sign-image-test.sh`, `rescan-test.sh`, `verify-release-test.sh`, `changed-services-test.sh`, `verify-collect-test.sh`,
  `sources-test.sh`; job `config` của `.github/workflows/ci.yml`; `deploy/ci/changed-services.sh` (mọi `*-test.sh` không build image).
- Kiểm cấu hình (mục 3), tệp ngoại lệ của cổng quét: luật của `.trivyignore.yaml`, `.grype.yaml`, `deploy/ci/trivy-config-ignore.yaml` là
  policy Rego ở `deploy/ci/ignorefile-policies/` (`lib.rego`, `trivyignore.rego`, `grypeignore.rego`, `configignore.rego`, ca âm ở
  `*_test.rego`), thay ba parser awk của `deploy/ci/scan-gate.sh`; `check_ignorefiles` của script đó chạy `conftest test --combine`
  bằng `CONFTEST_IMAGE` ghim của `Makefile`, cộng hai phép kiểm policy không làm được (khoá viết hai lần, qua yq `YQ_IMAGE`; path là file
  có thật); `make conftest-verify` ở job `config`; `deploy/ci/scan-gate-test.sh` còn các ca của phần bash; đổi policy không build image
  (`deploy/ci/changed-services.sh`).
- Kiểm cấu hình (mục 3), check của `svp-gitops` (B1 của phụ lục), luật trên file của cây: policy Rego ở `deploy/ci/gitops-tree-policies/`
  (`layout.rego` file của root chart và bootstrap, `argocd/apps/values.yaml` không đặt `cluster`; `envs.rego` thư mục env, `charts.yaml`
  với giá trị dẫn xuất, `images/` với nguồn phát hành; `platforms.rego` lớp nền tảng và luật overlay của file nền tảng; `author.rego` luật
  tác giả hẹp; input và helper ở `lib.rego`; ca âm ở `*_test.rego`, chạy bằng `make conftest-verify`). Bước 1 của
  `deploy/ci/gitops-check.sh` chỉ dựng input JSON (mục và nội dung file của cây; `revision` trên `main`, giá trị dẫn xuất và bảng nguồn
  đọc bằng git; tác giả, người gửi, file đổi của PR) rồi chạy `conftest test` bằng `CONFTEST_IMAGE`, không trả lời là đỏ; render, kubeconform,
  Kyverno CLI và kiểm bản phát hành ở lại script; `deploy/ci/gitops-check-test.sh` còn ca của phần bash, render và một ca mỗi phần input.
- Một bản luật bảng nguồn (B3 của phụ lục): luật chỉ ở `fail` của `deploy/helm/svp-policy/templates/imagevalidatingpolicy.yaml`;
  `deploy/k8s/lib.sh` bỏ `_release_sources_check`, `release_sources` đọc bảng và chỉ giữ bất biến prefix (đường dẫn registry kết thúc bằng `/`, không prefix nào là
  đầu prefix khác) mà mọi script dựa vào trước khi chọn nguồn; `deploy/ci/sources-test.sh` kiểm luật bằng render (không thêm công cụ), cùng hai hàm chọn nguồn đó.

## Thông tin thêm

- Phụ lục: [kiểm kê và ước lượng](appendix/0050-bash-to-standard-tools.md).

## Nguồn

- Tính đến 2026-11-05. [N1] [GitOps Bridge](https://github.com/gitops-bridge-dev/gitops-bridge), mẫu
  [EKS Blueprints: GitOps getting started (Argo CD)](https://aws-ia.github.io/terraform-aws-eks-blueprints/patterns/gitops/gitops-getting-started-argocd/).
- [N2] [Chainsaw](https://kyverno.github.io/chainsaw/latest/).
- [N3] [Conftest](https://www.conftest.dev/), [check-jsonschema](https://check-jsonschema.readthedocs.io/).
- [N4] [Helmfile](https://helmfile.readthedocs.io/).
- [N5] [Reloader](https://github.com/stakater/Reloader).
