import Foundation
import MacSpaceCore
import SwiftUI

@MainActor
final class TimeMachineModel: ObservableObject {
    @Published private(set) var snapshots: [LocalTimeMachineSnapshot] = []
    @Published var selectedIDs: Set<String> = []
    @Published private(set) var isLoading = false
    @Published private(set) var isDeleting = false
    @Published private(set) var loadedAt: Date?
    @Published private(set) var errorMessage: String?
    @Published private(set) var statusMessage = "Откройте раздел, чтобы прочитать локальные снимки"
    @Published var showDeleteConfirmation = false
    @Published private(set) var pendingDeletion: [LocalTimeMachineSnapshot] = []

    private let service: any TimeMachineManaging
    private var loadTask: Task<Void, Never>?
    private var generation: UUID?
    private var needsRefresh = true

    init(service: any TimeMachineManaging = TimeMachineService()) { self.service = service }

    var isBusy: Bool { isLoading || isDeleting }
    var canDeleteSelection: Bool { !isBusy && !needsRefresh && snapshots.contains { selectedIDs.contains($0.id) } }
    var canDeleteAll: Bool { !isBusy && !needsRefresh && !snapshots.isEmpty }

    func activate() { if loadedAt == nil || needsRefresh { refresh() } }

    func refresh() {
        guard !isDeleting else { return }
        loadTask?.cancel()
        let token = UUID(); generation = token; isLoading = true; errorMessage = nil
        cancelPrompt()
        statusMessage = "Читаем локальные снимки Time Machine…"
        loadTask = Task { [weak self, service] in
            do {
                let result = try await service.list()
                guard let self, self.generation == token, !Task.isCancelled else { return }
                self.snapshots = result.sorted { $0.id > $1.id }
                self.selectedIDs.formIntersection(Set(result.map(\.id)))
                self.loadedAt = Date(); self.needsRefresh = false
                self.statusMessage = "Дат локальных снимков: \(result.count)"
            } catch {
                guard let self, self.generation == token, !Task.isCancelled else { return }
                self.needsRefresh = true; self.errorMessage = error.localizedDescription
                self.statusMessage = "Не удалось обновить локальные снимки"
            }
            guard let self, self.generation == token else { return }
            self.isLoading = false; self.generation = nil; self.loadTask = nil
        }
    }

    func requestDeletion(all: Bool = false) {
        guard all ? canDeleteAll : canDeleteSelection else { return }
        pendingDeletion = all ? snapshots : snapshots.filter { selectedIDs.contains($0.id) }
        showDeleteConfirmation = !pendingDeletion.isEmpty
    }

    var confirmationMessage: String {
        "Будут безвозвратно удалены локальные снимки выбранных дат на всех подключённых дисках. Восстановление файлов из этих снимков станет недоступно.\n\n"
        + pendingDeletion.prefix(12).map(\.id).joined(separator: "\n")
        + (pendingDeletion.count > 12 ? "\nИ ещё дат: \(pendingDeletion.count - 12)" : "")
        + "\n\nmacOS запросит права администратора."
    }

    func cancelPrompt() { showDeleteConfirmation = false; pendingDeletion = [] }

    func confirmDeletion() {
        // Pending dates, rather than the live selection, bind the action to the reviewed confirmation.
        guard !isBusy, !needsRefresh, !pendingDeletion.isEmpty else { return }
        let approved = pendingDeletion
        cancelPrompt(); isDeleting = true; errorMessage = nil
        statusMessage = "Удаляем локальные снимки Time Machine…"
        Task { [weak self, service] in
            do {
                let result = try await service.delete(approved)
                guard let self else { return }
                self.snapshots.removeAll { result.removedIDs.contains($0.id) }
                self.selectedIDs.subtract(result.removedIDs)
                self.statusMessage = "Обработано дат: \(result.removedIDs.count); ошибок: \(result.failures.count)"
                if !result.failures.isEmpty {
                    self.errorMessage = result.failures.prefix(5).map { "\($0.dateID): \($0.message)" }.joined(separator: "\n")
                    self.needsRefresh = true
                }
            } catch {
                guard let self else { return }
                self.needsRefresh = true; self.errorMessage = error.localizedDescription
                self.statusMessage = "Удаление не завершено. Обновите список."
            }
            self?.isDeleting = false
        }
    }
}
