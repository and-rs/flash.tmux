bin := justfile_directory() / "zig-out/bin/flash_tmux"

default: test

test:
    zig build test

build:
    zig build -Doptimize=ReleaseFast

visual: build
    test -n "${TMUX:-}" || (echo "run inside tmux" >&2; exit 1)
    "{{bin}}" --pane="${TMUX_PANE}"

visual-copy: build
    test -n "${TMUX:-}" || (echo "run inside tmux" >&2; exit 1)
    tmux copy-mode
    "{{bin}}" --pane="${TMUX_PANE}"

tmux-test: build
    ./tests/tmux-sandbox.sh "{{bin}}"

tmux-sandbox: build
    ./tests/tmux-sandbox.sh --interactive "{{bin}}"

release:
    #!/usr/bin/env sh
    set -eu
    version=$(tr -d ' \t\r\n' < VERSION)
    git tag -a "$version" -m "$version"
    git push origin "$version"
