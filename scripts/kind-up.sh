#!/usr/bin/env bash
# Creates the local kind cluster and deploys LeadPipe to it with the same chart EKS uses.
# Usage: scripts/kind-up.sh [image-tag]    (default: the current git commit, or "dev")
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLUSTER="leadpipe"
NAMESPACE="leadpipe"
METRICS_SERVER_VERSION="v0.9.1"
TAG="${1:-$(git -C "${ROOT}" rev-parse --verify --short=12 HEAD 2>/dev/null || echo dev)}"

if ! kind get clusters 2>/dev/null | grep --quiet --line-regexp "${CLUSTER}"; then
  kind create cluster --config "${ROOT}/deploy/kind/cluster.yaml" --wait 120s
fi
kubectl config use-context "kind-${CLUSTER}"

# The HPA reads CPU from metrics-server. kind's kubelet certificates are self-signed, which is
# why this flag is needed here. EKS installs metrics-server as an add-on without it.
if ! kubectl --namespace kube-system get deployment metrics-server >/dev/null 2>&1; then
  kubectl apply --filename "https://github.com/kubernetes-sigs/metrics-server/releases/download/${METRICS_SERVER_VERSION}/components.yaml"
  kubectl --namespace kube-system patch deployment metrics-server --type=json \
    --patch '[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'
fi
kubectl --namespace kube-system rollout status deployment metrics-server --timeout=300s

echo "==> Building images tagged ${TAG}"
docker build --tag "leadpipe/api:${TAG}" "${ROOT}/app/api"
docker build --tag "leadpipe/worker:${TAG}" "${ROOT}/app/worker"

echo "==> Loading images into kind"
docker image inspect redis:7-alpine >/dev/null 2>&1 || docker pull redis:7-alpine
docker image inspect postgres:16-alpine >/dev/null 2>&1 || docker pull postgres:16-alpine
"${ROOT}/scripts/kind-load.sh" "leadpipe/api:${TAG}" "leadpipe/worker:${TAG}" redis:7-alpine postgres:16-alpine

kubectl create namespace "${NAMESPACE}" --dry-run=client --output yaml | kubectl apply --filename -
kubectl --namespace "${NAMESPACE}" apply --filename "${ROOT}/deploy/kind/postgres.yaml"
kubectl --namespace "${NAMESPACE}" rollout status statefulset postgres --timeout=180s

"${ROOT}/scripts/deploy.sh" local "${TAG}"
