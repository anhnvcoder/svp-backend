# PublicUptimeBudgetBurn

- Severity: `page` (runbook này) và `ticket` (cùng tên, chỉ ở Alertmanager). Rule sinh bằng Sloth từ SLO `public-uptime` của
  `deploy/observability/slo/svp-slos.yaml` (`make slo`).
- Chuẩn bị biến `PROM`, `AM`, hàm `dc`: [README](README.md#chuẩn-bị-trong-terminal). Trên eks, Prometheus là AMP: truy vấn qua
  Grafana của env (Explore, data source `prometheus`) và dashboard `svp-uptime`.

## Ý nghĩa và tác động tới người dùng

SLO: 99,9% lượt probe HTTP (job `blackbox-http`: `web`, `api`, `media`) thành công trong 30 ngày. Page cháy khi tỉ lệ probe lỗi
vượt **1,44%** trên cả 1 giờ và 5 phút, hoặc **0,6%** trên cả 6 giờ và 30 phút ([ADR-0074](../adr/0074-cost-uptime.md) §10,
[ADR-0020](../adr/0020-reliability-stage6.md) §3). SLI là trung bình của mọi probe: một đích đỏ liên tục trong ba đích đã là
tỉ lệ lỗi khoảng 33%, nên page cháy sau vài phút.

Probe chạy trong cluster nhưng đi đường người dùng đi. Trên eks: DNS công khai, CloudFront (WAF), ALB, Envoy, Service. Trên k3d:
Envoy của Gateway `svp`. Đích `web` là `/healthz` của web, `api` là `/readyz` của gateway (gateway không Ready thì probe đỏ dù
tiến trình còn sống), `media` là object `media/uptime-probe.txt` ở bucket media. Probe DNS (job `blackbox-dns`) không vào SLI: nó
chỉ giúp khoanh vùng.

Người dùng: đích đỏ nghĩa là trang web, API hay video HLS không tới được qua đường công khai (hoặc chậm quá hạn probe). Probe
chung region, VPC, NAT với hệ thống nên không đo từ địa lý người dùng; probe xanh chưa chứng minh mọi người dùng tới được.

Không có chuỗi `probe_success` thì SLO không có tỉ lệ và cảnh báo này không cháy: lúc đó `UptimeProbesAbsent` cháy
([uptime-probes-absent.md](uptime-probes-absent.md)).

**Cháy trong giờ đầu sau khi dựng cluster mới thì chờ hết cửa sổ, không điều tra.** `Probe` có từ khi `svp-observability` sync,
trước khi web và gateway lên, nên các lượt probe lúc dựng lỗi thật và nằm trong cửa sổ của cảnh báo
([`cost-and-uptime.md`](../explanation/cost-and-uptime.md#slo-và-cảnh-báo)). Chỉ cần thấy cả ba đích đã về 1 (truy vấn đầu ở Kiểm
tra nhanh): page hết trong khoảng 30 phút sau đó, ticket theo cửa sổ 6 giờ. Ba đích chưa xanh khi cluster đã dựng xong, hay page cháy
giữa buổi, mới là sự cố.

## Kiểm tra nhanh (5 phút)

Mở dashboard `svp-uptime` (`http://127.0.0.1:3000/d/svp-uptime` ở k3d, trong Grafana của env ở eks) trước: đích nào đỏ, pha nào
dài (`probe_http_duration_seconds` theo `phase`: `resolve`, `connect`, `tls`, `processing`, `transfer`), mã HTTP, số ngày tới hạn
cert, probe DNS.

Truy vấn tương đương (k3d: `PROM` từ `make k8s-ui-prometheus`; eks: dán vào Explore):

```sh
curl -sG "$PROM/api/v1/query" --data-urlencode 'query=min by (probe) (probe_success{job="blackbox-http"})' | jq -c '.data.result[] | [.metric.probe, .value[1]]'
curl -sG "$PROM/api/v1/query" --data-urlencode 'query=max by (probe) (probe_http_status_code{job="blackbox-http"})' | jq -c '.data.result[] | [.metric.probe, .value[1]]'
curl -sG "$PROM/api/v1/query" --data-urlencode 'query=avg by (probe, phase) (probe_http_duration_seconds{job="blackbox-http"})' | jq -c '.data.result[] | [.metric.probe, .metric.phase, .value[1]]'
# DNS probes exist on eks only (job blackbox-dns)
curl -sG "$PROM/api/v1/query" --data-urlencode 'query=min by (probe) (probe_success{job="blackbox-dns"})' | jq -c '.data.result[] | [.metric.probe, .value[1]]'
curl -sG "$AM/api/v2/alerts" --data-urlencode 'filter=alertname=~"PublicUptimeBudgetBurn|UptimeProbesAbsent|TLSCert.*"' | jq -c '.[] | [.labels.alertname, .labels.severity, .status.state]'
```

Một probe lần cuối cho blackbox, đọc lý do thật (`debug=true` trả log của lần thử). Module và URL lấy từ nhãn `instance` của
chuỗi và `Probe` tương ứng:

```sh
kubectl --context k3d-svp -n svp-obs get probes.monitoring.coreos.com
kubectl --context k3d-svp -n svp-obs get pods -l app.kubernetes.io/name=prometheus-blackbox-exporter
kubectl --context k3d-svp -n svp-obs logs -l app.kubernetes.io/name=prometheus-blackbox-exporter --since=15m --tail=200
```

Từ blackbox ra Envoy trên k3d (không `curl` từ pod tạm: dùng port-forward tới blackbox, `debug` cho thấy từng bước):

```sh
kubectl --context k3d-svp -n svp-obs port-forward svc/blackbox-exporter 9115:9115   # terminal riêng
curl -s 'http://127.0.0.1:9115/probe?module=http_local_api&target=https://svp-envoy.envoy-gateway-system.svc.cluster.local/readyz&debug=true' | tail -n 30
kubectl --context k3d-svp -n envoy-gateway-system get svc svp-envoy
kubectl --context k3d-svp -n envoy-gateway-system get pods
```

eks (người học chạy; thay `<env>` bằng `stg` hay `prd`, chuẩn bị `awsx` ở [README](README.md#alarm-của-dịch-vụ-managed-rds-msk-elasticache)):

```sh
kubectl --context svp-<env> -n svp-obs get pods -l app.kubernetes.io/name=prometheus-blackbox-exporter
kubectl --context svp-<env> -n svp-obs logs -l app.kubernetes.io/name=prometheus-blackbox-exporter --since=15m --tail=200
dig +short A <domain>; dig +short A api.<domain>; dig +short A <media domain>
curl -s -o /dev/null -w '%{http_code} %{time_total}\n' https://<domain>/healthz
curl -s -o /dev/null -w '%{http_code} %{time_total}\n' https://api.<domain>/readyz
curl -s -o /dev/null -w '%{http_code} %{time_total}\n' https://<media domain>/media/uptime-probe.txt
awsx elbv2 describe-target-health --target-group-arn "$(awsx elbv2 describe-target-groups --names svp-<env>-envoy --query 'TargetGroups[0].TargetGroupArn' --output text)" --query 'TargetHealthDescriptions[].[Target.Id,TargetHealth.State]' --output text
```

Đọc kết quả:

- Cả ba đích đỏ cùng lúc, DNS xanh → phần chung của đường vào (cert, CloudFront, ALB, Envoy, blackbox ra mạng).
- Cả ba đỏ, DNS cũng đỏ → DNS công khai hay CoreDNS (`kube-dns`) hỏng.
- Chỉ `api` đỏ với mã 503 → gateway chưa Ready hay dưới đang lỗi: [feed-availability-budget-burn.md](feed-availability-budget-burn.md) và cảnh báo
  khác cùng lúc. Chỉ `web` đỏ → [web-availability-budget-burn.md](web-availability-budget-burn.md). Chỉ `media` đỏ với 403 hay 404 → object probe
  hay bucket media (chính sách ẩn danh, `deploy/s3/init.sh` ở k3d, `uptime-probe.tf` ở eks).
- `probe_success` 0 với pha `tls` dài rồi thất bại → cert hay SNI; số ngày tới hạn âm hay nhỏ → [tls-cert-expiry-imminent.md](tls-cert-expiry-imminent.md).
- Pha `connect` hết hạn → chặn mạng: NetworkPolicy của blackbox, security group của ALB, NAT.

## Nguyên nhân thường gặp

1. **Dịch vụ phía sau lỗi thật** (gateway, web): probe đỏ trùng với cảnh báo SLO khác. Xử lý theo runbook đó; probe tự xanh theo.
2. **Cert hết hạn hay không khớp tên** (ACM, cert-manager): `probe_ssl_earliest_cert_expiry` gần 0; module eks kiểm chuỗi, nên
   cert sai là probe đỏ.
3. **DNS**: bản ghi của domain mất hay trỏ sai sau apply; probe DNS (eks) đỏ, `dig` không ra bản ghi A.
4. **CloudFront hay WAF**: mã 403 (WAF chặn User-Agent `svp-uptime-probe` khi Bot Control chuyển sang chặn,
   [ADR-0074](../adr/0074-cost-uptime.md) §6), 502/504 từ origin; sai behavior hay cache của đường `media`.
5. **ALB hay target group**: target `unhealthy` (Envoy không có pod Ready, cổng listener đổi), security group đổi.
6. **Envoy / Gateway**: Service `svp-envoy` không có endpoint, Gateway `svp` không Programmed, listener HTTPS đổi cổng
   (NetworkPolicy của blackbox cho đúng cổng container 10443).
7. **Pod blackbox**: restart, hết RAM, bị NetworkPolicy chặn ra (egress `envoy` ở k3d, TCP 443 công khai ở eks); chỉ một replica
   lỗi thì một nửa probe lỗi nhưng SLI vẫn đỏ.
8. **Agent Prometheus** (eks): agent không scrape hay không `remote_write` thì chuỗi cũ; lúc đó `UptimeProbesAbsent` cháy sau.
9. **NAT** (eks): blackbox ra Internet qua NAT; NAT hỏng hay hết cổng thì probe công khai đỏ, DNS nội bộ (`kube-dns`) vẫn xanh.

## Giảm thiểu

- Theo nguyên nhân tìm được: sửa dịch vụ, gia hạn cert, khôi phục bản ghi DNS (Terraform là nguồn sự thật: sửa tfvars/code rồi
  `apply`, người học chạy), mở lại target group.
- Pod blackbox lỗi (2 replica, PDB `maxUnavailable: 1`): xoá đúng pod lỗi, Deployment tạo pod mới; không xoá cả hai cùng lúc.

```sh
kubectl --context k3d-svp -n svp-obs delete pod <tên pod blackbox lỗi>
```

- Probe đỏ do chính cấu hình probe (module, URL sai sau đổi): sửa values của component `blackbox-exporter` hay chart
  `svp-observability` (GitOps: PR), không tắt cảnh báo.

## Khôi phục và xác nhận

```sh
curl -sG "$PROM/api/v1/query" --data-urlencode 'query=min by (probe) (probe_success{job="blackbox-http"})' | jq -c '.data.result[] | [.metric.probe, .value[1]]'
curl -sG "$PROM/api/v1/query" --data-urlencode 'query=slo:sli_error:ratio_rate5m{sloth_slo="public-uptime"}' | jq -c '.data.result[] | .value[1]'
```

Cả ba đích về 1, tỉ lệ lỗi 5 phút về 0, page hết trong tối đa ~30 phút (cửa sổ 30 phút), ticket lâu hơn theo cửa sổ 6 giờ và
1 ngày.

## Leo thang

- Page của SLO này mở postmortem; ghi rõ probe chung region, VPC, NAT với hệ thống và không đo từ địa lý người dùng.
- Đường công khai hỏng mà mọi bên trong xanh (CloudFront, WAF, ACM, Route 53): không có gì trong cluster để sửa; ghi vào postmortem
  và xem AWS Health của account.

## Liên kết

- Dashboard: `svp-uptime`, `svp-slo`.
- ADR: [ADR-0074](../adr/0074-cost-uptime.md) §6 đến §10 (nơi probe, module, đích, SLO), [ADR-0020](../adr/0020-reliability-stage6.md) §3.
- Diễn tập, đo: chưa có diễn tập làm cảnh báo này cháy; bước `uptime-cost` của `verify.yml` kiểm probe xanh trên k3d và compose.
