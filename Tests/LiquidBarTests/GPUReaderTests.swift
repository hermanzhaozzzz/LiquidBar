import Foundation
import Testing
@testable import LiquidBar

@Test
func gpuTelemetryPreservesValidZeroAndMissingFieldsSeparately() {
    let stopped = GPUReader.parse(id: 1, name: "Radeon RX 5700 XT", statistics: [
        "Temperature(C)": 51, "Fan Speed(RPM)": 0, "Fan Speed(%)": 0, "Total Power(W)": 35,
    ])
    #expect(stopped.temperature == 51)
    #expect(stopped.fanRPM == 0)
    #expect(stopped.fanPercent == 0)
    #expect(stopped.powerWatts == 35)
    let unavailable = GPUReader.parse(id: 1, name: "Radeon RX 5700 XT", statistics: [:])
    #expect(unavailable.temperature == nil)
    #expect(unavailable.fanRPM == nil)
    #expect(unavailable.fanPercent == nil)
}

@Test
func gpuRejectsInvalidDriverValuesWithoutDiscardingOtherSensors() {
    let reading = GPUReader.parse(id: 1, name: "GPU", statistics: [
        "Temperature(C)": Double.nan, "Fan Speed(RPM)": -1,
        "Fan Speed(%)": true, "Total Power(W)": 36.5,
    ])
    #expect(reading.temperature == nil)
    #expect(reading.fanRPM == nil)
    #expect(reading.fanPercent == nil)
    #expect(reading.powerWatts == 36.5)
    let running = GPUReader.parse(id: 1, name: "GPU", statistics: [
        "Temperature(C)": 52, "Fan Speed(RPM)": 1075, "Fan Speed(%)": 31,
    ])
    #expect(running.fanRPM == 1075)
    #expect(running.fanPercent == 31)
}

@Test
func gpuRegistryDuplicatesDoNotBecomeSeparateCards() {
    let first = GPUReading(id: 7, name: "Radeon", temperature: 50, fanRPM: 0)
    let second = GPUReading(id: 9, name: "Radeon", temperature: 55, fanRPM: 900)
    #expect(GPUReader.uniqueDevices([second, first, first]) == [first, second])
}

@Test
func gpuStaleSnapshotKeepsIdentityButNotLiveReadings() {
    let now = Date()
    let reading = GPUReading(id: 1, name: "Radeon", temperature: 51, fanRPM: 1075, fanPercent: 31)
    let fresh = GPUSnapshot(sampledAt: now.addingTimeInterval(-2), devices: [reading])
    #expect(fresh.primaryReading(now: now) == reading)
    let stale = GPUSnapshot(sampledAt: now.addingTimeInterval(-7), devices: [reading])
    #expect(stale.primaryReading(now: now)?.name == "Radeon")
    #expect(stale.primaryReading(now: now)?.temperature == nil)
    #expect(stale.primaryReading(now: now)?.fanRPM == nil)
    #expect(GPUSnapshot().primaryReading() == nil)
}

@Test
func oldHistoryLoadsAndNewHistoryIncludesGPU() throws {
    let legacy = Data(#"{"timestamp":1000,"cpuTemperature":60,"fanRPM":[900,900,0]}"#.utf8)
    let old = try JSONDecoder().decode(HistorySample.self, from: legacy)
    #expect(old.cpuTemperature == 60)
    #expect(old.gpuTemperature == nil)
    #expect(old.gpuFanRPM == nil)
    let new = HistorySample(timestamp: Date(), cpuTemperature: nil, liquidTemperature: nil,
                            fanRPM: [nil, nil, nil], pumpRPM: nil, gpuTemperature: 52, gpuFanRPM: 0)
    let roundTrip = try JSONDecoder().decode(HistorySample.self, from: JSONEncoder().encode(new))
    #expect(roundTrip.gpuTemperature == 52)
    #expect(roundTrip.gpuFanRPM == 0)
}

@Test @MainActor
func historyStoresGPUIndependentlyOfCPUAndUSB() {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = HistoryStore(baseDirectory: directory)
    store.append(cpuTemperature: nil, snapshot: .unavailable,
                 gpu: GPUReading(id: 1, name: "Radeon", temperature: 51, fanRPM: 0))
    #expect(store.samples.last?.gpuTemperature == 51)
    #expect(store.samples.last?.gpuFanRPM == 0)
    #expect(store.samples.last?.cpuTemperature == nil)
}
