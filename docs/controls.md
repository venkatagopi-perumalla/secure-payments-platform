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
| Build user can only push to one registry | IAM policy `push-payments-api-image` on `payments-github-ci`; identity-check run prints `user/payments-github-ci` |
| Vulnerable dependency blocked | Pull request adding `jinja2==2.10`: `scan` failed, `build-and-push` skipped |
| Vulnerable image blocked | First real run blocked a HIGH zlib CVE in the base image; fixed by applying OS updates at build time |
| Images are immutable and scanned | ECR tag mutability `IMMUTABLE`, scan on push, image tagged with the commit ID |
| Software bill of materials kept | CycloneDX SBOM uploaded as a build artifact on every main build |
| Terraform misconfigurations block the build | Trivy config scan with `exit-code: 1`; accepted risks listed with reasons in `.trivyignore` |
