#!/bin/zsh
set -euo pipefail

script_dir=${0:A:h}
project_dir=${script_dir:h}
configuration=${1:-release}
app_dir="$project_dir/.build/Tokenozaur.app"
export SWIFT_EXEC="$project_dir/Scripts/swiftc_compatible.sh"
export SWIFTPM_MODULECACHE_OVERRIDE="$project_dir/.build/module-cache"
export CLANG_MODULE_CACHE_PATH="$project_dir/.build/module-cache"
cd "$project_dir"
swift build --disable-sandbox -c "$configuration" --product Tokenozaur
binary_path=$(swift build --disable-sandbox -c "$configuration" --show-bin-path)/Tokenozaur

mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$binary_path" "$app_dir/Contents/MacOS/Tokenozaur"
cp "$project_dir/Resources/Info.plist" "$app_dir/Contents/Info.plist"
chmod +x "$app_dir/Contents/MacOS/Tokenozaur"

xattr -cr "$app_dir"
codesign --force --deep --sign - "$app_dir"
printf '%s\n' "$app_dir"
