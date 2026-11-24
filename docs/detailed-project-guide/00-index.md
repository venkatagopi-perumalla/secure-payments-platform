# Secure Payments API on AWS: Detailed Project Guide

This guide explains the whole project from start to finish: what was built, why each part exists, every command that mattered, every error that happened, and what I learned. It is written so that someone new to AWS can follow it, and so that I can use it to prepare for interviews.

The short summary is in the main [`README.md`](../../README.md). This guide is the long version.

---

## 1. The project in one paragraph

A small payments API (Python FastAPI and PostgreSQL) and the AWS platform around it, built the way a regulated payments team would run it. The API runs on ECS Fargate in private subnets, behind an Application Load Balancer with AWS WAF and HTTPS. The database is RDS PostgreSQL 16, encrypted with a customer-managed KMS key. Every change goes through a GitHub pull request with tests and security scans, every image is scanned and immutable, and every production deployment needs a named approver. CloudTrail, AWS Config and CloudWatch alarms provide the audit trail and alerting. I then broke it on purpose (bad releases, a stopped task, a database failover, a restore, a traffic burst) and measured how it recovered.

This is a portfolio project in a lab AWS account. It is **not** certified against PCI DSS or any other standard.

---

## 2. Status of the project

| Item | Status | Source |
| --- | --- | --- |
| Days 1 and 4 to 21 of the build plan | Done | Conversation history, repository |
| Days 2 and 3 (local Docker) | Skipped on purpose: no Docker on the laptop. Tests run in CI against a real PostgreSQL instead | Conversation history |
| HTTPS on `api.venkatagopiperumalla.com` | Done on 24 November 2026, merged in pull request #5 | Repository, command output |
| Measured tests | Done between 17 and 24 November 2026 | README, `docs/evidence/` |
| `dev` environment | Destroyed after the work (86 resources destroyed on 24 November 2026) | Command output |
| `shared` (ECR, CI users) and `bootstrap` (Terraform state bucket) | Still exist | Conversation history |
| Root cause of the Day 21 `CannotPullContainerError` | **Not verified.** See chapter 11 | Conversation history |

Because `dev` is destroyed, the API address is not live. The screenshots in `docs/evidence/` are the proof that it worked.

---

## 3. Table of contents

| # | File | What it covers |
| --- | --- | --- |
| 00 | `00-index.md` | This page: summary, status, how to read the guide, repository map |
| 01 | `01-context-and-constraints.md` | Why the project exists, the goals, and the account limits that shaped it (blocked region, blocked OIDC) |
| 02 | `02-architecture.md` | The full architecture with a Mermaid diagram, and how a request travels through it |
| 03 | `03-setup-and-day-1.md` | Tools installed on Windows, AWS access, the repository layout and the first commit |
| 04 | `04-terraform-foundation.md` | Terraform state bucket, the `bootstrap` / `shared` / `dev` split, modules, and the network (VPC, subnets, VPC endpoints, security groups, KMS) |
| 05 | `05-data-layer.md` | RDS PostgreSQL: encryption, forced TLS, AWS-managed password, backups, Multi-AZ |
| 06 | `06-ci-pipeline.md` | GitHub Actions CI: tests, Trivy scans, SBOM, image build and push to ECR |
| 07 | `07-ecs-alb-waf.md` | ECS Fargate service, load balancer, WAF, autoscaling, and HTTPS with ACM |
| 08 | `08-change-control.md` | Approval-gated deployments, rollback workflow, branch protection |
| 09 | `09-audit-monitoring.md` | CloudTrail, AWS Config rules, CloudWatch alarms, dashboard, SNS email, SLO |
| 10 | `10-resilience-tests.md` | Every failure test: method, exact numbers, evidence |
| 11 | `11-troubleshooting-case-studies.md` | Every verified error: symptom, investigation, root cause, fix, lesson |
| 12 | `12-security-and-testing.md` | The security controls, accepted risks, known gaps and the test suite |
| 13 | `13-interview-preparation.md` | Key concepts, trade-offs, 20 interview questions with answers, 2-minute and 5-minute pitches |

HTTPS was added after this table of contents was approved. It is covered inside chapter 07 (how it was built) and chapter 11 (the problems hit while building it), so no new chapter was added.

---

## 4. How to read this guide

- **New to AWS?** Read 01, 02 and 03 first, then follow the chapters in order.
- **Preparing for an interview?** Read 02, 10, 11 and 13.
- **Want only the proof?** Read 10, then open the screenshots in `docs/evidence/`.

### Labels used in this guide

| Label | Meaning |
| --- | --- |
| **Verified** | Checked against the repository, a command output or a screenshot |
| **Unverified** | Believed to be true but not proven. The guide says why |
| **Missing** | Information that was never recorded. The guide does not guess it |

### Sensitive values

No passwords, access keys, tokens, secrets, email addresses or payment data appear in this guide. Where a command needs one, it is shown as a placeholder, for example `<DEPLOY_ACCESS_KEY_ID>` or `<YOUR_EMAIL>`.

### Commands

All commands were run in **Windows PowerShell** unless a chapter says otherwise. Commands in this guide are for explanation only. Some of them create or delete real AWS resources, and AWS charges for running resources.

---

## 5. Repository map

```
secure-payments-platform/
├── README.md                     Short project summary and measured results
├── .trivyignore                  Accepted security findings, each with a reason
├── .github/workflows/
│   ├── ci.yml                    Tests, scans, image build and push
│   ├── deploy.yml                Approval-gated deployment to ECS
│   ├── rollback.yml              Approval-gated rollback to an earlier task definition
│   └── identity-check.yml        Confirms which AWS identity CI is using
├── app/
│   ├── Dockerfile                Container image for the API
│   ├── app/main.py               The FastAPI payments API
│   └── tests/                    Unit and integration tests
├── terraform/
│   ├── bootstrap/                S3 bucket that holds Terraform state
│   ├── envs/shared/              ECR repository and the two CI users (kept between rebuilds)
│   ├── envs/dev/                 The environment that is built and destroyed
│   └── modules/
│       ├── network/              VPC, subnets, VPC endpoints, security groups
│       ├── database/             RDS PostgreSQL
│       └── service/              ECS, load balancer, WAF, IAM roles
└── docs/
    ├── architecture.png          Architecture diagram
    ├── controls.md               42 controls, each with its evidence
    ├── rollback.md               Rollback procedure and measurements
    ├── slo.md                    Service level objective (99.5 percent)
    ├── evidence/                 Screenshots and the failover probe CSV
    └── detailed-project-guide/   This guide
```

---

## 6. Key facts at a glance

| Fact | Value |
| --- | --- |
| AWS region | eu-north-1 (Stockholm). The lab account blocks eu-west-1 |
| Network | VPC `10.30.0.0/16`, public, app and data subnets in two availability zones, no NAT gateway |
| Compute | ECS Fargate, 2 to 4 tasks, port 8000 |
| Database | RDS PostgreSQL 16, `db.t4g.micro`, KMS-encrypted, TLS forced |
| Entry point | Application Load Balancer with AWS WAF; HTTPS on 443, port 80 redirects |
| Domain | `api.venkatagopiperumalla.com` (DNS at Porkbun) |
| Infrastructure as code | Terraform with AWS provider `~> 6.0`, state in S3 with a lock file |
| CI/CD | GitHub Actions; Trivy pinned to a commit ID |
| Controls documented | 42, in `docs/controls.md` |
| Build period | 15 to 19 November 2026, HTTPS on 24 November 2026 |
