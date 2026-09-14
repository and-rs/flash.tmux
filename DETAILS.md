# here I document technical details

## Some development considerations:

1. tests separated from the source files.
2. files with dedicated and separated concerns.
3. it's a bit concerning the amount of tmux calls done.

## Problems that were encountered along the way.

1. why use a replica session?
   - related to cursor jumping, state while opening the flash buffer & more.
2. solutions that prevent the cursor from jumping?
   - unanswered yet
3. characters that are skipped from buffer?
   - yes some character, like box characters, are skipped from the flash buffer.
     as it is basically unusual/impossible to jump to them and just pollute the
     selection buffer. there are other chars that might be worth skipping over
     too in the future.

## Future ideas

1. we could use `tmux -C` control mode for the tmux calls that we make
   - the problem would be parsing the protocol and validating how much faster it
     would be.
