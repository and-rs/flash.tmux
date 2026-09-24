# here I document technical details

## Dev guidelines:

1. tests separated from the source files.
2. files with dedicated and separated concerns.
3. no silent errors and no unrecoverable frozen state.

## Problems that were encountered along the way.

1. why use a replica session?
   - we don't anymore. a pane-sized `display-popup` covers the source without `swap-pane`, which was flashing the live application cursor.
2. solutions that prevent the cursor from jumping to and from the corner of the terminal?
   - unanswered yet
3. characters that are skipped from buffer?
   - yes some character, like box characters, are skipped from the flash buffer. as it is basically unusual/impossible to jump to them and just pollute the selection buffer. there are other chars that might be worth skipping over too in the future.

## Future ideas

1. we could use `tmux -C` control mode for the tmux calls that we make
   - the problem would be parsing the protocol and validating how much faster it would be.
