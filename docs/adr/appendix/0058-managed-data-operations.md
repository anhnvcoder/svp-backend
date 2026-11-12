# Phụ lục ADR-0058: RDS, MSK, ElastiCache có CloudWatch alarm gửi SNS mã hoá CMK tới email, ngưỡng theo khuyến nghị của AWS; MSK tự tăng dung lượng broker; ElastiCache chờ cửa sổ bảo trì ở prd và gửi slow-log tới CloudWatch Logs

Phụ lục của [ADR-0058](../0058-managed-data-operations.md): bảng phương án và nguồn. Mọi nguồn đọc ngày 2026-11-11.

## Phương án

| Phương án | Trạng thái ngành | Được | Mất | Nguồn |
| --- | --- | --- | --- | --- |
| **CloudWatch alarm → SNS → email** | Hiện hành, cách AWS khuyên cho dịch vụ managed | Sống độc lập với cluster; không thành phần tự vận hành; ngưỡng cùng Terraform của dịch vụ; trang "Recommended alarms" cho ngưỡng sẵn | Cảnh báo ở hai chỗ (CloudWatch, Alertmanager); ~$0,10 mỗi metric của alarm mỗi tháng | [N1], [N4] |
| YACE (`prometheus-community/yet-another-cloudwatch-exporter`) vào Prometheus | Hiện hành, exporter CloudWatch phổ biến nhất của Prometheus | Một chỗ xem và cảnh báo; dashboard Grafana chung | Cluster chết là mất alarm; trả `GetMetricData` mỗi lần scrape; thêm IAM, Pod Identity, một Deployment | [N11] |
| `prometheus/cloudwatch_exporter` (Java) | Cũ hơn YACE, vẫn bảo trì | Như YACE | Như YACE; JVM nặng, gọi API theo từng metric | [N12] |
| Cả CloudWatch alarm và exporter | Hiện hành ở tổ chức lớn | Alarm sống khi cluster chết, dashboard chung | Hai đường, gấp đôi cấu hình | — |

## Nguồn

- [N1] CloudWatch, Recommended alarms (RDS, ElastiCache; trang không có mục MSK): <https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/Best_Practice_Recommended_Alarms_AWS_Services.html>
- [N2] MSK, Best practices for Standard brokers (CPU, đĩa, heap): <https://docs.aws.amazon.com/msk/latest/developerguide/bestpractices.html>;
  metric và mức `DEFAULT`: <https://docs.aws.amazon.com/msk/latest/developerguide/metrics-details.html>
- [N3] SNS, Encryption at rest (key policy cho dịch vụ gửi tới topic mã hoá): <https://docs.aws.amazon.com/sns/latest/dg/sns-key-management.html>
- [N4] Amazon CloudWatch pricing (alarm, alarm metric math): <https://aws.amazon.com/cloudwatch/pricing/>
- [N5] Amazon RDS storage autoscaling: <https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/USER_PIOPS.Autoscaling.html>
- [N6] RDS, Maximum number of database connections: <https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/CHAP_Limits.html#RDS_Limits.MaxConnections>
- [N7] MSK, Automatic scaling: <https://docs.aws.amazon.com/msk/latest/developerguide/msk-autoexpand.html>
- [N8] MSK, Auto-scaling policy details: <https://docs.aws.amazon.com/msk/latest/developerguide/msk-autoexpand-details.html>
- [N9] Modifying an ElastiCache cluster (`ApplyImmediately`): <https://docs.aws.amazon.com/AmazonElastiCache/latest/dg/Clusters.Modify.html>
- [N10] ElastiCache log delivery: <https://docs.aws.amazon.com/AmazonElastiCache/latest/dg/Log_Delivery.html>
- [N11] YACE: <https://github.com/prometheus-community/yet-another-cloudwatch-exporter>
- [N12] CloudWatch exporter: <https://github.com/prometheus/cloudwatch_exporter>
