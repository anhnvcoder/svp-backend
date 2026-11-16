# Phụ lục ADR-0076: PR của `svp-infra` có `terraform plan` bằng role OIDC chỉ đọc, Infracost từ HCL

Phụ lục của [ADR-0076](../0076-terraform-plan-infracost-pr.md): phương án, statement IAM đủ, kiểm kê refresh, nguồn. Đọc 2026-11-15 trừ khi
ghi khác. Account ID trong ví dụ là `111111111111`.

## Phương án

### Chạy plan trên PR

| Phương án | Trạng thái ngành | Được | Mất | Nguồn |
| --- | --- | --- | --- | --- |
| Atlantis | Hiện hành; CNCF Sandbox từ 2024-06-18; bản v0.49.0 | Plan, apply, comment kết quả trên PR, mã nguồn mở | Một server tự host nghe webhook, giữ credential lâu dài, phải vá, chạy cả tháng; trái "không server" | [N10] |
| HCP Terraform | Hiện hành; gói Free tới 500 managed resource, 1 run đồng thời | Speculative plan trên PR qua VCS, UI, policy | State dời khỏi bucket của account; credential AWS (dynamic credentials hay key) nằm ở HashiCorp; vượt 500 resource thì trả tiền | [N11] |
| Spacelift, env0 | Hiện hành, SaaS; Spacelift Free 2 user | Như HCP, thêm drift detection | Thêm vendor giữ credential và state hay đọc state; giới hạn gói free | [N12] |
| Actions + OIDC, `aws-actions/configure-aws-credentials` | Hiện hành; v6.3.0 (2026-09-11) | Cách phổ biến nhất, `mask-aws-account-id` | Action bên thứ ba thứ nhất ở `svp-infra` (hiện chỉ action của GitHub); credential thành biến môi trường của mọi bước sau trong job | [N13] |
| **Actions + OIDC qua SDK** | Hiện hành: cách GitHub tả cho action tự viết; chuỗi credential web identity chuẩn của SDK AWS | Không action mới; token ở file 600 chỉ container Terraform đọc; backend S3 và provider tự assume | Khoảng chục dòng shell tự viết, có test lệnh giả | [N1], [N4], [N5] |

### Refresh

| Phương án | Được | Mất |
| --- | --- | --- |
| **Plan có refresh** | Thấy drift và thay đổi do provider mới đọc tài nguyên khác đi | Role cần quyền đọc cấu hình mọi dịch vụ của root (`ReadOnlyAccess` + bổ sung §6) |
| `-refresh=false` | Ít API, không cần đọc tài nguyên | Plan sai khi tài nguyên đổi ngoài Terraform; data source vẫn gọi API nên vẫn cần quyền đọc; mất giá trị chính ở PR Renovate |

### Chi phí

| Phương án | Trạng thái ngành | Được | Mất | Nguồn |
| --- | --- | --- | --- | --- |
| **Infracost CLI v0.10** | Cũ, vẫn phát hành: v0.10.49 (2026-11-10, Apache-2.0); v0.10.45 đã chuẩn bị chuyển sang v2 | Đọc HCL không credential AWS; comment PR, diff base/PR bằng chính CLI; khoá API; image Docker Hub ghim được theo digest | Khoá API (secret); gói Free 1 000 run mỗi tháng; HCL không thấy giá trị `*.auto.tfvars`; dòng đang chuyển dần sang v2 (§10) | [N14], [N15], [N18], [N30] |
| Infracost CLI v2 | Hiện hành: repo `infracost/cli` (tạo 2026-03-06, v2.19.1 ngày 2026-11-12, Apache-2.0); tài liệu `infracost.io/docs` tả bản này | Lệnh `scan`, sinh workflow CI, hướng AI agent | CI cần token tài khoản Infracost Cloud (`INFRACOST_CLI_AUTHENTICATION_TOKEN`: service account hay personal access token, đăng nhập bằng trình duyệt) thay khoá API; workflow sinh ra chạy `infracost-ci` trong image `ghcr.io/infracost/ci:2` (tag trôi) và có bước báo trạng thái PR lên dashboard; plugin parser, provider tải bản mới nhất lúc chạy và tự cập nhật, ghim từng plugin bằng biến môi trường riêng, ngoài digest của image | [N29], [N34] |
| Không ước lượng | Không gì thêm | Chi phí chỉ ở phụ lục ADR, tính tay | — | — |
| AWS Pricing Calculator tay | Chính xác theo mức dùng nhập | Không vào PR, mỗi lần tính tay | — | — |

## 1. Luật an toàn

- Trust của **Role plan** buộc `sub` có dạng environment (§4). Trong token còn claim `workflow_ref` (đường workflow kèm ref) [N1], và GitHub cho
  đưa claim vào `sub` bằng mẫu tuỳ biến [N1]; với PR, ref là `refs/pull/<n>/merge`, file workflow là bản của chính PR. Buộc thêm đường
  `plan.yml` chặn được workflow khác của PR, không chặn được PR sửa `plan.yml`, `ci/terraform-plan.sh` hay `Makefile`.
- Vì vậy kiểm soát duy nhất giữa code của PR và role là lượt duyệt **Environment plan**: người học đọc diff `.github/`, `ci/`, `Makefile` (và
  provider, module mới ở PR Renovate) trước khi duyệt. Code của PR nhận được role thì đọc được đúng những gì plan đọc (cấu hình account, hai file
  state): tập Deny (§5) và việc không ghi state vẫn giữ, nhưng che giá trị, không in text plan là việc của chính code đó.
- PR từ fork không tới được bước này: secret không vào lượt chạy từ fork [N26], job gác bỏ qua trước khi nêu environment.

## 2. Workflow plan

- Job nêu environment có required reviewer chờ duyệt; GitHub cho tối đa 30 ngày ("Gate approval time"), quá hạn thì huỷ theo luật chung của trang
  giới hạn [N3]. Cả lượt chạy tối đa 35 ngày, tính cả thời gian chờ duyệt [N3].
- `concurrency`: lượt `pending` cùng nhóm bị huỷ khi lượt mới vào hàng; `cancel-in-progress: true` huỷ cả lượt đang chạy [N6]. Trang không nói
  riêng lượt đang chờ duyệt environment: ghi ở Xác nhận của ADR, kiểm ở PR thật.

## 3. Token OIDC và credential

- Token mẫu của tài liệu GitHub có `"iat": 1632493567`, `"exp": 1632493867`, `"nbf": 1632492967`: hết hạn 300 s sau lúc phát [N31]. STS trả
  `ExpiredToken` cho token hết hạn: "Get a new identity token from the identity provider and then retry the request." [N32].
- SDK đọc lại file token mỗi lần lấy credential: `IdentityTokenFile.GetIdentityToken` gọi `os.ReadFile`, `WebIdentityRoleProvider.Retrieve` gọi nó
  trước mỗi `AssumeRoleWithWebIdentity` (`aws-sdk-go-v2/credentials` v1.20.10, bản mà provider AWS v6.71.0 ghim) [N5]. Phiên STS không đặt
  `DurationSeconds` sống 3600 s [N32], bằng `max_session_duration` của role.
- Một lượt **Buổi mở** chạy cho mỗi env: `init`, `state pull` của `aws/envs/<env>`; `init`, `plan`, `show -json` của `aws/accounts/<env>`; `plan`,
  `show -json` của `aws/envs/<env>`. Script lấy token mới trước mỗi lệnh, ghi đè tại chỗ file mode 600 (không đổi inode, mount chỉ đọc vẫn
  thấy bản mới); token cũ hết hạn sau 5 phút nên không cần thu hồi. Một lệnh `plan` dài hơn 1 giờ vẫn lỗi khi SDK làm mới credential.

## 4. Role plan

Trust policy (giá trị thật dựng trong Terraform từ `local` của root; id owner, repo là số công khai của API GitHub):

```json
{
  "Effect": "Allow",
  "Principal": { "Federated": "arn:aws:iam::111111111111:oidc-provider/token.actions.githubusercontent.com" },
  "Action": "sts:AssumeRoleWithWebIdentity",
  "Condition": {
    "StringEquals": {
      "token.actions.githubusercontent.com:aud": "sts.amazonaws.com",
      "token.actions.githubusercontent.com:sub": "repo:anhnvcoder@96784839/svp-infra@1440574580:environment:terraform-plan"
    }
  }
}
```

Statement thêm vào key policy của khoá state (module `account-baseline`; principal là account như statement `SvpAdminUsesKey`, nên key policy
không cần role tồn tại trước và không phụ thuộc module role):

```json
{
  "Sid": "CiPlanReadsState",
  "Effect": "Allow",
  "Principal": { "AWS": "arn:aws:iam::111111111111:root" },
  "Action": "kms:Decrypt",
  "Resource": "*",
  "Condition": {
    "ArnEquals": { "aws:PrincipalArn": "arn:aws:iam::111111111111:role/svp-ci-terraform-plan" },
    "StringEquals": {
      "kms:ViaService": "s3.ap-southeast-1.amazonaws.com",
      "kms:EncryptionContext:aws:s3:arn": "arn:aws:s3:::svp-tfstate-111111111111-ap-southeast-1"
    }
  }
}
```

Inline `Allow` của role (`svp-ci-terraform-plan-read`):

| Sid | Hành động | Resource | Lý do |
| --- | --- | --- | --- |
| `StateKeyViaS3` | `kms:Decrypt` (điều kiện `kms:ViaService` như trên) | `<state-key>` (§5) | `ReadOnlyAccess` không có `kms:Decrypt`; key policy ủy cho IAM |
| `RefreshReadsMissing` | `grafana:ListWorkspaceServiceAccounts`, `pricingplanmanager:GetSubscription` | `*` | Refresh cần, `ReadOnlyAccess` v192 không có (§6) |

## 5. Tập Deny

Inline `Deny` của role (`svp-ci-terraform-plan-deny`); `<state>` = `arn:aws:s3:::svp-tfstate-<account>-ap-southeast-1`, `<media>` =
`arn:aws:s3:::svp-<env>-media-<account>-ap-southeast-1`, `<state-key>` = ARN khoá state dạng
`arn:aws:kms:ap-southeast-1:<account>:key/<key-id>` (thuộc tính `arn` của `aws_kms_key.state`, `aws/modules/account-baseline/kms.tf`). Không dùng
ARN alias `arn:aws:kms:ap-southeast-1:<account>:alias/svp-tfstate`: IAM chỉ nhận ARN khoá [N33], statement có alias không khớp lệnh nào nên
`NotResource` không miễn khoá state và `StateKeyViaS3` không cho gì.

| Sid | Hành động | Resource / điều kiện |
| --- | --- | --- |
| `DenyWorkloadData` | `secretsmanager:GetSecretValue`, `secretsmanager:BatchGetSecretValue`, `dynamodb:GetItem`, `dynamodb:BatchGetItem`, `dynamodb:Query`, `dynamodb:Scan`, `dynamodb:PartiQLSelect`, `dynamodb:GetRecords`, `logs:GetLogEvents`, `logs:FilterLogEvents`, `logs:StartQuery`, `logs:GetQueryResults`, `logs:StartLiveTail`, `logs:GetLogRecord`, `logs:GetLogObject`, `sqs:ReceiveMessage`, `kinesis:GetRecords`, `xray:BatchGetTraces`, `xray:GetTraceSummaries`, `aps:QueryMetrics`, `aps:GetSeries`, `aps:GetLabels`, `aps:GetMetricMetadata`, `rds:DownloadDBLogFilePortion`, `rds:DownloadCompleteDBLogFile`, `ec2:GetConsoleOutput`, `ec2:GetConsoleScreenshot`, `ec2:GetPasswordData` | `*` |
| `DenyObjectReads` | `s3:GetObject*` | `NotResource`: `<state>/aws/accounts/<env>/terraform.tfstate`, `<state>/aws/<env>/terraform.tfstate`, `<media>/media/uptime-probe.txt` |
| `DenyDecryptOtherKeys` | `kms:Decrypt` | `NotResource`: `<state-key>` |
| `DenyDecryptStateOutsideS3` | `kms:Decrypt` | `<state-key>`, `StringNotEquals` `kms:ViaService` `s3.ap-southeast-1.amazonaws.com` |
| `DenyStateWrites` | `NotAction`: `s3:Get*`, `s3:List*` | `<state>`, `<state>/*` |

- `ReadOnlyAccess` v192 cho mọi hành động của `DenyWorkloadData` trừ `secretsmanager:GetSecretValue`, `BatchGetSecretValue` và `kms:Decrypt`
  (đối chiếu bằng wildcard của chính policy). Hai hành động secret vẫn Deny: phòng khi policy managed hay resource policy của secret mở thêm.
- `sqs:ReceiveMessage` không chỉ đọc: message nhận bị ẩn khỏi consumer khác trong visibility timeout, lần nhận không xoá tính là một lần nhận lỗi
  [N25]; với hàng đợi trạng thái MediaConvert, một lượt đọc làm chậm và có thể đẩy message vào DLQ.
- Hai object ngoại lệ ngoài state: `media/uptime-probe.txt` là object công khai qua CloudFront (nội dung `ok`), refresh của nó cần
  `s3:GetObject` (`HeadObject` [N9]) và `s3:GetObjectTagging`.

## 6. Kiểm kê refresh

Cách làm (2026-11-15):

1. Liệt kê mọi `resource`, `data` `aws_*` của `aws/accounts/<env>`, `aws/envs/<env>`, 17 module local mà hai root gọi, và module registry ở version
   ghim (`terraform-aws-modules/eks` 21.29.0 cùng `eks-managed-node-group`, `karpenter`; `vpc` 6.7.3): 154 loại.
2. Với mỗi loại, tìm hàm đọc trong mã provider AWS v6.71.0 (`internal/service/*`), lấy lệnh API đọc (`Get*`, `List*`, `Describe*`, `Head*`,
   paginator) của hàm đó và các hàm `find*` nó gọi; loại không bắt được tự động thì đọc tay.
3. Đối chiếu mỗi `<dịch vụ>:<hành động>` với wildcard của `ReadOnlyAccess` v192 và với tập Deny. `HeadBucket` ứng `s3:ListBucket`, `HeadObject`
   ứng `s3:GetObject` [N9].

| Root, file | Resource / data | Lệnh đọc | Kết quả |
| --- | --- | --- | --- |
| `aws/envs/<env>`: `modules/msk/main.tf` (`scram`, `kafka_admin`, `kafka_users`), `modules/elasticache/main.tf` (`valkey_users`) | `aws_secretsmanager_secret_version` với `secret_string_wo` | `ListSecretVersionIds` (nhánh `has_secret_string_wo`) | Không chạm Deny [N7], [N8] |
| `aws/envs/<env>`: `modules/media/uptime-probe.tf` | `aws_s3_object.uptime_probe` | `HeadObject`, `GetObjectTagging` | Ngoại lệ ARN trong `DenyObjectReads` |
| `aws/envs/<env>`: `modules/media/cloudfront.tf` | `aws_pricingplanmanager_subscription.media` (stg) | `GetSubscription` | Thiếu ở `ReadOnlyAccess`: `RefreshReadsMissing` |
| `aws/accounts/<env>`: `modules/observability/grafana.tf` | `aws_grafana_workspace_service_account` | `ListWorkspaceServiceAccounts` | Thiếu ở `ReadOnlyAccess`: `RefreshReadsMissing` |
| `aws/accounts/<env>`: `modules/observability/grafana.tf` | `aws_ssm_parameter.grafana_workspace_id` (`String`) | `GetParameter`, `DescribeParameters` | Không giải mã KMS: không chạm Deny |
| `aws/envs/<env>`: `baseline.tf`; `modules/ssm-bastion/main.tf` | `data "aws_ssm_parameter"` `/svp/<env>/grafana-workspace-id`, `/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64` | `GetParameter` | `String`: không chạm Deny |
| `aws/accounts/<env>`, `aws/envs/<env>`: mọi `aws_kms_key` (state, DNSSEC, backup, alarms, registry, observability, rds, msk, media) | `aws_kms_key` | `DescribeKey`, `GetKeyPolicy`, `GetKeyRotationStatus`, `ListResourceTags` | Key policy có account principal với `Describe*`, `Get*`, `List*` hay `kms:*`, hoặc key policy mặc định: IAM quyết |
| Backend của hai root | state | `GetObject` trên khoá root, `kms:Decrypt` qua S3 | `CiPlanReadsState`, `StateKeyViaS3` |
| `modules/eks` (registry module) | `data "tls_certificate"`; `aws_ip_ranges` của `modules/edge` | HTTPS tới issuer OIDC của EKS, `ip-ranges.json` | Ngoài API AWS; runner có mạng |
| `modules/eks` | `data "aws_ssm_parameter" "ami"` của node group | — | `count = 0`: `use_latest_ami_release_version = false` |

Mọi loại khác (EC2, EKS, IAM, RDS, MSK, ElastiCache, CloudFront, ACM, Route 53, WAF, ECR, AMP, X-Ray, Backup, SNS, SQS, EventBridge, Application
Auto Scaling, MediaConvert, GuardDuty, Budgets, CloudWatch, CloudWatch Logs) đọc bằng `Describe*`, `Get*`, `List*` mà `ReadOnlyAccess` có và tập Deny
không chứa.

## 10. Infracost

- `infracost comment github` của v0.10.49 nhận `--behavior` `update`, `new`, `hide-and-new`, `delete-and-new`, cần `--repo`, `--pull-request`
  (hay `--commit`), `--path`, `--github-token` [N19]. Image Docker Hub có tag `0.10.49` và `ci-0.10.49` [N30].
- Bản v0.10.45 (2026-07-03) ghi "updates the v0.x CLI for the v2 migration" và thêm thông báo nâng v2 vào bộ kiểm cập nhật [N14].

## Nguồn

- [N1] GitHub, "OpenID Connect reference": <https://docs.github.com/en/actions/reference/security/oidc>. "Without `id-token: write`, the OIDC JWT ID
  token cannot be requested."; `ACTIONS_ID_TOKEN_REQUEST_URL`: "The URL for GitHub's OIDC provider."; ví dụ `curl` thêm `&audience=` vào URL;
  "The subject claim includes the environment name when the job references an environment."; dạng `pull_request` "but only if the job doesn't
  reference an environment."; "Repositories created after July 15, 2026 use an immutable default subject format".
- [N2] GitHub, "Deployments and environments": <https://docs.github.com/en/actions/reference/workflows-and-actions/deployments-and-environments>.
  "If you are on a GitHub Free, GitHub Pro, or GitHub Team plan, required reviewers are only available for public repositories."; "The deployment
  branch or tag rule is matched against the `GITHUB_REF` of the workflow run."; "No restriction on which branch or tag can deploy to the
  environment."; prevent self-review: "users who initiate a deployment cannot approve the deployment job, even if they are a required reviewer".
- [N3] GitHub, "Actions limits": <https://docs.github.com/en/actions/reference/limits>. "A workflow may wait for up to 30 days on environment
  approvals."; "Unless otherwise stated, the expected behavior when a limit is reached is that the workflow/job will get cancelled."; workflow run
  time 35 ngày: "This period includes execution duration, and time spent on waiting and approval."
- [N4] HashiCorp, "Backend type: s3" (Terraform v1.15.x): <https://developer.hashicorp.com/terraform/language/backend/s3>. `role_arn` "Can also be
  set with the `AWS_ROLE_ARN` environment variable."; `web_identity_token_file` "Can also be set with the `AWS_WEB_IDENTITY_TOKEN_FILE` environment
  variable."; `session_name` qua `AWS_ROLE_SESSION_NAME`.
- [N5] AWS SDK for Go v2, `config/resolve_credentials.go`: <https://github.com/aws/aws-sdk-go-v2/blob/main/config/resolve_credentials.go> (nhánh
  `len(envConfig.WebIdentityTokenFilePath) > 0` gọi `assumeWebIdentity` với `RoleARN`, `RoleSessionName`); Terraform v1.15.8 dùng
  `aws-sdk-go-base/v2` trên SDK này (`go.mod`). Tài liệu provider AWS v6.71.0: "This support is based on the underlying `AWS_ROLE_ARN` and
  `AWS_WEB_IDENTITY_TOKEN_FILE` environment variables": <https://github.com/hashicorp/terraform-provider-aws/blob/v6.71.0/website/docs/index.html.markdown>.
  `credentials/stscreds/web_identity_provider.go` ở `credentials/v1.20.10` (bản trong `go.mod` của provider AWS v6.71.0):
  <https://github.com/aws/aws-sdk-go-v2/blob/credentials/v1.20.10/credentials/stscreds/web_identity_provider.go>
  (`GetIdentityToken`: `os.ReadFile(string(j))`; `Retrieve` gọi `p.options.TokenRetriever.GetIdentityToken()` mỗi lần).
- [N6] GitHub, "Control the concurrency of workflows and jobs":
  <https://docs.github.com/en/actions/how-tos/write-workflows/choose-when-workflows-run/control-workflow-concurrency>. "By default, any existing
  `pending` job or workflow in the same concurrency group will be canceled"; "To also cancel any currently running job or workflow in the same
  concurrency group, specify `cancel-in-progress: true`."
- [N7] Provider AWS v6.71.0, `resourceSecretVersionRead`:
  <https://github.com/hashicorp/terraform-provider-aws/blob/v6.71.0/internal/service/secretsmanager/secret_version.go> (dòng 208–257: khi
  `hasWriteOnly`, đọc bằng `findSecretVersionEntryByTwoPartKey`, tức `ListSecretVersionIds`, đặt `secret_string` rỗng; nhánh khác gọi `GetSecretValue`).
- [N8] Provider AWS v6.71.0, `HasWriteOnlyValue` đọc thuộc tính `has_<attr>` trong state:
  <https://github.com/hashicorp/terraform-provider-aws/blob/v6.71.0/internal/flex/write_only.go>.
- [N9] AWS, `HeadObject`: <https://docs.aws.amazon.com/AmazonS3/latest/API/API_HeadObject.html>. "To use `HEAD`, you must have the `s3:GetObject`
  permission."
- [N10] CNCF, Atlantis: <https://www.cncf.io/projects/atlantis/>. "Atlantis was accepted to CNCF on June 18, 2024 at the Sandbox maturity level.";
  README <https://github.com/runatlantis/atlantis>: "A self-hosted golang application that listens for Terraform pull request events via webhooks."
- [N11] HashiCorp, HCP Terraform overview: <https://developer.hashicorp.com/terraform/cloud-docs/overview>. "Free organizations are limited to 500
  managed resources."; "When pull requests are opened, linked workspaces and Stacks run speculative plans with the proposed code changes".
- [N12] Spacelift, pricing: <https://spacelift.io/pricing> ("Free forever", "2 users"); env0: <https://www.env0.com/pricing>.
- [N13] `aws-actions/configure-aws-credentials`: <https://github.com/aws-actions/configure-aws-credentials> (v6.3.0, 2026-09-11; `role-to-assume`,
  `mask-aws-account-id`).
- [N14] Infracost CLI releases: <https://github.com/infracost/infracost/releases> (v0.10.49 2026-11-10; v0.10.45 2026-07-03); license Apache-2.0.
- [N15] Infracost, pricing: <https://www.infracost.io/pricing/>. Gói Free: "1000 free runs per month, Slack Community support".
- [N16] AWS IAM, role settings: <https://docs.aws.amazon.com/IAM/latest/UserGuide/id_roles_update-role-settings.html>. "This setting can have a
  value from 1 hour to 12 hours."
- [N17] AWS managed policy `ReadOnlyAccess`: <https://docs.aws.amazon.com/aws-managed-policy/latest/reference/ReadOnlyAccess.html>. "Policy
  version: v192 (default)", "Edited time: November 13, 2026, 14:27 UTC"; không có `secretsmanager:GetSecretValue`, `kms:Decrypt`.
- [N18] Infracost, FAQ: <https://www.infracost.io/docs/faq/>. "The CLI does not send the Terraform plan JSON file, or any cloud credentials or
  secrets to the Cloud Pricing API."; "Infracost parses Terraform HCL code directly to extract only cost-related parameters"; cần credential cloud
  không: "No! Infracost parses code directly and uses pricing data to estimate costs."
- [N19] Infracost v0.10.49, `cmd/infracost/comment_github.go`:
  <https://github.com/infracost/infracost/blob/v0.10.49/cmd/infracost/comment_github.go> (`validCommentGitHubBehaviors = []string{"update", "new",
  "hide-and-new", "delete-and-new"}`).
- [N20] AWS Systems Manager, SecureString và KMS:
  <https://docs.aws.amazon.com/systems-manager/latest/userguide/secure-string-parameter-kms-encryption.html>. "To decrypt either type of
  `SecureString` parameter value, the user needs `kms:Decrypt` permission."
- [N21] AWS IAM, policy evaluation logic: <https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_policies_evaluation-logic.html>. "An explicit
  deny in either of these policies overrides the allow."
- [N22] AWS KMS, `kms:ViaService`: <https://docs.aws.amazon.com/kms/latest/developerguide/conditions-kms.html#conditions-kms-via-service>. "The
  `kms:ViaService` condition key limits use of an KMS key to requests from specified AWS services."; S3: `s3.<region>.amazonaws.com`.
- [N23] Amazon S3, Bucket Keys: <https://docs.aws.amazon.com/AmazonS3/latest/userguide/bucket-key.html>. "S3 Bucket Keys use the bucket ARN as
  encryption context."
- [N24] AWS KMS, default key policy: <https://docs.aws.amazon.com/kms/latest/developerguide/key-policy-default.html>. "it allows the account to use
  IAM policies to delegate the permissions specified in the policy statement."
- [N25] Amazon SQS, `ReceiveMessage`: <https://docs.aws.amazon.com/AWSSimpleQueueService/latest/APIReference/API_ReceiveMessage.html>. "When a
  message is received from a queue, it becomes temporarily invisible to other consumers for the duration of the visibility timeout."
- [N26] GitHub, "Events that trigger workflows":
  <https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows>. "With the exception of `GITHUB_TOKEN`, secrets
  are not passed to the runner when a workflow is triggered from a forked repository."; ref của `pull_request`: "PR merge branch
  `refs/pull/PULL_REQUEST_NUMBER/merge`".
- [N27] Provider AWS v6.71.0: `internal/service/grafana/workspace_service_account.go` (`NewListWorkspaceServiceAccountsPaginator`),
  `internal/service/pricingplanmanager/subscription.go` (`GetSubscription`): <https://github.com/hashicorp/terraform-provider-aws/tree/v6.71.0/internal/service>;
  đối chiếu với [N17].
- [N28] Infracost, config file: <https://www.infracost.io/docs/features/config_file/>. `var_files`: "Optional. Array of string. Variable files to
  use when parsing Terraform HCL code".
- [N29] Infracost CLI v2: <https://github.com/infracost/cli> (v2.19.1, 2026-11-12); <https://www.infracost.io/docs/> tả cài v2.
- [N30] Docker Hub, `infracost/infracost`: <https://hub.docker.com/r/infracost/infracost/tags> (tag `0.10.49`, `ci-0.10.49`).
- [N31] GitHub, "OpenID Connect": <https://docs.github.com/en/actions/concepts/security/openid-connect>, token mẫu (`"nbf": 1632492967`,
  `"exp": 1632493867`, `"iat": 1632493567`).
- [N32] AWS STS, `AssumeRoleWithWebIdentity`: <https://docs.aws.amazon.com/STS/latest/APIReference/API_AssumeRoleWithWebIdentity.html>.
  `ExpiredToken`: "The web identity token that was passed is expired or is not valid."; `DurationSeconds`: "By default, the value is set to
  3600 seconds."
- [N33] AWS KMS, "IAM policies": <https://docs.aws.amazon.com/kms/latest/developerguide/cmks-in-iam-policies.html>. "To specify a KMS key in an
  IAM policy statement, you must use its key ARN. You cannot use a key id, alias name, or alias ARN to identify a KMS key in an IAM policy
  statement."
- [N34] Infracost CLI v2.19.1: README <https://github.com/infracost/cli/blob/v2.19.1/README.md> ("Before running any commands, authenticate with
  Infracost"; `INFRACOST_CLI_AUTHENTICATION_TOKEN` "to a service account token or personal access token"; "By default, the CLI downloads the
  latest version of each plugin"; "Plugins auto-update by default"); `internal/cmds/ci_platforms.go` (`ciImage = "ghcr.io/infracost/ci:2"`),
  `internal/cmds/ci_github.go` (bước "Update pull request status": "Without this the dashboard leaves every merged pull request at OPEN"):
  <https://github.com/infracost/cli/tree/v2.19.1/internal/cmds>.
