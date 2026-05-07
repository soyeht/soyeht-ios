import SwiftUI
import SoyehtCore

struct HouseholdHomeView: View {
    let household: ActiveHouseholdState
    @ObservedObject var machineJoinRuntime: HouseholdMachineJoinRuntime
    let onAdd: () -> Void
    let onSettings: () -> Void
    @State private var selectedRequestId: String?

    var body: some View {
        ZStack(alignment: .top) {
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

            joinRequestStack
        }
        .background(SoyehtTheme.bgPrimary.ignoresSafeArea())
    }

    private var canAddMachine: Bool {
        household.personCert.allows("household.add_machine")
    }

    @ViewBuilder
    private var joinRequestStack: some View {
        let requests = machineJoinRuntime.pendingRequests
        let confirmingKey = machineJoinRuntime.confirmingRequestKey
        // Pin order: a confirming request always wins over a manual
        // selection, which always wins over the most-recent arrival. This
        // keeps the in-flight card visible after the operator taps Confirm
        // even if a newer request lands during the biometric ceremony.
        let confirming = confirmingKey.flatMap { id in
            requests.first { $0.envelope.idempotencyKey == id }
        }
        let selected = selectedRequestId.flatMap { id in
            requests.first { $0.envelope.idempotencyKey == id }
        }
        if let top = confirming ?? selected ?? requests.last {
            let topId = top.envelope.idempotencyKey
            let secondaryRequests = requests.filter { $0.envelope.idempotencyKey != topId }
            VStack(spacing: 8) {
                // Hide the secondary pill row entirely while the top card
                // is mid-confirm. Allowing a swap here would tear down the
                // CardHost (`.id(topId)` rebuild) while the original
                // `viewModel.confirm()` Task is still running biometric +
                // POST against the now-orphaned ViewModel.
                if requests.count > 1, confirmingKey == nil {
                    HStack(spacing: 6) {
                        ForEach(Array(secondaryRequests.suffix(3)), id: \.envelope.idempotencyKey) { request in
                            Button {
                                selectedRequestId = request.envelope.idempotencyKey
                            } label: {
                                Text(request.envelope.displayHostname(maxCharacters: 22))
                                    .font(Typography.monoSmall)
                                    .foregroundColor(SoyehtTheme.textSecondary)
                                    .lineLimit(1)
                                    .padding(.horizontal, 10)
                                    .frame(height: 28)
                                    .background(SoyehtTheme.bgTertiary)
                                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(Text("Show join request"))
                        }
                    }
                    .transition(.move(edge: .top).combined(with: .opacity))
                }

                if let card = JoinRequestConfirmationCardHost(
                    request: top,
                    household: household,
                    runtime: machineJoinRuntime
                ) {
                    card
                        .id(topId)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .padding(.top, 16)
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, alignment: .top)
            .animation(.spring(response: 0.34, dampingFraction: 0.78), value: requests)
        }
    }
}

private struct JoinRequestConfirmationCardHost: View {
    @StateObject private var viewModel: JoinRequestConfirmationViewModel
    @ObservedObject private var runtime: HouseholdMachineJoinRuntime
    private let householdName: String
    private let requestKey: String

    init?(
        request: JoinRequestQueue.PendingRequest,
        household: ActiveHouseholdState,
        runtime: HouseholdMachineJoinRuntime
    ) {
        guard let viewModel = try? runtime.makeViewModel(for: request, household: household) else {
            return nil
        }
        _viewModel = StateObject(
            wrappedValue: viewModel
        )
        self.runtime = runtime
        self.householdName = household.householdName
        self.requestKey = request.envelope.idempotencyKey
    }

    var body: some View {
        JoinRequestConfirmationView(
            viewModel: viewModel,
            householdName: householdName
        )
        .shadow(color: Color.black.opacity(0.18), radius: 20, x: 0, y: 12)
        // Mirror the lifecycle of *this card* into the runtime so
        // `HouseholdHomeView` can pin its card selection and hide the
        // pill row for the entire user-visible window — biometric +
        // POST while authorizing, plus the success-checkmark or error
        // banner the user still needs to see after the wire round-trip
        // settles. The lock releases only when the card returns to a
        // pre-Confirm state (`pending` after a non-terminal revert) or
        // is dismissed.
        .onChange(of: viewModel.state) { newState in
            switch newState {
            case .authorizing, .succeeded, .failed:
                runtime.setConfirmingRequest(requestKey)
            case .pending, .dismissed:
                if runtime.confirmingRequestKey == requestKey {
                    runtime.setConfirmingRequest(nil)
                }
            }
        }
        .onDisappear {
            // SwiftUI tore down the host (e.g. `.id(topId)` rebuild after
            // the request was dismissed). Make sure we don't leave the
            // runtime stuck "confirming" if the VM never reached a
            // terminal state under our observation window.
            if runtime.confirmingRequestKey == requestKey {
                runtime.setConfirmingRequest(nil)
            }
        }
    }
}
