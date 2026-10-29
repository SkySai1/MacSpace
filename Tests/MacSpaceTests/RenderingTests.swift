import AppKit
import SwiftUI
import Testing
@testable import MacSpace
@testable import MacSpaceCore

@Suite("Нативный интерфейс")
@MainActor
struct RenderingTests {
    @Test("Окно отрисовывается в трёх режимах и двух оформлениях")
    func renderWindow() async throws {
        _ = NSApplication.shared
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("MacSpaceRendering-" + UUID().uuidString)
        let root = temporary.appendingPathComponent("Рабочие файлы")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        for (path, megabytes) in [
            ("Медиатека/Видео/Поездка.mov", 8), ("Медиатека/Фото/Альбом.heic", 5),
            ("Проекты/Приложение/Resources.dat", 4), ("Проекты/Дизайн/Макет.png", 3),
            ("Архивы/backup.zip", 5), ("Документы/Отчёт.pdf", 2), ("notes.txt", 1),
            ("Очень длинное название папки с документами для проверки размера/data", 3)
        ] {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 0x61, count: megabytes * 1_024 * 1_024).write(to: url)
        }
        let trash = temporary.appendingPathComponent("Тестовая Корзина")
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 2_000_000).write(to: trash.appendingPathComponent("Пример.zip"))
        let timeMachineService = FixtureTimeMachineService()
        let model = AppModel(trashManager: TrashDirectoryService(testLocations: [TrashLocation(url: trash, name: "Корзина теста")]),
                             timeMachineService: timeMachineService)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 860),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: ContentView(model: model))
        window.contentView = host
        window.setContentSize(NSSize(width: 1400, height: 860))
        let capture = ProcessInfo.processInfo.environment["MACSPACE_CAPTURE_PREVIEWS"] == "1"
        let output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/previews", isDirectory: true)
        if capture { try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true) }

        func render(_ name: String) throws {
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            #expect(bitmap.pixelsWide >= 1060)
            #expect(bitmap.pixelsHigh >= 680)
            #expect(png.count > 5_000)
            if capture { try png.write(to: output.appendingPathComponent(name + ".png")) }
        }

        window.appearance = NSAppearance(named: .aqua)
        try await Task.sleep(for: .milliseconds(200))
        try render("welcome")
        model.startScan(root)
        let deadline = Date().addingTimeInterval(10)
        while model.isScanning && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(model.snapshot != nil)
        for (appearance, name) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            window.appearance = NSAppearance(named: appearance)
            for mode in DisplayMode.allCases {
                model.selectedID = nil
                model.mode = mode
                try await Task.sleep(for: .milliseconds(200))
                try render("\(mode.rawValue)-\(name)")
                if mode == .bars {
                    let parent = try #require(model.snapshot?.nodes.values.first { $0.name == "Медиатека" })
                    let nested = try #require(model.snapshot?.nodes.values.first { $0.name == "Видео" })
                    model.toggleExpansion(parent.id)
                    if !model.expandedFolderIDs.contains(nested.id) { model.toggleExpansion(nested.id) }
                    try await Task.sleep(for: .milliseconds(200))
                    try render("bars-expanded-\(name)")
                    model.toggleExpansion(parent.id)
                }
                if mode == .map {
                    let parent = try #require(model.visibleMapTiles.first { $0.hasChildren })
                    let builds = model.mapLayoutBuildCount
                    model.activateMapTile(parent, header: false)
                    try await Task.sleep(for: .milliseconds(200))
                    #expect(model.mapLayoutBuildCount == builds)
                    try render("map-expanded-\(name)")
                    model.activateMapTile(parent, header: true)
                    try await Task.sleep(for: .milliseconds(100))
                    #expect(model.mapLayoutBuildCount == builds)
                }
            }
        }
        model.selectTab(.trash)
        let trashDeadline = Date().addingTimeInterval(10)
        while model.isScanning && Date() < trashDeadline { try await Task.sleep(for: .milliseconds(10)) }
        model.mode = .table
        try await Task.sleep(for: .milliseconds(200))
        #expect(model.canEmptyTrash)
        try render("trash")
        model.selectTab(.timeMachine)
        while model.timeMachine.isLoading { try await Task.sleep(for: .milliseconds(10)) }
        model.timeMachine.selectedIDs = Set(model.timeMachine.snapshots.map(\.id))
        for (appearance, name) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            window.appearance = NSAppearance(named: appearance)
            try await Task.sleep(for: .milliseconds(200))
            #expect(model.timeMachine.canDeleteSelection)
            #expect(host.bounds.height <= 900)
            try render("time-machine-\(name)")
        }
        await timeMachineService.setListFails(true)
        model.timeMachine.refresh()
        while model.timeMachine.isLoading { try await Task.sleep(for: .milliseconds(10)) }
        try await Task.sleep(for: .milliseconds(100))
        #expect(!model.timeMachine.canDeleteAll)
        #expect(host.bounds.height <= 900)
        try render("time-machine-denied")
        await timeMachineService.setListFails(false)
        model.timeMachine.refresh()
        while model.timeMachine.isLoading { try await Task.sleep(for: .milliseconds(10)) }
        model.timeMachine.requestDeletion(all: true); model.timeMachine.confirmDeletion()
        while model.timeMachine.isDeleting { try await Task.sleep(for: .milliseconds(10)) }
        try await Task.sleep(for: .milliseconds(100))
        #expect(model.timeMachine.snapshots.isEmpty)
        try render("time-machine-empty")
    }
}
