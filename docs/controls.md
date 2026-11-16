# Controls evidence

| Control | Evidence |
| --- | --- |
| Private subnets with no internet route | `aws ec2 describe-route-tables` on payments-private shows only `10.30.0.0/16 local` |
| Security groups allow only named sources | Terraform `security_groups.tf`: internet to load balancer on 80, load balancer to app on 8000, app to database on 5432 |
| Database encrypted with a customer-managed key | `aws rds describe-db-instances`: StorageEncrypted `True`, PostgreSQL 16.13 |
| Database not public | Same command: PubliclyAccessible `False`; it sits in data subnets with no internet route |
| TLS enforced on every connection | `aws rds describe-db-parameters`: `rds.force_ssl 1` |
| Database password managed and rotated by AWS | `aws secretsmanager describe-secret`: name `rds!db-...`, encrypted with the project KMS key, RotationEnabled `True` |
| Backups for point-in-time restore | BackupRetentionPeriod `7` days |
| Registry tags immutable, images scanned on push | `aws ecr describe-repositories`: `IMMUTABLE True` |
