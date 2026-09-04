import Foundation

/// Presentation depth chosen from the document-size contract. The source is
/// never transformed, regardless of highlighting mode.
enum MarkdownHighlightingMode: Equatable, Sendable {
    case full
    case reduced
    case unsupported
}
