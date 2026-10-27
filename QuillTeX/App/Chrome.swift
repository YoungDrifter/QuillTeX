import SwiftUI
import AppKit

/// White surfaces and black ink; secondary copy retains native subdued labels.
/// The ink levels, hairline and control surfaces mirror PaperLens 1.0.3 so the
/// two apps share one visual language.
enum Palette {
    static let accent = Color.black
    static let primaryInk = Color(white: 0.13)
    static let secondaryInk = Color(white: 0.46)
    static let subtleSurface = Color(white: 0.965)
    static let controlSurface = Color(white: 0.985)
    static let hairline = Color.black.opacity(0.085)
    static let selectedOpacity: Double = 0.10
    static let pressedOpacity: Double = 0.14
    static let chromeHoverOpacity: Double = 0.05

    static let topBar = controlSurface
    static let sidebarTop = subtleSurface
    static let sidebarBottom = subtleSurface
    static let previewHeader = controlSurface
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
    static let segmentedButtonWidth: CGFloat = 50
    /// Chrome glyphs and the circular hit area every top-bar control uses.
    static let chromeIconSize: CGFloat = 18
    /// Horizontal padding of a capsule control group; the group hugs the 38 pt
    /// buttons vertically, like PaperLens 1.0.3.
    static let chromeGroupInset: CGFloat = 4
    static let chromeSpacing: CGFloat = 2
    /// Keep the visible state inset from the full-size click target.
    static let buttonSurfaceInset: CGFloat = 3
    /// Shared radius and padding for app-owned floating panels.
    static let panelCornerRadius: CGFloat = 12
    static let panelPadding: CGFloat = 16
    static let popoverWidth: CGFloat = 320
    static let popoverLabelWidth: CGFloat = 54
    static let popoverControlHeight: CGFloat = 34
    static let sidebarModeSlotWidth: CGFloat = 52
    static let sidebarIconWidth: CGFloat = 18
    static let sidebarRowHeight: CGFloat = 30
    static let sidebarDisclosureWidth: CGFloat = 18
    static let groupedButtonSize = controlHeight
    /// Both pane headers (breadcrumb and PDF title) share this height so their titles
    /// sit on one line and their bottom rules line up.
    static let paneHeaderHeight: CGFloat = 36
    static let previewControlHeight: CGFloat = 28
    static let previewActionWidth: CGFloat = 30
    static let zoomInputWidth: CGFloat = 60
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

enum ChromeMotion {
    static let feedback = Animation.easeOut(duration: 0.14)
    static let press = Animation.spring(response: 0.24, dampingFraction: 0.82)
    static let transition = Animation.smooth(duration: 0.24)
}

extension View {
    func quillCapsule(selected: Bool = false) -> some View {
        modifier(QuillCapsuleSurface(emphasized: selected))
    }
}

private struct QuillCapsuleSurface: ViewModifier {
    var emphasized: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    func body(content: Content) -> some View {
        content.background {
            if #available(macOS 26.0, *), !reduceTransparency {
                Capsule().fill(.clear).glassEffect(.regular, in: Capsule())
            } else {
                Capsule().fill(Palette.controlSurface)
                    .overlay(Capsule().fill(LinearGradient(
                        colors: [.white.opacity(0.9), .white.opacity(0.1)], startPoint: .top, endPoint: .bottom)))
                    .overlay(Capsule().strokeBorder(Palette.hairline, lineWidth: 0.7))
            }
        }
        .overlay(Capsule().strokeBorder(Color.black.opacity(emphasized ? 0.16 : 0), lineWidth: 0.7).allowsHitTesting(false))
    }
}

struct ChromeButton: View {
    let icon: String
    let label: String
    var selected = false
    var width: CGFloat = ChromeMetrics.controlHeight
    var selectionNamespace: Namespace.ID? = nil
    /// Standalone controls keep their own capsule; grouped ones rely on the
    /// group's capsule so the bar reads as a few quiet clusters.
    var standalone = false
    var iconOffsetY: CGFloat = 0
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: ChromeMetrics.chromeIconSize, weight: .regular))
                .symbolRenderingMode(.monochrome)
                .offset(y: iconOffsetY)
                .frame(width: width, height: ChromeMetrics.controlHeight)
                .contentShape(Capsule())
        }
        .buttonStyle(ChromeButtonStyle(selected: selected, selectionNamespace: selectionNamespace))
        .modifier(ChromeHoverFeedback(selected: selected))
        .chromeControlBoundary()
        .help(label).accessibilityLabel(label)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .modifier(OptionalCapsule(enabled: standalone))
    }
}

private struct OptionalCapsule: ViewModifier {
    let enabled: Bool
    @ViewBuilder func body(content: Content) -> some View { if enabled { content.quillCapsule() } else { content } }
}
struct TopBar: View {
    @State private var showingFileInfo = false
    @State private var showingRecents = false
    @ObservedObject var store: ProjectStore
    private var titleWidth: CGFloat {
        let name = store.activeDocument?.url.deletingPathExtension().lastPathComponent ?? "QuillTeX"
        let width = (name as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 13, weight: .medium)]).width
        return min(240, ceil(width) + 30)
    }

    /// Fixed chrome the title has to leave room for: window controls, sidebar
    /// toggle, navigation group, build controls, pane switcher and the trailing
    /// recents/settings capsule. PaperLens recomputes the same budget when a
    /// control is added; the number moved by the clock button's slot.
    private static let fixedChromeWidth: CGFloat = 894

    var body: some View {
        ChromeHostingContainer(content:
            GeometryReader { geometry in
                let compact = geometry.size.width < 1100
                let segmentWidth = ChromeMetrics.segmentedButtonWidth
                // Document navigation precedes the title, which keeps a small leading gap.
                HStack(spacing: compact ? 4 : 6) {
                    Color.clear.frame(width: store.isFullScreen ? ChromeMetrics.controlsInsetFullScreen : ChromeMetrics.controlsInset)
                    ChromeButton(icon: "sidebar.left", label: "Show or Hide Sidebar") { store.sidebarVisible.toggle() }
                    HStack(spacing: ChromeMetrics.chromeSpacing) {
                        ChromeButton(icon: "plus", label: "Open a TeX File in This Project") { store.showFilePicker = true }.disabled(store.root == nil)
                            .popover(isPresented: $store.showFilePicker) { ProjectFilePicker(store: store) }
                        ChromeButton(icon: "rectangle.topthird.inset", label: store.isTabBarVisible ? "Hide Tab Bar" : "Show Tab Bar",
                                     selected: store.isTabBarVisible) { store.toggleTabBar() }
                            .accessibilityValue(store.isTabBarVisible ? "Shown" : "Hidden")
                        Divider().frame(height: 14).padding(.horizontal, 2)
                        ChromeButton(icon: "chevron.left", label: "Back") { store.moveHistory(-1) }.disabled(!store.canGoBack)
                        ChromeButton(icon: "chevron.right", label: "Forward") { store.moveHistory(1) }.disabled(!store.canGoForward)
                    }.padding(.horizontal, ChromeMetrics.chromeGroupInset).quillCapsule().chromeControlGroup()
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
                            .frame(maxWidth: min(titleWidth, max(48, geometry.size.width - Self.fixedChromeWidth)))
                            .frame(height: ChromeMetrics.controlHeight)
                            .padding(.horizontal, 10)
                            .contentShape(Capsule())
                            .help(store.activeDocument?.url.lastPathComponent ?? "QuillTeX")
                            .layoutPriority(-1)
                        }
                        .buttonStyle(ChromeButtonStyle())
                        .modifier(ChromeHoverFeedback())
                        .chromeControlBoundary()
                        .onChange(of: store.activeID) { _, _ in showingFileInfo = false }
                        .disabled(store.activeDocument == nil)
                        .popover(isPresented: $showingFileInfo) {
                            if let url = store.activeDocument?.url {
                                DocumentFileInfoPopover(url: url, update: store.updateActiveFile) { showingFileInfo = false }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .layoutPriority(-1)
                    BuildControls(store: store).fixedSize(horizontal: true, vertical: false)
                    ChromeSegmentedGroup(selection: store.paneMode) { paneSelection in
                        ChromeButton(icon: "rectangle", label: "Editor Only", selected: store.paneMode == .editor,
                                     width: segmentWidth, selectionNamespace: paneSelection) { store.paneMode = .editor }
                        // The wash marks the PDF side, matching PDF Only — so the split
                        // icon fills its right half.
                        ChromeButton(icon: store.paneMode == .split ? "rectangle.lefthalf.inset.filled" : "rectangle.righthalf.inset.filled", label: "Editor and PDF", selected: store.paneMode == .split,
                                     width: segmentWidth, selectionNamespace: paneSelection) { store.showEditorAndPDF() }
                        ChromeButton(icon: "rectangle.fill", label: "PDF Only", selected: store.paneMode == .preview,
                                     width: segmentWidth, selectionNamespace: paneSelection) { store.paneMode = .preview }
                    }.padding(.horizontal, ChromeMetrics.chromeGroupInset).quillCapsule().chromeControlGroup()
                    // Recents and Settings share the trailing capsule group. Both
                    // open a native popover, like the compile settings and the
                    // document title popovers.
                    HStack(spacing: ChromeMetrics.chromeSpacing) {
                        ChromeButton(icon: "clock", label: "Recent Projects") { showingRecents.toggle() }
                            .popover(isPresented: $showingRecents) {
                                RecentProjectsView(store: store, library: store.library, onClose: { showingRecents = false })
                            }
                        SettingsLink {
                            Image(systemName: "gearshape").font(.system(size: ChromeMetrics.chromeIconSize, weight: .regular))
                                .foregroundStyle(Palette.primaryInk)
                                .frame(width: ChromeMetrics.controlHeight, height: ChromeMetrics.controlHeight).contentShape(Circle())
                        }
                        .buttonStyle(ChromeButtonStyle())
                        .modifier(ChromeHoverFeedback())
                        .chromeControlBoundary()
                        .help("Settings")
                        .accessibilityLabel("Settings")
                    }
                    .padding(.horizontal, ChromeMetrics.chromeGroupInset).quillCapsule().chromeControlGroup()
                }
                .padding(.horizontal, 10).frame(height: ChromeMetrics.topBarHeight)
                .background(Palette.topBar)
                .overlay(alignment: .bottom) { Divider() }
            }
            .frame(height: ChromeMetrics.topBarHeight)
        ).frame(height: ChromeMetrics.topBarHeight)
    }
}

struct FileTabBar: View {
    @ObservedObject var store: ProjectStore
    @State private var draggedID: UUID?
    var body: some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 2) {
                        ForEach(Array(store.documents.enumerated()), id: \.element.id) { index, document in
                            FileTab(document: document, store: store, draggedID: $draggedID,
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
                        .coordinateSpace(name: "fileTabs")
                }
                .onChange(of: store.activeID) { _, id in if let id { proxy.scrollTo(id) } }
            }
        }
        .frame(height: 32)
        .background(Palette.subtleSurface)
        .overlay(alignment: .bottom) { Divider() }
    }
}

private struct FileTab: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false
    @ObservedObject var document: SourceDocument
    @ObservedObject var store: ProjectStore
    @Binding var draggedID: UUID?
    let width: CGFloat
    @ViewBuilder var body: some View {
        if document.url == store.root { content }
        else {
            content.highPriorityGesture(
                DragGesture(minimumDistance: 6, coordinateSpace: .named("fileTabs"))
                    .onChanged { value in
                        draggedID = document.id
                        let target = Int(max(0, value.location.x - 8) / (width + 2))
                        withAnimation(reduceMotion ? nil : ChromeMotion.feedback) {
                            store.moveTab(document.id, to: target)
                        }
                    }
                    .onEnded { _ in draggedID = nil }
            )
            .accessibilityAction(named: Text("Move Tab Left")) { move(-1) }
            .accessibilityAction(named: Text("Move Tab Right")) { move(1) }
        }
    }
    private func move(_ delta: Int) {
        if let index = store.documents.firstIndex(where: { $0.id == document.id }) { store.moveTab(document.id, to: index + delta) }
    }
    private var content: some View {
        HStack(spacing: 7) {
            Group {
                if document.url != store.root {
                    Button { store.close(document) } label: {
                        Image(systemName: "xmark").font(.system(size: 9)).foregroundStyle(.secondary)
                            .frame(width: 20, height: 20).contentShape(Rectangle())
                    }.buttonStyle(QuillRowButtonStyle(cornerRadius: 10)).help("Close \(document.url.lastPathComponent)")
                        .opacity(hovering ? 1 : 0).allowsHitTesting(hovering)
                } else { Color.clear.frame(width: 20, height: 20) }
            }
            Button { if draggedID == nil { store.activate(document) } } label: {
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
        .background(Capsule().fill(store.activeID == document.id ? Palette.controlSurface : Color.black.opacity(hovering ? 0.04 : 0)))
        .overlay { Capsule().strokeBorder(Color.black.opacity(store.activeID == document.id ? 0.10 : 0), lineWidth: 0.7) }
        .shadow(color: .black.opacity(store.activeID == document.id ? 0.035 : 0), radius: 2, y: 1)
        .onHover { hovering = $0 }
        .animation(reduceMotion ? nil : ChromeMotion.feedback, value: hovering)
        .animation(reduceMotion ? nil : ChromeMotion.feedback, value: store.activeID)
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
            QuillPopoverTitle("Open Project File")
            TextField("Search .tex files", text: $query).textFieldStyle(.roundedBorder).controlSize(.large)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(files, id: \.self) { file in
                        Button {
                            // Revalidate against symlink changes since indexing.
                            guard let directory = store.directory, ProjectIndexer.isWithin(file, directory: directory) else { return }
                            store.openSource(file); store.showFilePicker = false
                        } label: {
                            QuillPopupRowLabel(symbol: "doc.text",
                                               title: file.lastPathComponent,
                                               subtitle: store.relativePath(file.deletingLastPathComponent()))
                                .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(QuillRowButtonStyle())
                    }
                    if files.isEmpty { Text("No matching .tex files").foregroundStyle(.secondary).padding(8) }
                }
                .padding(8)
            }.frame(height: 250)
        }.frame(width: ChromeMetrics.popoverWidth).quillPopoverContent()
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
        VStack(alignment: .leading, spacing: 16) {
            QuillPopoverTitle("File Information")
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 12) {
                GridRow {
                    Text("Name").foregroundStyle(.secondary)
                    TextField("File name", text: $name).textFieldStyle(.roundedBorder)
                        .focused($nameFocused).onSubmit(apply)
                }
                GridRow {
                    Text("Tags").foregroundStyle(.secondary)
                    TextField("Separate tags with commas", text: $tags).textFieldStyle(.roundedBorder).onSubmit(apply)
                }
                if let error { Text(error).foregroundStyle(.red).gridCellColumns(2).fixedSize(horizontal: false, vertical: true) }
                HStack {
                    Spacer()
                    Button("Cancel", action: dismiss).buttonStyle(SettingsActionStyle())
                    Button("Done", action: apply).buttonStyle(SettingsActionStyle()).keyboardShortcut(.defaultAction)
                }.gridCellColumns(2)
            }
        }
        .frame(width: ChromeMetrics.popoverWidth).quillPopoverContent()
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
