import MacSpaceCore
import SwiftUI

struct InspectorView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ScrollView {
            if model.selectedIDs.count > 1 {
                VStack(alignment: .leading, spacing: 20) {
                    Image(systemName: "square.stack.3d.up").font(.largeTitle).foregroundStyle(Color.spaceAccent)
                    Text("Выбрано объектов: \(model.selectedIDs.count)").font(.title3.bold())
                    detail("На диске", value: byteText(model.selectionSummary.allocatedBytes))
                    detail("Размер файлов", value: byteText(model.selectionSummary.logicalBytes))
                    Text("Выбранная папка включает её потомков; размеры не суммируются повторно.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Показать в Finder", action: model.revealSelection)
                    Button("В Корзину…", role: .destructive) { model.requestTrash() }
                        .disabled(!model.canTrashSelection)
                    Text("⌘-клик добавляет и убирает объект. Shift выбирает диапазон.")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(20)
            } else if let node = model.inspectedNode {
                VStack(alignment: .leading, spacing: 20) {
                    Text("СВЕДЕНИЯ").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 12) {
                        Image(systemName: node.symbol)
                            .font(.system(size: 40, weight: .light)).foregroundStyle(Color.spaceAccent)
                        Text(node.name).font(.title3.weight(.semibold)).textSelection(.enabled)
                        Text(node.typeTitle).font(.caption).foregroundStyle(.secondary)
                    }
                    Divider()
                    VStack(alignment: .leading, spacing: 14) {
                        detail("На диске", value: byteText(node.allocatedBytes))
                        detail("Размер файлов", value: byteText(node.logicalBytes))
                        if node.isDirectory {
                            detail("Объектов внутри", value: node.descendantCount.formatted())
                        }
                        if let folder = model.currentFolder {
                            let share = fraction(node.bytes(for: model.metric), of: folder.bytes(for: model.metric))
                            VStack(alignment: .leading, spacing: 7) {
                                HStack {
                                    Text("Доля текущей папки").foregroundStyle(.secondary)
                                    Spacer()
                                    Text(share, format: .percent.precision(.fractionLength(1)))
                                }
                                .font(.caption)
                                ProgressView(value: share).tint(.spaceAccent)
                            }
                        }
                    }
                    Divider()
                    VStack(alignment: .leading, spacing: 7) {
                        Text("Путь").font(.caption).foregroundStyle(.secondary)
                        Text(node.url.path).font(.caption).textSelection(.enabled)
                            .lineLimit(8).truncationMode(.middle)
                    }
                    if let error = node.scanError {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    if node.sharesStorage {
                        Text("Жёсткая ссылка: выделенное место уже учтено у другого имени файла в этом анализе.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let original = node.accountedAtID {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Данные уже учтены по пути:").foregroundStyle(.secondary)
                            Text(original).textSelection(.enabled)
                            if node.isDirectory {
                                Text("При открытии будет показан этот путь. Повторный обход исключён.").foregroundStyle(.secondary)
                            }
                        }
                        .font(.caption)
                    }
                    if node.kind == .symbolicLink {
                        Text("Содержимое ссылки не анализировалось. Размер относится к самой ссылке.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    VStack(spacing: 9) {
                        if node.isDirectory && node.id != model.currentFolderID {
                            Button { model.navigate(to: node.id) } label: {
                                Label("Открыть папку", systemImage: "arrow.right.circle")
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        Button { model.reveal(node) } label: {
                            Label("Показать в Finder", systemImage: "magnifyingglass")
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        Button(role: .destructive) { model.requestTrash(node) } label: {
                            Label("В Корзину…", systemImage: "trash")
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .disabled(!model.canTrash(node))
                        .help("Переместить файл или папку в Корзину (⌘⌫)")
                    }
                    .buttonStyle(.bordered).controlSize(.large)
                    Text(model.mode == .map ? "Клик раскрывает папку, клик по её шапке сворачивает содержимое." : "Двойной щелчок по папке открывает её содержимое.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                .padding(20)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.4))
    }

    private func detail(_ title: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value).fontWeight(.medium).monospacedDigit()
        }
        .font(.caption)
    }
}

struct IssuesView: View {
    let snapshot: ScanSnapshot
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Не все объекты удалось прочитать").font(.title2.bold())
            Text("Ошибок: \(snapshot.issueCount). Размеры включают только прочитанные объекты. Проверьте права доступа и повторите анализ. Полный доступ к диску настраивается в macOS → Конфиденциальность и безопасность.")
                .font(.callout).foregroundStyle(.secondary)
            List(snapshot.issues) { issue in
                VStack(alignment: .leading, spacing: 5) {
                    Text(issue.path).font(.callout).textSelection(.enabled)
                    Text(issue.message).font(.caption).foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }
            if snapshot.issueCount > snapshot.issues.count {
                Text("Показаны первые \(snapshot.issues.count) ошибок.").font(.caption).foregroundStyle(.secondary)
            }
            HStack { Spacer(); Button("Готово") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(24).frame(width: 650, height: 440)
    }
}

struct NodeContextMenu: View {
    let node: DiskNode
    @ObservedObject var model: AppModel

    var body: some View {
        if node.isDirectory {
            Button("Открыть папку") { model.navigate(to: node.id) }
        }
        Button("Показать в Finder") { model.reveal(node) }
        Divider()
        Button("Переместить в Корзину…", role: .destructive) { model.requestTrash(node) }
            .disabled(!model.canTrashRequest(node))
    }
}
