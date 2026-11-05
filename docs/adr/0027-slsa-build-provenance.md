# 0027. SLSA build provenance cho bảy image phát hành bằng predicate SLSA v1 do repo dựng, `cosign attest --type slsaprovenance1` định dạng cũ trên digest index, Kyverno kiểm provenance trên đường GitOps, bật theo bậc

- Trạng thái: Bị thay bởi [0040](0040-sigstore-bundle-actions-attest.md)
- Ngày: 2026-10-28
- Người quyết: người học (duyệt, chọn (a) ở cả ba dòng đề xuất)

## Bối cảnh và vấn đề

- **Yêu cầu:** mỗi bản phát hành của bảy image (`gateway`, `user-service`, `video-service`, `media-worker`, `engagement-service`,
  `feed-service`, `web`) có attestation provenance của build, ký keyless như `vuln`; Kyverno `svp-images` kiểm thêm provenance (builder,
  repository, ref) trên đường GitOps; mức SLSA đạt được ghi trung thực. [ADR-0015](0015-cicd-devsecops-stage5.md) §7 để SLSA provenance lại.
- **Hiện trạng lúc quyết** ([ADR-0015](0015-cicd-devsecops-stage5.md) §4, §7, §8; [ADR-0019](0019-web-k3d-supply-chain-observability.md) cho
  `web`): job `build` không cầm `id-token`, build `--provenance=false` (image là một manifest đơn); job `sign` ký và attest `spdxjson`, `vuln`
  **định dạng cũ** (`.sig`/`.att`) kèm `--replace`, vì Kyverno v1.19.1 giữ **một payload mỗi `predicateType`** và có bundle nào trên digest
  thì cosign lẫn Kyverno bỏ `.sig`/`.att`. Identity ký `images.yml@refs/heads/main` viết một chỗ ở `deploy/helm/svp-policy/values.yaml`.
  ImageValidatingPolicy `svp-images` kiểm sáu phép (prefix + digest, chữ ký, `vuln`, hai nền tảng, không CRITICAL, tuổi `vuln` ≤ 72 giờ),
  Enforce trên GitOps ([ADR-0024](0024-multi-environment.md)); `verify-release.sh` kiểm cùng điều kiện, đòi đúng một `vuln`.
- **Ràng buộc:** chỉ action của GitHub và `sigstore/cosign-installer`, ghim SHA (ADR-0015 §11); CI trung lập nền tảng qua hàm `ci_*`
  ([ADR-0023](0023-ci-platform-neutral.md)); không thêm công cụ (cosign v3.1.3 đã có); repo public, attestation công khai trên Rekor.
- **SLSA v1.2 Build track:** L1 là provenance có, nêu digest đầu ra; L2 thêm Hosted và Provenance Authentic (provenance do control plane của
  nền tảng sinh, không do tenant); L3 thêm Unforgeable và Isolated. GitHub tự xếp `actions/attest` là L2, L3 cần reusable workflow tách build.
- Kyverno v1.19.2 (2026-10-20) vá 24 advisory và thêm `additionalExtensions`, nhưng không có bản sửa "extract newest attestation" (#18049):
  giới hạn một payload mỗi loại vẫn đứng; nâng Kyverno là thay đổi riêng. Bảng yêu cầu SLSA, hiện trạng đủ chi tiết: [phụ lục](appendix/0027-slsa-build-provenance.md).

## Yếu tố quyết định

- Giữ định dạng chữ ký, `vuln`, rescan mà Kyverno v1.19.1 và `verify-release.sh` đang đọc.
- Không thêm action hay reusable workflow ngoài allow list; mang sang GitLab được.
- Mức SLSA ghi trung thực; không job nào cầm `id-token` dùng cache.
- Không lúc nào cluster GitOps từ chối bản đang chạy hợp lệ.

## Phương án đã cân nhắc

- Cách sinh A. `cosign attest --type slsaprovenance1`, predicate SLSA v1 do script của repo dựng: L1, cùng `.att` với `vuln`, chạy được trên GitLab.
- Cách sinh B. `actions/attest` / `actions/attest-build-provenance`: L2, nhưng Sigstore bundle buộc chuyển cả chữ ký và `vuln` sang bundle, mất `--replace`.
- Cách sinh C. `slsa-framework/slsa-github-generator`: L3 về thiết kế, nhưng không còn bảo trì tích cực, predicate v0.2, gọi bằng tag, ngoài allow list.
- Cách sinh D. Provenance của BuildKit: L1, không ký, đổi hình image.
- Subject: chỉ digest index (chọn), hay index và cả hai manifest con (ba attestation, Kyverno không đọc bản trên manifest con).
- Nơi attest: job `sign` hiện có (chọn), hay job `build` (phải cấp `id-token: write` cho job có cache).
- Bật: giá trị chart tắt rồi bật bằng PR GitOps (chọn), bật ngay cùng merge (`gitops.sh`, `values-check` đỏ tới khi đủ bảy bản), hay policy thứ
  hai `svp-provenance` ở Audit (thêm webhook, hai policy phải giữ khớp). Bảng đủ cột: phụ lục.

## Kết quả quyết định

Chọn A, chỉ digest index ở job `sign`, bật theo bậc. Nguyên văn từng mục (predicate mẫu, lý do từng field) ở [phụ lục](appendix/0027-slsa-build-provenance.md).

### 1. Cách sinh: A, `cosign attest --type slsaprovenance1` định dạng cũ, predicate do repo dựng

- `deploy/ci/provenance-predicate.sh OUT` dựng predicate **chỉ** từ hàm `ci_*` của `deploy/ci/platform.sh`; `sign-image.sh` attest **sau** `vuln`:
  `cosign attest --yes --new-bundle-format=false --use-signing-config=false --replace --type slsaprovenance1 --predicate <file> <repo>@<digest index>`.
- Predicate theo `buildType` `https://actions.github.io/buildtypes/workflow/v1`: `externalParameters.workflow` (repository, ref, path),
  `inputs` chỉ khi lượt dispatch có input `services` khác rỗng; `resolvedDependencies` đúng một mục (commit nguồn, `gitCommit` 40 hex);
  `builder.id` = `ci_builder_id` (trùng subject của chứng chỉ Fulcio); `invocationId` = `ci_run_attempt_url`. Không `internalParameters`,
  `byproducts`, `startedOn`/`finishedOn`, token hay biến môi trường tuỳ ý. Trên máy `builder.id` là `local`, không bao giờ được ký.
- Image diễn tập không mang provenance; rescan (`--replace --type vuln`) không động tới provenance, provenance không có hạn tuổi.

### 2. Subject: chỉ digest index; attest ở job `sign`

Đúng thứ pod chạy và Kyverno xác minh, một attestation mỗi bản phát hành; giữ quy tắc "không job nào cầm `id-token` dùng cache". Job
`sign` không thêm quyền nào.

### 3. Mức SLSA ghi trung thực

- **Ghi là Build L1.** Không ghi L2 (kể cả "L2 có điều kiện"), không L3, cho tới khi có thiết kế chứng minh mọi field bắt buộc ở L2 do nền tảng
  sinh hay kiểm trong control plane. Đạt Hosted (runner GitHub-hosted); chưa đạt Authentic vì predicate do bước của tenant dựng; không L3 vì
  job `sign` chạy script của repo với `id-token: write`.
- Đối chiếu field với chứng chỉ (`builder.id`, repository, ref ở Kyverno; thêm commit ở `verify-release.sh`) là bảo đảm của chữ ký, ghi riêng,
  không nâng mức. Lên L2: chuyển sang B khi Kyverno có #18049, hay dựng predicate từ claim OIDC đã ký (phải chứng minh riêng), kèm lập luận trong một ADR; lên L3: reusable workflow ở chỗ repo build không sửa được.

### 4. Kyverno: kiểm provenance trên đường GitOps

- `svp-policy` thêm attestation `provenance` (`intoto.type: https://slsa.dev/provenance/v1`) và bốn phép **sau** sáu phép hiện có, mỗi phép
  một message: 7. provenance ký bởi đúng identity; 8. `builder.id` bằng `imageVerification.subject`; 9. `externalParameters.workflow.repository`
  bằng repository của repo; 10. `externalParameters.workflow.ref` bằng `refs/heads/main`. `extractPayload` chỉ sau `verifyAttestationSignatures`.
- Giá trị chart mặc định tắt (render giống hệt hiện nay, đường dev không đổi); bật ở cấu hình GitOps của stg, prd
  ([ADR-0025](0025-gitops-config-repo.md)), không trong `values.yaml` của chart. Không phép kiểm tuổi cho provenance. Mỗi image thêm một lần xác minh khi chưa trúng cache, chưa đo.

### 5. `verify-release.sh` kiểm cùng điều kiện, cùng lúc với policy

Đọc trạng thái bật từ cùng nguồn giá trị Argo CD dùng cho policy; khi bật: `cosign verify-attestation --type slsaprovenance1`, **đúng một**
provenance, phép 8–10, và `gitCommit` bằng commit trong chứng chỉ (`--certificate-github-workflow-sha`), lệch thì đỏ.

### 6. Triển khai theo bậc

1. Merge phần sinh provenance cùng policy và `verify-release.sh` **tắt**.
2. Dispatch `images.yml --ref main -f services=all`, merge PR promote cuộn: bảy digest mới.
3. Kiểm bảy digest bằng `verify-release.sh` ở chế độ bật.
4. PR bật provenance ở cấu hình GitOps; từ đây stg, prd Enforce provenance.
5. Kịch bản `gitops` của `verify.yml` chạy ca mới của diễn tập với policy bật.

Rollback về digest trước bậc 2 bị từ chối khi đã bật: trỏ bản có provenance, hay PR tắt giá trị trước.

### 7. Diễn tập

`make drill-k8s-supplychain` thêm ca `l` (`SUPPLYCHAIN_NO_PROVENANCE`): digest phát hành cũ trước provenance (ký, `vuln` còn trong 72 giờ nhờ
rescan `values_ref`) bị từ chối **đúng message của phép 7**; ca a được nhận khi policy bật; quá hạn thì ca FAIL nêu lệnh dispatch, không tìm được digest cũ thì SKIP có lý do; policy tắt thì SKIP nêu "policy tắt".

### Hệ quả

- Tốt: mỗi bản phát hành mang attestation ký nêu commit, workflow, lượt chạy, đọc bằng `cosign` không token; không đổi định dạng hay identity
  của chữ ký, SBOM, `vuln`; mang sang GitLab chỉ thêm nhánh của `ci_*` và `buildType`.
- Xấu: chỉ Build L1; ai merge được vào `main` ký được provenance tuỳ ý dưới identity đúng; một predicate của repo phải giữ đúng đặc tả, thêm
  một lượt ghi Rekor mỗi bản; rollback về bản trước provenance phải tắt kiểm trước; phép 8–10 phần lớn lặp lại identity của chữ ký.
- Xem lại khi: Kyverno có bản phát hành chứa #18049 (xét B, bundle cho cả chuỗi); có reusable workflow tin cậy được (L3); nâng Kyverno lên
  v1.19.2 (`additionalExtensions`); `cosign` bỏ định dạng cũ.

## Xác nhận

Mọi giả định của bảng kiểm chứng đạt ở lượt `gitops` [40954609229](https://github.com/anhnvcoder/svp-backend/actions/runs/40954609229) và lại đạt
trên `main` ở [41015270736](https://github.com/anhnvcoder/svp-backend/actions/runs/41015270736): `verify-release.sh` qua 7/7 digest, mỗi bản
đúng một provenance, commit khớp chứng chỉ; Kyverno "provenance checked: yes", ca a nhận, ca l từ chối đúng message; rescan
[41018158008](https://github.com/anhnvcoder/svp-backend/actions/runs/41018158008) giữ provenance. Một phần: thời gian admission lần đầu dưới
`timeoutSeconds: 30` nhưng chưa trích số. Bảng đủ: phụ lục.

## Hiện thực ở

Hiện thực bị 0040 thay (`provenance-predicate.sh` đã xoá); danh sách theo bậc ở phụ lục.

- `deploy/ci/provenance-predicate.sh`, `deploy/ci/provenance-predicate-test.sh`, `deploy/ci/platform.sh`, `.github/actions/image-sign/` với `deploy/ci/image-guard.sh` (thay `sign-image.sh` đã xoá),
  `.github/workflows/images.yml` (mục 1, 2).
- `deploy/helm/svp-policy/` (`imageVerification.requireProvenance`, `files/sources.json`, `templates/imagevalidatingpolicy.yaml`) (mục 4).
- `deploy/ci/common.sh`, `deploy/ci/verify-release.sh`, `deploy/ci/values-check.sh`, `deploy/k8s/gitops.sh` (mục 5).
- `deploy/k8s/drills/supplychain/` (ca l), `deploy/k8s/k8s.mk`, `deploy/ci/verify-steps/supplychain.sh` (mục 7); overlay `envs/stg/svp-policy.yaml`,
  `envs/prd/svp-policy.yaml` của `svp-gitops` (bậc 4).

## Nguồn

Danh sách [S1]–[S15] có ghi chú ở phụ lục.

- SLSA v1.2: [Build Track Basics](https://slsa.dev/spec/v1.2/build-track-basics), [Build Requirements](https://slsa.dev/spec/v1.2/build-requirements),
  [Build Provenance](https://slsa.dev/spec/v1.2/build-provenance).
- GitHub Docs, [Artifact attestations](https://docs.github.com/en/actions/concepts/security/artifact-attestations); [`actions/attest`](https://github.com/actions/attest).
- Kyverno, [ImageValidatingPolicy](https://kyverno.io/docs/policy-types/image-validating-policy/); [v1.19.2](https://github.com/kyverno/kyverno/releases/tag/v1.19.2).
- Fulcio, [OID information](https://github.com/sigstore/fulcio/blob/main/docs/oid-info.md).

## Thông tin thêm

Phụ lục: [`appendix/0027-slsa-build-provenance.md`](appendix/0027-slsa-build-provenance.md) (tiêu đề và trạng thái gốc với các mốc hiện thực,
bối cảnh và bảng SLSA, bảng lựa chọn, nguyên văn quyết định, "Cần người học chọn", bảng kiểm chứng, hiện thực theo bậc, nguồn).

ADR này chỉnh [ADR-0015](0015-cicd-devsecops-stage5.md) §7 (SLSA provenance `slsaprovenance1` trên digest index ở job `sign`) và §8 (phép 7–10 khi bật).

### Chỉnh bởi

- §4, §5: [0033](0033-svp-web-repo.md): repository và ref mà provenance phải nêu, identity theo nguồn phát hành; `verify-release.sh` theo nguồn.
- §6: [0033](0033-svp-web-repo.md): rollback về web của nguồn cũ sau khi gỡ nguồn đó bị từ chối như rollback về bản trước provenance.
- §6: [0036](0036-repo-rename.md): rollback về bản trước đổi tên repo bị từ chối như về bản trước provenance.
