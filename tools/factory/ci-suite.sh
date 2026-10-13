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
gh run watch "$id" -R "$repo" --exit-status --interval 20 >/dev/null && rc=0 || rc=$?
# Best-effort summary grep: the log endpoint (results-receiver.actions.githubusercontent.com)
# is behind the vServer egress allowlist and can time out. That must not corrupt $rc,
# which already carries the real result from `gh run watch` above.
gh run view "$id" -R "$repo" --log 2>/dev/null | grep -E "PASSED|FAILED|All tests passed|Some tests failed|[0-9]+ issues? found|No issues found" | sed 's/^.*Z //' | tail -8 || true
echo "ci-suite: run $id result rc=$rc"
exit $rc
