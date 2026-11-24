# 03. Setup and Day 1

This chapter covers the laptop setup, AWS access, the repository and the API code written on Day 1.

---

## 1. Tools

All work was done on a Windows laptop in **PowerShell**, with **VS Code** as the editor.

| Tool | Why it is needed | Check command | Expected |
| --- | --- | --- | --- |
| AWS CLI v2 | Talk to AWS from the terminal | `aws --version` | `aws-cli/2.x` |
| Terraform 1.10 or newer | Build infrastructure from code. 1.10 is needed for S3 state locking with `use_lockfile` | `terraform version` | `v1.10` or newer |
| Git | Version control | `git --version` | any recent version |
| Python 3.12 | Run the unit tests locally | `python --version` | `3.12.x` |
| Docker | Build and run the container locally | `docker --version` | **Not installed.** Days 2 and 3 skipped |

Tools were installed with `winget`.

### Problem: `python` and `aws` not found after installing

| | |
| --- | --- |
| Symptom | Right after installing, PowerShell said `python` and `aws` were not recognised |
| Root cause | A PowerShell window reads the `PATH` variable when it opens. The installers changed `PATH` after the window was already open |
| Fix | Close PowerShell and open a new window |
| Lesson | After installing a command-line tool on Windows, always open a new terminal before testing it |
| Status | Verified (conversation history) |

---

## 2. AWS access

### Sign in from the CLI

```powershell
aws configure
```

It asks for four values:

| Prompt | Value |
| --- | --- |
| AWS Access Key ID | `<ADMIN_ACCESS_KEY_ID>` |
| AWS Secret Access Key | `<ADMIN_SECRET_ACCESS_KEY>` |
| Default region name | `eu-north-1` |
| Default output format | `json` |

The keys come from IAM in the AWS console: **IAM, Users, your user, Security credentials, Create access key**. The secret is shown only once.

> **Never** paste access keys into a chat, a file in the repository or a screenshot.

### Check who you are

```powershell
aws sts get-caller-identity
```

`sts get-caller-identity` returns the account ID and the user or role you are signed in as. It is the first command to run whenever something about permissions looks wrong. The output showed account `472639329900`.

**Missing:** the exact name of the admin IAM user used on the laptop. CloudTrail later recorded one deliberate test change by a user called `cli-admin` (chapter 09), which suggests that name, but it was not otherwise recorded.

---

## 3. The repository

| Item | Value |
| --- | --- |
| Name | `secure-payments-platform` |
| Owner | `venkatagopi-perumalla` on GitHub |
| Visibility | Public. GitHub only offers required reviewers on environments for private repositories on paid plans, and this project needs that feature for the approval step |
| Created | By hand on github.com, then cloned to `C:\Users\<USER>\Downloads\secure-payments-platform` |

### Folder layout

```
app/                    the API, Dockerfile and tests
terraform/bootstrap/    state bucket
terraform/envs/         shared and dev
terraform/modules/      network, database, service
.github/workflows/      ci, deploy, rollback, identity-check
docs/                   controls, rollback, SLO, evidence
```

The early empty folders were kept with `.gitkeep` files, because Git does not track empty folders.

### `.gitignore`

```
__pycache__/
*.pyc
.venv/
.pytest_cache/
.terraform/
*.tfstate
*.tfstate.*
*.pem
local.auto.tfvars
```

| Line | Why |
| --- | --- |
| `.terraform/` | Downloaded providers and modules, large and rebuilt by `terraform init` |
| `*.tfstate` | State files can hold secrets. State lives in S3 instead |
| `local.auto.tfvars` | Holds the image tag and the alert email address. Personal values do not go into Git |

### Problem: confusion about folders on Day 1

| | |
| --- | --- |
| Symptom | The folders on the laptop did not match the plan document, and the step-by-step instructions in chat differed from the document, which caused a lot of confusion |
| Root cause | **Unverified.** The repository was created by hand on GitHub, and the files were being created step by step in a different order from the document |
| Fix | All Day 1 files were provided together as one folder and copied into the repository (accepting Windows' "Replace" prompt). Then `pytest` and `git status` confirmed the result |
| Lesson | Follow one source of instructions at a time. Confirm the current folder with `pwd` and run `git status` often |
| Status | Symptom and fix verified (conversation history). **Missing:** the exact wrong paths |

---

## 4. The API (`app/app/main.py`)

The API is written in **Python** with **FastAPI**, and talks to PostgreSQL with **psycopg 3**.

### Endpoints

| Method and path | Needs API key | What it does | Responses |
| --- | --- | --- | --- |
| `GET /health` | No | Says the process is alive. Used by the load balancer and the container health check | 200 `{"status":"ok"}` |
| `GET /ready` | No | Runs `SELECT 1` on the database | 200 ready, 503 if the database is down |
| `POST /payments` | Yes | Creates a payment | 201 new, 200 repeat, 401 bad key, 409 key reused with a different body, 422 bad input |
| `GET /payments/{id}` | Yes | Reads one payment | 200, 404, 422 if the ID is not a UUID |

### Input rules

```python
class PaymentIn(BaseModel):
    amount: Decimal = Field(gt=0, max_digits=12, decimal_places=2)
    currency: str = Field(pattern="^[A-Z]{3}$")
    reference: str = Field(min_length=1, max_length=64)
```

- `amount` is a `Decimal`, never a float, because floats cannot store money exactly. It must be above zero, with at most 2 decimal places.
- `currency` must be three capital letters, like `EUR`.
- `reference` is a short client reference.

### The API key

```python
def require_api_key(x_api_key: str = Header(default="")):
    expected = os.environ.get("API_KEY", "")
    if not expected or not hmac.compare_digest(x_api_key, expected):
        raise HTTPException(status_code=401, detail="invalid api key")
```

- The key comes from the environment. On AWS, ECS injects it from Secrets Manager.
- `hmac.compare_digest` compares in constant time, so an attacker cannot guess the key one character at a time by timing the responses.
- If no key is configured, every request is refused, rather than everything being allowed.

### Idempotency

Payment clients retry when a network call times out. Without protection, a retry could create a second payment. The client sends an `Idempotency-Key` header, and the database has a unique index on it:

```sql
INSERT INTO payments (id, amount, currency, reference, idempotency_key)
VALUES (...)
ON CONFLICT (idempotency_key) DO NOTHING
RETURNING id
```

| Situation | Result |
| --- | --- |
| New key | Insert, return **201** |
| Same key, same body | Nothing inserted; return the original payment with **200** |
| Same key, different body | **409**: the key is already used for a different payment |

### Database connection

```python
sslmode=os.environ.get("DB_SSLMODE", "require")
```

TLS to the database is **on by default**. Only the CI test job and local development switch it off (`DB_SSLMODE=disable`) because their PostgreSQL containers have no TLS.

### Logging

```python
logger.info("payment accepted id=%s currency=%s", payment_id, payment.currency)
```

Only the payment ID and currency are logged. Not the amount, the reference or any key.

### Start-up

On start, `init_db()` creates the `payments` table and the unique index if they do not exist. Setting `SKIP_DB_INIT=1` skips this, which the unit tests use.

---

## 5. The container (`app/Dockerfile`)

```dockerfile
FROM python:3.12-slim
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
RUN apt-get update && apt-get upgrade -y && rm -rf /var/lib/apt/lists/*
RUN useradd --system --uid 10001 appuser
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY app ./app
USER 10001
EXPOSE 8000
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
```

| Line | Why |
| --- | --- |
| `python:3.12-slim` | Small official base image |
| `PYTHONDONTWRITEBYTECODE=1` | No `.pyc` files, which matters because the file system is read-only on AWS |
| `apt-get upgrade -y` | Applies OS security fixes at build time. Added after the image scan blocked a HIGH zlib vulnerability (chapter 11) |
| `useradd ... 10001` and `USER 10001` | The app does not run as root |
| `--no-cache-dir` | Smaller image |

### Pinned dependencies

`requirements.txt`:

```
fastapi==0.163.1
uvicorn[standard]==0.54.0
psycopg[binary]==3.3.9
```

`requirements-dev.txt` adds `pytest==8.4.2` and `httpx==0.28.1`. Exact versions mean the scanner checks exactly what will run.

---

## 6. Local development file

`docker-compose.yml` runs the API and PostgreSQL together with throwaway local values (`local-dev-only`, `local-dev-key`). These are not real secrets. It was **never run**, because there is no Docker on the laptop.

---

## 7. Running the tests locally

```powershell
cd app
pip install -r requirements-dev.txt
pytest -q
```

Expected: **8 passed, 4 skipped.** The 4 skipped tests need a real database and run in CI. Chapter 12 lists all 12 tests.

---

## 8. Git habits from Day 1

| Habit | Why |
| --- | --- |
| Run `git status` before and after every change | Shows exactly what will be committed |
| Run `git add .` from the repository root | Running it from a subfolder misses files elsewhere (chapter 11) |
| One branch and pull request per change | The `protect-main` ruleset requires it (chapter 08) |
| Never commit `local.auto.tfvars` or keys | `.gitignore` covers them; `git status` confirms it |

Git on Windows prints `LF will be replaced by CRLF` warnings. These are about line endings and are harmless.
