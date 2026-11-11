import Foundation

@main
struct DocumentLibraryTests {
    @MainActor static func main() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("QuillTeX-library-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let bundled = URL(fileURLWithPath: "QuillTeX/Project/bundled_templates", isDirectory: true)
        let library = DocumentLibrary(directory: base, bundledTemplatesDirectory: bundled)
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            guard condition() else { fatalError("FAILED: \(message)") }; checks += 1
        }
        check(library.storageError == nil, "library initializes")
        check(library.templates.count == 5, "five portable templates ship without a blank entry")
        check(!library.templates.contains { $0.title == "blank" }, "blank is not a template; it is the unselected default")
        for template in library.templates {
            let actual = try Data(contentsOf: template.url)
            let original = try Data(contentsOf: bundled.appendingPathComponent(template.url.lastPathComponent))
            check(actual == original, "template copied without modifications: \(template.title)")
        }
        for template in library.templates {
            let actual = try Data(contentsOf: template.url)
            let original = try Data(contentsOf: bundled.appendingPathComponent(template.url.lastPathComponent))
            check(actual == original, "template copied without modifications: \(template.title)")
        }
        check(!library.templates.contains { $0.title.hasPrefix("academic-") }, "private academic templates are not distributed")
        for template in library.templates {
            let source = try library.source(for: template)
            check(!source.contains("/Users/"), "bundled templates have no personal absolute paths")
        }
        let legacyDirectory = base.appendingPathComponent("LegacyNames")
        let legacyTemplates = legacyDirectory.appendingPathComponent("Templates")
        try FileManager.default.createDirectory(at: legacyTemplates, withIntermediateDirectories: true)
        try "Current article".write(to: legacyTemplates.appendingPathComponent("article.tex"), atomically: true, encoding: .utf8)
        try "Customized old article".write(to: legacyTemplates.appendingPathComponent("basic_article.tex"), atomically: true, encoding: .utf8)
        try "Earlier old article".write(to: legacyTemplates.appendingPathComponent("basic-article.tex"), atomically: true, encoding: .utf8)
        try "Legacy blank".write(to: legacyTemplates.appendingPathComponent("空白文稿.tex"), atomically: true, encoding: .utf8)
        let migrated = DocumentLibrary(directory: legacyDirectory, bundledTemplatesDirectory: bundled)
        check(migrated.storageError == nil, "legacy filenames migrate successfully")
        check(!migrated.templates.contains { $0.title.hasPrefix("basic") }, "previous built-in names become plain English names")
        let articleSources = try migrated.templates.filter { $0.title.hasPrefix("article") }.map { try migrated.source(for: $0) }
        check(Set(articleSources) == ["Current article", "Customized old article", "Earlier old article"], "filename migration retains every customized copy and resolves collisions")
        let legacyCustomBlank = migrated.templates.first { $0.title == "空白文稿" }
        check(legacyCustomBlank.flatMap { try? migrated.source(for: $0) } == "Legacy blank",
              "a customized legacy blank keeps its content instead of being deleted")
        check(!migrated.templates.contains { $0.title == "blank" }, "an empty retired blank is not recreated")
        let migrationRestart = DocumentLibrary(directory: legacyDirectory, bundledTemplatesDirectory: bundled)
        check(migrationRestart.templates.count == migrated.templates.count, "filename migration does not duplicate templates on restart")
        // The retired built-in blank is cleaned up once on upgrade; any blank the
        // user creates later must survive every later launch.
        let upgrade = base.appendingPathComponent("BlankUpgrade")
        let upgradeTemplates = upgrade.appendingPathComponent("Templates")
        try FileManager.default.createDirectory(at: upgradeTemplates, withIntermediateDirectories: true)
        try Data().write(to: upgradeTemplates.appendingPathComponent("blank.tex"))
        try Data().write(to: upgradeTemplates.appendingPathComponent("空白文稿.tex"))
        let upgraded = DocumentLibrary(directory: upgrade, bundledTemplatesDirectory: bundled)
        check(upgraded.storageError == nil, "blank upgrade cleanup succeeds")
        check(!FileManager.default.fileExists(atPath: upgradeTemplates.appendingPathComponent("blank.tex").path),
              "the shipped zero-byte blank.tex is removed once")
        check(!FileManager.default.fileExists(atPath: upgradeTemplates.appendingPathComponent("空白文稿.tex").path),
              "the old zero-byte Chinese blank is removed once")
        check(!upgraded.templates.contains { $0.title == "blank" || $0.title == "空白文稿" },
              "retired blank entries disappear from the chooser")
        let userBlank = try upgraded.createTemplate(named: "blank")
        check(try! upgraded.source(for: userBlank).isEmpty, "New Template blank starts empty")
        let upgradedRestart = DocumentLibrary(directory: upgrade, bundledTemplatesDirectory: bundled)
        check(upgradedRestart.templates.contains { $0.title == "blank" },
              "a blank template created after the upgrade survives a restart")
        check(FileManager.default.fileExists(atPath: userBlank.url.path),
              "the second launch no longer deletes the user's blank template")
        let customizedDirectory = base.appendingPathComponent("CustomizedBlank")
        let customizedTemplates = customizedDirectory.appendingPathComponent("Templates")
        try FileManager.default.createDirectory(at: customizedTemplates, withIntermediateDirectories: true)
        try "\\section{My Blank}".write(to: customizedTemplates.appendingPathComponent("blank.tex"), atomically: true, encoding: .utf8)
        try Data().write(to: customizedTemplates.appendingPathComponent("空白文稿.tex"))
        let customized = DocumentLibrary(directory: customizedDirectory, bundledTemplatesDirectory: bundled)
        check(customized.templates.contains { $0.title == "blank" }, "a customized blank template is preserved")
        check(customized.templates.first { $0.title == "blank" }.flatMap { try? customized.source(for: $0) } == "\\section{My Blank}",
              "the customized blank keeps its content")
        check(!customized.templates.contains { $0.title == "空白文稿" }, "the empty legacy copy is still cleaned up")
        let customizedRestart = DocumentLibrary(directory: customizedDirectory, bundledTemplatesDirectory: bundled)
        check(customizedRestart.templates.contains { $0.title == "blank" }, "the customized blank survives a restart")
        // Recovery is isolated from the ordinary chooser/import count checks.
        let recovery = base.appendingPathComponent("Recovery")
        let archived = recovery.appendingPathComponent("RetiredTemplates")
        let current = recovery.appendingPathComponent("Templates")
        try FileManager.default.createDirectory(at: archived, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: current, withIntermediateDirectories: true)
        try "User edition".write(to: current.appendingPathComponent("academic-article.tex"), atomically: true, encoding: .utf8)
        try "Retired edition".write(to: archived.appendingPathComponent("academic-article.tex"), atomically: true, encoding: .utf8)
        try "Other edition".write(to: archived.appendingPathComponent(UUID().uuidString + "-academic-article.tex"), atomically: true, encoding: .utf8)
        try "Unrelated".write(to: archived.appendingPathComponent("keep.txt"), atomically: true, encoding: .utf8)
        let recovered = DocumentLibrary(directory: recovery, bundledTemplatesDirectory: bundled)
        let recoveredSources = try recovered.templates.filter { $0.title.hasPrefix("academic-article") }.map { try recovered.source(for: $0) }
        check(Set(recoveredSources) == ["User edition", "Retired edition", "Other edition"], "recovery preserves all same-name copies without overwriting")
        check(recovered.templates.filter { $0.title.hasPrefix("academic-article") }.count == 3, "old UUID collision names are restored to readable names")
        check(FileManager.default.fileExists(atPath: archived.appendingPathComponent("keep.txt").path), "recovery leaves unrelated files alone")
        let recoveredRestart = DocumentLibrary(directory: recovery, bundledTemplatesDirectory: bundled)
        check(recoveredRestart.templates.count == recovered.templates.count, "recovery runs once without duplicating files on restart")
        let reimported = try recoveredRestart.importTemplate(current.appendingPathComponent("academic-article.tex"))
        let reimportedRestart = DocumentLibrary(directory: recovery, bundledTemplatesDirectory: bundled)
        check(reimportedRestart.templates.contains { $0.url.standardizedFileURL.path == reimported.standardizedFileURL.path }, "explicitly imported legacy names survive restart")
        let editable = library.templates.first!
        try "customized".write(to: editable.url, atomically: true, encoding: .utf8)
        let restarted = DocumentLibrary(directory: base, bundledTemplatesDirectory: bundled)
        let kept = try String(contentsOf: editable.url, encoding: .utf8)
        check(kept == "customized", "restart preserves customized templates")
        let imported = try restarted.importTemplate(editable.url)
        check(imported != editable.url, "same-name import gets a new name")
        let importedSource = try String(contentsOf: imported, encoding: .utf8)
        check(importedSource == "customized", "import source retained")
        check(restarted.templates.count == 6, "import immediately updates chooser")
        // Deleting a template removes only that file and refreshes the chooser.
        let doomed = restarted.templates.first { $0.url.standardizedFileURL.path == imported.standardizedFileURL.path }!
        try restarted.deleteTemplate(doomed)
        check(!FileManager.default.fileExists(atPath: imported.path), "deleted template file is gone")
        check(restarted.templates.count == 5, "chooser drops the deleted template")
        let afterDelete = DocumentLibrary(directory: base, bundledTemplatesDirectory: bundled)
        check(!afterDelete.templates.contains { $0.id == doomed.id }, "deletion persists across launches")
        check(afterDelete.templates.count == 5, "remaining templates survive")
        for number in 0..<25 { try restarted.record(base.appendingPathComponent("doc-\(number).tex")) }
        check(restarted.recents.count == 20, "history limit")
        try restarted.record(base.appendingPathComponent("doc-9.tex"))
        check(restarted.recents.first?.title == "doc-9", "reopen moves item to top")
        check(restarted.recents.filter { $0.title == "doc-9" }.count == 1, "history deduplicates")
        let historyReloaded = DocumentLibrary(directory: base, bundledTemplatesDirectory: bundled)
        check(historyReloaded.recents.first?.title == "doc-9", "history persisted across launches")
        try historyReloaded.remove(historyReloaded.recents[0])
        let removedReloaded = DocumentLibrary(directory: base, bundledTemplatesDirectory: bundled)
        check(!removedReloaded.recents.contains { $0.title == "doc-9" }, "removing history persists")
        let broken = Data("malformed history".utf8)
        try broken.write(to: library.historyURL, options: .atomic)
        let corrupt = DocumentLibrary(directory: base, bundledTemplatesDirectory: bundled)
        check(corrupt.storageError != nil, "corrupt history reported")
        do { try corrupt.record(base.appendingPathComponent("new.tex")); fatalError("corrupt history overwritten") } catch {}
        let preserved = try Data(contentsOf: library.historyURL)
        check(preserved == broken, "corrupt history is not silently overwritten")
        check(!corrupt.templates.isEmpty, "templates work even with corrupt history")
        print("PASS: \(checks) document-library assertions")
    }
}
