# LiquidBar

[简体中文](README.zh-CN.md)

LiquidBar is a native macOS menu-bar monitor and controller for individually
detected cooling, lighting, and numeric-display devices. A Kraken is not
required to use a Smart Device V2.

## Device interfaces

| Interface | Available functions | Limits |
| --- | --- | --- |
| NZXT Smart Device V2 (`1e71:2006`) | Three fan channels, RPM/duty, presets, CPU temperature curve, HUE2 lighting | Splitters share a channel. A spinning fan can lack tach feedback. Lighting needs compatible accessories on the RGB ports. |
| NZXT Kraken X53/X63/X73 (`1e71:2007`) | Coolant temperature and pump control | Optional; absence does not block other devices. |
| ASUS AURA USB (`0b05:18f3`, `1939`, `19af`) | Fixed color, brightness-scaled color, off, breathing, rainbow | `18f3` uses configuration-derived mainboard/ARGB channels. Other models use liquidctl, whose dynamic/off commands may affect all channels. Animation phase is not guaranteed to match NZXT. |
| DeepCool LD-Series (`3633:000a`) | CPU temperature, utilization and power; °C/°F | Numeric fields, not images/GIFs. Requires valid telemetry and ongoing updates. The tested unit goes dark after updates stop; this is its timeout behavior, not a screen power-off command. |
| AMD GPU IORegistry `PerformanceStatistics` | GPU temperature, one aggregate fan RPM/driver-reported percentage, power and temperature history | Read-only; tested with the Sapphire NITRO+ RX 5700 XT SE. Missing metrics stay unavailable and valid zero readings remain zero. No GPU fan-speed writes or per-physical-fan readings. |
| AMDRyzenCPUPowerManagement **0.7.2** | CPU metrics and experimental NCT67xx motherboard fan control | Requires explicit detection, physical header mapping and driver authorization. Generic labels do not prove header locations. |

These are implemented interfaces, not universal hardware validation. The current
development machine is a Ryzen 9 3900X / ASUS TUF Gaming X570-PLUS Hackintosh
with NCT6798D. Three-pin pump control requires the motherboard's DC configuration;
a duty write alone does not prove physical speed changed. LiquidBar does not
change the BIOS PWM/DC mode.

## Operation

- In Settings, choose CPU, GPU, or CPU + GPU for the menu-bar temperatures.
  Older settings keep CPU-only display. Missing/stale GPU data shows `GPU --°`;
  the optional coolant display remains separate. This display choice does not
  change fan targets, temperature curves, or CPU/coolant alert rules.
- Menu-bar temperatures use CPU/graphics-card icons and independent sensor colors.
  Normal values are teal, warm values orange and hot values red; unavailable values
  are neutral. CPU/coolant colors use their configured thresholds. GPU colors use
  70°C/85°C as display references only, without adding GPU alerts or fan control.
  Both light and dark appearances have separate palettes.

- CPU sampling and 24-hour history are independent of USB and motherboard
  authorization. CPU data is never substituted for missing coolant temperature.
- Settings → General → Update frequency offers Smooth, Balanced (default) and
  Eco: CPU/GPU telemetry every 1, 2 or 4 seconds; USB devices every 1/2/3 seconds
  while the panel is open and 3/5/6 seconds while it is closed. History remains
  at 5 seconds. Eco reduces wakeups but adds menu-bar and alert latency.
- GPU temperature and fan feedback appear in the main fan panel and are sampled
  independently of USB and motherboard authorization. GPU temperature is also
  recorded in history. The GPU fan row is monitoring-only: no macOS fan write
  interface with verified automatic restoration is implemented. The reported
  percentage is not labelled PWM duty, and GPU data does not yet drive Smart curves.
- Targets and measured RPM/duty are separate. Manual presets disable the Smart
  CPU-temperature curve. This software curve is not uploaded to the controller
  as an autonomous curve.
- Each controllable cooling row shows its current mode. Dragging a slider switches
  that channel to manual. The radiator switch restores motherboard automatic
  control; the Kraken pump switch uses a hardware coolant-temperature curve. The
  three NZXT channels share the software CPU curve, so their auto switch is
  group-level. GPU fans stay monitoring-only because macOS has no verified
  restorable write interface.
- An armed Smart curve renews a 15-second helper lease. Lost updates, parent EOF
  or normal termination trigger a best-effort full-speed request on all three
  channels. Explicitly switching the curve off freezes the current curve duty as
  manual targets; only an unconfirmed write falls back to full speed. Manual
  presets instead apply their chosen targets. USB failure, a hung driver or a
  forcibly killed helper can prevent this fallback, so physical verification
  remains necessary.
- Lighting is configured in Settings. Settings → Lighting → **Show color groups
  in the panel** turns the menu-bar panel into two columns: speed and status on
  the left, all lighting color groups on the right. Changes apply automatically.
  The right column starts with an **All lighting** card that applies color,
  effect and brightness to every group; each group can then be adjusted
  separately. A group with a single channel does not offer “All channels”.
  Connect cooler ARGB to the
  appropriate motherboard 5 V ARGB header, not a proprietary NZXT lighting connector.
- Motherboard fans remain under existing firmware control by default. The main
  panel has a separate Radiator Fan slider for a confirmed CPU_FAN header
  (30–100%), with measured RPM/duty, automatic/manual state and a button to
  restore motherboard automatic control. Confirming the CPU header does not enable pump
  control. The driver can authorize access for the worker-process lifetime.
  Presets include the verified CPU_FAN radiator target; the software Smart
  temperature curve still covers only the NZXT fans. The Kraken pump is not
  changed by presets.
- An independent worker attempts to restore only the motherboard channels it
  overrides after app exit, lost heartbeat or pipe closure. Restoration failures
  are reported. This cannot cover kernel crashes, power loss or SIGKILL of the
  worker itself.
- Chinese/English UI, login startup, wake recovery and optional thermal alerts
  are available. There is no telemetry or automatic network access.

## Requirements and build

- macOS 13 or later; Swift 5.10 or later.
- Homebrew liquidctl 1.16 or later (`brew install liquidctl`).
- VirtualSMC/SMCAMDProcessor for the tested temperature path. Motherboard control
  requires the exact AMDRyzenCPUPowerManagement ABI listed above.

```bash
swift test
/usr/local/opt/liquidctl/libexec/bin/python -m unittest discover -s Tests/Python
./scripts/build_dmg.sh
```

On Apple Silicon use `/opt/homebrew/opt/liquidctl/libexec/bin/` for Python.
The app locates either prefix and does not install dependencies. The generated
`dist/LiquidBar.app` is ad-hoc signed for local use, not Developer-ID notarized.

## Install

Open `dist/LiquidBar-<version>.dmg`, drag **LiquidBar.app** to Applications and
launch it. When upgrading, quit the running LiquidBar from its menu first and
wait for its workers to finish. Gatekeeper may require System Settings →
Privacy & Security → “Open Anyway” for the ad-hoc signature.

On first launch the Setup Assistant checks liquidctl, the CPU temperature sensor,
the GPU and connected devices, then requests notification permission and the
login-item registration. It can be reopened from **Settings → Setup Assistant**
at any time. Settings, logs and history live in
`~/Library/Application Support/LiquidBar/`; back that directory up before an
upgrade.

For development, `./scripts/install_app.sh` copies `dist/LiquidBar.app` to
`/Applications` and launches it.

## Optional persistent CPU fan service

A dedicated LaunchDaemon can authorize the radiator slider across app and computer
restarts, without another “Until Process Terminate” prompt. Initial installation
requires administrator access. This build permits only the verified CPU_FAN index 1
on NCT6798D `0xD42B` with driver 0.7.2; it does not control the pump or chipset fan.
It is not a generic motherboard service for unverified header mappings.

Authorization covers the current login account: other programs under the same UID
may also use this limited fan capability. On this machine, a candidate carrying
hardened-runtime flags could still be injected while passing the exact code-hash
check. Static signature verification therefore does not prove process isolation.
Installation requires explicit acceptance of account scope. The service remains
limited to CPU_FAN at 30–100% and restoration of automatic control; it exposes no
arbitrary root command, file-write or driver-selector interface and does not change EFI.

The app carries the matching service package inside its bundle. Install or update
it from **Settings → Motherboard → Install/Update fan service**. LiquidBar quits,
restores automatic fan control, asks macOS for administrator rights, installs the
service and reopens itself. Nothing outside the app has to be run by hand.

For repository development the equivalent CLI remains:

```bash
sudo ./scripts/install_fan_service.sh --account-scoped
```

When LiquidBar is replaced by a different build, the installed service is pinned
to the old code hash and the app shows **Needs update**. The app also compares the
running process and the on-disk bundle against the service requirement: a stale
process after an in-place app replacement shows **Restart required** with a restart
action instead of a raw signature error. The launch permission check asks once;
upgrades are never accepted automatically.

The GUI and daemon retain hardened runtime and exact code-signature checks as
additional constraints. Installation records their signatures, the current login
UID and `authorizationScope: "user-account"` in root-owned configuration. After
an app upgrade changes its signature, run the service installer again; new version
signatures are not accepted automatically. Installed files are:

- `/Library/PrivilegedHelperTools/com.hermanzhaozzzz.LiquidBar.FanControl`
- `/Library/LaunchDaemons/com.hermanzhaozzzz.LiquidBar.FanControl.plist`
- `/Library/Application Support/LiquidBar/FanControl/config.json`
- Log: `/Library/Logs/LiquidBarFanControl.log`

Persistent authorization does not mean a permanent manual duty. Client disconnect,
a 15-second lease expiry or a temperature guard restores motherboard automatic
control. Upgrade and removal wait for verified normal restoration and stop on
failure without forcing termination. Installation, removal and rollback refuse to
proceed while the GUI or its workers are running. Removal retains logs and backups:

```bash
sudo ./scripts/uninstall_fan_service.sh
```

An upgrade prints the root-owned backup directory. For rollback, first restore
the older GUI matching that backup's signature, then pass the directory name to
`sudo ./scripts/rollback_fan_service.sh BACKUP_NAME --account-scoped`.

## Hardware checks

Read GPU telemetry without opening the GUI or changing cooling settings:

```bash
/Applications/LiquidBar.app/Contents/MacOS/LiquidBar --gpu-status
```

The default diagnostic reads status; Smart initialization enables reports:

```bash
/usr/local/opt/liquidctl/libexec/bin/python scripts/hardware_smoke_test.py
```

An attended test raises selected Smart channels by five percentage points, then
restores and checks original duties. Stop other controller-accessing apps first:

```bash
/usr/local/opt/liquidctl/libexec/bin/python scripts/hardware_smoke_test.py --write --channels 1 2
```

A spinning fan without tach feedback requires one explicitly selected channel
and `--observe-missing-tach`; duty readback is not proof of speed change. RGB
color, display content, header mapping and sleep/wake need separate physical
checks. Mock tests and successful builds do not replace those checks.

## License

Copyright © 2026 Huanan Zhao. [GPL-3.0-or-later](LICENSE).
See [NOTICE.md](NOTICE.md) for third-party sources and notices.
