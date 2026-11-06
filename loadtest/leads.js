// Drives the autoscaling demo: k6 runs inside the cluster and posts leads to the API Service.
// It runs in the cluster because a port-forward would limit throughput before the API did.
import { check, sleep } from "k6";
import http from "k6/http";

const BASE_URL = __ENV.API_URL || "http://leadpipe-api";
const HEADERS = {
  "Content-Type": "application/json",
  "X-API-Key": __ENV.API_KEY || "local-dev-key",
};
const TITLES = ["CEO", "VP Sales", "Head of Growth", "Marketing Manager", "Analyst"];
const SOURCES = ["website_form", "crm", "referral", "event", "paid_ads"];

export const options = {
  stages: [
    { duration: "30s", target: 10 },
    { duration: "3m", target: 20 },
    { duration: "15s", target: 0 },
  ],
};

export default function () {
  const response = http.post(
    `${BASE_URL}/leads`,
    JSON.stringify({
      email: `load-${__VU}-${__ITER}@example.com`,
      name: `Load Test ${__VU}`,
      company: "Example Ltd",
      job_title: TITLES[__ITER % TITLES.length],
      company_size: 1 + (__ITER % 2000),
      source: SOURCES[__VU % SOURCES.length],
    }),
    { headers: HEADERS },
  );
  check(response, { "accepted (202)": (r) => r.status === 202 });
  sleep(0.05);
}
