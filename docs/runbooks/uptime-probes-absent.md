# UptimeProbesAbsent

- Severity: `page`. Rule viết tay, nhóm `svp-uptime` của `deploy/observability/prometheus/rules/svp-alerts.yaml`.
- Chuẩn bị biến `PROM`, `AM`, hàm `dc`: [README](README.md#chuẩn-bị-trong-terminal). Trên eks, Prometheus là AMP: truy vấn qua
  Grafana của env (Explore, data source `prometheus`).

## Ý nghĩa và tác động tới người dùng

Không có chuỗi `probe_success{job="blackbox-http"}` nào trong 5 phút (`absent_over_time`), liền 5 phút nữa (`for: 5m`). Nghĩa là
**uptime không còn được đo**: SLO `public-uptime` không có tỉ lệ nên cũng không cảnh báo, dù người dùng có tới được hay không
([ADR-0074](../adr/0074-cost-uptime.md) §10).

Rule chạy ở ruler của AMP, ngoài cluster, nên cháy cả khi cluster chết, agent Prometheus chết hay pod blackbox chết. Compose
(`OBS=lgtm`) có blackbox nên cũng có cảnh báo này.

**Có thể cháy vài phút lúc dựng hay gỡ buổi và không có nghĩa gì.** Luật ở AMP được tạo trước khi probe chạy, và bị xoá ở
`pre-destroy.sh` của buổi; trong khoảng giữa hai mốc đó mà blackbox chưa lên (dựng) hay đã bị gỡ trước khi luật bị xoá (gỡ), chuỗi vắng
và cảnh báo cháy. Cháy quá ~15 phút sau khi `apply` xong, hay cháy giữa buổi, mới là sự cố thật.

Người dùng: chưa chắc thấy gì. Đây là cảnh báo về công cụ đo, không phải về dịch vụ; nhưng khi nó cháy thì không biết dịch vụ
có lỗi hay không, nên xem như dịch vụ chưa được kiểm tới khi probe về.

## Kiểm tra nhanh (5 phút)

Compose:

```sh
curl -sG "$AM/api/v2/alerts" --data-urlencode 'filter=alertname="UptimeProbesAbsent"' | jq -c '.[] | [.labels.severity, .status.state, .startsAt]'
curl -sG "$PROM/api/v1/query" --data-urlencode 'query=count by (job) (up)' | jq -c '.data.result[] | [.metric.job, .value[1]]'
curl -sG "$PROM/api/v1/targets" | jq -c '.data.activeTargets[] | select(.scrapePool|test("blackbox")) | [.scrapePool, .health, .lastError]'
make ps
```

Container blackbox exporter của profile `obs` không chạy (`make ps`) hay target `blackbox-http` `down` → xem `make logs SVC=<tên service
blackbox ở deploy/compose/compose.yaml>`.

k3d:

```sh
kubectl --context k3d-svp -n svp-obs get pods -l app.kubernetes.io/name=prometheus-blackbox-exporter
kubectl --context k3d-svp -n svp-obs get probes.monitoring.coreos.com
kubectl --context k3d-svp -n svp-obs logs -l app.kubernetes.io/name=prometheus-blackbox-exporter --since=15m --tail=200
curl -sG "$PROM/api/v1/targets" | jq -c '.data.activeTargets[] | select(.scrapePool|test("uptime|blackbox")) | [.scrapePool, .health, .lastError]'
kubectl --context k3d-svp -n argocd get applications.argoproj.io blackbox-exporter svp-observability
```

eks (người học chạy; `<env>` là `stg` hay `prd`):

```sh
kubectl --context svp-<env> -n svp-obs get pods
kubectl --context svp-<env> -n svp-obs get probes.monitoring.coreos.com
kubectl --context svp-<env> -n svp-obs logs -l app.kubernetes.io/name=prometheus-blackbox-exporter --since=15m --tail=200
kubectl --context svp-<env> -n argocd get applications.argoproj.io blackbox-exporter-public svp-observability kube-prometheus-stack
```

Lệnh nào trên eks không trả lời (API server, kubeconfig hết hạn) thì cluster chết hay đường tới nó mất; xem
[argocd-application-degraded.md](argocd-application-degraded.md) và log EKS của account. Trên Grafana của env, `up` của job agent và
dashboard `svp-uptime` cho biết chuỗi nào còn.

Đọc kết quả:

- Pod blackbox không có hay `CrashLoopBackOff` → nguyên nhân 3 hay 4 dưới.
- Pod blackbox chạy, không có `Probe` → chart `svp-observability` chưa render `Probe` (value `probes` rỗng hay Application chưa sync).
- `Probe` có, pod chạy mà target `down` với `lastError` → Prometheus không tới được blackbox 9115 (NetworkPolicy) hay blackbox
  không ra được đích.
- Mọi chuỗi vắng, cả `up` → agent Prometheus (eks) hay remote_write tới AMP hỏng, hay cluster chết.

## Nguyên nhân thường gặp

1. **Đang dựng hay gỡ buổi**: luật ở AMP có trước probe hay sau probe (xem trên); cháy tự hết khi blackbox lên, hay khi
   `pre-destroy.sh` xoá luật.
2. **Cluster chết hay không tới được** (eks): node hay control plane hỏng; hoặc buổi đã `destroy` mà `pre-destroy.sh` chưa xoá luật ở AMP.
3. **Pod blackbox chết**: restart lặp, hết RAM, image không kéo được (mirror ECR), Kyverno từ chối.
4. **Application blackbox không sync** (Argo CD): component `blackbox-exporter` (k3d) hay `blackbox-exporter-public` (eks) lỗi hoặc
   chưa tới wave 4.
5. **Agent Prometheus hay `remote_write` lỗi** (eks): agent không scrape, danh tính Pod Identity của agent bị từ chối, AMP từ
   chối ghi. Mọi metric vắng, không chỉ probe.
6. **NetworkPolicy**: Prometheus không vào được blackbox 9115 (policy `blackbox` của chart `svp-observability`).
7. **NAT hỏng** (eks): blackbox sống nhưng không probe được, `probe_success` có giá trị 0 chứ không vắng, nên nguyên nhân này làm
   [public-uptime-budget-burn.md](public-uptime-budget-burn.md) cháy chứ không phải cảnh báo này.
8. **Compose**: stack không lên theo profile `obs`, hay đổi `OBS` (một bộ observability mỗi lúc).

## Giảm thiểu

- Đang dựng hay gỡ buổi: chờ; nếu luật AMP còn mà buổi đã gỡ, chạy bước dọn luật của buổi (`pre-destroy.sh`, người học chạy).
- Pod blackbox lỗi: xoá đúng pod lỗi (còn pod kia Ready) để Deployment tạo lại; Application không sync: sync lại qua Argo CD
  (`make k8s-ui-argocd`) hay sửa theo [argocd-application-degraded.md](argocd-application-degraded.md).
- Compose: `make up OBS=lgtm`.

## Khôi phục và xác nhận

```sh
curl -sG "$PROM/api/v1/query" --data-urlencode 'query=count by (probe) (probe_success{job="blackbox-http"})' | jq -c '.data.result[] | [.metric.probe, .value[1]]'
curl -sG "$AM/api/v2/alerts" --data-urlencode 'filter=alertname="UptimeProbesAbsent"' | jq -c '.[] | [.labels.severity, .status.state]'
```

Ba đích `web`, `api`, `media` có chuỗi, cảnh báo resolve sau chu kỳ đánh giá kế tiếp (ruler AMP đánh giá mỗi
`rules.amp.interval` của chart: 15 giây ở prd, 30 giây ở stg).

## Leo thang

- Cháy giữa buổi và không tìm thấy nguyên nhân trong cluster (eks): coi như cluster hay agent chết, xem
  [argocd-application-degraded.md](argocd-application-degraded.md); khi đã khôi phục, ghi vào postmortem khoảng thời gian không đo.
- Không mở postmortem riêng cho lần cháy lúc dựng hay gỡ buổi.

## Liên kết

- Dashboard: `svp-uptime`.
- ADR: [ADR-0074](../adr/0074-cost-uptime.md) §6, §10, [ADR-0063](../adr/0063-managed-observability.md) §5 (luật ở AMP).
- Diễn tập, đo: chưa có diễn tập làm cảnh báo này cháy; bước `uptime-cost` của `verify.yml` kiểm cảnh báo không cháy khi probe sống.
