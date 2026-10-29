import Darwin
import Foundation
import Testing
@testable import MacSpaceCore

@Suite("Очистка только разрешённой тестовой Корзины")
struct TrashDirectoryTests {
    @Test("Удаляются файлы и папки, ссылка не затрагивает внешние данные, корень сохраняется")
    func emptyFixture() async throws {
        let tree = try TemporaryTree()
        defer { tree.remove() }
        let trash = try tree.directory("trash")
        _ = try tree.directory("trash/folder/nested")
        _ = try tree.file("trash/folder/nested/file", bytes: 90)
        _ = try tree.file("trash/file", bytes: 40)
        let outside = try tree.file("outside", bytes: 120)
        try FileManager.default.createSymbolicLink(at: trash.appendingPathComponent("link"), withDestinationURL: outside)
        let snapshot = try await DiskScanner().scan(root: trash)
        let service = TrashDirectoryService(testLocations: [TrashLocation(url: trash, name: "Тестовая Корзина")])
        let result = await service.empty(roots: [snapshot.root])
        #expect(result.failures.isEmpty)
        #expect(result.removedIDs.count == 3)
        #expect(try FileManager.default.contentsOfDirectory(atPath: trash.path).isEmpty)
        #expect(try Data(contentsOf: outside).count == 120)
        let updated = snapshot.removingSubtrees(ids: result.removedIDs)
        #expect(updated.root.logicalBytes == 0)
        #expect(updated.root.descendantCount == 0)
    }

    @Test("Внешний путь и подменённый корень не очищаются")
    func rejectForeignAndReplaced() async throws {
        let tree = try TemporaryTree()
        defer { tree.remove() }
        let trash = try tree.directory("trash")
        _ = try tree.file("trash/old", bytes: 10)
        let outside = try tree.directory("outside")
        let protected = try tree.file("outside/keep", bytes: 20)
        let snapshot = try await DiskScanner().scan(root: trash)
        let foreign = try await DiskScanner().scan(root: outside)
        let service = TrashDirectoryService(testLocations: [TrashLocation(url: trash, name: "Тест")])
        let rejected = await service.empty(roots: [foreign.root])
        #expect(rejected.removedIDs.isEmpty)
        #expect(rejected.failures.count == 1)
        #expect(FileManager.default.fileExists(atPath: protected.path))
        try FileManager.default.moveItem(at: trash, to: tree.root.appendingPathComponent("old-trash"))
        _ = try tree.directory("trash")
        let replacement = try tree.file("trash/new", bytes: 30)
        let changed = await service.empty(roots: [snapshot.root])
        #expect(changed.removedIDs.isEmpty)
        #expect(changed.failures.count == 1)
        #expect(FileManager.default.fileExists(atPath: replacement.path))
    }

    @Test("Корень-ссылка и отказ доступа не приводят к удалению")
    func denyLinkAndPermissions() async throws {
        let tree = try TemporaryTree()
        defer { tree.remove() }
        let actual = try tree.directory("actual")
        let file = try tree.file("actual/keep", bytes: 30)
        let link = tree.root.appendingPathComponent("trash-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: actual)
        let realSnapshot = try await DiskScanner().scan(root: actual)
        let fake = DiskNode(url: link, parentID: nil, kind: .directory, identity: realSnapshot.root.identity)
        let linkedService = TrashDirectoryService(testLocations: [TrashLocation(url: link, name: "Ссылка")])
        let result = await linkedService.empty(roots: [fake])
        #expect(result.removedIDs.isEmpty)
        #expect(result.failures.count == 1)
        #expect(chmod(actual.path, 0) == 0)
        defer { _ = chmod(actual.path, 0o700) }
        let service = TrashDirectoryService(testLocations: [TrashLocation(url: actual, name: "Тест")])
        let denied = await service.empty(roots: [realSnapshot.root])
        #expect(denied.removedIDs.isEmpty)
        #expect(!denied.failures.isEmpty)
        #expect(chmod(actual.path, 0o700) == 0)
        #expect(FileManager.default.fileExists(atPath: file.path))
    }
}
