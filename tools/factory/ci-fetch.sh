#!/usr/bin/env bash
# Usage: ci-fetch.sh <url> <sha256> <dest>
# Downloads a public URL via GitHub Actions (the vServer egress blocks
# release-assets.githubusercontent.com). Pushes a throwaway ci-fetch/<id> branch
# with a request file, the ci-fetch.yml workflow downloads + verifies the file and
# replaces the branch with a one-file orphan commit, which we fetch and unpack.
# HEAD must contain .github/workflows/ci-fetch.yml. Working tree/branch untouched.
set -euo pipefail
[ $# -eq 3 ] || { echo "usage: $0 <url> <sha256> <dest>" >&2; exit 64; }
url=$1 sha=$2 dest=$3
repo=birkschmithuesen/Wing
tmp=$(mktemp -d)
id=$(printf '%s' "$url$sha" | sha256sum | cut -c1-10)
br="ci-fetch/$id"
trap 'rm -rf "$tmp"; git push -q origin --delete "$br" >/dev/null 2>&1 || true' EXIT

# Request commit = HEAD's tree + .ci-fetch/request, built with a temp index.
export GIT_INDEX_FILE="$tmp/index"
git read-tree HEAD
blob=$(printf '%s\n%s\n' "$url" "$sha" | git hash-object -w --stdin)
git update-index --add --cacheinfo "100644,$blob,.ci-fetch/request"
tree=$(git write-tree)
unset GIT_INDEX_FILE
req=$(git commit-tree "$tree" -p HEAD -m "ci-fetch request $id")

git push -q -f origin "$req:refs/heads/$br"
rid=""
for _ in $(seq 1 30); do
  rid=$(gh run list -R "$repo" --branch "$br" \
        --json databaseId,headSha --jq ".[] | select(.headSha==\"$req\") | .databaseId" | head -1)
  [ -n "$rid" ] && break
  sleep 5
done
[ -n "$rid" ] || { echo "ci-fetch: no run appeared for $br" >&2; exit 2; }
echo "ci-fetch: run $rid"
gh run watch "$rid" -R "$repo" --interval 10 >/dev/null 2>&1 || true
concl=$(gh run view "$rid" -R "$repo" --json conclusion --jq .conclusion)
[ "$concl" = success ] || { echo "ci-fetch: run $rid $concl https://github.com/$repo/actions/runs/$rid" >&2; exit 1; }

git fetch -q origin "+refs/heads/$br:refs/ci-fetch/$id"
mkdir -p "$(dirname "$dest")"
git cat-file blob "refs/ci-fetch/$id:payload" > "$dest"
git update-ref -d "refs/ci-fetch/$id"
echo "$sha  $dest" | sha256sum -c -
