import SwiftUI
import SwiftTerm

struct TerminalPreview: UIViewRepresentable {
    let fontSize: CGFloat
    var sampleText: String = "$ ssh deploy@prod\r\nLast login: Mon Mar 29\r\ndeploy@prod:~$ "

    func makeUIView(context: Context) -> TerminalView {
        let font = UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        let tv = TerminalView(frame: .zero, font: font)
        SoyehtTerminalAppearance.apply(to: tv)
        tv.isUserInteractionEnabled = false
        tv.contentInsetAdjustmentBehavior = .never
        tv.feed(text: sampleText)
        return tv
    }

    func updateUIView(_ tv: TerminalView, context: Context) {
        tv.font = UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
    }
}
