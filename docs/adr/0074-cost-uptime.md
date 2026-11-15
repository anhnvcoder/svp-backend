# 0074. Chi phí compute theo namespace và service bằng OpenCost với giá on-demand công khai, đọc Prometheus của k3d hay AMP của eks; uptime từ ngoài vào bằng blackbox exporter trong cluster probe qua domain công khai, SLO và cảnh báo ở ruler AMP; không dịch vụ AWS tính tiền mới

- Trạng thái: Chấp nhận
- Ngày: 2026-11-15
- Người quyết: người học (2026-11-14: làm theo chuẩn ngành, chart chính thức ghim version, AI tự quyết thiết kế), AI đề xuất thiết kế
  theo tài liệu và mã nguồn ở tag đã ghim

## Bối cảnh và vấn đề

- Chi phí thật của stg, prd chỉ có ở Cost Explorer theo tag và dịch vụ ([0060](0060-org-detection-logging.md)): không biết namespace hay service nào
  dùng phần nào của node. Cluster sống một buổi vài giờ rồi destroy; metric sống qua destroy ở AMP ([0063](0063-managed-observability.md)).
- Mọi cảnh báo hiện có đo từ trong hệ thống (metric của service, của Envoy): khi DNS, CloudFront, WAF, ALB hay cert hỏng thì người dùng thấy lỗi mà
  không SLO nào đỏ. Không gì báo cert sắp hết hạn.
- Ràng buộc: repo public; AI không chạy lệnh chạm account; k3d, compose miễn phí và gần như tương thích cloud; một công cụ chính mỗi mảng; dịch vụ AWS
  tính tiền theo luật cờ của [0071](0071-paid-features.md); khác biệt nền tảng là dữ liệu ở `svp-gitops`; máy 16 GB.

## Yếu tố quyết định

- Số chi phí ra từ dữ liệu có sẵn (Prometheus của k3d, AMP của eks) và giá có nguồn; không quyền IAM ngoài đọc AMP.
- Probe đi đúng đường người dùng đi; mất probe cũng là cảnh báo; một công cụ và một cách viết luật trên compose, k3d, eks.
- Chi phí mỗi buổi và tháng không buổi dưới ngưỡng cờ của 0071 §7; không tài nguyên sống lâu mới.

## Phương án đã cân nhắc

Trạng thái ngành, được, mất, nguồn, chi phí theo trang giá có ngày đọc: [phụ lục](appendix/0074-cost-uptime.md#phương-án). In đậm là lựa chọn.

- Chi phí: **OpenCost** (dự án CNCF mức Incubating [N14]); Kubecost (sản phẩm đóng của IBM xây trên OpenCost, bản miễn phí giới hạn số
  core và thời gian giữ metric [N15]).
- Giá node: **giá on-demand công khai mà OpenCost tự tải**; Spot Data Feed (bucket S3, giao theo giờ); Spot Price History (quyền
  `ec2:DescribeSpotPriceHistory`); CUR qua Athena (`cloudCost`; Data Exports giao lần đầu tới 24 giờ, làm mới mỗi ngày [N38]).
- Nơi probe: CloudWatch Synthetics; Route 53 health check; Grafana Cloud Synthetic Monitoring; blackbox ở nơi khác (EC2 ở region khác);
  **blackbox trong cluster probe qua domain công khai**.

## Kết quả quyết định

Chọn các phương án in đậm, vì chúng dùng lại AMP, ruler, Alertmanager, dashboard và Pod Identity đã có, chạy giống nhau trên ba nền tảng và
không thêm dịch vụ tính tiền. Giá trị đủ từng §, trích nguồn: phụ lục, cùng số §.

### 1. OpenCost: Component opencost và Bản ghim

- Application `opencost` của `argocd/apps/components.json` (`svp-gitops`), namespace `svp-obs`, wave 8 (sau các service: chưa Ready khi chưa tới được
  Prometheus, wave sớm hơn thì chặn mọi service), mọi nền tảng, values `base/opencost.yaml`. Chart `opencost` 2.5.34 (app 1.121.4, image có digest trong chart); chart
  `prometheus-blackbox-exporter` 11.21.3 (app v0.29.1); sidecar `aws-sigv4-proxy` của AWS từ ECR Public, ghim digest theo luật hiện có.
- Một replica: không nằm trên đường cảnh báo page, khởi động lại thì đọc lại Prometheus. UI, MCP tắt: xem chi phí ở Grafana và API cổng 9003.
  Pod Security `restricted`. ServiceMonitor của chart bật, giữ `honorLabels: true` mặc định [N1]: label `namespace`, `pod`, `container` của
  metric OpenCost thắng label của target.
- `emitKsmV1Metrics: false`: tài liệu OpenCost khuyên tắt khi đã có kube-state-metrics v2 để không trùng series [N10]. Ba metric thô mà §5 dùng
  không đọc metric KSM: request lấy từ cache Kubernetes API, mức dùng từ cAdvisor, giá từ provider [N5], [N6]. API Allocation, Assets của OpenCost
  đọc vài tên KSM v1 (`kube_node_status_capacity_cpu_cores`…) mà chỉ OpenCost phát [N8], [N12]: phần idle, capacity của API đó sai; không gì đọc API.
- `resources` của container `opencost`: request `cpu: 10m`, `memory: 256Mi`, limit `memory: 1Gi`. Tệp giá EC2 của region được parse theo
  luồng, chỉ giữ giá loại node đang có [N3], nên RAM không theo cỡ tệp; RAM tăng gần tuyến tính theo số container [N13]. Cỡ tệp, số đo và
  cách tính: phụ lục §1.

### 2. Nguồn Prometheus của OpenCost

- k3d: Service `kps-prometheus` namespace `svp-obs` cổng 9090. eks: chế độ AMP của chart (`amp.enabled`, `workspaceId` = `cluster.ampWorkspaceId`):
  chart thêm container `sigv4proxy` (tên cố định trong template; `sigV4Proxy.name: aps` là tên dịch vụ để ký SigV4) và trỏ OpenCost tới
  `http://localhost:8005/workspaces/<id>` [N2]; `region`, `host` theo `cluster.region`, không `role_arn`.
- Credential của sidecar từ Pod Identity: cluster thêm biến của container credential provider vào pod [N16]; SDK Go của proxy mới hơn bản
  tối thiểu Pod Identity cần [N17], [N18] (version: phụ lục §2). Vì sao proxy: OpenCost không ký SigV4; chế độ AMP của chart là đường
  chính thức. Cái giá: một image thêm.
- `defaultClusterId`: k3d `svp-k3d`, eks `cluster.name`.

### 3. Giá

- eks: OpenCost tải `pricing.us-east-1.amazonaws.com/offers/v1.0/aws/AmazonEC2/current/<region>/index.json` không credential [N11], [N3]; k3d: giá
  mặc định của OpenCost (provider `custom` [N36]). Không `customPricing`, không Spot Data Feed, không CUR (`cloudCost.enabled: false`): cluster
  sống một buổi, export CUR có tới 24 giờ sau và làm mới mỗi ngày [N38], feed giao theo giờ [N11], nên đối soát không chạy khi cluster còn; chi
  phí thật đã ở Cost Explorer.
- Node Spot (nhãn `karpenter.sh/capacity-type: spot`) được nhận là preemptible; không feed thì OpenCost gọi `DescribeSpotPriceHistory`, bị từ chối
  vì role không có quyền (lỗi được nhớ 1 giờ), rồi lấy **giá on-demand** công khai (`createNode`, `pkg/cloud/aws/provider.go` [N3], [N4]).
- Cái giá: số của node Spot ở stg là trần (giá on-demand), không phải giá đã trả; prd on-demand khớp giá niêm yết; không gồm Savings Plans, giảm giá,
  EBS, mạng, dịch vụ managed. Mỗi loại node mới (Karpenter) làm OpenCost tải lại tệp giá [N3]: thêm dữ liệu NAT (§11).

### 4. Danh tính OpenCost

Khoá `opencost` trong `local.pod_identity` của `aws/modules/eks/pod-identity.tf` (`svp-infra`, namespace `svp-obs`, ServiceAccount `opencost`), role
`<cluster>-opencost` ở `iam.tf`: `aps:QueryMetrics`, `aps:GetSeries`, `aps:GetLabels`, `aps:GetMetricMetadata` trên workspace của env (bốn hành
động đọc của policy AWS `AmazonPrometheusQueryAccess`, hẹp về một workspace). Không quyền giá, EC2, S3: mọi gọi API AWS khác của OpenCost bị từ chối.

### 5. Chi phí compute và dashboard

- Metric của OpenCost [N9], [N5]: `container_cpu_allocation`, `container_memory_allocation_bytes` (label `namespace`, `pod`, `container`, `node`;
  giá trị là max của request và mức dùng [N6]); `node_cpu_hourly_cost`, `node_ram_hourly_cost`, `node_total_hourly_cost` (label `node`; USD mỗi
  giờ mỗi vCPU, mỗi GiB, mỗi node). Khớp với recording rule.
- Nhóm `svp-cost` của `svp-alerts.yaml`: `namespace:svp_compute_cost_usd_per_hour:sum`, `service:svp_compute_cost_usd_per_hour:sum` (namespace `svp`,
  `service` lấy từ `container`), `cluster:svp_node_cost_usd_per_hour:sum`. Chỉ CPU, RAM được cấp phát; idle là cluster trừ tổng namespace.
- Dashboard `svp-cost.json` (uid `svp-cost`) chỉ đọc ba recording rule; compose không có OpenCost nên dashboard trống ở đó.

### 6. Nơi probe

- blackbox exporter chạy trong cluster (và compose), probe qua đường người dùng đi: DNS công khai → CloudFront (WAF) → ALB → Envoy trên eks; Envoy của
  Gateway `svp` trên k3d; service trong mạng compose. Luật đánh giá ở ruler AMP, ngoài cluster.
- Vì sao: không dịch vụ, không tiền mới, một công cụ ở mọi nền tảng; luật, SLO, Alertmanager, dashboard dùng lại. CloudWatch Synthetics mỗi buổi
  ~$1,05–1,22 mỗi env, chạm ngưỡng cờ của 0071 §7; ba phương án còn lại thêm công cụ hay máy thứ hai (bảng: phụ lục §6).
- Cái giá: probe chung region, VPC, NAT với hệ thống; không đo từ địa lý người dùng; cluster chết thì probe chết theo. Bù bằng **Cảnh báo mất
  probe** (§10) ở ruler AMP, vẫn chạy khi cluster mất. Bot Control của web đang chỉ đếm ([0061](0061-edge-cloudfront-waf-acm.md)): bật chặn thì
  probe (User-Agent `svp-uptime-probe`, không trình duyệt) có thể bị chặn.

### 7. blackbox exporter và Module probe

- Hai Application cùng chart, namespace `svp-obs`, wave 4: `blackbox-exporter` chỉ k3d (values `base/blackbox-exporter.yaml`, ba module
  `http_local_*`), `blackbox-exporter-public` chỉ eks (`base/blackbox-exporter-public.yaml` và `.values.tpl` của eks: `http_public`, `dns_*`). Cả
  hai `fullnameOverride: blackbox-exporter` (Service cổng 9115), 2 replica, PDB `maxUnavailable: 1`, trải zone, ServiceMonitor riêng của chart tắt.
- Mọi module HTTP: IPv4, chỉ 200, không theo redirect, User-Agent `svp-uptime-probe`. eks `http_public` kiểm TLS bằng CA hệ thống; `dns_web`,
  `dns_api`, `dns_media` hỏi bản ghi A, chỉ nhận `NOERROR`.
- k3d `http_local_*`: SNI và `Host` của từng listener, `insecure_skip_verify: true`: cert listener do cert-manager ký bằng CA sinh trong cluster,
  không có bản ở `svp-obs`. `probe_ssl_earliest_cert_expiry` vẫn có: blackbox lấy hạn từ cert peer khi có kết nối TLS, không xét chuỗi đã kiểm [N19].
  Cái giá: probe k3d không kiểm chuỗi tin cậy; eks kiểm đủ, không module nào bỏ kiểm. Compose `http_compose` (HTTP thường).

### 8. Đích probe, Probe của chart, Service Envoy

- Đích `web` (`/healthz` của web), `api` (`/readyz` của gateway), `media` (object `media/uptime-probe.txt`, `Cache-Control: no-store`, trong bucket
  media; eks `aws/modules/media/uptime-probe.tf`, local `deploy/s3/init.sh`). Nhãn `probe` của chuỗi là tên đích.
- Chart `svp-observability` thêm value `probes`: một CR `Probe` mỗi đích, job `blackbox-http` (DNS `blackbox-dns`), mặc định ba đích k3d, eks đặt URL
  công khai qua `platforms/eks/svp-observability.values.tpl`. `PrometheusAgent` đọc `probeSelector` như `Prometheus` [N21], [N22].
- Service của đội Envoy tên cố định `svp-envoy` ở mọi nền tảng (mặc định chart `svp-cluster`): k3d probe
  `https://svp-envoy.envoy-gateway-system.svc.cluster.local`; drill OPS-2 khớp Service theo namespace, kiểu và nhãn thay tên sinh.

### 9. NetworkPolicy

Chart `svp-observability`: blackbox vào từ Prometheus 9115, ra pod Envoy cổng listener HTTPS (`egress: envoy`) hay TCP 443 tới IPv4 công khai
(`internet`, eks); OpenCost vào từ Prometheus 9003, ra Kubernetes API và `opencost.query`: `prometheus` (pod Prometheus 9090, Prometheus thêm vào từ
OpenCost) hay `amp` (endpoint AWS, Pod Identity Agent), `opencost.publicPricing` (TCP 443 IPv4 công khai cho tệp giá). Cái giá: hai pod ra Internet
qua NAT như `grafana-operator`.

### 10. SLO và cảnh báo

- SLO `public-uptime` 99,9 %, SLI `1 - avg(avg_over_time(probe_success{job="blackbox-http"}[{{.window}}]))`, cảnh báo `PublicUptimeBudgetBurn` (page
  có runbook, ticket). Probe DNS không vào SLI: cùng lỗi đã làm probe HTTP đỏ; dashboard `svp-uptime.json` và runbook dùng nó để khoanh vùng.
- Nhóm `svp-uptime`: `UptimeProbesAbsent` (`absent_over_time` 5 phút, `for: 5m`, page): bắt cluster, agent hay blackbox chết; compose có blackbox nên
  không cháy ở đó. `TLSCertExpiringSoon` (< 21 ngày, `for: 1h`, ticket), `TLSCertExpiryImminent` (< 7 ngày, `for: 15m`, page).
- 21 ngày nằm dưới mốc gia hạn của ACM (45 ngày trước hạn với cert 198 ngày, 60 ngày với cert 395 ngày cũ [N23]) và của cert-manager (còn 1/3 thời
  hạn, mặc định 90 ngày [N24]): cháy nghĩa là gia hạn đã hỏng. Luật mới vào hai file luật sẵn có, đi cùng hai `RuleGroupsNamespace` của 0063 §5.

### 11. Chi phí và cờ

- Mỗi buổi 4 giờ ~$0,09–0,17 ở stg, ~$0,09–0,18 ở prd: mẫu AMP thêm (series của OpenCost, blackbox, recording rule), dữ liệu NAT mỗi lần
  tải tệp giá EC2, request CloudFront, WAF, S3 của probe; truy vấn AMP dưới mức miễn phí. Tháng không buổi $0: không tài nguyên sống lâu mới
  (role, object probe không tính tiền đáng kể). Số mẫu, giá đơn vị, cỡ tệp và cách tính: phụ lục §11.
- Không cần cờ của 0071: không đạt điều (a) ở §7 của nó (≥ $2 tháng không buổi hay ≥ $1 mỗi buổi); phần dùng thêm thuộc AMP, NAT,
  CloudFront của mục "Không cờ" (0071 §9).

### 12. ADR cũ

Chỉnh: 0063 §5, §11; 0011 §8, §9; 0056 §6. Đã xét, không chỉnh: 0020 (SLO web, luật runbook giữ nguyên), 0055 (stg, prd chạy cùng component),
0061 (edge không đổi), 0071 (ngưỡng và mục "Không cờ" giữ nguyên).

### Hệ quả

- Tốt: chi phí compute theo namespace, service xem được trong buổi và sau destroy; uptime đo đúng đường người dùng; cảnh báo cert sắp hết hạn; mất
  probe là cảnh báo page; không dịch vụ, quyền IAM ngoài đọc AMP, tài nguyên sống lâu mới.
- Xấu: số Spot của stg là trần; không đo từ địa lý người dùng; probe k3d không kiểm chuỗi TLS; mỗi buổi dựng cluster mới `PublicUptimeBudgetBurn` page cháy chừng 30 phút, ticket theo cửa sổ 6 giờ (Probe có trước web,
  gateway; chờ, không điều tra); hai image mới (OpenCost, sigv4-proxy) và blackbox; OpenCost tải lại cả tệp giá EC2 (phụ lục §1) mỗi lần
  khởi động hay gặp loại node mới; API Allocation, Assets của OpenCost sai phần capacity khi KSM v1 tắt.
- Xem lại khi: có người dùng thật ở nhiều region hay SLA với khách (probe ngoài region); cần giá Spot thật (thêm `ec2:DescribeSpotPriceHistory`);
  dùng API hay UI của OpenCost (`emitKsmV1MetricsOnly`); cluster chạy lâu dài (CUR, `cloudCost`); Bot Control của web chuyển sang chặn.

## Xác nhận

- Kiểm tĩnh: `make helm-check` (render `Probe`, NetworkPolicy, hai component theo nền tảng), `make slo-check`, test promtool của nhóm `svp-uptime`,
  `svp-cost`, `make kyverno-test`, test mocked của role `opencost` và object probe ở `svp-infra`, `make docs-check`.
- `verify.yml`, bước `uptime-cost` ở job `gitops` (k3d) và `compose` (`compose-obs`): `probe_success` = 1 cho `web`, `api`, `media`; k3d thêm hạn cert
  > 21 ngày, `cluster:svp_node_cost_usd_per_hour:sum` > 0, chi phí namespace `svp` > 0; không `UptimeProbesAbsent` cháy. Trạng thái
  `PublicUptimeBudgetBurn` chỉ in vào bảng, không làm bước đỏ: probe lỗi lúc dựng nằm trong cửa sổ của alert.
- Buổi stg, prd: chi phí theo namespace, uptime, số mẫu AMP và dữ liệu NAT thật để thay ước lượng ở phụ lục §11.

## Hiện thực ở

- Repo này: `deploy/observability/prometheus/rules/svp-alerts.yaml`, `svp-alerts.test.yaml`, `slo-generated.yaml`,
  `deploy/observability/slo/svp-slos.yaml` (§5, §10); `deploy/observability/grafana/dashboards/svp-cost.json`, `svp-uptime.json` (§5, §10);
  `deploy/helm/svp-observability/` (`values.yaml`, `templates/probes.yaml`, `networkpolicies.yaml`, `grafana.yaml`, `ci/eks-example.yaml`; §8, §9);
  `deploy/helm/svp-cluster/values.yaml`, `deploy/k8s/drills/threats/ops-2/chainsaw-test.yaml` (§8); `deploy/observability/blackbox/blackbox.yaml`,
  `deploy/observability/prometheus/prometheus.yaml`, `deploy/compose/compose.yaml`, `deploy/s3/init.sh` (§7, §8); `.github/workflows/verify.yml`,
  `ci.yml`, `deploy/ci/verify-steps/uptime-cost.sh`, `uptime-cost-test.sh`, `steps-test.sh`, `deploy/ci/verify-collect.sh`, `verify-collect-test.sh` (Xác nhận); `renovate.json` (§7);
  `docs/runbooks/public-uptime-budget-burn.md`, `uptime-probes-absent.md`, `tls-cert-expiry-imminent.md` (§10); `docs/explanation/cost-and-uptime.md`.
- `svp-gitops`: `argocd/apps/components.json`, `argocd/project.yaml`, `renovate.json` (§1, §7); `base/opencost.yaml`, `platforms/eks/opencost.yaml`,
  `opencost.values.tpl` (§1–§3); `base/blackbox-exporter.yaml`, `base/blackbox-exporter-public.yaml`,
  `platforms/eks/blackbox-exporter-public.values.tpl` (§7); `platforms/eks/svp-observability.yaml`, `svp-observability.values.tpl` (§8, §9).
- `svp-infra`: `aws/modules/eks/pod-identity.tf`, `iam.tf`, `variables.tf`, `tests/opencost.tftest.hcl`, `tests/validation.tftest.hcl` (§4); `aws/modules/media/uptime-probe.tf`,
  `tests/uptime-probe.tftest.hcl` (§8); `docs/diagrams/`.

## Nguồn

Đọc 2026-11-15; tên đủ, trích dẫn và mọi nguồn khác ở [phụ lục](appendix/0074-cost-uptime.md#nguồn).

- OpenCost: [N1] <https://github.com/opencost/opencost-helm-chart/blob/opencost-2.5.34/charts/opencost/values.yaml>,
  [N3] <https://github.com/opencost/opencost/blob/v1.121.4/pkg/cloud/aws/provider.go>,
  [N5] <https://github.com/opencost/opencost/blob/v1.121.4/pkg/costmodel/metrics.go>,
  [N9] <https://opencost.io/docs/integrations/metrics>, [N10] <https://opencost.io/docs/installation/helm>
- blackbox, Prometheus Operator: [N19] <https://github.com/prometheus/blackbox_exporter/blob/v0.29.1/prober/tls.go>,
  [N21] <https://github.com/prometheus-operator/prometheus-operator/blob/v0.94.2/pkg/apis/monitoring/v1/prometheus_types.go>
- AWS, cert-manager: [N16] <https://docs.aws.amazon.com/eks/latest/userguide/pod-id-how-it-works.html>,
  [N23] <https://docs.aws.amazon.com/acm/latest/userguide/dns-renewal-validation.html>,
  [N24] <https://github.com/cert-manager/cert-manager/blob/v1.21.3/pkg/apis/certmanager/v1/types_certificate.go>

## Thông tin thêm

Phụ lục: [`appendix/0074-cost-uptime.md`](appendix/0074-cost-uptime.md) (phương án, giá trị đủ từng §, bảng giá, chi phí mỗi buổi và tháng không
buổi, nguồn).
