/**
 * k6 load test — demo-app API autoscaling proof
 *
 * Usage:
 *   k6 run -e BASE_URL=http://localhost:8080 tests/load/k6-api.js
 *
 * Stages:
 *   0-1m  ramp from 0 → 50 VUs   (warm-up)
 *   1-4m  hold at 50 VUs          (sustained load — HPA should fire here)
 *   4-5m  ramp from 50 → 0 VUs   (cool-down — watch replicas drop)
 */

import http from 'k6/http';
import { check, sleep } from 'k6';

const BASE_URL = __ENV.BASE_URL || 'http://localhost:8080';

export const options = {
  stages: [
    { duration: '1m', target: 50 },
    { duration: '3m', target: 50 },
    { duration: '1m', target: 0 },
  ],
  thresholds: {
    http_req_duration: ['p(95)<2000'],  // 95th percentile < 2 s
    http_req_failed:   ['rate<0.05'],   // error rate < 5 %
  },
};

export default function () {
  const payload = JSON.stringify({
    type: 'order.created',
    payload: { item_id: `item-${Math.floor(Math.random() * 10000)}` },
  });

  const res = http.post(`${BASE_URL}/events`, payload, {
    headers: { 'Content-Type': 'application/json' },
  });

  check(res, {
    'status 200':   (r) => r.status === 200,
    'has event_id': (r) => JSON.parse(r.body).event_id !== undefined,
  });

  sleep(0.1);
}
