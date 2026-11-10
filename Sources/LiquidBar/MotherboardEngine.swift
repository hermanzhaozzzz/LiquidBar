import Foundation

/// Used only on the helper's serial queue; injectable for hardware-free tests.
final class MotherboardEngine {
    private let transport: MotherboardDriverTransport
    private var version: String?
    private var chipID: UInt64?
    private var initialized = false
    private var names: [String] = []
    private(set) var overriddenChannels = Set<Int>()
    private var originalReadings: [Int: MotherboardFanReading] = [:]
    init(transport: MotherboardDriverTransport = MotherboardIOTransport()) { self.transport = transport }

    private func driverVersion() throws -> String {
        if let version { return version }
        let data = try transport.call(selector: 8, inputs: [], capacity: 64).bytes
        let value = String(decoding: data.prefix { $0 != 0 }, as: UTF8.self)
        guard value == "0.7.2" else { throw MotherboardError(message: "Unsupported motherboard driver version \(value); expected 0.7.2.") }
        version = value
        return value
    }
    func cpuMetrics() throws -> MotherboardCPUMetrics {
        _ = try driverVersion()
        let data = try transport.call(selector: 4, inputs: [], capacity: 67 * 4).bytes
        guard data.count >= 12 else { throw MotherboardError(message: "Incomplete CPU sensor response.") }
        let power = Double(data.withUnsafeBytes { $0.loadUnaligned(as: Float.self) })
        let temp = Double(data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: Float.self) })
        return MotherboardCPUMetrics(temperature: temp.isFinite && (0...125).contains(temp) ? temp : nil,
            powerWatts: power.isFinite && (0...1000).contains(power) ? power : nil)
    }
    func initializeFans() throws -> MotherboardFanSnapshot {
        _ = try driverVersion()
        // Explicit initialization can unlock the SuperIO I/O window. It does
        // not change fan duty. Never called implicitly by CPU sensor polling.
        let values = try integers(90)
        guard values.count == 2, values[0] == 1 else { throw MotherboardError(message: "Unsupported motherboard fan controller.") }
        chipID = values[1]
        initialized = true
        names = []
        return try readFans()
    }
    func readFans() throws -> MotherboardFanSnapshot {
        let driver = try driverVersion()
        guard initialized else { throw MotherboardError(message: "Initialize motherboard fans first.") }
        guard let number = try integers(91).first, (1...7).contains(number) else { throw MotherboardError(message: "Invalid motherboard fan count.") }
        let count = Int(number)
        if names.count != count {
            names = try (0..<count).map { index in
                let data = try transport.call(selector: 92, inputs: [UInt64(index)], capacity: 128).bytes
                return String(decoding: data.prefix { $0 != 0 }, as: UTF8.self)
            }
        }
        let rpms = try integers(93), controls = try integers(94)
        guard rpms.count == count, controls.count == count else { throw MotherboardError(message: "Incomplete motherboard fan response.") }
        let fans = try (0..<count).map { index -> MotherboardFanReading in
            guard rpms[index] <= 65535, controls[index] >> 8 <= 255 else { throw MotherboardError(message: "Invalid motherboard fan response.") }
            let raw = UInt8(controls[index] >> 8)
            return MotherboardFanReading(index: index, name: names[index], rpm: Int(rpms[index]),
                duty: Int((Double(raw) * 100 / 255).rounded()), automatic: controls[index] & 1 != 0, rawDuty: raw)
        }
        return MotherboardFanSnapshot(driverVersion: driver, chipID: chipID, fans: fans)
    }
    func setDuty(index: Int, percent: Int, role: MotherboardFanRole) throws -> MotherboardFanSnapshot {
        guard (role.minimumDuty...100).contains(percent) else { throw MotherboardError(message: "Duty must be \(role.minimumDuty)...100%.") }
        let previous = try channel(index)
        if originalReadings[index] == nil { originalReadings[index] = previous }
        try write(index, raw: UInt8((Double(percent) * 255 / 100).rounded()))
        return try readFans()
    }
    func restoreAutomatic(index: Int) throws -> MotherboardFanSnapshot {
        _ = try channel(index)
        try restoreMode(index)
        return try readFans()
    }
    func restoreAllOverrides() throws {
        var failures: [String] = []
        for index in overriddenChannels.sorted() {
            do { try restoreOriginal(index) }
            catch { failures.append("\(index + 1): \(error.localizedDescription)") }
        }
        if !failures.isEmpty { throw MotherboardError(message: "Restore failed: " + failures.joined(separator: "; ")) }
    }
    func testIncrease(index: Int, role: MotherboardFanRole, duration: TimeInterval = 3,
                      wait: (TimeInterval) throws -> Void = { Thread.sleep(forTimeInterval: $0) }) throws -> MotherboardFanTestResult {
        let before = try channel(index)
        guard before.rawDuty < 255 else { throw MotherboardError(message: "Already at 100%; an increase-only test cannot identify this header.") }
        let wasOverridden = overriddenChannels.contains(index)
        let original = originalReadings[index]
        if original == nil { originalReadings[index] = before }
        let target = UInt8(min(255, max(Int(before.rawDuty) + 13, Int(ceil(Double(role.minimumDuty) * 255 / 100)))))
        func restore() throws {
            if before.automatic { try restoreMode(index) }
            else { try write(index, raw: before.rawDuty) }
            if !wasOverridden { overriddenChannels.remove(index) }
            originalReadings[index] = original
        }
        let during: MotherboardFanReading
        do {
            try write(index, raw: target)
            try wait(min(5, max(1, duration)))
            during = try channel(index)
        } catch {
            if (error as? MotherboardError)?.permissionDenied != true { try restore() }
            else { originalReadings[index] = original }
            throw error
        }
        try restore()
        return MotherboardFanTestResult(before: before, during: during, after: try channel(index))
    }
    private func channel(_ index: Int) throws -> MotherboardFanReading {
        let snapshot = try readFans()
        guard snapshot.fans.indices.contains(index) else { throw MotherboardError(message: "Invalid motherboard channel.") }
        return snapshot.fans[index]
    }
    private func write(_ index: Int, raw: UInt8) throws {
        // No all-fan command: only the explicitly selected physical header.
        let previouslyOverridden = overriddenChannels.contains(index)
        overriddenChannels.insert(index) // Keep responsibility for uncertain/partial write failures.
        do { _ = try transport.call(selector: 95, inputs: [UInt64(index), UInt64(raw)], capacity: 0) }
        catch {
            // The 0.7.2 kernel returns NotPrivileged before touching registers.
            // Do not turn a declined first write into repeated restore prompts.
            if (error as? MotherboardError)?.permissionDenied == true && !previouslyOverridden {
                overriddenChannels.remove(index)
                originalReadings.removeValue(forKey: index)
            }
            throw error
        }
    }
    private func restoreMode(_ index: Int) throws {
        _ = try transport.call(selector: 96, inputs: [UInt64(index)], capacity: 0)
        overriddenChannels.remove(index)
        originalReadings.removeValue(forKey: index)
    }
    private func restoreOriginal(_ index: Int) throws {
        if let original = originalReadings[index], !original.automatic {
            try write(index, raw: original.rawDuty)
            overriddenChannels.remove(index)
            originalReadings.removeValue(forKey: index)
        } else { try restoreMode(index) }
    }
    private func integers(_ selector: UInt32) throws -> [UInt64] {
        let data = try transport.call(selector: selector, inputs: [], capacity: 512).bytes
        guard data.count.isMultiple(of: 8) else { throw MotherboardError(message: "Invalid driver integer response.") }
        return stride(from: 0, to: data.count, by: 8).map { offset in
            data.withUnsafeBytes { UInt64(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt64.self)) }
        }
    }
}
