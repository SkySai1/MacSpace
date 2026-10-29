import Foundation
import Testing
@testable import MacSpace
@testable import MacSpaceCore

actor FixtureTimeMachineService: TimeMachineManaging {
    private var snapshots: [LocalTimeMachineSnapshot]
    private var listFails = false
    private let failedDeletionID: String?
    private let cancelAuthorization: Bool
    private(set) var listCount = 0
    private(set) var deletions: [[LocalTimeMachineSnapshot]] = []

    init(dates: [String] = ["2026-10-29-140000", "2026-10-29-130000"],
         failedDeletionID: String? = nil, cancelAuthorization: Bool = false) {
        snapshots = dates.compactMap { LocalTimeMachineSnapshot(dateID: $0) }
        self.failedDeletionID = failedDeletionID; self.cancelAuthorization = cancelAuthorization
    }
    func setListFails(_ value: Bool) { listFails = value }
    func list() throws -> [LocalTimeMachineSnapshot] {
        listCount += 1
        if listFails { throw TimeMachineError.commandFailed("Operation not permitted") }
        return snapshots
    }
    func delete(_ snapshots: [LocalTimeMachineSnapshot]) async throws -> TimeMachineDeleteResult {
        deletions.append(snapshots)
        try await Task.sleep(for: .milliseconds(50))
        if cancelAuthorization { throw TimeMachineError.authorizationCancelled }
        let removed = Set(snapshots.filter { $0.id != failedDeletionID }.map(\.id))
        self.snapshots.removeAll { removed.contains($0.id) }
        return TimeMachineDeleteResult(removedIDs: removed, failures: snapshots.filter { $0.id == failedDeletionID }.map {
            TimeMachineFailure(dateID: $0.id, message: "Operation not permitted")
        })
    }
}

private actor RacingTimeMachineService: TimeMachineManaging {
    private(set) var calls = 0
    func list() async -> [LocalTimeMachineSnapshot] {
        calls += 1
        let first = calls == 1
        let result = [first ? "2026-10-29-130000" : "2026-10-29-150000"].compactMap { LocalTimeMachineSnapshot(dateID: $0) }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global().asyncAfter(deadline: .now() + (first ? 0.1 : 0.01)) { continuation.resume(returning: result) }
        }
    }
    func delete(_ snapshots: [LocalTimeMachineSnapshot]) throws -> TimeMachineDeleteResult { throw TimeMachineError.unexpectedOutput }
}

@Suite("Вкладка Time Machine и подтверждение удаления")
@MainActor
struct TimeMachineModelTests {
    private func wait(_ model: TimeMachineModel) async throws {
        let deadline = Date().addingTimeInterval(5)
        while model.isBusy && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!model.isBusy)
    }

    @Test("Опоздавшее чтение не перезаписывает более свежий список")
    func staleRefresh() async throws {
        let service = RacingTimeMachineService()
        let model = TimeMachineModel(service: service)
        model.activate()
        while await service.calls == 0 { try await Task.sleep(for: .milliseconds(1)) }
        model.refresh(); try await wait(model)
        #expect(model.snapshots.map(\.id) == ["2026-10-29-150000"])
        try await Task.sleep(for: .milliseconds(150))
        #expect(model.snapshots.map(\.id) == ["2026-10-29-150000"])
        #expect(!model.isLoading)
    }

    @Test("Отмена не удаляет; подтверждение связано с показанными датами, а не новым выбором")
    func confirmation() async throws {
        let service = FixtureTimeMachineService()
        let model = TimeMachineModel(service: service)
        model.confirmDeletion()
        #expect(await service.deletions.isEmpty)
        model.activate(); try await wait(model)
        #expect(model.snapshots.count == 2)
        let first = model.snapshots[0].id, second = model.snapshots[1].id
        model.selectedIDs = [first]
        model.requestDeletion()
        #expect(model.showDeleteConfirmation)
        #expect(model.confirmationMessage.contains("на всех подключённых дисках"))
        model.cancelPrompt(); model.confirmDeletion()
        #expect(await service.deletions.isEmpty)
        model.requestDeletion()
        model.selectedIDs = [second]
        // SwiftUI may dismiss the alert binding before running its button action.
        model.showDeleteConfirmation = false
        model.confirmDeletion(); try await wait(model)
        #expect(await service.deletions.map { $0.map(\.id) } == [[first]])
        #expect(model.snapshots.map(\.id) == [second])
        #expect(model.selectedIDs == [second])
        #expect(await service.listCount == 1)
        model.activate()
        #expect(await service.listCount == 1)
    }

    @Test("Частичный отказ сохраняет неудавшуюся дату и требует обновления перед повторением")
    func partialDeletion() async throws {
        let failed = "2026-10-29-130000"
        let service = FixtureTimeMachineService(failedDeletionID: failed)
        let model = TimeMachineModel(service: service)
        model.activate(); try await wait(model)
        model.selectedIDs = Set(model.snapshots.map(\.id))
        model.requestDeletion(all: true)
        #expect(model.pendingDeletion.count == 2)
        model.confirmDeletion(); try await wait(model)
        #expect(model.snapshots.map(\.id) == [failed])
        #expect(model.selectedIDs == [failed])
        #expect(model.errorMessage?.contains("Operation not permitted") == true)
        #expect(!model.canDeleteAll && !model.canDeleteSelection)
        model.refresh(); try await wait(model)
        #expect(model.canDeleteSelection)
        #expect(model.errorMessage == nil)
    }

    @Test("Отказ чтения сохраняет предыдущий список; отмена системного запроса не считается успехом")
    func accessAndAuthorizationErrors() async throws {
        let service = FixtureTimeMachineService(cancelAuthorization: true)
        let model = TimeMachineModel(service: service)
        model.activate(); try await wait(model)
        let original = model.snapshots
        await service.setListFails(true)
        model.refresh(); try await wait(model)
        #expect(model.snapshots == original)
        #expect(!model.canDeleteAll)
        #expect(model.errorMessage != nil)
        await service.setListFails(false)
        model.refresh(); try await wait(model)
        model.requestDeletion(all: true); model.confirmDeletion(); try await wait(model)
        #expect(model.snapshots == original)
        #expect(model.errorMessage?.contains("отменён") == true)
        #expect(!model.canDeleteAll)
        #expect(await service.deletions.count == 1)
    }

    @Test("Вкладки сохраняют анализ и Корзину; удаление блокирует переключение без пересканирования папок")
    func workspaceIntegration() async throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("MacSpaceTimeMachine-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try Data([1, 2, 3]).write(to: temporary.appendingPathComponent("keep"))
        let service = FixtureTimeMachineService()
        let model = AppModel(trashManager: TrashDirectoryService(testLocations: []), timeMachineService: service)
        #expect(await service.listCount == 0)
        model.startScan(temporary)
        while model.isScanning { try await Task.sleep(for: .milliseconds(10)) }
        let original = try #require(model.snapshot)
        let version = model.snapshotVersion
        let file = try #require(model.rows.first?.id)
        model.selectedID = file
        model.selectTab(.timeMachine); try await wait(model.timeMachine)
        #expect(model.snapshot == nil && model.isTimeMachineTab && model.canRefresh)
        model.selectTab(.trash)
        while model.isScanning { try await Task.sleep(for: .milliseconds(10)) }
        let trash = try #require(model.snapshot)
        model.selectTab(.timeMachine)
        model.timeMachine.requestDeletion(all: true); model.timeMachine.confirmDeletion()
        #expect(model.isMutating)
        model.selectTab(.analysis); model.startScan(temporary)
        #expect(model.isTimeMachineTab && !model.isScanning)
        try await wait(model.timeMachine)
        #expect(!model.isMutating)
        model.selectTab(.trash)
        #expect(model.snapshot?.scannedAt == trash.scannedAt)
        model.selectTab(.analysis)
        #expect(model.snapshotVersion == version)
        #expect(model.snapshot?.scannedAt == original.scannedAt)
        #expect(model.snapshot?.root.allocatedBytes == original.root.allocatedBytes)
        #expect(model.selectedID == file)
        #expect(FileManager.default.fileExists(atPath: file))
        model.selectTab(.timeMachine)
        model.startScan(temporary)
        #expect(model.activeTab == .analysis)
        while model.isScanning { try await Task.sleep(for: .milliseconds(10)) }
    }
}
