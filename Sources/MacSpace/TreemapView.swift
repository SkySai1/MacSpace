import AppKit
import MacSpaceCore
import SwiftUI

struct TreemapView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            GeometryReader { proxy in
                ZStack(alignment: .topLeading) {
                    if model.isPreparingMap {
                        ProgressView("Подготовка карты…").frame(width: proxy.size.width, height: proxy.size.height)
                    } else if model.visibleMapTiles.isEmpty {
                        ContentUnavailableView("Нет объектов с ненулевым размером", systemImage: "square.split.2x2",
                                               description: Text("Пустые объекты доступны в «Содержимом»."))
                            .frame(width: proxy.size.width, height: proxy.size.height)
                    }
                    ForEach(model.visibleMapTiles) { tile in
                        tileView(tile)
                            .frame(width: tile.rect.width, height: tile.rect.height)
                            .offset(x: tile.rect.x, y: tile.rect.y)
                    }
                }
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
                .clipped()
                .task(id: model.mapRequest(size: proxy.size)) { await model.prepareMap(size: proxy.size) }
            }
            Text("Клик по папке раскрывает её · Шапка сворачивает · ⌘-клик — мультивыбор")
                .font(.caption2).foregroundStyle(.secondary).lineLimit(2)
        }
        .padding(.horizontal, 18).padding(.top, 4).padding(.bottom, 16)
    }

    private func tileView(_ tile: CachedMapTile) -> some View {
        let color = Color.spacePalette[tile.colorIndex % Color.spacePalette.count]
        let selected = model.selectedIDs.contains(tile.nodeID) && !tile.isGroup
        let expanded = model.mapExpandedFolderIDs.contains(tile.id) && tile.hasChildren
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 6)
                .fill(color.opacity(expanded ? 0.10 : 0.22 + Double(min(tile.depth, 3)) * 0.05))
                .contentShape(Rectangle())
                .onTapGesture { model.activateMapTile(tile, header: false, modifiers: NSEvent.modifierFlags) }
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(selected ? Color.spaceAccent : color.opacity(0.5), lineWidth: selected ? 3 : 1)
                .allowsHitTesting(false)
            if tile.rect.width > 20 && tile.rect.height > 26 {
                Button {
                    model.activateMapTile(tile, header: true, modifiers: NSEvent.modifierFlags)
                } label: {
                    HStack(spacing: 5) {
                        if tile.rect.width > 125 {
                            if tile.isDirectory { Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.system(size: 8)) }
                            Text(tile.title).lineLimit(1).truncationMode(.middle)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        Text(tile.sizeText).monospacedDigit().lineLimit(1).fixedSize(horizontal: true, vertical: false)
                            .layoutPriority(1)
                    }
                    .font(.system(size: 10, weight: .semibold))
                    .padding(.horizontal, 7)
                    .frame(maxWidth: .infinity, minHeight: 28, maxHeight: 28, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .clipped()
                .accessibilityLabel("\(tile.title), \(tile.sizeText), \(expanded ? "свернуть" : "раскрыть")")
            }
        }
        .contextMenu {
            if tile.isGroup {
                Button("Открыть содержимое папки") { model.navigate(to: tile.nodeID); model.mode = .table }
            } else if let node = model.snapshot?.nodes[tile.nodeID] { NodeContextMenu(node: node, model: model) }
        }
        .help("\(tile.title) · \(tile.sizeText)\n\(tile.nodeID)")
        .accessibilityElement(children: .contain)
    }
}
