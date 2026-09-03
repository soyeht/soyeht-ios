import SwiftUI
import SoyehtCore

/// One layout for every step of setup: the canvas, the step dots, a title, a
/// paragraph, whatever the step itself needs, and a footer.
///
/// Setup pins `NeoPalette.cloud` rather than following the active style. A
/// first launch has not chosen a style yet, and someone who runs classic
/// should not watch the window they are already in change appearance
/// mid-flow.
struct WelcomeStepScaffold<Content: View, Footer: View>: View {
    let step: Int
    let title: LocalizedStringResource
    let body_: LocalizedStringResource?
    let content: Content
    let footer: Footer

    private let palette = NeoPalette.cloud
    private static var stepCount: Int { 4 }

    init(
        step: Int,
        title: LocalizedStringResource,
        body: LocalizedStringResource? = nil,
        @ViewBuilder content: () -> Content,
        @ViewBuilder footer: () -> Footer
    ) {
        self.step = step
        self.title = title
        self.body_ = body
        self.content = content()
        self.footer = footer()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            NeoProgressDots(
                count: Self.stepCount,
                current: step - 1,
                palette: palette,
                accessibilityText: String(
                    localized: "bootstrap.dots.a11y",
                    defaultValue: "Step \(step) of \(Self.stepCount)",
                    comment: "VoiceOver label for the setup step indicator."
                )
            )
            .accessibilityIdentifier(WelcomeAccessibilityID.dots)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.bottom, 32)

            Text(title)
                .font(NeoFont.title)
                .foregroundStyle(palette.text)
                .fixedSize(horizontal: false, vertical: true)

            if let body_ {
                Text(body_)
                    .font(NeoFont.body)
                    .foregroundStyle(palette.textSecondary)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 12)
            }

            content
                .padding(.top, 28)

            Spacer(minLength: 16)

            footer
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(palette.canvas)
        .environment(\.neoPalette, palette)
        .accessibilityIdentifier(WelcomeAccessibilityID.window)
    }
}

extension WelcomeStepScaffold where Footer == EmptyView {
    init(
        step: Int,
        title: LocalizedStringResource,
        body: LocalizedStringResource? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.init(step: step, title: title, body: body, content: content, footer: { EmptyView() })
    }
}
