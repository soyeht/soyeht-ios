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
            // Newest-first peek order behind the active card. Cap at 3
            // because past that the visual stack collapses to a smear
            // and adds latency without adding signal — older requests
            // remain reachable by their TTL count and `requests.last`
            // promotion when the current top resolves. The cap is also
            // a soft cost gate: each peek card paints its own shadow
            // blur pass per frame on top of the active card's, so 4
            // simultaneous shadows is the budget. Raising the cap means
            // measuring frame time on a base-tier device (iPhone Devs
            // is the validation target) before shipping.
            let peekRequests: [JoinRequestQueue.PendingRequest] = Array(
                requests
                    .filter { $0.envelope.idempotencyKey != topId }
                    .reversed()
                    .prefix(3)
            )
            ZStack(alignment: .top) {
                // Hide the peek stack entirely while a confirm snapshot
                // is held. Allowing a swap here would tear down the
                // CardHost (`.id(topId)` rebuild) while the original
                // `viewModel.confirm()` Task is still running biometric +
                // POST against the now-orphaned ViewModel.
                if confirming == nil {
                    // Identity must be `idempotencyKey`, not the array
                    // index — when a peek request resolves out of the
                    // middle of the stack the surviving views must
                    // animate their offset/scale change rather than
                    // SwiftUI mutating the wrong view's content. The
                    // `Array(enumerated())` wrapper is the cost of
                    // pairing index (for stack offset) with stable
                    // identity in the same ForEach.
                    ForEach(Array(peekRequests.enumerated()), id: \.element.envelope.idempotencyKey) { index, request in
                        JoinRequestPeekCard(request: request) {
                            selectedRequestId = request.envelope.idempotencyKey
                        }
                        .scaleEffect(1 - CGFloat(index + 1) * 0.04)
                        .offset(y: CGFloat(index + 1) * 12)
                        .opacity(1 - Double(index + 1) * 0.2)
                        .zIndex(-Double(index + 1))
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                    }
                }

                if let card = JoinRequestConfirmationCardHost(
                    request: top,
                    household: household,
                    runtime: machineJoinRuntime
                ) {
                    card
                        .id(topId)
                        .transition(Self.transition(for: top.envelope.transportOrigin))
                        .zIndex(1)
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

    /// Map the `transportOrigin` of an incoming request to its presentation
    /// transition.
    ///
    /// - QR-initiated requests (LAN or Tailscale) animate in with an
    ///   AirDrop-style scale-from-center + opacity so the card visually
    ///   "lands" from the QR-scanner viewport the operator just left.
    ///   True spatial continuity from the QR-frame rectangle would
    ///   require a `matchedGeometryEffect` source on the QRScannerView
    ///   that survives the screen replacement; the scale-from-center
    ///   approximation gives the same perceptual cue (from-small,
    ///   to-final) without the cross-screen geometry plumbing.
    /// - Long-poll arrivals (Bonjour shortcut path) slide from the top
    ///   edge — the operator was not looking at any specific origin
    ///   rect, so a Notification Center-style top-edge slide matches
    ///   the "this just arrived" semantic.
    private static func transition(for origin: JoinRequestTransportOrigin) -> AnyTransition {
        switch origin {
        case .qrLAN, .qrTailscale:
            return .asymmetric(
                insertion: .scale(scale: 0.55, anchor: .center).combined(with: .opacity),
                removal: .opacity
            )
        case .bonjourShortcut:
            return .move(edge: .top).combined(with: .opacity)
        }
    }
}

/// Compact summary used to peek behind the active confirmation card when
/// multiple join requests are pending. Tapping promotes the request to
/// the top slot; the size-and-offset stacking in `joinRequestStack`
/// gives the iOS Notification Center peek-from-below cue.
private struct JoinRequestPeekCard: View {
    let request: JoinRequestQueue.PendingRequest
    let onTap: () -> Void
    @State private var now: Date = Date()

    var body: some View {
        let hostnameText = request.envelope.displayHostname(maxCharacters: 22)
        Button(action: onTap) {
            HStack(spacing: 10) {
                Image(systemName: "laptopcomputer")
                    .font(Typography.sansCard)
                    .foregroundColor(SoyehtTheme.accentGreen)
                    .frame(width: 22)

                Text(hostnameText)
                    .font(Typography.monoBodyMedium)
                    .foregroundColor(SoyehtTheme.textPrimary)
                    .lineLimit(1)

                Spacer(minLength: 8)

                Text(verbatim: timeRemainingText)
                    .font(Typography.monoSmall)
                    .foregroundColor(timeRemainingColor)
                    .monospacedDigit()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: 420, alignment: .leading)
            .background(SoyehtTheme.bgCard)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(SoyehtTheme.bgTertiary, lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.12), radius: 8, x: 0, y: 4)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(AccessibilityID.Household.joinRequestPeekCard(request.envelope.idempotencyKey))
        .accessibilityLabel(Text(LocalizedStringResource(
            "household.joinRequest.peek.accessibilityLabel",
            defaultValue: "Show join request from \(hostnameText)",
            comment: "VoiceOver label for a stacked peek card behind the active confirmation card. %@ = sanitized hostname of the candidate machine."
        )))
        // Drive the per-second redraw so the peek countdown stays in
        // sync with the active card without depending on an actor-bound
        // ticker. `.task(id:)` is bound to the SwiftUI view lifecycle —
        // SwiftUI cancels and restarts the loop when the host
        // re-identifies (different request promoted into this slot) and
        // cancels on disappear. The id pin closes the door on a stale
        // ticker outliving its peek card if the ForEach reuses a view
        // instance, which would otherwise be a slow leak in households
        // pairing many machines in sequence.
        .task(id: request.envelope.idempotencyKey) {
            while !Task.isCancelled {
                now = Date()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    private var secondsRemaining: Int {
        let expiry = Date(timeIntervalSince1970: TimeInterval(request.envelope.ttlUnix))
        return max(0, Int(ceil(expiry.timeIntervalSince(now))))
    }

    private var timeRemainingText: String {
        let total = secondsRemaining
        let minutes = total / 60
        let seconds = total % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    private var timeRemainingColor: Color {
        secondsRemaining <= 30
            ? SoyehtTheme.accentRed
            : SoyehtTheme.textSecondary
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
            },
            // After the success-checkmark animation completes, drive
            // the VM through to `.dismissed`. The state observer below
            // then releases the snapshot lock and the home view can
            // surface the next pending request — without this hook the
            // VM would sit at `.succeeded` forever (the View's
            // `dismissOnce()` only flips a private flag) and the
            // pinned card would block any newer arrival from rendering.
            onSucceeded: { [viewModel] in
                Task { await viewModel.dismiss() }
            },
            // Same contract for terminal failures: after the readback
            // window the VM auto-dismisses, the lock releases, and the
            // next pending request can render. Without this hook a
            // single failure (network drop, cert validation, server
            // error) would block every subsequent join visibility
            // until the operator manually tapped X — particularly
            // painful in households pairing several machines in
            // sequence where one transient error would mute the rest.
            onFailedReadbackComplete: { [viewModel] in
                Task { await viewModel.dismiss() }
            }
        )
        .shadow(color: Color.black.opacity(0.18), radius: 20, x: 0, y: 12)
        // The snapshot is *acquired* on tap (above). It's *released*
        // when the user no longer needs the card pinned. The state
        // observer maps each VM state to a release decision:
        //
        // - `.pending`: post-revert (biometric cancel/lockout) — back
        //   to a tappable card, lock can release so other pills show.
        // - `.dismissed`: terminal — either auto-driven by the
        //   `onSucceeded` / `onFailedReadbackComplete` hooks above
        //   (after the View's success/failure visibility window) or
        //   driven by the operator tapping X. Lock releases.
        // - `.authorizing` / `.succeeded` / `.failed`: keep the lock.
        //   The success and failure windows hold the card visible
        //   while the operator reads the result; the View itself
        //   transitions the VM to `.dismissed` once the readback
        //   completes, which is what closes the lock.
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
