import AppKit
import Combine
import MacSpaceCore
import SwiftUI

enum DisplayMode: String, CaseIterable, Identifiable {
    case bars, map, table
    var id: Self { self }
    var title: String { switch self { case .bars: "Шкалы"; case .map: "Карта папок"; case .table: "Содержимое" } }
    var symbol: String { switch self { case .bars: "chart.bar.xaxis"; case .map: "square.split.2x2"; case .table: "list.bullet" } }
}

enum WorkspaceTab: String, Hashable { case analysis, trash, timeMachine }

struct ContentRow: Identifiable, Sendable {
    let node: DiskNode
    let bytes: Int64
    let fraction: Double
    let sizeText: String
    var id: String { node.id }
    var name: String { node.name }
    var type: String { node.typeTitle }
    init(node: DiskNode, bytes: Int64, fraction: Double) {
        self.node = node; self.bytes = bytes; self.fraction = fraction
        sizeText = byteText(bytes)
    }
}

struct BarTreeRow: Identifiable {
    let content: ContentRow
    let depth: Int
    let colorIndex: Int
    var id: String { content.id }
}

struct SelectionSummary {
    var nodes: [DiskNode] = []
    var logicalBytes: Int64 = 0
    var allocatedBytes: Int64 = 0
}

private struct RowsKey: Hashable {
    let folderID: String
    let total: Int64
    let query: String
}

private struct WorkspaceState {
    let snapshot: ScanSnapshot?
    let version: UUID
    let folderID: String?
    let selectedIDs: Set<String>
    let expanded: Set<String>
    let mapExpanded: Set<String>
    let search: String
}

@MainActor
final class AppModel: ObservableObject {
    let timeMachine: TimeMachineModel
    private var timeMachineObservation: AnyCancellable?
    @Published private(set) var snapshot: ScanSnapshot?
    @Published private(set) var activeTab: WorkspaceTab = .analysis
    @Published private(set) var currentFolderID: String?
    @Published var selectedIDs: Set<String> = [] {
        didSet {
            if !selectedIDs.contains(focusedID ?? "") { focusedID = selectedIDs.sorted().first }
            updateSelectionSummary()
        }
    }
    @Published var mode: DisplayMode = .bars
    @Published var metric: SizeMetric = .allocated { didSet { if oldValue != metric { invalidateRows() } } }
    @Published var search = "" { didSet { if oldValue != search { invalidateRows() } } }
    @Published var tableSort = [KeyPathComparator(\ContentRow.bytes, order: .reverse)] { didSet { invalidateRows() } }
    @Published private(set) var expandedFolderIDs: Set<String> = []
    @Published private(set) var mapExpandedFolderIDs: Set<String> = []
    @Published var showInspector = true
    @Published private(set) var isScanning = false
    @Published private(set) var isTrashing = false
    @Published private(set) var isEmptyingTrash = false
    @Published private(set) var isPreparingMap = false
    @Published private(set) var progress: ScanProgress?
    @Published private(set) var scanningRoot: URL?
    @Published var errorMessage: String?
    @Published var pendingTrash: DiskNode?
    @Published private(set) var pendingTrashItems: [DiskNode] = []
    @Published var showTrashConfirmation = false
    @Published var showEmptyConfirmation = false
    @Published private(set) var visibleMapTiles: [CachedMapTile] = []
    @Published private(set) var statusMessage = "Выберите папку, чтобы начать анализ"
    private(set) var selectionSummary = SelectionSummary()
    private(set) var rowsBuildCount = 0
    private(set) var mapLayoutBuildCount = 0
    private(set) var snapshotVersion = UUID()

    private let scanner = DiskScanner()
    private let trashService: any TrashMoving
    private let trashManager: any TrashManaging
    private var scanTask: Task<Void, Never>?
    private var generation: UUID?
    private var handledLaunch = false
    private var focusedID: String?
    private var selectionAnchor: String?
    private var rowsCache: [RowsKey: [ContentRow]] = [:]
    private var barsCache: [BarTreeRow]?
    private var sidebarCache: [ContentRow]?
    private var mapCache: [MapRequest: CachedMapScene] = [:]
    private var mapCacheOrder: [MapRequest] = []
    private var currentMapKey: MapRequest?
    private var currentMapScene: CachedMapScene?
    private var mapPreparationToken: UUID?
    private var analysisState: WorkspaceState?
    private var trashState: WorkspaceState?
    private var trashLocations: [TrashLocation] = []
    private var trashNeedsRefresh = true
    private var pendingEmptyRoots: [DiskNode] = []

    init(trashService: any TrashMoving = TrashService(), trashManager: any TrashManaging = TrashDirectoryService(),
         timeMachineService: any TimeMachineManaging = TimeMachineService()) {
        self.trashService = trashService; self.trashManager = trashManager
        timeMachine = TimeMachineModel(service: timeMachineService)
        timeMachineObservation = timeMachine.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
    }

    // Compatibility for commands that operate on one focused item.
    var selectedID: String? {
        get { focusedID }
        set { setSelection(newValue.map { [$0] } ?? [], focus: newValue) }
    }
    var currentFolder: DiskNode? { currentFolderID.flatMap { snapshot?.nodes[$0] } }
    var selectedNode: DiskNode? { selectedID.flatMap { snapshot?.nodes[$0] } }
    var inspectedNode: DiskNode? { selectedNode ?? currentFolder }
    var isMutating: Bool { isTrashing || isEmptyingTrash || timeMachine.isDeleting }
    var isBusy: Bool { isScanning || isMutating || (isTimeMachineTab && timeMachine.isLoading) }
    var isTrashTab: Bool { activeTab == .trash }
    var isTimeMachineTab: Bool { activeTab == .timeMachine }
    var canRefresh: Bool { (isTimeMachineTab || snapshot != nil) && !isBusy }

    private func invalidateRows() {
        rowsCache.removeAll(keepingCapacity: true); barsCache = nil; sidebarCache = nil
    }
    private func invalidateSnapshot() {
        snapshotVersion = UUID(); invalidateRows()
        currentMapKey = nil; currentMapScene = nil; mapPreparationToken = nil; isPreparingMap = false; visibleMapTiles = []
    }

    var rows: [ContentRow] {
        guard let folder = currentFolder else { return [] }
        return childRows(of: folder, total: folder.bytes(for: metric), query: search.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    var sidebarRows: [ContentRow] {
        if let sidebarCache { return sidebarCache }
        guard let folder = currentFolder else { return [] }
        let result = childRows(of: folder, total: folder.bytes(for: metric)).filter { $0.node.isDirectory }
        sidebarCache = result
        return result
    }
    var barRows: [BarTreeRow] {
        if let barsCache { return barsCache }
        guard let folder = currentFolder else { return [] }
        let total = folder.bytes(for: metric)
        var stack = Array(rows.enumerated().map { BarTreeRow(content: $0.element, depth: 0, colorIndex: $0.offset) }.reversed())
        var visible: [BarTreeRow] = []
        while let row = stack.popLast() {
            visible.append(row)
            guard expandedFolderIDs.contains(row.id), row.content.node.isDirectory else { continue }
            stack.append(contentsOf: childRows(of: row.content.node, total: total).reversed().map {
                BarTreeRow(content: $0, depth: row.depth + 1, colorIndex: row.colorIndex)
            })
        }
        barsCache = visible
        return visible
    }
    private func childRows(of folder: DiskNode, total: Int64, query: String = "") -> [ContentRow] {
        let key = RowsKey(folderID: folder.id, total: total, query: query)
        if let cached = rowsCache[key] { return cached }
        guard let snapshot else { return [] }
        let result = folder.childIDs.compactMap { snapshot.nodes[$0] }
            .filter { query.isEmpty || $0.name.localizedStandardContains(query) }
            .map { ContentRow(node: $0, bytes: $0.bytes(for: metric), fraction: fraction($0.bytes(for: metric), of: total)) }
            .sorted { lhs, rhs in
                for comparator in tableSort {
                    let order = comparator.compare(lhs, rhs)
                    if order != .orderedSame { return order == .orderedAscending }
                }
                return lhs.id < rhs.id
            }
        rowsBuildCount += 1; rowsCache[key] = result
        return result
    }

    func select(_ id: String, modifiers: NSEvent.ModifierFlags = []) {
        guard snapshot?.nodes[id] != nil else { return }
        let additive = modifiers.contains(.command)
        if modifiers.contains(.shift) {
            let order = mode == .bars ? barRows.map(\.id) : (mode == .map ? visibleMapTiles.filter { !$0.isGroup }.map(\.nodeID) : rows.map(\.id))
            if let anchor = selectionAnchor, let start = order.firstIndex(of: anchor), let end = order.firstIndex(of: id) {
                let range = Set(order[min(start, end)...max(start, end)])
                setSelection(additive ? selectedIDs.union(range) : range, focus: id)
                return
            }
        }
        var ids: Set<String> = additive ? selectedIDs : []
        if additive && ids.contains(id) { ids.remove(id) } else { ids.insert(id) }
        selectionAnchor = id
        setSelection(ids, focus: ids.contains(id) ? id : nil)
    }
    func selectAllVisible() {
        let ids = mode == .bars ? barRows.map(\.id) : (mode == .map ? visibleMapTiles.filter { !$0.isGroup }.map(\.nodeID) : rows.map(\.id))
        setSelection(Set(ids), focus: ids.first)
    }
    private func setSelection(_ ids: Set<String>, focus: String?) {
        guard ids != selectedIDs || focusedID != focus else { return }
        focusedID = focus; selectedIDs = ids
    }
    private func updateSelectionSummary() {
        guard let snapshot else { selectionSummary = SelectionSummary(); return }
        let nodes = snapshot.topLevelSelection(selectedIDs)
        selectionSummary = SelectionSummary(nodes: nodes, logicalBytes: sumBytes(nodes.map(\.logicalBytes)), allocatedBytes: sumBytes(nodes.map(\.allocatedBytes)))
    }

    func canExpand(_ node: DiskNode) -> Bool { snapshot?.nodes[node.id].map { $0.isDirectory && !$0.childIDs.isEmpty } ?? false }
    func toggleExpansion(_ id: String) {
        guard let node = snapshot?.nodes[id], canExpand(node) else { return }
        if expandedFolderIDs.contains(id) { expandedFolderIDs.remove(id) } else { expandedFolderIDs.insert(id) }
        barsCache = nil; selectedID = id
    }
    private func pruneExpandedFolders(in snapshot: ScanSnapshot) {
        expandedFolderIDs = Set(expandedFolderIDs.filter { snapshot.nodes[$0].map { $0.isDirectory && !$0.childIDs.isEmpty } ?? false })
        mapExpandedFolderIDs = mapExpandedFolderIDs.filter { snapshot.nodes[$0]?.isDirectory == true }
        barsCache = nil
    }

    func mapRequest(size: CGSize) -> MapRequest {
        MapRequest(version: snapshotVersion, folderID: currentFolderID ?? "", metric: metric, query: search,
                   width: max(0, Int(size.width)), height: max(0, Int(size.height)))
    }
    func prepareMap(size: CGSize) async {
        guard let snapshot, currentFolder != nil else { return }
        let request = mapRequest(size: size)
        if request == currentMapKey {
            if isPreparingMap {
                mapPreparationToken = nil; isPreparingMap = false; refreshVisibleMap()
            }
            return
        }
        if let cached = mapCache[request] {
            mapPreparationToken = nil
            currentMapKey = request; currentMapScene = cached; isPreparingMap = false; refreshVisibleMap(); return
        }
        let token = UUID(); mapPreparationToken = token
        isPreparingMap = true
        visibleMapTiles = []
        let rootIDs = rows.map(\.id)
        let worker = Task.detached(priority: .userInitiated) { CachedMapScene.build(snapshot: snapshot, rootIDs: rootIDs, request: request) }
        let scene = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
        guard !Task.isCancelled, mapPreparationToken == token, request == mapRequest(size: size) else { return }
        mapLayoutBuildCount += 1
        mapCache[request] = scene; mapCacheOrder.append(request)
        while mapCacheOrder.count > 4 { mapCache.removeValue(forKey: mapCacheOrder.removeFirst()) }
        currentMapKey = request; currentMapScene = scene; isPreparingMap = false; refreshVisibleMap()
    }
    private func refreshVisibleMap() { visibleMapTiles = currentMapScene?.visible(expanded: mapExpandedFolderIDs) ?? [] }
    func activateMapTile(_ tile: CachedMapTile, header: Bool, modifiers: NSEvent.ModifierFlags = []) {
        if tile.isGroup { navigate(to: tile.nodeID); mode = .table; return }
        select(tile.nodeID, modifiers: modifiers)
        guard !modifiers.contains(.command), !modifiers.contains(.shift), tile.hasChildren else { return }
        if header && mapExpandedFolderIDs.contains(tile.id) { mapExpandedFolderIDs.remove(tile.id) }
        else { mapExpandedFolderIDs.insert(tile.id) }
        refreshVisibleMap()
    }

    func selectTab(_ tab: WorkspaceTab) {
        guard tab != activeTab, !isMutating else { return }
        if isScanning { cancelScan() }
        let state = WorkspaceState(snapshot: snapshot, version: snapshotVersion, folderID: currentFolderID,
                                   selectedIDs: selectedIDs, expanded: expandedFolderIDs, mapExpanded: mapExpandedFolderIDs, search: search)
        if activeTab == .analysis { analysisState = state }
        else if activeTab == .trash { trashState = state }
        activeTab = tab
        let restored = tab == .analysis ? analysisState : (tab == .trash ? trashState : nil)
        snapshot = restored?.snapshot; snapshotVersion = restored?.version ?? UUID(); currentFolderID = restored?.folderID
        expandedFolderIDs = restored?.expanded ?? []; mapExpandedFolderIDs = restored?.mapExpanded ?? []
        search = restored?.search ?? ""; invalidateRows(); currentMapKey = nil; currentMapScene = nil
        mapPreparationToken = nil; isPreparingMap = false; visibleMapTiles = []
        selectedIDs = restored?.selectedIDs ?? []
        errorMessage = nil
        if tab == .timeMachine { timeMachine.activate() }
        else if tab == .trash && (snapshot == nil || trashNeedsRefresh) { startTrashScan() }
        else { statusMessage = tab == .trash ? "Сохранённый анализ Корзины" : "Сохранённый анализ папки" }
    }

    func handleLaunch() {
        guard !handledLaunch else { return }; handledLaunch = true
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "--scan"), arguments.indices.contains(index + 1) {
            startScan(URL(fileURLWithPath: arguments[index + 1], isDirectory: true))
        }
    }
    func chooseFolder() {
        guard !isMutating else { return }
        let panel = NSOpenPanel()
        panel.title = "Выберите папку для анализа"; panel.prompt = "Анализировать"
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = true
        panel.directoryURL = isTrashTab ? FileManager.default.homeDirectoryForCurrentUser : snapshot?.root.url
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }; self?.startScan(url)
        }
    }
    private func beginScan(root: URL) -> UUID {
        scanTask?.cancel(); let token = UUID(); generation = token
        isScanning = true; progress = nil; scanningRoot = root; errorMessage = nil
        statusMessage = "Анализируем \(root.lastPathComponent)…"
        return token
    }
    func startScan(_ root: URL) {
        guard !isMutating else { return }
        if activeTab != .analysis { selectTab(.analysis) }
        let token = beginScan(root: root)
        let scanner = self.scanner
        scanTask = Task { [weak self] in
            do {
                let result = try await scanner.scan(root: root) { [weak self] value in
                    Task { @MainActor [weak self] in if self?.generation == token { self?.progress = value } }
                }
                guard let self, self.generation == token, !Task.isCancelled else { return }
                self.installScan(result); self.finishScan()
            } catch is CancellationError { }
            catch { self?.failScan(error, token: token) }
        }
    }
    private func startTrashScan() {
        guard !isMutating else { return }
        let token = beginScan(root: URL(fileURLWithPath: "/Корзина"))
        let scanner = self.scanner, manager = self.trashManager
        scanTask = Task { [weak self] in
            let locations = await manager.locations()
            var parts: [(TrashLocation, ScanSnapshot)] = []
            var failures: [ScanIssue] = []
            for location in locations {
                if Task.isCancelled { return }
                do {
                    guard location.url.standardizedFileURL.resolvingSymlinksInPath() == location.url.standardizedFileURL else {
                        throw TrashError.symbolicLink
                    }
                    let part = try await scanner.scan(root: location.url)
                    parts.append((location, part))
                } catch is CancellationError { return }
                catch { failures.append(ScanIssue(path: location.id, message: error.localizedDescription)) }
            }
            guard let self, self.generation == token, !Task.isCancelled else { return }
            self.trashLocations = locations
            self.installScan(.trashSnapshot(parts: parts, failures: failures))
            self.trashNeedsRefresh = false; self.finishScan()
        }
    }
    private func installScan(_ result: ScanSnapshot) {
        let sameRoot = snapshot?.rootID == result.rootID
        let oldAncestors = currentFolderID.map { snapshot?.ancestors(of: $0) ?? [] } ?? []
        let previousSelection = selectedIDs
        snapshot = result; invalidateSnapshot()
        if isTrashTab { trashState = nil } else { analysisState = nil }
        if sameRoot { pruneExpandedFolders(in: result) }
        else { expandedFolderIDs = []; mapExpandedFolderIDs = []; search = "" }
        if !sameRoot || currentFolderID.flatMap({ result.nodes[$0] })?.isDirectory != true {
            currentFolderID = sameRoot ? oldAncestors.reversed().first { result.nodes[$0.id]?.isDirectory == true }?.id ?? result.rootID : result.rootID
        }
        selectedIDs = sameRoot ? previousSelection.filter { result.nodes[$0] != nil } : []
        statusMessage = "Анализ завершён за \(result.duration.formatted(.number.precision(.fractionLength(1)))) с"
    }
    private func finishScan() { isScanning = false; progress = nil; scanningRoot = nil; generation = nil; scanTask = nil }
    private func failScan(_ error: Error, token: UUID) {
        guard generation == token else { return }; finishScan()
        statusMessage = "Анализ не завершён"; errorMessage = error.localizedDescription
    }
    func cancelScan() {
        scanTask?.cancel(); finishScan()
        statusMessage = snapshot == nil ? "Анализ отменён" : "Анализ отменён. Последний завершённый результат сохранён."
    }
    func rescan() {
        guard !isBusy else { return }
        if isTimeMachineTab { timeMachine.refresh() }
        else if isTrashTab { startTrashScan() } else if let root = snapshot?.root.url { startScan(root) }
    }
    func navigate(to id: String) {
        guard let node = snapshot?.nodes[id], node.isDirectory else { return }
        currentFolderID = node.accountedAtID ?? id
        selectedID = nil; search = ""; invalidateRows(); currentMapKey = nil; currentMapScene = nil; visibleMapTiles = []
    }
    func goUp() { if let parent = currentFolder?.parentID { navigate(to: parent) } }
    func reveal(_ node: DiskNode) {
        if isTrashTab, node.id == snapshot?.rootID, let location = trashLocations.first {
            NSWorkspace.shared.open(location.url)
        } else { NSWorkspace.shared.activateFileViewerSelecting([node.url]) }
    }
    func revealSelection() { NSWorkspace.shared.activateFileViewerSelecting(selectionSummary.nodes.map(\.url)) }

    func canTrash(_ node: DiskNode?) -> Bool {
        guard activeTab == .analysis, let node, let snapshot, let stored = snapshot.nodes[node.id], stored.identity == node.identity else { return false }
        let supported = node.kind == .regularFile || (node.isDirectory && node.accountedAtID == nil)
        return supported && node.id != snapshot.rootID && !isBusy
    }
    var canTrashSelection: Bool { !selectionSummary.nodes.isEmpty && selectionSummary.nodes.allSatisfy { canTrash($0) } }
    func canTrashRequest(_ node: DiskNode) -> Bool {
        selectedIDs.contains(node.id) && selectedIDs.count > 1 ? canTrashSelection : canTrash(node)
    }
    func requestTrash(_ node: DiskNode? = nil) {
        let candidates: [DiskNode]
        if let node, !selectedIDs.contains(node.id) { candidates = [node] }
        else if !selectionSummary.nodes.isEmpty { candidates = selectionSummary.nodes }
        else { candidates = inspectedNode.map { [$0] } ?? [] }
        guard !candidates.isEmpty, candidates.allSatisfy({ canTrash($0) }) else { return }
        pendingTrashItems = candidates; pendingTrash = candidates.first; showTrashConfirmation = true
    }
    func confirmPendingTrash() { confirmTrashItems(pendingTrashItems) }
    func confirmTrash(_ node: DiskNode) { confirmTrashItems([node]) }
    private func confirmTrashItems(_ candidates: [DiskNode]) {
        guard !candidates.isEmpty, candidates.allSatisfy({ canTrash($0) }), let initial = snapshot else { return }
        let nodes = initial.topLevelSelection(Set(candidates.map(\.id)))
        isTrashing = true; pendingTrash = nil; pendingTrashItems = []; showTrashConfirmation = false; errorMessage = nil
        Task { [weak self] in
            guard let self else { return }
            var removed: Set<String> = []; var failures: [String] = []
            for node in nodes {
                do { try await self.trashService.moveToTrash(candidate: node, root: initial.root); removed.insert(node.id) }
                catch { failures.append("\(node.url.path): \(error.localizedDescription)") }
            }
            if !removed.isEmpty {
                let updated = await Task.detached(priority: .userInitiated) { initial.removingSubtrees(ids: removed) }.value
                self.applyUpdatedSnapshot(updated, previous: initial); self.trashNeedsRefresh = true
            }
            self.isTrashing = false
            self.statusMessage = "Перемещено в Корзину: \(removed.count)"
            if !failures.isEmpty { self.errorMessage = failures.prefix(5).joined(separator: "\n") }
        }
    }
    private func applyUpdatedSnapshot(_ updated: ScanSnapshot, previous: ScanSnapshot) {
        let ancestors = currentFolderID.map { previous.ancestors(of: $0) } ?? []
        snapshot = updated; invalidateSnapshot(); pruneExpandedFolders(in: updated)
        if isTrashTab { trashState = nil } else { analysisState = nil }
        if currentFolderID.flatMap({ updated.nodes[$0] }) == nil {
            currentFolderID = ancestors.reversed().first { updated.nodes[$0.id] != nil }?.id ?? updated.rootID; search = ""
        }
        selectedIDs = selectedIDs.filter { updated.nodes[$0] != nil }
    }

    private var emptyableRoots: [DiskNode] {
        trashLocations.compactMap { snapshot?.nodes[$0.id] }.filter { $0.identity != nil && $0.scanError == nil }
    }
    var canEmptyTrash: Bool { isTrashTab && !isBusy && emptyableRoots.contains { !$0.childIDs.isEmpty } }
    func requestEmptyTrash() {
        guard canEmptyTrash else { return }; pendingEmptyRoots = emptyableRoots; showEmptyConfirmation = true
    }
    var destructiveTitle: String { showEmptyConfirmation ? "Очистить Корзину?" : "Переместить в Корзину: \(pendingTrashItems.count)?" }
    var destructiveMessage: String {
        if showEmptyConfirmation {
            return "Все объекты в доступной Корзине будут удалены без возможности восстановления.\n\n" + pendingEmptyRoots.map { "\($0.name) — \($0.url.path): \(byteText($0.allocatedBytes))" }.joined(separator: "\n")
        }
        return pendingTrashItems.prefix(8).map { $0.url.path }.joined(separator: "\n")
            + "\n\n\(byteText(sumBytes(pendingTrashItems.map(\.allocatedBytes)))) на диске. Восстановление доступно через Finder."
    }
    func cancelDestructivePrompt() {
        showTrashConfirmation = false; showEmptyConfirmation = false; pendingTrash = nil; pendingTrashItems = []; pendingEmptyRoots = []
    }
    func confirmEmptyTrash() {
        guard isTrashTab, !isBusy, let initial = snapshot, !pendingEmptyRoots.isEmpty else { return }
        let roots = pendingEmptyRoots; showEmptyConfirmation = false; pendingEmptyRoots = []; isEmptyingTrash = true; errorMessage = nil
        Task { [weak self] in
            guard let self else { return }
            let result = await self.trashManager.empty(roots: roots)
            let updated = await Task.detached(priority: .userInitiated) { initial.removingSubtrees(ids: result.removedIDs) }.value
            await self.updateSavedAnalysis(removing: result.removedIDs)
            self.applyUpdatedSnapshot(updated, previous: initial); self.isEmptyingTrash = false
            self.statusMessage = "Удалено из Корзины: \(result.removedIDs.count)"
            if !result.failures.isEmpty { self.errorMessage = result.failures.prefix(5).map { "\($0.path): \($0.message)" }.joined(separator: "\n") }
        }
    }

    private func updateSavedAnalysis(removing ids: Set<String>) async {
        guard let state = analysisState, let original = state.snapshot, !ids.isEmpty else { return }
        if ids.contains(original.rootID) {
            analysisState = WorkspaceState(snapshot: nil, version: UUID(), folderID: nil, selectedIDs: [], expanded: [], mapExpanded: [], search: "")
            return
        }
        let relevant = ids.filter { original.nodes[$0] != nil }
        guard !relevant.isEmpty else { return }
        let updated = await Task.detached(priority: .userInitiated) { original.removingSubtrees(ids: relevant) }.value
        let ancestors = state.folderID.map { original.ancestors(of: $0) } ?? []
        let survives = state.folderID.flatMap { updated.nodes[$0] } != nil
        analysisState = WorkspaceState(
            snapshot: updated, version: UUID(),
            folderID: survives ? state.folderID : ancestors.reversed().first { updated.nodes[$0.id] != nil }?.id ?? updated.rootID,
            selectedIDs: state.selectedIDs.filter { updated.nodes[$0] != nil },
            expanded: state.expanded.filter { updated.nodes[$0].map { !$0.childIDs.isEmpty } ?? false },
            mapExpanded: state.mapExpanded.filter { updated.nodes[$0] != nil }, search: survives ? state.search : ""
        )
    }
}

func sumBytes(_ values: [Int64]) -> Int64 {
    values.reduce(0) { let (sum, overflow) = $0.addingReportingOverflow($1); return overflow ? Int64.max : sum }
}

func fraction(_ value: Int64, of total: Int64) -> Double {
    guard total > 0 else { return 0 }
    return min(1, max(0, Double(value) / Double(total)))
}

func byteText(_ value: Int64) -> String {
    ByteTextCache.shared.string(value)
}

private final class ByteTextCache: @unchecked Sendable {
    static let shared = ByteTextCache()
    private let lock = NSLock()
    private let formatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter(); formatter.countStyle = .file; return formatter
    }()
    private var values: [Int64: String] = [:]
    func string(_ bytes: Int64) -> String {
        lock.lock(); defer { lock.unlock() }
        if let value = values[bytes] { return value }
        let value = formatter.string(fromByteCount: bytes)
        if values.count >= 4096 { values.removeAll(keepingCapacity: true) }
        values[bytes] = value
        return value
    }
}

extension DiskNode {
    var symbol: String {
        switch kind {
        case .directory: "folder.fill"
        case .symbolicLink: "link"
        case .other: "doc.badge.ellipsis"
        case .regularFile:
            switch url.pathExtension.lowercased() {
            case "jpg", "jpeg", "png", "heic", "gif", "svg", "webp": "photo"
            case "mp4", "mov", "mkv", "avi": "film"
            case "mp3", "wav", "flac", "m4a": "music.note"
            case "zip", "gz", "tar", "dmg", "7z": "archivebox"
            default: "doc"
            }
        }
    }
    var typeTitle: String {
        switch kind {
        case .directory: "Папка"
        case .regularFile: "Файл"
        case .symbolicLink: "Символическая ссылка"
        case .other: "Специальный файл"
        }
    }
}
