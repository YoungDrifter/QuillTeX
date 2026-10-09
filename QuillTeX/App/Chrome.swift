import SwiftUI
import AppKit

/// White surfaces and black ink; secondary copy retains native subdued labels.
enum Palette {
    static let accent = Color.black
    static let topBar = Color.white
    static let sidebarTop = Color.white
    static let sidebarBottom = Color.white
    static let previewHeader = Color.white
    static let previewCanvas = Color.white
    static let welcomeLeft = Color.white
    static let welcomeRight = Color.white
    static let brandText = Color.black
    static let headline = Color.black
    /// Selection wash used by the sidebar and the template chooser.
    static let selection = Color.white.opacity(0.68)
    static let selectionSoft = Color(white: 0).opacity(0.055)
}

/// Shared chrome measurements. `TopBar` and the window hook both use these so the
/// traffic lights stay on the top bar's centre line.
enum ChromeMetrics {
    static let topBarHeight: CGFloat = 54
    static let controlHeight: CGFloat = 38
    static let groupInset: CGFloat = 3
    static let groupedButtonSize = controlHeight - 2 * groupInset
    /// Both pane headers (breadcrumb and PDF title) share this height so their titles
    /// sit on one line and their bottom rules line up.
    static let paneHeaderHeight: CGFloat = 36
    /// The window controls draw their coloured circles about a point above the centre
    /// of their frames (the frames carry a shadow margin). Measured from screenshots,
    /// so the circles land on the top bar's centre line rather than a hair above it.
    static let trafficLightOpticalOffset: CGFloat = 1.2
    /// Leading space that keeps the top bar clear of the window controls.
    static let controlsInset: CGFloat = 76
    /// Window controls sit a little further from the window edge than AppKit puts them.
    static let controlsHorizontalOffset: CGFloat = 5
    /// Full screen hides the window controls, so the bar moves over instead.
    static let controlsInsetFullScreen: CGFloat = 8

    /// Windows always open windowed and centred on the screen. The launcher is a little
    /// smaller than the document window, and both can be resized and remembered after.
    static let welcomeWindowSize = CGSize(width: 780, height: 520)
    static let workspaceWindowSize = CGSize(width: 1280, height: 820)
    static let welcomeMinimumSize = CGSize(width: 720, height: 480)
    /// The workspace never shrinks below this: any smaller and the editor and the
    /// preview both get too narrow to read. Width matches the size the window is
    /// normally used at.
    static let workspaceMinimumSize = CGSize(width: 960, height: 700)
}

extension View {
    @ViewBuilder func quillCapsule(selected: Bool = false) -> some View {
        self.background(Color.white, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.black.opacity(selected ? 0.22 : 0.10), lineWidth: 0.7).allowsHitTesting(false))
    }
}

struct ChromeButton: View {
    let icon: String
    let label: String
    var selected = false
    var standalone = false
    var iconOffsetY: CGFloat = 0
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 17, weight: .regular))
                .offset(y: iconOffsetY)
                .frame(width: standalone ? ChromeMetrics.controlHeight : ChromeMetrics.groupedButtonSize,
                       height: standalone ? ChromeMetrics.controlHeight : ChromeMetrics.groupedButtonSize)
                .foregroundStyle(Color.black)
                .background(Capsule().fill(selected ? Color.primary.opacity(0.05) : (hover ? Color.primary.opacity(0.05) : .clear)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain).help(label).accessibilityLabel(label)
        .onHover { hover = $0 }
        .modifier(OptionalCapsule(enabled: standalone))
    }
}
private struct OptionalCapsule: ViewModifier {
    let enabled: Bool
    @ViewBuilder func body(content: Content) -> some View { if enabled { content.quillCapsule() } else { content } }
}

struct TopBar: View {
    @State private var showingFileInfo = false
    @ObservedObject var store: ProjectStore
    private var titleWidth: CGFloat {
        let name = store.activeDocument?.url.deletingPathExtension().lastPathComponent ?? "QuillTeX"
        let width = (name as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 13, weight: .medium)]).width
        return min(240, ceil(width) + 30)
    }

    var body: some View {
        GeometryReader { geometry in
            // Document navigation precedes the title, which keeps a small leading gap.
            HStack(spacing: 6) {
                Color.clear.frame(width: store.isFullScreen ? ChromeMetrics.controlsInsetFullScreen : ChromeMetrics.controlsInset)
                ChromeButton(icon: "sidebar.left", label: "Show or Hide Sidebar", standalone: true) { store.sidebarVisible.toggle() }
                HStack(spacing: 2) {
                    ChromeButton(icon: "macwindow.badge.plus", label: "Open a TeX File in This Project") { store.showFilePicker = true }.disabled(store.root == nil)
                        .popover(isPresented: $store.showFilePicker) { ProjectFilePicker(store: store) }
                    ChromeButton(icon: "rectangle.topthird.inset.filled", label: store.isTabBarVisible ? "Hide Tab Bar" : "Show Tab Bar",
                                 selected: store.isTabBarVisible, iconOffsetY: -2) { store.toggleTabBar() }
                        .accessibilityValue(store.isTabBarVisible ? "Shown" : "Hidden")
                    Divider().frame(height: 14).padding(.horizontal, 2)
                    ChromeButton(icon: "chevron.left", label: "Back") { store.moveHistory(-1) }.disabled(!store.canGoBack)
                    ChromeButton(icon: "chevron.right", label: "Forward") { store.moveHistory(1) }.disabled(!store.canGoForward)
                }.padding(ChromeMetrics.groupInset).quillCapsule()
                ZStack {
                    Button { showingFileInfo.toggle() } label: {
                        HStack(spacing: 5) {
                            if store.activeDocument?.isDirty == true {
                                Circle().fill(Color.secondary).frame(width: 6, height: 6)
                            }
                            Text(store.activeDocument?.url.deletingPathExtension().lastPathComponent ?? "QuillTeX")
                                .font(.system(size: 13, weight: .medium))
                                .lineLimit(1).truncationMode(.middle)
                                .alignmentGuide(VerticalAlignment.center) { dimensions in
                                    dimensions[.firstTextBaseline] - NSFont.systemFont(ofSize: 13, weight: .medium).capHeight / 2
                                }
                            Image(systemName: "chevron.down").font(.system(size: 9)).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: min(titleWidth, max(100, geometry.size.width - 854)))
                        .frame(height: 38)
                        .help(store.activeDocument?.url.lastPathComponent ?? "QuillTeX")
                        .layoutPriority(-1)
                    }
                    .buttonStyle(.plain)
                    .onChange(of: store.activeID) { _, _ in showingFileInfo = false }
                    .disabled(store.activeDocument == nil)
                    .popover(isPresented: $showingFileInfo) {
                        if let url = store.activeDocument?.url {
                            DocumentFileInfoPopover(url: url, update: store.updateActiveFile) { showingFileInfo = false }
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                BuildControls(store: store)
                HStack(spacing: 2) {
                    ChromeButton(icon: "rectangle", label: "Editor Only", selected: store.paneMode == .editor) { store.paneMode = .editor }
                    ChromeButton(icon: "rectangle.lefthalf.inset.filled", label: "Editor and PDF", selected: store.paneMode == .split) { store.showEditorAndPDF() }
                    ChromeButton(icon: "rectangle.fill", label: "PDF Only", selected: store.paneMode == .preview) { store.paneMode = .preview }
                }.padding(ChromeMetrics.groupInset).quillCapsule()
                // Settings live at the far right, next to the view switcher.
                SettingsLink {
                    Image(systemName: "gearshape").font(.system(size: 17, weight: .regular))
                        .frame(width: ChromeMetrics.groupedButtonSize, height: ChromeMetrics.groupedButtonSize).contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("Settings")
                .accessibilityLabel("Settings")
                .padding(ChromeMetrics.groupInset).quillCapsule()
            }
            .padding(.horizontal, 10).frame(height: ChromeMetrics.topBarHeight)
            .background(Palette.topBar)
            .overlay(alignment: .bottom) { Divider() }
        }
        .frame(height: ChromeMetrics.topBarHeight)
    }
}

struct FileTabBar: View {
    @ObservedObject var store: ProjectStore
    var body: some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 2) {
                        ForEach(Array(store.documents.enumerated()), id: \.element.id) { index, document in
                            FileTab(document: document, store: store,
                                    width: max(140, (geometry.size.width - 16) / CGFloat(max(store.documents.count, 1)) - 2))
                                .overlay(alignment: .trailing) {
                                    if index + 1 < store.documents.count,
                                       store.activeID != document.id,
                                       store.activeID != store.documents[index + 1].id {
                                        RoundedRectangle(cornerRadius: 0.5).fill(Color.black.opacity(0.18))
                                            .frame(width: 1, height: 16).offset(x: 1)
                                            .allowsHitTesting(false).accessibilityHidden(true)
                                    }
                                }
                                .id(document.id)
                        }
                    }.padding(.horizontal, 8).padding(.vertical, 2)
                }
                .onChange(of: store.activeID) { _, id in if let id { proxy.scrollTo(id) } }
            }
        }
        .frame(height: 32)
        .background { Capsule().fill(Color.black.opacity(0.055)).padding(.horizontal, 8).padding(.vertical, 2) }
        .overlay(alignment: .bottom) { Divider() }
    }
}

private struct FileTab: View {
    @State private var hovering = false
    @ObservedObject var document: SourceDocument
    @ObservedObject var store: ProjectStore
    let width: CGFloat
    var body: some View {
        HStack(spacing: 7) {
            Group {
                if document.url != store.root {
                    Button { store.close(document) } label: {
                        Image(systemName: "xmark").font(.system(size: 9)).foregroundStyle(.secondary)
                            .frame(width: 20, height: 20).contentShape(Rectangle())
                    }.buttonStyle(.plain).help("Close \(document.url.lastPathComponent)")
                        .opacity(hovering ? 1 : 0).allowsHitTesting(hovering)
                } else { Color.clear.frame(width: 20, height: 20) }
            }
            Button { store.activate(document) } label: {
                HStack(spacing: 5) {
                    if document.isDirty {
                        Circle().fill(Color.primary.opacity(0.55)).frame(width: 6, height: 6)
                            .accessibilityLabel("Unsaved changes")
                    }
                    Text(document.url.deletingPathExtension().lastPathComponent)
                        .lineLimit(1).truncationMode(.middle)
                        .font(.system(size: 12, weight: store.activeID == document.id ? .medium : .regular))
                }.frame(maxWidth: .infinity).contentShape(Rectangle())
            }.buttonStyle(.plain)
            Color.clear.frame(width: 20, height: 20)
        }
        .padding(.horizontal, 12).frame(width: width, height: 28)
        .background(Capsule().fill(store.activeID == document.id ? Color.white : Color.clear))
        .overlay { Capsule().strokeBorder(Color.black.opacity(store.activeID == document.id ? 0.10 : 0), lineWidth: 0.7) }
        .onHover { hovering = $0 }
        .help(store.relativePath(document.url))
        .accessibilityElement(children: .contain)
    }
}

private struct ProjectFilePicker: View {
    @ObservedObject var store: ProjectStore
    @State private var query = ""
    private var files: [URL] {
        store.index.texFiles.filter { query.isEmpty || store.relativePath($0).localizedCaseInsensitiveContains(query) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Open Project File").font(.headline)
            TextField("Search .tex files", text: $query).textFieldStyle(.roundedBorder)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3) {
                    ForEach(files, id: \.self) { file in
                        Button {
                            // Revalidate against symlink changes since indexing.
                            guard let directory = store.directory, ProjectIndexer.isWithin(file, directory: directory) else { return }
                            store.openSource(file); store.showFilePicker = false
                        } label: {
                            Label(store.relativePath(file), systemImage: "doc.text").font(.system(size: 12))
                                .frame(maxWidth: .infinity, alignment: .leading).padding(7).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                    if files.isEmpty { Text("No matching .tex files").foregroundStyle(.secondary).padding(8) }
                }
            }.frame(height: 250)
        }.padding(16).frame(width: 340)
    }
}

/// File metadata editor presented from the document title.
private struct DocumentFileInfoPopover: View {
    let url: URL
    let update: (URL, [String]) throws -> Void
    let dismiss: () -> Void
    @State private var name = ""
    @State private var tags = ""
    @State private var error: String?
    @FocusState private var nameFocused: Bool
    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 12) {
            GridRow {
                Text("Name:").foregroundStyle(.secondary)
                TextField("File name", text: $name).textFieldStyle(.roundedBorder)
                    .focused($nameFocused).onSubmit(apply)
            }
            GridRow {
                Text("Tags:").foregroundStyle(.secondary)
                TextField("Separate tags with commas", text: $tags).textFieldStyle(.roundedBorder).onSubmit(apply)
            }
            if let error { Text(error).foregroundStyle(.red).gridCellColumns(2).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Spacer()
                Button("Cancel", action: dismiss)
                Button("Done", action: apply).keyboardShortcut(.defaultAction)
            }.gridCellColumns(2)
        }
        .padding(18).frame(width: 380)
        .onAppear {
            name = url.lastPathComponent
            tags = ((try? url.resourceValues(forKeys: [.tagNamesKey]).tagNames) ?? []).joined(separator: ", ")
            nameFocused = true
        }
    }
    private func apply() {
        do {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed != ".", trimmed != "..", !trimmed.contains("/"), !trimmed.contains("\0") else {
                throw NSError(domain: "DocumentName", code: 1, userInfo: [NSLocalizedDescriptionKey: "Enter a valid file name."])
            }
            let destination = url.deletingLastPathComponent().appendingPathComponent(trimmed)
            let names = Array(NSOrderedSet(array: tags.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })) as? [String] ?? []
            try update(destination, names)
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
