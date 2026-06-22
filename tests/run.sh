#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
HOLBUILD_BIN=${HOLBUILD_BIN:-"$ROOT/bin/holbuild"}
HOLBUILD_TEST_JOBS=${HOLBUILD_TEST_JOBS:-1}
export HOLBUILD_ROOT="$ROOT"
export HOLBUILD_TEST_GLOBAL_CACHE="${HOLBUILD_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/holbuild}"

pinned_hol_rev=$(tr -d '[:space:]' < "$ROOT/vendor/hol/REV")

write_toolchain_manifest() {
  local manifest=$1
  local hol_git=${HOLBUILD_CANONICAL_HOL_GIT:-https://github.com/HOL-Theorem-Prover/HOL.git}
  cat > "$manifest" <<TOML
[holbuild]
schema = 2

[dependencies.hol]
git = "$hol_git"
rev = "$pinned_hol_rev"

[project]
name = "holbuild-test-toolchain"
TOML
}

cached_schema2_holdir() {
  local tmp output status
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/holbuild-test-toolchain.XXXXXX")
  write_toolchain_manifest "$tmp/holproject.toml"
  set +e
  output=$(cd "$tmp" && "$HOLBUILD_BIN" buildhol 2>&1)
  status=$?
  set -e
  rm -rf "$tmp"
  if [[ $status -ne 0 ]]; then
    printf '%s\n' "$output" >&2
    return "$status"
  fi
  printf '%s\n' "$output" | tail -n 1
}

resolve_holdir() {
  local configured=${HOLDIR:-${HOLBUILD_HOLDIR:-}}
  if [[ -n "$configured" ]]; then
    printf '%s\n' "$configured"
    return 0
  fi
  echo "HOLDIR not set; resolving schema 2 HOL toolchain cache" >&2
  cached_schema2_holdir
}

HOLDIR=$(resolve_holdir)
holdir_rev=$(git -C "$HOLDIR" rev-parse HEAD)
if [[ "$holdir_rev" != "$pinned_hol_rev" ]]; then
  echo "HOLDIR rev $holdir_rev does not match vendor/hol/REV $pinned_hol_rev" >&2
  exit 2
fi

case "$HOLBUILD_TEST_JOBS" in
  ''|*[!0-9]*) echo "HOLBUILD_TEST_JOBS must be a positive integer" >&2; exit 2 ;;
esac
if [[ "$HOLBUILD_TEST_JOBS" -lt 1 ]]; then
  echo "HOLBUILD_TEST_JOBS must be a positive integer" >&2
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
fail_fast_triggered=0

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
echo "running holbuild tests with HOLBUILD_TEST_JOBS=$HOLBUILD_TEST_JOBS"

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
  echo "START $name"
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
  return "$status"
}

terminate_running() {
  local pid
  for pid in "${running_pids[@]}"; do
    kill -TERM "$pid" 2>/dev/null || true
  done
  sleep 1
  for pid in "${running_pids[@]}"; do
    kill -KILL "$pid" 2>/dev/null || true
  done
}

stop_after_failure() {
  if [[ $fail_fast_triggered -eq 0 ]]; then
    fail_fast_triggered=1
    echo "stopping after first failed test" >&2
    terminate_running
  fi
}

wait_all() {
  while [[ ${#running_pids[@]} -gt 0 ]]; do
    if ! wait_one; then
      stop_after_failure
    fi
  done
}

declare -a selected_test_scripts=()
declare -a selected_test_names=()

if [[ $# -gt 0 ]]; then
  for name in "$@"; do
    test_script="$ROOT/tests/cases/$name/test.sh"
    if [[ ! -f "$test_script" ]]; then
      echo "unknown test case: $name" >&2
      echo "available test cases:" >&2
      for case_dir in "$ROOT"/tests/cases/*; do
        [[ -f "$case_dir/test.sh" ]] && echo "  $(basename "$case_dir")" >&2
      done
      exit 2
    fi
    selected_test_scripts+=("$test_script")
    selected_test_names+=("$name")
  done
else
  for test_script in "$ROOT"/tests/cases/*/test.sh; do
    selected_test_scripts+=("$test_script")
    selected_test_names+=("$(basename "$(dirname "$test_script")")")
  done
fi

selected_count=0
for i in "${!selected_test_scripts[@]}"; do
  test_script=${selected_test_scripts[$i]}
  name=${selected_test_names[$i]}
  selected_count=$((selected_count + 1))
  start_case "$test_script" "$name"
  if [[ ${#running_pids[@]} -ge "$HOLBUILD_TEST_JOBS" ]]; then
    if ! wait_one; then
      stop_after_failure
      break
    fi
  fi
done
echo "started $selected_count test case(s)"
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
