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
        func settle(_ duration: TimeInterval = 0.25) {
            RunLoop.main.run(until: Date().addingTimeInterval(duration))
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
        check(position.zoomMode == .manual, "reading state records manual zoom mode")
        let encodedPosition = try JSONEncoder().encode(position)
        let decodedPosition = try JSONDecoder().decode(PDFReadingState.self, from: encodedPosition)
        check(decodedPosition == position, "reading state survives persistence without losing page coordinates")

        coordinator.load(url, into: view, version: 2)
        check(view.document === firstDocument, "identical bytes keep the mounted PDF document")
        check(view.scaleFactor == position.scale, "unchanged builds preserve zoom")

        try secondData.write(to: url)
        coordinator.load(url, into: view, version: 3)
        check(view.document !== firstDocument, "changed bytes update the document")
        check(view.subviews.contains { $0 is NSImageView }, "old viewport covers document replacement")
        check(abs(view.scaleFactor - position.scale) < 0.001, "changed builds preserve zoom")
        check(view.readerPosition()!.pageIndex == position.pageIndex, "changed builds preserve the current page")
        check(view.zoomMode == .manual, "changed builds preserve manual zoom behavior")
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

        let otherURL = url.deletingLastPathComponent().appendingPathComponent("preview-other-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: otherURL) }
        try secondData.write(to: otherURL)
        let savedState = PDFReadingState(pageIndex: 1, topPoint: CGPoint(x: 20, y: 120), scale: 1.5, zoomMode: .manual)
        coordinator.load(otherURL, into: view, version: 5, readingState: savedState)
        settle()
        check(abs(view.scaleFactor - 1.5) < 0.001, "opening another PDF at the same build version restores its saved zoom")
        check(view.readerPosition()?.pageIndex == 1, "opening another PDF restores its saved page")
        check(abs((view.readerPosition()?.topPoint.y ?? 0) - savedState.topPoint.y) < 2,
              "opening another PDF restores the offset within its page")
        check(view.zoomMode == .manual, "opening another PDF restores its saved zoom mode")
        let widthState = PDFReadingState(pageIndex: 1, topPoint: CGPoint(x: 0, y: 80), scale: 0.9, zoomMode: .width)
        view.restore(widthState)
        settle()
        check(view.zoomMode == .width && abs(view.scaleFactor - 0.9) < 0.001, "restoring Fit Width preserves its chosen scale")
        var reportedState: PDFReadingState?
        view.onReadingStateChanged = { reportedState = $0 }
        let controls = PDFPreviewControls()
        controls.attach(view)
        controls.zoomIn()
        settle(0.4)
        check(reportedState?.zoomMode == .manual && abs((reportedState?.scale ?? 0) - 1.15) < 0.001,
              "zoom controls report the new reading state for the workspace session")
        controls.actualSize()
        settle()
        check(view.scaleFactor == 1 && view.zoomMode == .manual, "Actual Size selects exactly 100 percent")
        check(controls.percentage == "100%", "percentage follows Actual Size")
        view.scaleFactor = 1.37
        settle()
        check(controls.percentage == "137%", "percentage follows direct PDFKit zoom changes")
        check(controls.setPercentage("125%"), "percentage field accepts a percent suffix")
        settle()
        check(view.scaleFactor == 1.25 && controls.percentage == "125%", "editing percentage changes the actual PDF scale")
        check(controls.setPercentage("87.5"), "percentage field accepts decimals without a suffix")
        check(abs(view.scaleFactor - 0.875) < 0.001, "fractional percentage is applied precisely")
        check(!controls.setPercentage("abc") && !controls.setPercentage("-5"), "invalid zoom input leaves the PDF scale unchanged")
        check(abs(view.scaleFactor - 0.875) < 0.001, "invalid input does not change the last valid zoom")
        _ = controls.setPercentage("9999%")
        check(view.scaleFactor == view.maxScaleFactor, "entered percentages respect PDF zoom limits")
        controls.fitWidth()
        settle()
        check(view.zoomMode == .width && controls.percentage == "\(Int((view.scaleFactor * 100).rounded()))%", "percentage follows Fit Width")
        let menuEvent = NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                                          windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 0)!
        let menu = view.menu(for: menuEvent)!
        check(menu.items.map(\.title).prefix(4) == ["Zoom In", "Zoom Out", "Actual Size", "Fit Width"], "PDF menu exposes zoom, Actual Size and Fit Width")
        check(!menu.items.contains { $0.title == "Fit Page" }, "Fit Page is removed from the PDF menu")
        controls.zoomOut()
        settle()
        check(view.zoomMode == .manual, "menu zoom remains available after Fit Width")
        view.restore(PDFReadingState(pageIndex: 999, topPoint: .zero, scale: 99, zoomMode: .manual))
        settle()
        check(view.readerPosition()?.pageIndex == 2 && view.scaleFactor == view.maxScaleFactor,
              "restoration clamps removed pages and unsupported zoom levels")

        let target = PDFHighlight(page: 2, point: CGPoint(x: 50, y: 150), width: 100, height: 18)
        let media = view.document!.page(at: 1)!.bounds(for: .mediaBox)
        let targetBounds = target.bounds(in: media)
        check(targetBounds.width == 106 && targetBounds.height == 24, "sync highlight uses the reported box dimensions with a small margin")
        check(abs(targetBounds.minY - (media.maxY - 153)) < 0.001, "sync highlight converts the top-origin baseline correctly")
        view.reveal(target)
        let targetPage = view.document!.page(at: 1)!
        check(targetPage.annotations.count == 1 && !targetPage.annotations[0].shouldPrint,
              "sync location briefly marks its target without adding a printable annotation")
        view.reveal(PDFHighlight(page: 2, point: CGPoint(x: 60, y: 170), width: 120, height: 20))
        check(targetPage.annotations.count == 1, "consecutive sync locations replace the previous marker")
        settle(1.8)
        check(targetPage.annotations.isEmpty, "sync target marker disappears after the reading cue")
        view.reveal(PDFHighlight(page: 2, point: CGPoint(x: 1_000_000, y: 1_000_000)))
        check(targetPage.annotations.isEmpty, "out-of-page sync targets cannot create an invalid PDF destination")
        let unchangedPDF = try Data(contentsOf: otherURL)
        check(unchangedPDF == secondData, "sync target marker never changes the PDF on disk")
        print("PASS: \(checks) PDF-preview assertions")
    }
}
