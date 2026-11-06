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
5. **Restart theo Secret là việc của Reloader trên mọi nền tảng** (k3d dev, k3d GitOps, EKS): Secret do External Secrets làm mới ở stg,
   prd cũng cần restart, và một danh sách component phục vụ cả hai đường. Workload opt in bằng annotation theo tên Secret
   (`secret.reloader.stakater.com/reload`, không `auto`); `reloadStrategy: annotations` ghi annotation vào pod template như
   `kubectl rollout restart`, diff của Argo CD không thấy nó; Rollout restart bằng `spec.restartAt`, không có revision mới. Script không
   restart, không chờ client: `make k8s-secrets` và `make eks-secrets` mỗi lần làm đủ một lượt xoay credential theo thứ tự máy chủ, rồi
   Job init của `svp-data`, rồi client, có barrier chờ máy chủ chạy giá trị mới trước init. Ba rủi ro chấp nhận:
   - Rollout đang canary lúc Secret của nó đổi thì để Reloader và Argo Rollouts xử lý như mọi restart, script không chặn;
   - `reloadOnCreate: false` (Reloader v1.4 dùng chung một cờ cho mọi watcher, bật thì restart cả cụm lúc nó khởi động): Secret tạo sau
     workload, hôm nay chỉ `svp/sentry` tuỳ chọn, chỉ tới workload ở lần restart sau. Xem lại khi Reloader v2 ổn định;
   - Reloader ghi hash SHA của data Secret vào pod template (`reloader.stakater.com/last-reloaded-from`), manifest đó có thể vào
     artifact công khai: data các Secret opt in là giá trị ngẫu nhiên dài, hash không cho đoán ngược.

   Thay luồng xoay "sửa `.env`, `make k8s-secrets`, rồi `make k8s-up`" và bước tay của stg lab ở
   [0026](0026-secrets-gitops.md) §7.
6. **Kịch bản `dev-k3d` trở lại `verify.yml`, chỉ dispatch**: không chỗ nào khác chạy đường dev (máy 16 GB không chạy k3d). Nó chỉ dựng
   đường dev rồi kiểm `make k8s-smoke`, xoay credential (`make drill-k8s-reloader`) và diễn tập chuỗi cung ứng có ca (k), ca chỉ đường
   dev chạy được; bản đo một lần (RAM, KEDA, PDB, canary, backup) vẫn là bài lab của [0039](0039-mainpath-drills-scan-gate-sourcemaps.md)
   bảng 1.

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
- Bootstrap EKS theo GitOps Bridge (mục 1): root Terraform mỗi env
  [`aws/gitops/`](https://github.com/anhnvcoder/svp-infra/tree/main/aws/gitops) và module
  [`aws/modules/gitops-bridge`](https://github.com/anhnvcoder/svp-infra/tree/main/aws/modules/gitops-bridge) của `svp-infra` (Argo CD,
  AppProject, cluster Secret mang `cluster_values`, ApplicationSet tạo root); Secret nguồn của EKS ghi vào AWS Secrets Manager bằng
  `deploy/k8s/aws-secrets.sh` (`make eks-secrets`, test `aws-secrets-test.sh`), `deploy/k8s/glitchtip-init.sh`, helper ở `deploy/k8s/lib.sh`;
  `deploy/k8s/gitops.sh`, `secrets.sh` chỉ còn đường k3d. Check của `svp-gitops` render nền tảng `eks` với
  `deploy/ci/cluster-values.example.yaml` đứng thay giá trị bridge đặt, root hai tầng và env có ghim `gitopsRevision`
  (`deploy/ci/gitops-check.sh`, ca ở `gitops-check-test.sh`, luật khoá ở `deploy/ci/gitops-tree-policies/envs.rego`).
- Một bản luật bảng nguồn (B3 của phụ lục): luật chỉ ở `fail` của `deploy/helm/svp-policy/templates/imagevalidatingpolicy.yaml`;
  `deploy/k8s/lib.sh` bỏ `_release_sources_check`, `release_sources` đọc bảng và chỉ giữ bất biến prefix (đường dẫn registry kết thúc bằng `/`, không prefix nào là
  đầu prefix khác) mà mọi script dựa vào trước khi chọn nguồn; `deploy/ci/sources-test.sh` kiểm luật bằng render (không thêm công cụ), cùng hai hàm chọn nguồn đó.
- Diễn tập k8s (mục 2; E1, E2 của phụ lục): Chainsaw ghim `CHAINSAW_VERSION` của `Makefile` (cài ở `make tools`), config
  `deploy/k8s/drills/.chainsaw.yaml`, StepTemplate chung `deploy/k8s/drills/templates/`, test `deploy/k8s/drills/threats/<ID>/`,
  `supplychain/case-<chữ>/` (helper `supplychain/lib.sh`), `gitops/<mục>/`; `make drill-k8s-threats`, `drill-k8s-supplychain`,
  `drill-k8s-gitops` (`deploy/k8s/k8s.mk`) chạy chúng qua glue `deploy/k8s/drills/run.sh` (guard context, tìm giá trị Secret trong log
  và report; test `run-test.sh`); `make chainsaw-lint` (lint, kubeconform của StepTemplate theo schema cùng tag ở
  `deploy/k8s/drills/.schemas/`); hai script diễn tập bash xoá, `deploy/k8s/drills/lib.sh` chỉ còn phần `traffic.sh` dùng; test không
  cluster của diễn tập gitops `deploy/k8s/drills/gitops/gitops-test.sh`.
- Runner `verify.yml` (C1, C2 của phụ lục): mỗi target là một bước của `.github/workflows/verify.yml` (`timeout-minutes` riêng, output vào
  file, `targets` lọc bằng `if:`), script ngắn của bước ở `deploy/ci/verify-steps/` (`steps.sh`, `supplychain.sh`, `admission-metrics.sh`,
  `objstore.sh`, mỗi script một test cạnh nó); ba kiểm cluster của kịch bản `gitops` thành test Chainsaw ở `deploy/k8s/drills/gitops/`;
  `deploy/ci/verify-collect.sh` chỉ đưa lên artifact kết quả máy đọc, `verify-collect-test.sh` còn ca của phần lọc đó, ca restart sang
  `deploy/k8s/restart-test.sh` (giai đoạn đường dev k3d xoá cùng hàm restart, xem mục cuối); runner tự viết và các file kịch bản xoá; job `config` của `.github/workflows/ci.yml` chạy
  `make chainsaw-lint` và các test trên; `deploy/ci/changed-services.sh` (script của bước không build image). Lượt `verify.yml` của
  hai kịch bản trên nhánh của giai đoạn này: **kiểm sau push**.
- Pipeline image (A1, A2, A3, A7 của phụ lục): ba composite action `.github/actions/image-leg/` (build `docker buildx build`, `docker save`,
  trivy trên tar, syft, grype, hai cổng bằng mã thoát của công cụ, push rồi so config digest), `image-index/` (`docker buildx imagetools
  create`, kiểm index đúng hai manifest đã quét), `image-sign/` (`cosign sign`, `cosign attest --type spdxjson|vuln` bằng `COSIGN_IMAGE`
  ghim, `actions/attest`); mọi công cụ chạy từ image ghim của `Makefile`. Guard còn là bash ở `deploy/ci/image-guard.sh` (test
  `image-guard-test.sh`, các bước đọc từ file action); `deploy/ci/image-gate-test.sh` chạy bước cổng của `image-leg` bằng công cụ thật trên
  fixture `deploy/ci/testdata/image-gate/`. Job `build-nopush`, `build`, `merge`, `sign`, `drill-*` của `.github/workflows/images.yml` gọi
  action; `build-image.sh`, `push-image.sh`, `merge-index.sh`, `sign-image.sh` xoá; `deploy/ci/scan-gate.sh` còn `--check-ignorefile`
  (cả bước đầu của mỗi chân), cổng trivy của rescan và cổng grype của `make grype`; `sign-image-test.sh` còn ca của helper bundle mà rescan
  dùng; đổi file dưới `.github/actions/image-*/` build lại mọi image (`deploy/ci/changed-services.sh`); job `config` của
  `.github/workflows/ci.yml` chạy hai test mới. Predicate `vuln` không đổi (`deploy/ci/vuln-predicate.sh`).
- Đường dev k3d (mục 4, mục 5; D1, D2 của phụ lục):
  - helmfile ghim `HELMFILE_VERSION` của `Makefile` (cài ở `make tools`): `deploy/k8s/helmfile.yaml.gotmpl` đọc
    `argocd/apps/components.json` của bản clone `svp-gitops` (không có danh sách component thứ hai), lọc component của đường dev, values
    `base/`, `needs` theo wave; `deploy/k8s/install.sh` (`make k8s-up`) chỉ còn glue: guard, image, namespace, hai lượt helmfile quanh
    `secrets.sh`, hook postsync của từng release thay các hàm chờ;
  - Reloader là component `reloader` của `svp-gitops` (`base/reloader.yaml`, AppProject `argocd/project.yaml`); annotation opt in ở chart
    `svp-service`, `svp-data` (StatefulSet `s3`), `svp-observability` (GlitchTip) và ở `base/` của Redpanda, Grafana, KEDA; namespace
    `reloader` có PSA, NetworkPolicy ở chart `svp-cluster`;
  - thứ tự xoay credential ở thư viện `deploy/k8s/rotate.sh` (test `rotate-test.sh`), dùng bởi `deploy/k8s/secrets.sh`
    (`make k8s-secrets`, cả cluster GitOps qua External Secrets), `aws-secrets.sh` (`make eks-secrets`, test `aws-secrets-test.sh`) và
    `install.sh`; `restart_on_secret_change`, `restart_workload`, `restart_brokers` cùng `deploy/k8s/restart-test.sh` xoá: hai ca canary
    hết đối tượng (không còn guard canary), hai ca restart thành bước của diễn tập `reloader`, ca âm mới ở `rotate-test.sh` bù số ca âm;
  - bảng image `deploy/docker-bake.json` (định dạng JSON của bake, không phải `docker-bake.hcl` ở gốc như phụ lục D1: bash đọc bằng
    `jq` không cần docker, test nào chép `deploy/` vào cây tạm có sẵn bảng); `deploy/k8s/lib.sh` đọc bảng lúc được source
    (`built_services`, `dockerfile`), image dev của `make k8s-up`, `make k8s-images` và sáu image của `make up` build bằng
    `docker buildx bake`, `deploy/ci/plan.sh`, `changed-services.sh` và action `image-leg` đọc cùng bảng;
  - diễn tập `make drill-k8s-reloader` (`deploy/k8s/drills/reloader/`, giá trị mới của `new-values.sh`, test glue ở
    `deploy/k8s/drills/run-test.sh`): `make k8s-secrets` với giá trị mới, mỗi workload đọc Secret đổi thay pod, mỗi giá trị mới được
    nhận và giá trị cũ bị từ chối, lượt cùng `.env` không đổi gì; chạy ở kịch bản `gitops` và kịch bản mới `dev-k3d` (chỉ dispatch,
    input `gitops_ref`) của `.github/workflows/verify.yml`. Lượt `verify.yml` của nhánh giai đoạn này: **kiểm sau push**.

## Thông tin thêm

- Phụ lục: [kiểm kê và ước lượng](appendix/0050-bash-to-standard-tools.md).

## Nguồn

- Tính đến 2026-11-05. [N1] [GitOps Bridge](https://github.com/gitops-bridge-dev/gitops-bridge), mẫu
  [EKS Blueprints: GitOps getting started (Argo CD)](https://aws-ia.github.io/terraform-aws-eks-blueprints/patterns/gitops/gitops-getting-started-argocd/).
- [N2] [Chainsaw](https://kyverno.github.io/chainsaw/latest/).
- [N3] [Conftest](https://www.conftest.dev/), [check-jsonschema](https://check-jsonschema.readthedocs.io/).
- [N4] [Helmfile](https://helmfile.readthedocs.io/).
- [N5] [Reloader](https://github.com/stakater/Reloader).
