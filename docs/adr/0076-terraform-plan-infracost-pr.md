# 0076. PR của `svp-infra` có `terraform plan` bằng role OIDC chỉ đọc mà người học duyệt từng lượt, không đọc dữ liệu workload, chỉ đăng tóm tắt đã che, và ước chi phí bằng Infracost từ HCL; CI không bao giờ `apply`

- Trạng thái: Chấp nhận
- Ngày: 2026-11-15
- Người quyết: người học (2026-11-15: làm các khoảng trống CI/CD trước buổi cloud, AI tự quyết thiết kế, apply ở buổi cloud), AI đề xuất
  thiết kế theo tài liệu GitHub, AWS, Terraform, Infracost và mã nguồn ở version ghim

## Bối cảnh và vấn đề

- PR của `svp-infra` chỉ kiểm tĩnh (`check.yml` không credential: [0034](0034-aws-stage7.md) §2, `infra/AGENTS.md`); người học chạy
  `plan` bằng SSO. Người duyệt chỉ thấy diff `.tf`, không thấy Terraform sẽ tạo, sửa, xoá gì, nhất là ở PR Renovate nâng provider, module, lock.
- [0059](0059-org-structure-guardrails.md) §12 hoãn plan trên PR vì ba lý do: (a) cần role chỉ đọc riêng; (b) repo public, log và
  artifact Actions ai cũng đọc, plan in ARN, account ID, domain; (c) Infracost đọc cùng plan JSON. ADR này giải cả ba.
- Chi phí chỉ có ở phụ lục các ADR chi phí, tính tay; PR đổi cỡ hay cờ `aws/paid-features.json` không hiện chi phí.
- Ràng buộc: AI không chạm account; một người học (tác giả cũng là người duyệt); role CI đã có chỉ ở hai repo code
  ([0062](0062-ecr-registry-ci-oidc.md) §5); state ở bucket của account env, khoá `alias/svp-tfstate` chỉ cho `SvpAdmin` giải mã.
- Tài liệu ràng buộc thiết kế: job nêu environment nhận `sub` dạng environment thay dạng `pull_request` [N1]; required reviewers ở gói
  Free chỉ có cho repo public [N2]; lượt chờ duyệt environment tối đa 30 ngày rồi bị huỷ [N3]; secret không vào lượt chạy từ fork [N26].

## Yếu tố quyết định

- CI không `apply`; credential AWS của CI chỉ đọc, ngắn hạn, đúng một `sub`, mỗi lượt có người duyệt.
- Không lộ gì trên repo public: không text plan, không giá trị thuộc tính, account ID, domain trong log, comment, artifact.
- Không đọc dữ liệu workload (object, giá trị secret, item, log event, message, trace) dù đọc được cấu hình.
- Không đỏ giả: thiếu cấu hình thì bỏ qua có thông báo; lỗi thật thì đỏ. Không vào cổng PR (`infra-ok`).
- Không server tự chạy, không dịch vụ trả phí mới; Terraform, image ghim của repo.

## Phương án đã cân nhắc

Trạng thái ngành, được, mất, nguồn: [phụ lục](appendix/0076-terraform-plan-infracost-pr.md#phương-án). In đậm là lựa chọn.

- Plan: Atlantis (hiện hành, CNCF Sandbox [N10]): server tự host giữ credential lâu dài, phải vá và trả tiền chạy. HCP Terraform (hiện hành, Free
  500 resource, 1 run đồng thời [N11]): state và credential AWS dời sang HashiCorp. Spacelift, env0 (hiện hành, SaaS [N12]): như HCP, thêm vendor.
  Actions + OIDC với `aws-actions/configure-aws-credentials` (hiện hành [N13]): thêm action bên thứ ba vào `svp-infra`, credential thành biến
  môi trường của mọi bước sau. **Actions + OIDC qua SDK**: token lấy theo tài liệu GitHub [N1], Terraform tự assume bằng chuỗi credential chuẩn [N4], [N5].
- Refresh: **plan có refresh**; `-refresh=false` chỉ đọc state (không thấy drift, data source vẫn gọi API).
- Chi phí: **Infracost CLI v0.10** (cũ, vẫn phát hành; đọc HCL, không credential AWS [N18]); Infracost CLI v2 (hiện hành [N29]: CI cần token
  tài khoản Infracost Cloud, báo trạng thái PR lên dashboard, plugin tải bản mới nhất lúc chạy [N34]); không ước lượng; AWS Pricing
  Calculator tay (không vào PR).

## Kết quả quyết định

Chọn các phương án in đậm: không thêm action, server hay vendor giữ credential; mỗi lượt đọc account có người duyệt và chỉ để lại tóm tắt đã che.
Giá trị đủ, kiểm kê refresh, statement IAM: [phụ lục](appendix/0076-terraform-plan-infracost-pr.md), cùng số §.

### 1. Luật an toàn

- AI vẫn không chạy lệnh nào chạm account, kể cả `make ci-plan` (**Lệnh plan CI**, §3), target từ chối chạy ngoài Actions.
- Chỉ `.github/workflows/plan.yml` của `svp-infra` đọc account, bằng role `svp-ci-terraform-plan` (**Role plan**, §4), trong job có
  environment `terraform-plan` mà người học duyệt từng lượt, trên PR từ chính repo. CI không `apply`, `import`, ghi state hay khoá state;
  apply vẫn là việc của người học bằng SSO.
- Trust chỉ buộc tên environment (§4): workflow nào của PR cùng repo nêu nó, kể cả `plan.yml`, `ci/`, `Makefile` do chính PR sửa, nhận role
  khi lượt được duyệt. Người học chỉ duyệt sau khi đọc diff của PR (cả `aws/**` và lock): đó là kiểm soát duy nhất
  ([phụ lục](appendix/0076-terraform-plan-infracost-pr.md#1-luật-an-toàn)).
- `check.yml` giữ không credential, secret, environment. Cổng PR giữ `infra-ok`; plan và Infracost chỉ là thông tin.
- Đây là ngoại lệ thứ hai của luật "CI không credential AWS" (0034 §2), sau 0062 §5.

### 2. Workflow plan

- Trigger chỉ `pull_request` (không `pull_request_target`, `workflow_run`), lọc `paths` `aws/**`, `ci/**`, `Makefile`, chính file đó.
- Job gác đọc biến Actions `SVP_TF_PLAN_ENVS` (**Biến bật plan**, mảng JSON, mặc định `[]`, §9) và loại PR; job `plan` ma trận theo
  env, `permissions: contents: read, id-token: write`, `environment: terraform-plan`; job `plan-comment` (`pull-requests: write`, không checkout, không credential) đăng tóm tắt.
- Bỏ qua có `::notice::`, job xanh: biến rỗng (job `plan` không chạy nên environment không bị nêu), PR từ fork, PR chỉ đổi **Gốc không plan** (§7).
- PR của Renovate plan như mọi PR: thấy thay đổi do nâng provider là giá trị chính của plan. Người học duyệt sau khi đọc diff, vì provider mới
  chạy với credential của **Role plan**; `init -lockfile=readonly` chỉ nhận provider khớp hash của lock.
- Lượt chờ của PR đã đóng: người học bấm Reject; không thì GitHub huỷ sau 30 ngày [N3], không ảnh hưởng cổng PR.
- `concurrency` theo số PR, `cancel-in-progress: true`: push mới huỷ lượt cũ; lượt `pending` cùng nhóm cũng bị huỷ [N6].

### 3. Token OIDC và credential

- Ngay trước mỗi lệnh Terraform (`init`, `state pull`, `plan`, `show`), `ci/terraform-plan.sh` lấy token mới từ `ACTIONS_ID_TOKEN_REQUEST_URL`
  với audience `sts.amazonaws.com` (cần `id-token: write` [N1]), `::add-mask::`, ghi đè file mode 600 dưới `RUNNER_TEMP` (mount chỉ đọc vào
  container Terraform). Token sống 300 s (`exp` − `iat` của token mẫu [N31]) và STS từ chối token hết hạn [N32], mà lượt **Buổi mở** chạy hai
  root lâu hơn 5 phút; backend và provider assume khi khởi tạo rồi giữ phiên STS (mặc định 3600 s [N32]).
- Terraform đọc `AWS_ROLE_ARN`, `AWS_WEB_IDENTITY_TOKEN_FILE`, `AWS_ROLE_SESSION_NAME`: backend S3 [N4] và provider qua chuỗi credential mặc
  định của SDK, đọc lại file mỗi lần assume [N5]. Không action bên thứ ba; `patterns_allowed` của `svp-infra` không thêm gì.
- **Lệnh plan CI**: `make ci-plan ENV=<env>` gọi `ci/terraform-plan.sh`, chạy Terraform của `TERRAFORM_IMAGE`; từ chối khi thiếu `GITHUB_ACTIONS=true`
  và `ACTIONS_ID_TOKEN_REQUEST_URL`; `init -input=false -lockfile=readonly` với bucket, key, region; `plan -lock=false -input=false -no-color -out`;
  stdout, stderr của `plan` không vào log (stderr qua **Giá trị che** của §8 rồi mới in khi lỗi); text đầy đủ của plan không in, không upload.

### 4. Role plan

- **Role plan**: role IAM `svp-ci-terraform-plan` ở `svp-stg`, `svp-prd`, tạo bởi root `aws/accounts/<env>` qua module `aws/modules/ci-plan-role`.
- Trust: OIDC provider sẵn có của account (module `registry`, 0062 §5), `aud` = `sts.amazonaws.com`, `sub` `StringEquals` đúng một chuỗi dạng
  bất biến [N1]: `repo:anhnvcoder@96784839/svp-infra@1440574580:environment:terraform-plan`; `max_session_duration` 3600, mức thấp nhất [N16].
- Quyền: `ReadOnlyAccess` (v192, sửa 2026-11-13 [N17]), inline `Allow` cho phép đọc mà nó thiếu (§6), inline `Deny` của §5.
- Đọc state ở **Bucket state** `svp-tfstate-<account>-ap-southeast-1` (khoá `aws/accounts/<env>/terraform.tfstate`, `aws/<env>/terraform.tfstate`):
  `ReadOnlyAccess` có `s3:Get*`; nó không có `kms:Decrypt` [N17], và key policy của `alias/svp-tfstate` chỉ ủy cho IAM của `SvpAdmin`.
  Key policy thêm statement cho đúng role này (`aws:PrincipalArn` dựng từ account, như `SvpAdmin`, nên không vòng phụ thuộc): `kms:Decrypt` khi
  `kms:ViaService` = `s3.ap-southeast-1.amazonaws.com` [N22] và `kms:EncryptionContext:aws:s3:arn` = ARN bucket (S3 Bucket Key dùng ARN
  bucket làm encryption context [N23]); inline `Allow` `kms:Decrypt` cùng điều kiện, vì key policy ủy cho IAM [N24], trên ARN khoá dạng
  `key/<id>` (thuộc tính `arn` của `aws_kms_key.state`): IAM không nhận ARN alias [N33].

### 5. Tập Deny

Explicit Deny thắng mọi Allow [N21]. Bốn nhóm, statement đủ ở [phụ lục](appendix/0076-terraform-plan-infracost-pr.md#5-tập-deny):

| Nhóm | Hành động | Resource |
| --- | --- | --- |
| Dữ liệu workload | `secretsmanager:GetSecretValue`, `BatchGetSecretValue`; item DynamoDB, stream; log event, query, live tail của CloudWatch Logs; `sqs:ReceiveMessage` (ẩn message khỏi consumer [N25]); `kinesis:GetRecords`; trace X-Ray; truy vấn AMP; tải log RDS; console, password EC2 | `*` |
| Object | `s3:GetObject*` | mọi thứ trừ hai khoá state và `media/uptime-probe.txt` của bucket media |
| Giải mã | `kms:Decrypt` | mọi khoá trừ khoá state; khoá state khi không qua S3 |
| Ghi state | mọi hành động S3 trừ `s3:Get*`, `s3:List*` | **Bucket state** và mọi object của nó (cả `.tflock`) |

- Không Deny nào chạm refresh của root plan được: §6; tham số SSM: [phụ lục](appendix/0076-terraform-plan-infracost-pr.md#5-tập-deny).

### 6. Refresh đọc gì

Kiểm kê mọi resource, data source của root plan được (§7) và module con (cả `terraform-aws-modules/eks` 21.29.0, `vpc` 6.7.3), đối chiếu mã đọc của
provider AWS ở version của lock (6.71.0 ở `aws/envs/<env>`, 6.72.0 ở `aws/accounts/<env>`) với `ReadOnlyAccess` v192. Chỗ chạm Deny hay thiếu quyền:

- `aws_secretsmanager_secret_version` (module `msk`, `elasticache`) chỉ ghi `secret_string_wo`: khi state có `has_secret_string_wo`, provider
  đọc bằng `ListSecretVersionIds`, không `GetSecretValue` [N7], [N8]. Mọi secret version của root plan được phải ghi bằng `_wo`.
- `aws_s3_object.uptime_probe` (module `media`): `HeadObject` cần `s3:GetObject` [N9], thêm tag object: ngoại lệ đúng ARN object đó.
- `aws_grafana_workspace_service_account` (module `observability`) cần `grafana:ListWorkspaceServiceAccounts`; `aws_pricingplanmanager_subscription`
  (module `media`) cần `pricingplanmanager:GetSubscription`; `ReadOnlyAccess` v192 không có cả hai [N27]: inline `Allow` hai hành động đó.
- Khoá KMS, lệnh HTTPS ngoài API AWS: [phụ lục](appendix/0076-terraform-plan-infracost-pr.md#6-kiểm-kê-refresh).

### 7. Root plan được

- **Gốc plan được**, mỗi env của **Biến bật plan**: `aws/accounts/<env>` luôn; `aws/envs/<env>` khi state của nó khác rỗng (**Buổi
  mở**: `terraform state pull` bằng **Role plan** trả state khác rỗng); có buổi thì `aws/accounts/<env>` plan với `-var session_open=true`, không thì `false`.
- **Gốc không plan** (job summary nêu tên và lý do): `aws/bootstrap`, `aws/org` (management không đặt role CI), `aws/log-archive`, `aws/security`,
  `aws/baseline`, `aws/backup` (chạy từ management qua `OrganizationAccountAccessRole`), `aws/gitops/<env>` (API EKS chỉ qua tunnel), `github/`.

### 8. Giá trị che và tóm tắt

- **Giá trị che**: account ID của bốn secret `SVP_AWS_*_ACCOUNT_ID`, mọi giá trị chuỗi, số của **Secret tfvars** (§9), token OIDC;
  `::add-mask::` trước bước in đầu, và thay bằng `***` trong tóm tắt: add-mask chỉ che log, không che comment.
- Tóm tắt mỗi root: env, số tạo, sửa, xoá, thay, danh sách `<address>: <action>` từ `terraform show -json`, không giá trị thuộc tính. Một
  comment dính (marker, sửa thay vì thêm), job summary; artifact `plan-summary-<env>` chỉ chứa bản đã che.

### 9. Environment, secret, biến

- **Environment plan**: environment `terraform-plan` (Terraform `infra/github/`): reviewer bắt buộc là người học, `can_admins_bypass =
  false`, `prevent_self_review = false` (người học vừa mở PR vừa duyệt; bật thì không ai duyệt được [N2]), không giới hạn nhánh: rule
  nhánh khớp `GITHUB_REF` [N2], ref của PR là `refs/pull/<n>/merge` [N26].
- Secret của environment do người học đặt, không vào Terraform: bốn `SVP_AWS_*_ACCOUNT_ID` và **Secret tfvars** (`SVP_TFVARS_ACCOUNT_<ENV>`,
  `SVP_TFVARS_ENV_<ENV>`: nội dung `*.auto.tfvars`, ghi thành file trên runner, không vào artifact, log).
- **Biến bật plan** từ biến Terraform `terraform_plan_envs` (`stg`, `prd`); thêm env sau khi role của env đó đã apply và secret đã đặt.

### 10. Infracost

- `cost.yml` cùng trigger và `paths`; Infracost CLI v0.10.49 (Apache-2.0, 2026-11-10 [N14]) từ image ghim digest [N30] qua Makefile, chế độ HCL:
  đọc `.tf` và `<env>.tfvars` đã commit, không plan, state, credential AWS [N18]. CLI không gửi plan JSON, credential, secret tới Cloud Pricing
  API, chỉ thuộc tính tính giá và số resource theo loại [N18].
- Job `infracost` (`contents: read`, secret repo `INFRACOST_API_KEY`) tính bản base và bản PR, `diff`; job `infracost-comment`
  (`pull-requests: write`) đăng bằng `infracost comment github --behavior update` [N19]; bảng tổng mỗi project vào job summary. Bỏ qua có
  notice khi PR từ fork hay khoá rỗng.
- Mức dùng: khoá API miễn phí; trang giá ghi gói Free 1 000 run mỗi tháng [N15], không nói bản CLI nào; vì sao chưa chọn v2:
  [phụ lục](appendix/0076-terraform-plan-infracost-pr.md#chi-phí).
- `infracost.yml`: mỗi root plan được của hai env một project; `aws/envs/<env>` với `<env>.tfvars`; `aws/accounts/<env>` không file tfvars
  (chỉ có `*.auto.tfvars` bị gitignore, `var_files` không bắt buộc [N28]); `aws/accounts/stg` thêm project `session_open=true`. Giả định mức dùng
  ở `infracost-usage.yml`; cờ `paid-features.json` hiện qua chính HCL của module `paid-features`.

### 11. ADR cũ

Chỉnh: 0034 §2; 0059 §12; 0062 §5; 0041 (d).

### Hệ quả

- Tốt: PR hạ tầng thấy thay đổi và chi phí trước merge; PR Renovate nâng provider lộ thay đổi ngầm; không action, server, vendor mới giữ
  credential; mỗi lượt đọc account có bản ghi duyệt; dữ liệu workload ngoài tầm role; state không bị ghi hay khoá từ CI.
- Xấu: phiên Actions đọc cấu hình cả account bằng **Role plan** (ARN, tag, cấu hình tài nguyên); mỗi lượt plan, cả PR Renovate, chờ người
  học duyệt **Environment plan**, và lượt duyệt là kiểm soát duy nhất giữa code của PR và role: người học đọc diff của PR
  mỗi lần (§1); root management và chéo account không plan trong CI; plan không phát hiện drift của **Gốc không plan**; một lệnh Terraform
  quá phiên 1 giờ thì lỗi; mỗi lượt duyệt thêm một deployment vào lịch sử repo; Infracost HCL không thấy giá trị trong `*.auto.tfvars`; thêm một
  secret, một vendor đọc thuộc tính tính giá; v0.10 không còn là CLI tài liệu hiện hành tả.
- Xem lại khi: thêm resource mà provider đọc lúc refresh bằng hành động trong tập Deny hay ngoài `ReadOnlyAccess` (đối chiếu lại §6 khi nâng
  provider); một secret version không dùng `_wo`; AWS đổi `ReadOnlyAccess`; Infracost ngừng v0.10 hay Cloud Pricing API của nó (chuyển CLI v2);
  quá 1 000 run Infracost mỗi tháng; có người thứ hai duyệt (bật `prevent_self_review`); cần plan root org (role plan ở management).

## Xác nhận

- Lúc quyết chưa hiện thực. Kiểm tĩnh: `make check` của `svp-infra` (test mock của module `ci-plan-role`: trust một `sub`, `aud`, phiên, Deny,
  Allow; `ci-plan-test`, test Infracost với lệnh giả; zizmor); `make github-check`.
- Buổi cloud: apply **Role plan**, đặt secret, bật **Biến bật plan**; một PR thật cho comment tóm tắt đã che và comment Infracost; plan của
  `aws/accounts/stg` qua refresh với Deny (không `AccessDenied`); một lượt **Buổi mở** dài hơn 5 phút không `ExpiredToken` (§3); push mới khi
  lượt đang chờ duyệt thì lượt cũ bị huỷ (tài liệu không nói rõ lượt chờ duyệt [N6]).
- Sau buổi: bảng so giá Infracost với phụ lục chi phí vào phụ lục ADR này.

## Hiện thực ở

- `svp-infra`: `.github/workflows/plan.yml`, `ci/terraform-plan.sh` + test, `Makefile` (`ci-plan`, `ci-plan-test`) (§2, §3, §7, §8);
  `aws/modules/ci-plan-role/`, `aws/modules/registry/outputs.tf`, `aws/modules/account-baseline/` (key policy state), `aws/accounts/<env>/` (§4–§6);
  `github/environments.tf`, `github/variables.tf`, `github/repositories.tf` (§9); `.github/workflows/cost.yml`, `ci/infracost.sh` + test,
  `infracost.yml`, `infracost-usage.yml` (§10); `README.md`, `AGENTS.md` (§1).
- Repo code: `docs/reference/ci.md`, `docs/threat-model.md`.

## Nguồn

Đọc 2026-11-15; [N1]–[N34] kèm link và trích dẫn ở [phụ lục](appendix/0076-terraform-plan-infracost-pr.md#nguồn).

## Thông tin thêm

Phụ lục: [`appendix/0076-terraform-plan-infracost-pr.md`](appendix/0076-terraform-plan-infracost-pr.md) (phương án, IAM, refresh, nguồn).

### Chỉnh bởi

- §10: [0078](0078-paid-features-lean-defaults.md): `aws/accounts/<env>` có project `session_open=true` chỉ khi env có cờ `session`.
