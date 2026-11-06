#!/usr/bin/env bash
# Configures the GitHub side of the pipeline: variables, approval gates and the merge gate.
#
# Usage: scripts/github-setup.sh <aws-account-id> <aws-region>
#
# Run it once `gh` is logged in to an account with admin rights on the repository. On GitHub Free,
# Pro and Team plans, required reviewers only work on public repositories.
set -euo pipefail

ACCOUNT_ID="${1:?usage: github-setup.sh <aws-account-id> <aws-region>}"
REGION="${2:?usage: github-setup.sh <aws-account-id> <aws-region>}"
REPO="$(gh repo view --json nameWithOwner --jq .nameWithOwner)"
REVIEWER_ID="$(gh api user --jq .id)"

gh variable set AWS_ACCOUNT_ID --body "${ACCOUNT_ID}"
gh variable set AWS_REGION --body "${REGION}"

# Staging deploys on its own, but only from main. Without this, a workflow on any branch could
# name the environment and assume the staging role.
gh api --method PUT "repos/${REPO}/environments/staging" --input - --silent <<'EOF'
{
  "deployment_branch_policy": { "protected_branches": true, "custom_branch_policies": false }
}
EOF

# Production and infrastructure changes also wait for a person.
for environment in production infrastructure; do
  gh api --method PUT "repos/${REPO}/environments/${environment}" --input - --silent <<EOF
{
  "reviewers": [{ "type": "User", "id": ${REVIEWER_ID} }],
  "deployment_branch_policy": { "protected_branches": true, "custom_branch_policies": false }
}
EOF
done

# The merge gate: nothing reaches main unless the `CI passed` job succeeded.
gh api --method PUT "repos/${REPO}/branches/main/protection" --input - --silent <<'EOF'
{
  "required_status_checks": { "strict": true, "contexts": ["CI passed"] },
  "enforce_admins": true,
  "required_pull_request_reviews": null,
  "restrictions": null
}
EOF

echo "Configured ${REPO}: variables, environments, and branch protection on main."
