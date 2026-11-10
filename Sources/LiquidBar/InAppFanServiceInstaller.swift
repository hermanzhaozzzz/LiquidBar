import AppKit
import Foundation

enum InAppFanServiceInstaller {
    enum InstallError: LocalizedError {
        case assetsMissing
        case launchFailed(String)
        case unsafePath

        var errorDescription: String? {
            switch self {
            case .assetsMissing: return L10n.text("installerUnavailable")
            case .launchFailed(let message): return message
            case .unsafePath: return "Unsupported installation path."
            }
        }
    }

    private static var assetRoot: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("FanControlService")
    }

    static var isAvailable: Bool {
        guard let root = assetRoot else { return false }
        return FileManager.default.fileExists(atPath: root.appendingPathComponent("fan_service_admin.py").path)
            && FileManager.default.fileExists(atPath: root.appendingPathComponent("LiquidBarFanControlDaemon").path)
    }

    // The caller suspends hardware control first. This shows the administrator
    // password dialog while LiquidBar is still running, so the prompt reliably
    // appears, and installs the bundled service with the new build's signature.
    static func install(completion: @escaping (Result<Void, Error>) -> Void) {
        guard let root = assetRoot, isAvailable else {
            completion(.failure(InstallError.assetsMissing))
            return
        }
        let adminScript = root.appendingPathComponent("fan_service_admin.py").path
        let package = root.path
        let appPath = Bundle.main.bundlePath
        for path in [adminScript, package, appPath] where path.contains("\"") || path.contains("\n") {
            completion(.failure(InstallError.unsafePath))
            return
        }

        let command = "/usr/bin/python3 -I \(shellQuoted(adminScript)) install "
            + "--account-scoped --in-app --package \(shellQuoted(package)) --gui \(shellQuoted(appPath))"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = [
            "-e", "do shell script \"\(command)\" with administrator privileges",
        ]
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = Pipe()
        process.terminationHandler = { process in
            var message = String(
                data: errors.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if let range = message.range(of: "ERROR:") {
                message = String(message[range.upperBound...])
            }
            if let range = message.range(of: " (1)", options: .backwards) {
                message = String(message[..<range.lowerBound])
            }
            message = message.trimmingCharacters(in: .whitespacesAndNewlines)
            if message.contains("-128") || message.localizedCaseInsensitiveContains("cancel") {
                message = L10n.text("installerAuthorizationCancelled")
            }
            DispatchQueue.main.async {
                if process.terminationStatus == 0 {
                    completion(.success(()))
                } else {
                    completion(.failure(InstallError.launchFailed(
                        message.isEmpty ? L10n.text("installerFailed") : message
                    )))
                }
            }
        }
        do {
            try process.run()
        } catch {
            completion(.failure(InstallError.launchFailed(error.localizedDescription)))
        }
    }

    // Reopens the app after this process exits. The caller must exit immediately.
    static func relaunchAndExit() {
        let appPath = Bundle.main.bundlePath
        let pid = getpid()
        let scriptPath = "/tmp/liquidbar-relaunch-\(pid).zsh"
        let script = """
        #!/bin/zsh -f
        pid="$1"
        app="$2"
        while /bin/kill -0 "$pid" 2>/dev/null; do /bin/sleep 0.2; done
        /usr/bin/open "$app"
        """
        do {
            try Data(script.utf8).write(to: URL(fileURLWithPath: scriptPath))
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700], ofItemAtPath: scriptPath
            )
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/nohup")
            process.arguments = ["/bin/zsh", scriptPath, "\(pid)", appPath]
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
        } catch {
            AppLogger.shared.log("relaunch helper failed: \(error.localizedDescription)")
        }
        exit(0)
    }

    private static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
