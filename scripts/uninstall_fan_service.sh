#!/bin/zsh -f
set -euo pipefail
script_dir="${0:A:h}"
exec /usr/bin/python3 -I -S "$script_dir/fan_service_admin.py" uninstall
