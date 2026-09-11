#!/bin/sh
set -eu

DIR=$(dirname "$0")
BIN="$DIR/zig-out/bin/flash_tmux"

get_option() {
    val=$(tmux show-option -gqv "$1" || true)
    if [ -z "$val" ]; then
        printf '%s\n' "$2"
    else
        printf '%s\n' "$val"
    fi
}

key=$(get_option "@flash-key" "f")
copy_key=$(get_option "@flash-copy-key" "s")

if [ ! -x "$BIN" ]; then
    if ! command -v zig >/dev/null 2>&1; then
        tmux display-message "flash.tmux: zig not found"
        exit 0
    fi
    if ! (cd "$DIR" && zig build); then
        tmux display-message "flash.tmux: zig build failed"
        exit 0
    fi
fi

cmd="'$BIN' --pane=#{pane_id}"
tmux bind-key "$key" display-popup -B -E -x P -y P -w '#{pane_width}' -h '#{pane_height}' "$cmd"
tmux bind-key -T copy-mode-vi "$copy_key" display-popup -B -E -x P -y P -w '#{pane_width}' -h '#{pane_height}' "$cmd"
