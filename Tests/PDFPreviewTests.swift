import AppKit
import PDFKit

@main
struct PDFPreviewTests {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            guard condition() else { fatalError("FAILED: \(message)") }
            checks += 1
        }
        func settle() {
            RunLoop.main.run(until: Date().addingTimeInterval(0.25))
        }
        func pdf(_ color: NSColor) -> Data {
            let image = NSImage(size: NSSize(width: 400, height: 600))
            image.lockFocus()
            color.setFill()
            NSRect(x: 0, y: 0, width: 400, height: 600).fill()
            image.unlockFocus()
            let document = PDFDocument()
            for _ in 0..<3 { document.insert(PDFPage(image: image)!, at: document.pageCount) }
            return document.dataRepresentation()!
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("preview-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        let firstData = pdf(.white)
        let secondData = pdf(.lightGray)
        try firstData.write(to: url)
        let view = SyncPDFView(frame: NSRect(x: 0, y: 0, width: 600, height: 700))
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        window.orderFront(nil)
        defer { window.close() }
        let coordinator = PDFPreview.Coordinator()
        coordinator.load(url, into: view, version: 1)
        settle()
        let firstDocument = view.document!
        view.zoomMode = .manual
        view.scaleFactor = 1.25
        view.go(to: firstDocument.page(at: 1)!)
        settle()
        let position = view.readerPosition()!

        coordinator.load(url, into: view, version: 2)
        check(view.document === firstDocument, "identical bytes keep the mounted PDF document")
        check(view.scaleFactor == position.scale, "unchanged builds preserve zoom")

        try secondData.write(to: url)
        coordinator.load(url, into: view, version: 3)
        check(view.document !== firstDocument, "changed bytes update the document")
        check(view.subviews.contains { $0 is NSImageView }, "old viewport covers document replacement")
        check(abs(view.scaleFactor - position.scale) < 0.001, "changed builds preserve zoom")
        check(view.document!.index(for: view.currentPage!) == position.pageIndex, "changed builds preserve the current page")
        settle()
        check(!view.subviews.contains { $0 is NSImageView }, "refresh cover is removed after rendering")

        let goodDocument = view.document!
        try Data("invalid PDF".utf8).write(to: url)
        coordinator.load(url, into: view, version: 4)
        check(view.document === goodDocument, "truncated output keeps the last good preview")
        check(goodDocument.page(at: 2) != nil, "loaded pages survive overwriting the output file")
        try firstData.write(to: url)
        coordinator.load(url, into: view, version: 4)
        check(view.document !== goodDocument, "failed loads can retry the same version")
        try secondData.write(to: url)
        coordinator.load(url, into: view, version: 5)
        check(view.subviews.filter { $0 is NSImageView }.count == 1, "rapid refreshes keep a single cover")
        coordinator.clear(view)
        check(view.document == nil && !view.subviews.contains { $0 is NSImageView }, "project reset clears document and cover")
        coordinator.load(url, into: view, version: 5)
        settle()
        check(view.document?.pageCount == 3, "project reset permits loading the same version again")
        check(!view.subviews.contains { $0 is NSImageView }, "stale refresh callbacks leave no cover")
        print("PASS: \(checks) PDF-preview assertions")
    }
}
