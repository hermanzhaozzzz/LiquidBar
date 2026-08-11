import Foundation

final class AppLogger {
    static let shared = AppLogger()
    private let queue = DispatchQueue(label: "LiquidBar.Logger")
    private let maximumBytes = 1_000_000
    private let url: URL

    private init() {
        url = SettingsStore.applicationSupportDirectory().appendingPathComponent("LiquidBar.log")
    }

    func log(_ message: String) {
        queue.async {
            do {
                try FileManager.default.createDirectory(
                    at: self.url.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                self.rotateIfNeeded()
                let stamp = ISO8601DateFormatter().string(from: Date())
                let data = "\(stamp) \(message)\n".data(using: .utf8)!
                if !FileManager.default.fileExists(atPath: self.url.path) {
                    FileManager.default.createFile(atPath: self.url.path, contents: data)
                } else {
                    let handle = try FileHandle(forWritingTo: self.url)
                    defer { try? handle.close() }
                    try handle.seekToEnd()
                    try handle.write(contentsOf: data)
                }
            } catch {
                // Logging must never disrupt cooling control.
            }
        }
    }

    func contents() -> String {
        queue.sync {
            (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        }
    }

    func clear() {
        queue.sync { try? FileManager.default.removeItem(at: url) }
    }

    private func rotateIfNeeded() {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size >= maximumBytes else { return }
        let data = try? Data(contentsOf: url)
        let tail = data.map { Data($0.suffix(maximumBytes / 2)) }
        try? tail?.write(to: url, options: .atomic)
    }
}
