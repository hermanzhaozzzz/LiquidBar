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
  # Address only an already-running process. `tell application ... to quit`
  # can launch a stopped old app, which would reapply its saved device settings.
  /usr/bin/osascript -l JavaScript - "$destination_app" <<'JXA'
ObjC.import("AppKit");
function run(argv) {
    const apps = $.NSWorkspace.sharedWorkspace.runningApplications;
    for (let index = 0; index < apps.count; index++) {
        const app = apps.objectAtIndex(index);
        if (ObjC.unwrap(app.bundleURL.path) === argv[0]) {
            app.terminate;
        }
    }
}
JXA
  # Include workers left behind by a crashed parent. Never replace their bundle
  # while safety restoration is in progress, or force an app that cancelled quit.
  process_pattern='/Applications/LiquidBar[.]app/Contents/(MacOS/LiquidBar|Resources/device_helper[.]py)( |$)'
  deadline=$((SECONDS + 15))
  while /usr/bin/pgrep -f "$process_pattern" >/dev/null; do
    if (( SECONDS >= deadline )); then
      print -u2 "LiquidBar or its device helper is still running. Installation stopped; finish its safety shutdown and retry."
      exit 1
    fi
    /bin/sleep 0.2
  done
  /bin/rm -rf -- "$destination_app"
fi
/usr/bin/ditto "$source_app" "$destination_app"
/usr/bin/open "$destination_app"
print "$destination_app"
