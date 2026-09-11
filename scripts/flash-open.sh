#!/bin/sh
bin=$1
pane=$2
w=${3:-80}
h=${4:-24}
dir=$(dirname -- "$0")
dir=$(cd -- "$dir" && pwd)
sid="flash$$"

tmux new-session -d -s "$sid" -x "$w" -y "$h" || exit 1
ov=$(tmux display-message -t "$sid:" -p '#{pane_id}')
tmux set-option -t "$sid" status off
tmux resize-window -t "$sid:" -x "$w" -y "$h" 2>/dev/null || true
tmux respawn-pane -k -t "$ov" "/bin/sh '$dir/flash-run.sh' '$bin' '$pane'"
