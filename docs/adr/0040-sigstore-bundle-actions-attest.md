# 0040. Chữ ký, `vuln`, SBOM và provenance của image phát hành sang Sigstore bundle trong một bản phát hành mỗi nguồn; provenance bằng `actions/attest`; rescan gỡ bundle `vuln` cũ; revert nếu admission thật vượt hạn

- Trạng thái: Chấp nhận (người học duyệt 2026-11-01); hiện thực ở `svp-backend` (#72) và `svp-frontend` (#17); kiểm ở lượt phát hành đầu và số đo admission đạt (mục Xác nhận)
- Ngày: 2026-11-01
- Người quyết: người học (duyệt), AI (đề xuất)

## Bối cảnh và vấn đề

[0027](0027-slsa-build-provenance.md) chọn provenance tự dựng (`provenance-predicate.sh`, `cosign attest --type slsaprovenance1` định dạng cũ
`.sig`/`.att` với `--replace`), ghi trung thực Build L1, vì `actions/attest` (đường GitHub khuyến nghị, cho L2) ra Sigstore bundle, buộc đổi
cả chữ ký và `vuln` sang bundle khi chưa ai thử Kyverno v1.19.1 và rescan hằng ngày với bundle. [0037](0037-mainpath-standard-tools.md) §6 để
`actions/attest` cho một ADR riêng. Hai spike của `svp-labs` đã trả lời bằng lượt chạy thật (Kyverno CLI v1.19.1, bản cluster chạy):

- [`attest-spike`](https://github.com/anhnvcoder/svp-labs/tree/main/attest-spike): Kyverno đọc được provenance của `actions/attest` ở đúng các
  đường mà phép 8–10 của `svp-policy` so; một policy nhận cả image định dạng cũ lẫn image bundle, kể cả trong một pod. **Một image không được
  lẫn hai định dạng:** có một bundle referrer thì Kyverno và cosign chỉ đọc bundle; bản phát hành chỉ chuyển provenance bị từ chối ở phép `vuln`.
  Ở định dạng bundle, bundle attestation nào đúng identity cũng tính là chữ ký.
- [`bundle-spike`](https://github.com/anhnvcoder/svp-labs/tree/main/bundle-spike): (A) image keyless toàn bundle (chữ ký, `vuln`, provenance)
  qua đủ mười phép của template thật `svp-policy` với `requireProvenance: true`; thiếu `vuln` bị từ chối đúng message. (B) `--replace` không
  tác dụng với bundle: mỗi lượt rescan thêm một referrer; `cosign verify-attestation --type vuln` trả mọi bundle (`verify-release.sh` đòi đúng
  một); Kyverno giữ **bundle cuối danh sách referrer**, mà GHCR (không referrers API, tag dự phòng `sha256-<digest>`) xếp theo digest, không
  theo tuổi, nên một bundle cũ digest lớn làm mọi pod mới bị từ chối sau 72 giờ dù rescan vẫn chạy. `oras manifest delete` với `GITHUB_TOKEN`
  `packages: write` đưa bundle cũ ra khỏi danh sách (GHCR trả exit 1 `unsupported` nhưng tag dự phòng đã ghi lại); sau đó cả hai đọc đúng
  bundle còn lại. **Xác minh chậm hơn:** CLI 36–46 s cho image ba bundle trên GHCR, 14–16 s cho bản phát hành `gateway` định dạng cũ, 4–5 s
  cho cùng image trên registry tạm (tới 32 bundle): phần lớn là lượt gọi GHCR, mỗi image tải mọi bundle khoảng sáu lần.

Ràng buộc: webhook `svp-policy` `timeoutSeconds: 30` (Kubernetes cho tối đa 30 s), `failurePolicy: Fail` trên GitOps: quá hạn là pod bị từ
chối. Cache kết quả xác minh của Kyverno giữ 60 phút (`imageVerifyCacheMaxSize` ở `base/kyverno.yaml` của `svp-gitops`); pod đầu của một digest
mới luôn chưa trúng cache. `allowed_actions` của repo là `selected` với `github_owned_allowed`, nên `actions/attest` không cần mở thêm; ghim SHA
bắt buộc. Repo public: chứng chỉ Fulcio và Rekor public.

## Yếu tố quyết định

- Mức SLSA ghi trung thực, bằng công cụ hiện hành của nền tảng thay mã tự viết.
- Kyverno v1.19.1 đang chạy nhận bản cũ ở stg, prd và bản mới trong cùng thời gian; không digest nào mang hai định dạng.
- Sau mỗi rescan đúng một `vuln` đọc được và còn trong tuổi, ở Kyverno lẫn `verify-release.sh`.
- Admission của pod đầu một digest mới dưới hạn webhook 30 s.
- Rollback về bản trước vẫn được nhận.

## Phương án đã cân nhắc

- A. Giữ 0027 (định dạng cũ, predicate tự dựng, L1).
- B. Chỉ provenance sang `actions/attest`, chữ ký và `vuln` giữ định dạng cũ.
- C. Cả ba sang bundle trong một bản phát hành; rescan chỉ attest thêm.
- D. Cả ba sang bundle trong một bản phát hành; rescan attest rồi gỡ mọi bundle `vuln` khác của digest.
- E. Như D nhưng chờ Kyverno đọc attestation mới nhất mỗi loại (PR #18049) thay vì gỡ.
- F. Sinh và ký trong reusable workflow để lên L3.

## Kết quả quyết định

Chọn D, có điều kiện ở mục 6: đạt L2 bằng công cụ chuẩn, và là phương án duy nhất spike chứng minh giữ được một `vuln` đúng sau rescan với
Kyverno v1.19.1.

1. **Định dạng.** Job `sign` của `images.yml`: `sign-image.sh` ký (`cosign sign`), attest `spdxjson` trên từng manifest con và `vuln` trên
   digest index ở định dạng bundle (bỏ `--new-bundle-format=false --use-signing-config=false`); **sau** đó `actions/attest` (ghim SHA,
   `subject-name`, `subject-digest` của index, `push-to-registry: true`) ra provenance; `attestations: write` chỉ ở job này. Ở định dạng bundle `--replace` không còn tác dụng, nên chạy lại job (Re-run failed jobs)
   sẽ ghi thêm `vuln`, provenance lên cùng digest; job dò referrer trước khi ghi và bỏ qua cái đã có (hay mục 3 gỡ cả provenance thừa), để
   mỗi digest giữ đúng một bản mỗi loại như `verify-release.sh` đòi. Image diễn tập như
   nay: ký và `vuln`, không provenance. Bỏ `provenance-predicate.sh` và test của nó. Predicate do `actions/attest` dựng từ claim của token OIDC:
   `builder.id` là `<repo>/.github/workflows/images.yml@refs/heads/main` (bằng subject của chứng chỉ, phép 8), `externalParameters.workflow`
   (phép 9, 10), `resolvedDependencies[0].digest.gitCommit` (bước 5 của `gitops-check.sh`, `--certificate-github-workflow-sha` của
   `verify-release.sh`). Phép "builder là identity của nguồn" trước khi ký giữ.
2. **Một bản phát hành mỗi repo nguồn, cửa sổ chuyển giữa các image.** `svp-backend` đổi mọi image của nó trong một thay đổi; `svp-frontend`
   đổi `web` ở bản phát hành của nó sau khi ghim commit đó. Kyverno chọn định dạng theo từng image, nên `svp-policy` không khai gì mới; nó
   chỉ ghi cửa sổ chuyển và điều kiện bỏ định dạng cũ trong comment. Rescan ghi `vuln` theo định dạng chữ ký **đang có trên digest đó** (dữ
   liệu theo image, không phải chế độ): digest cũ thì `.att` với `--replace` như nay, digest mới thì bundle.
3. **Rescan gỡ bundle `vuln` cũ.** Sau `cosign attest`, cùng job gỡ mọi referrer `vuln` khác của digest bằng `oras manifest delete` (quyền
   `packages: write` job đã có, `docker login ghcr.io`), giữ bundle vừa attest; chọn theo bundle vừa ghi hay `scanFinishedOn` của bundle **đã
   xác minh** đúng identity, không theo nội dung chưa xác minh. Không tin exit code (GHCR trả 1): đọc lại danh sách referrer, phải còn đúng một
   `vuln`. Chỉ gỡ `vuln`: chữ ký, provenance, SBOM không bao giờ. Vẫn đòi `--source` và identity. Ghi đồng thời mất referrer (tag dự phòng là
   đọc-sửa-ghi): group `concurrency` rescan của `images.yml` cho mỗi repo chạy nối tiếp; job `sign` chỉ ghi digest vừa build. Vài giây giữa
   attest và gỡ, image có hai `vuln`: Kyverno đọc một trong hai (cả hai còn tuổi), `verify-release.sh` từ chối, chạy lại là qua.
4. **Script kiểm đọc cả hai định dạng không cần token.** `verify-release.sh`, `values-check.sh`, bước 5 của `gitops-check.sh` giữ lệnh
   `cosign verify`, `cosign verify-attestation` (hai định dạng cùng lệnh, cùng message khi thiếu loại); số envelope `vuln` và provenance vẫn
   đúng một. Không dùng `gh attestation verify` (đòi đăng nhập).
5. **Mức SLSA: Build L2.** Provenance do `actions/attest` dựng từ claim OIDC đã ký, ký bằng chứng chỉ Fulcio của chính lượt chạy, trên
   runner GitHub-hosted; GitHub tự xếp L2; `subject` do bước của repo đưa vào, L2 cho phép. **Không L3:** attest chạy trong job của chính
   workflow build, cùng bước của tenant (`sign-image.sh`) cầm `id-token`. L3 cần reusable workflow tách khỏi repo build (F); spike
   [`reusable-spike`](https://github.com/anhnvcoder/svp-labs/tree/main/reusable-spike) cho thấy Kyverno v1.19.1 không tách được repo gọi ở phép
   chữ ký và `vuln` khi SAN chung, nên F để lại.
6. **Rủi ro thời gian xác minh, đo sau merge.** CLI không cache mất 36–46 s, quá hạn 30 s; admission thật (cache, TUF đã nạp, trong cluster)
   chưa đo, và pod đầu của một digest mới luôn không cache. Trước merge chưa có image `svp-backend` nào ở định dạng bundle (`images.yml` chỉ
   push và ký trên `main`), nên đo sau merge, ở bản phát hành đầu (mục Xác nhận). Rủi ro nằm gọn giữa merge và lần dựng cluster kế tiếp:
   không cluster nào tự nhận bản mới (stg, prd chỉ chạy trong buổi AWS, k3d khi người học dựng). Lần không cache vượt 20 s (hai phần ba hạn,
   chừa chỗ cho GHCR chậm) thì revert phần hiện thực bằng một PR mỗi repo đã đổi trước buổi AWS kế tiếp, phát hành lại ở định dạng cũ (mục 7)
   và ghi số vào mục Xác nhận; phương án sau đó theo thứ tự thử: Kyverno v1.19.2
   (`loadBundles` đọc bundle một lần mỗi lượt, chưa đo), ít bundle hơn (bỏ `cosign sign` riêng vì bundle attestation đã tính là chữ ký: đổi
   nghĩa phép 2, cần ADR), giữ định dạng cũ (0027 đứng).
7. **Rollback.** Policy và script nhận digest định dạng cũ tới khi quyết bỏ, nên rollback về bản trước ADR này được nhận như hôm nay (rescan
   làm mới `vuln` của digest còn trong values). Điều kiện bỏ nhánh định dạng cũ của rescan và comment: `envs/stg/images/`, `envs/prd/images/`
   của `svp-gitops` không còn digest định dạng cũ (cả `web`); sau đó rollback về bản cũ cần đi qua quyết định khác. Đảo chính quyết định này
   (revert) không đủ: rescan cũ ghi `.att` lên digest bundle, Kyverno không đọc, `vuln` bundle quá 72 giờ; phải phát hành lại ở định dạng cũ.
8. **Artifact khác giữ định dạng cũ.** Hợp đồng REST `api/gateway` (`contract.sh`) ký định dạng cũ: không pod nào chạy nó, Kyverno không
   thấy, `cosign verify` đọc cả hai; đổi không được gì. SBOM trên manifest con đổi cùng định dạng bundle (mỗi manifest con chỉ mang SBOM của nó).

### Hệ quả

- Tốt: L2 ghi trung thực bằng công cụ của nền tảng; bỏ predicate tự dựng và test của nó; predicate có thêm `internalParameters.github`.
- Xấu:
  - Xác minh mỗi image chậm gấp hai tới ba lần ở CLI; admission gần hạn webhook là rủi ro chính (mục 6).
  - Phần gỡ của rescan dựa vào hành vi tag dự phòng của GHCR (lệnh lỗi nhưng danh sách đã ghi lại), nên phải đọc lại để kiểm; manifest đã
    gỡ còn trong package thành phiên bản không tag, chưa dọn (API xoá package version chưa thử).
  - Job rescan dùng `packages: write` để gỡ referrer: gỡ nhầm chữ ký hay provenance làm pod mới bị từ chối; script chỉ gỡ loại `vuln`.
  - Ở định dạng bundle phép chữ ký không còn kiểm điều gì riêng ngoài các phép attestation (cùng identity).
  - Thời gian chuyển có hai định dạng song song, rescan có một nhánh theo định dạng của digest.
- Xem lại khi: Kyverno có bản phát hành đọc attestation mới nhất mỗi loại (#18049, chưa có ở v1.19.2) hay GHCR có referrers API (xét bỏ phần
  gỡ); lên Kyverno v1.19.2 (`additionalExtensions`: xét lại F cho L3, đo lại thời gian); admission đo được trên 20 s.

## Xác nhận

Đã kiểm (2026-11-01, hai spike, Kyverno CLI v1.19.1, cosign v3.1.3 đọc ẩn danh): mười phép trên image keyless toàn bundle; từ chối khi thiếu
`vuln`; image lẫn định dạng bị từ chối; `--replace` không tác dụng; Kyverno đọc bundle cuối theo digest; gỡ bằng `oras manifest delete` trên
GHCR rồi Kyverno và cosign đọc đúng bundle còn lại; `cosign verify`, `verify-attestation` (cả `--certificate-github-workflow-sha`) trên bundle
không token; thời gian CLI ở trên.

Kiểm sau merge, ở lượt phát hành đầu (điều kiện giữ của mục 6, **đạt**): lượt `verify.yml` kịch bản `gitops` đầu tiên sau khi bản phát hành
đầu ở định dạng bundle đã promote stg (k3d trên runner, Kyverno v1.19.1 và `svp-policy` thật, digest của `envs/stg/images/` ở `svp-gitops`),
đo thời gian admission lần không cache và lần có cache, so với 20 s và 30 s. Nguồn: histogram
`apiserver_admission_webhook_admission_duration_seconds` của webhook Kyverno dành cho ImageValidatingPolicy `svp-images` (tên bắt đầu `ivpol.`,
ví dụ `ivpol.validate.kyverno.svc-fail-finegrained-svp-images`) và metric admission của Kyverno, do bước `gitops-admission-metrics` của kịch bản
`gitops` in ra trong lượt sync đầu, khi mọi
service đổi digest cùng lúc (đây cũng là phép kiểm dưới tải); event của pod không mang thời gian admission, và dry-run trên digest pod đang chạy
chỉ cho số có cache;
số và id lượt ghi ở đây. Lượt `verify.yml` `gitops` run 41334373082 (svp-backend `86627ec`, bản phát hành bundle đầu của mọi service):
webhook `ivpol.validate.kyverno.svc-fail-finegrained-svp-images` 18 lần, trung bình 5,4 s, 18/18 ≤ 10 s, 0 > 25 s;
`kyverno_admission_review_duration_seconds` 20/20 ≤ 20 s; `kyverno_image_validating_policy_execution_duration_seconds{policy_name="svp-images"}`
trung bình 5,4 s, 18/18 ≤ 20 s. Có cache (ca (a) của `drill-k8s-supplychain`): 536 ms. Rescan bundle (backend run 41330733964, frontend run
41330736595): mỗi image giữ đúng một bundle `vuln`, `scanFinishedOn` mới.

Kiểm ở lượt phát hành đầu (**đạt**: `images.yml` run 41326534756 backend, 41329548993 frontend; rescan 41330733964, 41330736595;
image diễn tập 41330755152; `verify.yml gitops` 41334373082): lượt `images.yml` của mỗi repo xanh; một image mỗi repo qua `verify-release.sh` (chữ ký, `vuln`,
provenance của `actions/attest`, identity đúng nguồn); `oras discover` chỉ thấy bundle referrer, không `.sig`/`.att` mới; PR promote stg qua
`gitops-ok`; sau một lượt rescan dispatch, `verify-release.sh` vẫn qua và đọc `scanFinishedOn` mới; `drill-k8s-supplychain` trong 72 giờ sau
dispatch image diễn tập: ca (a) nhận bản bundle, (b), (c) (CRITICAL trong `vuln` bundle, chưa thử ở spike), (l) từ chối đúng message. Thời
gian xác minh dưới tải: lượt sync đầu nói ở trên. Chưa kiểm và không có phép kiểm riêng: GHCR với hơn năm bundle.

## Ưu nhược từng phương án

- A: không đổi gì; mãi L1, tự giữ predicate.
- B: một bước nhỏ; spike cho thấy bị từ chối ở phép `vuln`, loại.
- C: không thêm quyền gỡ; Kyverno đọc bundle theo digest, `verify-release.sh` từ chối sau rescan đầu, loại.
- D: L2, rescan đúng; thêm bước gỡ dựa vào hành vi GHCR, xác minh chậm hơn.
- E: không bước gỡ; #18049 chưa ở bản phát hành nào, referrer vẫn tăng mỗi ngày (chậm thêm) và `verify-attestation` vẫn trả mọi bundle.
- F: L3 về thiết kế; với Kyverno v1.19.1 phép chữ ký, `vuln` không tách được repo gọi, identity mọi nguồn đổi theo SHA được gọi.

## Hiện thực ở

Repo `svp-backend` (đường dẫn từ gốc repo):

- `.github/workflows/images.yml` (job `sign`, `rescan`), `.github/workflows/ci.yml`, `deploy/ci/sign-image.sh`, `deploy/ci/rescan.sh`,
  `deploy/ci/provenance-predicate.sh` và `provenance-predicate-test.sh` (đã xoá), `deploy/ci/common.sh`, `changed-services.sh`, `platform.sh`
  (mục 1, 2, 3); test `deploy/ci/platform-test.sh`, `verify-collect-test.sh`, `ghcr-digest-test.sh`.
- `deploy/ci/verify-release.sh`, `deploy/ci/verify/gitops.sh`, `deploy/ci/ghcr-digest.sh` (mục 4); `deploy/ci/verify/gitops.sh` bước
  `gitops-admission-metrics` (mục 6); `deploy/helm/svp-policy/templates/imagevalidatingpolicy.yaml`
  (mục 2, 7); `deploy/k8s/drills/supplychain.sh`, `deploy/k8s/k8s.mk` (ca b, c, f, l).

Repo `svp-frontend`: `.backend-commit`, `.github/workflows/images.yml` (job ký, `rescan`) (mục 1, 3).

## Nguồn

Đọc ngày 2026-11-01.

- Spike `svp-labs`: [`attest-spike`](https://github.com/anhnvcoder/svp-labs/tree/main/attest-spike),
  [`bundle-spike`](https://github.com/anhnvcoder/svp-labs/tree/main/bundle-spike),
  [`reusable-spike`](https://github.com/anhnvcoder/svp-labs/tree/main/reusable-spike) (lệnh, output, version, giới hạn).
- `actions/attest` (v4.2.2; `push-to-registry`, quyền `attestations: write`): <https://github.com/actions/attest>
- GitHub Docs, "Artifact attestations" (SLSA v1.0 Build L2; reusable workflow cho L3):
  <https://docs.github.com/en/actions/concepts/security/artifact-attestations>
- SLSA v1.2, "Build: Requirements for producing artifacts": <https://slsa.dev/spec/v1.2/build-requirements>
- Kubernetes, "Dynamic Admission Control", Timeouts (1–30 s):
  <https://kubernetes.io/docs/reference/access-authn-authz/extensible-admission-controllers/#timeouts>
- Kyverno PR #18049 "extract newest attestation for ImageValidatingPolicy": <https://github.com/kyverno/kyverno/pull/18049>; v1.19.2 release
  notes: <https://github.com/kyverno/kyverno/releases/tag/v1.19.2>
- OCI Distribution Spec v1.1, referrers tag schema (tag dự phòng `sha256-<digest>`):
  <https://github.com/opencontainers/distribution-spec/blob/main/spec.md#referrers-tag-schema>
- ORAS, `oras manifest delete`: <https://oras.land/docs/commands/oras_manifest_delete>
