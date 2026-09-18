#!/usr/bin/env bash
set -euo pipefail

interactive=false
if [[ ${1:-} == --interactive ]]; then
   interactive=true
   shift
fi
bin=${1:?usage: tests/sh/tmux-sandbox.sh [--interactive] path/to/flash_tmux}
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

assert_cursor_marker() {
   local marker=$1 target=${2:-$pane} out cursor row
   out=$(TMUX="$socket_path,0,0" "$bin" --inspect --pane="$target")
   grep -qx 'in_mode=true' <<<"$out"
   cursor=$(grep '^copy_cursor=' <<<"$out")
   row=${cursor#*,}
   mapfile -t capture < <(grep -A 12 '^--- capture ---$' <<<"$out")
   [[ ${capture[$((row + 1))]} == "$marker"* ]]
}

assert_cursor_column() {
    local col=$1 target=${2:-$pane} out cursor
    out=$(TMUX="$socket_path,0,0" "$bin" --inspect --pane="$target")
    cursor=$(grep '^copy_cursor=' <<<"$out")
    if [[ ! $cursor =~ ^copy_cursor=$col,[0-9]+$ ]]; then
      printf 'expected copy_cursor=%s,<row>, got %s\n' "$col" "$cursor" >&2
      return 1
    fi
}

assert_copy_cursor() {
    local col=$1 row=$2 target=${3:-$pane} out cursor
    out=$(TMUX="$socket_path,0,0" "$bin" --inspect --pane="$target")
    cursor=$(grep '^copy_cursor=' <<<"$out")
    if [[ $cursor != "copy_cursor=$col,$row" ]]; then
      printf 'expected copy_cursor=%s,%s, got %s\n' "$col" "$row" "$cursor" >&2
      return 1
    fi
}

assert_cursor_char() {
   local char=$1 target=${2:-$pane} out cursor col row
   out=$(TMUX="$socket_path,0,0" "$bin" --inspect --pane="$target")
   cursor=$(grep '^copy_cursor=' <<<"$out")
   col=${cursor#copy_cursor=}
   col=${col%,*}
   row=${cursor#*,}
   mapfile -t capture < <(grep -A 200 '^--- capture ---$' <<<"$out")
   [[ ${capture[$((row + 1))]:col:1} == "$char" ]]
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

"$tmux_bin" -L "$socket" send-keys -t "$pane" -X refresh-on
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
overlay_pane=$("$tmux_bin" -L "$socket" display-message -p -t "$session:0.0" '#{pane_id}')
"$tmux_bin" -L "$socket" send-keys -t "$overlay_pane" Escape
for _ in {1..100}; do
   if ! "$tmux_bin" -L "$socket" has-session -t "flash-overlay-${pane#%}" 2>/dev/null; then
      break
   fi
   sleep 0.02
done
! "$tmux_bin" -L "$socket" has-session -t "flash-overlay-${pane#%}" 2>/dev/null
[[ $("$tmux_bin" -L "$socket" display-message -p -t "$pane" '#{pane_in_mode}') == 1 ]]
printf 'ok existing copy-mode invocation freezes live refresh\n'

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
"$tmux_bin" -L "$socket" send-keys -t "$overlay_pane" Escape
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
   if [[ $("$tmux_bin" -L "$socket" display-message -p -t "$pane" '#{pane_in_mode}') == 1 ]]; then
      break
   fi
   sleep 0.02
done
[[ $("$tmux_bin" -L "$socket" display-message -p -t "$pane" '#{pane_in_mode}') == 1 ]]

jump_target=$("$tmux_bin" -L "$socket" capture-pane -p -M -t "$pane" | grep -m 1 '^FLASH-NOISE-')
overlay_pane=$("$tmux_bin" -L "$socket" display-message -p -t "$session:0.0" '#{pane_id}')
"$tmux_bin" -L "$socket" send-keys -t "$overlay_pane" -l "$jump_target"
"$tmux_bin" -L "$socket" send-keys -t "$overlay_pane" Enter
for _ in {1..100}; do
   if ! "$tmux_bin" -L "$socket" has-session -t "flash-overlay-${pane#%}" 2>/dev/null; then
      break
   fi
   sleep 0.02
done
! "$tmux_bin" -L "$socket" has-session -t "flash-overlay-${pane#%}" 2>/dev/null
assert_cursor_marker "$jump_target"
printf 'ok normal invocation jumps within the frozen snapshot\n'

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

wrap_line=$(printf 'A%.0s' {1..90})WRAPTOKEN$(printf 'B%.0s' {1..40})
wrap_pane=$("$tmux_bin" -L "$socket" new-window -d -P -F '#{pane_id}' -t "$session" /bin/sh -c "printf '%s\\n' '$wrap_line'; exec cat")
wrap_win=$("$tmux_bin" -L "$socket" display-message -p -t "$wrap_pane" '#{session_name}:#{window_index}')
for _ in {1..100}; do
   if "$tmux_bin" -L "$socket" capture-pane -p -t "$wrap_pane" | grep -q WRAPTOKEN; then
      break
   fi
   sleep 0.02
done
"$tmux_bin" -L "$socket" capture-pane -p -t "$wrap_pane" | grep -q WRAPTOKEN

TMUX="$socket_path,0,0" "$bin" --pane="$wrap_pane"
for _ in {1..100}; do
   if [[ $("$tmux_bin" -L "$socket" display-message -p -t "$wrap_pane" '#{pane_in_mode}') == 1 ]]; then
      break
   fi
   sleep 0.02
done
[[ $("$tmux_bin" -L "$socket" display-message -p -t "$wrap_pane" '#{pane_in_mode}') == 1 ]]
for _ in {1..100}; do
   overlay_pane=$("$tmux_bin" -L "$socket" display-message -p -t "$wrap_win" '#{pane_id}')
   if [[ $overlay_pane != "$wrap_pane" ]]; then
      break
   fi
   sleep 0.02
done
[[ $overlay_pane != "$wrap_pane" ]]
"$tmux_bin" -L "$socket" send-keys -t "$overlay_pane" -l WRAPTOKEN
"$tmux_bin" -L "$socket" send-keys -t "$overlay_pane" Enter
for _ in {1..100}; do
   if ! "$tmux_bin" -L "$socket" has-session -t "flash-overlay-${wrap_pane#%}" 2>/dev/null; then
      break
   fi
   sleep 0.02
done
! "$tmux_bin" -L "$socket" has-session -t "flash-overlay-${wrap_pane#%}" 2>/dev/null
wrap_out=$(TMUX="$socket_path,0,0" "$bin" --inspect --pane="$wrap_pane")
grep -qx 'in_mode=true' <<<"$wrap_out"
grep -qx 'copy_cursor=10,1' <<<"$wrap_out"
printf 'ok jump lands on a soft-wrapped line\n'

blank_pane=$("$tmux_bin" -L "$socket" new-window -d -P -F '#{pane_id}' -t "$session" /bin/sh -c 'printf "\nHELLO\n   TARGETX\n"; exec cat')
blank_win=$("$tmux_bin" -L "$socket" display-message -p -t "$blank_pane" '#{session_name}:#{window_index}')
for _ in {1..100}; do
  if "$tmux_bin" -L "$socket" capture-pane -p -t "$blank_pane" | grep -q TARGETX; then
    break
  fi
  sleep 0.02
done
"$tmux_bin" -L "$socket" capture-pane -p -t "$blank_pane" | grep -q TARGETX
TMUX="$socket_path,0,0" "$bin" --pane="$blank_pane"
for _ in {1..100}; do
  if [[ $("$tmux_bin" -L "$socket" display-message -p -t "$blank_pane" '#{pane_in_mode}') == 1 ]]; then
    break
  fi
  sleep 0.02
done
[[ $("$tmux_bin" -L "$socket" display-message -p -t "$blank_pane" '#{pane_in_mode}') == 1 ]]
for _ in {1..100}; do
  overlay_pane=$("$tmux_bin" -L "$socket" display-message -p -t "$blank_win" '#{pane_id}')
  if [[ $overlay_pane != "$blank_pane" ]] && "$tmux_bin" -L "$socket" capture-pane -p -t "$overlay_pane" | grep -q TARGETX; then
    break
  fi
  sleep 0.02
done
[[ $overlay_pane != "$blank_pane" ]]
"$tmux_bin" -L "$socket" send-keys -t "$overlay_pane" -l TARGETX
"$tmux_bin" -L "$socket" send-keys -t "$overlay_pane" Enter
for _ in {1..100}; do
  if ! "$tmux_bin" -L "$socket" has-session -t "flash-overlay-${blank_pane#%}" 2>/dev/null; then
    break
  fi
  sleep 0.02
done
! "$tmux_bin" -L "$socket" has-session -t "flash-overlay-${blank_pane#%}" 2>/dev/null
assert_copy_cursor 3 2 "$blank_pane"
printf 'ok jump crosses leading blank rows to an exact cell\n'

fixture_pane=$("$tmux_bin" -L "$socket" new-window -d -P -F '#{pane_id}' -t "$session" /bin/sh -c 'exec cat')
fixture_win=$("$tmux_bin" -L "$socket" display-message -p -t "$fixture_pane" '#{session_name}:#{window_index}')
"$tmux_bin" -L "$socket" resize-window -t "$fixture_win" -x 135 -y 31
"$tmux_bin" -L "$socket" load-buffer -b flash-test-buffer tests/sh/test-buffer
"$tmux_bin" -L "$socket" paste-buffer -b flash-test-buffer -t "$fixture_pane"
for _ in {1..100}; do
   if "$tmux_bin" -L "$socket" capture-pane -p -t "$fixture_pane" | grep -q 'Plan · Grok 4.6 xAI · medium'; then
      break
   fi
   sleep 0.02
done
"$tmux_bin" -L "$socket" capture-pane -p -t "$fixture_pane" | grep -q 'Plan · Grok 4.6 xAI · medium'
TMUX="$socket_path,0,0" "$bin" --pane="$fixture_pane"
for _ in {1..100}; do
   overlay_pane=$("$tmux_bin" -L "$socket" display-message -p -t "$fixture_win" '#{pane_id}')
   if [[ $overlay_pane != "$fixture_pane" ]]; then
      break
   fi
   sleep 0.02
done
[[ $overlay_pane != "$fixture_pane" ]]
"$tmux_bin" -L "$socket" send-keys -t "$overlay_pane" -l P
plan_label=
for _ in {1..100}; do
   plan_line=$("$tmux_bin" -L "$socket" capture-pane -p -t "$overlay_pane" | grep -m 1 '┃  P' || true)
   plan_label=${plan_line:36:1}
   [[ $plan_label =~ [[:alpha:]] ]] && break
   sleep 0.02
done
[[ $plan_label =~ [[:alpha:]] ]]
"$tmux_bin" -L "$socket" send-keys -t "$overlay_pane" -l "$plan_label"
for _ in {1..200}; do
   if ! "$tmux_bin" -L "$socket" has-session -t "flash-overlay-${fixture_pane#%}" 2>/dev/null; then
      break
   fi
   sleep 0.02
done
! "$tmux_bin" -L "$socket" has-session -t "flash-overlay-${fixture_pane#%}" 2>/dev/null
assert_cursor_char P "$fixture_pane"
printf 'ok test-buffer Plan jump lands on its source cell\n'

column_line=$(printf '%*sABSOLUTE-COLUMN-TOKEN%*s' 32 '' 40 '')
column_pane=$("$tmux_bin" -L "$socket" new-window -d -P -F '#{pane_id}' -t "$session" /bin/sh -c "printf '%s\\n' '$column_line'; exec cat")
column_win=$("$tmux_bin" -L "$socket" display-message -p -t "$column_pane" '#{session_name}:#{window_index}')
for _ in {1..100}; do
   if "$tmux_bin" -L "$socket" capture-pane -p -t "$column_pane" | grep -q ABSOLUTE-COLUMN-TOKEN; then
      break
   fi
   sleep 0.02
done
"$tmux_bin" -L "$socket" copy-mode -t "$column_pane"
"$tmux_bin" -L "$socket" send-keys -t "$column_pane" -X history-top
"$tmux_bin" -L "$socket" send-keys -t "$column_pane" -X -N 60 cursor-right
TMUX="$socket_path,0,0" "$bin" --pane="$column_pane"
for _ in {1..100}; do
   overlay_pane=$("$tmux_bin" -L "$socket" display-message -p -t "$column_win" '#{pane_id}')
   if [[ $overlay_pane != "$column_pane" ]]; then
      break
   fi
   sleep 0.02
done
[[ $overlay_pane != "$column_pane" ]]
"$tmux_bin" -L "$socket" send-keys -t "$overlay_pane" -l ABSOLUTE-COLUMN-TOKEN
"$tmux_bin" -L "$socket" send-keys -t "$overlay_pane" Enter
for _ in {1..100}; do
   if ! "$tmux_bin" -L "$socket" has-session -t "flash-overlay-${column_pane#%}" 2>/dev/null; then
      break
   fi
   sleep 0.02
done
! "$tmux_bin" -L "$socket" has-session -t "flash-overlay-${column_pane#%}" 2>/dev/null
assert_cursor_column 32 "$column_pane"
printf 'ok jump resets to the target column\n'

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

"$tmux_bin" -L "$socket" resize-pane -Z -t "$pane"
[[ $("$tmux_bin" -L "$socket" display-message -p -t "$pane" '#{window_zoomed_flag}') == 1 ]]
TMUX="$socket_path,0,0" "$bin" --pane="$pane"
for _ in {1..100}; do
   overlay_pane=$("$tmux_bin" -L "$socket" display-message -p -t "$session:0.0" '#{pane_id}')
   if [[ $overlay_pane != "$pane" ]]; then
      break
   fi
   sleep 0.02
done
[[ $overlay_pane != "$pane" ]]
[[ $("$tmux_bin" -L "$socket" display-message -p -t "$overlay_pane" '#{window_zoomed_flag}') == 1 ]]
"$tmux_bin" -L "$socket" send-keys -t "$overlay_pane" Escape
for _ in {1..100}; do
   if ! "$tmux_bin" -L "$socket" has-session -t "flash-overlay-${pane#%}" 2>/dev/null; then
      break
   fi
   sleep 0.02
done
! "$tmux_bin" -L "$socket" has-session -t "flash-overlay-${pane#%}" 2>/dev/null
[[ $("$tmux_bin" -L "$socket" display-message -p -t "$pane" '#{window_zoomed_flag}') == 1 ]]
"$tmux_bin" -L "$socket" resize-pane -Z -t "$pane"
printf 'ok overlay keeps the pane zoomed\n'

if "$interactive"; then
   open_cmd="'$bin' --pane=#{pane_id}"
   "$tmux_bin" -L "$socket" set-option -g mode-keys vi
   "$tmux_bin" -L "$socket" bind-key f run-shell -b "$open_cmd"
   "$tmux_bin" -L "$socket" bind-key -T copy-mode-vi s run-shell -b "$open_cmd"
   "$tmux_bin" -L "$socket" send-keys -t "$pane" -X cancel
   printf 'sandbox: prefix-f at bottom; [ then scroll, then s. Detach with prefix-d.\n'
   "$tmux_bin" -L "$socket" attach-session -t "$session"
fi
