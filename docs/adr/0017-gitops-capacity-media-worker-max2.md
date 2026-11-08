# 0017. media-worker tối đa 2 replica và tiêu chí ổn định (c): k3s server không restart trong diễn tập KEDA

- Trạng thái: Chấp nhận
- Ngày: 2026-10-21
- Người quyết: người học (chọn C)

## Bối cảnh và vấn đề

- [ADR-0014 §2](0014-kubernetes-local-stage4.md#2-topology-và-ngân-sách-ram) đo cluster k3d `svp` chỉ bằng RAM: nghỉ
  > 6,5 GiB hay đỉnh > 8,7 GiB thì cắt lần lượt (1) Pyroscope, (2) metrics-generator của Tempo, (3) media-worker tối đa 2
  replica, (4) giới hạn và retention của Loki, Prometheus; nghỉ trên 6,5 GiB mà đủ (a) đỉnh dưới 8,7 GiB và (b) phần vượt là page
  cache thì ghi số, không cắt. [ADR-0015 §8](0015-cicd-devsecops-stage5.md#8-kyverno) thêm bước (1) tắt reports controller của Kyverno
  lên đầu thứ tự đó. [ADR-0014 §10](0014-kubernetes-local-stage4.md#10-workload): ScaledObject media-worker `maxReplicaCount: 3`
  "= 3 partition của `video.lifecycle.v1`", mỗi worker **2 CPU / 2 Gi** như compose (FF-3); Docker VM khoảng 9,7 GiB, 8 vCPU.
- Đo lại trên cluster GitOps (Argo CD, Kyverno, 23 Application): RAM đạt (a), (b) mà `make drill-k8s-keda N=9` vẫn FAIL vì k3s server
  chết (`level=fatal "Transaction commit failed"` khi compaction của kine/SQLite chạm hạn 20 s, container restart, API server mất
  2,5 phút). Lúc 3 worker cùng transcode, VM 99 % CPU bận, `MemAvailable` 1,06 GiB, swap tăng: nghẽn là CPU, thứ ADR-0014 §2 không đo.
  Hai lượt đo, số đỉnh và log ở [phụ lục](appendix/0017-gitops-capacity-media-worker-max2.md#bối-cảnh).

## Yếu tố quyết định

- Cluster phải đứng được suốt diễn tập KEDA (API server, Argo CD, HPA, `kubectl` không đứng theo), có tiêu chí đo được.
- Bớt đúng tài nguyên đang nghẽn (CPU), không mất observability hay Kyverno vô ích; một file values cho mọi đường; máy 16 GB.

## Phương án đã cân nhắc

- A. Ghi nhận là rủi ro, không cắt: giữ 3 job song song, nhưng API server có thể chết vài phút mỗi lần KEDA lên 3, drill không PASS.
- B. Cắt đúng thứ tự đã chốt (reports controller, Pyroscope, metrics-generator, rồi media-worker 2): ba bước đầu chỉ bớt RAM
  (~55, ~120, ~30 MiB), gần như không bớt CPU, mỗi bước một lượt đo ~20 phút.
- **C. Đi thẳng tới bước 3, media-worker tối đa 2 replica**: bớt 2 vCPU và ~0,7 GiB lúc đỉnh, một dòng values; mất một job song song.
- D. Giữ 3 replica, hạ limit CPU (ví dụ 1,5): tổng CPU gần như không giảm, mỗi job chậm hơn, lệch FF-3.
- E. Tăng CPU/RAM của Docker VM: máy 16 GB không còn chỗ cho macOS và compose.

Phân tích từng phương án ở [phụ lục](appendix/0017-gitops-capacity-media-worker-max2.md#các-lựa-chọn).

## Kết quả quyết định

Chọn **C**, vì nguyên nhân là CPU (mỗi worker 2 vCPU) và chỉ C bớt CPU lúc đỉnh mà giữ observability, Kyverno.

1. **Tiêu chí ổn định (c)**, thêm vào (a), (b) của ADR-0014 §2: **k3s server không restart trong suốt `make
   drill-k8s-keda`**, tức container `k3d-svp-server-0` giữ nguyên `RestartCount` và `State.StartedAt` (đọc bằng `docker inspect`
   lúc đầu và lúc kết thúc diễn tập). Drill tự kiểm (c), kể cả khi nó dừng vì lỗi khác; `docker inspect` không trả lời được cũng là
   FAIL, không tính là đạt. Thiếu (c) thì cắt như thiếu (a) hay (b).
2. **Thứ tự cắt khi thiếu (c):** đi thẳng tới bước 3 của ADR-0014 §2 (media-worker tối đa 2), bỏ qua reports controller
   (ADR-0015 §8), Pyroscope và metrics-generator. Thiếu (a) hay (b) thì vẫn cắt theo thứ tự cũ.
3. **media-worker `maxReplicaCount: 2`** (`keda.maxReplicas` trong `deploy/k8s/values/services/media-worker.yaml`). Cả hai đường (dev
   `make k8s-up` và GitOps) đọc cùng file nên cả hai cùng tối đa 2, dù đường dev đã chịu được 3.
4. **Topic `video.lifecycle.v1` giữ 3 partition**, thay ý "`maxReplicaCount` = số partition" của ADR-0014 §10: KEDA
   (`limitToPartitionsWithLag`) không xin quá một replica cho mỗi partition có lag, nên điều cần là số partition **≥**
   `maxReplicaCount`; với 2 worker, một worker giữ 2 partition. Không đổi số partition (Kafka không giảm được, tăng thì đổi ánh xạ
   khoá → partition; compose và cluster tạo topic bằng cùng `deploy/redpanda/create-topics.sh`).
5. **Cửa sổ đỉnh** của cách đo ADR-0014 §2 thành "6 mẫu liền trong khi đủ `maxReplicaCount` (2) worker cùng transcode".
6. **`drill-k8s-keda`** theo đó: điều kiện đầu là số partition ≥ `maxReplicaCount` ≥ 2; chờ `maxReplicaCount` replica Ready, mỗi
   pod giữ ít nhất một partition; ghim scale-down xuống `maxReplicaCount − 1` (1); đỉnh Ready phải đạt `maxReplicaCount`; vẫn upload
   tới khi record phủ đủ 3 partition. N giữ mặc định 9, cận 6–12 (12 video với 2 worker là 6 vòng ~45 s, dưới hạn 15 phút cho `READY`).

### Hệ quả

- Tốt: lúc đỉnh bớt 2 vCPU và ~0,7 GiB; có tiêu chí đo được cho việc "cluster đứng được", không chỉ "RAM vừa".
- Xấu: tối đa 2 job transcode song song, burst 9 video cần ~5 vòng thay vì ~3; đường dev cũng mất worker thứ ba. Sau khi đổi, cluster
  GitOps phải đo lại: nghỉ, rồi `make drill-k8s-keda N=9` **hai lần**, cả hai PASS gồm (c).
- Còn mở: trên cluster GitOps, RAM nghỉ (b) ở điểm 60 s và đỉnh (a) không đạt ngân sách (phần chênh lớn nhất là Argo CD); cắt theo thứ
  tự của ADR-0014 §2 hay ghi nhận là quyết định của người học. Lượt có 2 worker cùng transcode trên máy lab làm node server đứng ~40 s:
  rủi ro mở của máy lab.
- Xem lại khi: (c) vẫn trượt với 2 worker (xét D hay giảm CPU của thành phần khác, ghi bằng ADR mới); Docker VM có thêm CPU, hay chuyển
  lên cluster cloud với node thật (tính lại `maxReplicaCount` theo CPU của node, tối đa bằng số partition).

## Xác nhận

- Trên máy (cluster GitOps dựng mới, `maxReplicaCount` = 2): (c) đạt 3/3 lượt `make drill-k8s-keda N=9`, drill đạt 2/3; người học nhận
  kết quả, không đo lại ở local.
- Runner `ubuntu-24.04` 4 vCPU ([ADR-0021](0021-deferred-verification-stage6b.md) D1, D2): đường dev và đường GitOps PASS hai lượt có
  hai worker cùng transcode, (c) giữ, không node `NotReady`; RAM nghỉ (b) đạt ở đường dev, không đạt ở đường GitOps.
- Số đo, mã lượt chạy và ngày ở [phụ lục](appendix/0017-gitops-capacity-media-worker-max2.md#hệ-quả).

## Hiện thực ở

- `deploy/k8s/values/services/media-worker.yaml`: KEDA scale media-worker tối đa 2 replica.
- `deploy/k8s/drills/keda.sh`: tiêu chí (c), k3s server không restart suốt diễn tập.
- `deploy/k8s/cloud/values/chaos-mesh.yaml`: Chaos Mesh chỉ cài trên cluster cloud, vì máy 16 GB không còn chỗ.
- Hiện trạng: [`explanation/deployment.md`](../explanation/deployment.md), [`explanation/capacity.md`](../explanation/capacity.md),
  [`reference/k8s.md`](../reference/k8s.md); runbook [`k3s-server-down-under-transcode.md`](../runbooks/k3s-server-down-under-transcode.md).

## Thông tin thêm

Phụ lục: [`appendix/0017-gitops-capacity-media-worker-max2.md`](appendix/0017-gitops-capacity-media-worker-max2.md) (dòng trạng thái
gốc với các ghi chú có ngày, hai lượt đo trước quyết định, phân tích phương án, kiểm chứng sau đổi trên máy và trên runner).

### Chỉnh bởi

- Kiểm lại (c) và RAM: [0021](0021-deferred-verification-stage6b.md): hai worker cùng transcode và RAM nghỉ đo trên runner GitHub
  Actions thay cho cluster cloud.
- Kiểm lại (c) và RAM: [0039](0039-mainpath-drills-scan-gate-sourcemaps.md): một phần bị thay: `drill-k8s-keda` rời đường chính thành
  bài lab, đo lại trên EKS bằng k6 của buổi AWS.
- Đường script tạo topic: [0053](0053-msk-elasticache-valkey.md): `deploy/kafka/` của Apache Kafka thay `deploy/redpanda/create-topics.sh`.
