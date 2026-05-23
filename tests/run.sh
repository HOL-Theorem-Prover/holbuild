#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
HOLBUILD_BIN=${HOLBUILD_BIN:-"$ROOT/bin/holbuild"}
HOLDIR=${HOLDIR:-${HOLBUILD_HOLDIR:-}}
HOLBUILD_TEST_JOBS=${HOLBUILD_TEST_JOBS:-1}
HOLBUILD_TEST_SHARD_INDEX=${HOLBUILD_TEST_SHARD_INDEX:-0}
HOLBUILD_TEST_SHARD_COUNT=${HOLBUILD_TEST_SHARD_COUNT:-1}
HOLBUILD_TEST_PREWARM=${HOLBUILD_TEST_PREWARM:-1}
HOLBUILD_TEST_PREWARM_ONLY=${HOLBUILD_TEST_PREWARM_ONLY:-0}

if [[ -z "$HOLDIR" ]]; then
  echo "Set HOLDIR=/path/to/HOL or HOLBUILD_HOLDIR" >&2
  exit 2
fi

case "$HOLBUILD_TEST_JOBS" in
  ''|*[!0-9]*) echo "HOLBUILD_TEST_JOBS must be a positive integer" >&2; exit 2 ;;
esac
if [[ "$HOLBUILD_TEST_JOBS" -lt 1 ]]; then
  echo "HOLBUILD_TEST_JOBS must be a positive integer" >&2
  exit 2
fi
case "$HOLBUILD_TEST_SHARD_COUNT" in
  ''|*[!0-9]*) echo "HOLBUILD_TEST_SHARD_COUNT must be a positive integer" >&2; exit 2 ;;
esac
if [[ "$HOLBUILD_TEST_SHARD_COUNT" -lt 1 ]]; then
  echo "HOLBUILD_TEST_SHARD_COUNT must be a positive integer" >&2
  exit 2
fi
case "$HOLBUILD_TEST_SHARD_INDEX" in
  ''|*[!0-9]*) echo "HOLBUILD_TEST_SHARD_INDEX must be a non-negative integer" >&2; exit 2 ;;
esac
if [[ "$HOLBUILD_TEST_SHARD_INDEX" -ge "$HOLBUILD_TEST_SHARD_COUNT" ]]; then
  echo "HOLBUILD_TEST_SHARD_INDEX must be less than HOLBUILD_TEST_SHARD_COUNT" >&2
  exit 2
fi

test_tmp_root=${TMPDIR:-"$ROOT/scratch/tmp"}
mkdir -p "$test_tmp_root"
log_dir=$(mktemp -d "$test_tmp_root/holbuild-test-logs.XXXXXX")
cleanup() { rm -rf "$log_dir"; }
trap cleanup EXIT

declare -a running_pids=()
declare -a running_names=()
declare -a completed_names=()
declare -a completed_durations=()
declare -a completed_summaries=()
declare -a failed_names=()

now_ms() { date +%s%3N; }

sum_field_ms() {
  local field=$1
  local file=$2
  awk -v field="$field" '
    { for (i = 1; i <= NF; i++) if ($i ~ "^" field "=") { sub("^[^=]*=", "", $i); sum += $i } }
    END { printf "%d", sum + 0 }
  ' "$file" 2>/dev/null || printf '0'
}

max_field_ms() {
  local field=$1
  local file=$2
  awk -v field="$field" '
    { for (i = 1; i <= NF; i++) if ($i ~ "^" field "=") { sub("^[^=]*=", "", $i); if (($i + 0) > max) max = $i + 0 } }
    END { printf "%d", max + 0 }
  ' "$file" 2>/dev/null || printf '0'
}

count_lines() {
  local pattern=$1
  local file=$2
  grep -c -- "$pattern" "$file" 2>/dev/null || printf '0'
}

suite_start_ms=$(now_ms)
if [[ -z "${HOLBUILD_HOL_CACHE:-}" ]]; then
  if [[ -n "${HOLBUILD_CACHE:-}" ]]; then
    export HOLBUILD_HOL_CACHE=$HOLBUILD_CACHE
  elif [[ -n "${XDG_CACHE_HOME:-}" ]]; then
    export HOLBUILD_HOL_CACHE=$XDG_CACHE_HOME/holbuild
  else
    export HOLBUILD_HOL_CACHE=${HOME:?Set HOME, XDG_CACHE_HOME, HOLBUILD_CACHE, or HOLBUILD_HOL_CACHE}/.cache/holbuild
  fi
fi
echo "running holbuild tests with HOLBUILD_TEST_JOBS=$HOLBUILD_TEST_JOBS shard=$HOLBUILD_TEST_SHARD_INDEX/$HOLBUILD_TEST_SHARD_COUNT prewarm=$HOLBUILD_TEST_PREWARM prewarm_only=$HOLBUILD_TEST_PREWARM_ONLY HOLBUILD_HOL_CACHE=$HOLBUILD_HOL_CACHE"

prewarm_holbuild_cache() {
  if [[ "$HOLBUILD_TEST_PREWARM" == 0 || "$HOLBUILD_TEST_PREWARM" == false ]]; then
    return 0
  fi
  local prewarm_dir=$log_dir/prewarm-project
  local prewarm_log=$log_dir/prewarm.log
  local start_ms end_ms duration_ms
  mkdir -p "$prewarm_dir/src"
  cat > "$prewarm_dir/holproject.toml" <<'TOML'
[project]
name = "holbuild-test-prewarm"

[build]
members = ["src"]
TOML
  cat > "$prewarm_dir/src/PrewarmScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;
val _ = new_theory "Prewarm";
val _ = store_thm("prewarm_thm", ``T``, ACCEPT_TAC TRUTH);
val _ = export_theory();
SML
  start_ms=$(now_ms)
  echo "prewarming holbuild cache with source-built HOL environment"
  if (cd "$prewarm_dir" && "$HOLBUILD_BIN" --holdir "$HOLDIR" build PrewarmTheory) > "$prewarm_log" 2>&1; then
    end_ms=$(now_ms)
    duration_ms=$((end_ms - start_ms))
    echo "prewarm complete (${duration_ms} ms)"
  else
    local status=$?
    echo "prewarm failed (exit $status); log follows" >&2
    cat "$prewarm_log" >&2
    return "$status"
  fi
}

write_holbuild_wrapper() {
  local wrapper=$1
  cat > "$wrapper" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
start_ms=$(date +%s%3N)
status=0
"$REAL_HOLBUILD_BIN" "$@" || status=$?
end_ms=$(date +%s%3N)
printf 'holbuild\tstatus=%s\tms=%s\targc=%s\n' "$status" "$((end_ms - start_ms))" "$#" >> "$HOLBUILD_CASE_TIMING_LOG"
exit "$status"
SH
  chmod +x "$wrapper"
}

write_case_timing_summary() {
  local name=$1
  local duration_ms=$2
  local case_timing=$3
  local tool_timing=$4
  local summary_file=$5
  local holbuild_count holbuild_ms tool_count tool_ms phase_count phase_ms max_tool_ms max_phase_ms top_phase

  holbuild_count=$(count_lines '^holbuild' "$case_timing")
  holbuild_ms=$(sum_field_ms ms "$case_timing")
  tool_count=$(count_lines '^tool' "$tool_timing")
  tool_ms=$(awk '
    /^tool/ { for (i = 1; i <= NF; i++) if ($i ~ /^ms=/) { sub("ms=", "", $i); sum += $i } }
    END { printf "%d", sum + 0 }
  ' "$tool_timing" 2>/dev/null || printf '0')
  phase_count=$(count_lines '^phase' "$tool_timing")
  phase_ms=$(awk '
    /^phase/ { for (i = 1; i <= NF; i++) if ($i ~ /^ms=/) { sub("ms=", "", $i); sum += $i } }
    END { printf "%d", sum + 0 }
  ' "$tool_timing" 2>/dev/null || printf '0')
  max_tool_ms=$(awk '
    /^tool/ { for (i = 1; i <= NF; i++) if ($i ~ /^ms=/) { sub("ms=", "", $i); if (($i + 0) > max) max = $i + 0 } }
    END { printf "%d", max + 0 }
  ' "$tool_timing" 2>/dev/null || printf '0')
  max_phase_ms=$(awk '
    /^phase/ { for (i = 1; i <= NF; i++) if ($i ~ /^ms=/) { sub("ms=", "", $i); if (($i + 0) > max) max = $i + 0 } }
    END { printf "%d", max + 0 }
  ' "$tool_timing" 2>/dev/null || printf '0')
  top_phase=$(awk '
    function value(key,    i, prefix) { prefix = key "="; for (i = 1; i <= NF; i++) if (index($i, prefix) == 1) return substr($i, length(prefix) + 1); return "" }
    /^phase/ { ms = value("ms") + 0; name = value("name"); totals[name] += ms }
    END { best = "none"; for (name in totals) if (totals[name] > best_ms) { best = name; best_ms = totals[name] } printf "%s:%d", best, best_ms + 0 }
  ' "$tool_timing" 2>/dev/null || printf 'none:0')

  printf 'TIMING\tname=%s\twall_ms=%s\tholbuild_n=%s\tholbuild_ms=%s\ttool_n=%s\ttool_ms=%s\tphase_n=%s\tphase_ms=%s\tmax_tool_ms=%s\tmax_phase_ms=%s\ttop_phase=%s\n' \
    "$name" "$duration_ms" "$holbuild_count" "$holbuild_ms" "$tool_count" "$tool_ms" "$phase_count" "$phase_ms" "$max_tool_ms" "$max_phase_ms" "$top_phase" > "$summary_file"
}

run_case() {
  local test_script=$1
  local name=$2
  local log=$log_dir/$name.log
  local duration_file=$log_dir/$name.duration
  local summary_file=$log_dir/$name.summary
  local case_timing=$log_dir/$name.holbuild-timing
  local tool_timing=$log_dir/$name.tool-timing
  local wrapper=$log_dir/$name.holbuild-wrapper
  local start_ms end_ms duration_ms

  write_holbuild_wrapper "$wrapper"
  start_ms=$(now_ms)
  echo "== $name ==" > "$log"
  if REAL_HOLBUILD_BIN="$HOLBUILD_BIN" \
     HOLBUILD_CASE_TIMING_LOG="$case_timing" \
     HOLBUILD_TIMING_LOG="$tool_timing" \
     "$test_script" "$wrapper" "$HOLDIR" >> "$log" 2>&1; then
    end_ms=$(now_ms)
    duration_ms=$((end_ms - start_ms))
    echo "$duration_ms" > "$duration_file"
    write_case_timing_summary "$name" "$duration_ms" "$case_timing" "$tool_timing" "$summary_file"
    cat "$summary_file" >> "$log"
    echo "PASS $name (${duration_ms} ms)" >> "$log"
  else
    local status=$?
    end_ms=$(now_ms)
    duration_ms=$((end_ms - start_ms))
    echo "$duration_ms" > "$duration_file"
    write_case_timing_summary "$name" "$duration_ms" "$case_timing" "$tool_timing" "$summary_file"
    cat "$summary_file" >> "$log"
    echo "FAIL $name (exit $status, ${duration_ms} ms)" >> "$log"
    return "$status"
  fi
}

start_case() {
  local test_script=$1
  local name=$2
  run_case "$test_script" "$name" &
  running_pids+=("$!")
  running_names+=("$name")
}

remove_running_at() {
  local index=$1
  local last=$((${#running_pids[@]} - 1))
  running_pids[$index]=${running_pids[$last]}
  running_names[$index]=${running_names[$last]}
  unset 'running_pids[$last]'
  unset 'running_names[$last]'
}

running_index_for_pid() {
  local pid=$1
  local i
  for i in "${!running_pids[@]}"; do
    if [[ ${running_pids[$i]} == "$pid" ]]; then
      echo "$i"
      return 0
    fi
  done
  echo "unknown completed test pid: $pid" >&2
  exit 2
}

wait_one() {
  local completed_pid
  local status=0
  wait -n -p completed_pid "${running_pids[@]}" || status=$?

  local index
  index=$(running_index_for_pid "$completed_pid")
  local name=${running_names[$index]}
  local duration summary
  duration=$(cat "$log_dir/$name.duration" 2>/dev/null || echo 0)
  summary=$(cat "$log_dir/$name.summary" 2>/dev/null || true)
  completed_names+=("$name")
  completed_durations+=("$duration")
  completed_summaries+=("$summary")
  if [[ $status -ne 0 ]]; then
    failed_names+=("$name")
  fi
  cat "$log_dir/$name.log"
  remove_running_at "$index"
}

wait_all() {
  while [[ ${#running_pids[@]} -gt 0 ]]; do
    wait_one
  done
}

prewarm_holbuild_cache

if [[ "$HOLBUILD_TEST_PREWARM_ONLY" == 1 || "$HOLBUILD_TEST_PREWARM_ONLY" == true ]]; then
  echo "prewarm-only mode complete"
  exit 0
fi

case_index=0
selected_count=0
for test_script in "$ROOT"/tests/cases/*/test.sh; do
  name=$(basename "$(dirname "$test_script")")
  if [[ $((case_index % HOLBUILD_TEST_SHARD_COUNT)) -ne "$HOLBUILD_TEST_SHARD_INDEX" ]]; then
    case_index=$((case_index + 1))
    continue
  fi
  selected_count=$((selected_count + 1))
  start_case "$test_script" "$name"
  if [[ ${#running_pids[@]} -ge "$HOLBUILD_TEST_JOBS" ]]; then
    wait_one
  fi
  case_index=$((case_index + 1))
done
echo "selected $selected_count test case(s) for shard $HOLBUILD_TEST_SHARD_INDEX/$HOLBUILD_TEST_SHARD_COUNT"
wait_all

print_timing_summary() {
  local suite_end_ms total_ms i
  suite_end_ms=$(now_ms)
  total_ms=$((suite_end_ms - suite_start_ms))
  echo "holbuild test timing summary (total ${total_ms} ms):"
  printf '%8s %4s %9s %5s %9s %7s %9s %9s %s %s\n' \
    wall_ms hb_n hb_ms tool_n tool_ms phase_n phase_ms max_tool top_phase test
  for i in "${!completed_summaries[@]}"; do
    printf '%s\n' "${completed_summaries[$i]}"
  done | awk '
    function value(key,    i, prefix) {
      prefix = key "="
      for (i = 1; i <= NF; i++) if (index($i, prefix) == 1) return substr($i, length(prefix) + 1)
      return 0
    }
    /^TIMING/ {
      printf "%8d %4d %9d %5d %9d %7d %9d %9d %s %s\n", \
        value("wall_ms"), value("holbuild_n"), value("holbuild_ms"), \
        value("tool_n"), value("tool_ms"), value("phase_n"), value("phase_ms"), \
        value("max_tool_ms"), value("top_phase"), value("name")
    }
  ' | sort -nr
}

print_timing_summary

if [[ ${#failed_names[@]} -gt 0 ]]; then
  echo "failed holbuild tests: ${failed_names[*]}" >&2
  exit 1
fi

echo "all holbuild tests passed"
