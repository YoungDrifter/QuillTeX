import AppKit
import SwiftUI

/// Sample the rendered titlebar, not just its target state: the selection must
/// remain dark while passing between buttons, including across the middle slot.
private struct ObservedTitlebar: View {
    @ObservedObject var store: ProjectStore
    var body: some View { TopBar(store: store) }
}

@main struct ChromeAnimationTests {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("QuillTeX-chrome-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temp) }
        let store = ProjectStore(library: DocumentLibrary(directory: temp,
            bundledTemplatesDirectory: URL(fileURLWithPath: "QuillTeX/Project/BundledTemplates")))
        store.paneMode = .editor
        let root = NSHostingView(rootView: ObservedTitlebar(store: store))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 54),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = root
        window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        window.orderFront(nil)
        defer { window.close() }
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            guard condition() else { fatalError("FAILED: \(message)") }
            checks += 1
        }
        func settle(_ duration: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(duration)) }
        func selection() -> (center: CGFloat, width: CGFloat) {
            root.layoutSubtreeIfNeeded()
            let bitmap = root.bitmapImageRepForCachingDisplay(in: root.bounds)!
            root.cacheDisplay(in: root.bounds, to: bitmap)
            let scale = CGFloat(bitmap.pixelsWide) / root.bounds.width
            // Scan the pill's lower edge, below the glyphs, in the pane controls.
            let y = Int(40 * scale)
            var best = (start: 0, length: 0), start = 0
            for x in Int((root.bounds.width - 290) * scale)..<Int((root.bounds.width - 100) * scale) {
                let color = bitmap.colorAt(x: x, y: y)!.usingColorSpace(.deviceRGB)!
                if max(color.redComponent, color.greenComponent, color.blueComponent) < 0.4 {
                    if start == 0 { start = x }
                    if x-start+1 > best.length { best = (start, x-start+1) }
                } else { start = 0 }
            }
            return ((CGFloat(best.start) + CGFloat(best.length)/2) / scale, CGFloat(best.length) / scale)
        }
        settle(0.5)
        let editor = selection()
        func switchTo(_ mode: PaneMode) -> (center: CGFloat, width: CGFloat) {
            let initial = selection()
            store.paneMode = mode
            var centers: [CGFloat] = []
            for _ in 0..<10 {
                settle(0.025)
                let frame = selection()
                check(frame.width >= 24, "moving selection stays visible instead of fading out between buttons")
                centers.append(frame.center)
            }
            settle(0.35)
            let final = selection()
            check(final.width >= 24, "selection remains visible at its destination")
            if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                let lower = min(initial.center, final.center) + 6
                let upper = max(initial.center, final.center) - 6
                check(centers.contains { $0 > lower && $0 < upper }, "selection renders intermediate positions instead of jumping")
            }
            return final
        }
        let preview = switchTo(.preview)
        check(preview.center - editor.center > 80, "selection can slide across both pane slots")
        let split = switchTo(.split)
        check(split.center > editor.center && split.center < preview.center, "middle pane has its own selection position")
        let returned = switchTo(.editor)
        check(abs(returned.center-editor.center) < 1, "selection slides back to the first pane")
        print("PASS: \(checks) chrome-animation assertions")
    }
}
