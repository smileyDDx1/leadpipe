#!/usr/bin/env bash
# Demo: run a load test and watch the API scale up, then back down.
# Usage: scripts/demos/autoscaling.sh
set -euo pipefail
# shellcheck source=scripts/demos/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

docker image inspect grafana/k6:2.3.0 >/dev/null 2>&1 || docker pull grafana/k6:2.3.0
"${ROOT}/scripts/kind-load.sh" grafana/k6:2.3.0

kubectl --namespace "${NS}" delete job k6 --ignore-not-found --wait=true >/dev/null
kubectl --namespace "${NS}" create configmap k6-script --from-file="${ROOT}/loadtest/leads.js" \
  --dry-run=client --output yaml | kubectl apply --filename - >/dev/null

sample() {
  printf '%s  cpu=%-12s desired=%-2s ready=%-2s\n' "$(date +%H:%M:%S)" \
    "$(kubectl --namespace "${NS}" get hpa leadpipe-api --output jsonpath='{.status.currentMetrics[0].resource.current.averageUtilization}%')" \
    "$(kubectl --namespace "${NS}" get hpa leadpipe-api --output jsonpath='{.status.desiredReplicas}')" \
    "$(kubectl --namespace "${NS}" get deployment leadpipe-api --output jsonpath='{.status.readyReplicas}')"
}

say "Starting state"
kubectl --namespace "${NS}" get hpa leadpipe-api --no-headers | cut -c1-100
before="$(api_stats)"
echo "    ${before}"

say "Starting the load test: 20 virtual users for about 3 minutes 45 seconds"
kubectl --namespace "${NS}" apply --filename "${ROOT}/loadtest/k6-job.yaml" >/dev/null
while [[ "$(kubectl --namespace "${NS}" get job k6 --output jsonpath='{.status.completionTime}{.status.failed}')" == "" ]]; do
  sample
  sleep 15
done
sample

say "Load test result"
kubectl --namespace "${NS}" logs job/k6 \
  | grep -E 'checks_succeeded|checks_failed|http_req_duration\.|http_req_failed|http_reqs|iterations\.' | cut -c1-120

say "The queue absorbs the spike: waiting for the worker to finish the backlog"
started="${SECONDS}"
while :; do
  stats="$(api_stats)"
  pending="$(python -c "import json,sys; print(json.loads(sys.argv[1])['pending'])" "${stats}" | tr -d '\r')"
  echo "    $(date +%H:%M:%S)  leads still pending: ${pending}"
  [[ "${pending}" == "0" ]] && break
  (( SECONDS - started > 600 )) && { echo "    backlog not finished after 10 minutes"; break; }
  sleep 20
done
echo "    backlog cleared $((SECONDS - started))s after the load stopped"

say "Load is gone: waiting for the API to scale back down"
started="${SECONDS}"
while :; do
  sample
  replicas="$(kubectl --namespace "${NS}" get deployment leadpipe-api --output jsonpath='{.spec.replicas}')"
  minimum="$(kubectl --namespace "${NS}" get hpa leadpipe-api --output jsonpath='{.spec.minReplicas}')"
  [[ "${replicas}" == "${minimum}" ]] && break
  (( SECONDS - started > 480 )) && { echo "    still scaled up after 8 minutes"; break; }
  sleep 15
done

say "Scaling events recorded by Kubernetes"
kubectl --namespace "${NS}" get events --field-selector reason=SuccessfulRescale \
  --sort-by=.lastTimestamp --output custom-columns='MESSAGE:.message' --no-headers | cut -c1-110

say "Final state"
kubectl --namespace "${NS}" get hpa leadpipe-api --no-headers | cut -c1-100
echo "    $(api_stats)"
