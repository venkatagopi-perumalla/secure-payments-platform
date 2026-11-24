# 09. Audit trail and monitoring

This chapter covers Days 19 and 20: CloudTrail, AWS Config, alarms, the dashboard and the service level objective.

---

## 1. Day 19: the audit bucket (`envs/dev/audit.tf`)

One private S3 bucket, `payments-audit-<ACCOUNT_ID>`, holds both CloudTrail logs and AWS Config records.

| Setting | Why |
| --- | --- |
| Public access block (all four) | Never public |
| AES256 encryption | Encrypted at rest. Not a customer-managed key: accepted risk AWS-0015 |
| Versioning | Old versions kept |
| Bucket policy | CloudTrail and Config may write only to their own prefixes (`cloudtrail/AWSLogs/<ACCOUNT_ID>/` and `config/AWSLogs/<ACCOUNT_ID>/Config/`), with `bucket-owner-full-control` |
| `DenyInsecureTransport` | Any request without HTTPS is denied |
| `force_destroy = true` | **Lab only**, so `terraform destroy` can delete a bucket full of logs. A real audit bucket would never allow this |

### Problem: `aws_caller_identity` missing in `dev`

| | |
| --- | --- |
| Symptom | `terraform plan` failed on `audit.tf` because the account ID it uses was not defined in `dev` |
| Root cause | The audit bucket name and policy need the account ID, but the `dev` environment had no `aws_caller_identity` data source (it existed only in `bootstrap` and `shared`) |
| Fix | Added `data "aws_caller_identity" "me" {}` at the top of `audit.tf` |
| Status | Verified (conversation history; `audit.tf`). **Missing:** the exact error text |

---

## 2. CloudTrail

> **What is CloudTrail?** A record of every AWS API call: who made it, when, from where and what changed.

```hcl
resource "aws_cloudtrail" "main" {
  name                          = "payments-trail"
  s3_bucket_name                = aws_s3_bucket.audit.id
  s3_key_prefix                 = "cloudtrail"
  include_global_service_events = true
  is_multi_region_trail         = true
  enable_log_file_validation    = true
}
```

| Setting | Why |
| --- | --- |
| `is_multi_region_trail` | Records calls in every region, so activity in an unused region is not missed |
| `include_global_service_events` | Includes global services such as IAM |
| `enable_log_file_validation` | CloudTrail writes signed digest files. Anyone can later prove the logs were not changed or deleted |

### Evidence

```powershell
aws cloudtrail get-trail-status --name payments-trail --query IsLogging
aws cloudtrail describe-trails --query "trailList[?Name=='payments-trail'].LogFileValidationEnabled"
```

Results: `IsLogging true`, `LogFileValidationEnabled true`.

```powershell
aws cloudtrail lookup-events --lookup-attributes AttributeKey=EventName,AttributeValue=UpdateService --max-results 10 --query "Events[].[EventTime,Username,EventName]" --output table
```

Result: all 4 deploys and the rollback were made by `payments-github-deploy`; 1 deliberate test change by `cli-admin`. Every production change is traceable to an identity.

Evidence: `docs/evidence/cloudtrail-updateservice.png`.

---

## 3. AWS Config

> **What is AWS Config?** It records the configuration of resources over time and checks it continuously against rules.

The recorder records **all supported resources**, including global ones such as IAM, using a role with the AWS managed `AWS_ConfigRole` policy, and delivers to the audit bucket.

### The five rules

| Rule | Checks |
| --- | --- |
| `RDS_STORAGE_ENCRYPTED` | The database is encrypted |
| `RDS_INSTANCE_PUBLIC_ACCESS_CHECK` | The database is not public |
| `S3_BUCKET_PUBLIC_READ_PROHIBITED` | No bucket allows public read |
| `ALB_WAF_ENABLED` | The load balancer has WAF attached |
| `CLOUD_TRAIL_ENABLED` | CloudTrail is on |

Result: **5 of 5 COMPLIANT.** Rules can show `INSUFFICIENT_DATA` for the first few minutes after creation.

> **Cost note:** Config charges per configuration item recorded. It is easy to forget after a project, so it is part of `dev` and destroyed with it.

---

## 4. Day 20: alarms (`envs/dev/monitoring.tf`)

### SNS email

An SNS topic `payments-alerts` with an email subscription to `<YOUR_EMAIL>` (from `local.auto.tfvars`, not in Git). AWS sends a confirmation email first. **No alarm email arrives until the link in it is clicked.**

### The six alarms

| Alarm | Metric | Fires when | Sends OK email |
| --- | --- | --- | --- |
| `payments-5xx-rate` | Load balancer target 5xx count divided by request count | Above **2 percent** for 2 of 3 minutes | Yes |
| `payments-p95-latency` | Target response time, 95th percentile | Above **1 second** for 2 of 3 minutes | Yes |
| `payments-unhealthy-targets` | Unhealthy host count | Above 0 for 2 minutes | Yes |
| `payments-ecs-cpu-high` | ECS service CPU | Above 80 percent for 5 minutes | No |
| `payments-rds-cpu-high` | Database CPU | Above 80 percent for 15 minutes | No |
| `payments-rds-storage-low` | Database free storage | Below 2 GiB | No |

The 5xx alarm uses **metric math**:

```hcl
expression = "100 * errors / MAX([errors, requests])"
```

`MAX([errors, requests])` avoids dividing by zero when there is no traffic. `treat_missing_data = "notBreaching"` means no traffic is not an alarm.

The 5xx rate is a **rate**, not a count. 10 errors out of 10,000 requests is fine; 10 out of 20 is not.

### Proof the alert path works

Breaking the real service to test an alarm is risky, so the alarm state was forced by hand:

```powershell
aws cloudwatch set-alarm-state --alarm-name payments-5xx-rate --state-value ALARM --state-reason "Testing the alert path"
```

| Event | Time |
| --- | --- |
| ALARM email received | 17:13:20 |
| OK email received (automatic, at the next evaluation) | 17:14:18 |

Evidence: `docs/evidence/alarm-email.png`, `docs/evidence/alarm-ok-email.png`. The email address was cropped out of the screenshots.

**Missing:** the date of this test.

---

## 5. The dashboard

`payments-overview` has four panels:

| Panel | Metrics |
| --- | --- |
| Requests and server errors | Request count, target 5xx count |
| p95 response time | Target response time, p95 |
| ECS CPU and memory | Service CPU and memory |
| Database CPU and connections | RDS CPU and connections |

Evidence: `docs/evidence/cloudwatch-dashboard.png`.

---

## 6. The service level objective (`docs/slo.md`)

| Item | Value |
| --- | --- |
| Indicator (SLI) | Share of API requests that do not return a 5xx, measured at the load balancer |
| Objective (SLO) | **99.5 percent** over 30 days |
| Error budget | 0.5 percent: about 3 hours 36 minutes of full failure per 30 days |
| Alerts | 5xx rate above 2 percent for 2 of 3 minutes; p95 latency above 1 second |
| Burn rule | If more than half the budget is gone before day 20 of the window, stop feature work and fix reliability |

> **SLI, SLO, error budget.** The SLI is what you measure. The SLO is the target. The error budget is how much failure the target allows. When the budget is being spent too fast, reliability work comes before new features.

Measured on 18 November 2026: during the deployment, the automatic rollback and the manual rollback, **0** health-check requests failed.

---

## 7. Accepted risks in this area

| ID | Risk | Next step in a real system |
| --- | --- | --- |
| AWS-0015 | CloudTrail logs use S3-managed encryption | A dedicated KMS key with a CloudTrail key policy |
| AWS-0095 | The SNS topic is not encrypted | A dedicated KMS key whose policy allows `cloudwatch.amazonaws.com`. The AWS-managed SNS key would block CloudWatch from publishing |
| — | `force_destroy` on the audit bucket | Remove it; use S3 Object Lock for audit logs |

---

## 8. What I learned

- An alarm that has never fired is an untested alarm. Force it once.
- Alert on rates and percentiles, not raw counts.
- Log file validation turns logs into evidence.
- An SLO with a burn rule turns reliability into a decision, not a feeling.
