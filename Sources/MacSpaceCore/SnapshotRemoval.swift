import Foundation

extension ScanSnapshot {
    /// Updates cached results only. No filesystem reads and no new scan are performed.
    public func removingSubtree(id: String) -> ScanSnapshot {
        removingSubtrees(ids: [id])
    }

    public func removingSubtrees(ids: Set<String>) -> ScanSnapshot {
        let roots = topLevelSelection(ids.subtracting([rootID]))
        guard !roots.isEmpty else { return self }
        var removedIDs: Set<String> = []
        var stack = roots.map(\.id)
        var removedOwners: [FileIdentity: DiskNode] = [:]
        while let next = stack.popLast() {
            guard removedIDs.insert(next).inserted, let node = nodes[next] else { continue }
            stack.append(contentsOf: node.childIDs)
            if node.kind == .regularFile, node.accountedAtID == nil, let identity = node.identity {
                removedOwners[identity] = node
            }
        }

        var updated = nodes
        for removedID in removedIDs { updated.removeValue(forKey: removedID) }
        for removed in roots {
            if let parentID = removed.parentID { updated[parentID]?.childIDs.removeAll { $0 == removed.id } }
        }

        func adjustAncestors(
            from startID: String?, logical: Int64 = 0, allocated: Int64 = 0,
            descendants: Int = 0, issueDelta: Int = 0
        ) {
            var currentID = startID
            while let current = currentID, var node = updated[current] {
                node.logicalBytes = max(0, addingBytes(node.logicalBytes, logical))
                node.allocatedBytes = max(0, addingBytes(node.allocatedBytes, allocated))
                node.descendantCount = max(0, node.descendantCount + descendants)
                node.scanIssueCount = max(0, node.scanIssueCount + issueDelta)
                updated[current] = node
                currentID = node.parentID
            }
        }

        for removed in roots {
            adjustAncestors(from: removed.parentID, logical: -removed.logicalBytes, allocated: -removed.allocatedBytes,
                            descendants: -(removed.descendantCount + 1), issueDelta: -removed.scanIssueCount)
        }

        var survivingLinks: [FileIdentity: [String]] = [:]
        var orphanedDirectories: [String] = []
        for node in updated.values {
            if node.kind == .regularFile, let identity = node.identity, removedOwners[identity] != nil {
                survivingLinks[identity, default: []].append(node.id)
            } else if node.isDirectory, let owner = node.accountedAtID, removedIDs.contains(owner) {
                orphanedDirectories.append(node.id)
            }
        }
        for (identity, ids) in survivingLinks {
            guard let original = removedOwners[identity], let ownerID = ids.min() else { continue }
            // Moving one name to Trash doesn't reclaim blocks still referenced by other names.
            updated[ownerID]?.allocatedBytes = original.allocatedBytes
            updated[ownerID]?.sharesStorage = false
            updated[ownerID]?.accountedAtID = nil
            adjustAncestors(from: updated[ownerID]?.parentID, allocated: original.allocatedBytes)
            for aliasID in ids where aliasID != ownerID {
                updated[aliasID]?.accountedAtID = ownerID
            }
        }

        let removedParts = roots.map { $0.url.pathComponents }
        let remainingIssues = issues.filter {
            let parts = URL(fileURLWithPath: $0.path).pathComponents
            return !removedParts.contains { parts.starts(with: $0) }
        }
        var updatedIssues = remainingIssues
        var updatedIssueCount = max(0, issueCount - roots.reduce(0) { $0 + $1.scanIssueCount })
        // Some descriptions may have fallen outside the initial 200-entry report.
        // Refill it from known directory errors, using cached nodes only.
        let reportLimit = min(200, updatedIssueCount)
        if updatedIssues.count < reportLimit {
            let listedIDs = Set(updatedIssues.map(\.path))
            for node in updated.values {
                if updatedIssues.count >= reportLimit { break }
                if let message = node.scanError, !listedIDs.contains(node.id) {
                    updatedIssues.append(ScanIssue(path: node.id, message: message))
                }
            }
            updatedIssues.sort { $0.path < $1.path }
        }
        for aliasID in orphanedDirectories.sorted() {
            // A repeated directory had no cached children. Avoid a dangling navigation target.
            let message = "Первоначальный путь перемещён в Корзину. Содержимое этого пути можно уточнить командой «Обновить анализ»."
            updated[aliasID]?.accountedAtID = nil
            updated[aliasID]?.scanError = message
            updated[aliasID]?.scanIssueCount += 1
            adjustAncestors(from: updated[aliasID]?.parentID, issueDelta: 1)
            updatedIssueCount += 1
            if updatedIssues.count < 200 { updatedIssues.append(ScanIssue(path: aliasID, message: message)) }
        }

        return ScanSnapshot(
            rootID: rootID, nodes: updated, issues: updatedIssues, issueCount: updatedIssueCount,
            scannedAt: scannedAt, duration: duration,
            volumeTotalBytes: volumeTotalBytes, volumeAvailableBytes: volumeAvailableBytes
        )
    }
}
