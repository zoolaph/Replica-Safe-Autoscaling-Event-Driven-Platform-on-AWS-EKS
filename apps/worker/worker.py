import os, json, time
import boto3
import psycopg
from prometheus_client import Counter, start_http_server

AWS_REGION = os.getenv("AWS_REGION", "eu-west-3")
SQS_QUEUE_URL = os.getenv("SQS_QUEUE_URL", "")

PGHOST = os.getenv("PGHOST", "postgres")
PGPORT = int(os.getenv("PGPORT", "5432"))
PGDATABASE = os.getenv("PGDATABASE", "app")
PGUSER = os.getenv("PGUSER", "app")
PGPASSWORD = os.getenv("PGPASSWORD", "")

# In non-idempotent (broken) mode we use a 1-second visibility timeout so the
# message reappears on the queue while we are still writing to the DB.  With 5
# replicas all polling simultaneously, several pods will receive the same message
# before any of them deletes it — producing duplicate rows in processed_events.
VISIBILITY_TIMEOUT = int(os.getenv("VISIBILITY_TIMEOUT", "30"))
BROKEN_VISIBILITY_TIMEOUT = int(os.getenv("BROKEN_VISIBILITY_TIMEOUT", "1"))
WAIT_TIME_SECONDS = int(os.getenv("WAIT_TIME_SECONDS", "10"))
BATCH_SIZE = int(os.getenv("BATCH_SIZE", "10"))

# idempotent      → ON CONFLICT DO NOTHING into events table (safe to run N replicas)
# non-idempotent  → plain INSERT into processed_events table (no UNIQUE constraint) +
#                   short visibility timeout → duplicate rows guaranteed at scale
WORKER_MODE = os.getenv("WORKER_MODE", "idempotent")
POD_NAME = os.getenv("POD_NAME", "unknown")
METRICS_PORT = int(os.getenv("METRICS_PORT", "8000"))

processed_total = Counter(
    "worker_events_processed_total",
    "Events successfully written to DB",
    ["mode", "pod"],
)
deduped_total = Counter(
    "worker_events_deduped_total",
    "Events skipped as duplicates (idempotent mode only)",
    ["pod"],
)

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
    print(f"[worker] starting mode={WORKER_MODE} pod={POD_NAME}", flush=True)
    start_http_server(METRICS_PORT)
    print(f"[worker] metrics exposed on :{METRICS_PORT}/metrics", flush=True)

    conn = db_conn()

    try:
        while True:
            vis = BROKEN_VISIBILITY_TIMEOUT if WORKER_MODE == "non-idempotent" else VISIBILITY_TIMEOUT
            resp = sqs.receive_message(
                QueueUrl=SQS_QUEUE_URL,
                MaxNumberOfMessages=BATCH_SIZE,
                WaitTimeSeconds=WAIT_TIME_SECONDS,
                VisibilityTimeout=vis,
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
                            deduped_total.labels(pod=POD_NAME).inc()
                            print(f"[worker] deduped event_id={event_id}", flush=True)
                        else:
                            processed_total.labels(mode=WORKER_MODE, pod=POD_NAME).inc()
                            print(f"[worker] processed event_id={event_id} type={etype}", flush=True)
                        sqs.delete_message(QueueUrl=SQS_QUEUE_URL, ReceiptHandle=receipt)

                    else:
                        # BROKEN MODE (INCIDENT-001 repro):
                        # 1. Visibility timeout is 1 s — message reappears before we finish.
                        # 2. We write to processed_events (no UNIQUE constraint).
                        # 3. We do NOT delete the message, so every replica processes it.
                        # Result: same event_id written N times by N different pods.
                        conn.execute(
                            "INSERT INTO processed_events(event_id, type, payload, ts, pod_name)"
                            " VALUES (%s, %s, %s, %s, %s)",
                            (event_id, etype, json.dumps(payload), ts, POD_NAME),
                        )
                        conn.commit()
                        processed_total.labels(mode=WORKER_MODE, pod=POD_NAME).inc()
                        print(
                            f"[worker] BROKEN processed event_id={event_id} type={etype} pod={POD_NAME}",
                            flush=True,
                        )
                        # intentionally no delete_message — message will reappear and be
                        # processed again by this pod and all other replicas

                except psycopg.OperationalError as e:
                    print(f"[worker] DB connection lost, reconnecting: {e}", flush=True)
                    conn = db_conn()

                except Exception as e:
                    print(f"[worker] ERROR processing message: {e}", flush=True)
                    continue
    finally:
        conn.close()

if __name__ == "__main__":
    main()
