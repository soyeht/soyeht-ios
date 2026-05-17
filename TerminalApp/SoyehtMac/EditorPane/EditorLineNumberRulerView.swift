import AppKit
import SoyehtCore

final class EditorLineNumberRulerView: NSRulerView {
    private weak var textView: NSTextView?
    private var gutterFontSize: CGFloat = 11

    init(textView: NSTextView) {
        self.textView = textView
        super.init(scrollView: textView.enclosingScrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 60
        gutterFontSize = max(9, TerminalPreferences.shared.fontSize * 0.85)
    }

    override func resetCursorRects() {
        MacCursor.claim(.arrow, on: self)
    }

    required init(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    override var isFlipped: Bool { true }

    /// Update only the gutter font. Width stays fixed at 60pt so the scroll
    /// view's tiling stays put; mutating `ruleThickness` after attachment
    /// desyncs the document origin from the gutter.
    func applyMetrics(bodySize: CGFloat) {
        gutterFontSize = max(9, bodySize * 0.85)
        needsDisplay = true
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        EditorPaneDesign.surfaceDeep.setFill()
        bounds.fill()

        guard let textView,
              let layoutManager = textView.layoutManager else { return }

        let visibleRect = scrollView?.contentView.bounds ?? textView.visibleRect
        let text = textView.string as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: gutterFontSize, weight: .regular),
            .foregroundColor: EditorPaneDesign.dim,
        ]

        let topY = visibleRect.minY
        let bottomY = visibleRect.maxY
        var lineNumber = 1
        var index = 0
        while index < text.length {
            let lineRange = text.lineRange(for: NSRange(location: index, length: 0))
            let lineGlyphRange = layoutManager.glyphRange(forCharacterRange: lineRange, actualCharacterRange: nil)
            if lineGlyphRange.length > 0 {
                let lineRect = layoutManager.lineFragmentRect(forGlyphAt: lineGlyphRange.location, effectiveRange: nil)
                let lineTop = textView.textContainerOrigin.y + lineRect.minY
                if lineTop > bottomY { break }
                if lineTop + lineRect.height >= topY {
                    let label = "\(lineNumber)" as NSString
                    let size = label.size(withAttributes: attrs)
                    label.draw(
                        at: NSPoint(x: max(4, ruleThickness - size.width - 9), y: lineTop - topY),
                        withAttributes: attrs
                    )
                }
            }
            lineNumber += 1
            index = NSMaxRange(lineRange)
        }
    }
}
