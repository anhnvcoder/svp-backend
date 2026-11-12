# Tài liệu của `svp-backend`

Mục lục theo [Diátaxis](https://diataxis.fr): mỗi tài liệu thuộc một trong bốn loại, mỗi loại một mục đích. Bắt đầu từ
[`README.md`](../README.md) của repo (chạy thử, bản đồ thư mục); luật làm việc cho agent ở [`AGENTS.md`](../AGENTS.md).

## Tutorial: học bằng cách làm

- [`tutorials/first-run.md`](tutorials/first-run.md): clone repo, dựng stack bằng `make up OBS=lgtm`, chạy `make smoke`, đọc một trace
  trong Grafana.

## How-to: làm một việc cụ thể

- [`runbooks/`](runbooks/): một runbook cho mỗi cảnh báo mức page, sự cố đã gặp và quy trình tay (dựng `svp-gitops`, `svp-frontend`,
  `svp-infra`, đổi khoá JWT, phục hồi Postgres). Mục lục và mẫu ở [`runbooks/README.md`](runbooks/README.md).

## Reference: tra cứu

- [`reference/`](reference/): lệnh `make`, `.env` và biến, stack compose, cluster k3d và EKS, workflow CI, quy ước test.
- [`reference/contracts.md`](reference/contracts.md): topic event, phân trang feed, mã lỗi gRPC sang HTTP, route REST ở gateway.
- [`ci-cd.md`](ci-cd.md): đọc một lượt chạy GitHub Actions: job nào chạy khi nào, vì sao skip, kết quả ở đâu.
- Hợp đồng REST: [`services/gateway/openapi.yaml`](../services/gateway/openapi.yaml); contract gRPC và event: [`proto/`](../proto/).

## Explanation: hiểu vì sao

- [`architecture.md`](architecture.md): thiết kế hiện tại theo arc42 và C4: mục tiêu, ràng buộc, khối, runtime, triển khai, rủi ro.
- [`explanation/capabilities.md`](explanation/capabilities.md): năng lực kỹ thuật của hệ thống qua bốn repo, chuẩn ngành mỗi
  năng lực theo và nơi hiện thực.
- [`explanation/capacity.md`](explanation/capacity.md): ước lượng quy mô: tải, dữ liệu, băng thông và thiết kế rút ra từ đó.
- [`explanation/deployment.md`](explanation/deployment.md): compose, k3d và EKS: mỗi nơi gồm gì, vì sao khác nhau.
- [`explanation/environments.md`](explanation/environments.md): stg và prd: thành phần nào phải giống, được giảm hay giảm có
  điều kiện, vì sao, và khi giảm thì kiểm bù ở đâu.
- [`explanation/delivery.md`](explanation/delivery.md): CI/CD, chuỗi cung ứng, ba repo và hợp đồng API.
- [`explanation/observability.md`](explanation/observability.md): trace, metric, log, lỗi và số đo trình duyệt đi từ đâu tới đâu.
- [`explanation/reliability.md`](explanation/reliability.md): SLO, tải, backup, probe và vận hành.
- [`threat-model.md`](threat-model.md): mối đe doạ theo bề mặt (STRIDE) và cách kiểm từng mối.
- [`adr/`](adr/): nhật ký quyết định kiến trúc, mỗi quyết định một file; không bắt buộc đọc để dùng repo. Mục lục, trạng thái và
  quy ước (ADR ngắn, chi tiết và số đo ở phụ lục) ở [`adr/README.md`](adr/README.md).
- [`postmortems/`](postmortems/): postmortem không đổ lỗi của sự cố và game day.
- [`rfc/`](rfc/): đề xuất một trang cho người không làm kỹ thuật.

## Chuẩn áp dụng

Mỗi tài liệu và mỗi khuôn mẫu theo một chuẩn ngành có nguồn chính thức, để vừa dùng vừa học chuẩn đó. Tài liệu và mã hiện có được
đưa về các chuẩn này; ADR theo quy ước của [`adr/README.md`](adr/README.md): quyết định không đổi, chi tiết và lịch sử ở phụ lục.

| Mảng | Chuẩn | Áp ở đâu |
| --- | --- | --- |
| Cấu trúc tài liệu | [Diátaxis](https://diataxis.fr): tutorial, how-to, reference, explanation | Mục lục này, `docs/reference/` |
| Kiến trúc | [C4 model](https://c4model.com), [arc42](https://arc42.org) rút gọn; sơ đồ dạng code | `architecture.md` |
| Quyết định | ADR theo [MADR 4](https://adr.github.io/madr/): bối cảnh, phương án, quyết định, hệ quả; ngắn; đã chấp nhận thì bất biến | `adr/` |
| Cửa vào | [standard-readme](https://github.com/RichardLitt/standard-readme) | `README.md` |
| Giấy phép | [Apache-2.0](https://spdx.org/licenses/Apache-2.0.html), văn bản chuẩn nguyên văn | `LICENSE` |
| Tệp cộng đồng | [GitHub community health files](https://docs.github.com/en/communities); [Keep a Changelog](https://keepachangelog.com) và [SemVer](https://semver.org) cho thứ có version | `CONTRIBUTING.md`, `SECURITY.md`, hợp đồng REST |
| Hướng dẫn cho agent | [AGENTS.md](https://agents.md); `CLAUDE.md` chỉ import `AGENTS.md` | `AGENTS.md`, `CLAUDE.md` |
| Comment Go | [Go Doc Comments](https://go.dev/doc/comment), [Effective Go](https://go.dev/doc/effective_go), [Google Go Style Guide](https://google.github.io/styleguide/go); bố cục theo [go.dev/doc/modules/layout](https://go.dev/doc/modules/layout) | `services/`, `internal/`, `tools/` |
| Shell | [Google Shell Style Guide](https://google.github.io/styleguide/shellguide.html), [ShellCheck](https://www.shellcheck.net) | `deploy/**/*.sh` |
| Helm | [Helm chart best practices](https://helm.sh/docs/chart_best_practices/) | `deploy/helm/` |
| CI | [GitHub Actions security hardening](https://docs.github.com/en/actions/security-guides/security-hardening-for-github-actions), [OpenSSF Scorecard](https://scorecard.dev) làm thước đo | `.github/workflows/` |
| Văn phong | [Google developer documentation style guide](https://developers.google.com/style): câu ngắn, chủ động, thuật ngữ nhất quán | Mọi `.md` |
| Kiểm tài liệu tự động | [docs-as-code](https://www.writethedocs.org/guide/docs-as-code/): [markdownlint-cli2](https://github.com/DavidAnson/markdownlint-cli2) (`.markdownlint.yaml`), [lychee](https://lychee.cli.rs) (link và anchor nội bộ), image ghim digest | `make docs-check` |
| Nhãn tiến độ | Lịch sử ở git log, CHANGELOG, ADR; code và tài liệu hiện trạng không mang nhãn tiến độ của dự án | Mọi file ngoài ADR, postmortem |
