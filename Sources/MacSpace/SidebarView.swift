import MacSpaceCore
import SwiftUI

struct SidebarView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        List {
            Section {
                HStack(spacing: 10) {
                    Image(systemName: "chart.pie.fill").font(.title2).foregroundStyle(Color.spaceAccent)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("MacSpace").font(.headline)
                        Text("Пространство под контролем").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 10)
            }
            Section("Разделы") {
                Button { model.selectTab(.analysis) } label: {
                    Label("Анализ папок", systemImage: "internaldrive")
                        .foregroundStyle(model.activeTab == .analysis ? Color.spaceAccent : .primary)
                }
                Button { model.selectTab(.trash) } label: {
                    Label("Корзина", systemImage: "trash")
                        .foregroundStyle(model.isTrashTab ? Color.spaceAccent : .primary)
                }
                Button { model.selectTab(.timeMachine) } label: {
                    Label("Time Machine", systemImage: "clock.arrow.circlepath")
                        .foregroundStyle(model.isTimeMachineTab ? Color.spaceAccent : .primary)
                }
            }
            .disabled(model.isMutating)
            if !model.isTimeMachineTab {
              Section("Область анализа") {
                if let snapshot = model.snapshot {
                    navigationButton(snapshot.root, symbol: "internaldrive")
                    if let folder = model.currentFolder, folder.id != snapshot.rootID {
                        navigationButton(folder, symbol: "folder")
                    }
                } else {
                    Label("Папка не выбрана", systemImage: "folder")
                        .foregroundStyle(.secondary)
                }
                Button(action: model.chooseFolder) { Label("Выбрать папку…", systemImage: "plus.circle") }
                    .disabled(model.isMutating)
              }
            }
            if model.currentFolder != nil {
                let directories = model.sidebarRows
                if !directories.isEmpty {
                    Section("Крупные папки · \(directories.count)") {
                        ForEach(Array(directories.prefix(12))) { row in
                            let node = row.node
                            Button { model.navigate(to: node.id) } label: {
                                HStack(spacing: 7) {
                                    Image(systemName: "folder.fill").foregroundStyle(Color.spaceAccent)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(node.name).lineLimit(1)
                                        Text(row.sizeText).font(.caption2).foregroundStyle(.secondary)
                                    }
                                    Spacer(minLength: 0)
                                }
                                .padding(.vertical, 2)
                            }
                            .buttonStyle(.plain)
                            .help(node.url.path)
                        }
                    }
                }
            }
            Section {
                VStack(alignment: .leading, spacing: 7) {
                    Label("Как читать размеры", systemImage: "info.circle")
                        .font(.caption.weight(.medium))
                    Text("«На диске» показывает выделенные блоки. Объём, который освободится после удаления, может отличаться из-за APFS и снимков.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                .padding(.vertical, 8)
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            Text("Локальный анализ · macOS")
                .font(.caption2).foregroundStyle(.tertiary)
                .padding(12)
        }
    }

    private func navigationButton(_ node: DiskNode, symbol: String) -> some View {
        Button { model.navigate(to: node.id) } label: {
            Label(node.name, systemImage: symbol)
                .foregroundStyle(model.currentFolderID == node.id ? Color.spaceAccent : .primary)
                .fontWeight(model.currentFolderID == node.id ? .semibold : .regular)
                .lineLimit(1)
        }
        .buttonStyle(.plain)
        .help(node.url.path)
    }
}

struct WelcomeView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 22) {
            ZStack {
                RoundedRectangle(cornerRadius: 30).fill(Color.spaceAccent.opacity(0.08))
                    .frame(width: 170, height: 145)
                HStack(alignment: .bottom, spacing: 9) {
                    ForEach(Array([55.0, 93, 72, 115].enumerated()), id: \.offset) { index, height in
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.spacePalette[index].gradient)
                            .frame(width: 23, height: height)
                    }
                }
            }
            VStack(spacing: 10) {
                Text("Найдите, что занимает место").font(.system(size: 29, weight: .bold))
                Text("Выберите папку или диск. MacSpace покажет размеры,\nструктуру папок и поможет освободить пространство.")
                    .foregroundStyle(.secondary).multilineTextAlignment(.center).lineSpacing(4)
            }
            Button(action: model.chooseFolder) {
                Label("Выбрать папку для анализа", systemImage: "folder.badge.plus")
                    .padding(.horizontal, 12).padding(.vertical, 5)
            }
            .buttonStyle(.borderedProminent).controlSize(.large)
            .disabled(model.isBusy)
            HStack(spacing: 20) {
                Label("Шкалы размеров", systemImage: "chart.bar.xaxis")
                Label("Вложенная карта", systemImage: "square.split.2x2")
                Label("Корзина macOS", systemImage: "trash")
            }
            .font(.caption).foregroundStyle(.secondary)
            Text("Анализ выполняется на вашем Mac. Скрытые файлы включены.")
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
