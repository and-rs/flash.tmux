#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

root=$(cd "$(dirname -- "$0")/../.." && pwd)
cd "$root"

n=20
current_bin=$root/zig-out/bin/flash_tmux
labels=()
bins=()
while (($#)); do
  case $1 in
    --n)
      n=${2:?missing n}
      shift 2
      ;;
    --)
      shift
      break
      ;;
    -*)
      printf 'unknown option: %s\n' "$1" >&2
      exit 2
      ;;
    *)
      break
      ;;
  esac
done

if (($# == 1)); then
  current_bin=$1
  shift
fi

worktree=
cleanup() {
  if [[ -n ${tmux_bin:-} && -n ${socket:-} ]]; then
    "$tmux_bin" -L "$socket" kill-server 2>/dev/null || true
  fi
  if [[ -n $worktree ]]; then
    git worktree remove --force "$worktree" 2>/dev/null || rm -rf "$worktree"
  fi
  if [[ -n ${tmp_dir:-} ]]; then
    rm -rf "$tmp_dir"
  fi
}
trap cleanup EXIT

if (($#)); then
  (($# % 2 == 0)) || {
    printf 'usage: tests/sh/bench-overlay.sh [--n N] [bin] | [protocol bin]...\n' >&2
    exit 2
  }
  while (($#)); do
    labels+=("$1")
    bins+=("$2")
    shift 2
  done
else
  [[ -x $current_bin ]] || {
    printf 'missing %s; build first\n' "$current_bin" >&2
    exit 1
  }
  worktree=/tmp/flash.tmux-bench-head-$$
  git worktree add --detach "$worktree" HEAD >/dev/null
  (cd "$worktree" && zig build -Doptimize=ReleaseFast)
  labels=(replica popup)
  bins=("$worktree/zig-out/bin/flash_tmux" "$current_bin")
fi

for bin in "${bins[@]}"; do
  [[ -x $bin ]] || {
    printf 'missing binary: %s\n' "$bin" >&2
    exit 1
  }
done

cases_bin=$root/zig-out/bin/snapshot_cases
fixture=tests/fixtures/snapshots/bench-001.txt
tmux_bin=$(command -v tmux)
socket=flash-bench-$$
session=flash-bench
tmp_dir=$(mktemp -d)
samples=$tmp_dir/samples.tsv

[[ -x $cases_bin ]] || {
  printf 'missing %s; build snapshot-cases first\n' "$cases_bin" >&2
  exit 1
}
[[ -f $fixture ]] || {
  printf 'missing fixture: %s\n' "$fixture" >&2
  exit 1
}

IFS=$'\t' read -r width height < <("$cases_bin" "$fixture" --dimensions)
"$tmux_bin" -L "$socket" -f /dev/null new-session -d -x "$width" -y "$height" -s "$session" /bin/sh -c 'exec cat'
pane=$("$tmux_bin" -L "$socket" display-message -p -t "$session:0.0" '#{pane_id}')
window=$("$tmux_bin" -L "$socket" display-message -p -t "$pane" '#{session_name}:#{window_index}')
socket_path=$("$tmux_bin" -L "$socket" display-message -p '#{socket_path}')
perl -CSD -pe 's/\e\][^\a]*(?:\a|\e\\)//g; s/\e\[[0-?]*[ -\/]*[@-~]//g; s/[\x{2580}-\x{259F}]/ /g' "$fixture" >"$tmp_dir/replay.txt"
"$tmux_bin" -L "$socket" load-buffer -b flash-snapshot "$tmp_dir/replay.txt"
"$tmux_bin" -L "$socket" paste-buffer -b flash-snapshot -t "$pane"
sleep 0.5
for _ in {1..100}; do
  if [[ $("$tmux_bin" -L "$socket" display-message -p -t "$pane" '#{pane_height}') == "$height" ]]; then
    break
  fi
  sleep 0.02
done
[[ $("$tmux_bin" -L "$socket" display-message -p -t "$pane" '#{pane_width}') == "$width" ]]
[[ $("$tmux_bin" -L "$socket" display-message -p -t "$pane" '#{pane_height}') == "$height" ]]

inspect_bin=${bins[-1]}
capture_text() {
  TMUX="$socket_path,0,0" "$inspect_bin" --inspect --pane="$pane" |
    perl -0pe 's/\A.*?--- capture ---\n//s'
}
first_case() {
  local out=$1
  "$cases_bin" "$2" >"$tmp_dir/cases.tsv"
  IFS=$'\t' read -r "$3" "$4" "$5" <"$tmp_dir/cases.tsv" || true
  [[ -n ${!3:-} ]] || {
    printf 'no jump case for %s\n' "$out" >&2
    exit 1
  }
}

capture_text >"$tmp_dir/prefix-capture.txt"
first_case prefix "$tmp_dir/prefix-capture.txt" prefix_pattern prefix_row prefix_col
"$tmux_bin" -L "$socket" copy-mode -t "$pane"
"$tmux_bin" -L "$socket" send-keys -t "$pane" -X history-top
capture_text >"$tmp_dir/copy-capture.txt"
first_case copy-mode "$tmp_dir/copy-capture.txt" copy_pattern copy_row copy_col
"$tmux_bin" -L "$socket" copy-mode -q -t "$pane" || true

keys_target=
poll=0.01
settle=0.08
tries=200

wait_marker() {
  local target=$1 want=$2
  local i marker
  for ((i = 0; i < tries; i++)); do
    marker=$("$tmux_bin" -L "$socket" display-message -p -t "$target" '#{@flash-overlay}')
    if [[ $want == set && -n $marker ]]; then return 0; fi
    if [[ $want == clear && -z $marker ]]; then return 0; fi
    sleep "$poll"
  done
  return 1
}

start_overlay() {
  local proto=$1 bin=$2
  case $proto in
    replica)
      TMUX="$socket_path,0,0" "$bin" --pane="$pane"
      keys_target=
      ;;
    popup)
      keys_target=$("$tmux_bin" -L "$socket" new-window -d -P -F '#{pane_id}' -t "$session" /bin/sh -c "exec '$bin' --ui --pane='$pane'")
      ;;
    *)
      printf 'unknown protocol: %s\n' "$proto" >&2
      exit 2
      ;;
  esac
}

wait_ready() {
  local proto=$1
  local i overlay_pane sess
  case $proto in
    replica)
      sess=flash-overlay-${pane#%}
      for ((i = 0; i < tries; i++)); do
        overlay_pane=$("$tmux_bin" -L "$socket" display-message -p -t "$window" '#{pane_id}')
        if [[ $overlay_pane != "$pane" ]]; then
          keys_target=$overlay_pane
          return 0
        fi
        sleep "$poll"
      done
      return 1
      ;;
    popup)
      wait_marker "$pane" set
      ;;
  esac
}

wait_closed() {
  local proto=$1
  local i sess
  case $proto in
    replica)
      sess=flash-overlay-${pane#%}
      for ((i = 0; i < tries; i++)); do
        if ! "$tmux_bin" -L "$socket" has-session -t "$sess" 2>/dev/null; then
          return 0
        fi
        sleep "$poll"
      done
      return 1
      ;;
    popup)
      wait_marker "$pane" clear
      ;;
  esac
}

prepare_mode() {
  local mode=$1
  case $mode in
    prefix)
      if [[ $("$tmux_bin" -L "$socket" display-message -p -t "$pane" '#{pane_in_mode}') == 1 ]]; then
        "$tmux_bin" -L "$socket" copy-mode -q -t "$pane"
      fi
      ;;
    copy-mode)
      "$tmux_bin" -L "$socket" copy-mode -t "$pane"
      "$tmux_bin" -L "$socket" send-keys -t "$pane" -X history-top
      ;;
    *)
      printf 'unknown mode: %s\n' "$mode" >&2
      exit 2
      ;;
  esac
}

send_abort() {
  "$tmux_bin" -L "$socket" send-keys -t "$keys_target" C-c
}

case_for() {
  case $1 in
    prefix)
      pattern=$prefix_pattern
      row=$prefix_row
      col=$prefix_col
      ;;
    copy-mode)
      pattern=$copy_pattern
      row=$copy_row
      col=$copy_col
      ;;
  esac
}

send_jump() {
  local i
  for ((i = 0; i < ${#pattern}; i++)); do
    "$tmux_bin" -L "$socket" send-keys -t "$keys_target" -l "${pattern:i:1}"
  done
  "$tmux_bin" -L "$socket" send-keys -t "$keys_target" Enter
}

now() {
  printf '%s' "$EPOCHREALTIME"
}

delta() {
  awk -v t0="$1" -v t1="$2" 'BEGIN { printf "%.6f\n", t1 - t0 }'
}

close_overlay() {
  local proto=$1
  send_abort
  wait_closed "$proto" || {
    printf 'overlay did not close during cleanup\n' >&2
    exit 1
  }
}

run_timed() {
  local metric=$1 proto=$2 bin=$3 mode=$4
  prepare_mode "$mode"
  local t0 t1 t2
  t0=$(now)
  start_overlay "$proto" "$bin"
  wait_ready "$proto" || {
    printf 'overlay did not open: metric=%s proto=%s mode=%s\n' "$metric" "$proto" "$mode" >&2
    exit 1
  }
  t1=$(now)
  case $metric in
    open-to-ready)
      printf '%s\t%s\t%s\t%s\n' "$metric" "$mode" "$proto" "$(delta "$t0" "$t1")" >>"$samples"
      sleep "$settle"
      close_overlay "$proto"
      ;;
    open-abort)
      sleep "$settle"
      send_abort
      wait_closed "$proto" || {
        printf 'overlay did not close: metric=%s proto=%s mode=%s\n' "$metric" "$proto" "$mode" >&2
        exit 1
      }
      t2=$(now)
      printf '%s\t%s\t%s\t%s\n' "$metric" "$mode" "$proto" "$(delta "$t0" "$t2")" >>"$samples"
      ;;
    open-jump)
      case_for "$mode"
      sleep "$settle"
      send_jump
      wait_closed "$proto" || {
        printf 'overlay did not close: metric=%s proto=%s mode=%s\n' "$metric" "$proto" "$mode" >&2
        exit 1
      }
      t2=$(now)
      local cursor
      cursor=$(TMUX="$socket_path,0,0" "$bin" --inspect --pane="$pane" | grep '^copy_cursor=')
      if [[ $cursor != "copy_cursor=$col,$row" ]]; then
        printf 'cursor mismatch: expected=%s,%s got=%s proto=%s mode=%s\n' "$col" "$row" "${cursor#copy_cursor=}" "$proto" "$mode" >&2
        exit 1
      fi
      printf '%s\t%s\t%s\t%s\n' "$metric" "$mode" "$proto" "$(delta "$t0" "$t2")" >>"$samples"
      ;;
    *)
      printf 'unknown metric: %s\n' "$metric" >&2
      exit 2
      ;;
  esac
}

warmup=2
idx=0
for proto in "${labels[@]}"; do
  bin=${bins[idx]}
  idx=$((idx + 1))
  for mode in prefix copy-mode; do
    for ((i = 0; i < warmup; i++)); do
      prepare_mode "$mode"
      start_overlay "$proto" "$bin"
      wait_ready "$proto" || {
        printf 'warmup open failed: proto=%s mode=%s\n' "$proto" "$mode" >&2
        exit 1
      }
      sleep "$settle"
      close_overlay "$proto"
    done
    for metric in open-to-ready open-abort open-jump; do
      for ((i = 0; i < n; i++)); do
        run_timed "$metric" "$proto" "$bin" "$mode"
      done
    done
  done
done

awk -F '\t' -v impls="${labels[*]}" '
function sort_num(a, n,    i, j, tmp) {
  for (i = 1; i <= n; i++) {
    for (j = i + 1; j <= n; j++) {
      if (a[j] < a[i]) {
        tmp = a[i]
        a[i] = a[j]
        a[j] = tmp
      }
    }
  }
}
{
  key = $1 "\t" $2 "\t" $3
  c[key]++
  v[key, c[key]] = $4 + 0
}
END {
  split("open-to-ready open-abort open-jump", metrics, " ")
  split("prefix copy-mode", modes, " ")
  nimpl = split(impls, impl_order, " ")
  printf "{"
  printf "\"impls\":["
  for (ii = 1; ii <= nimpl; ii++) {
    if (ii > 1) printf ","
    printf "\"%s\"", impl_order[ii]
  }
  printf "],\"results\":["
  first = 1
  for (mi = 1; mi <= 3; mi++) {
    m = metrics[mi]
    for (di = 1; di <= 2; di++) {
      d = modes[di]
      for (ii = 1; ii <= nimpl; ii++) {
        p = impl_order[ii]
        key = m "\t" d "\t" p
        n = c[key] + 0
        if (n == 0) continue
        for (i = 1; i <= n; i++) a[i] = v[key, i]
        sort_num(a, n)
        sum = 0
        for (i = 1; i <= n; i++) sum += a[i]
        mean = sum / n
        if (n % 2) med = a[int(n / 2) + 1]
        else med = (a[n / 2] + a[n / 2 + 1]) / 2
        mean_ms[key] = mean * 1000
        if (!first) printf ","
        first = 0
        printf "{\"metric\":\"%s\",\"mode\":\"%s\",\"impl\":\"%s\",\"n\":%d,\"min_ms\":%.1f,\"med_ms\":%.1f,\"mean_ms\":%.1f,\"max_ms\":%.1f,\"samples_ms\":[", m, d, p, n, a[1] * 1000, med * 1000, mean * 1000, a[n] * 1000
        for (i = 1; i <= n; i++) {
          if (i > 1) printf ","
          printf "%.1f", a[i] * 1000
        }
        printf "]}"
      }
    }
  }
  printf "],\"speedup\":["
  first = 1
  if (nimpl >= 2) {
    base = impl_order[1]
    cont = impl_order[2]
    for (mi = 1; mi <= 3; mi++) {
      m = metrics[mi]
      for (di = 1; di <= 2; di++) {
        d = modes[di]
        k0 = m "\t" d "\t" base
        k1 = m "\t" d "\t" cont
        if (!(k0 in mean_ms) || !(k1 in mean_ms) || mean_ms[k1] == 0) continue
        if (!first) printf ","
        first = 0
        printf "{\"metric\":\"%s\",\"mode\":\"%s\",\"baseline\":\"%s\",\"contender\":\"%s\",\"ratio\":%.4f}", m, d, base, cont, mean_ms[k0] / mean_ms[k1]
      }
    }
  }
  printf "]}\n"
}
' "$samples"
