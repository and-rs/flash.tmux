# flash.tmux

Leap around a tmux pane like flash.nvim. Zig 0.16.

## Install

```tmux
set -g @plugin 'and-rs/flash.tmux'
```

Or `tmux run-shell /path/to/flash.tmux`. Fetches the latest release binary on first load and checks its SHA-256; Zig is used if that fails. Without Zig, tmux reports the failure and required next step.

For local development, use the development entry point instead. It always builds the checkout with Zig and never fetches a release:

```tmux
run-shell '/path/to/flash.dev.tmux'
```

## Config

```tmux
# Optional overrides
set -g @flash-key 's'
set -g @flash-copy-key 's'
set -g @flash-debug 'off'
```

Type a pattern, then a label. Esc aborts. Enter jumps the nearest match. `@flash-debug` `1`/`on`/`true`/`yes` logs to `/tmp/flash.tmux.log`.

## Dev

```
just test
just build
just visual      # inside tmux
just tmux-test
just release-build
```
