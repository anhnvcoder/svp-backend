# Phụ lục ADR-0063: Telemetry của eks vào dịch vụ managed sống qua destroy: metric tới Amazon Managed Service for Prometheus qua Prometheus agent HA và Collector, log tới CloudWatch Logs, trace tới X-Ray qua OTLP; luật và Alertmanager của AMP qua ACK gửi SNS; Amazon Managed Grafana nhận dashboard qua Grafana Operator; local giữ LGTM

Phụ lục của [ADR-0063](../0063-managed-observability.md): phương án, giá trị đủ của từng §, bảng nhóm luật upstream, bảng control FSBP, bảng
luồng SCP, RCP, bảng giá, chi phí của phần này và bảng tổng của run, nguồn; xếp theo §. Mọi nguồn đọc ngày 2026-11-13. Đường dẫn `aws/...` không
kèm repo là của `svp-infra`, `base/...`, `platforms/...` là của `svp-gitops`; `<region>` là `ap-southeast-1`; `<ws>` là id workspace AMP.
Thuật ngữ in đậm là thuật ngữ của plan R4 mà các ADR, module, chart dùng chung.

## Phương án

| Câu hỏi | Phương án | Trạng thái ngành | Được | Mất | Nguồn |
| --- | --- | --- | --- | --- | --- |
| Metric | **Workspace AMP + Prometheus agent HA + Collector ghi remote write** | Hiện hành (AWS: Prometheus agent mode hay OTel Collector ghi vào AMP) | Dữ liệu sống qua destroy, AMP HA, query PromQL như hiện có; ServiceMonitor, PodMonitor của chart giữ | Hai replica agent; dịch tên ở Collector phải khớp Prometheus (§6) | [N7], [N34] |
| | Managed collector của AMP (scraper agentless) | Hiện hành | Không pod scrape, AWS vận hành | $0,04 mỗi giờ mỗi collector; cấu hình scrape là file gửi qua API, không đọc ServiceMonitor, PodMonitor; Collector vẫn cần cho OTLP; một trang AWS nói workspace CMK không dùng được managed collector | [N3], [N7], [N11] |
| | CloudWatch OTLP metrics + PromQL | Mới (GA 2026-06) | Một dịch vụ cho metric, log; 15 tháng lưu trữ; giá theo GB | File luật, Alertmanager của dự án cần ruler Prometheus mà AMP có sẵn; dịch vụ GA chưa tới nửa năm | [N5], [N18] |
| | Prometheus trong cluster (như k3d) | Hiện trạng | $0; như local | Mất dữ liệu khi destroy (volume EBS gỡ cùng env), một replica, cảnh báo chết cùng cluster | [0034](../0034-aws-stage7.md) Câu 9 |
| Log | **CloudWatch Logs qua endpoint OTLP** | Hiện hành (ví dụ chính thức của AWS) | Sống qua destroy; Logs Insights; Collector chỉ đổi exporter | Ingest $0,70 mỗi GB; log group, stream phải có sẵn | [N12], [N16] |
| | Loki trên S3 | Hiện hành | Như local, LogQL | Đọc cần Loki chạy (cluster); thêm bucket, index, vận hành Loki | — |
| | Exporter `awscloudwatchlogs` | Alpha, API `PutLogEvents` | Tự tạo group, stream | Mọi ví dụ log của AWS dùng OTLP; exporter đang tìm người giữ | [N28] |
| Trace | **X-Ray qua endpoint OTLP, Transaction Search** | Hiện hành | Span sống qua destroy, tìm span trong CloudWatch, trace map | Data source X-Ray của Grafana không đọc được trace khi bật Transaction Search; `aws/spans` ngoài Terraform | [N14], [N15] |
| | Tempo trên S3 | Hiện hành | Như local, TraceQL, service map của Tempo | Đọc cần Tempo chạy (cluster) | — |
| Grafana | **Amazon Managed Grafana + Grafana Operator** | Hiện hành (AMG; Operator là cách GitOps cho Grafana ngoài) | Xem dữ liệu sau destroy, SSO Identity Center, AWS vận hành HA | Tối thiểu $9 mỗi workspace mỗi tháng kể cả không ai đăng nhập; service account tính như user; token ≤ 30 ngày | [N19], [N23], [N25] |
| | Grafana trong cluster trỏ AMP, CloudWatch | Hiện hành | $0; như k3d; dashboard từ ConfigMap | Mất UI khi destroy; không SSO; Grafana 12+ cần cài plugin Amazon Prometheus cho SigV4 | [N26] |
| | Provider Terraform `grafana` cho AMG | Hiện hành | Không thêm controller | Dashboard nằm ở repo code, Terraform ở `svp-infra`: chéo repo; token trong state | — |
| Luật, cảnh báo | **Ruler, Alertmanager của AMP qua ACK, tới SNS** | Hiện hành | Luật đánh giá ngoài cluster, cùng file luật; GitOps qua CR | SNS là receiver (email); chu kỳ tối thiểu 30 s phải xin quota | [N5], [N6], [N27] |
| | Grafana alerting của AMG | Hiện hành | Một chỗ cho luật, contact point | Phải đổi định dạng luật; 100 rule instance mỗi workspace, không tăng được | [N23] |
| | Luật ở Prometheus trong cluster | Hiện trạng | Như k3d | Chết cùng cluster; agent không đánh giá luật | [N30] |
| Gỡ buổi | **Xoá luật cùng cluster, nhận lại khi tạo** | — | Không đánh giá khi không có cluster | Lần tạo đầu mỗi buổi | [N27] |
| | Giữ (`deletion-policy: retain`) | — | Luật có sẵn đầu buổi | Ruler chạy cả tháng; bản trong AMP lệch git nếu buổi sau đổi luật mà ACK chưa chạy | [N27] |
| Container Insights | **Không bật** | OTel Container Insights là bản AWS khuyên | — | Không có add-on, dashboard dựng sẵn của CloudWatch | [N17] |
| | Bật OTel Container Insights | Hiện hành | Add-on managed, UI CloudWatch | Trùng cAdvisor, kube-state-metrics mà agent đã scrape; $0,08 mỗi GB | [N17] |

## §1. Metric: Workspace AMP và Prometheus agent

### Workspace

| Thiết lập | Giá trị | Nguồn |
| --- | --- | --- |
| Alias | `svp-<env>` (module `observability`, root `aws/accounts/<env>`) | **Workspace AMP** |
| Mã hoá | KMS `alias/svp-<env>-observability`; key policy cho `kms:DescribeKey`, `CreateGrant`, `GenerateDataKey`, `Decrypt` theo `kms:ViaService` `aps.<region>.amazonaws.com` và `kms:CallerAccount`; AMP tạo ba grant | [N3]: "If you revoke a grant ... the data in the workspace is lost permanently"; CMK không đổi được sau khi tạo |
| Retention | §10 (`aws_prometheus_workspace_configuration`, `retention_period_in_days`; tối thiểu 1, mặc định 150, tối đa 1095 ngày) | [N2], [N36] |
| `rule_query_offset_in_seconds` | Mặc định 60 s của workspace mới | [N2]; §5 |
| OTLP | AMP không có endpoint OTLP; chỉ remote write | [N7] |

### Prometheus agent

- `prometheus.agentMode: true` của kube-prometheus-stack 92.17.1 render `kind: PrometheusAgent`, bỏ `alerting`, `ruleSelector`, `retention`,
  `remoteRead`; `defaultRules.create` và `alertmanager.enabled` không tự tắt [N30]: values eks đặt `false` cả hai.
- HA theo hướng dẫn AMP cho Prometheus Operator [N4]: `replicas: 2`, `replicaExternalLabelName: __replica__`, `externalLabels.cluster: svp-<env>`,
  `prometheusExternalLabelNameClear: true` (bỏ nhãn `prometheus` hằng số của operator). AMP: "The final stored metrics include the cluster
  label, but not the replica"; chuyển leader khi replica leader ngừng gửi 30 s; 500 cluster mỗi workspace [N4].
- `remoteWrite`: URL `<ampEndpoint>api/v1/remote_write`, `sigv4.region` = `cluster.region`, `sendNativeHistograms: true` (AMP nhận native
  histogram từ 2026-06, mỗi bucket có dữ liệu tính 0,25 mẫu [N8]), `queueConfig` theo hướng dẫn AMP: `maxSamplesPerSend: 1000`, `maxShards: 200`,
  `capacity: 2500` (mặc định Prometheus 2000, 50, 10 000) [N7].
- SigV4 của Prometheus v3.15: `prometheus/sigv4` v0.5.0 gọi `config.LoadDefaultConfig` của aws-sdk-go-v2 (`config` v1.33.3), chuỗi mặc định có
  container credential provider của Pod Identity; bản tối thiểu cho Go v2 là `release-2023-11-14` [N33].
- Vì sao metric OTLP không đi qua agent: agent nhận OTLP (code v3.15 không chặn route OTLP ở agent mode [N29]), nhưng Service chia tải OTLP
  giữa hai replica, mỗi replica nhận một nửa, trong khi dedup giữ mẫu của leader và bỏ của replica kia [N4]: mất nửa dữ liệu.

## §2. Log: Log group ứng dụng

| Thiết lập | Giá trị | Nguồn |
| --- | --- | --- |
| Log group | `/svp/<env>/otel`, lớp Standard, KMS cùng key (key policy cho `logs.<region>.amazonaws.com`, điều kiện `kms:EncryptionContext:aws:logs:arn`) | **Log group ứng dụng**; [N13] |
| Stream | `otel-collector`, tạo cùng module | [N12]: "forward logs to an existing `LogGroup` and `LogStream`" |
| Endpoint | `https://logs.<region>.amazonaws.com/v1/logs`, chỉ HTTP, protobuf hay JSON, gzip | [N12] |
| Header | `x-aws-log-group`, `x-aws-log-stream` (bắt buộc; không nhận query parameter) | [N12] |
| Ký | SigV4 dịch vụ `logs` | [N12] |
| Giới hạn | 10 000 bản ghi mỗi request; 1 MB mỗi bản ghi; resource cộng scope ≤ 16 KB; timestamp từ 14 ngày trước tới 2 giờ sau, một request không trải quá 24 giờ | [N12] |
| Quyền người ghi | `logs:PutLogEvents` trên stream; log group CMK: thêm `kms:Encrypt`, `Decrypt`, `ReEncrypt*`, `GenerateDataKey*`, `DescribeKey` theo `kms:ViaService` `logs.<region>.amazonaws.com` | [N10], [N13] |

Lớp Infrequent Access rẻ một nửa ($0,35 mỗi GB, endpoint OTLP nhận) nhưng không có Live Tail, metric filter, subscription filter; lớp không đổi được
sau khi tạo. Chọn Standard: Live Tail dùng trong buổi; chênh ~$0,2 mỗi buổi (§12).

Region: không trang nào liệt kê region của riêng endpoint OTLP log; bảng giá `ap-southeast-1` có usage type `APS1-DataProcessingOtel-Bytes` và
thông báo 2025-04 nói thay đổi áp cho "the CloudWatch Logs PutLogEvents API and OpenTelemetry Protocol (OTLP) endpoint" ở mọi region có CloudWatch
Logs [N12], [N16]. Kiểm ở buổi stg đầu.

## §3. Trace: Trace X-Ray

- Endpoint `https://xray.<region>.amazonaws.com/v1/traces`: "The OTLP traces endpoint requires Transaction Search" [N14]; chưa bật thì trả "The
  OTLP API is supported with CloudWatch Logs as a Trace Segment Destination". OTLP "is authorized as `xray:PutTraceSegments`" [N14].
- Bật Transaction Search gồm ba phần, cả ba có resource Terraform ở provider ghim (6.72) [N36]:

| Bước | Resource | Giá trị |
| --- | --- | --- |
| Cho X-Ray ghi log | `aws_cloudwatch_log_resource_policy` | principal `xray.amazonaws.com`, `logs:PutLogEvents` trên `aws/spans:*` và `/aws/application-signals/data:*`, điều kiện `aws:SourceArn` (`arn:aws:xray:<region>:<account>:*`), `aws:SourceAccount` |
| Đích segment | `aws_xray_trace_segment_destination` (từ 6.46.0) | `CloudWatchLogs`; xoá khỏi Terraform không đổi gì trên AWS |
| Index | `aws_xray_indexing_rule` (từ 6.46.0) | rule `Default`, xác suất 1 % ("index 1% of ingested spans for free as trace summary" [N14]) |

- `aws/spans`: X-Ray tạo; "Log group names can't start with the string `aws/`" [N13] nên Terraform không tạo trước được. Khoá KMS của nó chỉ đặt
  được bằng `SpansLogGroupKmsKeyId` lúc X-Ray tạo group, provider chưa có tham số này [N14], [N36]. Retention: một bước tay mỗi account sau buổi
  đầu, `aws logs put-retention-policy --log-group-name aws/spans` theo §10 (README module, runbook `platform-setup.md`); mã hoá mặc định của
  CloudWatch Logs.
- Grafana: plugin X-Ray (nay "AWS Application Signals data source") dùng `GetTraceSummaries`, `BatchGetTraces`; tài liệu `BatchGetTraces`: "You
  cannot find traces through this API if Transaction Search is enabled since trace is not indexed in X-Ray" [N15]; đọc span trong `aws/spans` cần
  `StartTraceRetrieval`, `ListRetrievedTraces`, plugin chưa dùng. Tìm trace ở trang Traces của CloudWatch; AMG đọc span bằng Logs Insights.

## §4. Grafana: Grafana managed

### Workspace

| Thiết lập | Giá trị | Nguồn |
| --- | --- | --- |
| Tên | `svp-<env>` (module `observability`) | **Grafana managed** |
| Phiên bản | 13 (AMG nhận 9, 10, 12, 13; v13 gồm tính năng OSS 13.0–13.2; k3d chạy 13.3) | [N23] |
| Xác thực | `AWS_SSO`, instance Identity Center của org | [N20] |
| Quyền | `CUSTOMER_MANAGED`, role `svp-<env>-grafana` của module (trust `grafana.amazonaws.com`, `aws:SourceAccount` = account env) | [N21]: "Use only the `CUSTOMER_MANAGED` permission type when creating a workspace with the API, CLI or AWS CloudFormation" |
| Data source của workspace | `PROMETHEUS`, `CLOUDWATCH` (không `XRAY`: §3) | [N21] |
| Mạng | Không VPC, không network access control | [N22] |
| Vai trò | `ADMIN`: nhóm `svp-platform-admins`; `VIEWER`: nhóm `svp-platform-viewers` | **Nhóm nền tảng** |

- `SERVICE_MANAGED`: AMG tạo role `AmazonGrafanaServiceRole-<id>` gắn policy theo data source, nhưng "The ability ... to create and update IAM roles
  on behalf of the user is supported only in the Amazon Managed Grafana console" [N21]; ở console, account thành viên chọn được nó chỉ khi là
  delegated admin [N21]. Module tạo role với quyền §11.
- Identity Center: AMG ở account thành viên dùng instance của org: tài liệu nêu kịch bản "Member account of an existing organization in which IAM
  Identity Center is already configured" [N20]; account instance không hỗ trợ [N20]. Workspace ở `ap-southeast-1`, instance ở `sso_region` của
  `aws/org`: không tài liệu nào cam kết; trang multi-Region của Identity Center viết "most AWS managed applications don't support this type of
  connection"; một câu hỏi re:Post (2025-03-28) cho thấy console cảnh báo "IAM Identity Center, which is deployed in a different AWS Region" mà
  người dùng vẫn đăng nhập được [N20]. Phép thử trước khi dựng tạo một workspace thử ở account sandbox; không được thì xác thực `SAML` với một
  ứng dụng SAML của Identity Center (không ràng buộc region), nhóm qua thuộc tính `groups`.
- Mạng: không VPC thì AMG gọi AMP, CloudWatch qua endpoint AWS, không tới được dịch vụ chỉ có trong VPC; cấu hình VPC đòi hai AZ, mọi lưu lượng
  của workspace (cả AMP, CloudWatch) đi qua VPC [N22].
- URL: id workspace `g-` cộng 10 ký tự hex, tên `*.grafana-workspace.<region>.amazonaws.com` [N22].

### Grafana Operator

- v5.25.0 (2026-08-24): ma trận e2e chạy Kubernetes 1.34.8, 1.35.5, 1.36.1; bỏ hỗ trợ Kubernetes 1.33 và Grafana 10; giữ ba major Grafana gần nhất
  [N25]. CR `Grafana` ngoài: `spec.external.url` = `grafanaUrl`, `spec.external.apiKey` từ Secret `grafana-operator`; `.spec.config` không có tác
  dụng, không cài plugin vào Grafana ngoài [N25]. Bài AWS 2023 về Operator với AMG dùng API key, bị bỏ hẳn ở AMG v12 [N23], [N25].
- Token: service account `svp-grafana-operator`, vai trò Admin: Operator tạo, sửa `GrafanaDatasource`, mà Editor "Cannot add, edit, or delete data
  sources", chỉ Admin "Can add, edit, and delete data sources" [N23]; Admin và Editor cùng $9 [N19]. "Each service account is considered a user for
  billing purposes" [N23]; token sống tối đa 30 ngày (`secondsToLive` ≤ 2 592 000), quota 100 token mỗi workspace kể cả token đã hết hạn [N23].
  Script buổi xoá token cũ của service account, tạo token mới cho buổi, ghi vào entry `svp/<env>/grafana-operator`; External Secrets đưa vào Secret
  `grafana-operator`.
- Grafana Operator gọi API AMG ở địa chỉ công khai: NetworkPolicy của nó mở TCP 443 ra địa chỉ công khai, qua NAT (endpoint interface không phủ AMG).

### Data source

| uid | Kiểu | `jsonData` | Nguồn |
| --- | --- | --- | --- |
| `prometheus` | `grafana-amazonprometheus-datasource` | `sigV4Auth: true`, `sigV4AuthType: ec2_iam_role` (nhãn UI "Workspace IAM Role"), `sigV4Region` | [N26]: "SigV4 authentication support in the Core Prometheus plugin has been removed" ở Grafana 12+ |
| `cloudwatch` | `cloudwatch` | `authType: ec2_iam_role`, `defaultRegion` | [N26] |

uid đặt bằng `spec.uid` của `GrafanaDatasource`, không đổi được sau khi tạo; bỏ trống thì Operator lấy uid của object Kubernetes [N25]. Grafana 12+
chỉ nhận uid chữ, số, `-`, `_` [N25].

## §5. Cảnh báo: Luật trên AMP

### ACK

- `prometheusservice-controller` v1.10.0 (2026-11-10, runtime v0.68.0), GA; chart `oci://public.ecr.aws/aws-controllers-k8s/prometheusservice-chart`
  [N27]. CRD `v1alpha1`: `RuleGroupsNamespace` (`name` không đổi được, `configuration`, `workspaceID`), `AlertManagerDefinition` (`configuration`,
  `workspaceID`); CRD `Workspace` không có KMS, nên workspace ở Terraform [N27].
- Kubernetes 1.36: dự án không công bố ma trận; controller dựng với client-go v0.35.0, chart không có `kubeVersion` [N27]; kiểm ở buổi stg (điều kiện
  `ACK.ResourceSynced` của ba CR). Thay thế nếu không chạy: EKS Capability cho ACK [N27].
- Pod Identity: "recommended for EKS 1.24+" [N27]. Policy mẫu của ACK là `aps:*` cộng bốn quyền `logs:*Delivery*`, `*ResourcePolicy` trên `*` [N27]:
  thu hẹp theo §11.
- Annotation: `services.k8s.aws/adoption-policy: adopt-or-create` (feature gate `ResourceAdoption` bật trong chart [N27]) trên ba CR; `deletion-policy`
  mặc định `delete`.

### Chu kỳ và độ trễ

- Luật của dự án dựa vào chu kỳ 15 s (comment đầu `svp-alerts.yaml`: "2 x 15 s export + 15 s evaluation"); nhóm không ghi `interval`. Chart ghi
  `interval: 15s` vào mỗi nhóm khi `rules.target: amp`. Quota AMP "Rule evaluation interval" tối thiểu 30 s, chỉnh được [N6]: người học xin 15 s
  cho `svp-stg`, `svp-prd` qua Service Quotas trước buổi đầu. AWS không duyệt thì không bật luật trên AMP với 30 s: chu kỳ đổi nghĩa của
  `RateLimitFallbackActive` (cửa sổ 2 m phải dài hơn `for` cộng hai lần đánh giá) và cửa sổ 45 s; quyết lại bằng ADR mới.
- `rule_query_offset`: 60 s mặc định cho workspace mới [N2], để mẫu remote write đến trễ kịp vào; luật đánh giá dữ liệu cũ 60 s, cảnh báo cháy
  chậm hơn k3d ~60 s. AMP từ chối mẫu cũ hơn 1 giờ [N6].
- Giới hạn liên quan [N6]: 2 000 luật mỗi workspace; file rule groups namespace ≤ 1 000 000 byte; query trải tối đa 95 ngày (cửa sổ `30d` của SLO
  nằm trong); 50 000 000 mẫu quét mỗi khoảng 24 giờ của một query.

### Alertmanager

| Mục | Giá trị | Nguồn |
| --- | --- | --- |
| Receiver | SNS `alarmTopicArn` (`sns_configs`, `sigv4.region` bắt buộc); AMP còn nhận PagerDuty từ 2025-08-29, trang cấu hình vẫn ghi SNS là receiver duy nhất | [N5] |
| Route | `group_by: [alertname, severity]`; `page`: `repeat_interval: 4h`; `ticket`: `repeat_interval: 24h` (cửa sổ SLO 1d, 3d còn cháy nhiều ngày sau diễn tập); AMP cho tối đa 5 ngày | [N5] |
| Thông điệp | Subject (≤ 100 ký tự): `[<severity>] <alertname>`; message: `summary`, `runbook_url`, `severity` của từng cảnh báo; SNS ≤ 256 KB | [N5] |
| Topic policy | Thêm `aps.amazonaws.com`: `sns:Publish`, `sns:GetTopicAttributes`, `ArnEquals aws:SourceArn` = ARN workspace, `StringEquals aws:SourceAccount` | [N5] |
| Key policy của topic | `aps.amazonaws.com`: `kms:GenerateDataKey*`, `kms:Decrypt` | [N5] |

Topic Standard của module `alarms` ([0058](../0058-managed-data-operations.md)); khuôn `publisher_services` thêm `aps` (biến `aps_workspace_arn`).

### Nhóm luật upstream không chuyển

`defaultRules.rules` của `base/kube-prometheus-stack.yaml` tắt các nhóm về thành phần k3s không có; 18 khoá còn bật (đọc từ `values.yaml` và
`templates/prometheus/rules-1.14/` của chart 92.17.1 [N30]). Mức là nhãn `severity` mặc định của chart; không nhóm nào có `page`, nên trên k3d chúng
chỉ hiện ở UI Alertmanager (route chỉ gửi `severity="page"`). Trên eks Alertmanager của AMP chỉ có receiver ra ngoài: chuyển một nhóm là thêm email,
không thêm chỗ xem. Không dashboard, luật nào của dự án đọc recording rule của chúng (`git grep` trên dashboard và file luật: chỉ `slo:*`).

| Khoá (nhóm) | Nội dung | Mức | Vì sao không chuyển |
| --- | --- | --- | --- |
| `alertmanager` (`alertmanager.rules`) | 9 cảnh báo về Alertmanager trong cluster | critical 6, warning 3 | eks không chạy Alertmanager trong cluster: không series |
| `configReloaders` (`config-reloaders`) | `ConfigReloaderSidecarErrors` | warning | Reloader của agent; lỗi reload hiện ở log pod |
| `general` (`general.rules`) | `TargetDown`, `Watchdog`, `InfoInhibitor` | warning 1, none 2 | `Watchdog` luôn cháy (dead man's switch): ở AMP thành email mỗi `repeat_interval` khi không có dịch vụ nhận heartbeat; `InfoInhibitor` chỉ có nghĩa với luật inhibit của Alertmanager trong cluster |
| `k8sContainerCpuUsageSecondsTotal`, `k8sContainerMemoryCache`, `k8sContainerMemoryRss`, `k8sContainerMemorySwap`, `k8sContainerMemoryWorkingSetBytes`, `k8sContainerResource`, `k8sPodOwner` (bảy nhóm `k8s.rules.*`) | 22 recording rule | — | Chỉ dashboard của chính chart đọc; AMG chỉ nhận dashboard của dự án |
| `kubelet` (`kubelet.rules`) | 3 recording rule (quantile PLEG) | — | Như trên |
| `kubePrometheusGeneral` (`kube-prometheus-general.rules`) | `count:up1`, `count:up0` | — | Như trên |
| `kubernetesApps` (`kubernetes-apps`) | 17 cảnh báo (`KubePodCrashLooping`, `KubeDeploymentReplicasMismatch`…) | warning 17 | Health của mọi Application đã page qua `ArgoCDApplicationDegraded`; phần còn lại thấy ở Argo CD |
| `kubernetesResources` (`kubernetes-resources`) | 8 (`KubeCPUOvercommit`, `CPUThrottlingHigh`…) | warning 5, info 3 | Karpenter thêm node khi thiếu; throttling đọc ở dashboard USE |
| `kubernetesStorage` (`kubernetes-storage`) | 5 (`KubePersistentVolumeFillingUp`…) | critical 3, warning 2 | PVC trên eks chỉ còn WAL của agent và Pyroscope; dữ liệu bền ở dịch vụ managed có alarm riêng (0058) |
| `kubeStateMetrics` (`kube-state-metrics`) | 4 | critical 4 | Lỗi của chính kube-state-metrics |
| `prometheus` (`prometheus`) | 23 | critical 6, warning 17 | Phần lớn về TSDB, rule, Alertmanager mà agent không có; `PrometheusRemoteStorageFailures`, `PrometheusRemoteWriteBehind` đánh giá trên metric đi qua chính đường đang lỗi |
| `prometheusOperator` (`prometheus-operator`) | 8 | warning 8 | Lỗi của operator; hiện ở log, trạng thái CR |

### Gỡ buổi

`pre-destroy.sh` xoá hai `RuleGroupsNamespace` và `AlertManagerDefinition` khi ACK còn chạy, chờ CR biến mất (ACK xoá bản ở AMP, `deletion-policy`
`delete` [N27]), rồi mới gỡ cluster. Bản sót (script lỗi giữa chừng): buổi sau ACK nhận lại nhờ `adopt-or-create`; `sweep.sh` đọc
`ListRuleGroupsNamespaces`, `DescribeAlertManagerDefinition` của workspace và báo phần còn lại. Workspace, log group, AMG là tài nguyên sống lâu
(`kept`).

## §6. Collector theo nền tảng

### Dịch tên metric

Cả OTLP receiver của Prometheus v3.15 và exporter `prometheus_remote_write` v0.162.0 dùng `prometheus/otlptranslator` v1.0.0: cùng tên, hậu tố
`_total` và đơn vị, đổi `.` thành `_` [N28], [N29].

| Điểm | Prometheus (k3d, `base/kube-prometheus-stack.yaml`) | Exporter (eks, `k8s-eks.yaml`) |
| --- | --- | --- |
| Chiến lược | `translation_strategy` mặc định `UnderscoreEscapingWithSuffixes` | `translation_strategy: UnderscoreEscapingWithSuffixes` (mặc định; `add_metric_suffixes` đã deprecate) |
| Resource attribute → label | `promoteResourceAttributes` (27 khoá) | `resource_constant_labels.included` cùng 27 khoá (thay `resource_to_telemetry_conversion` đã deprecate; ưu tiên hơn nó) |
| `job`, `instance` | `service.namespace/service.name`, `service.instance.id` | Như vậy (`helper.go`) |
| Label scope | Không (`promote_scope_metadata` mặc định false) | `disable_scope_info: true` |
| `target_info` | Có ba label định danh (`keepIdentifyingResourceAttributes: true`) | Không có ba label đó, không tuỳ chọn; không luật, dashboard nào đọc `target_info` |
| Khoá bắt đầu bằng `_` | `_x` thành `key_x` | Giữ `_x` (gate `PermissiveLabelSanitization` beta); dự án không đặt khoá nào như vậy |
| Histogram exponential | Native histogram | Native histogram |
| Metric delta | Bỏ | Bỏ |

Danh sách 27 khoá giữ ở ba nơi cùng thứ tự: `deploy/observability/prometheus/prometheus.yaml` (compose), `base/kube-prometheus-stack.yaml`,
`k8s-eks.yaml`. Exporter beta, đổi tên thành `prometheus_remote_write` (tên cũ còn chạy, báo deprecate); remote write 2.0 của exporter "In Development",
không dùng [N28].

### Exporter và extension

| Tín hiệu | Thành phần | Cấu hình |
| --- | --- | --- |
| Metric | `prometheus_remote_write/amp` | `endpoint: ${env:SVP_OTELCOL_AMP_ENDPOINT}api/v1/remote_write`, `auth.authenticator: sigv4auth/aps`, bảng trên; `remote_write_queue: {enabled: true, queue_size: 16, num_consumers: 1}` (hàng đợi đếm batch, mục dưới), `retry_on_failure` 1 s/10 s/60 s như đích k3d |
| Log | `otlp_http/logs` | `logs_endpoint: https://logs.${env:SVP_OTELCOL_REGION}.amazonaws.com/v1/logs`, header `x-aws-log-group: ${env:SVP_OTELCOL_LOG_GROUP}`, `x-aws-log-stream: otel-collector`, `compression: gzip`, `auth.authenticator: sigv4auth/logs` (ví dụ của AWS [N12]) |
| Trace | `otlp_http/xray` | `traces_endpoint: https://xray.${env:SVP_OTELCOL_REGION}.amazonaws.com/v1/traces`, `auth.authenticator: sigv4auth/xray` |
| Ký | `sigv4auth/aps`, `sigv4auth/logs`, `sigv4auth/xray` | `region`, `service` (`aps`, `logs`, `xray`) tường minh; extension beta, đoán được dịch vụ từ host nhưng không từ tên `vpce-…`; không `assume_role`: chuỗi mặc định của aws-sdk-go-v2 (`config` v1.33.5) có Pod Identity [N28], [N33] |

`SVP_OTELCOL_AMP_ENDPOINT` (= `cluster.ampEndpoint`, kết thúc bằng `/`), `SVP_OTELCOL_REGION`, `SVP_OTELCOL_LOG_GROUP` do values eks của
`otel-collector` đặt.

### Hàng đợi của exporter AMP

Exporter "doesn't support `sending_queue` but provides `remote_write_queue`" [N28]: khối `sending_queue.sizer: bytes` của đích k3d chép sang bị từ
chối. `remote_write_queue` chỉ có `enabled`, `queue_size`, `num_consumers`; factory dựng queue với sizer theo request (mỗi phần tử là một batch
OTLP), không có `sizer`; mặc định 10 000 batch, `num_consumers` bị ép 1 khi gate `EnableMultipleWorkers` tắt [N28]. Giới hạn 4 MiB của k3d không
giữ được, thay bằng ngân sách theo batch: processor `batch` (`send_batch_size` 1 024 điểm, `timeout` 1 s, `send_batch_max_size` 1 024: `send_batch_size` chỉ kích hoạt gửi, cận
là `send_batch_max_size` [N28]) nên mỗi batch ≤ 1 024 điểm, ước ≤ 1 MiB
pdata (giả định ~1 KiB mỗi điểm với label đã promote; đo ở buổi stg); `queue_size: 16` → ≤ 16 MiB chờ gửi, khoảng 16 giây tải khi mỗi giây một batch (cùng cỡ hàng đợi 4 MiB của đích khác),
trong `memory_limiter` 192 MiB (`spike_limit_mib` 48) và limit 256 Mi của pod; đầy thì exporter từ chối batch mới và `memory_limiter` đã chặn trước.
`max_batch_size_bytes` 3 000 000 mặc định chia request lớn. AMP throttle trả 429: gate `exporter.prometheusremotewritexporter.RetryOn429` tắt mặc
định nên batch bị 429 bỏ ngay; bật gate để 429 được thử lại như 5xx [N28].

### Service graph

| Mục | Tempo metrics-generator | Connector `service_graph` v0.162.0 |
| --- | --- | --- |
| Đếm | `traces_service_graph_request_total`, `traces_service_graph_request_failed_total` | Cùng tên sau khi exporter thêm hậu tố (`_total` không bị lặp) |
| Độ trễ | `traces_service_graph_request_server_seconds`, `_client_seconds` | `traces_service_graph_request_server`, `_client`, đơn vị `s`: ra cùng tên; gate tên cũ đã bỏ ở v0.154.0 |
| Label | `client`, `server`, `connection_type` | Như vậy, thêm `failed` (mọi series) |
| Node ảo | peer: `peer.service`, `db.name`, `db.system`, `db.system.name`; database: `db.namespace`, `db.name`, `db.system`, `db.system.name` | Đặt `virtual_node_peer_attributes`, `database_name_attributes` bằng danh sách của Tempo |

Panel đọc `sum by (client, server) (rate(...))` nên label `failed` không đổi kết quả; xoá nó thì hai series (`failed` true, false) trùng nhãn.
Connector alpha, tên cũ `servicegraph` deprecate; `unpaired_spans_total`, `dropped_spans_total` có trong README nhưng code không phát [N28], [N31].
Connector ghép span client, server của một cạnh trong bộ nhớ một instance: Collector giữ một replica; thêm replica thì cần exporter `loadbalancing`
theo trace ID trước nó.

### Self-telemetry trên eks

Telemetry nội bộ của Collector không dùng được extension xác thực (issue #13778 mở; PR bị đóng vì extension khởi động sau telemetry [N32]) và AMP
không nhận OTLP. Trên eks: reader `pull` `prometheus` `0.0.0.0:8888`, `without_type_suffix: false`, `without_units: false` (mặc định là `true` từ
v0.152.0: tên mất `_total` và đơn vị mà dashboard USE dùng), `with_resource_constant_labels.included: [service.name, service.instance.id]`
[N32]; PodMonitor của chart `svp-observability` cho hai replica agent scrape (dedup như mọi target). Metric vẫn tới khi pipeline của Collector từ chối
dữ liệu, như reader đẩy thẳng hiện có ở k3d.

## §7. Dashboard trên eks

- Chart render `GrafanaDashboard` (folder `svp`) từ cùng năm JSON khi `dashboards.target: grafana-operator`; bỏ panel datasource `type: tempo`: bảng
  "Recent gateway traces (Tempo)" của `svp-red.json` (TraceQL) và "Service graph" của `svp-pipeline.json` (service map); panel "Service graph
  requests by edge" giữ.
- Tham chiếu datasource uid `prometheus` đổi `type` thành `grafana-amazonprometheus-datasource` (§4) để khớp kiểu của data source.
- Exemplar → trace: tắt trên eks (không data source trace trong AMG); trace ID mở ở trang Traces của CloudWatch.

## §8. Truy vấn canary trên eks

| Câu hỏi | Trả lời | Nguồn |
| --- | --- | --- |
| Rollouts v1.10.1 có SigV4? | Có: `authentication.sigv4` `{region, profile, roleArn}`; tài liệu chỉ nêu IRSA | [N33] |
| Khi nào SigV4 bật | `strings.Contains(address, "aps-workspaces")` và khối sigv4 không rỗng; ký dịch vụ `aps` | [N33] `prometheus.go` |
| SDK | `prometheus/common/sigv4` v0.1.0 trên aws-sdk-go v1 (`session.NewSessionWithOptions`); `go.mod` của Rollouts kéo v1.55.8 | [N33] |
| Pod Identity | Tối thiểu Go v1 1.47.11 [N33]; v1.55.8 đạt. Issue #4536 (mở, trên v1.8.2 với SDK v1.44) báo lỗi host `169.254.170.23`; chưa ai báo chạy trên v1.10.x | [N33] |
| Đường query | `address` = `ampEndpoint` bỏ `/` cuối; client thêm `/api/v1/query` | [N9] |
| Độ trễ ghi | Chưa biết: AMP không công bố. Agent gửi mỗi shard khi đủ `max_samples_per_send` 2 000 hay sau `batch_send_deadline` 5 s ("Further time might pass due to potential retries"); lỗi 5xx (và 429 khi `retry_on_http_429`) thử lại không giới hạn, backoff 30 ms gấp đôi tới `max_backoff` 5 s, theo `Retry-After` nếu có; `sample_age_limit` 0 nên mẫu về trễ chứ không mất. Suy "tối đa 20 s" từ scrape cộng deadline chỉ đúng khi mọi request thành công ngay | [N29] |
| Tiêu chí tươi | Hai query dùng `increase(...[1m])`, cần ≥ 2 mẫu trong cửa sổ; scrape 15 s nên mẫu mới nhất tại lúc hỏi không được cũ hơn 30 s: trễ remote write ≤ 30 s. Đo bằng `prometheus_remote_storage_queue_highest_timestamp_seconds − prometheus_remote_storage_queue_highest_sent_timestamp_seconds` của agent (công thức của `PrometheusRemoteWriteBehind`, upstream báo ở 120 s), đầu-cuối bằng `time() − max(timestamp(up{job="kubelet"}))` hỏi AMP | [N29], [N30] |
| Khi trễ quá | `increase` thiếu mẫu, điều kiện ≥ 30 request không thoả: query trả −1, đo Inconclusive, `inconclusiveLimit` 0 dừng Rollout chờ người, không promote, không abort; `initialDelay` 60 s chỉ hoãn lần đo đầu, không che trễ giữa chừng | `canary.yaml` |
| Phép thử ở buổi stg | (1) Đo trễ p99 trong buổi và trong một rollout (series của agent về AMP); (2) gửi trễ chủ động: NetworkPolicy tạm chặn agent tới AMP 45 s giữa một rollout, chờ AnalysisRun Inconclusive và Rollout dừng, gỡ chặn, resume Rollout, canary đi tiếp; (3) trễ p99 > 30 s hay (2) không hồi: cửa sổ `[2m]`, `initialDelay` 120 s, giữ ngưỡng 30 request (giá trị ở chart `svp-service`) | — |

PR #5010 của Rollouts (mở) chuyển sang `prometheus/sigv4` v0.5.0 (SDK v2) [N33]. Phép kiểm canary thành công và thất bại ở buổi stg là bằng chứng
duy nhất cho Pod Identity của Rollouts.

## §9. Container Insights; Pyroscope, GlitchTip

- OTel Container Insights (AWS khuyên; bản enhanced classic "In maintenance mode") thu cAdvisor, node-exporter, kube-state-metrics, API server, chu
  kỳ 30 s, PromQL; $0,08 mỗi GB (`CW:OTEL:Bytes:EKS-CI`) cộng $0,01 mỗi triệu mẫu PromQL [N17]. Agent đã scrape cAdvisor (qua kubelet),
  kube-state-metrics; node-exporter tắt vì Pod Security "restricted" (`base/kube-prometheus-stack.yaml`). Khoảng trống duy nhất là metric node;
  không luật, dashboard nào cần. Không bật.
- Pyroscope, GlitchTip: không dịch vụ AWS tương đương; ở lại trong cluster (dữ liệu mất khi destroy), xem bằng port-forward; AMG không tới được
  (không VPC, §4).

## §10. Retention và khác biệt stg/prd

| Dữ liệu | stg | prd | Nhóm ([0055](../0055-environment-matrix.md)) | Lý do |
| --- | --- | --- | --- | --- |
| **Workspace AMP** (`amp_retention_days`) | 31 ngày | 150 ngày (mặc định AMP) | Được giảm | stg vẫn đủ cửa sổ SLO 30 ngày và phép kiểm "metric còn ở buổi kế"; prd giữ một quý cộng để so xu hướng; lưu trữ ≤ 10 GB miễn phí (§12) |
| **Log group ứng dụng** (`log_retention_days`) | 7 ngày | 30 ngày | Được giảm | stg: đọc lại sau destroy, buổi kế gần; prd: như log group khác của prd |
| `aws/spans` (`span_retention_days`, bước tay) | 7 ngày | 30 ngày | Được giảm | Như log |
| Workspace, log group, Transaction Search, AMG, ACK, Operator, agent HA, đích telemetry | như prd | §1–§9 | Phải giống | stg chạy đúng đường dữ liệu của prd |

Giá trị nằm trong `locals` của root `aws/accounts/<env>` (**Khác biệt root env**).

## §11. Danh tính Pod Identity và role của AMG

Đối chiếu Service Authorization Reference [N10]. Action AMP nhận resource `workspace` (`RemoteWrite`, `QueryMetrics`, `GetSeries`, `GetLabels`,
`GetMetricMetadata`, `ListRules`, `ListAlerts`, `*AlertManagerDefinition`, `ListRuleGroupsNamespaces`) hay `rulegroupsnamespace`
(`arn:aws:aps:<region>:<account>:rulegroupsnamespace/<ws>/<tên>`: `Create`, `Put`, `Describe`, `DeleteRuleGroupsNamespace`); X-Ray
`PutTraceSegments` không có resource type; CloudWatch Logs: `PutLogEvents` nhận `log-stream`, `StartQuery`, `GetQueryResults`, `GetLogGroupFields`
nhận `log-group`, `StopQuery`, `DescribeLogGroups` không có resource type (JSON service reference `logs.json`).

| ServiceAccount | Action | Resource |
| --- | --- | --- |
| `svp-obs/otel-collector` | `aps:RemoteWrite` | workspace |
| | `logs:PutLogEvents` | `log-group:/svp/<env>/otel:log-stream:otel-collector` |
| | `kms:Encrypt`, `Decrypt`, `ReEncrypt*`, `GenerateDataKey*`, `DescribeKey`, điều kiện `kms:ViaService` = `logs.<region>.amazonaws.com` | key `alias/svp-<env>-observability` |
| | `xray:PutTraceSegments` | `*` (không resource type) |
| `svp-obs/kps-prometheus` | `aps:RemoteWrite` | workspace |
| `svp-obs/ack-prometheusservice-controller` | `aps:CreateRuleGroupsNamespace`, `PutRuleGroupsNamespace`, `DescribeRuleGroupsNamespace`, `DeleteRuleGroupsNamespace`, `TagResource`, `UntagResource`, `ListTagsForResource` | `rulegroupsnamespace/<ws>/*` |
| | `aps:CreateAlertManagerDefinition`, `PutAlertManagerDefinition`, `DescribeAlertManagerDefinition`, `DeleteAlertManagerDefinition`, `ListRuleGroupsNamespaces` | workspace |
| `argo-rollouts/argo-rollouts` | `aps:QueryMetrics` | workspace |

Rollouts chỉ gọi `/api/v1/query` nên chỉ cần `QueryMetrics`; `GetSeries`, `GetLabels`, `GetMetricMetadata` không bước nào dùng. Không action `*`.

Role `svp-<env>-grafana` của workspace AMG (không phải Pod Identity): `aps:QueryMetrics`, `GetSeries`, `GetLabels`, `GetMetricMetadata`, `ListRules`,
`ListAlerts` trên workspace; `logs:StartQuery`, `GetQueryResults`, `GetLogGroupFields` (resource `log-group`) trên `/svp/<env>/otel`, `aws/spans` và
log group của RDS, MSK, ElastiCache; statement riêng resource `*` cho `logs:StopQuery` và `logs:DescribeLogGroups` (hai action không có resource type
[N10]; gộp `StopQuery` vào statement theo log group thì huỷ query Logs Insights từ AMG bị từ chối, query chạy tiếp và tính phí); `kms:Decrypt` theo
`kms:ViaService` logs; `cloudwatch:GetMetricData`, `ListMetrics` (`*`, không resource type) cho metric của dịch vụ managed. Theo policy AWS cho data
source (`AmazonGrafanaCloudWatchAccess`, policy Prometheus của `SERVICE_MANAGED` [N21]), thu hẹp về tài nguyên của env.

## §12. Chi phí

### Bảng giá (`ap-southeast-1`)

| Dịch vụ | Mục | Giá (USD) | Nguồn |
| --- | --- | --- | --- |
| AMP | Mẫu ingest (`APS1-AMP:MetricSampleCount`) | 40 triệu đầu mỗi tháng 0; tới 2 tỷ 0,90 mỗi 10 triệu | [N11] Price List |
| AMP | Lưu trữ (`MetricStorageByteHrs`) | 10 GB-tháng đầu 0; sau 0,03 mỗi GB-tháng | [N11] |
| AMP | Mẫu query (`QuerySamplesProcessed`) | 200 tỷ đầu (toàn cầu) 0; sau 0,10 mỗi tỷ | [N11] |
| CloudWatch Logs | Ingest OTLP Standard (`DataProcessingOtel-Bytes`); IA | 0,70 mỗi GB; 0,35 | [N16] |
| CloudWatch Logs | Lưu trữ Standard | 0,03 mỗi GB-tháng | [N16] |
| CloudWatch Logs | Logs Insights | 0,007 mỗi GB quét | [N16] |
| Transaction Search | Span ingest (`Application-Signals-Bytes`); index | 0,35 mỗi GB (10 TB đầu); index 1 % đầu miễn phí, sau 0,75 mỗi triệu span; "Spans ingested as logs will not incur log ingestion pricing" | [N16] |
| AMG | User active Editor, Admin; Viewer | 9; 5 mỗi user mỗi workspace mỗi tháng; tối thiểu một Editor mỗi workspace mỗi tháng "even if no users log in"; service account tính như user | [N19] |
| KMS | Key | 1,00 mỗi tháng | phụ lục [0062](0062-ecr-registry-ci-oidc.md) §11 |

Thử 90 ngày của AMG (tối đa năm user mỗi account) không tính vào bảng: lab sống lâu hơn.

### Khối lượng giả định

Chưa đo trên eks; số dưới là giả định, đo ở buổi stg đầu (`prometheus_agent_active_series` của agent; `IncomingBytes` của log group; usage
`Application-Signals-Bytes`):

- Series hoạt động S ≈ 50 000 (cAdvisor, kube-state-metrics, kubelet, Envoy, Argo CD và metric OTLP của bảy service; khoảng 30 000–80 000), mỗi
  15 s: S × 240 × 4 giờ ≈ 48 triệu mẫu mỗi buổi; dedup HA, chỉ tính mẫu được nhận ("charged in full when deduplication is not set up" [N4]).
- Log OTLP ~0,5 GB, span ~1 GB mỗi buổi (smoke, một lượt k6).

### Phần này, mỗi buổi 4 giờ (mỗi env)

| Khoản | Buổi đầu của tháng | Buổi sau trong tháng |
| --- | --- | --- |
| AMP ingest: 48 triệu mẫu; 40 triệu miễn phí mỗi tháng tính chung mọi account của organization [N37] (stg, prd cùng buổi: mỗi env 20 triệu) | 2,52 (0,72 khi chỉ một env có buổi trong tháng) | 4,32 |
| Log: 0,5 GB × 0,70 | 0,35 | 0,35 |
| Span: 1 GB × 0,35 | 0,35 | 0,35 |
| AMG: tháng có buổi tính người học (Admin) và service account của Operator (Admin, cùng giá Editor): 18, thay vì mức tối thiểu 9 của tháng không buổi | +9,00 | 0 |
| Query (luật, dashboard, canary): dưới 200 tỷ mẫu miễn phí | 0 | 0 |
| **Cộng** | **~12,2** (~10,4 khi một env) | **~5,0** |

### Phần này, tháng không buổi (hai account)

| Khoản | Tháng (USD) |
| --- | --- |
| AMG: tối thiểu một Editor mỗi workspace × 2 | 18,00 |
| Hai key KMS `alias/svp-<env>-observability` | 2,00 |
| Lưu trữ AMP (dưới 10 GB miễn phí), log, span (vài GB × 0,03) | < 0,3 |
| Luật trên AMP | 0 (xoá khi gỡ buổi, §5) |
| **Cộng** | **~20,3** |

Khoản lớn nhất là mức tối thiểu của AMG.

### Bảng tổng của run

Cộng bảng phụ lục §11 của [0062](0062-ecr-registry-ci-oidc.md), §7 của [0064](0064-interface-endpoints.md), §8 của
[0065](0065-argocd-eks-capability.md) và phần này; mỗi cột là một env. Buổi đầu của tháng gánh các khoản theo tháng: AMG của tháng có buổi, bậc miễn
phí của AMP, digest bên thứ ba mới từ buổi trước.

| ADR | Mỗi buổi stg | Mỗi buổi prd | Tháng không buổi |
| --- | --- | --- | --- |
| 0062 registry | Inspector ~0,18 mỗi digest bên thứ ba mới: 0 khi không có; ≤ 6,8 buổi đầu tiên; ≤ 9 buổi cách buổi trước một tháng | Như stg | ~5,7 (tháng 1); ~9 (tháng 3); ~14 (tháng 6) |
| 0063 observability (bảng trên) | ~5,0 buổi sau trong tháng; ~12,2 buổi đầu tháng | Như stg (S lớn hơn ở prd ba AZ thì AMP tăng theo) | ~20,3 |
| 0064 endpoint | ~0,75 | ~2,3 | 0 |
| 0065 Argo CD trên eks | 0 (chưa hiện thực; ~0,34 khi hiện thực) | 0 (~0,34 khi hiện thực) | 0 |
| **Cộng** | **~5,8** buổi sau trong tháng không digest mới; **~22** buổi đầu tháng cách buổi trước một tháng | **~7,3**; **~23,5** | **~26** (tháng 1) tới **~34** (tháng 6) |
| Ngưỡng của người học | 24 | 25 | 35 |

Mọi cột dưới ngưỡng. Đỉnh mỗi buổi là buổi đầu tháng cách buổi trước một tháng (dư ~2 ở stg, ~1,5 ở prd); buổi đầu tiên (≤ 38 digest) ~19,8 và
~21,3. Các khoản theo tháng dồn vào buổi đó, lớn nhất là AMG của tháng có buổi (+9 mỗi env), rồi Inspector (≤ 9, phụ lục 0062 §11), rồi AMP
ingest khi stg, prd chia bậc miễn phí (2,52 mỗi env). Khối lượng là giả định, số đo lại ở buổi stg đầu. Tháng không buổi chạm 35 khoảng tháng 7
nếu repo phát hành stg không được dọn (lưu trữ tăng ~1,6 mỗi tháng, phụ lục 0062 §11); "Xem lại khi" của 0062 (repo vượt 30 GB, khoảng tháng 3)
gọi GC trước mốc đó.

## Hợp đồng cluster

| Khoá | Dạng trong **Hợp đồng cluster** | Tài liệu AWS | Kết quả |
| --- | --- | --- | --- |
| `ampWorkspaceId` | `^ws-[0-9a-f-]+$` | Id do AMP sinh: `ws-` + UUID (ví dụ của tài liệu); pattern API rộng hơn (`[0-9A-Za-z][-.0-9A-Z_a-z]*`, ≤ 64) [N9] | Khớp id AMP sinh |
| `ampEndpoint` | `^https://aps-workspaces\.<region>\.amazonaws\.com/workspaces/ws-[0-9a-f-]+/$` | Hướng dẫn: `prometheusEndpoint` là "base URL" `https://aps-workspaces.<region>.amazonaws.com/workspaces/<ws>/`, thêm `/api/v1/remote_write`, `/api/v1/query` [N9]; ví dụ của API Reference lại kết thúc bằng `/api/v1/` [N9] | Khớp hướng dẫn; hai trang lệch: validation của `gitops-bridge` báo ngay lần apply đầu nếu output khác |
| `logGroup` | `^/svp/[a-z]+/otel$` | Tên log group cho phép `/`, `.`, `-`, `_` | Khớp |
| `grafanaUrl` | `^https://g-[0-9a-z]+\.grafana-workspace\.<region>\.amazonaws\.com$` | Id `g-` + 10 hex; tên `*.grafana-workspace.<region>.amazonaws.com` [N22] | Khớp |
| `alarmTopicArn` | `^arn:aws:sns:<region>:[0-9]{12}:svp-[a-z]+-alarms$` | ARN SNS; tên topic của module `alarms` | Khớp |

## Bảng control FSBP

"FSBP" là có trong AWS Foundational Security Best Practices v1.0.0 [N35]. FSBP không có control nào cho AMP, AMG, X-Ray hay log group CloudWatch
Logs; CloudWatch.16 (retention log group, mặc định 365 ngày) chỉ thuộc NIST SP 800-53 và CRI Profile [N35].

| Control | Tiêu đề (tóm tắt) | FSBP | Kết quả | Lý do |
| --- | --- | --- | --- | --- |
| CloudWatch.16 | Log group giữ đủ lâu | không | Không áp (chuẩn không bật) | Retention theo §10 |
| KMS.3 | Key không bị xoá ngoài ý muốn | có | Đạt | Key sống ở root `aws/accounts/<env>` |
| KMS.4 | Bật xoay key | không | Đạt | Xoay hằng năm |
| KMS.5 | Key không công khai | có | Đạt | Key policy: account và principal dịch vụ có `kms:ViaService` |
| IAM.21 | Policy không có action `<dịch vụ>:*` | có | Đạt | §11 liệt kê từng action; policy mẫu `aps:*` của ACK không dùng |
| SecretsManager.1 | Bật xoay tự động | có | Chấp nhận FAILED | Entry `svp/<env>/grafana-operator`: token AMG do script buổi tạo, không có Lambda xoay |
| SecretsManager.3 | Không có secret không dùng 90 ngày | có | Chấp nhận FAILED khi 90 ngày không buổi | External Secrets đọc nó mỗi buổi |
| SecretsManager.4 | Xoay trong 90 ngày | có | Chấp nhận FAILED | Như SecretsManager.1; token sống ≤ 30 ngày |

## Bảng luồng SCP, RCP

Đối chiếu với SCP và RCP `svp-data-perimeter` của [0059](../0059-org-structure-guardrails.md) §3, §4. RCP phủ S3, KMS, Secrets Manager, SQS, STS;
AMP, CloudWatch Logs, X-Ray, AMG, SNS ngoài phạm vi RCP. Mọi tài nguyên ở `ap-southeast-1`, region SCP `svp-deny-other-regions` cho phép.

| Luồng | Principal | Tài nguyên | Qua nhờ |
| --- | --- | --- | --- |
| Collector, agent ghi metric | Role Pod Identity (trong org) | AMP; KMS do AMP gọi qua grant | AMP ngoài RCP; KMS: grant của dịch vụ cho principal trong org |
| Collector ghi log | Role Pod Identity | CloudWatch Logs `/svp/<env>/otel`; KMS theo `kms:ViaService` | Logs ngoài RCP; principal KMS trong org (`aws:PrincipalOrgID`) |
| CloudWatch Logs mã hoá | `logs.<region>.amazonaws.com` | KMS key observability | Principal dịch vụ (`aws:PrincipalIsAWSService`); `aws:SourceAccount` là account env, trong org |
| Collector ghi span | Role Pod Identity | X-Ray (OTLP) | Ngoài RCP |
| X-Ray ghi `aws/spans` | `xray.amazonaws.com` | CloudWatch Logs (resource policy) | Ngoài RCP; policy giới hạn `aws:SourceArn`, `aws:SourceAccount` |
| ACK ghi luật, Alertmanager | Role Pod Identity | AMP | Ngoài RCP |
| Rollouts query | Role Pod Identity | AMP | Ngoài RCP |
| Pod nhận role | `pods.eks.amazonaws.com` | STS `AssumeRole`, `TagSession` | Như dòng Pod Identity của 0059 |
| AMP gửi cảnh báo | `aps.amazonaws.com` | SNS `svp-<env>-alarms`; KMS key của topic | SNS ngoài RCP; KMS: principal dịch vụ, `aws:SourceAccount` trong org |
| AMG nhận role workspace | `grafana.amazonaws.com` | STS `AssumeRole` | Principal dịch vụ; trust giới hạn `aws:SourceAccount` |
| AMG đọc AMP, Logs Insights, CloudWatch | Role `svp-<env>-grafana` (trong org) | AMP, CloudWatch Logs, CloudWatch; KMS theo `kms:ViaService` | Ngoài RCP; KMS: principal trong org |
| Người dùng đăng nhập AMG | Identity Center của management | AMG | Ngoài RCP; RCP không áp lên management |
| Grafana Operator gọi API AMG | Token service account Grafana | API HTTP của AMG | Không phải API AWS: ngoài SCP, RCP; qua NAT |
| Script buổi tạo token | `SvpAdmin` của env | `grafana:CreateWorkspaceServiceAccountToken`, `DeleteWorkspaceServiceAccountToken`; Secrets Manager | Principal trong org |
| Terraform tạo workspace AMP, AMG, log group, Transaction Search | `SvpAdmin` của env | AMP, AMG, CloudWatch Logs, X-Ray, KMS, IAM | SCP không chặn dịch vụ nào ở `ap-southeast-1`; Identity Center ở `sso_region` của `aws/org`: phép thử trước khi dựng tạo workspace qua đúng bộ SCP |

SCP `svp-protect-baseline` không chạm tài nguyên nào ở đây; `svp-deny-iam-users`: không IAM user. Không luồng nào cần ngoại lệ.

## Nguồn

- [N1] AWS Prescriptive Guidance, "Best practices for streamlining Amazon EKS observability" (2025-04):
  <https://docs.aws.amazon.com/prescriptive-guidance/latest/amazon-eks-observability-best-practices/introduction.html> (trang trả 404 ngày đọc; nội
  dung qua bản trích của công cụ tìm kiếm); AWS Observability Best Practices, FAQ AMP:
  <https://github.com/aws-observability/observability-best-practices/blob/main/docs/en/faq/amp.md>
- [N2] AMP, workspace configuration: <https://docs.aws.amazon.com/prometheus/latest/userguide/AMP-workspace-configuration.html>;
  `UpdateWorkspaceConfiguration`: <https://docs.aws.amazon.com/prometheus/latest/APIReference/API_UpdateWorkspaceConfiguration.html>; retention mặc
  định: <https://docs.aws.amazon.com/prometheus/latest/userguide/what-is-Amazon-Managed-Service-Prometheus.html>
- [N3] AMP, encryption at rest: <https://docs.aws.amazon.com/prometheus/latest/userguide/encryption-at-rest-Amazon-Service-Prometheus.html>
- [N4] AMP, dedup HA: <https://docs.aws.amazon.com/prometheus/latest/userguide/AMP-ingest-dedupe.html>, với Prometheus Operator:
  <https://docs.aws.amazon.com/prometheus/latest/userguide/Send-high-availability-data-operator.html>
- [N5] AMP Alertmanager: <https://docs.aws.amazon.com/prometheus/latest/userguide/AMP-alertmanager-receiver.html>,
  <https://docs.aws.amazon.com/prometheus/latest/userguide/AMP-alertmanager-config.html>,
  <https://docs.aws.amazon.com/prometheus/latest/userguide/AMP-alertmanager-receiver-AMPpermission.html>
- [N6] AMP quotas: <https://docs.aws.amazon.com/prometheus/latest/userguide/AMP_quotas.html>
- [N7] AMP, cách ingest: <https://docs.aws.amazon.com/prometheus/latest/userguide/AMP-ingest-methods.html>; `queue_config`:
  <https://docs.aws.amazon.com/prometheus/latest/userguide/AMP-onboard-ingest-metrics-new-Prometheus.html>; managed collector:
  <https://docs.aws.amazon.com/prometheus/latest/userguide/AMP-collector-how-to.html>
- [N8] AWS blog, "Introducing native histogram support in Amazon Managed Service for Prometheus":
  <https://aws.amazon.com/blogs/mt/introducing-native-histogram-support-in-amazon-managed-service-for-prometheus/>
- [N9] AMP, chi tiết workspace: <https://docs.aws.amazon.com/prometheus/latest/userguide/AMP-find-workspace-details.html>; API `WorkspaceDescription`:
  <https://docs.aws.amazon.com/prometheus/latest/APIReference/API_WorkspaceDescription.html>
- [N10] Service Authorization Reference: AMP <https://docs.aws.amazon.com/service-authorization/latest/reference/list_amazonmanagedserviceforprometheus.html>,
  CloudWatch Logs <https://docs.aws.amazon.com/service-authorization/latest/reference/list_amazoncloudwatchlogs.html>, X-Ray
  <https://docs.aws.amazon.com/service-authorization/latest/reference/list_awsx-ray.html>, AMG
  <https://docs.aws.amazon.com/service-authorization/latest/reference/list_amazonmanagedgrafana.html>; JSON AMP, Logs:
  <https://servicereference.us-east-1.amazonaws.com/v1/aps/aps.json>, <https://servicereference.us-east-1.amazonaws.com/v1/logs/logs.json>
- [N11] Giá AMP: <https://aws.amazon.com/prometheus/pricing/>; Price List `AmazonPrometheus` `ap-southeast-1`:
  <https://pricing.us-east-1.amazonaws.com/offers/v1.0/aws/AmazonPrometheus/current/ap-southeast-1/index.json>
- [N12] CloudWatch, endpoint OTLP: <https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/CloudWatch-OTLPEndpoint.html>, cài nhanh với
  Collector: <https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/CloudWatch-OTLPSimplesetup.html>, endpoint HTTP của Logs:
  <https://docs.aws.amazon.com/AmazonCloudWatch/latest/logs/CWL_HTTP_Endpoints.html>; thông báo 2025-04:
  <https://aws.amazon.com/about-aws/whats-new/2025/04/amazon-cloudwatch-logs-increases-log-event-size-1-mb>
- [N13] CloudWatch Logs, mã hoá KMS: <https://docs.aws.amazon.com/AmazonCloudWatch/latest/logs/encrypt-log-data-kms.html>; `CreateLogGroup`:
  <https://docs.aws.amazon.com/AmazonCloudWatchLogs/latest/APIReference/API_CreateLogGroup.html>
- [N14] Transaction Search: <https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/Enable-TransactionSearch.html>; X-Ray OTLP:
  <https://docs.aws.amazon.com/xray/latest/devguide/xray-opentelemetry-bearer-token.html>
- [N15] X-Ray `BatchGetTraces`: <https://docs.aws.amazon.com/xray/latest/api/API_BatchGetTraces.html>; plugin: <https://github.com/grafana/x-ray-datasource>
- [N16] Giá CloudWatch: <https://aws.amazon.com/cloudwatch/pricing/>; Price List `AmazonCloudWatch`, `AWSXRay` `ap-southeast-1`:
  <https://pricing.us-east-1.amazonaws.com/offers/v1.0/aws/AmazonCloudWatch/current/ap-southeast-1/index.json>,
  <https://pricing.us-east-1.amazonaws.com/offers/v1.0/aws/AWSXRay/current/ap-southeast-1/index.json>
- [N17] Container Insights OTel: <https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/container-insights-eks-otel.html>, so sánh:
  <https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/container-insights-eks-compare.html>
- [N18] What's New, CloudWatch OTel metrics và PromQL: <https://aws.amazon.com/about-aws/whats-new/2026/06/amazon-cloudwatch-otel-metrics/>
- [N19] Giá AMG: <https://aws.amazon.com/grafana/pricing/>; FAQ: <https://aws.amazon.com/grafana/faqs/>
- [N20] AMG với Organizations: <https://docs.aws.amazon.com/grafana/latest/userguide/AMG-and-Organizations.html>; ứng dụng dùng Identity Center:
  <https://docs.aws.amazon.com/singlesignon/latest/userguide/awsapps-that-work-with-identity-center.html>; nhiều region:
  <https://docs.aws.amazon.com/singlesignon/latest/userguide/multi-region-application-use.html>; re:Post:
  <https://repost.aws/questions/QU-2T0Y7fLTrGW2AOs_34lIw>
- [N21] AMG, quyền: <https://docs.aws.amazon.com/grafana/latest/userguide/AMG-manage-permissions.html>; `CreateWorkspace`:
  <https://docs.aws.amazon.com/grafana/latest/APIReference/API_CreateWorkspace.html>; tạo workspace:
  <https://docs.aws.amazon.com/grafana/latest/userguide/AMG-create-workspace.html>
- [N22] AMG, VPC: <https://docs.aws.amazon.com/grafana/latest/userguide/AMG-configure-vpc.html>; VPC endpoint (dạng URL):
  <https://docs.aws.amazon.com/grafana/latest/userguide/VPC-endpoints.html>
- [N23] AMG, phiên bản: <https://docs.aws.amazon.com/grafana/latest/userguide/version-differences.html>; service account:
  <https://docs.aws.amazon.com/grafana/latest/userguide/v12-authenticating-grafana-apis.html>; token:
  <https://docs.aws.amazon.com/grafana/latest/APIReference/API_CreateWorkspaceServiceAccountToken.html>; quota:
  <https://docs.aws.amazon.com/grafana/latest/userguide/AMG_quotas.html>; vai trò Grafana (data source):
  <https://docs.aws.amazon.com/grafana/latest/userguide/Grafana-user-roles.html>
- [N24] AMG, region: <https://docs.aws.amazon.com/grafana/latest/userguide/what-is-Amazon-Managed-Service-Grafana.html>
- [N25] Grafana Operator v5.25.0: <https://github.com/grafana/grafana-operator/releases/tag/v5.25.0>; Grafana ngoài:
  <https://raw.githubusercontent.com/grafana/grafana-operator/v5.25.0/examples/grafana/external_grafana/README.md>; bài AWS 2023:
  <https://aws.amazon.com/blogs/mt/using-open-source-grafana-operator-on-your-kubernetes-cluster-to-manage-amazon-managed-grafana>
- [N26] Data source Amazon Prometheus: <https://github.com/grafana/grafana-amazonprometheus-datasource>; kiểu xác thực:
  <https://raw.githubusercontent.com/grafana/grafana-aws-sdk-react/main/src/providers.ts>
- [N27] ACK `prometheusservice-controller`: <https://github.com/aws-controllers-k8s/prometheusservice-controller/releases>; trạng thái dịch vụ:
  <https://aws-controllers-k8s.github.io/docs/services>; deletion policy:
  <https://github.com/aws-controllers-k8s/community/blob/main/docs/content/docs/user-docs/deletion-policy.md>; adoption:
  <https://github.com/aws-controllers-k8s/community/blob/main/docs/content/docs/user-docs/features.md>; IAM:
  <https://aws-controllers-k8s.github.io/docs/guides/configure-iam>
- [N28] OpenTelemetry Collector contrib v0.162.0:
  <https://github.com/open-telemetry/opentelemetry-collector-contrib/blob/v0.162.0/exporter/prometheusremotewriteexporter/README.md>,
  <https://github.com/open-telemetry/opentelemetry-collector-contrib/blob/v0.162.0/exporter/prometheusremotewriteexporter/config.go>,
  <https://github.com/open-telemetry/opentelemetry-collector-contrib/blob/v0.162.0/exporter/prometheusremotewriteexporter/factory.go>,
  <https://github.com/open-telemetry/opentelemetry-collector-contrib/blob/v0.162.0/extension/sigv4authextension/README.md>,
  <https://github.com/open-telemetry/opentelemetry-collector-contrib/blob/v0.162.0/connector/servicegraphconnector/README.md>,
  <https://github.com/open-telemetry/opentelemetry-collector-contrib/blob/v0.162.0/exporter/awscloudwatchlogsexporter/README.md>
- [N29] Prometheus v3.15.0, cấu hình OTLP và `remote_write`: <https://github.com/prometheus/prometheus/blob/v3.15.0/docs/configuration/configuration.md>;
  metric của queue remote write: <https://github.com/prometheus/prometheus/blob/v3.15.0/storage/remote/queue_manager.go>; tuning remote write:
  <https://prometheus.io/docs/practices/remote_write/>
- [N30] kube-prometheus-stack 92.17.1:
  <https://github.com/prometheus-community/helm-charts/blob/kube-prometheus-stack-92.17.1/charts/kube-prometheus-stack/values.yaml>; luật
  `PrometheusRemoteWriteBehind`:
  <https://github.com/prometheus-community/helm-charts/blob/kube-prometheus-stack-92.17.1/charts/kube-prometheus-stack/templates/prometheus/rules-1.14/prometheus.yaml>
- [N31] Tempo, service graph: <https://grafana.com/docs/tempo/latest/metrics-from-traces/service_graphs/>
- [N32] Collector, internal telemetry: <https://opentelemetry.io/docs/collector/internal-telemetry/>; issue #13778:
  <https://github.com/open-telemetry/opentelemetry-collector/issues/13778>
- [N33] Argo Rollouts v1.10.1: <https://github.com/argoproj/argo-rollouts/blob/v1.10.1/docs/analysis/prometheus.md>,
  <https://github.com/argoproj/argo-rollouts/blob/v1.10.1/metricproviders/prometheus/prometheus.go>, issue #4536:
  <https://github.com/argoproj/argo-rollouts/issues/4536>, PR #5010: <https://github.com/argoproj/argo-rollouts/pull/5010>; EKS Pod Identity, SDK
  tối thiểu: <https://docs.aws.amazon.com/eks/latest/userguide/pod-id-minimum-sdk.html>; `prometheus/sigv4` v0.5.0:
  <https://github.com/prometheus/sigv4/blob/v0.5.0/sigv4.go>
- [N34] AWS Observability Best Practices, Container Insights cho EKS:
  <https://github.com/aws-observability/observability-best-practices/blob/main/docs/en/guides/containers/aws-native/eks/amazon-cloudwatch-container-insights.md>
- [N35] Security Hub CSPM, FSBP: <https://docs.aws.amazon.com/securityhub/latest/userguide/fsbp-standard.html>; control CloudWatch:
  <https://docs.aws.amazon.com/securityhub/latest/userguide/cloudwatch-controls.html>
- [N36] Terraform AWS provider, CHANGELOG (`aws_xray_trace_segment_destination`, `aws_xray_indexing_rule` từ 6.46.0;
  `aws_prometheus_workspace_configuration`): <https://github.com/hashicorp/terraform-provider-aws/blob/main/CHANGELOG.md>
- [N37] AWS Billing, consolidated bills ("To measure usage, AWS treats all accounts in an organization as a single account"; bậc giá và free tier
  tính trên usage gộp): <https://docs.aws.amazon.com/awsaccountbilling/latest/aboutv2/con-bill-blended-rates.html>; giá AMP ("As part of the AWS
  Free Tier": 40 M mẫu ingest mỗi tháng): <https://aws.amazon.com/prometheus/pricing/>
