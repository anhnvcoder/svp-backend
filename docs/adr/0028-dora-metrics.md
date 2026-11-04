# 0028. DORA metrics của lab tính bằng script của repo từ bằng chứng đã triển khai (bản ghi Deployment `success` của stg), không từ merge; số là của stg lab, thiếu mẫu ghi "chưa đủ dữ liệu", không xếp hạng theo mức DORA

- Trạng thái: Bị thay bởi [0037](0037-mainpath-standard-tools.md)
- Ngày: 2026-10-28
- Người quyết: người học (duyệt 2026-10-28, chọn (a) ở cả bốn dòng của "Cần người học chọn"); thay bởi 0037 ngày 2026-11-01 (DORA rời đường chính, `dora.sh` thành bài lab `dora/` của `svp-labs`)

## Bối cảnh và vấn đề

- **Yêu cầu:** đo deployment frequency, lead time for changes, change failure rate, time to restore từ dữ liệu có thật của lab (commit, PR promote, bản ghi triển khai, đồng bộ của Argo CD, sự cố, postmortem); nơi tính là script CI trung lập nền tảng qua `deploy/ci/platform.sh` ([ADR-0023](0023-ci-platform-neutral.md)); nơi hiển thị do ADR này chọn.
- **Định nghĩa DORA** (đọc 2026-10-28): năm chỉ số giao phần mềm: change lead time, deployment frequency, failed deployment recovery time, change fail rate, deployment rework rate. MTTR đổi tên năm 2023 để tách sự cố do thay đổi khỏi nguyên nhân ngoài; rework rate thêm năm 2024, nên "time to restore" của lab đọc là failed deployment recovery time. Bốn mức hiệu năng 2024 (Elite, High, Medium, Low) là ảnh chụp khảo sát của năm đó; báo cáo 2025 mô tả bảy hồ sơ nhóm. DORA khuyên không đặt chỉ số làm mục tiêu hay so giữa các nhóm.
- **Dữ liệu của lab:** 10 PR promote trong repo code (#1 tới #25, 2026-10-21 tới 2026-10-25) chỉ đổi file values, không cluster nào chạy liên tục theo `main`; **merge không chứng minh đã triển khai** ([ADR-0024](0024-multi-environment.md) §8). Bản ghi stg là Deployment GitHub trên `svp-gitops` (environment `stg`, `ref` là commit đã đồng bộ, payload là bộ bảy `repository@digest`), chỉ ghi sau khi phép kiểm qua; chưa có bản ghi nào lúc quyết. Deployment status mặc định `auto_inactive: true` đặt bản ghi trước thành `inactive` và trạng thái trước đó bị xoá sau 90 ngày.
- stg chỉ sống trong một lượt runner (`gitops` dựng cluster mới, kiểm, xoá); prd chỉ render và kiểm tĩnh tới giai đoạn 7; postmortem duy nhất (`docs/postmortems/261024-gameday-engagement-down.md`) là game day tiêm có chủ ý, không do triển khai.
- Ràng buộc: một người làm, hai repo public (không token ghi cho việc đọc); CI trung lập nền tảng; máy 16 GB không chạy thêm dịch vụ thường trực; không bịa số, mỗi số có nguồn.

## Yếu tố quyết định

- Định nghĩa đúng của lab (deployment là bằng chứng đã chạy, khử trùng lượt kiểm, nhãn stg lab) viết thẳng thành code có test; không dịch vụ thường trực; dữ liệu công khai; trung lập nền tảng.
- Số thiếu mẫu không giả làm số thật; không xếp mức khi dữ liệu không đủ tư cách so với khảo sát production.

## Phương án đã cân nhắc

- §1 công cụ: **A. script của repo (`deploy/ci/dora.sh`) qua `ci_*`**.
- §1 B. Apache DevLake: Top-Level Project của ASF từ 2025-10-07, bản `v1.0.3-beta18`; bốn container thường trực, định nghĩa của lab phải ép vào mô hình.
- §1 C. Four Keys của Google: archive, gắn GCP.
- §1 D. DORA có sẵn của GitLab: chỉ gói Ultimate, lab ở GitHub.
- §1 E. SaaS (Swarmia, LinearB, DX): cần App đọc repo vào bên thứ ba.
- §2 deployment: A. merge vào `envs/<env>/images/`.
- §2 B. `status.history` của Argo CD.
- §2 **C. bản ghi Deployment `success` của stg**.
- §2 D. C cộng JSON `measure-gitops`.
- §3 mốc đầu lead time: **A. thời điểm commit có trên `main`**.
- §3 B. commit đầu của PR.
- §4 failure: **A. bằng chứng sau bản ghi (rollback có quy ước, postmortem chỉ vào deployment)**.
- §4 B. lượt `gitops` đỏ.
- §4 C. mọi postmortem.
- §5 hiển thị: **A. tóm tắt lượt chạy và JSON artifact**.
- §5 B. thêm dashboard Grafana.
- §5 C. dashboard DevLake.

Bảng được/mất ở [phụ lục](appendix/0028-dora-metrics.md).

## Kết quả quyết định

Chọn script của repo, đọc bằng chứng đã chạy ở stg, vì định nghĩa riêng của lab là phần khó mà công cụ nào cũng phải được dạy lại, còn script nhỏ có test làm trực tiếp, không thêm dịch vụ thường trực và mang sang GitLab bằng nhánh `gitlab` của các hàm `ci_*`; mỗi § dưới giữ quyết định, bảng và phân tích đầy đủ ở phụ lục.

### 1. Công cụ: script của repo (1A)

`deploy/ci/dora.sh` tính, `.github/workflows/dora.yml` chỉ nối bước. Đáng xét lại DevLake khi lab có nhiều repo, nhiều người hay một máy chủ chạy thường trực (đo RAM trước).

### 2. Nguồn và danh tính deployment (2C)

- **Deployment** là bản ghi Deployment `success` trên `svp-gitops` (ADR-0024 §8), environment `stg` hay `prd`, do App `svp-gitops-promoter` tạo và có URL lượt `verify.yml` trên `main` của repo code; bản ghi không qua bộ lọc hay thiếu `deployed_at` bị bỏ và liệt kê kèm lý do. Bên ghi tạo trạng thái `success` với **`auto_inactive: false`**, để trạng thái hiện tại của mọi bản ghi vẫn là `success` và không bị xoá sau 90 ngày.
- Bên đọc đọc mọi trạng thái API còn trả: `success` thì tính; `inactive` mà danh sách còn một `success` thì tính kèm cảnh báo nêu id; `inactive` không còn `success` thì bỏ và liệt kê id kèm lý do "không còn bằng chứng `success`".
- **Danh tính:** (env, revision R của `svp-gitops` đã đồng bộ, bộ bảy `repository@digest`). Nhiều bản ghi cùng (env, R, bộ) là **một** deployment lấy `deployed_at` của bản ghi **đầu tiên**, các bản sau là **lượt kiểm**; **R khác** là deployment mới kể cả khi bộ digest bằng bộ cũ; bộ trùng bộ cũ không tự là rollback.
- `measure-gitops` không dùng (2D không chọn). 10 PR promote trước khi tách repo **không** tính vào bốn chỉ số; chúng vào chỉ số riêng "tần suất promote" nhãn "trước tách, repo code", nguồn là commit squash `chore(release): …` trên `main` của repo code. prd chưa có bản ghi tới giai đoạn 7: output ghi "chưa có dữ liệu prd", không ghi 0.

### 3. Ánh xạ từng chỉ số vào lab

Mọi số của stg mang nhãn **"stg lab (cụm dựng trong một lượt runner)"**. Deployment frequency: số deployment có `deployed_at` trong cửa sổ, kèm số lượt kiểm. Change lead time: `deployed_at` của deployment sớm nhất ở env chứa thay đổi trừ thời điểm commit. Change fail rate: số deployment thất bại trên số deployment. Failed deployment recovery time: từ mốc bắt đầu tới mốc khôi phục. Deployment rework rate: số deployment là rollback hay là deployment sớm nhất chứa một commit sửa mà postmortem liệt kê, trên số deployment. Thêm "tần suất promote" (không phải DORA) và danh sách "đã merge, chưa triển khai" (bảng ở phụ lục).

### 4. Lead time chi tiết (3A)

- Mốc đầu: committer date của commit trên `main`; mốc cuối: `deployed_at` của deployment **sớm nhất** của env chứa thay đổi. **Thay đổi** là commit một cha của `main` repo code mà `deploy/ci/changed-services.sh` liệt kê một service, commit đổi `deploy/helm/` hay file dẫn xuất, hoặc commit của `svp-gitops` đổi ngoài `envs/*/images/` và `envs/*/charts.yaml`. Deployment D **chứa** c khi c là chính hay tổ tiên (`git merge-base --is-ancestor`) của mốc tương ứng trong D.
- Mỗi thay đổi có **một** mẫu, ở deployment sớm nhất chứa nó; thay đổi mà deployment đầu tiên của env đã chứa không có mẫu (deployment đầu tiên đếm vào frequency, không vào lead time). Ở stg lab lead time gồm cả thời gian chờ tới lượt `gitops` kế tiếp; output nói rõ. Lead time của bản web do `svp-frontend` build tính trên lịch sử repo đó (chỉnh bởi 0033).

### 5. Failure, rollback, restore (4A)

- **Rollback trong `svp-gitops`:** commit trên `main` có tiêu đề `revert: …` và footer `Refs: <sha>` (Conventional Commits), hay dạng `git revert`; `svp-gitops` đặt squash mặc định `squash_merge_commit_title: PR_TITLE`, `squash_merge_commit_message: PR_BODY`. Deployment có R chứa (lần đầu) commit như vậy là **rollback**; deployment **thất bại** là deployment gần nhất trước nó, cùng env, có R chứa commit bị revert. Rollback prd (giai đoạn 7): PR prd mở với bản ghi stg cũ hơn. Postmortem ghi `deployment` thì deployment đó thất bại.
- **Khôi phục:** bắt đầu là `started_at` của postmortem nếu có, không thì `deployed_at` của deployment thất bại; kết thúc là `restored_at` nếu có, không thì `deployed_at` của deployment rollback hay deployment đầu tiên chứa một commit trong `fix_commits`. Chưa có mốc kết thúc thì "chưa khôi phục". Postmortem `deployment: none` không vào bốn chỉ số (liệt kê "sự cố không do triển khai"); lượt `gitops` đỏ không phải failure.

### 6. Đủ dữ liệu, không xếp hạng

- Ngưỡng của lab: tỷ lệ (change fail rate, rework rate) cần ít nhất **10** deployment trong cửa sổ, trung vị (lead time, recovery time) cần ít nhất **5** mẫu; dưới ngưỡng in "chưa đủ dữ liệu (n = …, cần ≥ …)" cùng tử số, mẫu số hay từng giá trị. Cửa sổ có bản ghi nhưng không có deployment thì frequency là 0.
- **Không xếp mức** Elite/High/Medium/Low: bảng 2024 là của production và mẫu khảo sát năm đó, prd của lab chưa có dữ liệu, stg lab bị chặn bởi nhịp lượt runner. Bảng 2024 chỉ nằm ở phụ lục làm tham khảo.

### 7. Quy ước dữ liệu cần thêm

- Payload bản ghi stg: `deployed_at` (RFC 3339 UTC, muộn nhất trong các `deployedAt` của R ở `status.history`), R, bộ bảy `repository@digest`, `charts`, URL lượt chạy; trạng thái `success` với `auto_inactive: false` (cả bản ghi prd sau này).
- Postmortem thêm front matter YAML: `env` (`stg | prd | compose | k3d`), `deployment` (revision 40 hex của `svp-gitops` hay `none`), `started_at`, `restored_at`, `fix_commits`; mốc lấy từ dòng thời gian có nguồn (game day 2026-10-24: `env: compose`, `deployment: none`). `svp-gitops` ghi quy ước rollback và hai cài đặt squash vào `README.md`.

### 8. Workflow và output

- `.github/workflows/dora.yml`: `schedule` hằng tuần (thứ Bảy 09:17 UTC) và `workflow_dispatch` với input `days` (mặc định 30); `permissions: {}` ở đầu file, job chỉ `contents: read`; không secret, không environment, không `pull_request`; action ghim SHA. Đọc bằng `GITHUB_TOKEN` chỉ để có giới hạn 1 000 request mỗi giờ thay vì 60; git của hai repo bằng clone ẩn danh (`make gitops-clone`).
- Cửa sổ 30 ngày lăn, cộng cột "từ khi tách repo". Output: bảng Markdown vào tóm tắt của lượt (`ci_summary`), JSON artifact `dora` giữ 30 ngày; không giữ lịch sử artifact vì bản ghi `success` tính lại được bằng dispatch với `days` lớn hơn; không dashboard Grafana (5A). Chạy trên máy: `deploy/ci/dora.sh` ở chế độ `local` của `platform.sh`, chỉ đọc.

### 9. Hàm `ci_*` cần có và tương đương trên GitLab

Hàm đọc Deployment nhận repo đích, trả payload và mọi trạng thái; hàm ghi trạng thái nhận `auto_inactive: false`; tóm tắt qua `ci_summary`; PR promote, revert và postmortem đọc bằng `git log` và file, không cần hàm. GitLab: `GET /projects/:id/deployments` (gói Free) nhưng Deployment **không có payload**, nên bộ digest, R, `deployed_at` phải nằm chỗ khác, chốt khi mang CI sang GitLab; DORA dựng sẵn của GitLab (Ultimate) không thay script vì tính lead time từ lúc merge MR.

**Cần người học chọn** (duyệt 2026-10-28, chọn (a) cả bốn): 1. công cụ: script của repo; 2. nơi hiển thị: tóm tắt lượt chạy và JSON artifact; 3. failure: chỉ bằng chứng sau bản ghi; 4. kịch bản `gitops` vào lịch tuần của `verify.yml` trên `main`, bỏ bước chờ phát hành (trần một deployment mỗi tuần, ghi rõ trong output).

### Hệ quả

- Tốt: số của lab đọc từ bằng chứng đã chạy, mỗi số có nhãn môi trường và nguồn, số thiếu mẫu không giả làm số thật; bản ghi stg phục vụ cả cổng prd lẫn DORA; không thêm dịch vụ, không token ghi.
- Xấu: ở stg lab số đo nhịp lượt runner hơn nhịp giao hàng (frequency bị trần bởi số lượt `gitops`, lead time gồm chờ lượt kế, change fail rate gần như luôn thấp), không so được với bảng DORA; một người làm nên nhiều tuần liền mọi tỷ lệ là "chưa đủ dữ liệu"; quy ước mới giữ bằng kỷ luật (front matter postmortem, tiêu đề và footer PR revert, cài đặt squash); tự viết, tự giữ khi DORA đổi định nghĩa.
- Xem lại khi: giai đoạn 7 có prd thật (chốt bản ghi prd, xét lại xếp mức và `measure-gitops`); lab có nhiều repo, nhiều người hay máy chủ thường trực (xét DevLake, đo RAM); CI chạy thật trên GitLab (chỗ giữ payload); DORA công bố định nghĩa hay chỉ số mới.

## Xác nhận

- `deploy/ci/dora-test.sh` (dữ liệu giả cố định) xanh ở job `config` của `.github/workflows/ci.yml` (2026-10-29); `dora.yml` dispatch đầu 2026-10-30 đọc được bản ghi stg (deployment frequency 1), lead time "chưa đủ dữ liệu (n = 0, cần ≥ 5)".
- Chưa kiểm: footer `Refs:` của PR revert trong commit squash của `svp-gitops`; trạng thái `success` của bản ghi đầu sau lượt `gitops` thứ hai; lượt lịch tuần đầu của `verify.yml`. Bảng kiểm đầy đủ ở [phụ lục](appendix/0028-dora-metrics.md#kiểm-chứng-sau).

## Hiện thực ở

- `deploy/ci/dora.sh`, `deploy/ci/dora-test.sh`, `.github/workflows/dora.yml`, `deploy/ci/platform.sh` (`ci_deployment_list`, `ci_run_workflow`, `ci_deployment_record`), `deploy/ci/record-stg.sh`, `deploy/ci/platform-test.sh`.
- Front matter postmortem: `docs/postmortems/README.md`, `docs/postmortems/261024-gameday-engagement-down.md`. Lịch tuần của job `gitops`: `.github/workflows/verify.yml`, `deploy/ci/verify/gitops.sh`.
- Chưa kiểm: cài đặt squash của `svp-gitops` (§5). DORA đã thành bài lab `dora/` của `svp-labs` ([ADR-0037](0037-mainpath-standard-tools.md)).

## Nguồn

Đọc ngày 2026-10-28; danh sách đầy đủ [N1]–[N17] ở [phụ lục](appendix/0028-dora-metrics.md#nguồn). Chính: [DORA metrics](https://dora.dev/guides/dora-metrics/), [lịch sử các chỉ số](https://dora.dev/insights/dora-metrics-history/), [GitHub REST deployment statuses](https://docs.github.com/en/rest/deployments/statuses).

## Thông tin thêm

Phụ lục: [`appendix/0028-dora-metrics.md`](appendix/0028-dora-metrics.md) (tiêu đề và dòng trạng thái gốc, bối cảnh đầy đủ, bảng được/mất từng phương án, ánh xạ chỉ số, quy tắc lead time, bảng `ci_*` GitHub và GitLab, bảng "Kiểm chứng sau", danh sách nguồn).

### Chỉnh bởi

- §4: [0033](0033-svp-web-repo.md): lead time của bản web do `svp-frontend` build tính trên lịch sử repo đó (ba repo), từ 2026-10-30.
- §2: [0036](0036-repo-rename.md) §8: nguồn của image trong bản ghi gán theo bảng ở `charts.revision` của bản ghi; bản ghi dưới tên repo cũ đọc lâu dài, từ 2026-10-31.
- "Cần người học chọn" dòng 4: [0021](0021-deferred-verification-stage6b.md) mục 3: lịch tuần của `verify.yml` chạy job `gitops` không chờ phát hành, bản ghi stg ghi khi bước kịch bản xanh.
