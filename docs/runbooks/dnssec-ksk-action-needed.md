# dnssec-ksk-action-needed

- Severity: `page`. Alarm CloudWatch `svp-prd-dnssec-ksk-action-needed` của module `account-baseline` (`aws/modules/account-baseline/dnssec.tf`
  của `svp-infra`), chỉ zone prd `aws.<miền>`, ở `us-east-1`; email tới từ topic `svp-prd-dns-alarms`. Thiết kế: [ADR-0061](../adr/0061-edge-cloudfront-waf-acm.md) §11.
- Mọi lệnh AWS do người học chạy. Lệnh đọc dùng permission set chỉ đọc `anhnv-prd-ro`; lệnh ghi (Giảm thiểu, Khôi phục) dùng `anhnv-prd`, chỉ
  sau khi `check-account.sh prd` in đúng account. Lệnh `dig`, `delv` chạy ở máy bất kỳ.

Dán một lần cho mỗi terminal (Route 53 và key DNSSEC chỉ ở `us-east-1`; id zone đọc từ dimension của alarm nên không cần state Terraform):

```sh
ro() { AWS_PROFILE=anhnv-prd-ro aws --region us-east-1 "$@"; }
D='aws.<miền>'   # tên zone prd
ZONE=$(ro cloudwatch describe-alarms --alarm-names svp-prd-dnssec-ksk-action-needed --query 'MetricAlarms[0].Dimensions[?Name==`HostedZoneId`].Value' --output text)
KEY=$(ro kms describe-key --key-id alias/svp-dnssec --query KeyMetadata.KeyId --output text)
echo "zone=$ZONE key=$KEY"   # <zone-id>, id key; KEY rỗng là key đã bị xoá hẳn (Leo thang)
```

Trước mỗi khối lệnh ghi, ở bản clone `svp-infra` (biến `SVP_AWS_PRD_ACCOUNT_ID` đã export, không ghi vào file nào):

```sh
export SVP_SESSION_DIR="$PWD/.session/$(date -u +%Y%m%dT%H%M%SZ)"
aws/scripts/check-account.sh prd   # in account và ARN của anhnv-prd; account khác thì script dừng, không chạy tiếp
```

## Ý nghĩa và tác động tới người dùng

Metric `DNSSECKeySigningKeysNeedingAction` (namespace `AWS/Route53`, dimension `HostedZoneId`) là số KSK của zone ở trạng thái `ACTION_NEEDED`;
alarm kêu khi tổng trong một chu kỳ từ 1 trở lên (chu kỳ, ngưỡng ở `dnssec.tf`). Zone prd có đúng một KSK, `svp_prd_ksk`, nên alarm kêu nghĩa
là KSK duy nhất không dùng được. Route 53 đặt KSK vào `ACTION_NEEDED` khi mất quyền dùng key KMS của nó: key bị tắt, bị lên lịch xoá hay đã xoá,
key policy đổi.

Khi KSK `ACTION_NEEDED`, Route 53 không ký mới được và ngừng xoay ZSK. Chữ ký (`RRSIG`) đang phục vụ vẫn hợp lệ thêm vài ngày (Route 53 sinh
trước chữ ký cho vài ngày tới, phòng khi key KMS không dùng được); khi chữ ký cuối hết hạn, resolver kiểm DNSSEC (`1.1.1.1`, `8.8.8.8` và đa số
resolver của nhà mạng) trả `SERVFAIL` cho mọi tên của zone prd: web, `api`, `media` của prd không mở được, và `stg.aws.<miền>` cũng vậy vì bản
ghi `NS` uỷ quyền stg nằm trong zone prd. Tài liệu gọi đây là sự cố "you must act fast". Ảnh hưởng chỉ xảy ra khi DNS cha có bản ghi `DS` của
`aws`:

- **Cha có `DS` của `aws`** (chuỗi tin cậy đã nối): zone sẽ ngừng phân giải với resolver kiểm DNSSEC khi chữ ký hết hạn; đang `SERVFAIL` là đã
  hết.
- **Cha chưa có `DS` của `aws`** (trước bước đặt `DS` của runbook `edge-setup.md`, hay sau đường lui): zone là đảo tin cậy, resolver không kiểm
  chữ ký của nó, người dùng không mất gì. Vẫn sửa trong ngày, và không đặt `DS` khi alarm còn kêu.

Resolver không kiểm DNSSEC phân giải bình thường trong cả hai trường hợp.

## Kiểm tra nhanh (5 phút)

Compose, k3d: không có (zone, KSK, key KMS chỉ ở account prd).

AWS và DNS (người học chạy):

```sh
# 1. Trạng thái ký của zone và của KSK, kèm lý do Route 53 ghi
ro route53 get-dnssec --hosted-zone-id "$ZONE" --query '{Zone:Status,KSK:KeySigningKeys[].{Name:Name,Status:Status,Message:StatusMessage,Kms:KmsArn}}' --output json
# 2. Trạng thái key KMS: Enabled, Disabled, PendingDeletion (kèm ngày xoá)
ro kms describe-key --key-id "$KEY" --query 'KeyMetadata.[KeyState,Enabled,DeletionDate]' --output text
# 3. Key policy còn hai statement cho dnssec-route53.amazonaws.com và statement quản trị của account
ro kms get-key-policy --key-id "$KEY" --policy-name default --query Policy --output text | jq -c '.Statement[] | [.Sid, .Principal, .Action]'
# 4. Ai đổi key trong 2 ngày qua (CloudTrail của account, us-east-1)
ro cloudtrail lookup-events --lookup-attributes AttributeKey=EventSource,AttributeValue=kms.amazonaws.com --start-time "$(date -u -v-2d +%FT%TZ)" --query "Events[?contains(['DisableKey','ScheduleKeyDeletion','PutKeyPolicy','RevokeGrant','RetireGrant','EnableKey','CancelKeyDeletion'], EventName)].[EventTime,EventName,Username]" --output text
# 5. Cha có DS của aws chưa, và resolver kiểm DNSSEC có phân giải được zone không
dig +short DS "$D" @1.1.1.1
dig +dnssec +noall +comments SOA "$D" @1.1.1.1 | grep -E 'status|flags'
dig +cd +noall +comments SOA "$D" @1.1.1.1 | grep status
delv @1.1.1.1 SOA "$D"
```

Đọc:

- Bước 1: `KSK[0].Status` là `ACTION_NEEDED`, `Message` nói lý do; `Zone.ServeSignature` thường vẫn `SIGNING`.
- Bước 2: `Disabled` hay `PendingDeletion` là nguyên nhân 1 hay 2; `Enabled` thì xem bước 3. Lệnh lỗi `NotFoundException` là key đã xoá hẳn.
- Bước 3: thiếu `Route53DnssecUseKey` hay `Route53DnssecCreateGrant`, hay `Principal` khác `dnssec-route53.amazonaws.com`, là nguyên nhân 3.
- Bước 4: tên lệnh và người chạy; không có dòng nào mà key và policy đúng thì xem nguyên nhân 4.
- Bước 5: `DS` rỗng là cha chưa có `DS` (đảo tin cậy). Có `DS`: `status: NOERROR` với cờ `ad` là zone còn phân giải và kiểm được; `status:
  SERVFAIL` mà dòng `+cd` (bỏ kiểm DNSSEC) ra `NOERROR` là chữ ký đã hết hạn hay sai: người dùng đang mất zone, làm ngay Giảm thiểu. `delv` in
  `; fully validated` là chuỗi tin cậy đủ; máy không có `delv` hay `delv` thiếu thư viện mã hoá thì dựa vào `dig`.

Console: Route 53 → Hosted zones → `aws.<miền>` → DNSSEC signing (trạng thái KSK); KMS (`us-east-1`) → Customer managed keys → `svp-dnssec`.

## Nguyên nhân thường gặp

1. **Key KMS bị tắt** (bước 2 `Disabled`): ai đó chạy `DisableKey` (bước 4), console hay lệnh tay.
2. **Key bị lên lịch xoá** (bước 2 `PendingDeletion`, có `DeletionDate`): `ScheduleKeyDeletion` ở bước 4, thường do làm nhầm bước gỡ hẳn DNSSEC
   hay dọn tài nguyên bằng tay. Key còn cứu được tới `DeletionDate`.
3. **Key policy đổi** (bước 3 thiếu statement, bước 4 có `PutKeyPolicy`): policy sửa tay ngoài Terraform, hay một thay đổi của module
   `account-baseline` bỏ quyền của `dnssec-route53.amazonaws.com`.
4. **Guardrail của org chặn dịch vụ** (key và policy đúng, bước 4 không có gì): RCP `svp-data-perimeter` của root `aws/org` đổi mà không giữ luồng
   "Route 53 ký zone bằng key KMS" (bảng luồng RCP ở phụ lục ADR-0061). Email `svp-security` nhóm Organizations cùng lúc là dấu hiệu.

## Giảm thiểu

Chọn theo bước 5:

- **`SERVFAIL` đang xảy ra, hay không sửa được key trước khi chữ ký hết hạn** (key đã xoá hẳn, policy khoá cả quản trị): làm
  [Đường lui khẩn cấp](#đường-lui-khẩn-cấp) ngay. Người dùng có lại zone sau khi `DS` hết hạn trong cache của resolver, không phụ thuộc key.
- **Zone còn `NOERROR` với cờ `ad`, hay cha chưa có `DS`:** sửa key theo mục Khôi phục; chữ ký còn hạn vài ngày đủ cho việc này.

Không làm khi cha còn `DS` của `aws`: tắt ký (`dnssec_signing = false`, `disable-hosted-zone-dnssec`), tắt hay xoá KSK, `dnssec_enabled = false`.
Mỗi việc đó làm chữ ký không còn khớp `DS` và zone ngừng phân giải ngay sau khi chữ ký cũ hết hạn. Không đặt `DS` mới ở cha khi alarm còn kêu.

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

   Từ đây người dùng đã có lại zone, kể cả khi key còn hỏng.
3. Tắt ký ở root `aws/accounts/prd` của `svp-infra` (kiểm account trước, khối ở đầu trang):

   ```sh
   cd aws/accounts/prd
   AWS_PROFILE=anhnv-prd TF_VAR_account_id="$SVP_AWS_PRD_ACCOUNT_ID" terraform plan -var dnssec_signing=false -out=prd.tfplan
   AWS_PROFILE=anhnv-prd TF_VAR_account_id="$SVP_AWS_PRD_ACCOUNT_ID" terraform apply prd.tfplan && rm prd.tfplan
   ```

   Đọc plan trước khi apply: `module.baseline.aws_route53_hosted_zone_dnssec.this[0]` đổi tại chỗ `SIGNING` → `NOT_SIGNING`, và
   `module.baseline.aws_route53_key_signing_key.this[0]` đổi `status` về `ACTIVE` khi KSK chưa `ACTIVE`; không tạo, thay thế hay xoá gì. Plan có
   `aws_kms_key.dnssec` được tạo mới là key đang `PendingDeletion` hay đã mất: không apply, sửa key theo Khôi phục trước. Apply lỗi ở KSK vì key
   chưa dùng được thì sửa key rồi chạy lại bước này; zone vẫn phân giải trong lúc đó.
4. PR ở `svp-infra` đổi mặc định của biến `dnssec_signing` trong `aws/accounts/prd/variables.tf` thành `false`, để lượt apply sau không ký lại.

Gỡ hẳn DNSSEC (hiếm, sau bước 3): theo mục Tắt ký DNSSEC của module và runbook
[`edge-setup.md`](https://github.com/anhnvcoder/svp-infra/blob/main/docs/runbooks/edge-setup.md) của `svp-infra`. Ký lại và đặt lại `DS`
cũng theo `edge-setup.md`, chỉ khi bước 1 của Kiểm tra nhanh đã sạch.

## Khôi phục và xác nhận

Sửa key theo nguyên nhân (lệnh ghi, kiểm account trước), rồi bật lại KSK. Thứ tự quan trọng: key dùng được trước, KSK sau.

- **Nguyên nhân 1, key tắt:**
  `AWS_PROFILE=anhnv-prd aws kms enable-key --key-id "$KEY" --region us-east-1`.
- **Nguyên nhân 2, key chờ xoá:** huỷ xoá trước mọi `terraform plan`, rồi bật (huỷ xoá để key ở `Disabled`):
  `AWS_PROFILE=anhnv-prd aws kms cancel-key-deletion --key-id "$KEY" --region us-east-1`, rồi lệnh `enable-key` ở trên. Provider Terraform coi
  key `PendingDeletion` là không còn, nên plan trước khi huỷ đề nghị tạo key mới và thay KSK: không apply plan đó.
- **Nguyên nhân 3, key policy:** Terraform giữ policy đúng; apply lại ở `aws/accounts/prd` (`plan -out=prd.tfplan` rồi `apply prd.tfplan` như bước
  3 của đường lui, không `-var`). Plan chỉ được đổi tại chỗ `module.baseline.aws_kms_key.dnssec[0]` (`policy`) và
  `module.baseline.aws_route53_key_signing_key.this[0]` (`status` về `ACTIVE`, apply làm việc của lệnh `activate` dưới đây).
- **Nguyên nhân 4, RCP:** sửa ở root `aws/org` (management, `anhnv-sso`) theo README của root đó, giữ luồng của `dnssec-route53.amazonaws.com`.

Bật lại KSK khi key đã `Enabled` và policy đúng (bỏ qua nếu apply của nguyên nhân 3 đã làm):

```sh
AWS_PROFILE=anhnv-prd aws route53 activate-key-signing-key --hosted-zone-id "$ZONE" --name svp_prd_ksk --region us-east-1
ro route53 get-change --id <ChangeInfo.Id của lệnh trên>   # Status: INSYNC
```

Xác nhận:

- Bước 1 của Kiểm tra nhanh: `KSK[0].Status` là `ACTIVE`, `Zone.ServeSignature` là `SIGNING` (hay `NOT_SIGNING` nếu đã đi đường lui).
- Bước 5: cha có `DS` thì `status: NOERROR` với cờ `ad`.
- `terraform plan` ở `aws/accounts/prd` ra `No changes.` (đã đi đường lui: chỉ sau PR của bước 4).
- Alarm: `ro cloudwatch describe-alarms --alarm-names svp-prd-dnssec-ksk-action-needed --query 'MetricAlarms[0].[StateValue,StateReason]'`
  rời `ALARM`. Route 53 gửi metric DNSSEC thưa (tài liệu ghi một điểm mỗi 4 giờ mỗi zone), nên alarm có thể về `INSUFFICIENT_DATA` thay vì `OK`
  và không có email OK: bằng chứng là `get-dnssec`, không phải email.

## Leo thang

- **Key đã xoá hẳn** (`describe-key` `NotFoundException`, `KEY` rỗng): không cứu được, KSK không bao giờ `ACTIVE` lại. Đi đường lui ngay nếu cha có
  `DS`; sau đó KSK mới với key mới (plan của `aws/accounts/prd` tạo key và thay KSK), rồi đặt `DS` mới theo `edge-setup.md`.
- **Key policy không còn statement quản trị của account** (không ai trong account sửa được policy): chỉ AWS Support khôi phục quyền; đi đường lui
  trước, rồi mở case.
- KSK vẫn `ACTION_NEEDED` sau khi key `Enabled`, policy đúng và `activate-key-signing-key` đã `INSYNC`: thử lại một lần, rồi mở case AWS Support;
  cha có `DS` thì đi đường lui, không chờ.
- Bước 4 thấy người hay lệnh lạ đổi key: xử lý như sự kiện bảo mật theo [security-alert.md](security-alert.md).
- Mọi lần alarm này kêu ở prd có postmortem ([mẫu](../postmortems/README.md)), kể cả khi người dùng chưa mất gì.

## Liên kết

- Dashboard: CloudWatch (`us-east-1`) → Alarms `svp-prd-dnssec-ksk-action-needed`; Route 53 → Hosted zones → DNSSEC signing.
- ADR: [ADR-0061](../adr/0061-edge-cloudfront-waf-acm.md) §11, phụ lục [DNSSEC, Tắt ký DNSSEC, Chuỗi tin cậy, bảng luồng RCP](../adr/appendix/0061-edge-cloudfront-waf-acm.md).
- `svp-infra`: module `aws/modules/account-baseline` (mục Tắt ký DNSSEC của README), `aws/accounts/README.md` (mục Alarm và DNSSEC của prd),
  runbook `docs/runbooks/edge-setup.md` (đặt `DS`, đường lui, gỡ hẳn).
- Runbook cùng nhóm: [dnssec-internal-failure.md](dnssec-internal-failure.md).
- Diễn tập: không có (không làm hỏng key của zone prd có chủ đích).
- Nguồn (Route 53 Developer Guide, AWS KMS Developer Guide, đọc 2026-11-12):
  [Troubleshooting DNSSEC signing](https://docs.aws.amazon.com/Route53/latest/DeveloperGuide/dns-configuring-dnssec-troubleshoot.html)
  (nguyên nhân `ACTION_NEEDED`, "you must act fast", bật lại KSK),
  [Disabling DNSSEC signing](https://docs.aws.amazon.com/Route53/latest/DeveloperGuide/dns-configuring-dnssec-disable.html) (gỡ `DS` trước, chờ
  cache, rồi tắt ký),
  [Working with ZSKs](https://docs.aws.amazon.com/Route53/latest/DeveloperGuide/dns-configuring-dnssec-zsk-management.html) (chữ ký sinh trước vài
  ngày, ngừng xoay ZSK khi KSK `ACTION_NEEDED`),
  [Monitoring hosted zones using CloudWatch](https://docs.aws.amazon.com/Route53/latest/DeveloperGuide/monitoring-hosted-zones-with-cloudwatch.html)
  (metric, `us-east-1`, tần suất),
  [Customer managed key requirements](https://docs.aws.amazon.com/Route53/latest/DeveloperGuide/dns-configuring-dnssec-cmk-requirements.html),
  [Deleting AWS KMS keys](https://docs.aws.amazon.com/kms/latest/developerguide/deleting-keys.html) (huỷ xoá để key ở `Disabled`, key đã xoá không
  khôi phục được).
