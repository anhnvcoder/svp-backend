# 0043. `POST /videos` nhận `Idempotency-Key`; khoá thành `request_id` lưu cùng transaction với video ở video-service

- Trạng thái: Chấp nhận
- Ngày: 2026-11-02
- Người quyết: AI đề xuất, người học uỷ quyền

## Bối cảnh và vấn đề

`POST /videos` (RPC `InitUpload`) mỗi lần gọi tạo một video `UPLOADING` và ký một form upload 15 phút. Client mất câu trả lời (mạng di
động đứt, 504 của gateway) không biết video đã được tạo chưa; gọi lại thì có video thứ hai, chiếm một trong 3 suất `TOO_MANY_UPLOADS` và
nằm lại tới khi bị dọn sang `FAILED` sau 1 giờ. Cũng vì vậy gateway không tự thử lại `InitUpload` (danh sách `retry` của
`services/gateway/cmd/gateway/main.go`). Đối chiếu chuẩn ngành ngày 2026-11-01 ghi lệch này: POST không idempotent, không `Idempotency-Key`.

Các POST khác của gateway không cần khoá:

| Route | Gọi lại thì |
| --- | --- |
| `POST /videos/{id}/complete` | Idempotent theo trạng thái: video đã `PROCESSING`, `READY` thì trả nguyên trạng, không phát event lần hai |
| `POST /videos/{id}/views` | Lượt thử lại được tính là một lượt có chủ ý (hợp đồng ghi rõ); mỗi người một video tối đa một lượt mỗi 60 s |
| `POST /auth/register` | Email duy nhất: lần hai nhận 409 `EMAIL_ALREADY_REGISTERED`, không tạo trùng |
| `POST /auth/refresh` | Xoay vòng có phát hiện dùng lại; lưu phản hồi để trả lại là lưu access và refresh token (credential) |
| `POST /auth/login`, `/auth/logout` | Login lặp chỉ để lại một họ refresh token không dùng, tự hết hạn; logout đã idempotent (luôn 204) |

## Yếu tố quyết định

- Không tạo video trùng kể cả khi service chết giữa chừng hay hai lần gọi tới cùng lúc.
- Không cất credential (form upload đã ký) vào chỗ lưu nào ngoài câu trả lời.
- Theo chuẩn đang hình thành cho HTTP và chuẩn của gRPC; hợp đồng REST đổi không phá client (minor).

## Phương án đã cân nhắc

Trạng thái ngành đọc ngày 2026-11-02 từ nguồn ở mục Nguồn.

Nơi lưu khoá:

| Phương án | Trạng thái | Nguồn | Ghi chú |
| --- | --- | --- | --- |
| A. Không khoá (như hiện nay) | cũ | [N1] §1 | Thử lại tạo video trùng |
| B. Middleware ở gateway lưu status và thân phản hồi theo khoá ở Redis db 10, hết hạn sau 24 giờ | hiện hành (cách của Stripe) | [N3] | Không cùng transaction với insert; thân phản hồi là form đã ký |
| C. Bảng `idempotency_keys` riêng ở video-service, lưu phản hồi, dọn theo hạn | hiện hành | [N4] | Cùng transaction được, nhưng vẫn lưu form đã ký và thêm job dọn |
| D. Field `request_id` của request gRPC, video-service ghi vào cột của `videos` cùng insert, unique theo tác giả | hiện hành | [N2] | Không lưu phản hồi: lượt lặp dựng lại câu trả lời từ dòng video |

Dạng khoá ở biên REST:

| Phương án | Trạng thái | Nguồn | Ghi chú |
| --- | --- | --- | --- |
| E. Header `Idempotency-Key`, giá trị là Structured Field String (có ngoặc kép) | mới nổi: bản nháp `draft-ietf-httpapi-idempotency-key-header-08`, Active Internet-Draft của nhóm httpapi, cập nhật 2026-10-22, hết hạn 2027-04-25 | [N1] | Đúng chuẩn đang hình thành |
| F. Header trần kiểu Stripe (chuỗi tới 255 ký tự, không ngoặc) | hiện hành | [N3] | Phổ biến, không có đặc tả chung |
| G. Field `request_id` trong thân JSON | hiện hành ở API theo AIP | [N2] | Lẫn khoá với dữ liệu nghiệp vụ |

## Kết quả quyết định

Chọn **D** cho lưu trữ và **E** cho biên REST.

1. **Phạm vi.** Chỉ `POST /videos` nhận header, và header là tuỳ chọn: không có header thì như hiện nay. Hợp đồng REST
   (`services/gateway/openapi.yaml`) tăng minor. Các POST ở bảng Bối cảnh không nhận header, vì lý do ở bảng đó.
2. **Giá trị.** Structured Field String chứa một UUID dạng chuẩn chữ thường (như `video_id`), ví dụ
   `Idempotency-Key: "00000000-0000-4000-8000-000000000001"` theo [N1] §2.1, §2.2. Sai dạng, rỗng hay header lặp → 400 `INVALID_IDEMPOTENCY_KEY`
   ở gateway. Không chấp nhận thêm dạng trần (F): client duy nhất là web của ta, một dạng thì một đường kiểm.
3. **Lưu trữ.** Gateway chuyển khoá thành field `request_id` của `InitUploadRequest` (AIP-155 [N2]). video-service có cột `videos.request_id uuid`
   null được, unique index một phần `(author_id, request_id) WHERE request_id IS NOT NULL`, ghi cùng insert của video. Khoá có phạm vi tác giả: hai
   người dùng trùng khoá không đụng nhau. Redis (B) bị loại vì hai lý do: ghi khoá và insert video ở hai hệ thống, crash giữa hai bước lại tạo
   trùng; và thân phản hồi là form upload đã ký, một credential, phải nằm trong cache 24 giờ. Bảng riêng (C) cũng phải lưu form đó.
4. **Ngữ nghĩa** (theo [N1] §2.6, §2.7):
   - Cùng khoá, cùng `title`, `size_bytes`, `content_type` (so sau chuẩn hoá như lúc tạo), video còn `UPLOADING`, cửa sổ của form đầu
     (`created_at` + 15 phút) còn ít nhất 1 phút → 201 với đúng `video_id` đó và form **ký mới** hết hạn cùng lúc với form đầu. Bản nháp
     chỉ đòi câu trả lời "nhất quán với việc request đã hoàn tất theo ý người dùng" (§2.6), không đòi trả lại đúng byte cũ. Form không
     được sống quá cửa sổ đó: giới hạn 3 upload mở đếm và luồng dọn chọn video theo `created_at`, nên form gia hạn sẽ cho một tài khoản
     giữ quá 3 form còn hạn và ghi vào upload của video đã bị dọn sang `FAILED` (UP-7 của threat model).
   - Cùng khoá, khác một trong ba trường → 422 `IDEMPOTENCY_KEY_MISMATCH` ([N1] §2.7). video-service trả `INVALID_ARGUMENT` với reason đó.
   - Không trả lời lại được lần đầu: video của khoá đã rời `UPLOADING` (`PROCESSING`, `READY`, hay `FAILED` sau khi bị dọn), hay cửa sổ
     form đã hết (còn dưới 1 phút: form ngắn hơn vô dụng cho file 500 MiB) → **409 `VIDEO_NOT_UPLOADING`**. Chọn 409 chứ
     không 422: thân request đúng, chỉ trạng thái của tài nguyên không cho trả lời như lần đầu (RFC 9110 §15.5.10 "conflict with the current
     state of the target resource"); 422 của bản nháp dành cho khoá dùng lại với thân khác. video-service trả `FAILED_PRECONDITION` với reason
     đó; client cần upload mới thì dùng khoá mới.
   - Hai request cùng khoá tới đồng thời: khoá theo tác giả sẵn có của `createVideo` xếp hai transaction nối đuôi, bên sau thấy dòng của bên
     trước; unique index là chốt cuối nếu thứ tự đó đổi: vi phạm unique thì đọc lại và trả như lượt lặp. Không có 409 "request đang chạy" của
     bản nháp: transaction của bên trước chỉ vài mili giây, chờ rẻ hơn bắt client thử lại.
   - Lượt lặp tìm khoá **trước** khi đếm giới hạn, nên không tính vào `TOO_MANY_UPLOADS`.
   - `request_id` sai dạng tới thẳng video-service → `INVALID_ARGUMENT` `INVALID_REQUEST_ID`.
5. **Thời hạn khoá** ([N1] §2.3 đòi công bố): khoá sống bằng đời của dòng video; dòng `videos` không bị xoá nên khoá không hết hạn theo thời
   gian. Mô tả của `initUpload` trong hợp đồng ghi điều này.
6. **Web client** gửi header khi đổi ghim hợp đồng: một khoá (`crypto.randomUUID()`) cho một lần tạo video, giữ qua mọi lần thử lại của lần
   đó, khoá mới cho video mới.

### Hệ quả

- Tốt: thử lại `POST /videos` an toàn; không bảng, job dọn hay cache mới; không credential nào nằm ngoài câu trả lời.
- Tốt: khoá và video nguyên tử trong một transaction Postgres; trùng đồng thời do database quyết.
- Xấu: schema `videos` thêm một cột và một index; mọi lượt lặp trong cửa sổ ký form mới (một phép ký cục bộ, không gọi mạng khi
  credential đã có).
- Xấu: lượt lặp sau cửa sổ 15 phút của form đầu không nhận form mà nhận 409: client tạo video mới bằng khoá mới, video cũ nằm `UPLOADING`
  chờ luồng dọn (1 giờ). Upload chậm hơn 15 phút phải bắt đầu lại từ đầu.
- Xấu: không theo hết bản nháp: không 409 cho request đang chạy, không dạng trần; bản nháp đổi ở revision sau thì xem lại.
- Xấu: 409 `VIDEO_NOT_UPLOADING` trùng mã mà [N1] §2.7 dành cho request trước còn đang chạy; client chỉ đọc mã HTTP theo bản nháp sẽ chờ
  rồi thử lại mãi. Vô hại khi client duy nhất là web của ta; client khác phân biệt bằng `code` của problem.
- Xem lại khi: bản nháp thành RFC hay đổi mã lỗi; một POST khác bắt đầu tạo tài nguyên không có khoá tự nhiên; cần cho gateway tự thử lại
  `InitUpload` khi request có `request_id`.

## Xác nhận

Test của video-service: cùng khoá cùng thân → một dòng, cùng `video_id`; khác thân → `IDEMPOTENCY_KEY_MISMATCH`; khoá của video đã
`PROCESSING` → `VIDEO_NOT_UPLOADING`; lượt lặp trong cửa sổ nhận form hết hạn không quá `created_at` + 15 phút, ngoài cửa sổ (hay còn
dưới 1 phút) → `VIDEO_NOT_UPLOADING`, không form; lượt lặp khi đã đủ 3 upload vẫn thành công; hai lượt đồng thời → một dòng. Test của gateway: header sai
dạng, hai header, chuyển `request_id`, ánh xạ 422 và 409. `make api-contract-check` (minor), `make generate-check`, `buf breaking`; `make smoke`
gọi `POST /videos` hai lần cùng khoá và kiểm cùng `video_id`. Chưa kiểm lúc chấp nhận: các việc trên làm cùng phần hiện thực.

## Ưu nhược từng phương án

- A: tốt là không thêm gì; xấu là video trùng và suất upload bị chiếm khi thử lại.
- B: tốt là chung cho mọi route; xấu là không nguyên tử với insert, cất credential, thêm phụ thuộc Redis cho một route ghi.
- C: tốt là nguyên tử; xấu là lưu credential, thêm bảng và job dọn cho một route.
- D: như Kết quả quyết định; xấu là chỉ dùng được ở route có dòng tài nguyên để gắn khoá.
- E: tốt là theo chuẩn đang hình thành; xấu là bản nháp còn đổi. F: phổ biến nhưng không đặc tả. G: trộn khoá vào dữ liệu nghiệp vụ.

## Hiện thực ở

- `proto/svp/video/v1/video_service.proto` (`InitUploadRequest.request_id`, comment ngữ nghĩa lặp của `InitUpload`), `gen/go/svp/video/`.
- `services/video-service/migrations/00006_add_request_id.sql` (cột, unique index một phần), `migrations/migrations_test.go`,
  `queries/videos.sql`, `internal/store/`.
- `services/video-service/internal/server/server.go` (`InitUpload`, `createVideo`), `request_id_test.go`.
- `services/gateway/internal/api/api.go` (đọc header, chuyển `request_id`), `api_test.go`; `services/gateway/internal/httpx/problem.go`
  (ánh xạ 422, 409), `problem_test.go`.
- `services/gateway/openapi.yaml` (tham số header, response 409, 422, thời hạn khoá, `info.version` minor).
- `deploy/compose/smoke.sh` (bước gọi lặp).
- Repo `svp-frontend`: client upload gửi header, giữ một khoá qua các lần thử lại.

## Nguồn

Truy cập 2026-11-02.

- [N1] [IETF draft-ietf-httpapi-idempotency-key-header-08](https://datatracker.ietf.org/doc/draft-ietf-httpapi-idempotency-key-header/)
  (Active Internet-Draft, cập nhật 2026-10-22): §2.1 giá trị là Structured Field String, §2.2 khuyên UUID, §2.3 công bố chính sách hết hạn,
  §2.6 lượt lặp, §2.7 400, 422, 409.
- [N2] [AIP-155: Request identification](https://google.aip.dev/155) (Approved): field `request_id`, UUID, trả lại kết quả của request trước.
- [N3] [Stripe API: Idempotent requests](https://docs.stripe.com/api/idempotent_requests): lưu status và thân phản hồi, khoá xoá được sau
  24 giờ, so tham số với request gốc.
- [N4] [Brandur Leach: Implementing Stripe-like Idempotency Keys in Postgres](https://brandur.org/idempotency-keys) (2017-10-27).
- [RFC 9110 §15.5.10 409 Conflict](https://www.rfc-editor.org/rfc/rfc9110#section-15.5.10).
