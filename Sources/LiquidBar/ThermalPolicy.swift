import Foundation

struct ThermalPolicy {
    static func instantaneousSeverity(
        cpu: Double?,
        liquid: Double?,
        thresholds: AlertThresholds
    ) -> AlertSeverity {
        if (cpu.map { $0 >= thresholds.cpuCritical } ?? false) ||
            (liquid.map { $0 >= thresholds.liquidCritical } ?? false) {
            return .critical
        }
        if (cpu.map { $0 >= thresholds.cpuWarning } ?? false) ||
            (liquid.map { $0 >= thresholds.liquidWarning } ?? false) {
            return .warning
        }
        return .normal
    }

    static func isRecovered(
        cpu: Double?,
        liquid: Double?,
        from severity: AlertSeverity,
        thresholds: AlertThresholds
    ) -> Bool {
        switch severity {
        case .normal:
            return true
        case .warning:
            return (cpu.map { $0 < thresholds.cpuWarning - thresholds.hysteresis } ?? true) &&
                (liquid.map { $0 < thresholds.liquidWarning - thresholds.hysteresis } ?? true)
        case .critical:
            return (cpu.map { $0 < thresholds.cpuCritical - thresholds.hysteresis } ?? true) &&
                (liquid.map { $0 < thresholds.liquidCritical - thresholds.hysteresis } ?? true)
        }
    }
}
