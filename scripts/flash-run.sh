#!/bin/sh
bin=$1
pane=$2
ov=${TMUX_PANE}
sid=$(tmux display-message -t "$ov" -p '#{session_name}')
"$bin" --pane="$pane" || true
tmux swap-pane -s "$ov" -t "$pane" 2>/dev/null || true
tmux kill-session -t "$sid" 2>/dev/null || true
