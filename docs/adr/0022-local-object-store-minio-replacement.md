# 0022. Object store của đường local (compose và k3d) đổi từ MinIO (image Chainguard) sang RustFS, CORS theo bucket, tên trung tính `s3`; MinIO Chainguard là đường quay lại

- Trạng thái: Chấp nhận
- Ngày: 2026-10-24

## Bối cảnh và vấn đề

- MinIO community đã ngừng: repo `minio/minio` archive ngày 2026-04-25, chỉ phát mã nguồn, bản community cuối `RELEASE.2025-10-15T17-29-55Z`; `minio/mc` archive ngày 2026-07-14; bảy CVE công bố năm 2026 (hai cái cho ghi không xác thực: CVE-2026-40344, CVE-2026-41145) chỉ vá ở bản thương mại AIStor.
  [ADR-0008](0008-async-upload-pipeline-stage2a.md) §6 chọn image `cgr.dev/chainguard/minio` ghim digest và hẹn "chuyển sang SeaweedFS, Garage hoặc RustFS bằng ADR mới"; [ADR-0016](0016-web-client.md) §11 và [ADR-0020](0020-reliability-stage6.md) §16 dời việc đó sang đợt kiểm chứng dồn. ADR này là ADR đó.
- **Phạm vi:** đường local, cả compose (`deploy/compose/compose.yaml`, `deploy/minio/init.sh`, ba file policy) lẫn k3d (`deploy/helm/svp-data/templates/minio.yaml` chạy đúng `init.sh` đó, bucket `pg-backups` của plugin Barman Cloud, đích Velero). Cloud dùng S3/R2/GCS, ngoài ADR này. Không tách phạm vi: hai nơi dùng chung script, policy và hợp đồng.
- **Hợp đồng bản thay phải giữ** (đã kiểm trên MinIO, không nới cái nào):
  presigned POST (`PresignPostObject` của `aws-sdk-go-v2`, policy `{"key": <exact>}`, `{"Content-Type": ...}`, `["content-length-range", 1, size]`, hạn 15 phút; store từ chối form sai key, quá cỡ, rỗng, sai hay thiếu `Content-Type`, hết hạn: UP-1, UP-2, UP-4);
  quyền theo user, bucket và tiền tố (`deploy/minio/*-policy.json`; user `svp-pg-backup` chỉ `pg-backups`; root chỉ ở store và job init: UP-4, UP-5, BAK-1), một cặp key toàn quyền hay cờ đọc/ghi theo bucket là không tương đương;
  đọc ẩn danh `media/media/*` không `ListBucket`, `uploads` và `pg-backups` không gì ẩn danh, URL phát path-style (UP-5, UP-6);
  CORS chỉ origin của web (compose `http://localhost:3001`, `http://localhost:3002`; k3d `https://svp.localhost:8443`), preflight `POST` vào `uploads` và `GET` ở `media` (WEB-10), trong khi MinIO community chỉ có biến toàn cục;
  Barman Cloud (plugin v0.15.1, barman 3.20.1, boto3 1.43.105: checksum CRC mặc định, header qua `http://` nội bộ, trailer `aws-chunked` qua `https`) và Velero (plugin AWS v1.14.4 ép CRC32 cho multipart trên 5 MiB, `checksumAlgorithm: ""` không tắt được);
  vận hành: image đa kiến trúc ghim `@sha256:`, non-root, `readOnlyRootFilesystem`, drop ALL, seccomp `RuntimeDefault`, health không xác thực, tạo bucket, user, policy bằng script idempotent, RAM nhỏ (512 MiB).

## Yếu tố quyết định

- Đủ mọi hợp đồng trên có nguồn kiểm được; quyền theo user và tiền tố; CORS theo bucket (như S3 ở cloud); giấy phép và nhịp bảo trì; image non-root đa kiến trúc có tag version cho Renovate; RAM nhỏ; bản thay quay lại được.

## Phương án đã cân nhắc

Mọi nguồn đọc ngày 2026-10-24; bảng so sánh bảy cột và phân tích từng phương án ở phụ lục.

- **A. Giữ MinIO Chainguard:** không đổi gì, đã kiểm; một nhà cung cấp "best-effort" trên mã đóng băng, không theo dõi version được, CORS chỉ toàn cục, `mc` từ repo archive.
- B. Fork `pgsty/silo`: mã MinIO, nhóm nhỏ, đã đổi tên một lần, CORS vẫn toàn cục. C. Garage v2.4.1: không có quyền theo tiền tố, đọc ẩn danh qua cổng website riêng, mất UP-4: loại.
- D. SeaweedFS: `content-length-range` kiểm sau khi nhận cả form, CORS mặc định `*`, nhận mọi key khi thiếu cấu hình. F. VersityGW: policy theo user cần dịch vụ IAM riêng, CORS toàn cục một origin, chạy root.
- G. Ceph RGW (vượt RAM, cần `hostPath`), H. Zenko CloudServer (không POST Object, chỉ amd64): loại.
- **E. RustFS 1.0.3:** Apache-2.0, GA, policy IAM và bucket policy kiểu AWS, CORS theo bucket mặc định đóng, plugin Barman e2e trên RustFS, image non-root có tag; dự án trẻ, 43 advisory (nhiều cái về policy và xác thực), CLA cho phép đổi giấy phép, init phải viết lại, RAM chưa có nguồn.

## Kết quả quyết định

Chọn **E. RustFS** cho cả compose và k3d, đổi trong **một lần**, với điều kiện qua đủ kế hoạch kiểm; trượt một điểm của UP-1, UP-4, UP-5, UP-6, WEB-10 hay BAK-1 mà không có bản RustFS đã phát hành sửa trong buổi đó thì **quay lại A** theo mục Cách chuyển, không nới kiểm soát nào. E hơn A vì A phụ thuộc một nhà cung cấp trên mã đóng băng, không có version để Renovate theo, CORS không theo bucket; E đạt mọi tiêu chí có nguồn và là store mà plugin Barman Cloud chọn để kiểm. Cái giá bảo mật của E (advisory dày) được giới hạn vì store chỉ nghe trên loopback (compose) hay sau Envoy trên loopback (k3d).

1. **Image** `rustfs/rustfs:<version>@sha256:<index đa kiến trúc>` (≥ 1.0.3), một anchor ở compose và `values.yaml` của `svp-data`, Renovate theo version ([ADR-0015](0015-cicd-devsecops-stage5.md) §10); uid 10001, root chỉ đọc, drop ALL, k3d `fsGroup` và seccomp `RuntimeDefault`.
2. **Tên trung tính `s3`** thay `minio`: service và volume `s3`, `s3-data`; StatefulSet, Service, NetworkPolicy, Job init, nhãn ở `svp-data` (`s3.svp-data:9000`); Secret `s3-root`, `s3-users`; thư mục `deploy/s3/`; biến `SVP_S3_ROOT_PASSWORD`. User `svp-video-service`, `svp-media-worker`, `svp-pg-backup`, tên bucket, key, `S3_*` của service không đổi.
3. **CORS theo bucket:** job init đặt `PutBucketCors` cho `uploads` (`POST`) và `media` (`GET`, `HEAD`) từ origin web; `RUSTFS_CORS_ALLOWED_ORIGINS` để rỗng (đóng khi thiếu). WEB-10 chặt hơn: preflight `POST` vào `media` hay `GET` ở `uploads` cũng bị từ chối.
4. **Init** viết lại `init.sh` (idempotent, đặt lại secret key và policy theo `.env`, `pg-backups` chỉ khi có `SVP_PG_BACKUP_S3_SECRET_KEY`): CLI `rc` ghim digest nếu tạo được user với secret chọn sẵn, policy, bucket policy ẩn danh, CORS; không được thì `curl --aws-sigv4` gọi `/rustfs/admin/v3/add-user`, `add-canned-policy` và API S3. Không dùng `mc`. Ba file policy và `media-anonymous.json` giữ nội dung, sửa gì thì ghi lý do.
5. **Barman Cloud:** `ObjectStore` `svp-pg-backup` chỉ đổi `endpointURL`; chỉ thêm `AWS_REQUEST_CHECKSUM_CALCULATION=when_required` qua `instanceSidecarConfiguration.env` nếu `drill-k8s-backup` trượt vì checksum.
6. **RAM:** giữ giới hạn 512 MiB ở compose và k3d tới khi có số đo nghỉ và đỉnh (upload ~100 MB, base backup).
7. **Console RustFS tắt** (`RUSTFS_CONSOLE_ENABLE=false`; lượt hiện thực kiểm lại tên biến ở bản ghim): compose bỏ cổng `127.0.0.1:9001`, k3d không khai cổng 9001; OPS-1 còn **7** cổng loopback. Xem object bằng công cụ dòng lệnh của init trong container tạm.
8. **Velero (mục 12 của kế hoạch kiểm) kiểm ở kịch bản `velero`** của [ADR-0021](0021-deferred-verification-stage6b.md) §7 trên RustFS; rủi ro CRC32 multipart kiểm sớm bằng ca multipart của Quyết định 9, chỉ giảm rủi ro, không thay backup và restore qua BackupStorageLocation. Trạng thái "Chấp nhận, trừ mục 12" tới khi mục 12 đạt, trượt thì theo "Xem lại khi".
9. **User thử `svp-objstore-probe`** (bucket riêng `objstore-probe`: ghi, đọc, xoá, `AbortMultipartUpload`, liệt kê phần; không CORS, không ẩn danh), tạo khi có `SVP_S3_PROBE_SECRET_KEY` (compose có, cluster không). Ca multipart gọi thẳng `CreateMultipartUpload`, `UploadPart` (5 MiB và 1 MiB), `CompleteMultipartUpload` với CRC32, hai lượt: **(a) header** qua `http://` (mọi `UploadPart` có `x-amz-checksum-crc32`, không `Content-Encoding: aws-chunked`), **(b) trailer** qua proxy TLS của test (`Content-Encoding: aws-chunked`, `x-amz-trailer: x-amz-checksum-crc32`, `x-amz-content-sha256: STREAMING-UNSIGNED-PAYLOAD-TRAILER`, không header CRC32); đọc lại đúng từng byte, upload dở bị `AbortMultipartUpload`; request không mang đúng dạng của lượt thì **FAIL**. Thêm hai ca chữ ký POST: policy sửa sau khi ký, form không có trường chữ ký bị từ chối.
10. **k3d không nâng tại chỗ:** `make k8s-up` từ chối cluster còn StatefulSet `minio` ở `svp-data` và in lệnh dựng lại (`make k8s-down`, `make k8s-up`). Đường GitOps luôn tạo cluster mới.

### Hệ quả

- Tốt: store có bảo trì, Apache-2.0, ghim theo version; CORS theo bucket gần cấu hình cloud; tên `s3` không gắn sản phẩm; init không còn phụ thuộc `mc` đã archive.
- Xấu: một lượt sửa rộng và một lượt kiểm đủ compose, k3d; dựa vào dự án trẻ nhiều advisory về xác thực và policy (cập nhật vá phải theo sát hơn); `uploads`, `media` của compose chép một lần khi dừng ghi, backup Postgres trên k3d cũ bỏ; giữ trong repo script chép hai chiều và digest A làm đường quay lại.
- Xem lại khi (một điều là đủ; quay lại A nếu Chainguard còn phát, không thì xét D hay F bằng ADR mới): một mục kế hoạch kiểm trượt mà bản RustFS đã phát hành chưa sửa; advisory critical hay high chạm POST policy, policy IAM, bucket policy, CORS, chữ ký chưa vá sau 30 ngày; RustFS đổi giấy phép khỏi Apache-2.0, ngừng phát hành quá 6 tháng hay archive; image mất một kiến trúc hay không chạy non-root; plugin Barman bỏ RustFS khỏi e2e; RAM của store vượt 512 MiB.

## Kế hoạch kiểm

Viết trước, chạy theo thứ tự ở mỗi nơi; một dòng trượt thì dừng, sửa hay quay lại A. Nơi chạy: máy 16 GB chỉ chạy một lượt `make up` + `make smoke` (mục 1, 2 lần đầu, 3, 4, 6), phần còn lại ở runner `compose-obs`, `dev-k3d` của ADR-0021 và job `stack` của `ci.yml`.

- **Mục 1, 2:** `make compose-config`, `make helm-check`, `make check` sạch, không sửa hay bỏ test có sẵn; `make up` hai lần: job init thành công, chạy lại không đổi gì, log không in secret.
- **Mục 3:** `make test-stack PKGS=./internal/objstore/...`: `TestIntegrationPresignedPost` (form đúng; đổi key sang upload khác, sang `media`; quá 1 byte; rỗng; sai và thiếu `Content-Type`; hết hạn; policy sửa sau khi ký; form không chữ ký), `TestIntegrationWorkerPermissions`, `TestIntegrationVideoServicePermissions`, `TestIntegrationDeletePrefix`, ca multipart CRC32 hai lượt: đều PASS, không SKIP.
- **Mục 4–6:** `make smoke` (upload tới `READY`, HLS, đọc ẩn danh `uploads` và liệt kê `media` bị từ chối); `make web-e2e` xanh Chromium và WebKit; WEB-10: origin lạ không header, origin web đúng origin, hai ca mới (`POST` vào `/media`, `GET` ở `/uploads`) không header.
- **Mục 7–9:** `make drill-upload-cleanup` PASS không còn `mc stat`; `make drill-obs-threats` PASS, OPS-1 đúng 7 cổng; RAM `s3` đỉnh dưới 512 MiB trong `make measure-upload`.
- **Mục 10, 11:** `make k8s-up`, `make k8s-smoke`, `make drill-k8s-threats` toàn PASS (WEB-10, BAK-1, OPS-2, IN-2, FF-5); `make drill-k8s-backup` và `MODE=pitr` qua, RTO và RPO so với lượt MinIO.
- **Mục 12, 13:** Velero, BAK-2 (Quyết định 8); đường quay lại: `make object-store-copy TO=minio` rồi `make up`, `make smoke` xanh trên RustFS.

## Cách chuyển

- **Một thay đổi, một lần:** compose, k3d, policy, script, tài liệu cùng một PR, không chạy song song hai store.
- **Dữ liệu phải giữ ở compose:** Postgres native (`svp_video`) không đổi, nên mọi key mà một dòng `videos` trỏ tới phải có trên store đang chạy: `media/<id>/…` của video `READY` và `uploads/<id>` của video `READY`, `PROCESSING`, `UPLOADING` đã gửi file (video-service chỉ xoá cả hai phía khi `FAILED`).
- **Bốn quy tắc, cả hai chiều:** (1) dừng ghi trước khi chép: chờ hết video `PROCESSING` (`SELECT` chỉ đọc), rồi `make down` giữ volume; (2) **không bao giờ xoá ở đích, từ chối mọi key chỉ có ở đích**: chép mọi object của `uploads` và `media` giữ key và `Content-Type`, chỉ thêm key thiếu, không xoá, không ghi đè; đích có key nguồn không có hay cùng key khác kích thước thì từ chối, không ghi gì; (3) kiểm xong mới đổi endpoint: mọi key của nguồn có ở đích cùng kích thước và `Content-Type`, đích không có key ngoài nguồn; kiểm trượt thì stack chạy lại trên store cũ; (4) store cũ chỉ xoá khi đường chép ngược đã chạy thử (mục 13) và mục 1–11 đã qua; người học chạy lệnh xoá.
- **Bước chép** `make object-store-copy TO=s3|minio` (`deploy/compose/object-store-copy.sh`): từ chối khi compose hay k3d đang chạy; dựng tạm hai store trên network nội bộ không publish cổng (MinIO bằng image A ghim digest, mật khẩu root ngẫu nhiên mỗi lượt; RustFS trên volume `s3-data`); `mc mirror` **không** `--remove`, **không** `--overwrite`; chạy kiểm của quy tắc 3; gỡ hai container tạm, không xoá volume. Script và digest A ở lại trong repo chừng nào RustFS còn chạy.
- **k3d:** cluster mới (`make k8s-down`, `make k8s-up`); lịch sử backup trên MinIO cũ mất cùng cluster (lab, chưa có dữ liệu cần giữ). **Quay lại A:** dừng ghi, `make object-store-copy TO=minio` (đích có key thừa thì từ chối, người học quyết), revert PR, `make up`, `make smoke`, xoá `s3-data` khi đã qua; revert PR một mình không đủ vì video tạo trên RustFS chỉ có object ở `s3-data`.

## Xác nhận

- Kế hoạch kiểm mục 1–11 và 13 đạt trên code cuối, kiểm ngày 2026-10-25 (PR #24, `rustfs/rustfs:1.0.3` ghim digest); mục 12 (Velero) đạt ngày 2026-10-28 ở kịch bản `velero` (hai lượt, RTO 58 s và 57 s), nên trạng thái bỏ phần "trừ mục 12".
- Số đo: `make test-stack` 39 PASS, 0 SKIP; `make web-e2e` 64/64; `drill-k8s-threats` 16/16; RAM `s3` đỉnh 356 MiB ở compose (70% của 512 MiB), ~280 MiB nghỉ cuối ở k3d; backup `latest` RTO 89,7 s, `pitr` RTO 89,6 s, cùng khoảng với MinIO.
- Khác với lúc viết, không nới hợp đồng: hai ca có sẵn của mục 3 (đổi key) đòi một mã 4xx và không object nào được ghi thay vì đúng 403 (RustFS trả 400 `InvalidPolicyDocument`); init dùng `curl --aws-sigv4`, không `rc`; `RUSTFS_CHECK_UPDATE=false`; chi tiết ở phụ lục.

## Hiện thực ở

- Store compose (Quyết định 1–3, 7): `deploy/compose/compose.yaml` (service `s3`, `s3-init`, volume `s3-data`, anchor `x-s3-image`), `deploy/compose/compose.mk`, `.env.example`, `renovate.json`.
- Init, policy, CORS, user thử (Quyết định 3, 4, 9): `deploy/s3/init.sh`, `deploy/s3/*-policy.json`, `deploy/s3/media-anonymous.json`.
- Store k3d (Quyết định 1–3, 5, 7, 10): `deploy/helm/svp-data/templates/s3.yaml`, `files/s3` (symlink tới `deploy/s3/`), `values.yaml`, `templates/networkpolicies.yaml`, `templates/backup.yaml` (`endpointURL`); `deploy/k8s/secrets.sh` (Secret `s3-root`, `s3-users`), `install.sh`, `k8s.mk`, `gitops.sh`, `deploy/k8s/drills/backup.sh`; mục KSV-0125 của `s3.yaml` ở `deploy/ci/trivy-config-ignore.yaml`.
- Kiểm: `internal/objstore/integration_test.go`, `web/e2e/security.e2e.ts` (WEB-10), `deploy/compose/drills/{common,upload-cleanup,obs-threats}.sh`, `deploy/k8s/drills/threats.sh`, `deploy/ci/verify-run.sh`, `verify-sample.sh`. Mã web nay ở `svp-frontend` ([0033](0033-svp-web-repo.md)); danh sách file đầy đủ ở phụ lục. Hiện trạng: [`explanation/deployment.md`](../explanation/deployment.md), [`threat-model.md`](../threat-model.md) (UP-5, WEB-10, BAK-1, BAK-2, OPS-1).

## Nguồn

- Repo MinIO, fork, ADR: <https://github.com/minio/minio>, <https://github.com/chainguard-forks/minio>, <https://github.com/rustfs/rustfs>, <https://docs.rustfs.com/administration/iam/policies>; danh sách đủ [M1]–[M11], [G1]–[G6], [W1]–[W13], [R1]–[R16], [V1]–[V6], [C1]–[C5], [Z1]–[Z4], [B1]–[B10] ở phụ lục.

## Thông tin thêm

Phụ lục: [`appendix/0022-local-object-store-minio-replacement.md`](appendix/0022-local-object-store-minio-replacement.md) (tiêu đề và dòng trạng thái gốc, bảng so sánh phương án, phân tích từng phương án, kế hoạch kiểm đầy đủ, cách chuyển, danh sách file, kết quả từng mục, số đo RAM, nguồn).

### Chỉnh bởi

- Kết quả quyết định: [0050](0050-bash-to-standard-tools.md): bỏ đường quay lại MinIO; RustFS là object store duy nhất của đường local, đổi store thì dùng công cụ sao chép S3 chuẩn.
