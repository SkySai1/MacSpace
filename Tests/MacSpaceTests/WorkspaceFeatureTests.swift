import AppKit
import Darwin
import Foundation
import Testing
@testable import MacSpace
@testable import MacSpaceCore

private actor BatchFixtureMover: TrashMoving {
    let destination: URL
    let failingName: String?
    private(set) var moved: [String] = []
    init(destination: URL, failingName: String? = nil) { self.destination = destination; self.failingName = failingName }
    func moveToTrash(candidate: DiskNode, root: DiskNode) throws {
        if candidate.name == failingName { throw CocoaError(.fileWriteNoPermission) }
        let url = try TrashService.validate(candidate: candidate.url, root: root.url,
                                            expectedCandidate: candidate.identity, expectedRoot: root.identity)
        try FileManager.default.moveItem(at: url, to: destination.appendingPathComponent(UUID().uuidString))
        moved.append(candidate.id)
    }
}

@Suite("Мультивыбор, Корзина и кэш карты")
@MainActor
struct WorkspaceFeatureTests {
    @Test("Без доступа к Корзине или при подмене её ссылкой очистка недоступна", arguments: [true, false])
    func unavailableTrash(useLink: Bool) async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        try write("actual/keep", in: root, bytes: 30)
        let actual = root.appendingPathComponent("actual")
        let trash = useLink ? root.appendingPathComponent("link") : actual
        if useLink { try FileManager.default.createSymbolicLink(at: trash, withDestinationURL: actual) }
        else { #expect(chmod(actual.path, 0) == 0) }
        defer { _ = chmod(actual.path, 0o700) }
        let model = AppModel(trashManager: TrashDirectoryService(testLocations: [TrashLocation(url: trash, name: "Тест")]))
        model.selectTab(.trash); try await wait(model)
        #expect(!model.canEmptyTrash)
        #expect(model.errorMessage == nil)
        #expect((model.snapshot?.issueCount ?? 0) > 0)
        model.requestEmptyTrash()
        #expect(!model.showEmptyConfirmation)
        #expect(chmod(actual.path, 0o700) == 0)
        #expect(FileManager.default.fileExists(atPath: actual.appendingPathComponent("keep").path))
    }
    private func wait(_ model: AppModel) async throws {
        let deadline = Date().addingTimeInterval(10)
        while model.isBusy && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!model.isBusy)
    }
    private func temporary() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("MacSpaceFeatures-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func write(_ path: String, in root: URL, bytes: Int) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 1, count: bytes).write(to: url)
    }

    @Test("⌘ и Shift выбирают несколько файлов; родитель с потомком переносится один раз")
    func multiSelectionAndFiles() async throws {
        let temporary = try temporary(); defer { try? FileManager.default.removeItem(at: temporary) }
        let root = temporary.appendingPathComponent("scan"), holding = temporary.appendingPathComponent("holding")
        try FileManager.default.createDirectory(at: holding, withIntermediateDirectories: true)
        try write("folder/child", in: root, bytes: 90)
        try write("first", in: root, bytes: 60)
        try write("last", in: root, bytes: 20)
        let mover = BatchFixtureMover(destination: holding)
        let model = AppModel(trashService: mover)
        model.metric = .logical; model.mode = .table
        model.startScan(root); try await wait(model)
        let initial = try #require(model.snapshot)
        let rows = model.rows
        model.select(rows[0].id)
        model.select(rows[2].id, modifiers: [.shift])
        #expect(model.selectedIDs == Set(rows.map(\.id)))
        model.select(rows[1].id, modifiers: [.command])
        #expect(model.selectedIDs.count == 2)
        let folder = try #require(initial.nodes.values.first { $0.name == "folder" })
        let file = try #require(initial.nodes.values.first { $0.name == "first" })
        model.selectedIDs = [folder.id, folder.childIDs[0], file.id]
        #expect(model.selectionSummary.logicalBytes == 150)
        #expect(model.canTrashSelection)
        model.requestTrash()
        #expect(model.pendingTrashItems.count == 2)
        model.confirmPendingTrash(); try await wait(model)
        #expect(await mover.moved.count == 2)
        #expect(model.snapshot?.root.logicalBytes == 20)
        #expect(model.snapshot?.scannedAt == initial.scannedAt)
        #expect(!model.isScanning)
        #expect(model.selectedIDs.isEmpty)
    }

    @Test("Частичный отказ не мешает переносу остальных выбранных файлов")
    func partialFailure() async throws {
        let temporary = try temporary(); defer { try? FileManager.default.removeItem(at: temporary) }
        let root = temporary.appendingPathComponent("scan"), holding = temporary.appendingPathComponent("holding")
        try FileManager.default.createDirectory(at: holding, withIntermediateDirectories: true)
        try write("ok", in: root, bytes: 100)
        try write("denied", in: root, bytes: 200)
        let model = AppModel(trashService: BatchFixtureMover(destination: holding, failingName: "denied"))
        model.startScan(root); try await wait(model)
        model.selectedIDs = Set(model.rows.map(\.id))
        model.requestTrash(); model.confirmPendingTrash(); try await wait(model)
        #expect(model.snapshot?.root.logicalBytes == 200)
        #expect(model.selectedIDs.count == 1)
        #expect(model.errorMessage != nil)
        #expect(model.rows.map(\.name) == ["denied"])
    }

    @Test("Корзина анализируется отдельно; очистка требует подтверждения и обновляет только снимок")
    func trashWorkspace() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let trash = root.appendingPathComponent("trash")
        try write("analysis/keep", in: root, bytes: 50)
        try write("trash/folder/file", in: root, bytes: 200)
        try write("trash/file", in: root, bytes: 40)
        let manager = TrashDirectoryService(testLocations: [TrashLocation(url: trash, name: "Тестовая Корзина")])
        let model = AppModel(trashManager: manager)
        model.startScan(root); try await wait(model)
        #expect(model.snapshot?.root.logicalBytes == 290)
        let analysisDate = model.snapshot?.scannedAt
        model.selectTab(.trash); try await wait(model)
        #expect(model.snapshot?.root.logicalBytes == 240)
        #expect(model.canEmptyTrash)
        #expect(!model.canTrash(model.snapshot?.nodes[trash.path]))
        model.requestEmptyTrash()
        #expect(model.showEmptyConfirmation)
        #expect(FileManager.default.fileExists(atPath: trash.appendingPathComponent("file").path))
        model.cancelDestructivePrompt()
        #expect(!model.showEmptyConfirmation)
        #expect(FileManager.default.fileExists(atPath: trash.appendingPathComponent("file").path))
        let trashDate = model.snapshot?.scannedAt
        model.requestEmptyTrash(); model.confirmEmptyTrash(); try await wait(model)
        #expect(model.snapshot?.root.logicalBytes == 0)
        #expect(model.snapshot?.scannedAt == trashDate)
        #expect(!model.canEmptyTrash)
        #expect(try FileManager.default.contentsOfDirectory(atPath: trash.path).isEmpty)
        model.selectTab(.analysis)
        #expect(model.snapshot?.root.logicalBytes == 50)
        #expect(model.snapshot?.scannedAt == analysisDate)
    }

    @Test("Выделение и раскрытие используют готовые строки и геометрию")
    func cachedSelectionAndMap() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        try write("Длинное название папки, которое не должно перекрывать её размер/child/data", in: root, bytes: 20_000)
        for index in 0..<1_000 { try write("files/file-\(index)", in: root, bytes: index + 1) }
        let model = AppModel(); model.startScan(root); try await wait(model)
        let folder = try #require(model.snapshot?.nodes.values.first { $0.name == "files" })
        model.toggleExpansion(folder.id)
        _ = model.rows; _ = model.barRows; _ = model.sidebarRows
        let buildCount = model.rowsBuildCount
        let ids = model.barRows.map(\.id)
        let start = ContinuousClock.now
        for index in 0..<1_000 {
            model.select(ids[index % ids.count])
            _ = model.rows; _ = model.barRows; _ = model.sidebarRows
        }
        let elapsed = ContinuousClock.now - start
        print("MacSpace: 1000 выборов с кэшированными строками: \(elapsed)")
        #expect(model.rowsBuildCount == buildCount)
        model.mode = .map
        let viewport = CGSize(width: 1000, height: 600)
        await model.prepareMap(size: viewport)
        let parent = try #require(model.visibleMapTiles.first { $0.hasChildren })
        let originalRect = parent.rect
        let layouts = model.mapLayoutBuildCount
        let currentFolder = model.currentFolderID
        model.activateMapTile(parent, header: false)
        let expandedIDs = model.visibleMapTiles.map(\.id)
        #expect(model.visibleMapTiles.count > model.rows.count)
        #expect(model.visibleMapTiles.first { $0.id == parent.id }?.rect == originalRect)
        model.activateMapTile(parent, header: true)
        model.activateMapTile(parent, header: false)
        #expect(model.visibleMapTiles.map(\.id) == expandedIDs)
        model.select(parent.nodeID, modifiers: [.command])
        await model.prepareMap(size: viewport)
        #expect(model.mapLayoutBuildCount == layouts)
        #expect(model.currentFolderID == currentFolder)
        model.metric = .logical; await model.prepareMap(size: viewport)
        #expect(model.mapLayoutBuildCount == layouts + 1)
        model.metric = .allocated; await model.prepareMap(size: viewport)
        #expect(model.mapLayoutBuildCount == layouts + 1)
        let canceled = Task { await model.prepareMap(size: CGSize(width: viewport.width + 8, height: viewport.height)) }
        canceled.cancel(); await canceled.value
        await model.prepareMap(size: viewport)
        #expect(!model.isPreparingMap)
        #expect(!model.visibleMapTiles.isEmpty)
        #expect(model.mapLayoutBuildCount == layouts + 1)
    }
}
