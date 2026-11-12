# Phụ lục ADR-0062: Image của stg, prd ở ECR private của từng account env: CI sao chép cùng digest kèm chữ ký, attestation từ GHCR bằng role OIDC hẹp theo repo và mục đích; image bên thứ ba qua pull-through cache được làm nóng theo tag, Kyverno đổi tham chiếu lúc tạo pod; Inspector quét repo cache

Phụ lục của [ADR-0062](../0062-ecr-registry-ci-oidc.md): phương án, giá trị đủ của từng §, bảng subject → referrer, bảng control FSBP, bảng
luồng SCP, RCP, bảng giá và nguồn, xếp theo §. Mọi nguồn đọc ngày 2026-11-13. Đường dẫn `aws/...` không kèm repo là của `svp-infra`; `<stg>`,
`<prd>` là id account `svp-stg`, `svp-prd`; `<ecr>` là host **Registry ECR của env**; `<owner-id>`, `<repo-id>` là id số của account GitHub
`anhnvcoder` và của repo. Thuật ngữ in đậm là tên mà các ADR, module, workflow dùng chung; nghĩa ghi ở ADR và phụ lục này.

## Phương án

| Câu hỏi | Phương án | Trạng thái ngành | Được | Mất | Nguồn |
| --- | --- | --- | --- | --- | --- |
| Nơi đặt registry | **ECR private của mỗi account env** | Hiện hành (mỗi workload account một registry) | Image vào prd chỉ qua `promote-prd`; IAM, KMS trong cùng account, không policy chéo | Hai bản lưu, hai lượt quét Inspector mỗi digest; rescan chép `vuln` tới hai nơi | [N27] |
| | ECR ở account Shared Services (OU Infrastructure), chia sẻ bằng policy repo theo org | Hiện hành (registry trung tâm) | Một bản lưu, một lượt quét; ít role CI hơn | Thêm account, policy repo, key policy và role chéo account; image chưa duyệt nằm cạnh image prd; SRA không nêu registry cho account này | [N28], [N29] |
| | Giữ GHCR, thêm pull-through cache GHCR | Hiện hành | CI không cần credential AWS | Kéo lần đầu theo digest qua cache lỗi [N9] mà bản phát hành nào cũng ghim digest; cache GHCR cần PAT; referrer qua cache chỉ được làm mới mỗi 6 giờ | [N6], [N9] |
| Đưa bản phát hành vào ECR | **oras chép index và từng referrer theo subject** | Hiện hành (OCI 1.1) | Cùng digest, chữ ký keyless của nguồn giữ nguyên; chạy lại thấy đúng phần thiếu | Thêm job, credential; dựa vào việc ECR nhận referrer GHCR (phép thử) | [N1], [N21] |
| | `oras cp -r` một lệnh | Hiện hành (preview của ORAS) | Ngắn | Lỗi ở referrer nào không rõ; một báo cáo ECR trả 405 cho referrer SPDX có `subject` là index | [N10], [N21] |
| | Build lại và push ECR | Cũ cho nhiều registry | Không cần chép | Trái build một lần; digest khác GHCR, phải ký lại | — |
| | ECR replication stg → prd | Hiện hành | ECR tự chép | Mọi bản stg vào prd, không qua duyệt `promote-prd`; lưu trữ prd tăng như stg | — |
| | Ký managed của ECR (AWS Signer) | Mới | Ký khi push, không cần cosign | Mất identity keyless và attestation của nguồn; Kyverno phải kiểm loại chữ ký khác; $0,02 mỗi lần ký | [N25] |
| Image bên thứ ba | **Pull-through cache, `MutatingPolicy` đổi tham chiếu, làm nóng theo tag** | Hiện hành (bài AWS dùng Kyverno) | Một chỗ đổi cho mọi chart; cache sống qua destroy; image được quét | Bước làm nóng mỗi buổi; webhook mutate; pod tạo trước Kyverno kéo upstream | [N6], [N8], [N9] |
| | Sửa registry trong values từng chart | Hiện hành | Không webhook | ~15 chart, mỗi chart một khoá khác; chart thêm image mới thì lọt | — |
| | Mirror của containerd (`hosts.toml`) trên node | Hiện hành | Trượt cache thì rơi về upstream | kubelet đưa credential theo tên image (upstream), mirror ECR không nhận token; cấu hình nằm trong AMI, userdata | — |
| | Giữ kéo upstream qua NAT | Hiện trạng | Không thêm gì | Không quét; giới hạn lượt kéo Docker Hub; phụ thuộc năm registry | [0034](../0034-aws-stage7.md) |
| Policy đổi tham chiếu | **`MutatingPolicy` `policies.kyverno.io/v1` (CEL)** | Hiện hành của Kyverno | Cùng họ với IVP `svp-images` đang chạy | Bài AWS viết bằng `ClusterPolicy`, phải dịch | [N15], [N16] |
| | `ClusterPolicy` mutate | Cũ: deprecate ở v1.19, dự kiến bỏ ở v1.20 | Mẫu có sẵn của bài AWS | Viết lại khi lên v1.20 | [N8], [N15] |
| Giữ bản phát hành | **Không lifecycle** | — | Không xoá bản đang chạy hay đích rollback | Lưu trữ tăng không giới hạn (§11); ECR.3 FAILED | [N3] |
| | Giữ N bản mới nhất (`imageCountMoreThan`) | Hiện hành | Chặn trên dung lượng | Digest prd hay đích rollback cũ hơn N bị xoá | [N3] |
| | `sinceImagePushed`, `sinceImagePulled` | Hiện hành | Chặn trên theo tuổi | Env chỉ chạy trong buổi: digest đang dùng có thể lâu không được kéo | [N3] |
| | Archive (`transition`) | Mới (2025-11) | Giữ bản cũ | Image archive không kéo được tới khi khôi phục; giá bậc đầu bằng lưu thường | [N3], [N25] |
| Quét | **Inspector liên tục trên năm tiền tố cache** | Hiện hành | Image bên thứ ba có finding ở Security Hub, quét lại khi có CVE mới | ~$0,18 mỗi digest mới mỗi account; ECR.1 FAILED ở repo phát hành | [N23], [N25] |
| | Inspector mọi repo | Hiện hành | ECR.1 đạt mọi repo | Quét lại bản đã qua cổng trivy, grype: 285 digest × 2 nền tảng × $0,09 ≈ $51 mỗi tháng ở stg | [N25] |
| | Basic scanning của ECR | Hiện hành, miễn phí | Không tốn | Không Inspector.2, không quét liên tục, không finding Inspector ở Security Hub | [N23] |
| Credential CI | **Role OIDC, `sub` bất biến, `StringEquals`** | Hiện hành (GitHub, AWS khuyên) | Không khoá dài hạn; đổi tên hay tạo lại repo không mở lại trust | Trust phải đúng id số của account và repo | [N11], [N12], [N13] |
| | `sub` theo tên (`repo:anhnvcoder/<repo>:...`) | Cũ với repo đổi tên sau 2026-07-15 | Dễ đọc | GitHub không phát dạng này cho hai repo nữa: không nhận được role | [N12] |
| | Access key IAM user | Cũ | — | Khoá dài hạn trong secret; SCP `svp-deny-iam-users` cấm | [0059](../0059-org-structure-guardrails.md) §3 |

## §1. Nơi đặt registry

- Host registry private của ECR có dạng `aws_account_id.dkr.ecr.region.amazonaws.com` [N27] (ví dụ
  `000000000000.dkr.ecr.ap-southeast-1.amazonaws.com`); regex `ecrRegistry` của **Hợp đồng cluster**
  (`^[0-9]{12}\.dkr\.ecr\.[a-z]{2}(-[a-z]+)+-[0-9]+\.amazonaws\.com$`) khớp dạng đó, gồm `ap-southeast-1`. Endpoint FIPS, dual-stack không dùng.
- AWS SRA, Shared Services: "The Shared Services account is part of the Infrastructure OU, and its purpose is to support the services that
  multiple applications and teams use to deliver their outcomes" [N28]; trang đó kể Systems Manager, Directory Service, IAM Identity Center, không
  nêu registry. Mẫu registry trung tâm của AWS chia sẻ repo bằng policy theo `aws:PrincipalOrgID` [N29].
- Lý do không chọn trung tâm: thêm một account (OU Infrastructure chưa có), Pod Identity của Kyverno và role node kéo chéo account, key KMS cho
  principal hai account; image từ `main` (chưa duyệt) và image prd chung một registry. Lợi duy nhất đo được là chi phí (§11: một bản lưu, một
  lượt quét Inspector mỗi digest).

## §2. Repo phát hành

| Thiết lập | Giá trị | Lý do, nguồn |
| --- | --- | --- |
| Repo | `svp-backend/gateway`, `user-service`, `video-service`, `engagement-service`, `feed-service`, `media-worker`, `svp-frontend/web` | `services` của `sources.json` (**Repo phát hành**) |
| Mã hoá | `KMS`, key `alias/svp-<env>-ecr`, xoay hằng năm | ECR.5 (không thuộc FSBP); ECR tạo hai grant cho repo khi tạo, gọi `GenerateDataKey` khi đẩy, `Decrypt` khi kéo [N5] |
| Key policy | quản trị bởi account; không principal ngoài account | Người tạo repo cần `kms:CreateGrant`, `kms:DescribeKey`, `kms:RetireGrant` [N5]: Terraform chạy bằng quyền admin của account |
| Tag | `IMMUTABLE` | ECR.2 "passes if tag immutability is enabled and has the value `IMMUTABLE`" [N24]; `IMMUTABLE_WITH_EXCLUSION` (2025-07) không đạt ECR.2 và không cần |
| Tag của bản phát hành | không tag, chép theo digest | Digest trong `envs/<env>/images/` là danh tính; kubelet kéo `repo:tag@digest` theo digest |
| Quét | không vào filter Inspector | §10 |
| Lifecycle | không | Mọi image ở đây không tag: rule `untagged`, `any` nào cũng chọn chúng |
| Policy repo | không | Mọi principal đọc, ghi ở cùng account, quyền nằm ở IAM |

Hành vi lifecycle với referrer và manifest con [N3]: "When reference artifacts are present in a repository, Amazon ECR lifecycle policies
automatically expire or archive those artifacts within 24 hours of the deletion or archival of the subject image"; "If an image is referenced by a
manifest list, it cannot be expired or archived without the manifest list being deleted or archived first". GC theo tập đang dùng sau này chỉ cần
xoá index; referrer và manifest con đi theo.

## §3. Sao chép phát hành

### OCI 1.1 ở ECR và GHCR

- ECR: "OCI 1.1 is now supported in ECR in all AWS commercial regions" (What's New 2024-06-27); blog AWS: "clients can query a registry like
  Amazon ECR for any image referrers for a given image digest" [N1]. API `ListImageReferrers` của ECR có ví dụ referrer
  `artifactType: application/vnd.dev.sigstore.bundle.v0.3+json` và đòi `ecr:BatchGetImage` [N2].
- Sigstore: cosign ghi bundle mới thành referrer OCI 1.1; ECR, GHCR nằm trong danh sách registry đã thử [N20].
- GHCR không có referrers API (nguồn thứ cấp; khớp hành vi `oras manifest delete` mà 0040 §3 ghi): oras đọc referrer qua tag dự phòng
  `sha256-<digest>` theo spec phân phối OCI [N22].
- ORAS v1.3: `--from-distribution-spec`, `--to-distribution-spec` nhận `v1.1-referrers-tag`, `v1.1-referrers-api`; "When copying an image
  index, all of its manifests will be copied" [N21].

### Đồ thị phát hành

Đọc từ `.github/actions/image-sign/action.yml` (bản phát hành; image diễn tập không chép vì không thuộc **Repo phát hành**):

| Subject | Referrer | Bước tạo |
| --- | --- | --- |
| index `DIGEST` | chữ ký (`cosign sign`, bundle) | "Sign and attest" |
| index `DIGEST` | `vuln` (`cosign attest --type vuln`, bundle) | "Sign and attest"; rescan thay |
| index `DIGEST` | provenance SLSA (`actions/attest`, `push-to-registry: true`) | "Attest the build provenance" |
| manifest con `linux/amd64` | SBOM SPDX (`cosign attest --type spdxjson`, bundle) | "Sign and attest" |
| manifest con `linux/arm64` | SBOM SPDX (`cosign attest --type spdxjson`, bundle) | "Sign and attest" |

### Lệnh và thứ tự

- (i) Index chưa có ở đích: `oras cp` index theo digest, nguồn `--from-distribution-spec v1.1-referrers-tag`, đích
  `--to-distribution-spec v1.1-referrers-api`, không `-r`. Đích ghi tag dự phòng thì lỗi ngay (repo `IMMUTABLE`), nên cờ đích đặt tường minh.
- (ii) Mỗi subject của bảng trên: `oras discover` nguồn và đích, chép từng referrer nguồn có mà đích thiếu (trừ `vuln` khi đích đã có một).
- (iii) `cosign verify`, `cosign verify-attestation` (SBOM trên từng manifest con; `vuln`, provenance trên index) ở `<ecr>/<tên>@<DIGEST>` với
  identity của `sources.json`; `vuln` ở đích có `scanFinishedOn` trong `maxAttestationAge`.
- Không bước nào xoá, và "index đã có" không bao giờ là xong: lượt lỗi giữa chừng (index đã chép, thiếu referrer) được lượt chạy lại chép nốt rồi
  verify. `vuln` ở đích quá `maxAttestationAge` thì `copy` lỗi, thông điệp nêu lệnh rescan (§4).
- Quota: `PutImage` 10 lần mỗi giây mỗi registry; ảnh mỗi repo 100 000 [N4].
- Rủi ro đã biết [N10] (mở từ 2026-03-06, chưa có trả lời của AWS): `oras copy -r` từ `ghcr.io` sang ECR nhận `405 Method Not Allowed`,
  "Invalid parameter at 'ImageManifest' failed to satisfy constraint: 'Invalid JSON syntax'" cho referrer SPDX có `subject` là index. Bundle
  Sigstore là manifest khác (artifact type, layer bundle); phép thử trước khi dựng chép đủ năm referrer của một bản phát hành thật.

### Ba chỗ chạy

| Chỗ | Khi nào | Digest | Đích | Role (§5) | Lỗi thì |
| --- | --- | --- | --- | --- | --- |
| (a) job `ecr-copy` của `images.yml`, sau `sign`, matrix theo image (`svp-backend` sáu image, `svp-frontend` `web`) | Mỗi lượt build trên `main` | Digest leg vừa ký | ECR stg | `svp-ci-ecr-release-backend`, `svp-ci-ecr-release-frontend` | Leg đỏ, không artifact `ecr-<image>`: image đó không được promote (§4) |
| (b) job `promote-prd` của `svp-backend` (environment `promote-prd`, có người duyệt) | Dispatch `promote_prd` | Mọi image của `envs/stg/images/` ở `stg_ref`, cả `web` | ECR prd | `svp-ci-ecr-promote` | Chép và verify hết trước khi mở PR `bot/promote-prd`; một image lỗi thì không mở. Digest đã chép bị bỏ lại tới khi `vuln` quá hạn: **Rescan digest chưa promote** với `env: prd` (§4) |
| (c) job `rescan` của mỗi repo code (environment `ecr-rescan`) | Lịch hằng ngày; dispatch `rescan` | **Tập rescan ECR** hay một digest (**Rescan digest chưa promote**), §4 | ECR của env theo §4 | `svp-ci-ecr-rescan-<repo>` ở stg rồi prd | Job đỏ; chạy lại an toàn |

Index vào ECR stg qua (a) (hay đường phục hồi của nó, §4), vào ECR prd chỉ qua (b); (c) không đưa digest mới nào vào ECR prd.

## §4. Digest phát hành và rescan ECR

### Digest phát hành

`ecr-copy` là matrix theo image, `fail-fast: false`; mỗi leg tải artifact `ecr-<image>` (cùng `repository`, `tag`, `digest` của `release-<image>`)
chỉ sau khi verify trên bản ECR đạt. `promote` (stg) `needs: [plan, ecr-copy]` và đọc `pattern: ecr-*` thay `release-*`: image lỗi chép hay verify
không có artifact nên không được promote, image khác vẫn đi (luật "promotes successful ones" có sẵn); chạy lại leg lỗi rồi chạy lại `promote` thì đi
tiếp. `images-ok` tính `ecr-copy`.

### Tập rescan ECR

`rescan.sh list` đọc `envs/<e>/images/` ở các ref dưới đây; job của mỗi repo code chỉ giữ dòng của image nó phát hành (`svp-backend` sáu image,
`svp-frontend` `web`). Mỗi dòng đọc dưới `envs/<e>/` là một cặp (digest, ECR của env `<e>`): `envs/stg/` → ECR stg, `envs/prd/` → ECR prd; host lấy
từ biến `SVP_ECR_REGISTRY_STG`, `SVP_ECR_REGISTRY_PRD` mà job đặt (rỗng thì bỏ bước ECR: test, k3d).

| Ref đọc | Vì sao trong tập |
| --- | --- |
| `main` của `svp-gitops` | Digest stg, prd đang chạy |
| Mọi PR promote đang mở của bot: `bot/promote-stg` (backend), `bot/promote-stg-web` (frontend), `bot/promote-prd` (mọi image) | Digest chờ merge hay chờ duyệt; index đã ở ECR từ (a), (b) trước khi PR mở |
| `values_ref`: nhánh, SHA hay `refs/pull/<n>/head` của `svp-gitops` | Digest rollback (ca dưới) |
| `values_ref` là commit của repo code (trước `svp-gitops`, k3d) | Không có đích ECR: chỉ làm mới GHCR |

`rescan.sh run` ghi `vuln` mới trên GHCR cho mỗi digest (0040 §3), rồi gọi `ecr-copy.sh refresh` cho mỗi cặp của digest đó bằng role rescan của
account env đó:

1. Index không có ở ECR đó (`ecr:DescribeImages`): in thông báo, bỏ qua, không lỗi; index chỉ vào ECR qua (a), (b) của §3 (hay đường phục
   hồi của (a), dưới).
2. Chép `vuln` mới từ GHCR.
3. Đọc danh sách referrer ở đích, gỡ mọi `vuln` khác bằng `aws ecr batch-delete-image --image-ids imageDigest=<digest>` (`ecr:BatchDeleteImage`,
   tối đa 100 id mỗi lần): tài liệu ECR chỉ nêu API này [N3]; `DELETE /v2/<name>/manifests/<digest>` của spec OCI không thấy trong tài liệu ECR.
   Chỉ gỡ `vuln`; đọc lại danh sách, phải còn đúng một `vuln`, như 0040 §3.
4. Chép referrer khác còn thiếu theo từng subject như (ii) của §3, rồi verify như (iii).

Sau một lượt rescan, mỗi cặp có đúng một `vuln`, là bản mới. Một cặp lỗi thì job `rescan` đỏ; chạy lại an toàn vì mỗi bước đọc đích trước khi ghi.

### Ca theo thời gian

| Ca | Bản ECR được làm mới | Cách |
| --- | --- | --- |
| Digest stg, prd đang chạy | ECR của env đó | Rescan hằng ngày đọc `main` |
| PR promote stg chờ merge quá 72 giờ | ECR stg (index vào từ (a)) | Rescan hằng ngày đọc nhánh của PR |
| PR promote prd chờ duyệt quá 72 giờ | ECR prd (index vào từ (b) trước khi PR mở) | Rescan hằng ngày đọc `bot/promote-prd` |
| Rollback stg tới digest cũ hơn `maxAttestationAge` | ECR stg | Runbook: trước khi sync, dispatch rescan với `values_ref` là ref ghi digest đó dưới `envs/stg/` (PR revert: `refs/pull/<n>/head`) |
| Rollback prd (`promote-prd` với `stg_ref` cũ) | GHCR, ECR stg; ECR prd khi digest từng chạy ở prd | Dispatch rescan với `values_ref` = `stg_ref` (guard có sẵn của `promote-prd`); digest từng chạy ở prd còn bản ECR prd với `vuln` cũ, (b) không thay được: thêm một dispatch với `values_ref` là commit `main` lúc `envs/prd/` còn ghi digest đó |
| Digest chưa vào `envs/` (leg (a) lỗi, `vuln` quá hạn) | ECR stg | **Rescan digest chưa promote** với `env: stg` (dưới) |
| `promote-prd` đã chép digest vào ECR prd rồi lỗi ở image khác, không mở PR; chạy lại khi `vuln` ở ECR prd đã quá hạn | ECR prd (digest chưa có dưới `envs/prd/` ở ref nào: rescan theo lịch chỉ làm mới GHCR, ECR stg) | **Rescan digest chưa promote** với `env: prd` (dưới), mỗi image bị bỏ lại một dispatch |
| Digest phát hành trước khi có đường ECR | Không có bản ở ECR (`refresh` bỏ qua) | stg: dispatch `images.yml` với `services: all` ở hai repo code (build, chép, promote mới); prd: lượt `promote-prd` kế tiếp ((b) chép mọi image) |

### Rescan digest chưa promote

Bản ECR của một digest bị bỏ lại tới khi `vuln` quá `maxAttestationAge`, lúc digest chưa có dưới `envs/<env>/` ở ref nào của **Tập rescan
ECR**: rescan theo lịch không làm mới bản đó, còn `copy` không xoá nên không tự thay `vuln`. Hai ca:

- `stg`: leg (a) lỗi (ECR, mạng) và chỉ được chạy lại sau khi `vuln` quá hạn; digest chưa ở `envs/` nên `vuln` ở GHCR cũng đã cũ.
- `prd`: `promote-prd` (b) đã chép, verify digest vào ECR prd rồi lỗi ở image khác nên không mở PR; lượt chạy lại sau 72 giờ verify digest đó lỗi
  vì `vuln` ở ECR prd quá hạn. Digest có ở `envs/stg/` nên GHCR, ECR stg vẫn được làm mới hằng ngày; ECR prd thì không.

Workflow `images.yml` của repo phát hành image (`svp-backend` cho sáu image, `svp-frontend` cho `web`) nhận input `digest`, `image`, `env` (`stg`
mặc định, `prd`) cho job `rescan` (dispatch, environment `ecr-rescan`), dùng role rescan của repo đó ở account `env`:

1. `rescan.sh run` cho đúng digest đó trên GHCR (ghi `vuln` mới, không qua `list`).
2. `ecr-copy.sh refresh` sang ECR của `env`: bản bị bỏ lại có `vuln` cũ thì `vuln` mới được chép, bản cũ bị gỡ; index chưa có thì bỏ qua.
3. `stg`: `ecr-copy.sh copy` sang ECR stg (chép phần còn thiếu, verify), rồi chạy lại leg `ecr-copy` lỗi của lượt build (giờ verify đạt, tải
   `ecr-<image>`) và `promote`. `prd`: không `copy` (index chỉ vào ECR prd qua (b)); chạy lại `promote-prd` với cùng `stg_ref`, (b) chép phần còn
   thiếu, verify mọi image rồi mở PR.

Mỗi image bị bỏ lại một dispatch. Role rescan của mỗi account đã có quyền đẩy và xoá trên repo của mình: không nới quyền role release, role promote
vẫn không xoá.

### Vì sao role release, promote không có quyền xoá

Chúng chạy ở mọi bản phát hành; xoá nhầm chữ ký, SBOM, provenance thì pod mới bị từ chối. `vuln` quá hạn ở đích là việc của rescan: `copy` lỗi,
thông điệp nêu lệnh `gh workflow run images.yml ... -f rescan=true -f values_ref=<ref>` (digest đã ở `envs/<env>/` của ECR đang verify) hay input
`digest`, `image`, `env` (chưa ở đó: `stg` với (a), `prd` với (b)).

## §5. Role CI ECR

### Trust

- GitHub: provider `https://token.actions.githubusercontent.com`, audience `sts.amazonaws.com` cho action chính thức [N11]. IAM: "AWS secures
  communication with OIDC identity providers (IdPs) using our library of trusted root certificate authorities ... only then we secure
  communication using the thumbprints" [N13]: GitHub dùng CA tin cậy, provider không cần thumbprint.
- Changelog GitHub [N12]: "All repositories created after July 15, 2026 will automatically use the new immutable subject claim format";
  "Repository renames and transfers after July 15, 2026 will also adopt the new format"; ghi chú 2026-06-10: dấu phân cách là `@`. Tài liệu
  [N11]: `repo:OWNER@OWNER-ID/REPO@REPO-ID:ref:refs/heads/BRANCH`; "You can't remove these IDs from the immutable format". Job có environment:
  "The subject claim includes the environment name when the job references an environment" [N11].
- Hai repo đổi tên 2026-10-31 ([0036](../0036-repo-rename.md)), nên dùng dạng bất biến. Người học kiểm trước khi apply:
  `gh api repos/anhnvcoder/svp-backend/actions/oidc/customization/sub` (trường `use_immutable_subject`), id: `gh api users/anhnvcoder --jq .id`,
  `gh api repos/anhnvcoder/<repo> --jq .id`. Id là số công khai, ghi trong `locals` của root `aws/accounts/<env>`.

| Role | Account | `sub` (`StringEquals`) | Repo ECR | Xoá |
| --- | --- | --- | --- | --- |
| `svp-ci-ecr-release-backend` | stg | `repo:anhnvcoder@<owner-id>/svp-backend@<backend-id>:ref:refs/heads/main` | `svp-backend/*` | không |
| `svp-ci-ecr-release-frontend` | stg | `repo:anhnvcoder@<owner-id>/svp-frontend@<frontend-id>:ref:refs/heads/main` | `svp-frontend/web` | không |
| `svp-ci-ecr-promote` | prd | `repo:anhnvcoder@<owner-id>/svp-backend@<backend-id>:environment:promote-prd` | mọi **Repo phát hành** | không |
| `svp-ci-ecr-rescan-backend` | stg, prd | `repo:anhnvcoder@<owner-id>/svp-backend@<backend-id>:environment:ecr-rescan` | `svp-backend/*` | có |
| `svp-ci-ecr-rescan-frontend` | stg, prd | `repo:anhnvcoder@<owner-id>/svp-frontend@<frontend-id>:environment:ecr-rescan` | `svp-frontend/web` | có |

Mỗi role: điều kiện `token.actions.githubusercontent.com:aud` = `sts.amazonaws.com` và `:sub` đúng chuỗi trên, `MaxSessionDuration` 3 600
(IAM nhận 1–12 giờ [N13]).

### Quyền đẩy ECR

| Action | Resource | Bước dùng |
| --- | --- | --- |
| `ecr:GetAuthorizationToken` | `*` (API không nhận resource) | `aws ecr get-login-password` |
| `ecr:BatchCheckLayerAvailability`, `InitiateLayerUpload`, `UploadLayerPart`, `CompleteLayerUpload` | ARN repo của role | đẩy blob |
| `ecr:PutImage` | ARN repo của role | đẩy index, manifest con, referrer |
| `ecr:BatchGetImage` | ARN repo của role | đọc manifest; referrers API [N2] |
| `ecr:GetDownloadUrlForLayer` | ARN repo của role | đọc bundle khi verify |
| `ecr:DescribeImages` | ARN repo của role | `refresh`: index có ở ECR không |
| `ecr:BatchDeleteImage` | ARN repo của role rescan | gỡ `vuln` cũ |

Không quyền KMS: ECR gọi KMS qua grant của repo [N5].

### Trong workflow

`aws-actions/configure-aws-credentials` v6.3.0 (2026-09-15) [N14], ghim SHA như mọi action; `role-to-assume` dựng từ secret
`SVP_AWS_<ENV>_ACCOUNT_ID` và tên role cố định, `aws-region: ap-southeast-1`, `role-duration-seconds: 3600`, `mask-aws-account-id: true` ("Setting
this will hide account IDs from output anyway" [N14]). Job cần `id-token: write`.

## §6. Pull-through cache

### Rule và credential

| Tiền tố | Upstream | Credential | Ghi chú |
| --- | --- | --- | --- |
| `ghcr` | `ghcr.io` | `ecr-pullthroughcache/ghcr` | PAT (classic), chỉ `read:packages` |
| `docker-hub` | `registry-1.docker.io` | `ecr-pullthroughcache/docker-hub` | PAT "Repo Public Read-only"; image chính thức cần `library/` |
| `quay` | `quay.io` | không | |
| `k8s` | `registry.k8s.io` | không | |
| `ecr-public` | `public.ecr.aws` | không | |

- ECR [N6]: "Amazon ECR Public, Kubernetes container image registry, and Quay (doesn't require authentication)"; "Docker Hub, ..., GitHub Container
  Registry ... (requires authentication with AWS Secrets Manager secret)". Secret: tên bắt đầu `ecr-pullthroughcache/`, cùng account, region với
  rule, khoá `username`, `accessToken`; "You must use the default `aws/secretsmanager` encryption key to encrypt your secret. Amazon ECR doesn't support
  using a customer managed key (CMK) for this." ECR dùng service-linked role `AWSServiceRoleForECRPullThroughCache` (principal
  `pullthroughcache.ecr.amazonaws.com`).
- GitHub [N26]: "GitHub Packages only supports authentication using a personal access token (classic)"; "Select the `read:packages` scope to
  download container images and read their metadata". Docker [N30]: "Repo Public Read-only: View, search, and pull images from public
  repositories"; hạn 30, 90 ngày hay tuỳ chọn tới một năm, không sửa hạn được.
- Hạn 90 ngày cả hai; người học tạo token, ghi bằng `aws secretsmanager put-secret-value` với profile của account env, xoay trước hạn theo runbook
  (lịch nhắc của người học; GitHub gửi email trước khi PAT hết hạn). SecretsManager.1, .4 FAILED (§FSBP).
- Hành vi [N6]: ECR làm mới tag "at least once every 24 hours"; referrer "within the last 6 hours"; upstream lỗi thì "the last cached image will
  still be pulled"; kéo lần đầu cần đường ra Internet của ECR.

### Repository creation template

| Thiết lập | Giá trị | Nguồn |
| --- | --- | --- |
| Tiền tố, `appliedFor` | năm tiền tố trên, `PULL_THROUGH_CACHE` | "the repository prefix you specify during rule creation is what you should specify as your repository creation template prefix" [N7] |
| Mã hoá | `KMS`, key `alias/svp-<env>-ecr` | ECR.5 |
| Tag | `MUTABLE` | "the recommended setting to use for templates used for repositories created by pull through cache actions" [N7]; "Turning on image tag immutability for repositories using a pull through cache rule will prevent Amazon ECR from updating images using the same tag" [N6] |
| Lifecycle | một rule: `tagStatus: any`, `countType: sinceImagePulled`, 30 ngày, `expire` | Image không được kéo 30 ngày thì xoá; buổi sau làm nóng lại (§7); referrer theo subject [N3]. ECR nhận `sinceImagePulled` với `expire` từ 2026-11-11: trước đó API trả "SINCE_IMAGE_PULLED CountType can only be used with TRANSITION ActionType"; AWS đóng yêu cầu: "Starting today, `sinceImagePulled` now supports the expire action ... No intermediate archive step required" [N31]. Bản tiếng Anh của [N3] (đọc 2026-11-13) ghi "are expired or archived"; bản dịch của trang ví dụ còn câu cấm cũ. Phép thử trước khi dựng tạo template này |
| Role tạo repo | `svp-<env>-ecr-template`, trust `ecr.amazonaws.com`; `ecr:CreateRepository`, `ecr:TagResource` trên `repository/<tiền tố>/*`; `kms:CreateGrant`, `kms:RetireGrant`, `kms:DescribeKey` trên key | "This role must be provided when using repository tags and/or KMS in the template" [N7]; mẫu của AWS dùng resource `*` và thêm `ecr:ReplicateImage` (không replication: bỏ) [N7] |

### Quyền của node

`ecr:BatchImportUpstreamImage` ("retrieve the external image and import it to your private registry") và `ecr:CreateRepository` ("required if the
repository storing the cached images doesn't already exist") trên `arn:aws:ecr:ap-southeast-1:<account>:repository/<tiền tố>/*` [N6], thêm vào
role của MNG `system` và node Karpenter; kéo dùng `AmazonEC2ContainerRegistryReadOnly` có sẵn (`aws/modules/eks/README.md`).

## §7. Làm nóng cache

- Roadmap ECR #2837 [N9] (mở 2026-07-18, nhãn "Proposed"): "Allow a pull-through cache rule to populate the cache when an image is referenced by
  digest (`@sha256:…`), not only when it's pulled by tag"; "a digest reference for an image the cache hasn't already seen fails (`manifest unknown`,
  ...)". Tài liệu ECR chỉ nói kéo theo digest một kiến trúc của image đã có [N6].
- Danh sách: output của `deploy/ci/image-list.sh <gitops> <env>` (repo này), mỗi dòng `<ref upstream>:<tag>@<digest>` của một image bên thứ ba
  ghim trong bản render eks của env, cùng nguồn với `pin_check` của `deploy/ci/gitops-check.sh`; image của **Repo phát hành** không thuộc danh sách.
- `aws/scripts/ecr-warm.sh <env> <file danh sách>` (`svp-infra`), mỗi dòng: ánh xạ theo **Ánh xạ registry**, kéo `<ecr>/<tiền tố>/<repo>:<tag>`
  (index, mọi manifest con [N6]) bằng credential của người học, rồi kiểm digest ghim có ở ECR; không có thì lỗi, nêu image, tag, digest ghim và
  digest ECR đang giữ cho tag. Lỗi vì cache chưa làm mới tag (tối đa 24 giờ) thì chạy lại sau; vì upstream dời tag thì cập nhật digest ghim
  (PR Renovate).
- Chạy mỗi buổi sau `aws/envs/<env>`, trước bootstrap Argo CD; chạy lại khi PR đổi digest bên thứ ba merge giữa buổi. Lần chạy thứ hai không
  nhập gì mới. Phép thử trước khi dựng kéo theo digest một image chưa cache (xác nhận #2837 với các upstream của lab), rồi theo tag và theo digest,
  để chốt lệnh kéo của script.

## §8. Chuyển hướng image

### Kyverno

- v1.19 [N15]: "Official deprecation of `ClusterPolicy` and `Policy`", "removal planned for v1.20"; v1.17 đưa `MutatingPolicy` lên `v1`.
  `MutatingPolicy` dùng `matchConstraints`, `matchConditions`, `patchType` `JSONPatch` hay `ApplyConfiguration` [N16]. Policy chọn `JSONPatch` trên từng
  phần tử `containers`, `initContainers`, `ephemeralContainers` có image khớp một luật (danh sách `registryMirror.rules`, tiền tố dài nhất trước).
- Bài AWS [N8] dùng `ClusterPolicy` hai rule mutate (`containers`, `initContainers`); về `failurePolicy`: "Ignoring the webhook on failure may be
  needed during an outage, but it is up to you to determine how your policy webhook should be configured."
- Kyverno không gửi request của `kube-system`, `kyverno` tới webhook của policy (namespaceSelector của ConfigMap Kyverno, ghi ở
  `deploy/helm/svp-policy/templates/imagevalidatingpolicy.yaml`): Karpenter, Load Balancer Controller (`kube-system`) và Kyverno kéo upstream.

### Ánh xạ và chuẩn hoá

| Tham chiếu trong pod | Sau ánh xạ |
| --- | --- |
| `glitchtip/glitchtip:6.2.6@sha256:…` | `<ecr>/docker-hub/glitchtip/glitchtip:6.2.6@sha256:…` |
| `redis:8@sha256:…` | `<ecr>/docker-hub/library/redis:8@sha256:…` |
| `docker.io/library/redis:8.10.2-alpine@sha256:…` | `<ecr>/docker-hub/library/redis:8.10.2-alpine@sha256:…` |
| `index.docker.io/envoyproxy/gateway:v1.9.3@sha256:…` | `<ecr>/docker-hub/envoyproxy/gateway:v1.9.3@sha256:…` |
| `quay.io/argoproj/argocd:v3.5.5@sha256:…` | `<ecr>/quay/argoproj/argocd:v3.5.5@sha256:…` |
| `registry.k8s.io/kube-state-metrics/kube-state-metrics:v2.20.0@sha256:…` | `<ecr>/k8s/kube-state-metrics/kube-state-metrics:v2.20.0@sha256:…` |
| `ghcr.io/cloudnative-pg/cloudnative-pg:1.30.1@sha256:…` | `<ecr>/ghcr/cloudnative-pg/cloudnative-pg:1.30.1@sha256:…` |
| `ghcr.io/anhnvcoder/svp-backend/gateway:<tag>@sha256:…` | `<ecr>/svp-backend/gateway:<tag>@sha256:…` |
| `public.ecr.aws/<x>:…` ngoài `kube-system` | `<ecr>/ecr-public/<x>:…` |
| `localhost:5000/x`, host khác năm upstream | không đổi |

- Đoạn đầu là host khi có `.`, `:` hay là `localhost` (cách Docker phân tích tên); không thì Docker Hub. Tên Docker Hub một đoạn thêm `library/`:
  "For Docker Hub official images, the `/library` prefix must be included" [N6].
- Hàm `image()` của thư viện CEL Kyverno: `registry()` cho "e.g., `index.docker.io`", `repository()` "e.g., `library/nginx`" [N16]; chart
  `svp-policy` dùng hàm này hay xử lý chuỗi, test Kyverno CLI giữ đủ bảng trên.
- `kubectl debug` thêm container qua subresource `pods/ephemeralcontainers` (UPDATE): policy chỉ khớp CREATE `pods`, container đó kéo upstream.

## §9. Ảnh phát hành trên eks

- Kyverno IVP [N17]: `credentials.providers` nhận `default`, `amazon`, `azure`, `google`, `github`; với `amazon` "no secret is required, provided
  the Kyverno admission controller pod has the appropriate IAM permissions"; bảng quyền nêu `ecr:GetAuthorizationToken`, `ecr:BatchGetImage`; tài liệu
  chỉ tả IRSA.
- `go.mod` của Kyverno v1.19.1 [N18]: `github.com/aws/aws-sdk-go-v2/config v1.32.31`, `github.com/awslabs/amazon-ecr-credential-helper/ecr-login
  v0.12.0`, `github.com/google/go-containerregistry v0.21.8`, `github.com/sigstore/cosign/v3 v3.1.2`. Bản tối thiểu có Pod Identity: "Go v2 –
  release-2023-11-14" [N18]; Pod Identity là credential provider của container trong chuỗi mặc định của SDK.
- Quyền: `ecr:GetAuthorizationToken` (resource `*`); `ecr:BatchGetImage`, `ecr:GetDownloadUrlForLayer` (tải layer bundle) trên ARN mọi **Repo phát
  hành**; không quyền KMS [N5]; không quyền cache (namespace `svp` không chạy image bên thứ ba).
- Issue Kyverno liên quan: #16664 [N19] ("`fetchBundles` ... calls `remote.Referrers(subject)`", lỗi trên registry không có referrers API; ECR có);
  #17363 (attestor `key.kms`, lab dùng keyless); #17833 (mỗi bundle tải hai lần: thời gian admission đo ở buổi, ngưỡng của 0040 §6).

## §10. Quét ECR

| Thiết lập | Giá trị | Nguồn |
| --- | --- | --- |
| Delegated admin | `svp-security` (`aws/org/delegated-admins.tf`, `inspector2.amazonaws.com` trong service access) | "Only the AWS Organizations management account can designate and remove a delegated administrator" [N23] |
| Bật cho thành viên | ECR cho mọi account thành viên hiện có (stg, prd, `svp-log-archive`, `svp-security`) và account mới | Inspector.2 "fails if the delegated Amazon Inspector administrator account or any associated member account doesn't have ECR scanning enabled" [N24]; account không có image không tốn gì |
| Loại tài nguyên | chỉ ECR | Dưới đây |
| Cấu hình quét registry (mỗi account env) | `ENHANCED`, `CONTINUOUS_SCAN`, filter `ghcr/*`, `docker-hub/*`, `quay/*`, `k8s/*`, `ecr-public/*` | Chế độ quét chỉ đặt ở ECR [N23] |
| Thời hạn quét lại | mặc định của Inspector (7 ngày với account bật từ 2026-10-15) | [N23]; với image đa kiến trúc, theo dõi "last in use" không hỗ trợ, quét lại theo ngày đẩy, kéo |
| Finding | Security Hub (tích hợp Inspector), cùng đường cảnh báo với GuardDuty ([0060](../0060-org-detection-logging.md)) | |

- Inspector: "continually scanned" khi bật liên tục, quét lại "Whenever Amazon Inspector adds a new common vulnerabilities and exposures (CVE)
  item to its database, and that CVE is relevant to that container image"; không hỗ trợ media type danh sách manifest, quét từng manifest con [N23].
- Không EC2: node sống trong buổi, AMI EKS ghim version và vá bằng nâng AMI (0056); GuardDuty Runtime Monitoring theo dõi node; EC2 scanning tính
  theo instance. Không Lambda: lab không có function. Repo phát hành: §10 của ADR.
- Không thêm SCP cho Inspector: sau khi bật, chỉ delegated admin tắt được Inspector của thành viên [N23]; cấu hình quét registry do root
  `aws/accounts/<env>` giữ, lệch thì plan thấy.

## §11. Chi phí registry

### Bảng giá

| Dịch vụ | Mục | Giá (USD) | Nguồn |
| --- | --- | --- | --- |
| ECR | Lưu trữ, `ap-southeast-1` | 0,10 mỗi GB-tháng (`APS1-TimedStorage-ByteHrs`) | [N25] Price List `AmazonECR` |
| ECR | Truyền trong region | 0 | [N25] trang giá ECR |
| ECR | Pull-through cache | không phí riêng, tính lưu trữ | [N8] |
| ECR | Ký managed (phương án không chọn) | 0,02 mỗi lần | [N25] Price List |
| Inspector | Image quét lần đầu; quét lại | 0,09; 0,01 (ví dụ `us-east-1`, trang không ghi Singapore); thử 15 ngày miễn phí cho account mới dùng | [N25] |
| KMS | Key | 1,00 mỗi tháng, tính theo giờ; 0,03 mỗi 10 000 request | [N25] |
| Secrets Manager | Secret; API | 0,40 mỗi secret-tháng; 0,05 mỗi 10 000 lần gọi | [N25] |
| IAM | OIDC provider, role | 0 | — |

### Số đo dùng để tính

- Bản phát hành: 30 ngày tới 2026-11-13, dòng `digest:` mới trong `envs/<env>/images/` của `svp-gitops`: stg 285 (gateway 43, user-service,
  video-service, engagement-service, media-worker 41, feed-service 40, `web` 38), prd 28 (bốn lượt promote × 7).
- Cỡ nén mỗi kiến trúc (manifest GHCR của digest stg hiện tại): gateway 18,8–20,4 MB (layer binary 17,9–19,5 MB), feed-service 24,0–26,1 MB,
  media-worker 72–76 MB (binary 18,9–20,6 MB, ffmpeg 49–52 MB), `web` 68,7–69,1 MB (layer 51 MB và 6 MB). Layer binary đổi ở mọi bản (bốn bản
  gateway liền nhau có bốn layer binary khác), layer nền dùng chung trong repo.
- Image bên thứ ba: 38 digest ghim trong `base/`, `platforms/eks/`, `argocd/apps/` (gồm vài image chỉ k3d); 50 digest bên thứ ba mới trong 30 ngày.

### Lưu trữ tăng theo bản phát hành

| Repo | Mỗi tháng (giới hạn trên) | Chi phí thêm |
| --- | --- | --- |
| Go, stg: 206 digest × 2 kiến trúc × ~21 MB | ~8,7 GB | |
| media-worker, stg: 41 × 2 × ~20 MB | ~1,6 GB | |
| `web`, stg: 38 × 2 × ~57 MB | ~4,3 GB | |
| **stg** | **~14,5 GB** | +$1,45 mỗi tháng, cộng dồn: tháng 1 trung bình ~$0,7, tháng 3 ~$3,6, tháng 6 ~$8 |
| **prd**: 4 × (6 × 42 MB + 114 MB) | **~1,5 GB** | +$0,15 mỗi tháng, cộng dồn |

### Lúc không buổi (hai account)

| Khoản | Tháng (USD) |
| --- | --- |
| Hai key KMS `alias/svp-<env>-ecr` | 2,00 |
| Bốn secret cache (hai mỗi account) | 1,60 |
| Repo cache (~5 GB mỗi account, xoá sau 30 ngày không kéo) | ~1,00 |
| Repo phát hành stg, prd (bảng trên) | ~0,8 ở tháng 1; ~4 ở tháng 3; ~8,8 ở tháng 6 |
| Inspector quét lại trong 7 ngày sau lượt nhập, request KMS, API Secrets Manager | < 0,5 |
| **Cộng** | **~5,7 ở tháng 1; ~9 ở tháng 3; ~14 ở tháng 6** |

Khoản lớn nhất về lâu dài là lưu trữ bản phát hành stg; GC theo tập đang dùng là cách chặn (Xem lại khi của ADR).

### Mỗi buổi (mỗi account env)

| Khoản | stg | prd |
| --- | --- | --- |
| Inspector: mỗi digest bên thứ ba mới được nhập × 2 nền tảng (amd64, arm64) × 0,09 | buổi đầu ≤ 38 × 0,18 ≈ 6,8; buổi sau một tháng ≤ 50 × 0,18 ≈ 9 (chỉ digest eks dùng) | như stg |
| Kéo image ECR → node trong region; layer qua endpoint gateway S3 | 0 | 0 |
| Lưu trữ cache mới nhập trong 4 giờ | < 0,01 | < 0,01 |

Inspector tính mỗi image nền tảng nó quét (giả định: kiến trúc khác amd64, arm64 không được quét nên không tính). Số digest mới mỗi buổi phụ thuộc
nhịp Renovate giữa hai buổi; phí truyền qua NAT hay endpoint interface của ECR thuộc ADR về endpoint interface (0064).

## §12. Khác biệt stg/prd và ADR cũ

| Thành phần | stg | prd | Nhóm ([0055](../0055-environment-matrix.md)) | Lý do |
| --- | --- | --- | --- | --- |
| Registry, repo phát hành, cache, template, quét, Kyverno | như prd | §1–§10 | Phải giống | stg chạy đúng đường kéo, kiểm của prd |
| Bộ role CI | release backend, release frontend, rescan ×2 | promote, rescan ×2 | Khác theo thiết kế | stg nhận bản từ `main`; prd chỉ từ `promote-prd` có người duyệt |

ADR cũ chỉnh (dòng `### Chỉnh bởi`): 0034 Câu 10, §2; 0015 (registry, chữ ký, quyền job CI); 0040 §3 (rescan thêm bản ECR); 0041 (action được
phép, environment `ecr-rescan`, secret repo); 0055 §2, §3.

## Bảng control FSBP

"FSBP" là có trong chuẩn AWS Foundational Security Best Practices v1.0.0 [N24].

| Control | Tiêu đề (tóm tắt) | FSBP | Kết quả | Lý do |
| --- | --- | --- | --- | --- |
| ECR.1 | Repo private có cấu hình quét | có | Đạt ở repo cache; chấp nhận FAILED ở repo phát hành | §10: cổng trivy, grype trước push, rescan hằng ngày, admission đòi `vuln` dưới 72 giờ |
| ECR.2 | Tag bất biến (`IMMUTABLE`) | có | Đạt ở repo phát hành; chấp nhận FAILED ở repo cache | AWS khuyên `MUTABLE` cho cache; pod kéo theo digest |
| ECR.3 | Có ít nhất một lifecycle policy | có | Đạt ở repo cache; chấp nhận FAILED ở repo phát hành | §2: không xoá tự động khi chưa có GC theo tập đang dùng |
| ECR.4 | Repo public có tag | có | Không áp | Không repo public |
| ECR.5 | Mã hoá bằng CMK | không | Đạt | Key `alias/svp-<env>-ecr` cho mọi repo |
| Inspector.1 | Bật quét EC2 | có | Chấp nhận FAILED | §10 |
| Inspector.2 | Bật quét ECR | có | Đạt | Mọi thành viên và delegated admin |
| Inspector.3 | Bật quét code Lambda | có | Chấp nhận FAILED | Không có Lambda |
| Inspector.4 | Bật quét Lambda chuẩn | có | Chấp nhận FAILED | Không có Lambda |
| SecretsManager.1 | Bật xoay tự động | có | Chấp nhận FAILED | PAT của GitHub, Docker Hub không xoay bằng Lambda của Secrets Manager được; xoay tay theo runbook |
| SecretsManager.2 | Xoay tự động thành công | có | Không áp | Không xoay tự động |
| SecretsManager.3 | Không có secret không dùng (90 ngày) | có | Dự kiến đạt | ECR đọc secret mỗi lần làm mới; kiểm sau buổi đầu |
| SecretsManager.4 | Xoay trong 90 ngày | có | Chấp nhận FAILED | `put-secret-value` tay không phải lượt xoay; hạn token 90 ngày giữ cùng nhịp |
| KMS.3 | Key không bị xoá ngoài ý muốn | có | Đạt | Key sống ở root `aws/accounts/<env>` |
| KMS.4 | Bật xoay key | không | Đạt | Xoay hằng năm |
| KMS.5 | Key không công khai | có | Đạt | Key policy chỉ account |
| IAM.21 | Policy không có action `<dịch vụ>:*` | có | Đạt | §5, §6, §9 liệt kê từng action |

## Bảng luồng SCP, RCP

Đối chiếu với SCP và RCP `svp-data-perimeter` của [0059](../0059-org-structure-guardrails.md) §3, §4 (bảng ở phụ lục 0059). RCP phủ S3, KMS,
Secrets Manager, SQS, STS; ECR, Inspector nằm ngoài phạm vi RCP.

| Luồng | Principal | Tài nguyên | Qua nhờ |
| --- | --- | --- | --- |
| Job CI nhận role | Danh tính web của GitHub | STS `AssumeRoleWithWebIdentity` | Không có trong `EnforceOrgIdentities`; TLS |
| CI đẩy, đọc, gỡ ở ECR | Role CI (trong org) | ECR; KMS qua grant | ECR ngoài phạm vi RCP; KMS do ECR gọi thay principal trong org (như dòng mã hoá at-rest của 0059); kiểm ở lượt `main` đầu tiên |
| ECR đọc secret cache | `AWSServiceRoleForECRPullThroughCache` | Secrets Manager, key `aws/secretsmanager` | Service-linked role không chịu RCP |
| ECR kéo upstream | ECR | Internet | Ngoài phạm vi RCP |
| Node nhập image cache | Role node (trong org) | ECR | Ngoài phạm vi RCP |
| ECR nhận role tạo repo của template | `ecr.amazonaws.com` | STS `AssumeRole` | Principal dịch vụ; `aws:SourceAccount` (nếu có) là account env, trong org |
| Role template tạo grant | Role `svp-<env>-ecr-template` (trong org) | KMS | Principal trong org |
| Node, Kyverno kéo, đọc ECR | Role node, role Pod Identity | ECR; KMS qua grant | Như hai dòng trên |
| Kyverno nhận role Pod Identity | `pods.eks.amazonaws.com` | STS `AssumeRole`, `TagSession` | Như dòng Pod Identity của 0059 |
| Inspector quét image | Service-linked role của Inspector | ECR, KMS qua grant | Service-linked role không chịu RCP |
| Đăng ký delegated admin Inspector | Role SSO của management | Organizations | Ngoài phạm vi RCP (management) |

SCP: ECR, Inspector, Secrets Manager chạy ở `ap-southeast-1`; IAM, STS nằm trong danh sách dịch vụ toàn cục của `svp-deny-other-regions`
(`aws/modules/org-policies/main.tf`). `svp-deny-iam-users`: không IAM user. `svp-protect-baseline`: không chạm ECR, Inspector, role mới. Tag policy
bắt tag ở `kms:ALL_SUPPORTED`: key `alias/svp-<env>-ecr` mang tag mặc định của provider; ECR không bị bắt tag. Không luồng nào cần ngoại lệ.

## Nguồn

- [N1] What's New 2024-06-27, "Amazon ECR supports Open Container Initiative Image and Distribution specification version 1.1":
  <https://aws.amazon.com/about-aws/whats-new/2024/06/amazon-ecr-oci-image-distribution-version-1-1>; blog AWS, "Diving into OCI Image and Distribution 1.1
  support in Amazon ECR": <https://aws.amazon.com/blogs/opensource/diving-into-oci-image-and-distribution-1-1-support-in-amazon-ecr>
- [N2] ECR API `ListImageReferrers`: <https://docs.aws.amazon.com/AmazonECR/latest/APIReference/API_ListImageReferrers.html>
- [N3] ECR lifecycle policy: <https://docs.aws.amazon.com/AmazonECR/latest/userguide/LifecyclePolicies.html>, tham số:
  <https://docs.aws.amazon.com/AmazonECR/latest/userguide/lifecycle_policy_parameters.html>; `BatchDeleteImage`:
  <https://docs.aws.amazon.com/AmazonECR/latest/APIReference/API_BatchDeleteImage.html>
- [N4] ECR service quotas: <https://docs.aws.amazon.com/AmazonECR/latest/userguide/service-quotas.html>; tag bất biến:
  <https://docs.aws.amazon.com/AmazonECR/latest/userguide/image-tag-mutability.html>
- [N5] ECR encryption at rest: <https://docs.aws.amazon.com/AmazonECR/latest/userguide/encryption-at-rest.html>
- [N6] ECR pull through cache: <https://docs.aws.amazon.com/AmazonECR/latest/userguide/pull-through-cache.html>, secret:
  <https://docs.aws.amazon.com/AmazonECR/latest/userguide/pull-through-cache-creating-secret.html>, IAM:
  <https://docs.aws.amazon.com/AmazonECR/latest/userguide/pull-through-cache-iam.html>, kéo:
  <https://docs.aws.amazon.com/AmazonECR/latest/userguide/pull-through-cache-working-pulling.html>, service-linked role:
  <https://docs.aws.amazon.com/AmazonECR/latest/userguide/slr-pullthroughcache.html>
- [N7] ECR repository creation templates: <https://docs.aws.amazon.com/AmazonECR/latest/userguide/repository-creation-templates.html>; API:
  <https://docs.aws.amazon.com/AmazonECR/latest/APIReference/API_CreateRepositoryCreationTemplate.html>
- [N8] AWS blog, "Announcing pull through cache for registry.k8s.io in Amazon Elastic Container Registry":
  <https://aws.amazon.com/blogs/containers/announcing-pull-through-cache-for-registry-k8s-io-in-amazon-elastic-container-registry/>
- [N9] aws/containers-roadmap #2837, "[ECR] [request]: pull-through cache — support digest-pinned images on first pull":
  <https://github.com/aws/containers-roadmap/issues/2837>
- [N10] aws/containers-roadmap #2783, "ECR rejects OCI 1.1 referrer manifests during recursive copy (`oras copy -r`)":
  <https://github.com/aws/containers-roadmap/issues/2783>
- [N11] GitHub Docs, OpenID Connect reference: <https://docs.github.com/en/actions/reference/security/oidc>; "Configuring OpenID Connect in Amazon Web
  Services": <https://docs.github.com/en/actions/how-tos/secure-your-work/security-harden-deployments/oidc-in-aws>
- [N12] GitHub changelog 2026-04-23, "Immutable subject claims for GitHub Actions OIDC tokens":
  <https://github.blog/changelog/2026-04-23-immutable-subject-claims-for-github-actions-oidc-tokens>
- [N13] IAM, thumbprint của OIDC IdP: <https://docs.aws.amazon.com/IAM/latest/UserGuide/id_roles_providers_create_oidc_verify-thumbprint.html>; thời hạn
  phiên: <https://docs.aws.amazon.com/IAM/latest/UserGuide/id_roles_update-role-settings.html>
- [N14] `aws-actions/configure-aws-credentials`: <https://github.com/aws-actions/configure-aws-credentials>, bản phát hành:
  <https://github.com/aws-actions/configure-aws-credentials/releases>
- [N15] Kyverno v1.19 release: <https://kyverno.io/blog/2026/08/20/announcing-kyverno-release-1.19/>; v1.17:
  <https://kyverno.io/blog/2026/02/02/announcing-kyverno-release-1.17/>; migration sang CEL: <https://kyverno.io/docs/guides/migration-to-cel/>
- [N16] Kyverno `MutatingPolicy`: <https://kyverno.io/docs/policy-types/mutating-policy/>; thư viện CEL: <https://kyverno.io/docs/policy-types/cel-libraries/>
- [N17] Kyverno `ImageValidatingPolicy`: <https://kyverno.io/docs/policy-types/image-validating-policy/>
- [N18] `go.mod` của Kyverno v1.19.1: <https://raw.githubusercontent.com/kyverno/kyverno/v1.19.1/go.mod>; EKS Pod Identity, SDK tối thiểu:
  <https://docs.aws.amazon.com/eks/latest/userguide/pod-id-minimum-sdk.html>
- [N19] Kyverno issue #16664: <https://github.com/kyverno/kyverno/issues/16664>; #17363: <https://github.com/kyverno/kyverno/issues/17363>; #17833:
  <https://github.com/kyverno/kyverno/issues/17833>
- [N20] Sigstore, registry support: <https://docs.sigstore.dev/cosign/system_config/registry_support/>; spec bundle của cosign:
  <https://github.com/sigstore/cosign/blob/main/specs/BUNDLE_SPEC.md>
- [N21] ORAS `oras cp`: <https://oras.land/docs/commands/oras_cp>, `oras discover`: <https://oras.land/docs/commands/oras_discover>, v1.3.0:
  <https://github.com/oras-project/oras/releases/tag/v1.3.0>
- [N22] OCI Distribution Spec, referrers API và tag dự phòng: <https://github.com/opencontainers/distribution-spec/blob/main/spec.md>
- [N23] Inspector, quét ECR: <https://docs.aws.amazon.com/inspector/latest/user/scanning-ecr.html>, thời hạn quét lại:
  <https://docs.aws.amazon.com/inspector/latest/user/scanning_resources_configure_duration_setting_ecr.html>, delegated admin:
  <https://docs.aws.amazon.com/inspector/latest/user/admin-member-relationship.html>
- [N24] Security Hub CSPM, FSBP: <https://docs.aws.amazon.com/securityhub/latest/userguide/fsbp-standard.html>; control:
  <https://docs.aws.amazon.com/securityhub/latest/userguide/ecr-controls.html>, <https://docs.aws.amazon.com/securityhub/latest/userguide/inspector-controls.html>,
  <https://docs.aws.amazon.com/securityhub/latest/userguide/secretsmanager-controls.html>, <https://docs.aws.amazon.com/securityhub/latest/userguide/kms-controls.html>
- [N25] Trang giá: <https://aws.amazon.com/ecr/pricing/>, <https://aws.amazon.com/inspector/pricing/>, <https://aws.amazon.com/kms/pricing/>,
  <https://aws.amazon.com/secrets-manager/pricing/>; Price List ECR `ap-southeast-1`:
  <https://pricing.us-east-1.amazonaws.com/offers/v1.0/aws/AmazonECR/current/ap-southeast-1/index.json>
- [N26] GitHub Docs, "Working with the Container registry":
  <https://docs.github.com/en/packages/working-with-a-github-packages-registry/working-with-the-container-registry>
- [N27] ECR, private registry: <https://docs.aws.amazon.com/AmazonECR/latest/userguide/Registries.html>
- [N28] AWS SRA, Shared Services account:
  <https://docs.aws.amazon.com/prescriptive-guidance/latest/security-reference-architecture/shared-services.html>
- [N29] AWS blog, "Sharing Amazon ECR repositories with multiple accounts using AWS Organizations":
  <https://aws.amazon.com/blogs/containers/sharing-amazon-ecr-repositories-with-multiple-accounts-using-aws-organizations>
- [N30] Docker Docs, access tokens: <https://docs.docker.com/security/access-tokens/>, <https://docs.docker.com/security/access-tokens/personal-access-tokens/>
- [N31] aws/containers-roadmap #2728, "[ECR] [request]: Support lifecycle policy for image deletion not just transitioning to archive" (đóng
  2026-11-11 kèm trả lời của AWS): <https://github.com/aws/containers-roadmap/issues/2728>
