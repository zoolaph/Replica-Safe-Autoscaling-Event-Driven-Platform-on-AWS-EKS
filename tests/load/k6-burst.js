/**
 * k6 burst producer — KEDA worker autoscaling proof
 *
 * Goal: fill the SQS queue faster than the worker can drain it,
 *       so KEDA sees depth > queueLength threshold and scales workers up.
 *
 * Usage:
 *   # 1. scale worker to 0 first (so queue builds up)
 *   kubectl -n demo-app scale deploy worker --replicas=0
 *
 *   # 2. fire the burst
 *   k6 run -e BASE_URL=http://localhost:8080 tests/load/k6-burst.js
 *
 *   # 3. restore KEDA control (remove the manual override)
 *   kubectl -n demo-app scale deploy worker --replicas=1
 *
 * Stages:
 *   0-30s  ramp 0 → 100 VUs  (aggressive burst)
 *   30s-2m hold at 100 VUs   (sustained backlog build)
 *   2-3m   ramp 100 → 0 VUs  (stop producing, watch drain + scale-down)
 */

import http from 'k6/http';
import { check, sleep } from 'k6';

const BASE_URL = __ENV.BASE_URL || 'http://localhost:8080';

export const options = {
  stages: [
    { duration: '30s', target: 100 },
    { duration: '90s', target: 100 },
    { duration: '60s', target: 0  },
  ],
  thresholds: {
    http_req_duration: ['p(95)<3000'],
    http_req_failed:   ['rate<0.10'],
  },
};

export default function () {
  const payload = JSON.stringify({
    type: 'order.created',
    payload: { item_id: `burst-${Math.floor(Math.random() * 100000)}` },
  });

  const res = http.post(`${BASE_URL}/events`, payload, {
    headers: { 'Content-Type': 'application/json' },
  });

  check(res, {
    'status 200':   (r) => r.status === 200,
    'has event_id': (r) => {
      try { return JSON.parse(r.body).event_id !== undefined; }
      catch { return false; }
    },
  });

  // no sleep — maximise throughput to outpace the worker
}
