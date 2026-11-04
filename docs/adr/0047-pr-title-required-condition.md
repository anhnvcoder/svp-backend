# 0047. `pr-title` thành check bắt buộc ở một repo khi `pr-title.yml` đã trên `main` và đã xanh ở ít nhất một PR, không đòi PR bot

- Trạng thái: Chấp nhận
- Ngày: 2026-11-04
- Người quyết: người học

## Bối cảnh và vấn đề

[0041](0041-github-hardening.md) (h) thêm job `pr-title` (workflow `pr-title.yml`) kiểm tiêu đề PR theo Conventional Commits ở `svp-backend`,
`svp-frontend`, `svp-gitops`, `svp-infra`, và chỉ cho nó thành check bắt buộc ở ruleset `main` sau khi đã xanh trên một PR người và một PR bot
ở từng repo. Ngày 2026-11-04: `pr-title.yml` đã trên `main` của cả bốn repo; `pr-title` xanh trên PR người ở bốn repo và trên PR bot ở
`svp-gitops`; `svp-backend`, `svp-frontend`, `svp-infra` chưa có PR bot nào kể từ khi `pr-title` chạy (Renovate mở PR theo lịch tuần, PR
promote chỉ mở ở `svp-gitops`). Trong lúc chờ, check vẫn chạy nhưng PR tiêu đề sai vẫn merge được.

## Yếu tố quyết định

- Check bắt buộc không báo trạng thái thì PR bị chặn ở "Waiting for status to be reported", check từ app khác app ruleset ghi thì không tính
  [N1]; một lượt xanh trên PR chứng minh tên job và app phát check khớp ruleset.
- Tiêu đề PR bot do cấu hình định sẵn, không do người gõ: Renovate bật `semanticCommits` với type `chore` (bản vá bảo mật `fix`), scope
  `deps` ở cả bốn repo [N2]; PR promote mang `chore(stg): …`, `chore(prd): …`, nằm trong bộ tiêu đề đạt của 0041 (h).
- Luật kiểm được mà không phụ thuộc lịch của bot.

## Phương án đã cân nhắc

- Giữ câu của 0041 (h), chờ PR bot ở từng repo: an toàn nhất cho PR bot; thời gian chờ không biết trước, check không chặn suốt thời gian đó.
- **`pr-title.yml` trên `main` và xanh ở ít nhất một PR, không đòi PR bot**: bắt buộc ngay khi đã chứng minh check chạy đúng tên; PR bot đầu
  tiên của repo có tiêu đề sai thì bị chặn.
- Bắt buộc ngay khi `pr-title.yml` merge: chưa có bằng chứng check chạy đúng tên; sai tên là mọi PR đứng chờ.

## Kết quả quyết định

Chọn phương án hai: `pr-title` thành check bắt buộc ở ruleset `main` của một repo khi `pr-title.yml` đã trên `main` của repo đó và `pr-title` đã
xanh ở ít nhất một PR; không đòi PR bot, vì tiêu đề PR bot là cấu hình đã theo Conventional Commits. Thay câu "một PR người và một PR bot ở
từng repo" của 0041 (h). Bốn repo đạt luật ngày 2026-11-04; repo có CI thêm về sau theo cùng luật.

### Hệ quả

- Tốt: tiêu đề sai bị chặn ở cả bốn repo từ khi `apply`, không chờ lịch Renovate.
- Xấu: PR bot đầu tiên ở `svp-backend`, `svp-frontend`, `svp-infra` chưa được thử; tiêu đề sai thì PR đó không tự merge cho tới khi sửa cấu
  hình bot hay tiêu đề.
- Xem lại khi: một PR bot bị `pr-title` chặn; đổi regex của 0041 (h) hay cấu hình tiêu đề của Renovate, App promote.

## Xác nhận

- `make check DIRS=github` của `svp-infra` xanh; `terraform plan` (người học chạy) chỉ bốn `update in-place` `github_repository_ruleset.*_main`,
  trong khối `required_status_checks`.
- Sau `apply`: PR tiêu đề sai bị chặn, `gh api` GET ruleset `main` có `pr-title`. Chưa kiểm: PR bot đầu tiên ở ba repo còn lại.

## Hiện thực ở

- `svp-infra`: `github/rulesets.tf` (`pr-title` trong `required_status_checks` của ruleset `main` ở bốn repo), `github/README.md`.
- `.github/workflows/pr-title.yml` của `svp-backend`, `svp-frontend`, `svp-gitops`, `svp-infra` (job `pr-title`).

## Nguồn

- Tính đến 2026-11-04. [N1] [Troubleshooting required status checks](https://docs.github.com/en/pull-requests/collaborating-with-pull-requests/collaborating-on-repositories-with-code-quality-features/troubleshooting-required-status-checks): check bắt buộc chưa báo thì PR bị chặn ("Waiting for status to be reported"); check đòi từ một GitHub App cụ thể ("was not set by the expected GitHub App").
- [N2] [Renovate: `semanticCommits`, `semanticCommitType`, `semanticCommitScope`](https://docs.renovatebot.com/configuration-options/#semanticcommits).
