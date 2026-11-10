#!/usr/bin/python3
"""Pin the two hardened-runtime release artifacts for a reviewed local install."""
import hashlib
import json
from pathlib import Path
import plistlib
import sys

from fan_service_admin import LABEL, PRODUCT, signature


def main():
    if len(sys.argv) != 3:
        raise SystemExit('usage: build_service_manifest.py APP SERVICE_PACKAGE')
    app, package = map(Path, sys.argv[1:])
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    daemon = package / PRODUCT
    data = {
        'protocolVersion': 1,
        'authorizationScope': 'user-account',
        'label': LABEL,
        'product': PRODUCT,
        'version': info['CFBundleShortVersionString'],
        'build': info['CFBundleVersion'],
        'guiCDHash': signature(app),
        'daemonCDHash': signature(daemon),
        'guiBinarySHA256': hashlib.sha256((app / 'Contents/MacOS/LiquidBar').read_bytes()).hexdigest(),
        'daemonSHA256': hashlib.sha256(daemon.read_bytes()).hexdigest(),
        'cpuIndex': 1,
        'chipID': 54315,
        'driverVersion': '0.7.2',
    }
    (package / 'manifest.json').write_text(json.dumps(data, indent=2) + '\n')


if __name__ == '__main__':
    main()
