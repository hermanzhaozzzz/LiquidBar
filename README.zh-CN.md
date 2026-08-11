# LiquidBar

[English](README.md)

LiquidBar 是一个轻量的原生 macOS 菜单栏工具，用于监控和控制已测试的
Hackintosh + NZXT 散热设备。它强调低占用、稳定的硬件访问和清晰的单层界面，
视觉信息密度参考 iStat Menus。

> 0.1.3 版本目前只测试了下列硬件。代码结构可以扩展，但暂不承诺支持其他 Mac
> 或 liquidctl 设备。

## 已测试环境

- macOS 15.2，x86_64 Hackintosh
- AMD Ryzen 9 3900X，VirtualSMC + SMCAMDProcessor
- NZXT Kraken X53/X63/X73（`1e71:2007`）
- NZXT Smart Device V2（`1e71:2006`）
- 相关 EFI 配置：
  [My-Opencore-EFI-for-AMD3900X-5700XT-TUF-x570-Hackintosh](https://github.com/hermanzhaozzzz/My-Opencore-EFI-for-AMD3900X-5700XT-TUF-x570-Hackintosh)

## 功能

- 菜单栏紧凑显示 `CPU 52°  F 810  P 2158`
- 通过 VirtualSMC 读取 CPU 温度，通过 liquidctl 读取水温和转速
- Fan 1/2/3 与水泵独立滑块，并带安全下限
- 三路风扇联动，以及安静、日常、性能、全速预设
- 可选的风扇识别与重命名
- 15 分钟、1 小时、6 小时、24 小时温度趋势图
- 本地滚动保存最近 24 小时历史
- 可选 macOS 通知和过热全速保护
- 登录静默启动、睡眠唤醒恢复和设备重连
- 中英文界面自动跟随 macOS 语言
- 不含遥测、分析、自动联网或自动更新服务

## 环境要求

- macOS 13 或更高版本
- Swift 5.10 或更高版本；Apple Command Line Tools 即可
- Homebrew liquidctl 1.16 或更高版本：

```bash
brew install liquidctl
liquidctl list
```

应用会在 `/usr/local/opt/liquidctl` 和 `/opt/homebrew/opt/liquidctl` 查找
liquidctl，不会自行下载或安装依赖。

## 本地构建

```bash
git clone https://github.com/hermanzhaozzzz/LiquidBar.git
cd LiquidBar
swift test
./scripts/build_app.sh
```

应用包生成在 `dist/LiquidBar.app`，并针对本地使用进行 ad-hoc 签名。项目目前
没有 Developer ID 证书，因此 0.1.3 不发布未经公证的公开二进制。

安装并启动：

```bash
./scripts/install_app.sh
```

安装目标为 `/Applications/LiquidBar.app`。macOS 可能要求你在“系统设置”中
批准登录项或通知权限。

## 开发

```bash
swift build
swift test
python3 -m py_compile Resources/device_helper.py
```

在有人看护且硬件与已测试配置完全相同时，可以运行可逆的真机测试。脚本会将转速
提高 5 个百分点并保持 4 秒，随后验证恢复结果：

```bash
/usr/local/opt/liquidctl/libexec/bin/python scripts/hardware_smoke_test.py
```

原生 AppKit/SwiftUI 进程负责菜单栏和 CPU 传感器读取。一个常驻 Python helper
导入用户通过 Homebrew 安装的 liquidctl，并通过 JSON Lines 管道串行处理全部 HID
访问。滑块只在拖动结束时写入设备。面板收起时每 5 秒轮询，展开时每 2 秒轮询。

配置、日志和滚动历史保存在
`~/Library/Application Support/LiquidBar/`。

## 许可证

Copyright © 2026 Huanan Zhao `<hermanzhaozzzz@gmail.com>`。

LiquidBar 根据 [GPL-3.0-or-later](LICENSE) 发布。第三方说明见
[NOTICE.md](NOTICE.md)。
