import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct MacSpaceApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        Window("MacSpace", id: "main") {
            ContentView(model: model)
                .frame(minWidth: 1060, minHeight: 680)
                .tint(.spaceAccent)
                .task { model.handleLaunch() }
        }
        .defaultSize(width: 1320, height: 840)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Выбрать папку…", action: model.chooseFolder)
                    .keyboardShortcut("o")
                    .disabled(model.isMutating)
            }
            CommandMenu("Анализ") {
                Button("Обновить анализ", action: model.rescan)
                    .keyboardShortcut("r")
                    .disabled(!model.canRefresh)
                Button("Остановить анализ", action: model.cancelScan)
                    .keyboardShortcut(".")
                    .disabled(!model.isScanning)
                Divider()
                Button("На уровень выше", action: model.goUp)
                    .keyboardShortcut(.upArrow, modifiers: .command)
                    .disabled(model.currentFolder?.parentID == nil)
                Button("Открыть выбранную папку") {
                    if let node = model.selectedNode { model.navigate(to: node.id) }
                }
                .keyboardShortcut(.downArrow, modifiers: .command)
                .disabled(model.selectedNode?.isDirectory != true)
                Divider()
                Button("Переместить в Корзину…") { model.requestTrash() }
                    .keyboardShortcut(.delete, modifiers: .command)
                    .disabled(model.selectedIDs.isEmpty ? !model.canTrash(model.inspectedNode) : !model.canTrashSelection)
                Button("Очистить корзину…", action: model.requestEmptyTrash)
                    .disabled(!model.canEmptyTrash)
                Divider()
                Button("Снимки Time Machine") { model.selectTab(.timeMachine) }
                    .disabled(model.isMutating)
                Button("Удалить выбранные снимки…") { model.timeMachine.requestDeletion() }
                    .disabled(!model.isTimeMachineTab || !model.timeMachine.canDeleteSelection)
            }
        }
    }
}

extension Color {
    static let spaceAccent = Color(red: 0.12, green: 0.52, blue: 0.46)
    static let spacePalette: [Color] = [
        .spaceAccent, Color(red: 0.22, green: 0.48, blue: 0.76),
        Color(red: 0.65, green: 0.43, blue: 0.73), Color(red: 0.82, green: 0.54, blue: 0.24),
        Color(red: 0.26, green: 0.62, blue: 0.68), Color(red: 0.72, green: 0.40, blue: 0.46)
    ]
}
