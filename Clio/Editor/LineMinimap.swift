import AppKit
import Observation
import SwiftUI

struct LineMinimapSnapshot: Equatable, Sendable {
    struct Stroke: Equatable, Sendable {
        let offset: Int
        let width: Double
    }
    let strokes: [Stroke]
    let sourceLength: Int
    let isSampled: Bool
    static let empty = Self(strokes: [], sourceLength: 0, isSampled: false)
    static let maximumStrokes = 160

    /// Called on the Markdown actor, using its existing source mirror. Large
    /// files sample bounded windows rather than scanning or copying the file.
    static func make(from source: NSString) -> Self {
        let length = source.length
        guard length > 0 else { return .empty }
        var lines: [Stroke] = []
        if length > 65_536 {
            for index in 0..<maximumStrokes {
                var offset = index * length / maximumStrokes
                if offset > 0, (0xDC00...0xDFFF).contains(source.character(at: offset)) { offset -= 1 }
                let sample = source.substring(with: NSRange(location: offset, length: min(128, length - offset)))
                let count = sample.prefix(while: { !$0.isNewline }).filter { !$0.isWhitespace }.count
                if count > 0 { lines.append(Stroke(offset: offset, width: min(1, Double(count) / 72))) }
            }
            return Self(strokes: lines, sourceLength: length, isSampled: true)
        }
        var offset = 0
        while offset < length {
            var end = 0
            var contentsEnd = 0
            source.getLineStart(nil, end: &end, contentsEnd: &contentsEnd, for: NSRange(location: offset, length: 0))
            let line = source.substring(with: NSRange(location: offset, length: contentsEnd - offset))
            let count = line.trimmingCharacters(in: .whitespaces).count
            if count > 0 { lines.append(Stroke(offset: offset, width: min(1, Double(count) / 72))) }
            guard end > offset else { break }
            offset = end
        }
        if lines.count > maximumStrokes {
            let all = lines
            lines = (0..<maximumStrokes).map { all[$0 * (all.count - 1) / (maximumStrokes - 1)] }
            return Self(strokes: lines, sourceLength: length, isSampled: true)
        }
        return Self(strokes: lines, sourceLength: length, isSampled: false)
    }

    func activeIndex(at offset: Int) -> Int {
        max(0, strokes.lastIndex(where: { $0.offset <= offset }) ?? 0)
    }

    func displayed(in height: CGFloat) -> [Stroke] {
        let capacity = max(1, min(Self.maximumStrokes, Int(max(0, height) / 8)))
        guard strokes.count > capacity else { return strokes }
        guard capacity > 1 else { return Array(strokes.prefix(1)) }
        return (0..<capacity).map { strokes[$0 * (strokes.count - 1) / (capacity - 1)] }
    }
}

@MainActor @Observable final class EditorMinimapModel {
    var snapshot = LineMinimapSnapshot.empty
    var visibleOffset = 0
    var reservesNativeScroller = NSScroller.preferredScrollerStyle == .legacy
    @ObservationIgnored var navigate: ((Int) -> Void)?
}

struct EditorMinimapOverlay: View {
    @Environment(EditorWindowSession.self) private var windowSession
    @Environment(AppState.self) private var appState

    var body: some View {
        GeometryReader { geometry in
            let model = windowSession.minimap
            let strokes = model.snapshot.displayed(in: max(0, geometry.size.height - 32))
            if !strokes.isEmpty && windowSession.motion.contextProgress > 0.001 {
                let active = max(0, strokes.lastIndex(where: { $0.offset <= model.visibleOffset }) ?? 0)
                Canvas { context, size in
                    for (index, stroke) in strokes.enumerated() {
                        let width = 2 + stroke.width * 10
                        let rect = CGRect(x: size.width - width - 8, y: CGFloat(index) * 8 + 5,
                                          width: width, height: index == active ? 1.5 : 1)
                        context.fill(Path(roundedRect: rect, cornerRadius: 1),
                                     with: .color(index == active ? appState.accent.color.opacity(0.8) : Color(nsColor: Palette.muted).opacity(0.7)))
                    }
                }
                .frame(width: 32, height: CGFloat(strokes.count) * 8 + 8)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                    let index = min(max(0, Int((value.location.y - 4) / 8)), strokes.count - 1)
                    windowSession.motion.update { $0.noteIntentionalInteraction() }
                    model.navigate?(strokes[index].offset)
                })
                .onHover { hovering in
                    if hovering { windowSession.motion.update { $0.noteIntentionalInteraction() } }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Document minimap")
                .accessibilityValue("Block \(active + 1) of \(strokes.count)\(model.snapshot.isSampled ? ", sampled" : "")")
                .accessibilityAdjustableAction { direction in
                    let next = direction == .increment ? min(active + 1, strokes.count - 1) : max(0, active - 1)
                    windowSession.motion.update { $0.noteIntentionalInteraction() }
                    model.navigate?(strokes[next].offset)
                }
                .accessibilityIdentifier("editor.minimap")
                .modifier(ContextChromeMotion(motion: windowSession.motion))
                .padding(.top, 12)
                .padding(.trailing, model.reservesNativeScroller ? 16 : 0)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }
        }
        .allowsHitTesting(!windowSession.motion.hasActiveSurfaces)
    }
}
