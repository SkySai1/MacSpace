import Foundation
import MacSpaceCore
import Testing
@testable import MacSpace

private actor TemporaryTrashMover: TrashMoving {
    let destination: URL
    let shouldFail: Bool
    private(set) var calls = 0

    init(destination: URL, shouldFail: Bool = false) {
        self.destination = destination
        self.shouldFail = shouldFail
    }

    func moveToTrash(candidate: DiskNode, root: DiskNode) throws {
        calls += 1
        if shouldFail { throw CocoaError(.fileWriteNoPermission) }
        let checked = try TrashService.validate(candidate: candidate.url, root: root.url,
                                               expectedCandidate: candidate.identity, expectedRoot: root.identity)
        // Move only test data within its UUID fixture; never use the user's actual Trash.
        try FileManager.default.moveItem(at: checked, to: destination.appendingPathComponent(UUID().uuidString))
    }
}

@Suite("Перенос без повторного сканирования")
@MainActor
struct TrashUpdateTests {
    private func waitUntilIdle(_ model: AppModel) async throws {
        let deadline = Date().addingTimeInterval(10)
        while model.isBusy && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!model.isBusy)
    }

    @Test("Успешный перенос обновляет только снимок и сохраняет доступную навигацию", arguments: [true, false])
    func updateAfterTrash(deletingOpenFolder: Bool) async throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("MacSpaceTrashUpdate-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let root = temporary.appendingPathComponent("scan")
        let holding = temporary.appendingPathComponent("holding")
        for folder in [root.appendingPathComponent("remove/nested"), root.appendingPathComponent("keep"), holding] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        try Data(repeating: 1, count: 1_000).write(to: root.appendingPathComponent("remove/nested/data"))
        try Data(repeating: 1, count: 50).write(to: root.appendingPathComponent("keep/data"))
        let mover = TemporaryTrashMover(destination: holding)
        let model = AppModel(trashService: mover)
        model.startScan(root)
        try await waitUntilIdle(model)
        let initial = try #require(model.snapshot)
        let removed = try #require(initial.nodes.values.first { $0.name == "remove" })
        let kept = try #require(initial.nodes.values.first { $0.name == "keep" })
        let nested = try #require(initial.nodes.values.first { $0.name == "nested" })
        model.toggleExpansion(removed.id)
        model.toggleExpansion(nested.id)
        model.toggleExpansion(kept.id)
        if deletingOpenFolder {
            model.navigate(to: nested.id)
            model.selectedID = nested.childIDs.first
            model.search = "data"
        } else {
            model.selectedID = kept.id
            model.search = "keep"
        }
        // A full rescan would incorrectly incorporate these changes into cached totals.
        try Data(repeating: 2, count: 5_000).write(to: root.appendingPathComponent("keep/data"))
        try Data(repeating: 3, count: 10_000).write(to: root.appendingPathComponent("new-file"))
        model.confirmTrash(removed)
        try await waitUntilIdle(model)
        let updated = try #require(model.snapshot)
        #expect(model.errorMessage == nil)
        #expect(!model.isScanning)
        #expect(updated.scannedAt == initial.scannedAt)
        #expect(updated.duration == initial.duration)
        #expect(updated.root.logicalBytes == 50)
        #expect(updated.root.allocatedBytes == initial.root.allocatedBytes - removed.allocatedBytes)
        #expect(updated.root.descendantCount == 2)
        #expect(updated.nodes[removed.id] == nil)
        #expect(model.expandedFolderIDs == [kept.id])
        #expect(model.barRows.allSatisfy { $0.id != removed.id && $0.id != nested.id })
        #expect(updated.nodes.values.allSatisfy { $0.name != "new-file" })
        #expect(model.currentFolderID == updated.rootID)
        #expect(model.selectedID == (deletingOpenFolder ? nil : kept.id))
        #expect(model.search == (deletingOpenFolder ? "" : "keep"))
        #expect(!model.canTrash(removed))
        #expect(updated.volumeAvailableBytes == initial.volumeAvailableBytes)
        #expect(await mover.calls == 1)
    }

    @Test("Неуспешный перенос не вычитает размеры")
    func failedTrash() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MacSpaceTrashFailure-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("keep"), withIntermediateDirectories: true)
        try Data(repeating: 1, count: 800).write(to: root.appendingPathComponent("keep/data"))
        let mover = TemporaryTrashMover(destination: root, shouldFail: true)
        let model = AppModel(trashService: mover)
        model.startScan(root)
        try await waitUntilIdle(model)
        let initial = try #require(model.snapshot)
        let node = try #require(initial.nodes.values.first { $0.name == "keep" })
        model.selectedID = node.id
        model.confirmTrash(node)
        try await waitUntilIdle(model)
        #expect(model.errorMessage != nil)
        #expect(model.snapshot?.root.logicalBytes == initial.root.logicalBytes)
        #expect(model.snapshot?.root.allocatedBytes == initial.root.allocatedBytes)
        #expect(model.snapshot?.root.descendantCount == initial.root.descendantCount)
        #expect(model.snapshot?.nodes[node.id] != nil)
        #expect(model.selectedID == node.id)
        #expect(FileManager.default.fileExists(atPath: node.url.path))
        #expect(await mover.calls == 1)
    }
}
