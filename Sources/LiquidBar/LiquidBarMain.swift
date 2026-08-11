import AppKit
import ServiceManagement

@main
enum LiquidBarMain {
    static func main() {
        if CommandLine.arguments.contains("--smc-probe") {
            if let value = SMCReader()?.cpuTemperature() {
                print(String(format: "%.1f", value))
                return
            }
            fputs("CPU temperature unavailable\n", stderr)
            exit(2)
        }
        if CommandLine.arguments.contains("--login-item-status") {
            let status = SMAppService.mainApp.status
            let name: String
            switch status {
            case .notRegistered: name = "notRegistered"
            case .enabled: name = "enabled"
            case .requiresApproval: name = "requiresApproval"
            case .notFound: name = "notFound"
            @unknown default: name = "unknown"
            }
            print("\(name) (\(status.rawValue))")
            return
        }
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.run()
    }
}
