import Darwin
import FanControlShared
import Foundation
import Security

private final class FanReply: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false
    private let continuation: CheckedContinuation<FanControlStatus, Error>
    init(_ continuation: CheckedContinuation<FanControlStatus, Error>) { self.continuation = continuation }
    func finish(_ result: Result<FanControlStatus, Error>) {
        lock.lock()
        guard !completed else { lock.unlock(); return }
        completed = true; lock.unlock()
        continuation.resume(with: result)
    }
    func received(_ data: Data?, _ error: String?) {
        if let error { finish(.failure(FanControlError(error))); return }
        do {
            guard let data, data.count <= 65536 else { throw FanControlError("Invalid fan service response.") }
            let value = try JSONDecoder().decode(FanControlStatus.self, from: data)
            guard value.protocolVersion == FanControlConstants.protocolVersion, value.cpuIndex == 1,
                  value.chipID == 54315, value.driverVersion == "0.7.2" else {
                throw FanControlError("Fan control service needs an administrator update.")
            }
            finish(.success(value))
        } catch { finish(.failure(error)) }
    }
}

actor PrivilegedFanService {
    private var connection: NSXPCConnection?
    private var stopping = false

    nonisolated static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: FanControlConstants.configuration)
    }

    // A fresh connection cannot own the GUI's lease. Closing it must not send
    // restoreCPU or a second status request through the general shutdown path.
    static func readOnlyStatus() async throws -> FanControlStatus {
        let observer = PrivilegedFanService()
        do {
            let result = try await observer.status()
            await observer.closeReadOnlyConnection()
            return result
        } catch {
            await observer.closeReadOnlyConnection()
            throw error
        }
    }

    private func closeReadOnlyConnection() {
        connection?.invalidate()
        connection = nil
    }

    private func connect() throws -> NSXPCConnection {
        if let connection { return connection }
        let policy = try FanControlConfiguration.readSecurely()
        guard policy.allowedUID == geteuid() else { throw FanControlError("Fan service was installed for a different local user.") }
        var code: SecCode?
        var requirement: SecRequirement?
        guard SecCodeCopySelf([], &code) == errSecSuccess,
              SecRequirementCreateWithString(policy.guiRequirement as CFString, [], &requirement) == errSecSuccess,
              let code, let requirement, SecCodeCheckValidity(code, [], requirement) == errSecSuccess else {
            throw FanControlError("LiquidBar changed since fan service installation. Update the fan service once with administrator permission.")
        }
        let value = NSXPCConnection(machServiceName: FanControlConstants.service, options: .privileged)
        value.remoteObjectInterface = NSXPCInterface(with: FanControlXPC.self)
        value.setCodeSigningRequirement(policy.daemonRequirement)
        value.resume()
        connection = value
        return value
    }

    func status() async throws -> FanControlStatus {
        try await request { $0.status(reply: $1) }
    }
    func setCPU(percent: Int) async throws -> FanControlStatus {
        guard (30...100).contains(percent) else { throw FanControlError("CPU fan duty must be 30–100%.") }
        return try await request { $0.setCPU(percent: percent, reply: $1) }
    }
    func restoreCPU() async throws -> FanControlStatus {
        try await request { $0.restoreCPU(reply: $1) }
    }

    func shutdown() async throws {
        stopping = true
        defer { stopping = false }
        var failure: Error?
        if connection != nil {
            do {
                let current = try await request(allowDuringShutdown: true) { $0.status(reply: $1) }
                if current.controlledByThisConnection {
                    let restored = try await request(allowDuringShutdown: true) { $0.restoreCPU(reply: $1) }
                    if !restored.automatic { throw FanControlError("CPU automatic control was not confirmed.") }
                }
            } catch { failure = error }
        }
        connection?.invalidate(); connection = nil
        if let failure { throw failure }
    }

    private func request(allowDuringShutdown: Bool = false, _ operation: @escaping (FanControlXPC, @escaping (Data?, String?) -> Void) -> Void) async throws -> FanControlStatus {
        guard !stopping || allowDuringShutdown else { throw FanControlError("Fan control connection is closing.") }
        let active = try connect()
        do {
            let result: FanControlStatus = try await withCheckedThrowingContinuation { continuation in
                let reply = FanReply(continuation)
                guard let proxy = active.remoteObjectProxyWithErrorHandler({ error in
                    reply.finish(.failure(FanControlError("Fan service connection failed. Check installation or update the service: " + error.localizedDescription)))
                }) as? FanControlXPC else {
                    reply.finish(.failure(FanControlError("Fan service protocol is unavailable."))); return
                }
                operation(proxy, reply.received)
                DispatchQueue.global().asyncAfter(deadline: .now() + 6) {
                    reply.finish(.failure(FanControlError("Fan service timed out; automatic-control restoration is not confirmed.")))
                }
            }
            return result
        } catch {
            active.invalidate()
            if connection === active { connection = nil }
            throw error
        }
    }
}
