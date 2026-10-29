import Foundation

public struct MapRect: Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double
    public var area: Double { width * height }

    public init(x: Double = 0, y: Double = 0, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

public struct MapItem: Sendable {
    public let id: String
    public let value: Double
    public init(id: String, value: Double) { self.id = id; self.value = value }
}

public struct MapTile: Identifiable, Sendable {
    public let id: String
    public let rect: MapRect
}

/// Squarified treemap: area is proportional to size, with compact, readable rectangles.
public enum TreemapLayout {
    public static func tiles(items: [MapItem], in bounds: MapRect) -> [MapTile] {
        guard bounds.x.isFinite, bounds.y.isFinite, bounds.width > 0, bounds.height > 0,
              bounds.area.isFinite, bounds.area > 0 else { return [] }
        let items = items.filter { $0.value > 0 && $0.value.isFinite }.sorted {
            $0.value == $1.value ? $0.id < $1.id : $0.value > $1.value
        }
        guard let largest = items.first?.value else { return [] }
        // Normalize first, so even extremely large values cannot overflow the total.
        let total = items.reduce(0.0) { $0 + $1.value / largest }
        let areas = items.map { ($0.id, ($0.value / largest) / total * bounds.area) }
        var remaining = bounds
        var row: [(String, Double)] = []
        var result: [MapTile] = []

        func worst(_ row: [(String, Double)], side: Double) -> Double {
            guard side > 0, let smallest = row.last?.1, smallest > 0 else { return .infinity }
            let sum = row.reduce(0) { $0 + $1.1 }
            let largest = row[0].1
            return max(side * side * largest / (sum * sum), sum * sum / (side * side * smallest))
        }

        func place(_ row: [(String, Double)]) {
            let sum = row.reduce(0) { $0 + $1.1 }
            guard sum > 0, remaining.width > 0, remaining.height > 0 else { return }
            let vertical = remaining.width >= remaining.height
            let side = vertical ? remaining.height : remaining.width
            let thickness = min(sum / side, vertical ? remaining.width : remaining.height)
            var offset = vertical ? remaining.y : remaining.x
            for (index, entry) in row.enumerated() {
                let end = vertical ? remaining.y + remaining.height : remaining.x + remaining.width
                let length = index == row.count - 1 ? max(0, end - offset) : min(entry.1 / thickness, max(0, end - offset))
                let rect = vertical
                    ? MapRect(x: remaining.x, y: offset, width: thickness, height: length)
                    : MapRect(x: offset, y: remaining.y, width: length, height: thickness)
                result.append(MapTile(id: entry.0, rect: rect))
                offset += length
            }
            remaining = vertical
                ? MapRect(x: remaining.x + thickness, y: remaining.y, width: max(0, remaining.width - thickness), height: remaining.height)
                : MapRect(x: remaining.x, y: remaining.y + thickness, width: remaining.width, height: max(0, remaining.height - thickness))
        }

        for entry in areas where entry.1 > 0 {
            let side = min(remaining.width, remaining.height)
            if row.isEmpty || worst(row + [entry], side: side) <= worst(row, side: side) {
                row.append(entry)
            } else {
                place(row)
                row = [entry]
            }
        }
        if !row.isEmpty { place(row) }
        return result
    }
}
