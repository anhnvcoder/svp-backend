# 0041. Siết cài đặt GitHub và chuỗi CI của mọi repo: Code Owner trên đường nhạy cảm, chỉ squash với lịch sử thẳng, environment `promote-prd` có người duyệt, Scorecard, zizmor, dependency review, lint tiêu đề PR, Renovate tự merge hẹp lại

- Trạng thái: Chấp nhận
- Ngày: 2026-11-01
- Người quyết: người học (duyệt theo đề xuất)

## Bối cảnh và vấn đề

Cài đặt GitHub của sáu repo (`svp-backend`, `svp-frontend`, `svp-gitops`, `svp-infra`, `svp-labs`, `.github`) là code ở `github/` của
`svp-infra`. Đối chiếu với OpenSSF Scorecard và tài liệu bảo mật của GitHub Actions ngày 2026-11-01 thấy: không ruleset nào đòi duyệt; chỉ
`svp-gitops` có `CODEOWNERS`; không `required_linear_history`, `svp-backend` còn cho merge commit và rebase; job `promote-prd` dùng chung
environment `promote` của stg (không người duyệt, admin bypass được), nên cổng prd duy nhất là duyệt Code Owner trên PR prd, mà admin cũng
bypass được; `svp-backend` cho `GITHUB_TOKEN` tạo và duyệt PR dù không workflow nào cần; `svp-labs`, `.github` cho mọi action, không ghim
SHA, không ruleset; không Scorecard, không lint bảo mật workflow, không dependency review, không kiểm tiêu đề PR (thành tiêu đề commit
squash); Renovate tự merge cả bản vá Go module chạy thật ([0035](0035-renovate-automerge.md)).

Ràng buộc: lab một người trên tài khoản cá nhân, gói Free, mọi repo public; PR của bot (Renovate, App promote) phải tự đi được.

## Yếu tố quyết định

- Không ai (token lộ, admin bấm nhầm) đổi được prd, workflow hay luật quét mà không qua một bước duyệt có bản ghi.
- Luật là luật chặn được kiểm (ruleset, check tổng sẵn có); không thêm check bắt buộc khi `ci-ok`, `gitops-ok`, `infra-ok` gánh được; không
  action bên thứ ba khi shell đủ; chỉ dùng tính năng có ở gói Free cho repo public của tài khoản cá nhân (ruleset có ở đó [N1]).

## Phương án đã cân nhắc

- Duyệt PR: 0 approval (chọn); 1 approval với tài khoản thứ hai (duyệt giả, [0025](0025-gitops-config-repo.md) §7). Code Owner: chỉ đường
  nhạy cảm (chọn); `*` cả repo (chặn mọi PR Renovate tự merge); không `CODEOWNERS`.
- Cổng prd: environment `promote-prd` có người duyệt (chọn); chỉ duyệt Code Owner trên PR prd; `prevent_self_review = true`. Lint bảo mật
  workflow: zizmor qua image ghim (chọn); zizmor qua action chính thức; poutine; octoscan; chỉ CodeQL `actions`.
- Tiêu đề PR: job shell (chọn); ruleset metadata restrictions; action bên thứ ba; commitlint. Check: `strict = false` (chọn); `true`; merge queue.
- Renovate: tự merge hẹp lại (chọn); giữ [0035](0035-renovate-automerge.md); tắt hẳn tự merge.

## Kết quả quyết định

- **(a) Không đòi duyệt PR** (`required_approving_review_count = 0`) ở mọi ruleset, vì tác giả không tự duyệt PR của mình và lab chỉ có một
  người. Ngoại lệ có chủ ý với check Code-Review của Scorecard [N8]: điểm thấp được chấp nhận. Có người thứ hai có quyền ghi thì 1 approval,
  `require_last_push_approval`, `dismiss_stale_reviews_on_push`.
- **(b) `CODEOWNERS` ở gốc mọi repo**, vì Code Owner là luật duy nhất chặn PR của bot và người khác trên đúng file chọn [N16]. `svp-gitops` giữ
  nguyên (`*` có chủ, `/envs/stg/` không chủ). `svp-backend`, `svp-frontend`, `svp-infra`: chỉ `/CODEOWNERS`, `/.github/`, `/renovate.json`,
  `/Makefile`, `/.trivyignore.yaml`, `/.grype.yaml` có chủ, backend thêm `/deploy/ci/`, `/deploy/helm/svp-policy/`, infra thêm `/github/`,
  `/aws/`; file khác không chủ để PR Renovate tự merge vẫn chạy; ruleset `owners` riêng (`require_code_owner_review`, vai admin bypass chỉ ở
  chế độ `pull_request`) cùng dạng `svp-gitops`. `svp-labs`, `.github`: `* @anhnvcoder`, không đòi duyệt Code Owner (không bot nào mở PR).
  Đã đo ở `svp-gitops` ([`ci.md`](../reference/ci.md)): tác giả PR kiêm Code Owner duy nhất được GitHub coi là đã thoả luật, nên giá trị thật
  của luật là chặn PR của bot và người khác trên đường nhạy cảm.
- **(c) Chỉ squash merge, commit lấy `PR_TITLE` + `PR_BODY`, `required_linear_history`** ở ruleset `main` của mọi repo, vì mỗi commit trên
  `main` là một PR revert được, mang tiêu đề đã lint ở (h). Ruleset ghi `allowed_merge_methods = ["squash"]`: chặn cả khi cài đặt repo bị
  mở lại [N2]. `svp-labs`, `.github` có ruleset `main` mới: cấm xoá, force push, lịch sử thẳng, PR 0 approval, không check (không có CI).
- **(d) Environment `promote-prd`** ở `svp-backend` cho job `promote-prd`, vì cổng prd phải là bước dừng có bản ghi mà admin không bỏ qua
  được [N4]: người duyệt là người học; `prevent_self_review = false` (người dispatch là người duyệt duy nhất: bật thì không ai duyệt được);
  `can_admins_bypass = false`; chỉ nhánh `main`; biến Client ID như `promote`. Khoá App `svp-gitops-promoter` ở đây là **khoá riêng thứ
  hai** (App cho tới 25 khoá, thu hồi từng khoá [N5]), người học đặt tay. Environment `promote` của stg giữ nguyên.
- **(e) `can_approve_pull_request_reviews = false` ở `svp-backend`**, vì không workflow nào mở hay duyệt PR bằng `GITHUB_TOKEN` (PR promote
  dùng token App): quyền không ai dùng là đường tấn công thừa.
- **(f) `svp-labs`, `.github` theo cài đặt Actions của repo chính** (`allowed_actions = "selected"`, action của GitHub, không
  `verified_allowed`, ghim SHA bắt buộc), vì repo public cho mọi action thì PR fork hay tag bị đẩy lại chạy được code lạ. Pattern của
  `svp-labs` chỉ `sigstore/cosign-installer@*`, `.github` không pattern. Reusable workflow, composite action của chính repo không cần pattern:
  chế độ "Allow OWNER, and select non-OWNER, actions and reusable workflows" cho action cục bộ và reusable workflow [N6] (tài liệu nói
  "organization": Xác nhận kiểm lại trên repo cá nhân). Duyệt workflow PR fork `all_external_contributors` người học đặt tay (provider không quản).
- **(g) Scorecard và zizmor** ở `svp-backend`, `svp-frontend`, `svp-gitops`, `svp-infra` (không ở `svp-labs`: đường học, không CI; không ở
  `.github`: không workflow), vì Scorecard đo cả repo theo chuẩn OpenSSF còn zizmor chặn lỗi bảo mật từng workflow trước merge.
  - Scorecard: `scorecard.yml` riêng, khi push `main` và lịch tuần, `publish_results: true` (kết quả công khai; luật workflow: không `env`
    mức workflow, chỉ job Scorecard có `id-token: write` và chỉ gồm action được duyệt [N7]), SARIF lên code scanning, `ossf/scorecard-action@*`
    vào pattern của bốn repo; không `repo_token` (Branch-Protection đọc ruleset bằng `GITHUB_TOKEN`).
  - zizmor 1.31.1 [N9] từ image chính thức `ghcr.io/zizmorcore/zizmor` ghim `tag@sha256` có dòng `# renovate:` (`ZIZMOR_IMAGE` của
    `Makefile` ở backend, frontend, infra; của `env` trong `check.yml` ở `svp-gitops`). Chạy `zizmor --persona=regular` trên cả repo, chặn mọi
    finding (exit code 11–14); CI dùng `--format=github`, repo có job `sarif` chạy thêm `--format=sarif` (chỉ báo). Audit online bằng
    `GH_TOKEN` = `GITHUB_TOKEN` của job, chỉ `contents: read` (impostor commit, action có lỗ hổng); trên máy không token thì offline. Ngoại lệ ở
    `.github/zizmor.yml` (`rules.<id>.ignore`), mỗi mục một comment lý do. Job nằm trong check tổng, không thêm check bắt buộc.
- **(h) Lint tiêu đề PR theo Conventional Commits** [N15]: workflow `pr-title.yml`, job `pr-title`, `pull_request` loại `opened, edited,
  reopened, synchronize` [N18] (tách khỏi CI: sửa tiêu đề không chạy lại CI), `permissions: {}`, tiêu đề vào script qua `env`, kiểm bằng
  `[[ =~ ]]` của bash, vì ruleset metadata restrictions chỉ có ở gói Enterprise và kiểm metadata commit, không kiểm tiêu đề PR [N2]. Bốn repo
  có CI dùng chung regex (ngữ pháp, không liệt kê scope) và bộ thử dưới đây; `svp-backend` đổi commit squash sang `PR_TITLE` + `PR_BODY` như
  ba repo kia. `pr-title` thành check bắt buộc chỉ sau khi đã xanh trên một PR người và một PR bot ở từng repo.

  ```text
  ^(feat|fix|chore|docs|refactor|test|ci|build|perf|revert)(\([^)]+\))?!?: .+|^Revert ".+"$
  ```

  - Đạt: `feat(feed): thêm phân trang explore`, `feat(api)!: bỏ trường cũ`, `fix(deps): update module golang.org/x/net to v0.47.1 [security]`,
    `chore(deps): lock file maintenance`, `chore(config): migrate config renovate.json`, `chore(stg): phát hành feed-service ở 0a1b2c3d4e5f`,
    `chore(prd): phát hành bộ stg của svp-gitops 0a1b2c3d4e5f`, `Revert "feat(feed): thêm phân trang explore"` (nút Revert của GitHub).
  - Không đạt: `Update README.md`, `style: format`, `feat:thiếu dấu cách`, `feat(): scope rỗng`, `Feat(feed): chữ hoa`, `chore(deps):`,
    `fix(deps) : dấu cách trước hai chấm`, `Revert feat(feed): thiếu ngoặc kép`.
- **(i) Renovate tự merge hẹp lại** (thay một phần [0035](0035-renovate-automerge.md)), vì bản vá Go module hay base image chạy thật vào stg
  mà chỉ CI chặn là đường chuỗi cung ứng rộng nhất [N17]. Chỉ tự merge `digest`, `pinDigest` của image (cùng tag, digest mới) và `patch` của thứ
  chỉ dùng lúc dev (npm `devDependencies`, image của compose). Duyệt tay: mọi cập nhật Go module (cả `digest`, tức pseudo-version sang commit
  mới, và directive `go`), npm `dependencies`, patch tag của base image và image chạy trong cluster, image của workflow (`.github/` có chủ), image công cụ ghim
  trong `Makefile` (`/Makefile` có chủ).
- **(j) `strict_required_status_checks_policy` giữ `false`**, vì bật thì mỗi PR (cả PR bot tự merge) phải cập nhật nhánh và build lại image
  (`images-ok`) sau mỗi merge; merge queue (cách chuẩn để có `strict` mà không tốn thế) chỉ có ở repo của organization [N3], không có ở repo
  của tài khoản cá nhân. Lượt CI trên `main` sau merge bắt xung đột ngữ nghĩa.
- **(k) Dependency review trên PR** ở backend (Go module) và frontend (npm): job `actions/dependency-review-action` ghim SHA [N14] (của GitHub,
  miễn phí cho repo public), `fail-on-severity: high`, không `allow-licenses` (license chỉ hiện trong tóm tắt: chưa có danh sách license), vì
  nó chặn dependency có lỗ hổng ngay lúc PR thêm vào, trước khi trivy, grype thấy trong image. Job chỉ chạy trên `pull_request`, nằm trong
  `ci-ok`; `ci-ok` nhận nó `skipped` ở sự kiện khác.

### Hệ quả

- Tốt: prd chỉ đổi sau một lần duyệt có bản ghi mà admin không bypass; workflow, luật quét, cài đặt GitHub chỉ đổi qua người học kể cả khi PR
  do bot mở; `main` thẳng, mỗi commit một PR có tiêu đề đúng chuẩn; lỗi bảo mật workflow bị chặn trước merge; Scorecard công khai số đo.
- Xấu: Scorecard Code-Review luôn thấp, người học vẫn tự merge PR của mình trên đường có chủ; promote prd thêm một lần duyệt và một khoá App
  phải xoay, người học vắng thì không ai promote prd (có chủ đích); PR Renovate đọc tay tăng, bản vá vào stg chậm hơn; zizmor báo nhầm thì
  thêm mục `zizmor.yml` phải giữ; `strict = false`: hai PR xanh riêng có thể đỏ khi ghép, chỉ lộ ở lượt `main` sau merge (PR revert).
- Xem lại khi: có người thứ hai có quyền ghi (a); repo chuyển sang organization (merge queue và `strict = true`, (j)); một bản tự merge làm đỏ
  `main` hay hỏng stg (i); `.github` có workflow hay `svp-labs` có CI (Scorecard, zizmor ở đó).

## Xác nhận

Thứ tự áp: cài đặt repo, ruleset (chưa có `pr-title`), environment `promote-prd` với khoá thứ hai, duyệt PR fork trước; rồi merge
`CODEOWNERS`, workflow, `renovate.json`; `pr-title` thành check bắt buộc chỉ sau lượt xanh trên PR người và PR bot của từng repo. Cách kiểm:

- `terraform plan` của `github/` chỉ đổi đúng các mục trên; sau `apply`, `gh api` GET khớp `.tf`; `uses:` của mọi workflow nằm trong danh
  sách cho phép; dispatch `reusable-spike-caller.yml` của `svp-labs` chạy được (N6).
- zizmor exit 0 ở bốn repo, check tổng đỏ khi job zizmor đỏ; bộ tiêu đề thử ở (h) chạy trong test của `pr-title`; PR tiêu đề sai bị chặn.
- Dispatch `promote_prd` dừng chờ duyệt, Reject thì không PR prd nào mở; lượt `scorecard.yml` đầu trên `main` xanh, có kết quả ở API Scorecard.
- `renovate-config-validator --strict` đạt; không file nào vừa được tự merge vừa có Code Owner.

## Ưu nhược từng phương án

Lint bảo mật workflow, tính đến 2026-11-01 (bản phát hành đọc từ API GitHub ngày đó; không nguồn riêng về mức dùng):

| Công cụ | Trạng thái | Ghi chú |
| --- | --- | --- |
| zizmor [N9] | hiện hành | Chuyên bảo mật workflow; v1.31.1 (2026-10-15), image chính thức đa kiến trúc, action `zizmorcore/zizmor-action` |
| poutine [N10] | hiện hành, ngách | Quét chuỗi build nhiều nền tảng (GitHub, GitLab…); v1.1.6 (2026-05-22) |
| octoscan [N11] | mới nổi | Chưa 1.0 (v0.1.7, 2026-03-30) |
| actionlint [N12] | hiện hành | Đã có ở job `config`: cú pháp, kiểu, shellcheck; không phải công cụ bảo mật |
| CodeQL `actions` [N13] | hiện hành | Default setup của backend đã quét `actions`, chỉ báo, không chặn PR |
| Scorecard [N7] | hiện hành | Đo cấp repo (ruleset, ghim, quyền), không lint từng dòng: bổ sung, không thay zizmor |

- zizmor qua image ghim: một bản cho máy và CI, Renovate theo dõi, allowlist không đổi; action chính thức tự đẩy SARIF nhưng thêm một action
  bên thứ ba có `security-events: write`. Metadata restrictions: chỉ Enterprise, không kiểm tiêu đề PR [N2]; action kiểu
  `action-semantic-pull-request`: thêm vào allowlist cho việc một regex làm được; commitlint: thêm Node và cấu hình ở mọi repo.
- `prevent_self_review = true`: lab một người thì không ai duyệt được; chỉ Code Owner trên PR prd: admin bypass được, không bước dừng trước
  khi job lấy khoá App. `strict = true` không merge queue: PR bot chờ cập nhật nhánh, build lại, auto-merge kẹt nối đuôi.
- Giữ [0035](0035-renovate-automerge.md): bản vá Go module bị chiếm (tuổi do người phát hành tự đặt) vào stg không ai đọc; tắt hẳn tự merge:
  hàng chục PR tay mỗi tuần, cả digest image.

## Hiện thực ở

- `svp-infra`: `github/repositories.tf` (cách merge, commit squash, `can_approve`, Actions của `svp-labs`, `.github`, pattern Scorecard),
  `github/rulesets.tf` (`main` của sáu repo, `owners` của backend, frontend, infra, `pr-title` bắt buộc), `github/environments.tf`
  (`promote-prd`), `github/README.md`; `Makefile`, `.github/workflows/check.yml` (zizmor).
- `CODEOWNERS` ở gốc `svp-backend`, `svp-frontend`, `svp-infra`, `svp-labs`, `.github`; `.github/workflows/scorecard.yml`, `pr-title.yml`,
  `.github/zizmor.yml` của backend, frontend, gitops, infra (sẽ có); `.github/workflows/check.yml` của `svp-gitops` (zizmor).
- `svp-backend`, `svp-frontend`: `.github/workflows/ci.yml` (zizmor, dependency review), `Makefile`, `renovate.json`; backend thêm
  `.github/workflows/images.yml` job `promote-prd`.

## Nguồn

- Tính đến 2026-11-01. [N1] [About rulesets](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-rulesets/about-rulesets): ruleset có ở repo public của gói Free. [N2] [Available rules for rulesets](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-rulesets/available-rules-for-rulesets): linear history, merge method bắt buộc; metadata restrictions chỉ gói Enterprise, kiểm metadata commit (squash: commit kết quả).
- [N3] [Managing a merge queue](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/configuring-pull-request-merges/managing-a-merge-queue): "available in any public repository owned by an organization, or in private repositories owned by organizations using GitHub Enterprise Cloud".
- [N4] [Deployments and environments](https://docs.github.com/en/actions/reference/workflows-and-actions/deployments-and-environments): required reviewers, prevent self-review, tắt admin bypass; ở gói Free chỉ cho repo public. [N5] [Managing private keys for GitHub Apps](https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/managing-private-keys-for-github-apps): tới 25 khoá mỗi App.
- [N6] [Managing GitHub Actions settings for a repository](https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/enabling-features-for-your-repository/managing-github-actions-settings-for-a-repository): chế độ "Allow OWNER, and select non-OWNER…", action cục bộ và reusable workflow.
- [N7] [ossf/scorecard-action](https://github.com/ossf/scorecard-action) v2.5.0 (2026-10-12): `publish_results`, Workflow Restrictions, Branch-Protection đọc ruleset không cần token admin. [N8] [Scorecard checks: Code-Review](https://github.com/ossf/scorecard/blob/main/docs/checks.md#code-review).
- [N9] zizmor: [Installation](https://docs.zizmor.sh/installation/) (image `ghcr.io/zizmorcore/zizmor`), [Usage](https://docs.zizmor.sh/usage/) (chế độ online, exit code, persona), [Configuration](https://docs.zizmor.sh/configuration/), [releases](https://github.com/zizmorcore/zizmor/releases).
- [N10] [boostsecurityio/poutine](https://github.com/boostsecurityio/poutine). [N11] [synacktiv/octoscan](https://github.com/synacktiv/octoscan). [N12] [rhysd/actionlint](https://github.com/rhysd/actionlint).
- [N13] [CodeQL: supported languages and frameworks](https://codeql.github.com/docs/codeql-overview/supported-languages-and-frameworks/) (GitHub Actions workflows). [N14] [actions/dependency-review-action](https://github.com/actions/dependency-review-action) v5.0.0: repo public, `fail-on-severity`, `allow-licenses`.
- [N15] [Conventional Commits 1.0.0](https://www.conventionalcommits.org/en/v1.0.0/). [N16] [About code owners](https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/customizing-your-repository/about-code-owners).
- [N17] Renovate: [configuration options](https://docs.renovatebot.com/configuration-options/) (`automerge`, `matchUpdateTypes`, `matchDepTypes`). [N18] [Events that trigger workflows: `pull_request`](https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows#pull_request) (loại `edited`).
