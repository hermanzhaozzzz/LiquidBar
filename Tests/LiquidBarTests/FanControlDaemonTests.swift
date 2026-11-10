import FanControlShared
import Foundation
import Testing
@testable import LiquidBarFanControlDaemon

private func daemonPolicy(cpuIndex: Int = 1, guiRequirement: String? = nil,
                          authorizationScope: String = "user-account") -> FanControlConfiguration {
    let requirement = "cdhash H\"" + String(repeating: "a", count: 40) + "\""
    return FanControlConfiguration(allowedUID: 501, authorizationScope: authorizationScope, guiRequirement: guiRequirement ?? requirement,
                                   daemonRequirement: requirement, cpuIndex: cpuIndex)
}

private final class FakeCPUFan: CPUFanBackend {
    var sample = CPUFanSample(rpm: 1400, duty: 53, automatic: true, temperature: 60)
    var writes: [Int] = []
    var restores = 0
    var failSet = false
    var failRestore = false
    var failRead = false
    var ignoreSet = false
    func read() throws -> CPUFanSample {
        if failRead { throw FanControlError("injected telemetry failure") }
        return sample
    }
    func set(percent: Int) throws {
        writes.append(percent)
        if !ignoreSet { sample = CPUFanSample(rpm: percent * 30, duty: percent, automatic: false, temperature: 60) }
        if failSet { throw FanControlError("injected partial write") }
    }
    func restoreAutomatic() throws {
        restores += 1
        if failRestore { throw FanControlError("injected restore failure") }
        sample = CPUFanSample(rpm: 1400, duty: 53, automatic: true, temperature: sample.temperature)
    }
}

@Test func daemonTrustRejectsBroadRequirementsAndUnverifiedHeaders() throws {
    try daemonPolicy().validate()
    #expect(throws: Error.self) { try daemonPolicy(cpuIndex: 5).validate() }
    #expect(throws: Error.self) { try daemonPolicy(guiRequirement: "identifier com.hermanzhaozzzz.LiquidBar").validate() }
    #expect(throws: Error.self) { try daemonPolicy(authorizationScope: "application-only").validate() }
    #expect(throws: Error.self) { try daemonPolicy(authorizationScope: "").validate() }
    var missingScope = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(daemonPolicy())) as? [String: Any])
    missingScope.removeValue(forKey: "authorizationScope")
    let oldData = try JSONSerialization.data(withJSONObject: missingScope)
    #expect(throws: Error.self) { try JSONDecoder().decode(FanControlConfiguration.self, from: oldData) }
    let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try JSONEncoder().encode(daemonPolicy()).write(to: path)
    defer { try? FileManager.default.removeItem(at: path) }
    #expect(throws: Error.self) { try FanControlConfiguration.readSecurely(path: path.path) }
}

@Test func daemonOwnerLeaseCannotBeRenewedOrReplacedByAnObserver() throws {
    let backend = FakeCPUFan()
    var clock = 0.0
    let core = FanControlCore(configuration: daemonPolicy(), backend: backend, clock: { clock }, log: { _,_,_,_ in })
    try core.start()
    #expect(backend.writes.isEmpty && backend.sample.automatic)
    let owner = UUID(), observer = UUID()
    for invalid in [29, 101] { #expect(throws: Error.self) { try core.setCPU(client: owner, percent: invalid) } }
    #expect(backend.writes.isEmpty)
    _ = try core.setCPU(client: owner, percent: 30)
    #expect(throws: Error.self) { try core.setCPU(client: observer, percent: 80) }
    #expect(throws: Error.self) { try core.restoreCPU(client: observer) }
    clock = 14
    #expect(try !core.status(client: observer).controlledByThisConnection)
    core.disconnected(client: observer)
    #expect(!backend.sample.automatic && core.owner == owner)
    #expect(backend.restores == 1) // Observer reads/closes never restore the GUI's lease.
    clock = 16
    core.tick()
    #expect(backend.sample.automatic && core.owner == nil)
    #expect(core.lastReason == "lease_timeout")
    _ = try core.setCPU(client: owner, percent: 100)
    clock = 32
    // A late heartbeat must not revive a lease that has already expired.
    #expect(try core.status(client: owner).automatic)
    #expect(backend.writes == [30, 100])
}

@Test func daemonRestoresForDisconnectSleepAndThermalFailure() throws {
    for reason in ["client_disconnected", "sleep", "overheat", "invalid_temperature", "fan_feedback_missing"] {
        let backend = FakeCPUFan()
        let core = FanControlCore(configuration: daemonPolicy(), backend: backend, log: { _,_,_,_ in })
        try core.start()
        let owner = UUID()
        _ = try core.setCPU(client: owner, percent: 30)
        switch reason {
        case "client_disconnected":
            core.disconnected(client: UUID())
            #expect(!backend.sample.automatic)
            core.disconnected(client: owner)
        case "sleep":
            try core.sleep()
            #expect(throws: Error.self) { try core.setCPU(client: owner, percent: 30) }
            core.wake()
        case "overheat":
            backend.sample = CPUFanSample(rpm: 900, duty: 30, automatic: false, temperature: 75)
            core.tick()
        case "invalid_temperature":
            backend.sample = CPUFanSample(rpm: 900, duty: 30, automatic: false, temperature: nil)
            core.tick()
        default:
            backend.sample = CPUFanSample(rpm: 0, duty: 30, automatic: false, temperature: 60)
            core.tick()
        }
        #expect(backend.sample.automatic && core.owner == nil)
        #expect(core.lastReason == (reason == "sleep" ? "wake" : reason))
        #expect(backend.writes == [30])
    }
}

@Test func daemonNeverReportsPartialWriteOrFailedRestoreAsSuccess() throws {
    for mismatch in [false, true] {
        let backend = FakeCPUFan()
        var events: [(String, Bool?)] = []
        let core = FanControlCore(configuration: daemonPolicy(), backend: backend, log: { event,_,restored,_ in events.append((event, restored)) })
        try core.start()
        if mismatch { backend.ignoreSet = true } else { backend.failSet = true }
        #expect(throws: Error.self) { try core.setCPU(client: UUID(), percent: 30) }
        #expect(backend.sample.automatic)
        #expect(core.lastReason == "write_failed")
        backend.failRestore = true
        #expect(!core.stop())
        #expect(core.draining)
        #expect(events.last?.0 == "error")
        #expect(events.contains { $0.0 == "restoration_failed" && $0.1 == false })
        #expect(throws: Error.self) { try core.setCPU(client: UUID(), percent: 30) }
    }
}

@Test func daemonWakeRestoresAfterFailedPreSleepRestoration() throws {
    let backend = FakeCPUFan()
    let core = FanControlCore(configuration: daemonPolicy(), backend: backend, log: { _,_,_,_ in })
    try core.start()
    _ = try core.setCPU(client: UUID(), percent: 30)
    backend.failRestore = true
    #expect(throws: Error.self) { try core.sleep() }
    #expect(core.sleeping && core.owner != nil)
    backend.failRestore = false
    core.wake()
    #expect(backend.sample.automatic && core.owner == nil && !core.sleeping)
    #expect(core.lastReason == "wake")
    #expect(backend.writes == [30])
}

@Test func daemonClearsTransientFailureOnlyAfterHealthyAutomaticReadback() throws {
    for manuallyOwned in [false, true] {
        let backend = FakeCPUFan()
        let core = FanControlCore(configuration: daemonPolicy(), backend: backend, log: { _,_,_,_ in })
        try core.start()
        if manuallyOwned { _ = try core.setCPU(client: UUID(), percent: 30) }
        backend.failRead = true
        core.tick()
        #expect(core.error != nil)
        backend.failRead = false
        backend.sample = CPUFanSample(rpm: 1400, duty: 53, automatic: true, temperature: nil)
        core.tick()
        #expect(core.error != nil)
        backend.sample = CPUFanSample(rpm: 1400, duty: 53, automatic: true, temperature: 60)
        core.tick()
        #expect(core.error == nil && core.owner == nil)
        #expect(core.lastReason == "automatic_control_recovered")
    }
}

@Test func daemonPersistentOwnerHeartbeatKeepsControlWithoutRepeatedWrites() throws {
    let backend = FakeCPUFan()
    var clock = 0.0
    let core = FanControlCore(configuration: daemonPolicy(), backend: backend, clock: { clock }, log: { _,_,_,_ in })
    let owner = UUID()
    try core.start()
    _ = try core.setCPU(client: owner, percent: 30)
    for moment in stride(from: 2.0, through: 120.0, by: 2.0) {
        clock = moment
        core.tick()
        #expect(try core.status(client: owner).controlledByThisConnection)
    }
    #expect(!backend.sample.automatic)
    #expect(backend.writes == [30])
    #expect(core.stop())
    #expect(backend.sample.automatic)
}
