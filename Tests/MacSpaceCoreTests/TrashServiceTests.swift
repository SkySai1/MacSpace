import Foundation
import Testing
@testable import MacSpaceCore

@Suite("Проверки перед переносом в Корзину")
struct TrashServiceTests {
    @Test("Разрешена только вложенная папка")
    func validFolder() throws {
        let tree = try TemporaryTree()
        defer { tree.remove() }
        let folder = try tree.directory("nested/folder")
        #expect(try TrashService.validate(candidate: folder, root: tree.root) == folder)
    }

    @Test("Файл разрешён; корень, внешний и отсутствующий пути отклоняются")
    func rejectedPaths() throws {
        let tree = try TemporaryTree()
        let outside = try TemporaryTree()
        defer { tree.remove(); outside.remove() }
        let file = try tree.file("file.txt", bytes: 10)
        #expect(throws: TrashError.self) { try TrashService.validate(candidate: tree.root, root: tree.root) }
        #expect(throws: TrashError.self) { try TrashService.validate(candidate: outside.root, root: tree.root) }
        #expect(try TrashService.validate(candidate: file, root: tree.root) == file)
        #expect(throws: TrashError.self) { try TrashService.validate(candidate: tree.root.appendingPathComponent("missing"), root: tree.root) }
    }

    @Test("Проверка по компонентам пути, а не по общему префиксу")
    func prefixCollision() throws {
        let tree = try TemporaryTree()
        defer { tree.remove() }
        let root = try tree.directory("data")
        let outside = try tree.directory("data-backup/nested")
        #expect(throws: TrashError.self) { try TrashService.validate(candidate: outside, root: root) }
        #expect(throws: TrashError.self) { try TrashService.validate(candidate: root.appendingPathComponent("../data-backup/nested"), root: root) }
    }

    @Test("Ссылка на папку, в том числе внутри корня, отклоняется")
    func symlinkRejection() throws {
        let tree = try TemporaryTree()
        defer { tree.remove() }
        let actual = try tree.directory("actual/nested")
        let link = tree.root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: actual.deletingLastPathComponent())
        #expect(throws: TrashError.self) { try TrashService.validate(candidate: link, root: tree.root) }
        #expect(throws: TrashError.self) { try TrashService.validate(candidate: link.appendingPathComponent("nested"), root: tree.root) }
    }

    @Test("Подмена папки после анализа обнаруживается по inode")
    func replacedDirectory() async throws {
        let tree = try TemporaryTree()
        defer { tree.remove() }
        let folder = try tree.directory("target")
        let snapshot = try await DiskScanner().scan(root: tree.root)
        let identity = try #require(snapshot.nodes[folder.path]?.identity)
        // Retain the old inode to avoid immediate inode reuse by the filesystem.
        try FileManager.default.moveItem(at: folder, to: tree.root.appendingPathComponent("old"))
        _ = try tree.directory("target")
        #expect(throws: TrashError.self) {
            try TrashService.validate(candidate: folder, root: tree.root, expectedCandidate: identity, expectedRoot: snapshot.root.identity)
        }
    }
}
