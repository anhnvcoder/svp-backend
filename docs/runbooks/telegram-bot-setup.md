# Tạo bot Telegram nhận cảnh báo `severity=page`

- Quy trình do người học chạy, không có cảnh báo. Mở khi muốn Alertmanager gửi cảnh báo `severity=page` tới Telegram thay vì chỉ liệt
  kê ở giao diện của nó, hay khi đổi bot hoặc chat nhận.
- Bot là tuỳ chọn: thiếu một trong hai biến thì Alertmanager không gửi gì và vẫn chạy bình thường.
- **Không dán token vào lệnh, issue, PR hay chat.** Token lộ là ai cũng điều khiển được bot; token và chat ID không có trong repo nào.

## Ý nghĩa và tác động tới người dùng

Alertmanager (profile `obs` của compose, namespace `svp-obs` của k3d và EKS) gửi cảnh báo `severity=page` tới `api.telegram.org` khi có
cả `SVP_ALERT_TELEGRAM_BOT_TOKEN` lẫn `SVP_ALERT_TELEGRAM_CHAT_ID` trong `.env`; cảnh báo `severity=ticket` luôn chỉ nằm ở giao diện. Người
dùng sản phẩm không thấy gì. Không có bot thì cảnh báo page vẫn cháy, chỉ không ai được báo ngoài giao diện Alertmanager.

Đường đi của hai biến: `.env` → compose (token là compose secret, chat ID là biến môi trường của container `alertmanager`) hay
`deploy/k8s/secrets.sh` (k3d) hay `make eks-secrets` (EKS, entry `obs` của Secrets Manager) → file cấu hình Alertmanager. Chat ID phải là số
nguyên, khác thì Alertmanager không bật receiver Telegram và ghi lý do vào log.

## Kiểm tra nhanh (5 phút)

Compose, sau `make up OBS=lgtm`:

```sh
make logs SVC=alertmanager | grep alertmanager-entrypoint
```

Mong `Telegram receiver on for severity=page`. `Telegram receiver off (… empty)` là một trong hai biến rỗng;
`is not an integer` là chat ID sai
dạng. k3d: `make k8s-secrets` in dòng `Alertmanager: severity=page goes to Telegram` hay `Telegram receiver off`.

## Nguyên nhân thường gặp

1. Chưa tạo bot hay chưa điền `.env`: receiver tắt, không lỗi nào khác.
2. Chat ID là username hay tên chat thay vì số (`-?[0-9]+`; chat nhóm có số âm).
3. Chưa nhắn gì cho bot: `getUpdates` rỗng nên không lấy được chat ID (bước 2).
4. Bot có webhook: `getUpdates` không chạy khi webhook đặt (lỗi `409 Conflict`), bot này đang dùng cho việc khác; tạo bot riêng cho lab.
5. Đổi `.env` nhưng chưa nạp lại: compose `make up OBS=lgtm` lại, k3d `make k8s-secrets`, EKS `make eks-secrets`.

## Khôi phục và xác nhận

Các bước 2 và 3 đọc token từ bàn phím, không qua lệnh: `read -s` không echo, và token chỉ ở biến của shell hiện tại.

### 1. Tạo bot (giữ tay)

Việc duy nhất làm trong ứng dụng Telegram, vì BotFather là bot của Telegram và không có API tạo bot:

1. Mở chat với `@BotFather` (kiểm dấu tích xanh xác thực), gửi `/newbot`.
2. Nhập tên hiển thị, rồi username (5–32 ký tự chữ Latin, số, `_`, phải kết thúc bằng `bot`, không đổi được sau này).
3. BotFather trả **token** (dạng `<số>:<chuỗi>`). Giữ cửa sổ chat, chưa dán đâu cả. Mất hay lộ token: `/token` hay `/revoke` ở cùng chat
   rồi làm lại từ bước 3 của mục "Khôi phục và xác nhận" (điền `.env`).
4. Mở chat với bot vừa tạo, bấm **Start** và gửi một tin bất kỳ (bot chỉ nhận update từ người nhắn nó). Muốn nhận ở nhóm: thêm bot vào nhóm
   rồi nhắn một tin trong nhóm.

Nguồn: [Telegram Bot features, BotFather](https://core.telegram.org/bots/features#botfather), đọc ngày 2026-11-15.

### 2. Lấy chat ID

`getUpdates` của Bot API trả các update bot chưa nhận (giữ tối đa 24 giờ), mỗi update có `message.chat.id`. Token đi
qua stdin của `curl -K -`, không
vào dòng lệnh hay lịch sử:

```sh
printf 'Bot token: '; read -rs TG_TOKEN; echo
printf 'url = "https://api.telegram.org/bot%s/getUpdates"\n' "$TG_TOKEN" | curl -sS -K - \
  | jq '[.result[].message.chat | {id, type}] | unique'
```

Mong một mảng có dòng `{"id": 123456789, "type": "private"}` (chat riêng: số dương; nhóm: số âm). `"result": []` là
chưa nhắn bot (bước 1.4) hay
tin đã quá 24 giờ; `409` là bot đang có webhook (nguyên nhân 4); `401` là sai token. Giữ `TG_TOKEN` trong terminal cho bước 3.

Nguồn: [Telegram Bot API, getUpdates](https://core.telegram.org/bots/api#getupdates), đọc ngày 2026-11-15.

### 3. Điền `.env`

Chạy ở gốc repo, trong cùng terminal, với `TG_CHAT` là số vừa đọc. Lệnh thay hai dòng cũ (nếu có) bằng hai dòng mới, qua file tạm mode 600:

```sh
printf 'Chat ID: '; read -r TG_CHAT
( umask 077
  { grep -v '^SVP_ALERT_TELEGRAM_' .env
    printf 'SVP_ALERT_TELEGRAM_BOT_TOKEN=%s\nSVP_ALERT_TELEGRAM_CHAT_ID=%s\n' "$TG_TOKEN" "$TG_CHAT"
  } > .env.tmp && mv .env.tmp .env )
unset TG_TOKEN TG_CHAT
```

`.env` không được in ra màn hình ở bước nào. Mở `.env` bằng trình soạn rồi dán tay cũng được, miễn không dán token vào dòng lệnh.

### 4. Kiểm

Nạp lại như nguyên nhân 5, rồi đọc lại "Kiểm tra nhanh": dòng `Telegram receiver on for severity=page`. Không có lệnh
gửi tin thử: tin đầu tiên tới
khi có cảnh báo page thật cháy (log của Alertmanager ghi lỗi gọi Telegram nếu có).

## Leo thang

- Receiver `on` mà không có tin nào khi cảnh báo page cháy: xem log `alertmanager` tìm lỗi gọi `api.telegram.org` (`401` là token sai hay đã
  `/revoke`; lỗi nói không tìm thấy chat là chat ID sai, bot chưa từng được nhắn hay bị đuổi khỏi nhóm). Trên cluster,
  egress tới `api.telegram.org:443` do
  NetworkPolicy của chart `svp-observability` cho phép riêng cho Alertmanager.
- Nghi lộ token: `/revoke` ở BotFather ngay, rồi làm lại bước 2–4 với token mới.

## Liên kết

- [`compose.md`](../reference/compose.md) (`.env`, Alertmanager), [`environment.md`](../reference/environment.md).
- `deploy/observability/alertmanager/entrypoint.sh` (ghép cấu hình), `deploy/k8s/secrets.sh` (k3d).
