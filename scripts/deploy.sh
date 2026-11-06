#!/usr/bin/env bash
# Deploys LeadPipe with Helm, smoke-tests it, and rolls back automatically if the test fails.
# GitHub Actions and local kind runs share this script, so the local demos exercise the real path.
#
# Usage: scripts/deploy.sh <local|staging|production> <image-tag>
#
# staging and production also need:
#   AWS_REGION            the AWS region
#   IMAGE_REGISTRY        the ECR registry, such as 123456789012.dkr.ecr.ap-south-1.amazonaws.com
#   A kubeconfig for the cluster, and AWS credentials for this environment's deploy role
set -euo pipefail

ENVIRONMENT="${1:?usage: deploy.sh <local|staging|production> <image-tag>}"
TAG="${2:?usage: deploy.sh <local|staging|production> <image-tag>}"
CHART_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../helm/leadpipe" && pwd)"
RELEASE="leadpipe"
SECRET_NAME="leadpipe-secrets"

case "${ENVIRONMENT}" in
  local)
    NAMESPACE="leadpipe"
    VALUES_FILE="values-local.yaml"
    ;;
  staging)
    NAMESPACE="staging"
    VALUES_FILE="values-staging.yaml"
    ;;
  production)
    NAMESPACE="production"
    VALUES_FILE="values-prod.yaml"
    ;;
  *)
    echo "unknown environment: ${ENVIRONMENT}" >&2
    exit 2
    ;;
esac

# Check for every tool before changing anything. A tool that goes missing halfway through could
# leave a broken release live, with the rollback step never reached.
required_tools=(helm)
if [[ "${ENVIRONMENT}" != "local" ]]; then
  required_tools+=(aws jq kubectl sha256sum)
fi
for tool in "${required_tools[@]}"; do
  if ! command -v "${tool}" >/dev/null; then
    echo "deploy.sh needs ${tool}, which is not installed. Nothing was changed." >&2
    exit 2
  fi
done

helm_args=(
  --namespace "${NAMESPACE}"
  --values "${CHART_DIR}/${VALUES_FILE}"
  --set-string "image.tag=${TAG}"
)

if [[ "${ENVIRONMENT}" != "local" ]]; then
  : "${IMAGE_REGISTRY:?IMAGE_REGISTRY is required}"

  # RDS owns the database password and keeps it in Secrets Manager. Terraform never sees it.
  read -r db_host db_secret_arn < <(aws rds describe-db-instances \
    --db-instance-identifier "${DB_INSTANCE_ID:-leadpipe}" \
    --query 'DBInstances[0].[Endpoint.Address,MasterUserSecret.SecretArn]' \
    --output text)
  : "${db_host:?could not find the database}"
  db_secret="$(aws secretsmanager get-secret-value \
    --secret-id "${db_secret_arn}" --query SecretString --output text)"
  api_key="$(aws secretsmanager get-secret-value \
    --secret-id "leadpipe/${ENVIRONMENT}/api-key" --query SecretString --output text)"

  # Stop GitHub Actions from ever printing these values, even by accident.
  if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
    echo "::add-mask::$(jq -r .password <<<"${db_secret}")"
    echo "::add-mask::${api_key}"
  fi

  # Credentials stay out of Helm values and release history, so the Secret is created directly.
  # Process substitution keeps the values out of the process list.
  kubectl create secret generic "${SECRET_NAME}" \
    --namespace "${NAMESPACE}" \
    --from-env-file=<(
      jq -r '"DB_USER=\(.username)\nDB_PASSWORD=\(.password)"' <<<"${db_secret}"
      printf 'API_KEY=%s\n' "${api_key}"
    ) \
    --dry-run=client --output yaml | kubectl apply --filename -

  helm_args+=(
    --set-string "image.registry=${IMAGE_REGISTRY}"
    --set-string "database.host=${db_host}"
    # A changed secret changes this hash, which restarts the pods so they pick up the new values.
    --set-string "secrets.checksum=$(sha256sum <<<"${db_secret}${api_key}" | cut -d' ' -f1)"
  )
fi

echo "==> Deploying ${TAG} to ${ENVIRONMENT} (namespace ${NAMESPACE})"
# --rollback-on-failure covers a failed migration or pods that never become ready.
helm upgrade "${RELEASE}" "${CHART_DIR}" --install \
  "${helm_args[@]}" \
  --rollback-on-failure \
  --wait \
  --timeout "${DEPLOY_TIMEOUT:-10m}"

echo "==> Smoke testing ${ENVIRONMENT}"
# The smoke test covers what Helm's readiness wait cannot: the Service routing real requests.
if helm test "${RELEASE}" --namespace "${NAMESPACE}" --timeout 3m --logs; then
  echo "==> ${TAG} is live in ${ENVIRONMENT}"
  exit 0
fi

echo "==> Smoke test failed" >&2
revision="$(helm history "${RELEASE}" --namespace "${NAMESPACE}" --max 1 | awk 'END { print $1 }')"
if [[ "${revision}" -le 1 ]]; then
  echo "==> This is the first release, so there is nothing to roll back to" >&2
  exit 1
fi
echo "==> Rolling back ${ENVIRONMENT} to the previous release" >&2
helm rollback "${RELEASE}" 0 --namespace "${NAMESPACE}" --wait --timeout 5m
echo "==> Rolled back. ${TAG} is not live." >&2
exit 1
