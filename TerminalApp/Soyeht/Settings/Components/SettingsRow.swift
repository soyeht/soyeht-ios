import SwiftUI
import SoyehtCore

struct SettingsRow: View {
    let icon: String
    let label: LocalizedStringKey
    let value: String
    var valueColor: Color = SoyehtTheme.historyGray

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(Typography.sansBody)
                .foregroundColor(SoyehtTheme.historyGreen)
                .frame(width: 18, alignment: .center)

            Text(label)
                .font(Typography.monoCardBody)
                .foregroundColor(SoyehtTheme.textPrimary)

            Spacer()

            Text(value)
                .font(Typography.monoTag)
                .foregroundColor(valueColor)

            Image(systemName: "chevron.right")
                .font(Typography.sansSmall)
                .foregroundColor(SoyehtTheme.textTertiary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }
}
