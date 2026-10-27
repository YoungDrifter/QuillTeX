import SwiftUI
import PDFKit
import AppKit

/// The header controls act on the mounted PDFKit view without reloading the PDF.
final class PDFPreviewControls: ObservableObject {
    weak var view: SyncPDFView?
    @Published private(set) var scaleFactor: CGFloat = 1
    @Published private(set) var hasDocument = false
    private var observers: [NSObjectProtocol] = []
    private var refresh: DispatchWorkItem?
    static func formattedPercentage(_ scale: CGFloat) -> String {
        String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), scale * 100)
            .replacingOccurrences(of: ".0", with: "") + "%"
    }
    var percentage: String { hasDocument ? Self.formattedPercentage(scaleFactor) : "—" }

    func attach(_ view: SyncPDFView) {
        guard self.view !== view else { return }
        observers.forEach(NotificationCenter.default.removeObserver)
        self.view = view
        for name in [Notification.Name.PDFViewScaleChanged, .PDFViewDocumentChanged] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: view, queue: .main) { [weak self] _ in
                self?.scheduleRefresh()
            })
        }
        scheduleRefresh()
    }
    private func scheduleRefresh() {
        refresh?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let scale = self.view?.scaleFactor ?? 1
            if scale.isFinite, self.scaleFactor != scale { self.scaleFactor = scale }
            let loaded = self.view?.document != nil
            if self.hasDocument != loaded { self.hasDocument = loaded }
        }
        refresh = work
        DispatchQueue.main.async(execute: work)
    }
    deinit {
        refresh?.cancel()
        observers.forEach(NotificationCenter.default.removeObserver)
    }
    func zoomIn() { view?.zoomIn(nil) }
    func zoomOut() { view?.zoomOut(nil) }
    func setPercentage(_ text: String) -> Bool {
        let number = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "%", with: "").replacingOccurrences(of: ",", with: ".")
        guard let percentage = Double(number), percentage.isFinite, percentage > 0,
              let view, view.document != nil else { return false }
        view.setZoomPercentage(CGFloat(percentage))
        return true
    }
    func actualSize() { view?.actualSize(nil) }
    func fitWidth() { view?.fitWidth() }
}

private struct PDFPreviewControlsKey: FocusedValueKey { typealias Value = PDFPreviewControls }
extension FocusedValues {
    var pdfPreviewControls: PDFPreviewControls? {
        get { self[PDFPreviewControlsKey.self] }
        set { self[PDFPreviewControlsKey.self] = newValue }
    }
}

/// PDFKit preview. Continuous scrolling, fit width, and it keeps the reader's place
/// across rebuilds: same page, same offset inside the page, same zoom.
struct PDFPreview: NSViewRepresentable {
    /// Nil until a build has produced something. The view stays mounted either way:
    /// inserting an AppKit-backed view while SwiftUI is dispatching a hover event
    /// crashes the responder machinery, so the pane only ever flips an overlay.
    let pdfURL: URL?
    let version: Int
    let controls: PDFPreviewControls
    var highlight: PDFHighlight?
    var readingState: PDFReadingState? = nil
    var onReadingStateChanged: ((PDFReadingState) -> Void)? = nil
    var onCommandClick: (Int, CGPoint) -> Void

    func makeNSView(context: Context) -> SyncPDFView {
        let view = SyncPDFView()
        view.autoScales = false
        view.scaleFactor = 1
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.displaysPageBreaks = true
        view.pageBreakMargins = NSEdgeInsets(top: 4, left: 4, bottom: 4, right: 4)
        view.minScaleFactor = 0.1
        view.maxScaleFactor = 4
        view.backgroundColor = NSColor.white
        view.onCommandClick = onCommandClick
        view.onReadingStateChanged = onReadingStateChanged
        controls.attach(view)
        if let pdfURL { context.coordinator.load(pdfURL, into: view, version: version, readingState: readingState) }
        return view
    }

    func updateNSView(_ view: SyncPDFView, context: Context) {
        controls.attach(view)
        view.onCommandClick = onCommandClick
        view.onReadingStateChanged = onReadingStateChanged
        if let pdfURL { context.coordinator.load(pdfURL, into: view, version: version, readingState: readingState) }
        else { context.coordinator.clear(view) }
        if let highlight { context.coordinator.apply(highlight, to: view) }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        private var loadedVersion = -1
        private var appliedHighlight = -1
        private var loadedData: Data?
        private var loadedURL: URL?

        func clear(_ view: SyncPDFView) {
            loadedVersion = -1
            appliedHighlight = -1
            loadedData = nil
            loadedURL = nil
            view.clearPreview()
        }

        /// Reload only when a build produced a new file, restoring the reader's place.
        func load(_ url: URL, into view: SyncPDFView, version: Int, readingState: PDFReadingState? = nil) {
            let url = url.standardizedFileURL
            let isNewDocument = loadedURL != url
            guard version != loadedVersion || isNewDocument else { return }
            guard let data = try? Data(contentsOf: url) else { return }
            if data == loadedData, !isNewDocument {
                loadedVersion = version
                return
            }
            // Own the bytes: the next TeX run can overwrite the output file while
            // PDFKit is still lazily drawing pages from the last successful build.
            guard let document = PDFDocument(data: data) else { return }
            // A failed or truncated build must not replace a good preview.
            guard document.pageCount > 0 else { return }
            loadedVersion = version
            loadedData = data
            loadedURL = url
            if isNewDocument { appliedHighlight = -1 }
            view.replacePreview(with: document, readingState: isNewDocument ? readingState : nil,
                                preservesReadingPosition: !isNewDocument)
        }

        func apply(_ highlight: PDFHighlight, to view: SyncPDFView) {
            guard highlight.generation != appliedHighlight else { return }
            appliedHighlight = highlight.generation
            view.reveal(highlight)
        }
    }
}

/// `PDFView` that reports ⌘-clicks so a click in the page can open the source line.
final class SyncPDFView: PDFView {
    var onCommandClick: ((Int, CGPoint) -> Void)?
    var onReadingStateChanged: ((PDFReadingState) -> Void)?
    typealias ZoomMode = PDFZoomMode
    var zoomMode = ZoomMode.width
    private weak var observedClip: NSClipView?
    private var boundsObserver: NSObjectProtocol?
    private var adjustingHorizontalPosition = false
    private var refreshCover: NSImageView?
    private var refreshGeneration = 0
    private var readingStateReport: DispatchWorkItem?
    private var lastReportedState: PDFReadingState?
    private weak var highlightPage: PDFPage?
    private var highlightAnnotation: PDFAnnotation?
    private var highlightRemoval: DispatchWorkItem?

    func clearPreview() {
        refreshGeneration += 1
        refreshCover?.removeFromSuperview()
        refreshCover = nil
        readingStateReport?.cancel()
        lastReportedState = nil
        removeTargetHighlight()
        zoomMode = .width
        document = nil
    }

    /// Keep the last rendered viewport over PDFKit's temporary blank layout.
    func replacePreview(with document: PDFDocument, readingState: PDFReadingState? = nil,
                        preservesReadingPosition: Bool = true) {
        let previous = readingState ?? (preservesReadingPosition ? readerPosition() : nil)
        removeTargetHighlight()
        refreshGeneration += 1
        let generation = refreshGeneration
        if refreshCover == nil, self.document != nil, window != nil,
           bounds.width > 0, bounds.height > 0,
           let bitmap = bitmapImageRepForCachingDisplay(in: bounds) {
            cacheDisplay(in: bounds, to: bitmap)
            let image = NSImage(size: bounds.size)
            image.addRepresentation(bitmap)
            let cover = NSImageView(frame: bounds)
            cover.image = image
            cover.imageScaling = .scaleAxesIndependently
            cover.autoresizingMask = [.width, .height]
            addSubview(cover, positioned: .above, relativeTo: nil)
            refreshCover = cover
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            context.allowsImplicitAnimation = false
            self.document = document
            minScaleFactor = 0.1
            maxScaleFactor = 4
            if let previous { restore(previous) } else { fitWidth() }
            layoutSubtreeIfNeeded()
            layoutDocumentView()
        }
        // PDFKit renders tiles after layout. Give it a short settling interval,
        // then flush display before revealing the new viewport without a fade.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard let self, self.refreshGeneration == generation else { return }
            self.layoutSubtreeIfNeeded()
            if previous == nil, self.zoomMode == .width { self.fitWidth() }
            self.documentView?.displayIfNeeded()
            self.displayIfNeeded()
            self.refreshCover?.removeFromSuperview()
            self.refreshCover = nil
            self.scheduleReadingStateReport()
        }
    }

    deinit {
        readingStateReport?.cancel()
        highlightRemoval?.cancel()
        if let boundsObserver { NotificationCenter.default.removeObserver(boundsObserver) }
    }

    private var pageSize: NSSize? {
        guard let page = currentPage ?? document?.page(at: 0) else { return nil }
        let size = page.bounds(for: displayBox).size
        return page.rotation % 180 == 0 ? size : NSSize(width: size.height, height: size.width)
    }

    override func zoomIn(_ sender: Any?) { setManualScale(scaleFactor + 0.25) }
    override func zoomOut(_ sender: Any?) { setManualScale(scaleFactor - 0.25) }
    @objc func actualSize(_ sender: Any?) { setManualScale(1) }
    func setZoomPercentage(_ percent: CGFloat) { setManualScale(percent / 100) }
    @objc private func fitWidthFromMenu(_ sender: Any?) { fitWidth() }

    private func setManualScale(_ scale: CGFloat) {
        guard document != nil else { return }
        zoomMode = .manual
        autoScales = false
        scaleFactor = min(maxScaleFactor, max(minScaleFactor, scale))
        configureHorizontalScrolling()
        layoutDocumentView()
        scheduleReadingStateReport()
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        for (title, action) in [("Zoom In", #selector(zoomIn(_:))), ("Zoom Out", #selector(zoomOut(_:))),
                                ("Actual Size", #selector(actualSize(_:))), ("Fit Width", #selector(fitWidthFromMenu(_:)))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.isEnabled = document != nil
            menu.addItem(item)
        }
        if currentSelection != nil {
            menu.addItem(.separator())
            let copy = NSMenuItem(title: "Copy", action: #selector(PDFView.copy(_:)), keyEquivalent: "")
            copy.target = self
            menu.addItem(copy)
        }
        return menu
    }

    override func layout() {
        super.layout()
        configureHorizontalScrolling()
        // Like PaperLens, Fit commands apply once. Resizing preserves the scale.
    }

    func fitWidth() {
        guard let size = pageSize, size.width > 0 else { return }
        zoomMode = .width
        autoScales = false
        pageBreakMargins = NSEdgeInsets(top: 4, left: 0, bottom: 4, right: 0)
        // Overlay scrollbars keep the entire preview width available to the page.
        configureHorizontalScrolling()
        let availableWidth = bounds.width
        guard availableWidth > 0 else { return }
        scaleFactor = min(maxScaleFactor, max(minScaleFactor, availableWidth / size.width))
        layoutDocumentView()
        centerHorizontally()
        scheduleReadingStateReport()
    }

    func centerHorizontally() {
        DispatchQueue.main.async { [weak self] in
            guard let scroll = self?.documentView?.enclosingScrollView,
                  let documentView = scroll.documentView else { return }
            let centerX: CGFloat
            if let self, let page = self.currentPage ?? self.document?.page(at: 0) {
                centerX = documentView.convert(self.convert(page.bounds(for: self.displayBox), from: page), from: self).midX
            } else {
                centerX = documentView.bounds.midX
            }
            let x = centerX - scroll.contentView.bounds.width / 2
            scroll.contentView.setBoundsOrigin(NSPoint(x: x, y: scroll.contentView.bounds.origin.y))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
    }

    private func configureHorizontalScrolling() {
        guard let scroll = documentView?.enclosingScrollView else { return }
        if zoomMode != .manual { scroll.scrollerStyle = .overlay }
        scroll.horizontalScrollElasticity = zoomMode == .manual ? .automatic : .none
        scroll.hasHorizontalScroller = zoomMode == .manual
        let clip = scroll.contentView
        guard observedClip !== clip else { return }
        if let boundsObserver { NotificationCenter.default.removeObserver(boundsObserver) }
        observedClip = clip
        clip.postsBoundsChangedNotifications = true
        boundsObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.scheduleReadingStateReport()
            guard !self.adjustingHorizontalPosition, self.zoomMode != .manual,
                  let clip = self.observedClip, let documentView = clip.documentView else { return }
            let centerX: CGFloat
            if let page = self.currentPage ?? self.document?.page(at: 0) {
                centerX = documentView.convert(self.convert(page.bounds(for: self.displayBox), from: page), from: self).midX
            } else {
                centerX = documentView.bounds.midX
            }
            let x = centerX - clip.bounds.width / 2
            if abs(clip.bounds.origin.x - x) > 0.25 {
                self.adjustingHorizontalPosition = true
                clip.setBoundsOrigin(NSPoint(x: x, y: clip.bounds.origin.y))
                self.adjustingHorizontalPosition = false
            }
        }
    }

    override func magnify(with event: NSEvent) {
        guard document != nil, event.magnification.isFinite else { return }
        zoomMode = .manual
        autoScales = false
        let point = convert(event.locationInWindow, from: nil)
        let page = page(for: point, nearest: true)
        let pagePoint = page.map { convert(point, to: $0) }
        scaleFactor = min(maxScaleFactor, max(minScaleFactor, scaleFactor * (1 + event.magnification)))
        // Keep the page point under the fingers while PDFKit lays out the new scale.
        if let page, let pagePoint, let scroll = documentView?.enclosingScrollView {
            layoutDocumentView()
            let moved = convert(pagePoint, from: page)
            let origin = scroll.contentView.bounds.origin
            scroll.contentView.scroll(to: NSPoint(x: origin.x + moved.x - point.x, y: origin.y + point.y - moved.y))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        scheduleReadingStateReport()
    }

    /// Where the reader is: page number and the point (top-left origin) at the top of
    /// the viewport, plus the zoom, so a rebuild can put them back.
    typealias ReaderPosition = PDFReadingState

    func readerPosition() -> ReaderPosition? {
        guard let document, let page = currentPage else { return nil }
        let topLeftInView = NSPoint(x: bounds.minX, y: bounds.maxY)
        let topPage = self.page(for: topLeftInView, nearest: true) ?? page
        let index = document.index(for: topPage)
        let topLeft = convert(topLeftInView, to: topPage)
        let media = topPage.bounds(for: .mediaBox)
        return ReaderPosition(pageIndex: index,
                              topPoint: CGPoint(x: topLeft.x - media.minX, y: media.maxY - topLeft.y),
                              scale: scaleFactor, zoomMode: zoomMode)
    }

    func restore(_ position: ReaderPosition?) {
        guard let position, let document, document.pageCount > 0 else { return }
        let index = min(max(position.pageIndex, 0), document.pageCount - 1)
        guard let page = document.page(at: index) else { return }
        guard position.topPoint.x.isFinite, position.topPoint.y.isFinite,
              position.scale.isFinite, position.scale > 0 else { fitWidth(); return }
        let media = page.bounds(for: .mediaBox)
        let point = CGPoint(x: media.minX + position.topPoint.x, y: media.maxY - position.topPoint.y)
        // Old sessions may contain wholePage; retain their scale as a manual zoom.
        zoomMode = position.zoomMode == .wholePage ? .manual : position.zoomMode
        pageBreakMargins = NSEdgeInsets(top: 4, left: 0, bottom: 4, right: 0)
        autoScales = false
        scaleFactor = min(maxScaleFactor, max(minScaleFactor, position.scale))
        configureHorizontalScrolling()
        layoutDocumentView()
        go(to: PDFDestination(page: page, at: point))
        scheduleReadingStateReport()
    }

    /// Brings a SyncTeX point (top-left origin) into view.
    func reveal(page pageNumber: Int, point: CGPoint) {
        reveal(PDFHighlight(page: pageNumber, point: point))
    }

    func reveal(_ highlight: PDFHighlight) {
        guard let document, document.pageCount > 0 else { return }
        guard highlight.page > 0, highlight.page <= document.pageCount,
              highlight.point.x.isFinite, highlight.point.y.isFinite else { return }
        let index = highlight.page - 1
        guard let page = document.page(at: index) else { return }
        let media = page.bounds(for: .mediaBox)
        let rect = highlight.bounds(in: media)
        guard !rect.isNull, !rect.isEmpty else { return }
        let target = CGPoint(x: media.minX + highlight.point.x, y: min(media.maxY, rect.maxY + 24))
        go(to: PDFDestination(page: page, at: target))
        removeTargetHighlight()
        if !rect.isNull, !rect.isEmpty {
            let annotation = PDFAnnotation(bounds: rect, forType: .square, withProperties: nil)
            annotation.color = .clear
            annotation.interiorColor = NSColor.black.withAlphaComponent(0.10)
            let border = PDFBorder()
            border.lineWidth = 0
            annotation.border = border
            annotation.shouldPrint = false
            page.addAnnotation(annotation)
            highlightPage = page
            highlightAnnotation = annotation
            let removal = DispatchWorkItem { [weak self] in self?.removeTargetHighlight() }
            highlightRemoval = removal
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6, execute: removal)
        }
        scheduleReadingStateReport()
    }

    private func removeTargetHighlight() {
        highlightRemoval?.cancel()
        highlightRemoval = nil
        if let annotation = highlightAnnotation { highlightPage?.removeAnnotation(annotation) }
        highlightAnnotation = nil
        highlightPage = nil
    }

    /// Coalesce scroll notifications before persisting a stable reading position.
    func scheduleReadingStateReport() {
        readingStateReport?.cancel()
        let report = DispatchWorkItem { [weak self] in
            guard let self, let state = self.readerPosition(), state != self.lastReportedState else { return }
            self.lastReportedState = state
            self.onReadingStateChanged?(state)
        }
        readingStateReport = report
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: report)
    }

    override func mouseDown(with event: NSEvent) {
        // Command-click is the inverse search gesture, on both sides of the split.
        guard event.modifierFlags.contains(.command),
              let page = page(for: convert(event.locationInWindow, from: nil), nearest: true),
              let document else {
            super.mouseDown(with: event)
            return
        }
        let inPage = convert(convert(event.locationInWindow, from: nil), to: page)
        let media = page.bounds(for: .mediaBox)
        onCommandClick?(document.index(for: page) + 1, CGPoint(x: inPage.x - media.minX, y: media.maxY - inPage.y))
    }
}

/// The PDF pane: header, then either the built document or the empty state.
struct PreviewPane: View {
    @ObservedObject var store: ProjectStore
    @ObservedObject private var build: BuildController
    @StateObject private var controls = PDFPreviewControls()
    @State private var zoomText = ""
    @State private var zoomTextEdited = false
    @FocusState private var zoomFocused: Bool

    private func commitZoom() {
        guard zoomTextEdited else { return }
        zoomTextEdited = false
        _ = controls.setPercentage(zoomText)
        let factor = controls.view?.scaleFactor ?? controls.scaleFactor
        zoomText = controls.hasDocument ? PDFPreviewControls.formattedPercentage(factor) : "—"
    }

    private func performZoom(_ action: () -> Void) {
        zoomTextEdited = false
        action()
        zoomText = PDFPreviewControls.formattedPercentage(controls.view?.scaleFactor ?? controls.scaleFactor)
    }

    private var zoomInput: some View {
        TextField("Zoom", text: Binding(get: { zoomText }, set: { zoomText = $0; zoomTextEdited = true }))
            .textFieldStyle(.plain).font(.system(size: 11, weight: .medium)).monospacedDigit()
            .multilineTextAlignment(.center)
            .focused($zoomFocused)
            .onSubmit { commitZoom(); zoomFocused = false }
            .onChange(of: zoomFocused) { _, focused in
                if !focused { commitZoom() }
            }
            .onChange(of: controls.percentage) { _, value in
                zoomText = value
                zoomTextEdited = false
            }
            .onAppear { zoomText = controls.percentage }
            .accessibilityLabel("Zoom percentage")
        .padding(.horizontal, 10)
        .frame(width: ChromeMetrics.zoomInputWidth, height: ChromeMetrics.previewControlHeight)
        .foregroundStyle(Palette.primaryInk).tint(Palette.primaryInk)
        .contentShape(Capsule())
        .onTapGesture { if controls.hasDocument { zoomFocused = true } }
        .help("Enter a zoom percentage")
    }

    private var zoomDivider: some View {
        Rectangle().fill(Palette.hairline).frame(width: 1, height: 12).padding(.horizontal, 2)
    }

    private func zoomButton(_ symbol: String, title: String, action: @escaping () -> Void) -> some View {
        Button { performZoom(action); zoomFocused = false } label: {
            Image(systemName: symbol).font(.system(size: 13, weight: .medium))
                .frame(width: ChromeMetrics.previewActionWidth, height: ChromeMetrics.previewControlHeight - 2)
                .contentShape(Circle())
        }
        .buttonStyle(ChromeButtonStyle()).modifier(ChromeHoverFeedback())
        .help(title).accessibilityLabel(title)
    }

    init(store: ProjectStore) {
        self.store = store
        self.build = store.build
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Label("PDF", systemImage: "doc.richtext")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.primaryInk)
                    .fixedSize()
                Text(build.lastSummary).font(.system(size: 11)).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .help(build.lastSummary)
                HStack(spacing: 0) {
                    zoomInput
                    zoomDivider
                    zoomButton("1.square", title: "Actual Size (100%)", action: controls.actualSize)
                    zoomDivider
                    zoomButton("arrow.left.and.right", title: "Fit Width", action: controls.fitWidth)
                }
                .padding(.horizontal, 2)
                .frame(height: ChromeMetrics.previewControlHeight)
                .modifier(PreviewControlSurface(focused: zoomFocused))
                .fixedSize().disabled(build.pdfURL == nil)
                .accessibilityElement(children: .contain).accessibilityLabel("PDF zoom")
            }
            .padding(.horizontal, 12).frame(height: ChromeMetrics.paneHeaderHeight).background(Palette.previewHeader)
            Divider()
            if let message = store.syncStatusMessage {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "info.circle")
                    Text(message).frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .padding(.horizontal, 18).padding(.vertical, 7)
                .background(Palette.subtleSurface)
                Divider()
            }
            ZStack {
                PDFPreview(pdfURL: build.pdfURL, version: build.pdfVersion, controls: controls, highlight: build.highlight,
                           readingState: store.pdfReadingState, onReadingStateChanged: store.updatePDFReadingState) { page, point in
                    store.syncPDFToSource(page: page, point: point)
                }
                // The empty state sits on top while there is nothing to show, so the
                // AppKit view below is never inserted or removed.
                if build.pdfURL == nil {
                    PreviewPlaceholder().background(Palette.previewCanvas)
                }
            }
        }
        .background(Palette.previewCanvas)
        .focusedSceneValue(\.pdfPreviewControls, controls)
    }
}

/// One capsule contains all PDF zoom controls.
private struct PreviewControlSurface: ViewModifier {
    var focused = false
    var pressed = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered = false

    func body(content: Content) -> some View {
        content
            .background {
                Capsule().fill(LinearGradient(
                    colors: [pressed ? Palette.subtleSurface : .white,
                             focused ? .white : Palette.subtleSurface],
                    startPoint: .top, endPoint: .bottom))
            }
            .overlay {
                Capsule().strokeBorder(Palette.primaryInk.opacity(focused ? 0.6 : (hovered || pressed ? 0.34 : 0.22)),
                    lineWidth: focused ? 1.2 : 0.8).allowsHitTesting(false)
            }
            .opacity(isEnabled ? 1 : 0.4)
            .onHover { hovered = $0 && isEnabled }
            .animation(reduceMotion ? nil : ChromeMotion.feedback, value: hovered)
            .animation(reduceMotion ? nil : ChromeMotion.feedback, value: focused)
            .animation(reduceMotion ? nil : ChromeMotion.press, value: pressed)
    }
}
