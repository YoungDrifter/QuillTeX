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
    /// Light veil over the blurred sidebar material; it keeps the desktop colour
    /// without letting background text become legible.
    static let sidebarVeil = Color.white.opacity(0.25)
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
    /// Both pane headers (breadcrumb and PDF title) share this height so their titles
    /// sit on one line and their bottom rules line up.
    static let paneHeaderHeight: CGFloat = 54
    /// One-line SyncTeX notice that floats under the preview header.
    static let syncBannerHeight: CGFloat = 28
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
    @State private var hoveredTab: UUID?
    @State private var tabStripWidth: CGFloat = 0
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
                    if showsDocumentControls {
                        // Compile and pane controls sit together on the right, with a
                        // quiet rule separating them from the tabs. Non-document tabs
                        // (library home, New Tab, Templates, Settings) have no compile
                        // context, so the group slides away towards the trailing edge.
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
                        .layoutPriority(2)
                        .transition(.asymmetric(
                            insertion: .move(edge: .trailing).combined(with: .opacity),
                            removal: .move(edge: .trailing).combined(with: .opacity)))
                    }
                }
                .animation(.smooth(duration: 0.24), value: showsDocumentControls)
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

    private func tabStrip(maxWidth: CGFloat) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
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
            .animation(.smooth(duration: 0.24), value: scrollableTabs.map(\.id))
            .padding(.vertical, 2)
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(key: TabStripWidthKey.self, value: proxy.size.width)
                }
            }
        }
        // Hug the tabs so the add control follows the last one. maxWidth-only is
        // flexible: HStack shrinks this strip only when the tabs would reach the
        // fixed compile controls on the right.
        .frame(maxWidth: max(tabStripWidth, 0), alignment: .leading)
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

    private func tabPill(_ tab: WorkspaceTab) -> some View {
        let active = store.activeTabID == tab.id
            && (tab.isSettings ? store.showingSettings
                : (tab.isLibrary ? store.showingLibrary && !store.showingSettings
                    : (tab.path == nil ? store.showingLibrary && store.librarySelection == .newTab
                                       : !store.showingLibrary && !store.showingSettings)))
        let hovered = hoveredTab == tab.id
        return HStack(spacing: 4) {
            Button { store.activateTab(tab) } label: {
                HStack(spacing: 6) {
                    if tab.isLibrary {
                        Image(systemName: "folder")
                            .font(.system(size: 11, weight: .regular))
                            .foregroundStyle(active ? Palette.primaryInk : Palette.secondaryInk)
                    } else if tab.isSettings {
                        Image(systemName: "gearshape")
                            .font(.system(size: 11, weight: .regular))
                            .foregroundStyle(active ? Palette.primaryInk : Palette.secondaryInk)
                    } else if tab.path == nil {
                        Image(systemName: "plus")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(active ? Palette.primaryInk : Palette.secondaryInk)
                    }
                    Text(tab.title)
                        .font(.system(size: 12.5, weight: active ? .semibold : .regular))
                        .foregroundStyle(active ? Palette.primaryInk : Palette.secondaryInk)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .padding(.leading, 12)
                .padding(.trailing, active || hovered ? 2 : 12)
                .frame(height: 30)
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .chromeControlBoundary()
            .transition(.opacity)
            .help(tab.isLibrary ? "Library" : (tab.path?.path ?? "New Tab"))

            if active || hovered {
                Button { store.closeTab(tab) } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8.5, weight: .bold))
                        .foregroundStyle(Palette.secondaryInk)
                        .frame(width: 18, height: 18)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .chromeControlBoundary()
                .padding(.trailing, 6)
                .transition(.opacity)
                .help("Close Tab")
                .accessibilityLabel("Close \(tab.title)")
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
        .animation(.smooth(duration: 0.18), value: active)
        .onContinuousHover { phase in
            switch phase {
            case .active:
                if hoveredTab != tab.id { hoveredTab = tab.id }
            case .ended:
                if hoveredTab == tab.id { hoveredTab = nil }
            }
        }
        .offset(x: tabDragOffsets[tab.id] ?? 0)
        .zIndex(tabDragOffsets[tab.id] == nil ? 0 : 1)
        .animation(.easeOut(duration: 0.14), value: hovered)
        .simultaneousGesture(tabDragGesture(tab))
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

private struct TabStripWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
