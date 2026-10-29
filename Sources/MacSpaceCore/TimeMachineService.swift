import Foundation

/// One date represents the local snapshots of that date on all mounted disks.
/// This is exactly the scope of `tmutil deletelocalsnapshots <date>`.
public struct LocalTimeMachineSnapshot: Identifiable, Hashable, Sendable {
    public let id: String
    public let createdAt: Date

    public init?(dateID: String) {
        let characters = Array(dateID.utf8)
        guard characters.count == 17, characters.enumerated().allSatisfy({ index, value in
            [4, 7, 10].contains(index) ? value == 45 : (48...57).contains(value)
        }) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        formatter.isLenient = false
        guard let date = formatter.date(from: dateID), formatter.string(from: date) == dateID else { return nil }
        id = dateID; createdAt = date
    }
}

public struct TimeMachineFailure: Sendable {
    public let dateID: String
    public let message: String
    public init(dateID: String, message: String) { self.dateID = dateID; self.message = message }
}

public struct TimeMachineDeleteResult: Sendable {
    public let removedIDs: Set<String>
    public let failures: [TimeMachineFailure]
    public init(removedIDs: Set<String>, failures: [TimeMachineFailure] = []) {
        self.removedIDs = removedIDs; self.failures = failures
    }
}

public protocol TimeMachineManaging: Sendable {
    func list() async throws -> [LocalTimeMachineSnapshot]
    func delete(_ snapshots: [LocalTimeMachineSnapshot]) async throws -> TimeMachineDeleteResult
}

public enum TimeMachineError: LocalizedError, Sendable {
    case unexpectedOutput
    case commandFailed(String)
    case authorizationCancelled
    case timedOut

    public var errorDescription: String? {
        switch self {
        case .unexpectedOutput: "Не удалось распознать ответ Time Machine. Обновите список перед повторной операцией."
        case .commandFailed(let details): "Time Machine не выполнила операцию. \(details)"
        case .authorizationCancelled: "Запрос прав администратора отменён. Обновите список перед повторной операцией."
        case .timedOut: "Time Machine не ответила вовремя. Обновите список: операция могла завершиться частично."
        }
    }
}

struct TimeMachineCommand: Sendable {
    let executable: String
    let arguments: [String]
    var timeout: TimeInterval = 60
}

struct TimeMachineCommandResult: Sendable {
    let status: Int32
    let output: String
}

protocol TimeMachineCommandRunning: Sendable {
    func run(_ command: TimeMachineCommand) async throws -> TimeMachineCommandResult
}

/// The runner is injectable so tests never delete real snapshots or request authorization.
public actor TimeMachineService: TimeMachineManaging {
    private let runner: any TimeMachineCommandRunning
    public init() { runner = SystemTimeMachineRunner() }
    init(runner: any TimeMachineCommandRunning) { self.runner = runner }

    public func list() async throws -> [LocalTimeMachineSnapshot] {
        let result = try await runner.run(TimeMachineCommand(executable: "/usr/bin/tmutil", arguments: ["listlocalsnapshotdates"]))
        guard result.status == 0 else { throw TimeMachineError.commandFailed(String(result.output.prefix(2000))) }
        return try Self.parseDates(result.output)
    }

    static func parseDates(_ output: String) throws -> [LocalTimeMachineSnapshot] {
        let lines = output.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard lines.first == "Snapshot dates for all disks:" else { throw TimeMachineError.unexpectedOutput }
        var dates: [String: LocalTimeMachineSnapshot] = [:]
        for line in lines.dropFirst() {
            guard let snapshot = LocalTimeMachineSnapshot(dateID: line) else { throw TimeMachineError.unexpectedOutput }
            dates[snapshot.id] = snapshot
        }
        return dates.values.sorted { $0.id > $1.id }
    }

    public func delete(_ snapshots: [LocalTimeMachineSnapshot]) async throws -> TimeMachineDeleteResult {
        let requested = Set(snapshots.map(\.id))
        guard !requested.isEmpty else { return TimeMachineDeleteResult(removedIDs: []) }
        // Re-list immediately before deletion; expired snapshots need no administrator command.
        let current = Set(try await list().map(\.id))
        let present = requested.intersection(current)
        let expired = requested.subtracting(current)
        guard !present.isEmpty else { return TimeMachineDeleteResult(removedIDs: expired) }
        try Task.checkCancellation()
        let script = Self.deletionScript(dates: present.sorted())
        let appleScript = "do shell script \"\(Self.appleScriptString(script))\" with administrator privileges"
        let result = try await runner.run(TimeMachineCommand(executable: "/usr/bin/osascript", arguments: ["-e", appleScript], timeout: 300))
        guard result.status == 0 else {
            if result.output.contains("(-128)") { throw TimeMachineError.authorizationCancelled }
            throw TimeMachineError.commandFailed(String(result.output.prefix(2000)))
        }
        let parsed = Self.parseDeletion(result.output, requested: present)
        return TimeMachineDeleteResult(removedIDs: expired.union(parsed.removedIDs), failures: parsed.failures)
    }

    static func deletionScript(dates: [String]) -> String {
        // Dates can only originate from the validated value type. No paths, wildcards or volume-wide deletion.
        dates.map { date in
            "LC_ALL=C /usr/bin/tmutil deletelocalsnapshots '\(date)' 2>&1\n"
            + "/usr/bin/printf '\\nMACSPACE_RESULT:\(date):%d\\n' \"$?\""
        }.joined(separator: "\n")
    }

    static func appleScriptString(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
    }

    static func parseDeletion(_ output: String, requested: Set<String>) -> TimeMachineDeleteResult {
        var statuses: [String: Int32] = [:]
        var details: [String: String] = [:]
        var buffer: [String] = []
        for line in output.components(separatedBy: .newlines) {
            if line.hasPrefix("MACSPACE_RESULT:") {
                let parts = line.split(separator: ":", omittingEmptySubsequences: false)
                if parts.count == 3, requested.contains(String(parts[1])), let status = Int32(parts[2]), (0...255).contains(status) {
                    let id = String(parts[1]); statuses[id] = status
                    details[id] = buffer.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                    buffer = []
                }
            } else { buffer.append(line) }
        }
        let removed = Set(statuses.filter { $0.value == 0 }.map(\.key))
        let failures = requested.subtracting(removed).sorted().map { id in
            TimeMachineFailure(dateID: id, message: details[id].flatMap { $0.isEmpty ? nil : String($0.prefix(1500)) }
                ?? "Удаление не подтверждено системой. Обновите список; проверьте права и полный доступ к диску для MacSpace.")
        }
        return TimeMachineDeleteResult(removedIDs: removed, failures: failures)
    }
}

struct SystemTimeMachineRunner: TimeMachineCommandRunning {
    func run(_ command: TimeMachineCommand) async throws -> TimeMachineCommandResult {
        let execution = TimeMachineProcess()
        return try await withTaskCancellationHandler {
            try await Task.detached(priority: .userInitiated) { try execution.run(command) }.value
        } onCancel: { execution.stop() }
    }
}

/// Process launch, pipe draining and waiting happen on a worker, never on the UI actor.
private final class TimeMachineProcess: @unchecked Sendable {
    private let process = Process()
    private let lock = NSLock()
    private var stopped = false
    private var timedOut = false

    func stop(timeout: Bool = false) {
        lock.lock(); defer { lock.unlock() }
        stopped = true; timedOut = timedOut || timeout
        if process.isRunning { process.terminate() }
    }

    func run(_ command: TimeMachineCommand) throws -> TimeMachineCommandResult {
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: command.executable)
        process.arguments = command.arguments
        var environment = ProcessInfo.processInfo.environment; environment["LC_ALL"] = "C"
        process.environment = environment
        process.standardOutput = pipe; process.standardError = pipe
        lock.lock()
        guard !stopped else { lock.unlock(); throw CancellationError() }
        do { try process.run() } catch { lock.unlock(); throw error }
        lock.unlock()
        let timeout = DispatchWorkItem { [weak self] in self?.stop(timeout: true) }
        DispatchQueue.global().asyncAfter(deadline: .now() + command.timeout, execute: timeout)
        defer { timeout.cancel() }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        lock.lock(); let didTimeOut = timedOut, wasStopped = stopped; lock.unlock()
        if didTimeOut { throw TimeMachineError.timedOut }
        if wasStopped { throw CancellationError() }
        return TimeMachineCommandResult(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self))
    }
}
