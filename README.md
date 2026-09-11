# flash.tmux

Leap around a tmux pane like flash.nvim. Zig 0.16.

## Install

```tmux
set -g @plugin 'and-rs/flash.tmux'
```

Or `tmux run-shell /path/to/flash.tmux`. Fetches the release binary matching `VERSION` on first load and again after the plugin updates (TPM). Checks SHA-256; Zig is used if that fails. Without Zig, tmux reports the failure and required next step.

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
just visual # inside tmux
just tmux-test
```

## Compared to:

This plugin jumps. It does not yank. Type a pattern, press a label, the copy-mode cursor moves there. From prefix it enters copy-mode; from copy-mode it keeps (and extends) an active selection. Yank with tmux as usual (`v` then `y`).

> (None are better or worse, just different setups, you make your own conclusions)

Same job, different shape:

| plugin                                                                  | search                     | where                | overlay         | lang   |
| ----------------------------------------------------------------------- | -------------------------- | -------------------- | --------------- | ------ |
| this                                                                    | incremental + labels       | prefix and copy-mode | replica session | Zig    |
| [AndreVicencio/tmux-flash](https://github.com/AndreVicencio/tmux-flash) | incremental + labels       | copy-mode-vi only    | replica window  | Python |
| [leo0o7/flash.tmux](https://github.com/leo0o7/flash.tmux)               | incremental + labels       | copy-mode only       | popup           | Python |
| [j4hangir/tmux-jump](https://github.com/j4hangir/tmux-jump)             | incremental; labels if ≤10 | prefix               | popup           | Go     |

Different job (hint-to-copy or easymotion):

- [Kristijan/flash-copy.tmux](https://github.com/Kristijan/flash-copy.tmux) — search words, copy/range to clipboard
- [tmux-fingers](https://github.com/Morantron/tmux-fingers), [tmux-thumbs](https://github.com/fcsonline/tmux-thumbs), [tmux-fastcopy](https://github.com/abhinav/tmux-fastcopy) — regex hints (URLs, SHAs, paths) then copy
- [schasse/tmux-jump](https://github.com/schasse/tmux-jump), [easyjump.tmux](https://github.com/roy2220/easyjump.tmux), [tmux-easy-motion](https://github.com/IngoMeyer441/tmux-easy-motion) — 1–2 char easymotion/leap, not flash incremental search
