bin := justfile_directory() / "zig-out/bin/flash_tmux"

default: test

test:
    zig build test

build:
    zig build

visual: build
    test -n "${TMUX:-}" || (echo "run inside tmux" >&2; exit 1)
    tmux display-popup -B -E -w 100% -h 100% -x 0 -y 0 "{{bin}} --pane ${TMUX_PANE}"
