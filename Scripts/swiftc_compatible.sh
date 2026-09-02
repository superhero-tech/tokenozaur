#!/bin/zsh
set -euo pipefail

script_dir=${0:A:h}
project_dir=${script_dir:h}
mkdir -p "$project_dir/.build/module-cache"

exec /Library/Developer/CommandLineTools/usr/bin/swiftc \
  -module-cache-path "$project_dir/.build/module-cache" \
  -interface-compiler-version 6.2.3.3.2 \
  "$@"
