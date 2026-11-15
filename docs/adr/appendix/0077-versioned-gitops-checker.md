# Phụ lục ADR-0077: Checker của `svp-gitops` phát hành theo semver bằng release-please

Phụ lục của [ADR-0077](../0077-versioned-gitops-checker.md): phương án, cấu hình release-please, quyền App, cách Renovate đọc digest, nguồn.
Đọc 2026-11-15 trừ khi ghi khác.

## Phương án

### Cách `svp-gitops` ghim checker

| Phương án | Trạng thái ngành | Được | Mất | Nguồn |
| --- | --- | --- | --- | --- |
| Giữ commit `main` + Renovate `git-refs` | Hiện trạng | Không thêm gì | Mỗi commit là một bản; không changelog, không tín hiệu breaking; đổi hợp đồng cần thứ tự tay | ADR-0025 §5, §10 |
| Reusable workflow `{owner}/{repo}/.github/workflows/{file}@{ref}` | Hiện hành | Logic job ở repo code; ref là SHA, tag hay nhánh, GitHub khuyên SHA | Check còn đọc chart ở lịch sử repo code nên job vẫn checkout repo code; tag vẫn cần version; đổi cấu trúc job (`gitops-ok`, `diff-preview`) | [N11] |
| OCI artifact bằng ORAS | Hiện hành; CNCF Sandbox | Gói bất biến theo digest, ký được | Thêm push GHCR, ký, kéo; không thay được checkout lịch sử chart | [N12] |
| Image checker | Hiện hành | Script và công cụ ghim trong một image | Thêm build, quét, ký, rescan một image; vẫn cần repo code cho chart | — |
| **Tag git semver trên repo code** | Hiện hành | Không đổi cách chạy check; ghim bằng tag + commit; Renovate đọc tag | Thêm một quy trình phát hành | [N1] |

### Công cụ phát hành

| Phương án | Trạng thái ngành | Được | Mất | Nguồn |
| --- | --- | --- | --- | --- |
| **release-please** (manifest) | Hiện hành; action v5.0.0 (2026-04-22), lõi 17.6.0 (2026-04-13) | PR phát hành từ Conventional Commits; changelog; tag; GitHub Release; nhiều package theo đường | Một PR phát hành mỗi bản; App để PR đó chạy CI | [N1], [N6] |
| semantic-release | Hiện hành | Phát hành ngay khi commit vào nhánh phát hành | Không có PR phát hành: tag và changelog sinh ra không qua cổng PR; hệ sinh thái plugin npm | [N13] |
| changesets | Hiện hành | Người đóng góp khai mức thay đổi từng PR | Mỗi PR thêm file changeset; trùng với tiêu đề Conventional Commits đã bắt buộc; hướng monorepo npm | [N14] |

## 2. Release checker

Cấu hình (giá trị, không phải file; thay đổi hiện thực viết file theo `$schema` của 17.6.0):

```json
{
  "$schema": "https://raw.githubusercontent.com/googleapis/release-please/v17.6.0/schemas/config.json",
  "packages": {
    "deploy/ci": {
      "release-type": "simple",
      "component": "gitops-check",
      "initial-version": "1.0.0",
      "include-component-in-tag": true
    }
  }
}
```

- `initial-version`: "Releases the initial library with a specified version"; strategy dùng nó cho bản đầu (`initialReleaseVersion` của
  `src/strategies/base.ts`) [N2], [N5].
- `include-component-in-tag`, `include-v-in-tag`: mặc định `true` [N2]; tag `gitops-check-v1.0.0` (dấu phân cách mặc định `-`).
- `changelog-path`: "Defaults to `CHANGELOG.md`", tính từ đường package (`addPath`), nên `deploy/ci/CHANGELOG.md` [N2], [N4].
- Strategy `simple`: changelog `createIfMissing: true`, file version `createIfMissing: false` [N4]: không `version.txt`, version ở manifest.
- Mức tăng: commit breaking → major, `feat` → minor, còn lại → patch (`src/versioning-strategies/default.ts`); "A 'chore' or 'build' commit is not
  a releasable unit." [N1]. Commit chia theo đường package, commit chỉ chạm file ngoài đường bị bỏ (`src/util/commit-split.ts`).
- `bootstrap-sha`: "This is an uncommon use case and should generally be avoided." [N2]; tìm lịch sử tới `commit-search-depth`, mặc định 500
  (`DEFAULT_COMMIT_SEARCH_DEPTH` [N3]). Lúc quyết lịch sử `main` có 161 commit, 58 chạm `deploy/ci`: CHANGELOG `1.0.0` gồm các commit `feat`, `fix`
  trong đó.

## 3. Workflow và App phát hành

- README action v5.0.0, mục "Workflow Permissions" cho `GITHUB_TOKEN`: `contents: write`, `issues: write`, `pull-requests: write`; và "You will
  want to configure a GitHub Actions secret with a Personal Access Token if you want GitHub Actions CI checks to run on Release Please PRs." [N6].
  App thay PAT: token installation ngắn hạn, quyền theo App, chỉ cài một repo.
- Release-please gọi `octokit.issues.addLabels`, `issues.removeLabel`, `issues.createComment` (`src/github-api.ts` [N7]); nhãn mặc định
  `autorelease: pending`, `autorelease: tagged` [N3].
- Bảng quyền GitHub App liệt kê `POST /repos/{owner}/{repo}/issues/{issue_number}/labels` và `POST /repos/{owner}/{repo}/labels` dưới cả
  "Issues" và "Pull requests", mức write; endpoint có dấu ✓ nhận một quyền bất kỳ trong tập: "Other endpoints work with any one permission
  from a set of permissions." [N8]. Vì vậy App chỉ có `pull_requests: write`; lượt đầu báo lỗi quyền nhãn hay comment thì thêm `issues: write`
  bằng ADR chỉnh.
- SHA tag `v5.0.0` của `googleapis/release-please-action`: commit `45996ed1f6d02564a971a2fa1b5860e934307cf7` (tag không annotate).

## 5. Ghim checker

- Datasource `github-tags` của Renovate 44.239.1 lấy tag bằng GraphQL, mỗi bản có `newDigest: hash`; với tag có annotate, `hash` là `oid` của
  `target` (commit) [N9]. Bước sinh cập nhật gán `update.newDigest = release.newDigest` [N10]. `extractVersion` chỉ đổi chuỗi version, không
  đổi digest.
- `separateMajorMinor` mặc định `true`: "If set to `false`, Renovate will upgrade dependencies to their latest release only." [N15].
- Cấu hình chung của `svp-gitops/renovate.json`: `schedule: ["* 0-8 * * 6"]` (`timezone` `Asia/Ho_Chi_Minh`), `minimumReleaseAge: "3 days"`.
  Luật cũ của checker khớp `matchDatasources: ["git-refs"]` và chỉ bỏ `minimumReleaseAge`; datasource đổi sang `github-tags` thì luật đó thôi
  khớp, mỗi bản checker chờ 3 ngày rồi tới sáng thứ Bảy kế tiếp (tới 10 ngày) [N17]. Luật thay nó (giá trị, không phải file):

```json
{
  "matchDatasources": ["github-tags"],
  "matchPackageNames": ["anhnvcoder/svp-backend"],
  "minimumReleaseAge": null,
  "schedule": ["at any time"]
}
```

- `minimumReleaseAge` chờ một bản đủ cũ để bản bị rút hay độc hại lộ ra; bản checker do chính repo code phát hành, đã qua `ci-ok`, `images-ok`,
  Code Owner, tag bất biến, nên khoảng chờ không thêm gì. `schedule` mặc định `["at any time"]`, `minimumReleaseAge` mặc định `null` [N15].
- Mend Renovate Community Cloud chạy job định kỳ cho repo đang hoạt động mỗi 4 giờ, và đưa job vào hàng khi có webhook, cả thao tác trên
  Dependency Dashboard [N16]: PR nâng ghim tới trong 4 giờ sau tag, hay sớm hơn khi người học tick một ô trên dashboard (`dependencyDashboard: true`).
- Bước khớp tag đọc tag từ chính checkout đủ lịch sử hay `git ls-remote` ẩn danh, không token; thông điệp lỗi nêu tag, commit mong và commit thật.

## Nguồn

- [N1] googleapis/release-please, README v17.6.0: <https://github.com/googleapis/release-please>. "Release Please automates CHANGELOG generation,
  the creation of GitHub releases, and version bumps for your projects."; "Release Please also supports releasing multiple artifacts from the
  same repository."; `fix:` "correlates to a SemVer patch", `feat:` "correlates to a SemVer minor", `!` "will result in a SemVer major".
- [N2] release-please, `schemas/config.json` v17.6.0: <https://github.com/googleapis/release-please/blob/v17.6.0/schemas/config.json>
  (`initial-version`, `include-component-in-tag`, `include-v-in-tag`, `changelog-path`, `bootstrap-sha`, `last-release-sha`, `commit-search-depth`).
- [N3] release-please, `src/manifest.ts` v17.6.0: <https://github.com/googleapis/release-please/blob/v17.6.0/src/manifest.ts>
  (`DEFAULT_LABELS = ['autorelease: pending']`, `DEFAULT_RELEASE_LABELS = ['autorelease: tagged']`, `DEFAULT_COMMIT_SEARCH_DEPTH = 500`).
- [N4] release-please, `src/strategies/simple.ts` v17.6.0: <https://github.com/googleapis/release-please/blob/v17.6.0/src/strategies/simple.ts>.
- [N5] release-please, `src/strategies/base.ts` v17.6.0: <https://github.com/googleapis/release-please/blob/v17.6.0/src/strategies/base.ts>.
- [N6] googleapis/release-please-action, README v5.0.0: <https://github.com/googleapis/release-please-action/blob/v5.0.0/README.md>; releases
  <https://github.com/googleapis/release-please-action/releases> (v5.0.0, 2026-04-22).
- [N7] release-please, `src/github-api.ts` v17.6.0: <https://github.com/googleapis/release-please/blob/v17.6.0/src/github-api.ts>.
- [N8] GitHub, "Permissions required for GitHub Apps": <https://docs.github.com/en/rest/authentication/permissions-required-for-github-apps>.
- [N9] Renovate 44.239.1, `lib/modules/datasource/github-tags/index.ts`:
  <https://github.com/renovatebot/renovate/blob/44.239.1/lib/modules/datasource/github-tags/index.ts>; `lib/util/github/graphql/query-adapters/tags-query-adapter.ts`.
- [N10] Renovate 44.239.1, `lib/workers/repository/process/lookup/generate.ts`:
  <https://github.com/renovatebot/renovate/blob/44.239.1/lib/workers/repository/process/lookup/generate.ts>.
- [N11] GitHub, "Reuse workflows": <https://docs.github.com/en/actions/how-tos/reuse-automations/reuse-workflows>. "the `{ref}` can be a SHA, a
  release tag, or a branch name."; "Using the commit SHA is the safest option for stability and security."
- [N12] ORAS: <https://oras.land/docs/>. "It allows you to push (upload) and pull (download) things to and from an OCI Registry."; "We are a Cloud
  Native Computing Foundation Sandbox Project."
- [N13] semantic-release: <https://semantic-release.gitbook.io/semantic-release/> ("For each new commit added to one of the release branches").
- [N14] changesets: <https://github.com/changesets/changesets>. "A tool to manage versioning and changelogs with a focus on monorepos"; "It lets
  contributors declare how their changes should be released."
- [N15] Renovate 44.239.1, `lib/config/options/index.ts` (`separateMajorMinor` `default: true`; `schedule` `default: ['at any time']`;
  `minimumReleaseAge` `default: null`): <https://github.com/renovatebot/renovate/blob/44.239.1/lib/config/options/index.ts>.
- [N16] Mend Renovate, "Mend-hosted Apps" (tài liệu của 44.239.1): <https://docs.renovatebot.com/mend-hosted/overview/>. "Job scheduling (active
  repos)": "Every 4 hours" ở Community Cloud và Community (OSS) Cloud; "It also listens to webhooks and enqueues a Renovate job when relevant
  changes occur in a repo, or when actions are triggered from the Renovate PRs or Dashboard issue."
- [N17] `svp-gitops/renovate.json` (nhánh `main` lúc quyết): `schedule`, `minimumReleaseAge`, luật `matchDatasources: ["git-refs"]` của checker.
