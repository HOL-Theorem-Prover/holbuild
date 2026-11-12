#!/usr/bin/env bash
# Require successful consumer evidence from this exact tag and source commit.
set -euo pipefail
[[ $# == 2 ]] || { echo "usage: $0 TAG COMMIT" >&2; exit 2; }
: "${GH_REPO:?required}"
tag=$1
commit=$2
[[ $tag =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ && $commit =~ ^[0-9a-f]{40}$ ]] || exit 2
runs=$(gh api --paginate "repos/$GH_REPO/actions/workflows/release.yml/runs?head_sha=$commit&per_page=100" \
  --jq '.workflow_runs[] | select(.event == "push") | [.id, .head_branch, .head_sha] | @tsv')
while IFS=$'\t' read -r run branch sha; do
  [[ $branch == "$tag" && $sha == "$commit" ]] || continue
  result=$(gh api --paginate "repos/$GH_REPO/actions/runs/$run/jobs?filter=latest&per_page=100" \
    --jq '.jobs[] | select(.name == "consumers") | .conclusion')
  if [[ $result == success ]]; then
    echo "$tag: all three consumers passed in release run $run ($commit)"
    exit 0
  fi
done <<< "$runs"
echo "$tag: no release run has a successful consumer check at $commit" >&2
exit 1
