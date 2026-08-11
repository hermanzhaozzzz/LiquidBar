import Foundation

enum L10n {
    private static var isChinese: Bool {
        Locale.preferredLanguages.first?.lowercased().hasPrefix("zh") == true
    }

    private static let english: [String: String] = [
        "cpu": "CPU",
        "liquid": "Liquid",
        "pump": "Pump",
        "fans": "Fans",
        "fan": "Fan",
        "quiet": "Quiet",
        "daily": "Daily",
        "performance": "Performance",
        "full": "Full",
        "settings": "Settings…",
        "quit": "Quit LiquidBar",
        "offline": "Cooling devices offline",
        "linkedFans": "Link fans",
        "history": "Temperature history",
        "launchAtLogin": "Launch at login",
        "menuBar": "Menu Bar",
        "fanNames": "Fan names",
        "presets": "Presets",
        "alerts": "Overheat alerts",
        "systemNotifications": "System notifications",
        "criticalSound": "Sound for critical alerts",
        "automaticBoost": "Automatic full-speed protection",
        "cpuWarning": "CPU warning",
        "cpuCritical": "CPU critical",
        "liquidWarning": "Liquid warning",
        "liquidCritical": "Liquid critical",
        "diagnostics": "Data & Diagnostics",
        "copyDiagnostics": "Copy diagnostics",
        "clearLog": "Clear log",
        "identify": "Test",
        "loginNeedsApproval": "Login item needs approval in System Settings.",
        "openLoginItems": "Open Login Items",
        "notificationDenied": "Notifications are disabled in System Settings.",
        "openNotificationSettings": "Open Notification Settings",
        "helperMissing": "liquidctl is unavailable. Install it with Homebrew.",
        "deviceError": "Cooling devices have been unavailable for one minute.",
        "warningTitle": "LiquidBar temperature warning",
        "criticalTitle": "LiquidBar critical temperature",
        "warningBody": "A monitored temperature has remained above its warning threshold.",
        "criticalBody": "A monitored temperature has remained above its critical threshold.",
        "done": "Done",
        "status": "Status",
        "connected": "Connected",
    ]

    private static let chinese: [String: String] = [
        "cpu": "CPU",
        "liquid": "冷却液",
        "pump": "水泵",
        "fans": "风扇",
        "fan": "风扇",
        "quiet": "安静",
        "daily": "日常",
        "performance": "性能",
        "full": "全速",
        "settings": "设置…",
        "quit": "退出 LiquidBar",
        "offline": "冷却设备离线",
        "linkedFans": "联动风扇",
        "history": "温度趋势",
        "launchAtLogin": "登录时启动",
        "menuBar": "菜单栏",
        "fanNames": "风扇名称",
        "presets": "预设",
        "alerts": "过热提醒",
        "systemNotifications": "系统弹出提醒",
        "criticalSound": "严重警告声音",
        "automaticBoost": "自动全速保护",
        "cpuWarning": "CPU 预警",
        "cpuCritical": "CPU 严重",
        "liquidWarning": "冷却液预警",
        "liquidCritical": "冷却液严重",
        "diagnostics": "数据与诊断",
        "copyDiagnostics": "复制诊断信息",
        "clearLog": "清除日志",
        "identify": "测试",
        "loginNeedsApproval": "登录项需要在系统设置中批准。",
        "openLoginItems": "打开登录项设置",
        "notificationDenied": "系统设置中已禁用通知。",
        "openNotificationSettings": "打开通知设置",
        "helperMissing": "liquidctl 不可用，请先通过 Homebrew 安装。",
        "deviceError": "冷却设备已连续一分钟无法访问。",
        "warningTitle": "LiquidBar 温度预警",
        "criticalTitle": "LiquidBar 严重高温",
        "warningBody": "监控温度已持续超过预警阈值。",
        "criticalBody": "监控温度已持续超过严重阈值。",
        "done": "完成",
        "status": "状态",
        "connected": "已连接",
    ]

    static func text(_ key: String) -> String {
        (isChinese ? chinese[key] : english[key]) ?? english[key] ?? key
    }

    static func preset(_ id: PresetID) -> String {
        text(id.rawValue)
    }
}
