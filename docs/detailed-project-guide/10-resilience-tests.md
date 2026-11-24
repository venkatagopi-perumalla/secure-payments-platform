# 10. Resilience tests

Every number in this chapter was measured in the `dev` environment. Each test lists the method, the result and the evidence. Nothing here is estimated.

---

## 1. Summary

| # | Test | Result | Evidence |
| --- | --- | --- | --- |
| 1 | Approved deployment (revision 2 to 4) | **2 min 3 s**, **0 of 300** health checks failed | `ecs-deploy-success.png`, `deploy-approval.png` |
| 2 | Bad image reference (revision 3) | New tasks could not start; revision 2 kept serving 2 of 2 tasks; no user errors | `ecs-bad-image-event.png` |
| 3 | Release that crashes on start-up (revision 5) | Circuit breaker rolled back after 3 of 3 failed tasks in **about 4 min**, **0** user errors | `ecs-circuit-breaker-rollback.png`, `docs/rollback.md` |
| 4 | Manual rollback (revision 6 to 4) | **3 min 0 s** from approval to stable | `docs/rollback.md` |
| 5 | Deploy from a non-main branch | Refused in **6 s**; deploy key never released | `deploy-branch-refused.png` |
| 6 | Stop one running task | **90 of 90** health checks returned 200; ECS replaced the task | `docs/controls.md` |
| 7 | WAF burst | **3,000 of 3,000** blocked on the second burst | `waf-block.png` |
| 8 | Forced alarm | ALARM email 17:13:20, OK email 17:14:18 | `alarm-email.png`, `alarm-ok-email.png` |
| 9 | Database Multi-AZ failover under load | Payments failed for **about 10 s**: **291 of 300** accepted; AWS failover **48 s** | `rds-failover-events.png`, `failover-probe-results.png`, `failover-probe.csv` |
| 10 | Point-in-time restore | **14.2 min** to a new encrypted, private instance | `docs/rollback.md` |
| 11 | HTTPS redirect and certificate | HTTP 301 to HTTPS; HTTPS 200; Amazon-issued certificate | `https-redirect.png`, `https-browser.png` |

All evidence files are in `docs/evidence/` unless another path is shown.

---

## 2. How availability was measured

For deployments and rollbacks, a second PowerShell window called the API once a second and recorded each status code. One request a second is far below the WAF limit, so a 403 would mean a WAF block from an earlier burst, not a real failure. Real failures are 5xx codes and timeouts.

**Missing:** the exact loop script used for tests 1, 3 and 6. Tests 1 and 6 report health-check results; the CSV in test 9 is the only raw probe output kept in the repository.

---

## 3. Tests 1 to 5: deployments and rollbacks

Covered in detail in chapter 08. Key points:

- **Test 1:** with `minimum_healthy_percent = 100` and `maximum_percent = 200`, new tasks start and pass health checks before old ones stop. 0 of 300 requests failed.
- **Test 2:** an accidental test. A trailing dot in the `ECR_REGISTRY` variable made an invalid image address. The rolling update simply never replaced the working tasks.
- **Test 3:** a deliberate `KeyError` at start-up. The circuit breaker rolled back; the deploy workflow correctly ended red.
- **Test 4:** timed from the approval click to "stable".
- **Test 5:** GitHub environment branch rules work before any AWS credentials are released.

---

## 4. Test 6: self-healing

| Step | |
| --- | --- |
| Method | While a loop called `/health`, one of the two tasks was stopped with `aws ecs stop-task` |
| Expected | The load balancer stops sending traffic to the stopped task; ECS starts a replacement |
| Result | **90 of 90** returned 200. Afterwards, 2 of 2 tasks running |
| Why it worked | Two tasks in two zones behind the load balancer, and the service keeps the desired count |

**Missing:** the time until the replacement was healthy.

---

## 5. Test 7: WAF rate limit

| Step | |
| --- | --- |
| Rule | Block an IP above 2,000 requests in 5 minutes |
| First try | A sequential loop. **No blocks.** It was not fast enough to cross the limit |
| Second try | Parallel `curl` requests in two bursts |
| Result | First burst allowed; second burst **3,000 of 3,000 blocked with 403** |

This test was run **after** the self-healing test, because the block also stops your own test traffic for a few minutes.

---

## 6. Test 8: alert path

Forced `payments-5xx-rate` to ALARM with `aws cloudwatch set-alarm-state`. The email arrived, and the OK email followed by itself at the next evaluation, 58 seconds later. Details in chapter 09.

---

## 7. Test 9: database failover under load

### Method

1. The database was converted to Multi-AZ (12:41:17 to 12:49:59).
2. A probe in a second window sent **one `POST /payments` per second**, each with a new idempotency key, and recorded the time and status code to `failover-probe.csv`.
3. A failover was forced:

```powershell
aws rds reboot-db-instance --db-instance-identifier payments-postgres --force-failover
```

   **Unverified:** the exact command typed. `reboot-db-instance --force-failover` is the documented way to force a Multi-AZ failover and is what the plan used.
4. AWS events were read for the failover times:

```powershell
aws rds describe-events --source-identifier payments-postgres --source-type db-instance --duration 60
```

### Results

From `failover-probe.csv` (300 requests, 13:00:42 to 13:06:31):

| Code | Count |
| --- | --- |
| 201 (accepted) | **291** |
| 500 | **8** |
| Timeout | **1** |

All 9 failures were between **13:01:18 and 13:01:27**: a timeout at 13:01:18, then 500s. That is about 10 seconds of failed payments.

From AWS events:

| Event | Time |
| --- | --- |
| Failover started | 13:01:15 |
| Failover completed | 13:02:03 |

AWS reports **48 seconds**, but users saw errors for only **about 10 seconds**. That is why the README reports both, and why I now measure from the user's side.

### Why the API recovered by itself

The app opens a **new database connection per request** (`get_conn()` in `main.py`). After the failover, the database's DNS name pointed at the new primary, so the next connection simply worked. No restart was needed.

### A confusing moment

| | |
| --- | --- |
| Symptom | After the failover, listing the instance did not obviously show the primary and standby zones swapped |
| What settled it | The RDS **events** clearly recorded the failover start and completion |
| Lesson | Use the service's event log as the source of truth for what happened, not a single snapshot of a field |
| Status | Verified (conversation history) |

### What the 9 failures mean

These 9 requests failed with 500 or a timeout. **They were not retried** in this test. Because every payment has an idempotency key, a client could safely retry them with the same key: no payment could be created twice. In a real client, a retry with backoff would turn those 9 failures into successes. This is listed as a known gap.

---

## 8. Test 10: point-in-time restore

### Method

```powershell
aws rds restore-db-instance-to-point-in-time --source-db-instance-identifier payments-postgres --target-db-instance-identifier payments-restore-test --use-latest-restorable-time --db-subnet-group-name payments-db --vpc-security-group-ids <DB_SECURITY_GROUP_ID> --no-publicly-accessible
aws rds wait db-instance-available --db-instance-identifier payments-restore-test
```

### Result

| Item | Value |
| --- | --- |
| Started | 13:47:08 |
| Available | 14:01:19 |
| Duration | **14.2 minutes** |
| Encrypted | Yes |
| Public | No |

The test instance was deleted afterwards to stop its cost.

**Known gap:** the restored database was **not queried**, because it is private. The restore was proven by timing, encryption and privacy, not by reading a row.

**Unverified:** the exact restore command options. The command above is the documented method; the options actually typed were not recorded.

---

## 9. Test 11: HTTPS (24 November 2026)

| Check | Result |
| --- | --- |
| `http://api.venkatagopiperumalla.com/health` | 301 to `https://api.venkatagopiperumalla.com:443/health` |
| `https://api.venkatagopiperumalla.com/health` | 200, `{"status":"ok"}` |
| Certificate | `CN=api.venkatagopiperumalla.com`, issuer Amazon RSA 2048 S25 |
| Listener policy | `ELBSecurityPolicy-TLS13-1-2-2021-06` |
| Request without User-Agent | 403 from WAF, which proves WAF covers HTTPS too |

Details in chapter 07.

---

## 10. Day 21 problem: `CannotPullContainerError`

This is documented exactly as it happened. **Its root cause is not verified.**

| | |
| --- | --- |
| When | Day 21, while rebuilding `dev` for the failure tests |
| Symptom | ECS tasks could not start. The error was `CannotPullContainerError`: the image tag `8661334f...` was **not found** in ECR |
| What the tag was | The `image_tag` in `local.auto.tfvars`, which Terraform uses only when it first creates the service |
| How it was resolved | The `deploy` workflow was run with a tag that did exist, `1b6112245c50...`. Result: **2 of 2 tasks running and ready** |
| Root cause | **Unverified.** The image with tag `8661334f...` was not in the repository at that time. One possible explanation is the ECR lifecycle rule that keeps only the last 30 images, but this was **not checked** and is only a guess |
| What was not done | ECR was not searched for the old tag's history, and the lifecycle rule's actions were not inspected |

### What changed because of it

Before rebuilding `dev` on 24 November 2026, the tag in `local.auto.tfvars` was compared with the newest images in ECR first:

```powershell
aws ecr describe-images --repository-name payments-api --region eu-north-1 --query "sort_by(imageDetails,&imagePushedAt)[-3:].{tag:imageTags[0],pushed:imagePushedAt}" --output table
```

The file pointed at `1b6112245c50...`, which was no longer among the three newest. It was changed to the newest tag, `e5490661...`, before applying, and the rebuild worked.

**Lesson:** a tag stored outside the pipeline can go stale. Check that it still exists before every rebuild.

---

## 11. What these tests prove, and what they do not

| Proven | Not proven |
| --- | --- |
| A bad release does not reach users | Behaviour under real production traffic |
| Rollback works, automatically and by hand, in minutes | Recovery from a whole-region failure (single region only) |
| Losing a task or a database zone is survivable | That the restored database contains the right rows |
| Alerts reach a person | That a person responds (no on-call rota) |
| The firewall blocks a burst | Protection against a distributed attack from many IPs |
