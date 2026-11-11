import AppKit
import PDFKit

enum PaneMode { case editor, split, preview }


@main
struct WorkspaceLayoutTests {
    @MainActor static func main() {
        _ = NSApplication.shared
        func pane(_ view: NSView = NSView()) -> NSViewController {
            let controller = NSViewController()
            controller.view = view
            return controller
        }
        let controller = WorkspaceSplitController(sidebar: pane(), topBar: pane(), editor: pane(NSTextView()), preview: pane(PDFView()), topBarHeight: 46)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentViewController = controller
        window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        window.orderFront(nil)
        window.setContentSize(NSSize(width: 1280, height: 800))
        defer { window.close() }
        func settle() {
            window.contentView?.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.35))
            window.contentView?.layoutSubtreeIfNeeded()
        }
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            guard condition() else { fatalError("FAILED: \(message)") }
            checks += 1
        }
        func sidebarWidth() -> CGFloat { controller.splitViewItems[0].viewController.view.frame.width }
        func balanced() -> Bool {
            let items = controller.content.splitViewItems
            return abs(items[0].viewController.view.frame.width - items[1].viewController.view.frame.width) < 1
        }
        /// Draws a divider into a small bitmap so the resting line can be checked
        /// without depending on the window server.
        func renderedDividerPixel(_ split: WorkspaceDividerView) -> NSColor? {
            let size = NSSize(width: 4, height: 4)
            guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4,
                                             bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                             colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
            NSGraphicsContext.saveGraphicsState()
            defer { NSGraphicsContext.restoreGraphicsState() }
            guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
            NSGraphicsContext.current = context
            NSColor.clear.setFill()
            NSRect(origin: .zero, size: size).fill(using: .copy)
            split.drawDivider(in: NSRect(origin: .zero, size: size))
            context.flushGraphics()
            return rep.colorAt(x: 2, y: 2)?.usingColorSpace(.sRGB)
        }
        settle()
        check(balanced(), "a freshly opened workspace starts with equal editor and preview widths")
        // The content column: one shared backdrop behind a transparent top bar
        // and a single white rounded card that hosts the editor/PDF split.
        let contentColumn = controller.splitViewItems[1].viewController.view
        let backdrop = controller.backdropView
        let card = controller.cardView
        let columnBounds = contentColumn.bounds
        check(backdrop.superview === contentColumn, "backdrop is hosted by the content column")
        check(card.superview === contentColumn, "card is hosted by the content column")
        check(contentColumn.subviews.first === backdrop, "backdrop is the backmost content column view")
        check(contentColumn.subviews.count == 3, "content column stacks backdrop, top bar and card")
        let topBarHost = contentColumn.subviews[1]
        check(topBarHost !== backdrop && topBarHost !== card, "top bar sits between backdrop and card")
        check(abs(topBarHost.frame.height - 46) < 0.5, "top bar keeps its 46 point height on the backdrop")
        check(abs(backdrop.frame.minX - columnBounds.minX) < 0.5 &&
              abs(backdrop.frame.minY - columnBounds.minY) < 0.5 &&
              abs(backdrop.frame.width - columnBounds.width) < 0.5 &&
              abs(backdrop.frame.height - columnBounds.height) < 0.5,
              "backdrop covers the whole content column")
        check(abs(backdrop.veilView.frame.width - backdrop.bounds.width) < 0.5 &&
              abs(backdrop.veilView.frame.height - backdrop.bounds.height) < 0.5,
              "backdrop veil covers the material")
        check(backdrop.material == .sidebar, "backdrop uses the sidebar material")
        check(backdrop.blendingMode == .behindWindow, "backdrop blends with the window background")
        check(backdrop.state == .active, "backdrop stays active")
        check(backdrop.hitTest(NSPoint(x: columnBounds.midX, y: columnBounds.midY)) == nil,
              "decorative backdrop never takes input")
        let veil = backdrop.veilView.layer?.backgroundColor.flatMap(NSColor.init(cgColor:))?.usingColorSpace(.sRGB)
        if backdrop.reducesTransparency {
            check(veil != nil && abs(veil!.whiteComponent - 0.945) < 0.01 && veil!.alphaComponent > 0.99,
                  "reduced transparency uses the opaque light gray surface")
        } else {
            check(veil != nil && abs(veil!.redComponent - 1) < 0.01 && abs(veil!.alphaComponent - 0.25) < 0.01,
                  "backdrop uses the sidebar's 25% white veil")
        }
        check(abs(card.frame.minX - 8) < 0.5, "card is inset 8 points from the content leading edge")
        check(abs(card.frame.maxX - (columnBounds.width - 8)) < 0.5, "card is inset 8 points from the content trailing edge")
        check(abs(card.frame.minY - 8) < 0.5, "card is inset 8 points from the content bottom")
        check(abs(card.frame.maxY - (columnBounds.height - 46)) < 0.5, "card starts at the 46 point top bar bottom")
        check(abs(card.frame.maxY - topBarHost.frame.minY) < 0.5, "card top is flush with the top bar bottom")
        check(card.wantsLayer, "card is layer backed")
        check(card.layer?.cornerRadius == 16, "card uses a 16 point corner radius")
        check(card.layer?.cornerCurve == .continuous, "card uses continuous corners")
        check(card.layer?.masksToBounds == true, "card clips its content to the rounded corners")
        let cardColor = card.layer?.backgroundColor.flatMap(NSColor.init(cgColor:))?.usingColorSpace(.sRGB)
        check(cardColor != nil && cardColor!.redComponent > 0.99 && cardColor!.greenComponent > 0.99 &&
              cardColor!.blueComponent > 0.99 && cardColor!.alphaComponent > 0.99, "card paints opaque white")
        check(controller.content.view.superview === card, "editor/PDF split is hosted by the card")
        check(abs(controller.content.view.frame.width - card.bounds.width) < 0.5 &&
              abs(controller.content.view.frame.height - card.bounds.height) < 0.5,
              "editor/PDF split fills the card edge to edge")
        let outerDivider = controller.splitView as! WorkspaceDividerView
        let innerDivider = controller.content.splitView as! WorkspaceDividerView
        check(outerDivider.dividerAppearance == .sharedBackground, "outer divider uses the shared backdrop appearance")
        check(outerDivider.restingDividerColor.alphaComponent == 0, "outer divider is clear at rest")
        check(innerDivider.dividerAppearance == .cardHairline, "inner divider uses the card hairline appearance")
        let hairline = innerDivider.restingDividerColor.usingColorSpace(.sRGB)
        check(hairline != nil && abs(hairline!.redComponent - 0.92) < 0.01 && hairline!.alphaComponent == 1,
              "inner divider is a subtle opaque hairline")
        let outerPixel = renderedDividerPixel(outerDivider)
        check(outerPixel != nil && outerPixel!.alphaComponent < 0.01, "outer divider paints no resting line")
        let innerPixel = renderedDividerPixel(innerDivider)
        check(innerPixel != nil && abs(innerPixel!.redComponent - 0.92) < 0.01 && innerPixel!.alphaComponent > 0.99,
              "inner divider paints the card hairline")
        // The library browser (no document open) keeps the backdrop but drops the
        // white card: its content area runs edge to edge below the top bar.
        controller.setCardStyle(.library)
        settle()
        check(controller.cardStyle == .library, "card style switches to the library browser")
        check(abs(card.frame.minX) < 0.5 && abs(card.frame.maxX - contentColumn.bounds.width) < 0.5 &&
              abs(card.frame.minY) < 0.5 && abs(card.frame.maxY - (contentColumn.bounds.height - 46)) < 0.5,
              "library card fills the content area from the top bar to the window edges")
        let libraryColor = card.layer?.backgroundColor.flatMap(NSColor.init(cgColor:))?.usingColorSpace(.sRGB)
        check(libraryColor != nil && libraryColor!.alphaComponent < 0.01, "library card has no white surface")
        check(card.layer?.masksToBounds == false && card.layer?.cornerRadius == 0,
              "library card neither rounds nor clips the browser")
        check(abs(backdrop.frame.width - contentColumn.bounds.width) < 0.5 &&
              abs(backdrop.frame.height - contentColumn.bounds.height) < 0.5,
              "backdrop still covers the content column in the library style")
        controller.setCardStyle(.document)
        settle()
        check(controller.cardStyle == .document, "card style returns to the document card")
        check(abs(card.frame.minX - 8) < 0.5 && abs(card.frame.maxX - (contentColumn.bounds.width - 8)) < 0.5 &&
              abs(card.frame.minY - 8) < 0.5 && abs(card.frame.maxY - (contentColumn.bounds.height - 46)) < 0.5,
              "switching back restores the document card insets")
        check(card.layer?.cornerRadius == 16 && card.layer?.masksToBounds == true,
              "switching back restores the white rounded card")
        let drawn = NSRect(x: sidebarWidth(), y: 0, width: controller.splitView.dividerThickness, height: 800)
        let grab = controller.splitView(controller.splitView, effectiveRect: drawn, forDrawnRect: drawn, ofDividerAt: 0)
        check(abs(grab.width - 25) < 1, "sidebar resize cursor is limited to the divider")
        check(!grab.contains(CGPoint(x: 100, y: 100)), "sidebar content is outside divider hover area")
        let sidebar = sidebarWidth()
        check(abs(sidebar - 248) < 1, "initial sidebar width")
        controller.content.splitView.setPosition(350, ofDividerAt: 0)
        settle()
        check(abs(sidebarWidth() - sidebar) < 1, "editor/PDF resizing keeps sidebar width")
        check(!balanced(), "editor/PDF divider can create unequal widths")
        controller.update(sidebarVisible: true, paneMode: .split, splitLayoutVersion: 1)
        settle()
        check(balanced(), "Editor and PDF balances the two content panes")
        check(abs(sidebarWidth() - sidebar) < 1, "balancing keeps sidebar width")
        controller.content.splitView.setPosition(350, ofDividerAt: 0)
        settle()
        controller.update(sidebarVisible: true, paneMode: .split, splitLayoutVersion: 2)
        settle()
        check(balanced(), "clicking the already-selected split mode balances again")
        for mode in [PaneMode.editor, .preview, .split] {
            controller.update(sidebarVisible: true, paneMode: mode, splitLayoutVersion: 2)
            settle()
            check(abs(sidebarWidth() - sidebar) < 1, "pane mode changes keep sidebar width")
        }
        check(balanced(), "returning from a single pane balances content")
        controller.splitView.setPosition(310, ofDividerAt: 0)
        settle()
        check(abs(sidebarWidth() - 310) < 1, "sidebar divider remains adjustable")
        controller.content.splitView.setPosition(350, ofDividerAt: 0)
        settle()
        check(abs(sidebarWidth() - 310) < 1, "content resizing preserves a custom sidebar width")
        controller.update(sidebarVisible: true, paneMode: .split, splitLayoutVersion: 3)
        settle()
        check(balanced(), "balancing works with a custom sidebar width")
        check(abs(sidebarWidth() - 310) < 1, "balancing preserves a custom sidebar width")
        controller.update(sidebarVisible: false, paneMode: .split, splitLayoutVersion: 3)
        settle()
        controller.update(sidebarVisible: true, paneMode: .split, splitLayoutVersion: 3)
        settle()
        check(abs(sidebarWidth() - 310) < 1, "hiding and showing restores custom sidebar width")
        func verifyCursorRegion(_ split: WorkspaceDividerView) {
            guard let divider = split.effectiveDividerRects.first else { fatalError("missing divider") }
            check(abs(divider.rect.width - 25) < 1, "cursor and drag region have the same 25 point width")
            for offset: CGFloat in [-12, -6, 0, 6, 12] {
                let point = NSPoint(x: divider.rect.midX + offset, y: split.bounds.midY)
                let parentPoint = split.convert(point, to: split.superview)
                check(split.hitTest(parentPoint) === split, "split owns hit testing throughout the grab region")
                let location = split.convert(point, to: nil)
                let event = NSEvent.mouseEvent(with: .mouseMoved, location: location, modifierFlags: [],
                                               timestamp: 0, windowNumber: window.windowNumber,
                                               context: nil, eventNumber: 0, clickCount: 0, pressure: 0)!
                NSCursor.iBeam.set()
                split.cursorUpdate(with: event)
                check(NSCursor.current == NSCursor.resizeLeftRight, "cursorUpdate shows resize on both sides")
                NSCursor.iBeam.set()
                split.mouseMoved(with: event)
                check(NSCursor.current == NSCursor.resizeLeftRight, "mouseMoved maintains resize against editor/PDF cursors")
            }
            for offset: CGFloat in [-20, 20] {
                let point = NSPoint(x: divider.rect.midX + offset, y: split.bounds.midY)
                check(split.hitTest(split.convert(point, to: split.superview)) !== split, "pane owns input beyond grab region")
            }
            check(split.trackingAreas.contains { $0.options.contains(.mouseMoved) && $0.options.contains(.enabledDuringMouseDrag) },
                  "tracking maintains hover while moving and dragging")
        }
        verifyCursorRegion(controller.splitView as! WorkspaceDividerView)
        verifyCursorRegion(controller.content.splitView as! WorkspaceDividerView)
        controller.content.splitView.setPosition(400, ofDividerAt: 0)
        settle()
        verifyCursorRegion(controller.content.splitView as! WorkspaceDividerView)
        let wideCard = card.frame
        window.setContentSize(NSSize(width: 960, height: 700))
        settle()
        check(abs(card.frame.width - (wideCard.width - 320)) < 1, "card shrinks with the window")
        check(abs(card.frame.minX - 8) < 0.5 && abs(card.frame.maxX - (contentColumn.bounds.width - 8)) < 0.5,
              "card keeps its horizontal insets after a window resize")
        check(abs(card.frame.minY - 8) < 0.5 && abs(card.frame.maxY - (contentColumn.bounds.height - 46)) < 0.5,
              "card keeps its vertical insets after a window resize")
        verifyCursorRegion(controller.content.splitView as! WorkspaceDividerView)
        for mode in [PaneMode.editor, .preview] {
            controller.update(sidebarVisible: true, paneMode: mode, splitLayoutVersion: 4)
            settle()
            check((controller.content.splitView as! WorkspaceDividerView).effectiveDividerRects.isEmpty,
                  "collapsed content panes leave no resize hit or cursor region")
            // AppKit may re-run the window's content constraints while collapsing a
            // split item, so verify the card tracks its own content column exactly.
            check(abs(card.frame.minX - 8) < 0.5 &&
                  abs(card.frame.maxX - (contentColumn.bounds.width - 8)) < 0.5 &&
                  abs(card.frame.minY - 8) < 0.5 &&
                  abs(card.frame.maxY - (contentColumn.bounds.height - 46)) < 0.5,
                  "Editor Only / PDF Only leaves the card and its insets unchanged")
        }
        let expandedContentWidth = contentColumn.bounds.width
        controller.update(sidebarVisible: false, paneMode: .split, splitLayoutVersion: 4)
        settle()
        check((controller.splitView as! WorkspaceDividerView).effectiveDividerRects.isEmpty,
              "collapsed sidebar leaves no stale resize region")
        check(abs(card.frame.minX - 8) < 0.5 && abs(card.frame.width - (contentColumn.bounds.width - 16)) < 0.5,
              "card follows the content column when the sidebar collapses")
        check(contentColumn.bounds.width > expandedContentWidth + 100 && card.frame.width > 200,
              "collapsing the sidebar gives the card the reclaimed width")
        verifyCursorRegion(controller.content.splitView as! WorkspaceDividerView)
        window.setContentSize(NSSize(width: 1280, height: 800))
        controller.update(sidebarVisible: true, paneMode: .split, splitLayoutVersion: 4)
        settle()
        check(abs(card.frame.width - (contentColumn.bounds.width - 16)) < 0.5,
              "card returns to the expanded content column width")
        check(abs(card.frame.maxY - (contentColumn.bounds.height - 46)) < 0.5,
              "card keeps the top bar boundary after expanding again")
        controller.restoreLayout(sidebarWidth: 315, editorFraction: 0.64)
        settle()
        check(abs(sidebarWidth() - 315) < 1, "restored sidebar width is applied independently")
        check(abs(controller.content.editorFraction - 0.64) < 0.01, "restored editor fraction is applied to mounted panes")
        var reported: (Double, Double)?
        controller.onLayoutChange = { reported = ($0, $1) }
        controller.content.splitView.setPosition(400, ofDividerAt: 0)
        settle()
        check(reported != nil && abs(reported!.0 - 315) < 1, "divider changes report layout without changing sidebar width")
        check(abs(reported!.1 - controller.content.editorFraction) < 0.01, "divider changes report the actual content fraction")
        var reportedVisibility: Bool?
        controller.onSidebarVisibilityChange = { reportedVisibility = $0 }
        controller.splitView.setPosition(0, ofDividerAt: 0)
        settle()
        check(controller.splitViewItems[0].isCollapsed, "dragging the divider fully left collapses the sidebar")
        check(reportedVisibility == false, "a dragged collapse reports hidden visibility to the store")
        controller.update(sidebarVisible: true, paneMode: .split, splitLayoutVersion: 5)
        settle()
        check(!controller.splitViewItems[0].isCollapsed, "the sidebar toggle reopens a dragged-closed sidebar")
        check(abs(sidebarWidth() - 315) < 1, "reopening after a dragged collapse restores the previous width")
        let editorScroll = NSScrollView()
        editorScroll.hasVerticalScroller = true
        editorScroll.autohidesScrollers = true
        editorScroll.scrollerStyle = .overlay
        let source = NSTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 4000))
        source.string = String(repeating: "A long source document\n", count: 200)
        editorScroll.documentView = source
        let scrolling = WorkspaceSplitController(sidebar: pane(), topBar: pane(), editor: pane(editorScroll), preview: pane(), topBarHeight: 46)
        window.contentViewController = scrolling
        window.setContentSize(NSSize(width: 1280, height: 800))
        scrolling.view.frame = NSRect(x: 0, y: 0, width: 1280, height: 800)
        settle()
        let contentDivider = scrolling.content.splitView as! WorkspaceDividerView
        let sidebarDivider = scrolling.splitView as! WorkspaceDividerView
        RunLoop.main.run(until: Date().addingTimeInterval(2))
        check(!contentDivider.effectiveDividerRects.isEmpty, "faded overlay scroller permits resizing")
        editorScroll.flashScrollers()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        check(contentDivider.isDividerDragBlocked(at: 0), "visible overlay knob blocks the entire content divider")
        check(contentDivider.effectiveDividerRects.isEmpty, "visible scroller removes both sides of the divider grab region")
        let line = NSRect(x: contentDivider.subviews[0].frame.maxX, y: 0, width: 1, height: contentDivider.bounds.height)
        check(scrolling.content.splitView(contentDivider, effectiveRect: line, forDrawnRect: line, ofDividerAt: 0).isEmpty,
              "native split dragging is disabled as well as custom hit testing")
        check(!sidebarDivider.effectiveDividerRects.isEmpty, "editor scrollbar does not disable the sidebar divider")
        let originalWidth = contentDivider.subviews[0].frame.width
        let click = NSEvent.mouseEvent(with: .leftMouseDown, location: contentDivider.convert(NSPoint(x: line.midX + 8, y: 100), to: nil),
                                      modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                      eventNumber: 0, clickCount: 1, pressure: 1)!
        contentDivider.mouseDown(with: click)
        check(contentDivider.subviews[0].frame.width == originalWidth, "preview-side click cannot begin dragging while the knob is visible")
        RunLoop.main.run(until: Date().addingTimeInterval(2))
        check(!contentDivider.effectiveDividerRects.isEmpty, "resizing resumes after the overlay knob fades")
        editorScroll.scrollerStyle = .legacy
        editorScroll.autohidesScrollers = false
        settle()
        check(contentDivider.isDividerDragBlocked(at: 0), "always-visible legacy scrollbar keeps content resizing disabled")
        editorScroll.hasVerticalScroller = false
        settle()
        check(!contentDivider.effectiveDividerRects.isEmpty, "removing the scrollbar restores content resizing")

        // Both middle dividers pause while the pane beside them shows a scrollbar.
        let sidebarScroll = NSScrollView()
        sidebarScroll.hasVerticalScroller = true
        sidebarScroll.autohidesScrollers = true
        sidebarScroll.scrollerStyle = .overlay
        let sidebarText = NSTextView(frame: NSRect(x: 0, y: 0, width: 240, height: 4000))
        sidebarText.string = String(repeating: "Section\n", count: 400)
        sidebarScroll.documentView = sidebarText
        let both = WorkspaceSplitController(sidebar: pane(sidebarScroll), topBar: pane(), editor: pane(NSTextView()), preview: pane(), topBarHeight: 46)
        window.contentViewController = both
        window.setContentSize(NSSize(width: 1280, height: 800))
        both.view.frame = NSRect(x: 0, y: 0, width: 1280, height: 800)
        settle()
        let bothSidebarDivider = both.splitView as! WorkspaceDividerView
        let bothContentDivider = both.content.splitView as! WorkspaceDividerView
        RunLoop.main.run(until: Date().addingTimeInterval(2))
        check(!bothSidebarDivider.effectiveDividerRects.isEmpty, "faded sidebar scroller permits resizing")
        sidebarScroll.flashScrollers()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        check(bothSidebarDivider.isDividerDragBlocked(at: 0), "visible sidebar scrollbar blocks the sidebar divider")
        check(bothSidebarDivider.effectiveDividerRects.isEmpty, "visible sidebar scroller removes the divider grab region")
        let sidebarLine = NSRect(x: bothSidebarDivider.subviews[0].frame.maxX, y: 0, width: 1, height: bothSidebarDivider.bounds.height)
        check(both.splitView(bothSidebarDivider, effectiveRect: sidebarLine, forDrawnRect: sidebarLine, ofDividerAt: 0).isEmpty,
              "native sidebar split dragging is disabled while its scrollbar is visible")
        check(!bothContentDivider.effectiveDividerRects.isEmpty, "the sidebar scrollbar does not disable the content divider")
        let sidebarOriginalWidth = bothSidebarDivider.subviews[0].frame.width
        let sidebarClick = NSEvent.mouseEvent(with: .leftMouseDown,
                                             location: bothSidebarDivider.convert(NSPoint(x: sidebarLine.midX + 8, y: 100), to: nil),
                                             modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                             eventNumber: 0, clickCount: 1, pressure: 1)!
        bothSidebarDivider.mouseDown(with: sidebarClick)
        check(bothSidebarDivider.subviews[0].frame.width == sidebarOriginalWidth,
              "a click on the sidebar divider cannot begin dragging while its scrollbar is visible")
        RunLoop.main.run(until: Date().addingTimeInterval(2))
        check(!bothSidebarDivider.effectiveDividerRects.isEmpty, "sidebar resizing resumes after the scroller fades")

        // A chosen editor/PDF ratio must survive window resizes instead of drifting
        // when AppKit hands new width to both panes equally.
        both.restoreLayout(sidebarWidth: 248, editorFraction: 0.62)
        settle()
        check(abs(both.content.editorFraction - 0.62) < 0.01, "restored content ratio is applied")
        window.setContentSize(NSSize(width: 1100, height: 800))
        settle()
        check(abs(both.content.editorFraction - 0.62) < 0.02, "content ratio survives shrinking the window")
        window.setContentSize(NSSize(width: 1440, height: 800))
        settle()
        check(abs(both.content.editorFraction - 0.62) < 0.02, "content ratio survives growing the window")

        // A project opened from the launcher creates its split before the workspace
        // window reaches its editing size; the stored ratio must still win.
        let reopened = WorkspaceSplitController(sidebar: pane(), topBar: pane(), editor: pane(NSTextView()), preview: pane(PDFView()), topBarHeight: 46)
        let reopenedWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 700),
                                      styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        reopenedWindow.contentViewController = reopened
        reopenedWindow.setFrameOrigin(NSPoint(x: -20000, y: -10000))
        reopenedWindow.orderFront(nil)
        reopened.restoreLayout(sidebarWidth: 248, editorFraction: 0.35)
        reopenedWindow.contentView?.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.35))
        reopenedWindow.contentView?.layoutSubtreeIfNeeded()
        reopenedWindow.setContentSize(NSSize(width: 1280, height: 800))
        reopenedWindow.contentView?.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.35))
        reopenedWindow.contentView?.layoutSubtreeIfNeeded()
        check(abs(reopened.content.editorFraction - 0.35) < 0.02,
              "reopened workspace keeps its stored ratio after the window grows to editing size")
        reopenedWindow.close()

        print("PASS: \(checks) workspace-layout assertions")
    }
}
