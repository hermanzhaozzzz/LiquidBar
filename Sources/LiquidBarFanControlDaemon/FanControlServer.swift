import Darwin
import FanControlShared
import Foundation
import IOKit
import IOKit.pwr_mgt

final class ServiceLog {
    private let descriptor: Int32
    private let lock = NSLock()
    init() throws {
        descriptor = open(FanControlConstants.log, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw FanControlError("Cannot open the service log.") }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_uid == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_nlink == 1, info.st_mode & 0o077 == 0 else {
            close(descriptor)
            throw FanControlError("Fan service log must be a private root-owned regular file.")
        }
    }
    deinit { close(descriptor) }
    func write(event: String, reason: String, restored: Bool? = nil, error: String? = nil, signal: Int32? = nil) {
        lock.lock(); defer { lock.unlock() }
        var value: [String: Any] = ["time": ISO8601DateFormatter().string(from: Date()), "pid": getpid(),
                                    "event": event, "reason": reason]
        if let restored { value["restored"] = restored }
        if let error { value["error"] = error }
        if let signal { value["signal"] = signal }
        guard var data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else { return }
        data.append(10)
        data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { break }
                offset += count
            }
        }
        fsync(descriptor)
    }
}

final class FanControlServer: NSObject, NSXPCListenerDelegate {
    let queue = DispatchQueue(label: "LiquidBar.FanControl.serial")
    let core: FanControlCore
    private let configuration: FanControlConfiguration
    private let listener: NSXPCListener
    private let log: ServiceLog
    private let drainLock = NSLock()
    private var draining = false
    private var timer: DispatchSourceTimer?
    private var signals: [DispatchSourceSignal] = []
    private var powerObserver: ServicePowerObserver?

    init(configuration: FanControlConfiguration, backend: CPUFanBackend, log: ServiceLog) {
        self.configuration = configuration; self.log = log
        core = FanControlCore(configuration: configuration, backend: backend) { event, reason, restored, error in
            log.write(event: event, reason: reason, restored: restored, error: error)
        }
        listener = NSXPCListener(machServiceName: FanControlConstants.service)
        super.init()
    }

    func start() throws {
        try queue.sync { try core.start() }
        // Retain the exact-hash gate in addition to the accepted account boundary.
        // This host's injection behavior prevents claiming process-exclusive access.
        listener.setConnectionCodeSigningRequirement(configuration.guiRequirement)
        listener.delegate = self
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 2, repeating: 2, leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in self?.core.tick() }
        self.timer = timer; timer.resume()
        powerObserver = try ServicePowerObserver { [weak self] sleeping, acknowledge in
            guard let self else { acknowledge(); return }
            self.queue.async {
                defer { acknowledge() }
                if sleeping {
                    do { try self.core.sleep() }
                    catch { self.log.write(event: "error", reason: "sleep", restored: false, error: error.localizedDescription) }
                } else { self.core.wake() }
            }
        }
        for number in [SIGTERM, SIGINT] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global(qos: .userInitiated))
            source.setEventHandler { [weak self] in self?.stop(signal: number) }
            source.resume(); signals.append(source)
        }
        // Do not accept a manual write until every independent safeguard is armed.
        listener.resume()
        log.write(event: "started", reason: "ready", restored: true)
    }

    var isDraining: Bool { drainLock.lock(); defer { drainLock.unlock() }; return draining }

    private func stop(signal: Int32) {
        drainLock.lock()
        if draining { drainLock.unlock(); return }
        draining = true
        drainLock.unlock()
        listener.suspend()
        queue.async {
            self.timer?.cancel()
            let restored = self.core.stop()
            self.log.write(event: "stopped", reason: "signal", restored: restored,
                           error: self.core.error, signal: signal)
            exit(restored ? 0 : 1)
        }
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard !isDraining, connection.effectiveUserIdentifier == configuration.allowedUID else { return false }
        connection.setCodeSigningRequirement(configuration.guiRequirement)
        let endpoint = FanControlEndpoint(server: self)
        connection.exportedInterface = NSXPCInterface(with: FanControlXPC.self)
        connection.exportedObject = endpoint
        let client = endpoint.client
        connection.invalidationHandler = { [weak self] in
            guard let self else { return }
            self.queue.async { self.core.disconnected(client: client) }
        }
        connection.interruptionHandler = connection.invalidationHandler
        connection.resume()
        return true
    }
}

private final class FanControlEndpoint: NSObject, FanControlXPC {
    let client = UUID()
    private let server: FanControlServer
    init(server: FanControlServer) { self.server = server }
    private func perform(_ reply: @escaping (Data?, String?) -> Void,
                         operation: @escaping (FanControlCore, UUID) throws -> FanControlStatus) {
        server.queue.async {
            guard !self.server.isDraining else { reply(nil, "Fan control service is stopping."); return }
            do { reply(try JSONEncoder().encode(operation(self.server.core, self.client)), nil) }
            catch { reply(nil, error.localizedDescription) }
        }
    }
    func status(reply: @escaping (Data?, String?) -> Void) {
        perform(reply) { try $0.status(client: $1) }
    }
    func heartbeat(reply: @escaping (Data?, String?) -> Void) {
        perform(reply) { try $0.status(client: $1) }
    }
    func setCPU(percent: Int, reply: @escaping (Data?, String?) -> Void) {
        perform(reply) { try $0.setCPU(client: $1, percent: percent) }
    }
    func restoreCPU(reply: @escaping (Data?, String?) -> Void) {
        perform(reply) { try $0.restoreCPU(client: $1) }
    }
}

private final class ServicePowerObserver {
    // IOMessage.h: iokit_common_msg(code) = (0x38 << 26) | code.
    // These C function-like macros are not imported by Swift.
    private static let canSleep: UInt32 = 0xe0000270
    private static let willSleep: UInt32 = 0xe0000280
    private static let poweredOn: UInt32 = 0xe0000300
    private var notificationPort: IONotificationPortRef?
    private var notifier: io_object_t = 0
    private var connection: io_connect_t = 0
    private let action: (Bool, @escaping () -> Void) -> Void

    init(action: @escaping (Bool, @escaping () -> Void) -> Void) throws {
        self.action = action
        connection = IORegisterForSystemPower(Unmanaged.passUnretained(self).toOpaque(), &notificationPort, { context, _, message, argument in
            guard let context else { return }
            let observer = Unmanaged<ServicePowerObserver>.fromOpaque(context).takeUnretainedValue()
            let identifier = Int(bitPattern: argument)
            if message == ServicePowerObserver.canSleep {
                IOAllowPowerChange(observer.connection, identifier)
            } else if message == ServicePowerObserver.willSleep {
                observer.action(true) { IOAllowPowerChange(observer.connection, identifier) }
            } else if message == ServicePowerObserver.poweredOn {
                observer.action(false, {})
            }
        }, &notifier)
        guard connection != 0, let notificationPort,
              let source = IONotificationPortGetRunLoopSource(notificationPort)?.takeUnretainedValue() else {
            throw FanControlError("Cannot register the fan service sleep safeguard.")
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    }
    deinit {
        if notifier != 0 { IODeregisterForSystemPower(&notifier) }
        if connection != 0 { IOServiceClose(connection) }
        if let notificationPort { IONotificationPortDestroy(notificationPort) }
    }
}
