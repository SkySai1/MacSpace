import Darwin
import Foundation

public enum ScanError: LocalizedError {
    case notDirectory(String)
    case cannotRead(String, String)

    public var errorDescription: String? {
        switch self {
        case .notDirectory(let path): "Выберите папку для анализа: \(path)"
        case .cannotRead(let path, let reason): "Не удалось прочитать \(path). \(reason)"
        }
    }
}

/// Owns filesystem work on a separate executor. No symlink traversal or recursion on the call stack.
public actor DiskScanner {
    public init() {}

    /// TCC and filesystem permissions can surface either as Cocoa or POSIX errors.
    nonisolated static func isPermissionDenied(_ error: Error) -> Bool {
        var current: NSError? = error as NSError
        for _ in 0..<8 {
            guard let underlying = current else { return false }
            if underlying.domain == NSCocoaErrorDomain && underlying.code == NSFileReadNoPermissionError {
                return true
            }
            if underlying.domain == NSPOSIXErrorDomain &&
                (underlying.code == Int(EACCES) || underlying.code == Int(EPERM)) {
                return true
            }
            current = underlying.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return false
    }

    private enum Step {
        case visit(URL, parentID: String?)
        case finishDirectory(String)
    }

    public func scan(
        root requestedRoot: URL,
        progress: @Sendable (ScanProgress) -> Void = { _ in }
    ) async throws -> ScanSnapshot {
        try Task.checkCancellation()
        let root = requestedRoot.standardizedFileURL.resolvingSymlinksInPath()
        let start = Date()
        var nodes: [String: DiskNode] = [:]
        var steps: [Step] = [.visit(root, parentID: nil)]
        var filePaths: [FileIdentity: String] = [:]
        var directoryPaths: [FileIdentity: String] = [:]
        var issues: [ScanIssue] = []
        var issueCount = 0
        var visitedCount = 0
        var allocatedBytes: Int64 = 0
        var lastProgress = Date.distantPast

        func recordIssue(_ url: URL, _ message: String) {
            issueCount += 1
            // Keep memory bounded even on a whole disk with many inaccessible entries.
            if issues.count < 200 { issues.append(ScanIssue(path: url.path, message: message)) }
        }

        while let step = steps.popLast() {
            try Task.checkCancellation()
            switch step {
            case .finishDirectory(let id):
                guard var directory = nodes[id] else { continue }
                for childID in directory.childIDs {
                    guard let child = nodes[childID] else { continue }
                    directory.logicalBytes = addingBytes(directory.logicalBytes, child.logicalBytes)
                    directory.allocatedBytes = addingBytes(directory.allocatedBytes, child.allocatedBytes)
                    directory.descendantCount += child.descendantCount + 1
                    directory.scanIssueCount += child.scanIssueCount
                }
                nodes[id] = directory

            case .visit(let url, let parentID):
                var metadata = stat()
                let result = url.withUnsafeFileSystemRepresentation { path in
                    guard let path else { return Int32(-1) }
                    return Darwin.lstat(path, &metadata)
                }
                guard result == 0 else {
                    let errorCode = errno
                    let denied = errorCode == EACCES || errorCode == EPERM
                    let message = denied ? "Нет доступа. Объект пропущен." : String(cString: strerror(errorCode))
                    if parentID == nil {
                        guard denied else { throw ScanError.cannotRead(url.path, message) }
                        // A denied root still produces a valid partial snapshot, without an alert.
                        nodes[url.path] = DiskNode(url: url, parentID: nil, kind: .directory, scanError: message, scanIssueCount: 1)
                        visitedCount += 1
                    } else if let parentID {
                        nodes[parentID]?.scanIssueCount += 1
                    }
                    recordIssue(url, message)
                    continue
                }

                let type = metadata.st_mode & S_IFMT
                let kind: NodeKind = switch type {
                case S_IFDIR: .directory
                case S_IFREG: .regularFile
                case S_IFLNK: .symbolicLink
                default: .other
                }
                if parentID == nil && kind != .directory { throw ScanError.notDirectory(url.path) }

                var shared = false
                let identity = FileIdentity(device: metadata.st_dev, inode: metadata.st_ino)
                var accountedAtID: String?
                if kind == .regularFile {
                    accountedAtID = filePaths[identity]
                    shared = accountedAtID != nil
                    if !shared { filePaths[identity] = url.path }
                } else if kind == .directory {
                    accountedAtID = directoryPaths[identity]
                }
                let logical = kind == .directory ? 0 : max(0, Int64(metadata.st_size))
                let blocks = max(0, Int64(metadata.st_blocks))
                let (blockBytes, blockOverflow) = blocks.multipliedReportingOverflow(by: 512)
                let allocated = kind == .directory || shared ? 0 : (blockOverflow ? Int64.max : blockBytes)
                var node = DiskNode(
                    url: url, parentID: parentID, kind: kind, identity: identity,
                    logicalBytes: logical, allocatedBytes: max(0, allocated), sharesStorage: shared, accountedAtID: accountedAtID
                )
                visitedCount += 1
                allocatedBytes = addingBytes(allocatedBytes, node.allocatedBytes)

                if kind == .directory && accountedAtID == nil {
                    do {
                        // Include hidden files and descend into file packages such as .app bundles.
                        let entries = try FileManager.default.contentsOfDirectory(
                            at: url, includingPropertiesForKeys: nil, options: []
                        )
                        // Foundation may rewrite /var to /private/var in returned URLs.
                        // Keep every ID under the same root spelling, without resolving symlinks.
                        .map { url.appendingPathComponent($0.lastPathComponent) }
                        .sorted { $0.path < $1.path }
                        // A denied path must not prevent a later, accessible alias from being scanned.
                        directoryPaths[identity] = url.path
                        steps.append(.finishDirectory(url.path))
                        for entry in entries.reversed() { steps.append(.visit(entry, parentID: url.path)) }
                    } catch {
                        let denied = Self.isPermissionDenied(error)
                        if parentID == nil && !denied { throw ScanError.cannotRead(url.path, error.localizedDescription) }
                        let message = denied ? "Нет доступа. Содержимое папки пропущено." : error.localizedDescription
                        node.scanError = message
                        node.scanIssueCount = 1
                        recordIssue(url, message)
                    }
                }
                nodes[node.id] = node
                if let parentID { nodes[parentID]?.childIDs.append(node.id) }

                if Date().timeIntervalSince(lastProgress) >= 0.1 {
                    progress(ScanProgress(visitedCount: visitedCount, allocatedBytes: allocatedBytes, currentPath: url.path))
                    lastProgress = .now
                }
                if visitedCount.isMultiple(of: 256) { await Task.yield() }
            }
        }
        try Task.checkCancellation()
        let capacity = try? root.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey])
        progress(ScanProgress(visitedCount: visitedCount, allocatedBytes: allocatedBytes, currentPath: root.path))
        return ScanSnapshot(
            rootID: root.path, nodes: nodes, issues: issues, issueCount: issueCount,
            scannedAt: start, duration: Date().timeIntervalSince(start),
            volumeTotalBytes: capacity?.volumeTotalCapacity.map(Int64.init),
            volumeAvailableBytes: capacity?.volumeAvailableCapacity.map(Int64.init)
        )
    }
}
