import Foundation
import MacSpaceCore

struct MapRequest: Hashable, Sendable {
    let version: UUID
    let folderID: String
    let metric: SizeMetric
    let query: String
    let width: Int
    let height: Int
}

struct CachedMapTile: Identifiable, Sendable {
    let id: String
    let nodeID: String
    let rect: MapRect
    let title: String
    let sizeText: String
    let bytes: Int64
    let colorIndex: Int
    let depth: Int
    let isDirectory: Bool
    let isGroup: Bool
    var hasChildren = false
    var subtreeEnd = 0
}

struct CachedMapScene: Sendable {
    let tiles: [CachedMapTile]

    func visible(expanded: Set<String>) -> [CachedMapTile] {
        var result: [CachedMapTile] = []
        var index = 0
        while index < tiles.count {
            let tile = tiles[index]
            result.append(tile)
            index = tile.hasChildren && !expanded.contains(tile.id) ? tile.subtreeEnd : index + 1
        }
        return result
    }

    static func build(snapshot: ScanSnapshot, rootIDs: [String], request: MapRequest) -> CachedMapScene {
        var tiles: [CachedMapTile] = []
        func level(ids: [String], parentID: String, bounds: MapRect, depth: Int, inheritedColor: Int?) {
            if Task.isCancelled { return }
            let children = ids.compactMap { snapshot.nodes[$0] }.filter { $0.bytes(for: request.metric) > 0 }.sorted {
                let lhs = $0.bytes(for: request.metric), rhs = $1.bytes(for: request.metric)
                return lhs == rhs ? $0.id < $1.id : lhs > rhs
            }
            let shown = Array(children.prefix(200))
            let rest = children.dropFirst(200)
            let groupID = "map-group:" + parentID
            var values = shown.map { MapItem(id: $0.id, value: Double($0.bytes(for: request.metric))) }
            if !rest.isEmpty {
                values.append(MapItem(id: groupID, value: rest.reduce(0.0) { $0 + Double($1.bytes(for: request.metric)) }))
            }
            let colors = Dictionary(uniqueKeysWithValues: shown.enumerated().map { ($0.element.id, $0.offset % 6) })
            for position in TreemapLayout.tiles(items: values, in: bounds) {
                let rect = MapRect(x: position.rect.x + 2, y: position.rect.y + 2,
                                   width: max(0, position.rect.width - 4), height: max(0, position.rect.height - 4))
                guard rect.width >= 3, rect.height >= 3 else { continue }
                let node = snapshot.nodes[position.id]
                let bytes = node?.bytes(for: request.metric) ?? rest.reduce(Int64(0)) {
                    let (sum, overflow) = $0.addingReportingOverflow($1.bytes(for: request.metric))
                    return overflow ? Int64.max : sum
                }
                let index = tiles.count
                tiles.append(CachedMapTile(
                    id: position.id, nodeID: node?.id ?? parentID, rect: rect,
                    title: node?.name ?? "Ещё \(rest.count) объектов",
                    sizeText: byteText(bytes), bytes: bytes,
                    colorIndex: inheritedColor ?? colors[position.id, default: 0], depth: depth,
                    isDirectory: node?.isDirectory == true, isGroup: node == nil
                ))
                // Precompute every level which can be displayed at this viewport, even while collapsed.
                if let node, node.isDirectory, !node.childIDs.isEmpty, rect.width > 24, rect.height > 52 {
                    level(ids: node.childIDs, parentID: node.id,
                          bounds: MapRect(x: rect.x + 4, y: rect.y + 32, width: rect.width - 8, height: rect.height - 36),
                          depth: depth + 1, inheritedColor: inheritedColor ?? colors[node.id, default: 0])
                    tiles[index].hasChildren = tiles.count > index + 1
                }
                tiles[index].subtreeEnd = tiles.count
            }
        }
        level(ids: rootIDs, parentID: request.folderID,
              bounds: MapRect(width: Double(request.width), height: Double(request.height)), depth: 0, inheritedColor: nil)
        return CachedMapScene(tiles: tiles)
    }
}
