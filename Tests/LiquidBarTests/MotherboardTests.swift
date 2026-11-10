import Foundation
import Testing
@testable import LiquidBar

private final class FakeMotherboard: MotherboardDriverTransport {
    var version = "0.7.2"
    var calls: [(UInt32, [UInt64])] = []
    var raw = [UInt8](repeating: 128, count: 7)
    var automatic = [Bool](repeating: true, count: 7)
    var failNextWrite = false
    var denyNextWrite = false
    var restoreFailures = 0
    var failRPM = false
    func call(selector: UInt32, inputs: [UInt64], capacity: Int) throws -> MotherboardDriverResponse {
        calls.append((selector, inputs))
        func integers(_ values: [UInt64]) -> MotherboardDriverResponse {
            var bytes = Data()
            for var value in values { withUnsafeBytes(of: &value) { bytes.append(contentsOf: $0) } }
            return MotherboardDriverResponse(bytes: bytes)
        }
        switch selector {
        case 8: return MotherboardDriverResponse(bytes: Data((version + "\0").utf8))
        case 4:
            let floats: [Float] = [72.5, 55.25, 0]
            return MotherboardDriverResponse(bytes: floats.withUnsafeBytes { Data($0) })
        case 90: return integers([1, 0xD42B])
        case 91: return integers([7])
        case 92: return MotherboardDriverResponse(bytes: Data("Generic \(inputs[0])".utf8))
        case 93:
            if failRPM { failRPM = false; throw MotherboardError(message: "read failed") }
            return integers(raw.map { UInt64($0) * 10 })
        case 94: return integers((0..<7).map { UInt64(raw[$0]) << 8 | (automatic[$0] ? 1 : 0) })
        case 95:
            if denyNextWrite { denyNextWrite = false; throw MotherboardError(message: "denied", permissionDenied: true) }
            let index = Int(inputs[0]); raw[index] = UInt8(inputs[1]); automatic[index] = false
            if failNextWrite { failNextWrite = false; throw MotherboardError(message: "partial write") }
            return MotherboardDriverResponse(bytes: Data())
        case 96:
            if restoreFailures > 0 { restoreFailures -= 1; throw MotherboardError(message: "restore failed") }
            automatic[Int(inputs[0])] = true
            return MotherboardDriverResponse(bytes: Data())
        default: throw MotherboardError(message: "unexpected selector")
        }
    }
}

@Test func motherboardCPUDoesNotInitializeOrControlFans() throws {
    let driver = FakeMotherboard()
    let independent = MotherboardEngine(transport: driver)
    let metrics = try independent.cpuMetrics()
    #expect(metrics.temperature == 55.25)
    #expect(metrics.powerWatts == 72.5)
    #expect(driver.calls.map(\.0) == [8, 4])
    #expect(throws: Error.self) { try independent.readFans() }
}

@Test func motherboardRequiresSupportedABIAndExplicitInitialization() throws {
    let driver = FakeMotherboard(); driver.version = "99.0"
    let engine = MotherboardEngine(transport: driver)
    #expect(throws: Error.self) { try engine.initializeFans() }
    #expect(!driver.calls.contains { $0.0 == 90 })
}

@Test func motherboardBoundsNeverWriteInvalidChannelOrPumpDuty() throws {
    let driver = FakeMotherboard()
    let tested = MotherboardEngine(transport: driver)
    _ = try tested.initializeFans()
    #expect(throws: Error.self) { try tested.setDuty(index: 5, percent: 79, role: .pump) }
    #expect(throws: Error.self) { try tested.setDuty(index: 7, percent: 100, role: .cpu) }

    #expect(!driver.calls.contains { $0.0 == 95 })
}

@Test func motherboardIncreaseTestRestoresAfterReadFailureAndPartialWrite() throws {
    for partial in [false, true] {
        let driver = FakeMotherboard()
        let tested = MotherboardEngine(transport: driver)
        _ = try tested.initializeFans()
        if partial { driver.failNextWrite = true }
        #expect(throws: Error.self) {
            try tested.testIncrease(index: 1, role: .cpu, wait: { _ in driver.failRPM = true })
        }
        #expect(driver.automatic[1])
        #expect(tested.overriddenChannels.isEmpty)
        #expect(driver.calls.filter { $0.0 == 95 }.allSatisfy { $0.1[0] == 1 && $0.1[1] > 128 })
        #expect(!driver.calls.contains { $0.0 == 97 })
    }
}

@Test func motherboardRestoresOriginalManualDutyExactly() throws {
    let driver = FakeMotherboard(); driver.automatic[1] = false; driver.raw[1] = 137
    let engine = MotherboardEngine(transport: driver)
    _ = try engine.initializeFans()
    let result = try engine.testIncrease(index: 1, role: .cpu, wait: { _ in })
    #expect(result.during.rawDuty > result.before.rawDuty)
    #expect(result.after.rawDuty == 137 && !result.after.automatic)
    _ = try engine.setDuty(index: 1, percent: 90, role: .cpu)
    try engine.restoreAllOverrides()
    #expect(driver.raw[1] == 137 && !driver.automatic[1])
}

@Test func motherboardRetainsRollbackResponsibilityAfterFailure() throws {
    let driver = FakeMotherboard()
    let tested = MotherboardEngine(transport: driver)
    _ = try tested.initializeFans()
    driver.failNextWrite = true
    #expect(throws: Error.self) { try tested.setDuty(index: 1, percent: 60, role: .cpu) }
    #expect(tested.overriddenChannels == [1])
    driver.restoreFailures = 1
    #expect(throws: Error.self) { try tested.restoreAllOverrides() }
    #expect(tested.overriddenChannels == [1])
    try tested.restoreAllOverrides()
    #expect(tested.overriddenChannels.isEmpty && driver.automatic[1])
}

@Test func motherboardDoesNotOverlapRetiringHelperAfterTimeout() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let events = directory.appendingPathComponent("events")
    let script = """
    import json,pathlib,sys,time
    p=pathlib.Path(sys.argv[1]); first=not p.exists()
    with p.open('a') as f: f.write('start\\n')
    for line in sys.stdin:
        request=json.loads(line)
        if first: time.sleep(4); first=False
        print(json.dumps({'id':request['id'],'cpu':{'temperature':50,'powerWatts':65}}),flush=True)
    with p.open('a') as f: f.write('end\\n')
    """
    let service = MotherboardService(helperExecutable: URL(fileURLWithPath: "/usr/bin/python3"),
        helperArguments: ["-u", "-c", script, events.path], requestTimeout: 1)
    await #expect(throws: Error.self) { try await service.cpuMetrics() }
    await #expect(throws: Error.self) { try await service.cpuMetrics() }
    #expect(try String(contentsOf: events, encoding: .utf8) == "start\n")
    try await Task.sleep(nanoseconds: 1_500_000_000)
    let metrics = try await service.cpuMetrics()
    #expect(metrics.temperature == 50)
    try await service.shutdown()
    #expect(try String(contentsOf: events, encoding: .utf8) == "start\nend\nstart\nend\n")
}

@Test func motherboardShutdownReportsFailedRestorationAndPreventsRestart() async throws {
    let script = """
    import json,sys
    for line in sys.stdin:
        request=json.loads(line)
        print(json.dumps({'id':request['id'],'cpu':{'temperature':50,'powerWatts':65}}),flush=True)
    sys.exit(7)
    """
    let service = MotherboardService(helperExecutable: URL(fileURLWithPath: "/usr/bin/python3"),
        helperArguments: ["-u", "-c", script])
    _ = try await service.cpuMetrics()
    await #expect(throws: Error.self) { try await service.shutdown() }
    await #expect(throws: Error.self) { try await service.cpuMetrics() }
}

@Test func motherboardDeclinedAuthorizationDoesNotTriggerRestorePrompts() throws {
    for test in [false, true] {
        let driver = FakeMotherboard()
        let tested = MotherboardEngine(transport: driver)
        _ = try tested.initializeFans()
        driver.denyNextWrite = true
        if test {
            #expect(throws: Error.self) { try tested.testIncrease(index: 1, role: .cpu, wait: { _ in }) }
        } else {
            #expect(throws: Error.self) { try tested.setDuty(index: 1, percent: 60, role: .cpu) }
        }
        try tested.restoreAllOverrides()
        #expect(tested.overriddenChannels.isEmpty)
        #expect(!driver.calls.contains { $0.0 == 96 })
        #expect(driver.raw[1] == 128 && driver.automatic[1])
    }
}
