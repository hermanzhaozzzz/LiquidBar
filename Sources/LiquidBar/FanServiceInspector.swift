import Darwin
import Foundation
import Security
import FanControlShared

// Compares three signatures: the running process, the app bundle on disk, and
// the fan service's pinned GUI requirement. This catches the case where the app
// was replaced while a stale process kept running, which otherwise surfaces as a
// raw "LiquidBar changed since fan service installation" error.
enum FanServiceInspector {
    private static var cache: (configDate: Date?, appDate: Date?, state: FanServiceHealth)?
    private static let lock = NSLock()

    static func invalidate() {
        lock.lock()
        cache = nil
        lock.unlock()
    }

    static func inspect(force: Bool = false) -> FanServiceHealth {
        let configURL = URL(fileURLWithPath: FanControlConstants.configuration)
        let appURL = Bundle.main.bundleURL
        let configDate = try? configURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        let appDate = try? appURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate

        lock.lock()
        if !force, let cache, cache.configDate == configDate, cache.appDate == appDate {
            let state = cache.state
            lock.unlock()
            return state
        }
        lock.unlock()

        let state = compute()
        lock.lock()
        cache = (configDate, appDate, state)
        lock.unlock()
        return state
    }

    private static func compute() -> FanServiceHealth {
        guard FileManager.default.fileExists(atPath: FanControlConstants.configuration) else {
            return .notInstalled
        }
        guard let policy = try? FanControlConfiguration.readSecurely(),
              policy.allowedUID == geteuid(),
              let configHash = hash(from: policy.guiRequirement) else {
            return .needsUpdate
        }
        let runningHash = runningCDHash()
        let diskHash = diskCDHash()
        if runningHash == configHash { return .installed }
        if diskHash == configHash { return .needsRestart }
        return .needsUpdate
    }

    private static func hash(from requirement: String) -> String? {
        guard let range = requirement.range(of: #"[0-9a-fA-F]{40}"#, options: .regularExpression) else {
            return nil
        }
        return String(requirement[range]).lowercased()
    }

    private static func runningCDHash() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else {
            return nil
        }
        return cdhash(staticCode)
    }

    private static func diskCDHash() -> String? {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(Bundle.main.bundleURL as CFURL, [], &staticCode) == errSecSuccess,
              let staticCode else {
            return nil
        }
        return cdhash(staticCode)
    }

    private static func cdhash(_ code: SecStaticCode) -> String? {
        var info: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
        guard SecCodeCopySigningInformation(code, flags, &info) == errSecSuccess,
              let dict = info as? [String: Any],
              let unique = dict[kSecCodeInfoUnique as String] as? Data else {
            return nil
        }
        return unique.map { String(format: "%02x", $0) }.joined()
    }
}
