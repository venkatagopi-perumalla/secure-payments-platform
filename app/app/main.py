import hmac
import logging
import os
import uuid
from contextlib import asynccontextmanager
from decimal import Decimal

import psycopg
from fastapi import Depends, FastAPI, Header, HTTPException, Response
from pydantic import BaseModel, Field

logger = logging.getLogger("payments")
logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")


def get_conn():
    return psycopg.connect(
        host=os.environ["DB_HOST"],
        port=int(os.environ.get("DB_PORT", "5432")),
        dbname=os.environ["DB_NAME"],
        user=os.environ["DB_USER"],
        password=os.environ["DB_PASSWORD"],
        sslmode=os.environ.get("DB_SSLMODE", "require"),
        connect_timeout=5,
    )


def init_db():
    with get_conn() as conn:
        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS payments (
                id uuid PRIMARY KEY,
                amount numeric(12, 2) NOT NULL,
                currency char(3) NOT NULL,
                reference text NOT NULL,
                status text NOT NULL DEFAULT 'ACCEPTED',
                created_at timestamptz NOT NULL DEFAULT now()
            )
            """
        )
        conn.execute("ALTER TABLE payments ADD COLUMN IF NOT EXISTS idempotency_key text")
        conn.execute("CREATE UNIQUE INDEX IF NOT EXISTS payments_idempotency_key_idx ON payments (idempotency_key)")


@asynccontextmanager
async def lifespan(app: FastAPI):
    if os.environ.get("SKIP_DB_INIT") != "1":
        init_db()
    yield


app = FastAPI(title="payments-api", lifespan=lifespan)


class PaymentIn(BaseModel):
    amount: Decimal = Field(gt=0, max_digits=12, decimal_places=2)
    currency: str = Field(pattern="^[A-Z]{3}$")
    reference: str = Field(min_length=1, max_length=64)


class PaymentOut(PaymentIn):
    id: uuid.UUID
    status: str


@app.get("/health")
def health():
    return {"status": "ok"}


@app.get("/ready")
def ready():
    try:
        with get_conn() as conn:
            conn.execute("SELECT 1")
    except Exception:
        raise HTTPException(status_code=503, detail="database unavailable")
    return {"status": "ready"}


def require_api_key(x_api_key: str = Header(default="")):
    expected = os.environ.get("API_KEY", "")
    if not expected or not hmac.compare_digest(x_api_key, expected):
        raise HTTPException(status_code=401, detail="invalid api key")


@app.post("/payments", response_model=PaymentOut, status_code=201, dependencies=[Depends(require_api_key)])
def create_payment(
    payment: PaymentIn,
    response: Response,
    idempotency_key: str = Header(min_length=8, max_length=64),
):
    payment_id = uuid.uuid4()
    with get_conn() as conn:
        inserted = conn.execute(
            "INSERT INTO payments (id, amount, currency, reference, idempotency_key) "
            "VALUES (%s, %s, %s, %s, %s) ON CONFLICT (idempotency_key) DO NOTHING RETURNING id",
            (payment_id, payment.amount, payment.currency, payment.reference, idempotency_key),
        ).fetchone()
        if inserted is None:
            row = conn.execute(
                "SELECT id, amount, currency, reference, status FROM payments WHERE idempotency_key = %s",
                (idempotency_key,),
            ).fetchone()
            if (row[1], row[2], row[3]) != (payment.amount, payment.currency, payment.reference):
                raise HTTPException(status_code=409, detail="idempotency key already used with a different request")
            response.status_code = 200
            return PaymentOut(id=row[0], amount=row[1], currency=row[2], reference=row[3], status=row[4])
    logger.info("payment accepted id=%s currency=%s", payment_id, payment.currency)
    return PaymentOut(id=payment_id, status="ACCEPTED", **payment.model_dump())


@app.get("/payments/{payment_id}", response_model=PaymentOut, dependencies=[Depends(require_api_key)])
def get_payment(payment_id: uuid.UUID):
    with get_conn() as conn:
        row = conn.execute(
            "SELECT id, amount, currency, reference, status FROM payments WHERE id = %s",
            (payment_id,),
        ).fetchone()
    if row is None:
        raise HTTPException(status_code=404, detail="payment not found")
    return PaymentOut(id=row[0], amount=row[1], currency=row[2], reference=row[3], status=row[4])
