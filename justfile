bin := justfile_directory() / "zig-out/bin/flash_tmux"

default: test

test:
    zig build test

build:
    zig build

visual: build
    test -n "${TMUX:-}" || (echo "run inside tmux" >&2; exit 1)
    tmux display-popup -B -E -x P -y P -w "$(tmux display-message -p '#{pane_width}')" -h "$(tmux display-message -p '#{pane_height}')" "{{justfile_directory()}}/flash-run.sh {{bin}} ${TMUX_PANE}"

visual-copy: build
    test -n "${TMUX:-}" || (echo "run inside tmux" >&2; exit 1)
    tmux copy-mode
    tmux display-popup -B -E -x P -y P -w "$(tmux display-message -p '#{pane_width}')" -h "$(tmux display-message -p '#{pane_height}')" "{{justfile_directory()}}/flash-run.sh {{bin}} ${TMUX_PANE}"

tmux-test: build
    ./tests/tmux-sandbox.sh "{{bin}}"

tmux-sandbox: build
    ./tests/tmux-sandbox.sh --interactive "{{bin}}"
