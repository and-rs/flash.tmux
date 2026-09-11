bin := justfile_directory() / "zig-out/bin/flash_tmux"

default: test

test:
    zig build test

build:
    zig build

visual: build
    test -n "${TMUX:-}" || (echo "run inside tmux" >&2; exit 1)
    "{{justfile_directory()}}/scripts/flash-open.sh" "{{bin}}" "${TMUX_PANE}" $(tmux display-message -p '#{pane_width} #{pane_height}')

visual-copy: build
    test -n "${TMUX:-}" || (echo "run inside tmux" >&2; exit 1)
    tmux copy-mode
    "{{justfile_directory()}}/scripts/flash-open.sh" "{{bin}}" "${TMUX_PANE}" $(tmux display-message -p '#{pane_width} #{pane_height}')

tmux-test: build
    ./tests/tmux-sandbox.sh "{{bin}}"

tmux-sandbox: build
    ./tests/tmux-sandbox.sh --interactive "{{bin}}"
