-- Broken-by-design audit table used by WORKER_MODE=non-idempotent (INCIDENT-001 repro).
-- Deliberately has NO UNIQUE constraint on event_id so duplicate processing is visible.
-- The pod_name column lets you see which replica processed each row.
CREATE TABLE IF NOT EXISTS processed_events (
  id         BIGSERIAL PRIMARY KEY,
  event_id   TEXT      NOT NULL,
  type       TEXT      NOT NULL,
  payload    JSONB     NOT NULL,
  ts         BIGINT    NOT NULL,
  pod_name   TEXT      NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
