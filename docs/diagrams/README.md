# Sơ đồ

> **Tóm tắt**
>
> - **Trả lời:** sơ đồ chính của `svp-backend` dựng, sinh và kiểm ra sao: lệnh, bố cục, cách nhúng, token màu, icon, luật cập nhật.
> - **Vì sao:** một khuôn D2 → SVG cho cả ba repo, nguồn là text nên sơ đồ đổi cùng PR và CI đỏ khi SVG lệch nguồn
>   ([ADR-0082](../adr/0082-d2-diagrams-all-repos.md), [ADR-0079](../adr/0079-d2-diagrams.md)).
> - **Đọc tiếp:** [`architecture.md`](../architecture.md), trang dùng các sơ đồ chính.

Sơ đồ ở đây là của hệ thống: service, workload, luồng. Sơ đồ hạ tầng AWS đầy đủ (account, mạng, từng root Terraform) nằm ở `svp-infra`:
[`docs/diagrams/README.md` của `svp-infra`](https://github.com/anhnvcoder/svp-infra/blob/main/docs/diagrams/README.md); trang ở đây
chỉ vẽ phần của hệ thống và link sang đó. Mermaid giữ cho luồng nhỏ và sequence.

## Lệnh

Chạy từ gốc repo; D2 chạy trong container ghim digest (`D2_IMAGE` của `Makefile`), không mạng.

| Lệnh | Việc |
| --- | --- |
| `make diagrams` | Sinh mọi `docs/diagrams/*.d2` (trừ `tokens.d2`) thành hai SVG: `<tên>.svg` (theme sáng) và `<tên>-dark.svg` (theme tối) |
| `make diagrams-check` | Sinh vào thư mục tạm, so với cả hai SVG đã commit; lệch, thiếu, hay SVG không còn `.d2` cùng tên thì exit khác 0 kèm tên file |
| `make diagrams NAMES='<tên …>'` | Chỉ các sơ đồ đó (cả hai target nhận `NAMES`) |
| `make diagrams PNG=1` | Sinh thêm `<tên>.png` và `<tên>-dark.png` bên cạnh để xem; không commit (`.gitignore`) |
| `make diagrams LAYOUT=<engine> OUT=<thư mục> SUFFIX=<chữ>` | Bản thử: engine khác `layout-engine` của file, thư mục khác trong repo, hậu tố tên; không commit |

`diagrams-check` chạy một lần mỗi lượt CI, ở job `docs` của `ci.yml` (job chạy mọi PR, kể cả PR chỉ đổi `.d2`, `.svg`). CI chỉ kiểm
SVG khớp `.d2`; `.d2` khớp code do người viết và review kiểm. Cùng nguồn, cùng digest của image thì ra cùng byte, arm64 lẫn amd64.
Đổi digest `D2_IMAGE` có thể đổi byte của SVG: PR đổi nó chạy `make diagrams` trên nhánh của PR và commit SVG mới cùng PR.

## Một file `.d2`

Mỗi sơ đồ mở bằng `vars` đặt engine và lề, rồi nạp token. Theme không nằm trong file: `make diagrams` truyền theme 0 cho bản sáng và
theme 200 cho bản tối. Engine ở gốc là ELK; khối nào có `grid-rows`, `grid-columns` thì D2 xếp theo lưới (mục [Bố cục](#bố-cục)).
Engine khác chỉ khi có lý do, ghi ở comment đầu file `.d2`.

```d2
vars: {d2-config: {layout-engine: elk; pad: 20}}
...@tokens
```

## Bố cục

Đích: đọc trọn trong một màn hình laptop, chữ cỡ thường. Cỡ thật của hình (viewBox, đọc bằng
`grep -o 'viewBox="[^"]*"' docs/diagrams/<tên>.svg`) rộng khoảng 1000–1500 px; tỉ lệ cao/rộng không quá 1,3, thường 0,5–1. Hình dựng
dọc một chuỗi dài bị GitHub kéo cho rộng bằng cột chữ rồi dài hơn một màn hình, nên không dùng `direction: down` cho chuỗi dài.

- **Lưới thay cho chuỗi dọc.** Bọc các khối cấp gốc vào một container trong suốt `all` (`style: {stroke: transparent; fill: transparent}`)
  có `grid-rows`, `grid-columns`; chuỗi dài xếp thành hàng rắn (hàng trên trái sang phải, hàng dưới phải sang trái). Tiêu đề `title`
  đứng ngoài `all`.
- **Luôn đặt cả `grid-rows` lẫn `grid-columns`.** Chỉ có `grid-columns` thì D2 điền theo cột; đặt cả hai thì điền theo hàng, đúng thứ tự
  khai báo.
- **Mũi tên trong lưới là đoạn thẳng giữa hai ô.** Đặt hai nút nối nhau ở hai ô kề nhau; mũi tên không đi xuyên nút khác. Nhãn mũi tên nằm
  giữa đoạn: chừa khoảng cách ô (`horizontal-gap` 75–110) cho nhãn, ngắt nhãn dài bằng `\n`.
- **Ô cùng hàng cùng cao, ô cùng cột cùng rộng.** Khối cao kéo giãn các ô cùng hàng; gom nhóm nhỏ vào container trong suốt (`grid-rows`
  riêng) để cột bên cạnh chia đều chiều cao.
- **`grid-gap` cũng là lề trong của container.** Container trong suốt đặt `grid-gap: 0` và chừa khoảng cách bằng nút trống có `width`
  hay `height` (`style: {stroke: transparent; fill: transparent}`), nếu không hình có khoảng trống lớn quanh viền.
- **Nhãn mũi tên không nằm trên viền khung.** Khoảng cách trước khung phải lớn hơn lề trong của khung cộng nửa nhãn; mũi tên đi qua góc có
  nhãn khung thì dời nhãn khung (`label.near: top-right` hay `bottom-left`).
- **Ngắt dòng `sub`, `root` quanh 28 ký tự** bằng `\n` để khối hẹp, hình không rộng quá; chữ giữ nguyên.
- Tên `top`, `layers` là từ khoá của D2: không dùng làm tên nút hay container.

## Nhúng vào trang

Mỗi sơ đồ có hai SVG, mỗi file một theme, và trang nhúng cả hai bằng một thẻ `<picture>`; đường dẫn tương đối tính từ trang nhúng:

```html
<picture>
  <source media="(prefers-color-scheme: dark)" srcset="diagrams/<tên>-dark.svg">
  <img src="diagrams/<tên>.svg" alt="<câu hỏi của sơ đồ>">
</picture>
```

Đặt một dòng trống trước và sau khối để khối HTML không nuốt đoạn văn bên cạnh.

- **Vì sao không một SVG chứa cả hai theme.** SVG trong thẻ `<img>` chọn theme theo `prefers-color-scheme` của hệ điều hành, không theo
  theme người dùng chọn trong GitHub: máy sáng mà GitHub tối thì hình vẫn sáng, nền trắng trên trang tối.
- **Vì sao `<picture>`, không hậu tố riêng của GitHub trên URL ảnh** (kiểu `#gh-…-mode-only`). Loại hậu tố này chỉ GitHub hiểu;
  `<picture>` là HTML: GitHub chọn nguồn theo theme của nó, editor theo theme của editor hay hệ điều hành. `.markdownlint.yaml` bật
  `no-inline-html` (MD033) và chỉ cho ba thẻ `picture`, `source`, `img` (`allowed_elements`).
- **Cỡ.** `make diagrams` truyền `--scale 1` nên SVG mang `width`, `height` của cỡ thật, không `width` trên thẻ ảnh. GitHub chỉ thu hình
  rộng hơn cột chữ, không phóng hình nhỏ hơn.
- Hai file cùng tên gốc, hậu tố `-dark`; `diagrams-check` kiểm cả hai và coi `<tên>-dark.svg` không còn `<tên>.d2` là mồ côi.

## Token

`tokens.d2` giữ các `class` dùng chung; nút gắn bằng `class: <tên>`, mũi tên gắn bằng `{class: <tên>}`. Một khối là container bo góc nền
nhạt, viền màu theo chức năng, nhãn đậm là tiêu đề; `grid-rows` xếp các dòng con dưới tiêu đề: dòng `sub` liệt kê dịch vụ bằng ` · `,
dòng `root` ghi thông tin phụ cỡ chữ đơn cách. Nền nhạt đi với chữ tối nên đọc được ở cả hai theme; font mặc định của D2 hiển thị đủ dấu
tiếng Việt. Bộ class giữ cùng tên, cùng nghĩa với `svp-infra`, thêm năm class của hệ thống.

| Class | Dùng cho |
| --- | --- |
| `governance`, `prevention`, `detection`, `alerting`, `investigation`, `recovery` | sáu lớp bảo mật: quản trị, phòng ngừa, phát hiện, cảnh báo, điều tra, phục hồi |
| `workload`, `data` | dịch vụ chạy tải, nơi giữ dữ liệu |
| `sub`, `root` | dòng phụ dưới tiêu đề: dịch vụ (chữ thường), thông tin phụ (chữ đơn cách) |
| `account` | container một account AWS: bo góc, nét liền |
| `region` | vị trí (region): nét đứt mảnh; không phải ranh giới tin cậy |
| `trust` | ranh giới tin cậy thật (tổ chức, mạng ngoài): nét đứt dày |
| `group` | nhóm theo vòng đời hay mục đích: nét chấm mảnh; không phải account hay ranh giới |
| `data-flow`, `control-flow` | mũi tên mảnh: dữ liệu (nét liền), điều khiển như chính sách, API, trigger (nét đứt) |
| `person` | người dùng, người vận hành |
| `external` | hệ thống ngoài nền tảng: GitHub, Sigstore, Telegram, registry upstream (nét đứt mảnh) |
| `sync-call` | mũi tên nét liền: gọi đồng bộ (REST, gRPC) |
| `event-flow` | mũi tên nét đứt cam: event qua Kafka |
| `cloud-event` | mũi tên nét đứt tím: event của dịch vụ AWS (EventBridge, SQS) |

## Icon

Sơ đồ có khối là một dịch vụ AWS dùng icon dịch vụ đó. Icon là SVG cỡ 48 của
[AWS Architecture Icons](https://aws.amazon.com/architecture/icons/), bản `07312026` (gói `Icon-package_07312026`, thư mục
`Architecture-Service-Icons_07312026/<nhóm>/48/Arch_<dịch vụ>_48.svg`), chép vào `docs/diagrams/icons/` với tên ngắn kebab-case
(`kms.svg`, `ecr.svg`), cùng bản với `svp-infra`. AWS cho dùng bộ này để vẽ sơ đồ kiến trúc; không sửa hình, không đổi màu.

- **Trong repo, không URL.** D2 chạy trong container `--network none` nên không tải icon từ mạng; đường dẫn tương đối tính từ file
  `.d2` (`icon: ./icons/kms.svg`) và D2 nhúng hình vào SVG (base64), nên máy và CI ra cùng byte.
- **Chỉ icon dùng tới.** Thêm dịch vụ mới thì chép đúng một file từ gói cùng bản; nâng bản gói thì thay mọi file trong `icons/` cùng
  lúc, sửa bản ở đoạn trên, chạy lại `make diagrams`. `diagrams-check` chỉ quét SVG ở `docs/diagrams/`, không quét `icons/`.
- **Cỡ.** Nút icon là `shape: image`, `width: 48; height: 48`, nhãn nằm dưới hình; nhãn nằm trên nền nhạt của khối nên đặt `font-color`
  tối ở cả hai theme (theme tối của D2 tô chữ sáng, không đọc được trên nền nhạt).

## Luật

- PR đổi kiến trúc mà một sơ đồ `.d2` tả (service, workload, luồng) thì sửa `.d2` đó và chạy `make diagrams` trong cùng PR; không sửa
  SVG bằng tay (`diagrams-check` đỏ, lần sinh sau ghi đè).
- Mỗi sơ đồ trả lời một câu hỏi, tối đa khoảng 15 nút, mọi nút đối chiếu được với code hay chart; luồng phức tạp có một sơ đồ tổng quan
  (khoảng 8 nút) và một sơ đồ chi tiết (`<tên>-detail`). Khối chạy song song đặt cạnh nhau, không ép thành chuỗi.
- Trước khi giao, `make diagrams PNG=1` rồi xem `<tên>.png` (sáng) và `<tên>-dark.png` (tối): chữ không tràn, mũi tên không xuyên nút hay
  cắt nhãn khung, tỉ lệ cao/rộng không quá 1,3. Xoá PNG sau khi xem.
