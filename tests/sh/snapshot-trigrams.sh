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

tested=0
while IFS=$'\t' read -r pattern row col; do
  if ((limit > 0 && tested >= limit)); then
    break
  fi
  pane=$("$tmux_bin" -L "$socket" new-window -d -P -F '#{pane_id}' -t "$session" /bin/sh -c 'exec cat')
  window=$("$tmux_bin" -L "$socket" display-message -p -t "$pane" '#{session_name}:#{window_index}')
  "$tmux_bin" -L "$socket" paste-buffer -b flash-snapshot -t "$pane"
  "$tmux_bin" -L "$socket" copy-mode -t "$pane"
  "$tmux_bin" -L "$socket" send-keys -t "$pane" -X history-top
  [[ $("$tmux_bin" -L "$socket" display-message -p -t "$pane" '#{copy_cursor_x},#{copy_cursor_y}') == 0,0 ]]
  TMUX="$socket_path,0,0" "$bin" --pane="$pane"
  for _ in {1..100}; do
    overlay_pane=$("$tmux_bin" -L "$socket" display-message -p -t "$window" '#{pane_id}')
    if [[ $overlay_pane != "$pane" ]]; then
      break
    fi
    sleep 0.02
  done
  [[ $overlay_pane != "$pane" ]] || {
    printf 'overlay did not open: pattern=%s\n' "$pattern" >&2
    exit 1
  }

  "$tmux_bin" -L "$socket" send-keys -t "$overlay_pane" -l "$pattern"
  "$tmux_bin" -L "$socket" send-keys -t "$overlay_pane" Enter
  for _ in {1..100}; do
    if ! "$tmux_bin" -L "$socket" has-session -t "flash-overlay-${pane#%}" 2>/dev/null; then
      break
    fi
    sleep 0.02
  done
  ! "$tmux_bin" -L "$socket" has-session -t "flash-overlay-${pane#%}" 2>/dev/null || {
    printf 'overlay did not close: pattern=%s\n' "$pattern" >&2
    exit 1
  }

  cursor=$(TMUX="$socket_path,0,0" "$bin" --inspect --pane="$pane" | grep '^copy_cursor=')
  if [[ $cursor != "copy_cursor=$col,$row" ]]; then
    printf 'FAIL pattern=%s expected=%s,%s got=%s\n' "$pattern" "$col" "$row" "${cursor#copy_cursor=}" >&2
    exit 1
  fi
  "$tmux_bin" -L "$socket" kill-window -t "$window"
  ((tested += 1))
done < "$tmp_dir/cases.tsv"

printf 'ok bench-001 ASCII trigrams: %s cases\n' "$tested"
