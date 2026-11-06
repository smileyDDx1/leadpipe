#!/usr/bin/env bash
# Demo: delete running pods and show Kubernetes replacing them, with no lead lost.
# Usage: scripts/demos/self-healing.sh
set -euo pipefail
# shellcheck source=scripts/demos/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

wait_ready() {
  local component="$1" old="$2" started="$3" current ready
  while :; do
    current="$(kubectl --namespace "${NS}" get pods \
      --selector "app.kubernetes.io/component=${component}" --no-headers \
      --output custom-columns='NAME:.metadata.name,READY:.status.containerStatuses[0].ready' \
      | grep -v "${old}" | grep true || true)"
    ready="${current%% *}"
    if [[ -n "${ready}" ]]; then
      echo "    replaced by ${ready}, ready after $((SECONDS - started))s"
      return
    fi
    sleep 1
  done
}

say "Starting state"
pods ""

for component in api worker; do
  old="$(live_pod "${component}")"
  say "Deleting the ${component} pod: ${old}"
  started="${SECONDS}"
  kubectl --namespace "${NS}" delete pod "${old}" --wait=false >/dev/null
  wait_ready "${component}" "${old}" "${started}"
done

old="$(live_pod redis)"
say "Deleting the redis pod: ${old}"
started="${SECONDS}"
kubectl --namespace "${NS}" delete pod "${old}" --wait=false >/dev/null
wait_ready redis "${old}" "${started}"
echo "    Redis has no persistence, so the stream and the consumer group are gone."

say "The harder case: a long Redis outage, with a lead arriving in the middle of it"
kubectl --namespace "${NS}" scale deployment leadpipe-redis --replicas=0 >/dev/null
kubectl --namespace "${NS}" wait pod --selector app.kubernetes.io/component=redis \
  --for=delete --timeout=60s >/dev/null
echo "    Redis is scaled to zero. Waiting 25 seconds, longer than readiness takes to fail."
sleep 25
echo "    The API stays in service, because it can still save leads:"
pods api

say "Posting a lead while Redis is down"
lead_id="$(in_cluster "
import json, time, urllib.request
body = json.dumps({'email': f'selfheal-{int(time.time())}@example.com', 'name': 'Self Heal',
                   'job_title': 'CTO', 'company_size': 500, 'source': 'referral'}).encode()
request = urllib.request.Request('http://leadpipe-api/leads', data=body, method='POST',
    headers={'X-API-Key': 'local-dev-key', 'Content-Type': 'application/json'})
started = time.time()
response = urllib.request.urlopen(request, timeout=15)
result = json.load(response)
print(result['id'])
print(f'    HTTP {response.status} in {time.time() - started:.2f}s', flush=True)
" | tee /dev/stderr | head -1)"

say "Bringing Redis back. It starts empty, so only the sweep can recover this lead."
kubectl --namespace "${NS}" scale deployment leadpipe-redis --replicas=1 >/dev/null
kubectl --namespace "${NS}" rollout status deployment leadpipe-redis --timeout=60s >/dev/null

say "Waiting for the lead to be scored, with nothing done by hand"
started="${SECONDS}"
while :; do
  state="$(in_cluster "
import json, urllib.request
request = urllib.request.Request('http://leadpipe-api/leads/${lead_id}', headers={'X-API-Key': 'local-dev-key'})
lead = json.load(urllib.request.urlopen(request, timeout=5))
print(lead['status'], lead['score'], lead['grade'])" 2>/dev/null || true)"
  if [[ "${state}" == scored* ]]; then
    echo "    lead ${lead_id}: ${state}, $((SECONDS - started))s after Redis came back"
    break
  fi
  if (( SECONDS - started > 180 )); then
    echo "    TIMEOUT: lead ${lead_id} is still [${state}]" >&2
    exit 1
  fi
  sleep 3
done

say "Worker log"
kubectl --namespace "${NS}" logs --selector app.kubernetes.io/component=worker --tail=200 \
  | grep -E 'recreating|created consumer group|re-queued|unavailable' | tail -6 \
  | sed -E 's/.*"time": "[^T]*T([0-9:]{8})[^"]*".*"message": "(.*)"\}/    \1  \2/' || true

say "Final state"
pods ""
