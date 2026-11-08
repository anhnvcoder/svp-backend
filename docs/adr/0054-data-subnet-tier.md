# 0054. VPC của stg, prd có ba tầng subnet: RDS, MSK, ElastiCache ở subnet database không có route ra Internet

- Trạng thái: Chấp nhận
- Ngày: 2026-11-08
- Người quyết: người học (2026-11-08: VPC ba tầng public, private, database theo chuẩn production); AI theo giao (khối địa chỉ, cách dựng bằng module)

## Bối cảnh và vấn đề

- Module `network` của `svp-infra` dựng VPC hai tầng ([0034](0034-aws-stage7.md) §8, §9): subnet public (NAT gateway, NLB) và subnet private `/19`
  mỗi AZ. Node EKS, pod (VPC CNI cấp IP pod từ subnet của node) và RDS nằm chung subnet private; [0053](0053-msk-elasticache-valkey.md) §2, §7 đặt
  thêm broker MSK và ElastiCache vào cùng subnet đó.
- Route table private có `0.0.0.0/0` tới NAT gateway, nên tầng dữ liệu đi ra Internet được, dù không dịch vụ dữ liệu nào cần.
- `cluster.dbCidrs` (egress 5432, 9096, 6379 trong NetworkPolicy của pod, phụ lục 0034 §7) là cả subnet private: luật egress "tới database" mở cổng
  đó tới mọi node và mọi pod của VPC, không chỉ tới database.
- Chưa buổi AWS nào dựng VPC hay RDS: đổi subnet bây giờ không đụng tài nguyên thật nào.

## Yếu tố quyết định

- Chuẩn ngành: tách tầng mạng, tầng dữ liệu ở subnet riêng không có đường ra Internet (AWS Well-Architected SEC05-BP01 [N1]).
- `dbCidrs` chỉ gồm địa chỉ của tầng dữ liệu.
- Một bộ code cho stg và prd, theo `az_count`; dải private, public đã có không đổi.
- Dùng thứ module `terraform-aws-modules/vpc` đã ghim có sẵn, không tự viết route table.

## Phương án đã cân nhắc

In đậm là lựa chọn.

- Giữ hai tầng: không đổi gì; tầng dữ liệu đi ra được qua NAT, `dbCidrs` rộng bằng subnet của node.
- **`database_subnets` của module `vpc` 6.7.3 [N2]**: subnet có route table riêng khi `create_database_subnet_route_table = true` (mặc định `false` gắn
  subnet vào route table private, có route tới NAT), route NAT và Internet Gateway đều tắt mặc định; một tầng cho cả RDS, MSK, ElastiCache vì cả ba cùng
  mô hình security group và cùng một danh sách `dbCidrs` (module còn có `elasticache_subnets`, `redshift_subnets` riêng từng engine: thêm subnet mà không
  thêm gì cho bảo mật).
- `intra_subnets`: cũng không route ra Internet, nhưng là tầng chung cho thứ không cần mạng ngoài; tên không nói đây là tầng dữ liệu, không có cờ
  route và subnet group của tầng database.

## Kết quả quyết định

Chọn `database_subnets` của module `vpc`: đạt tầng dữ liệu không đường ra Internet bằng thứ module đã ghim có sẵn. Cái giá: thêm route table (một ở stg,
một mỗi AZ ở prd) và bộ test giữ cờ route.

- **Ba tầng:** public (NAT, NLB), private (node, pod EKS, bastion SSM), database (RDS, MSK, ElastiCache), mỗi AZ một subnet mỗi tầng.
- **Địa chỉ:** dải VPC chia 8 khối; khối 0–5 private, khối 7 public như 0034; khối 6 (đã để dành) chia tiếp 8 phần, mỗi AZ một subnet database
  (`/22` với VPC `/16`: `10.0.192.0/22`, `10.0.196.0/22`, `10.0.200.0/22`). Chia 8 phần để đủ chỗ cho `az_count` tối đa 6.
- **Route:** route table database chỉ có route `local` của VPC: `create_database_subnet_route_table = true`, `create_database_nat_gateway_route = false`,
  `create_database_internet_gateway_route = false`. Một route table với stg (một NAT), mỗi AZ một với prd.
- **Subnet group:** module `network` không tạo DB subnet group (`create_database_subnet_group = false`): module `rds` tạo của nó (cần subnet ở ít
  nhất hai AZ [N3]), MSK nhận thẳng danh sách subnet, mỗi subnet một AZ khác nhau [N4], module `elasticache` tạo subnet group của ElastiCache.
- **Không tag** `kubernetes.io/*` trên subnet database: AWS Load Balancer Controller không đặt load balancer ở đó.
- **Hợp đồng:** module `network` xuất `database_subnet_ids`, `database_subnet_cidrs`; root env đặt RDS, MSK, ElastiCache vào `database_subnet_ids`,
  `cluster.dbCidrs` = `database_subnet_cidrs` (thay `private_subnet_cidrs`).

### Hệ quả

- Tốt: tầng dữ liệu không đi ra Internet kể cả qua NAT; egress 5432, 9096, 6379 của pod chỉ tới subnet database, không tới node, pod khác; route
  table, subnet không tính tiền.
- Xấu: thêm `az_count` subnet và route table (một ở stg, `az_count` ở prd) mỗi env; ID route table chỉ biết sau apply nên test của module giữ cờ route qua local
  `database_routes`, không đọc được chính route table lúc plan.
- Xem lại khi: một dịch vụ của tầng dữ liệu cần gọi ra ngoài VPC (khi đó thêm VPC endpoint, không mở NAT); cần NACL riêng cho tầng dữ liệu.

## Xác nhận

- Lúc quyết: `make test DIRS=aws/modules/network` của `svp-infra` (mock provider, plan): số subnet database bằng `az_count`, dải nằm trong khối 6, dải
  private, public không đổi, route table riêng, không route NAT, Internet Gateway, IPv6 egress, không tag `kubernetes.io/*`, không DB subnet group;
  đổi `own_route_table` về `false` hay bật route NAT làm test đỏ.
- Buổi stg: route table của subnet database chỉ có route `local`; ENI của RDS, MSK, ElastiCache nằm ở subnet database; service nối được cả ba qua
  NetworkPolicy với `dbCidrs` mới. Kết quả có ngày ghi vào mục này.

## Hiện thực ở

- `svp-infra`: `aws/modules/network/` (subnet, route table, output, test); `aws/envs/stg/`, `aws/envs/prd/` (RDS, MSK, ElastiCache vào
  `database_subnet_ids`; `cluster_values.dbCidrs` từ `database_subnet_cidrs`).

## Nguồn

Đọc 2026-11-08.

- [N1] AWS Well-Architected, SEC05-BP01 Create network layers: <https://docs.aws.amazon.com/wellarchitected/latest/security-pillar/sec_network_protection_create_layers.html>
- [N2] `terraform-aws-modules/vpc` 6.7.3: <https://registry.terraform.io/modules/terraform-aws-modules/vpc/aws/6.7.3>; mã ở
  <https://github.com/terraform-aws-modules/terraform-aws-vpc/blob/v6.7.3/main.tf> (`aws_route_table.database`, `aws_route_table_association.database`,
  `aws_route.database_nat_gateway`, `aws_route.database_internet_gateway`)
- [N3] RDS trong VPC, subnet group cần subnet ở ít nhất hai AZ: <https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/USER_VPC.Scenarios.html>
- [N4] MSK provisioned, mỗi subnet một AZ khác nhau: <https://docs.aws.amazon.com/msk/latest/developerguide/msk-create-cluster.html>
