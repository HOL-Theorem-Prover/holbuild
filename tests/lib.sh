#!/usr/bin/env bash

require_file() {
  local path=$1
  [[ -f "$path" ]] || { echo "missing expected file: $path" >&2; exit 1; }
}

require_grep() {
  local pattern=$1
  local path=$2
  grep -q "$pattern" "$path" || {
    echo "missing expected pattern '$pattern' in $path" >&2
    exit 1
  }
}

make_temp_dir() {
  mktemp -d "${TMPDIR:-/tmp}/holbuild-test.XXXXXX"
}

cache_hit_key() {
  local target=$1
  local path=$2
  awk -v target="$target" '
    $0 ~ "cache hit: " target " .* key=" {
      sub(/^.* key=/, "")
      sub(/[[:space:]].*$/, "")
      print
      exit
    }
  ' "$path"
}

require_cache_hit_key() {
  local target=$1
  local path=$2
  local key
  key=$(cache_hit_key "$target" "$path")
  if [[ -z "$key" ]]; then
    echo "missing cache hit key for $target in $path" >&2
    exit 1
  fi
  printf '%s\n' "$key"
}
