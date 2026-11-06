#!/usr/bin/env bash
# Validates and tests every Terraform config. No AWS account is needed, because the tests run
# against a mocked provider. They prove the wiring and the rules, not that AWS accepts the result.
set -euo pipefail

INFRA="$(cd "$(dirname "${BASH_SOURCE[0]}")/../infra" && pwd)"
TERRAFORM="${TERRAFORM:-terraform}"
LOCK_FILE="${INFRA}/main/.terraform.lock.hcl"

# Terraform downloads the provider again for any config with no lock file entry, even if it is
# already in the plugin cache. The AWS provider is about 180 MB and there are seven configs, so
# share one cache and give the modules a copy of the committed lock file. These copies are
# git-ignored. The default cache sits under an ignored .terraform directory.
export TF_PLUGIN_CACHE_DIR="${TF_PLUGIN_CACHE_DIR:-${INFRA}/.terraform/plugin-cache}"
mkdir -p "${TF_PLUGIN_CACHE_DIR}"

for config in bootstrap modules/vpc modules/eks modules/rds modules/ecr modules/iam main; do
  echo "==> ${config}"
  if [[ "${config}" == modules/* ]]; then
    cp "${LOCK_FILE}" "${INFRA}/${config}/.terraform.lock.hcl"
  fi
  "${TERRAFORM}" -chdir="${INFRA}/${config}" init -backend=false -input=false >/dev/null
  "${TERRAFORM}" -chdir="${INFRA}/${config}" validate
  "${TERRAFORM}" -chdir="${INFRA}/${config}" test
done
