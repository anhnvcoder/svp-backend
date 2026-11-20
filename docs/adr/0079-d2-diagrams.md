# 0079. Sơ đồ chính của tài liệu svp-infra viết bằng D2 và sinh thành SVG; draw.io giữ cho sơ đồ icon AWS, Mermaid cho luồng nhỏ

- Trạng thái: Chấp nhận
- Ngày: 2026-11-20
- Người quyết: người học (2026-11-20: chọn D2 → SVG cho sơ đồ chính của handbook `svp-infra`), AI đề xuất và so phương án

## Bối cảnh và vấn đề

Tài liệu học SAP của `svp-infra` cần sơ đồ cho luồng áp, bảo mật nhiều lớp, ranh giới account và câu hỏi chính của từng chương.
Repo public; GitHub hiện SVG qua `<img>` (không chạy script) và vẽ Mermaid. Sơ đồ phải đẹp, đọc được ở cả theme sáng và tối,
và đổi theo code: một sơ đồ lệch Terraform còn hại hơn không có sơ đồ.

## Yếu tố quyết định

- Sơ đồ đổi cùng PR với kiến trúc, diff đọc được, có phép kiểm tự động khi lệch.
- Thể hiện được account, ranh giới tin cậy, luồng dữ liệu khác luồng điều khiển, với màu theo chức năng dùng chung.
- Hiển thị đủ tiếng Việt có dấu, cả hai theme, không phụ thuộc dịch vụ ngoài lúc đọc.
- Đổi công cụ về sau không làm mất nội dung.

## Phương án đã cân nhắc

- SVG vẽ tay: đẹp nhưng lệch code, diff là toạ độ không đọc được, không kiểm tự động được.
- Chỉ Mermaid: có sẵn trên GitHub, diff đọc được, nhưng khó vẽ account lồng ranh giới tin cậy và ít quyền kiểm soát hình, nên chỉ
  hợp luồng nhỏ và sequence.
- draw.io: tốt cho icon AWS và sửa tay, nhưng nguồn là XML sinh ra, không có token dùng chung, không kiểm lệch được.
- D2 sinh SVG: nguồn là text, diff đọc được, `classes` làm token dùng chung, một SVG chứa cả theme sáng và tối, sinh trong container
  ghim digest nên cùng nguồn ra cùng byte.

## Kết quả quyết định

Sơ đồ chính viết bằng D2 ở `docs/diagrams/<tên>.d2` của `svp-infra`, sinh `<tên>.svg` bằng `make diagrams`, không sửa SVG bằng tay;
token (màu theo chức năng, account, trust, data flow, control flow) ở `docs/diagrams/tokens.d2`. `make diagrams-check` chạy trong
CI và đỏ khi SVG lệch nguồn. Engine layout (ELK hay TALA) và theme do `d2-config` của từng file quyết, chọn sau khi so hai bản của
cùng một sơ đồ. draw.io giữ cho sơ đồ tổng có icon AWS, Mermaid cho luồng nhỏ và sequence.

### Hệ quả

- Tốt: sơ đồ đổi cùng PR với kiến trúc và bị kiểm lệch; mọi sơ đồ chung một bộ màu; đổi công cụ chỉ cần vẽ lại từ nguồn text.
- Xấu: thêm một công cụ vào repo; D2 là sản phẩm của một công ty (Terrastruct), engine TALA chỉ chạy tốt khi image còn được phát hành.
- Rủi ro: Terrastruct dừng kinh doanh. Giảm nhẹ: nguồn là text, SVG đã sinh là file tĩnh, image ghim digest vẫn chạy; ELK là mã
  nguồn mở nên không phụ thuộc TALA; đổi công cụ không mất nội dung.
- Xem lại khi: image `d2lang/d2` ngừng phát hành bản vá, hay `diagrams-check` lệch giữa arm64 và amd64.

## Xác nhận

`make diagrams-check` xanh với SVG đã commit, đỏ khi một SVG bị sửa tay; chạy hai lần ra cùng byte, trên arm64 lẫn amd64 (kiểm
bằng hai bản image theo kiến trúc, ELK và TALA).

## Hiện thực ở

- `svp-infra`: `Makefile` (`D2_IMAGE`, `diagrams`, `diagrams-check`, nhóm `check-lint`), `.github/workflows/check.yml` (job `docs`),
  `docs/diagrams/` (`tokens.d2`, `README.md`, các cặp `.d2` và `.svg`), `AGENTS.md` (luật cập nhật sơ đồ).

## Nguồn

- D2: <https://d2lang.com>
- Image chính thức: <https://hub.docker.com/r/d2lang/d2>
