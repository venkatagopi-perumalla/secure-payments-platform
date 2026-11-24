# 07. ECS Fargate, the load balancer, WAF and HTTPS

This chapter covers Days 13 to 15 (running the API on AWS) and the HTTPS work done on 24 November 2026.

---

## 1. ECS Fargate in five sentences

- **ECS** (Elastic Container Service) runs containers on AWS.
- **Fargate** means AWS provides the servers. There are no machines to patch or scale.
- A **task definition** describes the container: image, CPU, memory, ports, secrets, logs.
- A **task** is one running copy of it.
- A **service** keeps a chosen number of tasks running, replaces failed ones and registers them with the load balancer.

---

## 2. Day 13: permissions, logs and the task (`modules/service`)

### Two IAM roles

| Role | Used by | Permissions |
| --- | --- | --- |
| `payments-ecs-exec` (execution role) | **ECS itself**, while starting a task | AWS managed `AmazonECSTaskExecutionRolePolicy` (pull images, write logs), plus `secretsmanager:GetSecretValue` on the two secrets only and `kms:Decrypt` on the project key only |
| `payments-ecs-task` (task role) | **The app code**, while running | **None.** The app does not call AWS |

An empty task role means that even if the app were compromised, it would get no AWS permissions.

### The log group

`/payments/api`, with 30 days retention.

### The task definition (`task.tf`)

| Setting | Value | Why |
| --- | --- | --- |
| Family | `payments-api` | Each change makes a new numbered **revision** (`payments-api:1`, `:2`, ...) |
| CPU / memory | 256 / 512 | Smallest Fargate size (0.25 vCPU, 0.5 GB) |
| Network mode | `awsvpc` | Each task gets its own private IP in an app subnet |
| `readonlyRootFilesystem` | `true` | Nothing can be written inside the container, which blocks a common attack step |
| Port | 8000 | |
| Environment | `DB_HOST`, `DB_NAME`, `DB_SSLMODE=require` | Not secret |
| Secrets | `DB_USER`, `DB_PASSWORD` from the RDS secret (by JSON key), `API_KEY` from `payments/api-key` | Injected at start. They never appear in the task definition, only the secret's address does |
| Health check | Python calls `http://localhost:8000/health` every 15 s | ECS replaces a task that fails 3 times |
| Logs | `awslogs` driver to `/payments/api` | |

```hcl
secrets = [
  { name = "DB_USER",     valueFrom = "${var.db_secret_arn}:username::" },
  { name = "DB_PASSWORD", valueFrom = "${var.db_secret_arn}:password::" },
  { name = "API_KEY",     valueFrom = var.api_key_secret_arn },
]
```

The `:username::` part picks one field from the JSON secret that RDS created.

The health check uses Python, not `curl`, because the slim image does not include `curl`.

### The API key (`envs/dev/app.tf`)

```hcl
resource "random_password" "api_key" {
  length  = 40
  special = false
}

resource "aws_secretsmanager_secret" "api_key" {
  name                    = "payments/api-key"
  kms_key_id              = aws_kms_key.main.arn
  recovery_window_in_days = 0 # lab only, so destroy and recreate work
}
```

- Terraform generates a 40-character key and stores it in Secrets Manager, encrypted with the project key.
- `recovery_window_in_days = 0` deletes the secret immediately on destroy. Otherwise AWS keeps it for 7 days and the next apply fails because the name is still taken.
- **Honest note:** the generated key is also stored in the Terraform state file. The state bucket is private and encrypted, but anyone with access to the state can read it.

---

## 3. Day 14: load balancer, firewall and service

### Load balancer (`alb.tf`)

| Resource | Setting | Why |
| --- | --- | --- |
| `aws_lb` `payments-alb` | `application`, public subnets | The only public entry point |
| | `drop_invalid_header_fields = true` | Drops malformed HTTP headers, which blocks request-smuggling tricks |
| Target group `payments-api` | Port 8000, `target_type = "ip"` | Fargate tasks register by IP |
| | `deregistration_delay = 30` | When a task stops, it finishes in-flight requests for 30 s. The default is 300 s, which slows deployments |
| | Health check `/health`, healthy 2, unhealthy 3, every 15 s | |

Listeners: originally one HTTP listener on 80 forwarding to the target group. Since 24 November 2026: HTTPS on 443, and 80 redirects (section 6).

### AWS WAF (`waf.tf`)

| Rule | Priority | Action |
| --- | --- | --- |
| `AWSManagedRulesCommonRuleSet` | 1 | AWS-maintained rules for common attacks (bad bots, cross-site scripting patterns, missing headers and more) |
| `rate-limit`: 2,000 requests per 5 minutes per IP | 2 | Block |
| Default | | Allow |

The rate limit was raised from 300 (in the first plan) to 2,000 after the outside review: 300 would block my own test loops.

### The service (`service.tf`)

| Setting | Value | Why |
| --- | --- | --- |
| `desired_count` | 2 | One task per zone |
| `deployment_minimum_healthy_percent` / `maximum_percent` | 100 / 200 | During a deploy, new tasks start **before** old ones stop. Never fewer than 2 healthy |
| `health_check_grace_period_seconds` | 30 | New tasks get 30 s to start before health checks count |
| `deployment_circuit_breaker` | enable, rollback | If new tasks keep failing, ECS stops the deploy and returns to the last working revision by itself |
| `assign_public_ip` | `false` | Tasks only have private IPs |
| `depends_on` | the HTTPS listener | The service is created after the listener exists |
| `lifecycle.ignore_changes` | `task_definition`, `desired_count` | After the first apply, the **deploy pipeline** owns the task definition and **autoscaling** owns the count. Without this, every `terraform apply` would roll the service back to the revision in the code |

### Autoscaling

Target tracking keeps average CPU at **60 percent**, between **2 and 4** tasks.

### Wiring it into `dev`

`envs/dev/app.tf` calls the module. The registry lives in `shared`, so `dev` looks it up by name:

```hcl
data "aws_ecr_repository" "api" {
  name = "payments-api"
}
image = "${data.aws_ecr_repository.api.repository_url}:${var.image_tag}"
```

`image_tag` comes from `local.auto.tfvars` (not in Git). It is only used when the service is first created. After that, the deploy pipeline changes the image.

**Important lesson from the review:** the API key had to be in the task definition **from the first apply**. Because of `ignore_changes`, a secret added to the task definition in Terraform later would be silently ignored.

---

## 4. Day 15: prove it works

### A payment through the load balancer

```powershell
$key = aws secretsmanager get-secret-value --secret-id payments/api-key --query SecretString --output text
$h = @{ "X-API-Key" = $key; "Idempotency-Key" = "<UNIQUE_KEY>" }
$body = '{"amount": 10.50, "currency": "EUR", "reference": "test-1"}'
Invoke-RestMethod -Method Post -Uri "<APP_URL>/payments" -Headers $h -ContentType "application/json" -Body $body
```

The key is kept in a variable and never printed. Sending the same request again returned the **same payment ID**, not a second payment.

### No public IP

ECS console, cluster `payments`, a task, Networking: a private IP in `10.30.11.x` or `10.30.12.x` and no public IP.

### Self-healing

One task was stopped by hand while a loop kept calling the API.

| Result | |
| --- | --- |
| Health checks during the test | **90 of 90** returned 200 |
| After | ECS started a replacement; 2 of 2 running |

**Missing:** how long the replacement took to become healthy.

### WAF burst

| Attempt | Method | Result |
| --- | --- | --- |
| 1 | A simple PowerShell loop, one request after another | **Did not trip the limit.** Sequential requests were too slow to exceed 2,000 in the WAF's counting window |
| 2 | Parallel `curl` requests | First burst allowed; on the second burst **3,000 of 3,000** were blocked with **403** |

Screenshot: `docs/evidence/waf-block.png`. After a burst, my own IP stayed blocked for a few minutes, which is expected.

**Lesson:** to test a rate limit, the test must actually be faster than the limit. WAF evaluates rate over a time window and acts with a short delay, so the first burst usually passes.

### Load across zones

The logs showed requests served by two tasks, and health checks came from both public subnets.

---

## 5. Problems in this phase

| # | Symptom | Root cause | Fix | Lesson |
| --- | --- | --- | --- | --- |
| 1 | Sequential WAF burst did not trigger any 403 | Requests were sent one at a time, too slowly | Parallel `curl` burst | Test tools must match the behaviour being tested |
| 2 | `imageTag=(git rev-parse HEAD)` did not work in a PowerShell command | PowerShell split the expression into separate arguments | Save the value first: `$tag = git rev-parse HEAD`, then use `imageTag=$tag` | In PowerShell, put command output in a variable before building arguments |

Status: verified (conversation history).

---

## 6. HTTPS on a custom domain (24 November 2026)

### Why

Plain HTTP was the biggest gap. Payment requests and API keys must not cross the internet unencrypted. AWS does not issue certificates for the `*.elb.amazonaws.com` name, so HTTPS needed a domain I own: `venkatagopiperumalla.com`, with DNS at **Porkbun**. The API uses the subdomain **`api.venkatagopiperumalla.com`**. The main domain stays the portfolio site.

### Code changes (pull request #5)

| File | Change |
| --- | --- |
| `modules/network/security_groups.tf` | New rule `alb_https`: 443 from the internet |
| `modules/service/variables.tf` | New variable `certificate_arn` |
| `modules/service/alb.tf` | New HTTPS listener on 443 with `ELBSecurityPolicy-TLS13-1-2-2021-06`; the port 80 listener now **redirects** with 301 |
| `modules/service/service.tf` | `depends_on` changed to the HTTPS listener |
| `envs/dev/https.tf` (new) | `api_domain` variable, ACM certificate with DNS validation, validation wait, outputs |
| `envs/dev/app.tf` | Passes the validated certificate to the module; `app_url` is now `https://api.venkatagopiperumalla.com` |
| `.trivyignore` | AWS-0054 (HTTP listener) removed |
| README, `docs/controls.md` | Updated; new control "HTTPS for API traffic from the internet" |

```hcl
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "redirect"
    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }
}
```

```hcl
resource "aws_acm_certificate" "api" {
  domain_name       = var.api_domain
  validation_method = "DNS"
  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_acm_certificate_validation" "api" {
  certificate_arn         = aws_acm_certificate.api.arn
  validation_record_fqdns = [for o in aws_acm_certificate.api.domain_validation_options : o.resource_record_name]
}
```

`aws_acm_certificate_validation` does not create anything. It **waits** until ACM says the certificate is issued, so the listener is never created with an unvalidated certificate.

### Steps

| Step | Command or action | Result |
| --- | --- | --- |
| 1. Check the image tag | `aws ecr describe-images` for the newest tags | `local.auto.tfvars` pointed at an older tag; changed to the newest (`e5490661...`) before building, to avoid a repeat of the Day 21 pull error |
| 2. Check DNS | `nslookup -type=NS venkatagopiperumalla.com` | Porkbun nameservers |
| 3. Check `api` is free | `nslookup -type=CNAME api.venkatagopiperumalla.com` | No record |
| 4. Create only the certificate | `terraform apply -target="aws_acm_certificate.api"` | 1 added |
| 5. Get the validation record | `terraform output acm_validation_record` | A CNAME name and value |
| 6. Add the validation CNAME at Porkbun | Host `_<token>.api`, target `_<token>.<id>.acm-validations.aws` | |
| 7. Full apply | `terraform apply` | `85 added, 0 changed, 0 destroyed` |
| 8. Point the domain at the load balancer | CNAME `api` to the load balancer DNS name | |

**Porkbun detail:** the Host field takes only the part **before** the domain (`_<token>.api`), because Porkbun adds `.venkatagopiperumalla.com` itself.

### Test results

| Test | Result |
| --- | --- |
| `curl.exe -I http://api.venkatagopiperumalla.com/health` | `HTTP/1.1 301 Moved Permanently`, `Location: https://api.venkatagopiperumalla.com:443/health` |
| `curl.exe -i https://api.venkatagopiperumalla.com/health` | `HTTP/1.1 200 OK`, `{"status":"ok"}` |
| Certificate | Subject `CN=api.venkatagopiperumalla.com`, issuer `Amazon RSA 2048 S25`, valid 24 November 2026 to 10 June 2027 |
| Listener policy | 443 HTTPS `ELBSecurityPolicy-TLS13-1-2-2021-06`; 80 HTTP (redirect) |
| CI | `test` and `scan` green **without** the AWS-0054 exception |

Evidence: `docs/evidence/https-browser.png`, `docs/evidence/https-redirect.png`.

The certificate lasts about 200 days, which matches the shorter maximum lifetime for public certificates. ACM renews it automatically while it is in use.

### Problems hit while adding HTTPS

| # | Symptom | Root cause | Fix |
| --- | --- | --- | --- |
| 1 | `git checkout -b https` said the branch already exists | An old, empty local branch with the same name | Confirmed it had no commits of its own, deleted it with `git branch -D https`, created it again |
| 2 | PowerShell error `Get-Variable : A positional parameter cannot be found` | Terraform code was pasted into PowerShell instead of into the file | Append to the file with `Add-Content` and a here-string |
| 3 | `terraform validate`: `"certificate_arn" is required` | `app.tf` not yet updated | Added the `certificate_arn` line |
| 4 | `terraform validate`: `aws_lb_listener "https" has not been declared` | The new `alb.tf` was edited in VS Code but **not saved to disk**. `Select-String` showed only the old listener | Wrote the whole file from PowerShell with `Set-Content` and a here-string, then checked with `Select-String` |
| 5 | `terraform apply` asked for many variables, then failed | It was run from `terraform\modules\service`, a module folder, not `envs\dev` | Stopped, moved to `envs\dev` and ran it again. Nothing had been created |
| 6 | `nslookup api...` printed a name but no address | No record existed yet; the earlier output was simply "no data" | Confirmed with `-type=CNAME`, which returned only the zone's SOA record |
| 7 | Windows `curl -v` showed no certificate details | Windows `curl.exe` uses the Windows TLS library (schannel), which does not print them | Used .NET (`[Net.HttpWebRequest]`) to read the certificate |
| 8 | That .NET request got **403** | It sends no `User-Agent` header, and the WAF common rule set blocks requests without one | No fix needed. The TLS handshake had already succeeded. This also proved WAF covers the HTTPS listener |
| 9 | `curl.exe --tls-max 1.1` failed with `SEC_E_UNSUPPORTED_FUNCTION` | Windows itself may have TLS 1.0/1.1 switched off, so this does **not** prove the server refused it | The listener policy is the proof. The README claims "TLS 1.2/1.3 only (ELB policy)", not "tested TLS 1.1 refused" |
| 10 | `git push` rejected: `GH007: Your push would publish a private email address` | The commit used a private Gmail address, and GitHub's email privacy protection is on | Set `git config --global user.email` to the GitHub **noreply** address, then `git commit --amend --reset-author --no-edit` and push again |
| 11 | The first `terraform destroy` said `0 destroyed` | It was run from the repository root, where there is no Terraform configuration | Ran it from `envs\dev`: **86 destroyed** |

All verified from command output on 24 November 2026.

### Cleanup

- `dev` destroyed: 86 resources (the 85 from the apply plus the certificate created first).
- Porkbun: the `api` CNAME deleted, so the name does not point at a load balancer that no longer exists. The ACM validation CNAME kept, because ACM reuses it for the same domain in the same account, which makes the next certificate validate quickly.

### Known gap that remains

TLS ends at the load balancer. The hop from the load balancer to the tasks on port 8000 is plain HTTP inside the private VPC. Encrypting that hop would need TLS inside the container or a service mesh.

---

## 7. What I learned

- `ignore_changes` is essential when a pipeline, not Terraform, owns deployments, but it means some Terraform changes are silently skipped.
- An empty task role is the safest task role.
- A 301 redirect is better than closing port 80: clients that type `http://` still reach the secure endpoint.
- DNS validation lets a certificate be issued with no email and renewed with no work.
- Always check the file on disk (`Select-String`, `Get-Content`) when a tool says something is missing.
