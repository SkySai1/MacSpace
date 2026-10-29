import AppKit
import MacSpaceCore
import SwiftUI

struct BarsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let visibleRows = model.barRows
        VStack(spacing: 0) {
            HStack {
                Text("СТРОК · \(visibleRows.count)")
                Spacer()
                Text("ДОЛЯ И РАЗМЕР В ТЕКУЩЕЙ ПАПКЕ")
            }
            .font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
            .padding(.horizontal, 28).padding(.top, 5).padding(.bottom, 10)
            ScrollView {
                LazyVStack(spacing: 5) {
                    ForEach(visibleRows) { item in
                        BarRow(
                            row: item.content, depth: item.depth,
                            color: Color.spacePalette[item.colorIndex % Color.spacePalette.count],
                            selected: model.selectedIDs.contains(item.id),
                            expanded: model.expandedFolderIDs.contains(item.id),
                            canExpand: model.canExpand(item.content.node),
                            select: { model.select(item.id, modifiers: NSEvent.modifierFlags) },
                            open: { model.navigate(to: item.id) },
                            toggle: { model.toggleExpansion(item.id) }
                        )
                        .contextMenu { NodeContextMenu(node: item.content.node, model: model) }
                    }
                }
                .padding(.horizontal, 18).padding(.bottom, 18)
            }
        }
    }
}

private struct BarRow: View {
    let row: ContentRow
    let depth: Int
    let color: Color
    let selected: Bool
    let expanded: Bool
    let canExpand: Bool
    let select: () -> Void
    let open: () -> Void
    let toggle: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            rowContent
                .contentShape(Rectangle())
                .onTapGesture(count: 2, perform: open)
                .onTapGesture(perform: select)
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { select() }
                .accessibilityAction(named: "Открыть папку") { open() }
            if row.node.isDirectory {
                Button(action: toggle) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .animation(.easeInOut(duration: 0.15), value: expanded)
                        .frame(width: 24, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(canExpand ? .secondary : .tertiary)
                .disabled(!canExpand)
                .help(canExpand ? (expanded ? "Свернуть папку" : "Развернуть папку") : "Нет доступных вложенных объектов")
                .accessibilityLabel("\(expanded ? "Свернуть" : "Развернуть") папку «\(row.name)»")
                .accessibilityValue(expanded ? "Развернута" : "Свернута")
            } else {
                Color.clear.frame(width: 24, height: 28).accessibilityHidden(true)
            }
        }
        .padding(10)
        .background(selected ? Color.spaceAccent.opacity(0.1) : Color(nsColor: .controlBackgroundColor).opacity(0.55), in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(selected ? Color.spaceAccent.opacity(0.5) : .clear, lineWidth: 1))
        .help("\(row.node.url.path)\n\(byteText(row.bytes)) · \(row.node.typeTitle)")
    }

    private var rowContent: some View {
        HStack(spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: row.node.symbol)
                    .font(.system(size: 17))
                    .foregroundStyle(row.node.isDirectory ? color : .secondary)
                    .frame(width: 25)
                VStack(alignment: .leading, spacing: 4) {
                    Text(row.name).font(.callout.weight(.medium)).lineLimit(1).truncationMode(.middle)
                    Text(row.node.isDirectory ? "\(row.node.childIDs.count) объектов" : row.type)
                        .font(.caption2).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.leading, CGFloat(min(depth, 6)) * 16)
            .frame(width: 210, alignment: .leading)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(color.opacity(0.09))
                    Capsule().fill(color.gradient)
                        .frame(width: row.bytes > 0 ? max(3, proxy.size.width * row.fraction) : 0)
                }
                .frame(height: 13).frame(maxHeight: .infinity)
            }
            .frame(minWidth: 50, maxWidth: .infinity).frame(height: 30)
            VStack(alignment: .trailing, spacing: 4) {
                Text(row.sizeText).font(.callout.weight(.semibold)).monospacedDigit()
                Text(row.fraction, format: .percent.precision(.fractionLength(1)))
                    .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
            }
            .frame(width: 95, alignment: .trailing)
        }
    }
}

struct FolderTableView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Table(model.rows, selection: $model.selectedIDs, sortOrder: $model.tableSort) {
            TableColumn("Имя", value: \.name) { row in
                HStack(spacing: 8) {
                    Image(systemName: row.node.symbol)
                        .foregroundStyle(row.node.isDirectory ? Color.spaceAccent : .secondary)
                    Text(row.name).lineLimit(1).truncationMode(.middle)
                    if row.node.scanError != nil { Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange) }
                }
                .help(row.node.url.path)
            }
            .width(min: 120, ideal: 240)
            TableColumn(model.metric.title, value: \.bytes) { row in
                Text(row.sizeText).monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 85, ideal: 100, max: 140)
            TableColumn("Доля", value: \.fraction) { row in
                HStack(spacing: 8) {
                    ProgressView(value: row.fraction).tint(.spaceAccent).frame(width: 45)
                    Text(row.fraction, format: .percent.precision(.fractionLength(1)))
                        .font(.caption).monospacedDigit()
                }
            }
            .width(min: 100, ideal: 110, max: 130)
            TableColumn("Тип", value: \.type) { row in
                Text(row.type).foregroundStyle(.secondary).lineLimit(1)
            }
            .width(min: 65, ideal: 80, max: 130)
        }
        .contextMenu(forSelectionType: String.self) { ids in
            if let id = ids.first, let node = model.snapshot?.nodes[id] {
                NodeContextMenu(node: node, model: model)
            }
        } primaryAction: { ids in
            if let id = ids.first { model.navigate(to: id) }
        }
    }
}
