#!/usr/bin/env sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

luac -p "$ROOT"/lua/nvimclaw/*.lua "$ROOT"/plugin/nvimclaw.lua

nvim --headless -u NONE \
  --cmd 'set noswapfile' \
  --cmd "set rtp^=$ROOT" \
  +"luafile $ROOT/tests/headless.lua"
