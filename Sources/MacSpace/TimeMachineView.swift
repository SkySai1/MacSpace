import AppKit
import MacSpaceCore
import SwiftUI

struct TimeMachineView: View {
    @ObservedObject var model: TimeMachineModel

    var body: some View {
        GeometryReader { viewport in
            content.frame(width: viewport.size.width, height: viewport.size.height)
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                Label("Time Machine", systemImage: "clock.arrow.circlepath")
                    .font(.system(size: 28, weight: .bold))
                Text("Локальные снимки на подключённых дисках")
                    .foregroundStyle(.secondary)
                Text("Одна строка объединяет снимки одной даты на всех дисках. Удаление действует на всю строку. Размер отдельных снимков недоступен; освобождённое место зависит от общих блоков APFS.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Text("Дат: \(model.snapshots.count) · Выбрано: \(model.selectedIDs.count)")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    Spacer()
                    Button("Выбрать все") { model.selectedIDs = Set(model.snapshots.map(\.id)) }
                        .disabled(model.isBusy || model.snapshots.isEmpty)
                    Button("Удалить выбранные…", role: .destructive) { model.requestDeletion() }
                        .disabled(!model.canDeleteSelection)
                    Button("Очистить все…", role: .destructive) { model.requestDeletion(all: true) }
                        .disabled(!model.canDeleteAll)
                }
            }
            .padding(22)
            Divider()
            if let error = model.errorMessage {
                VStack(alignment: .leading, spacing: 10) {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .lineLimit(6).textSelection(.enabled).help(error)
                    HStack {
                        Button("Повторить", action: model.refresh).disabled(model.isBusy)
                        Button("Настройки доступа…") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                    }
                }
                .font(.callout).padding(16).frame(maxWidth: .infinity, alignment: .leading)
                .background(.orange.opacity(0.08))
            }
            if model.isBusy {
                HStack(spacing: 12) {
                    ProgressView().controlSize(.small)
                    Text(model.statusMessage).font(.callout)
                    Spacer()
                }.padding(16)
            }
            if model.snapshots.isEmpty {
                ContentUnavailableView(
                    model.isLoading ? "Читаем снимки…" : (model.errorMessage == nil ? "Локальных снимков нет" : "Снимки недоступны"),
                    systemImage: "clock.arrow.circlepath",
                    description: Text("Здесь отображаются локальные снимки Time Machine, которые доступны на этом Mac.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Table(model.snapshots, selection: $model.selectedIDs) {
                    TableColumn("Дата и время") { snapshot in
                        Text(snapshot.createdAt, format: .dateTime.day().month(.wide).year().hour().minute().second())
                            .monospacedDigit()
                    }
                    .width(min: 200, ideal: 250)
                    TableColumn("Дата снимков") { snapshot in
                        Text(snapshot.id).font(.callout.monospaced()).textSelection(.enabled)
                    }
                    .width(min: 145, ideal: 175)
                    TableColumn("Область удаления") { _ in Text("Все подключённые диски").foregroundStyle(.secondary) }
                }
                .frame(minHeight: 0, maxHeight: .infinity)
                .disabled(model.isBusy)
            }
            Text("⌘-клик — мультивыбор · Shift — диапазон. Резервные копии на диске назначения здесь не отображаются.")
                .font(.caption).foregroundStyle(.secondary).padding(16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .alert("Удалить локальные снимки: \(model.pendingDeletion.count)?", isPresented: $model.showDeleteConfirmation) {
            Button("Отмена", role: .cancel, action: model.cancelPrompt)
            Button("Удалить снимки", role: .destructive, action: model.confirmDeletion)
        } message: { Text(model.confirmationMessage) }
    }
}
