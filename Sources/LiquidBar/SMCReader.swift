// AppleSMC reader adapted from exelban/Stats (MIT).
// https://github.com/exelban/stats/blob/master/SMC/smc.swift

import Foundation
import IOKit

private enum SMCCommand: UInt8 {
    case kernelIndex = 2
    case readBytes = 5
    case readKeyInfo = 9
}

private struct SMCKeyData {
    typealias Bytes = (
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
    )

    struct Version {
        var major: UInt8 = 0
        var minor: UInt8 = 0
        var build: UInt8 = 0
        var reserved: UInt8 = 0
        var release: UInt16 = 0
    }

    struct LimitData {
        var version: UInt16 = 0
        var length: UInt16 = 0
        var cpuPLimit: UInt32 = 0
        var gpuPLimit: UInt32 = 0
        var memPLimit: UInt32 = 0
    }

    struct KeyInfo {
        var dataSize: IOByteCount32 = 0
        var dataType: UInt32 = 0
        var dataAttributes: UInt8 = 0
    }

    var key: UInt32 = 0
    var version = Version()
    var limitData = LimitData()
    var keyInfo = KeyInfo()
    var padding: UInt16 = 0
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: Bytes = (
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
    )
}

private struct SMCValue {
    let key: String
    var dataSize: UInt32 = 0
    var dataType = ""
    var bytes = Array(repeating: UInt8(0), count: 32)
}

final class SMCReader {
    private var connection: io_connect_t = 0
    private let preferredKeys = ["TC0P", "TC0E", "TC0F", "TC0T", "TC0p"]

    init?() {
        let matching = IOServiceMatching("AppleSMC")
        let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }

        guard IOServiceOpen(service, mach_task_self_, 0, &connection) == kIOReturnSuccess else {
            return nil
        }
    }

    deinit {
        if connection != 0 { IOServiceClose(connection) }
    }

    func cpuTemperature() -> Double? {
        for key in preferredKeys {
            if let value = readValue(key), value.isFinite, (0...110).contains(value) {
                return value
            }
        }
        return nil
    }

    private func readValue(_ key: String) -> Double? {
        guard key.utf8.count == 4 else { return nil }
        var value = SMCValue(key: key)
        guard read(&value) == kIOReturnSuccess, value.dataSize > 0 else { return nil }

        switch value.dataType {
        case "sp78":
            let raw = Int16(bitPattern: UInt16(value.bytes[0]) << 8 | UInt16(value.bytes[1]))
            return Double(raw) / 256.0
        case "flt ":
            let bits = UInt32(value.bytes[0]) |
                UInt32(value.bytes[1]) << 8 |
                UInt32(value.bytes[2]) << 16 |
                UInt32(value.bytes[3]) << 24
            return Double(Float(bitPattern: bits))
        case "ui8 ":
            return Double(value.bytes[0])
        case "ui16":
            return Double(UInt16(value.bytes[0]) << 8 | UInt16(value.bytes[1]))
        default:
            return nil
        }
    }

    private func read(_ value: inout SMCValue) -> kern_return_t {
        var input = SMCKeyData()
        var output = SMCKeyData()
        input.key = fourCharCode(value.key)
        input.data8 = SMCCommand.readKeyInfo.rawValue

        var result = call(input: &input, output: &output)
        guard result == kIOReturnSuccess else { return result }

        value.dataSize = UInt32(output.keyInfo.dataSize)
        value.dataType = fourCharString(output.keyInfo.dataType)
        input.keyInfo.dataSize = output.keyInfo.dataSize
        input.data8 = SMCCommand.readBytes.rawValue

        result = call(input: &input, output: &output)
        guard result == kIOReturnSuccess else { return result }

        withUnsafeBytes(of: &output.bytes) { raw in
            let count = min(Int(value.dataSize), value.bytes.count, raw.count)
            value.bytes.replaceSubrange(0..<count, with: raw.prefix(count))
        }
        return kIOReturnSuccess
    }

    private func call(input: inout SMCKeyData, output: inout SMCKeyData) -> kern_return_t {
        let inputSize = MemoryLayout<SMCKeyData>.stride
        var outputSize = MemoryLayout<SMCKeyData>.stride
        return IOConnectCallStructMethod(
            connection,
            UInt32(SMCCommand.kernelIndex.rawValue),
            &input,
            inputSize,
            &output,
            &outputSize
        )
    }

    private func fourCharCode(_ string: String) -> UInt32 {
        string.utf8.reduce(0) { ($0 << 8) | UInt32($1) }
    }

    private func fourCharString(_ value: UInt32) -> String {
        let bytes = [
            UInt8((value >> 24) & 0xff), UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff), UInt8(value & 0xff),
        ]
        return String(bytes: bytes, encoding: .ascii) ?? ""
    }
}
