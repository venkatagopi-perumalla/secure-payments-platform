import os
import uuid

import pytest

os.environ["SKIP_DB_INIT"] = "1"
os.environ["API_KEY"] = "test-key"

pytestmark = pytest.mark.skipif("DB_HOST" not in os.environ, reason="no database configured")

from fastapi.testclient import TestClient

from app.main import app, init_db

client = TestClient(app)
BODY = {"amount": 25.50, "currency": "EUR", "reference": "INV-1"}


@pytest.fixture(scope="module", autouse=True)
def setup_db():
    init_db()


def headers(key=None):
    return {"X-API-Key": "test-key", "Idempotency-Key": key or str(uuid.uuid4())}


def test_create_and_read_back():
    r = client.post("/payments", json=BODY, headers=headers())
    assert r.status_code == 201
    pid = r.json()["id"]
    r2 = client.get(f"/payments/{pid}", headers={"X-API-Key": "test-key"})
    assert r2.status_code == 200
    assert r2.json()["reference"] == "INV-1"


def test_replay_returns_same_payment():
    h = headers()
    first = client.post("/payments", json=BODY, headers=h)
    second = client.post("/payments", json=BODY, headers=h)
    assert first.status_code == 201
    assert second.status_code == 200
    assert second.json()["id"] == first.json()["id"]


def test_same_key_different_body_is_rejected():
    h = headers()
    assert client.post("/payments", json=BODY, headers=h).status_code == 201
    other = {**BODY, "amount": 99}
    assert client.post("/payments", json=other, headers=h).status_code == 409


def test_unknown_payment_is_404():
    r = client.get(f"/payments/{uuid.uuid4()}", headers={"X-API-Key": "test-key"})
    assert r.status_code == 404
