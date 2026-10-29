import Darwin
import Foundation
import Testing
@testable import MacSpaceCore

@Suite("Обновление снимка без сканирования")
struct SnapshotRemovalTests {
    @Test("Пакетный перенос исключает повторный учёт родителей и передаёт оставшуюся жёсткую ссылку")
    func batchRemoval() async throws {
        let tree = try TemporaryTree()
        defer { tree.remove() }
        for name in ["remove", "b", "c"] { _ = try tree.directory(name) }
        let owner = try tree.file("remove/file", bytes: 20_000)
        for name in ["b", "c"] { try FileManager.default.linkItem(at: owner, to: tree.root.appendingPathComponent("\(name)/link")) }
        let sibling = try tree.file("sibling", bytes: 100)
        _ = try tree.file("keep", bytes: 1_000)
        let snapshot = try await DiskScanner().scan(root: tree.root)
        let removed = tree.root.appendingPathComponent("remove").path
        let linkB = tree.root.appendingPathComponent("b/link").path
        let updated = snapshot.removingSubtrees(ids: [removed, owner.path, sibling.path, linkB])
        #expect(updated.root.logicalBytes == 21_000)
        #expect(updated.root.descendantCount == 4)
        #expect(updated.root.allocatedBytes == snapshot.root.allocatedBytes - (snapshot.nodes[sibling.path]?.allocatedBytes ?? 0))
        #expect(updated.nodes[tree.root.appendingPathComponent("c/link").path]?.sharesStorage == false)
        #expect(updated.scannedAt == snapshot.scannedAt)
    }
    @Test("Удаление поддерева вычитает размеры и счётчики только у предков")
    func subtractSubtree() async throws {
        let tree = try TemporaryTree()
        defer { tree.remove() }
        _ = try tree.directory("parent/remove/nested")
        let removedFile = try tree.file("parent/remove/nested/data", bytes: 10_000)
        let keptFile = try tree.file("parent/keep", bytes: 400)
        let siblingFile = try tree.file("outside", bytes: 700)
        let snapshot = try await DiskScanner().scan(root: tree.root)
        let id = tree.root.appendingPathComponent("parent/remove").path
        let removed = try #require(snapshot.nodes[id])
        let parentID = try #require(removed.parentID)

        let updated = snapshot.removingSubtree(id: id)
        #expect(updated.root.logicalBytes == 1_100)
        #expect(updated.root.allocatedBytes == snapshot.root.allocatedBytes - removed.allocatedBytes)
        #expect(updated.nodes[parentID]?.logicalBytes == 400)
        #expect(updated.nodes[parentID]?.descendantCount == 1)
        #expect(updated.root.descendantCount == 3)
        #expect(updated.nodes[id] == nil)
        #expect(updated.nodes[removedFile.path] == nil)
        #expect(updated.nodes[parentID]?.childIDs == [keptFile.path])
        #expect(updated.nodes[siblingFile.path]?.allocatedBytes == snapshot.nodes[siblingFile.path]?.allocatedBytes)
        #expect(updated.scannedAt == snapshot.scannedAt)
        #expect(updated.duration == snapshot.duration)
        #expect(updated.volumeAvailableBytes == snapshot.volumeAvailableBytes)
        #expect(updated.volumeTotalBytes == snapshot.volumeTotalBytes)
        #expect(snapshot.nodes[id] != nil)
        #expect(FileManager.default.fileExists(atPath: removedFile.path))
        #expect(updated.removingSubtree(id: id).root.logicalBytes == updated.root.logicalBytes)
        #expect(updated.removingSubtree(id: updated.rootID).nodes.count == updated.nodes.count)
    }

    @Test("Жёсткие ссылки сохраняют учёт блоков при последовательных удалениях", arguments: [true, false])
    func transferHardLinks(removeOwnerFirst: Bool) async throws {
        let tree = try TemporaryTree()
        defer { tree.remove() }
        for name in ["a", "b", "c"] { _ = try tree.directory(name) }
        let original = try tree.file("a/file", bytes: 20_000)
        for name in ["b", "c"] {
            try FileManager.default.linkItem(at: original, to: tree.root.appendingPathComponent("\(name)/file"))
        }
        var snapshot = try await DiskScanner().scan(root: tree.root)
        let allocated = snapshot.root.allocatedBytes
        let first = removeOwnerFirst ? "a" : "b"
        let nextOwner = removeOwnerFirst ? "b" : "a"
        snapshot = snapshot.removingSubtree(id: tree.root.appendingPathComponent(first).path)
        let ownerID = tree.root.appendingPathComponent("\(nextOwner)/file").path
        let aliasID = tree.root.appendingPathComponent("c/file").path
        #expect(snapshot.root.logicalBytes == 40_000)
        #expect(snapshot.root.allocatedBytes == allocated)
        #expect(snapshot.nodes[ownerID]?.allocatedBytes == allocated)
        #expect(snapshot.nodes[ownerID]?.sharesStorage == false)
        #expect(snapshot.nodes[ownerID]?.accountedAtID == nil)
        #expect(snapshot.nodes[aliasID]?.accountedAtID == ownerID)

        snapshot = snapshot.removingSubtree(id: tree.root.appendingPathComponent(nextOwner).path)
        #expect(snapshot.root.allocatedBytes == allocated)
        #expect(snapshot.nodes[aliasID]?.allocatedBytes == allocated)
        #expect(snapshot.nodes[aliasID]?.sharesStorage == false)
        #expect(snapshot.nodes[aliasID]?.accountedAtID == nil)
        snapshot = snapshot.removingSubtree(id: tree.root.appendingPathComponent("c").path)
        #expect(snapshot.root.allocatedBytes == 0)
        #expect(snapshot.root.logicalBytes == 0)
        #expect(snapshot.root.descendantCount == 0)
        #expect(snapshot.nodes.count == 1)
    }

    @Test("Отчёт о пропусках корректно обновляется даже при ограничении в 200 записей")
    func removeIssues() async throws {
        let tree = try TemporaryTree()
        defer { tree.remove() }
        let parent = try tree.directory("remove")
        let kept = try tree.directory("remove-backup")
        var blocked: [URL] = []
        defer { for url in blocked { _ = chmod(url.path, 0o700) } }
        for index in 0..<205 {
            let url = try tree.directory("remove/\(index)")
            blocked.append(url)
            #expect(chmod(url.path, 0) == 0)
        }
        blocked.append(kept)
        #expect(chmod(kept.path, 0) == 0)
        let snapshot = try await DiskScanner().scan(root: tree.root)
        #expect(snapshot.issueCount == 206)
        #expect(snapshot.issues.count == 200)
        #expect(snapshot.root.scanIssueCount == 206)
        #expect(snapshot.nodes[parent.path]?.scanIssueCount == 205)
        let updated = snapshot.removingSubtree(id: parent.path)
        #expect(updated.issueCount == 1)
        #expect(updated.root.scanIssueCount == 1)
        #expect(updated.issues.count == 1)
        #expect(updated.issues.first?.path == kept.path)
        #expect(updated.nodes[kept.path]?.scanError != nil)
    }

    @Test("Повторный путь не ссылается на удалённый узел")
    func orphanedDirectoryAlias() {
        let rootURL = URL(fileURLWithPath: "/fixture")
        let original = DiskNode(url: rootURL.appendingPathComponent("original"), parentID: rootURL.path, kind: .directory)
        let alias = DiskNode(url: rootURL.appendingPathComponent("alias"), parentID: rootURL.path,
                             kind: .directory, accountedAtID: original.id)
        let root = DiskNode(url: rootURL, parentID: nil, kind: .directory,
                            childIDs: [original.id, alias.id], descendantCount: 2)
        let snapshot = ScanSnapshot(rootID: root.id, nodes: [root.id: root, original.id: original, alias.id: alias])
        let updated = snapshot.removingSubtree(id: original.id)
        #expect(updated.nodes[alias.id]?.accountedAtID == nil)
        #expect(updated.nodes[alias.id]?.scanError != nil)
        #expect(updated.root.descendantCount == 1)
        #expect(updated.issueCount == 1)
        #expect(updated.root.scanIssueCount == 1)
    }
}
