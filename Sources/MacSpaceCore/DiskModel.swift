import Foundation

public enum NodeKind: String, Sendable {
    case directory, regularFile, symbolicLink, other
}

public enum SizeMetric: String, CaseIterable, Identifiable, Sendable {
    case allocated, logical
    public var id: Self { self }
    public var title: String { self == .allocated ? "На диске" : "Размер файлов" }
}

public struct FileIdentity: Hashable, Sendable {
    public let device: Int32
    public let inode: UInt64
    public init(device: Int32, inode: UInt64) { self.device = device; self.inode = inode }
}

public struct DiskNode: Identifiable, Sendable {
    public var id: String { url.path }
    public let url: URL
    public let parentID: String?
    public let kind: NodeKind
    public let identity: FileIdentity?
    public let displayName: String?
    public var childIDs: [String]
    public var logicalBytes: Int64
    public var allocatedBytes: Int64
    public var descendantCount: Int
    public var sharesStorage: Bool
    public var accountedAtID: String?
    public var scanError: String?
    public var scanIssueCount: Int

    public var name: String { displayName ?? (url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent) }
    public var isDirectory: Bool { kind == .directory }

    public init(
        url: URL, parentID: String?, kind: NodeKind, identity: FileIdentity? = nil, childIDs: [String] = [],
        logicalBytes: Int64 = 0, allocatedBytes: Int64 = 0,
        descendantCount: Int = 0, sharesStorage: Bool = false, accountedAtID: String? = nil,
        scanError: String? = nil, scanIssueCount: Int = 0, displayName: String? = nil
    ) {
        self.url = url
        self.parentID = parentID
        self.kind = kind
        self.identity = identity
        self.displayName = displayName
        self.childIDs = childIDs
        self.logicalBytes = logicalBytes
        self.allocatedBytes = allocatedBytes
        self.descendantCount = descendantCount
        self.sharesStorage = sharesStorage
        self.accountedAtID = accountedAtID
        self.scanError = scanError
        self.scanIssueCount = scanIssueCount
    }

    public func bytes(for metric: SizeMetric) -> Int64 {
        metric == .allocated ? allocatedBytes : logicalBytes
    }
}

public struct ScanIssue: Identifiable, Sendable {
    public var id: String { path }
    public let path: String
    public let message: String
    public init(path: String, message: String) { self.path = path; self.message = message }
}

public struct ScanProgress: Sendable {
    public let visitedCount: Int
    public let allocatedBytes: Int64
    public let currentPath: String
}

public struct ScanSnapshot: Sendable {
    public let rootID: String
    public let nodes: [String: DiskNode]
    public let issues: [ScanIssue]
    public let issueCount: Int
    public let scannedAt: Date
    public let duration: TimeInterval
    public let volumeTotalBytes: Int64?
    public let volumeAvailableBytes: Int64?

    public var root: DiskNode { nodes[rootID]! }

    public init(
        rootID: String, nodes: [String: DiskNode], issues: [ScanIssue] = [],
        issueCount: Int = 0, scannedAt: Date = .now, duration: TimeInterval = 0,
        volumeTotalBytes: Int64? = nil, volumeAvailableBytes: Int64? = nil
    ) {
        precondition(nodes[rootID] != nil)
        self.rootID = rootID
        self.nodes = nodes
        self.issues = issues
        self.issueCount = issueCount
        self.scannedAt = scannedAt
        self.duration = duration
        self.volumeTotalBytes = volumeTotalBytes
        self.volumeAvailableBytes = volumeAvailableBytes
    }

    public func children(of id: String, metric: SizeMetric, ascending: Bool = false) -> [DiskNode] {
        guard let parent = nodes[id] else { return [] }
        return parent.childIDs.compactMap { nodes[$0] }.sorted {
            let lhs = $0.bytes(for: metric), rhs = $1.bytes(for: metric)
            if lhs != rhs { return ascending ? lhs < rhs : lhs > rhs }
            return $0.url.path < $1.url.path
        }
    }

    public func ancestors(of id: String) -> [DiskNode] {
        var result: [DiskNode] = []
        var current = nodes[id]
        while let node = current {
            result.append(node)
            current = node.parentID.flatMap { nodes[$0] }
        }
        return result.reversed()
    }

    /// A selected parent already includes its selected descendants.
    public func topLevelSelection(_ ids: Set<String>) -> [DiskNode] {
        ids.compactMap { nodes[$0] }.filter { node in
            var parent = node.parentID
            while let id = parent {
                if ids.contains(id) { return false }
                parent = nodes[id]?.parentID
            }
            return true
        }.sorted { $0.id < $1.id }
    }
}

func addingBytes(_ left: Int64, _ right: Int64) -> Int64 {
    let (sum, overflow) = left.addingReportingOverflow(right)
    return overflow ? Int64.max : sum
}
