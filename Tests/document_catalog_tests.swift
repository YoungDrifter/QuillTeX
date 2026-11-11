import Foundation

@main
struct DocumentCatalogTests {
    @MainActor static func main() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("QuillTeX-catalog-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: base) }
        try fm.createDirectory(at: base, withIntermediateDirectories: true)

        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            guard condition() else { fatalError("FAILED: \(message)") }
            checks += 1
        }
        func expectFailure(_ message: String, _ body: () throws -> Void) -> Error? {
            do {
                try body()
                fatalError("FAILED: \(message)")
            } catch {
                checks += 1
                return error
            }
        }
        func writeDocument(_ name: String, in directory: URL, contents: String = "source") throws -> URL {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent(name)
            try contents.write(to: url, atomically: true, encoding: .utf8)
            return url
        }

        // MARK: - Init, storage location, empty state

        let dataDirectory = base.appendingPathComponent("data", isDirectory: true)
        let catalog = DocumentCatalog(directory: dataDirectory)
        check(catalog.entries.isEmpty, "catalog initializes empty")
        check(catalog.folders.isEmpty, "catalog initializes without folders")
        check(catalog.storageError == nil, "catalog initializes without a storage error")
        check(catalog.storageURL.lastPathComponent == "DocumentCatalog.json", "snapshot uses the fixed file name")
        check(catalog.storageURL.deletingLastPathComponent().standardizedFileURL == dataDirectory.standardizedFileURL,
              "snapshot lives in the catalog directory")
        check(fm.fileExists(atPath: dataDirectory.path), "catalog creates its directory on init")
        check(!fm.fileExists(atPath: catalog.storageURL.path), "catalog does not write before a mutation")

        // MARK: - Linking, deduplication, display names

        let documents = base.appendingPathComponent("documents", isDirectory: true)
        let alpha = try writeDocument("alpha.tex", in: documents)
        let alphaEntry = try catalog.link(alpha)
        check(catalog.entries.count == 1, "link inserts an entry")
        check(alphaEntry.displayName == "alpha", "link derives the display name from the file stem")
        check(alphaEntry.kind == .file, "an ordinary .tex file links as a file")
        check(alphaEntry.folderID == nil && alphaEntry.tags.isEmpty && !alphaEntry.starred,
              "a new entry starts unsorted, untagged and unstarred")
        check(alphaEntry.updatedAt != nil, "link records the file modification date")
        check(alphaEntry.createdOnDiskAt != nil, "link records the on-disk creation date")
        check(fm.fileExists(atPath: catalog.storageURL.path), "link persists a snapshot")

        let explicitName = try catalog.link(alpha, displayName: "Alpha Draft")
        check(catalog.entries.count == 1, "relinking the same path does not duplicate")
        check(explicitName.id == alphaEntry.id, "relinking keeps the entry identity")
        check(explicitName.addedAt == alphaEntry.addedAt, "relinking keeps the date added")
        check(explicitName.displayName == "Alpha Draft", "relinking refreshes the display name")
        check(explicitName.lastViewedAt == alphaEntry.lastViewedAt, "relinking does not mark the entry as viewed")

        let messyPath = documents
            .appendingPathComponent("nested", isDirectory: true)
            .appendingPathComponent("..", isDirectory: true)
            .appendingPathComponent("alpha.tex")
        let standardizedLink = try catalog.link(messyPath)
        check(catalog.entries.count == 1, "standardized paths deduplicate")
        check(standardizedLink.id == alphaEntry.id, "standardized relink keeps identity")
        check(standardizedLink.displayName == "alpha", "relinking without a name restores the derived name")

        let missingError = expectFailure("linking a missing file throws") {
            _ = try catalog.link(documents.appendingPathComponent("does-not-exist.tex"))
        }
        check(missingError?.localizedDescription.contains("could not be found") == true,
              "a missing-file error has a readable description")

        // MARK: - Star, tags, rename

        catalog.setStarred(alphaEntry.id, true)
        check(catalog.entry(id: alphaEntry.id)?.starred == true, "setStarred updates the entry")
        check(catalog.starredEntries.count == 1, "starredEntries reflects the star")
        catalog.toggleStar(alphaEntry.id)
        check(catalog.entry(id: alphaEntry.id)?.starred == false, "toggleStar clears the star")
        check(catalog.starredEntries.isEmpty, "starredEntries drops the unstarred entry")

        let persistedCatalog = DocumentCatalog(directory: dataDirectory)
        check(persistedCatalog.entries.count == 1, "entries persist across instances")
        check(persistedCatalog.entries.first?.id == alphaEntry.id, "entry identity persists")
        check(persistedCatalog.entries.first?.displayName == "alpha", "display name persists")

        try catalog.setTags(alphaEntry.id, tags: ["  Draft ", "draft", "Research", "", "   "])
        check(catalog.entry(id: alphaEntry.id)?.tags == ["Draft", "Research"],
              "setTags trims, drops empty values and deduplicates case-insensitively")

        let beta = try writeDocument("beta.tex", in: documents)
        let betaEntry = try catalog.link(beta)
        try catalog.setTags(betaEntry.id, tags: ["Research", "Notes"])
        let tags = catalog.allTags
        check(tags.count == 3, "allTags is unique across entries")
        check(Set(tags.map { $0.lowercased() }) == Set(["draft", "research", "notes"]),
              "allTags keeps every distinct tag")
        check(zip(tags, tags.dropFirst()).allSatisfy { $0.localizedStandardCompare($1) == .orderedAscending },
              "allTags is sorted")

        try catalog.setTags(betaEntry.id, tags: ["zeta", "Alpha", "beta"])
        let sortedTags = catalog.entry(id: betaEntry.id)!.tags
        check(sortedTags.count == 3, "tags keep all distinct values")
        check(Set(sortedTags) == Set(["Alpha", "beta", "zeta"]), "tags keep the first spelling")
        check(zip(sortedTags, sortedTags.dropFirst()).allSatisfy { $0.localizedStandardCompare($1) == .orderedAscending },
              "tags are sorted")

        try catalog.rename(alphaEntry.id, to: "  Main Draft ")
        check(catalog.entry(id: alphaEntry.id)?.displayName == "Main Draft", "rename trims and updates the display name")
        check(fm.fileExists(atPath: alpha.path), "rename does not rename the file on disk")
        _ = expectFailure("renaming to an empty name throws") {
            try catalog.rename(alphaEntry.id, to: "   ")
        }
        check(catalog.entry(id: alphaEntry.id)?.displayName == "Main Draft", "a failed rename keeps the previous name")

        // MARK: - Missing files and unlink

        let doomedFile = try writeDocument("gone.tex", in: documents)
        let doomedEntry = try catalog.link(doomedFile)
        check(!catalog.isMissing(doomedEntry), "linked files are not missing")
        try fm.removeItem(at: doomedFile)
        check(catalog.isMissing(doomedEntry), "isMissing reports a deleted file")
        catalog.refreshMetadata()
        check(catalog.entry(id: doomedEntry.id) != nil, "refreshMetadata never prunes missing files")
        catalog.removeEntry(doomedEntry.id)
        check(catalog.entry(id: doomedEntry.id) == nil, "a missing entry can still be unlinked")

        let keepFile = try writeDocument("keep.tex", in: documents)
        let keepEntry = try catalog.link(keepFile)
        catalog.removeEntry(keepEntry.id)
        check(catalog.entry(id: keepEntry.id) == nil, "removeEntry unlinks the entry")
        check(fm.fileExists(atPath: keepFile.path), "removeEntry leaves the file on disk")
        check(catalog.entries.count == 2, "removeEntry refreshes the published entries")

        // MARK: - Folders

        let papers = try catalog.createFolder(named: "Papers")
        check(catalog.folders.count == 1, "createFolder adds a folder")
        check(papers.name == "Papers", "a folder keeps the given name")
        _ = expectFailure("duplicate folder names are rejected") {
            _ = try catalog.createFolder(named: "papers")
        }
        _ = expectFailure("empty folder names are rejected") {
            _ = try catalog.createFolder(named: "   ")
        }

        try catalog.renameFolder(papers.id, to: "Articles")
        check(catalog.folder(id: papers.id)?.name == "Articles", "renameFolder updates the folder")
        _ = expectFailure("renaming a folder to an empty name fails") {
            try catalog.renameFolder(papers.id, to: "  ")
        }
        _ = expectFailure("renaming an unknown folder fails") {
            try catalog.renameFolder(UUID(), to: "Ghost")
        }

        catalog.setFolder(alphaEntry.id, folderID: papers.id)
        check(catalog.entry(id: alphaEntry.id)?.folderID == papers.id, "setFolder moves the entry")
        check(catalog.entries(inFolder: papers.id).count == 1, "entries(inFolder:) returns folder members")
        check(catalog.unsortedEntries.count == 1, "unsortedEntries excludes filed entries")

        let folderReload = DocumentCatalog(directory: dataDirectory)
        check(folderReload.folder(id: papers.id)?.name == "Articles", "folders persist across instances")
        check(folderReload.entry(id: alphaEntry.id)?.folderID == papers.id, "folder membership persists")

        let coloredFolder = try catalog.createFolder(named: "Colored Test", color: .green)
        check(coloredFolder.color == .green, "createFolder stores the chosen accent")
        check(catalog.folder(id: papers.id)?.color == nil, "folders keep the default accent until one is chosen")
        catalog.setFolderColor(coloredFolder.id, color: .purple)
        check(catalog.folder(id: coloredFolder.id)?.color == .purple, "setFolderColor updates the accent")
        let colorReload = DocumentCatalog(directory: dataDirectory)
        check(colorReload.folder(id: coloredFolder.id)?.color == .purple, "folder accents persist across instances")
        catalog.setFolderColor(coloredFolder.id, color: nil)
        check(catalog.folder(id: coloredFolder.id)?.color == nil, "folder accent can be reset to the default")
        catalog.deleteFolder(coloredFolder.id)

        catalog.setFolder(alphaEntry.id, folderID: UUID())
        check(catalog.entry(id: alphaEntry.id)?.folderID == nil, "setFolder falls back to Unsorted for unknown folders")
        check(catalog.unsortedEntries.count == 2, "unknown folder places the entry in Unsorted")
        check(catalog.entries(in: .folder(nil)) == catalog.unsortedEntries, "the nil folder selection is Unsorted")

        catalog.setFolder(alphaEntry.id, folderID: papers.id)
        catalog.deleteFolder(papers.id)
        check(catalog.folder(id: papers.id) == nil, "deleteFolder removes the folder")
        check(catalog.entry(id: alphaEntry.id)?.folderID == nil, "entries of a deleted folder fall back to Unsorted")
        check(catalog.unsortedEntries.count == 2, "deleted-folder entries join Unsorted")

        // MARK: - Selection queries

        catalog.setStarred(alphaEntry.id, true)
        check(catalog.entries(in: .all).count == catalog.entries.count, "the all selection returns every entry")
        check(catalog.entries(in: .starred).map(\.id) == [alphaEntry.id], "the starred selection returns starred entries")
        try catalog.setTags(betaEntry.id, tags: ["Draft", "Notes"])
        check(catalog.entries(in: .tag("Draft")).count == 2, "the tag selection matches entries")
        check(catalog.entries(in: .tag("draft")).count == 2, "the tag selection ignores letter case")
        check(catalog.entries(in: .folder(papers.id)).isEmpty, "a deleted folder selects nothing")
        check(catalog.allTags.filter { $0.caseInsensitiveCompare("Draft") == .orderedSame }.count == 1,
              "allTags deduplicates the same tag from different entries")

        // MARK: - Main files and project entries

        check(catalog.entry(forMainFile: alpha)?.id == alphaEntry.id, "entry(forMainFile:) finds a linked file")
        check(catalog.entry(forMainFile: messyPath)?.id == alphaEntry.id, "entry(forMainFile:) standardizes the path")

        let projectFolder = base.appendingPathComponent("projects/My Paper", isDirectory: true)
        let mainFile = try writeDocument("main.tex", in: projectFolder)
        let projectEntry = try catalog.link(mainFile)
        check(projectEntry.kind == .project, "main.tex links as a project")
        check(projectEntry.displayName == "My Paper", "a project entry uses the parent folder name")
        let chapterFile = try writeDocument("chapter.tex", in: projectFolder)
        let chapterEntry = try catalog.link(chapterFile)
        check(chapterEntry.kind == .file && chapterEntry.displayName == "chapter",
              "other .tex files inside a project folder link as files")

        let finalCatalog = DocumentCatalog(directory: dataDirectory)
        check(finalCatalog.entries.count == 4, "the complete catalog persists")
        check(finalCatalog.folders.isEmpty, "folder deletion persists")
        check(finalCatalog.entry(id: alphaEntry.id)?.starred == true, "stars persist")
        check(finalCatalog.entry(id: projectEntry.id)?.kind == .project, "project kinds persist")
        check(finalCatalog.entry(id: alphaEntry.id)?.displayName == "Main Draft", "renamed display names persist")

        // MARK: - Date grouping

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = calendar.date(from: DateComponents(year: 2027, month: 6, day: 15, hour: 12))!
        func morning(_ daysAgo: Int, hour: Int = 9) -> Date {
            let day = calendar.date(byAdding: .day, value: -daysAgo, to: calendar.startOfDay(for: now))!
            return calendar.date(byAdding: .hour, value: hour, to: day)!
        }
        let todayA = LibraryEntry(path: "/seeded/today-a.tex", displayName: "Today A",
                                  addedAt: morning(0, hour: 8), updatedAt: morning(0, hour: 8))
        let todayB = LibraryEntry(path: "/seeded/today-b.tex", displayName: "Today B",
                                  addedAt: morning(0, hour: 10), updatedAt: morning(0, hour: 10))
        let yesterday = LibraryEntry(path: "/seeded/yesterday.tex", displayName: "Yesterday",
                                     addedAt: morning(1), updatedAt: morning(1))
        let lastWeek = LibraryEntry(path: "/seeded/last-week.tex", displayName: "Last Week",
                                    addedAt: morning(3), updatedAt: morning(3))
        let lastMonth = LibraryEntry(path: "/seeded/last-month.tex", displayName: "Last Month",
                                     addedAt: morning(10), updatedAt: morning(10))
        let earlier = LibraryEntry(path: "/seeded/earlier.tex", displayName: "Earlier",
                                   addedAt: morning(40), updatedAt: morning(0, hour: 23))
        let seededEntries = [todayA, yesterday, todayB, lastWeek, lastMonth, earlier]
        let seededDirectory = base.appendingPathComponent("seeded", isDirectory: true)
        try fm.createDirectory(at: seededDirectory, withIntermediateDirectories: true)
        let seedEncoder = JSONEncoder()
        seedEncoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try seedEncoder.encode(LibrarySnapshot(version: 1, folders: [], entries: seededEntries))
            .write(to: seededDirectory.appendingPathComponent("DocumentCatalog.json"), options: .atomic)
        let seededCatalog = DocumentCatalog(directory: seededDirectory)
        check(seededCatalog.entries.map(\.displayName) == ["Today A", "Yesterday", "Today B", "Last Week", "Last Month", "Earlier"],
              "a seeded snapshot loads in order")

        let groups = seededCatalog.grouped(seededCatalog.entries, now: now, calendar: calendar)
        check(groups.map(\.title) == ["Today", "Yesterday", "Last 7 Days", "Last 30 Days", "Earlier"],
              "date groups use the expected titles")
        check(groups.count == 5, "only non-empty date groups are returned")
        check(groups[0].entries.map(\.displayName) == ["Today A", "Today B"], "the Today group preserves input order")
        check(groups[1].entries.map(\.displayName) == ["Yesterday"], "Yesterday groups by calendar day")
        check(groups[2].entries.map(\.displayName) == ["Last Week"], "Last 7 Days holds the previous week")
        check(groups[3].entries.map(\.displayName) == ["Last Month"], "Last 30 Days holds the previous month")
        check(groups[4].entries.map(\.displayName) == ["Earlier"], "Earlier holds everything older")
        let todayOnly = seededCatalog.grouped([todayA], now: now, calendar: calendar)
        check(todayOnly.map(\.title) == ["Today"], "empty groups are omitted")

        check(seededCatalog.sorted(seededCatalog.entries, by: .name).first?.displayName == "Earlier",
              "name sorting is ascending")
        check(seededCatalog.sorted(seededCatalog.entries, by: .name).last?.displayName == "Yesterday",
              "name sorting keeps every entry")
        check(seededCatalog.sorted(seededCatalog.entries, by: .created).first?.displayName == "Today B",
              "created sorting is newest first")
        check(seededCatalog.sorted(seededCatalog.entries, by: .updated).first?.displayName == "Earlier",
              "updated sorting uses the modification date")

        // MARK: - One-time migration from the previous recent-documents list

        let migrationDirectory = base.appendingPathComponent("migration", isDirectory: true)
        try fm.createDirectory(at: migrationDirectory, withIntermediateDirectories: true)
        let legacyDocuments = base.appendingPathComponent("legacy-documents", isDirectory: true)
        let legacyOne = try writeDocument("old-one.tex", in: legacyDocuments, contents: "one")
        let legacyTwo = try writeDocument("old-two.tex", in: legacyDocuments, contents: "two")
        let firstOpened = Date(timeIntervalSince1970: 1_700_000_000)
        let secondOpened = Date(timeIntervalSince1970: 1_600_000_000)
        let legacyJSON = """
        [
          {"path": "\(legacyOne.standardizedFileURL.path)", "openedAt": \(firstOpened.timeIntervalSinceReferenceDate)},
          {"path": "\(legacyTwo.standardizedFileURL.path)", "openedAt": \(secondOpened.timeIntervalSinceReferenceDate)},
          {"path": "\(legacyOne.standardizedFileURL.path)", "openedAt": \(firstOpened.timeIntervalSinceReferenceDate)}
        ]
        """
        try legacyJSON.write(to: migrationDirectory.appendingPathComponent("RecentDocuments.json"),
                             atomically: true, encoding: .utf8)
        check(!fm.fileExists(atPath: migrationDirectory.appendingPathComponent("DocumentCatalog.json").path),
              "migration starts without a catalog snapshot")
        let migrated = DocumentCatalog(directory: migrationDirectory)
        check(migrated.storageError == nil, "migration succeeds without a storage error")
        check(migrated.entries.count == 2, "migration deduplicates standardized paths")
        check(migrated.entries.allSatisfy { $0.kind == .file }, "migrated entries are file links")
        check(migrated.entries.allSatisfy { $0.tags.isEmpty && !$0.starred && $0.folderID == nil },
              "migrated entries start unsorted, untagged and unstarred")
        check(migrated.entries.map(\.displayName) == ["old-one", "old-two"], "migrated names are file stems")
        check(migrated.entries.first.map { abs($0.addedAt.timeIntervalSince(firstOpened)) < 0.001 } == true,
              "migration keeps the open date as the added date")
        check(migrated.entries.first.map { abs($0.lastViewedAt.timeIntervalSince(firstOpened)) < 0.001 } == true,
              "migration keeps the open date as the last viewed date")
        check(fm.fileExists(atPath: migrated.storageURL.path), "migration persists the migrated snapshot")
        let migratedAgain = DocumentCatalog(directory: migrationDirectory)
        check(migratedAgain.entries.count == 2, "migration runs only once")

        // MARK: - Corrupt snapshot behaviour

        let corruptDirectory = base.appendingPathComponent("corrupt", isDirectory: true)
        try fm.createDirectory(at: corruptDirectory, withIntermediateDirectories: true)
        let corruptURL = corruptDirectory.appendingPathComponent("DocumentCatalog.json")
        let corruptBytes = Data("this is not a catalog".utf8)
        try corruptBytes.write(to: corruptURL, options: .atomic)
        let corruptCatalog = DocumentCatalog(directory: corruptDirectory)
        check(corruptCatalog.storageError != nil, "a corrupt snapshot reports a storage error")
        check(corruptCatalog.entries.isEmpty && corruptCatalog.folders.isEmpty, "a corrupt snapshot keeps memory empty")
        let corruptLinkError = expectFailure("linking against a corrupt snapshot throws") {
            _ = try corruptCatalog.link(alpha)
        }
        check((corruptLinkError as? NSError)?.code == CocoaError.Code.fileReadCorruptFile.rawValue,
              "corrupt mutating calls throw CocoaError.fileReadCorruptFile")
        _ = expectFailure("creating a folder against a corrupt snapshot throws") {
            _ = try corruptCatalog.createFolder(named: "Nope")
        }
        corruptCatalog.refreshMetadata()
        corruptCatalog.removeEntry(alphaEntry.id)
        let preservedBytes = try Data(contentsOf: corruptURL)
        check(preservedBytes == corruptBytes, "mutations never overwrite a corrupt snapshot")
        check(corruptCatalog.entries.isEmpty, "a corrupt snapshot stays empty after non-throwing mutations")

        // MARK: - LibraryDocumentCreator

        check(LibraryDocumentCreator.sanitizedName("  My Paper  ") == "My Paper", "sanitize trims outer whitespace")
        check(LibraryDocumentCreator.sanitizedName("   ") == "Untitled", "sanitize replaces a blank name")
        check(LibraryDocumentCreator.sanitizedName("") == "Untitled", "sanitize replaces an empty name")
        check(LibraryDocumentCreator.sanitizedName("a/b:c") == "a-b-c", "sanitize replaces separators")
        check(LibraryDocumentCreator.sanitizedName("a\u{0}b") == "a-b", "sanitize replaces NUL")
        check(LibraryDocumentCreator.sanitizedName("...note") == "note", "sanitize strips leading dots")
        check(LibraryDocumentCreator.sanitizedName("note...") == "note", "sanitize strips trailing dots")
        check(LibraryDocumentCreator.sanitizedName("note. .  ") == "note", "sanitize collapses trailing dots and spaces")
        check(LibraryDocumentCreator.sanitizedName("...") == "Untitled", "sanitize falls back for dot-only names")
        let longName = LibraryDocumentCreator.sanitizedName(String(repeating: "a", count: 200))
        check(longName.count == 120, "sanitize caps the name at 120 characters")

        let newDocuments = base.appendingPathComponent("new-documents", isDirectory: true)
        let createdMain = try LibraryDocumentCreator.create(
            named: "Paper/A:One", templateSource: "\\documentclass{article}\n中文内容\n", in: newDocuments)
        check(fm.fileExists(atPath: createdMain.path), "create writes the main file")
        check(createdMain.lastPathComponent == "Paper-A-One.tex", "the main file is named after the folder")
        check(createdMain.deletingLastPathComponent().lastPathComponent == "Paper-A-One", "create makes a same-named folder")
        let createdSource = try String(contentsOf: createdMain, encoding: .utf8)
        check(createdSource == "\\documentclass{article}\n中文内容\n", "create writes the template source as UTF-8")

        let secondMain = try LibraryDocumentCreator.create(
            named: "Paper/A:One", templateSource: "second", in: newDocuments)
        check(secondMain.deletingLastPathComponent().lastPathComponent == "Paper-A-One 2",
              "a colliding document name gets a numeric suffix")
        check(fm.fileExists(atPath: createdMain.path), "a colliding create does not overwrite the first document")

        let existingFolder = newDocuments.appendingPathComponent("Existing", isDirectory: true)
        try fm.createDirectory(at: existingFolder, withIntermediateDirectories: true)
        let marker = existingFolder.appendingPathComponent("marker.txt")
        try "keep".write(to: marker, atomically: true, encoding: .utf8)
        let existingMain = try LibraryDocumentCreator.create(named: "Existing", templateSource: "existing", in: newDocuments)
        check(existingMain.deletingLastPathComponent().lastPathComponent == "Existing 2",
              "an existing folder is not overwritten")
        check(fm.fileExists(atPath: marker.path), "an existing folder keeps its contents")

        let untitledMain = try LibraryDocumentCreator.create(named: "   ", templateSource: "", in: newDocuments)
        check(untitledMain.deletingLastPathComponent().lastPathComponent == "Untitled", "a blank name creates Untitled")
        let nestedMain = try LibraryDocumentCreator.create(
            named: "Deep", templateSource: "x", in: base.appendingPathComponent("nested/deep", isDirectory: true))
        check(fm.fileExists(atPath: nestedMain.path), "create makes intermediate directories")

        // MARK: - LibraryPreferences

        let suiteName = "QuillTeX-catalog-tests-\(UUID().uuidString)"
        guard let testDefaults = UserDefaults(suiteName: suiteName) else {
            fatalError("FAILED: could not create an isolated UserDefaults suite")
        }
        defer { testDefaults.removePersistentDomain(forName: suiteName) }
        let preferences = LibraryPreferences(defaults: testDefaults)
        check(preferences.newDocumentDirectory.standardizedFileURL == LibraryPreferences.defaultDirectory.standardizedFileURL,
              "preferences default to the Documents/QuillTeX directory")
        check(LibraryPreferences.defaultDirectory.lastPathComponent == "QuillTeX", "the default directory is named QuillTeX")
        check(LibraryPreferences.defaultDirectory.deletingLastPathComponent().lastPathComponent == "Documents",
              "the default directory lives in Documents")
        let chosenDirectory = base.appendingPathComponent("chosen-documents", isDirectory: true)
        preferences.setDirectory(chosenDirectory)
        check(testDefaults.string(forKey: "quilltex.newDocumentDirectory") == chosenDirectory.path,
              "setDirectory persists the chosen path")
        let reloadedPreferences = LibraryPreferences(defaults: testDefaults)
        check(reloadedPreferences.newDocumentDirectory.standardizedFileURL == chosenDirectory.standardizedFileURL,
              "preferences reload the stored path")
        reloadedPreferences.resetToDefault()
        check(testDefaults.string(forKey: "quilltex.newDocumentDirectory") == nil, "resetToDefault clears the stored path")
        check(reloadedPreferences.newDocumentDirectory.standardizedFileURL == LibraryPreferences.defaultDirectory.standardizedFileURL,
              "resetToDefault returns the default path")

        print("PASS: \(checks) document-catalog assertions")
    }
}
