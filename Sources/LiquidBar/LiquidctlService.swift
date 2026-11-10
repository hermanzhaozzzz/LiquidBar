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

struct HelperData: Decodable {
    let devices: [String: DeviceCapability]?
    let errors: [String: String]?
    let applied: Bool?
    let liquidTemperature: Double?
    let pumpRPM: Int?
    let pumpDuty: Int?
    let fanRPM: [Int?]?
    let fanDuty: [Int?]?
    let fanModes: [String?]?
    let noiseLevel: Int?

    enum CodingKeys: String, CodingKey {
        case devices, errors, applied
        case liquidTemperature = "liquid_temperature"
        case pumpRPM = "pump_rpm"
        case pumpDuty = "pump_duty"
        case fanRPM = "fan_rpm"
        case fanDuty = "fan_duty"
        case fanModes = "fan_modes"
        case noiseLevel = "noise_level"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Status contains capability objects; apply returns per-device acknowledgements.
        devices = try? c.decode([String: DeviceCapability].self, forKey: .devices)
        errors = try c.decodeIfPresent([String: String].self, forKey: .errors)
        applied = try c.decodeIfPresent(Bool.self, forKey: .applied)
        liquidTemperature = try c.decodeIfPresent(Double.self, forKey: .liquidTemperature)
        pumpRPM = try c.decodeIfPresent(Int.self, forKey: .pumpRPM)
        pumpDuty = try c.decodeIfPresent(Int.self, forKey: .pumpDuty)
        fanRPM = try c.decodeIfPresent([Int?].self, forKey: .fanRPM)
        fanDuty = try c.decodeIfPresent([Int?].self, forKey: .fanDuty)
        fanModes = try c.decodeIfPresent([String?].self, forKey: .fanModes)
        noiseLevel = try c.decodeIfPresent(Int.self, forKey: .noiseLevel)
    }
}

actor LiquidctlService {
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var nextRequestID = 1
    private var curveMayBeArmed = false
    private var retiringProcess: Process?
    private var retiringOutput: FileHandle?
    private var retiringCurveArmed = false
    private var retirementFailure: String?
    private let executableOverride: URL?
    private let helperOverride: URL?
    private let requestTimeout: TimeInterval

    init(executable: URL? = nil, helper: URL? = nil, timeout: TimeInterval = 12) {
        executableOverride = executable
        helperOverride = helper
        requestTimeout = timeout
    }

    deinit {
        try? input?.close()
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
            connected: data.devices?.values.contains(where: { $0.connected }) ?? false,
            devices: data.devices ?? [:],
            errors: data.errors ?? [:]
        )
    }

    func setFan(index: Int, duty: Int) throws {
        _ = try request([
            "action": "set", "device": "smart", "channel": "fan\(index)",
            "duty": min(100, max(30, duty)),
        ])
        curveMayBeArmed = false
    }

    func setPump(duty: Int) throws {
        _ = try request([
            "action": "set", "device": "kraken", "channel": "pump",
            "duty": min(100, max(50, duty)),
        ])
    }

    func apply(fans: [Int]?, pump: Int?, curve: Bool = false) throws {
        var payload: [String: Any] = ["action": "apply", "curve": curve]
        if let fans { payload["fans"] = fans.map { min(100, max(30, $0)) } }
        if let pump { payload["pump"] = min(100, max(50, pump)) }
        _ = try request(payload)
        if fans != nil { curveMayBeArmed = curve }
    }

    func disarmCurve() throws {
        _ = try request(["action": "curve_disarm"])
        curveMayBeArmed = false
    }

    func setLighting(device: String, settings: LightingSettings) throws {
        _ = try request([
            "action": "lighting", "device": device, "channel": settings.channel,
            "mode": settings.mode, "colors": [settings.rgb], "speed": "normal",
        ])
    }

    func updateDisplay(enabled: Bool, temperature: Double?, utilization: Double?, power: Double?, unit: String) throws {
        var payload: [String: Any] = ["action": "display", "enabled": enabled, "unit": unit]
        if enabled {
            guard let temperature, let utilization, let power,
                  temperature.isFinite, utilization.isFinite, power.isFinite else {
                throw LiquidctlError.response(L10n.text("displayTelemetryUnavailable"))
            }
            payload["temperature"] = temperature
            payload["utilization"] = utilization
            payload["power"] = power
        }
        _ = try request(payload)
    }

    func identifyFan(index: Int) throws {
        _ = try request(["action": "identify", "index": index])
    }

    func reconnect() throws {
        try stop()
        _ = try request(["action": "initialize"])
    }

    func stop() throws {
        // A failed/timed-out request may still be executing. Never exchange another
        // command on the same pipe or replay a write whose outcome is unknown.
        try? input?.close()
        input = nil
        if let process {
            retiringProcess = process
            retiringOutput = output
            retiringCurveArmed = curveMayBeArmed
            // An armed worker must finish its own full-speed writes on EOF.
            // Retain it and refuse a competing session if those writes block.
            if !curveMayBeArmed && process.isRunning { process.terminate() }
        } else if output != nil { try? output?.close() }
        process = nil
        output = nil
        try awaitRetirement(timeout: 2)
    }

    private func awaitRetirement(timeout: TimeInterval) throws {
        if let retirementFailure { throw LiquidctlError.response(retirementFailure) }
        guard let retiringProcess else { return }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while retiringProcess.isRunning && ProcessInfo.processInfo.systemUptime < deadline {
            usleep(10_000)
        }
        guard !retiringProcess.isRunning else {
            throw LiquidctlError.response("The previous USB helper is still finishing its safety shutdown; no new control session has started.")
        }
        retiringProcess.waitUntilExit()
        try? retiringOutput?.close()
        retiringOutput = nil
        self.retiringProcess = nil
        if retiringCurveArmed && (retiringProcess.terminationReason != .exit || retiringProcess.terminationStatus != 0) {
            retirementFailure = "The USB helper did not confirm its full-speed fallback. Check cooling before restarting LiquidBar."
            throw LiquidctlError.response(retirementFailure!)
        }
        curveMayBeArmed = false
        retiringCurveArmed = false
    }

    private func request(_ values: [String: Any]) throws -> HelperResponse {
        try ensureRunning()
        if values["curve"] as? Bool == true { curveMayBeArmed = true }
        guard let input, let output else { throw LiquidctlError.disconnected }

        let requestID = nextRequestID
        nextRequestID += 1
        var payload = values
        payload["id"] = requestID
        let data = try JSONSerialization.data(withJSONObject: payload)
        let response: HelperResponse
        do {
            try input.write(contentsOf: data + Data([0x0a]))
            let line = try readLine(from: output.fileDescriptor, timeout: requestTimeout)
            response = try JSONDecoder().decode(HelperResponse.self, from: line)
            guard response.id == requestID else {
                throw LiquidctlError.response("liquidctl helper returned an unexpected request id; session reset")
            }
        } catch {
            do { try stop() }
            catch { throw error }
            throw error
        }
        guard response.ok else {
            throw LiquidctlError.response(response.error ?? "unknown liquidctl error")
        }
        if values["action"] as? String != "status", let errors = response.data?.errors, !errors.isEmpty {
            throw LiquidctlError.response(errors.keys.sorted().map { "\($0): \(errors[$0]!)" }.joined(separator: "; "))
        }
        return response
    }

    private func ensureRunning() throws {
        if process?.isRunning == true { return }
        if process != nil { try stop() }
        try awaitRetirement(timeout: 2)
        guard let python = executableOverride ?? pythonExecutable() else { throw LiquidctlError.dependencyMissing }
        guard let helper = helperOverride ?? helperScript() else { throw LiquidctlError.helperMissing }

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
            stdinPipe.fileHandleForReading.closeFile()
            stdoutPipe.fileHandleForWriting.closeFile()
            stderrPipe.fileHandleForWriting.closeFile()
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

    private func readLine(from descriptor: Int32, timeout: TimeInterval) throws -> Data {
        var bytes: [UInt8] = []
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while true {
            var pollDescriptor = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { throw LiquidctlError.timedOut }
            let result = Darwin.poll(&pollDescriptor, 1, Int32(max(1, remaining * 1_000)))
            if result == 0 { throw LiquidctlError.timedOut }
            if result < 0 {
                if errno == EINTR { continue }
                throw LiquidctlError.disconnected
            }
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
