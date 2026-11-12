# 0051. Zone gốc `aws.<miền>` của lab nằm ở account `svp-prd`, zone `stg.aws.<miền>` của stg là zone con do zone prd uỷ quyền; management không còn hosted zone

- Trạng thái: Chấp nhận
- Ngày: 2026-11-06
- Người quyết: người học (2026-11-06: prd dùng tên gốc, môi trường thấp hơn là subdomain của nó)

## Bối cảnh và vấn đề

- [0048](0048-prd-aws.md) §1 đặt zone lab `aws.<miền>` ở management (root `aws/bootstrap` của `svp-infra`, DNS của `<miền>` uỷ quyền tới nó bằng
  bốn bản ghi `NS` `aws`); §2 cho mỗi account thành viên một zone baseline `<env>.aws.<miền>`, zone lab uỷ quyền xuống bằng `NS`. prd vì vậy chạy ở
  `prd.aws.<miền>`, không ở tên gốc của lab.
- Zone lab là tài nguyên mà workload dùng (ExternalDNS, cert-manager ghi vào zone con của nó), nằm ở account mà AWS khuyên chỉ dùng cho việc
  bắt buộc phải làm ở đó [N1]; mỗi lần NS của một zone con đổi thì phải apply ở management.
- Ràng buộc như 0048: repo public (không tên miền, account, name server thật), AI không chạy lệnh chạm account, mọi uỷ quyền phải tránh lúc
  bản ghi `NS` trỏ tới zone đã xoá (threat model AWS-7).

## Yếu tố quyết định

- prd ở tên gốc `aws.<miền>`, stg là subdomain của tên đó.
- Management chỉ giữ việc phải làm ở management [N1]; không thêm account chỉ để giữ một zone.
- Mọi uỷ quyền bên trong AWS là Terraform; ngoài AWS chỉ còn một chỗ sửa tay (bản ghi `NS` `aws` ở DNS của `<miền>`).
- Không lúc nào có uỷ quyền treo, cả khi chuyển lần đầu lẫn khi gỡ.

## Phương án đã cân nhắc

In đậm là lựa chọn.

- Giữ zone lab ở management (0048 §1, §2): đã chạy; prd không ở tên gốc, management giữ tài nguyên workload dùng, đổi NS của zone con là apply ở management.
- **Zone gốc ở prd, stg là zone con của prd:** prd ở tên gốc, management hết zone; đổi NS của zone stg cần apply ở account prd, gỡ prd phải theo thứ tự.
- Zone gốc ở một account dùng chung riêng (account Network của OU Infrastructure là hub mạng của org [N2]): tách quyền rõ nhất, nhưng thêm account
  thứ tư (email, baseline, budget, profile) chỉ để giữ một zone; tài liệu đó chỉ nêu Route 53 Resolver, không nói riêng hosted zone công khai.
- DNS của `<miền>` uỷ quyền thẳng từng env (`stg.aws`, `prd.aws` là hai `NS` ở DNS cha, không zone `aws`): mỗi env độc lập, nhưng mọi uỷ quyền là
  sửa tay ngoài Terraform, và prd vẫn không ở tên gốc: khi `aws` đã uỷ quyền đi thì bản ghi `stg.aws` ở DNS cha không còn được hỏi tới.

## Kết quả quyết định

Chọn zone gốc ở prd: đạt tên gốc cho prd và management không còn zone mà không thêm account; uỷ quyền stg là một bản ghi Terraform trong zone
prd. Cái giá: đổi NS của zone stg cần apply ở account prd; gỡ prd phải gỡ stg trước; zone `prd.aws.<miền>` đã dựng bị thay một lần; lần chuyển
phải chờ TTL của `NS` trước khi xoá zone cũ.

### 1. Zone mỗi account

- Module `account-baseline` tạo zone đúng tên biến `zone_name` (DNS chữ thường, không dấu chấm cuối); không nhánh theo env. Giá trị nằm trong
  tfvars không commit của root `aws/accounts/<env>`: prd `aws.<miền>`, stg `stg.aws.<miền>`. Output `zone_id`, `name_servers` giữ tên.
- Management không còn hosted zone: `aws/bootstrap` chỉ giữ bucket state, budget và phần dùng chung khác của 0048 §1.

### 2. Uỷ quyền hai tầng

- Tầng 1, ngoài Terraform: bốn bản ghi `NS` `aws` ở DNS của `<miền>` trỏ tới output `name_servers` của `aws/accounts/prd`; người học sửa tay.
- Tầng 2, Terraform: biến `delegated_subdomains` của module (tên zone con → bốn name server khác nhau, khoá phải là con thật của `zone_name`) tạo
  bản ghi `NS` TTL 172800 trong zone của env; chỉ root `aws/accounts/prd` truyền nó, với `stg.aws.<miền>` → output `name_servers` của
  `aws/accounts/stg`. Route 53 uỷ quyền subdomain bằng bản ghi `NS` ở zone cha mang name server của zone con, kể cả khi hai zone ở hai account [N3].
- Zone stg phải thay (NS mới): như gỡ ở §5, bỏ khoá stg ở prd và apply prd trước, rồi thay zone stg, rồi đặt NS mới và apply prd lần nữa
  trước khi buổi stg dùng tên của nó.
- ExternalDNS (`policy: sync`, registry TXT, owner là tên cluster) chỉ sửa, xoá bản ghi nó sở hữu [N4] và chỉ quản `A`, `AAAA`, `CNAME` [N5], nên
  cluster prd không đụng bản ghi `NS` uỷ quyền stg trong zone prd; cert-manager chỉ ghi TXT DNS-01.

### 3. Tên miền của env

`domain` của root `aws/envs/<env>` là tên zone của env (0048 §2 giữ nguyên luật này): prd `aws.<miền>` (web ở apex, API `api.aws.<miền>`), stg
`stg.aws.<miền>` (API `api.stg.aws.<miền>`). Script buổi đọc tên zone của env từ tfvars của `aws/accounts/<env>`, không đọc file nào của `aws/bootstrap`;
quét và chờ dọn giữ `NS`, `SOA` ở đỉnh zone và mọi bản ghi `NS` dưới đỉnh.

### 4. Chuyển một lần từ zone lab ở management

Bảng lệnh ở `aws/accounts/README.md` của `svp-infra`, cùng số bước:

0. Trên cấu hình cũ, gỡ bản ghi `NS` `prd.aws.<miền>` khỏi zone lab (apply bootstrap), để cha không còn trỏ tới zone sắp bị thay.
1. Apply `aws/accounts/stg`: zone stg không bị thay.
2. Apply `aws/accounts/prd`: zone `prd.aws.<miền>` (rỗng) bị thay bằng `aws.<miền>`, thêm bản ghi `NS` của stg.
3. Đổi bốn `NS` `aws` ở DNS của `<miền>` sang name server mới của prd.
4. `dig NS aws.<miền> +short` ở hai resolver công cộng ra đúng bốn name server đó, `check-dns.sh` của hai env xanh. Buổi stg chạy được từ đây:
   zone stg không đổi, đường cũ qua management và đường mới qua prd cùng trỏ tới nó.
5. Chờ ít nhất 172800 giây tính từ bước 3: TTL thường gặp của bản ghi `NS` là hai ngày, và AWS dặn không xoá zone cũ trong 48 giờ sau khi đổi
   name server vì resolver còn dùng nó [N6]; resolver cũng có thể giữ NS theo TTL của DNS cha [N7]. Buổi prd đầu tiên cần chứng chỉ bắt đầu sau bước này.
6. Zone lab chỉ còn `NS`, `SOA` ở đỉnh và bản ghi `NS` của stg (bản ghi khác thì xoá trước).
7. Apply bootstrap trên cấu hình mới: xoá đúng zone lab và bản ghi `NS` của stg. Bootstrap không apply vì lý do khác từ bước 1 tới bước này.

### 5. Gỡ

Zone nào được uỷ quyền thì gỡ `NS` ở cha trước, rồi mới xoá zone (AWS-7). Gỡ stg: bỏ khoá stg khỏi `delegated_subdomains` của prd, apply prd, rồi
gỡ baseline stg. Gỡ prd: gỡ stg trước (zone prd chứa uỷ quyền của stg), gỡ bốn `NS` `aws` ở DNS của `<miền>`, rồi gỡ baseline prd.

### Hệ quả

- Tốt: prd ở tên gốc; management không giữ tài nguyên workload dùng; uỷ quyền trong AWS là một bản ghi Terraform; không thêm account.
- Xấu: người có quyền Terraform, admin ở account prd nắm cả uỷ quyền stg; role trong cluster prd (IAM của ExternalDNS chỉ `A`, `AAAA`, `CNAME`,
  `TXT`, cert-manager chỉ TXT `_acme-challenge.*`) không ghi được `NS`, chỉ ghi được bản ghi dưới `stg.aws.<miền>` trong zone prd, không được
  phân giải vì tên đó đã uỷ quyền; đổi NS zone stg cần apply ở prd; gỡ prd phụ thuộc stg; một lần thay zone `prd.aws.<miền>` và chờ hai ngày
  trước khi xoá zone cũ.
- Xem lại khi: có env thứ ba hay người thứ hai cần quyền DNS riêng (account Network dùng chung); prd cần dựng lại zone thường xuyên.

## Xác nhận

- Lúc quyết chưa hiện thực trên account. Đã kiểm khi hiện thực: `make check` của `svp-infra` (test module với `delegated_subdomains` và validation,
  self-test script buổi), `make docs-check` của repo này.
- Còn lại: thứ tự §4 trên account thật; `dig NS aws.<miền> +short` ra bốn name server của zone prd, `dig NS stg.aws.<miền> +short` ra bốn name server
  của zone stg; bootstrap plan sau §4 không còn hosted zone; buổi stg, buổi prd có chứng chỉ cho tên mới.

## Hiện thực ở

- `svp-infra`: `aws/modules/account-baseline/` (`zone_name`, `delegated_subdomains`, §1, §2); `aws/accounts/` và `aws/accounts/README.md` (giá trị mỗi
  env, thứ tự chuyển và gỡ, §1, §2, §4, §5); `aws/bootstrap/` (không còn hosted zone, §1); `aws/envs/` (`domain`, §3); `aws/scripts/` (tên zone theo
  env, bản ghi giữ khi quét, §3).

## Nguồn

Đọc 2026-11-06.

- [N1] <https://docs.aws.amazon.com/organizations/latest/userguide/orgs_best-practices_mgmt-acct.html>
- [N2] <https://docs.aws.amazon.com/whitepapers/latest/organizing-your-aws-environment/foundational-ous.html>
- [N3] <https://docs.aws.amazon.com/Route53/latest/DeveloperGuide/dns-routing-traffic-for-subdomains.html>
- [N4] <https://github.com/kubernetes-sigs/external-dns/blob/v0.23.0/docs/faq.md>
- [N5] <https://github.com/kubernetes-sigs/external-dns/blob/v0.23.0/docs/flags.md>
- [N6] <https://docs.aws.amazon.com/Route53/latest/DeveloperGuide/hosted-zones-migrating.html>
- [N7] <https://docs.aws.amazon.com/Route53/latest/DeveloperGuide/migrate-dns-domain-in-use.html>

## Thông tin thêm

### Chỉnh bởi

- §2, Hệ quả: [0061](0061-edge-cloudfront-waf-acm.md): không còn gì trong cluster ghi zone (ExternalDNS bỏ, cert-manager không còn DNS-01); bản ghi edge do Terraform của root env; đỉnh zone hai env có CAA cho CA của Amazon; zone prd ký DNSSEC (KSK bằng key KMS `us-east-1`, `DS` ở DNS cha) và ghi query log.
