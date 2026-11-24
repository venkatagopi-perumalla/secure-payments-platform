# 13. Interview preparation

Use this chapter to talk about the project in your own words. Every number here is measured and appears in the README or `docs/`. Do not add numbers that are not there.

---

## 1. Key concepts to explain simply

| Concept | One-sentence explanation |
| --- | --- |
| VPC endpoint | A private door from my network to one AWS service, so my containers do not need internet access |
| Security group referencing | "Only the load balancer's group may reach the app" stays true even when IP addresses change |
| Customer-managed KMS key | The company controls the encryption key and its policy, and every use is logged |
| Managed master password | AWS generates, stores and rotates the database password; no person sees it |
| Immutable image tags | A tag can never be overwritten, so what was scanned is what runs |
| SBOM | A list of every package in the image, to answer "are we affected?" quickly |
| Idempotency key | A client-chosen ID for a request, so a retry never creates a second payment |
| Circuit breaker | ECS stops a failing rollout and returns to the last working version by itself |
| Environment secret | A secret GitHub releases only after the environment's approval rules pass |
| Log file validation | Signed digests that prove CloudTrail logs were not changed |
| SLO and error budget | A reliability target, and the amount of failure it allows before reliability work comes first |
| 301 redirect | Tells clients "use HTTPS instead", so `http://` still ends up encrypted |
| DNS validation (ACM) | Proves domain ownership with a DNS record, so certificates issue and renew with no email |
| Drift | When the real resource differs from the code |

---

## 2. Trade-offs I made

| Decision | Chosen | Alternative | Why |
| --- | --- | --- | --- |
| Compute | ECS Fargate | EKS | One small stateless service: no nodes, no control-plane cost, simpler security model. I would choose EKS for many services, a platform team or Kubernetes tooling. My EKS project shows I can do both |
| Outbound access | VPC endpoints | NAT gateway | Only named AWS services are reachable; smaller attack surface |
| Endpoint placement | One zone | Two zones | Cost in a lab; production would use both |
| CI credentials | Two scoped IAM users | OIDC | OIDC blocked by the organisation SCP; risk reduced with scope and approval |
| Region | eu-north-1 | eu-west-1 | Only region allowed; still in the EU |
| Deploy ownership | Pipeline owns the task definition (`ignore_changes`) | Terraform owns it | Avoids Terraform undoing deployments; cost is that some Terraform changes are skipped |
| Port 80 | Redirect to HTTPS | Close it | Clients typing `http://` still reach the secure endpoint |
| Scanning | Blocking, with a reviewed ignore file | Report only | Report-only findings get ignored |
| Database | Multi-AZ for the failover test | Single-AZ | Measured recovery; doubles database cost |
| Environment lifetime | Destroy `dev` after use | Keep it running | Cost; also proves rebuild from code |

---

## 3. Twenty interview questions with answers

**1. Tell me about this project.**
I built a small payments API and the AWS platform around it the way a regulated team would run it: private network, customer-managed encryption, scanned immutable images, approval-gated deployments, audit logging and alarms. Then I broke it on purpose and measured recovery. For example, a database failover under load caused about 10 seconds of failed payments, and a broken release rolled back by itself in about 4 minutes with no user errors.

**2. How does a request reach the database?**
DNS points `api.venkatagopiperumalla.com` at the load balancer. HTTP is redirected to HTTPS. WAF checks the request. The load balancer forwards to a Fargate task in a private subnet on port 8000. The app checks the API key and idempotency key and writes to PostgreSQL over TLS. The database is in a separate private subnet and accepts only the app's security group.

**3. Your containers have no internet access. How do they pull images and read secrets?**
VPC endpoints: interface endpoints for ECR API, ECR Docker, CloudWatch Logs and Secrets Manager, and an S3 gateway endpoint for image layers. Private DNS makes the normal AWS addresses resolve to those endpoints.

**4. Why no NAT gateway?**
A NAT gateway gives the tasks a route to the whole internet. Endpoints give access only to the services they need. It also saves the NAT cost. The trade-off is that adding a new AWS dependency needs a new endpoint.

**5. How do you handle the database password?**
I don't. RDS generates it, stores it in Secrets Manager encrypted with my KMS key, and rotates it. ECS injects it at task start. It never appears in code, state I wrote, or chat. One known gap: tasks read it only at start, so after rotation they need a restart. The fix is fetching per connection or RDS Proxy.

**6. What stops a vulnerable image reaching production?**
Three gates. CI scans dependencies, Terraform and the built image, and fails on HIGH or CRITICAL before the push. ECR scans on push. The deploy workflow refuses any image whose scan status is not `COMPLETE`. On the first real run, the image scan blocked a HIGH zlib vulnerability in the base image.

**7. Why pin a GitHub Action to a commit ID?**
Tags can be moved. In March 2026, Trivy Action version tags were moved to malicious code. A full commit ID cannot be changed. I pinned Trivy and recorded the version in a comment.

**8. How do approvals work?**
Deploys and rollbacks use a GitHub `production` environment with me as a required reviewer and only `main` allowed. The deploy user's AWS key is an environment secret, so the job cannot even sign in to AWS until someone approves. A run from another branch was refused in 6 seconds.

**9. A deploy shows green. How do you know the new version is running?**
The last step compares the task definition the pipeline deployed with the one ECS is actually running. If the circuit breaker rolled back, they differ, and the job fails. A rolled-back release once correctly ended red.

**10. Describe a failed release.**
I made a release that crashed on start-up with a `KeyError`. CI was green because the tests skip start-up code. ECS started new tasks, they crashed, and after 3 failures the circuit breaker returned to the previous revision in about 4 minutes. Old tasks kept serving, so users saw 0 errors. The lesson was to add a start-up test, and that runtime safety nets catch what tests miss.

**11. How long does a rollback take?**
Automatic: about 4 minutes. Manual, through the approved rollback workflow: 3 minutes 0 seconds from approval to stable. A normal deployment took 2 minutes 3 seconds with 0 of 300 health checks failed.

**12. What happened in the database failover test?**
I made the database Multi-AZ, ran a probe that created one payment per second, and forced a failover. 291 of 300 were accepted; 8 returned 500 and 1 timed out, all within about 10 seconds. AWS said the failover took 48 seconds. So I report what users saw, not only what AWS reports. The app recovered without a restart because it opens a new connection per request.

**13. Those 9 payments failed. Is that acceptable?**
For a payments client, no. But they are safe to retry: each had an idempotency key, so a retry with the same key cannot create a duplicate. The fix is client retries with backoff. I listed it as a known gap.

**14. How fast can you restore the database?**
Point-in-time restore to a new encrypted, private instance took 14.2 minutes. I did not query the restored copy because it is private; that is a stated gap.

**15. How do you know who changed production?**
CloudTrail records every API call, with log file validation so the logs can be proven unedited. `UpdateService` events showed all 4 deploys and the rollback by the deploy user, and one deliberate test by my admin user.

**16. What alerts do you have?**
Six CloudWatch alarms through SNS email: 5xx rate above 2 percent, p95 latency above 1 second, unhealthy targets, ECS CPU, database CPU and low storage. I forced the 5xx alarm: the email arrived, and the OK email followed 58 seconds later.

**17. What is your SLO?**
99.5 percent of requests without a 5xx over 30 days, measured at the load balancer. That allows about 3 hours 36 minutes of full failure. If half the budget is gone before day 20, reliability work comes before features.

**18. Tell me about a hard problem you debugged.**
The deploy gate kept saying "Scan status None" for images that had been scanned. First I found the images were OCI indexes with provenance attestations, which ECR basic scanning skips, so I built with `--provenance=false`. Then the status was still empty: AWS's newer basic scanning no longer fills it in `DescribeImages`. I switched the gate to `DescribeImageScanFindings` and gave the deploy user exactly that permission. The lesson: check the gate's data source, not just the input.

**19. What would you change for production?**
OIDC instead of access keys; two approvers; TLS from the load balancer to the tasks; a least-privilege database user; endpoints in both zones; KMS keys for CloudTrail and SNS; deletion protection and final snapshots; client retries; cross-region backups; and a real on-call process.

**20. Why ECS and not Kubernetes?**
Fit, not fashion. One small service with no need for Kubernetes tooling is simpler, cheaper and safer on Fargate: no nodes to patch and no control plane. For many services and a platform team, I would choose EKS, and my other project shows I can run it with GitOps.

---

## 4. Questions to be ready for (honest answers)

| Question | Honest answer |
| --- | --- |
| Is it PCI compliant? | No. It uses controls aligned with common payments themes, with evidence. It is not certified |
| Did you write all of it alone? | I built, ran, broke and fixed everything myself, using an AI assistant for guidance and code drafts, and verified each step with real AWS output |
| Is it running now? | No. The environment is destroyed after each session to save cost. The evidence is in `docs/evidence/` |
| Why did Day 21's image pull fail? | Unknown. The tag was missing from ECR; I fixed it by deploying an existing tag. I did not verify the cause. The lifecycle rule is a guess I did not check |
| What did it cost? | I did not record the exact cost. It was destroyed after each session to keep it low |

---

## 5. The 2-minute pitch

> I built a payments API on AWS the way a regulated team would run it, and then I tested whether it really holds up.
>
> The API runs on ECS Fargate in private subnets with no internet route. It reaches AWS through VPC endpoints. The only way in is a load balancer with HTTPS on my own domain and AWS WAF in front. The database is PostgreSQL on RDS, encrypted with a customer-managed key, with TLS forced and a password that AWS generates and rotates.
>
> Every change goes through a pull request with 12 tests and Trivy scans. Images are tagged with the commit ID, immutable and scanned. Deployments need a named approver, the deploy key is only released after approval, and only main can deploy.
>
> Then I broke it. A normal deploy took about 2 minutes with 0 of 300 checks failing. A release that crashed on start-up rolled back automatically in about 4 minutes with no user errors. A forced database failover caused about 10 seconds of failed payments. A point-in-time restore took 14.2 minutes.
>
> Everything is in Terraform, there are 42 documented controls with evidence, and I list the gaps honestly, like the lab account blocking OIDC.

---

## 6. The 5-minute version

Use the 2-minute pitch, then add:

1. **Constraints (30 s):** the organisation SCP allowed only eu-north-1 and blocked IAM OIDC. I used two scoped IAM users and put the deploy key behind approval.
2. **Architecture detail (1 min):** three subnet tiers in two zones; security groups that reference each other; empty task role; read-only file system; `bootstrap`, `shared` and `dev` Terraform split by lifetime.
3. **One debugging story (1 min):** the "Scan status None" gate (question 18).
4. **What I measured from the user's side (30 s):** AWS said failover took 48 seconds, but users saw about 10 seconds of errors, and the API recovered without a restart.
5. **What I would do next (1 min):** OIDC, two approvers, end-to-end TLS, least-privilege database user, client retries, cross-region backups.

---

## 7. CV bullets (verified numbers only)

- Built a payments API platform on AWS with Terraform: private VPC with VPC endpoints instead of NAT, ECS Fargate, RDS PostgreSQL encrypted with a customer-managed KMS key, ALB with HTTPS (ACM) and AWS WAF.
- Designed GitHub Actions CI/CD with 12 tests against real PostgreSQL, blocking Trivy scans, SBOMs, immutable ECR images and approval-gated deployments; deploy refuses unscanned images and fails if ECS rolls back.
- Measured resilience: zero-error deployment in 2 min 3 s; automatic circuit-breaker rollback in about 4 min with 0 user errors; Multi-AZ failover under load with about 10 s of failed requests (291 of 300 accepted); point-in-time restore in 14.2 min.
- Implemented audit and monitoring: CloudTrail with log file validation, 5 AWS Config rules, 6 CloudWatch alarms to email, dashboard and a 99.5 percent SLO; documented 42 controls with evidence.

---

## 8. Before an interview

- Re-read chapters 02, 10 and 11.
- Be ready to draw the architecture from memory (chapter 02).
- Know the numbers in section 7 exactly.
- Know your gaps (chapter 12, section 3) and say them before you are asked.
