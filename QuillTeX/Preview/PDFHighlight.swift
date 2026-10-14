import Foundation
import CoreGraphics

/// A position the preview should jump to, produced by a source → PDF sync.
///
/// Kept apart from the PDFKit view so the build layer — and therefore the tests — can
/// use it without pulling SwiftUI in.
struct PDFHighlight: Equatable {
    var page: Int
    /// Point in PDF page space with a top-left origin (the SyncTeX convention).
    var point: CGPoint
    var width: CGFloat = 0
    var height: CGFloat = 0
    var generation: Int = 0

    /// SyncTeX's box origin is its lower-left corner, measured from the page top.
    func bounds(in mediaBox: CGRect) -> CGRect {
        let boxWidth = width.isFinite && width > 0 ? width : 36
        let boxHeight = height.isFinite && height > 0 ? height : 14
        return CGRect(x: mediaBox.minX + point.x,
                      y: mediaBox.maxY - point.y,
                      width: boxWidth, height: boxHeight)
            .insetBy(dx: -3, dy: -3).intersection(mediaBox)
    }
}

enum PDFZoomMode: String, Codable {
    case wholePage, width, manual
}

/// A portable reading position. Page coordinates use the SyncTeX top-left origin.
struct PDFReadingState: Codable, Equatable {
    var pageIndex: Int
    var topPoint: CGPoint
    var scale: CGFloat
    var zoomMode: PDFZoomMode = .wholePage
}
