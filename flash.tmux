#!/bin/sh

DIR=$(dirname -- "$0")
DIR=$(cd -- "$DIR" && pwd)
BIN="$DIR/zig-out/bin/flash_tmux"
LOG="${TMPDIR:-/tmp}/flash.tmux.log"

log() {
    printf '%s %s\n' "$(date '+%H:%M:%S' 2>/dev/null || echo --)" "$*" >>"$LOG"
}

say() {
    log "$1"
    tmux display-message "flash.tmux: $1" || true
}

log "start 0=$0 dir=$DIR"
log "PATH=$PATH"

if ! command -v zig >/dev/null 2>&1; then
    env_path=$(tmux show-environment -g PATH 2>/dev/null || true)
    case "$env_path" in
        PATH=*)
            PATH="${env_path#PATH=}"
            export PATH
            log "adopted tmux PATH"
            ;;
    esac
fi

get_option() {
    val=$(tmux show-option -gqv "$1" 2>/dev/null || true)
    if [ -z "$val" ]; then
        printf '%s\n' "$2"
    else
        printf '%s\n' "$val"
    fi
}

key=$(get_option "@flash-key" "s")
copy_key=$(get_option "@flash-copy-key" "s")
log "keys prefix=$key copy=$copy_key"

if [ ! -x "$BIN" ]; then
    say "building"
    if ! command -v zig >/dev/null 2>&1; then
        say "zig not on PATH (see $LOG)"
        exit 0
    fi
    if ! (cd "$DIR" && zig build) >>"$LOG" 2>&1; then
        say "zig build failed (see $LOG)"
        exit 0
    fi
fi

if [ ! -x "$BIN" ]; then
    say "missing $BIN"
    exit 0
fi

open="'$BIN' --pane=#{pane_id}"
if ! tmux bind-key "$key" run-shell -b "$open"; then
    say "bind prefix-$key failed"
    exit 0
fi
if ! tmux bind-key -T copy-mode-vi "$copy_key" run-shell -b "$open"; then
    say "bind copy-mode-vi $copy_key failed"
    exit 0
fi

say "ready prefix-$key copy-$copy_key"
