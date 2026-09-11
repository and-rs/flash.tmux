#!/bin/sh

DIR=$(dirname -- "$0")
DIR=$(cd -- "$DIR" && pwd)
FLASH_TMUX_DEV=1 exec "$DIR/flash.tmux"
