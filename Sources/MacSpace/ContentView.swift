import MacSpaceCore
import SwiftUI

struct ContentView: View {
    @ObservedObject var model: AppModel
    @State private var showIssues = false

    var body: some View {
        NavigationSplitView {
            SidebarView(model: model)
                .navigationSplitViewColumnWidth(min: 190, ideal: 215, max: 270)
        } detail: {
            VStack(spacing: 0) {
                HStack {
                    Picker("Раздел", selection: Binding(get: { model.activeTab }, set: { model.selectTab($0) })) {
                        Text("Анализ папок").tag(WorkspaceTab.analysis)
                        Text("Корзина").tag(WorkspaceTab.trash)
                        Text("Time Machine").tag(WorkspaceTab.timeMachine)
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 380).disabled(model.isMutating)
                    Spacer()
                    if model.isTrashTab {
                        Button("Очистить корзину…", role: .destructive, action: model.requestEmptyTrash)
                            .disabled(!model.canEmptyTrash)
                    }
                }
                .padding(.horizontal, 22).padding(.vertical, 12)
                Divider()
                if model.isScanning { scanBanner }
                if model.isTimeMachineTab {
                    TimeMachineView(model: model.timeMachine)
                } else if model.snapshot != nil {
                    analysisContent
                } else {
                    WelcomeView(model: model)
                }
                Divider()
                statusBar
            }
            .background(Color(nsColor: .windowBackgroundColor))
            .alert("Не удалось выполнить операцию", isPresented: Binding(
                get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } }
            )) {
                Button("Понятно", role: .cancel) { model.errorMessage = nil }
            } message: {
                Text(model.errorMessage ?? "")
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button(action: model.goUp) { Label("На уровень выше", systemImage: "arrow.up") }
                    .disabled(model.currentFolder?.parentID == nil)
                    .help("На уровень выше (⌘↑)")
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button(action: model.chooseFolder) { Label("Выбрать папку", systemImage: "folder.badge.plus") }
                    .disabled(model.isMutating)
                    .help("Выбрать папку (⌘O)")
                Button(action: model.rescan) { Label("Обновить", systemImage: "arrow.clockwise") }
                    .disabled(!model.canRefresh)
                    .help("Обновить анализ (⌘R)")
                Button { model.showInspector.toggle() } label: {
                    Label("Сведения", systemImage: "sidebar.right")
                }
                .disabled(model.snapshot == nil)
                .help("Показать сведения о выбранном объекте")
            }
        }
        .inspector(isPresented: Binding(
            get: { model.showInspector && model.snapshot != nil }, set: { model.showInspector = $0 }
        )) {
            InspectorView(model: model)
                .inspectorColumnWidth(min: 230, ideal: 250, max: 300)
        }
        .alert(model.destructiveTitle, isPresented: Binding(
            get: { model.showTrashConfirmation || model.showEmptyConfirmation },
            set: { if !$0 { model.showTrashConfirmation = false; model.showEmptyConfirmation = false } }
        )) {
            Button("Отмена", role: .cancel, action: model.cancelDestructivePrompt)
            if model.showEmptyConfirmation {
                Button("Очистить корзину", role: .destructive, action: model.confirmEmptyTrash)
            } else {
                Button("В Корзину", role: .destructive, action: model.confirmPendingTrash)
            }
        } message: {
            Text(model.destructiveMessage)
        }
        .sheet(isPresented: $showIssues) {
            if let snapshot = model.snapshot { IssuesView(snapshot: snapshot) }
        }
    }

    private var analysisContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            FolderHeader(model: model)
            HStack(spacing: 12) {
                Picker("Представление", selection: $model.mode) {
                    ForEach(DisplayMode.allCases) { mode in
                        Label(mode.title, systemImage: mode.symbol).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 400)
                Spacer(minLength: 0)
                Picker("Размер", selection: $model.metric) {
                    ForEach(SizeMetric.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .frame(width: 145)
                .help("На диске: выделенные блоки; размер файлов: логическое содержимое")
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 16)
            Divider()
            contentControls
                HStack(spacing: 12) {
                    Text(model.selectedIDs.isEmpty ? "⌘-клик — мультивыбор · Shift — диапазон" : "Выбрано: \(model.selectedIDs.count) · \(byteText(model.selectionSummary.allocatedBytes))")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    Button("Снять выбор") { model.selectedID = nil }.disabled(model.selectedIDs.isEmpty)
                    if !model.isTrashTab {
                        Button("В Корзину…", role: .destructive) { model.requestTrash() }
                            .disabled(!model.canTrashSelection)
                    }
                }
                .frame(height: 30)
                .padding(.horizontal, 22).padding(.bottom, 10)
            if let snapshot = model.snapshot, snapshot.issueCount > 0 {
                Button { showIssues = true } label: {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                        Text("Результат неполный: ошибок доступа — \(snapshot.issueCount)")
                        Spacer()
                        Text("Подробнее").fontWeight(.medium)
                    }
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 8)
                    .background(.orange.opacity(0.07))
                }
                .buttonStyle(.plain)
            }
            Group {
                if model.rows.isEmpty {
                    let skipped = model.currentFolder?.scanError != nil
                    let emptyTitle = model.isTrashTab
                        ? ((model.snapshot?.issueCount ?? 0) > 0 ? "Корзина недоступна" : "Корзина пуста")
                        : "Папка пуста"
                    ContentUnavailableView(
                        skipped ? "Папка пропущена" : (model.search.isEmpty ? emptyTitle : "Ничего не найдено"),
                        systemImage: skipped ? "folder.badge.minus" : (model.search.isEmpty ? "folder" : "magnifyingglass"),
                        description: Text(model.currentFolder?.scanError ?? (model.search.isEmpty
                            ? "В этой папке нет доступных объектов." : "Поиск выполняется по именам в текущей папке."))
                    )
                } else {
                    switch model.mode {
                    case .bars: BarsView(model: model)
                    case .map: TreemapView(model: model)
                    case .table: FolderTableView(model: model)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var contentControls: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Имя в этой папке", text: $model.search)
                    .textFieldStyle(.plain)
                    .accessibilityLabel("Фильтр по имени в текущей папке")
                if !model.search.isEmpty {
                    Button { model.search = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                        .accessibilityLabel("Очистить фильтр")
                }
            }
            .padding(7)
            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 7))
            .frame(maxWidth: 230)
            Spacer(minLength: 4)
            if model.mode == .map {
                Text("Клик — раскрыть · Шапка — свернуть")
                    .font(.caption2).foregroundStyle(.secondary)
            } else {
                Menu {
                    Button("Сначала крупные") { model.tableSort = [KeyPathComparator(\ContentRow.bytes, order: .reverse)] }
                    Button("Сначала небольшие") { model.tableSort = [KeyPathComparator(\ContentRow.bytes)] }
                    Button("По имени") { model.tableSort = [KeyPathComparator(\ContentRow.name)] }
                } label: { Label("Сортировка", systemImage: "arrow.up.arrow.down") }
                .fixedSize()
            }
            Button { model.selectAllVisible() } label: { Image(systemName: "checklist") }
                .help("Выбрать все видимые объекты")
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 12)
    }

    private var scanBanner: some View {
        HStack(spacing: 12) {
            ProgressView().controlSize(.small)
            VStack(alignment: .leading, spacing: 3) {
                Text("Анализируем \(model.scanningRoot?.lastPathComponent ?? "папку")…")
                    .font(.callout.weight(.medium))
                Text(model.progress?.currentPath ?? "Читаем структуру папок")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            if let progress = model.progress {
                Text("\(progress.visitedCount.formatted()) объектов\n\(byteText(progress.allocatedBytes))")
                    .font(.caption.monospacedDigit()).multilineTextAlignment(.trailing)
            }
            Button("Остановить", action: model.cancelScan)
        }
        .padding(14)
        .background(Color.spaceAccent.opacity(0.08))
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            Image(systemName: model.isBusy ? "circle.dotted" : "checkmark.circle")
                .foregroundStyle(model.isBusy ? .secondary : Color.spaceAccent)
            Text(model.isTimeMachineTab ? model.timeMachine.statusMessage : (model.isEmptyingTrash ? "Очищаем Корзину…" : (model.isTrashing ? "Переносим выбранные объекты в Корзину…" : model.statusMessage)))
                .lineLimit(1)
            Spacer()
            if model.isTimeMachineTab, let date = model.timeMachine.loadedAt {
                Text(date, format: .dateTime.hour().minute()).help("Время чтения списка снимков")
            } else if let snapshot = model.snapshot {
                Text(snapshot.scannedAt, format: .dateTime.hour().minute())
                    .help("Время начала последнего завершённого анализа")
            }
        }
        .font(.caption).foregroundStyle(.secondary)
        .padding(.horizontal, 16).padding(.vertical, 9)
    }
}

struct FolderHeader: View {
    @ObservedObject var model: AppModel

    var body: some View {
        if let folder = model.currentFolder, let snapshot = model.snapshot {
            VStack(alignment: .leading, spacing: 16) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(Array(snapshot.ancestors(of: folder.id).enumerated()), id: \.element.id) { index, node in
                            if index > 0 { Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold)).foregroundStyle(.tertiary) }
                            Button(node.name) { model.navigate(to: node.id) }
                                .buttonStyle(.plain)
                                .foregroundStyle(node.id == folder.id ? .primary : .secondary)
                                .help(node.url.path)
                        }
                    }
                    .font(.caption)
                }
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(folder.name).font(.system(size: 28, weight: .bold)).lineLimit(1)
                        Text(model.isTrashTab && folder.id == snapshot.rootID ? "Доступные системные корзины текущего пользователя" : folder.url.path).font(.caption).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    }
                    Spacer()
                    Image(systemName: "internaldrive")
                        .font(.system(size: 32, weight: .light)).foregroundStyle(Color.spaceAccent)
                }
                HStack(spacing: 0) {
                    SummaryValue(title: model.metric.title, value: byteText(folder.bytes(for: model.metric)), accent: true)
                    Divider().frame(height: 36).padding(.horizontal, 18)
                    SummaryValue(title: "Объектов внутри", value: folder.descendantCount.formatted())
                    if let free = snapshot.volumeAvailableBytes {
                        Divider().frame(height: 36).padding(.horizontal, 18)
                        SummaryValue(title: "Свободно на томе", value: byteText(free))
                    }
                    Spacer(minLength: 0)
                }
            }
            .padding(22)
        }
    }
}

private struct SummaryValue: View {
    let title: String
    let value: String
    var accent = false
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(size: 22, weight: .semibold, design: .rounded))
                .foregroundStyle(accent ? Color.spaceAccent : .primary)
                .monospacedDigit().lineLimit(1).minimumScaleFactor(0.65)
        }
    }
}
