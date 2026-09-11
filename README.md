# flash.tmux

Leap around a tmux pane like flash.nvim. Needs Zig 0.16.

## Install

TPM:

```tmux
set -g @plugin 'and-rs/flash.tmux'
```

Or `source-file /path/to/flash.tmux`. Builds `zig-out/bin/flash_tmux` on first
load if missing.

## Keys

|              | default                 |
| ------------ | ----------------------- |
| prefix       | `f` (`@flash-key`)      |
| copy-mode-vi | `s` (`@flash-copy-key`) |

Type a pattern, then a label. Esc aborts. Enter jumps the nearest match.

## Dev

```
just test
just build
just visual # inside tmux
just tmux-test
```
