# 0012. Giữ Grafana LGTM là bộ observability chính; Elastic 9.5.5 qua APM Server chỉ là profile so sánh

- Trạng thái: Chấp nhận
- Ngày: 2026-10-17
- Người quyết: người học (bài so sánh theo [ADR-0011 §12](0011-observability-stage3.md#12-bài-so-sánh-elastic)); kết luận theo số đo của ADR này

## Bối cảnh và vấn đề

- [ADR-0011 §9 và §12](0011-observability-stage3.md#12-bài-so-sánh-elastic) chốt LGTM là bộ chính và để lại bài so sánh Elastic: cùng dữ liệu OTel qua Collector, chạy **lần lượt** (máy 16 GB, không bật hai bộ cùng lúc), heap Elasticsearch 1 GB, security tắt chỉ vì dev local, chỉ publish Kibana trên loopback; image/digest Elastic chốt ở đây.
- Tiêu chí của ADR-0011 §12: RAM nghỉ/đỉnh, thời gian khởi động, số dòng cấu hình, truy vấn (PromQL/LogQL/TraceQL với ES|QL/KQL), nhảy trace ↔ log, công vận hành, chi phí khi lên cloud. Không so error tracker hay profile.
- Máy Apple M2 16 GB; Docker Desktop đã nâng lên khoảng **9,7 GiB** (`docker info` MemTotal 10 419 650 560 byte, 8 CPU) trước bài đo. Postgres/Redis native nằm ngoài số đo container.

## Yếu tố quyết định

- Số đo trên cùng dữ liệu và cùng tải lab: RAM nghỉ/đỉnh, thời gian khởi động, số dòng cấu hình, thời gian truy vấn mẫu.
- Vừa ngân sách RAM 3–3,5 GiB trên core mà ADR-0011 §13 dự toán; đường SLO/cảnh báo đã dựa trên PromQL; chi phí lên cloud.

## Phương án đã cân nhắc

- §1 **Collector → APM Server (OTLP) → Elasticsearch, Kibana đọc** (đường Elastic hỗ trợ cho upstream OTel, index template do plugin `apm-data` tự cài)
- §1 exporter `elasticsearch` của Collector ghi thẳng (bớt một container nhưng bỏ qua pipeline xử lý, chưa kiểm)
- §1 một service `otelcol` đổi file cấu hình theo biến (một biến sai là LGTM nhận cấu hình Elastic)
- §6 **giữ LGTM là bộ chính, giữ profile `obs-elastic` để học**
- §6 chọn Elastic làm bộ chính
- §6 bỏ profile Elastic

Bảng được/mất ở [phụ lục](appendix/0012-elastic-vs-grafana-stage3.md).

## Kết quả quyết định

Giữ **Grafana LGTM là bộ chính** và Elastic 9.5.5 qua APM Server chỉ là profile so sánh `obs-elastic`, vì ở cùng dữ liệu và tải lab LGTM nhẹ hơn, khởi động nhanh hơn và khớp đường PromQL của SLO; mỗi § dưới giữ quyết định, bảng và số đo đầy đủ ở phụ lục.

### 1. Đường dữ liệu và cách dựng profile `obs-elastic`

- Giữ đường APM Server. Profile `obs-elastic` ở `deploy/compose/compose.yaml` gồm `elasticsearch` (`discovery.type=single-node`, `xpack.security.enabled=false`, `ES_JAVA_OPTS=-Xms1g -Xmx1g`, `mem_limit: 2g`, không publish, tắt `ingest.geoip.downloader`), `kibana` (`deploy/observability/elastic/kibana.yml`, chỉ `127.0.0.1:5601`, `mem_limit: 1536m`), `apm-server` (`apm-server.yml`, OTLP ở 8200, `mem_limit: 512m`, không publish).
- `otelcol-elastic`: cùng image Collector ghim digest, hai `--config`: `deploy/observability/otelcol/config.yaml` của `obs` rồi `deploy/observability/elastic/otelcol-config.yaml` ghép đè (chỉ thêm exporter `apm-server:8200` và trỏ ba pipeline cùng metric tự thân sang đó); receiver và processor chỉ có một nguồn là file `obs`. `make otelcol-validate` kiểm cả hai cấu hình. Nằm ở `default` và `worker` với **alias mạng `otelcol`**, nên service vẫn gửi `otelcol:4317`.
- Cách dựng này **chỉnh** câu "Một service compose `otelcol` dùng cho cả hai cách chạy" của [ADR-0011 §1](0011-observability-stage3.md#1-đường-đi-telemetry-và-collector): một **tên** mạng và một bộ receiver/processor, nhưng hai service compose (`otelcol`, `otelcol-elastic`).
- `make up OBS=elastic` thêm `--profile obs-elastic`; `OBS=lgtm` và `OBS=elastic` từ chối khi container chạy lâu dài của bộ kia đang chạy (báo `make down` trước). Không service `core` nào phụ thuộc profile này.
- Image ghim `tag@sha256` (manifest list có linux/amd64 và linux/arm64; digest ở phụ lục): `docker.elastic.co/elasticsearch/elasticsearch`, `docker.elastic.co/kibana/kibana`, `docker.elastic.co/apm/apm-server`, cùng tag `9.5.5` (bản ổn định mới nhất lúc tra 2026-10-17). APM Server healthcheck bằng `bash` mở `/dev/tcp/127.0.0.1/8200` và chạy với `--strict.perms=false`.
- Không cần bước tay: APM Server ghi data stream `traces-apm*`, `metrics-apm*`, `logs-apm*` ngay khi khởi động; `vm.max_map_count` trong VM Docker Desktop đã **262144**. Profile này không có Pyroscope (0 dòng WARN/pyroscope sau hơn 2 phút) và `SENTRY_DSN` vẫn trỏ GlitchTip không chạy.

### 2. Cách đo

- Cùng code, cùng file compose, image Go đã build trước, mỗi bộ: `make ps` rỗng; `docker stats --no-stream` mẫu cách nhau 2–3 s và `docker ps` mỗi 1 s ghi lúc container lên và `(healthy)` đầu tiên; `time make up OBS=lgtm` / `OBS=elastic` (`--wait`); chờ 60 s, **RAM nghỉ** là trung vị các mẫu trong 90–100 s tiếp theo; `make smoke` **3 lần liền**, **RAM đỉnh** là mẫu lớn nhất tới 4 s sau lần smoke cuối.
- Truy vấn mẫu đo `curl -w '%{time_total}'` một lần từ host qua Grafana datasource proxy và Kibana (`/api/console/proxy?path=/_query`, `/internal/apm/...`); `make down`, `make ps` rỗng; Elastic khởi động thêm một lượt với volume ấm. Trace có lỗi lấy từ thân 404 `VIDEO_NOT_FOUND`; trace ≥ 3 service là của `POST /videos/{video_id}/complete`.

### 3. Số đo (2026-10-17)

- RAM backend nghỉ: LGTM (`otelcol` + `lgtm`) **1 374 MiB**, Elastic (`otelcol` + Elasticsearch + Kibana + APM Server) **2 995 MiB**. Tổng stack nghỉ/đỉnh smoke: LGTM **2 276 / 2 676 MiB**, Elastic **3 585 / 3 759 MiB**. Không container nào OOM hay restart; Elasticsearch dùng 84% giới hạn lúc nghỉ, Kibana 76%.
- Khởi động toàn stack (`make up --wait`): LGTM **19 s** và 20 s, Elastic ấm **44 s**, nguội **74 s**. Số dòng cấu hình tới UI có trace ↔ log: LGTM **220**, Elastic **194**. Bảng từng container, khởi động và dòng cấu hình ở phụ lục.

### 4. Truy vấn mẫu

- Mọi truy vấn mẫu (trace theo `trace_id`, log của trace, trace ≥ 3 service, tỉ lệ lỗi theo route, p99 feed) làm được ở cả hai bộ và đều dưới 0,1 s (ES|QL đầu tiên quét mọi data stream 0,31 s). Service map: Tempo có sẵn; Kibana `/internal/apm/service-map` trả **403**, cần license Platinum (license đang chạy `basic`).
- Hai cột p99 không cùng phép tính (PromQL nội suy bucket, ES|QL percentile trên từng transaction chỉ đúng khi giữ 100% trace); mẫu nhỏ, không phải benchmark. Quan sát: trace ↔ log Elastic có sẵn, LGTM cần provisioning và override nhãn OTLP của Loki; Elastic index mọi field log (`labels.*`) nên tốn index; APM Server tạo `logs-apm.error` từ exception event; LGTM dùng PromQL cho Sloth và rule, Elastic phải viết lại cảnh báo bằng Kibana alerting (chưa kiểm license).

### 5. Chi phí khi lên cloud

- Dùng mốc giá niêm yết tra 2026-10-16 ở [ADR-0011 §12](0011-observability-stage3.md#12-bài-so-sánh-elastic): [Grafana Cloud](https://grafana.com/pricing/) Free 10k active series và 50 GB ingest/tháng, Pro từ 19 USD/tháng + usage; [Elastic Observability Serverless Complete](https://www.elastic.co/pricing/serverless-observability/) ingest logs/traces từ 0,09 USD/GB, metric từ 0,023 USD/GB (chi tiết ở phụ lục). Lab chưa có lượng ingest thật nên không quy ra hoá đơn.
- Điểm tự host đo được: Elastic cần thêm khoảng **1,6 GiB RAM** lúc nghỉ so với LGTM (2 995 so với 1 374 MiB); service map cần license Platinum hoặc bản managed. Giá AWS/GCP managed so ở buổi cloud.

### 6. Quyết định

- **Giữ Grafana LGTM là bộ chính** (như ADR-0011): RAM backend nghỉ 1,34 GiB so với 2,92 GiB, tổng stack 2,2 GiB so với 3,5 GiB (Elastic vừa ngân sách 3–3,5 GiB nhưng chỉ chạy được khi Docker Desktop đã ~9,7 GiB); khởi động ấm 19–20 s so với 44 s (nguội 74 s); SLO/cảnh báo và dashboard dựa trên PromQL, service graph Tempo miễn phí còn service map Kibana cần Platinum; truy vấn mẫu nào cũng làm được dưới 0,1 s ở cả hai.
- **Profile `obs-elastic` giữ lại** để học và so lại; không cảnh báo, không dashboard, không GlitchTip. Không thay APM Server bằng exporter `elasticsearch`: chưa kiểm, và tài liệu Elastic không hỗ trợ đường đó cho Kibana APM.
- **Nên chọn Elastic khi** tổ chức đã vận hành Elasticsearch hoặc dùng Elastic cho SIEM/security; cần tìm kiếm full-text trên khối log lớn với field tuỳ ý (mọi field đều được index, không bị giới hạn nhãn như Loki); muốn một ngôn ngữ truy vấn (ES|QL) cho cả ba tín hiệu với trace ↔ log có sẵn; chấp nhận license trả phí hoặc Elastic Cloud cho service map, ML và tính năng APM nâng cao.

### Hệ quả

- Tốt: kết luận "LGTM là bộ chính" có số đo trên cùng tải; Collector đổi backend chỉ bằng exporter và alias mạng, service, SDK và processor xoá dữ liệu nhạy cảm giữ nguyên; có profile Elastic chạy bằng một lệnh để thử ES|QL, Kibana APM.
- Xấu: cấu hình Collector Elastic là file ghép sau file `obs` (đổi tên exporter hay pipeline ở `obs` phải chạy lại `make otelcol-validate`, image Elastic nâng riêng); Elastic chạy không đăng nhập, Dev Tools ghi/xoá được chỉ mục, chỉ chấp nhận vì loopback và dữ liệu lab như Grafana anonymous Admin (OPS-2), không dùng ngoài máy local; lượt `obs-elastic` không có Pyroscope, GlitchTip, cảnh báo hay dashboard nên không dùng cho diễn tập quan sát.
- Xem lại khi: lên cloud có lượng ingest/series/retention thật (tính Grafana Cloud, Elastic Cloud, dịch vụ AWS/GCP bằng giá ngày đó); cần tìm kiếm full-text log hoặc SIEM, hay tổ chức đã có Elastic; Elastic hỗ trợ chính thức đường exporter thẳng cho Kibana APM, hoặc đưa service map vào license miễn phí.

## Xác nhận

- 2026-10-17: `make compose-config` exit 0 cho `core`, `core`+`obs`, `core`+`obs-elastic`, `OBS=off`; digest kiểm bằng `docker buildx imagetools inspect <image>:9.5.5`; hai bộ không chạy cùng (exit 2 với thông báo `make down`); `make smoke` 3 lần trên Elastic và 9 lần trên LGTM, mọi lượt 38 bước ok; `make otelcol-validate` exit 0 cho `obs` và cấu hình ghép (bản lỗi bị từ chối).
- Bảng lệnh và kết quả đầy đủ ở [phụ lục](appendix/0012-elastic-vs-grafana-stage3.md#kiểm-chứng-đã-kiểm-ngày-2026-10-17). Chưa làm: thao tác bằng trình duyệt (đã gọi API của các trang), khởi động nguội của LGTM, CPU, lượng đĩa, thử exporter `elasticsearch`, overhead a/b/c của ADR-0011 §10.

## Hiện thực ở

- Profile `obs-elastic` của `deploy/compose/compose.yaml`, chọn bằng `make up OBS=elastic` (`deploy/compose/compose.mk`).
- Cấu hình ở `deploy/observability/elastic/` (`apm-server.yml`, `kibana.yml`, `otelcol-config.yaml` ghép đè lên `deploy/observability/otelcol/config.yaml`, chỉ đổi exporter).
- Hiện trạng: [`explanation/observability.md`](../explanation/observability.md), [`reference/compose.md`](../reference/compose.md).

## Thông tin thêm

Phụ lục: [`appendix/0012-elastic-vs-grafana-stage3.md`](appendix/0012-elastic-vs-grafana-stage3.md) (bảng được/mất, digest, quy trình đo, bảng RAM, khởi động và dòng cấu hình, bảng truy vấn mẫu, mốc giá, bảng kiểm chứng).
