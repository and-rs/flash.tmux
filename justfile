bin := justfile_directory() / "zig-out/bin/flash_tmux"

default: build

build:
    zig build -Doptimize=ReleaseFast

visual: build
    test -n "${TMUX:-}" || (echo "run inside tmux" >&2; exit 1)
    "{{bin}}" --pane="${TMUX_PANE}"

visual-copy: build
    test -n "${TMUX:-}" || (echo "run inside tmux" >&2; exit 1)
    tmux copy-mode
    "{{bin}}" --pane="${TMUX_PANE}"

snapshot-test: build
    zig build snapshot-cases -Doptimize=ReleaseFast
    ./tests/sh/snapshot-trigrams.sh "{{bin}}"

release:
    #!/usr/bin/env sh
    set -eu
    version=$(tr -d ' \t\r\n' < VERSION)
    head_version=$(git show HEAD:VERSION 2>/dev/null | tr -d ' \t\r\n')
    if [ "$version" != "$head_version" ]; then
        printf 'VERSION is not committed at HEAD\n' >&2
        exit 1
    fi
    git tag -a "$version" -m "$version"
    git push origin "$version"
