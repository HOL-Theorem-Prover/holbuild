#!/usr/bin/env bash
# Validate the packaged candidate against trusted consumer mains before release.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
: "${GITHUB_WORKSPACE:?required}" "${GITHUB_SHA:?required}" "${GITHUB_REF_NAME:?required}"
: "${RUNNER_TEMP:?required}" "${GITHUB_STEP_SUMMARY:?required}" "${GH_REPO:?required}"
: "${HOLBUILD_REMOTE_EXEC_URL:?required}" "${HOLBUILD_REMOTE_CACHE_URL:?required}"
: "${EXEC_CURL_CONFIG_CONTENT:?fleet credential required}"
: "${CACHE_CURL_CONFIG_CONTENT:?cache credential required}"
tag=$GITHUB_REF_NAME
[[ $tag =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Expected a numeric release tag, got $tag" >&2; exit 2; }
[[ $HOLBUILD_REMOTE_EXEC_URL == https://* && $HOLBUILD_REMOTE_CACHE_URL == https://* ]] || {
  echo 'Release checks require HTTPS fleet and cache URLs' >&2; exit 2;
}
[[ $(git -C "$GITHUB_WORKSPACE" rev-parse HEAD) == "$GITHUB_SHA" ]] || {
  echo "Checkout differs from candidate source $GITHUB_SHA" >&2; exit 2;
}
refs=$(git ls-remote "https://github.com/$GH_REPO.git" "refs/tags/$tag" "refs/tags/$tag^{}")
commit=$(awk '$2 ~ /\^\{\}$/ {print $1; found=1} END {if (!found) print first} NR==1 {first=$1}' <<< "$refs")
[[ $commit == "$GITHUB_SHA" ]] || { echo "Tag $tag does not resolve to candidate source $GITHUB_SHA" >&2; exit 2; }

work="$RUNNER_TEMP/release-consumers"
mkdir -p "$work/evidence" "$work/candidate" "$work/baseline"
auth=$(mktemp -d "$RUNNER_TEMP/release-consumer-auth.XXXXXX")
trap 'rm -rf "$auth"' EXIT
export HOLBUILD_REMOTE_EXEC_CURL_CONFIG="$auth/exec.curl"
export HOLBUILD_REMOTE_CACHE_CURL_CONFIG="$auth/cache.curl"
install -m 600 /dev/null "$HOLBUILD_REMOTE_EXEC_CURL_CONFIG"
install -m 600 /dev/null "$HOLBUILD_REMOTE_CACHE_CURL_CONFIG"
printf '%s\n' "$EXEC_CURL_CONFIG_CONTENT" > "$HOLBUILD_REMOTE_EXEC_CURL_CONFIG"
printf '%s\n' "$CACHE_CURL_CONFIG_CONTENT" > "$HOLBUILD_REMOTE_CACHE_CURL_CONFIG"
unset EXEC_CURL_CONFIG_CONTENT CACHE_CURL_CONFIG_CONTENT
export HOLBUILD_CACHE="$work/cache"
export HOLBUILD_REMOTE_CACHE_URL

status=$(curl -q -sS -o /dev/null -w '%{http_code}' --max-time 15 \
  -K "$HOLBUILD_REMOTE_EXEC_CURL_CONFIG" "$HOLBUILD_REMOTE_EXEC_URL/v1/queue")
[[ $status == 200 ]] || { echo "Fleet probe returned HTTP $status" >&2; exit 1; }
status=$(curl -q -sS -o /dev/null -w '%{http_code}' --max-time 15 \
  -K "$HOLBUILD_REMOTE_CACHE_CURL_CONFIG" "$HOLBUILD_REMOTE_CACHE_URL/ac/$(printf '%064d' 0)")
[[ $status == 404 || $status == 200 ]] || { echo "Cache probe returned HTTP $status" >&2; exit 1; }

name="holbuild-$tag-linux-x86_64"
archive="$name.tar.gz"
(cd "$GITHUB_WORKSPACE/download" && sha256sum -c "$archive.sha256")
tar -xzf "$GITHUB_WORKSPACE/download/$archive" -C "$work/candidate"
candidate="$work/candidate/$name/bin/holbuild"
[[ $("$candidate" --version) == "holbuild ${tag#v}" ]] || { echo 'Candidate version differs from tag' >&2; exit 2; }
{
  printf 'Candidate: `%s` at `%s`\n\n' "$tag" "$GITHUB_SHA"
  printf 'Archive SHA256: `%s`\n\n' "$(sha256sum "$GITHUB_WORKSPACE/download/$archive" | cut -d ' ' -f1)"
  printf 'Executable SHA256: `%s`\n\n' "$(sha256sum "$candidate" | cut -d ' ' -f1)"
} | tee "$work/evidence/candidate.md" >> "$GITHUB_STEP_SUMMARY"

consumers=(vyper-hol verifereum solidity-hol)
for consumer in "${consumers[@]}"; do
  git clone --depth 1 --branch main "https://github.com/verifereum/$consumer.git" "$work/$consumer"
  printf '%s main: `%s`\n\n' "$consumer" "$(git -C "$work/$consumer" rev-parse HEAD)" \
    | tee "$work/evidence/$consumer.md" >> "$GITHUB_STEP_SUMMARY"
done

base=$(gh api "repos/$GH_REPO/releases/latest" --jq .tag_name)
[[ $base =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Invalid published release tag: $base" >&2; exit 2; }
old_name="holbuild-$base-linux-x86_64"
gh release download "$base" --pattern "$old_name.tar.gz" --pattern SHA256SUMS --dir "$work/baseline"
(cd "$work/baseline" && awk -v name="$old_name.tar.gz" '$2 == name' SHA256SUMS | sha256sum -c -)
tar -xzf "$work/baseline/$old_name.tar.gz" -C "$work/baseline"
old="$work/baseline/$old_name/bin/holbuild"
[[ $("$old" --version) == "holbuild ${base#v}" ]] || { echo 'Published binary version differs from tag' >&2; exit 2; }
printf 'Cache compatibility baseline: `%s`\n\n' "$base" >> "$GITHUB_STEP_SUMMARY"
lost=0
# Complete every inventory before any consumer can warm shared dependency keys.
for consumer in "${consumers[@]}"; do
  status=0
  (cd "$work/$consumer" && "$root/tools/release-key-inventory.sh" "$old" "$candidate" --skip-proof-steps) \
    > "$work/evidence/$consumer-inventory.txt" 2>&1 || status=$?
  {
    printf '\n%s initial cache inventory:\n\n```text\n' "$consumer"
    cat "$work/evidence/$consumer-inventory.txt"
    printf '```\n\n'
  } >> "$GITHUB_STEP_SUMMARY"
  case $status in
    0) ;;
    1) lost=1 ;;
    *) echo "$consumer cache inventory failed (exit $status)" >&2; exit "$status" ;;
  esac
done
if [[ $lost == 1 ]]; then
  # Save the loss before warming: a retry must not silently publish after its
  # predecessor has filled the candidate cache entries.
  releases=$(gh api --paginate --slurp "repos/$GH_REPO/releases")
  existing=$(jq -c --arg tag "$tag" '[.[][] | select(.tag_name == $tag)] | first // empty' <<< "$releases")
  notes="$work/evidence/compatibility-loss.md"
  printf 'Breaking release: consumer cache compatibility changed since %s.\n\n' "$base" > "$notes"
  for consumer in "${consumers[@]}"; do
    printf '%s\n\n' "$consumer" >> "$notes"
    cat "$work/evidence/$consumer-inventory.txt" >> "$notes"
    printf '\n' >> "$notes"
  done
  if [[ -n $existing ]]; then
    jq -r '.body // ""' <<< "$existing" >> "$notes"
    gh release edit "$tag" --draft=true --notes-file "$notes"
  else
    gh release create "$tag" --verify-tag --draft --title "$tag" --notes-file "$notes"
  fi
fi

for consumer in "${consumers[@]}"; do
  status=0
  (cd "$work/$consumer" && "$candidate" build --skip-proof-steps --remote-only \
    --remote-exec "$HOLBUILD_REMOTE_EXEC_URL") 2>&1 | tee "$work/evidence/$consumer-build.txt" || status=$?
  printf '%s build exit: `%s`\n\n' "$consumer" "$status" >> "$GITHUB_STEP_SUMMARY"
  [[ $status == 0 ]] || exit "$status"
done
