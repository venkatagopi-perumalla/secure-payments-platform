# 01. Context and constraints

This chapter explains why the project exists, what it had to prove, and the limits of the AWS account that shaped almost every design decision.

---

## 1. Why this project

I am targeting Cloud, DevOps and SRE roles in Ireland, especially in fintech and banking. My earlier portfolio project (EKS GitOps platform) shows Kubernetes and GitOps. Payments teams also ask about different things:

- Is the network private?
- Is the data encrypted with keys the company controls?
- Who approved this change, and can you prove it?
- What happens when a release is broken, or a database zone fails?
- Where is the evidence?

This project answers those questions with a small, real service and measured results.

### The business scenario

A payments team needs a new service that accepts payment requests and stores them. The company's risk team requires that:

1. Nothing is open to the internet except the front door.
2. Data is encrypted.
3. Every change is reviewed and traceable to a person.
4. A bad release rolls back by itself.
5. The team can show evidence of all of it.

I built that service and the evidence.

### How it differs from the EKS project

| EKS GitOps project | This project |
| --- | --- |
| Kubernetes, Helm, Argo CD | AWS-native containers (ECS Fargate) |
| Cluster and GitOps operations | A database, secrets, security controls and audit evidence |
| Incident and RCA in Kubernetes | Measured failure tests on AWS managed services |

Together they cover the two common ways Irish finance teams run containers.

---

## 2. Goals

| Goal | How it was met | Chapter |
| --- | --- | --- |
| Private network | App and data subnets with no internet route; VPC endpoints instead of NAT | 04 |
| Encrypted data | Customer-managed KMS key for the database and secrets; TLS forced to the database; HTTPS at the load balancer | 04, 05, 07 |
| No stored database password | RDS generates and keeps the password in Secrets Manager | 05 |
| Scanned, immutable images | Trivy scans in CI; ECR immutable tags and scan on push | 06 |
| Approved deployments | GitHub `production` environment with a named approver | 08 |
| Tested rollback | Automatic (circuit breaker) and manual (workflow), both timed | 08, 10 |
| Audit trail | CloudTrail with log file validation; AWS Config rules | 09 |
| Alerting and an SLO | CloudWatch alarms to email; 99.5 percent SLO | 09 |
| Measured resilience | Self-heal, failover, restore, WAF burst | 10 |

---

## 3. What this project is not

- **Not certified.** It is not PCI DSS, DORA or any other compliance certification. The README says this, and I never claim "PCI compliant".
- **Not a real payment system.** The API validates a payment request and stores it in PostgreSQL. It is not connected to any bank, card network or payment provider. No money moves.
- **Not always running.** The `dev` environment is destroyed after each working session to save cost.

---

## 4. Account constraints

The lab AWS account belongs to an AWS Organization. The organisation has **Service Control Policies (SCPs)** that I cannot change.

> **What is an SCP?** A rule set by the organisation that sits above every IAM permission in an account. Even an administrator cannot do something an SCP denies.

### Constraint 1: only eu-north-1

| | |
| --- | --- |
| What happened | Work in eu-west-1 (Ireland) was denied by the organisation's SCP |
| Decision | Use **eu-north-1 (Stockholm)** for everything |
| Impact | None on the design. Data still stays in the EU, which matters for finance |
| Status | Verified (conversation history; region set in every Terraform provider and workflow) |

### Constraint 2: IAM OIDC provider blocked

| | |
| --- | --- |
| What happened | Creating an IAM OIDC identity provider for GitHub Actions was blocked by the SCP |
| Why it matters | OIDC lets GitHub Actions get short-lived AWS credentials with no stored keys. It is the recommended approach |
| Decision | Use **two least-privilege IAM users** with access keys stored as GitHub secrets |
| How the risk was reduced | The build user can only push to one ECR repository. The deploy user's key is a `production` environment secret, so it is released only after a person approves the run |
| Status | Verified (conversation history; `terraform/envs/shared/github_users.tf`; README gaps list) |

This is listed honestly as a known gap. In a normal account I would use OIDC and delete the keys.

---

## 5. Personal constraints

| Constraint | Effect |
| --- | --- |
| Windows laptop, PowerShell | Every command in this guide is PowerShell. Some commands needed Windows-specific forms (for example `curl.exe` instead of `curl`) |
| No Docker on the laptop | Days 2 and 3 of the plan (local container run) were skipped. CI builds the image and runs the database tests against a real PostgreSQL service container instead |
| Lab credit budget | `dev` destroyed after each session; no NAT gateway; smallest database and task sizes |

---

## 6. The plan

The project followed a 21-day plan in 7 phases, plus an optional Day 22 for HTTPS.

| Phase | Days | Content | Status |
| --- | --- | --- | --- |
| 1 | 1 to 3 | API code, container, local tests | Day 1 done; Days 2 and 3 skipped (no Docker) |
| 2 | 4 to 6 | Terraform state, network, KMS | Done |
| 3 | 7 to 9 | Database, secrets, registry, evidence | Done |
| 4 | 10 to 12 | Shared folder, CI pipeline, break the pipeline | Done |
| 5 | 13 to 15 | ECS service, load balancer, WAF, proof | Done |
| 6 | 16 to 18 | Approval gate, deployment, rollbacks | Done |
| 7 | 19 to 21 | Audit, monitoring, failure tests, README | Done |
| Extra | 22 | HTTPS with a domain and ACM | Done on 24 November 2026 |

The original plan was corrected after an outside review. The corrections included pinning the Trivy action to a commit ID, moving the registry into a separate `shared` folder, IAM users instead of OIDC, and API key and idempotency key requirements on the API.

### Plan items that were not done

These were suggested as "mid-level upgrades" in the plan. They are **not** in the repository, so they are not claimed anywhere:

| Item | Status |
| --- | --- |
| A planned (not applied) `prod` environment | Not done |
| A decision record "why ECS Fargate and not EKS" as a file | Not done as a file. The reasoning is in chapter 13 |
| A cost section with measured daily cost in the README | Not done. **Missing:** the real daily cost was not recorded |
| A dedicated least-privilege database user for the app | Not done. The app uses the RDS master user (see chapter 12) |
| AWS Budgets alert | **Missing:** not recorded whether this was created |

---

## 7. Timeline

| Date | Work | Source |
| --- | --- | --- |
| 15 to 19 November 2026 | Days 1 and 4 to 21 | Conversation history |
| 18 November 2026 | Deployment and rollback measurements | `docs/rollback.md` |
| 17 to 19 November 2026 | Measured results in the README (original set) | README |
| 24 November 2026 | HTTPS added, merged in pull request #5, `dev` destroyed | Repository, command output |

**Missing:** the exact date of each individual day was not recorded.
