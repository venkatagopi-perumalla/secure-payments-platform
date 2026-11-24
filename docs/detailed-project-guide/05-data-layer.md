# 05. The data layer

This chapter covers Days 7 to 9: the encrypted PostgreSQL database, its AWS-managed password, the evidence that it is protected, and the Multi-AZ change made on Day 21.

---

## 1. Why RDS

**Amazon RDS** runs PostgreSQL for you: AWS handles patching, backups, failover and storage. A payments team should not spend its time operating database servers.

---

## 2. The database module (`terraform/modules/database/main.tf`)

Called from `envs/dev/main.tf`:

```hcl
module "database" {
  source            = "../../modules/database"
  name              = local.name
  db_name           = "payments"
  subnet_ids        = module.network.data_subnet_ids
  security_group_id = module.network.db_security_group_id
  kms_key_arn       = aws_kms_key.main.arn
  multi_az          = true
}
```

### The instance

| Setting | Value | Why |
| --- | --- | --- |
| `identifier` | `payments-postgres` | Its name in AWS |
| `engine_version` | `16` | PostgreSQL 16. AWS picks the latest minor version (16.13 at the time) |
| `instance_class` | `db.t4g.micro` | Smallest Graviton (ARM) size. Lab cost |
| `allocated_storage`, `storage_type` | 20 GB, `gp3` | Small, current-generation SSD |
| `storage_encrypted`, `kms_key_id` | `true`, the project key | Disk, backups and snapshots are encrypted with the customer-managed key |
| `manage_master_user_password` | `true` | AWS generates the password and stores it in Secrets Manager |
| `master_user_secret_kms_key_id` | The project key | That secret is also encrypted with the project key |
| `username` | `payments_admin` | The master user name |
| `db_subnet_group_name` | Data subnets | The database lives only in the data tier |
| `publicly_accessible` | `false` | No public address, ever |
| `multi_az` | `true` (from Day 21) | A standby copy in the second zone |
| `backup_retention_period` | `7` | Point-in-time restore for the last 7 days |
| `enabled_cloudwatch_logs_exports` | `postgresql`, `upgrade` | Database logs in CloudWatch |
| `auto_minor_version_upgrade` | `true` | Security patches applied in the maintenance window |
| `skip_final_snapshot`, `deletion_protection` | `true`, `false` | **Lab only**, so `terraform destroy` works. A real system would use the opposite |

### The parameter group

```hcl
resource "aws_db_parameter_group" "this" {
  name   = "${var.name}-pg16"
  family = "postgres16"

  parameter {
    name         = "rds.force_ssl"
    apply_method = "pending-reboot"
    value        = "1"
  }
  parameter {
    name  = "log_connections"
    value = "1"
  }
  parameter {
    name  = "log_disconnections"
    value = "1"
  }
}
```

| Parameter | Effect |
| --- | --- |
| `rds.force_ssl = 1` | The database **refuses** any connection without TLS |
| `log_connections`, `log_disconnections` | Every login and logout is logged, which helps audits and investigations |

---

## 3. No password anywhere

With `manage_master_user_password = true`:

1. AWS creates a strong password.
2. AWS stores it in Secrets Manager as a secret named `rds!db-<id>`, encrypted with the project key.
3. AWS rotates it.
4. ECS injects the user name and password into the container at start-up (chapter 07).

No person, no file in the repository and no chat ever contained the password. The Terraform output `db_secret_arn` shows only the secret's **address** (ARN), not its value.

> **Rule followed throughout:** never print a secret's value. Commands that show settings (`describe-secret`) are fine. Commands that show the value (`get-secret-value`) are only used inside a variable, never printed.

### Known gap: rotation and running tasks

ECS reads the password only when a task starts. If AWS rotates it, running tasks keep the old one until they restart. The production fix is to fetch the secret per connection or to use RDS Proxy. This is listed in the README gaps.

### Known gap: the app uses the master user

The app logs in as `payments_admin`, which can do anything in the database. A better design uses a separate `payments_app` user with only `SELECT` and `INSERT` on the `payments` table. This was planned as an optional hardening step and **not done**.

---

## 4. Day 7 problem: parameter group drift

| | |
| --- | --- |
| Symptom | Every `terraform plan` showed a change to the parameter group, even right after an apply |
| Root cause | AWS and Terraform disagreed about the `apply_method` of `rds.force_ssl`. Without it written in the code, Terraform's default and the value AWS reported did not match, so Terraform kept trying to "fix" it |
| Fix | Set `apply_method = "pending-reboot"` explicitly on that parameter |
| How it was confirmed | The next `terraform plan` showed no changes |
| Lesson | **Drift** means the real resource differs from the code. A plan that never reaches zero changes is a sign to compare what AWS returns with what the code says, attribute by attribute |
| Status | Verified (conversation history; README "Problems found and fixed") |

---

## 5. Day 8: the container registry

The registry was later moved to `terraform/envs/shared/ecr.tf` (chapter 04).

```hcl
resource "aws_ecr_repository" "api" {
  name                 = "payments-api"
  image_tag_mutability = "IMMUTABLE"
  force_delete         = true

  image_scanning_configuration {
    scan_on_push = true
  }
}
```

| Setting | Why |
| --- | --- |
| `IMMUTABLE` | A tag (the commit ID) can never be overwritten. What was scanned is exactly what runs |
| `scan_on_push` | ECR scans every image for known vulnerabilities |
| `force_delete` | Lab only: lets Terraform delete the repository even if it still has images |
| Lifecycle policy: keep the last 30 images | The registry does not grow forever. **Note:** this rule can delete an old image that an old task definition or `local.auto.tfvars` still points to |

An account-level **registry scanning rule** was added later (`ecr_scanning.tf`). Chapter 11 explains why.

---

## 6. Day 9: evidence that the data is protected

The database is private, so it cannot be reached from the laptop, and that is the point. Its **settings** were checked instead.

```powershell
aws rds describe-db-instances --db-instance-identifier payments-postgres --query "DBInstances[0].[DBInstanceStatus,StorageEncrypted,PubliclyAccessible,MultiAZ,BackupRetentionPeriod,Engine,EngineVersion]" --output text
```

| Check | Result |
| --- | --- |
| Storage encrypted | `True` |
| Publicly accessible | `False` |
| Backup retention | `7` days |
| Engine | PostgreSQL 16.13 |

```powershell
aws rds describe-db-parameters --db-parameter-group-name payments-pg16 --query "Parameters[?ParameterName=='rds.force_ssl'].[ParameterName,ParameterValue]" --output text
```

Result: `rds.force_ssl 1`.

```powershell
aws secretsmanager describe-secret --secret-id <DB_SECRET_ARN> --query "[Name,KmsKeyId,RotationEnabled]"
```

Result: a name starting `rds!db-`, the project KMS key, rotation `True`.

```powershell
aws ecr describe-repositories --repository-names payments-api --query "repositories[0].[imageTagMutability,imageScanningConfiguration.scanOnPush]" --output text
```

Result: `IMMUTABLE True`.

These results became rows in `docs/controls.md`.

**Missing:** the exact command text used on the day may have differed slightly from the commands above. The results are as recorded in `docs/controls.md`.

---

## 7. Day 21: Multi-AZ

For the failover test, the database was converted to **Multi-AZ**: AWS keeps a standby copy in the other zone and switches to it automatically if the primary fails.

| Step | Time |
| --- | --- |
| Conversion started | 12:41:17 |
| Conversion finished | 12:49:59 |

That is about 8 minutes 42 seconds. The failover and restore tests that followed are in chapter 10.

`multi_az = true` is still set in `envs/dev/main.tf`. The plan suggested switching it off after the test to save cost. **Unverified:** whether that was intended to be permanent. It does double the database cost while `dev` runs.

---

## 8. What I learned

- Let AWS own the database password. It removes a whole class of leaks.
- Force TLS on the server side; do not rely on the client to ask for it.
- Prove a private database's controls with its settings, not by connecting to it.
- Drift that never goes away usually means a default value mismatch.
