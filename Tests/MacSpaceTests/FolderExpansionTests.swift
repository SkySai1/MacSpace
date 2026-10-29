import Foundation
import Testing
@testable import MacSpace

@Suite("Разворачивание папок в шкалах")
@MainActor
struct FolderExpansionTests {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MacSpaceExpansion-" + UUID().uuidString)
        for path in ["Parent/Nested", "Other", "Empty"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(path), withIntermediateDirectories: true)
        }
        for (path, bytes) in [("Parent/Nested/deep", 100), ("Parent/small", 20), ("Other/file", 50), ("top", 200)] {
            try Data(repeating: 1, count: bytes).write(to: root.appendingPathComponent(path))
        }
        return root
    }

    private func waitForScan(_ model: AppModel) async throws {
        let deadline = Date().addingTimeInterval(10)
        while model.isScanning && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!model.isScanning)
        #expect(model.errorMessage == nil)
    }

    @Test("Стрелка раскрывает дерево, сохраняет текущую папку и сортирует детей внутри родителей")
    func expandAndCollapse() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel()
        model.metric = .logical
        model.startScan(root)
        try await waitForScan(model)
        let initial = try #require(model.snapshot)
        let parent = try #require(initial.nodes.values.first { $0.name == "Parent" })
        let nested = try #require(initial.nodes.values.first { $0.name == "Nested" })
        let empty = try #require(initial.nodes.values.first { $0.name == "Empty" })
        let file = try #require(initial.nodes.values.first { $0.name == "top" })
        #expect(model.barRows.map { $0.content.name } == ["top", "Parent", "Other", "Empty"])

        model.toggleExpansion(parent.id)
        #expect(model.barRows.map { $0.content.name } == ["top", "Parent", "Nested", "small", "Other", "Empty"])
        model.toggleExpansion(nested.id)
        #expect(model.barRows.map { $0.content.name } == ["top", "Parent", "Nested", "deep", "small", "Other", "Empty"])
        #expect(model.barRows.map(\.depth) == [0, 0, 1, 2, 1, 0, 0])
        #expect(model.currentFolderID == initial.rootID)
        #expect(model.snapshot?.scannedAt == initial.scannedAt)
        #expect(model.snapshot?.root.logicalBytes == 370)
        #expect(!model.isScanning)
        let deep = try #require(model.barRows.first { $0.content.name == "deep" })
        #expect(abs(deep.content.fraction - 100.0 / 370.0) < 0.0001)
        #expect(deep.colorIndex == model.barRows.first { $0.id == parent.id }?.colorIndex)

        model.toggleExpansion(parent.id)
        #expect(model.barRows.map { $0.content.name } == ["top", "Parent", "Other", "Empty"])
        #expect(model.selectedID == parent.id)
        model.toggleExpansion(parent.id)
        #expect(model.barRows.contains { $0.content.name == "deep" })
        model.tableSort = [KeyPathComparator(\ContentRow.bytes)]
        #expect(model.barRows.map { $0.content.name } == ["Empty", "Other", "Parent", "small", "Nested", "deep", "top"])
        model.search = "Parent"
        #expect(model.barRows.map { $0.content.name } == ["Parent", "small", "Nested", "deep"])

        let expanded = model.expandedFolderIDs
        #expect(!model.canExpand(empty))
        #expect(!model.canExpand(file))
        model.toggleExpansion(empty.id)
        model.toggleExpansion(file.id)
        #expect(model.expandedFolderIDs == expanded)
    }

    @Test("Развёрнутые папки сохраняются при навигации и обновлении, исчезнувшие пути очищаются")
    func retainAndPrune() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel()
        model.startScan(root)
        try await waitForScan(model)
        let initial = try #require(model.snapshot)
        let parent = try #require(initial.nodes.values.first { $0.name == "Parent" })
        let nested = try #require(initial.nodes.values.first { $0.name == "Nested" })
        model.toggleExpansion(parent.id)
        model.toggleExpansion(nested.id)
        model.navigate(to: parent.id)
        model.goUp()
        #expect(model.expandedFolderIDs == [parent.id, nested.id])
        try FileManager.default.removeItem(at: nested.url)
        model.rescan()
        try await waitForScan(model)
        #expect(model.expandedFolderIDs == [parent.id])
        #expect(model.barRows.contains { $0.content.name == "small" })

        model.startScan(root.appendingPathComponent("Other"))
        try await waitForScan(model)
        #expect(model.expandedFolderIDs.isEmpty)
    }
}
