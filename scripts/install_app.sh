#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
repo_root="${script_dir:h}"
source_app="$repo_root/dist/LiquidBar.app"
destination_app="/Applications/LiquidBar.app"

if [[ ! -d "$source_app" || ! -x "$source_app/Contents/MacOS/LiquidBar" ]]; then
  print -u2 "Build LiquidBar first with scripts/build_app.sh"
  exit 1
fi
if [[ "$destination_app" != "/Applications/LiquidBar.app" ]]; then
  print -u2 "Unexpected installation target"
  exit 1
fi
if [[ -L "$destination_app" ]]; then
  print -u2 "Refusing to overwrite a symbolic link at $destination_app"
  exit 1
fi

if [[ -e "$destination_app" ]]; then
  /usr/bin/osascript -e 'tell application "LiquidBar" to quit' >/dev/null 2>&1 || true
  /bin/rm -rf -- "$destination_app"
fi
/usr/bin/ditto "$source_app" "$destination_app"
/usr/bin/open "$destination_app"
print "$destination_app"
