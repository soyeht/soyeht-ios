import SwiftUI
import SoyehtCore

/// Mac-side safety code display — 6 words in 2 rows of 3, monospace 22pt.
/// T053a stagger animation via `AnimationCatalog.staggerWord`.
/// T053c: pass `glowActive = true` to play the green glow (FR-129).
struct SafetyCodeDisplay: View {
    let words: [String]  // exactly 6
    var glowActive: Bool = false

    @State private var visible = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 14) {
            wordRow(indices: 0..<3)
            wordRow(indices: 3..<6)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(BrandColors.card)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(
                    glowActive ? BrandColors.accentGreen : BrandColors.border,
                    lineWidth: glowActive ? 2 : 1
                )
                .shadow(
                    color: glowActive ? BrandColors.accentGreen.opacity(0.45) : .clear,
                    radius: 10
                )
                .animation(AnimationCatalog.safetyGlow(reduceMotion: reduceMotion), value: glowActive)
        )
        .onAppear { visible = true }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(words.joined(separator: " ")))
    }

    @ViewBuilder
    private func wordRow(indices: Range<Int>) -> some View {
        HStack(spacing: 18) {
            ForEach(Array(indices), id: \.self) { idx in
                wordLabel(words[idx], index: idx)
            }
        }
    }

    private func wordLabel(_ word: String, index: Int) -> some View {
        Text(verbatim: word)
            .font(.system(size: 22, design: .monospaced))
            .foregroundColor(BrandColors.textPrimary)
            .opacity(visible ? 1 : 0)
            .animation(
                AnimationCatalog.staggerWord(wordIndex: index, reduceMotion: reduceMotion),
                value: visible
            )
    }
}
