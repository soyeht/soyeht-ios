import SwiftUI
import SoyehtCore

/// T110a — key dissolve animation: key fades from iPhone → Mac silhouettes.
/// Runs once on appear; calls `onComplete` when done. ≤2s, gentle.
/// Reduce Motion: static iPhone → arrow → Mac layout, completes immediately.
struct KeyHandoffMetaphorView: View {
    let onComplete: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var phoneKeyOpacity: Double = 1
    @State private var macKeyOpacity: Double = 0
    @State private var keyScale: Double = 0.85
    @State private var arrowOpacity: Double = 0

    var body: some View {
        if reduceMotion {
            staticLayout
                .onAppear { onComplete() }
        } else {
            animatedLayout
                .onAppear { runAnimation() }
        }
    }

    // MARK: - Animated

    private var animatedLayout: some View {
        HStack(spacing: 0) {
            ZStack {
                phoneIcon
                    .opacity(1)
                keyIcon
                    .opacity(phoneKeyOpacity)
                    .scaleEffect(keyScale)
                    .offset(x: 8, y: -8)
            }

            arrowIcon
                .opacity(arrowOpacity)
                .padding(.horizontal, 12)

            ZStack {
                macIcon
                    .opacity(1)
                keyIcon
                    .opacity(macKeyOpacity)
                    .scaleEffect(keyScale)
                    .offset(x: 8, y: -8)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(LocalizedStringResource(
            "keyHandoff.a11y",
            defaultValue: "Animação: chave transferida do iPhone para o Mac",
            comment: "VoiceOver label for key handoff metaphor animation."
        )))
    }

    private func runAnimation() {
        // Phase 1 (0–0.3s): arrow fades in
        withAnimation(.easeIn(duration: 0.3)) {
            arrowOpacity = 1
        }
        // Phase 2 (0.4–0.9s): key on phone fades + shrinks out
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            withAnimation(.easeInOut(duration: 0.5)) {
                phoneKeyOpacity = 0
                keyScale = 1.05
            }
        }
        // Phase 3 (0.85–1.4s): key on mac fades + grows in
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.85) {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
                macKeyOpacity = 1
                keyScale = 1.0
            }
        }
        // Phase 4 (1.6s): arrow fades out; complete
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            withAnimation(.easeOut(duration: 0.25)) {
                arrowOpacity = 0
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.9) {
            onComplete()
        }
    }

    // MARK: - Static (Reduce Motion)

    private var staticLayout: some View {
        HStack(spacing: 16) {
            ZStack(alignment: .topTrailing) {
                phoneIcon
                keyIcon.offset(x: 6, y: -6)
            }

            Image(systemName: "arrow.right")
                .font(.system(size: 20, weight: .medium))
                .foregroundColor(BrandColors.textMuted)

            ZStack(alignment: .topTrailing) {
                macIcon
                keyIcon.offset(x: 6, y: -6)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(LocalizedStringResource(
            "keyHandoff.a11y",
            defaultValue: "Animação: chave transferida do iPhone para o Mac",
            comment: "VoiceOver label for key handoff metaphor animation."
        )))
    }

    // MARK: - Sub-views

    private var phoneIcon: some View {
        Image(systemName: "iphone")
            .font(.system(size: 52))
            .foregroundColor(BrandColors.textMuted.opacity(0.6))
    }

    private var macIcon: some View {
        Image(systemName: "macbook")
            .font(.system(size: 52))
            .foregroundColor(BrandColors.textMuted.opacity(0.6))
    }

    private var keyIcon: some View {
        Image(systemName: "key.fill")
            .font(.system(size: 18))
            .foregroundColor(BrandColors.accentGreen)
    }

    private var arrowIcon: some View {
        Image(systemName: "arrow.right")
            .font(.system(size: 18, weight: .medium))
            .foregroundColor(BrandColors.accentGreen)
    }
}
