# 0079. Sơ đồ chính của tài liệu svp-infra viết bằng D2 và sinh thành SVG; draw.io giữ cho sơ đồ icon AWS, Mermaid cho luồng nhỏ

- Trạng thái: Chấp nhận
- Ngày: 2026-11-20
- Người quyết: người học (2026-11-20: chọn D2 → SVG cho sơ đồ chính của handbook `svp-infra`, rồi ELK sau khi xem bản ELK và TALA
  của cùng hai sơ đồ), AI đề xuất và so phương án

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
token (màu theo chức năng, account, region, trust, data flow, control flow) ở `docs/diagrams/tokens.d2`. `make diagrams-check` chạy
trong CI và đỏ khi SVG lệch nguồn. draw.io giữ cho sơ đồ tổng có icon AWS, Mermaid cho luồng nhỏ và sequence.

Engine layout của mọi sơ đồ là ELK (`layout-engine: elk` trong `d2-config` của từng file): phân tầng trên xuống hợp luồng một chiều
của tài liệu, hình hẹp hơn nên đọc được trên điện thoại, và ELK là mã nguồn mở do Eclipse duy trì lâu dài. TALA, engine của
Terrastruct, không chọn: rủi ro nhà cung cấp, và ở bản so nó cho hình rộng hơn. Engine khác chỉ dùng khi có lý do, ghi ở comment
đầu file `.d2`; không giữ hai bản của một sơ đồ.

### Hệ quả

- Tốt: sơ đồ đổi cùng PR với kiến trúc và bị kiểm lệch; mọi sơ đồ chung một bộ màu; đổi công cụ chỉ cần vẽ lại từ nguồn text.
- Xấu: thêm một công cụ vào repo; D2 là sản phẩm của một công ty (Terrastruct); ELK có thể đặt nhãn mũi tên lên viền khung, nên
  sơ đồ ghi chi tiết ở nhãn nút và tách sơ đồ tổng quan khỏi sơ đồ chi tiết.
- Rủi ro: Terrastruct dừng kinh doanh. Giảm nhẹ: nguồn là text, SVG đã sinh là file tĩnh, image ghim digest vẫn chạy; ELK là mã
  nguồn mở nên không phụ thuộc TALA; đổi công cụ không mất nội dung.
- Xem lại khi: image `d2lang/d2` ngừng phát hành bản vá, hay `diagrams-check` lệch giữa arm64 và amd64.

## Xác nhận

`make diagrams-check` xanh với SVG đã commit, đỏ khi một SVG bị sửa tay; chạy hai lần ra cùng byte, trên arm64 lẫn amd64 (kiểm
bằng hai bản image theo kiến trúc); mọi `.d2` có `layout-engine: elk`.

## Hiện thực ở

- `svp-infra`: `Makefile` (`D2_IMAGE`, `diagrams`, `diagrams-check`, target `check`), `.github/workflows/check.yml` (job `docs`),
  `docs/diagrams/` (`tokens.d2`, `README.md`, các cặp `.d2` và `.svg`), `AGENTS.md` (luật cập nhật sơ đồ).
- `svp-backend`: `Makefile`, `.github/workflows/ci.yml` (job `docs`), `docs/diagrams/` (cùng khuôn, [0082](0082-d2-diagrams-all-repos.md)).

## Nguồn

- D2: <https://d2lang.com>
- Image chính thức: <https://hub.docker.com/r/d2lang/d2>

## Thông tin thêm

### Chỉnh bởi

- Kết quả quyết định: [0082](0082-d2-diagrams-all-repos.md): khuôn D2 áp thêm cho `svp-backend` và `svp-labs`, không đổi quyết định chọn D2.
