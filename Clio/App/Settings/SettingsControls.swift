import AppKit
import SwiftUI

enum AccentSwatch {
    static func image(for color: NSColor) -> NSImage {
        let image = NSImage(size: NSSize(width: 14, height: 14), flipped: false) { _ in
            let circle = NSBezierPath(ovalIn: NSRect(x: 1, y: 1, width: 12, height: 12))
            color.setFill()
            circle.fill()
            NSColor.labelColor.withAlphaComponent(0.25).setStroke()
            circle.lineWidth = 0.5
            circle.stroke()
            return true
        }
        image.isTemplate = false
        return image
    }
}

struct NativeEditorFontPicker: NSViewRepresentable {
    @Binding var name: String
    @Binding var size: Double

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSButton {
        let button = InteractionButton(title: "Choose Font…", target: context.coordinator,
                              action: #selector(Coordinator.showFonts(_:)))
        button.bezelStyle = .rounded
        button.setAccessibilityIdentifier("settings.editorFont")
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.parent = self
        let font = Typography.font(size: size, name: name)
        button.title = "\(font.displayName ?? font.fontName)…"
        if (NSFontManager.shared.target as AnyObject?) === context.coordinator {
            NSFontManager.shared.setSelectedFont(font, isMultiple: false)
        }
    }

    static func dismantleNSView(_ button: NSButton, coordinator: Coordinator) {
        coordinator.releasePanel()
    }

    final class Coordinator: NSObject {
        var parent: NativeEditorFontPicker
        private weak var previousTarget: AnyObject?
        private var previousAction: Selector?
        init(_ parent: NativeEditorFontPicker) { self.parent = parent }

        @objc func showFonts(_ sender: Any?) {
            let manager = NSFontManager.shared
            if (manager.target as AnyObject?) !== self {
                previousTarget = manager.target as AnyObject?
                previousAction = manager.action
            }
            manager.target = self
            manager.action = #selector(changeFont(_:))
            manager.setSelectedFont(Typography.font(size: parent.size, name: parent.name), isMultiple: false)
            manager.orderFrontFontPanel(sender)
        }

        @objc func changeFont(_ sender: NSFontManager) {
            let font = sender.convert(Typography.font(size: parent.size, name: parent.name))
            parent.name = font.fontName
            parent.size = min(20, max(12, Double(font.pointSize)))
        }

        func releasePanel() {
            let manager = NSFontManager.shared
            guard (manager.target as AnyObject?) === self else { return }
            manager.fontPanel(false)?.orderOut(nil)
            manager.target = previousTarget
            if let previousAction { manager.action = previousAction }
        }
    }
}

struct SliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let valueLabel: String

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 12) {
                Slider(value: $value, in: range, step: step)
                    .frame(minWidth: 100, maxWidth: 220)

                Text(valueLabel)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .frame(width: 88, alignment: .trailing)
            }
        }
    }
}

struct IntegerSliderRow: View {
    let title: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    let valueLabel: String

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 12) {
                Slider(
                    value: Binding(
                        get: { Double(value) },
                        set: { value = Int($0.rounded()) }
                    ),
                    in: Double(range.lowerBound)...Double(range.upperBound),
                    step: 1
                )
                .frame(minWidth: 100, maxWidth: 220)

                Text(valueLabel)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .frame(width: 110, alignment: .trailing)
            }
        }
    }
}

struct SettingsFootnote: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}
