#!/usr/bin/env bash
# Live tmux check for bench-001.
#
# snapshot_cases turns one frozen pane into expected jumps. Each trigram is then
# typed into flash --ui on a fresh pane. The fixture file is never modified.
# --pattern reruns one trigram and skips the scrolled, owned, and crash checks.
#
# FLASH-SNAPSHOT-END is appended to the paste. Copy-mode starts only after that
# line is on the live screen, so a short sleep is not the completion signal.
# The pane is tall enough for the whole replay. history_size must stay 0, or the
# history-top slice would drop jumps and the suite would shrink.
set -euo pipefail

usage() {
  printf 'usage: tests/sh/snapshot-trigrams.sh path/to/flash_tmux [--limit N] [--pattern TEXT] [--keep] [--all]\n' >&2
}

bin=
limit=0
pattern_filter=
keep=0
all=0
while (($#)); do
  case $1 in
  --limit)
    limit=${2:?missing limit}
    shift 2
    ;;
  --pattern)
    pattern_filter=${2:?missing pattern}
    shift 2
    ;;
  --keep)
    keep=1
    shift
    ;;
  --all)
    all=1
    shift
    ;;
  --)
    shift
    break
    ;;
  -*)
    printf 'unknown option: %s\n' "$1" >&2
    usage
    exit 2
    ;;
  *)
    if [[ -z $bin ]]; then
      bin=$1
      shift
    else
      printf 'unexpected argument: %s\n' "$1" >&2
      usage
      exit 2
    fi
    ;;
  esac
done
[[ -n $bin ]] || {
  usage
  exit 2
}

fixture=tests/fixtures/snapshots/bench-001.txt
cases_bin=$(dirname -- "$bin")/snapshot_cases
tmux_bin=$(command -v tmux)
socket="flash-snapshot-test-$$"
session=flash-snapshot-test
tmp_dir=$(mktemp -d)
debug_root=${TMPDIR:-/tmp}/flash-snapshot-debug-$$
case_index=0
fail_count=0
tested=0
matched=0
pane=
ui_pane=
window=
pattern=
row=
col=
cursor=

cleanup() {
  local status=$?
  # --keep leaves the server so the failing pane can be attached.
  if ((keep)); then
    printf 'kept socket=%s session=%s\n' "$socket" "$session" >&2
  elif [[ -n ${tmux_bin:-} && -n ${socket:-} ]]; then
    "$tmux_bin" -L "$socket" kill-server 2>/dev/null || true
  fi
  rm -rf "$tmp_dir"
  exit "$status"
}
trap cleanup EXIT

# Dump survives cleanup. The private server does not, unless --keep.
dump_failure() {
  local why=$1
  local dir got_row delta
  mkdir -p "$debug_root"
  dir=$(mktemp -d "$debug_root/case.XXXXXX")
  {
    printf 'reason=%s\n' "$why"
    printf 'case_index=%s\n' "$case_index"
    printf 'pattern=%s\n' "$pattern"
    printf 'expected=%s,%s\n' "$col" "$row"
    printf 'got=%s\n' "$cursor"
    printf 'socket=%s\n' "$socket"
    printf 'session=%s\n' "$session"
    printf 'pane=%s\n' "$pane"
    printf 'ui_pane=%s\n' "$ui_pane"
  } >"$dir/context.txt"
  if [[ -n $pane ]]; then
    "$tmux_bin" -L "$socket" display-message -p -t "$pane" \
      'pane_width=#{pane_width}
pane_height=#{pane_height}
history_size=#{history_size}
copy_cursor_x=#{copy_cursor_x}
copy_cursor_y=#{copy_cursor_y}
scroll_position=#{scroll_position}' >"$dir/formats.txt" || true
  fi
  [[ -f $tmp_dir/capture.txt ]] && cp "$tmp_dir/capture.txt" "$dir/oracle-capture.txt"
  [[ -f $tmp_dir/live-capture.txt ]] && cp "$tmp_dir/live-capture.txt" "$dir/live-capture.txt"
  [[ -f $tmp_dir/live-inspect.txt ]] && cp "$tmp_dir/live-inspect.txt" "$dir/live-inspect.txt"
  [[ -f $tmp_dir/post-inspect.txt ]] && cp "$tmp_dir/post-inspect.txt" "$dir/post-inspect.txt"
  if [[ -n $ui_pane ]]; then
    "$tmux_bin" -L "$socket" capture-pane -p -e -t "$ui_pane" >"$dir/ui-pane.txt" || true
  fi
  if [[ $cursor == copy_cursor=*,* && $row =~ ^[0-9]+$ ]]; then
    got_row=${cursor#copy_cursor=}
    got_row=${got_row#*,}
    if [[ $got_row =~ ^[0-9]+$ ]]; then
      delta=$((got_row - row))
      printf 'delta=%s\n' "$delta" >"$dir/delta.txt"
      printf 'delta pattern=%s expected_row=%s got_row=%s delta=%s\n' "$pattern" "$row" "$got_row" "$delta" >&2
    fi
  fi
  printf 'debug: %s\n' "$dir" >&2
}

fail() {
  dump_failure "$1"
  printf '%s\n' "$1" >&2
  exit 1
}

[[ -x $cases_bin ]] || {
  printf 'missing %s; build first\n' "$cases_bin" >&2
  exit 1
}
[[ -f $fixture ]] || {
  printf 'missing fixture: %s\n' "$fixture" >&2
  exit 1
}

wait_size() {
  local target=$1
  local attempt
  for attempt in {1..100}; do
    if [[ $("$tmux_bin" -L "$socket" display-message -p -t "$target" '#{pane_width},#{pane_height}') == "$width,$height" ]]; then
      return 0
    fi
    sleep 0.02
  done
  return 1
}

# Last line of the replay. Visible on the live screen means cat has received the paste.
# It is not part of the history-top slice --inspect compares.
sentinel=FLASH-SNAPSHOT-END

wait_sentinel() {
  local target=$1
  local attempt
  for attempt in {1..200}; do
    if "$tmux_bin" -L "$socket" capture-pane -p -t "$target" | grep -F -q -- "$sentinel"; then
      return 0
    fi
    sleep 0.02
  done
  fail "paste did not land: missing $sentinel"
}

# Paste into cat prints twice: the tty echoes the input, then cat writes it. Feed the file instead.
replay_cmd() {
  local times=${1:-1}
  local n files
  files=$(printf '%q' "$tmp_dir/replay.txt")
  for ((n = 1; n < times; n++)); do
    files+=" $(printf '%q' "$tmp_dir/replay.txt")"
  done
  printf 'cat %s; exec cat' "$files"
}

settle_replay() {
  wait_size "$pane" || fail "pane did not reach ${width}x${height}"
  wait_sentinel "$pane"
}

new_replay_pane() {
  local times=${1:-1}
  pane=$("$tmux_bin" -L "$socket" new-window -d -P -F '#{pane_id}' -t "$session" /bin/sh -c "$(replay_cmd "$times")")
  window=$("$tmux_bin" -L "$socket" display-message -p -t "$pane" '#{session_name}:#{window_index}')
  ui_pane=
  settle_replay
}

# history-top makes copy_cursor_y match a row in the captured grid.
freeze_at_top() {
  "$tmux_bin" -L "$socket" copy-mode -t "$pane"
  "$tmux_bin" -L "$socket" send-keys -t "$pane" -X history-top
}

# A scrolled pane means --inspect will not see the whole replay.
assert_full_view() {
  local size
  size=$("$tmux_bin" -L "$socket" display-message -p -t "$pane" '#{history_size}')
  [[ $size == 0 ]] || fail "paste scrolled: history_size=$size pane=${width}x${height}"
}

capture_body() {
  local inspect_out=$1
  local dest=$2
  printf '%s' "$inspect_out" | perl -0pe 's/\A.*?--- capture ---\n//s' >"$dest"
}

wait_marker() {
  local target=$1 want=$2
  local attempt marker
  for attempt in {1..100}; do
    marker=$("$tmux_bin" -L "$socket" display-message -p -t "$target" '#{@flash-overlay}')
    if [[ $want == set && -n $marker ]]; then return 0; fi
    if [[ $want == clear && -z $marker ]]; then return 0; fi
    sleep 0.02
  done
  return 1
}

start_ui() {
  ui_pane=$("$tmux_bin" -L "$socket" new-window -d -P -F '#{pane_id}' -t "$session" /bin/sh -c "exec '$bin' --ui --pane='$1'")
}

# Fail before flash starts when this pane is not the pane the answer key came from.
assert_replay() {
  local live
  live=$(TMUX="$socket_path,0,0" "$bin" --inspect --pane="$pane")
  printf '%s' "$live" >"$tmp_dir/live-inspect.txt"
  capture_body "$live" "$tmp_dir/live-capture.txt"
  cmp -s "$tmp_dir/capture.txt" "$tmp_dir/live-capture.txt" || fail "replay mismatch: pattern=$pattern"
}

capture_cursor() {
  local inspect_out
  inspect_out=$(TMUX="$socket_path,0,0" "$bin" --inspect --pane="$pane")
  printf '%s' "$inspect_out" >"$tmp_dir/post-inspect.txt"
  cursor=$(grep '^copy_cursor=' <<<"$inspect_out" || true)
}

type_chars() {
  local text=$1
  local i
  for ((i = 0; i < ${#text}; i++)); do
    "$tmux_bin" -L "$socket" send-keys -t "$ui_pane" -l "${text:i:1}"
  done
  "$tmux_bin" -L "$socket" send-keys -t "$ui_pane" Enter
}

# --- oracle pane -----------------------------------------------------------
# One private server. cat receives the paste so the pane shows fixture text only.
# tmux paste quotes raw escapes before cat sees them, so strip those first.
perl -CSD -pe 's/\e\][^\a]*(?:\a|\e\\)//g; s/\e\[[0-?]*[ -\/]*[@-~]//g; s/[\x{2580}-\x{259F}]/ /g' "$fixture" >"$tmp_dir/replay.txt"
"$cases_bin" "$tmp_dir/replay.txt" >"$tmp_dir/required.tsv"
[[ -s $tmp_dir/required.tsv ]] || fail "no replay cases"
IFS=$'\t' read -r width _ < <("$cases_bin" "$tmp_dir/replay.txt" --dimensions)
printf '%s\n' "$sentinel" >>"$tmp_dir/replay.txt"
# A line that fills the last column makes tmux wrap it. One extra column avoids that.
# One extra row keeps the trailing newline from scrolling the first line away.
width=$((width + 1))
height=$(($(grep -c '' "$tmp_dir/replay.txt") + 1))
"$tmux_bin" -L "$socket" -f /dev/null new-session -d -x "$width" -y "$height" -s "$session" /bin/sh -c "$(replay_cmd)"
pane=$("$tmux_bin" -L "$socket" display-message -p -t "$session:0.0" '#{pane_id}')
socket_path=$("$tmux_bin" -L "$socket" display-message -p '#{socket_path}')
settle_replay
freeze_at_top
assert_full_view
initial=$(TMUX="$socket_path,0,0" "$bin" --inspect --pane="$pane")
[[ $(grep '^copy_cursor=' <<<"$initial") == copy_cursor=0,0 ]] || fail "expected top cursor, got $(grep '^copy_cursor=' <<<"$initial")"
capture_body "$initial" "$tmp_dir/capture.txt"
"$cases_bin" "$tmp_dir/capture.txt" >"$tmp_dir/cases.tsv"
cut -f1 "$tmp_dir/required.tsv" | sort >"$tmp_dir/required-patterns.txt"
cut -f1 "$tmp_dir/cases.tsv" | sort >"$tmp_dir/live-patterns.txt"
cmp -s "$tmp_dir/required-patterns.txt" "$tmp_dir/live-patterns.txt" || fail "live cases are not the full replay set"

# --- trigrams --------------------------------------------------------------
# Each case gets a new pane. The answer key stays the oracle capture above.
while IFS=$'\t' read -r pattern row col; do
  case_index=$((case_index + 1))
  if [[ -n $pattern_filter && $pattern != "$pattern_filter" ]]; then
    continue
  fi
  matched=$((matched + 1))
  if ((limit > 0 && matched > limit)); then
    break
  fi
  cursor=
  new_replay_pane
  freeze_at_top
  assert_full_view
  scroll_before=$("$tmux_bin" -L "$socket" display-message -p -t "$pane" '#{scroll_position}')
  [[ $("$tmux_bin" -L "$socket" display-message -p -t "$pane" '#{copy_cursor_x},#{copy_cursor_y}') == 0,0 ]] || fail "pattern=$pattern did not start at 0,0"
  assert_replay

  start_ui "$pane"
  wait_marker "$pane" set || fail "overlay did not open: pattern=$pattern"
  sleep 0.5
  type_chars "$pattern"
  wait_marker "$pane" clear || fail "overlay did not close: pattern=$pattern"

  capture_cursor
  if [[ $cursor != "copy_cursor=$col,$row" ]]; then
    dump_failure "cursor mismatch: pattern=$pattern expected=$col,$row got=${cursor#copy_cursor=}"
    printf 'FAIL pattern=%s expected=%s,%s got=%s\n' "$pattern" "$col" "$row" "${cursor#copy_cursor=}" >&2
    fail_count=$((fail_count + 1))
    if ((all)); then
      "$tmux_bin" -L "$socket" kill-window -t "$window" || true
      continue
    fi
    exit 1
  fi
  [[ $("$tmux_bin" -L "$socket" display-message -p -t "$pane" '#{scroll_position}') == "$scroll_before" ]] || fail "scroll changed: pattern=$pattern"
  [[ -z $("$tmux_bin" -L "$socket" display-message -p -t "$pane" '#{@flash-overlay}') ]] || fail "overlay marker leaked: pattern=$pattern"

  # Ctrl-C must close a second open without leaving the marker behind.
  start_ui "$pane"
  wait_marker "$pane" set || fail "overlay did not retrigger: pattern=$pattern"
  sleep 0.5
  "$tmux_bin" -L "$socket" send-keys -t "$ui_pane" C-c
  wait_marker "$pane" clear || fail "retrigger overlay did not close: pattern=$pattern"
  "$tmux_bin" -L "$socket" kill-window -t "$window"
  tested=$((tested + 1))
done <"$tmp_dir/cases.tsv"

if [[ -n $pattern_filter && matched -eq 0 ]]; then
  fail "no case matched pattern=$pattern_filter"
fi
if ((fail_count)); then
  printf 'failed %s trigram cursor checks\n' "$fail_count" >&2
  exit 1
fi

if [[ -z $pattern_filter ]]; then
  # Scrolled view: two copies, then page-down, then jump without moving scroll.
  new_replay_pane 2
  freeze_at_top
  "$tmux_bin" -L "$socket" send-keys -t "$pane" -X page-down
  scroll_before=$("$tmux_bin" -L "$socket" display-message -p -t "$pane" '#{scroll_position}')
  ((scroll_before > 0)) || fail "failed to establish a scrolled view"
  scrolled=$(TMUX="$socket_path,0,0" "$bin" --inspect --pane="$pane")
  capture_body "$scrolled" "$tmp_dir/scrolled-capture.txt"
  "$cases_bin" "$tmp_dir/scrolled-capture.txt" >"$tmp_dir/scrolled-cases.tsv"
  IFS=$'\t' read -r pattern row col <"$tmp_dir/scrolled-cases.tsv"
  [[ -n ${pattern:-} ]] || fail "no scrolled jump case"
  cp "$tmp_dir/scrolled-capture.txt" "$tmp_dir/capture.txt"
  assert_replay
  start_ui "$pane"
  wait_marker "$pane" set || fail "scrolled overlay did not open"
  sleep 0.5
  type_chars "$pattern"
  wait_marker "$pane" clear || fail "scrolled overlay did not close"
  capture_cursor
  [[ $cursor == "copy_cursor=$col,$row" ]] || fail "scrolled cursor mismatch: expected=$col,$row got=${cursor#copy_cursor=}"
  [[ $("$tmux_bin" -L "$socket" display-message -p -t "$pane" '#{scroll_position}') == "$scroll_before" ]] || fail "scrolled view changed"
  "$tmux_bin" -L "$socket" kill-window -t "$window"

  # Owned overlay: source was not already in copy mode. Ctrl-C must leave it that way.
  new_replay_pane
  pattern=
  row=
  col=
  cursor=
  start_ui "$pane"
  wait_marker "$pane" set || fail "owned overlay did not open"
  sleep 0.1
  "$tmux_bin" -L "$socket" send-keys -t "$ui_pane" C-c
  wait_marker "$pane" clear || fail "owned overlay did not close"
  [[ $("$tmux_bin" -L "$socket" display-message -p -t "$pane" '#{pane_in_mode}') == 0 ]] || fail "owned source leaked copy mode"
  "$tmux_bin" -L "$socket" kill-window -t "$window"

  # Kill the overlay process. A later launch must clear copy mode and the marker.
  new_replay_pane
  start_ui "$pane"
  wait_marker "$pane" set || fail "crash-recovery overlay did not open"
  overlay_pid=$("$tmux_bin" -L "$socket" display-message -p -t "$ui_pane" '#{pane_pid}')
  kill -TERM "$overlay_pid" 2>/dev/null || true
  kill -KILL "$overlay_pid" 2>/dev/null || true
  ui_dead=0
  for attempt in {1..100}; do
    if ! kill -0 "$overlay_pid" 2>/dev/null; then
      ui_dead=1
      break
    fi
    sleep 0.02
  done
  ((ui_dead == 1)) || fail "overlay process did not die"
  TMUX="$socket_path,0,0" "$bin" --pane="$pane" || true
  [[ $("$tmux_bin" -L "$socket" display-message -p -t "$pane" '#{pane_in_mode}') == 0 ]] || fail "crash recovery leaked owned copy mode"
  [[ -z $("$tmux_bin" -L "$socket" display-message -p -t "$pane" '#{@flash-overlay}') ]] || fail "crash recovery leaked overlay marker"
  "$tmux_bin" -L "$socket" kill-window -t "$window"
fi

printf 'ok bench-001 ASCII trigrams: %s cases\n' "$tested"
