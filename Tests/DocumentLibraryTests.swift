import Foundation
import CryptoKit

@main
struct DocumentLibraryTests {
    @MainActor static func main() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("QuillTeX-library-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let bundled = URL(fileURLWithPath: "QuillTeX/Project/BundledTemplates", isDirectory: true)
        let library = DocumentLibrary(directory: base, bundledTemplatesDirectory: bundled)
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            guard condition() else { fatalError("FAILED: \(message)") }; checks += 1
        }
        check(library.storageError == nil, "library initializes")
        check(library.templates.count == 6, "five portable templates plus blank")
        check(library.templates.contains { $0.title == "空白文稿" }, "blank template selectable")
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
        let legacy = library.templatesDirectory.appendingPathComponent("retired-test.tex")
        let legacyData = Data("Old default".utf8)
        let digest = SHA256.hash(data: legacyData).map { String(format: "%02x", $0) }.joined()
        try legacyData.write(to: legacy)
        try library.retireUnmodifiedTemplate(named: legacy.lastPathComponent, digest: digest)
        check(!FileManager.default.fileExists(atPath: legacy.path), "unmodified old default leaves chooser")
        let archived = try Data(contentsOf: base.appendingPathComponent("RetiredTemplates/retired-test.tex"))
        check(archived == legacyData, "retired copy remains recoverable")
        try Data("User customization".utf8).write(to: legacy)
        try library.retireUnmodifiedTemplate(named: legacy.lastPathComponent, digest: digest)
        check(FileManager.default.fileExists(atPath: legacy.path), "customized legacy template is preserved")
        try FileManager.default.removeItem(at: legacy)
        let editable = library.templates.first!
        try "customized".write(to: editable.url, atomically: true, encoding: .utf8)
        let restarted = DocumentLibrary(directory: base, bundledTemplatesDirectory: bundled)
        let kept = try String(contentsOf: editable.url, encoding: .utf8)
        check(kept == "customized", "restart preserves customized templates")
        let imported = try restarted.importTemplate(editable.url)
        check(imported != editable.url, "same-name import gets a new name")
        let importedSource = try String(contentsOf: imported, encoding: .utf8)
        check(importedSource == "customized", "import source retained")
        check(restarted.templates.count == 7, "import immediately updates chooser")
        // Deleting a template removes only that file and refreshes the chooser.
        let doomed = restarted.templates.first { $0.url.standardizedFileURL.path == imported.standardizedFileURL.path }!
        try restarted.deleteTemplate(doomed)
        check(!FileManager.default.fileExists(atPath: imported.path), "deleted template file is gone")
        check(restarted.templates.count == 6, "chooser drops the deleted template")
        let afterDelete = DocumentLibrary(directory: base, bundledTemplatesDirectory: bundled)
        check(!afterDelete.templates.contains { $0.id == doomed.id }, "deletion persists across launches")
        check(afterDelete.templates.count == 6, "remaining templates survive")
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
