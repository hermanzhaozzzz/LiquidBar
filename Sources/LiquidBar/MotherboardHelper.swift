import Foundation
import Darwin

struct MotherboardRequest: Codable {
    let id: Int
    let action: String
    var index: Int?
    var percent: Int?
    var role: MotherboardFanRole?
    var duration: TimeInterval?
}
struct MotherboardResponse: Codable {
    let id: Int
    var cpu: MotherboardCPUMetrics?
    var snapshot: MotherboardFanSnapshot?
    var test: MotherboardFanTestResult?
    var error: String?
}

/// A separate process owns manual control. It restores only channels it has
/// overridden when the app closes its pipe, dies, stops polling, or terminates
/// the helper normally. This does not protect against a kernel/system crash.
enum MotherboardHelperMain {
    static func run(engine: MotherboardEngine = MotherboardEngine()) {
        signal(SIGPIPE, SIG_IGN)
        signal(SIGTERM, SIG_IGN)
        signal(SIGINT, SIG_IGN)
        let parent = getppid()
        let queue = DispatchQueue(label: "LiquidBar.motherboard.helper")
        var lastRequest = ProcessInfo.processInfo.systemUptime
        var restoreError: String?
        func restore() {
            for attempt in 1...3 {
                do { try engine.restoreAllOverrides(); restoreError = nil; return }
                catch {
                    FileHandle.standardError.write(Data(("Motherboard restore attempt \(attempt): " + error.localizedDescription + "\n").utf8))
                    if attempt < 3 { Thread.sleep(forTimeInterval: 0.25) }
                }
            }
            restoreError = "Motherboard control could not be restored; restart to recover BIOS control."
            FileHandle.standardError.write(Data(("WARNING: " + restoreError! + "\n").utf8))
        }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler {
            let parentAlive = getppid() == parent && kill(parent, 0) == 0
            if !parentAlive || ProcessInfo.processInfo.systemUptime - lastRequest > 15 {
                restore()
                if !parentAlive && engine.overriddenChannels.isEmpty { exit(0) }
            }
        }
        timer.resume()
        let termination = DispatchSource.makeSignalSource(signal: SIGTERM, queue: queue)
        termination.setEventHandler { restore(); exit(engine.overriddenChannels.isEmpty ? 0 : 1) }
        termination.resume()
        let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: queue)
        interrupt.setEventHandler { restore(); exit(engine.overriddenChannels.isEmpty ? 0 : 1) }
        interrupt.resume()
        while let line = readLine() {
            queue.sync {
                var response = MotherboardResponse(id: -1)
                do {
                    guard line.utf8.count <= 4096 else { throw MotherboardError(message: "Oversized motherboard request.") }
                    let request = try JSONDecoder().decode(MotherboardRequest.self, from: Data(line.utf8))
                    response = MotherboardResponse(id: request.id)
                    lastRequest = ProcessInfo.processInfo.systemUptime
                    switch request.action {
                    case "cpu": response.cpu = try engine.cpuMetrics()
                    case "initialize": response.snapshot = try engine.initializeFans()
                    case "fans": response.snapshot = try engine.readFans()
                    case "set":
                        guard let index = request.index, let percent = request.percent, let role = request.role else { throw MotherboardError(message: "Incomplete fan command.") }
                        response.snapshot = try engine.setDuty(index: index, percent: percent, role: role)
                    case "restore":
                        guard let index = request.index else { throw MotherboardError(message: "Missing fan channel.") }
                        response.snapshot = try engine.restoreAutomatic(index: index)
                    case "restoreAll": try engine.restoreAllOverrides()
                    case "test":
                        guard let index = request.index, let role = request.role else { throw MotherboardError(message: "Incomplete fan test.") }
                        response.test = try engine.testIncrease(index: index, role: role, duration: request.duration ?? 3)
                    default: throw MotherboardError(message: "Unsupported motherboard operation.")
                    }
                } catch {
                    response.error = error.localizedDescription
                    restore()
                }
                if let restoreError { response.error = [response.error, restoreError].compactMap { $0 }.joined(separator: " ") }
                lastRequest = ProcessInfo.processInfo.systemUptime
                // Authorization can block inside the kernel. Check parent again
                // immediately after returning, before keeping any manual duty.
                if getppid() != parent || kill(parent, 0) != 0 { restore(); exit(engine.overriddenChannels.isEmpty ? 0 : 1) }
                do {
                    var bytes = try JSONEncoder().encode(response); bytes.append(10)
                    try FileHandle.standardOutput.write(contentsOf: bytes)
                } catch { restore(); exit(engine.overriddenChannels.isEmpty ? 0 : 1) }
            }
        }
        queue.sync { restore() }
        timer.cancel(); termination.cancel(); interrupt.cancel()
        exit(engine.overriddenChannels.isEmpty ? 0 : 1)
    }
}
