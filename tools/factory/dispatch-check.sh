#!/usr/bin/env bash
# Runs a workflow for committed HEAD on a throwaway ref and waits for its result
# (like ci-suite.sh, which stays the factory's test command).
# Usage: dispatch-check.sh <workflow.yml> [input=value ...]
#   dispatch-check.sh voice-apk.yml publish=false   # compile Kotlin, no voice-apk-bin update
#   dispatch-check.sh voice-apk.yml publish=true    # build for the phone
#   dispatch-check.sh voice-review.yml              # renders -> branch voice-review-bin
# workflow_dispatch only works for workflows that exist on the default branch.
# Workflows not on origin/main yet are triggered by the push itself instead: they
# must list the branch pattern ci-<name>/** (and ci-<name>-publish/** for
# publish=true) under on.push.branches. Inputs are then ignored except publish.
set -euo pipefail
repo=birkschmithuesen/Wing
workflow=$1; shift
name=${workflow%.yml}
sha=$(git rev-parse HEAD)
prefix="ci-$name"
for kv in "$@"; do
  [ "$kv" = "publish=true" ] && prefix="ci-$name-publish"
done
br="$prefix/${sha:0:12}"
on_main=false
git fetch -q origin main
git cat-file -e "origin/main:.github/workflows/$workflow" 2>/dev/null && on_main=true
git push -q -f origin "HEAD:refs/heads/$br"
trap 'git push -q origin --delete "$br" >/dev/null 2>&1 || true' EXIT
if $on_main; then
  fields=()
  for kv in "$@"; do fields+=(-f "$kv"); done
  gh workflow run "$workflow" -R "$repo" --ref "$br" "${fields[@]}" >/dev/null
fi
id=""
for _ in $(seq 1 30); do
  id=$(gh run list -R "$repo" --branch "$br" \
        --json databaseId,headSha,workflowName,path --jq ".[] | select(.headSha==\"$sha\" and (.path|endswith(\"/$workflow\"))) | .databaseId" | head -1)
  [ -n "$id" ] && break
  sleep 5
done
[ -n "$id" ] || { echo "dispatch-check: no $workflow run appeared for $br" >&2; exit 2; }
echo "dispatch-check: $workflow run $id for $sha"
gh run watch "$id" -R "$repo" --interval 20 >/dev/null 2>&1 || true
concl=$(gh run view "$id" -R "$repo" --json conclusion --jq .conclusion)
gh run view "$id" -R "$repo" --json jobs \
  --jq '.jobs[] | "\(.name): \(.conclusion)" , (.steps[] | select(.conclusion=="failure") | "  failed step: \(.name)")' || true
echo "dispatch-check: $workflow run $id conclusion=$concl https://github.com/$repo/actions/runs/$id"
[ "$concl" = "success" ]
