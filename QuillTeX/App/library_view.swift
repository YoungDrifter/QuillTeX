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
    /// The library tree uses one row spacing everywhere so the measured branch
    /// height matches what the reveal clips.
    static let sidebarRowSpacing: CGFloat = 1
    static let sidebarDocumentRowHeight: CGFloat = 28
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

/// The menu's order list. A folder view also offers Manual and Kind. The active
/// sort is always included so the menu can never open with no checked item.
func librarySortMenuOrders(showsAdded: Bool, folderOrders: Bool,
                           active: LibrarySortOrder) -> [LibrarySortOrder] {
    var orders: [LibrarySortOrder] = folderOrders
        ? [.manual, .name, .kind, .lastViewed]
        : [.name, .lastViewed]
    if showsAdded { orders.append(.added) }
    orders += [.created, .updated]
    if !orders.contains(active) { orders.append(active) }
    return orders
}

/// One shared sort menu for documents and templates.
private struct LibrarySortMenu: View {
    @Binding var sort: LibrarySortOrder
    @Binding var ascending: Bool
    var showsAdded = true
    /// Folder views also offer the Finder-style manual order and Kind.
    var folderOrders = false
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
                                ascending = order.defaultAscending
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
        librarySortMenuOrders(showsAdded: showsAdded, folderOrders: folderOrders, active: sort)
    }
}

private struct LibraryContentWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// One shared column header for documents and templates.
private struct LibraryTableHeader: View {
    @Binding var sort: LibrarySortOrder
    @Binding var ascending: Bool
    var trailingWidth: CGFloat = 0
    var showsAdded = true
    var showsLastViewed = true
    var inset: CGFloat = LibraryLook.browserInset

    var body: some View {
        HStack(spacing: 0) {
            button("Name", order: .name)
                .frame(maxWidth: .infinity, alignment: .leading)
            if showsLastViewed {
                button("Last Viewed", order: .lastViewed)
                    .frame(width: LibraryLook.dateColumnWidth, alignment: .leading)
            }
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
                ascending = order.defaultAscending
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
    var showsLastViewed = true

    var body: some View {
        HStack(spacing: 0) {
            if showsLastViewed { cell(lastViewed) }
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

    func thumbnail(for entry: LibraryEntry, size: NSSize, outputDirectory: String) async -> NSImage? {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: Self.load(entry: entry, size: size,
                                                         outputDirectory: outputDirectory,
                                                         cache: self.cache))
            }
        }
    }

    private static func load(entry: LibraryEntry, size: NSSize, outputDirectory: String,
                             cache: NSCache<NSString, NSImage>) -> NSImage? {
        guard let (url, key) = resolvePDF(for: entry, outputDirectory: outputDirectory) else { return nil }
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
    static func pdfURL(for entry: LibraryEntry, outputDirectory: String) -> URL? {
        resolvePDF(for: entry, outputDirectory: outputDirectory)?.0
    }

    /// Resolve the same output location as compilation, then accept the old
    /// beside-the-source and build-folder locations for existing projects.
    private static func resolvePDF(for entry: LibraryEntry, outputDirectory: String) -> (URL, String)? {
        guard let url = LibraryPDFLocator.pdfURL(for: entry, outputDirectory: outputDirectory) else { return nil }
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate?.timeIntervalSince1970 ?? 0
        return (url, "\(url.standardizedFileURL.path)#\(modified)")
    }
}

/// Collects a document's compiled PDFs into a directory the user picks.
@MainActor
enum LibraryPDFExporter {
    static func export(_ entries: [LibraryEntry]) {
        let unique = entries.reduce(into: [LibraryEntry]()) { result, entry in
            if !result.contains(where: { $0.id == entry.id }) { result.append(entry) }
        }
        guard !unique.isEmpty else { return }
        guard let directory = chooseExportDirectory() else { return }

        var exported = 0
        var missing: [String] = []
        var failed: [String] = []
        // Resolve the output the same way compilation does, so a build folder
        // inside the project is preferred over a stale sibling PDF.
        let outputDirectory = BuildSettings.shared.outputDirectory
        for entry in unique {
            guard let pdf = LibraryPDFLocator.pdfURL(for: entry, outputDirectory: outputDirectory) else {
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

    /// Export one compiled PDF, used by a document tab's context menu.
    static func export(pdf: URL, displayName: String) {
        guard let directory = chooseExportDirectory() else { return }
        do {
            let destination = availableDestination(named: displayName + ".pdf", in: directory)
            try FileManager.default.copyItem(at: pdf, to: destination)
            report(exported: 1, missing: [], failed: [])
        } catch {
            report(exported: 0, missing: [], failed: ["\(displayName): \(error.localizedDescription)"])
        }
    }

    private static func chooseExportDirectory() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose where to save the exported PDFs."
        panel.prompt = "Export Here"
        guard panel.runModal() == .OK else { return nil }
        return panel.url
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
        // A clean success is a quiet confirmation, not a modal dialog.
        if exported > 0 && missing.isEmpty && failed.isEmpty {
            QuillToast.shared.show("\(exported) PDF\(exported == 1 ? "" : "s") exported")
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
    @State private var outputDirectory = "."

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
        .task(id: "\(revision)#\(outputDirectory)") {
            image = nil
            image = await LibraryThumbnailStore.shared.thumbnail(
                for: entry, size: NSSize(width: size.width * 2, height: size.height * 2),
                outputDirectory: outputDirectory)
        }
        .onAppear { outputDirectory = BuildSettings.shared.outputDirectory }
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
    Button("Open in New Tab") { store.openLibraryEntry(entry, inNewTab: true) }
    Button("Rename Project") { store.requestRenameProject(entry.url) }
    Button("Rename Main File") { store.requestRenameFile(entry.url) }
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
    Button("Clear Intermediate Files") { store.clearIntermediateFiles(forTabMain: entry.url) }
    Divider()
    Button("Remove from Library", role: .destructive) {
        catalog.removeEntry(entry.id)
        QuillToast.shared.show("Removed \(entry.displayName) from Library")
    }
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
                                width: min(370, max(320, geometry.size.width * 0.56)),
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
                                    Circle().strokeBorder(Color.white,
                                                          lineWidth: color == option ? 2 : 0)
                                }
                                .shadow(color: .black.opacity(color == option ? 0.14 : 0),
                                        radius: color == option ? 2 : 0, y: 1)
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
            .padding(.top, 10)
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

/// App-wide expansion state for the library sidebar's folder tree. The sidebar is
/// rebuilt whenever the home tab is shown or the window reopens, so this state
/// lives outside the view and is persisted in UserDefaults.
final class LibrarySidebarExpansion: ObservableObject {
    struct State: Codable, Equatable {
        var expandedFolderIDs: Set<UUID> = []
        var unsortedExpanded = true
        var foldersExpanded = true
        var initialized = false
    }

    static let shared = LibrarySidebarExpansion()
    static let defaultsKey = "workspace.librarySidebarExpansion"

    @Published private(set) var state: State
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.defaultsKey),
           let saved = try? JSONDecoder().decode(State.self, from: data) {
            state = saved
        } else {
            state = State()
        }
    }

    /// The first launch expands every folder, matching the old behavior. After
    /// that the persisted state wins, including "everything collapsed".
    func initializeIfNeeded(folderIDs: [UUID]) {
        guard !state.initialized else { return }
        var next = state
        next.expandedFolderIDs = Set(folderIDs)
        next.unsortedExpanded = true
        next.foldersExpanded = true
        next.initialized = true
        apply(next)
    }

    func setFolderExpanded(_ id: UUID, _ expanded: Bool) {
        var next = state
        if expanded { next.expandedFolderIDs.insert(id) }
        else { next.expandedFolderIDs.remove(id) }
        apply(next)
    }

    func setUnsortedExpanded(_ expanded: Bool) {
        var next = state
        next.unsortedExpanded = expanded
        apply(next)
    }

    func setFoldersExpanded(_ expanded: Bool) {
        var next = state
        next.foldersExpanded = expanded
        apply(next)
    }

    func expandFolders(_ ids: [UUID]) {
        var next = state
        next.expandedFolderIDs.formUnion(ids)
        apply(next)
    }

    private func apply(_ next: State) {
        guard next != state else { return }
        state = next
        if let data = try? JSONEncoder().encode(next) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }
}

struct LibrarySidebarContent: View {
    @ObservedObject var store: ProjectStore
    @ObservedObject var catalog: DocumentCatalog
    var onNew: () -> Void
    var onOpen: () -> Void
    var onOpenEntry: (LibraryEntry) -> Void

    @ObservedObject private var sidebarExpansion = LibrarySidebarExpansion.shared
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
        .onAppear(perform: initializeExpansion)
        .onChange(of: dialogs.createdFolderID) { _, id in
            guard let id else { return }
            // Reveal the new folder together with every containing folder.
            var revealIDs: [UUID] = []
            var reveal: UUID? = id
            while let folderID = reveal {
                revealIDs.append(folderID)
                reveal = catalog.folder(id: folderID)?.parentID
            }
            withAnimation(reduceMotion ? nil : ChromeMotion.transition) {
                sidebarExpansion.setFoldersExpanded(true)
                sidebarExpansion.expandFolders(revealIDs)
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
        .contextMenu {
            // A section can also live in its own tab, independent of the home tab.
            Button("Open in New Tab") {
                store.showLibrary(selection: selection, title: title, inNewTab: true)
            }
        }
        .help(title)
    }

    private var expandedFolders: Set<LibraryFolderKey> {
        var keys = Set(sidebarExpansion.state.expandedFolderIDs.map { LibraryFolderKey.folder($0) })
        if sidebarExpansion.state.unsortedExpanded { keys.insert(.unsorted) }
        return keys
    }

    private var foldersExpanded: Bool { sidebarExpansion.state.foldersExpanded }

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
                    sidebarExpansion.setFoldersExpanded(!foldersExpanded)
                }
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, 2)
        .frame(height: 28)
    }

    private var folderList: some View {
        // Each folder emits its own subtree so every level is inserted and
        // removed with the same branch reveal. A flat ForEach only animated the
        // rows below a collapsed folder, which made a top-level folder pop in
        // and out while a nested one appeared to unfold.
        VStack(alignment: .leading, spacing: LibraryLook.sidebarRowSpacing) {
            LibraryFolderBranch(item: .unsorted, depth: 0,
                                expandedFolders: expandedFolders,
                                store: store, catalog: catalog,
                                onOpenEntry: onOpenEntry,
                                onToggle: toggleFolder)
            ForEach(catalog.rootFolders) { folder in
                LibraryFolderBranch(item: .folder(folder), depth: 0,
                                    expandedFolders: expandedFolders,
                                    store: store, catalog: catalog,
                                    onOpenEntry: onOpenEntry,
                                    onToggle: toggleFolder)
            }
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

    private func initializeExpansion() {
        sidebarExpansion.initializeIfNeeded(folderIDs: catalog.folders.map(\.id))
    }

    private func setFolderExpanded(_ key: LibraryFolderKey, _ expanded: Bool) {
        switch key {
        case .unsorted:
            sidebarExpansion.setUnsortedExpanded(expanded)
        case .folder(let id):
            sidebarExpansion.setFolderExpanded(id, expanded)
        }
    }

    private func toggleFolder(_ key: LibraryFolderKey) {
        let expanded = !expandedFolders.contains(key)
        if reduceMotion {
            setFolderExpanded(key, expanded)
        } else {
            withAnimation(ChromeMotion.transition) {
                setFolderExpanded(key, expanded)
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

private let libraryFolderSortOptions: [LibrarySortOrder] = [
    .manual, .name, .kind, .lastViewed, .created, .updated
]

/// Sidebar row for one folder. Its expanded subtree is emitted by
/// LibraryFolderBranch, which keeps every nesting level on the same reveal.
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
                                                                           : (hovered ? 0.07 : 0))))
        }
        .contentShape(RoundedRectangle(cornerRadius: LibraryLook.sidebarCorner, style: .continuous))
        .overlay {
            // Dropping onto a folder outlines the whole row in the native accent
            // color, the same rounded box the reference file browser uses.
            if dropTargeted {
                RoundedRectangle(cornerRadius: LibraryLook.sidebarCorner, style: .continuous)
                    .strokeBorder(Color(nsColor: .controlAccentColor), lineWidth: 1.5)
                    .padding(.leading, CGFloat(depth) * LibraryLook.sidebarIndentStep)
                    .padding(.trailing, 2)
            }
        }
        .onContinuousHover { phase in
            switch phase {
            case .active: hovered = true
            case .ended: hovered = false
            }
        }
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
            // The folder row opens its page. These two actions are the folder's
            // create and import entry points, matching New Document / Open
            // Document for the library. Opening a local .tex files it here.
            Button("Open in New Tab") {
                store.showLibrary(selection: .folder(folderID), title: name, inNewTab: true)
            }
            Button("New Document in This Folder") { store.openNewDocumentSheet(folderID: folderID) }
            Button("Open Documents to This Folder…") { store.chooseDocumentForFolder(folderID) }
            if let folderID {
                Button("New Folder in This Folder") {
                    dialogs.presentNewFolder(
                        color: LibraryFolderColor.allCases[catalog.folders.count % LibraryFolderColor.allCases.count],
                        parentID: folderID)
                }
            }
            Button("Export PDFs from This Folder") { LibraryPDFExporter.export(entries) }
            Menu("Sort By") {
                ForEach(libraryFolderSortOptions, id: \.self) { order in
                    // A Toggle inside a menu renders the system checkmark for the
                    // active choice, the same affordance Finder uses.
                    Toggle(isOn: Binding(
                        get: { catalog.sortOrder(in: folderID) == order },
                        set: { isOn in
                            if isOn { catalog.setSortOrder(order, in: folderID) }
                        }
                    )) {
                        Text(order.title)
                    }
                }
            }
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
            // The count is a hover affordance: it stays out of the resting
            // sidebar and appears only for the folder under the pointer. Zero
            // is shown too, so an empty folder reads as empty rather than as a
            // broken count.
            Text("\(count)")
                .font(.system(size: 10))
                .monospacedDigit()
                .foregroundStyle(Palette.secondaryInk)
                .opacity(hovered ? 1 : 0)
                .animation(.easeOut(duration: 0.12), value: hovered)
                .accessibilityHidden(!hovered)
        }
        .padding(.leading, 2)
        .padding(.trailing, 8)
        .frame(height: LibraryLook.sidebarRowHeight)
        .contentShape(Rectangle())
    }
}

/// One folder row plus its expanded subtree. Every level uses the same
/// height reveal, so a top-level folder folds exactly like a nested one instead
/// of depending on rows below it to animate.
private struct LibraryFolderBranch: View {
    let item: LibraryFolderItem
    let depth: Int
    let expandedFolders: Set<LibraryFolderKey>
    @ObservedObject var store: ProjectStore
    @ObservedObject var catalog: DocumentCatalog
    let onOpenEntry: (LibraryEntry) -> Void
    let onToggle: (LibraryFolderKey) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var contentPresent = false
    @State private var contentOpen = false
    @State private var naturalHeight: CGFloat = 0
    @State private var closeWork: DispatchWorkItem?
    @State private var syncGeneration = 0

    private var key: LibraryFolderKey { item.key }
    private var folder: LibraryFolder? {
        if case .folder(let folder) = item { return folder }
        return nil
    }
    private var entries: [LibraryEntry] {
        switch item {
        case .unsorted: catalog.unsortedEntries
        case .folder(let folder): catalog.entries(inFolder: folder.id)
        }
    }
    private var sortedEntries: [LibraryEntry] {
        catalog.sorted(entries, by: catalog.sortOrder(in: folder?.id))
    }
    private var childFolders: [LibraryFolder] {
        guard let folder else { return [] }
        return catalog.childFolders(of: folder.id)
    }
    private var isExpanded: Bool { expandedFolders.contains(key) }
    private var hasChildren: Bool { !entries.isEmpty || !childFolders.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: LibraryLook.sidebarRowSpacing) {
            row
            if contentPresent {
                VStack(alignment: .leading, spacing: LibraryLook.sidebarRowSpacing) {
                    // Subfolders come first, then the documents filed directly
                    // inside this folder, matching the order of the row list.
                    ForEach(childFolders) { child in
                        LibraryFolderBranch(item: .folder(child), depth: depth + 1,
                                            expandedFolders: expandedFolders,
                                            store: store, catalog: catalog,
                                            onOpenEntry: onOpenEntry,
                                            onToggle: onToggle)
                    }
                    ForEach(sortedEntries) { entry in
                        LibrarySidebarDocumentRow(
                            entry: entry,
                            indent: LibraryLook.sidebarDocumentIndent
                                + CGFloat(depth) * LibraryLook.sidebarIndentStep,
                            store: store, catalog: catalog,
                            onOpen: { onOpenEntry(entry) })
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .background(GeometryReader { proxy in
                    Color.clear.preference(key: LibraryBranchHeightKey.self,
                                           value: proxy.size.height)
                })
                .frame(height: contentOpen ? naturalHeight : 0, alignment: .top)
                .clipped()
                .opacity(contentOpen ? 1 : 0)
                .allowsHitTesting(contentOpen)
                .accessibilityHidden(!contentOpen)
                .onPreferenceChange(LibraryBranchHeightKey.self) { height in
                    guard height > 0, abs(height - naturalHeight) > 0.5 else { return }
                    naturalHeight = height
                }
            }
        }
        .onAppear { if isExpanded != contentPresent { sync(animated: false) } }
        .onChange(of: isExpanded) { _, _ in sync(animated: true) }
        .onDisappear { closeWork?.cancel() }
    }

    /// Mount the subtree first so its natural height is known, then animate the
    /// occupied height open. Closing animates the same height to zero before
    /// the subtree leaves the hierarchy, which keeps the removed rows clipped
    /// and lets rows below slide instead of jumping.
    private func sync(animated: Bool) {
        closeWork?.cancel()
        closeWork = nil
        syncGeneration &+= 1
        let generation = syncGeneration
        let animate = animated && !reduceMotion
        if isExpanded && hasChildren {
            if contentPresent {
                withAnimation(animate ? ChromeMotion.transition : nil) { contentOpen = true }
            } else {
                contentPresent = true
                contentOpen = false
                naturalHeight = 0
                DispatchQueue.main.async {
                    guard generation == syncGeneration, isExpanded, contentPresent else { return }
                    withAnimation(animate ? ChromeMotion.transition : nil) { contentOpen = true }
                }
            }
        } else if contentPresent {
            withAnimation(animate ? ChromeMotion.transition : nil) { contentOpen = false }
            let work = DispatchWorkItem {
                guard generation == syncGeneration, !isExpanded else { return }
                contentPresent = false
            }
            closeWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + (animate ? 0.26 : 0), execute: work)
        }
    }

    @ViewBuilder
    private var row: some View {
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
                isExpanded: isExpanded,
                store: store, catalog: catalog,
                onSelect: {
                    store.showLibrary(selection: .folder(nil), title: DocumentCatalog.unsortedTitle)
                },
                onToggle: { onToggle(.unsorted) }
            )
        case .folder(let folder):
            let index = catalog.folders.firstIndex(where: { $0.id == folder.id }) ?? 0
            LibraryFolderRow(
                key: .folder(folder.id),
                name: folder.name,
                symbol: "folder",
                tint: folder.color?.tint ?? LibraryLook.folderTints[index % LibraryLook.folderTints.count],
                count: catalog.entries(in: .folder(folder.id)).count,
                entries: entries,
                hasChildren: hasChildren,
                depth: depth,
                isSelected: store.librarySelection == .folder(folder.id),
                isExpanded: isExpanded,
                store: store, catalog: catalog,
                onSelect: {
                    store.showLibrary(selection: .folder(folder.id), title: folder.name)
                },
                onToggle: { onToggle(.folder(folder.id)) }
            )
        }
    }
}

private struct LibraryBranchHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
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
            .frame(height: LibraryLook.sidebarDocumentRowHeight)
            .contentShape(Rectangle())
        .padding(.leading, indent)
        .contentShape(Rectangle())
        .background {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Palette.primaryInk.opacity(hovered ? 0.08 : 0))
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
        .onContinuousHover { phase in
            switch phase {
            case .active: hovered = true
            case .ended: hovered = false
            }
        }
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
        .quillHelp(entry.path)
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
    @FocusState private var searchFocused: Bool
    @State private var searchFocusMonitor: Any?
    @State private var sortAscending = false
    @State private var contentWidth: CGFloat = 800

    private var totalEntries: [LibraryEntry] { catalog.entries(in: store.librarySelection) }

    /// A narrow window keeps the title, view switch, sort and search usable by
    /// dropping the document count and then the least useful date columns.
    private var compactHeader: Bool { contentWidth < 700 }
    private var veryCompact: Bool { contentWidth < 620 }
    private var showsCount: Bool { contentWidth >= 680 }
    private var showsAddedColumn: Bool { contentWidth >= 700 }
    private var showsLastViewedColumn: Bool { contentWidth >= 560 }
    private var headerInset: CGFloat { veryCompact ? 16 : LibraryLook.browserInset }
    private var searchWidth: CGFloat { veryCompact ? 132 : (compactHeader ? 168 : 196) }

    /// Folder views carry their own sort (set from the folder's context menu);
    /// other views keep the toolbar's sort.
    private var effectiveSort: LibrarySortOrder {
        if case .folder(let id) = store.librarySelection { return catalog.sortOrder(in: id) }
        return sort
    }

    private var sortBinding: Binding<LibrarySortOrder> {
        Binding(get: { effectiveSort }, set: { newSort in
            if case .folder(let id) = store.librarySelection {
                catalog.setSortOrder(newSort, in: id)
            }
            sort = newSort
        })
    }

    private var visibleEntries: [LibraryEntry] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return totalEntries }
        return totalEntries.filter { entry in
            entry.displayName.localizedCaseInsensitiveContains(query)
                || entry.path.localizedCaseInsensitiveContains(query)
        }
    }

    private var orderedEntries: [LibraryEntry] {
        catalog.sorted(visibleEntries, by: effectiveSort, ascending: sortAscending)
    }

    private var groups: [LibraryDateGroup] {
        // Name sorting has no dates, so it is one flat list. Date sorting groups
        // by the very date the user chose (Last Viewed / Updated / Created).
        guard let dateColumn else {
            return orderedEntries.isEmpty ? [] : [LibraryDateGroup(title: "", entries: orderedEntries)]
        }
        // Groups follow the arrow too: ascending shows Earlier before Today.
        return LibraryDateGrouping.groups(orderedEntries, date: dateColumn.value,
                                          ascending: sortAscending)
            .map { LibraryDateGroup(title: $0.title, entries: $0.items) }
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
        .background {
            GeometryReader { proxy in
                Color.clear.preference(key: LibraryContentWidthKey.self, value: proxy.size.width)
            }
        }
        .onPreferenceChange(LibraryContentWidthKey.self) { width in
            guard width > 0, abs(width - contentWidth) > 0.5 else { return }
            contentWidth = width
        }
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
        switch effectiveSort {
        case .manual, .name, .kind: nil
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
        HStack(alignment: .center, spacing: compactHeader ? 6 : 10) {
            newDocumentControl

            HStack(alignment: .firstTextBaseline, spacing: 9) {
                Text(browserTitle)
                    .font(.system(size: veryCompact ? 21 : 24, weight: .semibold))
                    .foregroundStyle(Palette.primaryInk)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if showsCount {
                    Text(countText)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Palette.secondaryInk)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: veryCompact ? 4 : 12)
            LibraryViewModeControl(mode: $viewMode)
            sortMenu
            searchField
        }
        .padding(.horizontal, headerInset)
        .padding(.top, 20)
        .padding(.bottom, 14)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12.5, weight: .regular))
                .foregroundStyle(Palette.secondaryInk)
            TextField("Search", text: $search)
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .font(.system(size: 13.5))
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
        .frame(width: searchWidth)
        .modifier(LibraryControlSurface())
        // Fill the whole pill on hover, not just the text area.
        .overlay {
            Capsule()
                .fill(Palette.primaryInk.opacity(searchHovered ? 0.05 : 0))
                .padding(4)
                .allowsHitTesting(false)
        }
        .onHover { searchHovered = $0 }
        .animation(.easeOut(duration: 0.15), value: searchHovered)
        // The window put the first text field into edit mode on open, leaving a
        // blinking caret in the Search pill before the user clicked anything.
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                if search.isEmpty { NSApp.keyWindow?.makeFirstResponder(nil) }
            }
        }
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                if search.isEmpty { searchFocused = false }
            }
            if searchFocusMonitor == nil {
                searchFocusMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { event in
                    if searchFocused, let window = event.window,
                       window.firstResponder is NSTextView,
                       let hit = window.contentView?.hitTest(event.locationInWindow) {
                        var clickedText = false
                        var view: NSView? = hit
                        while let current = view {
                            if current is NSTextField || current is NSTextView { clickedText = true; break }
                            view = current.superview
                        }
                        if !clickedText { searchFocused = false }
                    }
                    return event
                }
            }
        }
        .onDisappear {
            if let monitor = searchFocusMonitor { NSEvent.removeMonitor(monitor) }
            searchFocusMonitor = nil
        }
        .quillHelp("Filter documents by name or path")
    }

    private var sortMenu: some View {
        // Same quiet gray wash as the other capsules and the search pill.
        LibrarySortMenu(sort: sortBinding, ascending: $sortAscending,
                        showsAdded: true, folderOrders: true)
            // Same hover treatment as the neighbouring capsules.
            .modifier(CapsuleHoverWash())
    }

    private var columnHeader: some View {
        LibraryTableHeader(sort: sortBinding, ascending: $sortAscending,
                           trailingWidth: LibraryLook.rowActionsWidth,
                           showsAdded: showsAddedColumn,
                           showsLastViewed: showsLastViewedColumn,
                           inset: headerInset)
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
                            showsAdded: showsAddedColumn,
                            showsLastViewed: showsLastViewedColumn,
                            inset: headerInset,
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
            .padding(.horizontal, headerInset)
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
    var showsAdded = true
    var showsLastViewed = true
    var inset: CGFloat = LibraryLook.browserInset
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
        .padding(.trailing, inset)
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
                .padding(.leading, inset + LibraryLook.docTileSize.width + 11)
                .padding(.trailing, inset)
        }
        .onContinuousHover { phase in
            switch phase {
            case .active: hovered = true
            case .ended: hovered = false
            }
        }
        .animation(.easeOut(duration: 0.12), value: hovered)
        .modifier(LibraryEntryContextMenu(store: store, catalog: catalog, entry: entry, onOpen: onOpen))
        .quillHelp(entry.path)
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
                               added: showsAdded ? entry.addedAt : nil,
                               updated: entry.updatedAt ?? entry.addedAt,
                               created: entry.createdOnDiskAt ?? entry.addedAt,
                               showsLastViewed: showsLastViewed)
        }
        .padding(.leading, inset)
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
                    if !catalog.isMissing(entry),
                       LibraryThumbnailStore.pdfURL(for: entry,
                           outputDirectory: BuildSettings.shared.outputDirectory) == nil {
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
    let onCreate: (String, String, DocumentTemplate?, URL) -> Void

    @State private var name = "Untitled"
    @State private var projectName = ""
    @State private var selectedTemplateID: String?
    @State private var destination: URL
    @FocusState private var nameFocused: Bool

    init(templates: [DocumentTemplate], directory: URL,
         onDismiss: @escaping () -> Void,
         onCreate: @escaping (String, String, DocumentTemplate?, URL) -> Void) {
        self.templates = templates
        self.directory = directory
        self.onDismiss = onDismiss
        self.onCreate = onCreate
        _destination = State(initialValue: directory)
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var fileBaseName: String {
        trimmedName.lowercased().hasSuffix(".tex")
            ? (trimmedName as NSString).deletingPathExtension : trimmedName
    }

    private var selectedTemplate: DocumentTemplate? {
        templates.first { $0.id == selectedTemplateID }
    }

    private var canCreate: Bool {
        !fileBaseName.isEmpty
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                QuillDialogBackdrop()
                    .onTapGesture(perform: onDismiss)
                QuillDialogCard(title: "New Document",
                                width: min(390, max(340, geometry.size.width * 0.56)),
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
            QuillDialogFieldLabel("File Name")
            QuillDialogField {
                TextField("File name", text: $name)
                    .textFieldStyle(.plain)
                    .focused($nameFocused)
                    .onSubmit(create)
            }
            .padding(.top, 7)

            QuillDialogFieldLabel("Project Name")
                .padding(.top, 16)
            QuillDialogField {
                TextField(fileBaseName.isEmpty ? "Project name" : fileBaseName,
                          text: $projectName)
                    .textFieldStyle(.plain)
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
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Palette.primaryInk)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(Palette.secondaryInk)
                    }
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .padding(.horizontal, 12)
                .frame(minHeight: 28)
                // Same capsule and the same hover feedback as the Choose… button
                // beside it (SettingsActionStyle uses ChromeHoverFeedback).
                .background(Capsule().fill(Color.black.opacity(0.025)))
                .overlay(Capsule().strokeBorder(Color.black.opacity(0.12), lineWidth: 1))
                .contentShape(Capsule())
                .modifier(CapsuleHoverWash())
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
        let customName = projectName.trimmingCharacters(in: .whitespacesAndNewlines)
        onCreate(fileBaseName, customName.isEmpty ? fileBaseName : customName, selectedTemplate, destination)
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
        case .manual, .name, .kind: nil
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
        case .manual:
            sorted = filtered
        case .name:
            sorted = filtered.sorted { $0.displayTitle.localizedCaseInsensitiveCompare($1.displayTitle) == .orderedAscending }
        case .kind:
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
        // Base order is already the field's natural direction: names ascend,
        // dates descend. Reverse only when the arrow asks for the other one.
        guard sort != .manual, sortAscending != sort.defaultAscending else { return sorted }
        return sorted.reversed()
    }

    private var groupedTemplates: [(title: String, templates: [DocumentTemplate])] {
        guard let column = dateColumn else {
            return visibleTemplates.isEmpty ? [] : [("", visibleTemplates)]
        }
        return LibraryDateGrouping.groups(visibleTemplates,
                                          date: { templateDate($0, column: column) },
                                          ascending: sortAscending)
            .map { ($0.title, $0.items) }
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
        // Same quiet gray wash as the other capsules and the search pill.
        LibrarySortMenu(sort: $sort, ascending: $sortAscending, showsAdded: false)
            // Same hover treatment as the neighbouring capsules.
            .modifier(CapsuleHoverWash())
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
            Button("Open in New Tab") { store.openTemplate(template, inNewTab: true) }
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
            Button("Open in New Tab") { store.openTemplate(template, inNewTab: true) }
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
                    createCard("Open Document", detail: "Add a local file or folder", symbol: "folder", shortcut: "⌘O", action: onOpen)
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
                                            Text(libraryEntrySubtitle(entry, catalog: catalog)).font(.system(size: 10))
                                                .foregroundStyle(Palette.secondaryInk).lineLimit(1)
                                                .truncationMode(.middle)
                                        }
                                        Spacer(minLength: 0)
                                    }
                                    .padding(.horizontal, 8).frame(height: 40)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(QuillRowButtonStyle(cornerRadius: LibraryLook.sidebarCorner))
                                .contextMenu {
                                    Button("Open in New Tab") {
                                        store.openLibraryEntry(entry, inNewTab: true)
                                    }
                                }

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
                                            Text(libraryEntrySubtitle(entry, catalog: catalog))
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
                                .contextMenu {
                                    Button("Open in New Tab") {
                                        store.openLibraryEntry(entry, inNewTab: true)
                                    }
                                }

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
