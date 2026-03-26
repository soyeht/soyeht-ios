import SwiftUI

struct SplashView: View {
    let onFinished: () -> Void

    @State private var progress: CGFloat = 0
    @State private var showText = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                // Logo
                VStack(spacing: 16) {
                    HStack(spacing: 0) {
                        Text("> ")
                            .foregroundColor(SoyehtTheme.accentGreen)
                        Text("soyeht")
                            .foregroundColor(.white)
                    }
                    .font(.system(size: 32, weight: .bold, design: .monospaced))

                    Text("the operating system for AI agents")
                        .font(SoyehtTheme.subtitleFont)
                        .foregroundColor(SoyehtTheme.textSecondary)
                }
                .opacity(showText ? 1 : 0)

                Spacer()

                // Progress bar
                VStack(spacing: 8) {
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.white.opacity(0.1))
                            .frame(height: 3)

                        RoundedRectangle(cornerRadius: 2)
                            .fill(SoyehtTheme.accentGreen)
                            .frame(width: progress * 200, height: 3)
                    }
                    .frame(width: 200)

                    Text("connecting...")
                        .font(SoyehtTheme.smallMono)
                        .foregroundColor(SoyehtTheme.textSecondary)
                }
                .opacity(showText ? 1 : 0)

                Spacer()
                    .frame(height: 60)

                // Version
                Text("v2.1.0")
                    .font(SoyehtTheme.smallMono)
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
