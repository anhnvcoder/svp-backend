# Bảo mật AWS cấp tổ chức

Trang này giải thích lớp bảo mật nằm trên mọi account AWS của lab: org gồm những account nào và vì sao, guardrail gắn ở
đâu, ai đổi được gì, dịch vụ nào phát hiện bất thường, log đi về đâu và một sự kiện bảo mật tới người học bằng đường
nào. Quyết định và lý do ở [ADR-0059](../adr/0059-org-structure-guardrails.md) (cấu trúc, guardrail, quyền) và
[ADR-0060](../adr/0060-org-detection-logging.md) (phát hiện, log, cảnh báo); registry và credential AWS của CI ở
[ADR-0062](../adr/0062-ecr-registry-ci-oidc.md), endpoint interface ở [ADR-0064](../adr/0064-interface-endpoints.md),
Argo CD trên EKS ở [ADR-0065](../adr/0065-argocd-eks-capability.md); statement đủ của mọi policy, event pattern,
retention và bảng giá ở phụ lục của các ADR đó. Bảo mật trong một env (pod, bucket, mạng, dịch vụ dữ liệu) ở
[`threat-model.md`](../threat-model.md#411-biên-aws); đường vào công khai ở [`edge.md`](edge.md); stg so với prd ở
[`environments.md`](environments.md).

Code ở repo [`svp-infra`](https://github.com/anhnvcoder/svp-infra): root `aws/org`, `aws/log-archive`, `aws/security`,
`aws/baseline`, `aws/bootstrap`, `aws/accounts/<env>` và module `aws/modules/org-policies`,
`aws/modules/security-baseline`, `aws/modules/registry`, `aws/modules/network`. Mọi lệnh chạm account do người học chạy.

## Cấu trúc org theo AWS SRA

AWS Security Reference Architecture (SRA) tách việc quản trị, log và công cụ bảo mật ra khỏi account chạy workload. Admin của workload có toàn
quyền trong account của nó; nếu log và finding nằm cùng account, người đó (hay credential bị lộ của người đó) xoá được dấu vết của chính mình.
Đặt chúng ở account khác, chỉ đổi được qua Terraform chạy từ management, cắt đường đó.

![Sơ đồ org AWS](https://raw.githubusercontent.com/anhnvcoder/svp-infra/main/docs/diagrams/svp-aws-org.png)

| Account | OU | Vai trò | Profile |
| --- | --- | --- | --- |
| management | root của org | Organizations, Identity Center, trail org, policy, budget, state Terraform; không workload | `anhnv-sso` |
| `svp-log-archive` | `Security` | Log Archive: bucket của mọi loại log | `anhnv-log-ro` (chỉ đọc log) |
| `svp-security` | `Security` | Security Tooling: delegated admin của GuardDuty, Security Hub, Config, Access Analyzer; bus và topic cảnh báo | `anhnv-security-ro` (chỉ đọc) |
| `svp-prd` | `Workloads/Prod` | Env prd, chỉ sống trong buổi | `anhnv-prd`, `anhnv-prd-ro` |
| `svp-stg` | `Workloads/NonProd` | Env stg, chỉ sống trong buổi | `anhnv-stg`, `anhnv-stg-ro` |

Hai account `svp-log-archive`, `svp-security` không có profile ghi và không có bucket state riêng: Terraform của chúng chạy từ management (mục
sau). Biến terminal `SVP_AWS_LOG_ACCOUNT_ID`, `SVP_AWS_SECURITY_ACCOUNT_ID` giữ id của chúng, như `SVP_AWS_STG_ACCOUNT_ID`; không file commit nào
ghi id account.

### Policy của org gắn ở đâu

Policy gắn ở root của org áp cho mọi account thành viên, kể cả account tạo sau; policy gắn ở OU `Prod` chỉ áp cho prd. SCP và RCP không áp lên
management, nên management là đường sửa khi một guardrail chặn nhầm. Declarative policy và tag policy gắn root thì áp cả management.

| Policy | Loại | Gắn ở | Việc |
| --- | --- | --- | --- |
| `svp-deny-leave-organization` | SCP | root | Account không tự rời org |
| `svp-protect-cloudtrail` | SCP | root | Không dừng, xoá, sửa trail org |
| `svp-deny-other-regions` | SCP | root | Chỉ region nhà và `us-east-1` (dịch vụ toàn cục; WAF, cert ACM, log của CloudFront; khoá DNSSEC) |
| `svp-protect-baseline` | SCP | root | Không đổi baseline bảo mật của account, trừ **vai trò triển khai baseline** |
| `svp-deny-iam-users` | SCP | root | Không tạo IAM user, access key, mật khẩu console |
| `svp-prod-guardrails` | SCP | OU `Prod` | Không chạy EC2 Spot qua `RunInstances` ở prd |
| `svp-data-perimeter` | RCP | root | Dữ liệu S3, KMS, Secrets Manager, SQS, STS không tới principal ngoài org, không qua request không TLS |
| `svp-ec2-baseline` | Declarative EC2 | root | Không AMI, snapshot EBS public; IMDSv2 bắt buộc; serial console tắt |
| `svp-tags` | Tag policy | root | Bốn khoá tag `Project`, `Env`, `ManagedBy`, `Stack` đúng hoa thường và đúng giá trị |

SCP đặt trần quyền: IAM của account cho gì thì vẫn không vượt được nó. RCP đặt trần cho tài nguyên: một bucket policy lỡ cho principal ngoài org
vẫn bị RCP từ chối. Hai lớp bổ sung nhau, nên cấu hình sai ở một phía không đủ để lộ dữ liệu. `svp-prod-guardrails` không chặn được Spot qua
`CreateFleet` của Karpenter; NodePool on-demand của prd giữ phần đó (ADR-0059 §3).

## Ai đổi được gì

### Root chạy từ management và vai trò triển khai baseline

Ba root `aws/log-archive`, `aws/security`, `aws/baseline` chạy bằng `anhnv-sso`. Provider của mỗi account đích assume
`OrganizationAccountAccessRole`, role mà Organizations tạo trong mọi account thành viên và chỉ management assume được. Cách này giống
`AWSControlTowerExecution` của Control Tower: baseline của mọi account đi qua một đường có `plan` đọc được.

`OrganizationAccountAccessRole` cũng là principal duy nhất được miễn ở `svp-protect-baseline`. `SvpAdmin` ở stg, prd có `AdministratorAccess`
mà vẫn không tắt được GuardDuty, Config, Security Hub, không đổi S3 Block Public Access cấp account hay key EBS mặc định, không sửa rule chuyển
cảnh báo. Đổi lại, admin của management là admin của mọi account: management giữ ít người và MFA phần cứng.

### Permission set

Người học vào account bằng Identity Center, không IAM user. Mỗi permission set gán ở account cần nó; thời hạn phiên ở ADR-0059 §8.

| Permission set | Gán ở | Quyền | Dùng cho |
| --- | --- | --- | --- |
| `SvpAdmin` | `svp-stg`, `svp-prd` | `AdministratorAccess`, phiên ngắn | `apply`, script buổi |
| `SvpReadOnly` | `svp-stg`, `svp-prd`, `svp-security` | `ViewOnlyAccess` + `SecurityAudit`, thêm đọc CloudWatch Logs | Đọc cấu hình, trạng thái, finding; không đọc object S3, giá trị secret, dữ liệu bảng; không ghi trạng thái finding |
| `SvpLogReader` | `svp-log-archive` | `ViewOnlyAccess`, đọc object và giải mã bucket log | Đọc log trail, Config, flow log, GuardDuty, WAF, CloudFront |

Đọc hằng ngày đi qua permission set chỉ đọc, nên một phiên điều tra không vô tình sửa gì; quyền ghi chỉ mở khi cần, và chỉ ở stg, prd.

### Root tập trung và break-glass

`aws/org` bật centralized root access: account thành viên không giữ mật khẩu, access key hay MFA của root. Việc chỉ root làm được trên account
thành viên đi qua `sts:AssumeRoot` từ management, mỗi phiên một task policy và một thời hạn ngắn. Rule `svp-security-root-session` của management
bắt phiên mở ở `ap-southeast-1` và `us-east-1` (mục [Đường cảnh báo](#luồng-phát-hiện-tới-cảnh-báo)). STS nhận `AssumeRoot` ở endpoint của mọi
region, mà management không chịu `svp-deny-other-regions`: phiên mở ở region khác chỉ nằm trong trail org, không tới email (phần Hệ quả của
ADR-0060). Root của management giữ MFA phần cứng cất ngoài máy và là đường break-glass khi Identity Center hỏng: runbook
[`break-glass.md`](https://github.com/anhnvcoder/svp-infra/blob/main/docs/runbooks/break-glass.md) của `svp-infra`.

## Baseline của mỗi account

Module `security-baseline` áp một lần mỗi account trong năm account (management, `svp-log-archive`, `svp-security`, `svp-stg`, `svp-prd`), từ
root `aws/baseline`:

- S3 Block Public Access cấp account, bốn cờ bật.
- EBS mã hoá mặc định ở region nhà và `us-east-1`. Ở `svp-stg`, `svp-prd` region nhà key mặc định là CMK `alias/svp-ebs` (root `aws/baseline`
  tạo), nơi khác là `aws/ebs`.
- AWS Config ghi liên tục mọi loại tài nguyên, giao snapshot và lịch sử về bucket Config của Log Archive.
- Rule EventBridge `svp-security-*` chuyển sự kiện bảo mật sang account `svp-security`.

Khác biệt giữa account (key EBS, có chuyển sự kiện đổi IAM, KMS, S3 hay không, region của rule đăng nhập root) là dữ liệu trong bảng
`local.accounts` của `aws/baseline`, không nhánh `if` theo account. Ở stg, prd không chuyển sự kiện đổi IAM, KMS, S3 thành công: mỗi buổi tạo
và xoá hàng chục role, key, bucket, và email cho từng cái sẽ che mất email đáng đọc.

## Phát hiện

Root `aws/security` cấu hình các dịch vụ từ account `svp-security`, delegated admin do `aws/org` đăng ký, ở region nhà `ap-southeast-1` và
`us-east-1`. Region khác bị `svp-deny-other-regions` chặn ở account thành viên nên không bật.

- **GuardDuty** tự bật cho mọi account, kể cả account mới: S3 Protection, EKS Audit Log, Runtime Monitoring, RDS Protection, Lambda Protection,
  Malware Protection for EC2. Agent runtime của node EKS là add-on `aws-guardduty-agent` do module `eks` cài, gửi sự kiện qua interface endpoint
  `guardduty-data` của module `network`: GuardDuty tự quản agent thì tự tạo endpoint và security group ngoài state Terraform, chặn destroy VPC
  cuối buổi. Bucket `uploads` của mỗi env có plan Malware Protection for S3 (module `media`), gắn tag kết quả quét lên object.
- **Security Hub CSPM** cấu hình tập trung: một configuration policy `svp-security-standards` gắn root bật chuẩn AWS Foundational Security Best
  Practices và CIS AWS Foundations Benchmark cho mọi account; region nhà gom finding của `us-east-1`.
- **AWS Config**: recorder của baseline ở mọi account, aggregator `svp-org` ở `svp-security`. Không conformance pack: chuẩn CIS của Security Hub
  đã đánh giá cùng các rule.
- **IAM Access Analyzer** loại `ORGANIZATION` ở hai region: báo tài nguyên chia sẻ ra ngoài org.
- **Amazon Inspector** ([ADR-0062](../adr/0062-ecr-registry-ci-oidc.md) §10) qua delegated admin `svp-security`, chỉ
  loại tài nguyên ECR, ở region nhà: cấu hình org (`aws/security/inspector.tf`) tự bật quét ECR cho mọi account thành
  viên, cả `svp-security`, `svp-log-archive`. Registry của `svp-stg`, `svp-prd` quét nâng cao liên tục chỉ trên repo của
  pull-through cache (image bên thứ ba); repo phát hành đã qua trivy, grype trước push, rescan hằng ngày và admission
  đòi báo cáo dưới hạn, nên không quét lại. Không EC2 (node thay mỗi buổi, AMI ghim, vá bằng nâng AMI) và không Lambda
  (lab không có). Finding vào Security Hub.

Phần không được giám sát và lý do (bastion không có agent runtime, volume mã hoá bằng `alias/svp-ebs` không được quét malware, management ngoài
hai region, kể cả phiên `AssumeRoot` mở ở đó) ở phần Hệ quả của ADR-0060.

## Lớp edge

Mỗi env đón request công khai ở CloudFront, không ở load balancer nào trong VPC ([`edge.md`](edge.md),
[ADR-0061](../adr/0061-edge-cloudfront-waf-acm.md)). Phần bảo mật của lớp này:

- **WAF:** ba web ACL scope CLOUDFRONT mỗi env (`svp-<env>-web`, `-api`, `-media`), giống hệt ở stg và prd: luật rate-based theo IP, IP
  reputation và các nhóm luật managed của AWS; ATP cho đăng nhập ở api, Bot Control chỉ gắn nhãn ở web. Log về bucket log WAF của Log Archive.
- **Origin không công khai:** web, API qua VPC origin tới ALB internal ở subnet edge; security group của ALB chỉ nhận prefix list
  origin-facing của CloudFront. Media đọc bucket qua OAC.
- **TLS:** cert ACM ở CloudFront (`us-east-1`) và ALB (region nhà), TLS policy AWS khuyên; Envoy dùng CA nội bộ của cert-manager, nên không
  khoá riêng của cert công khai nào nằm trong cluster.
- **DNS:** CAA ở đỉnh zone của cả hai env chỉ cho CA của Amazon; zone prd ký DNSSEC (khoá KMS ở `us-east-1`, hai alarm page tới topic SNS
  của module `alarms`) và có query log. Root `aws/accounts/<env>` giữ chúng, sống giữa các buổi.
- **Log:** log chuẩn v2 của CloudFront và log WAF về Log Archive (mục sau); không access log ALB vì mọi request đã có ở hai log đó.

Control Security Hub FSBP áp lên tài nguyên edge (`CloudFront.*`, `WAF.*`, `ACM.*`, `Route53.*`, `ELB.*`), đạt hay chấp nhận có lý do: phụ lục
ADR-0061. Mối đe doạ của lớp này ở [threat model](../threat-model.md#413-edge).

## Registry và credential AWS của CI

Image chạy trên EKS nằm trong ECR private của chính account env ([ADR-0062](../adr/0062-ecr-registry-ci-oidc.md)):
module `registry` ở root `aws/accounts/<env>`, sống qua mọi buổi. Phần bảo mật:

- **Repo phát hành** (`svp-backend/<service>`, `svp-frontend/web`): mã hoá bằng CMK `alias/svp-<env>-ecr` (ECR dùng key
  qua grant, người đẩy, kéo không cần quyền KMS), tag `IMMUTABLE`, không lifecycle xoá image (một bản phát hành đang
  chạy hay là đích rollback không bị xoá tự động). Chữ ký và attestation đi theo image dưới dạng referrer, nên Kyverno
  xác minh ngay ở ECR, cùng identity keyless như ở GHCR.
- **Pull-through cache** cho năm tiền tố (`ghcr`, `docker-hub`, `quay`, `k8s`, `ecr-public`): credential của GHCR,
  Docker Hub là secret `ecr-pullthroughcache/*` (PAT chỉ đọc, người học ghi và xoay), ECR đọc bằng service-linked role
  của nó. Role node chỉ thêm quyền nhập image upstream trên `repository/<tiền tố>/*`.
- **Role CI ECR:** CI của `svp-backend`, `svp-frontend` có credential AWS, ngoại lệ có ADR của luật "CI không credential
  AWS"; `svp-infra` vẫn không có. Mỗi account env một IAM OIDC provider `token.actions.githubusercontent.com`; mỗi role
  tin đúng một chuỗi `sub` dạng bất biến (`repo:<owner>@<owner-id>/<repo>@<repo-id>:...`, không đổi khi repo đổi tên),
  phiên 1 giờ, chỉ quyền đẩy ECR trên repo của nó:

  | Role | Account | Ai nhận (`sub`) | Repo | Xoá |
  | --- | --- | --- | --- | --- |
  | `svp-ci-ecr-release-backend` | stg | `svp-backend`, `ref:refs/heads/main` | `svp-backend/*` | không |
  | `svp-ci-ecr-release-frontend` | stg | `svp-frontend`, `ref:refs/heads/main` | `svp-frontend/web` | không |
  | `svp-ci-ecr-promote` | prd | `svp-backend`, `environment:promote-prd` | mọi repo phát hành | không |
  | `svp-ci-ecr-rescan-backend` | stg, prd | `svp-backend`, `environment:ecr-rescan` | `svp-backend/*` | có |
  | `svp-ci-ecr-rescan-frontend` | stg, prd | `svp-frontend`, `environment:ecr-rescan` | `svp-frontend/web` | có |

  Tách theo repo nguồn: frontend không ghi được image backend và ngược lại. Tách theo mục đích: prd không có role nhận
  `main`, image vào prd chỉ qua job `promote-prd` có người duyệt; chỉ role rescan được `BatchDeleteImage` (gỡ báo cáo lỗ
  hổng cũ). Account ID chỉ ở secret repo, bị che trong log công khai. Luồng phát hành dùng các role:
  [`delivery.md`](delivery.md#phát-hành-sang-ecr).

```mermaid
sequenceDiagram
    participant J as Job CI (main hay environment)
    participant GH as OIDC của GitHub
    participant STS as AWS STS (account env)
    participant ECR as ECR của env
    J->>GH: xin ID token (id-token: write), audience sts.amazonaws.com
    GH-->>J: JWT ký, sub = repo:owner@id/repo@id:ref hay :environment
    J->>STS: AssumeRoleWithWebIdentity (configure-aws-credentials)
    STS->>STS: kiểm chữ ký, aud, sub đúng một chuỗi của trust policy
    STS-->>J: credential tạm 1 giờ của role
    J->>ECR: GetAuthorizationToken, đăng nhập vào DOCKER_CONFIG riêng của job
    J->>ECR: chép, xác minh trên đúng repo mà role cho
```

Rủi ro còn lại (job nào trên `main` khai environment `ecr-rescan` cũng nhận role rescan, role rescan ghi và xoá được
image của repo mình) ở [threat model](../threat-model.md#48-bề-mặt-khác) SC-16.

## Endpoint interface

Mọi gọi API AWS từ VPC của env đi qua endpoint interface ([ADR-0064](../adr/0064-interface-endpoints.md)), module
`network`: STS, `eks-auth`, Secrets Manager, CloudWatch Logs, SSM, ECR, EC2, ELB, AMP, X-Ray, SQS (danh sách là dữ liệu
của module). Private DNS bật, nên tên API công khai phân giải ra IP của ENI trong VPC và pod không phải cấu hình gì;
security group `svp-<env>-endpoints` chỉ nhận TCP 443 từ CIDR của VPC.

- **Endpoint policy:** ở dịch vụ nhận policy, cho mọi hành động nhưng từ chối khi `aws:PrincipalAccount` khác account
  của env: credential của account khác không dùng được đường này. Policy không thay IAM; dịch vụ không nhận policy thì
  AWS cho toàn quyền qua endpoint.
- **Không `kms`:** không thành phần nào trong VPC gọi KMS trực tiếp; EBS, Secrets Manager, ECR, CloudWatch Logs, AMP gọi
  KMS thay người dùng.
- **NetworkPolicy:** pod gọi API AWS (Kyverno, External Secrets, Collector, Prometheus agent, ACK) mở thêm TCP 443 tới
  `awsEndpointCidrs` (EKS: CIDR của VPC) và TCP 80 tới agent Pod Identity, vì private DNS đưa đích của chúng vào dải
  private mà policy cũ chặn.
- **Vẫn qua NAT:** GitHub, Telegram, Sigstore, lần kéo đầu của pull-through cache, API ECR Public, API Pricing của
  Karpenter, Amazon Managed Grafana (bảng: ADR-0064 §6).

## Đăng nhập công cụ vận hành

Người học vào công cụ vận hành của env bằng IAM Identity Center của org, không tài khoản riêng của công cụ. Hai nhóm ở
`aws/org/identity-center.tf`: `svp-platform-admins`, `svp-platform-viewers`; id nhóm chỉ ở `<env>.auto.tfvars` không
commit của root `aws/accounts/<env>`.

- **Amazon Managed Grafana** `svp-<env>` ([ADR-0063](../adr/0063-managed-observability.md) §4): xác thực `AWS_SSO`, nhóm
  admin là `ADMIN`, nhóm viewer là `VIEWER`; quyền đọc AMP, CloudWatch của env qua role `svp-<env>-grafana`
  (`CUSTOMER_MANAGED`). Grafana Operator trong cluster ghi dashboard bằng token của service account
  `svp-grafana-operator`, tạo mới mỗi buổi; token không bao giờ vào git.
- **Argo CD trên EKS** giữ cách cài hiện tại: chart `argo-cd` tự cài, một replica, đăng nhập `admin` cục bộ, UI chỉ qua
  port-forward loopback (threat model OPS-2). ADR-0065 chọn EKS Capability cho Argo CD (AWS chạy Argo CD, đăng nhập
  Identity Center theo hai nhóm trên, không tài khoản cục bộ); thay đổi đó là việc riêng, kèm cập nhật threat model.

```mermaid
sequenceDiagram
    participant U as Người học (trình duyệt)
    participant AMG as Amazon Managed Grafana svp-env
    participant IDC as IAM Identity Center của org
    U->>AMG: mở URL workspace
    AMG->>IDC: chuyển hướng tới trang đăng nhập
    U->>IDC: đăng nhập bằng user của Identity Center
    IDC-->>AMG: assertion: user, nhóm svp-platform-*
    AMG->>AMG: vai trò theo nhóm: admins → Admin, viewers → Viewer
    AMG-->>U: dashboard, truy vấn AMP, CloudWatch bằng role svp-env-grafana
```

## Luồng log

Mọi log bảo mật về account `svp-log-archive`. Mỗi loại log một bucket, tên `<tiền tố>-<id account log>-<region>`
([ADR-0038](../adr/0038-s3-bucket-names.md)), mã hoá bằng key `alias/svp-log-archive` cùng region với bucket, policy chỉ cho principal dịch vụ
của org ghi. Riêng bucket access log của trail dùng SSE-S3: S3 chỉ giao server access log vào bucket SSE-S3. Bucket trail có Object Lock;
retention của từng bucket ở ADR-0060 §7.

```mermaid
flowchart LR
    subgraph mgmt["management"]
        trail["Trail org svp-audit<br/>mọi account, mọi region"]
    end
    subgraph every["mọi account"]
        config["Config recorder<br/>module security-baseline"]
    end
    subgraph sec["svp-security"]
        gd["GuardDuty detector<br/>ap-southeast-1, us-east-1"]
    end
    subgraph env["svp-stg, svp-prd, trong buổi"]
        vpc["VPC flow log<br/>module network"]
        waf["Web ACL của CloudFront<br/>module waf, us-east-1"]
        cfd["Distribution CloudFront<br/>module edge, media, us-east-1"]
    end
    subgraph log["svp-log-archive"]
        subgraph home["ap-southeast-1, key alias/svp-log-archive"]
            bct[("svp-cloudtrail-#lt;log#gt;-ap-southeast-1<br/>Object Lock")]
            bcfg[("svp-config-#lt;log#gt;-ap-southeast-1")]
            bgd[("svp-guardduty-#lt;log#gt;-ap-southeast-1")]
            bfl[("svp-flowlogs-#lt;log#gt;-ap-southeast-1")]
            bacc[("svp-cloudtrail-access-#lt;log#gt;-ap-southeast-1<br/>SSE-S3")]
        end
        subgraph use1["us-east-1, key alias/svp-log-archive"]
            bwaf[("aws-waf-logs-svp-#lt;log#gt;-us-east-1")]
            dest["Delivery destination<br/>svp-cloudfront-env"]
            bcf[("svp-cloudfront-#lt;log#gt;-us-east-1")]
        end
    end
    trail --> bct
    bct -.->|"server access log"| bacc
    config --> bcfg
    gd -->|"xuất finding"| bgd
    vpc -->|"Parquet"| bfl
    waf -->|"che authorization, cookie"| bwaf
    cfd -->|"log chuẩn v2, không cookie"| dest --> bcf
```

- Trail `svp-audit` ở management ghi management event của mọi account. Data event S3 chỉ cho bucket người dùng của prd: `uploads` đọc và ghi,
  `media` chỉ ghi (đọc là lưu lượng người xem qua CloudFront). stg không có dữ liệu người dùng thật, nên không trả phí data event ở đó.
- Bucket trail cũ ở management còn giữ log trước khi trail đổi đích, chỉ đọc tới khi Object Lock của nó hết hạn; README của `aws/org` ghi bước gỡ.
- Log chuẩn v2 của CloudFront đi chéo account: account env giữ delivery source và delivery, `svp-log-archive` giữ delivery destination mỗi env
  và bucket ([ADR-0061](../adr/0061-edge-cloudfront-waf-acm.md) §8). Media của stg (gói CloudFront Free) không có log này.
- Flow log, log WAF và log CloudFront chỉ có khi env sống, nhưng bucket sống giữa các buổi: log của buổi đã gỡ vẫn đọc được. Root env nhận id account log qua
  `TF_VAR_log_archive_account_id` (từ `SVP_AWS_LOG_ACCOUNT_ID`), nên buổi chỉ chạy được sau khi `aws/log-archive` đã áp.
- Đọc log: profile `anhnv-log-ro`; lệnh mẫu ở runbook [`security-alert.md`](../runbooks/security-alert.md).

## Luồng phát hiện tới cảnh báo

Cảnh báo phải tới người học khi không cluster nào chạy, nên nó đi hoàn toàn trên dịch vụ managed: EventBridge, SNS, email.

```mermaid
flowchart LR
    subgraph acct["Mỗi account, ap-southeast-1 và us-east-1"]
        ct["Sự kiện CloudTrail<br/>bus mặc định"] --> fwd["Rule svp-security-*<br/>module security-baseline"]
    end
    subgraph sec["svp-security, ap-southeast-1"]
        bus["Bus svp-security-events<br/>policy theo aws:PrincipalOrgID"] --> notify["Rule svp-security-notify"]
        gd["GuardDuty"] --> sh["Security Hub CSPM<br/>aggregator"]
        aa["IAM Access Analyzer"] --> sh
        insp["Inspector<br/>repo cache ECR"] --> sh
        sh -->|"Security Hub Findings - Imported"| findings["Rule svp-security-findings<br/>HIGH, CRITICAL, NEW, ACTIVE"]
        notify --> sns[["Topic SNS svp-security-alarms<br/>mã hoá CMK"]]
        findings --> sns
    end
    fwd -->|"role svp-security-forwarder"| bus
    sns --> mail["Email security_alert_email"]
```

- Rule ở mỗi account bắt các nhóm sự kiện của ADR-0060 §10: root đăng nhập; management mở phiên `AssumeRoot` (chỉ ở hai region, mục
  [Root tập trung và break-glass](#root-tập-trung-và-break-glass)); đổi cấu trúc, policy của Organizations (chỉ management); trail bị dừng,
  xoá, sửa; rule `svp-security-*` bị đổi; GuardDuty, Security Hub, Config, Access Analyzer bị tắt hay đổi; lệnh bị guardrail từ chối;
  đổi IAM, KMS, S3, Identity Center ở ba account không chạy workload. Event pattern đủ ở phụ lục ADR-0060.
- Sự kiện cần role để sang bus của account khác (`svp-security-forwarder`); bus chỉ nhận từ principal trong org.
- Finding đi đường riêng: GuardDuty và Access Analyzer gửi finding vào Security Hub, rule trên bus mặc định của
  `svp-security` chỉ lấy finding mới, còn mở, mức HIGH hay CRITICAL của hai dịch vụ đó (lọc theo `ProductName`). Finding
  của Inspector chỉ ở Security Hub, không tới email: người học đọc nó cùng bảng Security Hub. Finding của control FSBP,
  CIS không tới email: Security Hub gửi lại sự kiện mỗi lần đánh giá lại, email sẽ lặp; người học đọc bảng Security Hub
  theo runbook.
- Input transformer ghi tên sự kiện hay tiêu đề finding, account, region, principal, mã lỗi và URL runbook
  [`security-alert.md`](../runbooks/security-alert.md), nên email đủ để bắt đầu phân loại.
- Topic SNS dùng module `alarms` như alarm của dịch vụ managed; publisher là `events.amazonaws.com` thay vì CloudWatch.

## Thứ tự áp lần đầu

Mỗi root đọc thứ root trước tạo ra (id account, tên bucket, ARN key), nên lần đầu phải áp theo thứ tự. Mọi bước do người học chạy theo runbook
[`org-security-setup.md`](https://github.com/anhnvcoder/svp-infra/blob/main/docs/runbooks/org-security-setup.md) của `svp-infra`; bước nào đỏ thì
dừng.

```mermaid
sequenceDiagram
    participant P as Người học (anhnv-sso)
    participant B as aws/bootstrap
    participant O as aws/org
    participant L as aws/log-archive
    participant S as aws/security
    participant BL as aws/baseline
    P->>B: 1. apply: key state, Cost Anomaly Detection, tag phân bổ
    P->>P: sinh lại backend.hcl, init -reconfigure mọi root
    P->>O: 2. apply -target: tổ chức, OU, account
    P->>P: đặt SVP_AWS_LOG_ACCOUNT_ID, SVP_AWS_SECURITY_ACCOUNT_ID
    P->>L: 3. apply: bucket log, key
    P->>O: 4. apply đủ: trusted access, delegated admin, root tập trung, policy, permission set, trail đổi đích
    P->>S: 5. apply: GuardDuty, Security Hub, Config, Access Analyzer, bus, topic
    P->>P: xác nhận đăng ký email SNS
    P->>BL: 6. apply: baseline năm account
    P->>P: 7. kiểm sau áp: dịch vụ bật, phép thử guardrail, cảnh báo thử
```

Bước 2 dùng `-target` vì tạo account gần như không đảo ngược (đóng account chờ 90 ngày): plan của bước này chỉ được thêm hai account và đổi OU
của stg, prd. Bước 3 phải trước bước 4 vì trail và policy của bucket trỏ vào nhau: bucket cho đúng trail `svp-audit` ghi, trail chỉ đổi đích
khi bucket đã có. Từ khi bước 1–3 đã áp, buổi stg, prd mới chạy được, vì root env ghi flow log, log WAF và log CloudFront vào Log Archive.
Phần edge (bucket log CloudFront, CAA, DNSSEC) áp thêm theo runbook
[`edge-setup.md`](https://github.com/anhnvcoder/svp-infra/blob/main/docs/runbooks/edge-setup.md) của `svp-infra`.
