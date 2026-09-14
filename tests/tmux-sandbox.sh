#!/usr/bin/env bash
set -euo pipefail

interactive=false
if [[ ${1:-} == --interactive ]]; then
  interactive=true
  shift
fi
bin=${1:?usage: tests/tmux-sandbox.sh [--interactive] path/to/flash_tmux}
tmux_bin=$(command -v tmux)
socket="flash-tmux-test-$$"
session="flash-tmux-test"
trap '"$tmux_bin" -L "$socket" kill-server 2>/dev/null || true' EXIT

"$tmux_bin" -L "$socket" -f /dev/null new-session -d -x 80 -y 12 -s "$session" \
  /bin/sh -c 'i=1; while [ "$i" -le 120 ]; do printf "FLASH-MARKER-%03d\n" "$i"; i=$((i + 1)); done; (sleep 0.25; i=1; while :; do printf "FLASH-NOISE-%06d\n" "$i"; i=$((i + 1)); sleep 0.01; done) & exec cat'
pane=$("$tmux_bin" -L "$socket" display-message -p -t "$session:0.0" '#{pane_id}')
socket_path=$("$tmux_bin" -L "$socket" display-message -p '#{socket_path}')

for _ in {1..100}; do
  if "$tmux_bin" -L "$socket" capture-pane -p -t "$pane" | grep -q FLASH-MARKER-120; then
    break
  fi
  sleep 0.02
done
"$tmux_bin" -L "$socket" capture-pane -p -t "$pane" | grep -q FLASH-MARKER-120

probe() {
  local name=$1 marker=$2
  local out
  out=$(TMUX="$socket_path,0,0" "$bin" --inspect --pane="$pane")
  grep -qx 'in_mode=true' <<<"$out"
  grep -q "$marker" <<<"$out"
  printf 'ok %s: %s\n' "$name" "$marker"
}

assert_cursor_row() {
  local marker=$1 out
  out=$(TMUX="$socket_path,0,0" "$bin" --inspect --pane="$pane")
  grep -qx 'in_mode=true' <<<"$out"
  grep -qx 'copy_cursor=0,0' <<<"$out"
  grep -A 1 '^--- capture ---$' <<<"$out" | grep -q "^$marker"
}

"$tmux_bin" -L "$socket" copy-mode -t "$pane"
"$tmux_bin" -L "$socket" send-keys -t "$pane" -X history-top
probe top FLASH-MARKER-001

for _ in {1..100}; do
  assert_cursor_row FLASH-MARKER-001
done
printf 'ok copy-mode capture remains aligned during output\n'

"$tmux_bin" -L "$socket" send-keys -t "$pane" -X goto-line 60
probe middle FLASH-MARKER-060

"$tmux_bin" -L "$socket" send-keys -t "$pane" -X history-bottom
probe bottom FLASH-MARKER-120

"$tmux_bin" -L "$socket" send-keys -t "$pane" -X cancel
TMUX="$socket_path,0,0" "$bin" --pane="$pane"

for _ in {1..100}; do
  if [[ $("$tmux_bin" -L "$socket" display-message -p -t "$pane" '#{pane_in_mode}') == 1 ]]; then
    break
  fi
  sleep 0.02
done
[[ $("$tmux_bin" -L "$socket" display-message -p -t "$pane" '#{pane_in_mode}') == 1 ]]

frozen_before=$("$tmux_bin" -L "$socket" capture-pane -p -M -t "$pane")
sleep 0.1
frozen_after=$("$tmux_bin" -L "$socket" capture-pane -p -M -t "$pane")
[[ $frozen_before == "$frozen_after" ]]
printf 'ok normal invocation freezes source before capture\n'

overlay_pane=$("$tmux_bin" -L "$socket" display-message -p -t "$session:0.0" '#{pane_id}')
"$tmux_bin" -L "$socket" send-keys -t "$overlay_pane" C-c
for _ in {1..100}; do
  if ! "$tmux_bin" -L "$socket" has-session -t "flash-overlay-${pane#%}" 2>/dev/null; then
    break
  fi
  sleep 0.02
done
! "$tmux_bin" -L "$socket" has-session -t "flash-overlay-${pane#%}" 2>/dev/null
[[ $("$tmux_bin" -L "$socket" display-message -p -t "$pane" '#{pane_in_mode}') == 0 ]]
printf 'ok Esc restores live pane after normal invocation\n'

TMUX="$socket_path,0,0" "$bin" --pane="$pane"
for _ in {1..100}; do
  overlay_pane=$("$tmux_bin" -L "$socket" display-message -p -t "$session:0.0" '#{pane_id}')
  if [[ $overlay_pane != "$pane" ]]; then
    break
  fi
  sleep 0.02
done
[[ $overlay_pane != "$pane" ]]
overlay_pid=$("$tmux_bin" -L "$socket" display-message -p -t "$overlay_pane" '#{pane_pid}')
kill -TERM "$overlay_pid"
for _ in {1..100}; do
  if [[ $("$tmux_bin" -L "$socket" display-message -p -t "$overlay_pane" '#{pane_dead}') == 1 ]]; then
    break
  fi
  sleep 0.02
done
[[ $("$tmux_bin" -L "$socket" display-message -p -t "$overlay_pane" '#{pane_dead}') == 1 ]]
TMUX="$socket_path,0,0" "$bin" --pane="$overlay_pane"
[[ $("$tmux_bin" -L "$socket" display-message -p -t "$session:0.0" '#{pane_id}') == "$pane" ]]
! "$tmux_bin" -L "$socket" has-session -t "flash-overlay-${pane#%}" 2>/dev/null
printf 'ok dead overlay restores its source\n'

other=$("$tmux_bin" -L "$socket" split-window -d -P -F '#{pane_id}' -t "$pane" /bin/sh -c 'exec cat')
other_target=$("$tmux_bin" -L "$socket" display-message -p -t "$other" '#{session_name}:#{window_index}.#{pane_index}')

TMUX="$socket_path,0,0" "$bin" --pane="$pane"
for _ in {1..100}; do
  if [[ $("$tmux_bin" -L "$socket" display-message -p -t "$pane" '#{pane_in_mode}') == 1 ]]; then
    break
  fi
  sleep 0.02
done
[[ $("$tmux_bin" -L "$socket" display-message -p -t "$pane" '#{pane_in_mode}') == 1 ]]

overlay_pane=$("$tmux_bin" -L "$socket" display-message -p -t "$session:0.0" '#{pane_id}')
TMUX="$socket_path,0,0" "$bin" --pane="$overlay_pane"
TMUX="$socket_path,0,0" "$bin" --pane="$other"
for _ in {1..100}; do
  if [[ $("$tmux_bin" -L "$socket" display-message -p -t "$other" '#{pane_in_mode}') == 1 ]]; then
    break
  fi
  sleep 0.02
done
[[ $("$tmux_bin" -L "$socket" display-message -p -t "$other" '#{pane_in_mode}') == 1 ]]
"$tmux_bin" -L "$socket" has-session -t "flash-overlay-${pane#%}"
"$tmux_bin" -L "$socket" has-session -t "flash-overlay-${other#%}"
printf 'ok duplicate is ignored and panes run independently\n'

"$tmux_bin" -L "$socket" send-keys -t "$session:0.0" C-c
"$tmux_bin" -L "$socket" send-keys -t "$other_target" C-c
for _ in {1..100}; do
  if ! "$tmux_bin" -L "$socket" has-session -t "flash-overlay-${pane#%}" 2>/dev/null &&
    ! "$tmux_bin" -L "$socket" has-session -t "flash-overlay-${other#%}" 2>/dev/null; then
    break
  fi
  sleep 0.02
done
! "$tmux_bin" -L "$socket" has-session -t "flash-overlay-${pane#%}" 2>/dev/null
! "$tmux_bin" -L "$socket" has-session -t "flash-overlay-${other#%}" 2>/dev/null

if "$interactive"; then
  open_cmd="'$bin' --pane=#{pane_id}"
  "$tmux_bin" -L "$socket" set-option -g mode-keys vi
  "$tmux_bin" -L "$socket" bind-key f run-shell -b "$open_cmd"
  "$tmux_bin" -L "$socket" bind-key -T copy-mode-vi s run-shell -b "$open_cmd"
  "$tmux_bin" -L "$socket" send-keys -t "$pane" -X cancel
  printf 'sandbox: prefix-f at bottom; [ then scroll, then s. Detach with prefix-d.\n'
  "$tmux_bin" -L "$socket" attach-session -t "$session"
fi
