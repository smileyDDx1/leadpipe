#!/usr/bin/env bash
# Installs what runs inside the EKS cluster but is not part of the app, right after
# `terraform apply`. Safe to run repeatedly.
#
# Needs AWS credentials with cluster-admin access, and AWS_REGION.
set -euo pipefail

: "${AWS_REGION:?AWS_REGION is required}"
CLUSTER="${CLUSTER_NAME:-leadpipe}"
ENVIRONMENTS=(staging production)
CONTROLLER_CHART_VERSION="3.6.2"

aws eks update-kubeconfig --name "${CLUSTER}" --region "${AWS_REGION}"

for environment in "${ENVIRONMENTS[@]}"; do
  kubectl create namespace "${environment}" --dry-run=client --output yaml | kubectl apply --filename -
  # Pods only count as ready once the ALB sees them as healthy, which rolling updates rely on
  # for zero downtime.
  kubectl label namespace "${environment}" elbv2.k8s.aws/pod-readiness-gate-inject=enabled --overwrite

  # Generate each API key once. The value only ever exists in Secrets Manager and the cluster.
  secret_id="leadpipe/${environment}/api-key"
  if ! aws secretsmanager get-secret-value --secret-id "${secret_id}" >/dev/null 2>&1; then
    aws secretsmanager put-secret-value --secret-id "${secret_id}" \
      --secret-string "$(openssl rand -hex 32)" >/dev/null
    echo "Generated the API key for ${environment}"
  fi
done

vpc_id="$(aws eks describe-cluster --name "${CLUSTER}" --query cluster.resourcesVpcConfig.vpcId --output text)"

# Its AWS permissions come from the Pod Identity association in infra/modules/iam, which is
# keyed to this namespace and service account name.
helm upgrade aws-load-balancer-controller aws-load-balancer-controller --install \
  --repo https://aws.github.io/eks-charts \
  --version "${CONTROLLER_CHART_VERSION}" \
  --namespace kube-system \
  --set-string "clusterName=${CLUSTER}" \
  --set-string "region=${AWS_REGION}" \
  --set-string "vpcId=${vpc_id}" \
  --set-string serviceAccount.name=aws-load-balancer-controller \
  --wait --timeout 5m

kubectl --namespace kube-system get deployment aws-load-balancer-controller
