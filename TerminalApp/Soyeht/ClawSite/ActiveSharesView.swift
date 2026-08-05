import SwiftUI
import SoyehtCore

/// The owner's "who has, had, or could still get to my stuff" screen — a
/// revocable lifecycle history across Waiting/Accepted/Expired/Revoked, not
/// just the currently reachable ones.
struct ActiveSharesView: View {
    @StateObject private var model: ActiveSharesViewModel
    let onDismiss: () -> Void
    let dateFormatter: any ActiveShareDateFormatting
    @State private var didCopySlotID: Data?

    init(
        model: ActiveSharesViewModel,
        onDismiss: @escaping () -> Void,
        dateFormatter: any ActiveShareDateFormatting = ActiveShareDateFormatter()
    ) {
        _model = StateObject(wrappedValue: model)
        self.onDismiss = onDismiss
        self.dateFormatter = dateFormatter
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            switch model.phase {
            case .loading:
                centered {
                    ProgressView()
                    Text("Loading your active shares…")
                        .font(Typography.monoTag)
                        .foregroundColor(SoyehtTheme.textSecondary)
                }
            case .failed(let message):
                centered {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 30))
                        .foregroundColor(SoyehtTheme.textTertiary)
                    Text(message)
                        .font(Typography.monoTag)
                        .multilineTextAlignment(.center)
                        .foregroundColor(SoyehtTheme.textSecondary)
                    Button("Try again") { Task { await model.load() } }
                        .font(Typography.sansNav)
                        .foregroundColor(SoyehtTheme.accentGreen)
                        .padding(.top, 6)
                }
            case .loaded:
                if model.rows.isEmpty {
                    centered {
                        Text("Nothing shared right now")
                            .font(Typography.monoBodyLargeMedium)
                            .foregroundColor(SoyehtTheme.textPrimary)
                        Text("Apps you share will show up here.")
                            .font(Typography.monoTag)
                            .foregroundColor(SoyehtTheme.textSecondary)
                    }
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(model.rows) { row in
                                rowView(row)
                                Divider().padding(.leading, 16)
                            }
                        }
                    }
                }
            }
        }
        .background(SoyehtTheme.bgPrimary)
        .task { await model.load() }
        .confirmationDialog(
            "Stop sharing?",
            isPresented: Binding(
                get: { model.pendingRevoke != nil },
                set: { if !$0 { model.cancelRevoke() } }
            ),
            presenting: model.pendingRevoke
        ) { row in
            Button("Stop sharing \(row.displayName)", role: .destructive) {
                Task { await model.confirmRevoke() }
            }
            Button("Cancel", role: .cancel) { model.cancelRevoke() }
        } message: { _ in
            Text("Whoever has this link loses access. This can't be undone.")
        }
        .alert(
            "Couldn't stop sharing",
            isPresented: Binding(
                get: { model.revokeFailureMessage != nil },
                set: { if !$0 { model.dismissRevokeFailure() } }
            )
        ) {
            Button("OK") { model.dismissRevokeFailure() }
        } message: {
            Text(model.revokeFailureMessage ?? "")
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Button(action: onDismiss) {
                Image(systemName: "chevron.left")
                    .font(Typography.sansNav)
                    .foregroundColor(SoyehtTheme.textSecondary)
            }
            Text("Active Shares")
                .font(Typography.monoBodyLargeMedium)
                .foregroundColor(SoyehtTheme.textPrimary)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func rowView(_ row: ActiveShareRow) -> some View {
        let now = Date()
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                // No real per-app icon data exists on this DTO (only
                // app_id/display_name) — a single local, generic SF Symbol
                // stands in for every row, same as any other app. Hidden
                // from accessibility since it's purely decorative and the
                // row's combined element already announces the name.
                Image(systemName: "app.fill")
                    .foregroundColor(SoyehtTheme.textTertiary)
                    .accessibilityHidden(true)
                Text(row.displayName)
                    .font(Typography.monoBodyLargeMedium)
                    .foregroundColor(SoyehtTheme.textPrimary)
                Spacer()
                Text(row.statusText(formatter: dateFormatter, now: now))
                    .font(Typography.monoTag)
                    .foregroundColor(SoyehtTheme.textSecondary)
            }
            Text(row.lifetimeText(formatter: dateFormatter, now: now))
                .font(Typography.monoTag)
                .foregroundColor(SoyehtTheme.textTertiary)
            if row.readiness != .running {
                Text("App not running right now")
                    .font(Typography.monoTag)
                    .foregroundColor(SoyehtTheme.textTertiary)
            }
            HStack(spacing: 16) {
                if model.canCopyLink(row) {
                    Button(didCopySlotID == row.id ? "Copied" : "Copy Link") {
                        if model.copyLink(row) {
                            didCopySlotID = row.id
                            Task {
                                try? await Task.sleep(nanoseconds: 1_500_000_000)
                                if didCopySlotID == row.id { didCopySlotID = nil }
                            }
                        }
                    }
                    .font(Typography.sansNav)
                    .foregroundColor(SoyehtTheme.accentGreen)
                }
                if row.canStopSharing {
                    Button("Stop Sharing", role: .destructive) {
                        model.requestRevoke(row)
                    }
                    .font(Typography.sansNav)
                    .foregroundColor(SoyehtTheme.textSecondary)
                }
                Spacer()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func centered<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 10) {
            Spacer()
            content()
            Spacer()
        }
        .padding(32)
        .frame(maxWidth: .infinity)
    }
}
