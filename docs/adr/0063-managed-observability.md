# 0063. Telemetry của eks vào dịch vụ managed sống qua destroy: metric tới Amazon Managed Service for Prometheus qua Prometheus agent HA và Collector, log tới CloudWatch Logs, trace tới X-Ray qua OTLP; luật và Alertmanager của AMP qua ACK gửi SNS; Amazon Managed Grafana nhận dashboard qua Grafana Operator; local giữ LGTM

- Trạng thái: Chấp nhận
- Ngày: 2026-11-13
- Người quyết: người học (duyệt plan R4: telemetry eks vào dịch vụ managed, AMG, ACK, Grafana Operator), AI đề xuất thiết kế theo tài liệu

## Bối cảnh và vấn đề

- Trên eks, telemetry ở trong cluster như k3d ([0034](0034-aws-stage7.md) Câu 9A, [0011](0011-observability-stage3.md), [0019](0019-web-k3d-supply-chain-observability.md)):
  Prometheus một replica trên EBS, Loki, Tempo, Grafana, Alertmanager Telegram. Destroy xoá cả dữ liệu, cảnh báo chết cùng cluster, không HA.
- Metric OTLP của bảy service vào OTLP receiver của Prometheus, dịch tên theo khối `otlp` của `base/kube-prometheus-stack.yaml` (27 resource
  attribute thành label); luật, năm dashboard dựa vào đúng tên, label đó; luật đánh giá mỗi 15 s; canary hỏi `kps-prometheus` với cửa sổ `[1m]`.
- Tài liệu đọc lúc quyết đổi thiết kế ban đầu: AMG tính tối thiểu một Editor mỗi workspace mỗi tháng kể cả khi không ai đăng nhập, service account
  tính như user [N19]; quyền `SERVICE_MANAGED` chỉ tạo được ở console [N21]; plugin X-Ray của Grafana không thấy trace khi Transaction Search bật
  [N15]; ruler AMP đánh giá tối thiểu 30 s [N6]; không tài liệu nào nói AMG dùng được Identity Center ở region khác [N20].
- Ràng buộc: repo public; AI không chạy lệnh chạm account; buổi tối đa 4 giờ; stg chạy như prd ([0055](0055-environment-matrix.md)); SCP, RCP
  của [0059](0059-org-structure-guardrails.md); local miễn phí, giữ LGTM, chỉ exporter khác theo nền tảng.

## Yếu tố quyết định

- Metric, log, trace (ba tín hiệu của hướng dẫn EKS observability của AWS [N1]) sống qua destroy, xem được sau buổi; nơi nhận dữ liệu HA.
- Luật, dashboard, canary chạy nguyên: cùng tên metric, label, chu kỳ đánh giá.
- Khác biệt k3d/eks là dữ liệu (file đích của Collector, values theo nền tảng), không `if`.
- Quyền tối thiểu qua Pod Identity; control FSBP; chi phí theo **Chi phí R4** của run.

## Phương án đã cân nhắc

Trạng thái ngành, được, mất, nguồn: [phụ lục](appendix/0063-managed-observability.md#phương-án). In đậm là lựa chọn.

- Metric: **AMP + Prometheus agent HA + Collector ghi remote write**; managed collector của AMP (agentless, $0,04 mỗi giờ, không đọc ServiceMonitor,
  PodMonitor); CloudWatch OTLP metrics + PromQL (mới, GA 2026-06 [N18]); Prometheus trong cluster (hiện trạng: mất khi destroy, một replica).
- Log: **CloudWatch Logs qua endpoint OTLP**; Loki trên S3 (đọc cần cluster); exporter `awscloudwatchlogs` (alpha).
- Trace: **X-Ray qua endpoint OTLP với Transaction Search**; Tempo trên S3 (đọc cần cluster).
- Grafana: **Amazon Managed Grafana + Grafana Operator**; Grafana trong cluster trỏ AMP ($0, mất UI khi destroy, không SSO); provider `grafana` (chéo repo).
- Cảnh báo: **ruler, Alertmanager của AMP qua ACK, tới SNS**; Grafana alerting của AMG (đổi định dạng luật, 100 rule instance mỗi workspace [N23]);
  luật ở Prometheus trong cluster (chết cùng cluster).
- Luật upstream của kube-prometheus-stack: **không chuyển**; chuyển cả 18 nhóm. Gỡ buổi: **xoá luật ở AMP**; giữ (ruler chạy cả tháng).

## Kết quả quyết định

Chọn các phương án in đậm: dữ liệu ở dịch vụ managed của account env, cluster chỉ còn thu và gửi. Cái giá: AMG tối thiểu $9 mỗi workspace mỗi tháng,
hai controller mới, dịch tên metric ở Collector phải khớp Prometheus, một bước tay cho `aws/spans`. Giá trị đủ từng mục: phụ lục, cùng số §.

### 1. Metric: Workspace AMP và Prometheus agent

- **Workspace AMP** (module `observability`, root `aws/accounts/<env>`), khoá `alias/svp-<env>-observability`: key policy theo `kms:ViaService`
  của AMP; CMK không đổi được sau khi tạo, thu hồi grant là mất dữ liệu [N3]. AMP không có endpoint OTLP, chỉ remote write [N7].
- **Prometheus agent**: `prometheus.agentMode` render `PrometheusAgent` [N30]; 2 replica trải zone ([0056](0056-eks-platform-ha.md) §6);
  `replicaExternalLabelName: __replica__`, `externalLabels.cluster: svp-<env>`, nhãn `prometheus` của operator bỏ; AMP giữ `cluster`, bỏ
  `__replica__`, đổi leader sau 30 s [N4]. Remote write `<ampEndpoint>api/v1/remote_write`, SigV4, native histogram (AMP nhận từ 2026-06 [N8]),
  `queueConfig` theo AWS [N7]. SigV4 của Prometheus v3.15 dùng chuỗi credential mặc định của aws-sdk-go-v2, có Pod Identity [N33].
- Metric OTLP của service đi thẳng từ Collector vào AMP (§6), không qua agent: dedup giữ mẫu của replica leader, bỏ của replica kia [N4], nên
  OTLP chia tải qua Service của hai replica sẽ mất nửa dữ liệu.

### 2. Log: Log group ứng dụng

- **Log group ứng dụng** lớp Standard, cùng khoá KMS (key policy cho CloudWatch Logs theo encryption context [N13]) và stream `otel-collector` cùng
  module: endpoint OTLP chỉ ghi vào log group, stream có sẵn [N12]. Standard thay Infrequent Access (nửa giá ingest): giữ Live Tail trong buổi.
- Endpoint `https://logs.<region>.amazonaws.com/v1/logs`, header `x-aws-log-group`, `x-aws-log-stream`, SigV4 `logs` [N12]; đọc bằng Logs Insights.

### 3. Trace: Trace X-Ray

- Endpoint OTLP của X-Ray cần Transaction Search [N14]: module `observability` tạo resource policy log cho `xray.amazonaws.com` (`aws/spans`,
  `/aws/application-signals/data`, điều kiện `aws:SourceArn`, `aws:SourceAccount`), đích segment `CloudWatchLogs` và rule index `Default` 1 % (mức
  miễn phí) bằng resource của provider ghim [N36].
- `aws/spans` do X-Ray tạo: API cấm tạo log group tên bắt đầu `aws/` [N13], provider chưa có tham số KMS của nó [N36]. Retention đặt bằng một
  bước tay mỗi account sau buổi đầu (README module, runbook `platform-setup.md`); mã hoá mặc định của CloudWatch Logs.
- Xem trace ở trang Traces của CloudWatch (tìm span, trace, trace map); AMG đọc span bằng Logs Insights trên `aws/spans`. AMG không có data source
  `xray`: plugin gọi `BatchGetTraces`, API không thấy trace khi Transaction Search bật [N15].

### 4. Grafana: Grafana managed

- **Grafana managed** Grafana 13 (cùng major với k3d [N23]), `AWS_SSO`, quyền `CUSTOMER_MANAGED` với role `svp-<env>-grafana` của module:
  `SERVICE_MANAGED` chỉ tạo được ở console [N21]. Data source của workspace `PROMETHEUS`, `CLOUDWATCH`. Không VPC: AMG gọi AMP, CloudWatch qua
  endpoint AWS, không tới được Pyroscope, GlitchTip trong VPC [N22].
- Identity Center của org dùng được cho AMG ở account thành viên [N20]; khác region với instance thì tài liệu không cam kết, re:Post báo đăng nhập
  được kèm cảnh báo [N20]: phép thử trước khi dựng kiểm, không được thì xác thực `SAML` với ứng dụng SAML của Identity Center.
- Grafana Operator v5.25 (e2e trên Kubernetes 1.34–1.36 [N25]) ở `svp-obs`: CR `Grafana` ngoài trỏ `grafanaUrl`, token từ Secret `grafana-operator`.
  Service account `svp-grafana-operator` vai trò Admin (Editor không tạo, sửa data source [N23]; cùng giá Editor [N19]), tính như user; token sống
  tối đa 30 ngày, quota 100 token mỗi workspace kể cả hết hạn [N23]: script buổi xoá token cũ, tạo mới vào entry `svp/<env>/grafana-operator`.
- Data source: uid `prometheus` kiểu `grafana-amazonprometheus-datasource` (Prometheus lõi của Grafana 12+ bỏ SigV4 [N26]), xác thực bằng role
  của workspace; uid `cloudwatch`. Uid đặt bằng `spec.uid` của CR [N25].

### 5. Cảnh báo: Luật trên AMP

- ACK `prometheusservice-controller` v1.10.0 (GA [N27]): `RuleGroupsNamespace` `svp-alerts`, `slo-generated` từ hai file luật,
  `AlertManagerDefinition` tới SNS `alarmTopicArn`. ACK không công bố dải Kubernetes; bản dựng với client-go v0.35 [N27]; kiểm ở buổi stg.
- **Chu kỳ 15 s như k3d**: chart ghi `interval: 15s` vào mỗi nhóm. Quota AMP tối thiểu 30 s, chỉnh được [N6]: người học xin 15 s cho hai account
  trước buổi đầu; không được thì không bật luật trên AMP với 30 s (đổi nghĩa cửa sổ 45 s, `RateLimitFallbackActive`), quyết lại bằng ADR mới.
  `rule_query_offset` giữ 60 s mặc định [N2]: chờ mẫu đến trễ, cảnh báo cháy chậm hơn k3d ~60 s.
- Alertmanager: `page` và `ticket` tới cùng topic (như alarm của dịch vụ managed), subject mang `severity`, `alertname`, thông điệp giữ
  `runbook_url`; `repeat_interval` page 4 giờ, ticket 24 giờ (tối đa 5 ngày [N5]). Topic thêm publisher `aps.amazonaws.com` (`sns:Publish`,
  `sns:GetTopicAttributes`, `aws:SourceArn` workspace, `aws:SourceAccount`), key của topic cho `kms:GenerateDataKey*`, `kms:Decrypt` [N5].
- Luật upstream không chuyển (bảng 18 khoá ở phụ lục): không nhóm nào `page` nên ở k3d chỉ hiện ở UI; AMP chỉ gửi ra ngoài, chuyển là thêm
  email; `Watchdog` luôn cháy; không dashboard, luật nào của dự án đọc recording rule của chúng.
- Gỡ buổi: `pre-destroy.sh` xoá ba CR khi ACK còn chạy (`deletion-policy` mặc định `delete` [N27]); CR mang `adoption-policy: adopt-or-create`
  để buổi sau nhận lại bản sót. Luật là code; giữ thì ruler đánh giá cả tháng không có dữ liệu mới.

### 6. Collector theo nền tảng

- `k8s-eks.yaml`: metric qua `prometheus_remote_write` tới `ampEndpoint`, log qua `otlp_http` tới endpoint OTLP của CloudWatch Logs, trace qua
  `otlp_http` tới X-Ray; ba extension `sigv4auth` (`aps`, `logs`, `xray`, region tường minh), chuỗi credential mặc định có Pod Identity [N28], [N33].
- Dịch tên như OTLP receiver của Prometheus (cùng thư viện `otlptranslator` [N28], [N29]): `translation_strategy: UnderscoreEscapingWithSuffixes`,
  `resource_constant_labels.included` = 27 khoá của `promoteResourceAttributes`, `disable_scope_info: true`; `job`, `instance` cùng cách sinh. Khác
  còn lại (`target_info` thiếu ba label định danh, khoá bắt đầu `_`) không chạm luật, dashboard nào: bảng ở phụ lục.
- Connector `service_graph` sinh `traces_service_graph_*` cùng tên, label `client`, `server`, `connection_type` như Tempo [N28], [N31], thêm
  label `failed`; node ảo theo thuộc tính của Tempo. Collector giữ một replica: connector ghép span hai đầu một cạnh trong một instance.
- Self-telemetry trên eks: telemetry nội bộ không dùng được extension xác thực [N32] và AMP không nhận OTLP: reader `pull` `:8888` giữ hậu tố
  `_total`, đơn vị và label `service_name`, `service_instance_id` như tên dashboard USE đang dùng, PodMonitor để agent scrape.

### 7. Dashboard trên eks

Cùng năm JSON; bỏ hai panel datasource `tempo` (TraceQL của `svp-red.json`, service map của `svp-pipeline.json`); panel `traces_service_graph_*` giữ
(§6); tham chiếu uid `prometheus` mang kiểu của plugin AMP [N26]. Exemplar → trace tắt; tìm trace ở trang Traces của CloudWatch (§3, [N15]).

### 8. Truy vấn canary trên eks

- Argo Rollouts v1.10.1 có `authentication.sigv4` cho Prometheus; SigV4 bật khi `address` chứa `aps-workspaces` [N33]. Thư viện ký dùng aws-sdk-go
  v1 (bản giải ra v1.55.8), mới hơn bản tối thiểu 1.47.11 của Pod Identity [N33]; issue #4536 (v1.8.2, SDK cũ) báo lỗi host Pod Identity, chưa
  ai báo chạy trên v1.10.x: phép kiểm canary thành công và thất bại ở buổi stg là bằng chứng.
- Độ trễ ghi chưa biết: AMP không công bố; `batch_send_deadline` 5 s của agent chỉ là hạn gom, lỗi 5xx thử lại mãi với backoff [N29]: khi rollout
  mẫu có thể trễ quá 45 s. Tiêu chí: trễ remote write của agent (công thức của `PrometheusRemoteWriteBehind` [N30]) ≤ 30 s thì `[1m]` còn ≥ 2 mẫu;
  quá thì canary trả −1, Inconclusive. Giữ `[1m]` tới khi buổi stg đo trễ và thử chặn 45 s (phụ lục); quá thì `[2m]`. Quyền chỉ `aps:QueryMetrics`.

### 9. Container Insights; Pyroscope, GlitchTip

- Không bật Container Insights: bản OTel AWS khuyên [N17] thu cAdvisor, kube-state-metrics mà agent đã scrape; khoảng trống duy nhất là metric
  node (node-exporter tắt vì Pod Security), không luật, dashboard nào cần.
- Pyroscope, GlitchTip ở lại trong cluster (AWS không có dịch vụ tương đương): dữ liệu mất khi destroy, xem bằng port-forward.

### 10. Retention và khác biệt stg/prd

**Khác biệt stg/prd**: **Workspace AMP** stg 31 ngày (đủ cửa sổ SLO 30 ngày), prd 150 (mặc định AMP [N2]); **Log group ứng dụng** và `aws/spans`
stg 7 ngày, prd 30. Mọi thứ khác giống ở hai env. Bảng: phụ lục.

### 11. Danh tính Pod Identity

**Danh tính Pod Identity** theo Service Authorization Reference [N10]: Collector `aps:RemoteWrite`, `logs:PutLogEvents` trên stream, KMS theo
`kms:ViaService` của Logs [N13], `xray:PutTraceSegments` (resource `*`: không có resource type; OTLP được cấp quyền như hành động này [N14]);
agent `aps:RemoteWrite`; ACK bốn hành động rule groups namespace, bốn alert manager definition và tag trên workspace, namespace của nó; Rollouts
`aps:QueryMetrics`. Role của AMG đọc AMP, Logs Insights, CloudWatch của env. Bảng đủ: phụ lục §11.

### 12. Chi phí, hợp đồng cluster và ADR cũ

- Phần này (giá `ap-southeast-1` [N11], [N16], [N19]; khối lượng giả định, đo ở buổi stg đầu): mỗi buổi ~$5 mỗi env (AMP ~48 triệu mẫu, log,
  span), buổi đầu của tháng ~$10–12 (thêm $9 AMG; 40 triệu mẫu miễn phí của AMP tính chung cả organization [N37]); tháng không buổi ~$20 (AMG tối
  thiểu $9 × 2, hai khoá KMS). Cộng phụ lục 0062, 0064, 0065: mỗi buổi ~$5,8–22 stg, ~$7,3–23,5 prd; tháng không buổi ~$26–34 (ngưỡng $24, $25, $35).
- **Hợp đồng cluster**: `ampWorkspaceId`, `ampEndpoint`, `logGroup`, `grafanaUrl`, `alarmTopicArn` khớp dạng của tài liệu AWS; `prometheusEndpoint`
  là base URL kết thúc `/workspaces/<id>/` theo hướng dẫn, ví dụ của API Reference lệch (`/api/v1/`) [N9]: phụ lục.
- ADR cũ chỉnh: 0034 Câu 9, §8; 0011, 0019 (đích telemetry trên eks); 0055 §2, §3; 0058 (topic thêm publisher AMP).

### Hệ quả

- Tốt: metric, log, span còn sau destroy, xem được giữa các buổi; cảnh báo đánh giá ngoài cluster, tới cùng topic với alarm dịch vụ managed;
  nhận dữ liệu HA; local và luật, dashboard không đổi; credential ngắn hạn qua Pod Identity.
- Xấu: AMG tính kể cả tháng không buổi; hai controller mới; dịch tên metric giữ khớp ở ba nơi; service map, TraceQL của Tempo không có trên eks;
  cảnh báo trễ thêm ~60 s; quota 15 s phải xin; một bước tay cho `aws/spans`; token AMG xoay mỗi buổi; Pyroscope, GlitchTip vẫn mất khi destroy.
- Xem lại khi: AWS không duyệt quota 15 s; ACK không `ACK.ResourceSynced` trên Kubernetes 1.36; canary không chạy bằng Pod Identity; plugin X-Ray
  đọc được Transaction Search; provider có KMS cho `aws/spans`; tổng chi phí vượt ngưỡng của người học; cần Collector nhiều replica.

## Xác nhận

- Lúc quyết chưa hiện thực. Kiểm tĩnh: test mocked module `observability`, `eks`, `alarms`; `make otelcol-validate` (cặp file chung + đích),
  `make helm-check` (render `rules.target: amp`, `dashboards.target: grafana-operator`), `make slo-check`, `make docs-check`.
- **Phép thử trước khi dựng** (người học, account sandbox): AMG `AWS_SSO` ở `ap-southeast-1` với Identity Center của org; quota chu kỳ luật 15 s.
- Buổi stg: query metric, log, span sau destroy và ở buổi kế; một cảnh báo tới SNS; dashboard trên AMG; canary thành công và thất bại; trễ remote
  write và phép thử chặn 45 s (§8); số đo series, GB thật để cập nhật bảng chi phí.

## Hiện thực ở

- `svp-infra`: `aws/modules/observability/` (§1–§4, §10), `aws/accounts/<env>/` (§10), `aws/modules/eks/pod-identity.tf` (§11),
  `aws/modules/alarms/` (§5), `aws/envs/<env>/` (§12), `aws/scripts/` (§3, §4, §5).
- Repo này: `deploy/observability/otelcol/` (§6), `deploy/helm/svp-observability/` (§5, §6, §7), `deploy/helm/svp-service/` (§8).
- `svp-gitops`: `argocd/apps/components.json`, `platforms/eks/` (§1, §4, §5, §6, §8).

## Nguồn

Đọc 2026-11-13; tên đủ, trích dẫn và mọi nguồn khác ở phụ lục.

- Hướng dẫn, AMP: [N1] <https://docs.aws.amazon.com/prescriptive-guidance/latest/amazon-eks-observability-best-practices/introduction.html>,
  [N2] <https://docs.aws.amazon.com/prometheus/latest/userguide/AMP-workspace-configuration.html>, [N3] <https://docs.aws.amazon.com/prometheus/latest/userguide/encryption-at-rest-Amazon-Service-Prometheus.html>,
  [N4] <https://docs.aws.amazon.com/prometheus/latest/userguide/AMP-ingest-dedupe.html>, [N5] <https://docs.aws.amazon.com/prometheus/latest/userguide/AMP-alertmanager-receiver.html>,
  [N6] <https://docs.aws.amazon.com/prometheus/latest/userguide/AMP_quotas.html>, [N7] <https://docs.aws.amazon.com/prometheus/latest/userguide/AMP-ingest-methods.html>,
  [N8] <https://aws.amazon.com/blogs/mt/introducing-native-histogram-support-in-amazon-managed-service-for-prometheus/>, [N9] <https://docs.aws.amazon.com/prometheus/latest/userguide/AMP-find-workspace-details.html>,
  [N10] <https://docs.aws.amazon.com/service-authorization/latest/reference/list_amazonmanagedserviceforprometheus.html>, [N11] <https://aws.amazon.com/prometheus/pricing/>
- CloudWatch, X-Ray: [N12] <https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/CloudWatch-OTLPEndpoint.html>, [N13] <https://docs.aws.amazon.com/AmazonCloudWatch/latest/logs/encrypt-log-data-kms.html>,
  [N14] <https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/Enable-TransactionSearch.html>, [N15] <https://docs.aws.amazon.com/xray/latest/api/API_BatchGetTraces.html>,
  [N16] <https://aws.amazon.com/cloudwatch/pricing/>, [N17] <https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/container-insights-eks-otel.html>, [N18] <https://aws.amazon.com/about-aws/whats-new/2026/06/amazon-cloudwatch-otel-metrics/>
- AMG, Grafana: [N19] <https://aws.amazon.com/grafana/pricing/>, [N20] <https://docs.aws.amazon.com/grafana/latest/userguide/AMG-and-Organizations.html>, [N21] <https://docs.aws.amazon.com/grafana/latest/APIReference/API_CreateWorkspace.html>,
  [N22] <https://docs.aws.amazon.com/grafana/latest/userguide/AMG-configure-vpc.html>, [N23] <https://docs.aws.amazon.com/grafana/latest/userguide/version-differences.html>,
  [N25] <https://github.com/grafana/grafana-operator/releases/tag/v5.25.0>, [N26] <https://github.com/grafana/grafana-amazonprometheus-datasource>
- ACK, OTel, Prometheus, Rollouts, Terraform: [N27] <https://github.com/aws-controllers-k8s/prometheusservice-controller/releases>, [N36] <https://github.com/hashicorp/terraform-provider-aws/blob/main/CHANGELOG.md>
  [N28] <https://github.com/open-telemetry/opentelemetry-collector-contrib/blob/v0.162.0/exporter/prometheusremotewriteexporter/README.md>, [N29] <https://github.com/prometheus/prometheus/blob/v3.15.0/docs/configuration/configuration.md>,
  [N30] <https://github.com/prometheus-community/helm-charts/blob/kube-prometheus-stack-92.17.1/charts/kube-prometheus-stack/values.yaml>, [N31] <https://grafana.com/docs/tempo/latest/metrics-from-traces/service_graphs/>,
  [N32] <https://opentelemetry.io/docs/collector/internal-telemetry/>, [N33] <https://github.com/argoproj/argo-rollouts/blob/v1.10.1/docs/analysis/prometheus.md>,

## Thông tin thêm

Phụ lục: [`appendix/0063-managed-observability.md`](appendix/0063-managed-observability.md) (phương án, giá trị đủ từng §, bảng nhóm luật upstream,
bảng dịch tên metric, bảng control FSBP, bảng luồng SCP, RCP, bảng giá, chi phí và bảng tổng của run, hợp đồng cluster, nguồn).
