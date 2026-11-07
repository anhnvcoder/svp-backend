# 0048. prd trên AWS: AWS Organizations với account `svp-stg`, `svp-prd` và management chỉ để quản trị; prd chuẩn production từ cùng module với stg; bootstrap EKS bằng GitOps Bridge ở root Terraform riêng; Secret của EKS từ Secrets Manager; prd ghim commit `svp-gitops` mà stg đã chạy

- Trạng thái: Chấp nhận
- Ngày: 2026-11-05
- Người quyết: người học (2026-11-04: account prd riêng trong Organizations, stg cũng sang account thành viên, Terraform thuần, SSM tới API prd,
  WAF, state riêng, khoá `gitopsRevision`; 2026-11-05: GitOps Bridge, giao AI chọn phần còn lại theo chuẩn ngành và ghi lý do)

## Bối cảnh và vấn đề

- [0034](0034-aws-stage7.md) dựng stg trên EKS trong một account sandbox (§3), cài Argo CD bằng `deploy/k8s/gitops.sh`, Secret của EKS từ namespace
  nguồn `svp-secrets`; prd chỉ render và kiểm tĩnh. [0050](0050-bash-to-standard-tools.md) §1 chọn GitOps Bridge cho bootstrap EKS.
- Cần prd chạy được theo chuẩn production (NAT mỗi AZ, RDS Multi-AZ, node nhiều AZ, bảo vệ xoá, không Spot cho phần stateful) từ cùng module với stg,
  và promote prd có cổng (environment `promote-prd`, Code Owner, [0041](0041-github-hardening.md)).
- Account sandbox đã là management của một org (feature set `ALL`, SCP bật, Identity Center loại organization). `base/`, `platforms/`, `argocd/apps`
  của `svp-gitops` dùng chung mọi env, nên một merge vào `main` tới prd ngay, trước khi stg chạy nó.
- Ràng buộc như 0034: repo public (không account ID, email, tên miền thật), AI không chạy lệnh chạm account, buổi tối đa 4 giờ, dựng và gỡ trong buổi.

## Yếu tố quyết định

- Khuyến nghị AWS: management account không chạy workload; chính sách áp lên account workload bằng SCP [N1].
- prd khác stg ở dữ liệu và một danh sách wiring đóng, không `if env`; mỗi giá trị (Argo CD, cluster, revision) đọc từ một nguồn.
- prd chỉ chạy bộ cấu hình stg đã chạy; chi phí buổi có nguồn; gỡ về baseline đo được.

## Phương án đã cân nhắc

Trạng thái ngành tại 2026-11-05; in đậm là lựa chọn. Được, mất và nguồn: phụ lục, mục "Phương án".

- Account: một account sandbox (0034 §3); stg ở management, prd thành viên (lệch [N1]); **Organizations, OU `Workloads`, `svp-stg`, `svp-prd`, Terraform
  thuần**; AWS Control Tower (hiện hành; AWS Config tốn thêm khi tài nguyên dựng và xoá mỗi buổi [N2]); Account Factory for Terraform (cần Control Tower [N3]).
- Log Archive và Audit account riêng theo AWS SRA [N4]: chuẩn cho org lớn, ở đây là bước sau; trail ở management.
- Bootstrap EKS: **root riêng `aws/gitops/<env>`**; trong chính root env (một apply cho cluster và tài nguyên Kubernetes, trái khuyến nghị của provider
  `kubernetes` [N5]; plan của prd phải mở tunnel); giữ bash (0050 đã bỏ).
- Ghim prd: **khoá `gitopsRevision` + hai tầng Application** (versioned base); ApplicationSet git files generator (không liệt kê được file của env [N6]);
  Kargo (hiện hành, thêm controller, CRD [N7]); GitOps Promoter (mới, v0.x) với Source Hydrator (beta [N8]); ghim chỉ trong cluster; nhánh theo env.
- API prd: **endpoint private + SSM port forwarding qua bastion** [N9]; endpoint công khai /32 như stg; AWS Client VPN (theo giờ, đắt hơn).
- Edge prd: **AWS WAF web ACL bằng Terraform**; CloudFront flat-rate plan (mới, theo tháng, không theo buổi).

## Kết quả quyết định

Chọn các phương án in đậm; `<env>` là `stg` hay `prd`, `<miền>` là tên miền của lab. Chi tiết từng §: [phụ lục](appendix/0048-prd-aws.md#chi-tiết-rút-khỏi-adr).

### 1. Account và quyền

- Management là account sandbox (profile `anhnv-sso`), chỉ giữ quản trị và dùng chung: Organizations, Identity Center, SCP, organization trail,
  budget tổng, zone lab `aws.<miền>`, bucket state của `aws/bootstrap`, `aws/org`, `github/`. Root `aws/org` (state `aws/org/terraform.tfstate`) quản phần cấp org.
- OU `Workloads`, account `svp-stg`, `svp-prd` tạo bằng Organizations (email qua biến không commit, role `OrganizationAccountAccessRole`,
  `prevent_destroy`, `close_on_deletion = false`). Ba SCP ở OU (module `org-policies`): chặn `LeaveOrganization`; chặn `cloudtrail:StopLogging`,
  `DeleteTrail`, `UpdateTrail`, `PutEventSelectors`, `PutInsightSelectors`; chặn region ngoài `ap-southeast-1`, `us-east-1` theo mẫu
  `aws:RequestedRegion` với `NotAction` [N10], không loại trừ role. Permission set `SvpAdmin` (`AdministratorAccess`, phiên 4 giờ) trên instance
  Identity Center có sẵn, gán user của người học vào hai account.
- Organization trail `svp-audit` ở management (đa region, đọc + ghi, log file validation, KMS `alias/svp-cloudtrail`, bucket theo tài liệu CloudTrail
  [N12]); chặn xoá log chọn theo CIS AWS Foundations, ghi ở README của `aws/org`. Log Archive account để sau.
- Mỗi account một profile SSO và một biến account: `anhnv-sso` + `SVP_AWS_MGMT_ACCOUNT_ID`, `anhnv-stg` + `SVP_AWS_STG_ACCOUNT_ID`, `anhnv-prd` +
  `SVP_AWS_PRD_ACCOUNT_ID` (`SVP_AWS_ACCOUNT_ID` bỏ); mỗi root `allowed_account_ids = [var.account_id]`; mọi lệnh `aws` viết sẵn ghi `--region`.
- Stg chuyển sang `svp-stg` không migrate state (stg không còn tài nguyên chạy). Key cũ `aws/stg/terraform.tfstate` trong bucket management: người học
  chứng minh nó không còn resource rồi xoá mọi version của nó (`aws s3api list-object-versions`, `delete-objects`, profile management).

### 2. State, DNS, budget mỗi account

- Baseline `aws/accounts/<env>` (module `account-baseline`, tag `Stack=baseline`): bucket state và KMS `alias/svp-tfstate` của account; `backend-<env>.hcl`
  không có `key`, mỗi root truyền key bằng `-backend-config` thứ hai, `tf.sh <env> init` luôn `-reconfigure`. Bucket management giữ ba state.
- Zone `<env>.aws.<miền>` ở baseline, uỷ quyền bằng `NS` từ zone lab; `domain` của root env là tên zone đó (web ở apex, API `api.<domain>`); budget tháng
  mỗi account thành viên, budget ở management tính cả org [N11].

### 3. Mức prd, wiring và luật kiểm

- Giá trị prd chỉ ở `aws/envs/prd/prd.tfvars` (bảng biến stg/prd ở phụ lục), `stg.tfvars` không đổi; biến mới của module mặc định giữ hành vi cũ.
- Hai root `aws/envs/stg`, `aws/envs/prd` gọi cùng module với cùng đối số (chỉ biến, output), kể cả `external-secrets`. Root prd thêm, và chỉ thêm:
  provider alias `us_east_1` cùng module `waf` truyền `web_acl_arn` vào `media`; module `ssm-bastion` và output `api_tunnel_command`; `teardown.tfvars`.
  Hai root `aws/gitops/stg`, `aws/gitops/prd` có `*.tf` giống hệt. Ngoài dòng `env = "<env>"` của `locals`, khác biệt nào khác là lỗi (`diff` hai cây).
- Không `if env`; test module có `run` mức prd `assert` thuộc tính bảo vệ; `make trivy` quét root với `<env>.tfvars`; ngoại lệ `Scope: stg only` không che
  finding nào của prd (đặt ở lời gọi module của root stg hay có điều kiện thuộc tính), có phép thử âm.

### 4. Truy cập API của prd và edge

- Endpoint công khai của API prd tắt; người học tới endpoint private bằng SSM port forwarding (`AWS-StartPortForwardingSessionToRemoteHost`) qua
  `t4g.nano` ở subnet private, không inbound, không khoá SSH, role chỉ `AmazonSSMManagedInstanceCore` (module `ssm-bastion`); root prd xuất
  `kubeconfig_command` (server `https://127.0.0.1:<cổng>`, `tls-server-name` là host của endpoint) và `api_tunnel_command`.
- Module `waf`: web ACL scope `CLOUDFRONT`, `AWSManagedRulesCommonRuleSet`, `AWSManagedRulesKnownBadInputsRuleSet`, một luật rate-based theo IP; chỉ root prd gọi.

### 5. Secret trên EKS

- Stg và prd trên EKS dùng store `aws` của ESO; k3d giữ store `kubernetes`. Module `external-secrets`: vỏ entry `svp/<env>/<entry>` (không version,
  `recovery_window_in_days = 0` vì env dựng lại cùng tên), Pod Identity cho controller → role `svp-<env>-external-secrets` chỉ assume năm role
  `svp-<env>-external-secrets-<namespace>`, mỗi role chỉ `GetSecretValue` trên entry namespace đó đọc.
- Nơi ghi: `AWS_PROFILE=anhnv-<env> make eks-secrets CONTEXT=svp-<env>` (`deploy/k8s/aws-secrets.sh`), sau apply root env, trước apply root gitops; entry và
  key từ `deploy/helm/svp-cluster/files/external-secrets.yaml`, giá trị từ `.env`, mỗi entry một `put-secret-value --secret-string file://…` (thư mục
  `mktemp -d` mode 700, giá trị không qua đối số hay output); `glitchtip-runtime` ba key rỗng chỉ khi chưa có version, `glitchtip-init.sh` điền sau.
- Cập nhật, cùng thứ tự ở k3d và EKS: (1) password admin Kafka vào broker; (2) ghi nguồn; (3) force-sync mọi ExternalSecret (script làm 1–3); runbook:
  (4) sync Application `svp-data`; (5) restart workload có Secret đổi (Rollout `gateway`, `web` qua `spec.restartAt`). `gitops.sh`, `secrets.sh` chỉ còn k3d.

### 6. Bootstrap EKS

- Root `infra/aws/gitops/<env>` đọc root env qua `terraform_remote_state` (`cluster_name`, `cluster_endpoint`, `cluster_certificate_authority_data`,
  `cluster_values`); provider `helm`, `kubernetes` lấy token bằng `exec` `aws eks get-token` (profile của env), host là `cluster_endpoint` hay
  `api_server_url` của `prd.tfvars` (tunnel), TLS server name là host của `cluster_endpoint`.
- Module `gitops-bridge` (không resource, test bằng `mock_provider`) tính tên, nhãn, nội dung cluster Secret, manifest root và values Argo CD.
- Commit bootstrap B là `gitopsRevision` của `envs/<env>/charts.yaml` ở `main`, khoá vắng thì commit của `main` lúc plan (`data "http"`: raw file, GitHub
  REST API); `require_pinned_revision` (`prd.tfvars` `true`, `stg.tfvars` `false`) làm plan dừng khi khoá vắng.
- Thứ tự `depends_on`: namespace → Argo CD → AppProject → cluster Secret → root. Namespace `argocd` và của dự án có nhãn Pod Security như
  `svp-cluster`: `data "helm_template"` (`show_only` `templates/namespaces.yaml`) trên chart `svp-cluster` mà runbook giải nén bằng `git archive` ở
  `revision` của `envs/<env>/charts.yaml` (đường dẫn qua biến) [N14], với values Application `svp-cluster` đọc (`platforms/eks/` ở B, `envs/<env>/` ở `main`).
- Argo CD một nguồn: `helm_release` lấy repo, chart, version từ `argocd/bootstrap.json`, values `base/argo-cd.yaml` rồi `platforms/eks/argo-cd.yaml` (bật
  controller ApplicationSet) của `svp-gitops` ở B. Argo CD không tự quản; đổi version hay values tới cluster ở lần apply sau.
- AppProject `svp`, `default` đã làm rỗng: nguyên văn `argocd/project.yaml` ở B, áp bằng `helm_release` của chart cục bộ `resources` của module (in
  nguyên văn danh sách manifest, như chart cùng tên của GitOps Bridge [N13]) với `take_ownership = true`, vì argocd-server đã tạo `default` [N14].
- Cluster Secret `in-cluster` (namespace `argocd`, server `https://kubernetes.default.svc`): label `argocd.argoproj.io/secret-type: cluster`,
  `svp.io/env`, `svp.io/platform: eks`, `svp.io/node-arch` (`arm64` | `amd64`, tfvars); annotation `svp.io/cluster-values` (JSON của `cluster_values`)
  và `svp.io/telegram-chat-id` (biến không commit, rỗng là chỉ commit status).
- Root là ApplicationSet `svp-bootstrap` (chart `resources`): cluster generator chọn Secret có label `svp.io/env` [N15], `goTemplate`, `missingkey=error`;
  nó tạo Application `svp-root` (project `svp`, label `svp.io/notify: root`, annotation `argocd.argoproj.io/compare-options: ServerSideDiff=false`, không
  finalizer, một source: chart `argocd/root` của `svp-gitops` ở `refs/heads/main`); `templatePatch` [N16] đặt `helm.valuesObject` `env`, `platform`,
  `nodeArch` từ label và `cluster` từ annotation (`fromYaml | toJson`), có chat thì thêm annotation `notifications.argoproj.io/subscribe.on-sync-failed.telegram`
  và `…on-health-degraded.telegram`. Phác thảo: phụ lục §6.
- `cluster` đi nguyên khối: `svp-root` → `svp-apps` (§7) → chart `argocd/apps`; mẫu `platforms/eks/*.values.tpl` vẫn đọc `.Values.cluster.<khoá>`.
  Hợp đồng `cluster.*` thêm `externalSecretsRoles` (map namespace → ARN role của §5, năm namespace `svp`, `svp-data`, `svp-obs`, `keda`, `argocd`):
  `svp-cluster.values.tpl` lấy role của SecretStore từ đó (thiếu namespace thì render fail) và region của store từ `region`.
- Revision `svp-root` theo dõi ở stg và prd: `refs/heads/main` từ lần sync đầu; commit status `argocd/<env>` ghi trên commit nó đã sync. k3d:
  `gitops.sh` tạo thẳng `svp-root` cùng spec (platform `k3d`, không `cluster`), không ApplicationSet.
- Trình tự buổi: apply `aws/envs/<env>` → `make eks-secrets` → (prd: PR promote đã merge, mở tunnel) → apply `aws/gitops/<env>` → chờ Application
  `svp-observability` Healthy (`kubectl wait --for=jsonpath`) → `make eks-glitchtip-init CONTEXT=svp-<env>` → `argocd app wait svp-root --sync --health`.
- Thứ tự gỡ: `pre-destroy.sh` xoá ApplicationSet `svp-bootstrap` (`svp-root`, `svp-apps` không finalizer nên không xoá dây chuyền), rồi Application workload,
  chờ NLB, TargetGroupBinding, bản ghi DNS, PVC gỡ khi controller còn chạy → destroy `aws/gitops/<env>` (prd qua tunnel) → destroy `aws/envs/<env>` → §9.

### 7. Ghim revision của prd

- Khoá `gitopsRevision` (commit 40 hex của `svp-gitops`, tuỳ chọn) trong `envs/<env>/charts.yaml`, file bot ghi: chỉ job `promote-prd` đặt nó.
- `svp-root` (tầng 1, chart `argocd/root` ở `refs/heads/main`) đọc `envs/<env>/` qua `files/envs`: kiểm `charts.yaml` (ba khoá cũ, `gitopsRevision` nếu có
  là 40 hex), lấy nội dung từng overlay và từng file `images/`, render đúng một Application `svp-apps`.
- `svp-apps` (tầng 2, không finalizer): chart `argocd/apps` ở R = `gitopsRevision`, khoá vắng thì `refs/heads/main`; values `targetRevision: R`,
  `envFiles` (`charts` bỏ `gitopsRevision`; `overlays`, `images`: tên file → nội dung), `env`, `platform`, `nodeArch`, `cluster`.
- Application mỗi component: chart upstream theo `components.json` ở R, chart backend ở `revision` của `envFiles.charts`; một nguồn `svp-gitops` duy
  nhất, `ref: values` ở R (`base/`, `platforms/`, mẫu `.values.tpl` cũng ở R); overlay, image của `envFiles` và phần mẫu sinh ra gộp vào
  `valuesObject` theo thứ tự đó (gộp như Helm gộp file values: map gộp từng khoá, giá trị khác kể cả list thay hẳn), Argo CD đọc sau mọi file
  values, nên thứ tự chung vẫn là `base/` < `platforms/` < overlay < image < mẫu. Không thêm nguồn `svp-gitops` thứ hai ở `refs/heads/main` cho
  `envs/<env>/`: repo-server của Argo CD v3.5.5 từ chối file values trỏ một repo ở hai revision (`cannot reference multiple revisions for the
  same repository`) [N21].
- Check của `svp-gitops`: render tầng 1 trên cây của PR; có khoá thì tầng 2 trên `git archive R` với `envs/<env>/` của PR, khoá phải là commit trên `main`;
  khoá vắng thì một cây, như hiện nay (stg luôn vắng). `valuesObject` của mỗi Application phải bằng overlay < image của cây < phần mẫu sinh ra; mọi
  nguồn `svp-gitops` của một Application cùng một revision.
- Rollback: lượt `promote-prd` với `stg_ref` cũ mở PR đặt lại `gitopsRevision` cùng image, chart của commit đó (Code Owner duyệt); R của `svp-apps` đổi,
  mọi component sync lại bản cũ.
- Vì sao hai tầng: generator của ApplicationSet chỉ đưa nội dung một file thành tham số, nên chart ở R sẽ đọc `envs/<env>/` cũ một lần promote; hai tầng
  giữ mọi luật render trong Helm, kiểm được bằng `helm template` (phụ lục, "Nguyên mẫu hai tầng").

### 8. Promote prd và bằng chứng stg

`promote-prd` ghi `gitopsRevision = <stg_ref>` cùng image và chart (một PR mỗi lần phát hành) và từ chối `stg_ref` không có commit status `argocd/stg`
`success` ([0032](0032-argocd-deploy-status.md)), đọc bằng token của job; hàm ở `deploy/ci/common.sh` cạnh `promote_stg_ref`, test trong
`promote-test.sh`. Buổi prd vì vậy cần buổi stg đã đồng bộ đúng commit sẽ promote.

### 9. Gỡ và kết thúc buổi

`aws/envs/prd/teardown.tfvars` chỉ nhấc bảo vệ cần để xoá (`rds_deletion_protection = false`, `media_force_destroy = true`…); gỡ prd là `apply` rồi
`destroy` với `-var-file=prd.tfvars -var-file=teardown.tfvars`, final snapshot vẫn được tạo. Sau §6: (prd) dán tên, thời điểm final snapshot, xoá nó và
backup tự động giữ lại; `sweep.sh <env>` rồi `sweep.sh mgmt` exit 0 chỉ khi account chỉ còn `Stack=baseline` (hay `bootstrap|org`) và KMS key `PendingDeletion`.

### 10. Chi phí

Buổi T = 4 giờ. H₀ (theo giờ khi prd chạy, chưa gồm Kafka) ~$0,90/giờ; O₀ (theo lượng dùng mỗi buổi, chưa gồm Kafka) ~$2,8; R (giữ giữa các buổi)
~$4,6/tháng năm đầu, báo riêng. Trần một buổi C = 4 × (H₀ + H_k) + O₀ + O_k, phần Kafka ở [0049](0049-kafka-prd.md). Bảng có nguồn và ngày đọc: phụ lục.

### Hệ quả

- Tốt: SCP và trail áp lên stg và prd; prd chỉ chạy cái stg đã chạy, rollback bằng PR; bootstrap EKS là Terraform theo mẫu GitOps Bridge; EKS không còn nguồn Secret trong cluster.
- Xấu: ba profile, thêm state; R tăng ~$4/tháng; mỗi lệnh `kubectl` vào prd cần tunnel; thêm tầng `argocd/root` (không bị ghim) và controller
  ApplicationSet; Argo CD, AppProject chỉ đổi khi apply lại; plan của root gitops cần mạng tới GitHub.
- Ngoài phạm vi: Karpenter (0034 Câu 7 hẹn cho prd, nay để sau), diễn tập migration expand/contract trên RDS, Valkey/ElastiCache HA, Velero, Log Archive
  và Audit account, permission set chỉ đọc cho prd.
- Xem lại khi: có người thứ hai cần quyền; cần control phát hiện liên tục (Control Tower); chi phí thực đo lệch quá 50 %; Source Hydrator lên GA.

## Xác nhận

- Lúc quyết chưa hiện thực. Đã kiểm: hai tầng render được bằng `helm template` trên bản sao `svp-gitops` (phụ lục, "Nguyên mẫu hai tầng").
- Còn lại: `make check` của `svp-infra` (test module, trivy, diff hai cặp root), check render có ghim của `svp-gitops`, `promote-test.sh`; buổi stg rồi
  buổi prd: `terraform apply` dựng cluster cùng Argo CD, `argocd/stg` có trên commit được promote, prd chạy đúng R, hai lượt sweep exit 0.

## Hiện thực ở

- `svp-infra`: `aws/org/`, `aws/modules/org-policies` (§1); `aws/accounts/`, `aws/modules/account-baseline`, `aws/bootstrap/` (§2); `aws/envs/`,
  `aws/modules/{network,eks,rds,media,waf,ssm-bastion,external-secrets}` (§3–§5); `aws/gitops/`, `aws/modules/gitops-bridge` (§6); `aws/scripts/`,
  `docs/runbooks/session-stg.md`, `session-prd.md` (§6, §9).
- `svp-gitops`: `argocd/root/`, `argocd/apps/`, `platforms/eks/argo-cd.yaml`, `envs/prd/` (§6, §7).
- Repo code: `deploy/k8s/aws-secrets.sh`, `glitchtip-init.sh`, `gitops.sh`, `secrets.sh`, `lib.sh` (§5, §6); `deploy/ci/common.sh`, `promote-test.sh`,
  `gitops-check.sh`, `cluster-values.example.yaml`, job `promote-prd` của `.github/workflows/images.yml` (§6–§8).

## Nguồn

Đọc 2026-11-05; đủ [N1]–[N21] và giá ở phụ lục. [N1] <https://docs.aws.amazon.com/organizations/latest/userguide/orgs_best-practices_mgmt-acct.html>,
[N5] <https://github.com/hashicorp/terraform-provider-kubernetes/blob/main/docs/index.md>, [N13] <https://github.com/gitops-bridge-dev/gitops-bridge>,
[N15] <https://github.com/argoproj/argo-cd/blob/v3.5.5/docs/operator-manual/applicationset/Generators-Cluster.md>, [N21] <https://github.com/argoproj/argo-cd/blob/v3.5.5/reposerver/repository/repository.go#L807-L812>.

## Thông tin thêm

Phụ lục: [`appendix/0048-prd-aws.md`](appendix/0048-prd-aws.md) (phương án, chi tiết từng §, bảng biến stg/prd, nguyên mẫu hai tầng, chi phí, nguồn).

### Chỉnh bởi

- §1, §2: [0051](0051-dns-prd-apex.md): zone gốc `aws.<miền>` ở account `svp-prd`, zone `stg.aws.<miền>` là zone con do zone prd uỷ quyền; management không còn hosted zone.
- Phương án "Edge prd", §3, §4: [0052](0052-cloudfront-flat-rate-free.md): lý do loại "CloudFront flat-rate plan" (theo tháng, không theo buổi) không còn đúng vì gói Free giá $0 và huỷ ngay; distribution media của stg và prd trên gói Free, root stg cũng gọi module `waf` (cùng provider alias `us_east_1`), `web_acl_arn` của `media` bắt buộc.
