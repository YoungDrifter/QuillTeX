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
        let tabs = pane()
        let controller = WorkspaceSplitController(sidebar: pane(), editor: pane(NSTextView()), preview: pane(PDFView()), tabBar: tabs)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentViewController = controller
        window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        window.orderFront(nil)
        window.setContentSize(NSSize(width: 1280, height: 800))
        defer { window.close() }
        func settle() {
            window.contentView?.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
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
        settle()
        let drawn = NSRect(x: sidebarWidth(), y: 0, width: controller.splitView.dividerThickness, height: 800)
        let grab = controller.splitView(controller.splitView, effectiveRect: drawn, forDrawnRect: drawn, ofDividerAt: 0)
        check(abs(grab.width - 25) < 1, "sidebar resize cursor is limited to the divider")
        check(!grab.contains(CGPoint(x: 100, y: 100)), "sidebar content is outside divider hover area")
        let sidebar = sidebarWidth()
        check(abs(sidebar - 240) < 1, "initial sidebar width")
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
        controller.update(sidebarVisible: true, paneMode: .split, splitLayoutVersion: 4, showTabs: true)
        settle()
        let widthBeforeTabs = sidebarWidth()
        check(abs(tabs.view.frame.height - 32) < 1, "tab row is 32 points high")
        let tabOrigin = controller.splitView.convert(tabs.view.bounds.origin, from: tabs.view)
        check(abs(tabOrigin.x - sidebarWidth() - controller.splitView.dividerThickness) < 1, "tabs start at content edge, outside sidebar")
        controller.update(sidebarVisible: true, paneMode: .split, splitLayoutVersion: 4, showTabs: false)
        settle()
        check(tabs.view.isHidden && tabs.view.frame.height < 1, "single tab hides row without taking space")
        check(abs(sidebarWidth() - widthBeforeTabs) < 1, "tab row visibility preserves sidebar width")
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
        window.setContentSize(NSSize(width: 960, height: 700))
        settle()
        verifyCursorRegion(controller.content.splitView as! WorkspaceDividerView)
        for mode in [PaneMode.editor, .preview] {
            controller.update(sidebarVisible: true, paneMode: mode, splitLayoutVersion: 4)
            settle()
            check((controller.content.splitView as! WorkspaceDividerView).effectiveDividerRects.isEmpty,
                  "collapsed content panes leave no resize hit or cursor region")
        }
        controller.update(sidebarVisible: false, paneMode: .split, splitLayoutVersion: 4)
        settle()
        check((controller.splitView as! WorkspaceDividerView).effectiveDividerRects.isEmpty,
              "collapsed sidebar leaves no stale resize region")
        verifyCursorRegion(controller.content.splitView as! WorkspaceDividerView)
        print("PASS: \(checks) workspace-layout assertions")
    }
}
