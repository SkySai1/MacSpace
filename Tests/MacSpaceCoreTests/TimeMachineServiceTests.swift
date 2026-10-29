import Foundation
import Testing
@testable import MacSpaceCore

private actor FixtureTimeMachineRunner: TimeMachineCommandRunning {
    private var results: [TimeMachineCommandResult]
    private(set) var commands: [TimeMachineCommand] = []
    init(_ results: [TimeMachineCommandResult]) { self.results = results }
    func run(_ command: TimeMachineCommand) throws -> TimeMachineCommandResult {
        commands.append(command)
        guard !results.isEmpty else { throw TimeMachineError.unexpectedOutput }
        return results.removeFirst()
    }
}

@Suite("Локальные снимки Time Machine: команды без настоящего удаления")
struct TimeMachineServiceTests {
    @Test("Только настоящие даты допустимы в аргументах", arguments: [
        "", "/", "2026-10-29-140000;id", "2026-10-29-140000\n", "$(whoami)",
        "2026-02-30-140000", "2025-02-29-140000", "2026-10-29-250000", "2026-13-29-140000",
        "com.apple.TimeMachine.2026-10-29-140000.local", "２０２６-10-29-140000"
    ])
    func invalidDates(_ value: String) { #expect(LocalTimeMachineSnapshot(dateID: value) == nil) }

    @Test("Список сортируется, даты объединяются; неизвестный вывод не выглядит пустым списком")
    func parseList() throws {
        let snapshots = try TimeMachineService.parseDates("Snapshot dates for all disks:\n2026-10-29-140000\n2024-02-29-101530\n2026-10-29-140000\n")
        #expect(snapshots.map(\.id) == ["2026-10-29-140000", "2024-02-29-101530"])
        #expect(try TimeMachineService.parseDates("Snapshot dates for all disks:\n").isEmpty)
        for output in ["", "Operation not permitted", "Snapshot dates for all disks:\n2026-02-30-120000", "Unrecognized header:\n"] {
            #expect(throws: TimeMachineError.self) { try TimeMachineService.parseDates(output) }
        }
    }

    @Test("Удаляются только подтверждённые даты; истёкшие пропускаются и частичный отказ сохраняется")
    func preciseDeletion() async throws {
        let first = try #require(LocalTimeMachineSnapshot(dateID: "2026-10-29-140000"))
        let second = try #require(LocalTimeMachineSnapshot(dateID: "2026-10-29-130000"))
        let expired = try #require(LocalTimeMachineSnapshot(dateID: "2026-10-28-100000"))
        let unselected = "2026-10-29-150000"
        let runner = FixtureTimeMachineRunner([
            .init(status: 0, output: "Snapshot dates for all disks:\n\(first.id)\n\(second.id)\n\(unselected)\n"),
            .init(status: 0, output: "Operation not permitted\rMACSPACE_RESULT:\(second.id):1\rDeleted\rMACSPACE_RESULT:\(first.id):0\r")
        ])
        let result = try await TimeMachineService(runner: runner).delete([first, second, expired, first])
        #expect(result.removedIDs == [first.id, expired.id])
        #expect(result.failures.count == 1)
        #expect(result.failures.first?.dateID == second.id)
        #expect(result.failures.first?.message == "Operation not permitted")
        let commands = await runner.commands
        #expect(commands.count == 2)
        #expect(commands.first?.executable == "/usr/bin/tmutil")
        #expect(commands.first?.arguments == ["listlocalsnapshotdates"])
        let command = try #require(commands.last)
        #expect(command.executable == "/usr/bin/osascript")
        let script = try #require(command.arguments.last)
        #expect(script.contains("with administrator privileges"))
        #expect(script.contains(first.id) && script.contains(second.id))
        #expect(!script.contains(expired.id) && !script.contains(unselected))
        #expect(!script.contains("thinlocalsnapshots"))
    }

    @Test("Исчезнувшие даты и пустой выбор не запрашивают права администратора")
    func expiredDates() async throws {
        let snapshot = try #require(LocalTimeMachineSnapshot(dateID: "2026-10-29-140000"))
        let runner = FixtureTimeMachineRunner([.init(status: 0, output: "Snapshot dates for all disks:\n")])
        let service = TimeMachineService(runner: runner)
        #expect(try await service.delete([]).removedIDs.isEmpty)
        #expect(await runner.commands.isEmpty)
        #expect(try await service.delete([snapshot]).removedIDs == [snapshot.id])
        #expect(await runner.commands.count == 1)
    }

    @Test("Ошибка чтения и отмена авторизации не приводят к повторным командам")
    func accessErrors() async throws {
        let snapshot = try #require(LocalTimeMachineSnapshot(dateID: "2026-10-29-140000"))
        let denied = FixtureTimeMachineRunner([.init(status: 1, output: "Operation not permitted")])
        await #expect(throws: TimeMachineError.self) { try await TimeMachineService(runner: denied).delete([snapshot]) }
        #expect(await denied.commands.count == 1)
        let cancelled = FixtureTimeMachineRunner([
            .init(status: 0, output: "Snapshot dates for all disks:\n\(snapshot.id)"),
            .init(status: 1, output: "User canceled. (-128)")
        ])
        do {
            _ = try await TimeMachineService(runner: cancelled).delete([snapshot])
            Issue.record("Ожидалась отмена авторизации")
        } catch TimeMachineError.authorizationCancelled { }
        #expect(await cancelled.commands.count == 2)
    }

    @Test("Неподтверждённый ответ не объявляется успешным удалением")
    func missingDeletionResults() {
        let dates: Set<String> = ["2026-10-29-140000", "2026-10-29-130000"]
        let result = TimeMachineService.parseDeletion("Deleted!\nMACSPACE_RESULT:unselected:0\nMACSPACE_RESULT:2026-10-29-140000:invalid", requested: dates)
        #expect(result.removedIDs.isEmpty)
        #expect(Set(result.failures.map(\.dateID)) == dates)
    }

    @Test("AppleScript корректно передаёт строки; shell сохраняет коды возврата без удаления")
    func scriptEncoding() async throws {
        // No scripting additions/admin clause or tmutil invocation in sandboxed tests.
        // Check the AppleScript string round-trip, then execute only false/printf plumbing.
        let date = "2026-10-29-140000"
        let script = TimeMachineService.deletionScript(dates: [date]).replacingOccurrences(of: "/usr/bin/tmutil", with: "/usr/bin/false")
        let command = TimeMachineCommand(executable: "/usr/bin/osascript", arguments: [
            "-e", "return \"\(TimeMachineService.appleScriptString(script))\""
        ])
        let result = try await SystemTimeMachineRunner().run(command)
        #expect(result.status == 0)
        #expect(result.output.trimmingCharacters(in: .newlines) == script)
        let shell = try await SystemTimeMachineRunner().run(TimeMachineCommand(executable: "/bin/sh", arguments: ["-c", result.output]))
        let parsed = TimeMachineService.parseDeletion(shell.output, requested: [date])
        #expect(parsed.removedIDs.isEmpty)
        #expect(parsed.failures.count == 1)
        #expect(shell.output.contains("MACSPACE_RESULT:\(date):1"))
    }

    @Test("Зависший процесс завершается по тайм-ауту; отмена не блокирует ожидание")
    func timeoutAndCancellation() async throws {
        let runner = SystemTimeMachineRunner()
        await #expect(throws: TimeMachineError.self) {
            try await runner.run(TimeMachineCommand(executable: "/bin/sleep", arguments: ["10"], timeout: 0.05))
        }
        let task = Task { try await runner.run(TimeMachineCommand(executable: "/bin/sleep", arguments: ["10"])) }
        try await Task.sleep(for: .milliseconds(30))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}
