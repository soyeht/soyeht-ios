import SwiftUI

struct SettingsRow: View {
    let icon: String
    let label: String
    let value: String
    var valueColor: Color = SoyehtTheme.historyGray

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundColor(SoyehtTheme.historyGreen)
                .frame(width: 18, alignment: .center)

            Text(label)
                .font(.system(size: 13, weight: .regular, design: .monospaced))
                .foregroundColor(SoyehtTheme.textPrimary)

            Spacer()

            Text(value)
                .font(SoyehtTheme.tagFont)
                .foregroundColor(valueColor)

            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(SoyehtTheme.textTertiary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }
}
