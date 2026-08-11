#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
repo_root="${script_dir:h}"
app_path="$repo_root/dist/LiquidBar.app"
contents_path="$app_path/Contents"
iconset_path="$repo_root/.build/LiquidBar.iconset"

if [[ "$repo_root" != "/Users/"*"/LiquidBar" && ! -f "$repo_root/Package.swift" ]]; then
  print -u2 "Unexpected repository root: $repo_root"
  exit 1
fi

cd "$repo_root"
swift build -c release
binary_dir="$(swift build -c release --show-bin-path)"
if [[ -z "$binary_dir" || ! -x "$binary_dir/LiquidBar" ]]; then
  print -u2 "Release binary was not produced"
  exit 1
fi

if [[ "$app_path" != "$repo_root/dist/LiquidBar.app" ]]; then
  print -u2 "Refusing to clean unexpected app path"
  exit 1
fi
/bin/rm -rf -- "$app_path"
/bin/rm -rf -- "$iconset_path"
/bin/mkdir -p "$contents_path/MacOS" "$contents_path/Resources" "$iconset_path"

/bin/cp "$binary_dir/LiquidBar" "$contents_path/MacOS/LiquidBar"
/bin/cp "$repo_root/Resources/Info.plist" "$contents_path/Info.plist"
/bin/cp "$repo_root/Resources/device_helper.py" "$contents_path/Resources/device_helper.py"

for spec in \
  "16 icon_16x16.png" "32 icon_16x16@2x.png" \
  "32 icon_32x32.png" "64 icon_32x32@2x.png" \
  "128 icon_128x128.png" "256 icon_128x128@2x.png" \
  "256 icon_256x256.png" "512 icon_256x256@2x.png" \
  "512 icon_512x512.png" "1024 icon_512x512@2x.png"; do
  size="${spec%% *}"
  name="${spec#* }"
  /usr/bin/sips -z "$size" "$size" "$repo_root/Resources/AppIcon.png" \
    --out "$iconset_path/$name" >/dev/null
done
/usr/bin/iconutil -c icns "$iconset_path" -o "$contents_path/Resources/AppIcon.icns"

/usr/bin/codesign --force --deep --sign - "$app_path"
print "$app_path"
