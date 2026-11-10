import Darwin
import FanControlShared
import Foundation

@main struct FanControlDaemonMain {
    static func main() {
        guard geteuid() == 0, CommandLine.arguments.count == 1 else {
            FileHandle.standardError.write(Data("This service must be installed by an administrator and launched by launchd.\n".utf8))
            exit(77)
        }
        do {
            let configuration = try FanControlConfiguration.readSecurely()
            let log = try ServiceLog()
            let backend = try NativeCPUFan(configuration: configuration)
            let server = FanControlServer(configuration: configuration, backend: backend, log: log)
            try server.start()
            withExtendedLifetime(server) { RunLoop.main.run() }
        } catch {
            FileHandle.standardError.write(Data(("Fan service startup failed: " + error.localizedDescription + "\n").utf8))
            exit(1)
        }
    }
}
