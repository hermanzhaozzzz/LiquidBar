import Combine
import Foundation

@MainActor
final class SettingsStore: ObservableObject {
    @Published var value: AppSettings {
        didSet {
            var clean = value
            clean.sanitize()
            if clean != value {
                value = clean
                return
            }
            save()
        }
    }

    private let url: URL

    init(baseDirectory: URL? = nil) {
        let directory = baseDirectory ?? Self.applicationSupportDirectory()
        url = directory.appendingPathComponent("settings.json")
        if let data = try? Data(contentsOf: url),
           var decoded = try? JSONDecoder().decode(AppSettings.self, from: data) {
            decoded.sanitize()
            value = decoded
        } else {
            value = AppSettings()
        }
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder.pretty.encode(value)
            try data.write(to: url, options: .atomic)
        } catch {
            AppLogger.shared.log("settings write failed: \(error.localizedDescription)")
        }
    }

    nonisolated static func applicationSupportDirectory() -> URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return root.appendingPathComponent("LiquidBar", isDirectory: true)
    }
}

extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

extension JSONDecoder {
    static var liquidBar: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
