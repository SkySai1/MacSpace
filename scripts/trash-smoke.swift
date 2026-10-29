import Darwin
import Foundation

// Explicit integration check; only this script's UUID-named fixture is changed.
// Usage: swift scripts/trash-smoke.swift [temporary-parent-directory]
func runSmokeTest() throws {
    let manager = FileManager.default
    let base = CommandLine.arguments.count > 1
        ? URL(fileURLWithPath: CommandLine.arguments[1]) : manager.temporaryDirectory
    let unique = "MacSpaceTrashSmoke-" + UUID().uuidString
    let root = base.appendingPathComponent(unique)
    let candidate = root.appendingPathComponent(unique)
    var movedURL: URL?
    try manager.createDirectory(at: candidate, withIntermediateDirectories: true)
    defer {
        if let movedURL, manager.fileExists(atPath: movedURL.path) {
            try? manager.moveItem(at: movedURL, to: candidate)
        }
        try? manager.removeItem(at: root)
    }
    let payload = Data("MacSpace smoke test".utf8)
    try payload.write(to: candidate.appendingPathComponent("probe.txt"))
    var resulting: NSURL?
    try manager.trashItem(at: candidate, resultingItemURL: &resulting)
    movedURL = resulting as URL?
    guard let result = movedURL, result.lastPathComponent == unique,
          manager.fileExists(atPath: result.path), !manager.fileExists(atPath: candidate.path) else {
        throw NSError(domain: "MacSpaceSmoke", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Неожиданный результат Корзины. Тестовый объект: \(unique)"
        ])
    }
    try manager.moveItem(at: result, to: candidate)
    movedURL = nil
    guard try Data(contentsOf: candidate.appendingPathComponent("probe.txt")) == payload else {
        throw NSError(domain: "MacSpaceSmoke", code: 2, userInfo: [NSLocalizedDescriptionKey: "Содержимое не восстановлено"])
    }
    print("Корзина: перенос и восстановление созданной тестовой папки успешны")
}

do {
    try runSmokeTest()
} catch {
    FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
    exit(1)
}
