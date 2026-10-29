import Darwin
import Foundation
import MacSpaceCore
import Testing
@testable import MacSpace

@Suite("Сценарии приложения", .serialized)
@MainActor
struct AppModelTests {
    private func waitForScan(_ model: AppModel) async throws {
        let deadline = Date().addingTimeInterval(10)
        while model.isScanning && Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!model.isScanning)
    }

    @Test("Анализ → сортировка → фильтр → вход в папку → возврат")
    func browsing() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MacSpaceAppTest-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("nested"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(repeating: 1, count: 900).write(to: root.appendingPathComponent("nested/large"))
        try Data(repeating: 1, count: 20).write(to: root.appendingPathComponent("small"))

        let model = AppModel()
        model.metric = .logical
        model.startScan(root)
        try await waitForScan(model)
        #expect(model.errorMessage == nil)
        #expect(model.rows.map(\.name) == ["nested", "small"])
        model.tableSort = [KeyPathComparator(\ContentRow.bytes)]
        #expect(model.rows.map(\.name) == ["small", "nested"])
        model.search = "NEST"
        #expect(model.rows.map(\.name) == ["nested"])
        let nested = try #require(model.rows.first?.id)
        model.selectedID = nested
        #expect(model.canTrash(model.selectedNode))
        model.requestTrash()
        #expect(model.showTrashConfirmation)
        #expect(model.pendingTrash?.id == nested)
        model.showTrashConfirmation = false
        model.pendingTrash = nil
        model.navigate(to: nested)
        #expect(model.search.isEmpty)
        #expect(model.rows.map(\.name) == ["large"])
        model.goUp()
        #expect(model.currentFolderID == model.snapshot?.rootID)
        #expect(!model.canTrash(model.currentFolder))

        model.startScan(root)
        #expect(!model.canTrash(model.snapshot?.nodes[nested]))
        model.cancelScan()
        #expect(model.snapshot != nil)
        #expect(!model.isBusy)
    }

    @Test("Обновление удалённой папки возвращает в ближайшую существующую")
    func rescanAfterRemoval() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MacSpaceRescan-" + UUID().uuidString)
        let child = root.appendingPathComponent("parent/child")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel()
        model.startScan(root)
        try await waitForScan(model)
        let id = try #require(model.snapshot?.nodes.values.first { $0.name == "child" }?.id)
        model.navigate(to: id)
        try FileManager.default.removeItem(at: child)
        model.rescan()
        try await waitForScan(model)
        #expect(model.currentFolder?.name == "parent")
    }

    @Test("Ошибка нового анализа сохраняет предыдущий результат")
    func failedRescan() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MacSpaceError-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel()
        model.startScan(root)
        try await waitForScan(model)
        let original = model.snapshot?.rootID
        model.startScan(root.appendingPathComponent("missing"))
        try await waitForScan(model)
        #expect(model.errorMessage != nil)
        #expect(model.snapshot?.rootID == original)
        #expect(!model.isBusy)
    }

    @Test("Отказ в доступе не вызывает модальный диалог и не мешает следующему анализу")
    func deniedAccess() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MacSpaceDenied-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(repeating: 1, count: 40).write(to: root.appendingPathComponent("data"))
        #expect(chmod(root.path, 0) == 0)
        defer { _ = chmod(root.path, 0o700) }

        let model = AppModel()
        model.startScan(root)
        try await waitForScan(model)
        #expect(model.errorMessage == nil)
        #expect(model.currentFolder?.scanError != nil)
        #expect(model.snapshot?.issueCount == 1)
        #expect(!model.isBusy)

        #expect(chmod(root.path, 0o700) == 0)
        model.rescan()
        try await waitForScan(model)
        #expect(model.errorMessage == nil)
        #expect(model.currentFolder?.scanError == nil)
        #expect(model.snapshot?.issueCount == 0)
        #expect(model.currentFolder?.logicalBytes == 40)
    }
}
