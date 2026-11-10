# LiquidBar

[English](README.md)

LiquidBar 是原生 macOS 菜单栏监控与控制工具，分别识别散热、灯光和数显设备。
不要求 Kraken 存在，Smart Device V2 可以独立工作。

## 设备接口

| 接口 | 已实现功能 | 限制 |
| --- | --- | --- |
| NZXT Smart Device V2（`1e71:2006`） | 三路调速、RPM/占空比、预设、CPU 温度曲线、HUE2 灯光 | 分线器共享一路；风扇可能在转却没有测速；灯光需另外连接兼容的 NZXT RGB 配件。 |
| NZXT Kraken X53/X63/X73（`1e71:2007`） | 水温、水泵控制 | 可选设备，缺失不阻断其他设备。 |
| ASUS AURA USB（`0b05:18f3`、`1939`、`19af`） | 固定色、颜色亮度、关闭、呼吸、彩虹 | `18f3` 根据设备配置表定位板载/ARGB 通道；其他型号走 liquidctl，其动态/关闭操作可能影响全部通道。不能保证与 NZXT 动画相位同步。 |
| DeepCool LD-Series（`3633:000a`） | CPU 温度、使用率、功耗数显，摄氏/华氏切换 | 数字字段，不支持任意图片/GIF；需要有效传感器数据和持续更新。实测设备停止更新后会超时黑屏，这不是应用发送了屏幕断电指令。 |
| AMD GPU IORegistry `PerformanceStatistics` | GPU 温度、一组风扇 RPM/驱动报告比例、功耗和温度历史 | 仅读取；本机蓝宝石 RX 5700 XT 超白金特别版已提供这些指标。缺失显示不可用，有效零值保留；不写显卡转速，也不能区分每只实体风扇。 |
| AMDRyzenCPUPowerManagement **0.7.2** | CPU 指标、实验性 NCT67xx 主板风扇读写 | 需要主动检测、确认实体插座映射和驱动授权；通用标签不代表实际插座。 |

以上是实现范围，不表示每种型号、插座和接线组合都通过实机验收。
开发机器为 Ryzen 9 3900X / ASUS TUF Gaming X570-PLUS，已识别 NCT6798D。
三针水泵需要主板 DC 配置；写入占空比成功不等于实际转速变化。
LiquidBar 不修改 BIOS 的 PWM/DC 模式。

## 使用方式

- 设置中的“菜单栏温度显示”可选 CPU、GPU 或 CPU + GPU；旧配置默认仍仅显示 CPU。
  GPU 数据缺失或过期时显示 `GPU --°`，可选水温显示保持独立。切换显示不会改变
  风扇目标、温度曲线或现有 CPU/冷却液告警规则。
- 菜单栏用芯片/显卡图标标识温度，每个传感器分别着色：正常青色、偏高橙色、
  高温红色，未知值灰色。CPU/水温采用已设置阈值；GPU 的 70°C/85°C 仅用于
  显示参考，不新增显卡告警或调速。浅色和深色外观使用各自的配色。

- CPU 采样和 24 小时历史独立于 USB 设备和主板授权窗口。没有水温传感器时，
  不使用 CPU 温度冒充水温。
- 设置 → 通用 → 采样频率提供流畅、标准（默认）、省电三档：CPU/GPU 分别每
  1、2、4 秒采样；USB 设备在面板打开时每 1/2/3 秒、关闭时每 3/5/6 秒轮询。
  历史固定每 5 秒记录。省电档减少唤醒，但菜单栏和告警会延迟。
- 主风扇面板显示 GPU 温度与风扇反馈，独立于 USB 和主板授权采样；GPU 温度也
  记录到趋势历史。显卡风扇一栏目前仅监控，没有已验证可恢复自动模式的 macOS
  调速接口；驱动报告的百分比不标成 PWM 占空比，GPU 温度尚未纳入 Smart 曲线。
- 界面分开显示目标值和实测 RPM/占空比。手动预设会关闭 Smart 温度曲线。
  曲线由运行中的软件计算，不会下载为控制器自主运行的曲线。
- 每个可控散热行显示当前模式。拖动滑条会把该通道切到手动；冷排拨杆恢复主板
  自动控制，水泵拨杆使用 Kraken 的冷却液硬件曲线。三路 NZXT 风扇共用同一条
  软件 CPU 曲线，所以它们的自动开关是组级的。显卡风扇保持只读，因为 macOS
  没有已验证可恢复的写入接口。
- 启用 Smart 曲线后，辅助进程要求在 15 秒内收到更新；失去更新、主进程管道
  关闭或正常结束时，会尝试将三路风扇设为全速。单独关闭曲线会把当前曲线占空比
  冻结为手动目标，只有写入未确认时才回退全速；选择手动预设则应用该预设目标。
  USB 故障、驱动卡死或强杀辅助进程可能使保底指令无法执行，因此仍需实机验证。
- 灯光入口位于设置页。设置 → 灯光 → **在面板显示颜色分组** 会把菜单栏面板
  展开为两栏：左侧调速与状态，右侧全部灯光颜色分组。修改后自动应用；右栏顶部
  的“所有灯光”卡会一次改到所有灯光组，之后仍可按组微调；只有一个通道的分组
  不显示“所有通道”。水冷 ARGB 接主板对应的
  5V ARGB 插座；普通 ARGB 不能直接接到 NZXT 专用灯光接口。
- 主板风扇默认保持固件控制。主面板的“冷排风扇”滑条独立调节已确认的
  CPU_FAN（30–100%），显示实测 RPM、占空比和自动/手动状态，并可恢复主板
  自动控制。CPU 通道的确认不会同时启用水泵控制；驱动授权窗口可选择允许至
  辅助进程退出。顶部预设会同时下发已核实的 CPU_FAN 冷排目标；软件 Smart 温度
  曲线仍只覆盖 NZXT 风扇。预设不改变水泵。
- 独立主板辅助进程记录自己接管的通道；应用退出、失去心跳或管道关闭时，
  尝试恢复之前的控制状态，并报告恢复失败。内核崩溃、断电以及直接用 SIGKILL
  杀死该辅助进程不在这个恢复保证内。
- 保留中英文界面、登录启动、唤醒恢复和可选温度告警。没有遥测或自动联网。

## 依赖与构建

- macOS 13 或更新版本、Swift 5.10 或更新版本。
- Homebrew liquidctl 1.16 或更新版本：`brew install liquidctl`。
- 测试环境通过 VirtualSMC/SMCAMDProcessor 提供 CPU 温度；主板风扇控制要求
  上述 AMDRyzenCPUPowerManagement 版本的接口。

```bash
swift test
/usr/local/opt/liquidctl/libexec/bin/python -m unittest discover -s Tests/Python
./scripts/build_dmg.sh
```

Apple Silicon 的 Python 路径使用 `/opt/homebrew/opt/liquidctl/libexec/bin/`。
应用寻找两个 Homebrew 前缀，不会自动安装依赖。
`dist/LiquidBar.app` 使用本地 ad-hoc 签名，没有 Developer ID 公证。

## 安装

打开 `dist/LiquidBar-<版本>.dmg`，把 **LiquidBar.app** 拖入“应用程序”后启动。
升级时请先从菜单正常退出正在运行的 LiquidBar，并等待其辅助进程结束。
由于是 ad-hoc 签名，Gatekeeper 可能要求在“系统设置 → 隐私与安全性”中点击
“仍要打开”。

首次启动会打开设置向导：检查 liquidctl、CPU 温度传感器、显卡与已连接设备，
再请求通知权限并注册登录项。之后可从 **设置 → 设置向导** 重新打开。配置、
日志和历史保存在 `~/Library/Application Support/LiquidBar/`，升级前请备份。

开发时仍可用 `./scripts/install_app.sh` 把 `dist/LiquidBar.app` 复制到
`/Applications` 并启动。

## 可选的持久 CPU 风扇服务

本机可以安装一个专用 LaunchDaemon，使冷排滑条在应用或电脑重启后无需再次
选择“Until Process Terminate”。首次安装需要管理员权限；服务仅开放已验证的
CPU_FAN 索引 1（NCT6798D `0xD42B`、驱动 0.7.2），不控制水泵或芯片组风扇。
这不是通用主板服务，不能直接用于未经验证的插座映射。

服务按当前登录账户授权：同一 UID 的其他程序也可能使用这项受限的风扇能力。
本机实测中，带 hardened runtime 标志的候选程序仍能被注入并通过精确代码签名
检查，因此静态签名验证不能证明进程隔离。安装必须显式接受账户范围；服务仍
固定限制为 CPU_FAN 的 30–100% 与恢复自动控制，不提供任意 root 命令、文件
写入或驱动 selector 接口，也不修改 EFI。

应用包内已经包含同一构建的风扇服务组件。请在 **设置 → 主板 → 安装/更新风扇服务**
中操作：LiquidBar 会先退出并恢复风扇自动控制，随后 macOS 请求管理员权限；
服务安装完成后应用会自动重新打开。不需要在应用外运行任何脚本。

仓库开发时仍可使用等价命令：

```bash
sudo ./scripts/install_fan_service.sh --account-scoped
```

应用被另一个构建替换后，已安装服务绑定的是旧代码哈希，设置 → 主板会显示
**需要更新**。应用还会同时比对运行进程、磁盘 App 与服务要求的签名：如果 App
在运行期间被替换，会显示 **需要重启** 并直接提供重启动作，而不是原始签名错误。
启动时的权限自检只会请求一次；服务不会自动接受新版本的签名。

GUI 与服务保留 hardened runtime 和精确代码签名检查作为附加约束。安装时将
当前登录 UID、两个签名和 `authorizationScope: "user-account"` 写入仅 root
可修改的配置。升级应用改变签名后，需要再次运行服务安装脚本；
服务不会自动接受任意新版本的签名。安装的内容为：

- `/Library/PrivilegedHelperTools/com.hermanzhaozzzz.LiquidBar.FanControl`
- `/Library/LaunchDaemons/com.hermanzhaozzzz.LiquidBar.FanControl.plist`
- `/Library/Application Support/LiquidBar/FanControl/config.json`
- 日志：`/Library/Logs/LiquidBarFanControl.log`

免重复授权不代表永久维持手动转速：客户端断开、15 秒租约超时或温度保护触发时，
服务恢复主板自动控制。安装、升级和卸载会先等待正常恢复证明；失败时停止操作，
不强杀服务。安装、卸载及回滚脚本都会拒绝在 GUI 或其辅助进程仍运行时操作。
移除服务时保留日志与回滚备份：

```bash
sudo ./scripts/uninstall_fan_service.sh
```

升级前会输出 root 管理的备份目录。需要回滚时，先恢复与备份签名匹配的旧 GUI，
再将该目录的名称传给 `sudo ./scripts/rollback_fan_service.sh BACKUP_NAME --account-scoped`。

## 实机验证

仅读取 GPU 指标，不打开界面、不改变散热设置：

```bash
/Applications/LiquidBar.app/Contents/MacOS/LiquidBar --gpu-status
```

默认诊断仅读取状态；Smart 初始化用于启用状态报告：

```bash
/usr/local/opt/liquidctl/libexec/bin/python scripts/hardware_smoke_test.py
```

有人看护时，可对选定的 Smart 通道提速 5 个百分点，然后恢复并核对原占空比。
测试前退出其他访问该控制器的程序：

```bash
/usr/local/opt/liquidctl/libexec/bin/python scripts/hardware_smoke_test.py --write --channels 1 2
```

没有测速反馈但实际在转的风扇，需要单独指定一路并添加 `--observe-missing-tach`。
占空比读回不代表物理转速已经变化。灯光颜色、屏幕内容、实体插座映射和睡眠唤醒
需要分别实测，模拟测试和构建成功不能代替这些验收。

## 许可证

Copyright © 2026 Huanan Zhao。[GPL-3.0-or-later](LICENSE)。
第三方来源与声明见 [NOTICE.md](NOTICE.md)。
