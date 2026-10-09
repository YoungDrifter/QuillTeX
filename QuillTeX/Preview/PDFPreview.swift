import SwiftUI
import PDFKit
import AppKit

/// The header controls act on the mounted PDFKit view without reloading the PDF.
final class PDFPreviewControls: ObservableObject {
    weak var view: SyncPDFView?
    func attach(_ view: SyncPDFView) {
        self.view = view
    }

    private func manualZoom() {
        view?.autoScales = false
        view?.zoomMode = .manual
    }

    func zoomIn() {
        guard let view, view.document != nil else { return }
        manualZoom()
        view.scaleFactor = min(view.maxScaleFactor, view.scaleFactor + 0.25)
    }

    func zoomOut() {
        guard let view, view.document != nil else { return }
        manualZoom()
        view.scaleFactor = max(view.minScaleFactor, view.scaleFactor - 0.25)
    }

    func fitPage() {
        guard let view, view.document != nil else { return }
        view.fitPage()
    }

    func fitWidth() {
        guard let view, view.document != nil else { return }
        view.fitWidth()
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
        controls.attach(view)
        if let pdfURL { context.coordinator.load(pdfURL, into: view, version: version) }
        return view
    }

    func updateNSView(_ view: SyncPDFView, context: Context) {
        controls.attach(view)
        view.onCommandClick = onCommandClick
        if let pdfURL { context.coordinator.load(pdfURL, into: view, version: version) }
        else { context.coordinator.clear(view) }
        if let highlight { context.coordinator.apply(highlight, to: view) }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        private var loadedVersion = -1
        private var appliedHighlight = -1
        private var loadedData: Data?

        func clear(_ view: SyncPDFView) {
            loadedVersion = -1
            appliedHighlight = -1
            loadedData = nil
            view.clearPreview()
        }

        /// Reload only when a build produced a new file, restoring the reader's place.
        func load(_ url: URL, into view: SyncPDFView, version: Int) {
            guard version != loadedVersion else { return }
            guard let data = try? Data(contentsOf: url) else { return }
            if data == loadedData {
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
            view.replacePreview(with: document)
        }

        func apply(_ highlight: PDFHighlight, to view: SyncPDFView) {
            guard highlight.generation != appliedHighlight else { return }
            appliedHighlight = highlight.generation
            view.reveal(page: highlight.page, point: highlight.point)
        }
    }
}

/// `PDFView` that reports ⌘-clicks so a click in the page can open the source line.
final class SyncPDFView: PDFView {
    var onCommandClick: ((Int, CGPoint) -> Void)?
    enum ZoomMode { case wholePage, width, manual }
    var zoomMode = ZoomMode.wholePage
    private weak var observedClip: NSClipView?
    private var boundsObserver: NSObjectProtocol?
    private var adjustingHorizontalPosition = false
    private var refreshCover: NSImageView?
    private var refreshGeneration = 0

    func clearPreview() {
        refreshGeneration += 1
        refreshCover?.removeFromSuperview()
        refreshCover = nil
        document = nil
    }

    /// Keep the last rendered viewport over PDFKit's temporary blank layout.
    func replacePreview(with document: PDFDocument) {
        let previous = readerPosition()
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
            if let previous { restore(previous) } else { fitPage() }
            layoutSubtreeIfNeeded()
            layoutDocumentView()
        }
        // PDFKit renders tiles after layout. Give it a short settling interval,
        // then flush display before revealing the new viewport without a fade.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard let self, self.refreshGeneration == generation else { return }
            self.layoutSubtreeIfNeeded()
            self.documentView?.displayIfNeeded()
            self.displayIfNeeded()
            self.refreshCover?.removeFromSuperview()
            self.refreshCover = nil
        }
    }

    deinit {
        if let boundsObserver { NotificationCenter.default.removeObserver(boundsObserver) }
    }

    private var pageSize: NSSize? {
        guard let page = currentPage ?? document?.page(at: 0) else { return nil }
        let size = page.bounds(for: displayBox).size
        return page.rotation % 180 == 0 ? size : NSSize(width: size.height, height: size.width)
    }

    /// Fit Page uses both viewport dimensions; Fit Width uses only its width.
    var wholePageScale: CGFloat {
        guard let size = pageSize, size.width > 0, size.height > 0 else { return 1 }
        let width = bounds.width
        let height = bounds.height
        guard width > 0, height > 0 else { return 1 }
        return min(width / size.width, height / size.height)
    }

    func fitPage() {
        zoomMode = .wholePage
        autoScales = false
        pageBreakMargins = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        configureHorizontalScrolling()
        scaleFactor = min(maxScaleFactor, max(minScaleFactor, wholePageScale))
        if let page = currentPage ?? document?.page(at: 0) {
            layoutDocumentView()
            if let scroll = documentView?.enclosingScrollView, let documentView = scroll.documentView {
                let pageRect = convert(page.bounds(for: displayBox), from: page)
                let rect = documentView.convert(pageRect, from: self)
                let clip = scroll.contentView.bounds
                scroll.contentView.scroll(to: NSPoint(x: rect.midX - clip.width / 2,
                                                     y: max(documentView.bounds.minY, rect.midY - clip.height / 2)))
                scroll.reflectScrolledClipView(scroll.contentView)
            }
        }
        centerHorizontally()
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
            guard let self, !self.adjustingHorizontalPosition, self.zoomMode != .manual,
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
    }

    /// Where the reader is: page number and the point (top-left origin) at the top of
    /// the viewport, plus the zoom, so a rebuild can put them back.
    struct ReaderPosition {
        var pageIndex: Int
        var topPoint: CGPoint
        var scale: CGFloat
    }

    func readerPosition() -> ReaderPosition? {
        guard let document, let page = currentPage else { return nil }
        let index = document.index(for: page)
        let topLeft = convert(NSPoint(x: bounds.minX, y: bounds.maxY), to: page)
        let media = page.bounds(for: .mediaBox)
        return ReaderPosition(pageIndex: index,
                              topPoint: CGPoint(x: topLeft.x, y: media.height - topLeft.y),
                              scale: scaleFactor)
    }

    func restore(_ position: ReaderPosition?) {
        guard let position, let document, document.pageCount > 0 else { return }
        let index = min(max(position.pageIndex, 0), document.pageCount - 1)
        guard let page = document.page(at: index) else { return }
        let media = page.bounds(for: .mediaBox)
        let point = CGPoint(x: position.topPoint.x, y: media.height - position.topPoint.y)
        if position.scale > 0 { scaleFactor = position.scale; autoScales = false }
        layoutDocumentView()
        go(to: PDFDestination(page: page, at: point))
    }

    /// Brings a SyncTeX point (top-left origin) into view.
    func reveal(page pageNumber: Int, point: CGPoint) {
        guard let document, document.pageCount > 0 else { return }
        let index = min(max(pageNumber - 1, 0), document.pageCount - 1)
        guard let page = document.page(at: index) else { return }
        let media = page.bounds(for: .mediaBox)
        let target = CGPoint(x: point.x, y: media.height - point.y)
        go(to: PDFDestination(page: page, at: target))
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
        onCommandClick?(document.index(for: page) + 1, CGPoint(x: inPage.x, y: media.height - inPage.y))
    }
}

/// The PDF pane: header, then either the built document or the empty state.
struct PreviewPane: View {
    @ObservedObject var store: ProjectStore
    @ObservedObject private var build: BuildController
    @StateObject private var controls = PDFPreviewControls()

    init(store: ProjectStore) {
        self.store = store
        self.build = store.build
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("PDF Preview").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                    .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 4) {
                    PreviewZoomButton(icon: "minus.magnifyingglass", label: "Zoom Out", action: controls.zoomOut)
                    PreviewZoomButton(icon: "plus.magnifyingglass", label: "Zoom In", action: controls.zoomIn)
                    PreviewZoomButton(icon: "arrow.down.forward.and.arrow.up.backward", label: "Fit Page", action: controls.fitPage)
                    PreviewZoomButton(icon: "arrow.left.and.right", label: "Fit Width", action: controls.fitWidth)
                }
                .fixedSize()
                .disabled(build.pdfURL == nil)
                Text(build.lastSummary).font(.system(size: 11)).foregroundStyle(.tertiary).lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .padding(.horizontal, 18).frame(height: ChromeMetrics.paneHeaderHeight).background(Palette.previewHeader)
            Divider()
            ZStack {
                PDFPreview(pdfURL: build.pdfURL, version: build.pdfVersion, controls: controls, highlight: build.highlight) { page, point in
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
    }
}

private struct PreviewZoomButton: View {
    let icon: String
    let label: String
    var selected = false
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
            .font(.system(size: 16))
            .foregroundStyle(.black)
            .frame(width: 28, height: 28)
            .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(selected ? 0.09 : (hovered ? 0.06 : 0))))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label).accessibilityLabel(label)
        .onHover { hovered = $0 }
    }
}
