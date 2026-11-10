#!/usr/bin/python3
"""Install/remove the narrowly scoped CPU fan service. No hardware commands here."""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import time

LABEL = 'com.hermanzhaozzzz.LiquidBar.FanControl'
PRODUCT = 'LiquidBarFanControlDaemon'
SERVICE = 'system/' + LABEL
BASE = Path('/Library/Application Support/LiquidBar/FanControl')
CONFIG = BASE / 'config.json'
HELPER = Path('/Library/PrivilegedHelperTools') / LABEL
PLIST = Path('/Library/LaunchDaemons') / (LABEL + '.plist')
LOG = Path('/Library/Logs/LiquidBarFanControl.log')
BACKUPS = BASE / 'backups'
GUI = Path('/Applications/LiquidBar.app')
REPO = Path(__file__).resolve().parent.parent
PACKAGE = REPO / 'dist/FanControlService'
HEX40 = re.compile(r'[0-9a-f]{40}')
IN_APP = False


def run(arguments, check=True):
    result = subprocess.run(arguments, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                            text=True, timeout=30)
    if check and result.returncode:
        raise RuntimeError(result.stderr.strip() or result.stdout.strip() or str(arguments))
    return result


def require_root():
    if os.geteuid() != 0:
        raise RuntimeError('Run this command with sudo after reviewing the installation package.')


def trusted(path, directory=False):
    info = path.lstat()
    if stat.S_ISLNK(info.st_mode) or info.st_uid != 0 or info.st_mode & 0o022:
        raise RuntimeError('Unsafe ownership, permissions, or symlink: ' + str(path))
    expected = stat.S_ISDIR if directory else stat.S_ISREG
    if not expected(info.st_mode):
        raise RuntimeError('Unexpected filesystem object: ' + str(path))


def directory(path, mode=0o755):
    if path == path.parent:
        trusted(path, True)
        return
    directory(path.parent)
    if not path.exists() and not path.is_symlink():
        path.mkdir(mode=mode)
        os.chown(path, 0, 0)
    trusted(path, True)


def check_destination(path):
    directory(path.parent)
    if path.exists() or path.is_symlink():
        trusted(path)


def copy_regular(source, target, limit=64 * 1024 * 1024):
    """Copy through one no-follow fd into a private root-owned staging directory."""
    descriptor = os.open(source, os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(descriptor, 'rb') as incoming:
        info = os.fstat(incoming.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_size > limit:
            raise RuntimeError('Invalid payload file: ' + str(source))
        with target.open('xb') as outgoing:
            remaining = info.st_size
            while remaining:
                chunk = incoming.read(min(1024 * 1024, remaining))
                if not chunk:
                    raise RuntimeError('Payload changed while copying: ' + str(source))
                outgoing.write(chunk)
                remaining -= len(chunk)
            if incoming.read(1):
                raise RuntimeError('Payload grew while copying: ' + str(source))
            outgoing.flush()
            os.fsync(outgoing.fileno())
    target.chmod(0o600)


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def signature(path):
    run(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(path)])
    result = run(['/usr/bin/codesign', '-d', '--verbose=4', str(path)])
    details = result.stdout + result.stderr
    digest = re.search(r'^CDHash=([0-9a-fA-F]{40})$', details, re.MULTILINE)
    flags = re.search(r'^CodeDirectory .*flags=.*\(.*runtime.*\)', details, re.MULTILINE)
    if not digest or not flags:
        raise RuntimeError('Missing exact CDHash or hardened runtime: ' + str(path))
    result = run(['/usr/bin/codesign', '-d', '--entitlements', ':-', str(path)])
    if result.stdout.strip():
        entitlements = plistlib.loads(result.stdout.encode())
        if entitlements:
            raise RuntimeError('The service and GUI must have no entitlement exemptions: ' + str(path))
    return digest.group(1).lower()


def manifest_at(package):
    data = json.loads((package / 'manifest.json').read_text())
    required = {'protocolVersion', 'authorizationScope', 'label', 'product', 'version', 'build', 'guiCDHash',
                'daemonCDHash', 'guiBinarySHA256', 'daemonSHA256', 'cpuIndex', 'chipID',
                'driverVersion'}
    if set(data) != required or data['protocolVersion'] != 1 or data['label'] != LABEL:
        raise RuntimeError('Unexpected service manifest.')
    if data['authorizationScope'] != 'user-account':
        raise RuntimeError('This package must declare the explicitly accepted user-account scope.')
    if (data['product'], data['cpuIndex'], data['chipID'], data['driverVersion']) != (PRODUCT, 1, 54315, '0.7.2'):
        raise RuntimeError('The package is not for the verified CPU header/driver.')
    for key in ('guiCDHash', 'daemonCDHash'):
        if not isinstance(data[key], str) or not HEX40.fullmatch(data[key]):
            raise RuntimeError('Invalid signature pin in manifest.')
    for key in ('guiBinarySHA256', 'daemonSHA256'):
        if not isinstance(data[key], str) or not re.fullmatch(r'[0-9a-f]{64}', data[key]):
            raise RuntimeError('Invalid file digest in manifest.')
    return data


def write_manifest(package, gui):
    """Build the pin file from the installed GUI and the reviewed daemon.

    The app bundles this daemon without a pre-generated manifest because the
    manifest pins the app's own CDHash; writing it before signing would change
    that hash. Installation therefore derives it from the exact files present.
    """
    info = plistlib.loads((gui / 'Contents/Info.plist').read_bytes())
    product = package / PRODUCT
    data = {
        'protocolVersion': 1,
        'authorizationScope': 'user-account',
        'label': LABEL,
        'product': PRODUCT,
        'version': info['CFBundleShortVersionString'],
        'build': info['CFBundleVersion'],
        'guiCDHash': signature(gui),
        'daemonCDHash': signature(product),
        'guiBinarySHA256': sha256(gui / 'Contents/MacOS/LiquidBar'),
        'daemonSHA256': sha256(product),
        'cpuIndex': 1,
        'chipID': 54315,
        'driverVersion': '0.7.2',
    }
    destination = package / 'manifest.json'
    destination.write_text(json.dumps(data, indent=2) + '\n')
    destination.chmod(0o600)
    return data


def verify_package(package, gui):
    data = manifest_at(package)
    if signature(package / PRODUCT) != data['daemonCDHash'] or sha256(package / PRODUCT) != data['daemonSHA256']:
        raise RuntimeError('Daemon signature/digest does not match the manifest.')
    if signature(gui) != data['guiCDHash'] or sha256(gui / 'Contents/MacOS/LiquidBar') != data['guiBinarySHA256']:
        raise RuntimeError('Install the matching LiquidBar.app before installing this service.')
    return data


def login_uid():
    console = os.stat('/dev/console').st_uid
    requested = int(os.environ.get('SUDO_UID', str(console)))
    if console < 501 or requested != console:
        raise RuntimeError('Install from the currently logged-in user account with sudo.')
    return console


def require_gui_stopped():
    rows = run(['/bin/ps', '-axo', 'pid=,command=']).stdout.splitlines()
    running = []
    for row in rows:
        fields = row.strip().split(None, 1)
        if len(fields) != 2:
            continue
        command = fields[1]
        if (command.startswith(str(GUI / 'Contents/MacOS/LiquidBar'))
                or str(GUI / 'Contents/Resources/device_helper.py') in command):
            running.append(fields[0])
    if running:
        raise RuntimeError('Quit LiquidBar normally and wait for its helpers before this operation. Running PIDs: '
                           + ', '.join(running))


def state():
    result = run(['/bin/launchctl', 'print', SERVICE], check=False)
    if result.returncode:
        if 'Could not find service' in result.stderr:
            return None
        raise RuntimeError('Cannot inspect the existing service: ' + result.stderr.strip())
    pid = re.search(r'^\s*pid = (\d+)\s*$', result.stdout, re.MULTILINE)
    code = re.search(r'^\s*last exit code = (-?\d+)\s*$', result.stdout, re.MULTILINE)
    terminating_signal = re.search(r'^\s*last terminating signal = (.+)$', result.stdout, re.MULTILINE)
    runs = re.search(r'^\s*runs = (\d+)\s*$', result.stdout, re.MULTILINE)
    lifecycle = re.search(r'^\s*state = (.+)$', result.stdout, re.MULTILINE)
    return {'pid': int(pid.group(1)) if pid else None,
            'exit': int(code.group(1)) if code else None,
            'signal': terminating_signal.group(1).strip() if terminating_signal else None,
            'runs': int(runs.group(1)) if runs else None,
            'state': lifecycle.group(1).strip() if lifecycle else None}


def disabled():
    text = run(['/bin/launchctl', 'print-disabled', 'system']).stdout
    return bool(re.search(r'"' + re.escape(LABEL) + r'"\s*=>\s*true', text))


def stop_service():
    current = state()
    if current is None:
        return
    was_disabled = disabled()
    run(['/bin/launchctl', 'disable', SERVICE])
    try:
        current = state()
        if current is None:
            return
        if current['pid'] is not None:
            trusted(LOG)
            log_info = LOG.stat()
            offset = log_info.st_size
            pid = current['pid']
            run(['/bin/launchctl', 'kill', 'SIGTERM', SERVICE])
            deadline = time.monotonic() + 25
            receipt = None
            while time.monotonic() < deadline:
                trusted(LOG)
                if LOG.stat().st_ino != log_info.st_ino or LOG.stat().st_size < offset:
                    raise RuntimeError('Service log changed during shutdown; restoration unconfirmed.')
                with LOG.open() as stream:
                    stream.seek(offset)
                    for line in stream:
                        try:
                            item = json.loads(line)
                        except ValueError:
                            continue
                        if item.get('event') == 'stopped' and item.get('pid') == pid:
                            receipt = item
                current = state()
                if receipt and receipt.get('restored') is not True:
                    raise RuntimeError('The service could not restore CPU automatic control.')
                if current is None:
                    raise RuntimeError('Service disappeared before shutdown could be verified.')
                if current['pid'] not in (None, pid):
                    raise RuntimeError('Service restarted during shutdown; refusing replacement.')
                if current['pid'] is None:
                    if (receipt and receipt.get('restored') is True and current['exit'] == 0
                            and current['signal'] is None and current['state'] == 'not running'):
                        break
                    # Older daemons predate the structured receipt but still exit
                    # zero only after restoring automatic control. The app has
                    # already suspended fan control and the user authorized this.
                    if (IN_APP and current['exit'] == 0 and current['signal'] is None
                            and current['state'] == 'not running'):
                        print('WARNING: previous service exited cleanly without a receipt; continuing in-app install.',
                              flush=True)
                        break
                    raise RuntimeError('Clean exit and current-instance restoration receipt were not both confirmed.')
                time.sleep(0.2)
            else:
                raise RuntimeError('Timed out waiting for restoration. No forced termination was used.')
        elif (current['signal'] is not None
              or current['state'] not in ('not running', 'waiting')
              or not (current['exit'] == 0 or current['runs'] == 0)):
            raise RuntimeError('No verified clean exit or never-run state; inspect restoration before replacing the service.')
        run(['/bin/launchctl', 'bootout', SERVICE])
        if state() is not None:
            raise RuntimeError('Service is still loaded; refusing replacement.')
    except BaseException:
        run(['/bin/launchctl', 'disable' if was_disabled else 'enable', SERVICE], check=False)
        raise


def publish(source, destination, mode):
    check_destination(destination)
    descriptor, name = tempfile.mkstemp(prefix='.' + destination.name + '.', dir=destination.parent)
    temporary = Path(name)
    try:
        with os.fdopen(descriptor, 'wb') as stream:
            stream.write(source.read_bytes())
            stream.flush()
            os.fsync(stream.fileno())
        os.chown(temporary, 0, 0)
        temporary.chmod(mode)
        os.replace(temporary, destination)
    finally:
        if temporary.exists():
            temporary.unlink()


def backup_existing():
    paths = {'helper': HELPER, 'config.json': CONFIG, 'launchdaemon.plist': PLIST}
    present = [path.exists() or path.is_symlink() for path in paths.values()]
    if not any(present):
        return None
    if not all(present):
        raise RuntimeError('Partial existing installation; refusing to overwrite it.')
    directory(BACKUPS, 0o700)
    target = Path(tempfile.mkdtemp(prefix=datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%SZ-'), dir=BACKUPS))
    for name, source in paths.items():
        trusted(source)
        copy_regular(source, target / name)
    (target / 'helper').chmod(0o700)
    print('ROLLBACK_BACKUP=' + str(target), flush=True)
    return target


def start_service():
    run(['/bin/launchctl', 'enable', SERVICE])
    run(['/bin/launchctl', 'bootstrap', 'system', str(PLIST)])
    time.sleep(1)
    current = state()
    if current is None or current['pid'] is None:
        raise RuntimeError('Service did not remain running. Keep the backup and inspect its log before retrying.')


def validate_config(data):
    keys = {'protocolVersion', 'authorizationScope', 'allowedUID', 'guiRequirement', 'daemonRequirement', 'cpuIndex', 'chipID', 'driverVersion'}
    if set(data) != keys or (data['protocolVersion'], data['cpuIndex'], data['chipID'], data['driverVersion']) != (1, 1, 54315, '0.7.2'):
        raise RuntimeError('Unexpected service configuration.')
    if data['authorizationScope'] != 'user-account':
        raise RuntimeError('The configuration must explicitly authorize the user-account scope.')
    if data['allowedUID'] != login_uid():
        raise RuntimeError('The service belongs to another logged-in UID.')
    for key in ('guiRequirement', 'daemonRequirement'):
        if not isinstance(data[key], str) or not re.fullmatch(r'cdhash H"[0-9a-f]{40}"', data[key]):
            raise RuntimeError('Invalid exact code-signature requirement.')


def install():
    require_root()
    if IN_APP:
        print('In-app install: the GUI is running with fan control suspended.')
    else:
        require_gui_stopped()
    directory(BASE)
    for path in (HELPER, CONFIG, PLIST, LOG):
        check_destination(path)
    with tempfile.TemporaryDirectory(prefix='.stage-', dir=BASE) as staging:
        stage = Path(staging)
        copy_regular(PACKAGE / PRODUCT, stage / PRODUCT)
        (stage / PRODUCT).chmod(0o700)
        manifest = PACKAGE / 'manifest.json'
        if manifest.exists():
            copy_regular(manifest, stage / 'manifest.json', 65536)
        else:
            write_manifest(stage, GUI)
        data = verify_package(stage, GUI)
        config = {'protocolVersion': 1, 'authorizationScope': 'user-account', 'allowedUID': login_uid(),
                  'guiRequirement': 'cdhash H"' + data['guiCDHash'] + '"',
                  'daemonRequirement': 'cdhash H"' + data['daemonCDHash'] + '"',
                  'cpuIndex': 1, 'chipID': 54315, 'driverVersion': '0.7.2'}
        validate_config(config)
        (stage / 'config.json').write_text(json.dumps(config, indent=2) + '\n')
        plist = {'Label': LABEL, 'ProgramArguments': [str(HELPER)], 'MachServices': {LABEL: True},
                 'RunAtLoad': True, 'KeepAlive': {'SuccessfulExit': False}, 'ExitTimeOut': 20,
                 'ThrottleInterval': 10, 'UserName': 'root', 'GroupName': 'wheel', 'Umask': 0o077}
        (stage / 'launchdaemon.plist').write_bytes(plistlib.dumps(plist))
        backup_existing()
        stop_service()
        publish(stage / PRODUCT, HELPER, 0o755)
        publish(stage / 'config.json', CONFIG, 0o644)
        publish(stage / 'launchdaemon.plist', PLIST, 0o644)
        start_service()
        print('Installed account-scoped, fixed CPU_FAN service for UID ' + str(config['allowedUID']))


def uninstall():
    require_root()
    require_gui_stopped()
    for path in (HELPER, CONFIG, PLIST, LOG):
        check_destination(path)
    backup_existing()
    stop_service()
    for path in (PLIST, HELPER, CONFIG):
        if path.exists():
            trusted(path)
            path.unlink()
    print('Service removed after normal restoration; backups and logs retained.')


def rollback(name):
    require_root()
    require_gui_stopped()
    if not re.fullmatch(r'[A-Za-z0-9_-]+', name):
        raise RuntimeError('Use only the backup directory name printed by installation.')
    source = BACKUPS / name
    directory(BACKUPS, 0o700)
    trusted(source, True)
    for filename in ('helper', 'config.json', 'launchdaemon.plist'):
        trusted(source / filename)
    config = json.loads((source / 'config.json').read_text())
    validate_config(config)
    if signature(GUI) != config['guiRequirement'][9:-1]:
        raise RuntimeError('Restore the matching earlier GUI app before rolling back this service.')
    if signature(source / 'helper') != config['daemonRequirement'][9:-1]:
        raise RuntimeError('Backup daemon signature does not match its pinned configuration.')
    expected_plist = plistlib.loads((source / 'launchdaemon.plist').read_bytes())
    if expected_plist.get('Label') != LABEL or expected_plist.get('ProgramArguments') != [str(HELPER)]:
        raise RuntimeError('Unexpected launch daemon in backup.')
    backup_existing()
    stop_service()
    publish(source / 'helper', HELPER, 0o755)
    publish(source / 'config.json', CONFIG, 0o644)
    publish(source / 'launchdaemon.plist', PLIST, 0o644)
    start_service()
    print('Rolled back service from ' + str(source))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['check-package', 'install', 'uninstall', 'rollback'])
    parser.add_argument('backup', nargs='?')
    parser.add_argument('--package', help='Directory containing the daemon and manifest.json')
    parser.add_argument('--gui', help='Path to the installed LiquidBar.app')
    parser.add_argument('--in-app', action='store_true',
                        help='The app has suspended fan control; allow the GUI process to stay running.')
    parser.add_argument('--account-scoped', action='store_true',
                        help='Explicitly accept that other programs under this UID may use the limited CPU fan capability.')
    args = parser.parse_args()
    global PACKAGE, GUI, IN_APP
    if args.package:
        PACKAGE = Path(args.package).resolve()
    if args.gui:
        GUI = Path(args.gui).resolve()
    IN_APP = args.in_app
    if args.action in ('install', 'rollback') and not args.account_scoped:
        parser.error('install/rollback require --account-scoped: process isolation is not guaranteed on this system')
    try:
        if args.action == 'check-package':
            data = verify_package(PACKAGE, REPO / 'dist/LiquidBar.app')
            print(json.dumps(data, indent=2))
        elif args.action == 'install':
            install()
        elif args.action == 'uninstall':
            uninstall()
        elif args.backup:
            rollback(args.backup)
        else:
            parser.error('rollback requires the root-owned backup directory name')
    except (RuntimeError, OSError, ValueError, subprocess.TimeoutExpired) as error:
        print('ERROR: ' + str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
