import Testing
@testable import MacSpaceCore

@Suite("Пропорциональная карта")
struct TreemapLayoutTests {
    @Test("Площадь пропорциональна размеру, прямоугольники не пересекаются", arguments: [
        MapRect(width: 900, height: 420), MapRect(width: 180, height: 700),
        MapRect(x: 13, y: 27, width: 500, height: 500)
    ])
    func areaAndIntersections(bounds: MapRect) {
        let values = [80.0, 50, 30, 20, 10, 6, 4, 1]
        let total = values.reduce(0, +)
        let items = values.enumerated().map { MapItem(id: "\($0.offset)", value: $0.element) }
        let tiles = TreemapLayout.tiles(items: items, in: bounds)
        #expect(tiles.count == values.count)
        #expect(abs(tiles.reduce(0.0) { $0 + $1.rect.area } - bounds.area) < 0.001)
        for tile in tiles {
            let expected = values[Int(tile.id)!] / total * bounds.area
            #expect(abs(tile.rect.area - expected) < 0.001)
            #expect(tile.rect.x >= bounds.x - 0.001 && tile.rect.y >= bounds.y - 0.001)
            #expect(tile.rect.x + tile.rect.width <= bounds.x + bounds.width + 0.001)
            #expect(tile.rect.y + tile.rect.height <= bounds.y + bounds.height + 0.001)
        }
        for i in tiles.indices {
            for j in tiles.indices where j > i {
                let a = tiles[i].rect, b = tiles[j].rect
                let overlapWidth = min(a.x + a.width, b.x + b.width) - max(a.x, b.x)
                let overlapHeight = min(a.y + a.height, b.y + b.height) - max(a.y, b.y)
                #expect(overlapWidth <= 0.001 || overlapHeight <= 0.001)
            }
        }
    }

    @Test("Пустые, нулевые и некорректные значения не дают геометрию")
    func emptyAndInvalid() {
        let bounds = MapRect(width: 300, height: 200)
        #expect(TreemapLayout.tiles(items: [], in: bounds).isEmpty)
        let invalid = [0.0, -1, .infinity, .nan].enumerated().map { MapItem(id: "\($0.offset)", value: $0.element) }
        #expect(TreemapLayout.tiles(items: invalid, in: bounds).isEmpty)
        #expect(TreemapLayout.tiles(items: [MapItem(id: "1", value: 1)], in: MapRect(width: 0, height: 100)).isEmpty)
        #expect(TreemapLayout.tiles(items: [MapItem(id: "1", value: 1)], in: MapRect(x: .nan, width: 100, height: 100)).isEmpty)
    }

    @Test("Большие значения не переполняют расчёт")
    func largeValues() {
        let tiles = TreemapLayout.tiles(items: [MapItem(id: "a", value: 1e308), MapItem(id: "b", value: 1e308)],
                                        in: MapRect(width: 600, height: 400))
        #expect(tiles.count == 2)
        #expect(tiles.allSatisfy { $0.rect.area.isFinite && abs($0.rect.area - 120_000) < 0.001 })
    }
}
