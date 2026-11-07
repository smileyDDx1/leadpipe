#!/usr/bin/env bash
# Demo: a pull request with a bug cannot reach main.
#
# Opens a real pull request that changes one scoring threshold, lets CI run on it, shows GitHub
# refusing the merge, then closes it and deletes the branch. It never tries to merge, and it cleans
# up even if something goes wrong along the way.
#
# Usage: scripts/demos/pipeline-gate.sh
set -euo pipefail
# shellcheck source=scripts/demos/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

REPO="$(gh repo view --json nameWithOwner --jq .nameWithOwner)"
BRANCH="demo/failing-test"
FILE="app/worker/leadpipe_worker/scoring.py"

read_file() {
  gh api "repos/${REPO}/contents/${FILE}?ref=$1" --jq .content | base64 --decode --ignore-garbage
}

clean_up() {
  gh pr close "${BRANCH}" >/dev/null 2>&1 || true
  gh api --method DELETE "repos/${REPO}/git/refs/heads/${BRANCH}" >/dev/null 2>&1 || true
}

say "The merge gate on main"
gh api "repos/${REPO}/branches/main/protection" --jq '"required check: \(.required_status_checks.contexts | join(", "))  |  must be up to date: \(.required_status_checks.strict)  |  applies to admins too: \(.enforce_admins.enabled)"'

say "Opening a pull request with a one-line bug"
trap clean_up EXIT
main_sha="$(gh api "repos/${REPO}/git/ref/heads/main" --jq .object.sha)"
gh api --method POST "repos/${REPO}/git/refs" -f "ref=refs/heads/${BRANCH}" -f "sha=${main_sha}" >/dev/null
file_sha="$(gh api "repos/${REPO}/contents/${FILE}?ref=${BRANCH}" --jq .sha)"
gh api --method PUT "repos/${REPO}/contents/${FILE}" \
  -f "branch=${BRANCH}" -f "sha=${file_sha}" -f "message=Demo: raise the hot lead threshold" \
  -f "content=$(read_file "${BRANCH}" | sed 's/^HOT_THRESHOLD = 70$/HOT_THRESHOLD = 90/' | base64 --wrap=0)" >/dev/null
gh pr create --base main --head "${BRANCH}" --title "Demo: a scoring bug that must not reach main" \
  --body "Opened by \`scripts/demos/pipeline-gate.sh\` to show the merge gate. The script closes it without merging." \
  | sed 's/^/    /'
gh pr diff "${BRANCH}" | grep -E '^[-+][^-+]' | sed 's/^/    /'

say "CI runs on the pull request"
# Match the run by commit. The branch name is reused between demos, so it can match an old run.
head_sha="$(gh pr view "${BRANCH}" --json headRefOid --jq .headRefOid)"
run=""
for _ in $(seq 1 30); do
  run="$(gh run list --commit "${head_sha}" --workflow CI --limit 1 --json databaseId --jq '.[0].databaseId // empty')"
  [[ -n "${run}" ]] && break
  sleep 5
done
if [[ -z "${run}" ]]; then
  echo "FAIL: CI did not start within 150 seconds" >&2
  exit 1
fi
echo "    https://github.com/${REPO}/actions/runs/${run}"

while :; do
  state="$(gh run view "${run}" --json status,jobs --jq '"\(.status) \([.jobs[] | select(.status == "completed")] | length)/\(.jobs | length)"')"
  echo "    $(date +%H:%M:%S)  run ${state%% *}, jobs finished: ${state##* }"
  [[ "${state%% *}" == "completed" ]] && break
  sleep 15
done

say "CI results"
(gh pr checks "${BRANCH}" --json bucket,name --jq '.[] | "\(.bucket)\t\(.name)"' || true) | sort
gate="$(gh pr checks "${BRANCH}" --json bucket,name --jq '.[] | select(.name == "CI passed") | .bucket' || true)"

say "What failed, from the logs"
gh run view "${run}" --log-failed \
  | cut -f3- | sed -E 's/^[^ ]+ //' \
  | grep -E '^FAILED tests|^FAIL  |[0-9]+ failed, [0-9]+ passed' | sort -u | cut -c1-105 | head -6

say "Pull request state according to GitHub"
for _ in $(seq 1 12); do
  merge_state="$(gh pr view "${BRANCH}" --json mergeStateStatus --jq .mergeStateStatus)"
  [[ "${merge_state}" != "UNKNOWN" ]] && break
  sleep 5
done
gh pr view "${BRANCH}" --json number,state --jq '"pull request #\(.number)  |  state: \(.state)  |  mergeStateStatus: '"${merge_state}"'"'

say "Closing it without merging, and checking main"
clean_up
trap - EXIT
read_file main | grep -E '^HOT_THRESHOLD' | sed 's/^/    main still has: /'

# BLOCKED alone proves little, because GitHub also reports it while checks are still pending.
if [[ "${gate}" != "fail" || "${merge_state}" != "BLOCKED" ]]; then
  echo "FAIL: expected CI passed to fail and the state to be BLOCKED, got [${gate}] and [${merge_state}]" >&2
  exit 1
fi
echo "    PASS: the required check failed, and GitHub refused the merge"
