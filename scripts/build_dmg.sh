#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
repo_root="${script_dir:h}"
app_path="$repo_root/dist/LiquidBar.app"
staging="$repo_root/.build/dmg-staging"

if [[ ! -d "$app_path" || ! -x "$app_path/Contents/MacOS/LiquidBar" ]]; then
  "$repo_root/scripts/build_app.sh" >/dev/null
fi

service_assets="$app_path/Contents/Resources/FanControlService"
if [[ ! -f "$service_assets/fan_service_admin.py" || ! -x "$service_assets/LiquidBarFanControlDaemon" ]]; then
  print -u2 "The app is missing bundled fan-service assets. Run scripts/build_app.sh first."
  exit 1
fi

version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app_path/Contents/Info.plist")"
dmg_path="$repo_root/dist/LiquidBar-$version.dmg"

if [[ "$staging" != "$repo_root/.build/dmg-staging" ]]; then
  print -u2 "Refusing to clean unexpected staging path"
  exit 1
fi
/bin/rm -rf -- "$staging" "$dmg_path"
/bin/mkdir -p "$staging"

/usr/bin/ditto "$app_path" "$staging/LiquidBar.app"
/bin/ln -s /Applications "$staging/Applications"

/usr/bin/hdiutil create \
  -volname "LiquidBar" \
  -srcfolder "$staging" \
  -ov -format UDZO \
  "$dmg_path" >/dev/null

/bin/rm -rf -- "$staging"
print "$dmg_path"
