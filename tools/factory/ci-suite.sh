#!/usr/bin/env bash
# Full Wing suite (flutter analyze + flutter test) on GitHub Actions.
# The vServer has no Flutter SDK (egress blocks Google storage), so the
# factory's test command pushes HEAD to a throwaway ci/<sha> branch, dispatches
# pr-quality.yml there and waits for its result. Exit code = suite result.
set -euo pipefail
repo=birkschmithuesen/Wing
sha=$(git rev-parse HEAD)
br="ci/${sha:0:12}"
git push -q -f origin "HEAD:refs/heads/$br"
trap 'git push -q origin --delete "$br" >/dev/null 2>&1 || true' EXIT
gh workflow run pr-quality.yml -R "$repo" --ref "$br" >/dev/null
id=""
for _ in $(seq 1 30); do
  id=$(gh run list -R "$repo" --workflow pr-quality.yml --branch "$br" \
        --json databaseId,headSha --jq ".[] | select(.headSha==\"$sha\") | .databaseId" | head -1)
  [ -n "$id" ] && break
  sleep 5
done
[ -n "$id" ] || { echo "ci-suite: no pr-quality run appeared for $br" >&2; exit 2; }
echo "ci-suite: run $id for $sha"
gh run watch "$id" -R "$repo" --interval 20 >/dev/null 2>&1 || true
# Result from the API, not from the logs: the log download host
# (results-receiver.actions.githubusercontent.com) is blocked by the egress firewall.
concl=$(gh run view "$id" -R "$repo" --json conclusion --jq .conclusion)
gh run view "$id" -R "$repo" --json jobs \
  --jq '.jobs[] | "\(.name): \(.conclusion)" , (.steps[] | select(.conclusion=="failure") | "  failed step: \(.name)")' || true
echo "ci-suite: run $id conclusion=$concl https://github.com/$repo/actions/runs/$id"
[ "$concl" = "success" ]
