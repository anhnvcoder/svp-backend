# Phụ lục ADR-0074: Chi phí compute theo namespace và service bằng OpenCost với giá on-demand công khai, đọc Prometheus của k3d hay AMP của eks; uptime từ ngoài vào bằng blackbox exporter trong cluster probe qua domain công khai, SLO và cảnh báo ở ruler AMP; không dịch vụ AWS tính tiền mới

Phụ lục của [ADR-0074](../0074-cost-uptime.md): phương án, giá trị đủ từng §, bảng giá, chi phí mỗi buổi và tháng không buổi, nguồn. Mọi nguồn
đọc ngày 2026-11-15 (giờ Việt Nam). Đường dẫn `aws/...` là của `svp-infra`, `base/`, `platforms/` là của `svp-gitops`. Số tiền là USD; giá AWS lấy
từ Price List công khai (`pricing.us-east-1.amazonaws.com/offers/v1.0/aws/<dịch vụ>/current/...`, ngày phát hành ghi ở ô) hay trang giá; phép
tính ghi ở ô. Mã nguồn đọc ở tag ghi trong nguồn.

## Phương án

| Câu hỏi | Phương án | Trạng thái ngành | Được | Mất | Chi phí | Nguồn |
| --- | --- | --- | --- | --- | --- | --- |
| Chi phí theo workload | **OpenCost** | Hiện hành: dự án CNCF, nhận 2022-06-17, mức Incubating từ 2024-10-25 | Mở, metric Prometheus, chart chính thức, chế độ AMP | Một image, một sidecar; số là ước lượng theo giá niêm yết | §11 | [N14], [N1] |
| Chi phí theo workload | Kubecost | Hiện hành (sản phẩm của IBM, xây trên OpenCost) | Đối soát hoá đơn, gợi ý tối ưu | Bản miễn phí "up to 250 cores", "15-day metric retention"; sản phẩm đóng, công cụ thứ hai | 0 ở bậc miễn phí | [N15] |
| Giá node | **Giá on-demand công khai OpenCost tự tải** | Hiện hành (mặc định của OpenCost trên AWS) | Không credential, không bucket | Node Spot tính theo giá on-demand (trần); tệp ~357 MB mỗi lần tải | NAT §11 | [N11], [N3] |
| Giá node | Spot Data Feed | Hiện hành (tính năng EC2) | Giá Spot đã trả theo instance | Bucket S3, quyền đọc bucket; feed "on an hourly basis": buổi vài giờ chỉ có vài lần giao | Lưu trữ S3 nhỏ | [N11] |
| Giá node | Spot Price History | Hiện hành (đường OpenCost tự thử khi không feed) | Giá Spot hiện tại theo AZ, loại node; cache 1 giờ | Quyền `ec2:DescribeSpotPriceHistory`; giá thị trường, không phải giá đã trả | 0 | [N3], [N4] |
| Giá node | CUR qua Athena (`cloudCost`) | Hiện hành (đối soát hoá đơn) | Giá thật, có giảm giá | Export có tới 24 giờ sau, làm mới mỗi ngày: không kịp trong buổi; Athena, bucket, quyền | Athena, S3 | [N38] |
| Nơi probe | CloudWatch Synthetics | Hiện hành (AWS native) | Ngoài cluster; chọn region | Công cụ thứ hai (script canary), cảnh báo qua CloudWatch alarm, không chạy ở k3d, compose | ~1,05–1,22 mỗi buổi mỗi env; ~223 mỗi tháng nếu chạy liền | [N26], [N27] |
| Nơi probe | Route 53 health check | Hiện hành (cho DNS failover) | Checker ở nhiều region của AWS; rẻ | Chỉ khoẻ, không khoẻ: không hạn cert, không thời lượng pha; cảnh báo đường riêng; không chạy local | ~0,016 mỗi buổi; 3 mỗi tháng nếu chạy liền | [N28] |
| Nơi probe | Grafana Cloud Synthetic Monitoring | Hiện hành (SaaS) | Ngoài AWS, nhiều điểm probe | Account, token bên thứ ba; metric ở Grafana Cloud, không ở AMP; cảnh báo riêng | 0 trong bậc miễn phí; ~166 mỗi tháng nếu chạy liền | [N29] |
| Nơi probe | blackbox ở nơi khác (EC2 ở region khác) | Hiện hành (mẫu nhiều điểm probe) | Cùng công cụ; sống khi cluster chết | Một máy, một root Terraform, vá, credential ghi chéo region; tài nguyên sống lâu | ~0,042 mỗi buổi; ~7,6 mỗi tháng nếu chạy liền, chưa EBS | [N30], [N31] |
| Nơi probe | **blackbox trong cluster qua domain công khai** | Hiện hành (blackbox exporter + CR `Probe` của Prometheus Operator) | Một công cụ ở ba nền tảng; dùng lại AMP, ruler, Alertmanager | Chung region, VPC, NAT; không đo từ địa lý người dùng | ~0,015 mỗi buổi | [N19], [N21] |

## §1. OpenCost: Component opencost và Bản ghim

- Chart `opencost` 2.5.34 (tag `opencost-2.5.34` của `opencost/opencost-helm-chart`, `appVersion: "1.121.4"`), image
  `ghcr.io/opencost/opencost:1.121.4@sha256:daa04ae…` ghim trong `values.yaml` của chart [N1]. Chart `prometheus-blackbox-exporter` 11.21.3
  (`appVersion: v0.29.1`) có khoá `replicas`, `podDisruptionBudget`, `topologySpreadConstraints`, `config`, `serviceMonitor` [N37].
  `aws-sigv4-proxy`: bản phát hành mới nhất trên GitHub là v1.13.1 (2026-10-09) [N18]; chart mặc định `:latest` [N1], nên `svp-gitops` ghim digest.
- Mặc định chart đáng chú ý [N1]: `opencost.ui.enabled`, `opencost.mcp.enabled` bật; `replicas: 1`; `resources.requests` `cpu: '10m'`,
  `memory: '55Mi'`, `limits` `memory: '1Gi'`; `metrics.serviceMonitor.enabled: false`, `honorLabels: true`, `scrapeInterval: 30s`;
  `emitKsmV1Metrics: ~` (biến `EMIT_KSM_V1_METRICS` mặc định `true` trong code [N7]).
- `emitKsmV1Metrics: false`: tài liệu cài Helm: "To avoid duplicate metrics from v2 KubeStateMetrics running in your cluster and v1
  KubestateMetrics from OpenCost, configure ... `emitKsmV1Metrics: false`, `emitKsmV1MetricsOnly: false`" [N10]. Khi tắt, OpenCost chỉ còn
  collector PV [N7].
- Metric của §5 không phụ thuộc KSM: `ComputeCostData` lấy pod từ cache Kubernetes API và chỉ hỏi Prometheus mức dùng RAM, CPU (cAdvisor
  `container_memory_working_set_bytes`, `container_cpu_usage_seconds_total`) và mạng [N6]; giá node từ provider, node từ cache [N5]. Phần dễ sai:
  querier đọc `kube_node_status_capacity_cpu_cores`, `kube_node_status_capacity_memory_bytes`, `kube_node_status_allocatable_*_cores|bytes`
  (`QueryNodeCPUCoresCapacity`, `QueryNodeRAMBytesCapacity`…), `kube_pod_labels`, `kube_namespace_labels` [N8]; kube-state-metrics v2 phát
  `kube_node_status_capacity{resource="cpu"}`, không phát tên v1, nên API Assets, idle của OpenCost thấy capacity 0 (issue #3477; người bảo trì:
  "Opencost writes all of the metrics it requires to avoid compatibility problems" [N12]). Xem lại khi cần API: `emitKsmV1MetricsOnly: true`
  phát thêm collector node, namespace, pod label, PV [N7].
- `resources`: request `cpu: 10m` (chart; emitter chạy mỗi phút [N5]), `memory: 256Mi`, limit `memory: 1Gi` (chart), không limit CPU (chart).
  Cách tính RAM: đo trên một cluster 100 node, 25 000 pod: "Opencost+Prometheus uses about 200MB of memory, plus an extra 0.5MB for each
  container", "usage is more or less linear with cluster size" [N13]; ~250 container ở stg ⇒ ~200 + 125 = ~325 MB cho cả OpenCost lẫn Prometheus,
  OpenCost riêng thấp hơn: request 256Mi. Tệp giá: `Content-Length: 356848755` (`curl -sI` URL `…/AmazonEC2/current/ap-southeast-1/index.json`,
  `Last-Modified` 2026-11-14) [N35]; `populatePricing` đọc bằng `json.Decoder.Token` theo luồng, chỉ lưu giá của loại node có trong cluster
  ("Only store pricing for instances we actually have in the cluster") cùng tập khoá hợp lệ [N3]: RAM không theo cỡ tệp, limit 1Gi của chart đủ chỗ.

## §2. Nguồn Prometheus của OpenCost

- Chế độ AMP [N2]: `opencost.prometheusServerEndpoint` = `printf "http://localhost:%d/workspaces/%v" sigV4Proxy.port amp.workspaceId`; container
  `- name: sigv4proxy`, đối số `--name {{ sigV4Proxy.name }}` (mặc định `aps`), `--region`, `--host`, `--port :8005`, `--role-arn` chỉ khi có
  `role_arn`; chart `fail` khi bật hơn một trong `internal`, `external`, `amp` [N2]. `PROMETHEUS_SERVER_ENDPOINT` đặt bằng helper đó.
- OpenCost kiểm Prometheus lúc khởi động bằng truy vấn `up`; `Buildinfo` lỗi không chặn ("we don't consider this a fatal error") [N3 module
  `prometheus-source`, `datasource.go`].
- Pod Identity: "the cluster adds the following content to the Pod manifest: `AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE`,
  `AWS_CONTAINER_CREDENTIALS_FULL_URI`" [N16]; Go v1 tối thiểu "v1.47.11" [N17]; `aws-sigv4-proxy` v1.13.1 dùng `github.com/aws/aws-sdk-go
  v1.55.8` [N18]. Container `opencost` cũng nhận credential: mọi gọi API AWS ngoài AMP bị từ chối (§4).
- k3d: `opencost.prometheus.internal` `serviceName: kps-prometheus`, `namespaceName: svp-obs`, `port: 9090`; mặc định chart (`prometheus-server`,
  `prometheus-system`, 80) không khớp stack.

## §3. Giá

- URL: `awsPricingBaseURL` = `https://pricing.us-east-1.amazonaws.com/offers/v1.0/aws/`, thêm `AmazonEC2/current/<region>/index.json` khi mọi node
  cùng region [N3]; tài liệu: "it will attempt to pull the AWS on-demand pricing from the configured public API URL with no further configuration
  required" [N11]. k3d không có `providerID` AWS: provider `custom`, `configs/default.json` "Default prices based on GCP us-central1" (CPU 0,031611,
  RAM 0,004237 mỗi giờ) [N36].
- Node Spot: `getUsageType` trả preemptible khi nhãn `karpenter.sh/capacity-type` là `spot` (hay `eks.amazonaws.com/capacityType: SPOT`) [N3].
  `createNode`: không có feed thì "Try to get spot pricing from DescribeSpotPriceHistory API"; không được thì "falling back to on-demand pricing",
  giữ `UsageType: preemptible`; chỉ khi không có giá công khai mới dùng `spotCPU`, `spotRAM` mặc định [N3]. Lỗi của `DescribeSpotPriceHistory` được
  nhớ (`Error // Negative cache`), làm mới sau `SpotPriceHistoryCacheAge = 1 * time.Hour` [N4]. Credential: không key thì
  `config.LoadDefaultConfig` (chuỗi mặc định, có Pod Identity) [N3].
- Tải lại: lúc khởi động (`router.go`) và trong `NodePricing` khi khoá của node có trong `ValidPricingKeys` mà chưa có trong `Pricing`, tức mỗi loại
  node mới vào cluster [N3].

## §4. Danh tính OpenCost

Bốn hành động `aps:QueryMetrics`, `aps:GetSeries`, `aps:GetLabels`, `aps:GetMetricMetadata` là phần đọc của `AmazonPrometheusQueryAccess`, như
Rollouts chỉ `aps:QueryMetrics` ([0063](../0063-managed-observability.md) §11). Khuôn tên `<cluster>-<khoá>` và trust một cặp namespace,
ServiceAccount theo `local.pod_identity` sẵn có của `aws/modules/eks/pod-identity.tf`.

## §5. Chi phí compute và dashboard

- Tài liệu metric: `container_cpu_allocation` "CPU allocation over last 1m", cores, label "container, node, namespace, pod";
  `container_memory_allocation_bytes` bytes; `node_cpu_hourly_cost` "Hourly cost per vCPU", `node_ram_hourly_cost` "Hourly cost per GiB of memory",
  `node_total_hourly_cost`, label "node, instance, provider_id", USD/hour [N9].
- Mã nguồn [N5]: node `[]string{"instance", "node", "instance_type", "region", "provider_id", "arch", "uid"}`; container `[]string{"namespace", "pod",
  "container", "instance", "node", "uid"}`; emitter chạy mỗi phút (`time.After(time.Minute)`), cửa sổ `METRICS_EMITTER_QUERY_WINDOW` mặc định
  2 phút. Giá trị allocation: "getContainerAllocation takes the max between request and usage" [N6].
- `honorLabels: true` của ServiceMonitor giữ `namespace`, `pod`, `container`, `instance` của OpenCost; tắt thì label target (`svp-obs`, pod OpenCost)
  thắng và label gốc thành `exported_*`, recording rule nhóm sai.

## §6. Nơi probe

Bảng giá ở §11. Ghi chú từng phương án không chọn:

- CloudWatch Synthetics: "Canaries can run as often as once per minute" [N27]; `APS1-CW:Canary-runs` $0,0017 mỗi lượt, `Global-CW:Canary-runs`
  100 lượt đầu mỗi tháng 0 [N26]. Ba canary mỗi phút trong buổi 4 giờ: 3 × 60 × 4 = 720 lượt; buổi đầu tháng (720 − 100) × 0,0017 = 1,05; buổi
  sau 720 × 0,0017 = 1,22; chưa gồm Lambda, S3, log của canary. Chạy liền: 3 × 43 800 = 131 400 lượt, (131 400 − 100) × 0,0017 ≈ 223 mỗi tháng.
- Route 53 health check: "An AWS endpoint is a resource running within AWS ... provisioned within the same AWS account", 50 health check đầu của
  AWS endpoint miễn phí; tính năng tuỳ chọn (HTTPS, string matching) $1,00 mỗi tháng mỗi tính năng; "prorated for partial months" [N28]. Ba check
  HTTPS: 3 × 1 × 4/730 ≈ 0,016 mỗi buổi; chạy liền 3 mỗi tháng.
- Grafana Cloud Synthetic Monitoring: miễn phí "100k API test executions ... per month"; Pro "$19 per month" kèm 100k, rồi "$5 / 10k API test
  executions" [N29]. Ba check mỗi phút từ ba điểm: 3 × 3 × 240 = 2 160 mỗi buổi (0); chạy liền 3 × 3 × 43 800 = 394 200, 19 + (394 200 − 100 000)
  / 10 000 × 5 ≈ 166 mỗi tháng.
- blackbox trên EC2 ở Tokyo: `t4g.nano` $0,0054 mỗi giờ (phát hành 2026-11-14) [N30], IPv4 công khai $0,005 mỗi giờ [N31]: 0,0104 mỗi giờ, 0,042 mỗi
  buổi, 730 × 0,0104 ≈ 7,6 mỗi tháng nếu sống liền để bắt cluster chết; chưa EBS, dữ liệu.
- Bot Control của web ở chế độ đếm ([0061](../0061-edge-cloudfront-waf-acm.md) phụ lục, Bot Control `COMMON`): probe không phải trình duyệt nên có
  thể mang nhãn bot; khi chuyển chặn cần ngoại lệ cho probe trước.

## §7. blackbox exporter và Module probe

- Khoá module của blackbox v0.29.1 [N20]: `follow_redirects` (mặc định `true`), `fail_if_not_ssl` (mặc định `false`), `preferred_ip_protocol`
  (mặc định `ip6`, nên đặt `ip4`), `tls_config.insecure_skip_verify`, `tls_config.server_name`; DNS `valid_rcodes`, `validate_answer_rrs`
  (`fail_if_none_matches_regexp`…).
- Hạn cert khi bỏ kiểm chuỗi [N19]: `if resp.TLS != nil { … probeSSLEarliestCertExpiryGauge.Set(float64(getEarliestCertExpiry(resp.TLS).Unix())) }`;
  `getEarliestCertExpiry` duyệt `state.PeerCertificates`, không đọc `VerifiedChains`. `probe_ssl_last_chain_expiry_timestamp_seconds` đọc chuỗi đã
  kiểm nên không dùng ở k3d.

## §8. Đích probe, Probe của chart, Service Envoy

- `PrometheusAgentSpec` nhúng `monitoringv1.CommonPrometheusFields` (`json:",inline"`) [N21]; `ProbeSelector *metav1.LabelSelector` nằm trong
  `CommonPrometheusFields` [N21]. Template `prometheus.yaml` của `kube-prometheus-stack` 92.17.1 (operator v0.94.2) render `probeSelector`,
  `probeNamespaceSelector` ở cả chế độ agent (khối không nằm trong `if not agentMode`) [N22]; `probeSelectorNilUsesHelmValues: false` ở `base/`.
- Object probe media `Cache-Control: no-store`: mỗi probe là một GET tới S3 qua CloudFront (§11).

## §9. NetworkPolicy

Peer, cổng đủ: ADR §9 và `deploy/helm/svp-observability/templates/networkpolicies.yaml` (nguồn sự thật). Tệp giá và
`pricing.us-east-1.amazonaws.com` không có endpoint interface trong VPC ([0064](../0064-interface-endpoints.md) §6 giữ đích ngoài AWS qua NAT).

## §10. SLO và cảnh báo

- ACM: "At 45 days prior to expiration, ACM checks for the following renewal criteria"; "Previously issued certificates with a 395-day validity
  period renew 60 days before expiration and receive a renewed validity period of 198 days. Certificates with a 198-day validity period renew 45
  days before expiration"; sự kiện khi không tự kiểm được "at 30 days, 15 days, seven days, three days, and one day prior to expiration" [N23].
- cert-manager v1.21.3: `duration` "If unset, this defaults to 90 days"; `renewBefore` "If unset, this defaults to 1/3 of the issued certificate's
  lifetime" [N24]: cert 90 ngày gia hạn khi còn 30 ngày. Certificate của `svp-cluster` không đặt `duration`, `renewBefore`.
- 21 ngày < 30 (cert-manager) < 45 (ACM 198 ngày) < 60 (ACM 395 ngày): `TLSCertExpiringSoon` chỉ cháy khi gia hạn đã trễ ít nhất chín ngày.

## §11. Chi phí

### Bảng giá

| Mục | Giá | Nguồn (ngày phát hành) |
| --- | --- | --- |
| AMP ingest (`APS1-AMP:MetricSampleCount`) | 40 triệu đầu mỗi tháng 0; tới 2 tỷ 0,90 mỗi 10 triệu | [N25] (2026-10-14) |
| AMP query (`QuerySamplesProcessed`) | 200 tỷ đầu (toàn cầu) 0; sau 0,10 mỗi tỷ | [N25] |
| AMP lưu trữ | 10 GB-tháng đầu 0; sau 0,03 mỗi GB-tháng | [N25] |
| CloudFront `AP-Requests-Tier2-HTTPS` | 0,012 mỗi 10 000 request HTTPS (Asia Pacific) | [N32] (2026-10-19) |
| CloudFront pay-as-you-go miễn phí mãi | 10 triệu request HTTP/HTTPS mỗi tháng | [0061](../0061-edge-cloudfront-waf-acm.md) phụ lục "Bảng giá" |
| WAF request; Bot Control | 0,60 mỗi triệu; Bot Control 10 triệu request đầu mỗi tháng miễn phí | [0061](../0061-edge-cloudfront-waf-acm.md) phụ lục "Bảng giá" |
| S3 GET (`APS1-Requests-Tier2`) | 0,004 mỗi 10 000 | [N33] (2026-11-09) |
| NAT gateway dữ liệu | 0,059 mỗi GB xử lý | [N34] (2026-11-14), như phụ lục [0048](../0048-prd-aws.md) |
| Tệp giá EC2 `ap-southeast-1` | 356 848 755 byte ≈ 0,357 GB mỗi lần tải | [N35] |

### Giả định

- Buổi 4 giờ như [0063](../0063-managed-observability.md) phụ lục §12; probe 30 s; trên eks hai replica agent cùng scrape mọi `Probe` (không chia
  shard), AMP dedup nên chỉ mẫu của một replica được tính, nhưng mỗi đích bị gọi 2 lần mỗi 30 s.
- Series mỗi đích blackbox, đếm tên metric ở mã nguồn v0.29.1 [N19] cộng 5 series scrape (`up`, `scrape_duration_seconds`,
  `scrape_samples_scraped`, `scrape_samples_post_metric_relabeling`, `scrape_series_added`): HTTP có TLS 22 + 5 = 27 (`probe_http_duration_seconds`
  5 pha); DNS 13 + 5 = 18. eks: 3 × 27 + 3 × 18 = 135 series.
- OpenCost ≈ 6N + 3C + L series [N5]: N node (6 metric mỗi node), C container (3 metric), L ≈ 300 (label metric mỗi Service, Deployment,
  StatefulSet, PV, metric tiến trình, HTTP của OpenCost). stg N ≈ 6, C ≈ 250 ⇒ ~1 100; prd N ≈ 9, C ≈ 300 ⇒ ~1 250. Scrape 30 s.
- Recording rule tính như mẫu ingest (cách đọc bất lợi): `svp-cost` ~28 series (≈ 20 namespace, 7 service, 1 cluster); Sloth của `public-uptime`
  ~15 series (8 cửa sổ SLI, 7 metadata); đánh giá 15 s.
- Mẫu AMP thêm nằm trên mức miễn phí đã dùng ở 0063: tính theo giá biên 0,90 mỗi 10 triệu.

### Mỗi buổi 4 giờ (mỗi env)

| Khoản | Cách tính | stg | prd |
| --- | --- | --- | --- |
| Mẫu blackbox | 135 × 120 × 4 = 64 800 | 0,0058 | 0,0058 |
| Mẫu Sloth `public-uptime` | 15 × 240 × 4 = 14 400 | 0,0013 | 0,0013 |
| Request CloudFront | 3 đích × 2 agent × 120 × 4 = 2 880 × 0,012/10 000 (ngoài 10 triệu miễn phí) | 0,0035 | 0,0035 |
| WAF | 2 880 × 0,60/1 000 000; Bot Control dưới mức miễn phí | 0,0017 | 0,0017 |
| S3 GET object probe | 960 × 0,004/10 000 | 0,0004 | 0,0004 |
| NAT của probe | 2 880 × ≤ 10 KB (handshake TLS và response, đo ở buổi) ≈ 0,029 GB × 0,059 | 0,0017 | 0,0017 |
| **Uptime** | | **~0,015** | **~0,015** |
| Mẫu OpenCost | stg 1 100 × 120 × 4 = 528 000; prd 1 250 × 480 = 600 000 | 0,048 | 0,054 |
| Mẫu `svp-cost` | 28 × 240 × 4 = 26 880 | 0,0024 | 0,0024 |
| NAT của tệp giá | (1 lúc khởi động + 0–4 loại node mới) × 0,357 GB × 0,059 = 0,021 mỗi lần | 0,021–0,105 | 0,021–0,105 |
| Truy vấn AMP | emitter ~2 × C × 8 mẫu mỗi phút (~1 triệu mỗi buổi), luật `svp-cost` ~0,8 triệu, cửa sổ 30 ngày, 3 ngày của SLO ≤ ~0,3 tỷ: dưới 200 tỷ miễn phí | 0 | 0 |
| **OpenCost** | | **~0,07–0,16** | **~0,08–0,16** |
| **Cộng** | | **~0,09–0,17** | **~0,09–0,18** |

### Tháng không buổi

0: role IAM và Pod Identity association không tính tiền theo thời gian; object probe 3 byte; mẫu thêm của mỗi buổi vài MB lưu trữ AMP, cộng với
phần của 0063 vẫn dưới 10 GB miễn phí. Không tài nguyên sống lâu mới.

### Cờ của 0071

[0071](../0071-paid-features.md) §7 (a): một mục thành cờ khi chi phí stg ≥ $2 mỗi tháng không buổi hay ≥ $1 mỗi buổi. Ở đây 0 và ~0,17: không đạt.
Các khoản là phần dùng thêm của AMP ingest, NAT, CloudFront, WAF, đã ở mục "Không cờ" của 0071 §9. CloudWatch Synthetics (~1,05–1,22 mỗi buổi) sẽ
đạt (a) và cần cờ.

## §12. ADR cũ

| ADR | Đoạn | Quyết định | Lý do |
| --- | --- | --- | --- |
| [0063](../0063-managed-observability.md) | §5, §11 | Chỉnh | Luật mới trong hai `RuleGroupsNamespace` sẵn có; danh tính Pod Identity thêm OpenCost đọc AMP |
| [0011](../0011-observability-stage3.md) | §8, §9 | Chỉnh | SLO thứ bảy, nhóm `svp-uptime`, `svp-cost` của file luật viết tay; profile `obs` của compose thêm blackbox |
| [0056](../0056-eks-platform-ha.md) | §6 | Chỉnh | Danh sách workload trải zone thêm blackbox (2 replica, PDB) |
| [0020](../0020-reliability-stage6.md) | §3, §12 | Không | SLO web giữ nguyên; luật runbook cho cảnh báo page được theo, không đổi |
| [0055](../0055-environment-matrix.md) | §2 | Không | OpenCost, blackbox chạy giống nhau ở stg, prd: thuộc nhóm phải giống sẵn có |
| [0061](../0061-edge-cloudfront-waf-acm.md) | WAF, edge | Không | Probe đi qua edge sẵn có; Bot Control chỉ đếm (cái giá ghi ở §6) |
| [0071](../0071-paid-features.md) | §7, §9 | Không | Ngưỡng và "Không cờ" áp nguyên (§11) |

## Nguồn

Đọc 2026-11-15.

- [N1] Chart `opencost` 2.5.34, `values.yaml`: <https://github.com/opencost/opencost-helm-chart/blob/opencost-2.5.34/charts/opencost/values.yaml>:
  `tag: "1.121.4@sha256:daa04ae…"`, `requests: cpu: '10m', memory: '55Mi'`, `limits: memory: '1Gi'`, `honorLabels: true`, `sigV4Proxy: image:
  public.ecr.aws/aws-observability/aws-sigv4-proxy:latest`, `name: aps`, `port: 8005`.
- [N2] Chart `opencost` 2.5.34, `templates/deployment.yaml`, `templates/_helpers.tpl`:
  <https://github.com/opencost/opencost-helm-chart/tree/opencost-2.5.34/charts/opencost/templates>: `- name: sigv4proxy`, `- --name`,
  `printf "http://localhost:%d/workspaces/%v"`, "Only use one of the prometheus setups: internal, external, or amp".
- [N3] OpenCost v1.121.4, `pkg/cloud/aws/provider.go` (`createNode`, `NodePricing`, `getUsageType`, `getPricingListURL`, `populatePricing`,
  `CreateConfig`): <https://github.com/opencost/opencost/blob/v1.121.4/pkg/cloud/aws/provider.go>; khởi động: `pkg/costmodel/router.go`,
  `modules/prometheus-source/pkg/prom/datasource.go` cùng tag.
- [N4] OpenCost v1.121.4, `pkg/cloud/aws/spotpricehistory.go`: <https://github.com/opencost/opencost/blob/v1.121.4/pkg/cloud/aws/spotpricehistory.go>.
- [N5] OpenCost v1.121.4, `pkg/costmodel/metrics.go`: <https://github.com/opencost/opencost/blob/v1.121.4/pkg/costmodel/metrics.go>.
- [N6] OpenCost v1.121.4, `pkg/costmodel/costmodel.go` (`ComputeCostData`, `queryMetrics`, `getContainerAllocation`):
  <https://github.com/opencost/opencost/blob/v1.121.4/pkg/costmodel/costmodel.go>.
- [N7] OpenCost v1.121.4, `pkg/metrics/kubemetrics.go`, `core/pkg/env/metrics.go` ("emit all necessary KSM v1 metrics that were removed in KSM
  v2", mặc định `true`): <https://github.com/opencost/opencost/blob/v1.121.4/pkg/metrics/kubemetrics.go>.
- [N8] OpenCost v1.121.4, `modules/prometheus-source/pkg/prom/metricsquerier.go`:
  <https://github.com/opencost/opencost/blob/v1.121.4/modules/prometheus-source/pkg/prom/metricsquerier.go>.
- [N9] OpenCost, OpenCost Metrics: <https://opencost.io/docs/integrations/metrics>.
- [N10] OpenCost, Installing with Helm, "Important Configuration Notes": <https://opencost.io/docs/installation/helm>.
- [N11] OpenCost, AWS configuration: <https://opencost.io/docs/configuration/aws>: URL giá, `AWS_PRICING_URL`; Spot Data Feed "on an hourly basis".
- [N12] OpenCost issue #3477: <https://github.com/opencost/opencost/issues/3477>.
- [N13] OpenCost issue #2637 "High memory usage": <https://github.com/opencost/opencost/issues/2637>.
- [N14] CNCF, OpenCost: <https://www.cncf.io/projects/opencost/>: "accepted to CNCF on June 17, 2022 and moved to the Incubating maturity level on
  October 25, 2024".
- [N15] IBM Kubecost pricing: <https://www.ibm.com/products/kubecost/pricing>: Foundations "Always free", "Unlimited clusters up to 250 cores",
  "15-day metric retention".
- [N16] Amazon EKS, Understand how EKS Pod Identity works: <https://docs.aws.amazon.com/eks/latest/userguide/pod-id-how-it-works.html>.
- [N17] Amazon EKS, Pod Identity minimum SDK versions: <https://docs.aws.amazon.com/eks/latest/userguide/pod-id-minimum-sdk.html>: "Go v1 – v1.47.11".
- [N18] `awslabs/aws-sigv4-proxy` v1.13.1, `go.mod` (`github.com/aws/aws-sdk-go v1.55.8`) và releases:
  <https://github.com/awslabs/aws-sigv4-proxy/blob/v1.13.1/go.mod>.
- [N19] blackbox exporter v0.29.1, `prober/http.go`, `prober/tls.go`, `prober/dns.go`, `prober/utils.go`, `prober/handler.go`:
  <https://github.com/prometheus/blackbox_exporter/tree/v0.29.1/prober>.
- [N20] blackbox exporter v0.29.1, `CONFIGURATION.md`: <https://github.com/prometheus/blackbox_exporter/blob/v0.29.1/CONFIGURATION.md>.
- [N21] Prometheus Operator v0.94.2, `pkg/apis/monitoring/v1/prometheus_types.go`, `pkg/apis/monitoring/v1alpha1/prometheusagent_types.go`:
  <https://github.com/prometheus-operator/prometheus-operator/tree/v0.94.2/pkg/apis/monitoring>.
- [N22] `kube-prometheus-stack` 92.17.1, `templates/prometheus/prometheus.yaml`:
  <https://github.com/prometheus-community/helm-charts/blob/kube-prometheus-stack-92.17.1/charts/kube-prometheus-stack/templates/prometheus/prometheus.yaml>.
- [N23] ACM, Renewal for domains validated by DNS: <https://docs.aws.amazon.com/acm/latest/userguide/dns-renewal-validation.html>.
- [N24] cert-manager v1.21.3, `pkg/apis/certmanager/v1/types_certificate.go`:
  <https://github.com/cert-manager/cert-manager/blob/v1.21.3/pkg/apis/certmanager/v1/types_certificate.go>.
- [N25] Price List AmazonPrometheus `ap-southeast-1`:
  <https://pricing.us-east-1.amazonaws.com/offers/v1.0/aws/AmazonPrometheus/current/ap-southeast-1/index.json>.
- [N26] Price List AmazonCloudWatch `ap-southeast-1` (`APS1-CW:Canary-runs`, `Global-CW:Canary-runs`):
  <https://pricing.us-east-1.amazonaws.com/offers/v1.0/aws/AmazonCloudWatch/current/ap-southeast-1/index.json>.
- [N27] CloudWatch Synthetics: <https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/CloudWatch_Synthetics_Canaries.html>.
- [N28] Route 53 pricing, Health Checks: <https://aws.amazon.com/route53/pricing/>.
- [N29] Grafana Cloud pricing, Synthetics API Testing: <https://grafana.com/pricing/>.
- [N30] Giá EC2 on-demand Tokyo của trang giá EC2:
  <https://b0.p.awsstatic.com/pricing/2.0/meteredUnitMaps/ec2/USD/current/ec2-ondemand-without-sec-sel/Asia%20Pacific%20(Tokyo)/Linux/index.json>.
- [N31] Amazon VPC pricing, public IPv4: <https://aws.amazon.com/vpc/pricing/>: "Hourly charge for In-use Public IPv4 Address $0.005".
- [N32] Price List AmazonCloudFront: <https://pricing.us-east-1.amazonaws.com/offers/v1.0/aws/AmazonCloudFront/current/index.json>.
- [N33] Price List AmazonS3 `ap-southeast-1`: <https://pricing.us-east-1.amazonaws.com/offers/v1.0/aws/AmazonS3/current/ap-southeast-1/index.json>.
- [N34] Price List AmazonEC2 `ap-southeast-1`, dòng NAT Gateway:
  <https://pricing.us-east-1.amazonaws.com/offers/v1.0/aws/AmazonEC2/current/ap-southeast-1/index.csv>.
- [N35] `curl -sI https://pricing.us-east-1.amazonaws.com/offers/v1.0/aws/AmazonEC2/current/ap-southeast-1/index.json`:
  `Content-Length: 356848755`, `Last-Modified: Sat, 14 Nov 2026 02:11:28 GMT`.
- [N36] OpenCost v1.121.4, `configs/default.json`: <https://github.com/opencost/opencost/blob/v1.121.4/configs/default.json>.
- [N37] Chart `prometheus-blackbox-exporter` 11.21.3, `Chart.yaml`, `values.yaml`:
  <https://github.com/prometheus-community/helm-charts/tree/prometheus-blackbox-exporter-11.21.3/charts/prometheus-blackbox-exporter>.
- [N38] AWS Data Exports, Creating exports: <https://docs.aws.amazon.com/cur/latest/userguide/dataexports-create.html>: "It can take up to 24
  hours for AWS to start delivering exports"; "refreshes the billing and cost management export output at least once a day".
