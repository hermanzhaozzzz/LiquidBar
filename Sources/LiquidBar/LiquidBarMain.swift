import AppKit

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
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.run()
    }
}
