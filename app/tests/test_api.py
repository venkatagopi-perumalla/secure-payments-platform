import os

os.environ["SKIP_DB_INIT"] = "1"
os.environ["API_KEY"] = "test-key"

from fastapi.testclient import TestClient

from app.main import app

client = TestClient(app)
GOOD = {"X-API-Key": "test-key", "Idempotency-Key": "test-key-0001"}
BODY = {"amount": 5, "currency": "EUR", "reference": "X1"}


def test_health():
    r = client.get("/health")
    assert r.status_code == 200
    assert r.json() == {"status": "ok"}


def test_requires_api_key():
    r = client.post("/payments", json=BODY, headers={"Idempotency-Key": "test-key-0001"})
    assert r.status_code == 401


def test_rejects_wrong_api_key():
    r = client.post("/payments", json=BODY, headers={**GOOD, "X-API-Key": "wrong"})
    assert r.status_code == 401


def test_requires_idempotency_key():
    r = client.post("/payments", json=BODY, headers={"X-API-Key": "test-key"})
    assert r.status_code == 422


def test_rejects_negative_amount():
    r = client.post("/payments", json={**BODY, "amount": -5}, headers=GOOD)
    assert r.status_code == 422


def test_rejects_bad_currency():
    r = client.post("/payments", json={**BODY, "currency": "euro"}, headers=GOOD)
    assert r.status_code == 422


def test_reading_requires_api_key():
    r = client.get("/payments/00000000-0000-0000-0000-000000000000")
    assert r.status_code == 401


def test_rejects_bad_payment_id():
    r = client.get("/payments/not-a-uuid", headers={"X-API-Key": "test-key"})
    assert r.status_code == 422
