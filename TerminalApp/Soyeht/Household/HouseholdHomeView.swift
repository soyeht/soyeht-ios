import SwiftUI
import SoyehtCore

struct HouseholdHomeView: View {
    let household: ActiveHouseholdState
    let onAdd: () -> Void
    let onSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text(household.householdName)
                        .font(Typography.monoPageTitle)
                        .foregroundColor(SoyehtTheme.textPrimary)
                    Text(verbatim: household.householdId)
                        .font(Typography.monoSmall)
                        .foregroundColor(SoyehtTheme.textComment)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Button(action: onSettings) {
                    Image(systemName: "gearshape")
                        .font(Typography.sansBody)
                        .foregroundColor(SoyehtTheme.textSecondary)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Settings"))
                if canAddMachine {
                    Button(action: onAdd) {
                        Image(systemName: "qrcode.viewfinder")
                            .font(Typography.sansBody)
                            .foregroundColor(SoyehtTheme.accentGreen)
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("Scan pairing code"))
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                Text(verbatim: "owner")
                    .font(Typography.monoSectionLabel)
                    .foregroundColor(SoyehtTheme.textComment)
                Text(household.personCert.displayName)
                    .font(Typography.monoBodySemi)
                    .foregroundColor(SoyehtTheme.textPrimary)
                Text(verbatim: household.ownerPersonId)
                    .font(Typography.monoSmall)
                    .foregroundColor(SoyehtTheme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(SoyehtTheme.bgPrimary.ignoresSafeArea())
    }

    private var canAddMachine: Bool {
        household.personCert.allows("household.add_machine")
    }
}
