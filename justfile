bin := justfile_directory() / "zig-out/bin/flash_tmux"

default: test

test:
    zig build test

build:
    zig build

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

release-build:
    mkdir -p dist
    zig build -Doptimize=ReleaseSafe -Dtarget=x86_64-linux-musl
    cp zig-out/bin/flash_tmux dist/flash_tmux-linux-x86_64
    zig build -Doptimize=ReleaseSafe -Dtarget=aarch64-linux-musl
    cp zig-out/bin/flash_tmux dist/flash_tmux-linux-aarch64
    zig build -Doptimize=ReleaseSafe -Dtarget=x86_64-macos
    cp zig-out/bin/flash_tmux dist/flash_tmux-macos-x86_64
    zig build -Doptimize=ReleaseSafe -Dtarget=aarch64-macos
    cp zig-out/bin/flash_tmux dist/flash_tmux-macos-aarch64
    zig build -Doptimize=ReleaseSafe -Dtarget=x86_64-freebsd
    cp zig-out/bin/flash_tmux dist/flash_tmux-freebsd-x86_64
    (cd dist && sha256sum flash_tmux-* > SHA256SUMS)
