import SwiftUI
import AppKit
import PDFKit

// MARK: - Library appearance

/// Measurements shared by the library sidebar and the All Documents browser. The
/// browser follows the reference's large, airy rows; the sidebar stays on the
/// compact side so it works from 180 pt upwards.
private enum LibraryLook {
    static let sidebarRowHeight: CGFloat = 30
    static let sidebarCorner: CGFloat = 7
    /// Extra indent for a folder's documents: they read as children of the
    /// folder's name instead of lining up with another folder row.
    static let sidebarDocumentIndent: CGFloat = 44
    /// One nesting step for subfolders and for documents one level deeper.
    static let sidebarIndentStep: CGFloat = 18
    static let browserInset: CGFloat = 24
    static let dateColumnWidth: CGFloat = 96
    static let rowActionsWidth: CGFloat = 58
    static let browserRowHeight: CGFloat = 64
    static let docTileSize = CGSize(width: 32, height: 40)
    static let folderTints: [Color] = [.blue, .pink, .orange, .gray]
    /// Browser rows and cards only take a transient hover wash. Which documents
    /// are open is already visible in the tab strip, so nothing stays highlighted
    /// in the library after the pointer leaves a row.
    static let hoverWash: Double = 0.04
}

extension LibraryFolderColor {
    var tint: Color {
        switch self {
        case .blue: .blue
        case .pink: .pink
        case .orange: .orange
        case .gray: .gray
        case .green: .green
        case .purple: .purple
        }
    }

    var nsColor: NSColor {
        switch self {
        case .blue: .systemBlue
        case .pink: .systemPink
        case .orange: .systemOrange
        case .gray: .systemGray
        case .green: .systemGreen
        case .purple: .systemPurple
        }
    }

    /// Small filled circle used by the New Folder colour popup.
    var swatch: NSImage {
        let image = NSImage(size: NSSize(width: 12, height: 12))
        image.lockFocus()
        nsColor.setFill()
        NSBezierPath(ovalIn: NSRect(x: 1, y: 1, width: 10, height: 10)).fill()
        image.unlockFocus()
        return image
    }
}

/// A stable key for the folder list: the built-in Unsorted group plus user folders.
private enum LibraryFolderKey: Hashable {
    case unsorted
    case folder(UUID)
}

/// Browser presentation. The list is the reference layout; the grid is the
/// compact alternative behind the view control.
private enum LibraryViewMode: String, CaseIterable, Identifiable {
    case list
    case grid
    var id: String { rawValue }
    var icon: String { self == .list ? "list.bullet" : "square.grid.2x2" }
    var title: String { self == .list ? "List" : "Grid" }
}

// MARK: - Formatting helpers

private enum LibraryDateText {
    static let time: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
    static let monthDay: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMM d")
        return formatter
    }()
    static let monthDayYear: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMM d yyyy")
        return formatter
    }()

    /// Deliberately mirrors the reference columns: a clock time for today, hours
    /// for the last day, then day counts, then a short date.
    static func short(_ date: Date?, now: Date = Date(), calendar: Calendar = .current) -> String {
        guard let date else { return "—" }
        if calendar.isDateInToday(date) { return time.string(from: date) }
        let seconds = now.timeIntervalSince(date)
        if seconds >= 0, seconds < 24 * 60 * 60 {
            let hours = max(1, Int(seconds / 3600))
            return hours == 1 ? "1 hour ago" : "\(hours) hours ago"
        }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date),
                                           to: calendar.startOfDay(for: now)).day ?? 0
        if days >= 2, days < 7 { return "\(days) days ago" }
        if calendar.component(.year, from: date) == calendar.component(.year, from: now) {
            return monthDay.string(from: date)
        }
        return monthDayYear.string(from: date)
    }
}

private enum LibraryPathText {
    static func abbreviated(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + String(path.dropFirst(home.count)) }
        return path
    }
}

/// The single date column tied to the active sort. Sorting by name shows none.
private enum LibraryDateColumn {
    case lastViewed, added, updated, created

    var title: String {
        switch self {
        case .lastViewed: "Last Viewed"
        case .added: "Added"
        case .updated: "Updated"
        case .created: "Created"
        }
    }

    func value(_ entry: LibraryEntry) -> Date {
        switch self {
        case .lastViewed: entry.lastViewedAt
        case .added: entry.addedAt
        case .updated: entry.updatedAt ?? entry.addedAt
        case .created: entry.createdOnDiskAt ?? entry.addedAt
        }
    }
}

/// One shared sort menu for documents and templates.
private struct LibrarySortMenu: View {
    @Binding var sort: LibrarySortOrder
    @Binding var ascending: Bool
    var showsAdded = true
    @State private var hovered = false

    var body: some View {
        Menu {
            Section("Sort By") {
                ForEach(orders) { order in
                    let active = sort == order
                    Toggle(isOn: Binding(
                        get: { active },
                        set: { on in
                            if active {
                                ascending.toggle()
                            } else if on {
                                sort = order
                                ascending = false
                            }
                        })) {
                        Text(order.title + (active ? (ascending ? "  ↑" : "  ↓") : ""))
                    }
                }
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Palette.primaryInk)
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Palette.primaryInk.opacity(hovered ? 0.06 : 0)))
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .onHover { hovered = $0 }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .modifier(LibraryControlSurface())
        .help("Sort")
        .accessibilityLabel("Sort, \(sort.title), \(ascending ? "ascending" : "descending")")
    }

    private var orders: [LibrarySortOrder] {
        showsAdded ? [.name, .lastViewed, .added, .created, .updated]
                   : [.name, .lastViewed, .created, .updated]
    }
}

/// One shared column header for documents and templates.
private struct LibraryTableHeader: View {
    @Binding var sort: LibrarySortOrder
    @Binding var ascending: Bool
    var trailingWidth: CGFloat = 0
    var showsAdded = true
    var inset: CGFloat = LibraryLook.browserInset

    var body: some View {
        HStack(spacing: 0) {
            button("Name", order: .name)
                .frame(maxWidth: .infinity, alignment: .leading)
            button("Last Viewed", order: .lastViewed)
                .frame(width: LibraryLook.dateColumnWidth, alignment: .leading)
            if showsAdded {
                button("Added", order: .added)
                    .frame(width: LibraryLook.dateColumnWidth, alignment: .leading)
            }
            button("Updated", order: .updated)
                .frame(width: LibraryLook.dateColumnWidth, alignment: .leading)
            button("Created", order: .created)
                .frame(width: LibraryLook.dateColumnWidth, alignment: .leading)
            Color.clear.frame(width: trailingWidth)
        }
        .padding(.horizontal, inset)
        .frame(height: 28)
    }

    private func button(_ title: String, order: LibrarySortOrder) -> some View {
        Button {
            if sort == order {
                ascending.toggle()
            } else {
                sort = order
                ascending = false
            }
        } label: {
            HStack(spacing: 3) {
                Text(title)
                    .font(.system(size: 11, weight: sort == order ? .medium : .regular))
                    .foregroundStyle(sort == order ? Palette.primaryInk : Palette.secondaryInk)
                if sort == order {
                    Image(systemName: ascending ? "chevron.up" : "chevron.down")
                        .font(.system(size: 7, weight: .semibold))
                        .foregroundStyle(Palette.secondaryInk)
                }
            }
            .lineLimit(1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Sort by \(order.title)")
    }
}

/// One shared three-date cell row for documents and templates.
private struct LibraryDateColumns: View {
    let lastViewed: Date
    var added: Date? = nil
    let updated: Date
    let created: Date

    var body: some View {
        HStack(spacing: 0) {
            cell(lastViewed)
            if let added { cell(added) }
            cell(updated)
            cell(created)
        }
    }

    private func cell(_ date: Date) -> some View {
        Text(LibraryDateText.short(date))
            .font(.system(size: 11.5))
            .foregroundStyle(Palette.secondaryInk)
            .lineLimit(1)
            .frame(width: LibraryLook.dateColumnWidth, alignment: .leading)
    }
}

/// First-page PDF thumbnails for library rows. PDFs are read on a background queue
/// and cached by path plus modification date; nothing is generated here.
/// `NSCache` and the serial queue are both thread-safe, so the store can cross
/// the background load without further synchronisation.
private final class LibraryThumbnailStore: @unchecked Sendable {
    static let shared = LibraryThumbnailStore()
    private let cache = NSCache<NSString, NSImage>()
    private let queue = DispatchQueue(label: "QuillTeX.LibraryThumbnails", qos: .utility)

    private init() {
        cache.countLimit = 256
    }

    func thumbnail(for entry: LibraryEntry, size: NSSize) async -> NSImage? {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: Self.load(entry: entry, size: size, cache: self.cache))
            }
        }
    }

    private static func load(entry: LibraryEntry, size: NSSize,
                             cache: NSCache<NSString, NSImage>) -> NSImage? {
        guard let (url, key) = resolvePDF(for: entry) else { return nil }
        // The same PDF is requested at very different sizes (tiny row icon vs a
        // full gallery page); the cache key must include the size or a small
        // thumbnail would be stretched into a blurry large one.
        let sizedKey = "\(key)#\(Int(size.width))x\(Int(size.height))"
        if let cached = cache.object(forKey: sizedKey as NSString) { return cached }
        guard let document = PDFDocument(url: url), let page = document.page(at: 0) else { return nil }
        let image = page.thumbnail(of: size, for: .cropBox)
        cache.setObject(image, forKey: sizedKey as NSString)
        return image
    }

    /// The staged compiled PDF for a library entry, if one exists.
    static func pdfURL(for entry: LibraryEntry) -> URL? {
        resolvePDF(for: entry)?.0
    }

    /// The compiled PDF usually sits next to the main .tex; also accept a
    /// same-named PDF in the document folder, its parent, or the build folder.
    private static func resolvePDF(for entry: LibraryEntry) -> (URL, String)? {
        var seen = Set<String>()
        for url in candidates(for: entry) {
            let path = url.standardizedFileURL.path
            guard seen.insert(path).inserted else { continue }
            guard FileManager.default.fileExists(atPath: path) else { continue }
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate?.timeIntervalSince1970 ?? 0
            return (url, "\(path)#\(modified)")
        }
        return nil
    }

    private static func candidates(for entry: LibraryEntry) -> [URL] {
        let stem = entry.url.deletingPathExtension().lastPathComponent
        let sibling = entry.url.deletingPathExtension().appendingPathExtension("pdf")
        let documentFolder = entry.folderURL.appendingPathComponent(stem).appendingPathExtension("pdf")
        let parentFolder = entry.folderURL.deletingLastPathComponent()
            .appendingPathComponent(stem).appendingPathExtension("pdf")
        let buildFolder = entry.folderURL.appendingPathComponent("build")
            .appendingPathComponent(stem).appendingPathExtension("pdf")
        return [sibling, documentFolder, parentFolder, buildFolder]
    }
}

/// Collects a document's compiled PDFs into a directory the user picks.
@MainActor
private enum LibraryPDFExporter {
    static func export(_ entries: [LibraryEntry]) {
        let unique = entries.reduce(into: [LibraryEntry]()) { result, entry in
            if !result.contains(where: { $0.id == entry.id }) { result.append(entry) }
        }
        guard !unique.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose where to save the exported PDFs."
        panel.prompt = "Export Here"
        guard panel.runModal() == .OK, let directory = panel.url else { return }

        var exported = 0
        var missing: [String] = []
        var failed: [String] = []
        for entry in unique {
            guard let pdf = LibraryThumbnailStore.pdfURL(for: entry) else {
                missing.append(entry.displayName)
                continue
            }
            do {
                let destination = availableDestination(named: entry.displayName + ".pdf", in: directory)
                try FileManager.default.copyItem(at: pdf, to: destination)
                exported += 1
            } catch {
                failed.append("\(entry.displayName): \(error.localizedDescription)")
            }
        }
        report(exported: exported, missing: missing, failed: failed)
    }

    private static func availableDestination(named name: String, in directory: URL) -> URL {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var destination = directory.appendingPathComponent(name)
        var suffix = 2
        while FileManager.default.fileExists(atPath: destination.path) {
            destination = directory.appendingPathComponent("\(base) \(suffix).\(ext)")
            suffix += 1
        }
        return destination
    }

    private static func report(exported: Int, missing: [String], failed: [String]) {
        if exported == 0 && missing.isEmpty && failed.isEmpty {
            QuillDialogCenter.shared.showAlert("Nothing to Export", "No documents were selected.")
            return
        }
        var lines: [String] = []
        if exported > 0 { lines.append("\(exported) PDF\(exported == 1 ? "" : "s") exported.") }
        if !missing.isEmpty {
            lines.append("No compiled PDF found for: \(missing.joined(separator: ", ")). Compile these documents first.")
        }
        if !failed.isEmpty { lines.append("Could not export: \(failed.joined(separator: "; "))") }
        QuillDialogCenter.shared.showAlert(exported > 0 ? "PDF Export Complete" : "No PDFs Exported",
                                           lines.joined(separator: "\n\n"))
    }
}

/// A 32 x 40 page thumbnail with the quiet tile outline; falls back to the
/// SF Symbol document tile when there is no PDF or it cannot be read.
struct LibraryDocumentThumbnail: View {
    let entry: LibraryEntry
    let size: CGSize
    var cornerRadius: CGFloat = 7

    @State private var image: NSImage?

    private var revision: String {
        "\(entry.path)#\(entry.updatedAt?.timeIntervalSince1970 ?? 0)"
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }

    var body: some View {
        ZStack {
            shape.fill(Color.white)
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFill()
            } else {
                shape.fill(Color.black.opacity(0.045))
                Image(systemName: "doc.text")
                    .font(.system(size: min(max(size.width * 0.42, 7), 13), weight: .regular))
                    .foregroundStyle(Palette.secondaryInk)
            }
            shape.strokeBorder(Palette.hairline, lineWidth: 0.6)
        }
        .frame(width: size.width, height: size.height)
        .clipShape(shape)
        .task(id: revision) {
            image = nil
            image = await LibraryThumbnailStore.shared.thumbnail(
                for: entry, size: NSSize(width: size.width * 2, height: size.height * 2))
        }
    }
}

@MainActor
private func libraryEntrySubtitle(_ entry: LibraryEntry, catalog: DocumentCatalog) -> String {
    // The title already carries the document name; the second line shows where the
    // document actually lives on disk, abbreviated to a readable ~ path.
    LibraryPathText.abbreviated(entry.folderURL.path)
}

// MARK: - Library dialogs

/// Name prompts and confirmations for the library. A native alert with a text
/// field keeps file-system actions out of the SwiftUI body.
@MainActor
private enum LibraryDialogs {
    static func deleteFolder(id: UUID, name: String, catalog: DocumentCatalog,
                             store: ProjectStore, onDeleted: @escaping () -> Void) {
        QuillDialogCenter.shared.showConfirm(title: "Delete “\(name)”?",
                                             message: "Documents move to Unsorted. Files stay on disk.",
                                             confirmTitle: "Delete",
                                             destructive: true,
                                             completion: { confirmed in
            guard confirmed else { return }
            catalog.deleteFolder(id)
            onDeleted()
        })
    }
}

// MARK: - Shared document context menu

@MainActor
@ViewBuilder
private func libraryEntryMenuContent(store: ProjectStore, catalog: DocumentCatalog,
                                     entry: LibraryEntry, onOpen: @escaping () -> Void) -> some View {
    Button("Open Document", action: onOpen)
    Button(entry.starred ? "Remove Star" : "Star Document") { catalog.toggleStar(entry.id) }
    Menu("Move to Folder") {
        Button {
            catalog.setFolder(entry.id, folderID: nil)
        } label: {
            if entry.folderID == nil {
                Label(DocumentCatalog.unsortedTitle, systemImage: "checkmark")
            } else {
                Text(DocumentCatalog.unsortedTitle)
            }
        }
        ForEach(catalog.foldersInTreeOrder(), id: \.folder.id) { item in
            Button {
                catalog.setFolder(entry.id, folderID: item.folder.id)
            } label: {
                let title = String(repeating: "    ", count: item.depth) + item.folder.name
                if entry.folderID == item.folder.id {
                    Label(title, systemImage: "checkmark")
                } else {
                    Text(title)
                }
            }
        }
    }
    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([entry.url]) }
    Button("Export PDF to Folder") { LibraryPDFExporter.export([entry]) }
    Divider()
    Button("Remove from Library", role: .destructive) { catalog.removeEntry(entry.id) }
}

private struct LibraryEntryContextMenu: ViewModifier {
    @ObservedObject var store: ProjectStore
    @ObservedObject var catalog: DocumentCatalog
    let entry: LibraryEntry
    let onOpen: () -> Void

    func body(content: Content) -> some View {
        content.contextMenu {
            libraryEntryMenuContent(store: store, catalog: catalog, entry: entry, onOpen: onOpen)
        }
    }
}

// MARK: - Sidebar

/// Page 1 of the window sidebar: the brand mark, New / Open, then the document
/// library. The shell owns the window controls, the page transition and the page
/// dots; this view only provides the page's content.
/// Drives window-level library dialogs so they float above the whole workspace
/// instead of running a nested modal loop inside a sidebar button action.
struct LibraryFolderDialogRequest: Identifiable {
    let id = UUID()
    var folderID: UUID?
    /// Folder that receives a newly created folder; nil creates a top-level one.
    var parentID: UUID?
    var name: String
    var color: LibraryFolderColor
}

@MainActor
final class LibraryDialogCenter: ObservableObject {
    static let shared = LibraryDialogCenter()
    @Published var folderDialog: LibraryFolderDialogRequest?
    @Published var createdFolderID: UUID?

    func presentNewFolder(color: LibraryFolderColor, parentID: UUID? = nil) {
        folderDialog = LibraryFolderDialogRequest(folderID: nil, parentID: parentID,
                                                  name: "", color: color)
    }

    func presentEdit(_ folder: LibraryFolder) {
        folderDialog = LibraryFolderDialogRequest(folderID: folder.id, parentID: folder.parentID,
                                                 name: folder.name, color: folder.color ?? .blue)
    }
}

struct NewFolderDialog: View {
    let catalog: DocumentCatalog
    let request: LibraryFolderDialogRequest
    let onDismiss: () -> Void

    @State private var name: String
    @State private var color: LibraryFolderColor
    @State private var errorMessage: String?
    @FocusState private var nameFocused: Bool

    init(catalog: DocumentCatalog, request: LibraryFolderDialogRequest, onDismiss: @escaping () -> Void) {
        self.catalog = catalog
        self.request = request
        self.onDismiss = onDismiss
        _name = State(initialValue: request.name)
        _color = State(initialValue: request.color)
    }

    private var editingID: UUID? { request.folderID }
    private var title: String { editingID == nil ? "New Folder" : "Edit Folder" }
    private var primaryTitle: String { editingID == nil ? "Create" : "Save" }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var duplicate: Bool {
        guard !trimmedName.isEmpty else { return false }
        return catalog.folders.contains {
            $0.id != editingID && $0.parentID == request.parentID
                && $0.name.caseInsensitiveCompare(trimmedName) == .orderedSame
        }
    }

    private var canCommit: Bool {
        !trimmedName.isEmpty && !duplicate
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                QuillDialogBackdrop()
                    .onTapGesture(perform: onDismiss)
                QuillDialogCard(title: title,
                                width: min(400, max(340, geometry.size.width * 0.66)),
                                close: onDismiss,
                                content: { form },
                                actions: [.primary(primaryTitle)],
                                onAction: { _ in commit() },
                                primaryEnabled: canCommit)
                    .accessibilityAddTraits(.isModal)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .onAppear { nameFocused = true }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 0) {
            QuillDialogFieldLabel("Name")
            QuillDialogField {
                TextField("Folder name", text: $name)
                    .textFieldStyle(.plain)
                    .focused($nameFocused)
                    .onSubmit(commit)
            }
            .padding(.top, 7)
            if duplicate {
                Text("Name already used.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Color.red)
                    .padding(.top, 5)
            } else if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Color.red)
                    .lineLimit(2)
                    .padding(.top, 5)
            }

            QuillDialogRow(label: "Color") {
                HStack(spacing: 6) {
                    ForEach(LibraryFolderColor.allCases) { option in
                        Button {
                            color = option
                        } label: {
                            Circle()
                                .fill(option.tint)
                                .frame(width: 18, height: 18)
                                .overlay {
                                    Circle().strokeBorder(color == option ? Palette.primaryInk : Color.clear,
                                                          lineWidth: 1.5)
                                }
                                .frame(width: 28, height: 28)
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .help(option.title)
                        .accessibilityLabel(option.title)
                        .accessibilityAddTraits(color == option ? .isSelected : [])
                    }
                }
            }
            .padding(.top, 16)
        }
    }

    private func commit() {
        guard canCommit else { return }
        do {
            if let editingID {
                try catalog.renameFolder(editingID, to: trimmedName)
                catalog.setFolderColor(editingID, color: color)
            } else {
                let folder = try catalog.createFolder(named: trimmedName, color: color,
                                                     parentID: request.parentID)
                LibraryDialogCenter.shared.createdFolderID = folder.id
            }
            onDismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct LibrarySidebarContent: View {
    @ObservedObject var store: ProjectStore
    @ObservedObject var catalog: DocumentCatalog
    var onNew: () -> Void
    var onOpen: () -> Void
    var onOpenEntry: (LibraryEntry) -> Void

    @State private var expandedFolders: Set<LibraryFolderKey> = [.unsorted]
    @State private var foldersExpanded = true
    @State private var didInitializeExpansion = false
    @ObservedObject private var dialogs = LibraryDialogCenter.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            brandRow
            actionRows
            divider
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
            ScrollView(.vertical) {
                navigation
            }
            .scrollIndicators(.automatic)
            divider
                .padding(.horizontal, 12)
            settingsRow
                .padding(.horizontal, 8)
                .padding(.top, 6)
                .padding(.bottom, 10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear(perform: expandAllFolders)
        .onChange(of: dialogs.createdFolderID) { _, id in
            guard let id else { return }
            withAnimation(reduceMotion ? nil : ChromeMotion.transition) {
                foldersExpanded = true
                // Reveal the new folder together with every containing folder.
                var reveal: UUID? = id
                while let folderID = reveal {
                    expandedFolders.insert(.folder(folderID))
                    reveal = catalog.folder(id: folderID)?.parentID
                }
            }
            dialogs.createdFolderID = nil
        }
    }

    private var divider: some View {
        Rectangle().fill(Palette.hairline).frame(height: 1)
    }

    private var brandRow: some View {
        HStack(spacing: 10) {
            Image("QuillTeXMark")
                .resizable()
                .interpolation(.high)
                .frame(width: 34, height: 34)
                .shadow(color: .black.opacity(0.08), radius: 2, y: 1)
            Text("QuillTeX")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Palette.primaryInk)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .frame(height: 54)
        .accessibilityElement(children: .combine)
    }

    private var actionRows: some View {
        VStack(spacing: 1) {
            sidebarAction("New Document", symbol: "doc.badge.plus") {
                store.openNewDocumentSheet(folderID: store.currentLibraryFolderID)
            }
            sidebarAction("Open Document", symbol: "folder", action: onOpen)
        }
        .padding(.horizontal, 8)
    }

    private func sidebarAction(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .light))
                    .frame(width: ChromeMetrics.sidebarIconWidth)
                Text(title)
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
            .frame(height: 32)
            .contentShape(Rectangle())
        }
        .buttonStyle(QuillRowButtonStyle(cornerRadius: LibraryLook.sidebarCorner))
        .help(title)
    }

    private var navigation: some View {
        VStack(alignment: .leading, spacing: 1) {
            navRow("All Documents", symbol: "list.bullet.rectangle", selection: .all)
            navRow("Templates", symbol: "square.on.square", selection: .templates)
            navRow("Starred", symbol: "star", selection: .starred)
            foldersHeader
                .padding(.top, 12)
            if foldersExpanded { folderList }
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func navRow(_ title: String, symbol: String, selection: LibrarySelection) -> some View {
        let selected = store.librarySelection == selection
        return Button {
            store.showLibrary(selection: selection, title: title)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .regular))
                    .frame(width: ChromeMetrics.sidebarIconWidth)
                Text(title)
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
            .frame(height: LibraryLook.sidebarRowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(QuillRowButtonStyle(selected: selected, cornerRadius: LibraryLook.sidebarCorner))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .help(title)
    }

    private var foldersHeader: some View {
        HStack(spacing: 4) {
            Text("Folders")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Palette.primaryInk)
            Spacer(minLength: 0)
            LibraryIconButton(symbol: "plus", label: "New Folder") {
                dialogs.presentNewFolder(color: LibraryFolderColor.allCases[catalog.folders.count % LibraryFolderColor.allCases.count])
            }
            LibraryIconButton(symbol: "chevron.down", label: foldersExpanded ? "Hide Folders" : "Show Folders",
                              rotation: .degrees(foldersExpanded ? 0 : -90)) {
                withAnimation(reduceMotion ? nil : ChromeMotion.transition) {
                    foldersExpanded.toggle()
                }
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, 2)
        .frame(height: 28)
    }

    private var folderList: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(folderNodes) { node in
                switch node.kind {
                case .folder(let item):
                    folderRow(item, depth: node.depth)
                case .document(let entry):
                    LibrarySidebarDocumentRow(
                        entry: entry,
                        indent: LibraryLook.sidebarDocumentIndent
                            + CGFloat(max(0, node.depth - 1)) * LibraryLook.sidebarIndentStep,
                        store: store, catalog: catalog,
                        onOpen: { onOpenEntry(entry) })
                }
            }
        }
    }

    /// Visible sidebar tree rows in depth-first order. Expanding a folder shows
    /// its subfolders first, then the documents filed directly inside it.
    private var folderNodes: [LibraryFolderNode] {
        var nodes: [LibraryFolderNode] = []
        nodes.append(LibraryFolderNode(id: "folder-unsorted", kind: .folder(.unsorted), depth: 0))
        if expandedFolders.contains(.unsorted) {
            for entry in catalog.unsortedEntries {
                nodes.append(LibraryFolderNode(id: "entry-\(entry.id)", kind: .document(entry), depth: 1))
            }
        }
        func append(_ folder: LibraryFolder, depth: Int) {
            nodes.append(LibraryFolderNode(id: "folder-\(folder.id)", kind: .folder(.folder(folder)), depth: depth))
            guard expandedFolders.contains(.folder(folder.id)) else { return }
            for child in catalog.childFolders(of: folder.id) { append(child, depth: depth + 1) }
            for entry in catalog.entries(inFolder: folder.id) {
                nodes.append(LibraryFolderNode(id: "entry-\(entry.id)", kind: .document(entry), depth: depth + 1))
            }
        }
        for folder in catalog.rootFolders { append(folder, depth: 0) }
        return nodes
    }

    @ViewBuilder
    private func folderRow(_ item: LibraryFolderItem, depth: Int) -> some View {
        switch item {
        case .unsorted:
            LibraryFolderRow(
                key: .unsorted,
                name: DocumentCatalog.unsortedTitle,
                symbol: "tray",
                tint: .gray,
                count: catalog.unsortedEntries.count,
                entries: catalog.unsortedEntries,
                hasChildren: !catalog.unsortedEntries.isEmpty,
                depth: depth,
                isSelected: store.librarySelection == .folder(nil),
                isExpanded: expandedFolders.contains(.unsorted),
                store: store,
                catalog: catalog,
                onSelect: {
                    store.showLibrary(selection: .folder(nil), title: DocumentCatalog.unsortedTitle)
                },
                onToggle: { toggleFolder(.unsorted) }
            )
        case .folder(let folder):
            let index = catalog.folders.firstIndex(where: { $0.id == folder.id }) ?? 0
            let entries = catalog.entries(inFolder: folder.id)
            LibraryFolderRow(
                key: .folder(folder.id),
                name: folder.name,
                symbol: "folder",
                tint: folder.color?.tint ?? LibraryLook.folderTints[index % LibraryLook.folderTints.count],
                count: entries.count,
                entries: entries,
                hasChildren: !entries.isEmpty || !catalog.childFolders(of: folder.id).isEmpty,
                depth: depth,
                isSelected: store.librarySelection == .folder(folder.id),
                isExpanded: expandedFolders.contains(.folder(folder.id)),
                store: store,
                catalog: catalog,
                onSelect: {
                    store.showLibrary(selection: .folder(folder.id), title: folder.name)
                },
                onToggle: { toggleFolder(.folder(folder.id)) }
            )
        }
    }

    private var settingsRow: some View {
        Button {
            store.openSettingsTab()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "gearshape")
                    .font(.system(size: 13, weight: .regular))
                    .frame(width: ChromeMetrics.sidebarIconWidth)
                Text("Settings")
                    .font(.system(size: 13))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
            .frame(height: LibraryLook.sidebarRowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(QuillRowButtonStyle(cornerRadius: LibraryLook.sidebarCorner))
        .help("Settings")
        .accessibilityLabel("Settings")
    }

    private func expandAllFolders() {
        // Only the first appearance expands everything; revisiting the page keeps
        // whatever the user collapsed.
        guard !didInitializeExpansion else { return }
        didInitializeExpansion = true
        var keys: Set<LibraryFolderKey> = [.unsorted]
        for folder in catalog.folders { keys.insert(.folder(folder.id)) }
        expandedFolders.formUnion(keys)
    }

    private func toggleFolder(_ key: LibraryFolderKey) {
        if reduceMotion {
            expandedFolders.formSymmetricDifference([key])
        } else {
            withAnimation(ChromeMotion.transition) {
                expandedFolders.formSymmetricDifference([key])
            }
        }
    }
}

private struct LibraryIconButton: View {
    let symbol: String
    let label: String
    var rotation: Angle = .zero
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .medium))
                .rotationEffect(rotation)
                .foregroundStyle(Palette.secondaryInk)
                .frame(width: 22, height: 22)
                .contentShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        }
        .buttonStyle(QuillRowButtonStyle(cornerRadius: 5))
        .help(label)
        .accessibilityLabel(label)
    }
}

/// Sidebar row for one folder. Child folders and documents are emitted by the
/// sidebar as separate depth-tagged rows, so nesting never has to recurse here.
private struct LibraryFolderRow: View {
    let key: LibraryFolderKey
    let name: String
    let symbol: String
    let tint: Color
    let count: Int
    let entries: [LibraryEntry]
    let hasChildren: Bool
    let depth: Int
    let isSelected: Bool
    let isExpanded: Bool
    @ObservedObject var store: ProjectStore
    @ObservedObject var catalog: DocumentCatalog
    var onSelect: () -> Void
    var onToggle: () -> Void

    @State private var hovered = false
    @State private var dropTargeted = false
    @ObservedObject private var dialogs = LibraryDialogCenter.shared

    private var folderID: UUID? {
        if case .folder(let id) = key { return id }
        return nil
    }

    @ViewBuilder
    var body: some View {
        if let folderID {
            rowCore.draggable(LibraryFolderDragPayload.string(for: folderID)) {
                HStack(spacing: 6) {
                    Image(systemName: "folder")
                    Text(name).lineLimit(1).truncationMode(.middle)
                }
                .font(.system(size: 12))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        } else {
            rowCore
        }
    }

    private var rowCore: some View {
        HStack(spacing: 0) {
            Button(action: onToggle) {
                QuillSidebarDisclosure(expanded: isExpanded)
                    .opacity(hasChildren ? 1 : 0)
            }
            .buttonStyle(.plain)
            .disabled(!hasChildren)
            .help(hasChildren ? (isExpanded ? "Collapse" : "Expand") : "")
            .accessibilityLabel(isExpanded ? "Collapse \(name)" : "Expand \(name)")

            Button(action: onSelect) {
                folderLabel
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
        }
        .padding(.leading, CGFloat(depth) * LibraryLook.sidebarIndentStep)
        .background {
            RoundedRectangle(cornerRadius: LibraryLook.sidebarCorner, style: .continuous)
                .fill(Palette.primaryInk.opacity(dropTargeted ? Palette.pressedOpacity
                                                             : (isSelected ? Palette.selectedOpacity
                                                                           : (hovered ? Palette.chromeHoverOpacity : 0))))
        }
        .contentShape(RoundedRectangle(cornerRadius: LibraryLook.sidebarCorner, style: .continuous))
        .overlay(alignment: .top) {
            if dropTargeted {
                Rectangle()
                    .fill(Color(nsColor: .controlAccentColor))
                    .frame(height: 2)
                    .padding(.leading, CGFloat(depth) * LibraryLook.sidebarIndentStep + 6)
                    .padding(.trailing, 6)
            }
        }
        .onHover { hovered = $0 }
        .dropDestination(for: String.self) { payloads, _ in
            var handled = false
            for payload in payloads {
                if let entryID = LibraryEntryDragPayload.entryID(from: payload),
                   let entry = catalog.entry(id: entryID) {
                    catalog.setFolder(entry.id, folderID: folderID)
                    handled = true
                } else if let draggedFolderID = LibraryFolderDragPayload.folderID(from: payload) {
                    // Dropping a folder onto another row orders it before that row;
                    // dropping on Unsorted moves it to the top level.
                    catalog.moveFolder(draggedFolderID, before: folderID)
                    handled = true
                }
            }
            return handled
        } isTargeted: { targeted in
            dropTargeted = targeted
        }
        .contextMenu {
            Button("Open Documents", action: onSelect)
            Button("New Document in This Folder") { store.openNewDocumentSheet(folderID: folderID) }
            if let folderID {
                Button("New Folder in This Folder") {
                    dialogs.presentNewFolder(
                        color: LibraryFolderColor.allCases[catalog.folders.count % LibraryFolderColor.allCases.count],
                        parentID: folderID)
                }
            }
            Button("Export PDFs from This Folder") { LibraryPDFExporter.export(entries) }
            if let folderID {
                Divider()
                Button("Edit…") {
                    guard let folder = catalog.folder(id: folderID) else { return }
                    LibraryDialogCenter.shared.presentEdit(folder)
                }
                Button("Delete Folder", role: .destructive) {
                    let deletedIDs = Set<UUID?>([folderID] + catalog.descendantFolders(of: folderID).map(\.id))
                    LibraryDialogs.deleteFolder(id: folderID, name: name, catalog: catalog, store: store) {
                        if case .folder(let selected) = store.librarySelection, deletedIDs.contains(selected) {
                            store.librarySelection = .folder(nil)
                        }
                    }
                }
            }
        }
    }

    private var folderLabel: some View {
        HStack(spacing: 7) {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .foregroundStyle(tint)
                .frame(width: ChromeMetrics.sidebarIconWidth)
            Text(name)
                .font(.system(size: 13))
                .foregroundStyle(Palette.primaryInk)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            if count > 0 {
                Text("\(count)")
                    .font(.system(size: 10))
                    .monospacedDigit()
                    .foregroundStyle(Palette.secondaryInk)
            }
        }
        .padding(.leading, 2)
        .padding(.trailing, 8)
        .frame(height: LibraryLook.sidebarRowHeight)
        .contentShape(Rectangle())
    }
}

/// A document filed in a folder. Its indent comes from the sidebar tree so a
/// subfolder's documents step in one more level than the subfolder itself.
private struct LibrarySidebarDocumentRow: View {
    let entry: LibraryEntry
    let indent: CGFloat
    @ObservedObject var store: ProjectStore
    @ObservedObject var catalog: DocumentCatalog
    let onOpen: () -> Void

    @State private var dropTargeted = false
    @State private var hovered = false

    var body: some View {
        let missing = catalog.isMissing(entry)
        // A plain tap target instead of a Button: a Button's own tracking eats the
        // press before SwiftUI's drag session can start, which broke drag-to-folder.
        return HStack(spacing: 7) {
                if missing {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(Color.orange)
                        .frame(width: ChromeMetrics.sidebarIconWidth)
                } else {
                    LibraryDocumentThumbnail(entry: entry,
                                             size: ChromeMetrics.documentPageIconSize,
                                             cornerRadius: ChromeMetrics.documentPageIconCornerRadius)
                        .frame(width: ChromeMetrics.documentPageIconSize.width)
                }
                Text(entry.displayName)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Palette.primaryInk)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                if entry.starred {
                    Image(systemName: "star.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(Palette.secondaryInk)
                }
            }
            .padding(.leading, 2)
            .padding(.trailing, 8)
            .frame(height: 28)
            .contentShape(Rectangle())
        .padding(.leading, indent)
        .contentShape(Rectangle())
        .background {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Palette.primaryInk.opacity(hovered ? Palette.chromeHoverOpacity : 0))
                .padding(.horizontal, 2)
        }
        .overlay(alignment: .top) {
            if dropTargeted {
                Rectangle()
                    .fill(Color(nsColor: .controlAccentColor))
                    .frame(height: 2)
                    .padding(.leading, indent + 6)
                    .padding(.trailing, 6)
            }
        }
        .onHover { hovered = $0 }
        .dropDestination(for: String.self) { payloads, _ in
            // Same-level drag inserts the dragged document before this row.
            var handled = false
            for payload in payloads {
                if let draggedID = LibraryEntryDragPayload.entryID(from: payload) {
                    catalog.moveEntry(draggedID, before: entry.id)
                    handled = true
                }
            }
            return handled
        } isTargeted: { targeted in
            dropTargeted = targeted
        }
        .onTapGesture(perform: onOpen)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { onOpen() }
        // Drag a sidebar document onto a folder row to file it there.
        .draggable(LibraryEntryDragPayload.string(for: entry.id)) {
            HStack(spacing: 6) {
                Image(systemName: "doc.text")
                Text(entry.displayName)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .font(.system(size: 12))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .modifier(LibraryEntryContextMenu(store: store, catalog: catalog, entry: entry, onOpen: onOpen))
        .help(entry.path)
    }
}

/// One row of the sidebar tree: a folder or a document, tagged with its depth.
private enum LibraryFolderItem {
    case unsorted
    case folder(LibraryFolder)

    var key: LibraryFolderKey {
        switch self {
        case .unsorted: .unsorted
        case .folder(let folder): .folder(folder.id)
        }
    }
}

private struct LibraryFolderNode: Identifiable {
    enum Kind {
        case folder(LibraryFolderItem)
        case document(LibraryEntry)
    }
    let id: String
    let kind: Kind
    let depth: Int
}

// MARK: - Browser

/// The All Documents browser drawn straight on the window's blurred backdrop: no card,
/// no opaque fill. The shell provides the backdrop and the top strip.
struct LibraryBrowser: View {
    @ObservedObject var store: ProjectStore
    @ObservedObject var catalog: DocumentCatalog
    var onOpenEntry: (LibraryEntry) -> Void
    var onNew: () -> Void
    var onOpen: () -> Void

    @State private var search = ""
    @State private var sort: LibrarySortOrder = .created
    @AppStorage("library.viewMode") private var viewMode: LibraryViewMode = .list
    @State private var newButtonHovered = false
    @State private var searchHovered = false
    @State private var sortAscending = false

    private var totalEntries: [LibraryEntry] { catalog.entries(in: store.librarySelection) }

    private var visibleEntries: [LibraryEntry] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return totalEntries }
        return totalEntries.filter { entry in
            entry.displayName.localizedCaseInsensitiveContains(query)
                || entry.path.localizedCaseInsensitiveContains(query)
        }
    }

    private var orderedEntries: [LibraryEntry] {
        let base = catalog.sorted(visibleEntries, by: sort)
        return sortAscending ? base.reversed() : base
    }

    private var groups: [LibraryDateGroup] {
        // Name sorting has no dates, so it is one flat list. Date sorting groups
        // by the very date the user chose (Last Viewed / Updated / Created).
        guard let dateColumn else {
            return orderedEntries.isEmpty ? [] : [LibraryDateGroup(title: "", entries: orderedEntries)]
        }
        let calendar = Calendar.current
        let now = Date()
        let startOfToday = calendar.startOfDay(for: now)
        let startOfYesterday = calendar.date(byAdding: .day, value: -1, to: startOfToday) ?? startOfToday
        let startOfLast7 = calendar.date(byAdding: .day, value: -7, to: startOfToday) ?? startOfYesterday
        let startOfLast30 = calendar.date(byAdding: .day, value: -30, to: startOfToday) ?? startOfLast7
        var buckets: [[LibraryEntry]] = Array(repeating: [], count: 5)
        for entry in orderedEntries {
            let date = dateColumn.value(entry)
            if date >= startOfToday { buckets[0].append(entry) }
            else if date >= startOfYesterday { buckets[1].append(entry) }
            else if date >= startOfLast7 { buckets[2].append(entry) }
            else if date >= startOfLast30 { buckets[3].append(entry) }
            else { buckets[4].append(entry) }
        }
        let titles = ["Today", "Yesterday", "Last 7 Days", "Last 30 Days", "Earlier"]
        return zip(titles, buckets).compactMap { title, entries in
            entries.isEmpty ? nil : LibraryDateGroup(title: title, entries: entries)
        }
    }

    private var isSearching: Bool {
        !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        switch store.librarySelection {
        case .templates:
            TemplatesBrowser(store: store, library: store.library)
        case .newTab:
            NewTabPage(store: store, catalog: catalog,
                       onOpenEntry: onOpenEntry, onNew: onNew, onOpen: onOpen) { selection, title in
                store.showLibrary(selection: selection, title: title)
            }
        default:
            browser
        }
    }

    private var browser: some View {
        VStack(spacing: 0) {
            browserHeader
            if viewMode == .list {
                columnHeader
                Rectangle()
                    .fill(Palette.hairline)
                    .frame(height: 0.7)
            }
            if let message = catalog.storageError { storageWarning(message) }
            if visibleEntries.isEmpty {
                emptyState
            } else if viewMode == .list {
                listContent
            } else {
                gridContent
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.clear)
    }

    // MARK: Header

    private var browserTitle: String {
        switch store.librarySelection {
        case .all: return "All Documents"
        case .starred: return "Starred"
        case .templates: return "Templates"
        case .newTab: return "New Tab"
        case .folder(let id):
            guard let id else { return DocumentCatalog.unsortedTitle }
            return catalog.folder(id: id)?.name ?? "Folder"
        case .tag: return "All Documents"
        }
    }

    @ViewBuilder
    private var newDocumentControl: some View {
        if isStarredPage {
            // Starred is a filtered view: it has no create/add action in the header.
            EmptyView()
        } else {
            Button(action: onNew) { plusTile }
                .buttonStyle(.plain)
                .onHover { newButtonHovered = $0 }
                .animation(.easeOut(duration: 0.15), value: newButtonHovered)
                .help("New Document")
                .accessibilityLabel("New Document")
        }
    }

    private var plusTile: some View {
        Image(systemName: "plus")
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(Palette.primaryInk)
            .frame(width: 36, height: 36)
            .quillCapsule()
            .contentShape(Circle())
    }

    private var isStarredPage: Bool {
        if case .starred = store.librarySelection { return true }
        return false
    }

    private var dateColumn: LibraryDateColumn? {
        switch sort {
        case .name: nil
        case .lastViewed: .lastViewed
        case .added: .added
        case .updated: .updated
        case .created: .created
        }
    }

    private var countText: String {
        let total = totalEntries.count
        let visible = visibleEntries.count
        guard visible != total else {
            return total == 1 ? "1 document" : "\(total) documents"
        }
        return "\(visible) of \(total)"
    }

    private var browserHeader: some View {
        HStack(alignment: .center, spacing: 10) {
            newDocumentControl

            HStack(alignment: .firstTextBaseline, spacing: 9) {
                Text(browserTitle)
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(Palette.primaryInk)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(countText)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Palette.secondaryInk)
                    .lineLimit(1)
            }
            Spacer(minLength: 12)
            LibraryViewModeControl(mode: $viewMode)
            sortMenu
            searchField
        }
        .padding(.horizontal, LibraryLook.browserInset)
        .padding(.top, 20)
        .padding(.bottom, 14)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(Palette.secondaryInk)
            TextField("Search", text: $search)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(Palette.primaryInk)
            if isSearching {
                Button {
                    search = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(Palette.secondaryInk)
                        .frame(width: 16, height: 16)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Clear Search")
            }
        }
        .padding(.horizontal, 11)
        .frame(width: 196)
        .background {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Palette.primaryInk.opacity(searchHovered ? 0.05 : 0))
        }
        .modifier(LibraryControlSurface())
        .onHover { searchHovered = $0 }
        .animation(.easeOut(duration: 0.15), value: searchHovered)
        .help("Filter documents by name or path")
    }

    private var sortMenu: some View {
        LibrarySortMenu(sort: $sort, ascending: $sortAscending, showsAdded: false)
    }

    private var columnHeader: some View {
        LibraryTableHeader(sort: $sort, ascending: $sortAscending,
                           trailingWidth: LibraryLook.rowActionsWidth)
    }

    // MARK: Content

    private var listContent: some View {
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(groups) { group in
                    if !group.title.isEmpty { groupCaption(group.title) }
                    ForEach(group.entries) { entry in
                        LibraryBrowserRow(
                            store: store,
                            catalog: catalog,
                            entry: entry,
                            dateColumn: dateColumn,
                            onOpen: { onOpenEntry(entry) }
                        )
                    }
                }
                Color.clear.frame(height: 16)
            }
        }
    }

    private var gridContent: some View {
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(groups) { group in
                    if !group.title.isEmpty { groupCaption(group.title) }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 220, maximum: 300), spacing: 14,
                                                 alignment: .leading)],
                              alignment: .leading, spacing: 14) {
                        ForEach(group.entries) { entry in
                            LibraryGridCard(
                                store: store,
                                catalog: catalog,
                                entry: entry,
                                onOpen: { onOpenEntry(entry) }
                            )
                        }
                    }
                    .padding(.horizontal, LibraryLook.browserInset)
                    .padding(.bottom, 6)
                }
                Color.clear.frame(height: 16)
            }
        }
    }

    private func groupCaption(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Palette.secondaryInk)
            .padding(.horizontal, LibraryLook.browserInset)
            .padding(.top, 16)
            .padding(.bottom, 5)
    }

    @ViewBuilder
    private var emptyState: some View {
        if !isSearching, case .folder = store.librarySelection {
            folderEmptyState
        } else {
            generalEmptyState
        }
    }

    /// Folder views (including Unsorted) read like the reference: one quiet
    /// panel with an explanation instead of a call to action.
    private var folderEmptyState: some View {
        VStack {
            Spacer()
            Text(emptyExplanation)
                .font(.system(size: 12))
                .foregroundStyle(Palette.secondaryInk)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 28)
                .padding(.vertical, 22)
                .frame(maxWidth: 520)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.white.opacity(0.42)))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Palette.hairline, lineWidth: 0.6))
            Spacer()
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var generalEmptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: isSearching ? "magnifyingglass" : "doc.text")
                .font(.system(size: 34, weight: .ultraLight))
                .foregroundStyle(Palette.secondaryInk.opacity(0.8))
            Text(isSearching ? "No Matching Documents" : "No Documents Yet")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Palette.primaryInk)
            Text(isSearching ? "Try a different name or path."
                             : emptyExplanation)
                .font(.system(size: 12))
                .foregroundStyle(Palette.secondaryInk)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyExplanation: String {
        switch store.librarySelection {
        case .all: return "Documents you create or open will be collected here."
        case .starred: return "Star a document to keep it close at hand."
        case .templates: return "Templates are starting points for new documents."
        case .newTab: return "Create a document or pick up where you left off."
        case .folder(nil): return "Any documents you haven't moved into a specific folder will appear here."
        case .folder(let id):
            if let folder = id.flatMap({ catalog.folder(id: $0) }) {
                return "No documents in “\(folder.name)” yet. Move a document here from All Documents."
            }
            return "This folder is empty. Move a document here from All Documents."
        case .tag: return "Documents you create or open will be collected here."
        }
    }

    private func storageWarning(_ message: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 9))
                .foregroundStyle(Color.orange)
            Text("Library changes may not be saved: \(message)")
                .font(.system(size: 10.5))
                .foregroundStyle(Palette.secondaryInk)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, LibraryLook.browserInset)
        .padding(.vertical, 6)
        .background(Color.orange.opacity(0.06))
    }
}

private struct LibraryViewModeControl: View {
    @Binding var mode: LibraryViewMode
    @State private var hovered: LibraryViewMode?

    var body: some View {
        HStack(spacing: 3) {
            ForEach(LibraryViewMode.allCases) { item in
                Button {
                    mode = item
                } label: {
                    Image(systemName: item.icon)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(mode == item || hovered == item ? Palette.primaryInk : Palette.secondaryInk)
                        .frame(width: 30, height: 26)
                        .background {
                            if mode == item || hovered == item {
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .fill(Palette.primaryInk.opacity(mode == item ? 0.11 : 0.06))
                                    .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                                        .strokeBorder(Palette.primaryInk.opacity(0.05), lineWidth: 0.6))
                            }
                        }
                        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
                .onHover { inside in
                    hovered = inside ? item : (hovered == item ? nil : hovered)
                }
                .animation(.easeOut(duration: 0.14), value: hovered == item)
                .help("\(item.title) View")
                .accessibilityLabel("\(item.title) View")
                .accessibilityAddTraits(mode == item ? .isSelected : [])
            }
        }
        .modifier(LibraryViewModeSurface())
    }
}

/// The view-mode group is a white capsule with the active slot as a soft gray
/// rounded tile, matching the library reference.
private struct LibraryViewModeSurface: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 4)
            .frame(height: 34)
            .quillCapsule()
    }
}

/// Glassy rounded surface shared by the browser's sort and search
/// controls: a frosted base, a soft top-light gradient, a bright inner edge and
/// a quiet ambient shadow, so the group floats over the backdrop like the
/// library reference instead of reading as flat outlined shapes.
private struct LibraryControlSurface: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 4)
            .frame(height: 34)
            .quillCapsule()
    }
}

private struct LibraryBrowserRow: View {
    @ObservedObject var store: ProjectStore
    @ObservedObject var catalog: DocumentCatalog
    let entry: LibraryEntry
    let dateColumn: LibraryDateColumn?
    let onOpen: () -> Void

    @State private var hovered = false

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onOpen) {
                rowLabel
            }
            .buttonStyle(.plain)
            actions
                .frame(width: LibraryLook.rowActionsWidth, height: LibraryLook.browserRowHeight)
                .opacity(hovered || entry.starred ? 1 : 0)
                .allowsHitTesting(hovered || entry.starred)
        }
        .padding(.trailing, LibraryLook.browserInset)
        .frame(height: LibraryLook.browserRowHeight)
        .background {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Palette.primaryInk.opacity(hovered ? LibraryLook.hoverWash : 0))
                .padding(.horizontal, 10)
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Palette.hairline.opacity(0.75))
                .frame(height: 0.7)
                .padding(.leading, LibraryLook.browserInset + LibraryLook.docTileSize.width + 11)
                .padding(.trailing, LibraryLook.browserInset)
        }
        .onHover { hovered = $0 }
        .modifier(LibraryEntryContextMenu(store: store, catalog: catalog, entry: entry, onOpen: onOpen))
        .help(entry.path)
    }

    private var rowLabel: some View {
        HStack(spacing: 0) {
            HStack(spacing: 11) {
                LibraryDocumentThumbnail(entry: entry,
                                         size: CGSize(width: LibraryLook.docTileSize.width,
                                                      height: LibraryLook.docTileSize.height))
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 4) {
                        Text(entry.displayName)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Palette.primaryInk)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if catalog.isMissing(entry) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 9))
                                .foregroundStyle(Color.orange)
                                .help("The file is no longer at this location")
                        }
                    }
                    Text(libraryEntrySubtitle(entry, catalog: catalog))
                        .font(.system(size: 10.5))
                        .foregroundStyle(Palette.secondaryInk)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            LibraryDateColumns(lastViewed: entry.lastViewedAt,
                               added: entry.addedAt,
                               updated: entry.updatedAt ?? entry.addedAt,
                               created: entry.createdOnDiskAt ?? entry.addedAt)
        }
        .padding(.leading, LibraryLook.browserInset)
        .frame(height: LibraryLook.browserRowHeight)
        .contentShape(Rectangle())
    }

    private var actions: some View {
        HStack(spacing: 0) {
            Button {
                catalog.toggleStar(entry.id)
            } label: {
                Image(systemName: entry.starred ? "star.fill" : "star")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(entry.starred ? Palette.primaryInk : Palette.secondaryInk)
                    .frame(width: 24, height: 24)
                    .contentShape(Circle())
            }
            .buttonStyle(ChromeButtonStyle())
            .help(entry.starred ? "Unstar" : "Star")
            .accessibilityLabel(entry.starred ? "Unstar" : "Star")

            Menu {
                libraryEntryMenuContent(store: store, catalog: catalog, entry: entry, onOpen: onOpen)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Palette.secondaryInk)
                    .frame(width: 24, height: 24)
                    .contentShape(Circle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More Actions")
            .accessibilityLabel("More Actions")
        }
        .frame(width: LibraryLook.rowActionsWidth, alignment: .trailing)
    }
}

private struct LibraryGridCard: View {
    @ObservedObject var store: ProjectStore
    @ObservedObject var catalog: DocumentCatalog
    let entry: LibraryEntry
    let onOpen: () -> Void

    @State private var hovered = false

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Text(entry.displayName)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Palette.primaryInk)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                    if entry.starred {
                        Image(systemName: "star.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(Palette.secondaryInk)
                    }
                    if catalog.isMissing(entry) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(Color.orange)
                    }
                }
                // Gallery cards show the compiled PDF's first page, like the
                // reference board, rather than a filename tile.
                LibraryDocumentThumbnail(entry: entry, size: CGSize(width: 164, height: 212),
                                         cornerRadius: 7)
                    .frame(maxWidth: .infinity)
                    .shadow(color: .black.opacity(0.07), radius: 4, y: 2)
                HStack(spacing: 4) {
                    Text(LibraryDateText.short(entry.updatedAt ?? entry.addedAt))
                        .font(.system(size: 9.5))
                        .foregroundStyle(Palette.secondaryInk.opacity(0.85))
                    Spacer(minLength: 0)
                    if !catalog.isMissing(entry), LibraryThumbnailStore.pdfURL(for: entry) == nil {
                        Text("No PDF")
                            .font(.system(size: 9.5))
                            .foregroundStyle(Palette.secondaryInk.opacity(0.7))
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 286, alignment: .topLeading)
            .background {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(Color.white)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .strokeBorder(Palette.hairline.opacity(hovered ? 0.95 : 0.65), lineWidth: 0.7)
            }
            .shadow(color: .black.opacity(hovered ? 0.10 : 0.055),
                    radius: hovered ? 9 : 4, y: hovered ? 3 : 1.5)
            .scaleEffect(hovered ? 1.006 : 1)
            .animation(.easeOut(duration: 0.16), value: hovered)
            .contentShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .modifier(LibraryEntryContextMenu(store: store, catalog: catalog, entry: entry, onOpen: onOpen))
        .help("\(entry.displayName)\n\(entry.path)\nUpdated \(LibraryDateText.short(entry.updatedAt ?? entry.addedAt))")
    }
}

/// New Document uses the same floating card as the other app dialogs: a name
/// field, the destination and template rows, and one full-width Create action.
struct NewDocumentDialog: View {
    let templates: [DocumentTemplate]
    let directory: URL
    let onDismiss: () -> Void
    let onCreate: (String, DocumentTemplate?, URL) -> Void

    @State private var name = "Untitled"
    @State private var selectedTemplateID: String?
    @State private var destination: URL
    @FocusState private var nameFocused: Bool

    init(templates: [DocumentTemplate], directory: URL,
         onDismiss: @escaping () -> Void,
         onCreate: @escaping (String, DocumentTemplate?, URL) -> Void) {
        self.templates = templates
        self.directory = directory
        self.onDismiss = onDismiss
        self.onCreate = onCreate
        _destination = State(initialValue: directory)
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var selectedTemplate: DocumentTemplate? {
        templates.first { $0.id == selectedTemplateID }
    }

    private var canCreate: Bool {
        !trimmedName.isEmpty
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                QuillDialogBackdrop()
                    .onTapGesture(perform: onDismiss)
                QuillDialogCard(title: "New Document",
                                width: min(460, max(360, geometry.size.width * 0.66)),
                                close: onDismiss,
                                content: { form },
                                actions: [.primary("Create")],
                                onAction: { _ in create() },
                                primaryEnabled: canCreate)
                    .accessibilityAddTraits(.isModal)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .onAppear {
            selectedTemplateID = nil
            nameFocused = true
            DispatchQueue.main.async {
                _ = NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
            }
        }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 0) {
            QuillDialogFieldLabel("Name")
            QuillDialogField {
                TextField("Document name", text: $name)
                    .textFieldStyle(.plain)
                    .focused($nameFocused)
                    .onSubmit(create)
            }
            .padding(.top, 7)

            QuillDialogRow(label: "Location") {
                HStack(spacing: 8) {
                    Text(LibraryPathText.abbreviated(destination.path))
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.secondaryInk)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(destination.path)
                    Button("Choose…", action: chooseLocation)
                        .buttonStyle(SettingsActionStyle())
                }
            }
            .padding(.top, 16)

            QuillDialogRow(label: "Template") {
                Menu {
                    Button {
                        selectedTemplateID = nil
                    } label: {
                        if selectedTemplate == nil { Label("None", systemImage: "checkmark") } else { Text("None") }
                    }
                    if !templates.isEmpty { Divider() }
                    ForEach(templates) { template in
                        Button {
                            selectedTemplateID = template.id
                        } label: {
                            if selectedTemplateID == template.id {
                                Label(template.displayTitle, systemImage: "checkmark")
                            } else {
                                Text(template.displayTitle)
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 5) {
                        Text(selectedTemplate?.displayTitle ?? "None")
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 9, weight: .medium))
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Palette.primaryInk)
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                    .background(Palette.primaryInk.opacity(0.035), in: Capsule())
                    .overlay(Capsule().strokeBorder(Palette.hairline, lineWidth: 0.8))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
        }
    }

    private func chooseLocation() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = destination
        panel.message = "Choose where the new document will be created."
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        destination = url
    }

    private func create() {
        guard canCreate else { return }
        LibraryPreferences.shared.rememberLastDocumentDirectory(destination)
        onCreate(trimmedName, selectedTemplate, destination)
        onDismiss()
    }
}

/// First meaningful lines of a template's .tex source, used by both the list and
/// grid views so templates read like documents rather than generic cards.
private struct TemplateSourcePreview: View {
    let template: DocumentTemplate
    @ObservedObject var library: DocumentLibrary
    var lineLimit: Int

    @State private var text = ""

    var body: some View {
        Text(text.isEmpty ? template.summary : text)
            .font(.system(size: 10.5))
            .foregroundStyle(Palette.secondaryInk)
            .lineLimit(lineLimit)
            .lineSpacing(1.5)
            .multilineTextAlignment(.leading)
            .task(id: template.id) {
                guard let source = try? library.source(for: template) else { text = ""; return }
                var lines: [String] = []
                for raw in source.split(whereSeparator: \.isNewline) {
                    let line = raw.trimmingCharacters(in: .whitespaces)
                    guard !line.isEmpty else { continue }
                    lines.append(line)
                    if lines.count >= 8 { break }
                }
                text = String(lines.joined(separator: " ").prefix(360))
            }
    }
}

private struct TemplatesBrowser: View {
    @ObservedObject var store: ProjectStore
    @ObservedObject var library: DocumentLibrary

    @State private var hovered: String?
    @AppStorage("templates.viewMode") private var viewMode: LibraryViewMode = .grid
    @State private var search = ""
    @State private var sort: LibrarySortOrder = .updated
    @State private var sortAscending = false

    private var dateColumn: LibraryDateColumn? {
        switch sort {
        case .name: nil
        case .lastViewed: .lastViewed
        case .added: .created
        case .updated: .updated
        case .created: .created
        }
    }

    private func updatedDate(_ template: DocumentTemplate) -> Date {
        (try? template.url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate ?? .distantPast
    }

    private func createdDate(_ template: DocumentTemplate) -> Date {
        (try? template.url.resourceValues(forKeys: [.creationDateKey]))?
            .creationDate ?? updatedDate(template)
    }

    private func viewedDate(_ template: DocumentTemplate) -> Date {
        (try? template.url.resourceValues(forKeys: [.contentAccessDateKey]))?
            .contentAccessDate ?? updatedDate(template)
    }

    private func templateDate(_ template: DocumentTemplate, column: LibraryDateColumn) -> Date {
        switch column {
        case .lastViewed: viewedDate(template)
        case .added: createdDate(template)
        case .updated: updatedDate(template)
        case .created: createdDate(template)
        }
    }

    private var visibleTemplates: [DocumentTemplate] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = query.isEmpty ? library.templates : library.templates.filter {
            $0.displayTitle.localizedCaseInsensitiveContains(query)
                || $0.summary.localizedCaseInsensitiveContains(query)
        }
        let sorted: [DocumentTemplate]
        switch sort {
        case .name:
            sorted = filtered.sorted { $0.displayTitle.localizedCaseInsensitiveCompare($1.displayTitle) == .orderedAscending }
        case .lastViewed:
            sorted = filtered.sorted { viewedDate($0) > viewedDate($1) }
        case .added:
            sorted = filtered.sorted { createdDate($0) > createdDate($1) }
        case .updated:
            sorted = filtered.sorted { updatedDate($0) > updatedDate($1) }
        case .created:
            sorted = filtered.sorted { createdDate($0) > createdDate($1) }
        }
        return sortAscending ? sorted.reversed() : sorted
    }

    private var groupedTemplates: [(title: String, templates: [DocumentTemplate])] {
        guard let column = dateColumn else {
            return visibleTemplates.isEmpty ? [] : [("", visibleTemplates)]
        }
        let calendar = Calendar.current
        let now = Date()
        let startOfToday = calendar.startOfDay(for: now)
        let startOfYesterday = calendar.date(byAdding: .day, value: -1, to: startOfToday) ?? startOfToday
        let startOfLast7 = calendar.date(byAdding: .day, value: -7, to: startOfToday) ?? startOfYesterday
        let startOfLast30 = calendar.date(byAdding: .day, value: -30, to: startOfToday) ?? startOfLast7
        var buckets: [[DocumentTemplate]] = Array(repeating: [], count: 5)
        for template in visibleTemplates {
            let date = templateDate(template, column: column)
            if date >= startOfToday { buckets[0].append(template) }
            else if date >= startOfYesterday { buckets[1].append(template) }
            else if date >= startOfLast7 { buckets[2].append(template) }
            else if date >= startOfLast30 { buckets[3].append(template) }
            else { buckets[4].append(template) }
        }
        let titles = ["Today", "Yesterday", "Last 7 Days", "Last 30 Days", "Earlier"]
        return zip(titles, buckets).compactMap { title, templates in
            templates.isEmpty ? nil : (title, templates)
        }
    }

    private func dateText(for template: DocumentTemplate) -> String? {
        guard let column = dateColumn else { return nil }
        return LibraryDateText.short(templateDate(template, column: column))
    }

    private func groupCaption(_ title: String, leading: CGFloat = 30) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Palette.secondaryInk)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, leading)
            .padding(.trailing, 30)
            .padding(.top, 14)
            .padding(.bottom, 5)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 10) {
                Button(action: createTemplate) {
                    Image(systemName: "plus")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Palette.primaryInk)
                        .frame(width: 36, height: 36)
                        .quillCapsule()
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("New Template")
                .accessibilityLabel("New Template")

                HStack(alignment: .firstTextBaseline, spacing: 9) {
                    Text("Templates")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(Palette.primaryInk)
                    Text(library.templates.count == 1
                         ? "1 template"
                         : "\(library.templates.count) templates")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Palette.secondaryInk)
                }
                Spacer(minLength: 12)
                LibraryViewModeControl(mode: $viewMode)
                sortMenu
                searchField
            }
            .padding(.horizontal, LibraryLook.browserInset)
            .padding(.top, 20).padding(.bottom, 14)

            if library.templates.isEmpty || visibleTemplates.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: library.templates.isEmpty ? "doc.text" : "magnifyingglass")
                        .font(.system(size: 34, weight: .ultraLight))
                        .foregroundStyle(Palette.secondaryInk.opacity(0.8))
                    Text(library.templates.isEmpty ? "No Templates Yet" : "No Matching Templates")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(Palette.primaryInk)
                    Text(library.templates.isEmpty
                         ? "Templates are starting points for new documents."
                         : "Try a different name or description.")
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.secondaryInk)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if viewMode == .grid {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(groupedTemplates.enumerated()), id: \.offset) { _, group in
                            if !group.title.isEmpty { groupCaption(group.title) }
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 230, maximum: 320), spacing: 14,
                                                         alignment: .leading)],
                                      alignment: .leading, spacing: 14) {
                                ForEach(group.templates) { template in
                                    templateCard(template, dateText: dateText(for: template))
                                }
                            }
                            .padding(.horizontal, 30)
                            .padding(.vertical, 6)
                        }
                    }
                    .padding(.bottom, 18)
                }
            } else {
                VStack(spacing: 0) {
                    LibraryTableHeader(sort: $sort, ascending: $sortAscending,
                                       showsAdded: false, inset: 32)
                    Rectangle()
                        .fill(Palette.hairline)
                        .frame(height: 0.7)
                        .padding(.horizontal, LibraryLook.browserInset)
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(Array(groupedTemplates.enumerated()), id: \.offset) { _, group in
                                if !group.title.isEmpty { groupCaption(group.title, leading: 12) }
                                ForEach(group.templates) { template in
                                    templateListRow(template)
                                }
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                    }
                }
            }
        }
    }

    private var sortMenu: some View {
        LibrarySortMenu(sort: $sort, ascending: $sortAscending, showsAdded: false)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(Palette.secondaryInk)
            TextField("Search", text: $search)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(Palette.primaryInk)
        }
        .padding(.horizontal, 11)
        .frame(width: 196)
        .modifier(LibraryControlSurface())
        .help("Filter templates by name or description")
    }

    private func templateCard(_ template: DocumentTemplate, dateText: String?) -> some View {
        let isHovered = hovered == template.id
        return Button {
            store.openTemplate(template)
        } label: {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 9) {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Palette.primaryInk.opacity(0.045))
                        .frame(width: 34, height: 34)
                        .overlay(Image(systemName: "doc.text")
                            .font(.system(size: 14))
                            .foregroundStyle(Palette.secondaryInk))
                    Text(template.displayTitle)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Palette.primaryInk)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                TemplateSourcePreview(template: template, library: library, lineLimit: 6)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                Spacer(minLength: 0)
                HStack(spacing: 4) {
                    if let dateText {
                        Text(dateText)
                            .font(.system(size: 9.5))
                            .foregroundStyle(Palette.secondaryInk.opacity(0.75))
                    }
                    Spacer(minLength: 0)
                }
            }
            .padding(15)
            .frame(maxWidth: .infinity, minHeight: 188, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(Color.white))
            .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(Palette.hairline.opacity(isHovered ? 0.95 : 0.65), lineWidth: 0.7))
            .shadow(color: .black.opacity(isHovered ? 0.10 : 0.05),
                    radius: isHovered ? 9 : 4, y: isHovered ? 3 : 1.5)
            .scaleEffect(isHovered ? 1.006 : 1)
            .contentShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 ? template.id : (hovered == template.id ? nil : hovered) }
        .animation(.easeOut(duration: 0.16), value: isHovered)
        .contextMenu {
            Button("Rename") { rename(template) }
            Button("Delete", role: .destructive) { delete(template) }
        }
        .help("\(template.displayTitle)\n\(template.url.path)")
    }

    private func templateListRow(_ template: DocumentTemplate) -> some View {
        let isHovered = hovered == template.id
        return Button {
            store.openTemplate(template)
        } label: {
            HStack(spacing: 11) {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Palette.primaryInk.opacity(0.045))
                    .frame(width: 28, height: 34)
                    .overlay(Image(systemName: "doc.text")
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.secondaryInk))
                VStack(alignment: .leading, spacing: 2) {
                    Text(template.displayTitle)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Palette.primaryInk)
                        .lineLimit(1)
                    TemplateSourcePreview(template: template, library: library, lineLimit: 1)
                        .font(.system(size: 10.5))
                }
                Spacer(minLength: 12)
                LibraryDateColumns(lastViewed: viewedDate(template),
                                   updated: updatedDate(template),
                                   created: createdDate(template))
            }
            .padding(.horizontal, 12)
            .frame(height: 48)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Palette.primaryInk.opacity(isHovered ? LibraryLook.hoverWash : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 ? template.id : (hovered == template.id ? nil : hovered) }
        .contextMenu {
            Button("Rename") { rename(template) }
            Button("Delete", role: .destructive) { delete(template) }
        }
        .help("\(template.displayTitle)\n\(template.url.path)")
    }

    private func createTemplate() {
        QuillDialogCenter.shared.showPrompt(title: "New Template",
                                            initial: "Template",
                                            placeholder: "Template name",
                                            confirmTitle: "Create") { [self] raw in
            guard let raw else { return }
            let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return }
            do {
                let template = try library.createTemplate(named: name)
                library.reloadTemplates()
                store.openTemplate(template)
            } catch {
                store.showError("Could Not Create Template", error.localizedDescription)
            }
        }
    }

    private func rename(_ template: DocumentTemplate) {
        QuillDialogCenter.shared.showPrompt(title: "Rename Template",
                                            initial: template.title,
                                            placeholder: "Template name",
                                            confirmTitle: "Rename") { [self] raw in
            guard let raw else { return }
            let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, name != template.title else { return }
            do {
                _ = try library.renameTemplate(template, to: name)
                library.reloadTemplates()
            } catch {
                store.showError("Could Not Rename Template", error.localizedDescription)
            }
        }
    }

    private func delete(_ template: DocumentTemplate) {
        QuillDialogCenter.shared.showConfirm(title: "Delete “\(template.displayTitle)”?",
                                             message: "Moves the template to the Trash.",
                                             confirmTitle: "Delete",
                                             destructive: true) { [self] confirmed in
            guard confirmed else { return }
            do {
                try library.deleteTemplate(template)
                library.reloadTemplates()
            } catch {
                store.showError("Could Not Delete Template", error.localizedDescription)
            }
        }
    }
}

/// The "+" destination: one quiet start page with Create cards, Quick Open and
/// recently opened documents, matching the reference's New Tab screen.
private struct NewTabPage: View {
    @ObservedObject var store: ProjectStore
    @ObservedObject var catalog: DocumentCatalog
    var onOpenEntry: (LibraryEntry) -> Void
    var onNew: () -> Void
    var onOpen: () -> Void
    var select: (LibrarySelection, String) -> Void

    @State private var quickOpen = ""

    private var quickResults: [LibraryEntry] {
        let query = quickOpen.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        return catalog.entries
            .filter { $0.displayName.localizedCaseInsensitiveContains(query)
                || $0.path.localizedCaseInsensitiveContains(query) }
            .sorted { $0.lastViewedAt > $1.lastViewedAt }
            .prefix(6)
            .map { $0 }
    }

    private var recent: [LibraryEntry] {
        catalog.entries.sorted { $0.lastViewedAt > $1.lastViewedAt }.prefix(6).map { $0 }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                Text("Create")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Palette.primaryInk)

                HStack(spacing: 16) {
                    createCard("New Document", detail: "Start from a template", symbol: "doc.badge.plus", shortcut: "⌘N", action: onNew)
                    createCard("Open Document", detail: "Link a local .tex file", symbol: "folder", shortcut: "⌘O", action: onOpen)
                    createCard("Templates", detail: "Edit your starting points", symbol: "square.on.square", shortcut: nil) {
                        select(.templates, "Templates")
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 12))
                            .foregroundStyle(Palette.secondaryInk)
                        TextField("Quick Open", text: $quickOpen)
                            .textFieldStyle(.plain)
                            .font(.system(size: 13))
                            .foregroundStyle(Palette.primaryInk)
                        Text("⌘O")
                            .font(.system(size: 10))
                            .foregroundStyle(Palette.secondaryInk)
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 40)
                    .quillCapsule()

                    if !quickResults.isEmpty {
                        VStack(spacing: 2) {
                            ForEach(quickResults) { entry in
                                Button { onOpenEntry(entry) } label: {
                                    HStack(spacing: 10) {
                                        LibraryDocumentThumbnail(entry: entry, size: CGSize(width: 24, height: 30), cornerRadius: 5)
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(entry.displayName).font(.system(size: 12.5, weight: .medium))
                                                .foregroundStyle(Palette.primaryInk).lineLimit(1)
                                            Text(entry.path).font(.system(size: 10))
                                                .foregroundStyle(Palette.secondaryInk).lineLimit(1)
                                                .truncationMode(.middle)
                                        }
                                        Spacer(minLength: 0)
                                    }
                                    .padding(.horizontal, 8).frame(height: 40)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(QuillRowButtonStyle(cornerRadius: LibraryLook.sidebarCorner))
                            }
                        }
                        .padding(.top, 4)
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("Recently Opened Documents")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Palette.secondaryInk)
                    if recent.isEmpty {
                        Text("Documents you create or open will be listed here.")
                            .font(.system(size: 12))
                            .foregroundStyle(Palette.secondaryInk)
                            .padding(.vertical, 8)
                    } else {
                        VStack(spacing: 2) {
                            ForEach(recent) { entry in
                                Button { onOpenEntry(entry) } label: {
                                    HStack(spacing: 12) {
                                        LibraryDocumentThumbnail(entry: entry, size: CGSize(width: 30, height: 38), cornerRadius: 6)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(entry.displayName)
                                                .font(.system(size: 13, weight: .medium))
                                                .foregroundStyle(Palette.primaryInk).lineLimit(1)
                                            Text(entry.folderURL.lastPathComponent)
                                                .font(.system(size: 10.5))
                                                .foregroundStyle(Palette.secondaryInk).lineLimit(1)
                                                .truncationMode(.middle)
                                        }
                                        Spacer(minLength: 0)
                                        Text(LibraryDateText.short(entry.lastViewedAt))
                                            .font(.system(size: 11))
                                            .foregroundStyle(Palette.secondaryInk)
                                    }
                                    .padding(.horizontal, 10).frame(height: 54)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(QuillRowButtonStyle(cornerRadius: LibraryLook.sidebarCorner))
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 34)
            .padding(.vertical, 30)
            .frame(maxWidth: 700, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    private func createCard(_ title: String, detail: String, symbol: String, shortcut: String?,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 17, weight: .regular))
                    .foregroundStyle(Palette.primaryInk)
                    .frame(width: 30, height: 30)
                Spacer(minLength: 0)
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Palette.primaryInk)
                HStack(spacing: 6) {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.secondaryInk)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if let shortcut {
                        Text(shortcut)
                            .font(.system(size: 10))
                            .foregroundStyle(Palette.secondaryInk)
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(RoundedRectangle(cornerRadius: 5).fill(Color.black.opacity(0.035)))
                    }
                }
            }
            .padding(16)
            .frame(width: 196, height: 142, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.white.opacity(0.9))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Palette.hairline, lineWidth: 0.7))
                    .shadow(color: .black.opacity(0.06), radius: 8, y: 2)
            }
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(QuillRowButtonStyle(cornerRadius: 14))
        .help(title)
    }
}
