# 08. Change control: approved deployments and rollback

This chapter covers Days 16 to 18: the approval gate, the deploy and rollback workflows, a normal deployment, a broken release that rolled back by itself, and a timed manual rollback.

---

## 1. The idea

A payments company must be able to answer, for every production change:

1. **What** changed? A commit ID, which is also the image tag.
2. **Was it checked?** Tests and scans passed, and the image scan completed.
3. **Who approved it,** and when?
4. **Did it work,** and if not, did it roll back?

This chapter builds the machinery that answers those questions.

---

## 2. Day 16: the `production` environment

In GitHub: **Settings, Environments, New environment**, named exactly `production`.

| Setting | Value | Effect |
| --- | --- | --- |
| Required reviewers | `venkatagopi-perumalla` | Every job that uses `production` pauses until a named person approves |
| Deployment branches | Selected: `main` only | A workflow run from any other branch is refused |
| Environment secrets | `AWS_DEPLOY_ACCESS_KEY_ID`, `AWS_DEPLOY_SECRET_ACCESS_KEY` | The deploy key is released to the job **only after** approval and only from `main` |
| Prevent self-review | **Off** | With one person, it cannot be switched on. Listed as a known gap |

The deploy user's access key was created in IAM and stored only as an environment secret: `<DEPLOY_USER_KEY_ID>` and `<DEPLOY_USER_SECRET>`.

> **Why environment secrets make the gate real:** if the deploy key were a normal repository secret, any workflow could read it and deploy without approval. As an environment secret, it does not exist for a job until the approval is given.

---

## 3. `deploy.yml`

Started by hand (**Actions, deploy, Run workflow**) with one input: the image tag (commit ID).

| Step | What it does | Why |
| --- | --- | --- |
| Wait for approval | `environment: production` | Change control |
| Sign in with the deploy user | Environment secrets | Separate identity from the build user |
| Check the image exists and was scanned | `aws ecr describe-image-scan-findings ... --query 'imageScanStatus.status'` must equal `COMPLETE` | Only scanned images reach production |
| Get the running task definition | `aws ecs describe-task-definition --task-definition payments-api` | Start from what is live, including secrets and settings |
| Put the new image in it | `amazon-ecs-render-task-definition@v1` with `${{ vars.ECR_REGISTRY }}/payments-api:<tag>` | Only the image changes |
| Deploy and wait | `amazon-ecs-deploy-task-definition@v2` with `wait-for-service-stability: true` | Registers a new revision and waits for ECS to finish |
| Fail if ECS rolled back | Compares the deployed revision with the one actually running; fails if they differ | **A rolled-back deploy can otherwise look green** |

The last step:

```bash
GOT=$(aws ecs describe-services --cluster payments --services payments-api --query 'services[0].taskDefinition' --output text)
echo "Deployed: $WANT"
echo "Running:  $GOT"
test "$GOT" = "$WANT"
```

---

## 4. `rollback.yml`

Started by hand with one input: a task definition **revision number**.

```bash
if ! [[ "$REVISION" =~ ^[0-9]+$ ]]; then echo "Revision must be a number"; exit 1; fi
aws ecs update-service --cluster payments --service payments-api --task-definition "payments-api:${REVISION}" > /dev/null
aws ecs wait services-stable --cluster payments --services payments-api
GOT=$(aws ecs describe-services ... --query 'services[0].taskDefinition' --output text)
[[ "$GOT" == *":${REVISION}" ]]
```

- It also uses `environment: production`, so it also needs approval. An emergency rollback is still a production change.
- The input is checked to be a number, so nothing else can be injected into the command.
- It reuses an existing, already-approved revision. No new image is built.

---

## 5. Day 17: a normal approved deployment

Method:
1. A small change was merged so CI built a new image.
2. A second PowerShell window called the API once a second.
3. `deploy` was run with the new commit ID and approved.

| Result | |
| --- | --- |
| Revision | 2 to 4 |
| Time | **2 minutes 3 seconds** to complete the rollout |
| Health checks during the rollout | **0 of 300 failed** |
| Final step | Deployed and running task definition both `payments-api:4` |

Evidence: `docs/evidence/deploy-approval.png`, `docs/evidence/ecs-deploy-success.png`.

### Problem: the deploy was refused with "Scan status None"

This was the longest problem in the project. The deploy check kept refusing images that had been scanned.

| Attempt | What was found | What was done |
| --- | --- | --- |
| 1 | The check used `aws ecr describe-images` and read the scan status. It returned `None` | Investigated the image in ECR |
| 2 | The image was an **OCI image index** (a list of manifests) with a provenance attestation, not a plain image. Newer Docker Buildx adds provenance by default. ECR basic scanning skips image indexes | Added `--provenance=false --sbom=false` to `docker build` in `ci.yml`, so a plain image manifest is pushed |
| 3 | Tried starting a manual scan of the old image | Hit the manual scan quota: **`LimitExceeded`** |
| 4 | Tried again on the old index image | **`UnsupportedImageType`**, confirming the index format was the problem |
| 5 | New images were plain manifests, but `describe-images` **still** returned no scan status | AWS's newer basic scanning no longer fills the scan status in `DescribeImages` |
| 6 | Switched the check to `aws ecr describe-image-scan-findings`, which does report `imageScanStatus.status` | Added `ecr:DescribeImageScanFindings` to the deploy user in `shared` |
| 7 | The repository's own `scan_on_push` setting was not being applied | Added an account-level **registry scanning rule** (`ecr_scanning.tf`): basic scan on push for `payments-api` |

After these changes the check returned `COMPLETE` and the deploy continued.

**Unverified:** the exact order of attempts 2 to 4. All of them happened, but their sequence is reconstructed from memory of the conversation.

| | |
| --- | --- |
| Root cause | Two causes together: images pushed as OCI indexes that basic scanning skips, and an API field (`DescribeImages` scan status) that no longer carries the value |
| Lesson | When a gate refuses something that should pass, check the gate's data source as well as the thing being checked |
| Status | Verified (conversation history; README "Problems found and fixed"; repository files) |

### Problem: a malformed image reference (revision 3)

| | |
| --- | --- |
| Symptom | New tasks for revision 3 could not start. ECS events said it **failed to normalize the image reference** |
| Root cause | The `ECR_REGISTRY` repository variable had a **trailing dot**, so the image address was invalid |
| Impact | **None for users.** The rolling deployment never stopped the old tasks, so revision 2 kept serving 2 of 2 tasks |
| Fix | Removed the trailing dot from the variable and deployed again |
| Evidence | `docs/evidence/ecs-bad-image-event.png` |
| Lesson | Rolling deployments with `minimum_healthy_percent = 100` turn a bad release into a non-event for users |
| Status | Verified |

---

## 6. Day 18: break it on purpose

### Automatic rollback (circuit breaker)

A release was made that passes CI but **crashes on start-up**: a line in the app's start-up code read an environment variable that does not exist, which raised a `KeyError`. The unit tests skip start-up code, so CI was green and the image was built.

| Result | |
| --- | --- |
| Revision | 5 (the bad release) |
| What ECS did | Started new tasks; each crashed. After **3 of 3** failed tasks, the circuit breaker stopped the rollout and returned to revision 4 |
| Time | About **4 minutes**, from approval (16:01) to rollback (16:05) |
| User impact | **0 errors.** Every health check in the 10-minute loop returned 200 |
| Deploy workflow | Ended **red** with "deployment was likely rolled back by the deployment circuit breaker" |

Evidence: `docs/evidence/ecs-circuit-breaker-rollback.png`, `docs/rollback.md`.

The red result is the **correct** result. The pipeline reported that the release did not go live.

### Manual rollback

1. The bad change was removed and a good build was deployed with approval (revision 6).
2. `rollback` was run with revision **4** and approved.

| Result | |
| --- | --- |
| Revision | 6 to 4 |
| Time | **3 minutes 0 seconds**, from approval (16:24:52) to stable (16:27:52) |
| Approved by | `venkatagopi-perumalla` |

### Only `main` can deploy

`deploy` was run from a branch called `test-deploy-from-branch`. GitHub refused it in **6 seconds**: "not allowed to deploy to production due to environment protection rules". The deploy key was never released.

Evidence: `docs/evidence/deploy-branch-refused.png`.

### CloudTrail confirms who changed production

CloudTrail `UpdateService` events showed all 4 deploys and the rollback made by `payments-github-deploy`, and 1 deliberate test made from the laptop by `cli-admin` (chapter 09).

---

## 7. Branch protection

The `protect-main` ruleset (chapter 06) completes the picture: code reaches `main` only through a pull request with `test` and `scan` passing, and only `main` can deploy.

```
Pull request -> test + scan green -> merge to main -> image built and scanned
  -> deploy run with commit ID -> named approval -> scan COMPLETE check
  -> rolling update with circuit breaker -> running = deployed check
```

---

## 8. What I learned

- Put the deploy key behind the approval, not just the workflow.
- A green pipeline must mean "the new version is running". Check it explicitly.
- The circuit breaker and a 100 percent minimum healthy setting make most bad releases invisible to users.
- Rollback is a change too. It needs the same approval and evidence.
- Debugging the scan gate taught me to question the tool's data, not only the input.
