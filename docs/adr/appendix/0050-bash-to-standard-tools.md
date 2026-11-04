# Phụ lục ADR-0050: Bash tự viết của đường chính nhường cho công cụ chuẩn

Kiểm kê từng script và ước lượng của [ADR-0050](../0050-bash-to-standard-tools.md), làm ngày 2026-11-05.

Kiểm chỉ đọc ở commit `6be8f25` (main, 2026-11-04). Không chạy make, docker, kubectl, helm, terraform; chỉ đọc file, `git grep`, `wc`.
Mục tiêu của người học: chỗ nào ngành có công cụ chuẩn thì thay, bash chỉ còn là glue ngắn. Quyết định nền: [ADR-0037](../0037-mainpath-standard-tools.md)
(đường chính theo công cụ chuẩn, adapter CI đóng băng, bỏ tương thích ngược sau một bản phát hành) và
[ADR-0039](../0039-mainpath-drills-scan-gate-sourcemaps.md) (diễn tập đo một lần sang `svp-labs`, cổng quét bằng cờ công cụ).

## Số liệu

- `git ls-files '*.sh'`: 74 mục, `wc -l` 25 312 dòng. `deploy/helm/svp-data/files/create-topics.sh` là **symlink** tới
  `deploy/redpanda/create-topics.sh` (41 dòng đếm hai lần): thực tế 73 file, 25 271 dòng.
- Theo khu vực: `deploy/ci/` 10 659 (42%), `deploy/k8s/` 7 704 (drills 3 704), `deploy/compose/drills/` 3 343, phần còn lại ~3 600.
- Test (`*-test.sh`): 9 file, 6 864 dòng (27%). Dòng comment: ~5 500 (22%; nhiều header 30–60 dòng).
- Adapter `platform.sh` (đóng băng): còn ~81 lời gọi `ci_*` ở 18 file của backend, 0 ở `svp-frontend` (lúc ADR-0037: 641 lời gọi, 37 file).
- Repo khác chạy script của repo này: `svp-frontend` (`images.yml` chạy `plan.sh`, `build-image.sh`, `push-image.sh`, `merge-index.sh`,
  `sign-image.sh`, `common.sh` từ bản checkout `.backend/`; `ci.yml` chạy `scan-gate.sh --check-ignorefile`; `Makefile` gọi
  `deploy/observability/glitchtip/sourcemaps.sh`), `svp-gitops` (`check.yml` chạy `gitops-check.sh` ở `CHECKER_COMMIT`), `svp-infra`
  (runbook `session-stg.md` gọi `make eks-gitops-up`, `eks-smoke`, `eks-seed` và `deploy/k6/cloud/run.sh`).

### Tổng theo loại đề xuất

| Loại | File | Dòng | Ghi chú |
| --- | --- | --- | --- |
| Thay bằng công cụ chuẩn (toàn phần hay một phần) | 38 | 16 152 | Ước còn ~3 500 dòng bash glue, cộng YAML/Rego/Go của công cụ mới |
| Giữ làm glue (có thể rút gọn) | 18 (+1 symlink) | 3 273 | Phần lớn dưới 150 dòng; `obs-threats.sh` 645, `eks-context-test.sh` 602, `promote-test.sh` 337, `rescan.sh` 301 là ngoại lệ có lý do |
| Chuyển sang `svp-labs` (chỉ để học, đóng băng) | 12 | 2 698 | Diễn tập compose đo một lần; khoảng 250 dòng của `drills/common.sh` ở lại cho `obs-threats.sh` |
| Xoá | 5 | 3 148 | Adapter CI + test (2 218), `object-store-copy` + test (913, cần người học xác nhận), `last-success.sh` (17) |

Thang công: **S** dưới 1 ngày, **M** 1–3 ngày, **L** hơn 3 ngày hay chạm nhiều repo. Đường: **chính** = chạy cho stg/prd thật (CI phát hành,
promote, check `svp-gitops`, buổi EKS); **kiểm định kỳ** = `verify.yml` tuần; **lab** = chỉ compose, k3d, diễn tập trên máy.

## Kiểm kê

### A. Pipeline image (`images.yml`, cũng chạy ở `svp-frontend`)

| # | Script (dòng) | Làm gì | Ai gọi | Đường | Thay bằng | Loại · công | Rủi ro, mất gì |
| --- | --- | --- | --- | --- | --- | --- | --- |
| A1 | `deploy/ci/build-image.sh` (125) | Một chân: `buildx --load`, `docker save`, trivy trên tar, syft SBOM, grype, cổng (ADR-0015, 0030 §6, 0039 §2) | `images.yml` job build; `images.yml` của `svp-frontend` | chính | Bước YAML gọi thẳng `docker buildx build`, `trivy image --input`, `syft`, `grype` bằng image ghim như nay; hay `docker/build-push-action` + `aquasecurity/trivy-action` + `anchore/sbom-action` + `anchore/scan-action` khi allowlist action mở (ADR-0037 §3) | Thay · M | Bảo đảm "quét đúng bản sẽ push" (so config digest) phải giữ: quét tar rồi đẩy chính tar đó; `build-push-action` build lại khi push thì mất. Hai repo đổi cùng lúc |
| A2 | `push-image.sh` (47), `merge-index.sh` (43) | Đẩy chân, so config digest với bản quét; ghép index amd64+arm64, kiểm đúng hai manifest | `images.yml` job push, index; `svp-frontend` | chính | `crane push image.tar` (digest không đổi) + `docker buildx imagetools create` (mẫu "distribute builds across runners" của Docker) | Thay · S | Kiểm "index đúng hai manifest" còn 3 dòng `imagetools inspect --raw \| jq` |
| A3 | `sign-image.sh` (111), `vuln-predicate.sh` (117) | Ký keyless, attest SBOM, attest `vuln` (predicate tự dựng gộp hai nền tảng), không ký trùng khi chạy lại (ADR-0040) | `images.yml` job sign; `rescan.sh`; `svp-frontend` | chính | `cosign sign`, `cosign attest --type spdxjson` (hay `actions/attest-sbom`), `trivy image --format cosign-vuln` + `cosign attest --type vuln`; provenance đã là `actions/attest` | Thay · M–L | **Hợp đồng Kyverno** đọc `predicate.scanner.result.platforms` (`imagevalidatingpolicy.yaml:23`): đổi sang predicate chuẩn của trivy phải sửa policy `svp-policy`, `verify-release.sh` và rescan trong một bản phát hành. Mất chống ký trùng khi re-run nếu bỏ `bundle_referrers` (~10 dòng nên giữ) |
| A4 | `plan.sh` (171), `changed-services.sh` (110), `last-success.sh` (17) | Chọn mode build/rescan/drill, ma trận chân, service đổi so với base; base là lượt push main thành công cuối (ADR-0015) | `images.yml` job plan; `svp-frontend` (`plan.sh`) | chính | Base: một dòng `gh run list -w images.yml -b main -e push -s success -L1 --json headSha -q '.[0].headSha'` (xoá `last-success.sh`); service đổi: `dorny/paths-filter` một filter mỗi service, hay đọc path từ `docker-bake.hcl` (D1); `plan.sh` giữ phần mode và kiểm input, ~80 dòng | `last-success` Xoá; còn lại Thay một phần · M | `changed-services.sh` giữ **danh sách loại trừ viết tay** các file `deploy/ci/` không job image nào đọc (dòng ~79–82): sang filter YAML là chép danh sách lần hai. Nên dời script `verify-*`, `gitops-check*`, test ra khỏi `deploy/ci/` để glob đơn giản. `image_paths` ở `deploy/k8s/lib.sh` dùng chung với `make k8s-up` |
| A5 | `common.sh` (778) | Thư viện: nguồn phát hành, provenance, guard promote, `yq_`, wrapper trivy/grype/cosign, referrer bundle, `release_format`, `replace_vuln_bundle` | Mọi script `deploy/ci/`; `images.yml` (promote, promote-prd); `make grype`; `svp-frontend` | chính | Wrapper trivy/grype/cosign biến mất cùng A1–A3; nhánh định dạng cũ `.sig/.att` xoá khi `envs/*/images` của `svp-gitops` không còn digest cũ (điều kiện ADR-0040 tự đặt); guard promote giữ (~60 dòng, có test) | Thay một phần · L | Ước còn ~250 dòng. Đổi hàm ở đây là đổi CI của hai repo (`svp-frontend` checkout backend ở commit ghim) |
| A6 | `platform.sh` (355), `platform-test.sh` (1 863) | Adapter CI trung lập, header ghi **FROZEN** (ADR-0023 bị thay bởi 0037 §2); test giả `gh`, `cosign`, còn kiểm luôn `scan-gate`, `verify-release`, `sign-image`, bundle | Mọi script `deploy/ci/` qua `ci_*`; `ci.yml` job config (test) | chính | Biến `GITHUB_*` và `gh` trực tiếp: `>>"$GITHUB_OUTPUT"`, `>>"$GITHUB_STEP_SUMMARY"`, `::add-mask::`, `::warning::`; script nào cần chạy trên máy thì có cờ `--dry-run` riêng | **Xoá** · M | Mất chế độ `local` (in lệnh thay vì ghi): đã chấp nhận ở 0037 §2. Ca test của script khác nằm trong `platform-test.sh` phải chuyển về test riêng hay biến mất cùng script được thay. Test lớn nhất repo, kiểm một lớp đang bị gỡ |
| A7 | `scan-gate.sh` (489) | Chọn cờ trivy/grype, đọc mã thoát, một dòng tóm tắt mỗi lần quét; `--check-ignorefile` kiểm `.trivyignore.yaml`, `.grype.yaml`, `trivy-config-ignore.yaml` (ADR-0039 §2) | `build-image.sh`, `rescan.sh`, `ci.yml` config, `make grype`; `svp-frontend` `ci.yml` | chính | Cổng: gọi thẳng `trivy convert --exit-code 1 --severity CRITICAL --ignorefile …` và `trivy convert --scanners secret --exit-code 1`, `grype --fail-on critical -c .grype.yaml` trong bước; luật file ngoại lệ: **conftest** (Rego) `--combine` (hạn ≤ 30 ngày, mỗi rule grype khớp một mục trivy còn hạn, khoá cấm) | Thay · M | Giữ: không `--severity` cho bí mật (giấu bí mật HIGH, ADR-0039 §2), mã thoát 5 của `trivy convert`, dòng tóm tắt. Luật chéo hai file viết bằng Rego cần test riêng (`conftest verify`) |
| A8 | `rescan.sh` (301) | Quét lại hằng ngày mọi digest đang phát hành, thay attestation `vuln` (Kyverno nhận tối đa 72 h) | `images.yml` job rescan (lịch, dispatch) | chính | Không có công cụ chuẩn cho "làm mới attestation có hạn"; mẫu ngành chính là lịch quét + `cosign attest` như này. Rút: bỏ nhánh định dạng cũ (ADR-0040), danh sách digest bằng `yq` trên clone `svp-gitops`, predicate bằng `trivy --format cosign-vuln` nếu A3 đổi | Giữ glue, rút còn ~120 · S–M | Guard nguồn (repo này không attest bản của repo khác) phải giữ |
| A9 | `contract.sh` (251), `contract-test.sh` (341) | `check`: luật version hợp đồng REST bằng oasdiff; `publish`: đẩy OCI bằng ORAS, ký cosign, không phát hành trùng (ADR-0033 §1) | `make api-contract-check` (`ci.yml` api-contract), `images.yml` job contract, `ci.yml` (test) | chính | `oasdiff breaking --fail-on ERR --severity-levels <file>` (nâng `api-version-not-bumped`… là tính năng của oasdiff) + `oasdiff changelog`, hay `oasdiff/oasdiff-action`; publish là 3 bước YAML `oras push`, `oras manifest fetch` so layer, `cosign sign` | Thay · M | Luật "tag đã có nội dung khác thì đỏ" (GHCR không có tag bất biến) giữ ~10 dòng; kiểm `info.version` dạng semver giữ ~5 dòng. Test registry giả 341 dòng mất phần lớn |
| A10 | `ghcr-digest.sh` (69), `ghcr-digest-test.sh` (78) | Digest mới nhất của image diễn tập trên GHCR, đọc ẩn danh (ADR-0039 §3) | `deploy/ci/verify/gitops.sh`, `deploy/k8s/drills/supplychain.sh`; `ci.yml` (test) | kiểm định kỳ | `oras repo tags` + `oras resolve` (ORAS đã ghim) hay `crane ls` + `crane digest` | Thay · S | Chọn "tag mới nhất theo commit của clone" còn ~5 dòng `git` |

### B. Phát hành và check `svp-gitops`

| # | Script (dòng) | Làm gì | Ai gọi | Đường | Thay bằng | Loại · công | Rủi ro, mất gì |
| --- | --- | --- | --- | --- | --- | --- | --- |
| B1 | `gitops-check.sh` (1 165), `gitops-check-test.sh` (877) | Check cây `svp-gitops`: hình dạng `envs/`, `charts.yaml`, lớp `platforms`, render root, render mọi chart + kubeconform (cả CRD ESO), Kyverno CLI (`images-pinned`, `no-lab-hosts`), kiểm bản phát hành (ADR-0025, 0024, 0037 §5–6) | `svp-gitops` `check.yml`; `make helm-check` (`--worktree`); `ci.yml` config (test) | chính (cổng merge `svp-gitops`) | Hình dạng file (`charts.yaml`, `images/*.yaml`, `components.json`): **JSON Schema** (`check-jsonschema`) hay conftest; luật chéo file (image overlay bằng image base, `localHosts`, luật tác giả PR bot): conftest Rego hay Kyverno CLI (đã có `gitops-policies/`); render: vòng `helm template` mỏng hay `ct lint`; diff: argocd-diff-preview (đã có); bước 5: B2 | Thay một phần · L | Ước còn ~300 bash + policy. Hơn 30 ca âm của test phải thành ca `conftest verify`/`kyverno test`. Luật tác giả PR bot (GIT-6, khoá App lộ) phải giữ. `svp-gitops` ghim `CHECKER_COMMIT`: nâng ở repo kia |
| B2 | `values-check.sh` (101), `verify-release.sh` (83) | Mỗi digest đổi trong `envs/*/images`: chữ ký đúng nguồn, đúng một `vuln` ≤ 48 h không CRITICAL phủ hai nền tảng, provenance khi policy đòi (ADR-0025, 0040) | `gitops-check.sh` bước 5; `deploy/k8s/gitops.sh` (bootstrap); diễn tập | chính | `cosign verify` + `cosign verify-attestation --type vuln --policy vuln.rego` (tuổi, CRITICAL, nền tảng) + `gh attestation verify --signer-workflow` hay `slsa-verifier verify-image`; hoặc chạy chính ImageValidatingPolicy bằng Kyverno CLI (**cần kiểm** CLI v1.19 có verify image của IVP offline không) | Thay · M | Luật đang viết hai lần (script và policy Kyverno); gộp được nếu Kyverno CLI làm. Biên 48 h < 72 h phải là tham số |
| B3 | `sources-test.sh` (200) | Giữ hai bản luật bảng nguồn (`sources.json`) khớp nhau: template `svp-policy` và `_release_sources_check` của `lib.sh` (ADR-0033, 0036) | `ci.yml` config | chính | `values.schema.json`/JSON Schema cho `sources.json` + **helm-unittest** cho ca render; bỏ bản luật trong `lib.sh` (script chỉ đọc) | Thay · S–M | Luật "prefix không là tiền tố của nguồn khác", ký tự cấm trong CEL không viết được bằng JSON Schema: giữ `fail` trong template (một chỗ) |
| B4 | `promote-test.sh` (337) | Test guard promote (`promote_not_behind`, `promote_stg_ref`, `promote_open_pr`, `promote_image_row`) và `rescan.sh list` (ADR-0037 §6) | `ci.yml` config | chính | Giữ: test của logic còn giữ. Promote chuẩn khác (Kargo) ADR-0037 §6 để làm lab | Giữ · S | Thu nhỏ theo A5, A8 |

### C. Kiểm chứng runner (`verify.yml`, lịch tuần và dispatch; ADR-0021, 0039 §1)

| # | Script (dòng) | Làm gì | Ai gọi | Đường | Thay bằng | Loại · công | Rủi ro, mất gì |
| --- | --- | --- | --- | --- | --- | --- | --- |
| C1 | `verify-run.sh` (280), `verify/compose-obs.sh` (48), `verify/gitops.sh` (394) | Chạy chuỗi make target có hạn giờ, output vào file, `results.tsv`; kịch bản `gitops` thêm `gitops-env`, `gitops-external-secrets`, `gitops-argocd-metrics` | `verify.yml` (kịch bản do `verify-run.sh` source) | kiểm định kỳ | Mỗi target một step Actions (`timeout-minutes`, `continue-on-error`, tóm tắt qua `$GITHUB_STEP_SUMMARY`); ba bước kiểm cluster: **Chainsaw** (`assert` Application Synced/Healthy, ExternalSecret Ready, PromQL trong step `script`) | Thay · M–L | Mất tính "chạy y hệt trên VM thuê" (lý do có script). Output target vẫn phải ra file, không ra log public |
| C2 | `verify-collect.sh` (240), `verify-collect-test.sh` (1 422) | Dựng artifact public theo allow list, lọc dòng log của namespace bên thứ ba, quét bí mật | `verify.yml`; `ci.yml` config (test) | kiểm định kỳ | Chỉ upload kết quả máy đọc (`results.tsv`, JUnit của Chainsaw, JSON diễn tập), không upload log; quét thêm bằng `gitleaks dir` (gitleaks đã có ở CI) | Thay · M | Mất log để đọc khi đỏ (đánh đổi chính; đọc lại bằng chạy lại có SSH/VM). Test lớn thứ hai repo |
| C3 | `verify-mask.sh` (151) | Mask giá trị bí mật của `.env` và Secret cluster trong log job | `verify.yml` | kiểm định kỳ | `::add-mask::` trực tiếp (không qua adapter); đọc `.env` theo H2 | Giữ, rút còn ~50 · S | Không công cụ chuẩn nào mask Secret của cluster vừa tạo |
| C4 | `verify-host.sh` (95) | Kiểm đĩa (dọn toolset runner), `/etc/hosts`, skew kubectl | `verify.yml` | kiểm định kỳ | Giữ; phần dọn đĩa có thể là `jlumbroso/free-disk-space` (cần allowlist) | Giữ · S | — |

### D. Cluster: đường dev k3d, bootstrap GitOps, EKS

| # | Script (dòng) | Làm gì | Ai gọi | Đường | Thay bằng | Loại · công | Rủi ro, mất gì |
| --- | --- | --- | --- | --- | --- | --- | --- |
| D1 | `deploy/k8s/lib.sh` (1 397) | Guard context (`k3d-svp`/`svp-stg`/`svp-prd`), docker/k3d/kubectl/helm, registry + cluster k3d (kiểm mount PSA), chờ, ES force-sync, clone gitops/web, restart theo Secret, báo pod chưa sẵn, build image dev, bảng nguồn, `values_*`, `compose_images` (ADR-0014) | `k8s.mk`, `compose.mk`, mọi script k8s, `deploy/ci/` (`image_paths`, `built_services`, `release_source*`), `svp-frontend` | lab + chính (phần dùng chung CI, EKS) | Registry + cluster: `ctlptl apply` (khai báo cluster + registry; k3d config đã có); build: **`docker buildx bake`** (`docker-bake.hcl` là dữ liệu chung cho `make up`, `make k8s-images` và CI, thay `image_paths`/`dockerfile`/`build_dev_images`); chờ: `kubectl wait`, `rollout status`; restart theo Secret: **Reloader** (stakater, có hỗ trợ Argo Rollouts); báo lỗi: `kubectl events` | Thay một phần · L | Ước còn ~400. Guard context cloud và kiểm mount PSA là luật an toàn: giữ. Đổi `image_paths` chạm CI (A4) |
| D2 | `deploy/k8s/install.sh` (625) | Đường dev: cài component theo wave của `components.json` bằng `helm upgrade --install --wait`, build image, Secret, base backup, tự chạy traffic khi có canary; còn kiểm MinIO cũ | `make k8s-up` | lab | **helmfile** (`needs`, `helmfile sync`; sinh từ `components.json` hay ngược lại), hoặc Tilt/Skaffold cho vòng dev; hoặc bỏ đường dev, dùng đường GitOps với overlay dev trỏ registry local | Thay · L | Hai đường phải cài cùng chart/version (nay chung một `components.json`). Kiểm StatefulSet `minio` là tương thích ngược quá một bản phát hành (trái ADR-0037 §4): xoá được ngay |
| D3 | `deploy/k8s/gitops.sh` (542) | Bootstrap GitOps: kiểm bản phát hành, tạo cluster k3d hay dùng EKS, Secret, cài Argo CD + AppProject + root app, chờ Synced/Healthy, `glitchtip-init` (ADR-0025, 0026, 0034, 0037 §5) | `make k8s-gitops-up`, `make eks-gitops-up` (người học, buổi AWS), `verify` gitops | **chính (EKS)** + lab | EKS: Terraform ở `svp-infra`: `helm_release` Argo CD + root app theo mẫu **GitOps Bridge** (metadata cluster thành annotation của cluster Secret, thay `CLUSTER_VALUES`); chờ: `argocd app wait --sync --health` hay `kubectl wait --for=jsonpath`; kiểm phát hành: B2 + admission Kyverno; k3d giữ ~100 dòng | Thay · L | AI không chạy terraform (người học chạy). Mất kiểm "bản phát hành hợp lệ trước khi tạo gì" nếu không giữ B2 trước apply. Thứ tự Secret nguồn trước Argo CD phải giữ |
| D4 | `deploy/k8s/secrets.sh` (540) | Secret từ `.env` (k3d) hay nguồn `svp-secrets` cho ESO (GitOps, EKS), đổi mật khẩu superuser Redpanda, restart (ADR-0026) | `install.sh`, `gitops.sh`, `make k8s-secrets`, `make eks-secrets` | chính (EKS) + lab | EKS: nguồn là **AWS Secrets Manager** (Terraform tạo secret, người học đặt giá trị) + ESO provider `aws` (ADR-0026 đã định cho prd), bỏ nhánh EKS; k3d: `kubectl create secret generic --from-env-file … --dry-run=client -o yaml \| kubectl apply --server-side -f -` sinh từ `external-secrets.yaml`; restart: Reloader | Thay · M–L | Giữ: đọc `.env` chặt, đọc đủ rồi mới apply, không in giá trị. Xoay mật khẩu superuser Redpanda khi broker chạy là việc riêng, giữ glue |
| D5 | `deploy/k8s/glitchtip-init.sh` (122) | Đọc DSN, token trong pod GlitchTip, ghi Secret (hay nguồn ESO), restart service | `make k8s-glitchtip-init`, `make eks-glitchtip-init`, `gitops.sh` | chính (EKS) + lab | Giữ; phần restart sang Reloader | Giữ · S | — |
| D6 | `deploy/k8s/eks-seed.sh` (69) | 4 user × 8 video cho k6 profile `cloud` | `make eks-seed` (buổi AWS) | chính (buổi AWS) | Giữ; hoặc gộp vào `setup()` của k6 | Giữ · S | — |
| D7 | `deploy/k8s/eks-context-test.sh` (602) | Test giả (kubectl/helm/k3d/docker/curl giả) của guard context EKS ở `lib.sh`, `gitops.sh`, `secrets.sh`, `eks-seed.sh` | `ci.yml` config | chính | Giữ; thu nhỏ theo D1–D4 | Giữ · S | — |
| D8 | `deploy/k6/cloud/render.sh` (126), `deploy/k6/cloud/run.sh` (120), `deploy/k8s/cloud/check.sh` (103) | Render Job k6 Indexed 20 pod, chạy/lấy log/xoá; kiểm tĩnh bằng kubeconform + "mọi image ghim digest" (ADR-0020, 0039) | `run.sh`: chỉ người học (runbook `session-stg.md` của `svp-infra`, không target make nào); `check.sh`: `make cloud-check` (`ci.yml` config) | chính (buổi AWS) | **k6-operator** `TestRun` (`parallelism`, script từ ConfigMap qua kustomize `configMapGenerator`); check: `kubeconform` thẳng trong `Makefile` + policy `images-pinned` của Kyverno CLI (đã có ở `gitops-policies/`) | Thay · M | Thêm operator vào EKS (component mới trong `components.json`). Kiểm "summary không chứa token" giữ bằng `gitleaks dir` |
| D9 | `deploy/k6/load.sh` (93) | k6 trên compose (`load-local`, `load-ci`) | `make load-local`, `make load-ci` (`ci.yml` stack) | lab + CI chỉ báo | Giữ; tuỳ chọn `grafana/run-k6-action` | Giữ · S | — |

### E. Diễn tập k8s

| # | Script (dòng) | Làm gì | Ai gọi | Đường | Thay bằng | Loại · công | Rủi ro, mất gì |
| --- | --- | --- | --- | --- | --- | --- | --- |
| E1 | `deploy/k8s/drills/threats.sh` (2 452, **lớn nhất**) | Các dòng threat model trên cluster: IN-2/IN-4 NetworkPolicy từ pod probe, IN-4/FF-6 ACL Kafka, FF-5 egress, FF-3/FF-4 securityContext, IN-9 `pg_hba`, RL-1, OPS-1/2, WEB-2/7/8/10/13, BAK-1, SEC-5/6/7 | `make drill-k8s-threats`; `verify` gitops | kiểm định kỳ (ADR-0039 giữ ở đường chính) | Harness **Chainsaw** (ADR-0039 §1C đã nêu "kubescape + Chainsaw"); NetworkPolicy: **netassert** v2 hay step Chainsaw với `nc`; FF-3/FF-4: Kyverno CLI hay **kubescape** trên manifest đã render (tĩnh, chạy được ở PR thay vì chỉ tuần); RBAC: `kubectl auth can-i` trong Chainsaw; HTTP (OPS, WEB): cùng công cụ với F1 | Thay · L | Mỗi ca có "control" (đích đóng vì policy chứ không vì service chết): phải giữ ở mọi ca. ACL Kafka vẫn là `rpk` trong step. Nên làm bài lab so bash với Chainsaw trước (đúng 0039 §1C) |
| E2 | `deploy/k8s/drills/supplychain.sh` (914) | Admission Kyverno: đã ký, chưa ký, CRITICAL, prefix, digest, tuổi attestation, controller down, ephemeral, update, thiếu provenance, keyless của vendor, nguồn tách nhau (ADR-0015, 0019, 0040) | `make drill-k8s-supplychain`; `verify` gitops | kiểm định kỳ | **Chainsaw** (`apply`/`create` với `expect` lỗi admission, dry-run server): công cụ Kyverno dùng để test chính nó; logic thuần của policy: `kyverno test` offline (như `make kyverno-test`) | Thay · M–L | Ca g (controller down) và f (bản policy tuổi 5 s) cần step script; đo thời gian trả lời phải giữ trong step |
| E3 | `deploy/k8s/drills/traffic.sh` (271), `deploy/k8s/drills/lib.sh` (67) | Traffic nền cho canary gateway và web (4 user, đăng nhập lại trước khi token hết hạn, log mỗi request); lib: `rpk`, PromQL qua port-forward | `make k8s-traffic-start/stop`; `install.sh` tự chạy khi có canary; drills | lab | traffic: k6 `constant-arrival-rate` chạy nền bằng `K6_IMAGE` (đã ghim); lib giữ | traffic Thay · M; lib Giữ | Đếm 404 chéo build lấy từ output JSON của k6 |

### F. Compose: smoke, DAST, diễn tập, tiện ích

| # | Script (dòng) | Làm gì | Ai gọi | Đường | Thay bằng | Loại · công | Rủi ro, mất gì |
| --- | --- | --- | --- | --- | --- | --- | --- |
| F1 | `deploy/compose/smoke.sh` (406), `deploy/compose/lib.sh` (263) | E2E qua gateway: đăng ký, idempotency, upload presigned, transcode, HLS, feed, like, view, refresh token; lib dùng chung (request, user, video, chờ READY, reset rate limit) | `make smoke`, `k8s-smoke`, **`eks-smoke`** (buổi AWS), `ci.yml` stack, `verify`; lib: dast, load, eks-seed, `eks-rl-reset`, drills | **chính** (ADR-0039 §1) | Test e2e Go (`go test -tags e2e ./e2e/...`, kiểu sinh từ OpenAPI): chuẩn của repo Go; hoặc **Hurl** (HTTP khai báo) hay k6 `checks` 1 VU | Thay · L | `lib.sh` dùng chung với drills: giữ bản bash tới khi drills sang lab. Reset rate limit LOCAL LAB ONLY giữ (Go hay `redis-cli`) |
| F2 | `deploy/dast/run.sh` (249) | Schemathesis trên compose, user test, lọc và quét báo cáo (ADR-0030) | `make dast` (`ci.yml` stack, chỉ báo) | CI chỉ báo | `schemathesis/action` (khi allowlist mở) hay giữ `docker run`; quét báo cáo bằng `gitleaks dir` | Thay một phần · S–M | Hạn giờ tự làm vì macOS không có `timeout` chỉ cần ở máy |
| F3 | `deploy/compose/object-store-copy.sh` (355), `object-store-copy-test.sh` (558) | Chép `uploads`, `media` MinIO↔RustFS khi đổi store (ADR-0022), từ chối ghi đè/xoá | `make object-store-copy TO=…`; **test không target, workflow nào gọi** | lab | `rclone sync`/`mc mirror` + runbook ngắn; hay chuyển `svp-labs` | **Xoá** · S | Mất đường quay lại MinIO có kiểm an toàn; ADR-0022 gọi MinIO là đường quay lại: **cần người học xác nhận** |
| F4 | Diễn tập compose đo một lần: `kill-worker.sh` (108), `duplicate-events.sh` (159), `duplicate-feed-events.sh` (183), `engagement-down.sh` (122), `rate-limit.sh` (149), `upload-cleanup.sh` (99), `measure-ready.sh` (88), `measure-freshness.sh` (294), `measure-explore-cache.sh` (156), `alert-to-sentry.sh` (276), `gameday.sh` (517), `drills/common.sh` (547) | Kill worker giữa transcode, replay event, circuit breaker, rate limit, dọn upload, đo READY/freshness/cache, alert→GlitchTip, game day (ADR-0008, 0009, 0010, 0005, 0011, 0020) | `compose.mk` `drill-*`, `measure-*`, `gameday*`; chạy tay | lab | **Chuyển `svp-labs/drills/`** đóng băng ở commit ghim (như 0039 làm với diễn tập k8s): số đo đã ở ADR; idempotent consumer đã có test Go (`projector_test.go`, `views_test.go`, `worker_test.go`). Nếu muốn còn chạy: chaos bằng Toxiproxy hay Pumba, đo bằng k6 + PromQL | Labs · S (chuyển) / L (viết lại) | Không ai chạy lại; đổi service làm hỏng âm thầm (0039 đã chấp nhận điều này cho k8s). ADR-0039 bảng 1 hiện ghi "script diễn tập compose vẫn ở repo, chạy tay": chuyển cần ADR mới hay dòng chỉnh |
| F5 | `deploy/compose/drills/obs-threats.sh` (645) | JWT-8 (PII trong trace, log, event), UP-8, OPS-1 (cổng publish), RL-2 trên `make up OBS=lgtm` | `make drill-obs-threats`; `verify` compose-obs | kiểm định kỳ (0039 giữ) | Không có công cụ chuẩn cho "telemetry không chứa PII"; phòng ở nguồn bằng processor `redaction`/`transform` của OTel Collector; viết lại cùng công cụ của F1 khi làm F1 | Giữ · M nếu viết lại | Cần `obs_*`, `sentry_*` của `drills/common.sh` (~250 dòng ở lại) |

### G. Khởi tạo dữ liệu (container init compose, Job Helm)

| # | Script (dòng) | Làm gì | Ai gọi | Đường | Thay bằng | Loại · công | Rủi ro, mất gì |
| --- | --- | --- | --- | --- | --- | --- | --- |
| G1 | `deploy/postgres/bootstrap.sh` (46) | Role, DB trên Postgres native | `make db-bootstrap` | lab | Giữ | Giữ · — | — |
| G2 | `deploy/helm/svp-data/files/pg-bootstrap.sh` (88) | Job: role, DB trên CNPG `svp-pg` hay RDS (`SVP_PG_MODE=external`) | Job `pg-bootstrap` của chart `svp-data` | chính (EKS, RDS) + lab | CNPG: `spec.managed.roles` + CRD **`Database`** (khai báo, CNPG ≥ 1.25; chart 0.29.1 đủ); RDS: Terraform provider `cyrilgdn/postgresql` ở `svp-infra`, hay giữ Job cho chế độ external | Thay · M | `bootstrap.sql` dùng chung với compose; grant chi tiết (default privileges) vẫn cần SQL |
| G3 | `deploy/redpanda/create-topics.sh` (41; `deploy/helm/svp-data/files/create-topics.sh` là symlink) | Tạo topic, DLQ bằng `rpk` | compose `redpanda-init`; Job `redpanda-init` (`.Files.Get`) | chính + lab | Giữ (rpk là công cụ của vendor); tuỳ chọn Redpanda Operator CRD `Topic` | Giữ · — | — |
| G4 | `deploy/helm/svp-data/files/kafka-users.sh` (89) | User SASL + ACL tối thiểu mỗi service (IN-4, FF-6) | Job `redpanda-init` | chính + lab | Giữ; tuỳ chọn Redpanda Operator CRD `User` (SASL + ACL khai báo), cần đổi chart redpanda sang operator | Giữ · — | — |
| G5 | `deploy/s3/init.sh` (149) | Bucket, CORS, policy, user mỗi service trên RustFS | compose `s3-init`; Job của `svp-data` (symlink thư mục) | lab (EKS dùng S3 qua Terraform) | Giữ (admin API riêng của RustFS) | Giữ · — | — |

### H. Observability, `.env`

| # | Script (dòng) | Làm gì | Ai gọi | Đường | Thay bằng | Loại · công | Rủi ro, mất gì |
| --- | --- | --- | --- | --- | --- | --- | --- |
| H1 | `deploy/observability/alertmanager/entrypoint.sh` (67) | Viết config Alertmanager (Telegram khi có token) | compose `alertmanager` | lab | Giữ | Giữ · — | Route ở **ba bản** (đây, `alertmanager_config` của `secrets.sh`, `files/external-secrets.yaml`), comment tự nhắc "keep the three in step" |
| H2 | `deploy/observability/glitchtip/dotenv.sh` (101), `dotenv-test.sh` (586) | Parser `.env` chặt để shell đọc giống compose | `compose.mk` (`make env`, `test-stack`), `postgres/bootstrap.sh`, `init.sh`, `verify-mask.sh`, `secrets.sh`; `ci.yml` config (test) | lab + CI | Lint bằng **dotenv-linter**; lấy giá trị bằng chính compose (`docker compose config --format json`), bỏ parser tự viết | Thay · M | Lý do tồn tại là shell và compose đọc khác nhau: dùng compose làm parser giữ được, nhưng mọi chỗ đọc cần Docker CLI |
| H3 | `deploy/observability/glitchtip/init.sh` (79) | Chạy job init GlitchTip, ghi DSN, token vào `.env` | `make glitchtip-init` | lab | Giữ | Giữ · — | — |
| H4 | `deploy/observability/glitchtip/sourcemaps.sh` (149) | Build stage sourcemaps của web, kiểm debug id, `sentry-cli sourcemaps upload` (ADR-0039 §3) | **chỉ `Makefile` của `svp-frontend`** | lab | Đã dùng công cụ chuẩn (`sentry-cli`); dời sang `svp-frontend` | Giữ, dời repo · S | — |

## Logic trùng lặp

- **Luật bảng nguồn phát hành viết hai lần**: template `svp-policy` và `_release_sources_check` của `deploy/k8s/lib.sh`; `sources-test.sh` (200) chỉ để giữ hai bản khớp (B3).
- **Luật bản phát hành viết hai lần**: `verify-release.sh`/`common.sh` (chữ ký, `vuln`, tuổi, provenance) và ImageValidatingPolicy của Kyverno (B2).
- **"Mọi image ghim digest" hai lần**: bước 3 của `deploy/k8s/cloud/check.sh` và policy `deploy/ci/gitops-policies/images-pinned.yaml` (+ `image_refs` của `gitops-check.sh`).
- **Quét bí mật trong output bốn chỗ**: `deploy/dast/run.sh`, `deploy/k6/load.sh`, `deploy/k6/cloud/run.sh logs`, `deploy/ci/verify-collect.sh`: một `gitleaks dir` thay cả bốn.
- **Kiểm "stack compose chạy, k3d không chạy" lặp**: `dast/run.sh`, `k6/load.sh`, `object-store-copy.sh`, `make up`/`k8s-up` (`k8s-exclusive`).
- **Route Alertmanager ba bản** (H1). **Bootstrap Postgres hai bản** (compose, k8s; cố ý, chung `bootstrap.sql`).
- **Helper trùng**: `now`, `rpk` ở cả `deploy/compose/drills/common.sh` và `deploy/k8s/drills/lib.sh`; `ok`/`fail` ở `deploy/k8s/lib.sh` và `deploy/compose/lib.sh`;
  restart theo Secret ở `install.sh`, `secrets.sh`, `glitchtip-init.sh` (qua `restart_on_secret_change`, Reloader thay).
- **Danh sách file "không job image nào đọc"** viết tay ở `changed-services.sh` và văn xuôi ở `docs/reference/ci.md` (A4).
- **Bảng service và đường build image** ở `lib.sh` (`built_services`, `image_paths`, `dockerfile`) dùng cho cả CI, compose và k3d: `docker-bake.hcl` biến nó thành dữ liệu (D1).

## Script không target make, workflow nào gọi trực tiếp

- `deploy/compose/object-store-copy-test.sh`: không target, không workflow; test không chạy ở CI (F3).
- `deploy/k6/cloud/run.sh`: không target, không workflow; chỉ người học chạy theo runbook `session-stg.md` của `svp-infra` (còn sống, ADR-0039 giữ).
- `deploy/observability/glitchtip/sourcemaps.sh`: repo này không gọi; chỉ `Makefile` của `svp-frontend` (H4).
- Chỉ script khác gọi (không chết): `last-success.sh`, `changed-services.sh` (plan.sh); `values-check.sh` (`gitops-check.sh`, `gitops.sh`);
  `verify-release.sh` (`values-check.sh`; dòng `Makefile:58` chỉ là comment); `vuln-predicate.sh` (`sign-image.sh`, `rescan.sh`); `ghcr-digest.sh`
  (`verify/gitops.sh`, `supplychain.sh`); `verify/*.sh` (`verify-run.sh` source theo tên kịch bản); các thư viện `common.sh`, `platform.sh`,
  `lib.sh`, `drills/common.sh`, `drills/lib.sh`.
- Code chết trong script: kiểm StatefulSet `minio` ở `install.sh` (tương thích ngược quá một bản phát hành, trái ADR-0037 §4); nhánh định dạng
  cũ `.sig/.att` ở `common.sh`/`rescan.sh` chờ điều kiện xoá của ADR-0040. Hàm `ci_*` nào cũng còn người gọi (`ci_repo`, `ci_run_url` chỉ dùng bên trong `platform.sh`).

## File lớn nhất

| File | Dòng | Loại |
| --- | --- | --- |
| `deploy/k8s/drills/threats.sh` | 2 452 | Thay (Chainsaw + netassert/kubescape) |
| `deploy/ci/platform-test.sh` | 1 863 | Xoá (adapter đóng băng) |
| `deploy/ci/verify-collect-test.sh` | 1 422 | Thay (không upload log, gitleaks) |
| `deploy/k8s/lib.sh` | 1 397 | Thay một phần (ctlptl, bake, Reloader) |
| `deploy/ci/gitops-check.sh` | 1 165 | Thay một phần (JSON Schema, conftest, Kyverno CLI) |
| `deploy/k8s/drills/supplychain.sh` | 914 | Thay (Chainsaw) |
| `deploy/ci/gitops-check-test.sh` | 877 | Thay theo B1 |
| `deploy/ci/common.sh` | 778 | Thay một phần |
| `deploy/compose/drills/obs-threats.sh` | 645 | Giữ |
| `deploy/k8s/install.sh` | 625 | Thay (helmfile hay Tilt) |

## Năm việc thay bớt nhiều dòng bash nhất (ước lượng)

| # | Việc | Bash bỏ đi | Thêm vào (định dạng khác) |
| --- | --- | --- | --- |
| 1 | Diễn tập k8s sang Chainsaw (+ netassert, kubescape/Kyverno CLI cho phần tĩnh): E1, E2 | ~2 950 của 3 366 | ~1 250 YAML Chainsaw + ~400 bash step |
| 2 | Runner `verify.yml` thành step Actions + Chainsaw + gitleaks: C1, C2 | ~2 200 của 2 384 | ~150 YAML workflow, ~150 Chainsaw |
| 3 | Xoá adapter CI đóng băng: A6 | ~2 000 của 2 218 | ~200 dòng test chuyển về script được giữ; ~81 lời gọi đổi sang `GITHUB_*`/`gh` |
| 4 | `gitops-check` sang JSON Schema + conftest/Kyverno CLI + vòng `helm template`: B1 | ~1 700 của 2 042 | ~200 Rego/schema + ca test |
| 5 | Đường dev k3d: `ctlptl` + `buildx bake` + helmfile/Tilt + Reloader: D1, D2 | ~1 550 của 2 022 | `docker-bake.hcl`, `helmfile.yaml` (~250) |

Tiếp theo: diễn tập compose sang `svp-labs` (2 698 dời ra, không thay), bootstrap EKS sang Terraform + AWS Secrets Manager (D3, D4: ~800),
xoá `object-store-copy` (913), `dotenv` sang dotenv-linter + compose (~650), `contract` sang oasdiff/oras (~470), `scan-gate` sang cờ + conftest (~430).

## Công cụ đề xuất và trạng thái (người học chọn trước khi thêm)

| Công cụ | Thay cho | Trạng thái ngành |
| --- | --- | --- |
| Chainsaw (kyverno/chainsaw) | E1, E2, phần cluster của C1 | Hiện hành, ngách k8s e2e; Kyverno dùng cho chính nó |
| kubescape | FF-3/FF-4 tĩnh của E1 | Hiện hành (CNCF incubating) |
| netassert v2 | NetworkPolicy của E1 | Ngách, ít người dùng; Chainsaw + `nc` là phương án không thêm công cụ |
| conftest (OPA/Rego) | A7, B1 | Hiện hành |
| check-jsonschema / JSON Schema | B1, B3 | Hiện hành |
| helm-unittest | B3 | Hiện hành |
| `docker buildx bake` | D1, A4 | Hiện hành, đang lan sang CI |
| ctlptl | D1 | Ngách (đội Tilt) |
| helmfile / Tilt / Skaffold | D2 | helmfile hiện hành; Tilt, Skaffold hiện hành cho vòng dev |
| Reloader (stakater) | restart theo Secret | Hiện hành |
| GitOps Bridge (Terraform) | D3 trên EKS | Hiện hành trong EKS Blueprints |
| CNPG `Database` + `managed.roles` | G2 | Mới (CNPG ≥ 1.25), là hướng của operator |
| k6-operator | D8 | Hiện hành |
| crane / ORAS | A2, A10 | Hiện hành (ORAS đã ghim) |
| oasdiff (`breaking --fail-on`) | A9 | Hiện hành (đã ghim) |
| `trivy --format cosign-vuln` | A3, A8 | Hiện hành; đổi hợp đồng Kyverno |
| dorny/paths-filter | A4 | Hiện hành; cần allowlist action |
| dotenv-linter | H2 | Hiện hành, ngách |
| Hurl / test e2e Go | F1 | Go e2e: chuẩn của repo Go; Hurl mới nổi |
| Toxiproxy / Pumba | F4 nếu viết lại | Toxiproxy hiện hành; Pumba cũ dần |
| Kargo | promote (B4) | Mới nổi; ADR-0037 §6 để lab |

## Ghi chú cho bước sau

- Không thứ tự nào ở đây là đã chốt. Việc chạm hai repo (A1–A6, B1) phải đổi `svp-frontend` và `CHECKER_COMMIT` của `svp-gitops` cùng lượt.
- Việc nhỏ, ít rủi ro làm được ngay: xoá `last-success.sh` (một dòng `gh`), xoá kiểm `minio` ở `install.sh`, dời `sourcemaps.sh` sang `svp-frontend`,
  `check.sh` dùng policy `images-pinned` có sẵn, `ghcr-digest.sh` sang ORAS, gộp quét bí mật output về `gitleaks dir`.
- Cần người học quyết: giữ đường quay lại MinIO (F3) hay không; chuyển diễn tập compose (F4) cần chỉnh bảng 1 của ADR-0039; đổi predicate `vuln`
  (A3) cần ADR vì đổi hợp đồng Kyverno; Terraform cho bootstrap EKS (D3, D4) là việc của `svp-infra`, người học chạy.
