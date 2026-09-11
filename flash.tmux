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

release_asset() {
    os=$(uname -s) || return 1
    arch=$(uname -m) || return 1
    case "$os" in
        Linux) os=linux ;;
        Darwin) os=macos ;;
        FreeBSD) os=freebsd ;;
        *) return 1 ;;
    esac
    case "$arch" in
        x86_64|amd64) arch=x86_64 ;;
        aarch64|arm64) arch=aarch64 ;;
        *) return 1 ;;
    esac
    if [ "$os" = freebsd ] && [ "$arch" != x86_64 ]; then
        return 1
    fi
    printf '%s\n' "flash_tmux-${os}-${arch}"
}

download() {
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL -o "$2" "$1"
    elif command -v wget >/dev/null 2>&1; then
        wget -q -O "$2" "$1"
    else
        log "no curl/wget"
        return 1
    fi
}

file_sha256() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | awk '{print $1}'
    elif command -v sha256 >/dev/null 2>&1; then
        sha256 -q "$1"
    else
        log "no sha256"
        return 1
    fi
}

fetch_release() {
    asset=$(release_asset) || return 1
    base="https://github.com/and-rs/flash.tmux/releases/latest/download"
    log "fetch $base/$asset"
    mkdir -p "$DIR/zig-out/bin" || return 1
    tmp="$BIN.$$"
    sums="$tmp.sums"
    if ! download "$base/SHA256SUMS" "$sums" || ! download "$base/$asset" "$tmp"; then
        rm -f "$tmp" "$sums"
        return 1
    fi
    if [ ! -s "$tmp" ] || [ ! -s "$sums" ]; then
        rm -f "$tmp" "$sums"
        return 1
    fi
    want=$(awk -v a="$asset" '$2 == a { print $1; exit }' "$sums")
    got=$(file_sha256 "$tmp") || {
        rm -f "$tmp" "$sums"
        return 1
    }
    rm -f "$sums"
    if [ -z "$want" ] || [ -z "$got" ] || [ "$want" != "$got" ]; then
        rm -f "$tmp"
        say "checksum mismatch"
        return 1
    fi
    chmod +x "$tmp" || {
        rm -f "$tmp"
        return 1
    }
    mv "$tmp" "$BIN" || {
        rm -f "$tmp"
        return 1
    }
    log "fetched latest $asset"
}

needs_build=0
if [ "${FLASH_TMUX_DEV:-0}" -eq 1 ]; then
    needs_build=1
elif [ ! -x "$BIN" ]; then
    if ! fetch_release; then
        log "release fetch or checksum verification failed"
        release_failed=1
    fi
fi

if [ ! -x "$BIN" ]; then
    needs_build=1
fi

if [ "$needs_build" -eq 1 ]; then
    log "building local checkout"
    if ! command -v zig >/dev/null 2>&1; then
        if [ "${release_failed:-0}" -eq 1 ]; then
            say "release unavailable; install Zig 0.16"
        else
            say "zig 0.16 not on PATH"
        fi
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
