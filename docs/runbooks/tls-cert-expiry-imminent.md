# TLSCertExpiryImminent

- Severity: `page` (runbook này) và `ticket` (`TLSCertExpiringSoon`, ngưỡng 21 ngày, dùng chung runbook). Rule viết tay, nhóm
  `svp-uptime` của `deploy/observability/prometheus/rules/svp-alerts.yaml`.
- Chuẩn bị biến `PROM`, `AM`: [README](README.md#chuẩn-bị-trong-terminal). Trên eks, Prometheus là AMP: truy vấn qua Grafana của env.

## Ý nghĩa và tác động tới người dùng

`probe_ssl_earliest_cert_expiry{job="blackbox-http"}` trừ giờ hiện tại còn dưới **7 ngày**, liền 15 phút
(`TLSCertExpiryImminent`, page), hay dưới **21 ngày**, liền 1 giờ (`TLSCertExpiringSoon`, ticket). Nhãn `probe` (`web`, `api`,
`media`) cho biết đích nào. Compose (HTTP) không có chuỗi TLS nên không cháy ở đó.

21 ngày nằm dưới mốc gia hạn tự động của ACM (60 ngày trước hạn) và của cert-manager (còn 1/3 thời hạn, mặc định 90 ngày), nên
cảnh báo cháy nghĩa là **gia hạn tự động đã hỏng** ([ADR-0074](../adr/0074-cost-uptime.md) §10), không phải cert chỉ sắp tới
kỳ gia hạn.

Người dùng: chưa thấy gì khi cảnh báo cháy. Cert hết hạn thì trình duyệt chặn trang, client API từ chối kết nối; probe cũng đỏ,
`PublicUptimeBudgetBurn` cháy theo ([public-uptime-budget-burn.md](public-uptime-budget-burn.md)). Trên k3d probe không kiểm chuỗi tin cậy
(`insecure_skip_verify`), nhưng vẫn đọc hạn của cert listener nên cảnh báo vẫn đúng.

## Kiểm tra nhanh (5 phút)

```sh
curl -sG "$PROM/api/v1/query" --data-urlencode 'query=min by (probe, instance) (probe_ssl_earliest_cert_expiry{job="blackbox-http"}) - time()' | jq -c '.data.result[] | [.metric.probe, .metric.instance, .value[1]/86400]'
curl -sG "$AM/api/v2/alerts" --data-urlencode 'filter=alertname=~"TLSCert.*"' | jq -c '.[] | [.labels.alertname, .labels.probe, .labels.severity, .status.state]'
```

Số cuối là số ngày còn lại. Dashboard `svp-uptime`, panel "Days until certificate expiry".

k3d (cert của listener Gateway `svp` do cert-manager ký bằng CA `svp-local-ca`, ClusterIssuer `svp-ca`):

```sh
kubectl --context k3d-svp get certificates.cert-manager.io -A
kubectl --context k3d-svp get certificates.cert-manager.io -A -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name,READY:.status.conditions[0].status,NOT_AFTER:.status.notAfter,RENEWAL:.status.renewalTime
kubectl --context k3d-svp -n cert-manager logs deploy/cert-manager --since=1h --tail=200
```

eks (người học chạy; cert của CloudFront ở `us-east-1`, cert của ALB cùng region với cluster; chuẩn bị `awsx` ở
[README](README.md#alarm-của-dịch-vụ-managed-rds-msk-elasticache), đổi `--region` của lệnh theo cert):

```sh
AWS_PROFILE=anhnv-<env> aws acm list-certificates --region us-east-1 --query 'CertificateSummaryList[].[DomainName,CertificateArn,Status,NotAfter]' --output text
AWS_PROFILE=anhnv-<env> aws acm describe-certificate --region us-east-1 --certificate-arn <arn> --query 'Certificate.[Status,NotAfter,RenewalEligibility,RenewalSummary.RenewalStatus,RenewalSummary.RenewalStatusReason,DomainValidationOptions[].ValidationStatus]' --output text
dig +short CNAME _<token>.<domain>   # is the ACM DNS validation record still there
```

Đọc kết quả:

- `RenewalStatus` `FAILED` hay `PENDING_VALIDATION` kèm `RenewalStatusReason` → ACM không gia hạn được (nguyên nhân 1 dưới).
- `RenewalEligibility` `INELIGIBLE` → cert không dùng bởi dịch vụ tích hợp nào (CloudFront, ALB), ACM không gia hạn tự động.
- cert-manager: `Ready` `False` hay `renewalTime` đã qua mà `notAfter` chưa đổi → cert-manager không gia hạn được (nguyên nhân 3).

## Nguyên nhân thường gặp

1. **ACM không xác thực lại được**: bản ghi CNAME xác thực DNS mất khỏi zone Route 53 (zone dựng lại, bản ghi xoá tay).
2. **Cert không còn gắn với dịch vụ** (CloudFront, ALB): ACM chỉ gia hạn cert đang dùng.
3. **cert-manager lỗi** (k3d): ClusterIssuer `svp-ca` không Ready, controller chết, CA `svp-local-ca` mất.
4. **Probe đọc cert khác cert dự định**: `instance` trỏ đích cũ hay domain đổi; kiểm nhãn `instance` trước khi sửa cert.
5. **Mới dựng lại buổi**: chuỗi cũ của buổi trước còn trong cửa sổ; `probe_ssl_earliest_cert_expiry` của lần probe đầu có thể chưa có.

## Giảm thiểu

- ACM: khôi phục bản ghi CNAME xác thực (Terraform là nguồn sự thật: `apply` của root `aws/envs/<env>`, người học chạy), rồi chờ ACM
  thử lại; cần ngay thì yêu cầu cert mới qua Terraform và gắn lại vào CloudFront hay ALB. Tránh sửa tay ngoài Terraform.
- cert-manager (k3d): sửa Issuer rồi buộc cấp lại:

```sh
kubectl --context k3d-svp get clusterissuers.cert-manager.io svp-ca
kubectl --context k3d-svp -n <ns> annotate certificates.cert-manager.io <tên> cert-manager.io/issue-temporary-certificate- --overwrite
kubectl --context k3d-svp -n <ns> delete secret <secret của certificate>   # cert-manager cấp lại ngay
```

Xoá Secret của Certificate làm listener mất cert tới khi cấp lại (vài giây); chỉ làm khi cert thật sự sắp hết hạn.

## Khôi phục và xác nhận

```sh
curl -sG "$PROM/api/v1/query" --data-urlencode 'query=min by (probe) (probe_ssl_earliest_cert_expiry{job="blackbox-http"}) - time()' | jq -c '.data.result[] | [.metric.probe, .value[1]/86400]'
```

Số ngày còn lại của mọi đích lớn hơn 21 (cert mới, thường 90 ngày hay 198 ngày). Cảnh báo ticket resolve sau khi giá trị
vượt 21 ngày, page khi vượt 7 ngày.

## Leo thang

- Cert đã hết hạn (số ngày âm) hay còn dưới 24 giờ mà chưa cấp lại được: sự cố người dùng; mở postmortem, ghi vì sao gia hạn tự
  động hỏng và vì sao cảnh báo ticket 21 ngày không được xử lý sớm hơn.
- Gia hạn tự động hỏng ở mọi cert cùng lúc: nghi sự cố của zone DNS hay của ACM; xem AWS Health của account.

## Liên kết

- Dashboard: `svp-uptime` (số ngày tới hạn cert).
- ADR: [ADR-0074](../adr/0074-cost-uptime.md) §10 (ngưỡng 21 và 7 ngày, nguồn mốc gia hạn),
  [ADR-0061](../adr/0061-edge-cloudfront-waf-acm.md) (cert ở CloudFront, ALB).
- Diễn tập, đo: chưa có diễn tập làm cảnh báo này cháy; test promtool của hai ngưỡng ở `svp-alerts.test.yaml`.
