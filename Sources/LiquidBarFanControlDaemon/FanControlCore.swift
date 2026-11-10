import FanControlShared
import Foundation

// Accessed only on FanControlServer.queue. A single authenticated connection
// owns a manual lease; other clients cannot renew or replace that lease.
final class FanControlCore {
    private let configuration: FanControlConfiguration
    private let backend: CPUFanBackend
    private let clock: () -> TimeInterval
    private let log: (String, String, Bool?, String?) -> Void
    private(set) var owner: UUID?
    private var deadline: TimeInterval = 0
    private var sample: CPUFanSample?
    private(set) var lastReason = "starting"
    private(set) var error: String?
    private(set) var sleeping = false
    private(set) var draining = false

    init(configuration: FanControlConfiguration, backend: CPUFanBackend,
         clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         log: @escaping (String, String, Bool?, String?) -> Void) {
        self.configuration = configuration; self.backend = backend; self.clock = clock; self.log = log
    }

    func start() throws { try restore(reason: "startup") }

    func status(client: UUID, renew: Bool = true) throws -> FanControlStatus {
        if owner != nil && clock() >= deadline { try restore(reason: "lease_timeout") }
        if owner == client && renew { deadline = clock() + FanControlConstants.leaseSeconds }
        if sample == nil { sample = try backend.read() }
        guard let sample else { throw FanControlError("CPU fan status is unavailable.") }
        return FanControlStatus(cpuIndex: configuration.cpuIndex, chipID: configuration.chipID,
                                driverVersion: configuration.driverVersion, rpm: sample.rpm, duty: sample.duty,
                                automatic: sample.automatic, temperature: sample.temperature, sampledAt: sample.sampledAt,
                                controlledByThisConnection: owner == client, lastReason: lastReason, error: error)
    }

    func setCPU(client: UUID, percent: Int) throws -> FanControlStatus {
        guard !draining, !sleeping else { throw FanControlError("Fan service is stopping or sleeping.") }
        guard (30...100).contains(percent) else { throw FanControlError("CPU fan duty must be 30–100%.") }
        guard owner == nil || owner == client else { throw FanControlError("Another LiquidBar connection owns CPU fan control.") }
        let before = try backend.read()
        guard let temperature = before.temperature, temperature.isFinite,
              temperature < FanControlConstants.maximumTemperature else {
            try restore(reason: "invalid_or_hot_temperature")
            throw FanControlError("CPU temperature is unavailable or at least 75°C; motherboard automatic control is active.")
        }
        owner = client // Includes uncertain writes; cleanup remains our responsibility.
        deadline = clock() + FanControlConstants.leaseSeconds
        do {
            try backend.set(percent: percent)
            let after = try backend.read()
            guard !after.automatic, abs(after.duty - percent) <= 1, after.rpm > 0 else {
                throw FanControlError("The CPU fan controller did not confirm the manual setting.")
            }
            sample = after; error = nil; lastReason = "user_set_\(percent)"
            log("manual", lastReason, nil, nil)
            return try status(client: client)
        } catch {
            let failure = error
            do { try restore(reason: "write_failed") }
            catch { self.error = "\(failure.localizedDescription); restoration: \(error.localizedDescription)" }
            throw failure
        }
    }

    func restoreCPU(client: UUID) throws -> FanControlStatus {
        guard owner == nil || owner == client else { throw FanControlError("Another LiquidBar connection owns CPU fan control.") }
        try restore(reason: "user_request")
        return try status(client: client)
    }

    func disconnected(client: UUID) {
        guard owner == client else { return }
        do { try restore(reason: "client_disconnected") } catch { recordFailure(error, reason: "client_disconnected") }
    }

    func tick() {
        guard !draining, !sleeping else { return }
        do {
            if owner != nil && clock() >= deadline { try restore(reason: "lease_timeout"); return }
            let current = try backend.read()
            sample = current
            if error != nil, current.automatic, let temperature = current.temperature,
               temperature.isFinite, temperature < FanControlConstants.maximumTemperature, current.rpm > 0 {
                owner = nil; deadline = 0; error = nil; lastReason = "automatic_control_recovered"
                log("restored", lastReason, true, nil)
            }
            guard owner != nil else { return }
            guard let temperature = current.temperature, temperature.isFinite else {
                try restore(reason: "invalid_temperature"); return
            }
            if temperature >= FanControlConstants.maximumTemperature { try restore(reason: "overheat"); return }
            if current.rpm <= 0 { try restore(reason: "fan_feedback_missing"); return }
            if current.automatic {
                owner = nil; lastReason = "external_automatic_control"
                log("control_changed", lastReason, true, nil)
            }
        } catch {
            recordFailure(error, reason: "telemetry_failed")
            if owner != nil {
                do { try restore(reason: "telemetry_failed") } catch { recordFailure(error, reason: "restoration_failed") }
            }
        }
    }

    func sleep() throws { sleeping = true; try restore(reason: "sleep") }
    func wake() {
        sleeping = false
        sample = nil
        // A failed pre-sleep restore must never resume its old manual lease.
        do { try restore(reason: "wake") }
        catch { recordFailure(error, reason: "wake_unconfirmed") }
    }

    func stop() -> Bool {
        draining = true
        do { try restore(reason: "signal"); return true }
        catch { recordFailure(error, reason: "signal"); return false }
    }

    private func restore(reason: String) throws {
        do {
            try backend.restoreAutomatic()
            let restored = try backend.read()
            guard restored.automatic else { throw FanControlError("CPU fan automatic control was not confirmed.") }
            sample = restored; owner = nil; deadline = 0; lastReason = reason
            if let temperature = restored.temperature, temperature.isFinite,
               temperature < FanControlConstants.maximumTemperature, restored.rpm > 0 {
                error = nil
            } else {
                error = "Automatic control is confirmed; CPU temperature or fan feedback is not healthy."
            }
            log("restored", reason, true, nil)
        } catch {
            self.error = error.localizedDescription
            lastReason = reason + "_unconfirmed"
            log("restoration_failed", reason, false, self.error)
            throw error
        }
    }

    private func recordFailure(_ failure: Error, reason: String) {
        error = failure.localizedDescription; lastReason = reason
        log("error", reason, nil, error)
    }
}
