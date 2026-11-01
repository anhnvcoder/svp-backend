# Tài liệu của `svp-backend`

Mục lục theo [Diátaxis](https://diataxis.fr): mỗi tài liệu thuộc một trong bốn loại, mỗi loại một mục đích. Bắt đầu từ
[`README.md`](../README.md) của repo (chạy thử, bản đồ thư mục); luật làm việc cho agent ở [`AGENTS.md`](../AGENTS.md).

## Tutorial: học bằng cách làm

Chưa có. Sổ tay dẫn người mới dựng và đi qua luồng request, luồng phát hành sẽ viết sau khi phần cloud xong.

## How-to: làm một việc cụ thể

- [`runbooks/`](runbooks/): một runbook cho mỗi cảnh báo mức page, sự cố đã gặp và quy trình tay (dựng `svp-gitops`, `svp-frontend`,
  `svp-infra`, đổi khoá JWT, phục hồi Postgres). Mục lục và mẫu ở [`runbooks/README.md`](runbooks/README.md).

## Reference: tra cứu

- [`reference/`](reference/): lệnh `make`, `.env` và biến, stack compose, cluster k3d và EKS, workflow CI, quy ước test.
- [`ci-cd.md`](ci-cd.md): đọc một lượt chạy GitHub Actions: job nào chạy khi nào, vì sao skip, kết quả ở đâu.
- Hợp đồng REST: [`services/gateway/openapi.yaml`](../services/gateway/openapi.yaml); contract gRPC và event: [`proto/`](../proto/).

## Explanation: hiểu vì sao

- [`architecture.md`](architecture.md): thiết kế hiện tại: yêu cầu, ước lượng quy mô, C4, luồng chính, contract.
- [`threat-model.md`](threat-model.md): mối đe doạ theo bề mặt (STRIDE) và cách kiểm từng mối.
- [`adr/`](adr/): nhật ký quyết định kiến trúc, mỗi quyết định một file; không bắt buộc đọc để dùng repo. Mục lục ở
  [`adr/README.md`](adr/README.md).
- [`postmortems/`](postmortems/): postmortem không đổ lỗi của sự cố và game day.
- [`rfc/`](rfc/): đề xuất một trang cho người không làm kỹ thuật.

## Chuẩn áp dụng

Mỗi tài liệu và mỗi khuôn mẫu theo một chuẩn ngành có nguồn chính thức, để vừa dùng vừa học chuẩn đó. Tài liệu và mã hiện có được
đưa dần về các chuẩn này; ADR cũ giữ nguyên vì là lịch sử.

| Mảng | Chuẩn | Áp ở đâu |
| --- | --- | --- |
| Cấu trúc tài liệu | [Diátaxis](https://diataxis.fr): tutorial, how-to, reference, explanation | Mục lục này, `docs/reference/` |
| Kiến trúc | [C4 model](https://c4model.com), [arc42](https://arc42.org) rút gọn; sơ đồ dạng code | `architecture.md` |
| Quyết định | ADR theo [MADR 4](https://adr.github.io/madr/): bối cảnh, phương án, quyết định, hệ quả; ngắn; đã chấp nhận thì bất biến | `adr/` |
| Cửa vào | [standard-readme](https://github.com/RichardLitt/standard-readme) | `README.md` |
| Tệp cộng đồng | [GitHub community health files](https://docs.github.com/en/communities); [Keep a Changelog](https://keepachangelog.com) và [SemVer](https://semver.org) cho thứ có version | `CONTRIBUTING.md`, `SECURITY.md`, hợp đồng REST |
| Hướng dẫn cho agent | [AGENTS.md](https://agents.md); `CLAUDE.md` chỉ import `AGENTS.md` | `AGENTS.md`, `CLAUDE.md` |
| Comment Go | [Go Doc Comments](https://go.dev/doc/comment), [Effective Go](https://go.dev/doc/effective_go), [Google Go Style Guide](https://google.github.io/styleguide/go); bố cục theo [go.dev/doc/modules/layout](https://go.dev/doc/modules/layout) | `services/`, `internal/`, `tools/` |
| Shell | [Google Shell Style Guide](https://google.github.io/styleguide/shellguide.html), [ShellCheck](https://www.shellcheck.net) | `deploy/**/*.sh` |
| Helm | [Helm chart best practices](https://helm.sh/docs/chart_best_practices/) | `deploy/helm/` |
| CI | [GitHub Actions security hardening](https://docs.github.com/en/actions/security-guides/security-hardening-for-github-actions), [OpenSSF Scorecard](https://scorecard.dev) làm thước đo | `.github/workflows/` |
| Văn phong | [Google developer documentation style guide](https://developers.google.com/style): câu ngắn, chủ động, thuật ngữ nhất quán | Mọi `.md` |
| Kiểm tài liệu tự động | [docs-as-code](https://www.writethedocs.org/guide/docs-as-code/) | Chưa chọn công cụ |
| Nhãn tiến độ | Lịch sử ở git log, CHANGELOG, ADR; code và tài liệu hiện trạng không mang nhãn "giai đoạn N", "phần M" | Mọi file ngoài ADR, postmortem |
