import Foundation
import IOKit

enum MotherboardFanRole: String, Codable, CaseIterable, Sendable {
    case cpu, pump
    var minimumDuty: Int { self == .pump ? 80 : 30 }
}
struct MotherboardCPUMetrics: Codable, Equatable, Sendable {
    let temperature: Double?
    let powerWatts: Double?
}
struct MotherboardFanReading: Codable, Identifiable, Equatable, Sendable {
    var id: Int { index }
    let index: Int
    let name: String
    let rpm: Int
    let duty: Int
    let automatic: Bool
    let rawDuty: UInt8
}
struct MotherboardFanSnapshot: Codable, Equatable, Sendable {
    let driverVersion: String
    let chipID: UInt64?
    let fans: [MotherboardFanReading]
}
struct MotherboardFanTestResult: Codable, Equatable, Sendable {
    let before: MotherboardFanReading
    let during: MotherboardFanReading
    let after: MotherboardFanReading
}
struct MotherboardError: LocalizedError {
    let message: String
    var permissionDenied = false
    var errorDescription: String? { message }
}
struct MotherboardDriverResponse {
    var bytes: Data
    var scalars: [UInt64] = []
}
protocol MotherboardDriverTransport: AnyObject {
    func call(selector: UInt32, inputs: [UInt64], capacity: Int) throws -> MotherboardDriverResponse
}

// ABI verified against AMDRyzenCPUPowerManagement release 0.7.2.
// One connection allows the driver's "Until Process Terminate" authorization.
final class MotherboardIOTransport: MotherboardDriverTransport {
    private var connection: io_connect_t = 0
    deinit { if connection != 0 { IOServiceClose(connection) } }
    func call(selector: UInt32, inputs: [UInt64], capacity: Int) throws -> MotherboardDriverResponse {
        if connection == 0 {
            let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AMDRyzenCPUPowerManagement"))
            guard service != 0 else { throw MotherboardError(message: "AMDRyzenCPUPowerManagement is unavailable.") }
            defer { IOObjectRelease(service) }
            let status = IOServiceOpen(service, mach_task_self_, 0, &connection)
            guard status == kIOReturnSuccess else { throw MotherboardError(message: "Cannot open the motherboard driver.") }
        }
        var output = [UInt8](repeating: 0, count: max(1, capacity))
        var outputSize = capacity
        var scalarOutput = [UInt64](repeating: 0, count: 1)
        var scalarCount: UInt32 = 1
        let status = inputs.withUnsafeBufferPointer { input in
            output.withUnsafeMutableBytes { out in
                scalarOutput.withUnsafeMutableBufferPointer { scalars in
                    IOConnectCallMethod(connection, selector, input.baseAddress, UInt32(inputs.count), nil, 0,
                        scalars.baseAddress, &scalarCount, capacity == 0 ? nil : out.baseAddress, &outputSize)
                }
            }
        }
        guard status == kIOReturnSuccess else {
            if status == kIOReturnNotPrivileged { throw MotherboardError(message: "Motherboard control was not authorized. Allow the driver's authorization prompt and retry.", permissionDenied: true) }
            if status == kIOReturnNoDevice { throw MotherboardError(message: "Motherboard fan controller is not initialized or unsupported.") }
            throw MotherboardError(message: "Motherboard operation \(selector) failed (\(String(format: "0x%08x", UInt32(bitPattern: status)))).")
        }
        guard outputSize <= capacity, scalarCount <= 1 else { throw MotherboardError(message: "Invalid motherboard driver response.") }
        return MotherboardDriverResponse(bytes: Data(output.prefix(outputSize)), scalars: Array(scalarOutput.prefix(Int(scalarCount))))
    }
}
