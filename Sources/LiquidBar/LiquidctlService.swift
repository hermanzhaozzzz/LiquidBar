import Darwin
import Foundation

enum LiquidctlError: LocalizedError {
    case dependencyMissing
    case helperMissing
    case launchFailed(String)
    case timedOut
    case disconnected
    case response(String)

    var errorDescription: String? {
        switch self {
        case .dependencyMissing: return L10n.text("helperMissing")
        case .helperMissing: return "device_helper.py is missing"
        case .launchFailed(let message): return "liquidctl helper failed to launch: \(message)"
        case .timedOut: return "liquidctl helper timed out"
        case .disconnected: return "liquidctl helper disconnected"
        case .response(let message): return message
        }
    }
}

private struct HelperResponse: Decodable {
    let id: Int?
    let ok: Bool
    let data: HelperData?
    let error: String?
}

private struct HelperData: Decodable {
    let liquidTemperature: Double?
    let pumpRPM: Int?
    let pumpDuty: Int?
    let fanRPM: [Int?]?
    let fanDuty: [Int?]?
    let fanModes: [String?]?
    let noiseLevel: Int?

    enum CodingKeys: String, CodingKey {
        case liquidTemperature = "liquid_temperature"
        case pumpRPM = "pump_rpm"
        case pumpDuty = "pump_duty"
        case fanRPM = "fan_rpm"
        case fanDuty = "fan_duty"
        case fanModes = "fan_modes"
        case noiseLevel = "noise_level"
    }
}

actor LiquidctlService {
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var nextRequestID = 1

    deinit {
        process?.terminate()
    }

    func status() throws -> DeviceSnapshot {
        let response = try request(["action": "status"])
        guard let data = response.data else {
            throw LiquidctlError.response("status response contained no data")
        }
        return DeviceSnapshot(
            timestamp: Date(),
            liquidTemperature: data.liquidTemperature,
            pumpRPM: data.pumpRPM,
            pumpDuty: data.pumpDuty,
            fanRPM: normalized(data.fanRPM),
            fanDuty: normalized(data.fanDuty),
            fanModes: normalized(data.fanModes),
            noiseLevel: data.noiseLevel,
            connected: true
        )
    }

    func setFan(index: Int, duty: Int) throws {
        _ = try request([
            "action": "set", "device": "smart", "channel": "fan\(index)",
            "duty": min(100, max(30, duty)),
        ])
    }

    func setPump(duty: Int) throws {
        _ = try request([
            "action": "set", "device": "kraken", "channel": "pump",
            "duty": min(100, max(50, duty)),
        ])
    }

    func apply(fans: [Int], pump: Int) throws {
        _ = try request([
            "action": "apply",
            "fans": fans.map { min(100, max(30, $0)) },
            "pump": min(100, max(50, pump)),
        ])
    }

    func identifyFan(index: Int) throws {
        _ = try request(["action": "identify", "index": index])
    }

    func reconnect() throws {
        stop()
        _ = try request(["action": "initialize"])
    }

    func stop() {
        if process?.isRunning == true {
            _ = try? request(["action": "shutdown"])
            process?.terminate()
        }
        process = nil
        input = nil
        output = nil
    }

    private func request(_ values: [String: Any]) throws -> HelperResponse {
        try ensureRunning()
        guard let input, let output else { throw LiquidctlError.disconnected }

        let requestID = nextRequestID
        nextRequestID += 1
        var payload = values
        payload["id"] = requestID
        let data = try JSONSerialization.data(withJSONObject: payload)
        try input.write(contentsOf: data)
        try input.write(contentsOf: Data([0x0a]))

        let line = try readLine(from: output.fileDescriptor, timeout: 8)
        let response = try JSONDecoder().decode(HelperResponse.self, from: line)
        guard response.id == requestID else {
            throw LiquidctlError.response("liquidctl helper returned an unexpected request id")
        }
        guard response.ok else {
            throw LiquidctlError.response(response.error ?? "unknown liquidctl error")
        }
        return response
    }

    private func ensureRunning() throws {
        if process?.isRunning == true { return }
        guard let python = pythonExecutable() else { throw LiquidctlError.dependencyMissing }
        guard let helper = helperScript() else { throw LiquidctlError.helperMissing }

        let process = Process()
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.executableURL = python
        process.arguments = ["-u", helper.path]
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.environment = [
            "PATH": "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin",
            "PYTHONUNBUFFERED": "1",
        ]
        process.terminationHandler = { process in
            if let data = try? stderrPipe.fileHandleForReading.readToEnd(),
               let text = String(data: data, encoding: .utf8),
               !text.isEmpty {
                AppLogger.shared.log("helper stderr: \(text)")
            }
        }
        do {
            try process.run()
        } catch {
            throw LiquidctlError.launchFailed(error.localizedDescription)
        }
        self.process = process
        input = stdinPipe.fileHandleForWriting
        output = stdoutPipe.fileHandleForReading
        AppLogger.shared.log("liquidctl helper started with \(python.path)")
    }

    private func pythonExecutable() -> URL? {
        let candidates = [
            "/usr/local/opt/liquidctl/libexec/bin/python",
            "/usr/local/opt/liquidctl/libexec/bin/python3",
            "/opt/homebrew/opt/liquidctl/libexec/bin/python",
            "/opt/homebrew/opt/liquidctl/libexec/bin/python3",
        ]
        return candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }).map {
            URL(fileURLWithPath: $0)
        }
    }

    private func helperScript() -> URL? {
        if let bundled = Bundle.main.url(forResource: "device_helper", withExtension: "py") {
            return bundled
        }
        let candidates = [
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("Resources/device_helper.py"),
            URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Resources/device_helper.py"),
        ]
        return candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) })
    }

    private func readLine(from descriptor: Int32, timeout: Int32) throws -> Data {
        var bytes: [UInt8] = []
        while true {
            var pollDescriptor = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            let result = Darwin.poll(&pollDescriptor, 1, timeout * 1_000)
            if result == 0 { throw LiquidctlError.timedOut }
            if result < 0 { throw LiquidctlError.disconnected }
            var byte: UInt8 = 0
            let count = Darwin.read(descriptor, &byte, 1)
            guard count == 1 else { throw LiquidctlError.disconnected }
            if byte == 0x0a { return Data(bytes) }
            bytes.append(byte)
            if bytes.count > 1_000_000 {
                throw LiquidctlError.response("liquidctl helper response exceeded 1 MB")
            }
        }
    }

    private func normalized<T>(_ values: [T?]?) -> [T?] {
        Array(((values ?? []) + [nil, nil, nil]).prefix(3))
    }
}
