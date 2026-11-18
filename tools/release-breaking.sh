#!/usr/bin/env bash
# Usage: tools/release-breaking.sh BASE TAG
#
# Decides whether the release TAG is breaking relative to BASE, the latest
# published release.  It is breaking when the golden key dump changed (its
# action or theory cache keys differ) or a commit in BASE..TAG carries a
# "Breaking-change:" trailer.  Prints one reason per line and exits 1 when
# breaking; exits 0 otherwise.
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "usage: $0 BASE TAG" >&2
  exit 2
fi
base=$1
tag=$2
breaking=0

if ! git diff --quiet "$base" "$tag" -- tests/golden/key-dumps; then
  echo "cache keys changed since $base (tests/golden/key-dumps)"
  breaking=1
fi

while IFS= read -r trailer; do
  [[ -n "$trailer" ]] || continue
  echo "Breaking-change: $trailer"
  breaking=1
done < <(git log --format='%(trailers:key=Breaking-change,valueonly,separator=%x0a)' "$base..$tag")

exit "$breaking"
