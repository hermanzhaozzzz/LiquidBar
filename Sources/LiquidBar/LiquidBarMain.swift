import AppKit
import ServiceManagement

@main
enum LiquidBarMain {
    static func main() {
        if CommandLine.arguments.contains("--gpu-status") {
            guard CommandLine.arguments.count == 2 else {
                fputs("--gpu-status accepts no additional arguments.\n", stderr)
                exit(64)
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            do {
                var data = try encoder.encode(GPUReader.readSnapshot())
                data.append(10)
                FileHandle.standardOutput.write(data)
            } catch {
                fputs("GPU status encoding failed.\n", stderr)
                exit(2)
            }
            return
        }
        if CommandLine.arguments.contains("--fan-service-status") {
            guard CommandLine.arguments.count == 2 else {
                fputs("--fan-service-status accepts no additional arguments.\n", stderr)
                exit(64)
            }
            runFanServiceStatus()
            return
        }
        if CommandLine.arguments.contains("--motherboard-helper") {
            MotherboardHelperMain.run()
            return
        }
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

    private static func runFanServiceStatus() {
        // Includes configuration/signature checks as well as the XPC reply.
        DispatchQueue.global().asyncAfter(deadline: .now() + 6) {
            fputs("Fan service status timed out after 6 seconds.\n", stderr)
            exit(2)
        }
        Task.detached {
            do {
                let status = try await PrivilegedFanService.readOnlyStatus()
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                encoder.dateEncodingStrategy = .iso8601
                var output = try encoder.encode(status)
                output.append(10)
                FileHandle.standardOutput.write(output)
                exit(0)
            } catch {
                FileHandle.standardError.write(Data(("Fan service status unavailable: " + error.localizedDescription + "\n").utf8))
                exit(2)
            }
        }
        dispatchMain()
    }
}
