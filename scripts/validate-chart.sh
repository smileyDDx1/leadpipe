#!/usr/bin/env bash
# Lints the chart with every values file and checks the output against Kubernetes schemas.
# Needs helm and docker. Runs in CI and works the same on a laptop.
set -euo pipefail

CHART="$(cd "$(dirname "${BASH_SOURCE[0]}")/../helm/leadpipe" && pwd)"
KUBECONFORM_IMAGE="ghcr.io/yannh/kubeconform:v0.8.0@sha256:faffaf43f95aa6425306e1ab8d6fcad72acb9049158f38e574c085ea1ec0f64e"
KUBERNETES_VERSION="1.37.0"
TEST_VALUES=(--set-string image.tag=0123456789abcdef --set-string database.host=db.example.com)

for values in values-local.yaml values-staging.yaml values-prod.yaml; do
  echo "==> ${values}"
  helm lint "${CHART}" --strict --values "${CHART}/${values}" "${TEST_VALUES[@]}"
  helm template leadpipe "${CHART}" --values "${CHART}/${values}" "${TEST_VALUES[@]}" \
    | docker run --rm --interactive "${KUBECONFORM_IMAGE}" \
      -strict -summary -kubernetes-version "${KUBERNETES_VERSION}"
done

# These must fail: every release has to trace back to a commit, and needs a database.
expect_failure() {
  local name="$1"
  shift
  if helm template leadpipe "${CHART}" --values "${CHART}/values-prod.yaml" "$@" >/dev/null 2>&1; then
    echo "FAIL: the chart accepted ${name}" >&2
    exit 1
  fi
  echo "PASS: the chart refuses ${name}"
}
expect_failure "a missing image tag" --set-string database.host=db.example.com
expect_failure "the latest tag" --set-string image.tag=latest --set-string database.host=db.example.com
expect_failure "a missing database host" --set-string image.tag=0123456789abcdef

# A new release must not restart Redis, or every deploy would throw away the queue.
redis_pod_template() {
  helm template leadpipe "${CHART}" --values "${CHART}/values-prod.yaml" \
    --set-string database.host=db.example.com --set-string "image.tag=$1" \
    --show-only templates/redis.yaml | sed -n '/^  template:/,/^---/p'
}
if [[ "$(redis_pod_template aaaa)" != "$(redis_pod_template bbbb)" ]]; then
  echo "FAIL: changing the image tag changes the Redis pod template" >&2
  exit 1
fi
echo "PASS: a new release leaves the Redis pod untouched"
