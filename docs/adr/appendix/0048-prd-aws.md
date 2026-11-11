# Phụ lục ADR-0048: prd trên AWS: AWS Organizations với account `svp-stg`, `svp-prd` và management chỉ để quản trị; prd chuẩn production từ cùng module với stg; bootstrap EKS bằng GitOps Bridge ở root Terraform riêng; Secret của EKS từ Secrets Manager; prd ghim commit `svp-gitops` mà stg đã chạy

Phụ lục của [ADR-0048](../0048-prd-aws.md): bảng phương án, chi tiết rút khỏi ADR (xếp theo §), nguyên mẫu hai tầng, chi phí H₀, O₀, R
và nguồn. Mọi nguồn đọc ngày 2026-11-05.

## Phương án

| Mục | Phương án | Trạng thái ngành | Được | Mất | Nguồn |
| --- | --- | --- | --- | --- | --- |
| Account | Một account sandbox (ADR-0034 §3) | Cũ cho prd | Không thêm gì | Không SCP; stg, prd cùng ranh giới quyền | [N1] |
| Account | Stg ở management, prd account thành viên | Lệch khuyến nghị | Một account ít hơn | Workload ở management; SCP không áp lên management | [N1] |
| Account | **Organizations, OU `Workloads`, `svp-stg`, `svp-prd`, Terraform thuần** | Hiện hành | Mọi thứ qua PR và `make check`; SCP áp lên cả hai env | Không control phát hiện, không Account Factory | [N1], [N10] |
| Account | AWS Control Tower | Hiện hành | Landing zone, guardrail, account dùng chung cho log và audit | AWS Config ghi mọi thay đổi, tốn thêm khi tài nguyên dựng và xoá mỗi buổi | [N2] |
| Account | Account Factory for Terraform | Hiện hành | Tạo account bằng pipeline Terraform | Cần landing zone Control Tower có sẵn | [N3] |
| Log | Log Archive, Audit account riêng (AWS SRA) | Hiện hành cho org lớn | Log tách khỏi người quản trị management | Thêm hai account, quyền chéo | [N4] |
| Bootstrap | **Root riêng `aws/gitops/<env>`** | Hiện hành (mẫu GitOps Bridge, EKS Blueprints) | Hai lần apply như provider khuyên; plan root env không cần tunnel | Thêm một root và một state mỗi env | [N5], [N13], [N19] |
| Bootstrap | Trong chính root env | Gặp nhiều | Một lệnh apply | Provider `kubernetes` cần API ngay lúc plan; plan prd phải mở tunnel | [N5] |
| Ghim | **`gitopsRevision` + hai tầng Application** | Versioned base, thông dụng | Không thêm công cụ; dấu vết và rollback bằng PR | Thêm tầng `argocd/root` | [N17] |
| Ghim | ApplicationSet git files generator đọc `envs/<env>/charts.yaml` | Hiện hành | Không thêm chart | Chỉ đưa nội dung một file thành tham số; chart ở commit ghim vẫn đọc `envs/<env>/` cũ một lần promote | [N6] |
| Ghim | Kargo v1.12 | Hiện hành | Promote theo stage có giao diện | Thêm controller, CRD, cách làm thứ hai bên cạnh `promote-prd` | [N7] |
| Ghim | GitOps Promoter v0.48 + Source Hydrator | Mới (argoproj-labs; Hydrator beta từ Argo CD 3.5) | Manifest đã render nằm trong git | Đổi cách lưu cấu hình sang nhánh hydrate | [N8] |
| API prd | **Endpoint private + SSM port forwarding qua `t4g.nano`** | Thông dụng | Không cổng mở, không khoá SSH, có log phiên | Mỗi lệnh `kubectl` cần tunnel | [N9] |
| API prd | AWS Client VPN | Hiện hành | VPN cho cả nhóm | $0,15/giờ mỗi subnet gắn + $0,05/giờ mỗi kết nối | <https://pricing.us-east-1.amazonaws.com/offers/v1.0/aws/AmazonVPC/current/ap-southeast-1/index.json> (phát hành 2026-11-03) |
| Edge prd | **AWS WAF web ACL bằng Terraform** | Thông dụng | Dựng và xoá trong buổi, tính theo giờ | Module với provider `us-east-1` | <https://aws.amazon.com/waf/pricing/> |
| Edge prd | CloudFront flat-rate plan có WAF kèm | Mới | Giá cố định theo tháng | Theo tháng, không theo buổi | ADR-0034 [N10] |

## Chi tiết rút khỏi ADR

### 1. Account và quyền

- Profile và biến (không commit; người học tạo profile bằng `aws configure sso`): management `anhnv-sso` + `SVP_AWS_MGMT_ACCOUNT_ID`; stg `anhnv-stg` +
  `SVP_AWS_STG_ACCOUNT_ID`; prd `anhnv-prd` + `SVP_AWS_PRD_ACCOUNT_ID`. `SVP_AWS_ACCOUNT_ID` bỏ hẳn; `TF_VAR_account_id` không nằm trong `.envrc`
  mà đặt ngay trong lệnh từ biến của account đó. Mọi lệnh `aws` viết sẵn ghi `--region`: `ap-southeast-1` cho dịch vụ theo region và STS, `us-east-1`
  cho Organizations, `<sso_region>` cho `sso-admin`, `identitystore`. Script buổi lấy profile và biến từ bảng theo env ở `infra/aws/scripts/lib.sh`.

### 2. State, DNS, budget mỗi account

- State: root baseline `aws/accounts/<env>` (profile của env) gọi module `account-baseline`: bucket `svp-tfstate-<account>-<region>`, KMS key
  `alias/svp-tfstate` (account quản trị key; mã hoá, giải mã chỉ role SSO của `SvpAdmin`), versioning, chặn public, TLS-only, `prevent_destroy` trên
  bucket và key; state của chính baseline ở `aws/accounts/<env>/terraform.tfstate` (dựng bằng state local rồi `init -migrate-state`). Output
  `backend_hcl` → `infra/aws/backend-<env>.hcl` (git ignore): `bucket`, `region`, `kms_key_id`, `encrypt`, `use_lockfile`, không `key`. Key mỗi root
  qua `-backend-config` thứ hai: baseline `aws/accounts/<env>/terraform.tfstate`, root env `aws/<env>/terraform.tfstate`, root gitops
  `aws/gitops/<env>/terraform.tfstate`. `tf.sh <env> init` luôn `terraform init -reconfigure -backend-config=../../backend-<env>.hcl
  -backend-config=key=<key>`. Bucket management (`aws/backend.hcl`) giữ đúng ba state: `aws/bootstrap`, `aws/org`, `github/`.
- DNS: zone lab `aws.<miền>` ở `aws/bootstrap` giữ nguyên; baseline tạo `<env>.aws.<miền>`; `aws/bootstrap` thêm biến `delegated_subdomains` (tên zone
  con → bốn name server, mặc định `{}`, giá trị trong `bootstrap.auto.tfvars` không commit) sinh bản ghi `NS`. Precondition của root env chỉ chạy lúc
  plan; bằng chứng apex được nhận là plan của người học.
- Budget: module `account-baseline` tạo budget tháng (50/80/100 % thực tế, 100 % dự báo), hạn mức qua biến, email qua biến không commit.

### 3. Mức prd, wiring và luật kiểm

Biến của module (mặc định là giá trị stg); root đặt chúng qua biến tương ứng của `<env>.tfvars`. Cột stg là `stg.tfvars` hiện tại.

| Module | Biến | stg | prd |
| --- | --- | --- | --- |
| network | `az_count` | 2 | 3 |
| network | `single_nat_gateway` | `true` | `false` (một NAT mỗi AZ) |
| network | `flow_log_enabled` | `false` | `true` (retention ở `prd.tfvars`) |
| network | `s3_endpoint_restricted`, `s3_endpoint_buckets` | `false`, `[]` | `true`; bucket `uploads`, `media` của env, bucket layer ECR của region, `prod-registry-k8s-io-<region>` |
| eks | `endpoint_public_access` | `true`, CIDR /32 của người học | `false` (§4) |
| eks | `secrets_kms_encryption` | `false` | `true` |
| eks | `control_plane_log_types` | `[]` | `["api", "audit", "authenticator"]` |
| eks | `node_capacity_type` | `SPOT` | `ON_DEMAND` |
| eks | `node_instance_types` | `m7g.large` + loại cùng cỡ | `m7g.large` + loại Graviton cùng cỡ |
| eks | `node_min_size`, `node_desired_size`, `node_max_size` | 3, 3, 5 | 3, 3, 6, trải 3 AZ |
| rds | `instance_class` | `db.t4g.small` | `db.t4g.medium` (lớp nhỏ nhất có Database Insights/Performance Insights) |
| rds | `multi_az` | `false` | `true` |
| rds | `backup_retention_period` | 1 | 7 |
| rds | `delete_automated_backups` | `true` | `false` |
| rds | `deletion_protection` | `false` | `true` |
| rds | `skip_final_snapshot` | `true` | `false` |
| rds | `performance_insights_enabled` | `false` | `true`, 7 ngày (mức miễn phí; Database Insights Standard) |
| rds | `monitoring_interval` | 0 | 60 |
| rds | `cloudwatch_logs_exports` | `[]` | `["postgresql", "upgrade"]`, log group do Terraform tạo có retention |
| media | `force_destroy` | `true` | `false` |
| media | `versioning_enabled` | `false` | `true`, bản cũ hết hạn sau 30 ngày |
| media | `access_logging_enabled` | `false` | `true`, bucket log riêng |
| media | `web_acl_arn` | `null` | ARN của module `waf` |
| media | `price_class` | `PriceClass_200` | `PriceClass_200` |

- Endpoint S3 có policy giới hạn bucket phải cho thêm bucket mà `registry.k8s.io` chuyển hướng tới cho client trong AWS
  (`prod-registry-k8s-io-<region>`) cùng bucket layer của ECR, không thì image của registry đó (ExternalDNS…) kéo lỗi trên subnet private.
- Wiring: mọi biến của root và lời gọi module có ở stg viết ở `aws/envs/stg/`, root prd chép sang. Danh sách khác biệt được phép, đủ cho hai cặp root:
  (a) dòng `env = "<env>"` của `locals` (tên, tag suy ra từ nó); (b) phần riêng của `aws/envs/prd` ghi ở ADR §3; (c) không gì khác trong `*.tf`.
  `kubeconfig_command`, host và TLS server name của API nằm ở output hay tính từ remote state. Phép so: `diff` hai cây `*.tf` sau khi bỏ đúng (a) và
  các file, khối (b) theo tên. Root prd: `local.env = "prd"`, tên `svp-prd`, `default_tags` `Stack=prd`, biến cá nhân trong `prd.auto.tfvars` không commit.

- Không `if env == …` trong module hay root. Ba lớp kiểm: (1) test mỗi module có một `run` với giá trị mức prd `assert` thuộc tính bảo vệ (Multi-AZ,
  deletion protection, versioning, KMS, log…); (2) `make trivy DIRS=aws/envs/prd` quét với `prd.tfvars`, không ngoại lệ chỉ-stg; (3) phép kiểm cuối
  đối chiếu `prd.tfvars` với bảng trên và diff hai root. Root prd không có `validation` ép giá trị prd (gỡ theo §9 của ADR).
- `make test` chỉ chạy `terraform test` của module (guard nhận đúng một `mock_provider "aws"`, không `alias`): module chỉ dùng provider mặc định (WAF
  là module riêng, root truyền `providers = { aws = aws.us_east_1 }`; `gitops-bridge` không resource). Root kiểm bằng `validate`, `tflint`, `trivy`;
  `validate` không chạy `validation` hay `precondition`.
- Ngoại lệ ghi `Scope: stg only` (comment `#trivy:ignore:<id>` hay `.trivyignore.yaml`) nằm ở lời gọi module trong root stg hay có điều kiện thuộc
  tính khớp giá trị stg; quét module riêng lẻ vẫn xanh; `Scope: every environment` giữ được ở prd. Phép thử âm: đổi tạm một giá trị của
  `prd.tfvars` về giá trị stg (vd `eks_endpoint_public_access = true`), `make trivy DIRS=aws/envs/prd` phải exit khác 0 với đúng finding đó, rồi trả
  lại file; `shasum` trước và sau bằng nhau.

### 4. Truy cập API của prd và edge

- Root `aws/gitops/prd` tới API qua cùng tunnel: `prd.tfvars` của nó chỉ đặt host loopback `https://127.0.0.1:<cổng>`; TLS server name tính trong root
  từ `cluster_endpoint` của remote state, không commit; hai provider `helm`, `kubernetes` dùng cùng một local cho host và TLS server name.
- Web ACL WAF: scope `CLOUDFRONT`, nhóm luật managed `AWSManagedRulesCommonRuleSet`, `AWSManagedRulesKnownBadInputsRuleSet`, một luật rate-based theo
  IP (`rate_limit`, mặc định 2 000 request mỗi 5 phút).

### 5. Secret trên EKS

- Map namespace → entry là local của module `external-secrets`, chép từ render của chart `svp-cluster` với `externalSecrets.store: aws`, `s3.mode:
  external`, `externalSecrets.argocdNotifications: true`: `argocd` [`argocd-notifications`]; `keda` [`kafka-users`]; `svp` [`glitchtip-runtime`,
  `jwt-signing`, `jwt-verify`, `kafka-users`, `pg-roles`, `web`]; `svp-data` [`kafka-admin`, `kafka-users`, `pg-roles`, `pg-superuser`]; `svp-obs`
  [`glitchtip-runtime`, `obs`, `pg-roles`]. Controller ESO ở namespace `external-secrets`, ServiceAccount theo `gitops/base/external-secrets.yaml`.
- `make eks-secrets` kiểm account của `AWS_PROFILE` bằng biến của env trước lần ghi đầu; `--region` ghi trong lệnh; bộ đọc `.env` chặt có sẵn.
- `glitchtip-runtime` có ba key rỗng từ lần đầu để ExternalSecret của wave 1 Ready trước khi GlitchTip (wave 5) chạy; `glitchtip-init.sh` trên EKS ghi
  giá trị vào Secrets Manager rồi force-sync ba ExternalSecret và restart như đường k3d.

### 6. Bootstrap EKS

Phác thảo hai đối tượng của §6 (giá trị giả của repo public; tên, khoá như ADR). Cluster Secret:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: in-cluster
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: cluster
    svp.io/env: prd
    svp.io/platform: eks
    svp.io/node-arch: arm64
  annotations:
    svp.io/cluster-values: '{"name":"svp-prd","region":"ap-southeast-1","externalSecretsRoles":{"svp":"arn:aws:iam::222222222222:role/svp-prd-external-secrets-svp"}}'
    svp.io/telegram-chat-id: ""
stringData:
  name: in-cluster
  server: https://kubernetes.default.svc
  config: '{"tlsClientConfig":{"insecure":false}}'
```

ApplicationSet `svp-bootstrap` (phần `templatePatch`; `template` như ADR §6):

```yaml
templatePatch: |
  {{- $chat := index .metadata.annotations "svp.io/telegram-chat-id" }}
  {{- if $chat }}
  metadata:
    annotations:
      notifications.argoproj.io/subscribe.on-sync-failed.telegram: {{ $chat | toJson }}
      notifications.argoproj.io/subscribe.on-health-degraded.telegram: {{ $chat | toJson }}
  {{- end }}
  spec:
    source:
      helm:
        valuesObject:
          env: {{ index .metadata.labels "svp.io/env" | toJson }}
          platform: {{ index .metadata.labels "svp.io/platform" | toJson }}
          nodeArch: {{ index .metadata.labels "svp.io/node-arch" | toJson }}
          cluster: {{ index .metadata.annotations "svp.io/cluster-values" | fromYaml | toJson }}
```

- Cluster generator lấy `metadata.labels.<key>`, `metadata.annotations.<key>` của cluster Secret; cluster cục bộ chỉ được chọn theo label khi có
  Secret khai báo cho nó [N15], [N20]. `templatePatch` cần `goTemplate: true`, không đổi được `spec.project` [N16]; `fromYaml`, `toJson` có trong Go
  template của ApplicationSet [N16].
- Bootstrap không còn kiểm bản phát hành (giữ ở promote và admission Kyverno), không còn vòng chờ (người học chạy `kubectl wait`, `argocd app wait`).
- Module `gitops-bridge` tự viết theo mẫu thay vì dùng module cộng đồng `terraform-helm-gitops-bridge` (bản phát hành cuối v0.0.2, 2023-12-16 [N13]):
  module chỉ tính giá trị nên test được bằng `mock_provider`, root giữ resource.

### 7. Ghim revision của prd

- Vì sao hai tầng: generator của ApplicationSet chỉ đưa nội dung một file thành tham số, nên chart ở R sẽ đọc `envs/<env>/` cũ một lần promote; hai tầng
  giữ mọi luật render trong Helm, kiểm được bằng `helm template` (phụ lục, "Nguyên mẫu hai tầng").

### 9. Gỡ và kết thúc buổi

- `teardown.tfvars` chỉ chứa bảo vệ cần nhấc để xoá, mỗi dòng một comment lý do; một dòng ngoài hai dòng của ADR chỉ khi `destroy` không chạy được thiếu nó.
- Kết thúc buổi, theo thứ tự, bước sau chỉ khi bước trước xong: (1) destroy `aws/gitops/<env>` rồi `aws/envs/<env>`; (2) chỉ prd: đọc final snapshot
  (`describe-db-snapshots`), xoá nó và mọi backup tự động được giữ (`describe-db-instance-automated-backups` rồi lệnh xoá); (3) `sweep.sh <env>`
  (profile của env) liệt kê từng mục còn được phép là "kept"/"pending deletion", exit 0 chỉ khi phần còn lại rỗng, còn gì khác thì in lệnh xoá và exit
  khác 0; (4) `sweep.sh mgmt` (profile `anhnv-sso`), cùng luật, chỉ `Stack=bootstrap|org`.

## Nguyên mẫu hai tầng

Chạy 2026-11-05, Helm v4.3.1, trên bản sao `git archive origin/main` của `svp-gitops` trong thư mục tạm (không đổi repo nào): thêm chart
`argocd/root` (đọc `files/envs/<env>/*`, render một Application `svp-apps`) và sửa `argocd/apps/templates/applications.yaml` của bản sao để đọc
`envFiles` từ values. Cluster là `deploy/ci/cluster-values.example.yaml`.

Bản đầu ghi overlay, image bằng `$env/` qua một source `ref: env` ở `refs/heads/main` bên cạnh `ref: values` ở commit ghim. `helm template` render
được, nhưng repo-server của Argo CD v3.5.5 từ chối khi sinh manifest: các source `ref` mà file values trỏ tới cùng một repo phải cùng
`targetRevision` [N21], nên prd có khoá sẽ `ComparisonError` ở mọi Application có overlay hay image. Bản dùng: tầng 1 chuyển nội dung overlay,
image (`envFiles.overlays`, `envFiles.images`: tên file → nội dung), tầng 2 gộp chúng cùng phần mẫu sinh ra vào `valuesObject` (`mustMergeOverwrite`
trên bản sao, cùng kết quả với cách Helm gộp file values: thử với `false`, `""`, `0`, `null`, list rỗng, map đổi thành scalar và ngược lại, so với
`*` của jq), mỗi Application chỉ còn một source `svp-gitops`.

```sh
helm template svp-root argocd/root --namespace argocd --set env=prd --set platform=eks --values cluster.yaml   # charts.yaml của bản sao có gitopsRevision
helm template svp-apps argocd/apps --namespace argocd --values t2-prd-values.yaml                              # valuesObject của svp-apps ở trên
helm template svp-root argocd/apps --namespace argocd --set env=prd --set platform=eks \
  --set targetRevision=refs/heads/main --values cluster.yaml                                                    # render một tầng hiện nay, để so
```

- prd có khoá: `svp-apps` có `targetRevision` là commit ghim, `envFiles` gồm ba khoá của `charts.yaml` (không `gitopsRevision`), nội dung 9
  overlay, 7 image. Tầng 2 ra 25 Application, mỗi Application nhiều nhất một source `svp-gitops` (`ref: values` ở commit ghim); Application
  `gateway` đọc `$values/base/services/gateway.yaml`, `valuesObject` là overlay `env.SENTRY_ENVIRONMENT`, khối `image` rồi phần mẫu sinh ra.
- Với mỗi Application, values đã ghép (file values theo thứ tự rồi `valuesObject`, Helm tự ghép) và phần còn lại của Application giống hệt render
  một tầng hiện nay ở stg trên k3d (25/25); trên eks chỉ khác ở phần nhánh thay đổi có chủ đích (store `aws` của `svp-cluster`; ở prd thêm
  `redpanda`, `svp-data`).
- Ca âm: `gitopsRevision: main` làm tầng 1 fail (`gitopsRevision is "main"`); một overlay `envs/prd/no-such.yaml` làm tầng 2 fail (`an overlay
  is <name>.yaml, name a component of components.json`); `envFiles.overlays` là danh sách tên (dạng của bản đầu) làm tầng 2 fail
  (`envFiles.overlays is no map of a file's name to its content`).

## Chi phí

Đơn vị và công thức theo ADR §10: một buổi T = 4 giờ; H theo giờ khi prd chạy; O theo lượng dùng trong một buổi; R theo tháng giữa các buổi, không
cộng vào trần. Region `ap-southeast-1` (WAF của CloudFront: `us-east-1`); tháng 730 giờ. Phần Kafka (H_k, O_k) và trần C ở [ADR-0049](../0049-kafka-prd.md).

### H₀: theo giờ khi prd chạy, chưa gồm Kafka

| Hạng mục | Lượng | Giá | Nguồn, ngày đọc | USD/giờ |
| --- | --- | --- | --- | --- |
| EKS control plane | 1 cluster | $0,10/giờ | <https://pricing.us-east-1.amazonaws.com/offers/v1.0/aws/AmazonEKS/current/ap-southeast-1/index.json> (phát hành 2026-10-27), đọc 2026-11-05 | 0,100 |
| Node `m7g.large` on-demand | 3 | $0,102/giờ | <https://aws.amazon.com/ec2/pricing/on-demand/> (dữ liệu của trang, phát hành 2026-11-04), đọc 2026-11-05 | 0,306 |
| NAT gateway | 3 (một mỗi AZ) | $0,059/giờ | <https://pricing.us-east-1.amazonaws.com/offers/v1.0/aws/AmazonEC2/current/ap-southeast-1/index.csv> (phát hành 2026-11-04), đọc 2026-11-05 | 0,177 |
| IPv4 công khai | 6 (3 NAT, NLB 3 AZ) | $0,005/IP-giờ | <https://pricing.us-east-1.amazonaws.com/offers/v1.0/aws/AmazonVPC/current/ap-southeast-1/index.json> (phát hành 2026-11-03), đọc 2026-11-05 | 0,030 |
| NLB | 1, ~1 NLCU (ước lượng) | $0,0252/giờ + $0,006/NLCU-giờ | <https://pricing.us-east-1.amazonaws.com/offers/v1.0/aws/AWSELB/current/ap-southeast-1/index.json> (phát hành 2026-11-02), đọc 2026-11-05 | 0,031 |
| RDS PostgreSQL `db.t4g.medium` Multi-AZ | 1 | $0,203/giờ | <https://pricing.us-east-1.amazonaws.com/offers/v1.0/aws/AmazonRDS/current/ap-southeast-1/index.csv> (phát hành 2026-10-29), đọc 2026-11-05 | 0,203 |
| RDS gp3 Multi-AZ | 20 GB | $0,276/GB-tháng | như dòng trên, đọc 2026-11-05 | 0,008 |
| EBS gp3 (đĩa node, PVC trừ Kafka, bastion) | ~130 GB (ước lượng) | $0,096/GB-tháng | AmazonEC2 `index.csv` như dòng NAT, đọc 2026-11-05 | 0,017 |
| Bastion `t4g.nano` | 1 | $0,0053/giờ | <https://aws.amazon.com/ec2/pricing/on-demand/> (dữ liệu của trang, phát hành 2026-11-04), đọc 2026-11-05 | 0,005 |
| WAF web ACL + 3 luật | 1 web ACL, 3 luật | $5 + 3 × $1 mỗi tháng, chia theo giờ | <https://pricing.us-east-1.amazonaws.com/offers/v1.0/aws/awswaf/current/us-east-1/index.json> (phát hành 2026-09-14), <https://aws.amazon.com/waf/pricing/>, đọc 2026-11-05 | 0,011 |
| KMS key mã hoá Secrets của EKS | 1 | $1/tháng | <https://pricing.us-east-1.amazonaws.com/offers/v1.0/aws/awskms/current/ap-southeast-1/index.json> (phát hành 2026-10-26), đọc 2026-11-05 | 0,001 |
| Secrets Manager | 11 (10 entry `svp/prd/*`, secret master RDS) | $0,40/secret-tháng, chia theo giờ lưu | <https://pricing.us-east-1.amazonaws.com/offers/v1.0/aws/AWSSecretsManager/current/ap-southeast-1/index.json> (phát hành 2026-09-11), <https://aws.amazon.com/secrets-manager/pricing/>, đọc 2026-11-05 | 0,006 |
| Database Insights Standard, Performance Insights 7 ngày | 1 instance | $0; chỉ retention thêm tính phí | <https://pricing.us-east-1.amazonaws.com/offers/v1.0/aws/AmazonCloudWatch/current/ap-southeast-1/index.json> (phát hành 2026-11-04), đọc 2026-11-05 | 0 |
| **H₀** | | | cộng các dòng trên, đọc 2026-11-05 | **~0,90** |

### O₀: theo lượng dùng trong một buổi, chưa gồm Kafka

| Hạng mục | Giả định lượng (ước lượng) | Giá | Nguồn, ngày đọc | USD/buổi |
| --- | --- | --- | --- | --- |
| Dữ liệu qua NAT | 15 GB (kéo image cho 3 node, cập nhật) | $0,059/GB | AmazonEC2 `index.csv` như H₀, đọc 2026-11-05 | 0,89 |
| CloudWatch Logs nạp vào | 2 GB (log control plane `api`, `audit`, `authenticator`, flow log, `postgresql`, enhanced monitoring) | $0,70/GB | AmazonCloudWatch `index.json` như H₀, đọc 2026-11-05 | 1,40 |
| Dữ liệu giữa AZ | 10 GB mỗi chiều | $0,01/GB mỗi chiều | AmazonEC2 `index.csv` như H₀, đọc 2026-11-05 | 0,20 |
| Node thêm khi đo | 2 node `m7g.large` × 1 giờ | $0,102/giờ | trang giá EC2 on-demand như H₀, đọc 2026-11-05 | 0,20 |
| S3 request và lưu trữ | 10 000 PUT, 100 000 GET, vài GB trong 4 giờ | $0,005/1 000 PUT, $0,004/10 000 GET, $0,025/GB-tháng | <https://pricing.us-east-1.amazonaws.com/offers/v1.0/aws/AmazonS3/current/ap-southeast-1/index.json> (phát hành 2026-11-04), đọc 2026-11-05 | 0,09 |
| Request qua WAF | 100 000 | $0,60/triệu | awswaf `us-east-1` như H₀, đọc 2026-11-05 | 0,06 |
| CloudFront | trong hạn mức miễn phí (1 TB, 10 triệu request mỗi tháng) | $0 | ADR-0034 [N10] <https://aws.amazon.com/cloudfront/pricing/>, đọc 2026-10-31 | 0 |
| Secrets Manager API, KMS request | vài nghìn | $0,05/10 000; KMS trong 20 000 miễn phí | AWSSecretsManager, awskms như H₀, đọc 2026-11-05 | ~0 |
| Final snapshot tới lúc xoá | 20 GB, dưới 1 giờ, trong phần backup miễn phí bằng dung lượng đã cấp | $0,095/GB-tháng phần vượt | AmazonRDS `index.csv` như H₀, đọc 2026-11-05 | 0 |
| **O₀** | | | cộng các dòng trên, đọc 2026-11-05 | **~2,8** |

Riêng phần chưa gồm Kafka: 4 × H₀ + O₀ ≈ $6,4 mỗi buổi; trần C của buổi prd cộng H_k, O_k ở [ADR-0049](../0049-kafka-prd.md).

### R: phí giữ giữa các buổi, theo tháng

| Hạng mục | Lượng | Giá | Nguồn, ngày đọc | USD/tháng |
| --- | --- | --- | --- | --- |
| KMS key `alias/svp-cloudtrail` (management) | 1 | $1/tháng; mỗi lần xoay vòng thứ nhất, thứ hai thêm $1/tháng | <https://aws.amazon.com/kms/pricing/>, đọc 2026-11-05 | 1,00 |
| KMS key `alias/svp-tfstate` (stg, prd) | 2 | như trên | <https://aws.amazon.com/kms/pricing/>, đọc 2026-11-05 | 2,00 |
| Organization trail, management event | bản sao đầu | $0 | <https://aws.amazon.com/cloudtrail/pricing/>, đọc 2026-11-05 | 0 |
| Bucket log của trail và access log | ~1 GB (ước lượng) | $0,025/GB-tháng | AmazonS3 `index.json` như O₀, đọc 2026-11-05 | 0,03 |
| Hosted zone `aws.<miền>` (management) | 1 | $0,50/zone-tháng (25 zone đầu) | <https://pricing.us-east-1.amazonaws.com/offers/v1.0/aws/AmazonRoute53/current/index.json> (phát hành 2026-11-04), đọc 2026-11-05 | 0,50 |
| Hosted zone `<env>.aws.<miền>` (stg, prd) | 2 | như trên | như trên, đọc 2026-11-05 | 1,00 |
| Bucket state (management, stg, prd) | vài MB (ước lượng) | $0,025/GB-tháng | AmazonS3 `index.json` như O₀, đọc 2026-11-05 | < 0,01 |
| Budget (org, stg, prd) | 3, không action | $0 | <https://aws.amazon.com/aws-cost-management/aws-budgets/pricing/>, đọc 2026-11-05 | 0 |
| Organizations, SCP | | $0 | <https://aws.amazon.com/organizations/faqs/>, đọc 2026-11-05 | 0 |
| IAM Identity Center | | $0 | <https://aws.amazon.com/iam/identity-center/faqs/>, đọc 2026-11-05 | 0 |
| KMS key của root env ở `PendingDeletion` | 1 mỗi env | $0 khi đang chờ xoá | <https://aws.amazon.com/kms/pricing/>, đọc 2026-11-05 | 0 |
| **R** | | | cộng các dòng trên, đọc 2026-11-05; năm thứ hai ~$7,6, từ năm thứ ba ~$10,6 nếu cả ba key xoay vòng tự động | **~4,6** |

## Nguồn

Đọc 2026-11-05.

- [N1] AWS Organizations, best practices for the management account: <https://docs.aws.amazon.com/organizations/latest/userguide/orgs_best-practices_mgmt-acct.html>
- [N2] AWS Control Tower: <https://docs.aws.amazon.com/controltower/latest/userguide/what-is-control-tower.html>, giá (AWS Config khi tài nguyên tạm dựng, xoá): <https://aws.amazon.com/controltower/pricing/>
- [N3] Account Factory for Terraform (cần landing zone Control Tower có sẵn): <https://docs.aws.amazon.com/controltower/latest/userguide/aft-overview.html>
- [N4] AWS Security Reference Architecture, Log Archive account: <https://docs.aws.amazon.com/prescriptive-guidance/latest/security-reference-architecture/log-archive.html>
- [N5] Provider Terraform `kubernetes`, mục "Stacking with managed Kubernetes cluster resources" (cluster và provider ở hai lần `apply`): <https://github.com/hashicorp/terraform-provider-kubernetes/blob/main/docs/index.md>
- [N6] Argo CD v3.5.5, ApplicationSet Git generator: <https://github.com/argoproj/argo-cd/blob/v3.5.5/docs/operator-manual/applicationset/Generators-Git.md>
- [N7] Kargo, bản phát hành v1.12.5 (2026-10-27): <https://github.com/akuity/kargo/releases>
- [N8] GitOps Promoter v0.48.0 (2026-10-30): <https://github.com/argoproj-labs/gitops-promoter/releases>; Source Hydrator (beta từ v3.5.0): <https://github.com/argoproj/argo-cd/blob/v3.5.5/docs/user-guide/source-hydrator.md>
- [N9] Session Manager, port forwarding tới host từ xa (`AWS-StartPortForwardingSessionToRemoteHost`): <https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-sessions-start.html>
- [N10] Ví dụ SCP (chặn theo region với `aws:RequestedRegion`): <https://docs.aws.amazon.com/organizations/latest/userguide/orgs_manage_policies_scps_examples.html>
- [N11] Consolidated billing của Organizations: <https://docs.aws.amazon.com/awsaccountbilling/latest/aboutv2/consolidated-billing.html>; budget của management account: <https://docs.aws.amazon.com/cost-management/latest/userguide/budgets-managing-costs.html>
- [N12] CloudTrail, policy bucket S3 cho organization trail: <https://docs.aws.amazon.com/awscloudtrail/latest/userguide/create-s3-bucket-policy-for-cloudtrail.html>
- [N13] GitOps Bridge (mẫu; module Terraform cluster Secret + `helm_release` chart `charts/resources`): <https://github.com/gitops-bridge-dev/gitops-bridge>, <https://github.com/gitops-bridge-dev/terraform-helm-gitops-bridge/blob/main/main.tf>
- [N14] Provider Terraform `helm`: `helm_release` (`take_ownership`) <https://github.com/hashicorp/terraform-provider-helm/blob/main/docs/resources/release.md>, data source `helm_template` (`chart` là đường dẫn, `show_only`) <https://github.com/hashicorp/terraform-provider-helm/blob/main/docs/data-sources/template.md>
- [N15] Argo CD v3.5.5, ApplicationSet cluster generator: <https://github.com/argoproj/argo-cd/blob/v3.5.5/docs/operator-manual/applicationset/Generators-Cluster.md>
- [N16] Argo CD v3.5.5, ApplicationSet `templatePatch` và Go template: <https://github.com/argoproj/argo-cd/blob/v3.5.5/docs/operator-manual/applicationset/Template.md>, <https://github.com/argoproj/argo-cd/blob/v3.5.5/docs/operator-manual/applicationset/GoTemplate.md>
- [N17] Argo CD v3.5.5, nhiều source và `ref` cho file values: <https://github.com/argoproj/argo-cd/blob/v3.5.5/docs/user-guide/multiple_sources.md>
- [N18] AWS Organizations FAQ và IAM Identity Center FAQ (không tính phí): <https://aws.amazon.com/organizations/faqs/>, <https://aws.amazon.com/iam/identity-center/faqs/>
- [N19] EKS Blueprints, GitOps getting started (Argo CD, metadata của cluster thành annotation): <https://github.com/aws-ia/terraform-aws-eks-blueprints/blob/main/patterns/gitops/getting-started-argocd/README.md>
- [N20] Argo CD v3.5.5, cluster khai báo bằng Secret: <https://github.com/argoproj/argo-cd/blob/v3.5.5/docs/operator-manual/declarative-setup.md>
- [N21] Argo CD v3.5.5, repo-server: các source `ref` mà file values trỏ tới cùng một repo phải cùng `targetRevision` (`cannot reference multiple
  revisions for the same repository`): <https://github.com/argoproj/argo-cd/blob/v3.5.5/reposerver/repository/repository.go#L807-L812>; thứ tự
  `parameters > valuesObject > values > valueFiles`: <https://github.com/argoproj/argo-cd/blob/v3.5.5/docs/user-guide/helm.md>
