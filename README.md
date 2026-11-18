# Secure Payments API on AWS

A small payments API (FastAPI + PostgreSQL) and the AWS platform around it:
Terraform, ECS Fargate, GitHub Actions with OIDC, approved deployments, tested rollback.

Status: Phase 1 (the app and its tests). The README grows as the project is built.
This is a portfolio project. It is not certified for PCI DSS or any other standard.

## Run the tests (no Docker, no database needed for the fast ones)

    cd app
    python -m venv .venv
    .\.venv\Scripts\Activate.ps1
    pip install -r requirements-dev.txt
    pytest -q

Expected: 8 passed, 4 skipped (the 4 database tests run in CI against a real PostgreSQL).

## Try the API without a database (health check only)

    $env:SKIP_DB_INIT = "1"
    $env:API_KEY = "local-dev-key"
    uvicorn app.main:app --port 8000

Open http://localhost:8000/health

Deployment test 1
