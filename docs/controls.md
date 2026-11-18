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
| Tasks have no public IP | ECS task networking shows only a 10.30.11.x or 10.30.12.x private address (screenshot) |
| Only the load balancer is public | Security groups: internet to load balancer on 80 only; tasks accept traffic only from the load balancer |
| API key and idempotency key required | POST /payments needs X-API-Key (from Secrets Manager) and Idempotency-Key; a repeat returns the same payment |
| No sensitive data in logs | CloudWatch log lines show payment ID and currency only |
| Load spread across two zones | Logs show requests served by two tasks; health checks from both public subnets |
| Self-healing | Stopped one task: 90 of 90 health checks returned 200, ECS restored 2 of 2 running tasks |
| WAF rate limit blocks bursts | 3,000 requests in under a minute: first burst allowed, second burst 3,000 of 3,000 blocked with 403 (screenshot: docs/evidence/waf-block.png) |
| Deploys need a named approver | deploy workflow paused for review; approved in the production environment |
| Only scanned images deploy | Deploy check reads DescribeImageScanFindings; refused an image with no scan result |
| Zero-downtime rollout | Revision 2 to 4: 300 of 300 health checks returned 200; rollout completed in 2 minutes 3 seconds (docs/evidence/ecs-deploy-success.png) |
| Bad release never reached users | Malformed image address (revision 3): new tasks could not start, revision 2 kept serving 2 of 2 tasks (docs/evidence/ecs-bad-image-event.png) |
| Pipeline confirms what is running | Final deploy step: deployed and running task definition both payments-api:4 |
| Broken release rolled back automatically | Circuit breaker triggered at 3 of 3 failed tasks; service returned to revision 4 in about 4 minutes with 0 user errors (docs/rollback.md) |
| Pipeline reports a rolled-back release as failed | Deploy run ended red: "deployment was likely rolled back by the deployment circuit breaker" |
| Manual rollback is approved and timed | rollback workflow, approved by venkatagopi-perumalla, revision 6 to 4 in 3 minutes 0 seconds |
| Least-privilege deploy user | Deploy user policy: register task definitions, update one service, pass two roles, read image scan results; nothing else |
| Only main can deploy | deploy run from branch test-deploy-from-branch refused in 6 seconds: "not allowed to deploy to production due to environment protection rules"; the deploy key was never released (docs/evidence/deploy-branch-refused.png) |
| Every API action is recorded | CloudTrail trail payments-trail: multi-region, IsLogging true |
| Audit logs cannot be silently edited | CloudTrail log file validation enabled (LogFileValidationEnabled true) |
| Production changes are traceable to an identity | CloudTrail UpdateService events: all 4 deploys and the rollback by payments-github-deploy; 1 deliberate test by cli-admin |
| Continuous compliance checks | AWS Config: 5 of 5 rules COMPLIANT (RDS encrypted, RDS not public, no public S3 read, WAF on load balancer, CloudTrail on) |
| Accepted risk: CloudTrail log encryption | S3-managed encryption, not a customer-managed key; recorded in .trivyignore (AWS-0015) |
| Alerts reach a person | Forced payments-5xx-rate to ALARM: email at 17:13:20; automatic OK email at 17:14:18 (docs/evidence/alarm-email.png, alarm-ok-email.png) |
| Service health is visible | CloudWatch dashboard payments-overview: requests, 5xx, p95 latency, ECS CPU and memory, database CPU and connections (docs/evidence/cloudwatch-dashboard.png) |
| Reliability target defined | 99.5 percent non-5xx over 30 days with an error budget and burn rule (docs/slo.md) |
