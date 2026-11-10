import Foundation
import IOKit

struct GPUReading: Codable, Equatable, Identifiable {
    let id: UInt64
    let name: String
    var temperature: Double?
    var fanRPM: Int?
    // This is the driver's reported percentage, not a verified PWM target.
    var fanPercent: Double?
    var powerWatts: Double?

    var withoutTelemetry: GPUReading {
        GPUReading(id: id, name: name)
    }
}

struct GPUSnapshot: Codable, Equatable {
    var sampledAt = Date()
    var devices: [GPUReading] = []

    static let unavailable = GPUSnapshot()

    func primaryReading(now: Date = Date()) -> GPUReading? {
        guard let device = devices.first else { return nil }
        let age = now.timeIntervalSince(sampledAt)
        return (0...6).contains(age) ? device : device.withoutTelemetry
    }
}

// Reading registry properties does not open a GPU user client or write registers.
// Its own actor keeps telemetry independent of USB and CPU fan authorization.
actor GPUReader {
    func read() -> GPUSnapshot { Self.readSnapshot() }

    static func readSnapshot() -> GPUSnapshot {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS else {
            return GPUSnapshot()
        }
        defer { IOObjectRelease(iterator) }
        var devices: [GPUReading] = []
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            var className = [CChar](repeating: 0, count: 128)
            guard IOObjectGetClass(entry, &className) == KERN_SUCCESS,
                  String(cString: className).hasPrefix("AMDRadeon") else { continue }
            var id: UInt64 = 0
            guard IORegistryEntryGetRegistryEntryID(entry, &id) == KERN_SUCCESS else { continue }
            let statistics = IORegistryEntryCreateCFProperty(
                entry, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0
            )?.takeRetainedValue() as? [String: Any] ?? [:]
            let model = IORegistryEntrySearchCFProperty(
                entry, kIOServicePlane, "model" as CFString, kCFAllocatorDefault,
                IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)
            )
            devices.append(parse(id: id, name: modelName(model), statistics: statistics))
        }
        return GPUSnapshot(devices: uniqueDevices(devices))
    }

    static func uniqueDevices(_ devices: [GPUReading]) -> [GPUReading] {
        var seen = Set<UInt64>()
        return devices.filter { seen.insert($0.id).inserted }.sorted { $0.id < $1.id }
    }

    static func parse(id: UInt64, name: String, statistics: [String: Any]) -> GPUReading {
        GPUReading(
            id: id, name: name,
            temperature: number(statistics["Temperature(C)"], in: 0...150),
            fanRPM: number(statistics["Fan Speed(RPM)"], in: 0...30_000).map { Int($0.rounded()) },
            fanPercent: number(statistics["Fan Speed(%)"], in: 0...100),
            powerWatts: number(statistics["Total Power(W)"], in: 0...2_000)
        )
    }

    private static func number(_ value: Any?, in range: ClosedRange<Double>) -> Double? {
        guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() else { return nil }
        let number = value.doubleValue
        return number.isFinite && range.contains(number) ? number : nil
    }

    private static func modelName(_ value: Any?) -> String {
        let name: String?
        if let data = value as? Data {
            name = String(data: data.prefix { $0 != 0 }, encoding: .utf8)
        } else {
            name = value as? String
        }
        let cleaned = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return cleaned.isEmpty ? "AMD Radeon GPU" : cleaned
    }
}
