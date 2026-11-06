#!/usr/bin/env bash
# Shared helpers for the demo scripts. Each demo runs against the local kind cluster.

NS="leadpipe"

say() { printf '\n[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }

pods() { kubectl --namespace "${NS}" get pods --no-headers \
  --selector "app.kubernetes.io/instance=leadpipe${1:+,app.kubernetes.io/component=$1}" \
  --output custom-columns='NAME:.metadata.name,READY:.status.containerStatuses[0].ready,PHASE:.status.phase,RESTARTS:.status.containerStatuses[0].restartCount,IMAGE:.spec.containers[0].image' \
  | grep -v smoke-test || true; }

# The first pod of a component that is not already shutting down.
live_pod() {
  kubectl --namespace "${NS}" get pods --selector "app.kubernetes.io/component=$1" --no-headers \
    --output custom-columns='NAME:.metadata.name,DELETING:.metadata.deletionTimestamp,PHASE:.status.phase' \
    | awk '$2 == "<none>" && $3 == "Running" { print $1; exit }'
}

# Runs Python inside the cluster, from a pod that does not depend on the API staying up.
# MSYS_NO_PATHCONV stops Git Bash on Windows from rewriting the arguments.
in_cluster() {
  MSYS_NO_PATHCONV=1 kubectl --namespace "${NS}" exec "$(live_pod worker)" -- python -c "$1"
}

api_stats() {
  in_cluster "
import json, urllib.request
request = urllib.request.Request('http://leadpipe-api/stats', headers={'X-API-Key': 'local-dev-key'})
print(json.dumps(json.load(urllib.request.urlopen(request, timeout=5))))"
}

# A pod that sends 5 requests per second to the API and reports failures every 5 seconds.
start_availability_probe() {
  kubectl --namespace "${NS}" delete pod availability-probe --ignore-not-found --wait=true >/dev/null
  MSYS_NO_PATHCONV=1 kubectl --namespace "${NS}" run availability-probe --restart=Never --image="$1" \
    --image-pull-policy=IfNotPresent --labels=app=availability-probe --command -- python -c "
import time, urllib.request
ok = failed = 0
started = window = time.time()
while True:
    try:
        urllib.request.urlopen('http://leadpipe-api/healthz', timeout=2).read()
        ok += 1
    except Exception:
        failed += 1
    if time.time() - window >= 5:
        print(f'{time.time() - started:6.0f}s  ok={ok}  failed={failed}', flush=True)
        window = time.time()
    time.sleep(0.2)
" >/dev/null
  kubectl --namespace "${NS}" wait pod availability-probe --for=condition=Ready --timeout=60s >/dev/null
}

stop_availability_probe() {
  kubectl --namespace "${NS}" logs availability-probe | tail -1 | sed 's/^/    requests so far: /'
  kubectl --namespace "${NS}" delete pod availability-probe --wait=false >/dev/null
}
