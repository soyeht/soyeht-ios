import SwiftUI
import SoyehtCore

struct SplashView: View {
    let onFinished: () -> Void

    @State private var progress: CGFloat = 0
    @State private var showText = false

    var body: some View {
        ZStack {
            SoyehtTheme.bgPrimary.ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                // Logo
                VStack(spacing: 16) {
                    HStack(spacing: 0) {
                        Text(verbatim: "> ")
                            .foregroundColor(SoyehtTheme.accentGreen)
                        Text(verbatim: "soyeht")
                            .foregroundColor(SoyehtTheme.textPrimary)
                    }
                    .font(Typography.monoDisplay)

                    Text("splash.tagline")
                        .font(Typography.sansSubtitle)
                        .foregroundColor(SoyehtTheme.textSecondary)
                }
                .opacity(showText ? 1 : 0)

                Spacer()

                // Progress bar
                VStack(spacing: 8) {
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(SoyehtTheme.progressTrack)
                            .frame(height: 3)

                        RoundedRectangle(cornerRadius: 2)
                            .fill(SoyehtTheme.accentGreen)
                            .frame(width: progress * 200, height: 3)
                    }
                    .frame(width: 200)

                    Text("splash.connecting")
                        .font(Typography.monoSmall)
                        .foregroundColor(SoyehtTheme.textSecondary)
                }
                .opacity(showText ? 1 : 0)

                Spacer()
                    .frame(height: 60)

                // Version
                Text(verbatim: "v2.1.0")
                    .font(Typography.monoSmall)
                    .foregroundColor(SoyehtTheme.textComment)
                    .padding(.bottom, 20)
            }
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.4)) {
                showText = true
            }
            withAnimation(.easeInOut(duration: 1.5)) {
                progress = 0.65
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                onFinished()
            }
        }
    }
}
