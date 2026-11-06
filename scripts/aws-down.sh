#!/usr/bin/env bash
# Tears down the AWS environment and stops the hourly charges.
#
# The order matters. The load balancers are created by the controller, not by Terraform. If they
# are still there when Terraform deletes the VPC, the delete hangs and then fails on their
# network interfaces. So: remove the apps, wait for the ALBs to go, and only then destroy.
#
# The state bucket and budget in infra/bootstrap stay, because rebuilding needs them. They cost
# almost nothing.
set -euo pipefail

: "${AWS_REGION:?AWS_REGION is required}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLUSTER="${CLUSTER_NAME:-leadpipe}"
ALB_TAG="elbv2.k8s.aws/cluster"

if aws eks describe-cluster --name "${CLUSTER}" >/dev/null 2>&1; then
  aws eks update-kubeconfig --name "${CLUSTER}" --region "${AWS_REGION}"
  for namespace in staging production; do
    helm uninstall leadpipe --namespace "${namespace}" --wait --ignore-not-found || true
  done

  echo "==> Waiting for the controller to delete the load balancers"
  for _ in $(seq 1 30); do
    remaining="$(aws resourcegroupstaggingapi get-resources \
      --resource-type-filters elasticloadbalancing:loadbalancer \
      --tag-filters "Key=${ALB_TAG},Values=${CLUSTER}" \
      --query 'length(ResourceTagMappingList)' --output text)"
    [[ "${remaining}" == "0" ]] && break
    echo "    ${remaining} left"
    sleep 10
  done
  if [[ "${remaining}" != "0" ]]; then
    echo "Load balancers are still present. Delete them in the EC2 console, then run this again." >&2
    exit 1
  fi

  helm uninstall aws-load-balancer-controller --namespace kube-system --wait --ignore-not-found || true
fi

terraform -chdir="${ROOT}/infra/main" destroy -auto-approve
echo "==> Done. Check the AWS Billing console in a few hours to confirm the charges stopped."
