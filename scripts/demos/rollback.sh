#!/usr/bin/env bash
# Demo: deploy broken versions and recover, three ways. A probe counts failed requests throughout.
# Usage: scripts/demos/rollback.sh <good-image-tag>
set -euo pipefail
# shellcheck source=scripts/demos/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

GOOD="${1:?usage: rollback.sh <good-image-tag>}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CHART="${ROOT}/helm/leadpipe"

history() { helm history leadpipe --namespace "${NS}" --max 6 | cut -c1-110; }

# Crashes as soon as it starts, like a release with a fatal bug.
printf 'FROM leadpipe/api:%s\nCMD ["python", "-c", "raise SystemExit(1)"]\n' "${GOOD}" \
  | docker build --quiet --tag leadpipe/api:broken-crash - >/dev/null

# Starts and passes its probes, but cannot make outgoing HTTP calls, so the smoke test fails.
printf 'FROM leadpipe/api:%s\nENV http_proxy=http://127.0.0.1:9\n' "${GOOD}" \
  | docker build --quiet --tag leadpipe/api:broken-smoke - >/dev/null

# The worker keeps the same tag scheme, so give it the good image under the broken tags.
docker tag "leadpipe/worker:${GOOD}" leadpipe/worker:broken-crash
docker tag "leadpipe/worker:${GOOD}" leadpipe/worker:broken-smoke
"${ROOT}/scripts/kind-load.sh" leadpipe/api:broken-crash leadpipe/api:broken-smoke \
  leadpipe/worker:broken-crash leadpipe/worker:broken-smoke

start_availability_probe "leadpipe/api:${GOOD}"

say "Starting state"
pods api
history

say "Scenario 1, manual: deploy a release that crashes on start, with no automatic rollback"
helm upgrade leadpipe "${CHART}" --namespace "${NS}" \
  --values "${CHART}/values-local.yaml" --set-string image.tag=broken-crash \
  --wait --timeout 60s 2>&1 | tail -2 | cut -c1-140 || true
say "The new pod crash-loops. maxUnavailable: 0 keeps the old pod serving."
pods api
kubectl --namespace "${NS}" get pods --selector app.kubernetes.io/component=api --no-headers | cut -c1-80
stop_at="$(kubectl --namespace "${NS}" logs availability-probe | tail -1)"
echo "    requests so far: ${stop_at}"

say "Recovering by hand: helm rollback"
helm rollback leadpipe 0 --namespace "${NS}" --wait --timeout 3m | cut -c1-110
pods api
history

say "Scenario 2, automatic: the pipeline deploys a release that crashes on start"
if DEPLOY_TIMEOUT=60s "${ROOT}/scripts/deploy.sh" local broken-crash 2>&1 | tail -4 | cut -c1-160; then
  :
fi
pods api
history
echo "    requests so far: $(kubectl --namespace "${NS}" logs availability-probe | tail -1)"

say "Scenario 3, automatic: pods pass their probes, but the smoke test fails"
set +e
"${ROOT}/scripts/deploy.sh" local broken-smoke 2>&1 | grep -E '^==>|attempt 10|failed:' | tail -6 | cut -c1-160
deploy_exit="${PIPESTATUS[0]}"
set -e
echo "    deploy.sh exit code: ${deploy_exit} (1 means rolled back, and fails the pipeline)"
pods api
history

say "Final result"
stop_availability_probe
live_tag="$(helm get values leadpipe --namespace "${NS}" | grep -A1 '^image:' | awk '/tag:/ { print $2 }' | tr -d '\r')"
echo "    live image tag: ${live_tag}"
if [[ "${deploy_exit}" != "1" || "${live_tag}" != "${GOOD}" ]]; then
  echo "FAIL: expected deploy.sh to exit 1 and ${GOOD} to be live" >&2
  exit 1
fi
echo "    PASS: every broken release was rolled back, and ${GOOD} is live"
