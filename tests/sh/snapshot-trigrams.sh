#!/usr/bin/env bash
set -euo pipefail

bin=${1:?usage: tests/sh/snapshot-trigrams.sh path/to/flash_tmux [--limit N]}
shift
limit=0
if [[ ${1:-} == --limit ]]; then
  limit=${2:?missing limit}
  shift 2
fi
(($# == 0)) || {
  printf 'unexpected argument: %s\n' "$1" >&2
  exit 2
}

fixture=tests/fixtures/snapshots/bench-001.txt
cases_bin=$(dirname -- "$bin")/snapshot_cases
tmux_bin=$(command -v tmux)
socket="flash-snapshot-test-$$"
session=flash-snapshot-test
tmp_dir=$(mktemp -d)
trap '"$tmux_bin" -L "$socket" kill-server 2>/dev/null || true; rm -rf "$tmp_dir"' EXIT

[[ -x $cases_bin ]] || {
  printf 'missing %s; build first\n' "$cases_bin" >&2
  exit 1
}
[[ -f $fixture ]] || {
  printf 'missing fixture: %s\n' "$fixture" >&2
  exit 1
}

IFS=$'\t' read -r width height < <("$cases_bin" "$fixture" --dimensions)
"$tmux_bin" -L "$socket" -f /dev/null new-session -d -x "$width" -y "$height" -s "$session" /bin/sh -c 'exec cat'
pane=$("$tmux_bin" -L "$socket" display-message -p -t "$session:0.0" '#{pane_id}')
socket_path=$("$tmux_bin" -L "$socket" display-message -p '#{socket_path}')
# Replay the searchable text; tmux paste quotes raw escape bytes before cat sees them.
perl -CSD -pe 's/\e\][^\a]*(?:\a|\e\\)//g; s/\e\[[0-?]*[ -\/]*[@-~]//g; s/[\x{2580}-\x{259F}]/ /g' "$fixture" > "$tmp_dir/replay.txt"
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

"$tmux_bin" -L "$socket" copy-mode -t "$pane"
"$tmux_bin" -L "$socket" send-keys -t "$pane" -X history-top
initial=$(TMUX="$socket_path,0,0" "$bin" --inspect --pane="$pane")
[[ $(grep '^copy_cursor=' <<<"$initial") == copy_cursor=0,0 ]] || {
  printf 'expected top cursor, got %s\n' "$(grep '^copy_cursor=' <<<"$initial")" >&2
  exit 1
}
printf '%s' "$initial" |
  perl -0pe 's/\A.*?--- capture ---\n//s' > "$tmp_dir/capture.txt"
"$cases_bin" "$tmp_dir/capture.txt" > "$tmp_dir/cases.tsv"

wait_marker() {
  local target=$1 want=$2
  for _ in {1..100}; do
    marker=$("$tmux_bin" -L "$socket" display-message -p -t "$target" '#{@flash-overlay}')
    if [[ $want == set && -n $marker ]]; then return 0; fi
    if [[ $want == clear && -z $marker ]]; then return 0; fi
    sleep 0.02
  done
  return 1
}

start_ui() {
  local source=$1
  "$tmux_bin" -L "$socket" new-window -d -P -F '#{pane_id}' -t "$session" /bin/sh -c "exec '$bin' --ui --pane='$source'"
}

tested=0
while IFS=$'\t' read -r pattern row col; do
  if ((limit > 0 && tested >= limit)); then
    break
  fi
  pane=$("$tmux_bin" -L "$socket" new-window -d -P -F '#{pane_id}' -t "$session" /bin/sh -c 'exec cat')
  window=$("$tmux_bin" -L "$socket" display-message -p -t "$pane" '#{session_name}:#{window_index}')
  "$tmux_bin" -L "$socket" paste-buffer -b flash-snapshot -t "$pane"
  sleep 0.5
  "$tmux_bin" -L "$socket" copy-mode -t "$pane"
  "$tmux_bin" -L "$socket" send-keys -t "$pane" -X history-top
  scroll_before=$("$tmux_bin" -L "$socket" display-message -p -t "$pane" '#{scroll_position}')
  [[ $("$tmux_bin" -L "$socket" display-message -p -t "$pane" '#{copy_cursor_x},#{copy_cursor_y}') == 0,0 ]]
  ui_pane=$(start_ui "$pane")
  wait_marker "$pane" set || {
    printf 'overlay did not open: pattern=%s\n' "$pattern" >&2
    exit 1
  }
  sleep 0.5

  for ((i = 0; i < ${#pattern}; i++)); do
    "$tmux_bin" -L "$socket" send-keys -t "$ui_pane" -l "${pattern:i:1}"
  done
  "$tmux_bin" -L "$socket" send-keys -t "$ui_pane" Enter
  wait_marker "$pane" clear || {
    printf 'overlay did not close: pattern=%s\n' "$pattern" >&2
    exit 1
  }

  cursor=$(TMUX="$socket_path,0,0" "$bin" --inspect --pane="$pane" | grep '^copy_cursor=')
  if [[ $cursor != "copy_cursor=$col,$row" ]]; then
    printf 'FAIL pattern=%s expected=%s,%s got=%s\n' "$pattern" "$col" "$row" "${cursor#copy_cursor=}" >&2
    exit 1
  fi
  [[ $("$tmux_bin" -L "$socket" display-message -p -t "$pane" '#{scroll_position}') == "$scroll_before" ]] || {
    printf 'scroll changed: pattern=%s\n' "$pattern" >&2
    exit 1
  }
  [[ -z $("$tmux_bin" -L "$socket" display-message -p -t "$pane" '#{@flash-overlay}') ]] || {
    printf 'overlay marker leaked: pattern=%s\n' "$pattern" >&2
    exit 1
  }

  ui_pane=$(start_ui "$pane")
  wait_marker "$pane" set || {
    printf 'overlay did not retrigger: pattern=%s\n' "$pattern" >&2
    exit 1
  }
  sleep 0.5
  "$tmux_bin" -L "$socket" send-keys -t "$ui_pane" C-c
  wait_marker "$pane" clear || {
    printf 'retrigger overlay did not close: pattern=%s\n' "$pattern" >&2
    exit 1
  }
  "$tmux_bin" -L "$socket" kill-window -t "$window"
  ((tested += 1))
done < "$tmp_dir/cases.tsv"

pane=$("$tmux_bin" -L "$socket" new-window -d -P -F '#{pane_id}' -t "$session" /bin/sh -c 'exec cat')
window=$("$tmux_bin" -L "$socket" display-message -p -t "$pane" '#{session_name}:#{window_index}')
"$tmux_bin" -L "$socket" paste-buffer -b flash-snapshot -t "$pane"
"$tmux_bin" -L "$socket" paste-buffer -b flash-snapshot -t "$pane"
sleep 0.5
"$tmux_bin" -L "$socket" copy-mode -t "$pane"
"$tmux_bin" -L "$socket" send-keys -t "$pane" -X history-top
"$tmux_bin" -L "$socket" send-keys -t "$pane" -X page-down
scroll_before=$("$tmux_bin" -L "$socket" display-message -p -t "$pane" '#{scroll_position}')
((scroll_before > 0)) || { printf 'failed to establish a scrolled view\n' >&2; exit 1; }
scrolled=$(TMUX="$socket_path,0,0" "$bin" --inspect --pane="$pane")
printf '%s' "$scrolled" | perl -0pe 's/\A.*?--- capture ---\n//s' > "$tmp_dir/scrolled-capture.txt"
"$cases_bin" "$tmp_dir/scrolled-capture.txt" > "$tmp_dir/scrolled-cases.tsv"
IFS=$'\t' read -r pattern row col < "$tmp_dir/scrolled-cases.tsv"
[[ -n ${pattern:-} ]] || { printf 'no scrolled jump case\n' >&2; exit 1; }
ui_pane=$(start_ui "$pane")
wait_marker "$pane" set || { printf 'scrolled overlay did not open\n' >&2; exit 1; }
sleep 0.5
for ((i = 0; i < ${#pattern}; i++)); do
  "$tmux_bin" -L "$socket" send-keys -t "$ui_pane" -l "${pattern:i:1}"
done
"$tmux_bin" -L "$socket" send-keys -t "$ui_pane" Enter
wait_marker "$pane" clear || { printf 'scrolled overlay did not close\n' >&2; exit 1; }
cursor=$(TMUX="$socket_path,0,0" "$bin" --inspect --pane="$pane" | grep '^copy_cursor=')
[[ $cursor == "copy_cursor=$col,$row" ]] || {
  printf 'scrolled cursor mismatch: expected=%s,%s got=%s\n' "$col" "$row" "${cursor#copy_cursor=}" >&2; exit 1;
}
[[ $("$tmux_bin" -L "$socket" display-message -p -t "$pane" '#{scroll_position}') == "$scroll_before" ]] || {
  printf 'scrolled view changed\n' >&2; exit 1;
}
"$tmux_bin" -L "$socket" kill-window -t "$window"

pane=$("$tmux_bin" -L "$socket" new-window -d -P -F '#{pane_id}' -t "$session" /bin/sh -c 'exec cat')
window=$("$tmux_bin" -L "$socket" display-message -p -t "$pane" '#{session_name}:#{window_index}')
"$tmux_bin" -L "$socket" paste-buffer -b flash-snapshot -t "$pane"
ui_pane=$(start_ui "$pane")
wait_marker "$pane" set || { printf 'owned overlay did not open\n' >&2; exit 1; }
sleep 0.1
"$tmux_bin" -L "$socket" send-keys -t "$ui_pane" C-c
wait_marker "$pane" clear || { printf 'owned overlay did not close\n' >&2; exit 1; }
[[ $("$tmux_bin" -L "$socket" display-message -p -t "$pane" '#{pane_in_mode}') == 0 ]] || { printf 'owned source leaked copy mode\n' >&2; exit 1; }
"$tmux_bin" -L "$socket" kill-window -t "$window"

pane=$("$tmux_bin" -L "$socket" new-window -d -P -F '#{pane_id}' -t "$session" /bin/sh -c 'exec cat')
window=$("$tmux_bin" -L "$socket" display-message -p -t "$pane" '#{session_name}:#{window_index}')
"$tmux_bin" -L "$socket" paste-buffer -b flash-snapshot -t "$pane"
ui_pane=$(start_ui "$pane")
wait_marker "$pane" set || { printf 'crash-recovery overlay did not open\n' >&2; exit 1; }
overlay_pid=$("$tmux_bin" -L "$socket" display-message -p -t "$ui_pane" '#{pane_pid}')
kill -TERM "$overlay_pid" 2>/dev/null || true
kill -KILL "$overlay_pid" 2>/dev/null || true
ui_dead=0
for _ in {1..100}; do
  if ! kill -0 "$overlay_pid" 2>/dev/null; then
    ui_dead=1
    break
  fi
  sleep 0.02
done
((ui_dead == 1)) || { printf 'overlay process did not die\n' >&2; exit 1; }
TMUX="$socket_path,0,0" "$bin" --pane="$pane" || true
[[ $("$tmux_bin" -L "$socket" display-message -p -t "$pane" '#{pane_in_mode}') == 0 ]] || { printf 'crash recovery leaked owned copy mode\n' >&2; exit 1; }
[[ -z $("$tmux_bin" -L "$socket" display-message -p -t "$pane" '#{@flash-overlay}') ]] || { printf 'crash recovery leaked overlay marker\n' >&2; exit 1; }
"$tmux_bin" -L "$socket" kill-window -t "$window"

printf 'ok bench-001 ASCII trigrams: %s cases\n' "$tested"
