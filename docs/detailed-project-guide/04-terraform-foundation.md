# 04. Terraform foundation and the network

This chapter covers Days 4 to 6: where Terraform keeps its records, how the code is split, and the private network with its endpoints, security groups and encryption key.

---

## 1. Terraform in five sentences

- **Terraform** builds cloud resources from text files (`.tf`) written in HCL.
- `terraform init` downloads the providers (plugins) and connects to the state backend.
- `terraform plan` shows what would change, without changing anything.
- `terraform apply` makes the changes after you type `yes`.
- **State** is Terraform's record of what it built. If the state is lost, Terraform no longer knows what it owns.

The routine before every apply:

```powershell
terraform fmt -recursive   # tidy formatting
terraform validate         # check the code is valid
terraform plan             # read what will change
terraform apply            # only after reading the plan
```

The most important habit: **read the last line of the plan.** `X to add, Y to change, Z to destroy`. Any unexpected destroy means stop.

---

## 2. Day 4: the state bucket (`terraform/bootstrap/main.tf`)

State is kept in S3, so it survives a lost laptop and is not committed to Git.

```hcl
resource "aws_s3_bucket" "state" {
  bucket = "payments-tfstate-${data.aws_caller_identity.me.account_id}"
}
```

The bucket name includes the account ID, because S3 bucket names must be unique across all of AWS.

| Resource | Why |
| --- | --- |
| `aws_s3_bucket_versioning` | Every old version of the state is kept, so a bad state can be recovered |
| `aws_s3_bucket_server_side_encryption_configuration` (AES256) | State is encrypted at rest |
| `aws_s3_bucket_public_access_block` (all four true) | The bucket can never be made public |

The bootstrap itself uses **local** state on purpose. It is a chicken-and-egg problem: the bucket that stores state cannot store its own state before it exists. The bootstrap folder is **never destroyed** during the project.

Result: bucket `payments-tfstate-472639329900`.

### Problems on Day 4

| # | Symptom | Root cause | Fix | Lesson |
| --- | --- | --- | --- | --- |
| 1 | `main.tf` contained broken, mixed-up text | The paste into the file was scrambled | The file was replaced with a clean copy | After pasting, read the file back before running anything |
| 2 | `terraform init` said the directory was empty | The file had not been saved yet in VS Code | Save (Ctrl+S), then run `init` again | An unsaved editor tab is invisible to Terraform. A dot on the tab means unsaved |

Status: verified (conversation history). **Missing:** the exact text of the scrambled file.

### Backend block (`envs/dev/versions.tf`)

```hcl
backend "s3" {
  bucket       = "payments-tfstate-472639329900"
  key          = "dev/terraform.tfstate"
  region       = "eu-north-1"
  encrypt      = true
  use_lockfile = true
}
```

- `key` is the path of this environment's state inside the bucket. `shared` uses `shared/terraform.tfstate`.
- `use_lockfile = true` makes Terraform write a small lock file next to the state, so two `apply` runs cannot change the same state at the same time. Before Terraform 1.10 this needed a DynamoDB table.
- A backend block cannot use variables, so the bucket name is written out.

### Tags on everything

```hcl
provider "aws" {
  region = var.region
  default_tags {
    tags = {
      Project     = "secure-payments-platform"
      Environment = "dev"
      ManagedBy   = "terraform"
      CostCenter  = "payments-lab"
    }
  }
}
```

Every resource gets the same four tags automatically. Finance teams use tags to see costs and ownership.

---

## 3. The three-folder split

| Folder | Holds | Why it is separate |
| --- | --- | --- |
| `bootstrap` | State bucket | Must exist before anything else and must never be destroyed |
| `envs/shared` | ECR repository, registry scan rule, CI users | Destroying `dev` every night must not delete the images or the CI users' keys stored in GitHub |
| `envs/dev` | Everything that costs money while running | Can be destroyed and rebuilt from code |

The registry was first planned inside `dev` (Day 8). An outside review pointed out that a nightly `dev` destroy would delete every image and force new access keys each time. It was moved into `shared` before Day 10.

The local name is `payments` everywhere (`locals { name = "payments" }`), so resources are named `payments-alb`, `payments-postgres` and so on.

---

## 4. Day 5: the network module

A **module** is a folder of Terraform called with inputs, like a function. `envs/dev/main.tf` calls it:

```hcl
module "network" {
  source              = "../../modules/network"
  name                = local.name
  region              = var.region
  vpc_cidr            = "10.30.0.0/16"
  azs                 = ["eu-north-1a", "eu-north-1b"]
  public_subnet_cidrs = ["10.30.1.0/24", "10.30.2.0/24"]
  app_subnet_cidrs    = ["10.30.11.0/24", "10.30.12.0/24"]
  data_subnet_cidrs   = ["10.30.21.0/24", "10.30.22.0/24"]
}
```

### What the module builds

| Resource | Purpose |
| --- | --- |
| VPC `10.30.0.0/16` with DNS support and hostnames | The private network. DNS hostnames are needed for interface endpoints |
| `aws_default_security_group` with no rules | Takes over the VPC's default security group and leaves it empty, so nothing can use it by accident |
| Internet gateway | The only way in or out of the VPC, used by the public subnets only |
| 2 public subnets | For the load balancer. `map_public_ip_on_launch = false` |
| 2 app subnets | For the ECS tasks |
| 2 data subnets | For the database |
| Public route table | `0.0.0.0/0` to the internet gateway |
| Private route table | **No** `0.0.0.0/0` route at all. Shared by app and data subnets |

> **What is a route table?** A list of where traffic may go. If there is no route to the internet, nothing in that subnet can reach the internet, even if it tries.

### Proof the private subnets have no way out

```powershell
aws ec2 describe-route-tables --filters "Name=tag:Name,Values=payments-private" --query "RouteTables[].Routes[].DestinationCidrBlock"
```

Result: only `10.30.0.0/16` (local). This is the first control in `docs/controls.md`. Later, the S3 gateway endpoint adds a prefix-list route to the same table, which is still private.

The plan document expected `Plan: 17 to add` for Day 5. **Missing:** the actual plan count was not recorded.

---

## 5. Day 6: VPC endpoints

With no internet route, the tasks still need four AWS services. **VPC endpoints** give private access over the AWS network.

| Endpoint | Type | Used for |
| --- | --- | --- |
| `s3` | Gateway (free, added to the private route table) | Image layers are stored in S3 |
| `ecr.api` | Interface | ECR authentication and image metadata |
| `ecr.dkr` | Interface | Pulling the image |
| `logs` | Interface | Sending container logs to CloudWatch |
| `secretsmanager` | Interface | Reading the database password and API key at start-up |

```hcl
resource "aws_vpc_endpoint" "interface" {
  for_each            = toset(local.interface_services)
  vpc_endpoint_type   = "Interface"
  subnet_ids          = [aws_subnet.app[0].id]
  security_group_ids  = [aws_security_group.endpoints.id]
  private_dns_enabled = true
}
```

- `private_dns_enabled = true` makes the normal AWS address (for example `secretsmanager.eu-north-1.amazonaws.com`) resolve to the endpoint inside the VPC, so the app needs no special configuration.
- **Cost trade-off:** interface endpoints are in **one** subnet only, to save money. A production setup would use both zones, because one zone failing would also cut the tasks off from these services.

### Why not a NAT gateway?

| NAT gateway | VPC endpoints |
| --- | --- |
| Gives the tasks a route to the whole internet | Gives access only to the named AWS services |
| Larger attack surface | Nothing else is reachable |
| Charged per hour and per GB | Interface endpoints are also charged per hour, but traffic stays private |

---

## 6. Day 6: security groups (`modules/network/security_groups.tf`)

> **What is a security group?** A firewall attached to a resource. It allows only the traffic you list. Everything else is denied.

Four groups: `payments-alb`, `payments-app`, `payments-db`, `payments-endpoints`. Read each rule as a sentence:

| Rule | From | To | Port |
| --- | --- | --- | --- |
| `alb_http` | Internet `0.0.0.0/0` | Load balancer | 80 (redirects only, since HTTPS) |
| `alb_https` | Internet `0.0.0.0/0` | Load balancer | 443 (added on 24 November 2026) |
| `alb_to_app` | Load balancer | App | 8000 |
| `app_from_alb` | Load balancer | App | 8000 |
| `app_to_endpoints` | App | Endpoints | 443 |
| `app_to_s3` | App | S3 prefix list | 443 |
| `app_to_db` | App | Database | 5432 |
| `db_from_app` | App | Database | 5432 |
| `endpoints_from_app` | App | Endpoints | 443 |

- Rules refer to **other security groups**, not IP ranges. "Only the app's security group may reach the database" stays correct even when tasks get new IP addresses.
- Each rule is its own resource (`aws_vpc_security_group_ingress_rule` / `egress_rule`), which is the current AWS provider recommendation and makes each rule easy to read and review.
- The app has **no** egress rule to the internet.

---

## 7. Day 6: the encryption key (`envs/dev/kms.tf`)

```hcl
resource "aws_kms_key" "main" {
  description             = "Encryption key for the payments platform data"
  enable_key_rotation     = true
  deletion_window_in_days = 7
}

resource "aws_kms_alias" "main" {
  name          = "alias/payments-main"
  target_key_id = aws_kms_key.main.key_id
}
```

| Setting | Meaning |
| --- | --- |
| Customer-managed key | The company controls the key and its policy, not AWS. Every use is logged in CloudTrail |
| `enable_key_rotation = true` | AWS rotates the key material every year automatically |
| `deletion_window_in_days = 7` | A deleted key waits 7 days (the minimum) before it is really gone. Short because this is a lab that is rebuilt often |
| Alias `alias/payments-main` | A readable name for the key |

The key encrypts the database storage, the database password secret and the API key secret.

The plan document expected `Plan: 19 to add` for Day 6. **Missing:** the actual count was not recorded.

---

## 8. Destroy and rebuild

On Day 6 the plan asked for a full `terraform destroy` and `terraform apply` to prove the network could be rebuilt from code alone, with no console clicks. This became the daily routine: build `dev` at the start of a session, destroy it at the end.

**Never destroy `bootstrap`.** Destroying it deletes the state of every environment.

---

## 9. What I learned

- Splitting Terraform by **lifetime** (bootstrap, shared, dev) is as important as splitting it by component.
- Security groups that reference each other are easier to reason about than IP ranges.
- No NAT gateway is a real design choice with trade-offs, not just a cost saving.
- Saving the file matters. Terraform only sees what is on disk.
