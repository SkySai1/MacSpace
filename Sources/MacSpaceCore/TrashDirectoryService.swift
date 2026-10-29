import Darwin
import Foundation

public struct TrashLocation: Identifiable, Sendable {
    public var id: String { url.path }
    public let url: URL
    public let name: String
    public init(url: URL, name: String) { self.url = url; self.name = name }
}

public struct TrashEmptyResult: Sendable {
    public let removedIDs: Set<String>
    public let failures: [ScanIssue]
    public init(removedIDs: Set<String>, failures: [ScanIssue] = []) {
        self.removedIDs = removedIDs; self.failures = failures
    }
}

public protocol TrashManaging: Sendable {
    func locations() async -> [TrashLocation]
    func empty(roots: [DiskNode]) async -> TrashEmptyResult
}

public actor TrashDirectoryService: TrashManaging {
    private let testLocations: [TrashLocation]?
    public init() { testLocations = nil }
    // Only @testable clients can supply arbitrary roots; production roots come from macOS.
    init(testLocations: [TrashLocation]) { self.testLocations = testLocations }

    public func locations() -> [TrashLocation] {
        if let testLocations { return testLocations }
        let manager = FileManager.default
        let home = manager.homeDirectoryForCurrentUser.resolvingSymlinksInPath()
        let standard = manager.urls(for: .trashDirectory, in: .userDomainMask).first
            ?? home.appendingPathComponent(".Trash", isDirectory: true)
        let homeTrash = standard.deletingLastPathComponent().resolvingSymlinksInPath()
            .appendingPathComponent(standard.lastPathComponent, isDirectory: true).standardizedFileURL
        var homeMetadata = stat()
        let homeStatus = homeTrash.withUnsafeFileSystemRepresentation { Darwin.lstat($0!, &homeMetadata) }
        var result: [TrashLocation] = homeStatus == 0 || errno != ENOENT
            ? [TrashLocation(url: homeTrash, name: "Корзина на Mac")] : []
        let volumes = manager.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeNameKey], options: [.skipHiddenVolumes]) ?? []
        for volume in volumes where volume.path.hasPrefix("/Volumes/") {
            let candidate = volume.resolvingSymlinksInPath().appendingPathComponent(".Trashes/\(getuid())", isDirectory: true)
                .standardizedFileURL
            var metadata = stat()
            let status = candidate.withUnsafeFileSystemRepresentation { Darwin.lstat($0!, &metadata) }
            if status == 0 && metadata.st_mode & S_IFMT == S_IFDIR && !result.contains(where: { $0.id == candidate.path }) {
                let name = (try? volume.resourceValues(forKeys: [.volumeNameKey]).volumeName) ?? volume.lastPathComponent
                result.append(TrashLocation(url: candidate, name: "Корзина · \(name)"))
            }
        }
        return result
    }

    public func empty(roots: [DiskNode]) -> TrashEmptyResult {
        let allowed = Set(locations().map(\.id))
        var removed: Set<String> = []
        var failures: [ScanIssue] = []
        for root in roots {
            do {
                try validateRoot(root, allowed: allowed)
                let entries = try FileManager.default.contentsOfDirectory(at: root.url, includingPropertiesForKeys: nil)
                for entry in entries {
                    let candidate = root.url.appendingPathComponent(entry.lastPathComponent)
                    do {
                        try validateRoot(root, allowed: allowed)
                        // removeItem unlinks symlinks themselves; it never follows their targets.
                        try FileManager.default.removeItem(at: candidate)
                        removed.insert(candidate.path)
                    } catch {
                        failures.append(ScanIssue(path: candidate.path, message: error.localizedDescription))
                    }
                }
            } catch {
                failures.append(ScanIssue(path: root.id, message: error.localizedDescription))
            }
        }
        return TrashEmptyResult(removedIDs: removed, failures: failures)
    }

    private func validateRoot(_ root: DiskNode, allowed: Set<String>) throws {
        let url = root.url.standardizedFileURL
        guard url.isFileURL, allowed.contains(url.path), url.path != "/", root.identity != nil,
              url.resolvingSymlinksInPath() == url else { throw TrashError.outsideRoot }
        var metadata = stat()
        let status = url.withUnsafeFileSystemRepresentation { Darwin.lstat($0!, &metadata) }
        guard status == 0, metadata.st_mode & S_IFMT == S_IFDIR else { throw TrashError.unavailable }
        guard FileIdentity(device: metadata.st_dev, inode: metadata.st_ino) == root.identity else { throw TrashError.changed }
    }
}

extension ScanSnapshot {
    public static func trashSnapshot(parts: [(TrashLocation, ScanSnapshot)], failures: [ScanIssue] = []) -> ScanSnapshot {
        let rootURL = URL(fileURLWithPath: "/__MacSpace__/Корзина", isDirectory: true)
        var root = DiskNode(url: rootURL, parentID: nil, kind: .directory, displayName: "Корзина")
        var nodes: [String: DiskNode] = [:]
        var issues = failures
        var issueCount = failures.count
        for (location, snapshot) in parts {
            nodes.merge(snapshot.nodes) { first, _ in first }
            let old = snapshot.root
            nodes[old.id] = DiskNode(
                url: old.url, parentID: root.id, kind: .directory, identity: old.identity,
                childIDs: old.childIDs, logicalBytes: old.logicalBytes, allocatedBytes: old.allocatedBytes,
                descendantCount: old.descendantCount, scanError: old.scanError,
                scanIssueCount: old.scanIssueCount, displayName: location.name
            )
            root.childIDs.append(old.id)
            root.logicalBytes = addingBytes(root.logicalBytes, old.logicalBytes)
            root.allocatedBytes = addingBytes(root.allocatedBytes, old.allocatedBytes)
            root.descendantCount += old.descendantCount + 1
            issues.append(contentsOf: snapshot.issues.prefix(max(0, 200 - issues.count)))
            issueCount += snapshot.issueCount
        }
        root.scanIssueCount = issueCount
        nodes[root.id] = root
        return ScanSnapshot(rootID: root.id, nodes: nodes, issues: Array(issues.prefix(200)), issueCount: issueCount,
                            duration: parts.reduce(0) { $0 + $1.1.duration })
    }
}
