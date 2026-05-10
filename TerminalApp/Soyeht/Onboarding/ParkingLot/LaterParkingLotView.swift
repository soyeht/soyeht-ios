import SwiftUI
import SoyehtCore

/// Cena PB4 — "Sem pressa" (T100, FR-030).
/// Shown when user chooses "Vou fazer mais tarde" on the proximity question.
/// Provides link + ShareSheet + opt-in email reminder; warmly defers setup.
struct LaterParkingLotView: View {
    let onDismiss: () -> Void

    @State private var showShareSheet = false
    @State private var showEmailForm = false

    private let downloadURL = URL(string: "https://soyeht.com/mac")!

    var body: some View {
        ZStack {
            BrandColors.surfaceDeep.ignoresSafeArea()

            VStack(spacing: 0) {
                dismissBar

                ScrollView {
                    VStack(spacing: 28) {
                        illustration

                        headingSection

                        linkCard

                        emailReminderTrigger
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 32)
                    .padding(.bottom, 40)
                }
            }
        }
        .preferredColorScheme(BrandColors.preferredColorScheme)
        .sheet(isPresented: $showShareSheet) {
            ActivityView(items: [downloadURL])
        }
        .sheet(isPresented: $showEmailForm) {
            EmailReminderForm(onDone: { showEmailForm = false })
        }
    }

    private var dismissBar: some View {
        HStack {
            Spacer()
            Button(action: onDismiss) {
                Text("parkingLot.dismiss", comment: "Dismiss button on parking lot screen.")
                .font(OnboardingFonts.subheadline)
                .foregroundColor(BrandColors.textMuted)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    private var illustration: some View {
        ZStack {
            Circle()
                .fill(BrandColors.accentGreen.opacity(0.1))
                .frame(width: 100, height: 100)
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 44))
                .foregroundColor(BrandColors.accentGreen)
        }
        .accessibilityHidden(true)
    }

    private var headingSection: some View {
        VStack(spacing: 10) {
            Text("parkingLot.title", comment: "Parking lot screen title. Reassuring and warm. Period is intentional.")
            .font(OnboardingFonts.heading)
            .foregroundColor(BrandColors.textPrimary)
            .multilineTextAlignment(.center)
            .accessibilityAddTraits(.isHeader)

            Text("parkingLot.subtitle", comment: "Parking lot subtitle explaining how to install later.")
            .font(OnboardingFonts.callout)
            .foregroundColor(BrandColors.textMuted)
            .multilineTextAlignment(.center)
        }
    }

    private var linkCard: some View {
        VStack(spacing: 12) {
            HStack {
                Image(systemName: "link")
                    .foregroundColor(BrandColors.accentGreen)
                    .accessibilityHidden(true)
                Text(verbatim: downloadURL.absoluteString)
                    .font(Font.system(.subheadline, design: .monospaced))
                    .foregroundColor(BrandColors.textPrimary)
                Spacer()
            }
            .padding(16)
            .background(BrandColors.card)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(BrandColors.border, lineWidth: 1)
            )

            Button(action: { showShareSheet = true }) {
                HStack(spacing: 8) {
                    Image(systemName: "square.and.arrow.up")
                        .accessibilityHidden(true)
                    Text("parkingLot.share", comment: "Share link button on parking lot screen.")
                }
                .font(Font.subheadline.weight(.medium))
                .foregroundColor(BrandColors.accentGreen)
            }
        }
    }

    private var emailReminderTrigger: some View {
        Button(action: { showEmailForm = true }) {
            HStack(spacing: 8) {
                Image(systemName: "envelope")
                    .font(.system(size: 14))
                    .accessibilityHidden(true)
                Text("parkingLot.emailReminder", comment: "Optional email reminder button on parking lot screen.")
                .font(OnboardingFonts.footnote)
            }
            .foregroundColor(BrandColors.textMuted)
        }
    }
}

// MARK: - ActivityView

private struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
