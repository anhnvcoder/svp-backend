# Phụ lục ADR-0055: stg chạy cùng dịch vụ, cấu hình, xác thực, mã hoá và giám sát với prd; stg chỉ giảm dự phòng, cỡ, số lượng, retention và bảo vệ xoá; mỗi khác biệt là dữ liệu có lý do

Phụ lục của [ADR-0055](../0055-environment-matrix.md): nguồn.

## Nguồn

Đọc 2026-11-11.

- [N1] The Twelve-Factor App, X. Dev/prod parity: <https://12factor.net/dev-prod-parity>
- [N2] AWS Well-Architected, REL10-BP01: <https://docs.aws.amazon.com/wellarchitected/latest/reliability-pillar/rel_fault_isolation_multiaz_region_system.html>
- [N3] AWS Well-Architected, Cost Optimization Pillar: <https://docs.aws.amazon.com/wellarchitected/latest/cost-optimization-pillar/welcome.html>
- [N4] NAT gateway basics: <https://docs.aws.amazon.com/vpc/latest/userguide/nat-gateway-basics.html>
- [N5] RDS DB instance class types: <https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/Concepts.DBInstanceClass.Types.html>
- [N6] RDS Multi-AZ: <https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/Concepts.MultiAZSingleStandby.html>
- [N7] MSK best practices: <https://docs.aws.amazon.com/msk/latest/developerguide/bestpractices.html>
- [N8] ElastiCache Multi-AZ: <https://docs.aws.amazon.com/AmazonElastiCache/latest/dg/AutoFailover.html>
- [N9] EKS cluster endpoint: <https://docs.aws.amazon.com/eks/latest/userguide/cluster-endpoint.html>
- [N10] EKS Best Practices, Auditing and logging: <https://docs.aws.amazon.com/eks/latest/best-practices/auditing-and-logging.html>
- [N11] EKS Best Practices, Data encryption: <https://docs.aws.amazon.com/eks/latest/best-practices/data-encryption-and-secrets-management.html>
- [N12] VPC Flow Logs: <https://docs.aws.amazon.com/vpc/latest/userguide/flow-logs.html>
- [N13] Gateway endpoints for S3: <https://docs.aws.amazon.com/vpc/latest/privatelink/vpc-endpoints-s3.html>
- [N14] Karpenter disruption: <https://karpenter.sh/docs/concepts/disruption/>
- [N15] Modifying an ElastiCache cluster: <https://docs.aws.amazon.com/AmazonElastiCache/latest/dg/Clusters.Modify.html>
