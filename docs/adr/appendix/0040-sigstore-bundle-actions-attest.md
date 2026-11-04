# Phụ lục ADR-0040: Chữ ký, `vuln`, SBOM và provenance của image phát hành sang Sigstore bundle trong một bản phát hành mỗi nguồn; provenance bằng `actions/attest`; rescan gỡ bundle `vuln` cũ; revert nếu admission thật vượt hạn

Phụ lục của [ADR-0040](../0040-sigstore-bundle-actions-attest.md): phần chuyển ra khỏi ADR, giữ nguyên văn và xếp theo mục: dòng trạng thái lúc chốt, bối cảnh đầy đủ với kết quả hai spike, ưu nhược từng phương án, các lần kiểm có ngày và id lượt chạy. Đây là lịch sử, nên giữ ngày của lúc ghi.

## Trạng thái ghi lúc chốt

- Trạng thái: Chấp nhận (người học duyệt 2026-11-01); hiện thực ở `svp-backend` (#72) và `svp-frontend` (#17); kiểm ở lượt phát hành đầu và số đo admission đạt (mục Xác nhận)

## Bối cảnh

[0027](../0027-slsa-build-provenance.md) chọn provenance tự dựng (`provenance-predicate.sh`, `cosign attest --type slsaprovenance1` định dạng cũ
`.sig`/`.att` với `--replace`), ghi trung thực Build L1, vì `actions/attest` (đường GitHub khuyến nghị, cho L2) ra Sigstore bundle, buộc đổi
cả chữ ký và `vuln` sang bundle khi chưa ai thử Kyverno v1.19.1 và rescan hằng ngày với bundle. [0037](../0037-mainpath-standard-tools.md) §6 để
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

## Ưu nhược từng phương án

- A: không đổi gì; mãi L1, tự giữ predicate.
- B: một bước nhỏ; spike cho thấy bị từ chối ở phép `vuln`, loại.
- C: không thêm quyền gỡ; Kyverno đọc bundle theo digest, `verify-release.sh` từ chối sau rescan đầu, loại.
- D: L2, rescan đúng; thêm bước gỡ dựa vào hành vi GHCR, xác minh chậm hơn.
- E: không bước gỡ; #18049 chưa ở bản phát hành nào, referrer vẫn tăng mỗi ngày (chậm thêm) và `verify-attestation` vẫn trả mọi bundle.
- F: L3 về thiết kế; với Kyverno v1.19.1 phép chữ ký, `vuln` không tách được repo gọi, identity mọi nguồn đổi theo SHA được gọi.

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
