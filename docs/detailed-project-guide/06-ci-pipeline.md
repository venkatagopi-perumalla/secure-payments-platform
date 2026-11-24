# 06. The CI pipeline

This chapter covers Days 10 to 12: the kept `shared` folder with the CI users, the GitHub Actions pipeline, and the tests that proved it blocks bad code.

---

## 1. GitHub Actions in five sentences

- A **workflow** is a YAML file in `.github/workflows/`.
- It runs on **events**, such as a pull request or a push to `main`.
- It contains **jobs** that run on fresh GitHub-hosted Linux machines (`ubuntu-latest`).
- Each job has **steps**: shell commands or reusable **actions** written by others.
- **Secrets** are encrypted values stored in GitHub and passed to steps without being printed.

---

## 2. Day 10: the `shared` folder

`terraform/envs/shared` holds what must survive a nightly `dev` destroy.

### Two IAM users instead of OIDC

The organisation blocks the IAM OIDC provider (chapter 01), so two users with access keys were created, each with the smallest permissions that work.

| User | Used by | Can do |
| --- | --- | --- |
| `payments-github-ci` | `ci.yml`, `identity-check.yml` | Get an ECR login token; push and read images in `payments-api` only |
| `payments-github-deploy` | `deploy.yml`, `rollback.yml` | Register task definitions; update and describe **one** ECS service; pass **two** roles to ECS only; read image details and scan results |

Build user policy (`push-payments-api-image`):

```hcl
statement {
  actions   = ["ecr:GetAuthorizationToken"]
  resources = ["*"]
}
statement {
  actions = [
    "ecr:BatchCheckLayerAvailability",
    "ecr:CompleteLayerUpload",
    "ecr:InitiateLayerUpload",
    "ecr:PutImage",
    "ecr:UploadLayerPart",
    "ecr:DescribeImages",
    "ecr:BatchGetImage",
    "ecr:GetDownloadUrlForLayer",
  ]
  resources = [aws_ecr_repository.api.arn]
}
```

`GetAuthorizationToken` must use `*` because it is an account-wide action. Everything else is limited to one repository.

Deploy user: the `iam:PassRole` statement has a condition so the roles can only be passed to `ecs-tasks.amazonaws.com`:

```hcl
statement {
  actions   = ["iam:PassRole"]
  resources = [local.exec_role_arn, local.task_role_arn]
  condition {
    test     = "StringEquals"
    variable = "iam:PassedToService"
    values   = ["ecs-tasks.amazonaws.com"]
  }
}
```

> **Why PassRole matters:** whoever can pass a powerful role to a service can borrow that role's power. Limiting which roles, and to which service, closes that path.

The deploy user's policy uses the **names** the `dev` environment will give its service and roles (`payments-api`, `payments-ecs-exec`, `payments-ecs-task`), because `shared` is built before `dev` exists.

### Storing the keys in GitHub

Access keys were created for each user in the IAM console and stored as GitHub secrets. They were never pasted into chat or files.

| Secret | Where | Value |
| --- | --- | --- |
| `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` | Repository secrets | `<CI_USER_KEY_ID>`, `<CI_USER_SECRET>` |
| `AWS_DEPLOY_ACCESS_KEY_ID`, `AWS_DEPLOY_SECRET_ACCESS_KEY` | **`production` environment** secrets | `<DEPLOY_USER_KEY_ID>`, `<DEPLOY_USER_SECRET>` |
| `ECR_REGISTRY` | Repository variable (not secret) | `<ACCOUNT_ID>.dkr.ecr.eu-north-1.amazonaws.com` |

Putting the deploy key in the `production` **environment** is important: GitHub only releases it to a job after that environment's approval rule passes (chapter 08).

### `identity-check.yml`

A tiny manual workflow that signs in with the build user's key and runs `aws sts get-caller-identity`. Its output showed `user/payments-github-ci`, proving the secrets were correct before the real pipeline ran.

---

## 3. Day 11: `ci.yml`

### Triggers

```yaml
on:
  pull_request:
  push:
    branches: [main]

permissions:
  contents: read
```

`permissions: contents: read` gives the workflow's built-in GitHub token read-only access. A compromised step cannot push code.

### Job 1: `test`

- Starts a real **PostgreSQL 16** container as a **service** next to the job, with throwaway values (`ci` / `ci-only`). These exist only inside the CI machine.
- Waits for it with `pg_isready`.
- Installs `requirements-dev.txt` and runs `pytest -q`. All 12 tests run, including the 4 that need a database.
- `DB_SSLMODE: disable` because the CI database has no TLS.

### Job 2: `scan`

Two Trivy scans. Both **fail the job** on HIGH or CRITICAL findings (`exit-code: "1"`).

| Scan | What it checks |
| --- | --- |
| `scan-type: fs` on `app`, scanners `vuln,secret` | Known vulnerabilities in the pinned Python packages, and secrets accidentally committed |
| `scan-type: config` on `terraform` | Terraform misconfigurations, for example an unencrypted bucket or a public listener. Accepted findings are listed in `.trivyignore` |

`ignore-unfixed: true` skips vulnerabilities with no fix available yet, so the build is not blocked by something nobody can fix.

### Job 3: `build-and-push`

Runs only on a push to `main`, and only after `test` and `scan` both pass.

| Step | What it does |
| --- | --- |
| Sign in with the build user | `aws-actions/configure-aws-credentials@v4` |
| Sign in to ECR | `aws-actions/amazon-ecr-login@v2` |
| Build | `docker build --provenance=false --sbom=false -t <registry>/payments-api:<commit-sha> app` |
| Scan the image | Trivy on the built image; fails on HIGH or CRITICAL |
| Bill of materials | Trivy writes a CycloneDX SBOM, `sbom.cdx.json` |
| Keep the SBOM | Uploaded as a workflow artifact named `sbom` |
| Push | `docker push`, **only if the scan passed** |

The image tag is the **commit ID** (`github.sha`). Combined with ECR's immutable tags, every image maps to exactly one commit.

> **What is an SBOM?** A software bill of materials: a list of every package and version inside the image. When a new vulnerability is announced, the SBOM answers "are we affected?" without rebuilding anything.

### Why Trivy is pinned to a commit ID

```yaml
uses: aquasecurity/trivy-action@57a97c7e7821a5776cebc9bb87c984fa69cba8f1 # v0.35.0
```

In March 2026, attackers moved the version tags of the Trivy GitHub Action (0.0.1 to 0.34.2) to malicious code. Anyone using `@v0.x` ran it. A **tag** can be moved; a full **commit ID** cannot. The comment records which release it is.

**Correction made:** an early README version said all actions were pinned. Only Trivy is pinned by commit ID. The GitHub-owned and AWS-owned actions (`actions/checkout@v4`, `aws-actions/...@v4`) use version tags. The README was corrected.

---

## 4. Day 12: run it and break it

### First run

The first run on `main` was **blocked** by the image scan.

| | |
| --- | --- |
| Symptom | `build-and-push` failed at "Scan the image" with a HIGH vulnerability in **zlib** |
| Root cause | The `python:3.12-slim` base image included an OS package (zlib) with a known HIGH vulnerability that had a fix available |
| Fix | Add `apt-get update && apt-get upgrade -y` to the Dockerfile so OS security fixes are applied at build time |
| Lesson | This is the pipeline working as designed. The vulnerable image never reached the registry |
| Status | Verified (README, `docs/controls.md`) |

### Proving a bad dependency is blocked

A test pull request added an old, vulnerable package, `jinja2==2.10`, to the requirements.

| Result | |
| --- | --- |
| `scan` | Failed |
| `build-and-push` | Skipped |

The pull request was then closed without merging. Recorded in `docs/controls.md`.

### Making the Terraform scan blocking

On Day 11 the Terraform scan was report-only (`exit-code: "0"`). On Day 12 it became blocking (`exit-code: "1"`), with accepted risks written into `.trivyignore`, each with a reason:

| ID | Finding | Reason it was accepted |
| --- | --- | --- |
| AWS-0132 | State bucket uses S3-managed encryption, not a customer-managed key | Private, versioned bucket that only holds state |
| AWS-0053 | Load balancer is internet-facing | By design: the only entry point, behind WAF |
| AWS-0054 | Load balancer listener uses HTTP | **Removed on 24 November 2026** when HTTPS was added |
| AWS-0015 | CloudTrail logs not encrypted with a customer-managed key | Private bucket, HTTPS-only policy, log file validation on |
| AWS-0095 | SNS alarm topic not encrypted | Carries only alarm names and states. Encrypting with the AWS-managed SNS key would stop CloudWatch from publishing |

Each ID is listed twice (`AWS-xxxx` and `AVD-AWS-xxxx`) because Trivy has used both formats.

---

## 5. Problems in this phase

| # | Symptom | Root cause | Fix | Lesson |
| --- | --- | --- | --- | --- |
| 1 | The workflow file was created at a doubled path, like `.github\workflows\.github\workflows\ci.yml` | The command was run from inside `.github\workflows` while using a path that started with `.github\workflows` again | Move the file to the correct path and run commands from the repository root | Check the current folder before creating a file with a relative path |
| 2 | The ECR push failed with **403** on a `HEAD` request for the image manifest | Before uploading, Docker checks whether layers and the manifest already exist. That check needs `ecr:BatchGetImage` and `ecr:GetDownloadUrlForLayer`, which the push-only policy did not have | Add those two actions to the build user's policy in `shared` | "Push-only" in practice also needs a little read access |
| 3 | The `.trivyignore` change did not take effect the first time | **Unverified.** The block that created or updated `.trivyignore` did not run as intended | It was run again and checked with `Get-Content .trivyignore` | Read a file back after creating it from PowerShell |
| 4 | A commit was missing 4 files | `git add .` was run from a subfolder, so only files in that subfolder were staged | `git add` from the repository root, and a new commit | Run `git status` before every commit |
| 5 | Commit messages said "Day 8" and "Day 9", which looked like a tutorial | Messages copied from the plan | The messages were reworded and the branch was force-pushed. This was done before branch protection blocked force pushes | Write commit messages that describe the change, not the plan step |

Status: all verified from conversation history. **Missing:** the exact error text for problems 1 and 3.

---

## 6. Branch protection

A GitHub ruleset called **`protect-main`** protects `main`:

| Rule | Effect |
| --- | --- |
| No deletion | `main` cannot be deleted |
| No force push | History on `main` cannot be rewritten |
| Pull request required, 0 approvals | Every change goes through a pull request. Approvals are 0 because there is only one person; GitHub does not let you approve your own pull request |
| Required status checks: `test` and `scan` | A pull request cannot be merged until both pass |

**Missing:** the day the ruleset was created.

---

## 7. What I learned

- A scanner is only a gate if it fails the job. Report-only scans get ignored.
- Accepted risks belong in a reviewed file with a reason, not in silence.
- Pin third-party actions by commit ID. Tags can be moved.
- Least privilege is found by testing. The 403 showed exactly which permission was missing.
