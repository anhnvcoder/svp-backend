# 0082. Sơ đồ chính của tài liệu svp-backend và svp-labs cũng viết bằng D2, theo cùng khuôn với svp-infra

- Trạng thái: Chấp nhận
- Ngày: 2026-11-22
- Người quyết: người học (2026-11-22: đồng ý áp khuôn tài liệu của `svp-infra` sang `svp-backend`, chọn lọc), AI đề xuất và so phương án

## Bối cảnh và vấn đề

[ADR-0079](0079-d2-diagrams.md) chọn D2 sinh SVG cho sơ đồ chính của `svp-infra` và giới hạn phạm vi ở repo đó. Tài liệu của
`svp-backend` (kiến trúc, triển khai, chuỗi cung ứng) vẫn vẽ sơ đồ lớn bằng Mermaid: khối 16 đến 95 dòng, GitHub tự xếp nên hình rộng
và rối, không có màu theo chức năng, không phân biệt gọi đồng bộ với event. `svp-labs` đã dùng D2 nhưng chỉ chép công thức
bằng tay. Người học đọc ba repo như một tài liệu nên ba kiểu sơ đồ khác nhau làm tốn công đọc.

## Yếu tố quyết định

- Sơ đồ chính của ba repo trông và đọc như nhau: cùng token, cùng cách nhúng cho theme sáng và tối.
- Sơ đồ đổi cùng PR với kiến trúc và bị kiểm lệch ở CI, như ở `svp-infra`.
- Không thêm công cụ thứ hai: cùng image D2 ghim digest, cùng công thức `Makefile`.
- Luồng nhỏ và sequence vẫn rẻ để viết và sửa.

## Phương án đã cân nhắc

- Giữ Mermaid ở `svp-backend`: không thêm công cụ, nhưng sơ đồ cấu trúc lớn khó đọc và không dùng chung token với `svp-infra`.
- Một repo chứa mọi sơ đồ cho cả ba repo: một nguồn, nhưng sơ đồ rời khỏi code nó tả nên không đổi cùng PR.
- D2 theo khuôn của ADR-0079 trong mỗi repo, mỗi repo giữ `.d2`, SVG và token của mình: chọn.

## Kết quả quyết định

Sơ đồ chính của `svp-backend` và `svp-labs` viết bằng D2 theo khuôn của ADR-0079: cùng image `d2lang/d2` ghim digest, engine ELK,
`tokens.d2` cùng class, hai SVG (sáng, `-dark`) nhúng bằng `<picture>`, `make diagrams-check` chạy trong CI. Mermaid giữ cho luồng
nhỏ và sequence. Sơ đồ hạ tầng AWS đầy đủ (account, mạng) ở `svp-infra`; sơ đồ ở `svp-backend` tả hệ thống: service, workload, luồng.
Mỗi repo chép khuôn, không dùng chung code, vì mỗi repo có CI và vòng phát hành riêng.

### Hệ quả

- Tốt: ba repo một kiểu sơ đồ; sơ đồ lệch nguồn thì CI đỏ; token `person`, `external`, `sync-call`, `event-flow`, `cloud-event` của
  `svp-backend` tách rõ người, hệ thống ngoài, gọi đồng bộ, event qua Kafka và event của dịch vụ AWS (EventBridge, SQS).
- Xấu: ba bản của công thức `Makefile` và `tokens.d2` có thể trôi lệch nhau; SVG sinh ra vào diff của PR; job `docs` kéo thêm image D2.
- Xem lại khi: ba bản công thức lệch nhau đến mức đổi digest phải sửa ba nơi theo ba cách; khi đó tách công thức thành một kho dùng chung.

## Xác nhận

`make diagrams-check` ở `svp-backend` thoát 0 khi chưa có sơ đồ và khi SVG khớp nguồn; thoát khác 0, nêu tên file, khi một SVG bị sửa hay
mất `.d2`; sinh hai lần ra cùng byte. Job `docs` của `ci.yml` chạy nó.

## Hiện thực ở

- `Makefile` (`D2_IMAGE`, `diagrams`, `diagrams-check`), `.github/workflows/ci.yml` (job `docs`), `.markdownlint.yaml` (MD033 cho
  `picture`, `source`, `img`), `docs/diagrams/` (`tokens.d2`, `README.md`, `icons/`, các cặp `.d2` và `.svg`),
  `AGENTS.md` (luật cập nhật sơ đồ).
- `svp-labs`: `Makefile` (`diagrams`, `diagrams-check`), `docs/diagrams/`.

## Nguồn

- D2: <https://d2lang.com>
- Image chính thức: <https://hub.docker.com/r/d2lang/d2>

## Thông tin thêm

Chỉnh: [0079](0079-d2-diagrams.md) mục "Kết quả quyết định": mở khuôn D2 cho `svp-backend` và `svp-labs`, không đổi quyết định
chọn D2.
