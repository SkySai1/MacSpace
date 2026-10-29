import Darwin
import Foundation
import Testing
@testable import MacSpaceCore

struct TemporaryTree {
    let root: URL
    init() throws {
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("MacSpaceTests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
    @discardableResult
    func directory(_ path: String) throws -> URL {
        let url = root.appendingPathComponent(path, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    @discardableResult
    func file(_ path: String, bytes: Int) throws -> URL {
        let url = root.appendingPathComponent(path)
        try Data(repeating: 0x61, count: bytes).write(to: url)
        return url
    }
}

@Suite("Сканирование файловой системы")
struct DiskScannerTests {
    @Test("Размеры, скрытые файлы, пакеты и навигация")
    func aggregateSizes() async throws {
        let tree = try TemporaryTree()
        defer { tree.remove() }
        let folder = try tree.directory("Папка.app/вложенная")
        let nested = try tree.file("Папка.app/вложенная/video.mov", bytes: 18_000)
        let hidden = try tree.file(".hidden", bytes: 111)
        _ = try tree.file("small.txt", bytes: 2_000)
        let snapshot = try await DiskScanner().scan(root: tree.root)

        #expect(snapshot.root.logicalBytes == 20_111)
        #expect(snapshot.nodes[folder.path]?.logicalBytes == 18_000)
        #expect(snapshot.nodes[hidden.path] != nil)
        #expect(snapshot.root.descendantCount == 5)
        #expect(snapshot.nodes.count == 6)
        #expect(snapshot.issues.isEmpty)
        #expect(snapshot.ancestors(of: nested.path).map(\.name) == [tree.root.lastPathComponent, "Папка.app", "вложенная", "video.mov"])
        #expect(snapshot.children(of: snapshot.rootID, metric: .logical).map(\.name) == ["Папка.app", "small.txt", ".hidden"])
        #expect(snapshot.children(of: snapshot.rootID, metric: .logical, ascending: true).first?.name == ".hidden")
        let sum = snapshot.nodes.values.filter { !$0.isDirectory }.reduce(Int64(0)) { $0 + $1.allocatedBytes }
        #expect(snapshot.root.allocatedBytes == sum)
    }

    @Test("Символические ссылки наружу и циклы не обходятся")
    func symbolicLinks() async throws {
        let tree = try TemporaryTree()
        let outside = try TemporaryTree()
        defer { tree.remove(); outside.remove() }
        _ = try outside.file("secret.dat", bytes: 9_000)
        try FileManager.default.createSymbolicLink(at: tree.root.appendingPathComponent("outside"), withDestinationURL: outside.root)
        try FileManager.default.createSymbolicLink(at: tree.root.appendingPathComponent("cycle"), withDestinationURL: tree.root)
        let snapshot = try await DiskScanner().scan(root: tree.root)
        #expect(snapshot.nodes.count == 3)
        #expect(snapshot.root.childIDs.allSatisfy { snapshot.nodes[$0]?.kind == .symbolicLink })
        #expect(snapshot.nodes.values.allSatisfy { $0.name != "secret.dat" })
        #expect(snapshot.issues.isEmpty)
    }

    @Test("Жёсткие ссылки не удваивают выделенное место")
    func hardLinks() async throws {
        let tree = try TemporaryTree()
        defer { tree.remove() }
        let original = try tree.file("a.bin", bytes: 24_000)
        let link = tree.root.appendingPathComponent("b.bin")
        try FileManager.default.linkItem(at: original, to: link)
        let snapshot = try await DiskScanner().scan(root: tree.root)
        #expect(snapshot.root.logicalBytes == 48_000)
        #expect(snapshot.root.allocatedBytes == snapshot.nodes[original.path]?.allocatedBytes)
        #expect(snapshot.nodes[link.path]?.allocatedBytes == 0)
        #expect(snapshot.nodes[link.path]?.sharesStorage == true)
        #expect(snapshot.nodes[original.path]?.identity == snapshot.nodes[link.path]?.identity)
    }

    @Test("Разреженные файлы: логический размер отличается от выделенного")
    func sparseFile() async throws {
        let tree = try TemporaryTree()
        defer { tree.remove() }
        let url = try tree.file("sparse.bin", bytes: 0)
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: 16 * 1_024 * 1_024)
        try handle.close()
        let snapshot = try await DiskScanner().scan(root: tree.root)
        #expect(snapshot.root.logicalBytes == 16 * 1_024 * 1_024)
        #expect(snapshot.root.allocatedBytes < snapshot.root.logicalBytes)
    }

    @Test("Пустые каталоги и файлы с нулевым размером")
    func emptyItems() async throws {
        let tree = try TemporaryTree()
        defer { tree.remove() }
        _ = try tree.directory("empty")
        _ = try tree.file("zero", bytes: 0)
        let snapshot = try await DiskScanner().scan(root: tree.root)
        #expect(snapshot.root.logicalBytes == 0)
        #expect(snapshot.root.allocatedBytes == 0)
        #expect(snapshot.root.descendantCount == 2)
        #expect(snapshot.children(of: snapshot.rootID, metric: .allocated).count == 2)
    }

    @Test("Не читаем содержимое FIFO")
    func specialFile() async throws {
        let tree = try TemporaryTree()
        defer { tree.remove() }
        let fifo = tree.root.appendingPathComponent("pipe")
        #expect(mkfifo(fifo.path, 0o600) == 0)
        let snapshot = try await DiskScanner().scan(root: tree.root)
        #expect(snapshot.nodes[fifo.path]?.kind == .other)
    }

    @Test("Отказ в доступе к папкам не прерывает обход доступных соседей")
    func unreadableDirectory() async throws {
        let tree = try TemporaryTree()
        defer { tree.remove() }
        let blocked = try tree.directory("b-blocked")
        let anotherBlocked = try tree.directory("d-blocked")
        let blockedFile = try tree.file("b-blocked/data.bin", bytes: 500)
        _ = try tree.file("d-blocked/data.bin", bytes: 700)
        let before = try tree.file("a-before.bin", bytes: 100)
        let after = try tree.file("e-after.bin", bytes: 200)
        _ = try tree.directory("c-readable/nested")
        let nested = try tree.file("c-readable/nested/data.bin", bytes: 300)
        for url in [blocked, anotherBlocked] { #expect(chmod(url.path, 0) == 0) }
        defer { for url in [blocked, anotherBlocked] { _ = chmod(url.path, 0o700) } }
        let snapshot = try await DiskScanner().scan(root: tree.root)
        #expect(snapshot.issueCount == 2)
        #expect(Set(snapshot.issues.map(\.path)) == [blocked.path, anotherBlocked.path])
        #expect(snapshot.nodes[blocked.path]?.scanError != nil)
        #expect(snapshot.nodes[anotherBlocked.path]?.scanError != nil)
        #expect(snapshot.nodes[blockedFile.path] == nil)
        #expect(snapshot.nodes[before.path]?.logicalBytes == 100)
        #expect(snapshot.nodes[after.path]?.logicalBytes == 200)
        #expect(snapshot.nodes[nested.path]?.logicalBytes == 300)
        #expect(snapshot.root.logicalBytes == 600)
    }

    @Test("Отказ в доступе к выбранному корню возвращает пропущенную папку", arguments: [false, true])
    func unreadableRoot(metadataDenied: Bool) async throws {
        let tree = try TemporaryTree()
        defer { tree.remove() }
        let parent = try tree.directory("restricted")
        let root = metadataDenied ? try tree.directory("restricted/nested") : parent
        _ = try tree.file(metadataDenied ? "restricted/nested/data.bin" : "restricted/data.bin", bytes: 500)
        #expect(chmod(parent.path, 0) == 0)
        defer { _ = chmod(parent.path, 0o700) }
        let scanner = DiskScanner()
        let snapshot = try await scanner.scan(root: root)
        #expect(snapshot.rootID == root.path)
        #expect(snapshot.root.scanError != nil)
        #expect(snapshot.root.childIDs.isEmpty)
        #expect(snapshot.root.logicalBytes == 0)
        #expect(snapshot.issueCount == 1)

        #expect(chmod(parent.path, 0o700) == 0)
        let readable = try await scanner.scan(root: root)
        #expect(readable.issueCount == 0)
        #expect(readable.root.scanError == nil)
        #expect(readable.root.logicalBytes == 500)
    }

    @Test("Распознаются отказы Cocoa, POSIX и вложенные ошибки")
    func permissionErrors() {
        let cocoa = NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError)
        let posix = NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))
        let wrapped = NSError(domain: NSCocoaErrorDomain, code: NSFileReadUnknownError,
                              userInfo: [NSUnderlyingErrorKey: posix])
        #expect(DiskScanner.isPermissionDenied(cocoa))
        #expect(DiskScanner.isPermissionDenied(posix))
        #expect(DiskScanner.isPermissionDenied(NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))))
        #expect(DiskScanner.isPermissionDenied(wrapped))
        #expect(!DiskScanner.isPermissionDenied(NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT))))
        #expect(!DiskScanner.isPermissionDenied(NSError(domain: NSCocoaErrorDomain, code: NSFileReadUnknownError)))
    }

    @Test("Некорректные корни отклоняются")
    func invalidRoots() async throws {
        let tree = try TemporaryTree()
        defer { tree.remove() }
        let file = try tree.file("file", bytes: 1)
        await #expect(throws: ScanError.self) { try await DiskScanner().scan(root: file) }
        await #expect(throws: ScanError.self) { try await DiskScanner().scan(root: tree.root.appendingPathComponent("missing")) }
    }

    @Test("Отмена прерывает обход; следующий анализ работает")
    func cancellation() async throws {
        let tree = try TemporaryTree()
        defer { tree.remove() }
        for index in 0..<1_000 { _ = try tree.file("\(index).txt", bytes: 10) }
        let scanner = DiskScanner()
        let (stream, continuation) = AsyncStream.makeStream(of: ScanProgress.self)
        let task = Task { try await scanner.scan(root: tree.root) { continuation.yield($0) } }
        var iterator = stream.makeAsyncIterator()
        _ = await iterator.next()
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        continuation.finish()
        let snapshot = try await scanner.scan(root: tree.root)
        #expect(snapshot.root.logicalBytes == 10_000)
    }
}
