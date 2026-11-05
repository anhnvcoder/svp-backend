# 0025. Cấu hình triển khai chuyển sang repo public `svp-gitops` (values gốc, overlay và digest của mỗi env, manifest Argo CD), PR promote mở bằng GitHub App chỉ cài trên repo đó; chart vẫn ở repo code và mỗi env ghim commit chart của nó cùng bộ digest

- Trạng thái: Chấp nhận
- Ngày: 2026-10-28
- Người quyết: người học (duyệt 2026-10-28, chọn (a) ở cả sáu dòng "Cần người học chọn"; bố cục workspace của §3 quyết 2026-10-29)

## Bối cảnh và vấn đề

- **Yêu cầu:** repo ứng dụng giữ code, test, Dockerfile, CI build, quét, ký; repo cấu hình giữ Helm values, digest đang chạy, manifest Argo CD; job promote mở PR sang repo cấu hình; Argo CD chỉ đọc repo cấu hình; quyền merge code tách khỏi quyền deploy (ruleset, CODEOWNERS riêng); chuyển kiểu brownfield, hai nguồn không chạy song song quá một buổi; ghi được và mất so với monorepo.
- **Đã chốt trước** (người học, 2026-10-25 và 2026-10-28): `svp-gitops` public, không secret, ở tài khoản cá nhân (<https://github.com/anhnvcoder/svp-gitops>); PR promote mở bằng GitHub App cài riêng trên `svp-gitops`, khoá ở environment `promote` của repo code; Argo CD và runner đọc cả hai repo qua HTTPS ẩn danh.
- **[ADR-0024](0024-multi-environment.md) §8 đã quyết cấu trúc env**, ADR này không thiết kế lại: `base/`, `envs/{stg,prd}/`, digest ở `envs/<env>/images/<svc>.yaml`, đơn vị promote prd là cả bộ bảy digest so với payload của một bản ghi triển khai stg, CODEOWNERS sở hữu `envs/prd/` và file chung, chart app-of-apps với `env`. ADR này chọn chart của repo nằm đâu và mọi thứ của việc tách (đường dev, lịch sử, check, App, ruleset, trình tự).
- **Hiện trạng lúc quyết** (`origin/main` ở `744f108`): cấu hình triển khai nằm trong repo code (`deploy/k8s/values/`, `deploy/k8s/envs/`, `deploy/argocd/` với `components.json` 24 component); năm chart của repo (`deploy/helm/*`) là code, đổi cùng service; ba symlink trong `deploy/argocd/apps/files/` chỉ đi được trong một repo; promote của [ADR-0015](0015-cicd-devsecops-stage5.md) §9 dùng `GITHUB_TOKEN`, không ghi được sang repo khác.
- **Ràng buộc:** một cluster lab mỗi lúc; kiểm nặng trên runner; CI trung lập nền tảng ([ADR-0023](0023-ci-platform-neutral.md)); repo public nên không secret, khoá hay id App trong repo nào.
- **Hiện trạng ngành** (đọc 2026-10-28): Kargo gói image **và** cấu hình thành một "Freight" đi qua các Stage như một khối [N15]; Argo CD multi-source đọc values từ nguồn git khác qua `$values` [N14]; token App ngắn hạn, thu hẹp theo repo và quyền [N1], và PR do token App mở sinh lượt workflow mới, `GITHUB_TOKEN` thì không [N11]. Chi tiết: phụ lục, mục "Bối cảnh".

## Yếu tố quyết định

- Cổng triển khai nằm ở diff của `svp-gitops`; mọi thứ quyết định cái gì chạy ở một env (digest, commit chart, values) đi cùng nhau qua stg rồi mới tới prd.
- Logic kiểm vẫn một bản, ở script của repo code (ADR-0023); không thêm controller, pipeline phát hành hay secret nào ngoài khoá App.
- Mỗi bước chuyển lùi được; đường dev vẫn chạy được trên máy.

## Phương án đã cân nhắc

- §1 nội dung: **A. cây của ADR-0024 §8 cộng `argocd/` (cả bản cài Argo CD), `CODEOWNERS`, `renovate.json`, `.github/`**.
- §1 B. giữ bản cài Argo CD ở repo code.
- §1 **C. hai symlink sang repo code thành giá trị dẫn xuất ghi cạnh commit chart ghim**.
- §1 D. chép hai file sang `svp-gitops`.
- §1 E. Config Management Plugin đọc file repo code.
- §2 chart: **A. ở repo code, mỗi env ghim commit trong `envs/<env>/charts.yaml`, promote cùng digest**.
- §2 B. một commit ghim chung: chart mới tới stg và prd cùng lúc.
- §2 C. gói OCI ký trên GHCR: thêm pipeline, vẫn phải chọn cách ghim.
- §2 D. chart chuyển hẳn sang `svp-gitops`: đường dev cần repo cấu hình.
- §3 đường dev: **A. bản clone `svp-gitops` ngoài git của repo code**.
- §3 B. submodule: cấu hình lại gắn vào lịch sử code.
- §3 C. bản sao đồng bộ bằng script.
- §4 lịch sử: **A. không giữ, commit khởi tạo ghi SHA nguồn và bảng đổi đường dẫn**.
- §4 B. `git filter-repo`: hash mới [N16].
- §4 C. `git subtree split`: một `--prefix` mỗi lần.
- §5 check: **A. workflow của `svp-gitops` checkout repo code ở commit ghim, gọi `deploy/ci/gitops-check.sh`**.
- §5 B. reusable workflow: logic vào YAML.
- §5 C. chép script.
- §6 credential: **A. GitHub App chỉ cài trên `svp-gitops`, token ngắn hạn**.
- §6 B. fine-grained PAT.
- §6 C. deploy key ghi.
- §6 **D. khoá ở environment `promote` chỉ cho `main`**.
- §7 duyệt file chung: **A. ruleset `main` không ai bypass + ruleset `owners` chỉ duyệt Code Owner, admin bypass chế độ `pull_request`**.
- §7 B. tài khoản thứ hai: trái điều khoản [N13].
- §7 C. mọi thay đổi do bot mở.
- §7 D. CODEOWNERS chỉ `envs/prd/`.
- §8 Argo CD: **A. root và `ref: values` đọc `svp-gitops`, chart đọc repo code ở commit ghim**.
- §8 B. mọi thứ từ `svp-gitops`: chỉ có với 2D.
- §8 C. ApplicationSet: đã loại.
- §9 trình tự: **A. brownfield một buổi, đóng băng promote từ lúc khởi tạo tới lúc cắt**.
- §9 B. chạy song song nhiều ngày.
- §9 C. cắt không kiểm trên runner.
- §10 Renovate: **A. `svp-gitops` có `renovate.json` riêng, bỏ qua `envs/**`**.
- §10 B. nâng tay.

Bảng được/mất từng lựa chọn và bảng tách repo so với monorepo: phụ lục, mục "Các lựa chọn".

## Kết quả quyết định

Chọn 1A + 1C, 2A, 3A, 4A, 5A, 6A + 6D, 7A, 8A, 9A, 10A, vì cổng triển khai nằm ở diff của `svp-gitops`, digest, commit chart và values của một env đi cùng nhau qua stg rồi mới tới prd, logic kiểm vẫn ở script của repo code, và không thêm gì ngoài khoá App. Mỗi § dưới giữ quyết định; cây đầy đủ, ví dụ file, bảng job và toàn văn ở phụ lục.

### 1. Cây của `svp-gitops`

- `README.md`, `CODEOWNERS` (§7), `renovate.json` (§10); `base/` (values gốc từ `deploy/k8s/values/`, cả `argo-cd.yaml`; `services/<svc>.yaml` bỏ khối `image`); `envs/<env>/` (overlay của ADR-0024, `charts.yaml` của §2, `images/<svc>.yaml`); `argocd/` (`project.yaml`, `bootstrap.json` là bản cài Argo CD cùng dạng một mục của `components.json`, `apps/` là chart app-of-apps với `components.json` và symlink `files/envs`); `.github/` (`workflows/check.yml`, ruleset `main`, `owners`, `tags`).
- `components.json`: `values` thành `base/<x>.yaml`; chart của repo giữ `path: deploy/helm/<chart>`, repo URL do chart app-of-apps đặt; chart của repo có thêm file trong `base/` khi GitOps cần khác mặc định của chart.
- Hai symlink sang repo code bỏ (1C): `podSecurityVersion` và `collectorConfigSha256` thành khoá của `envs/<env>/charts.yaml`.
- Không chuyển: `deploy/k8s/cloud/values/`, `deploy/k8s/cloud/charts.json`, `deploy/k8s/pod-security-admission.yaml`, `deploy/k8s/k3d.yaml`.

### 2. Chart của repo: ở repo code, mỗi env ghim commit của nó (2A)

- `envs/<env>/charts.yaml` có đúng ba khoá: `revision` (commit 40 hex của repo code), `podSecurityVersion`, `collectorConfigSha256` (dẫn xuất từ commit đó); `charts` là tên dành riêng trong thư mục env, chart app-of-apps đòi file này và từ chối khoá khác (lỗi render). `revision` là `targetRevision` của mọi nguồn chart repo code của env.
- **Promote stg** ghi `charts.yaml` cùng `envs/stg/images/` trong cùng PR: `revision` là HEAD của lượt `images.yml` trên `main`, không bao giờ lùi; lượt chỉ đổi `deploy/helm/` hay config Collector (không image nào build) vẫn chạy promote, chỉ ghi `charts.yaml`.
- **Promote prd và bản ghi stg:** payload bản ghi stg thêm `charts` (đọc từ Application chart đang chạy, phải khớp `charts.yaml` ở commit đã đồng bộ); promote prd chép cả bộ digest **và** `charts.yaml`; check prd so cả hai; rollback chép cả hai từ bản ghi cũ.
- **Check** mỗi env: `revision` là commit trên `main` của repo code; commit của mỗi image (`image.tag`) là tổ tiên hay chính `revision` (chart không cũ hơn code của image nào); hai giá trị dẫn xuất bằng giá trị tính từ `revision`. Đổi chart vì thế đi qua stg trước prd như digest; `Chart.yaml` không dùng để ghim.

### 3. Đường dev và CI repo code đọc bản clone (3A)

- Một hàm của `deploy/k8s/lib.sh` trả thư mục cấu hình: `SVP_GITOPS_DIR` nếu đặt; không thì `<workspace>/gitops`, với `<workspace>` là thư mục cha của thư mục chứa `git rev-parse --path-format=absolute --git-common-dir` (luôn `backend/.git`, nên đúng cả từ worktree ở `.worktrees/`). Thư mục không phải bản clone `svp-gitops` thì in lệnh `git clone` và dừng; đường dev **không tự clone, không fetch, không đổi nhánh** bản của người học.
- `make gitops-clone` (CI): clone ẩn danh, đủ lịch sử, vào `.gitops/svp-gitops` (gitignore), chuyển tới `GITOPS_REF` (mặc định `main`); có thay đổi chưa commit thì từ chối.
- Đường dev đọc working tree của bản clone: `base/` và `components.json`, không `envs/`, không `images/`. CI repo code clone `main` trước `make helm-check` và bước dựng; `helm-check` là `deploy/ci/gitops-check.sh --worktree`.
- Thay đổi chéo hai repo theo thứ tự: values mới dùng được với chart đang ghim (merge ở `svp-gitops` trước), rồi chart dùng values đó; bỏ một value thì ngược lại.

### 4. Không giữ lịch sử (4A)

Commit khởi tạo của `svp-gitops` ghi SHA đầy đủ của repo code mà cây dựng từ đó và bảng đổi đường dẫn (`deploy/k8s/values` → `base`, `deploy/k8s/envs` → `envs`, `deploy/argocd` → `argocd`, khối `image` → `envs/<env>/images/`); lịch sử cũ ở lại repo code public.

### 5. Check của `svp-gitops` (5A)

- `.github/workflows/check.yml`: trigger `pull_request` và `push` lên `main`; `permissions: {}`, job chỉ `contents: read` và `deployments: read`; không secret, không `pull_request_target`; action ghim SHA.
- Job checkout `svp-gitops` và repo code ở **commit checker** ghi một chỗ trong workflow, đủ lịch sử, gọi `deploy/ci/gitops-check.sh`: render mọi env × kiến trúc, quy tắc overlay, `images/`, `charts.yaml`, image upstream ghim digest, render prd không còn `svp.localhost`, `values-check` cho file digest đổi, luật §2, và với PR đổi `envs/prd/images/` hay `envs/prd/charts.yaml`: cả bộ khớp payload một bản ghi stg `success`.
- Check tổng bắt buộc **`gitops-ok`**; commit checker đổi bằng PR (file `.github/` có Code Owner, App không có quyền `workflows`).

### 6. GitHub App

- `svp-gitops-promoter`: `contents: write`, `pull_requests: write`, `deployments: write`, `metadata: read`, không quyền nào khác; webhook tắt; cài chỉ trên `svp-gitops`.
- Environment `promote` của repo code: deployment branch chỉ `main`, không người duyệt; biến `SVP_GITOPS_APP_CLIENT_ID`, secret `SVP_GITOPS_APP_PRIVATE_KEY`; không giá trị nào vào repo.
- Token bằng `actions/create-github-app-token` ghim SHA, `owner: anhnvcoder`, `repositories: svp-gitops`, `permission-*` chỉ của bước đó, không `skip-token-revoke`.
- Ba job có environment `promote`, chỉ trên `main`: `promote` (nhánh `bot/promote-stg`, PR, auto-merge), promote prd (nhánh `bot/promote-prd`, không auto-merge), ghi bản ghi stg (chỉ `deployments` write; Deployment với `auto_merge: false`, `required_contexts: []` [N9]); không job `pull_request` nào khai `promote`.
- Check PR prd chỉ nhận bản ghi do chính App tạo, có URL lượt `verify.yml` trên `main`: khớp bản ghi chặn nhầm lẫn, chặn kẻ xấu là duyệt của Code Owner. Khoá App xoay bằng khoá mới, thay secret, xoá khoá cũ.

### 7. Ruleset và CODEOWNERS (7A)

- `CODEOWNERS`: `*` thuộc `@anhnvcoder`, `/envs/stg/` không chủ (dòng khớp cuối thắng [N5]); mọi file mới mặc định có chủ.
- Ruleset `main` (`bypass_actors: []`): `deletion`, `non_fast_forward`, `pull_request` (0 approval, `require_code_owner_review: false`, `dismiss_stale_reviews_on_push: true`), check bắt buộc `gitops-ok`.
- Ruleset `owners`: chỉ `pull_request` với `require_code_owner_review: true`, 0 approval; bypass vai admin của repo, `bypass_mode: pull_request` [N4]. Hai ruleset cộng dồn [N3]: PR bot chỉ đổi `envs/stg/` cần check, không cần duyệt, auto-merge; PR bot đổi file có chủ cần người học duyệt; PR của người học trên file có chủ merge bằng bypass `owners`, check của `main` vẫn bắt buộc.
- Ruleset `tags`: mọi tag, rule `creation`, `update`, `deletion`, bypass duy nhất admin `always`, vì token App đẩy được tag và Argo CD có thể phân giải tên ngắn sang tag cùng tên [N17].
- Cài đặt repo: "Allow auto-merge" bật; "Allow GitHub Actions to create and approve pull requests" tắt; chỉ action của GitHub, ghim SHA; secret scanning, push protection, Dependabot alerts như repo code.

### 8. Argo CD (8A)

- Root `svp-root` đọc `svp-gitops`, `path: argocd/apps`, `targetRevision` = `GITOPS_REV`, `valuesObject` có `targetRevision`, `env`, `nodeArch`, `chartRepoURL` (repo code).
- **Dựng ở commit đã kiểm, theo nhánh sau:** `GITOPS_REV` là nhánh thì `gitops.sh` dựng root ở đúng SHA đã kiểm image, chờ mọi Application Synced/Healthy rồi mới chuyển sang `refs/heads/<nhánh>`; là SHA thì ở yên. Kịch bản `gitops` giữ SHA suốt các bước kiểm, chỉ bước chờ phát hành mới theo nhánh; bản phát hành merge trong lúc ghim không được đo là độ trễ GitOps.
- Mọi `targetRevision` đọc `svp-gitops` là tên đầy đủ `refs/heads/<nhánh>` hay SHA 40 hex, không bao giờ tên ngắn [N17]; `gitops-check.sh` từ chối render có tên ngắn.
- Application chart repo: `repoURL` repo code, `targetRevision` = `revision` của `charts.yaml`; nguồn `ref: values` là `svp-gitops` ở revision của root. AppProject `svp`: `sourceRepos` thêm `svp-gitops`, giữ repo code và repo chart; đích và kind không đổi. `gitops.sh` đọc mọi thứ của revision từ bản clone bằng `git show`/`git archive`.

### 9. Trình tự chuyển (9A)

1. PR-A của repo code (ADR 0026, 0027, 0029) merge. 2. Cây khởi tạo dựng trong thư mục tạm; checker cùng test vào `main` repo code bằng PR riêng. 3. Người học tạo App, environment, cài đặt repo. 4. Push commit khởi tạo, rồi commit thêm workflow; lượt đầu xanh; nhập ba ruleset. 5. **Đóng băng** promote ở repo code từ bước 4. 6. PR-B cắt ở repo code: trước merge, `dev-k3d` và `gitops` trên nhánh xanh và bảy digest hai bên bằng nhau; merge, đóng PR `bot/promote` cũ; hết đóng băng. 7. `charts.yaml` lên commit merge của PR-B, bump commit checker, lượt `gitops` trên `main`.

Cách lùi: trước merge PR-B đường cũ vẫn chạy; sau merge mà hỏng thì revert PR-B ở repo code, `svp-gitops` giữ nguyên; không xoá `svp-gitops`.

### 10. Renovate (10A)

- `svp-gitops/renovate.json`: chuyển nguyên manager và nhóm của values, `components.json`, nhóm `argo-cd chart` (`argocd/bootstrap.json` + `base/argo-cd.yaml`), action của `check.yml`, commit checker (`git-refs`); `ignorePaths: ["envs/**"]`; `minimumReleaseAge` 3 ngày, không automerge. Repo code bỏ manager của đường đã dời.
- Renovate nâng chart upstream trong `base/` tới stg và prd cùng lúc, sau duyệt Code Owner.

### 11. Được và mất so với monorepo

Theo bảng lựa chọn 11 (phụ lục): thay đổi cần cả code lẫn cấu hình thành hai PR theo thứ tự; chỉ PR vào `svp-gitops` đổi được thứ đang chạy; hai lịch sử, hai bộ CI, một khoá App; đường dev thêm bản clone. Bảng ánh xạ GitLab (CI và repo, bậc gói): phụ lục.

### 12. Thay đổi ở repo code

Bảng file đổi của repo code (`lib.sh`, `install.sh`, `gitops.sh`, `promote.sh`, `rescan.sh`, `platform.sh`, workflow, `renovate.json`; xoá `deploy/k8s/values/`, `deploy/k8s/envs/`, `deploy/argocd/` ở PR-B): phụ lục; file đã hiện thực ở mục "Hiện thực ở".

### Hệ quả

- Tốt: quyền deploy tách khỏi quyền merge code, push vào `main` repo code không đổi cluster nào; stg nhận bản phát hành không cần ai bấm; một bản phát hành là bảy digest cộng commit chart, đi qua stg rồi mới tới prd; lịch sử triển khai đọc riêng.
- Xấu: thay đổi cần cả code lẫn cấu hình thành hai PR theo thứ tự, CI repo code phụ thuộc `main` của `svp-gitops`; một khoá App dài hạn trong environment `promote`; người học tự merge file chung (mô phỏng tách quyền, không có người thứ hai); thay đổi chỉ ở chart cần một lượt promote; thêm tên dành riêng `charts` và checker phải đọc được cây ở mọi `revision` còn ghim.
- Xem lại khi: repo web cần promote sang `svp-gitops` (App thứ hai hay cùng App); có người thứ hai (bỏ bypass `owners`); Source Hydrator hay Kargo đủ chín (Freight thay `charts.yaml` + `images/`); chart cần dùng ngoài lab (gói OCI ký, 2C).
- ADR cũ được chỉnh bởi ADR này: [ADR-0014](0014-kubernetes-local-stage4.md) §12, [ADR-0015](0015-cicd-devsecops-stage5.md) §9–§11, [ADR-0021](0021-deferred-verification-stage6b.md) §6, [ADR-0023](0023-ci-platform-neutral.md), [ADR-0024](0024-multi-environment.md) §8; nội dung chỉnh ở phụ lục, mục "Hệ quả".

## Xác nhận

- PR bot chỉ đổi `envs/stg/` tự merge sau `gitops-ok`, không ai duyệt, check chạy ngay lúc mở PR; giá trị dẫn xuất của `charts.yaml` tính lại khớp.
- Argo CD đọc hai repo ẩn danh, chart repo code ở SHA của `charts.yaml`, mọi Application Synced, Healthy; bản ghi stg tạo được và check PR prd nhận đúng bản ghi; ca âm của `gitops-check-test.sh` (image mới hơn chart, giá trị dẫn xuất sai) đỏ đúng message.
- Không đạt: duyệt Code Owner không chặn PR của người học (tác giả kiêm Code Owner duy nhất coi như đã thoả), nên cũng không có bản ghi bypass; lớp chặn còn lại là `gitops-ok`.
- Chưa kiểm: ca âm của PR bot đổi file có chủ, token App bị từ chối khi ghi repo code, PR thử sửa script ở repo code không đổi kết quả check. Bảng kiểm chứng và id lượt chạy: phụ lục, mục "Kiểm chứng sau".

## Hiện thực ở

- Repo `svp-gitops`: `README.md`, `CODEOWNERS`, `renovate.json`, `base/`, `envs/{stg,prd}/` (overlay, `charts.yaml`, `images/`), `argocd/` (`project.yaml`, `bootstrap.json`, `apps/`), `.github/workflows/check.yml`; ruleset ở `github/rulesets.tf` của `svp-infra`.
- Thư mục cấu hình: `gitops_dir`, `gitops_clone` của `deploy/k8s/lib.sh`, target `gitops-clone` của `deploy/k8s/k8s.mk`, `deploy/k8s/install.sh`.
- Check: `deploy/ci/gitops-check.sh` (+ `gitops-check-test.sh`), luật trên file của cây ở `deploy/ci/gitops-tree-policies/` (conftest, [0050](0050-bash-to-standard-tools.md)), `deploy/ci/values-check.sh`, `deploy/ci/verify-release.sh`, `deploy/ci/common.sh`.
- Argo CD: `argocd_root_app`, `follow_branch` của `deploy/k8s/lib.sh`, `deploy/k8s/gitops.sh`, job `gitops` của `.github/workflows/verify.yml` (dựng ở commit của `origin/main` trong bản clone).
- Promote, bản ghi, rescan: `deploy/ci/promote.sh`, `deploy/ci/release-set.sh`, `deploy/ci/record-stg.sh`, `deploy/ci/promote-prd.sh`, `deploy/ci/rescan.sh` (+ test), job `promote`, `promote-prd`, `rescan` của `.github/workflows/images.yml`, `record-stg` của `.github/workflows/verify.yml`, job `config` của `ci.yml`.
- Cài đặt GitHub (người học): [`docs/runbooks/svp-gitops-setup.md`](../runbooks/svp-gitops-setup.md). Danh sách file đầy đủ theo mục: phụ lục, mục "Hiện thực ở".

## Nguồn

- [N1] `actions/create-github-app-token`: <https://github.com/actions/create-github-app-token>
- [N3] GitHub Docs, "About rulesets": <https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-rulesets/about-rulesets>
- [N14] Argo CD, "Multiple Sources for an Application": <https://argo-cd.readthedocs.io/en/stable/user-guide/multiple_sources/>
- [N15] Kargo, "Core Concepts": <https://docs.kargo.io/user-guide/core-concepts/>
- [N17] Argo CD, "Tracking and Deployment Strategies": <https://argo-cd.readthedocs.io/en/stable/user-guide/tracking_strategies/>
- Danh sách đầy đủ [N1]–[N17] kèm trích dẫn: phụ lục, mục "Nguồn".

## Thông tin thêm

Phụ lục: [`appendix/0025-gitops-config-repo.md`](appendix/0025-gitops-config-repo.md) (tiêu đề và trạng thái gốc, bối cảnh đầy đủ, mọi bảng lựa chọn, toàn văn các §, "Cần người học chọn", "Kiểm chứng sau", hệ quả, hiện thực ở, nguồn).

### Chỉnh bởi

- §7: [0028](0028-dora-metrics.md) §5: quy ước revert và cài đặt squash của `svp-gitops`.
- §2, §5, §6: [0033](0033-svp-web-repo.md): luật tổ tiên chỉ cho nguồn `backend`, nguồn khác theo bảng nguồn; check đọc lịch sử `svp-frontend`, luật tác giả PR; App thứ hai `svp-web-promoter`; mục "Xem lại khi" về App của repo web.
- §5, §8: [0036](0036-repo-rename.md): check checkout repo code dưới tên mới `svp-backend`, không checkout repo web, clone ẩn danh repo của mỗi nguồn khác `backend`; URL repo chart của `chartRepoURL`, `sourceRepos`.
- §6: [0037](0037-mainpath-standard-tools.md): bị thay từ 2026-11-01: job promote bằng script, job ghi bản ghi stg, quyền `deployments` của App.
- §6, §7: [0041](0041-github-hardening.md): job promote prd dùng environment `promote-prd` có người duyệt, khoá App thứ hai; ruleset `main` chỉ squash, lịch sử thẳng; `CODEOWNERS`, ruleset `owners` ở backend, frontend, infra.
- §8: [0048](0048-prd-aws.md): trên EKS Argo CD do Terraform cài (GitOps Bridge, root `aws/gitops/<env>`), không qua `gitops.sh`; `svp-root` do ApplicationSet `svp-bootstrap` tạo, thêm chart tầng 1 `argocd/root` trước `argocd/apps`.
