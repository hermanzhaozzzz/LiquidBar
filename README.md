# LiquidBar

[简体中文](README.zh-CN.md)

LiquidBar is a small native macOS menu-bar monitor and controller for a tested
Hackintosh + NZXT cooling setup. It prioritizes low overhead, predictable
hardware access, and a single-level interface inspired by the clarity of iStat
Menus.

> Version 0.1.0 is tested only on the hardware listed below. The architecture is
> extensible, but other Macs and liquidctl devices are not currently supported.

## Tested setup

- macOS 15.2, x86_64 Hackintosh
- AMD Ryzen 9 3900X with VirtualSMC + SMCAMDProcessor
- NZXT Kraken X53/X63/X73 (`1e71:2007`)
- NZXT Smart Device V2 (`1e71:2006`)
- Related EFI configuration:
  [My-Opencore-EFI-for-AMD3900X-5700XT-TUF-x570-Hackintosh](https://github.com/hermanzhaozzzz/My-Opencore-EFI-for-AMD3900X-5700XT-TUF-x570-Hackintosh)

## Features

- Compact `CPU 52°  F 810  P 2158` menu-bar status
- CPU temperature from VirtualSMC and coolant/fan/pump data from liquidctl
- Independent Fan 1/2/3 and pump sliders with safe minimums
- Linked-fan mode and Quiet, Daily, Performance, and Full presets
- Optional fan identification and naming
- 15-minute, 1-hour, 6-hour, and 24-hour temperature charts
- Rolling 24-hour local history
- Optional macOS notifications and full-speed thermal protection
- Silent launch at login, wake recovery, and device reconnect handling
- Chinese and English UI following the macOS language
- No telemetry, analytics, automatic network access, or auto-update service

## Requirements

- macOS 13 or later
- Swift 5.10 or later (Apple Command Line Tools are sufficient)
- Homebrew liquidctl 1.16 or later:

```bash
brew install liquidctl
liquidctl list
```

The app locates liquidctl under `/usr/local/opt/liquidctl` and
`/opt/homebrew/opt/liquidctl`. It does not download or install dependencies.

## Build locally

```bash
git clone https://github.com/hermanzhaozzzz/LiquidBar.git
cd LiquidBar
swift test
./scripts/build_app.sh
```

The app bundle is written to `dist/LiquidBar.app` and ad-hoc signed for local
use. No public binary is shipped in version 0.1.0 because the project does not
yet use a Developer ID certificate.

Install and launch it:

```bash
./scripts/install_app.sh
```

The install script targets `/Applications/LiquidBar.app`. macOS may ask you to
approve the login item or notification permission in System Settings.

## Development

```bash
swift build
swift test
python3 -m py_compile Resources/device_helper.py
```

With the computer attended, contributors working on the exact tested hardware
can run the reversible hardware test. It raises duties by 5 percentage points
for four seconds and verifies restoration:

```bash
/usr/local/opt/liquidctl/libexec/bin/python scripts/hardware_smoke_test.py
```

The native AppKit/SwiftUI process owns the menu bar and reads the CPU sensor.
A single persistent Python helper imports the user's Homebrew liquidctl package
and serializes all HID access over a JSON-lines pipe. Slider writes occur only
when dragging ends. Device polling is 5 seconds in the background and 2 seconds
while the popover is open.

Configuration, logs, and the rolling history live under
`~/Library/Application Support/LiquidBar/`.

## License

Copyright © 2026 Huanan Zhao `<hermanzhaozzzz@gmail.com>`.

LiquidBar is free software licensed under
[GPL-3.0-or-later](LICENSE). See [NOTICE.md](NOTICE.md) for third-party notices.
