import Darwin
import Foundation

public enum FanControlConstants {
    public static let service = "com.hermanzhaozzzz.LiquidBar.FanControl"
    public static let configuration = "/Library/Application Support/LiquidBar/FanControl/config.json"
    public static let executable = "/Library/PrivilegedHelperTools/" + service
    public static let log = "/Library/Logs/LiquidBarFanControl.log"
    public static let protocolVersion = 1
    public static let leaseSeconds: TimeInterval = 15
    public static let maximumTemperature = 75.0
}

public struct FanControlError: LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public struct FanControlConfiguration: Codable, Equatable, Sendable {
    public let protocolVersion: Int
    public let allowedUID: UInt32
    public let authorizationScope: String
    public let guiRequirement: String
    public let daemonRequirement: String
    public let cpuIndex: Int
    public let chipID: UInt64
    public let driverVersion: String

    public init(protocolVersion: Int = 1, allowedUID: UInt32, authorizationScope: String, guiRequirement: String,
                daemonRequirement: String, cpuIndex: Int = 1, chipID: UInt64 = 54315,
                driverVersion: String = "0.7.2") {
        self.protocolVersion = protocolVersion; self.allowedUID = allowedUID
        self.authorizationScope = authorizationScope
        self.guiRequirement = guiRequirement; self.daemonRequirement = daemonRequirement
        self.cpuIndex = cpuIndex; self.chipID = chipID; self.driverVersion = driverVersion
    }

    public func validate() throws {
        guard protocolVersion == FanControlConstants.protocolVersion, allowedUID > 0,
              authorizationScope == "user-account",
              cpuIndex == 1, chipID == 54315, driverVersion == "0.7.2" else {
            throw FanControlError("Unsupported fan service policy. Reinstall the approved service configuration.")
        }
        for requirement in [guiRequirement, daemonRequirement] {
            guard requirement.range(of: #"^cdhash H"[0-9a-fA-F]{40}"$"#, options: .regularExpression) != nil else {
                throw FanControlError("Fan service requires an exact code-directory hash.")
            }
        }
    }

    // The user-writable app bundle is never a trust source for the root peer.
    public static func readSecurely(path: String = FanControlConstants.configuration) throws -> Self {
        var current = URL(fileURLWithPath: path)
        while true {
            var info = stat()
            guard lstat(current.path, &info) == 0 else {
                throw FanControlError("Fan control service is not installed. Complete the administrator installation once.")
            }
            guard info.st_uid == 0, info.st_mode & 0o022 == 0,
                  info.st_mode & S_IFMT != S_IFLNK else {
                throw FanControlError("Fan service configuration must be root-owned and not writable by other users.")
            }
            if current.path == "/" { break }
            current.deleteLastPathComponent()
        }
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw FanControlError("Cannot open fan service configuration.") }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_uid == 0, info.st_mode & 0o022 == 0,
              info.st_mode & S_IFMT == S_IFREG, info.st_size > 0, info.st_size <= 16384 else {
            throw FanControlError("Invalid fan service configuration file.")
        }
        var bytes = [UInt8](repeating: 0, count: 16385)
        let count = read(descriptor, &bytes, bytes.count)
        guard count == Int(info.st_size) else { throw FanControlError("Incomplete fan service configuration.") }
        let value = try JSONDecoder().decode(Self.self, from: Data(bytes.prefix(count)))
        try value.validate()
        return value
    }
}

public struct FanControlStatus: Codable, Equatable, Sendable {
    public let protocolVersion: Int
    public let cpuIndex: Int
    public let chipID: UInt64
    public let driverVersion: String
    public let rpm: Int
    public let duty: Int
    public let automatic: Bool
    public let temperature: Double?
    public let sampledAt: Date
    public let controlledByThisConnection: Bool
    public let lastReason: String
    public let error: String?

    public init(cpuIndex: Int, chipID: UInt64, driverVersion: String, rpm: Int, duty: Int,
                automatic: Bool, temperature: Double?, sampledAt: Date = Date(),
                controlledByThisConnection: Bool, lastReason: String, error: String? = nil) {
        protocolVersion = FanControlConstants.protocolVersion
        self.cpuIndex = cpuIndex; self.chipID = chipID; self.driverVersion = driverVersion
        self.rpm = rpm; self.duty = duty; self.automatic = automatic; self.temperature = temperature
        self.sampledAt = sampledAt; self.controlledByThisConnection = controlledByThisConnection
        self.lastReason = lastReason; self.error = error
    }
}

@objc public protocol FanControlXPC {
    func status(reply: @escaping (Data?, String?) -> Void)
    func setCPU(percent: Int, reply: @escaping (Data?, String?) -> Void)
    func restoreCPU(reply: @escaping (Data?, String?) -> Void)
    func heartbeat(reply: @escaping (Data?, String?) -> Void)
}
