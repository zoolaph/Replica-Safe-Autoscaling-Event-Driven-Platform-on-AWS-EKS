import os, json, time
import boto3
import psycopg

AWS_REGION = os.getenv("AWS_REGION", "eu-west-3")
SQS_QUEUE_URL = os.getenv("SQS_QUEUE_URL", "")

PGHOST = os.getenv("PGHOST", "postgres")
PGPORT = int(os.getenv("PGPORT", "5432"))
PGDATABASE = os.getenv("PGDATABASE", "app")
PGUSER = os.getenv("PGUSER", "app")
PGPASSWORD = os.getenv("PGPASSWORD", "")

VISIBILITY_TIMEOUT = int(os.getenv("VISIBILITY_TIMEOUT", "30"))
WAIT_TIME_SECONDS = int(os.getenv("WAIT_TIME_SECONDS", "10"))
BATCH_SIZE = int(os.getenv("BATCH_SIZE", "10"))
# idempotent  → ON CONFLICT DO NOTHING (safe to run N replicas)
# non-idempotent → plain INSERT (broken mode, used to demo INCIDENT-001)
WORKER_MODE = os.getenv("WORKER_MODE", "idempotent")

if not SQS_QUEUE_URL:
    raise SystemExit("SQS_QUEUE_URL not set")
if not PGPASSWORD:
    raise SystemExit("PGPASSWORD not set")
if WORKER_MODE not in ("idempotent", "non-idempotent"):
    raise SystemExit(f"WORKER_MODE must be 'idempotent' or 'non-idempotent', got: {WORKER_MODE}")

sqs = boto3.client("sqs", region_name=AWS_REGION)

def db_conn():
    return psycopg.connect(
        host=PGHOST, port=PGPORT, dbname=PGDATABASE, user=PGUSER, password=PGPASSWORD
    )

def main():
    print(f"[worker] starting mode={WORKER_MODE}", flush=True)

    # One connection for the lifetime of this process.
    conn = db_conn()
    conn.execute("""
        CREATE TABLE IF NOT EXISTS events (
          id BIGSERIAL PRIMARY KEY,
          event_id TEXT NOT NULL UNIQUE,
          type TEXT NOT NULL,
          payload JSONB NOT NULL,
          ts BIGINT NOT NULL
        );
    """)
    conn.commit()

    try:
        while True:
            resp = sqs.receive_message(
                QueueUrl=SQS_QUEUE_URL,
                MaxNumberOfMessages=BATCH_SIZE,
                WaitTimeSeconds=WAIT_TIME_SECONDS,
                VisibilityTimeout=VISIBILITY_TIMEOUT,
            )
            msgs = resp.get("Messages", [])
            if not msgs:
                continue

            for m in msgs:
                receipt = m["ReceiptHandle"]
                body = m["Body"]
                try:
                    evt = json.loads(body)
                    event_id = evt.get("event_id", "missing")
                    etype = evt.get("type", "unknown")
                    payload = evt.get("payload", {})
                    ts = int(evt.get("ts", int(time.time())))

                    if WORKER_MODE == "idempotent":
                        cur = conn.execute(
                            "INSERT INTO events(event_id, type, payload, ts)"
                            " VALUES (%s, %s, %s, %s)"
                            " ON CONFLICT (event_id) DO NOTHING",
                            (event_id, etype, json.dumps(payload), ts),
                        )
                        conn.commit()
                        if cur.rowcount == 0:
                            print(f"[worker] deduped event_id={event_id}", flush=True)
                        else:
                            print(f"[worker] processed event_id={event_id} type={etype}", flush=True)
                    else:
                        # non-idempotent: plain INSERT — breaks under multiple replicas (INCIDENT-001)
                        conn.execute(
                            "INSERT INTO events(event_id, type, payload, ts) VALUES (%s, %s, %s, %s)",
                            (event_id, etype, json.dumps(payload), ts),
                        )
                        conn.commit()
                        print(f"[worker] processed event_id={event_id} type={etype}", flush=True)

                    sqs.delete_message(QueueUrl=SQS_QUEUE_URL, ReceiptHandle=receipt)

                except psycopg.OperationalError as e:
                    # Connection dropped — reconnect. Message stays in queue and retries.
                    print(f"[worker] DB connection lost, reconnecting: {e}", flush=True)
                    conn = db_conn()

                except Exception as e:
                    print(f"[worker] ERROR processing message: {e}", flush=True)
                    # don't delete; it will retry
                    continue
    finally:
        conn.close()

if __name__ == "__main__":
    main()
