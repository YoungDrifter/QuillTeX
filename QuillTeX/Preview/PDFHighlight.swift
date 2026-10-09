import CoreGraphics

/// A position the preview should jump to, produced by a source → PDF sync.
///
/// Kept apart from the PDFKit view so the build layer — and therefore the tests — can
/// use it without pulling SwiftUI in.
struct PDFHighlight: Equatable {
    var page: Int
    /// Point in PDF page space with a top-left origin (the SyncTeX convention).
    var point: CGPoint
    var generation: Int = 0
}
