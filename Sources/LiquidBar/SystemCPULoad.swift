import Darwin

/// Whole-system CPU utilization, sampled independently of cooling devices.
final class SystemCPULoad {
    private var previous: (busy: UInt64, total: UInt64)?

    func sample() -> Double? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let busy = UInt64(info.cpu_ticks.0) + UInt64(info.cpu_ticks.1) + UInt64(info.cpu_ticks.3)
        let total = busy + UInt64(info.cpu_ticks.2)
        defer { previous = (busy, total) }
        guard let previous, total > previous.total, busy >= previous.busy else { return nil }
        return min(100, max(0, Double(busy - previous.busy) / Double(total - previous.total) * 100))
    }
}
