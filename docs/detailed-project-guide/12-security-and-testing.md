# 12. Security controls and testing

This chapter brings the security picture together by layer, lists the accepted risks and known gaps, and explains the test suite.

The full evidence table is [`docs/controls.md`](../controls.md) (42 controls). This chapter explains them; it does not replace them.

---

## 1. Defence in depth

Security is built in layers, so one mistake does not expose everything.

| Layer | Controls |
| --- | --- |
| **Edge** | DNS name with an ACM certificate; HTTPS only (80 redirects); TLS 1.2/1.3 policy; WAF common rules; WAF rate limit; invalid headers dropped |
| **Network** | Three subnet tiers; no internet route for app and data; no NAT; VPC endpoints; security groups that reference each other; locked default security group; tasks without public IPs |
| **Application** | API key compared in constant time; idempotency key required; strict input validation; `Decimal` for money; minimal logging |
| **Container** | Non-root user; read-only root file system; OS updates at build time; pinned dependencies; image scanned before push |
| **Identity** | Empty task role; execution role limited to two secrets and one key; push-only build user; deploy user limited to one service and two roles; PassRole restricted to ECS |
| **Data** | Customer-managed KMS key with rotation; database storage, backups and secrets encrypted; TLS forced to the database; password generated, stored and rotated by AWS; database not public; 7-day backups; Multi-AZ |
| **Delivery** | Pull request required; tests and scans required; Trivy pinned by commit ID; immutable image tags; SBOM; scan check before deploy; named approval; deploy key behind approval; only `main` deploys; circuit breaker; running-version check |
| **Detection** | CloudTrail with log file validation; AWS Config rules; alarms with email; dashboard; SLO |

---

## 2. Accepted risks (`.trivyignore`)

Each entry was reviewed in a pull request and has a written reason.

| ID | Finding | Why accepted | Next step |
| --- | --- | --- | --- |
| AWS-0132 | State bucket uses S3-managed encryption | Private, versioned, state only | Customer-managed key |
| AWS-0053 | Load balancer is internet-facing | By design: the only entry point, behind WAF | None |
| AWS-0015 | CloudTrail logs use S3-managed encryption | Private bucket, HTTPS-only policy, log validation | Dedicated KMS key with a CloudTrail key policy |
| AWS-0095 | SNS topic not encrypted | Alarm names and states only. The AWS-managed SNS key would block CloudWatch | Dedicated KMS key that allows `cloudwatch.amazonaws.com` |

**Removed:** AWS-0054 (HTTP listener), on 24 November 2026, when HTTPS was added. The scan now passes without it.

---

## 3. Known gaps

These are stated in the README as well. Knowing them is part of the work.

| Gap | Why it exists | Production fix |
| --- | --- | --- |
| TLS ends at the load balancer | Load balancer to task is HTTP on 8000 inside the VPC | TLS in the container, or a service mesh |
| Long-lived access keys instead of OIDC | OIDC blocked by the organisation | OIDC with short-lived credentials; delete the keys |
| Single approver; prevent self-review off | One person | Two-person rule |
| Password rotation vs running tasks | Tasks read the secret only at start | Fetch per connection, or RDS Proxy |
| App uses the database master user | Simpler for a lab | A `payments_app` user with `SELECT` and `INSERT` only |
| API key stored in Terraform state | `random_password` lives in state | Generate the key outside Terraform, or restrict state access tightly |
| Interface endpoints in one zone | Cost | Endpoints in both zones |
| Restored database not queried | It is private | A one-off task inside the VPC that reads a row |
| Failed payments during failover not retried | Test client did not retry | Client retry with backoff and the same idempotency key |
| Lab-only settings | `force_destroy`, `skip_final_snapshot`, no deletion protection, 0-day secret recovery | Reverse all of them |
| Single region | Account allows one region | Cross-region backups and a recovery plan |
| Old commits show a personal email | Set before the noreply address | Leave history; noreply from now on |

---

## 4. What this project does not claim

- It is **not** PCI DSS, DORA or any other certification.
- The controls are aligned with common themes of payments regulation (encryption, access control, change control, audit, resilience), with evidence for each.
- It is a lab. Production would need everything in section 3.

---

## 5. The test suite

### Overview

| File | Tests | Needs a database | Runs locally | Runs in CI |
| --- | --- | --- | --- | --- |
| `app/tests/test_api.py` | 8 | No | Yes | Yes |
| `app/tests/test_integration.py` | 4 | Yes | Skipped | Yes, against PostgreSQL 16 |

Locally: **8 passed, 4 skipped**. In CI: **12 passed**.

### Unit tests (`test_api.py`)

They set `SKIP_DB_INIT=1` and a test API key (`test-key`), so they run with no database.

| Test | Proves |
| --- | --- |
| `test_health` | `/health` returns 200 and `{"status": "ok"}` |
| `test_requires_api_key` | No API key: 401 |
| `test_rejects_wrong_api_key` | Wrong API key: 401 |
| `test_requires_idempotency_key` | No idempotency key: 422 |
| `test_rejects_negative_amount` | Negative amount: 422 |
| `test_rejects_bad_currency` | `"euro"` instead of `"EUR"`: 422 |
| `test_reading_requires_api_key` | Reading a payment without a key: 401 |
| `test_rejects_bad_payment_id` | A non-UUID ID: 422 |

Six of the eight tests check that something is **refused**. Security tests are mostly about what must not work.

### Integration tests (`test_integration.py`)

Skipped unless `DB_HOST` is set. In CI, the job's PostgreSQL service provides it.

| Test | Proves |
| --- | --- |
| `test_create_and_read_back` | Create returns 201; reading it back returns the same reference |
| `test_replay_returns_same_payment` | Same key, same body: second call returns 200 and the **same ID** |
| `test_same_key_different_body_is_rejected` | Same key, different amount: 409 |
| `test_unknown_payment_is_404` | An unknown ID: 404 |

### What the tests do not cover

| Not covered | Why it matters | Covered elsewhere? |
| --- | --- | --- |
| Start-up code (`init_db`, lifespan) | Day 18's crashing release passed CI because of this | The circuit breaker caught it in AWS |
| TLS to the database | CI disables TLS | `rds.force_ssl = 1` enforces it on AWS |
| Concurrency: two requests with the same key at the same moment | The unique index should handle it, but no test proves it | No |
| Load and performance | No load test | Partly: WAF burst and deployment probes |

### Security scans as tests

| Scan | Fails on |
| --- | --- |
| Trivy filesystem (dependencies and secrets) | HIGH or CRITICAL with a fix available; any secret |
| Trivy config (Terraform) | HIGH or CRITICAL not listed in `.trivyignore` |
| Trivy image | HIGH or CRITICAL with a fix available |

Proven to block: `jinja2==2.10` (dependency scan) and the zlib vulnerability (image scan).

---

## 6. Secrets handling rules used throughout

| Rule | How it was applied |
| --- | --- |
| No secret in Git | `.gitignore` for state and `local.auto.tfvars`; Trivy secret scan |
| No secret in chat or screenshots | Keys entered only in the AWS console and GitHub settings; emails cropped |
| No secret printed | `get-secret-value` only into a PowerShell variable, never echoed |
| No secret in the task definition | ECS `secrets` with ARNs, values injected at start |
| No secret in logs | Only payment ID and currency logged |
| Placeholders in documentation | `<DEPLOY_USER_SECRET>`, `<YOUR_EMAIL>` and similar |

---

## 7. What I learned

- A list of honest gaps is stronger than a claim of being "secure".
- Most security tests check refusals.
- Tests that skip start-up code can let a broken release through; runtime safety nets must catch what tests miss.
- Every accepted risk needs a reason and a next step.
