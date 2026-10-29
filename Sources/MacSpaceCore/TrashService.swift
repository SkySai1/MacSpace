import Darwin
import Foundation

public enum TrashError: LocalizedError {
    case scanRoot, outsideRoot, symbolicLink, notDirectory, unavailable, changed

    public var errorDescription: String? {
        switch self {
        case .scanRoot: "Корневую папку анализа нельзя переносить в Корзину. Выберите вложенную папку."
        case .outsideRoot: "Объект находится за пределами области анализа."
        case .symbolicLink: "Путь содержит символическую ссылку. Выполните анализ заново."
        case .notDirectory: "Перенос в Корзину доступен только для обычных файлов и папок."
        case .unavailable: "Объект больше недоступен. Выполните анализ заново."
        case .changed: "Объект изменился после анализа. Выполните анализ заново."
        }
    }
}

public protocol TrashMoving: Sendable {
    func moveToTrash(candidate: DiskNode, root: DiskNode) async throws
}

public actor TrashService: TrashMoving {
    public init() {}

    /// Validation is also exposed for tests; it never changes the filesystem.
    public nonisolated static func validate(
        candidate: URL, root: URL,
        expectedCandidate: FileIdentity? = nil, expectedRoot: FileIdentity? = nil
    ) throws -> URL {
        let root = root.standardizedFileURL
        let candidate = candidate.standardizedFileURL
        let rootParts = root.pathComponents
        let candidateParts = candidate.pathComponents
        guard candidate != root else { throw TrashError.scanRoot }
        guard candidateParts.count > rootParts.count,
              candidateParts.starts(with: rootParts) else { throw TrashError.outsideRoot }
        guard root.resolvingSymlinksInPath() == root,
              candidate.resolvingSymlinksInPath() == candidate else { throw TrashError.symbolicLink }
        let values: URLResourceValues
        do {
            values = try candidate.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
        } catch { throw TrashError.unavailable }
        guard values.isSymbolicLink != true else { throw TrashError.symbolicLink }
        guard values.isDirectory == true || values.isRegularFile == true else { throw TrashError.notDirectory }
        for (url, expected) in [(candidate, expectedCandidate), (root, expectedRoot)] {
            guard let expected else { continue }
            var metadata = stat()
            let status = url.withUnsafeFileSystemRepresentation { path in
                guard let path else { return Int32(-1) }
                return Darwin.lstat(path, &metadata)
            }
            guard status == 0 else { throw TrashError.unavailable }
            guard FileIdentity(device: metadata.st_dev, inode: metadata.st_ino) == expected else {
                throw TrashError.changed
            }
        }
        return candidate
    }

    /// Moves an item into the system Trash so Finder can restore it.
    public func moveToTrash(candidate: DiskNode, root: DiskNode) throws {
        let checked = try Self.validate(
            candidate: candidate.url, root: root.url,
            expectedCandidate: candidate.identity, expectedRoot: root.identity
        )
        try FileManager.default.trashItem(at: checked, resultingItemURL: nil)
    }
}
