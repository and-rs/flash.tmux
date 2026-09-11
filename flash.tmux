#!/bin/sh

DIR=$(dirname -- "$0")
DIR=$(cd -- "$DIR" && pwd)
BIN="$DIR/zig-out/bin/flash_tmux"
LOG="${TMPDIR:-/tmp}/flash.tmux.log"

get_option() {
    val=$(tmux show-option -gqv "$1" 2>/dev/null || true)
    if [ -z "$val" ]; then
        printf '%s\n' "$2"
    else
        printf '%s\n' "$val"
    fi
}

debug=0
case $(get_option "@flash-debug" "") in
    1|on|true|yes) debug=1 ;;
esac

log() {
    [ "$debug" -eq 1 ] || return 0
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

key=$(get_option "@flash-key" "s")
copy_key=$(get_option "@flash-copy-key" "s")
log "keys prefix=$key copy=$copy_key"

if [ ! -x "$BIN" ]; then
    log "building"
    if ! command -v zig >/dev/null 2>&1; then
        say "zig not on PATH"
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

log "ready prefix-$key copy-$copy_key"
