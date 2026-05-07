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
        let confirming = machineJoinRuntime.confirmingRequest
        // Pin order: a confirming snapshot always wins over a manual
        // selection, which always wins over the most-recent arrival.
        // Using the *snapshot* — not a live queue lookup — is what lets
        // the card outlive `acknowledgeByMachine` removing the entry
        // mid-`.authorizing`, `confirmClaim` removing it before the VM
        // transitions to `.succeeded`, and the success-checkmark window
        // before the VM settles to `.dismissed`.
        let selected = selectedRequestId.flatMap { id in
            requests.first { $0.envelope.idempotencyKey == id }
        }
        if let top = confirming ?? selected ?? requests.last {
            let topId = top.envelope.idempotencyKey
            let secondaryRequests = requests.filter { $0.envelope.idempotencyKey != topId }
            VStack(spacing: 8) {
                // Hide the secondary pill row entirely while a confirm
                // snapshot is held. Allowing a swap here would tear down
                // the CardHost (`.id(topId)` rebuild) while the original
                // `viewModel.confirm()` Task is still running biometric +
                // POST against the now-orphaned ViewModel.
                if requests.count > 1, confirming == nil {
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
            // Animate on visible identity changes (additions / removals
            // / reorderings) — NOT on every PendingRequest field change.
            // The projection isolates the spring from harmless inner
            // mutations the queue may make to existing entries.
            .animation(
                .spring(response: 0.34, dampingFraction: 0.78),
                value: requests.map(\.envelope.idempotencyKey)
            )
        }
    }
}

private struct JoinRequestConfirmationCardHost: View {
    @StateObject private var viewModel: JoinRequestConfirmationViewModel
    @ObservedObject private var runtime: HouseholdMachineJoinRuntime
    private let householdName: String
    private let request: JoinRequestQueue.PendingRequest

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
        self.request = request
    }

    var body: some View {
        JoinRequestConfirmationView(
            viewModel: viewModel,
            householdName: householdName,
            // Synchronous on tap: snapshot the request into the runtime
            // BEFORE the unstructured Task is created (and thus before
            // the next main-actor turn could rebuild this host). See
            // `HouseholdMachineJoinRuntime.confirmingRequest` for the
            // full race window the snapshot closes.
            onConfirmTap: { [request, runtime] in
                runtime.beginConfirming(request)
            }
        )
        .shadow(color: Color.black.opacity(0.18), radius: 20, x: 0, y: 12)
        // The snapshot is *acquired* on tap (above). It's *released*
        // when the user no longer needs the card pinned: a non-terminal
        // revert (biometric cancel/lockout) drops back to `.pending`,
        // and any terminal flow eventually settles to `.dismissed` once
        // the success checkmark or error banner has been shown.
        // `.authorizing`/`.succeeded`/`.failed` keep the lock so the
        // card stays put while the user reads the result.
        .onChange(of: viewModel.state) { newState in
            switch newState {
            case .pending, .dismissed:
                runtime.endConfirming(request.envelope.idempotencyKey)
            case .authorizing, .succeeded, .failed:
                break
            }
        }
        .onDisappear {
            // Defence-in-depth: if SwiftUI tore down the host before
            // the state observer reached a release-eligible state
            // (e.g. host was rebuilt for an unrelated reason), don't
            // leak the lock. The key check ensures we never clear a
            // newer host's snapshot.
            runtime.endConfirming(request.envelope.idempotencyKey)
        }
    }
}
