# flash.tmux

Leap around a tmux pane like flash.nvim. Zig 0.16.

## Install

TPM:

```tmux
set -g @plugin 'and-rs/flash.tmux'
```

Or `tmux run-shell /path/to/flash.tmux`. Builds the binary on first load if missing.

## Keys

|              | default                 |
| ------------ | ----------------------- |
| prefix       | `s` (`@flash-key`)      |
| copy-mode-vi | `s` (`@flash-copy-key`) |
| debug        | off (`@flash-debug`)    |

Type a pattern, then a label. Esc aborts. Enter jumps the nearest match. `@flash-debug` `1`/`on`/`true`/`yes` logs to `/tmp/flash.tmux.log`.

## Dev

```
just test
just build
just visual      # inside tmux
just tmux-test
```
