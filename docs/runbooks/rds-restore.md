# Khôi phục RDS `svp-<env>` về một thời điểm (stg, prd)

- Quy trình làm tay, không có cảnh báo riêng; chỉ AWS. Postgres của k3d theo [postgres-restore.md](postgres-restore.md);
  compose không có backup. Thiết kế, mục tiêu RTO/RPO và nguồn: [ADR-0067](../adr/0067-backup-dr.md); giải thích:
  [`backup-dr.md`](../explanation/backup-dr.md).
- **Người học chạy mọi lệnh.** Lệnh AWS chạy ở bản clone `svp-infra` (cho `aws/scripts/check-account.sh`), với biến
  account của `$ENV` (`SVP_AWS_STG_ACCOUNT_ID` hay `SVP_AWS_PRD_ACCOUNT_ID`) đã export, không ghi vào file nào. Mỗi lệnh
  ghi nối sau `aws/scripts/check-account.sh "$ENV"` bằng `&&`: account của profile khác biến thì script thoát khác 0 và
  lệnh ghi không chạy.
- Lệnh `kubectl` tới cluster của `$ENV` cần tunnel tới API đang mở (output `api_tunnel_command` của `aws/envs/<env>`) và
  kubeconfig context `svp-$ENV` của buổi. Đọc database chỉ qua `svp-pg` của Deployment `svp-ops`; không `psql` từ máy
  tới RDS.

```sh
ENV=stg
N=svp-$ENV
```

## Ý nghĩa và tác động tới người dùng

Mở trang này khi dữ liệu của instance `svp-$ENV` sai và cần lấy lại trạng thái trước một thời điểm: xoá hay ghi nhầm,
migration hỏng dữ liệu, ứng dụng ghi sai hàng loạt. Người dùng thấy dữ liệu sai (video mất, đếm lệch, feed thiếu) hay
lỗi 5xx khi dữ liệu hỏng làm service lỗi.

PITR của RDS không ghi đè instance đang chạy: nó dựng instance mới từ backup tự động, nên instance nguồn và ứng dụng
chạy nguyên trong lúc khôi phục. Mọi thứ ghi sau thời điểm chọn không có trong bản khôi phục, kể cả dữ liệu đúng. Mất cả
account env thì không có PITR (backup tự động nằm trong account đó): bản còn lại là bản copy ở vault `svp-$ENV-copy` của
account `svp-backup` (bước 5).

## Kiểm tra nhanh (5 phút)

Compose, k3d: không có (k3d: [postgres-restore.md](postgres-restore.md)).

AWS:

```sh
# 1. Source state and the end of the PITR window (LatestRestorableTime lags real time by up to five minutes)
AWS_PROFILE=anhnv-$ENV aws rds describe-db-instances --db-instance-identifier "$N" --query 'DBInstances[0].[DBInstanceStatus,LatestRestorableTime,BackupRetentionPeriod]' --output text --region ap-southeast-1
# 2. The whole PITR window, still readable when the instance is gone and its automated backups were kept
AWS_PROFILE=anhnv-$ENV aws rds describe-db-instance-automated-backups --db-instance-identifier "$N" --query 'DBInstanceAutomatedBackups[].[Status,DbiResourceId,RestoreWindow.EarliestTime,RestoreWindow.LatestTime]' --output text --region ap-southeast-1
# 3. Snapshots of AWS Backup in the env vault, and their copies in account svp-backup (read-only profile)
AWS_PROFILE=anhnv-$ENV aws backup list-recovery-points-by-backup-vault --backup-vault-name "$N" --by-resource-type RDS --query 'RecoveryPoints[].[CreationDate,Status,RecoveryPointArn]' --output text --region ap-southeast-1
AWS_PROFILE=anhnv-backup-ro aws backup list-recovery-points-by-backup-vault --backup-vault-name "$N-copy" --by-resource-type RDS --query 'RecoveryPoints[].[CreationDate,Status,RecoveryPointArn]' --output text --region ap-southeast-1
# 4. Backup and copy jobs that failed in the last day (alarms svp-<env>-backup-job-failed, -backup-copy-failed)
AWS_PROFILE=anhnv-$ENV aws backup list-backup-jobs --by-state FAILED --by-created-after "$(date -u -v-24H +%FT%TZ)" --query 'BackupJobs[].[CreationDate,ResourceArn,StatusMessage]' --output text --region ap-southeast-1
AWS_PROFILE=anhnv-$ENV aws backup list-copy-jobs --by-state FAILED --by-created-after "$(date -u -v-24H +%FT%TZ)" --query 'CopyJobs[].[CreationDate,ResourceArn,StatusMessage]' --output text --region ap-southeast-1
```

Đọc: thời điểm cần quay về phải nằm giữa `EarliestTime` và `LatestTime` của bước 2; ngoài cửa sổ đó chỉ còn snapshot
hằng ngày (bước 3). Thời điểm của thao tác sai lấy từ log ứng dụng (CloudWatch Logs, Grafana) hay đọc dữ liệu hiện tại
qua `svp-pg`, ví dụ:

```sh
AWS_PROFILE=anhnv-$ENV kubectl --context "svp-$ENV" -n svp-data exec deploy/svp-ops -c postgres -- /opt/svp/bin/svp-pg video -c 'SELECT status, count(*), max(created_at) FROM videos GROUP BY status'
```

`svp-pg` nhận `video`, `engagement` hay `feed`, đăng nhập role app của service đó, phiên chỉ đọc. `svp_user` và
`svp_glitchtip` không đọc được qua nó.

## Nguyên nhân thường gặp

1. **Thao tác sai trên dữ liệu**: lệnh tay, script, migration lỗi. Dấu hiệu: số hàng hay trạng thái đổi đột ngột ở một
   thời điểm (bước SQL trên), log của migrate Job hay của service quanh thời điểm đó.
2. **Lỗi ứng dụng ghi sai**: bản phát hành mới ghi dữ liệu sai từ lúc deploy. Dấu hiệu: thời điểm khớp lần sync của Argo
   CD.
3. **Mất account env** (bị chiếm, instance và backup tự động bị xoá): bước 1 và 2 không trả gì, bước 3 bằng
   `anhnv-backup-ro` còn bản copy.

## Giảm thiểu

- Ghi lại thời điểm phát hiện và thời điểm của thao tác sai (UTC) cho postmortem.
- Không xoá, không sửa instance nguồn, không chạm vault: PITR cần backup tự động của nguồn, và instance nguồn giữ dữ
  liệu ghi sau thời điểm sai mà bản khôi phục không có.
- Nguyên nhân 2: rollback bản phát hành (PR vào `svp-gitops`, [svp-gitops-setup.md](svp-gitops-setup.md)) để dừng ghi
  sai trước khi khôi phục.

## Khôi phục và xác nhận

### 1. Dựng bản khôi phục `svp-$ENV-pitr`

`T` là thời điểm ngay trước thao tác sai, UTC RFC 3339, trong cửa sổ ở bước 2 của Kiểm tra nhanh. Bản khôi phục dùng
cùng subnet group, security group, parameter group và lớp với nguồn, một AZ, không public; khoá KMS là khoá RDS của
nguồn. Tên `svp-$ENV-pitr` là tên mà `restore-drill.sh <env> cleanup` và `sweep.sh` biết: instance còn sót cuối buổi
được xoá hay báo.

```sh
T=2026-01-01T00:00:00Z
read -r SUBNETS PARAMS CLASS SGS < <(AWS_PROFILE=anhnv-$ENV aws rds describe-db-instances --db-instance-identifier "$N" --query 'DBInstances[0].[DBSubnetGroup.DBSubnetGroupName,DBParameterGroups[0].DBParameterGroupName,DBInstanceClass,join(` `,VpcSecurityGroups[].VpcSecurityGroupId)]' --output text --region ap-southeast-1)
echo "$SUBNETS $PARAMS $CLASS $SGS"
# SGS is one word per security group.
aws/scripts/check-account.sh "$ENV" &&
  AWS_PROFILE=anhnv-$ENV aws rds restore-db-instance-to-point-in-time --source-db-instance-identifier "$N" --target-db-instance-identifier "$N-pitr" --restore-time "$T" --db-subnet-group-name "$SUBNETS" --vpc-security-group-ids $SGS --db-parameter-group-name "$PARAMS" --db-instance-class "$CLASS" --no-multi-az --no-publicly-accessible --no-deletion-protection --tags Key=Project,Value=svp "Key=Stack,Value=$ENV" --region ap-southeast-1
AWS_PROFILE=anhnv-$ENV aws rds wait db-instance-available --db-instance-identifier "$N-pitr" --region ap-southeast-1
```

Instance nguồn đã mất nhưng còn backup tự động (bước 2 trả `retained`; prd giữ, stg xoá cùng instance): thay
`--source-db-instance-identifier "$N"` bằng `--source-dbi-resource-id <DbiResourceId của bước 2>`, và đọc ba tên mà
module `rds` đặt bằng tiền tố (`svp-$ENV-`, `svp-$ENV-pg<major>-`, `svp-$ENV-db-`) thay cho lệnh `read` ở trên; lớp
instance là `rds_instance_class` của `<env>.tfvars`:

```sh
AWS_PROFILE=anhnv-$ENV aws rds describe-db-subnet-groups --query "DBSubnetGroups[?starts_with(DBSubnetGroupName, '$N-')].DBSubnetGroupName" --output text --region ap-southeast-1
AWS_PROFILE=anhnv-$ENV aws rds describe-db-parameter-groups --query "DBParameterGroups[?starts_with(DBParameterGroupName, '$N-pg')].DBParameterGroupName" --output text --region ap-southeast-1
AWS_PROFILE=anhnv-$ENV aws ec2 describe-security-groups --filters "Name=group-name,Values=$N-db-*" --query 'SecurityGroups[].GroupId' --output text --region ap-southeast-1
```

### 2. Kiểm bản khôi phục

```sh
H=$(AWS_PROFILE=anhnv-$ENV aws rds describe-db-instances --db-instance-identifier "$N-pitr" --query 'DBInstances[0].Endpoint.Address' --output text --region ap-southeast-1)
AWS_PROFILE=anhnv-$ENV kubectl --context "svp-$ENV" -n svp-data exec deploy/svp-ops -c postgres -- /opt/svp/bin/svp-pg video --host "$H" -c 'SELECT status, count(*), max(created_at) FROM videos GROUP BY status'
```

Cùng câu SQL không có `--host` đọc nguồn. Bản khôi phục đúng khi dữ liệu bị sai có ở đó với giá trị trước thao tác sai,
và không có thay đổi nào sau `T`. Cert của bản khôi phục mang tên endpoint của nó và ký bằng cùng CA, nên `verify-full`
qua được; lỗi TLS nghĩa là `H` sai. Câu digest mỗi bảng mà diễn tập dùng (`restore-drill.sh`, mục Kiểm dữ liệu của
[`backup-dr.md`](../explanation/backup-dr.md)) so được toàn bộ nội dung khi nguồn không ghi gì kể từ `T`.

### 3. Đưa bản khôi phục thay chỗ nguồn

Ứng dụng đọc địa chỉ Postgres từ hợp đồng `cluster.rdsAddress`: output `cluster_values` của root `aws/envs/<env>`
(`module.rds.address`, tức endpoint của instance `svp-<env>` trong state) → root `aws/gitops/<env>` →
`postgres.external.host` của `svp-data` và `externalSecrets.postgres` (`DATABASE_URL` của mọi service) của `svp-cluster`
([`eks.md`](../reference/eks.md)). Vì vậy dữ liệu khôi phục tới được ứng dụng khi nó mang đúng tên `svp-$ENV`: đổi tên
nguồn thành `svp-$ENV-old`, rồi khôi phục lần nữa thẳng ra tên `svp-$ENV`. Endpoint, `rdsAddress` và tên trong cert giữ
nguyên, cluster và root gitops không sửa gì. Cái giá: từ lúc đổi tên tới khi bản mới `available`, endpoint không có
instance nào và service lỗi kết nối (tính vào RTO); mọi thứ ghi vào nguồn sau `T` chỉ còn ở `svp-$ENV-old`.

Đường PITR làm bước này khi bước 2 đã chứng minh `T` đúng. Bản mới cùng subnet group, security group, parameter group,
lớp và Multi-AZ với nguồn (biến của bước 1), và để RDS quản mật khẩu master trong Secrets Manager, mã hoá bằng khoá RDS
của nguồn, như module `rds` (`manage_master_user_password`). Secret đó là secret mới với ARN mới, nên output
`rds_master_user_secret_arn` đổi.

```sh
read -r KEY MULTIAZ < <(AWS_PROFILE=anhnv-$ENV aws rds describe-db-instances --db-instance-identifier "$N" --query 'DBInstances[0].[KmsKeyId,MultiAZ]' --output text --region ap-southeast-1)
MAZ=--no-multi-az; [ "$MULTIAZ" = True ] && MAZ=--multi-az
echo "$KEY $MAZ"
# Free the name: the source keeps its automated backups under the new name.
aws/scripts/check-account.sh "$ENV" &&
  AWS_PROFILE=anhnv-$ENV aws rds modify-db-instance --db-instance-identifier "$N" --new-db-instance-identifier "$N-old" --apply-immediately --region ap-southeast-1
until AWS_PROFILE=anhnv-$ENV aws rds wait db-instance-available --db-instance-identifier "$N-old" --region ap-southeast-1; do sleep 30; done
# The daily plan selects by this tag: the old instance must not be backed up and copied into the locked vault.
OLD_ARN=$(AWS_PROFILE=anhnv-$ENV aws rds describe-db-instances --db-instance-identifier "$N-old" --query 'DBInstances[0].DBInstanceArn' --output text --region ap-southeast-1)
aws/scripts/check-account.sh "$ENV" &&
  AWS_PROFILE=anhnv-$ENV aws rds remove-tags-from-resource --resource-name "$OLD_ARN" --tag-keys Backup --region ap-southeast-1
aws/scripts/check-account.sh "$ENV" &&
  AWS_PROFILE=anhnv-$ENV aws rds restore-db-instance-to-point-in-time --source-db-instance-identifier "$N-old" --target-db-instance-identifier "$N" --restore-time "$T" --db-subnet-group-name "$SUBNETS" --vpc-security-group-ids $SGS --db-parameter-group-name "$PARAMS" --db-instance-class "$CLASS" $MAZ --no-publicly-accessible --manage-master-user-password --master-user-secret-kms-key-id "$KEY" --region ap-southeast-1
AWS_PROFILE=anhnv-$ENV aws rds wait db-instance-available --db-instance-identifier "$N" --region ap-southeast-1
```

Khôi phục từ snapshot (bước 5) thay lệnh `restore-db-instance-to-point-in-time` bằng:

```sh
aws/scripts/check-account.sh "$ENV" &&
  AWS_PROFILE=anhnv-$ENV aws rds restore-db-instance-from-db-snapshot --db-snapshot-identifier "$N-restore" --db-instance-identifier "$N" --db-subnet-group-name "$SUBNETS" --vpc-security-group-ids $SGS --db-parameter-group-name "$PARAMS" --db-instance-class "$CLASS" $MAZ --no-publicly-accessible --manage-master-user-password --master-user-secret-kms-key-id "$KEY" --region ap-southeast-1
```

State của root env vẫn giữ instance cũ (provider giữ `aws_db_instance` theo resource id, đi theo `svp-$ENV-old`). Gỡ địa
chỉ đó khỏi state, nhập instance mới vào, rồi plan; `tf.sh` kiểm account và đặt biến của root như mọi thao tác khác,
trên root đã `init` trong buổi (README của `svp-infra`, mục `tf.sh`):

```sh
aws/scripts/tf.sh "$ENV" env state-rm module.rds.aws_db_instance.this
aws/scripts/tf.sh "$ENV" env import module.rds.aws_db_instance.this "$N"
aws/scripts/tf.sh "$ENV" env plan
```

Đọc plan: `module.rds.aws_db_instance.this` chỉ `updated in-place` (tag, `copy_tags_to_snapshot`, monitoring, deletion
protection, `skip_final_snapshot`, `delete_automated_backups` mà bản khôi phục không mang theo); không dòng `must be
replaced` hay `destroy` nào. Khác thì không apply: xem Leo thang. Đúng thì apply, rồi ghi lại secret của cluster từ mật
khẩu master mới: `bootstrap.sh` đọc nó qua `rds_master_user_secret_arn` và chạy lượt đổi secret của `make eks-secrets`
(hook `pg-bootstrap` đặt lại mật khẩu role, Reloader restart workload; [`eks.md`](../reference/eks.md), mục "Đổi secret
của env đang chạy"):

```sh
aws/scripts/tf.sh "$ENV" env apply
aws/scripts/bootstrap.sh "$ENV" secrets
AWS_PROFILE=anhnv-$ENV kubectl --context "svp-$ENV" -n svp-data exec deploy/svp-ops -c postgres -- /opt/svp/bin/svp-pg video -c 'SELECT status, count(*), max(created_at) FROM videos GROUP BY status'
```

Câu SQL cuối (không `--host`) giờ đọc instance mới: đường PITR phải ra như bước 2 trên `svp-$ENV-pitr`.

### 4. Xoá bản khôi phục khi xong

`svp-$ENV-pitr` xoá ngay khi bước 2 xong. `svp-$ENV-old` (và snapshot `svp-$ENV-restore` của bước 5), nếu có, chỉ xoá
khi dữ liệu của bản mới đã kiểm và không cần lấy lại gì ghi sau `T` từ nguồn cũ; prd bật deletion protection nên tắt nó
trước.

```sh
aws/scripts/check-account.sh "$ENV" &&
  AWS_PROFILE=anhnv-$ENV aws rds delete-db-instance --db-instance-identifier "$N-pitr" --skip-final-snapshot --delete-automated-backups --region ap-southeast-1
AWS_PROFILE=anhnv-$ENV aws rds wait db-instance-deleted --db-instance-identifier "$N-pitr" --region ap-southeast-1
aws/scripts/check-account.sh "$ENV" &&
  AWS_PROFILE=anhnv-$ENV aws rds modify-db-instance --db-instance-identifier "$N-old" --no-deletion-protection --apply-immediately --region ap-southeast-1
aws/scripts/check-account.sh "$ENV" &&
  AWS_PROFILE=anhnv-$ENV aws rds delete-db-instance --db-instance-identifier "$N-old" --skip-final-snapshot --delete-automated-backups --region ap-southeast-1
aws/scripts/check-account.sh "$ENV" &&
  AWS_PROFILE=anhnv-$ENV aws rds delete-db-snapshot --db-snapshot-identifier "$N-restore" --region ap-southeast-1
```

### 5. Khôi phục từ vault copy

Dùng khi mất account env, hay khi bản cần chỉ còn ở `svp-$ENV-copy` (bước 3 của Kiểm tra nhanh). AWS Backup không
restore chéo account: bản copy được copy ngược về vault `svp-$ENV` rồi khôi phục ở account env. Quyền cho việc đó không
có sẵn (account env không chạm được bản copy, ADR-0067 §5): bước này thêm chúng, chạy copy, rồi gỡ ngay. Cần trước:
account env đã về tay người học (hay dựng lại), root `aws/accounts/<env>` đã apply (vault `svp-$ENV`, role
`svp-$ENV-backup`), và root `aws/envs/<env>` của buổi đã apply (khoá `alias/svp-$ENV-rds`, instance `svp-$ENV` mà
bước 3 thay chỗ).

Account `svp-backup` không có profile ghi. Đường vào là break-glass từ management: `anhnv-sso` assume
`OrganizationAccountAccessRole` của account backup, đường mà các root qua role dùng. Hàm `in_backup` chạy một lệnh với
credential tạm đó trong subshell riêng (không ghi file, không profile mới, mất khi lệnh xong) và dừng khi account không
phải `SVP_AWS_BACKUP_ACCOUNT_ID`; lệnh ghi qua nó nối sau `aws/scripts/check-account.sh mgmt`. IAM ở `us-east-1`.

```sh
ACCOUNT=$(AWS_PROFILE=anhnv-$ENV aws sts get-caller-identity --query Account --output text --region ap-southeast-1)
COPY_ROLE=svp-backup-restore-copy
D=$(mktemp -d)
in_backup() (
  read -r AK SK ST < <(AWS_PROFILE=anhnv-sso aws sts assume-role --role-arn "arn:aws:iam::$SVP_AWS_BACKUP_ACCOUNT_ID:role/OrganizationAccountAccessRole" --role-session-name svp-restore-copy --query 'Credentials.[AccessKeyId,SecretAccessKey,SessionToken]' --output text --region ap-southeast-1)
  export AWS_ACCESS_KEY_ID=$AK AWS_SECRET_ACCESS_KEY=$SK AWS_SESSION_TOKEN=$ST
  unset AWS_PROFILE
  [ "$(aws sts get-caller-identity --query Account --output text --region ap-southeast-1)" = "$SVP_AWS_BACKUP_ACCOUNT_ID" ] || { echo "not account svp-backup" >&2; exit 1; }
  "$@"
)
```

**5a. Thêm quyền.** Ba thứ, mỗi thứ là ảnh gương của chiều env → backup: vault access policy của `svp-$ENV` nhận
`backup:CopyIntoBackupVault` từ account backup (như vault copy, phụ lục ADR-0067 §5); key `alias/svp-backup-copy` thêm
hai statement cho account env, cùng action và điều kiện với statement cho account backup trên key RDS (ADR-0067 §6:
`CreateGrant` chỉ khi `kms:GrantIsForAWSResource`). Không theo khuôn key vault env (thêm `kms:ViaService` `backup.*`):
key này mã hoá cả bản copy RDS, mà RDS chép snapshot bằng grant của chính nó, không qua AWS Backup; điều kiện của key
RDS phủ cả bản copy S3. Thứ ba là role `svp-backup-restore-copy` cho copy job ở account backup, trust
`backup.amazonaws.com` của chính account đó, gắn hai managed policy backup của role `svp-<env>-backup` (ADR-0067 §7).

```sh
jq -n --arg p "arn:aws:iam::$SVP_AWS_BACKUP_ACCOUNT_ID:root" '{Version: "2012-10-17", Statement: [{Sid: "CopyFromBackupAccount", Effect: "Allow", Principal: {AWS: $p}, Action: "backup:CopyIntoBackupVault", Resource: "*"}]}' >"$D/vault-policy.json"
aws/scripts/check-account.sh "$ENV" &&
  AWS_PROFILE=anhnv-$ENV aws backup put-backup-vault-access-policy --backup-vault-name "$N" --policy "file://$D/vault-policy.json" --region ap-southeast-1
KEYID=$(in_backup aws kms describe-key --key-id alias/svp-backup-copy --query KeyMetadata.KeyId --output text --region ap-southeast-1)
in_backup aws kms get-key-policy --key-id "$KEYID" --policy-name default --query Policy --output text --region ap-southeast-1 >"$D/key-policy.json"
jq --arg p "arn:aws:iam::$ACCOUNT:root" '.Statement += [{Sid: "EnvAccountUseForRestoreCopy", Effect: "Allow", Principal: {AWS: $p}, Action: ["kms:Decrypt", "kms:DescribeKey", "kms:GenerateDataKey"], Resource: "*"}, {Sid: "EnvAccountGrantForRestoreCopy", Effect: "Allow", Principal: {AWS: $p}, Action: "kms:CreateGrant", Resource: "*", Condition: {Bool: {"kms:GrantIsForAWSResource": "true"}}}]' "$D/key-policy.json" >"$D/key-policy-restore.json"
aws/scripts/check-account.sh mgmt &&
  in_backup aws kms put-key-policy --key-id "$KEYID" --policy-name default --policy "file://$D/key-policy-restore.json" --region ap-southeast-1
jq -n --arg a "$SVP_AWS_BACKUP_ACCOUNT_ID" '{Version: "2012-10-17", Statement: [{Effect: "Allow", Principal: {Service: "backup.amazonaws.com"}, Action: "sts:AssumeRole", Condition: {StringEquals: {"aws:SourceAccount": $a}}}]}' >"$D/copy-trust.json"
aws/scripts/check-account.sh mgmt &&
  in_backup aws iam create-role --role-name "$COPY_ROLE" --assume-role-policy-document "file://$D/copy-trust.json" --region us-east-1
for p in AWSBackupServiceRolePolicyForBackup AWSBackupServiceRolePolicyForS3Backup; do
  arn=$(in_backup aws iam list-policies --scope AWS --query "Policies[?PolicyName=='$p'].Arn" --output text --region us-east-1)
  aws/scripts/check-account.sh mgmt && in_backup aws iam attach-role-policy --role-name "$COPY_ROLE" --policy-arn "$arn" --region us-east-1
done
```

**5b. Copy ngược.** `RP` là `RecoveryPointArn` của `svp-$ENV-copy` (bước 3 của Kiểm tra nhanh, `--by-resource-type RDS`
hay `S3`), mới nhất trước thời điểm sự cố. Bản copy về vault `svp-$ENV` được mã hoá lại bằng key của vault đó.

```sh
RP='<RecoveryPointArn in svp-$ENV-copy>'
aws/scripts/check-account.sh mgmt &&
  JOB=$(in_backup aws backup start-copy-job --recovery-point-arn "$RP" --source-backup-vault-name "$N-copy" --destination-backup-vault-arn "arn:aws:backup:ap-southeast-1:$ACCOUNT:backup-vault:$N" --iam-role-arn "arn:aws:iam::$SVP_AWS_BACKUP_ACCOUNT_ID:role/$COPY_ROLE" --query CopyJobId --output text --region ap-southeast-1)
until S=$(AWS_PROFILE=anhnv-backup-ro aws backup describe-copy-job --copy-job-id "$JOB" --query CopyJob.State --output text --region ap-southeast-1) && [ "$S" != CREATED ] && [ "$S" != RUNNING ]; do sleep 60; done; echo "$S"
AWS_PROFILE=anhnv-backup-ro aws backup describe-copy-job --copy-job-id "$JOB" --query 'CopyJob.[State,StatusMessage,DestinationRecoveryPointArn]' --output text --region ap-southeast-1
```

`S` phải là `COMPLETED`; `DestinationRecoveryPointArn` là recovery point mới trong `svp-$ENV`. Lỗi `AccessDenied` của
job nghĩa là một trong ba quyền của 5a chưa đúng: đọc `StatusMessage`, sửa, chạy lại 5b.

**5c. Gỡ quyền** ngay khi copy xong, kể cả khi job lỗi và dừng ở đây. Vault access policy của `svp-$ENV` và role không
có trong Terraform nên xoá bằng lệnh; key policy về lại như code bằng plan và apply root `aws/backup` theo các lệnh của
README đó (mục "Apply lần đầu", bước 2 và 3), plan phải là `0 to add, 1 to change, 0 to destroy`, chỉ `policy` của
`aws_kms_key.copy`.

```sh
aws/scripts/check-account.sh "$ENV" &&
  AWS_PROFILE=anhnv-$ENV aws backup delete-backup-vault-access-policy --backup-vault-name "$N" --region ap-southeast-1
for p in AWSBackupServiceRolePolicyForBackup AWSBackupServiceRolePolicyForS3Backup; do
  arn=$(in_backup aws iam list-policies --scope AWS --query "Policies[?PolicyName=='$p'].Arn" --output text --region us-east-1)
  aws/scripts/check-account.sh mgmt && in_backup aws iam detach-role-policy --role-name "$COPY_ROLE" --policy-arn "$arn" --region us-east-1
done
aws/scripts/check-account.sh mgmt && in_backup aws iam delete-role --role-name "$COPY_ROLE" --region us-east-1
rm -r "$D"
```

**5d. Khôi phục RDS.** Recovery point RDS là snapshot mã hoá bằng key của vault `svp-$ENV`, mà khôi phục từ snapshot giữ
nguyên khoá của nó; module `rds` giữ instance trên khoá `alias/svp-$ENV-rds`, nên import một instance khoá khác thì plan
đòi thay (xoá) nó. Vì vậy chép snapshot sang khoá RDS trước, rồi làm bước 3 với lệnh khôi phục từ snapshot (biến
`SUBNETS`… đọc bằng lệnh `read` của bước 1 trên `$N`). Object S3 thì làm theo [s3-restore.md](s3-restore.md) với
recovery point mới.

```sh
RP_ENV='<DestinationRecoveryPointArn from 5b>'
aws/scripts/check-account.sh "$ENV" &&
  AWS_PROFILE=anhnv-$ENV aws rds copy-db-snapshot --source-db-snapshot-identifier "$RP_ENV" --target-db-snapshot-identifier "$N-restore" --kms-key-id "alias/$N-rds" --region ap-southeast-1
AWS_PROFILE=anhnv-$ENV aws rds wait db-snapshot-available --db-snapshot-identifier "$N-restore" --region ap-southeast-1
```

Recovery point vừa copy về `svp-$ENV` (RDS hay S3) không có bản copy nào trong `svp-$ENV-copy`, nên
`restore-drill.sh <env> cleanup` cuối buổi giữ nó và thoát lỗi: không ghi `backup-drained`, và
`tf.sh <env> env plan --destroy` bị từ chối. Xoá nó bằng tay khi dữ liệu khôi phục đã kiểm (cuối bước 3 với RDS,
mục Xác nhận của [s3-restore.md](s3-restore.md) với S3):

```sh
aws/scripts/check-account.sh "$ENV" &&
  AWS_PROFILE=anhnv-$ENV aws backup delete-recovery-point --backup-vault-name "$N" --recovery-point-arn '<DestinationRecoveryPointArn from 5b>' --region ap-southeast-1
```

## Leo thang

- Bước 3, plan sau `import` có `must be replaced` hay `destroy` cho `module.rds.aws_db_instance.this`: không apply.
  Instance đang chạy là bản khôi phục, apply sẽ xoá nó. Giữ cả `svp-$ENV` lẫn `svp-$ENV-old`, dán plan cho postmortem.
- Bước 3 lỗi giữa chừng (đổi tên xong, restore lỗi): đổi tên `svp-$ENV-old` về `svp-$ENV` bằng cùng lệnh
  `modify-db-instance --new-db-instance-identifier`, gắn lại tag vừa gỡ (`add-tags-to-resource --tags
  Key=Backup,Value=daily`), ứng dụng chạy lại trên nguồn; state chưa đổi nên không cần `tf.sh`.
- Bước 5: không xoá gì ở `svp-backup`, không gỡ vault lock. Job copy `FAILED` hai lần thì gỡ quyền (5c), mở case với AWS
  Support và postmortem ([mẫu](../postmortems/README.md)).
- Restore lỗi (lệnh restore từ chối, instance `failed`): đọc sự kiện của instance (`$N-pitr`, hay `$N` ở bước 3) trong
  hai giờ qua, hai lần lỗi thì mở case với AWS Support.

  ```sh
  AWS_PROFILE=anhnv-$ENV aws rds describe-events --source-identifier "$N-pitr" --source-type db-instance --duration 120 --region ap-southeast-1
  ```

## Liên kết

- ADR: [ADR-0067](../adr/0067-backup-dr.md) §2 (mục tiêu), §5–§7 (vault copy, khoá, role), §9 (diễn tập PITR, kiểm
  dữ liệu);
  [ADR-0057](../adr/0057-postgres17-verify-full.md) (TLS `verify-full`, CA của RDS); threat model BAK-3.
- Cấu hình: module `rds` (`backup_retention_period`, khoá KMS), root `aws/envs/<env>`, `aws/accounts/<env>`,
  `aws/backup` và `aws/scripts/tf.sh`, `bootstrap.sh` của `svp-infra`;
  `deploy/ops/svp-pg`, `deploy/helm/svp-data/templates/svp-ops.yaml`.
- Diễn tập tái hiện: `aws/scripts/restore-drill.sh <env> rds` của `svp-infra` trong buổi stg, prd (PITR ra
  `svp-<env>-pitr`, so digest, đo RTO, RPO, xoá); số đo ở phụ lục ADR-0067. Thay chỗ (bước 3) và khôi phục từ vault copy
  (bước 5) không có diễn tập.
