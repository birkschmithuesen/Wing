#!/usr/bin/env bash
# Upstream-compatibility metrics for the fork (card t_ba3601fa).
#  (a) our lines in upstream-owned files: files that exist at the merge-base
#      and that we modified (--diff-filter=M), per file and total, plus
#      whether upstream also changed the file since the merge-base;
#  (b) probe merge of <upstream> into <branch> in a throwaway detached
#      worktree: conflict files (with git status code) and conflict blocks.
# Read-only for the current checkout; the probe worktree is removed on exit.
# Usage: tools/factory/upstream-diff-metrics.sh [branch=HEAD] [upstream=upstream/main]
set -euo pipefail
branch=${1:-HEAD}
upstream=${2:-upstream/main}
top=$(git rev-parse --show-toplevel)
base=$(git merge-base "$upstream" "$branch")
echo "branch $(git rev-parse --short=8 "$branch")  upstream $(git rev-parse --short=8 "$upstream")  merge-base $(git rev-parse --short=8 "$base")"

theirs=$(git diff --name-only "$base" "$upstream")
echo
echo "== (a) our lines in upstream files (added deleted path [U=upstream changed it too])"
git diff --numstat --diff-filter=M "$base" "$branch" | sort -k1,1nr | {
  n=0; a=0; d=0
  while read -r add del path; do
    mark=" "
    grep -qxF "$path" <<<"$theirs" && mark="U"
    printf '%6s %6s %s %s\n' "$add" "$del" "$mark" "$path"
    n=$((n + 1)); a=$((a + add)); d=$((d + del))
  done
  echo "TOTAL modified upstream files: $n  +$a -$d"
}

echo
echo "== (b) probe merge $upstream -> $branch"
probe="$top/.worktrees/upstream-probe-$$"
git worktree add -q --detach "$probe" "$branch"
trap 'git worktree remove --force "$probe" >/dev/null 2>&1 || true' EXIT
git -C "$probe" -c user.name=probe -c user.email=probe@invalid \
  merge -q --no-commit --no-ff "$upstream" >/dev/null 2>&1 || true
files=0; blocks=0
while IFS= read -r line; do
  code=${line:0:2}
  path=${line:3}
  case "$code" in
    DD|AU|UD|UA|DU|AA|UU) ;;
    *) continue ;;
  esac
  n=0
  [ -f "$probe/$path" ] && n=$(grep -c '^<<<<<<< ' "$probe/$path" || true)
  printf '%4s %s %s\n' "$n" "$code" "$path"
  files=$((files + 1)); blocks=$((blocks + n))
done < <(git -C "$probe" status --porcelain=v1 --untracked-files=no)
echo "TOTAL conflict files: $files  conflict blocks: $blocks"
