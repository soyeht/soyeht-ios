import SwiftUI
import SwiftTerm
import SoyehtCore

struct TerminalPreview: UIViewRepresentable {
    let fontSize: CGFloat
    var sampleText: String = "$ ssh deploy@prod\r\nLast login: Mon Mar 29\r\ndeploy@prod:~$ "

    func makeUIView(context: Context) -> TerminalView {
        let font = Typography.monoUIFont(size: fontSize, weight: .regular)
        let tv = TerminalView(frame: .zero, font: font)
        SoyehtTerminalAppearance.apply(to: tv)
        tv.isUserInteractionEnabled = false
        tv.contentInsetAdjustmentBehavior = .never
        tv.feed(text: sampleText)
        return tv
    }

    func updateUIView(_ tv: TerminalView, context: Context) {
        tv.setFonts(
            normal:     Typography.monoUIFont(size: fontSize, weight: .regular, italic: false),
            bold:       Typography.monoUIFont(size: fontSize, weight: .bold,    italic: false),
            italic:     Typography.monoUIFont(size: fontSize, weight: .regular, italic: true),
            boldItalic: Typography.monoUIFont(size: fontSize, weight: .bold,    italic: true)
        )
    }
}
