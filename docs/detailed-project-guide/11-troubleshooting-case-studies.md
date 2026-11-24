# 11. Troubleshooting case studies

Every verified error, failure and troubleshooting attempt in the project, in one place. Each case uses the same format.

| Field | Meaning |
| --- | --- |
| Symptom | What I saw |
| Investigation | What I checked |
| Root cause | Why it happened. Marked **Unverified** when not proven |
| Fix | What changed |
| Lesson | What I do differently now |
| Status | Where the facts come from |

The cases are grouped by area and numbered for reference.

---

## Index

| # | Case | Area | Severity |
| --- | --- | --- | --- |
| 1 | Region eu-west-1 denied | Account | Design change |
| 2 | IAM OIDC provider blocked | Account | Design change |
| 3 | `python` and `aws` not found after install | Laptop | Minor |
| 4 | No Docker on the laptop | Laptop | Plan change |
| 5 | Folder confusion on Day 1 | Git | Minor |
| 6 | Scrambled `bootstrap/main.tf` | Terraform | Minor |
| 7 | `terraform init` found an empty directory | Terraform | Minor |
| 8 | Parameter group drift | Terraform | Medium |
| 9 | Plan-style commit messages | Git | Minor |
| 10 | Doubled workflow path | Git | Minor |
| 11 | zlib HIGH vulnerability blocked the image | CI | Gate worked |
| 12 | ECR push 403 on the manifest check | IAM | Medium |
| 13 | `.trivyignore` change not applied the first time | CI | Minor |
| 14 | `git add .` from a subfolder missed 4 files | Git | Minor |
| 15 | Sequential WAF burst did not trip the limit | Testing | Minor |
| 16 | Deploy refused: "Scan status None" | CD, ECR | **Major** |
| 17 | Trailing dot in `ECR_REGISTRY` | CD | Medium, no user impact |
| 18 | Circuit breaker rollback ended the deploy red | CD | Expected |
| 19 | PowerShell split `imageTag=(git rev-parse HEAD)` | PowerShell | Minor |
| 20 | `aws_caller_identity` missing in `dev` | Terraform | Minor |
| 21 | Email address visible in screenshots | Evidence | Privacy |
| 22 | `CannotPullContainerError` on Day 21 | ECS, ECR | **Major, root cause unverified** |
| 23 | RDS zones did not appear to swap after failover | Testing | Minor |
| 24 | README and diagram overwritten by another project's files | Files | Medium |
| 25 | README overclaimed action pinning | Documentation | Accuracy |
| 26 | `readme-personal` branch pushed without changes | Git | Minor |
| 27 | Private Gmail address on 44 commits | Git | Privacy |
| 28 to 38 | Problems while adding HTTPS | Various | Minor |

---

## Account constraints

### Case 1: Region eu-west-1 denied

- **Symptom:** actions in eu-west-1 (Ireland) were denied.
- **Investigation:** the denial came from the AWS Organization, not from IAM permissions in the account.
- **Root cause:** a Service Control Policy allows only eu-north-1.
- **Fix:** everything uses **eu-north-1 (Stockholm)**: every provider block, workflow and CLI default.
- **Lesson:** when an administrator is denied, look above the account: SCPs win over IAM.
- **Status:** verified (conversation history).

### Case 2: IAM OIDC provider blocked

- **Symptom:** creating the GitHub OIDC identity provider was denied.
- **Root cause:** the organisation's SCP blocks it.
- **Fix:** two least-privilege IAM users with access keys stored as GitHub secrets; the deploy key is an environment secret released only after approval.
- **Lesson:** when the ideal control is not available, reduce the risk of the fallback and document the gap honestly.
- **Status:** verified (conversation history; `github_users.tf`; README).

---

## Laptop and Git

### Case 3: `python` and `aws` not found after install

- **Symptom:** `python` and `aws` were "not recognised" right after `winget` installed them.
- **Root cause:** an open PowerShell window keeps the `PATH` it started with.
- **Fix:** open a new PowerShell window.
- **Lesson:** new tool, new terminal.
- **Status:** verified (conversation history).

### Case 4: No Docker on the laptop

- **Symptom:** `docker` was not found.
- **Decision:** skip Days 2 and 3 (local container run). CI builds the image and runs the database tests against a real PostgreSQL container.
- **Impact:** `docker-compose.yml` exists but was never run.
- **Status:** verified (conversation history).

### Case 5: Folder confusion on Day 1

- **Symptom:** the laptop's folders did not match the plan document, and the chat steps differed from the document.
- **Root cause:** **Unverified.** Files were being created in a different order and place from the document.
- **Fix:** all Day 1 files were provided as one folder and copied into the repository; `pytest` and `git status` confirmed the result.
- **Lesson:** follow one source of instructions; check `pwd` and `git status` often.
- **Status:** verified (conversation history). **Missing:** exact paths.

### Case 9: Plan-style commit messages

- **Symptom:** commits were titled "Day 8" and "Day 9", which read like a tutorial.
- **Fix:** the messages were reworded and the branch force-pushed, before branch protection blocked force pushes on `main`.
- **Lesson:** commit messages describe the change.
- **Status:** verified (conversation history).

### Case 10: Doubled workflow path

- **Symptom:** a workflow file ended up under a path with `.github\workflows` twice.
- **Root cause:** a relative path starting with `.github\workflows` was used while already inside that folder.
- **Fix:** moved the file; ran commands from the repository root.
- **Status:** verified (conversation history). **Missing:** the exact path.

### Case 14: `git add .` from a subfolder missed 4 files

- **Symptom:** a commit did not include 4 changed files.
- **Root cause:** `git add .` stages only the current folder and below.
- **Fix:** staged from the repository root and committed again.
- **Lesson:** `git status` before every commit.
- **Status:** verified (conversation history).

### Case 26: `readme-personal` branch pushed without changes

- **Symptom:** the branch was pushed, but GitHub showed nothing to compare.
- **Root cause:** **Unverified.** Most likely the README edit was not saved or committed before the push.
- **Fix:** the change was committed and pushed again; merged as pull request #2.
- **Status:** verified (conversation history; commit `71fd873`). The branch may still exist on GitHub and can be deleted.

### Case 27: Private Gmail address on 44 commits

- **Symptom:** the commit author email on 44 commits was a personal Gmail address, visible to anyone viewing the history.
- **Fix (24 November 2026):** `git config --global user.email` set to the GitHub **noreply** address. Older commits were left as they are; rewriting public history was not worth the risk.
- **Related:** case 37.
- **Status:** verified (conversation history; command output).

---

## Terraform

### Case 6: Scrambled `bootstrap/main.tf`

- **Symptom:** the file contained broken, out-of-order text.
- **Root cause:** a bad paste.
- **Fix:** replaced with a clean copy.
- **Lesson:** read a file back after pasting.
- **Status:** verified (conversation history).

### Case 7: `terraform init` found an empty directory

- **Symptom:** `terraform init` reported no configuration files.
- **Root cause:** the file was open in VS Code but not saved.
- **Fix:** Ctrl+S, then `init`.
- **Status:** verified (conversation history). It happened again with `alb.tf` on 24 November (case 31).

### Case 8: Parameter group drift

- **Symptom:** every `terraform plan` showed a change to the database parameter group.
- **Investigation:** compared the parameter as AWS returned it with the code.
- **Root cause:** `apply_method` for `rds.force_ssl` differed between Terraform's default and what AWS reported.
- **Fix:** `apply_method = "pending-reboot"` set explicitly.
- **Lesson:** a plan that never settles is drift caused by a default value.
- **Status:** verified (conversation history; README; `modules/database/main.tf`).

### Case 20: `aws_caller_identity` missing in `dev`

- **Symptom:** the plan failed on `audit.tf`, which needs the account ID.
- **Root cause:** the data source existed in `bootstrap` and `shared`, not in `dev`.
- **Fix:** `data "aws_caller_identity" "me" {}` added to `audit.tf`.
- **Status:** verified (conversation history; `audit.tf`).

---

## CI, IAM and the registry

### Case 11: zlib HIGH vulnerability blocked the image

- **Symptom:** the first `build-and-push` run failed at the image scan.
- **Root cause:** the `python:3.12-slim` base image contained a zlib package with a fixable HIGH vulnerability.
- **Fix:** `apt-get update && apt-get upgrade -y` in the Dockerfile.
- **Lesson:** the gate did its job. The image never reached ECR.
- **Status:** verified (README; `docs/controls.md`).

### Case 12: ECR push 403 on the manifest check

- **Symptom:** `docker push` failed with **403** on a `HEAD` request for the manifest.
- **Root cause:** Docker checks whether the image already exists before uploading. That needs `ecr:BatchGetImage` and `ecr:GetDownloadUrlForLayer`, missing from the push-only policy.
- **Fix:** added both actions to `payments-github-ci` in `shared`.
- **Lesson:** least privilege is found by testing; the error names the missing step.
- **Status:** verified (conversation history; `github_users.tf`).

### Case 13: `.trivyignore` change not applied the first time

- **Symptom:** the PowerShell block that should have created `.trivyignore` did not take effect the first time.
- **Root cause:** **Unverified.** The PowerShell block that wrote the file did not run as intended.
- **Fix:** ran it again and read the file back with `Get-Content`.
- **Status:** verified (conversation history). **Missing:** exact error.

### Case 16: Deploy refused: "Scan status None"

The biggest case in the project.

- **Symptom:** `deploy.yml` printed `Scan status: None` and refused images that had been scanned.
- **Investigation and attempts:**
  1. Inspected the image: it was an **OCI image index** with a provenance attestation, which newer Docker Buildx creates by default.
  2. ECR basic scanning does not scan image indexes. Fix: `docker build --provenance=false --sbom=false`.
  3. A manual scan of the old image hit the quota: **`LimitExceeded`**.
  4. Another attempt returned **`UnsupportedImageType`**, confirming the index format.
  5. New plain images still showed no status in `DescribeImages`: AWS's newer basic scanning no longer fills that field.
  6. Switched the check to `DescribeImageScanFindings` and added `ecr:DescribeImageScanFindings` to the deploy user.
  7. Added an account-level registry scanning rule, because the repository's own `scan_on_push` was not being applied.
- **Root cause:** two at once: an image format that basic scanning skips, and an API field that no longer carries the value.
- **Lesson:** when a gate fails, check the gate's data source too. Read current AWS behaviour, not old examples.
- **Status:** verified (conversation history; README; `ci.yml`, `deploy.yml`, `ecr_scanning.tf`, `github_users.tf`). **Unverified:** the exact order of steps 2 to 4.

### Case 17: Trailing dot in `ECR_REGISTRY`

- **Symptom:** revision 3's tasks would not start; ECS events said it **failed to normalize the image reference**.
- **Root cause:** the GitHub variable `ECR_REGISTRY` ended with a `.`.
- **Impact:** none for users: revision 2 kept serving 2 of 2 tasks.
- **Fix:** removed the dot; deployed again.
- **Lesson:** rolling deployments make many mistakes invisible to users; ECS service events explain what happened.
- **Status:** verified (README; `docs/controls.md`; `ecs-bad-image-event.png`).

### Case 18: Circuit breaker rollback ended the deploy red

- **Symptom:** the deploy of revision 5 ended red: "deployment was likely rolled back by the deployment circuit breaker".
- **Root cause:** intended. Revision 5 had a deliberate `KeyError` at start-up.
- **Result:** rolled back to revision 4 in about 4 minutes with 0 user errors.
- **Lesson:** red is correct here. The pipeline must not report success when the release is not running.
- **Status:** verified (`docs/rollback.md`).

---

## PowerShell and testing

### Case 15: Sequential WAF burst did not trip the limit

- **Symptom:** no 403s from a simple loop.
- **Root cause:** one request at a time was too slow to exceed 2,000 requests in the WAF window.
- **Fix:** parallel `curl` bursts. Second burst: 3,000 of 3,000 blocked.
- **Status:** verified (conversation history; `waf-block.png`).

### Case 19: PowerShell split `imageTag=(git rev-parse HEAD)`

- **Symptom:** an AWS CLI command with `--image-ids imageTag=(git rev-parse HEAD)` failed.
- **Root cause:** PowerShell does not join the output of `(...)` into the surrounding argument the way the command expected.
- **Fix:** `$tag = git rev-parse HEAD`, then `imageTag=$tag`.
- **Status:** verified (conversation history).

### Case 23: RDS zones did not appear to swap after failover

- **Symptom:** after the forced failover, the instance listing did not obviously show the zones swapped.
- **Fix:** read `aws rds describe-events`: failover started 13:01:15, completed 13:02:03.
- **Lesson:** event logs are the source of truth.
- **Status:** verified (conversation history; `rds-failover-events.png`).

---

## Case 22: `CannotPullContainerError` on Day 21

Documented exactly as it happened. **The root cause is not verified.**

- **Symptom:** while rebuilding `dev` on Day 21, ECS tasks failed with `CannotPullContainerError`: image tag `8661334f...` not found.
- **Context:** the tag came from `local.auto.tfvars`, used only when Terraform first creates the service.
- **Resolution:** ran `deploy.yml` with an existing tag, `1b6112245c50...`. Result: 2 of 2 tasks running and ready.
- **Root cause:** **Unverified.** The image was not in ECR at that moment. The ECR lifecycle rule (keep 30 images) is one possible cause, but it was **not checked**. Nothing else was investigated.
- **Follow-up (24 November 2026):** before the HTTPS rebuild, the tag in `local.auto.tfvars` was compared with the newest ECR images. It was stale again and was updated to `e5490661...` before applying.
- **Lesson:** a value stored outside the pipeline goes stale. Check the image exists before a rebuild.
- **Status:** symptom and resolution verified (conversation history). Root cause unverified.

---

## Evidence and documentation

### Case 21: Email address visible in screenshots

- **Symptom:** the alarm screenshots showed the personal email address.
- **Fix:** cropped before adding to `docs/evidence/`.
- **Lesson:** check every screenshot for personal data before committing.
- **Status:** verified (conversation history).

### Case 24: README and diagram overwritten by another project's files

- **Symptom:** the README and architecture image in the repository turned into the EKS project's versions.
- **Root cause:** both projects' files were downloaded with the same names (`README.md`, `architecture.png`) into the Downloads folder, and the wrong ones were moved into this repository.
- **Fix:** files were provided again with unique names and moved into place.
- **Lesson:** use unique file names for downloads that will be moved into a repository.
- **Status:** verified (conversation history).

### Case 25: README overclaimed action pinning

- **Symptom:** the README said all actions were pinned to commit IDs.
- **Investigation:** read `ci.yml`: only Trivy is pinned by commit ID.
- **Fix:** README corrected to say Trivy is pinned and why.
- **Lesson:** check every claim against the file.
- **Status:** verified (conversation history; `ci.yml`).

---

## Cases 28 to 38: adding HTTPS (24 November 2026)

| # | Symptom | Root cause | Fix |
| --- | --- | --- | --- |
| 28 | `git checkout -b https`: branch already exists | An old empty local branch | Confirmed no unique commits (`git log main..https`), deleted it, recreated it |
| 29 | `git diff` stuck on a `:` prompt | Git opened its pager | Pressed `q`; used `git --no-pager` after that |
| 30 | `Get-Variable : A positional parameter cannot be found` | Terraform code pasted into PowerShell | `Add-Content` with a here-string to append to the file |
| 31 | `aws_lb_listener "https" has not been declared` | `alb.tf` edited in VS Code but not saved to disk; `Select-String` showed only the old listener | Wrote the file with `Set-Content`; checked with `Select-String` |
| 32 | `"certificate_arn" is required` | `app.tf` not yet updated | Added the line |
| 33 | `terraform apply` prompted for many variables | Run from `modules\service`, not `envs\dev` | Ran from `envs\dev`; nothing had been created |
| 34 | `nslookup api...` printed a name and no address | No record yet | `nslookup -type=CNAME` showed only the SOA record: the name was free |
| 35 | No certificate details from `curl.exe -v` | Windows `curl` uses schannel, which does not print them | Read the certificate with .NET `HttpWebRequest` |
| 36 | The .NET request got **403** | No User-Agent header; blocked by the WAF common rule set | No fix needed; TLS had already succeeded; proved WAF covers HTTPS |
| 37 | Push rejected: `GH007: Your push would publish a private email address` | GitHub email privacy protection | noreply address in git config; `git commit --amend --reset-author --no-edit`; pushed |
| 38 | `terraform destroy` said `0 destroyed` | Run from the repository root | Ran from `envs\dev`: 86 destroyed |

Also on that day: `curl.exe --tls-max 1.1` failed with `SEC_E_UNSUPPORTED_FUNCTION`. This was **not** counted as proof that the server refuses TLS 1.1, because Windows itself may have old TLS disabled. The listener policy is the proof.

All verified from command output on 24 November 2026.

---

## Patterns across all cases

| Pattern | Cases | Habit |
| --- | --- | --- |
| Wrong folder | 5, 10, 14, 33, 38 | Check the prompt path; run Terraform only from the environment folder |
| File not saved or not written | 7, 13, 26, 31 | Read the file back from disk (`Get-Content`, `Select-String`) |
| A gate doing its job | 11, 17, 18 | Treat a red pipeline as information, not an obstacle |
| Missing permission | 12, 16 | Add exactly the action named in the error |
| Tool's data, not the input | 16, 23 | Check where the tool gets its answer |
| Stale reference | 22 | Verify an image exists before using its tag |
| Personal data | 21, 27, 37 | Check screenshots and commit metadata |
