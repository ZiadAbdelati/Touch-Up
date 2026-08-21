#!/bin/zsh
set -euo pipefail

script_dir=${0:A:h}
repo_root=${script_dir:h}
output_dir=${1:-"$repo_root/build/rack-touch-seizer"}

mkdir -p "$output_dir"
xcrun clang \
  -arch x86_64 \
  -mmacosx-version-min=11.0 \
  -O2 \
  -Wall -Wextra -Werror \
  -fblocks \
  -I"$repo_root" \
  "$script_dir/RackTouchSeizer.c" \
  -framework CoreFoundation \
  -framework IOKit \
  -lpthread \
  -o "$output_dir/rack-touch-seizer"

codesign --force --sign - "$output_dir/rack-touch-seizer"
codesign --verify --strict "$output_dir/rack-touch-seizer"
echo "Built $output_dir/rack-touch-seizer"
