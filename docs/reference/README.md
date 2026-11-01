# Tra cứu

Loại tài liệu (Diátaxis): **reference**. Mô tả chính xác từng lệnh, biến, workflow và quy ước test để tra khi cần; không giải thích
vì sao (vì sao: ADR ở [`../adr/`](../adr/)) và không hướng dẫn từng bước (how-to: [`../runbooks/`](../runbooks/)). Luật làm việc ngắn ở
[`AGENTS.md`](../../AGENTS.md).

| File | Nội dung |
| --- | --- |
| [`make.md`](make.md) | Lệnh của code: proto, Go, vulncheck, fuzz, hợp đồng REST, target cần mã web, git hook |
| [`environment.md`](environment.md) | `make env`, quy tắc đọc `.env`, biến và hành vi khởi động của service |
| [`compose.md`](compose.md) | Stack compose (`make up`, `OBS`, `IMAGES`, `WEB_FROM`), diễn tập, tải k6, DAST, game day |
| [`k8s.md`](k8s.md) | Cluster k3d, Kyverno và nguồn phát hành, thư mục cấu hình và thư mục web, đường GitOps, diễn tập trên cluster, `cloud-check` |
| [`eks.md`](eks.md) | Target `eks-*`, biến S3 của service trên EKS, lớp nền tảng của `svp-gitops` |
| [`ci.md`](ci.md) | Workflow GitHub Actions, check của `svp-gitops`, ruleset, CodeQL, chạy lại job trên máy, file ignore, Renovate |
| [`testing.md`](testing.md) | Quy ước test |
