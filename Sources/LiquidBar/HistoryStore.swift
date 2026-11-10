import Combine
import Foundation

@MainActor
final class HistoryStore: ObservableObject {
    @Published private(set) var samples: [HistorySample] = []

    private let retention: TimeInterval = 86_400
    private let url: URL
    private var lastSave = Date.distantPast

    init(baseDirectory: URL? = nil) {
        let directory = baseDirectory ?? SettingsStore.applicationSupportDirectory()
        url = directory.appendingPathComponent("history.json")
        load()
    }

    func append(cpuTemperature: Double?, snapshot: DeviceSnapshot, gpu: GPUReading? = nil) {
        let sample = HistorySample(
            timestamp: Date(),
            cpuTemperature: cpuTemperature,
            liquidTemperature: snapshot.liquidTemperature,
            fanRPM: snapshot.fanRPM,
            pumpRPM: snapshot.pumpRPM,
            gpuTemperature: gpu?.temperature,
            gpuFanRPM: gpu?.fanRPM
        )
        samples.append(sample)
        prune()
        if Date().timeIntervalSince(lastSave) >= 60 { save() }
    }

    func samples(in range: ChartRange, maximumPoints: Int = 360) -> [HistorySample] {
        let cutoff = Date().addingTimeInterval(-range.rawValue)
        let filtered = samples.filter { $0.timestamp >= cutoff }
        guard filtered.count > maximumPoints else { return filtered }
        let stride = max(1, filtered.count / maximumPoints)
        return Swift.stride(from: 0, to: filtered.count, by: stride).map { filtered[$0] }
    }

    func flush() { save() }

    private func load() {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder.liquidBar.decode([HistorySample].self, from: data) else {
            return
        }
        samples = decoded
        prune()
    }

    private func prune() {
        let cutoff = Date().addingTimeInterval(-retention)
        if let firstValid = samples.firstIndex(where: { $0.timestamp >= cutoff }) {
            if firstValid > 0 { samples.removeFirst(firstValid) }
        } else if !samples.isEmpty {
            samples.removeAll(keepingCapacity: true)
        }
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder.pretty.encode(samples)
            try data.write(to: url, options: .atomic)
            lastSave = Date()
        } catch {
            AppLogger.shared.log("history write failed: \(error.localizedDescription)")
        }
    }
}
