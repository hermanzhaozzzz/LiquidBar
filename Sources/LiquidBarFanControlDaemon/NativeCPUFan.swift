import Darwin
import FanControlShared
import Foundation
import IOKit

struct CPUFanSample: Equatable {
    let rpm: Int
    let duty: Int
    let automatic: Bool
    let temperature: Double?
    var sampledAt = Date()
}

protocol CPUFanBackend: AnyObject {
    func read() throws -> CPUFanSample
    func set(percent: Int) throws
    func restoreAutomatic() throws
}

// This root process exposes no generic selector or arbitrary header operation.
// All SuperIO access is serialized by the server's single queue.
final class NativeCPUFan: CPUFanBackend {
    private var connection: io_connect_t = 0
    private let index: Int

    init(configuration: FanControlConfiguration) throws {
        try configuration.validate()
        index = configuration.cpuIndex
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AMDRyzenCPUPowerManagement"))
        guard service != 0 else { throw FanControlError("AMDRyzenCPUPowerManagement is unavailable.") }
        defer { IOObjectRelease(service) }
        guard IOServiceOpen(service, mach_task_self_, 0, &connection) == kIOReturnSuccess else {
            throw FanControlError("Cannot open the motherboard driver.")
        }
        let versionBytes = try call(8, capacity: 64)
        let version = String(decoding: versionBytes.prefix { $0 != 0 }, as: UTF8.self)
        guard version == configuration.driverVersion else { throw FanControlError("Unexpected motherboard driver version.") }
        let initialized = try integers(90)
        guard initialized.count == 2, initialized[0] == 1, initialized[1] == configuration.chipID else {
            throw FanControlError("The installed CPU header policy does not match this controller.")
        }
    }

    deinit { if connection != 0 { IOServiceClose(connection) } }

    func read() throws -> CPUFanSample {
        let count = try integers(91)
        guard count.count == 1, (2...7).contains(count[0]) else { throw FanControlError("Invalid fan count.") }
        let rpms = try integers(93), controls = try integers(94)
        guard rpms.count == Int(count[0]), controls.count == Int(count[0]), index < rpms.count,
              rpms[index] <= 65535, controls[index] >> 8 <= 255 else {
            throw FanControlError("Invalid CPU fan telemetry.")
        }
        let cpu = try call(4, capacity: 67 * 4)
        guard cpu.count >= 12 else { throw FanControlError("Missing CPU telemetry.") }
        let temperature = Double(cpu.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: Float.self) })
        return CPUFanSample(rpm: Int(rpms[index]), duty: Int((Double(controls[index] >> 8) * 100 / 255).rounded()),
                            automatic: controls[index] & 1 != 0,
                            temperature: temperature.isFinite && (0...125).contains(temperature) ? temperature : nil)
    }

    func set(percent: Int) throws {
        guard (30...100).contains(percent) else { throw FanControlError("CPU fan duty must be 30–100%.") }
        let raw = UInt64((Double(percent) * 255 / 100).rounded())
        _ = try call(95, inputs: [UInt64(index), raw], capacity: 0)
    }

    func restoreAutomatic() throws { _ = try call(96, inputs: [UInt64(index)], capacity: 0) }

    private func integers(_ selector: UInt32) throws -> [UInt64] {
        let data = try call(selector, capacity: 512)
        guard data.count.isMultiple(of: 8) else { throw FanControlError("Invalid driver response length.") }
        return stride(from: 0, to: data.count, by: 8).map { offset in
            data.withUnsafeBytes { UInt64(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt64.self)) }
        }
    }

    private func call(_ selector: UInt32, inputs: [UInt64] = [], capacity: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: max(1, capacity))
        var size = capacity
        var scalar: UInt64 = 0
        var scalarCount: UInt32 = 1
        let result = inputs.withUnsafeBufferPointer { input in
            bytes.withUnsafeMutableBytes { output in
                IOConnectCallMethod(connection, selector, input.baseAddress, UInt32(inputs.count), nil, 0,
                                    &scalar, &scalarCount, capacity == 0 ? nil : output.baseAddress, &size)
            }
        }
        guard result == kIOReturnSuccess, size <= capacity, scalarCount <= 1 else {
            throw FanControlError("Motherboard request failed (\(selector), \(String(format: "0x%08x", UInt32(bitPattern: result)))).")
        }
        return Data(bytes.prefix(size))
    }
}
