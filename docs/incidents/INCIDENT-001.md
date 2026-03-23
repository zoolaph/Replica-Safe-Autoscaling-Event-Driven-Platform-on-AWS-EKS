# INCIDENT-001 — Duplicate Event Processing on Worker Scale-Out

**Status:** Resolved
**Severity:** High (data correctness)
**Date:** 2025-11-15
**Affected component:** `worker` deployment in `demo-app` namespace
**Author:** Platform team

---

## Summary

When the `worker` deployment was scaled from 1 to 5 replicas under load, the same SQS messages were
processed multiple times by different pods, resulting in duplicate rows in the `processed_events`
table. This broke the assumption that "each event is written exactly once".

---

## Timeline

| Time (UTC) | Event |
|------------|-------|
| 14:02 | Load test started — 200 events pumped into SQS |
| 14:03 | Worker scaled to 5 replicas (manual) |
| 14:05 | DB row count = 847 for 200 events — 4.2× duplication |
| 14:06 | Worker scaled back to 1 replica |
| 14:07 | Incident declared |
| 14:45 | Root cause identified |
| 15:10 | Fix deployed (idempotent mode) |
| 15:12 | DB row count = 200 for 200 events — PASS |

---

## Root Cause

Three compounding problems in the **non-idempotent** (`WORKER_MODE=non-idempotent`) code path:

### Problem 1 — Short visibility timeout (1 second)

```python
BROKEN_VISIBILITY_TIMEOUT = int(os.getenv("BROKEN_VISIBILITY_TIMEOUT", "1"))
vis = BROKEN_VISIBILITY_TIMEOUT if WORKER_MODE == "non-idempotent" else VISIBILITY_TIMEOUT
resp = sqs.receive_message(..., VisibilityTimeout=vis)
```

SQS hides a message for `VisibilityTimeout` seconds after it is received. With a 1-second timeout
and a DB write that takes ~5 ms plus queue processing overhead, the message becomes visible again
before the processing pod deletes it. Any other polling replica can receive it.

### Problem 2 — No `delete_message` call

```python
# non-idempotent path (apps/worker/worker.py:107-118)
conn.execute("INSERT INTO processed_events ...")
conn.commit()
processed_total.labels(mode=WORKER_MODE, pod=POD_NAME).inc()
# intentionally no delete_message — message will reappear
```

The broken mode never deletes the message from SQS. It stays on the queue until its retention period
expires (4 days by default). Every poll from every replica will receive and process it.

### Problem 3 — No UNIQUE constraint on `processed_events`

The `processed_events` table has no uniqueness guarantee:

```sql
-- apps/db/migrations/002_add_processed_events.sql
CREATE TABLE IF NOT EXISTS processed_events (
    id         SERIAL PRIMARY KEY,
    event_id   TEXT NOT NULL,          -- ← no UNIQUE constraint
    type       TEXT,
    payload    JSONB,
    ts         BIGINT,
    pod_name   TEXT,
    created_at TIMESTAMPTZ DEFAULT NOW()
);
```

Without a `UNIQUE(event_id)` constraint, the database will happily accept any number of rows for the
same `event_id` from any number of pods.

---

## Impact

- **Data integrity:** 847 rows inserted for 200 unique events (4.2× duplication)
- **Downstream consumers:** Any service reading `processed_events` would see phantom events
- **Metrics:** `worker_events_processed_total` inflated — appeared healthy but was counting duplicates
- **Cost:** SQS messages were not deleted and continued to be re-processed until manually cleared

---

## Fix

Two changes were required:

### Fix 1 — Use idempotent mode (`WORKER_MODE=idempotent`)

```python
# idempotent path (apps/worker/worker.py:87-100)
cur = conn.execute(
    "INSERT INTO events(event_id, type, payload, ts)"
    " VALUES (%s, %s, %s, %s)"
    " ON CONFLICT (event_id) DO NOTHING",
    (event_id, etype, json.dumps(payload), ts),
)
conn.commit()
if cur.rowcount == 0:
    deduped_total.labels(pod=POD_NAME).inc()   # duplicate detected, skipped
else:
    processed_total.labels(mode=WORKER_MODE, pod=POD_NAME).inc()  # written once
sqs.delete_message(QueueUrl=SQS_QUEUE_URL, ReceiptHandle=receipt)
```

- `ON CONFLICT (event_id) DO NOTHING` makes the insert atomic and idempotent.
- `delete_message` is called unconditionally — the message is removed from SQS whether the row was
  inserted or skipped.

### Fix 2 — UNIQUE constraint on `events` table

```sql
-- apps/db/migrations/001_create_events.sql
CREATE TABLE IF NOT EXISTS events (
    id         SERIAL PRIMARY KEY,
    event_id   TEXT UNIQUE NOT NULL,   -- ← UNIQUE constraint
    ...
);
```

The database itself enforces correctness. Even if the application layer had a bug, the DB would
reject the second insert for the same `event_id`.

### Verification

```bash
# Reproduce the incident (demo-05-incident-001.sh)
./scripts/demo-05-incident-001.sh

# Apply the fix and verify (demo-06-fix-idempotency.sh)
./scripts/demo-06-fix-idempotency.sh
```

Expected output after fix:
```
events sent:    50
DB rows:        50
duplicates:     0
deduped_total:  >0  (KEDA re-delivers some messages; worker skips them correctly)
```

---

## What Worked Well

- The `deduped_total` counter (`worker_events_deduped_total`) made the fix immediately observable —
  when the value is > 0, deduplification is actively working.
- The `processed_events` table (broken mode) vs `events` table (idempotent mode) separation makes
  the before/after contrast explicit in the schema, not just in application code.
- Worker logs distinguish the two paths: broken mode logs `BROKEN processed event_id=...`,
  idempotent mode logs `processed event_id=...` or `deduped event_id=...`.

---

## Action Items

| Action | Owner | Status |
|--------|-------|--------|
| Set `WORKER_MODE=idempotent` as the default in `manifests/demo-app/worker.yaml` | Platform | Done |
| Add DB correctness assertion to smoke test (`demo-02-smoke.sh`) | Platform | Done |
| Document broken mode as an explicit demo (`demo-05-incident-001.sh`) | Platform | Done |
| Add `WorkerNotConsuming` and `WorkerSQSBacklogCritical` alerts | Platform | Done (issue #54) |

---

## Lessons Learned

1. **Visibility timeout is not a safety net.** A 30-second visibility timeout only delays re-delivery.
   If the processing pod crashes mid-write, the message will be redelivered. Idempotency must be in
   the write path, not in the delivery guarantee.

2. **Metrics can lie.** `worker_events_processed_total` incremented on every insert, including
   duplicates. The signal looked healthy. The `deduped_total` counter was added specifically so that
   "successful deduplication" is observable separately from "successful processing".

3. **Schema is the last line of defense.** Application bugs happen. A `UNIQUE` constraint in the DB
   is cheap, permanent protection that survives code regressions, bad deploys, and operator errors.
