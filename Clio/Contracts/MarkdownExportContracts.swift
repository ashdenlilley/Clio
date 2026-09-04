import Foundation

struct UTF16Range: Codable, Hashable, Sendable {
    var location: Int
    var length: Int

    init(location: Int, length: Int) {
        self.location = max(0, location)
        self.length = max(0, length)
    }

    var upperBound: Int { location + length }

    func clamped(toUTF16Length textLength: Int) -> Self {
        let safeLocation = min(location, max(0, textLength))
        return Self(
            location: safeLocation,
            length: min(length, max(0, textLength - safeLocation))
        )
    }
}

enum MarkdownSemanticKind: String, Codable, CaseIterable, Hashable, Sendable {
    case heading
    case paragraph
    case emphasis
    case strong
    case strikethrough
    case unorderedList
    case orderedList
    case task
    case blockquote
    case inlineCode
    case codeFence
    case link
    case autolink
    case table
    case thematicBreak
    case frontMatter
    case footnote
    case marker
}

enum CodeTokenKind: String, Codable, CaseIterable, Hashable, Sendable {
    case keyword
    case type
    case string
    case number
    case comment
    case function
    case property
    case operatorSymbol
    case punctuation
}

enum MarkdownSpanRole: Codable, Hashable, Sendable {
    case marker
    case content
    case destination
    case infoString
    case blockRule
    case codeToken(CodeTokenKind)
}

struct MarkdownSpan: Codable, Hashable, Sendable {
    let kind: MarkdownSemanticKind
    let role: MarkdownSpanRole
    let range: UTF16Range
    let level: Int?

    init(
        kind: MarkdownSemanticKind,
        role: MarkdownSpanRole,
        range: UTF16Range,
        level: Int? = nil
    ) {
        self.kind = kind
        self.role = role
        self.range = range
        self.level = level
    }
}

enum MarkdownDiagnosticSeverity: String, Codable, CaseIterable, Hashable, Sendable {
    case note
    case warning
    case error
}

struct MarkdownDiagnostic: Codable, Hashable, Sendable {
    let severity: MarkdownDiagnosticSeverity
    let message: String
    let range: UTF16Range?
}

enum MarkdownTableAlignment: String, Codable, CaseIterable, Hashable, Sendable {
    case none
    case leading
    case center
    case trailing
}

enum MarkdownTaskState: String, Codable, CaseIterable, Hashable, Sendable {
    case unchecked
    case checked
}

indirect enum MarkdownInline: Codable, Hashable, Sendable {
    case text(value: String, range: UTF16Range)
    case emphasis(content: [MarkdownInline], range: UTF16Range)
    case strong(content: [MarkdownInline], range: UTF16Range)
    case strikethrough(content: [MarkdownInline], range: UTF16Range)
    case code(value: String, range: UTF16Range)
    case link(
        destination: String,
        title: String?,
        content: [MarkdownInline],
        range: UTF16Range
    )
    case image(
        source: String,
        title: String?,
        alt: [MarkdownInline],
        range: UTF16Range
    )
    case autolink(text: String, destination: String, range: UTF16Range)
    case footnoteReference(label: String, range: UTF16Range)
    case softBreak(range: UTF16Range)
    case hardBreak(range: UTF16Range)
    case rawHTML(source: String, range: UTF16Range)
}

struct MarkdownListItem: Codable, Hashable, Sendable {
    let taskState: MarkdownTaskState?
    let blocks: [MarkdownBlock]
    let range: UTF16Range
}

struct MarkdownList: Codable, Hashable, Sendable {
    let isOrdered: Bool
    let start: Int?
    let isTight: Bool
    let items: [MarkdownListItem]
    let range: UTF16Range
}

struct MarkdownTableCell: Codable, Hashable, Sendable {
    let content: [MarkdownInline]
    let range: UTF16Range
}

struct MarkdownTable: Codable, Hashable, Sendable {
    let alignments: [MarkdownTableAlignment]
    let header: [MarkdownTableCell]
    let rows: [[MarkdownTableCell]]
    let range: UTF16Range
}

indirect enum MarkdownBlock: Codable, Hashable, Sendable {
    case paragraph(content: [MarkdownInline], range: UTF16Range)
    case heading(level: Int, content: [MarkdownInline], range: UTF16Range)
    case blockquote(blocks: [MarkdownBlock], range: UTF16Range)
    case list(MarkdownList)
    case codeFence(language: String?, source: String, range: UTF16Range)
    case table(MarkdownTable)
    case thematicBreak(range: UTF16Range)
    case frontMatter(source: String, range: UTF16Range)
    case footnoteDefinition(label: String, blocks: [MarkdownBlock], range: UTF16Range)
    case rawHTML(source: String, range: UTF16Range)
}

struct MarkdownDocumentModel: Codable, Hashable, Sendable {
    let blocks: [MarkdownBlock]
}

struct ParsedMarkdown: Codable, Hashable, Sendable {
    let documentID: DocumentID
    let generation: BufferGeneration
    let sourceFingerprint: String
    let sizeMode: DocumentSizeMode
    let document: MarkdownDocumentModel
    let spans: [MarkdownSpan]
    let diagnostics: [MarkdownDiagnostic]

    func canApply(to snapshot: DocumentTextSnapshot) -> Bool {
        documentID == snapshot.documentID
            && generation == snapshot.generation
            && sourceFingerprint == snapshot.sourceFingerprint
    }
}

protocol MarkdownParsing: Sendable {
    func parse(_ snapshot: DocumentTextSnapshot) async throws -> ParsedMarkdown
}

enum ExportFormat: String, Codable, CaseIterable, Hashable, Sendable, Identifiable {
    case pdf
    case html

    var id: Self { self }
}

enum PaperOrientation: String, Codable, CaseIterable, Hashable, Sendable {
    case portrait
    case landscape
}

struct PrintMargins: Codable, Hashable, Sendable {
    var top: Double
    var leading: Double
    var bottom: Double
    var trailing: Double
}

struct PDFPrintSettings: Codable, Hashable, Sendable {
    var paperName: String?
    var paperWidthPoints: Double?
    var paperHeightPoints: Double?
    var margins: PrintMargins
    var orientation: PaperOrientation

    var isValid: Bool {
        let marginValues = [margins.top, margins.leading, margins.bottom, margins.trailing]
        guard marginValues.allSatisfy({ $0.isFinite && $0 >= 0 }) else { return false }
        if paperWidthPoints == nil, paperHeightPoints == nil { return true }
        guard let paperWidthPoints, let paperHeightPoints else { return false }
        guard paperWidthPoints.isFinite,
              paperHeightPoints.isFinite,
              paperWidthPoints > 0,
              paperHeightPoints > 0 else { return false }
        // Stored dimensions are portrait-normalized; orientation is applied by
        // the exporter after validating the printable area.
        let portraitWidth = min(paperWidthPoints, paperHeightPoints)
        let portraitHeight = max(paperWidthPoints, paperHeightPoints)
        let orientedWidth = orientation == .portrait ? portraitWidth : portraitHeight
        let orientedHeight = orientation == .portrait ? portraitHeight : portraitWidth
        return orientedWidth - margins.leading - margins.trailing > 0
            && orientedHeight - margins.top - margins.bottom > 0
    }
}

struct ExportRequest: Sendable {
    let format: ExportFormat
    let snapshot: DocumentTextSnapshot
    let destinationURL: URL
    let pdfSettings: PDFPrintSettings?
    let recoveryStrategy: ExportRecoveryStrategy

    init(
        format: ExportFormat,
        snapshot: DocumentTextSnapshot,
        destinationURL: URL,
        pdfSettings: PDFPrintSettings?,
        recoveryStrategy: ExportRecoveryStrategy = .directoryTransaction
    ) {
        self.format = format
        self.snapshot = snapshot
        self.destinationURL = destinationURL
        self.pdfSettings = pdfSettings
        self.recoveryStrategy = recoveryStrategy
    }
}

/// The exact destination state presented to the user when an export collides.
/// A replacement decision is valid only for this revision; callers must ask
/// again if the file changes before the atomic commit.
struct ExportCollision: Codable, Hashable, Sendable {
    let destinationURL: URL
    let revision: DiskRevision
}

struct ExportCollisionResolution: Codable, Hashable, Sendable {
    let collision: ExportCollision
    let choice: CollisionChoice
}

struct ExportReceipt: Codable, Hashable, Sendable {
    let format: ExportFormat
    let destinationURL: URL
    let byteCount: Int64
    let completedAt: Date
    let generation: BufferGeneration
    let sourceFingerprint: String
}

@MainActor
protocol DocumentExportCoordinating: AnyObject {
    func export(_ request: ExportRequest) async throws -> ExportReceipt
}
