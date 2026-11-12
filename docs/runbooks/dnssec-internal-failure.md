# dnssec-internal-failure

- Severity: `page`. Alarm CloudWatch `svp-prd-dnssec-internal-failure` của module `account-baseline` (`aws/modules/account-baseline/dnssec.tf`
  của `svp-infra`), chỉ zone prd `aws.<miền>`, ở `us-east-1`; email tới từ topic `svp-prd-dns-alarms`. Thiết kế: [ADR-0061](../adr/0061-edge-cloudfront-waf-acm.md) §11.
- Mọi lệnh AWS do người học chạy. Lệnh đọc dùng permission set chỉ đọc `anhnv-prd-ro`; lệnh ghi (Giảm thiểu, Khôi phục) dùng `anhnv-prd`, chỉ
  sau khi `check-account.sh prd` in đúng account. Lệnh `dig`, `delv` chạy ở máy bất kỳ.

Dán một lần cho mỗi terminal (Route 53 và key DNSSEC chỉ ở `us-east-1`; id zone đọc từ dimension của alarm nên không cần state Terraform):

```sh
ro() { AWS_PROFILE=anhnv-prd-ro aws --region us-east-1 "$@"; }
D='aws.<miền>'   # tên zone prd
ZONE=$(ro cloudwatch describe-alarms --alarm-names svp-prd-dnssec-internal-failure --query 'MetricAlarms[0].Dimensions[?Name==`HostedZoneId`].Value' --output text)
KEY=$(ro kms describe-key --key-id alias/svp-dnssec --query KeyMetadata.KeyId --output text)
echo "zone=$ZONE key=$KEY"   # <zone-id>, id key; KEY rỗng là key đã bị xoá hẳn (dnssec-ksk-action-needed.md, Leo thang)
```

Trước mỗi khối lệnh ghi, ở bản clone `svp-infra` (biến `SVP_AWS_PRD_ACCOUNT_ID` đã export, không ghi vào file nào):

```sh
export SVP_SESSION_DIR="$PWD/.session/$(date -u +%Y%m%dT%H%M%SZ)"
aws/scripts/check-account.sh prd   # in account và ARN của anhnv-prd; account khác thì script dừng, không chạy tiếp
```

## Ý nghĩa và tác động tới người dùng

Metric `DNSSECInternalFailure` (namespace `AWS/Route53`, dimension `HostedZoneId`) bằng 1 khi có bất kỳ đối tượng DNSSEC nào của zone ở trạng
thái `INTERNAL_FAILURE`: trạng thái ký của zone, hay KSK `svp_prd_ksk`; alarm kêu khi tổng trong một chu kỳ từ 1 trở lên (chu kỳ, ngưỡng ở
`dnssec.tf`). Route 53 đặt trạng thái này khi một thao tác DNSSEC của nó không hoàn thành; tài liệu không liệt kê nguyên nhân.

Tác động:

- Khi KSK `INTERNAL_FAILURE`, Route 53 không cho đổi gì khác trên zone tới khi sửa xong, trừ thao tác sửa lỗi. Bản ghi của buổi prd (alias của
  web, `api`, `media`, bản ghi validation ACM ở root `aws/envs/prd`) và bản ghi của root `aws/accounts/prd` (`CAA`, uỷ quyền stg) không tạo, sửa,
  xoá được: `apply` và `destroy` lỗi ở chúng.
- Route 53 không ký được thì chữ ký (`RRSIG`) đang phục vụ chỉ còn hạn vài ngày. Khi DNS cha có bản ghi `DS` của `aws`, chữ ký hết hạn làm
  resolver kiểm DNSSEC (`1.1.1.1`, `8.8.8.8` và đa số resolver của nhà mạng) trả `SERVFAIL` cho mọi tên của zone prd, kể cả `stg.aws.<miền>` (bản
  ghi `NS` uỷ quyền stg nằm trong zone prd). Cha chưa có `DS` của `aws` (trước bước đặt `DS` của runbook `edge-setup.md`, hay sau đường lui) thì
  zone là đảo tin cậy, resolver không kiểm chữ ký, người dùng không mất gì.

Resolver không kiểm DNSSEC phân giải bình thường. Bản ghi đang có vẫn được trả lời trong lúc sự cố.

## Kiểm tra nhanh (5 phút)

Compose, k3d: không có (zone, KSK, key KMS chỉ ở account prd).

AWS và DNS (người học chạy):

```sh
# 1. Đối tượng nào INTERNAL_FAILURE: trạng thái ký của zone hay KSK, kèm lý do Route 53 ghi
ro route53 get-dnssec --hosted-zone-id "$ZONE" --query '{Zone:Status,KSK:KeySigningKeys[].{Name:Name,Status:Status,Message:StatusMessage}}' --output json
# 2. Thao tác DNSSEC gần nhất trên zone, có lỗi hay không (CloudTrail của account, us-east-1)
ro cloudtrail lookup-events --lookup-attributes AttributeKey=EventSource,AttributeValue=route53.amazonaws.com --start-time "$(date -u -v-2d +%FT%TZ)" --query 'Events[].CloudTrailEvent' --output json | jq -r '.[] | fromjson | select(.eventName | test("DNSSEC|KeySigningKey")) | [.eventTime, .eventName, (.errorCode // "-"), .userIdentity.arn] | @tsv'
# 3. Key KMS còn dùng được: Enabled, không PendingDeletion
ro kms describe-key --key-id "$KEY" --query 'KeyMetadata.[KeyState,Enabled,DeletionDate]' --output text
# 4. Cha có DS của aws chưa, và resolver kiểm DNSSEC có phân giải được zone không
dig +short DS "$D" @1.1.1.1
dig +dnssec +noall +comments SOA "$D" @1.1.1.1 | grep -E 'status|flags'
dig +cd +noall +comments SOA "$D" @1.1.1.1 | grep status
delv @1.1.1.1 SOA "$D"
```

Đọc:

- Bước 1: `Zone.ServeSignature` là `INTERNAL_FAILURE` (trạng thái ký) hay `KSK[0].Status` là `INTERNAL_FAILURE` (KSK); `Message` nói lý do nếu
  Route 53 ghi. KSK `ACTION_NEEDED` cùng lúc thì xử lý theo [dnssec-ksk-action-needed.md](dnssec-ksk-action-needed.md) trước.
- Bước 2: thao tác ngay trước lúc alarm kêu (`EnableHostedZoneDNSSEC`, `DisableHostedZoneDNSSEC`, `ActivateKeySigningKey`,
  `DeactivateKeySigningKey`, `CreateKeySigningKey`, `DeleteKeySigningKey`), ai chạy (Terraform qua role `SvpAdmin` hay người), có mã lỗi không.
- Bước 3: khác `Enabled` là nguyên nhân 2.
- Bước 4: `DS` rỗng là cha chưa có `DS` (đảo tin cậy). Có `DS`: `status: NOERROR` với cờ `ad` là zone còn phân giải và kiểm được; `status:
  SERVFAIL` mà dòng `+cd` (bỏ kiểm DNSSEC) ra `NOERROR` là chữ ký đã hết hạn hay sai: người dùng đang mất zone, làm ngay Giảm thiểu. `delv` in
  `; fully validated` là chuỗi tin cậy đủ; máy không có `delv` hay `delv` thiếu thư viện mã hoá thì dựa vào `dig`.

Console: Route 53 → Hosted zones → `aws.<miền>` → DNSSEC signing.

## Nguyên nhân thường gặp

Tài liệu của Route 53 chỉ cho cách sửa, không liệt kê nguyên nhân; thứ tự dưới đây theo dấu hiệu đọc được ở bước 1 đến 3.

1. **Một thao tác DNSSEC hỏng giữa chừng** (bước 2 có thao tác ngay trước alarm): `apply` của `aws/accounts/prd` (lần đầu ký, đổi
   `dnssec_signing`, thay KSK) hay lệnh tay của runbook `edge-setup.md`.
2. **Key KMS không dùng được lúc thao tác chạy** (bước 3 khác `Enabled`, hay KSK `ACTION_NEEDED` cùng lúc): nguyên nhân và cách sửa key ở
   [dnssec-ksk-action-needed.md](dnssec-ksk-action-needed.md).
3. **Lỗi phía Route 53** (bước 2 không có thao tác nào, key `Enabled`): leo thang.

## Giảm thiểu

Chọn theo bước 4:

- **`SERVFAIL` đang xảy ra, hay thử lại ở mục Khôi phục không đưa zone về trước khi chữ ký hết hạn:** làm
  [Đường lui khẩn cấp](#đường-lui-khẩn-cấp) ngay. Người dùng có lại zone sau khi `DS` hết hạn trong cache của resolver, không phụ thuộc Route 53
  sửa xong.
- **Zone còn `NOERROR` với cờ `ad`, hay cha chưa có `DS`:** thử lại thao tác theo mục Khôi phục.

Không làm khi cha còn `DS` của `aws`: tắt ký (`dnssec_signing = false`, `disable-hosted-zone-dnssec`), tắt hay xoá KSK, `dnssec_enabled = false`.
Tài liệu gợi ý "activate or deactivate the KSK", "enabling signing or disabling signing" để gỡ lỗi; ở zone còn `DS`, chỉ thử lại theo hướng ký (bật
KSK, bật ký). Không đặt `DS` mới ở cha khi alarm còn kêu. Buổi prd đang chạy thì hoãn `apply`, `destroy` của `aws/envs/prd` tới khi sửa xong;
`destroy` đã lỗi ở bản ghi Route 53 thì chạy lại sau khi sửa xong.

### Đường lui khẩn cấp

Đúng đường lui của mục [Tắt ký DNSSEC](https://github.com/anhnvcoder/svp-infra/blob/main/aws/modules/account-baseline/README.md#tắt-ký-dnssec)
của module: gỡ `DS` trước, chờ, rồi mới tắt ký.

1. Ghi TTL của `DS` ở name server của cha (cột thứ hai), rồi gỡ: Cloudflare → **DNS** → **Records** của `<miền>`, bản ghi **Type** `DS`, **Name**
   `aws` → **Delete**.

   ```sh
   P=$(dig +short NS '<miền>' | head -1)
   dig +noall +answer DS "$D" @"$P"   # trước khi gỡ: TTL ở cột 2; sau khi gỡ: rỗng
   ```

2. Chờ hết TTL đó tính từ lúc gỡ, rồi kiểm resolver công khai đã quên `DS` và phân giải zone (không còn cờ `ad`, `status: NOERROR`):

   ```sh
   dig +short DS "$D" @1.1.1.1; dig +short DS "$D" @8.8.8.8          # rỗng
   dig +dnssec +noall +comments SOA "$D" @1.1.1.1 | grep -E 'status|flags'
   ```

   Từ đây người dùng đã có lại zone, kể cả khi Route 53 chưa sửa xong.
3. Tắt ký ở root `aws/accounts/prd` của `svp-infra` (kiểm account trước, khối ở đầu trang):

   ```sh
   cd aws/accounts/prd
   AWS_PROFILE=anhnv-prd TF_VAR_account_id="$SVP_AWS_PRD_ACCOUNT_ID" terraform plan -var dnssec_signing=false -out=prd.tfplan
   AWS_PROFILE=anhnv-prd TF_VAR_account_id="$SVP_AWS_PRD_ACCOUNT_ID" terraform apply prd.tfplan && rm prd.tfplan
   ```

   Đọc plan trước khi apply: `module.baseline.aws_route53_hosted_zone_dnssec.this[0]` đổi tại chỗ sang `NOT_SIGNING`, và
   `module.baseline.aws_route53_key_signing_key.this[0]` đổi `status` về `ACTIVE` khi KSK chưa `ACTIVE`; không tạo, thay thế hay xoá gì. Apply lỗi
   vì zone còn `INTERNAL_FAILURE` thì thử lại theo hướng tắt ký (`disable-hosted-zone-dnssec`, mục Khôi phục) rồi chạy lại bước này; zone vẫn phân
   giải trong lúc đó.
4. PR ở `svp-infra` đổi mặc định của biến `dnssec_signing` trong `aws/accounts/prd/variables.tf` thành `false`, để lượt apply sau không ký lại.

Gỡ hẳn DNSSEC (hiếm, sau bước 3): theo mục Tắt ký DNSSEC của module và runbook
[`edge-setup.md`](https://github.com/anhnvcoder/svp-infra/blob/main/docs/runbooks/edge-setup.md) của `svp-infra`. Ký lại và đặt lại `DS`
cũng theo `edge-setup.md`, chỉ khi bước 1 của Kiểm tra nhanh đã sạch.

## Khôi phục và xác nhận

Theo tài liệu, sửa `INTERNAL_FAILURE` bằng cách chạy lại thao tác. Key KMS phải `Enabled` trước (nguyên nhân 2). Chạy lại thao tác ứng với trạng
thái mong muốn của zone (lệnh ghi, kiểm account trước), rồi đọc `get-change` tới `INSYNC`:

```sh
# Zone ký (bình thường): KSK INTERNAL_FAILURE thì bật lại KSK; trạng thái ký INTERNAL_FAILURE thì bật lại ký
AWS_PROFILE=anhnv-prd aws route53 activate-key-signing-key --hosted-zone-id "$ZONE" --name svp_prd_ksk --region us-east-1
AWS_PROFILE=anhnv-prd aws route53 enable-hosted-zone-dnssec --hosted-zone-id "$ZONE" --region us-east-1
# Chỉ khi đang đi đường lui và cha đã không còn DS của aws (bước 2 của đường lui sạch): tắt ký lại
AWS_PROFILE=anhnv-prd aws route53 disable-hosted-zone-dnssec --hosted-zone-id "$ZONE" --region us-east-1
# Mỗi lệnh trên in ChangeInfo.Id
ro route53 get-change --id <ChangeInfo.Id>   # Status: INSYNC
```

Xác nhận:

- Bước 1 của Kiểm tra nhanh: không còn `INTERNAL_FAILURE`; KSK `ACTIVE`, `Zone.ServeSignature` là `SIGNING` (hay `NOT_SIGNING` nếu đã đi đường
  lui).
- Bước 4: cha có `DS` thì `status: NOERROR` với cờ `ad`.
- `terraform plan` ở `aws/accounts/prd` ra `No changes.` (đã đi đường lui: chỉ sau PR của bước 4); lượt `apply`, `destroy` hoãn của `aws/envs/prd`
  chạy lại được.
- Alarm: `ro cloudwatch describe-alarms --alarm-names svp-prd-dnssec-internal-failure --query 'MetricAlarms[0].[StateValue,StateReason]'`
  rời `ALARM`. Route 53 gửi metric DNSSEC thưa (tài liệu ghi một điểm mỗi 4 giờ mỗi zone), nên alarm có thể về `INSUFFICIENT_DATA` thay vì `OK`
  và không có email OK: bằng chứng là `get-dnssec`, không phải email.

## Leo thang

- Chạy lại thao tác hai lần mà vẫn `INTERNAL_FAILURE`, hay nguyên nhân 3: mở case AWS Support (zone id, thời điểm, `StatusMessage` của bước 1,
  sự kiện của bước 2). Cha có `DS` thì đi đường lui trước, không chờ Support.
- Buổi prd không `destroy` được vì bản ghi Route 53: tài nguyên khác của buổi vẫn tính tiền theo giờ; sau khi sửa xong chạy lại `destroy` và
  quét sót của runbook buổi.
- Mọi lần alarm này kêu ở prd có postmortem ([mẫu](../postmortems/README.md)), kể cả khi người dùng chưa mất gì.

## Liên kết

- Dashboard: CloudWatch (`us-east-1`) → Alarms `svp-prd-dnssec-internal-failure`; Route 53 → Hosted zones → DNSSEC signing.
- ADR: [ADR-0061](../adr/0061-edge-cloudfront-waf-acm.md) §11, phụ lục [DNSSEC, Tắt ký DNSSEC, Chuỗi tin cậy](../adr/appendix/0061-edge-cloudfront-waf-acm.md).
- `svp-infra`: module `aws/modules/account-baseline` (mục Tắt ký DNSSEC của README), `aws/accounts/README.md` (mục Alarm và DNSSEC của prd),
  runbook `docs/runbooks/edge-setup.md` (đặt `DS`, đường lui, gỡ hẳn).
- Runbook cùng nhóm: [dnssec-ksk-action-needed.md](dnssec-ksk-action-needed.md).
- Diễn tập: không có (không tạo được `INTERNAL_FAILURE` có chủ đích).
- Nguồn (Route 53 Developer Guide, đọc 2026-11-12):
  [Troubleshooting DNSSEC signing](https://docs.aws.amazon.com/Route53/latest/DeveloperGuide/dns-configuring-dnssec-troubleshoot.html)
  (`INTERNAL_FAILURE`: chạy lại thao tác, không đổi được gì khác trên zone tới khi sửa),
  [Disabling DNSSEC signing](https://docs.aws.amazon.com/Route53/latest/DeveloperGuide/dns-configuring-dnssec-disable.html) (gỡ `DS` trước, chờ
  cache, rồi tắt ký),
  [Working with ZSKs](https://docs.aws.amazon.com/Route53/latest/DeveloperGuide/dns-configuring-dnssec-zsk-management.html) (chữ ký sinh trước vài
  ngày),
  [Monitoring hosted zones using CloudWatch](https://docs.aws.amazon.com/Route53/latest/DeveloperGuide/monitoring-hosted-zones-with-cloudwatch.html)
  (metric, `us-east-1`, tần suất),
  [Configuring DNSSEC signing](https://docs.aws.amazon.com/Route53/latest/DeveloperGuide/dns-configuring-dnssec.html) (khuyên alarm cho
  `DNSSECInternalFailure`, `DNSSECKeySigningKeysNeedingAction`).
