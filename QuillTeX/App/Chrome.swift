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
    static let sidebarSurface = Color(white: 0.945)
    /// The blurred sidebar material carries the desktop colour on its own. No
    /// white veil is laid over it, so the wallpaper tint reads a little more
    /// strongly while the material's blur keeps background text illegible.
    static let sidebarVeil = Color.white.opacity(0.0)
    static let controlSurface = Color(white: 0.985)
    static let hairline = Color.black.opacity(0.085)
    /// Opaque separator for dividers that sit over a behind-window material.
    static let hairlineSolid = Color(white: 0.93)
    /// Boundary between the content top bar and the panes below it. A little
    /// stronger than `hairline` so the bar reads as a separate row on white.
    static let chromeDivider = Color.black.opacity(0.12)
    static let selectedOpacity: Double = 0.10
    static let pressedOpacity: Double = 0.14
    static let chromeHoverOpacity: Double = 0.05

    static let topBar = Color.white
    static let sidebarTop = sidebarSurface
    static let sidebarBottom = sidebarSurface
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
    static let topBarHeight: CGFloat = 46
    /// Buttons shared by the content top bar and the sidebar navigation row.
    static let chromeControlHeight: CGFloat = 32
    static let segmentedButtonWidth: CGFloat = 46
    /// Chrome glyphs and the circular hit area every top-bar control uses.
    static let chromeIconSize: CGFloat = 16
    /// Horizontal padding of a capsule control group; the group hugs the 32 pt
    /// buttons vertically, like PaperLens 1.0.3.
    static let chromeGroupInset: CGFloat = 4
    static let chromeSpacing: CGFloat = 2
    /// Keep the visible state inset from the full-size click target.
    static let buttonSurfaceInset: CGFloat = 3
    /// Shared radius and padding for app-owned floating panels.
    static let panelCornerRadius: CGFloat = 12
    static let popupRowCornerRadius: CGFloat = 8
    static let panelPadding: CGFloat = 16
    static let popoverWidth: CGFloat = 320
    static let popoverLabelWidth: CGFloat = 54
    static let popoverControlHeight: CGFloat = 34
    static let sidebarModeSlotWidth: CGFloat = 52
    static let sidebarIconWidth: CGFloat = 18
    static let sidebarRowHeight: CGFloat = 30
    static let sidebarDisclosureWidth: CGFloat = 18
    /// Small document page icon shared by the library sidebar and the tab strip:
    /// near-square with a clearly rounded corner, instead of a tall page.
    static let documentPageIconSize = CGSize(width: 20, height: 22)
    static let documentPageIconCornerRadius: CGFloat = 5
    /// Both pane headers (breadcrumb and PDF title) share this height so their titles
    /// sit on one line and their bottom rules line up.
    static let paneHeaderHeight: CGFloat = 54
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
    static let pressedScale: CGFloat = 0.98
    static let feedback = Animation.easeOut(duration: 0.14)
    static let press = Animation.spring(response: 0.24, dampingFraction: 0.82)
    static let transition = Animation.smooth(duration: 0.24)
    /// One tab-change motion shared by the tab strip and the pane content: a
    /// quiet cross-fade for the content and a matching layout pass for pills.
    /// The single animation for every tab operation: switching, adding,
    /// closing and the New Tab -> document morph. Only layout and opacity use
    /// it; the tab strip's visual design is unchanged.
    static let tab = Animation.easeInOut(duration: 0.22)
}

extension View {
    func quillCapsule(selected: Bool = false) -> some View {
        modifier(QuillCapsuleSurface(emphasized: selected))
    }
    /// Content-hugging pill used by the editor and preview pane headers. Unlike
    /// the full-width header capsule this reads as a control floating over the
    /// pane instead of a rectangular surface covering it.
    func quillFloatingCapsule() -> some View {
        modifier(QuillFloatingSurface())
    }
    /// Row layout for the pane headers; each control draws its own floating pill.
    func quillPaneRow() -> some View {
        padding(.horizontal, 10)
            .frame(height: ChromeMetrics.paneHeaderHeight)
    }
}

/// White capsule with a soft lift for the pane-header controls.
private struct QuillFloatingSurface: ViewModifier {
    func body(content: Content) -> some View {
        content.background {
            Capsule()
                .fill(LinearGradient(colors: [.white, Palette.controlSurface],
                                     startPoint: .top, endPoint: .bottom))
                .overlay(Capsule().strokeBorder(Palette.hairline, lineWidth: 0.7))
                .shadow(color: .black.opacity(0.10), radius: 6, x: 0, y: 2)
        }
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
    var width: CGFloat = ChromeMetrics.chromeControlHeight
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
                .frame(width: width, height: ChromeMetrics.chromeControlHeight)
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
    @ObservedObject var store: ProjectStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hoveredTab: UUID?
    @State private var hoveringCloseTab: UUID?
    @State private var tabStripWidth: CGFloat = 0
    /// Document controls slide/fade with a hand-driven 60 fps tween. SwiftUI
    /// transitions and implicit opacity animations do not animate reliably in
    /// this AppKit-hosted top bar, so the progress value is stepped explicitly;
    /// that renders every intermediate frame on every tab switch, not just the
    /// first time a document opens.
    @State private var documentControlsRendered = false
    @State private var documentControlsWidth: CGFloat = 0
    @State private var documentControlsProgress: Double = 0
    @State private var documentControlsTween: UUID?
    /// Tabs being closed fade out in place before they are removed. Insertion
    /// needs no state: the strip's single layout animation grows the capsule.
    @State private var closingTabIDs: Set<UUID> = []
    @State private var tabDragOffsets: [UUID: CGFloat] = [:]
    @State private var tabDragSource: UUID?
    @State private var tabDragStartIndex = 0
    @State private var tabDragTargetIndex: Int?

    /// All Documents is the home tab: it stays pinned before the scrolling strip
    /// and never scrolls out of view, no matter how many tabs are open.
    private var pinnedHomeTab: WorkspaceTab? {
        store.tabs.first { $0.isLibrary && $0.selection == .all }
    }

    private enum TabStripItem: Identifiable {
        case tab(WorkspaceTab)
        case gap(Int)
        var id: String {
            switch self {
            case .tab(let tab): tab.id.uuidString
            case .gap(let index): "gap-\(index)"
            }
        }
    }

    private var tabStripItems: [TabStripItem] {
        var items = scrollableTabs.map(TabStripItem.tab)
        if tabDragSource != nil, let target = tabDragTargetIndex {
            items.insert(.gap(target), at: min(max(0, target), items.count))
        }
        return items
    }

    private var scrollableTabs: [WorkspaceTab] {
        let homeID = pinnedHomeTab?.id
        // Keep the store's creation order: a Templates or Starred tab opened
        // later must appear after the documents that were opened before it.
        return store.tabs.filter { $0.id != homeID }
    }

    private var showsDocumentControls: Bool {
        store.root != nil && !store.showingLibrary && !store.showingSettings
            && !store.isEditingTemplate
    }


    var body: some View {
        ChromeHostingContainer(content:
            GeometryReader { geometry in
                let compact = geometry.size.width < 1100
                HStack(spacing: compact ? 4 : 6) {
                    // The sidebar toggle joins the bar while the sidebar is hidden.
                    if !store.sidebarVisible && !store.showingSettings {
                        ChromeButton(icon: "sidebar.left", label: "Show Sidebar") {
                            store.sidebarVisible = true
                        }
                    }
                    // The pinned All Documents tab replaces the home icon.
                    if let pinnedHomeTab {
                        tabPill(pinnedHomeTab)
                            .fixedSize(horizontal: true, vertical: false)
                            .layoutPriority(1)
                    } else {
                        ChromeButton(icon: "house", label: "All Documents") { store.showLibraryPage() }
                    }
                    // Library-only tabs may use the full bar; once a document adds
                    // the compile/pane controls the strip shrinks towards the left.
                    tabStrip(maxWidth: .infinity)
                    newTabControl
                    Spacer(minLength: 8)
                    if documentControlsRendered {
                        // Compile and pane controls sit together on the right, with a
                        // quiet rule separating them from the tabs. Non-document tabs
                        // (library home, New Tab, Templates, Settings) have no compile
                        // context, so the group cross-fades and slides on the same clock
                        // as the tabs instead of popping in and out.
                        HStack(spacing: compact ? 4 : 6) {
                            Rectangle().fill(Palette.hairline)
                                .frame(width: 1, height: 18)
                                .padding(.horizontal, 7)
                            BuildControls(store: store).fixedSize(horizontal: true, vertical: false)
                            ChromeSegmentedGroup(selection: store.paneMode) { paneSelection in
                                ChromeButton(icon: "rectangle", label: "Editor Only", selected: store.paneMode == .editor,
                                             width: ChromeMetrics.segmentedButtonWidth, selectionNamespace: paneSelection) { store.paneMode = .editor }
                                ChromeButton(icon: store.paneMode == .split ? "rectangle.lefthalf.inset.filled" : "rectangle.righthalf.inset.filled", label: "Editor and PDF", selected: store.paneMode == .split,
                                             width: ChromeMetrics.segmentedButtonWidth, selectionNamespace: paneSelection) { store.showEditorAndPDF() }
                                ChromeButton(icon: "rectangle.fill", label: "PDF Only", selected: store.paneMode == .preview,
                                             width: ChromeMetrics.segmentedButtonWidth, selectionNamespace: paneSelection) { store.paneMode = .preview }
                            }.padding(.horizontal, ChromeMetrics.chromeGroupInset).quillCapsule().chromeControlGroup()
                            .fixedSize()
                        }
                        .fixedSize(horizontal: true, vertical: false)
                        .background {
                            GeometryReader { proxy in
                                Color.clear.preference(key: DocumentControlsWidthKey.self, value: proxy.size.width)
                            }
                        }
                        // Until the group has been measured once, show it at its
                        // natural size: a missing measurement must never leave the
                        // controls invisible after a tab switch.
                        .frame(width: documentControlsWidth > 0 ? documentControlsWidth * documentControlsProgress : nil,
                               alignment: .leading)
                        .clipped()
                        .opacity(documentControlsWidth > 0 ? documentControlsProgress : 1)
                        .layoutPriority(2)
                    }
                }
                .onAppear {
                    documentControlsRendered = showsDocumentControls
                    documentControlsProgress = showsDocumentControls ? 1 : 0
                }
                .onChange(of: showsDocumentControls) { _, shown in
                    guard !reduceMotion else {
                        documentControlsRendered = shown
                        documentControlsProgress = shown ? 1 : 0
                        documentControlsTween = nil
                        return
                    }
                    if shown {
                        documentControlsRendered = true
                        documentControlsProgress = 0
                        DispatchQueue.main.async {
                            tweenDocumentControls(to: 1) {
                                // Keep it visible if the measurement arrives late.
                                if documentControlsProgress < 1 { documentControlsProgress = 1 }
                            }
                        }
                    } else {
                        tweenDocumentControls(to: 0) {
                            guard !showsDocumentControls else { return }
                            documentControlsRendered = false
                        }
                    }
                }
                .onPreferenceChange(DocumentControlsWidthKey.self) { width in
                    // Never adopt a new measurement mid-tween: the collapse would
                    // jump. The width is stable between switches anyway.
                    guard width > 0, documentControlsTween == nil else { return }
                    documentControlsWidth = width
                }
                .padding(.leading, store.sidebarVisible
                         ? 10
                         : (store.isFullScreen ? ChromeMetrics.controlsInsetFullScreen : ChromeMetrics.controlsInset))
                .padding(.trailing, 10)
                .frame(height: ChromeMetrics.topBarHeight)
            }
            .frame(height: ChromeMetrics.topBarHeight)
        ).frame(height: ChromeMetrics.topBarHeight)
    }

    // MARK: - Tabs

    /// Compact identity of the tab layout: ids, titles, kind and the selected
    /// tab. Watching it lets one animation cover switching, adding, closing and
    /// the New Tab -> document morph without touching the pill design.
    private var tabLayoutSignature: [String] {
        store.tabs.map { tab in
            "\(tab.id.uuidString)|\(tab.title)|\(tab.path != nil)|\(tab.isLibrary)|\(tab.isSettings)|\(store.activeTabID == tab.id)"
        }
    }

    private func tabStrip(maxWidth: CGFloat) -> some View {
        ScrollView(.horizontal) {
            HStack(spacing: 4) {
                ForEach(tabStripItems) { item in
                    switch item {
                    case .tab(let tab):
                        tabPill(tab)
                    case .gap:
                        Capsule()
                            .fill(Palette.primaryInk.opacity(0.08))
                            .overlay(Capsule().strokeBorder(Palette.hairline, lineWidth: 0.8))
                            .frame(width: 8, height: 26)
                            .transition(.opacity)
                    }
                }
            }
            .animation(reduceMotion ? nil : ChromeMotion.tab, value: tabLayoutSignature)
            .padding(.vertical, 2)
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(key: TabStripWidthKey.self, value: proxy.size.width)
                }
            }
        }
        .scrollIndicators(.hidden)
        // Hug the tabs so the add control follows the last one. maxWidth-only is
        // flexible: HStack shrinks this strip only when the tabs would reach the
        // fixed compile controls on the right.
        .frame(maxWidth: max(tabStripWidth, 0), alignment: .leading)
        // The strip (and the New Tab button behind it) resize on the same clock,
        // so a new or closing tab never leaves the rest of the bar jumping.
        .animation(reduceMotion ? nil : ChromeMotion.tab, value: tabStripWidth)
        .layoutPriority(0)
        .onPreferenceChange(TabStripWidthKey.self) { tabStripWidth = $0 }
    }

    /// With no document tabs the New Tab page is offered as a wide pill; once
    /// tabs exist the same action shrinks to a quiet plus.
    /// The New Tab page is itself a tab: with no tabs the control is the wide
    /// "＋ New Tab" pill, with document tabs it shrinks to a quiet plus, and while
    /// the New Tab tab is open it is that tab (no second add control).
    @ViewBuilder
    private var newTabControl: some View {
        // The library page and Settings are tabs too, but they must not hide the
        // add control; only an open New Tab page does.
        if store.tabs.contains(where: { $0.path == nil && !$0.isSettings && !$0.isLibrary }) {
            EmptyView()
        } else {
            // One quiet plus for both states: it is the same reliable ChromeButton
            // used elsewhere in the bar, so opening the New Tab page always works.
            ChromeButton(icon: "plus", label: "New Tab") { store.showNewTabPage() }
        }
    }

    /// A tab keeps a fixed leading slot. All Documents is the pinned home page
    /// and cannot be closed, so it never offers a close control. The transient
    /// New Tab page is the same: switching tabs removes it and opening a
    /// document turns it into that document's tab. The selected tab shows the
    /// close control directly in place of its page preview; unselected tabs keep
    /// the preview at rest and swap it for a faint close on hover, which inks in
    /// fully only while the pointer is on the close control itself.
    private func tabPill(_ tab: WorkspaceTab) -> some View {
        let active = store.activeTabID == tab.id
            && (tab.isSettings ? store.showingSettings
                : (tab.isLibrary ? store.showingLibrary && !store.showingSettings
                    : (tab.path == nil ? store.showingLibrary && store.librarySelection == .newTab
                                       : !store.showingLibrary && !store.showingSettings)))
        let hovered = hoveredTab == tab.id
        let hoveringClose = hoveringCloseTab == tab.id
        let isNewTabPage = tab.path == nil && !tab.isSettings && !tab.isLibrary
        let closable = !(tab.isLibrary && tab.selection == .all) && !isNewTabPage
        let showsClose = closable && (active || hovered)
        let leadingSlot = ChromeMetrics.documentPageIconSize.width
        return ZStack(alignment: .leading) {
            Button { store.activateTab(tab) } label: {
                HStack(spacing: 6) {
                    Color.clear.frame(width: leadingSlot, height: 1)
                    Text(tab.title)
                        .font(.system(size: 12.5, weight: active ? .semibold : .regular))
                        .foregroundStyle(active ? Palette.primaryInk : Palette.secondaryInk)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .contentTransition(.opacity)
                    Spacer(minLength: 0)
                }
                .padding(.leading, 9)
                .padding(.trailing, 10)
                .frame(height: 30)
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .chromeControlBoundary()
            .help(tab.isLibrary ? "Library" : (tab.path?.path ?? "New Tab"))

            if showsClose {
                Button { closeTabAnimated(tab) } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8.5, weight: .bold))
                        .foregroundStyle(closeControlInk(hovered: hovered, onClose: hoveringClose))
                        .frame(width: leadingSlot, height: 30)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .chromeControlBoundary()
                .padding(.leading, 9)
                .background(ChromeHoverState { inside in
                    setCloseHover(inside, for: tab.id)
                }.allowsHitTesting(false))
                .transition(.opacity)
                .help("Close Tab")
                .accessibilityLabel("Close \(tab.title)")
            } else {
                tabLeadingIcon(tab, active: active)
                    .frame(width: leadingSlot, height: 30)
                    .padding(.leading, 9)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: 210)
        .background {
            if active {
                Capsule().fill(Color.white)
            } else if hovered {
                Capsule().fill(Palette.primaryInk.opacity(0.055))
            }
        }
        .clipShape(Capsule())
        .overlay {
            if active {
                Capsule().strokeBorder(Palette.hairline, lineWidth: 0.9)
            }
        }
        .opacity(closingTabIDs.contains(tab.id) ? 0 : 1)
        .animation(reduceMotion ? nil : ChromeMotion.tab, value: active)
        .animation(reduceMotion ? nil : ChromeMotion.tab, value: tab.title)
        .animation(reduceMotion ? nil : ChromeMotion.tab, value: closingTabIDs.contains(tab.id))
        .onContinuousHover { phase in
            switch phase {
            case .active:
                if hoveredTab != tab.id {
                    hoveredTab = tab.id
                    hoveringCloseTab = nil
                }
            case .ended:
                if hoveredTab == tab.id { hoveredTab = nil }
                if hoveringCloseTab == tab.id { hoveringCloseTab = nil }
            }
        }
        .offset(x: tabDragOffsets[tab.id] ?? 0)
        .zIndex(tabDragOffsets[tab.id] == nil ? 0 : 1)
        .animation(.easeOut(duration: 0.14), value: hovered)
        .simultaneousGesture(tabDragGesture(tab))
    }

    /// Fade the capsule out in place, then remove the tab. Keeping the fade on
    /// the existing layout (instead of a removal transition) means the strip
    /// never renders a clipped edge while it reflows.
    private func closeTabAnimated(_ tab: WorkspaceTab) {
        let isDirty = tab.path.map { path in
            store.documents.contains { $0.url.standardizedFileURL == path.standardizedFileURL && $0.isDirty }
        } ?? false
        guard !isDirty, !reduceMotion, !closingTabIDs.contains(tab.id) else {
            store.closeTab(tab)
            return
        }
        closingTabIDs.insert(tab.id)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
            closingTabIDs.remove(tab.id)
            store.closeTab(tab)
        }
    }

    /// Step the controls progress at ~60 fps. Stepping state by hand is the
    /// only way to guarantee intermediate frames in this AppKit-hosted bar.
    private func tweenDocumentControls(to target: Double, completion: @escaping () -> Void) {
        let token = UUID()
        documentControlsTween = token
        let start = documentControlsProgress
        let duration = 0.22
        let steps = 13
        for step in 1...steps {
            let delay = duration * Double(step) / Double(steps)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard documentControlsTween == token else { return }
                let t = Double(step) / Double(steps)
                let eased = t * t * (3 - 2 * t)
                documentControlsProgress = start + (target - start) * eased
                if step == steps {
                    documentControlsTween = nil
                    completion()
                }
            }
        }
    }

    /// The close control stays quiet when the tab is not hovered, reads as a
    /// faint hint while the pointer is anywhere on the tab, and inks in fully
    /// only when the pointer is on the close control itself.
    private func closeControlInk(hovered: Bool, onClose: Bool) -> Color {
        if onClose { return Palette.primaryInk }
        return hovered ? Palette.secondaryInk : Palette.secondaryInk.opacity(0.5)
    }

    private func setCloseHover(_ inside: Bool, for id: UUID) {
        if inside {
            if hoveringCloseTab != id { hoveringCloseTab = id }
        } else if hoveringCloseTab == id {
            hoveringCloseTab = nil
        }
    }

    /// Library tabs reuse the sidebar's own symbol for their selection so the
    /// tab strip and the sidebar never disagree (for example the Starred tab).
    private func libraryTabSymbol(_ selection: LibrarySelection?) -> String {
        switch selection {
        case .starred: "star"
        case .templates: "square.on.square"
        case .tag: "tag"
        case .folder: "folder"
        case .all, .newTab, .none: "list.bullet.rectangle"
        }
    }

    /// The at-rest counterpart of the close control. Unselected document tabs
    /// show the same rounded page preview the library uses, falling back to a
    /// plain document symbol; library pages reuse the sidebar's own symbol,
    /// Settings uses its gear and the New Tab page keeps the plus. Only the
    /// selected tab replaces the preview with the close control directly.
    @ViewBuilder
    private func tabLeadingIcon(_ tab: WorkspaceTab, active: Bool) -> some View {
        let ink = active ? Palette.primaryInk : Palette.secondaryInk
        if tab.isLibrary {
            Image(systemName: libraryTabSymbol(tab.selection))
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(ink)
        } else if tab.isSettings {
            Image(systemName: "gearshape")
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(ink)
        } else if tab.path == nil {
            Image(systemName: "plus")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(ink)
        } else if let path = tab.path,
                  let entry = (store.catalog ?? DocumentCatalog.shared).entry(forMainFile: path) {
            LibraryDocumentThumbnail(entry: entry,
                                     size: ChromeMetrics.documentPageIconSize,
                                     cornerRadius: ChromeMetrics.documentPageIconCornerRadius)
        } else {
            Image(systemName: "doc.text")
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(ink)
        }
    }

    /// Home stays pinned; every other tab can be dragged to a new position.
    private func tabDragGesture(_ tab: WorkspaceTab) -> some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                guard !(tab.isLibrary && tab.selection == .all) else { return }
                if tabDragSource != tab.id {
                    tabDragSource = tab.id
                    tabDragStartIndex = scrollableTabs.firstIndex(where: { $0.id == tab.id }) ?? 0
                }
                tabDragOffsets[tab.id] = value.translation.width
                let steps = Int((value.translation.width / 120).rounded())
                tabDragTargetIndex = min(max(0, tabDragStartIndex + steps), max(0, scrollableTabs.count - 1))
            }
            .onEnded { value in
                defer {
                    tabDragOffsets[tab.id] = nil
                    tabDragSource = nil
                    tabDragTargetIndex = nil
                }
                guard !(tab.isLibrary && tab.selection == .all) else { return }
                let steps = Int((value.translation.width / 120).rounded())
                store.moveTab(tab.id, by: steps)
            }
    }
}

private struct DocumentControlsWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private struct TabStripWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
