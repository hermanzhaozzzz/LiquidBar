import Foundation
import Darwin

actor MotherboardService {
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var buffer = Data()
    private var nextID = 0
    private var retiringProcess: Process?
    private var retiringOutput: FileHandle?
    private var retirementFailure: String?
    private let helperExecutable: URL?
    private let helperArguments: [String]
    private let requestTimeout: TimeInterval

    init(helperExecutable: URL? = nil, helperArguments: [String] = ["--motherboard-helper"], requestTimeout: TimeInterval = 120) {
        self.helperExecutable = helperExecutable
        self.helperArguments = helperArguments
        self.requestTimeout = requestTimeout
    }

    func cpuMetrics() throws -> MotherboardCPUMetrics {
        guard let value = try request("cpu").cpu else { throw invalidResponse() }
        return value
    }
    func initializeFans() throws -> MotherboardFanSnapshot {
        guard let value = try request("initialize").snapshot else { throw invalidResponse() }
        return value
    }
    func readFans() throws -> MotherboardFanSnapshot {
        guard let value = try request("fans").snapshot else { throw invalidResponse() }
        return value
    }
    func setDuty(index: Int, percent: Int, role: MotherboardFanRole) throws -> MotherboardFanSnapshot {
        guard let value = try request("set", index: index, percent: percent, role: role).snapshot else { throw invalidResponse() }
        return value
    }
    func restoreAutomatic(index: Int) throws -> MotherboardFanSnapshot {
        guard let value = try request("restore", index: index).snapshot else { throw invalidResponse() }
        return value
    }
    func restoreAllOverrides() throws {
        // Do not spawn a driver helper only to shut it down.
        guard process?.isRunning == true else { try awaitRetirement(timeout: 2); return }
        _ = try request("restoreAll")
    }
    func testIncrease(index: Int, role: MotherboardFanRole, duration: TimeInterval = 3) throws -> MotherboardFanTestResult {
        guard let value = try request("test", index: index, role: role, duration: duration).test else { throw invalidResponse() }
        return value
    }
    func shutdown() throws {
        // EOF is the helper's shutdown/restore signal. Never SIGKILL a worker
        // that may still own manual fan control.
        closePipes()
        try awaitRetirement(timeout: 8)
    }

    private func start() throws {
        if process?.isRunning == true { return }
        closePipes()
        try awaitRetirement(timeout: 2)
        guard let executable = helperExecutable ?? Bundle.main.executableURL else { throw MotherboardError(message: "Cannot locate the motherboard helper executable.") }
        let task = Process()
        task.executableURL = executable
        task.arguments = helperArguments
        let stdin = Pipe(), stdout = Pipe()
        task.standardInput = stdin
        task.standardOutput = stdout
        task.standardError = FileHandle.standardError
        try task.run()
        // Parent must not keep the child's pipe ends alive; otherwise EOF
        // detection after parent shutdown can be delayed indefinitely.
        stdin.fileHandleForReading.closeFile()
        stdout.fileHandleForWriting.closeFile()
        process = task
        input = stdin.fileHandleForWriting
        output = stdout.fileHandleForReading
        buffer.removeAll()
    }
    private func closePipes() {
        // Retain the retiring worker until its restoration and exit are observed.
        // A new worker must never race its delayed authorization/write/restore.
        try? input?.close()
        input = nil
        if let process {
            retiringProcess = process
            retiringOutput = output
        } else { try? output?.close() }
        output = nil
        process = nil
        buffer.removeAll()
    }
    private func awaitRetirement(timeout: TimeInterval) throws {
        if let retirementFailure { throw MotherboardError(message: retirementFailure) }
        guard let retiringProcess else { return }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while retiringProcess.isRunning && ProcessInfo.processInfo.systemUptime < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        guard !retiringProcess.isRunning else {
            throw MotherboardError(message: "The previous motherboard helper is still restoring or awaiting authorization. No new control session has started.")
        }
        retiringProcess.waitUntilExit()
        try? retiringOutput?.close()
        retiringOutput = nil
        self.retiringProcess = nil
        guard retiringProcess.terminationReason == .exit && retiringProcess.terminationStatus == 0 else {
            retirementFailure = "The motherboard helper did not exit cleanly; restoration is unconfirmed. Restart to recover BIOS control before another control session."
            throw MotherboardError(message: retirementFailure!)
        }
    }
    private func request(_ action: String, index: Int? = nil, percent: Int? = nil,
                         role: MotherboardFanRole? = nil, duration: TimeInterval? = nil) throws -> MotherboardResponse {
        try start()
        nextID += 1
        let command = MotherboardRequest(id: nextID, action: action, index: index, percent: percent, role: role, duration: duration)
        let response: MotherboardResponse
        do {
            var data = try JSONEncoder().encode(command); data.append(10)
            try input?.write(contentsOf: data)
            response = try JSONDecoder().decode(MotherboardResponse.self, from: readLine(timeout: requestTimeout))
            guard response.id == nextID else { throw invalidResponse() }
        } catch {
            // A failed command may have partially reached hardware. Closing
            // stdin makes the independent worker restore before exiting.
            closePipes()
            throw error
        }
        if let error = response.error { throw MotherboardError(message: error) }
        return response
    }
    private func readLine(timeout: TimeInterval) throws -> Data {
        guard let output else { throw invalidResponse() }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while true {
            if let newline = buffer.firstIndex(of: 10) {
                let line = Data(buffer[..<newline]); buffer.removeSubrange(...newline)
                return line
            }
            guard ProcessInfo.processInfo.systemUptime < deadline else { break }
            var descriptor = pollfd(fd: output.fileDescriptor, events: Int16(POLLIN), revents: 0)
            let result = poll(&descriptor, 1, 250)
            if result < 0 && errno == EINTR { continue }
            guard result >= 0 else { throw invalidResponse() }
            if result == 0 { continue }
            if descriptor.revents & Int16(POLLIN) != 0 {
                var chunk = [UInt8](repeating: 0, count: 4096)
                let count = Darwin.read(output.fileDescriptor, &chunk, chunk.count)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw MotherboardError(message: "Motherboard helper disconnected.") }
                buffer.append(contentsOf: chunk.prefix(count))
                guard buffer.count <= 65536 else { throw invalidResponse() }
            } else if descriptor.revents & Int16(POLLHUP | POLLERR | POLLNVAL) != 0 {
                throw MotherboardError(message: "Motherboard helper disconnected.")
            }
        }
        throw MotherboardError(message: "Motherboard helper timed out. Any manual override is being restored.")
    }
    private func invalidResponse() -> MotherboardError { MotherboardError(message: "Invalid motherboard helper response.") }
}
