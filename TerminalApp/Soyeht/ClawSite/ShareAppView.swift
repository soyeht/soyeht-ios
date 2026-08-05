import SwiftUI
import SoyehtCore

/// Owner-side: pick one of my apps, choose how long, get a link to send.
///
/// The whole point of claw-share is giving a friend access to one app
/// *without* making them part of the house, so this screen never asks who the
/// person is — it produces a link the owner sends however they already talk to
/// them. Whoever opens it first takes the single slot.
struct ShareAppView: View {
    @StateObject private var model: ShareAppViewModel
    let onDismiss: () -> Void
    let onShowActiveShares: () -> Void
    @State private var didCopyLink = false
    @State private var showsLinkDetails = false

    init(
        model: ShareAppViewModel,
        onDismiss: @escaping () -> Void,
        onShowActiveShares: @escaping () -> Void
    ) {
        _model = StateObject(wrappedValue: model)
        self.onDismiss = onDismiss
        self.onShowActiveShares = onShowActiveShares
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            switch model.phase {
            case .loading:
                centered {
                    ProgressView()
                    Text("Loading your apps…")
                        .font(Typography.monoTag)
                        .foregroundColor(SoyehtTheme.textSecondary)
                }
            case .picking, .minting:
                picker
            case .shared(let link, let expiresAt):
                sharedResult(link: link, expiresAt: expiresAt)
            case .failed(let message):
                centered {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 30))
                        .foregroundColor(SoyehtTheme.textTertiary)
                    Text("Couldn't share right now")
                        .font(Typography.monoBodyLargeMedium)
                        .foregroundColor(SoyehtTheme.textPrimary)
                    Text(message)
                        .font(Typography.monoTag)
                        .multilineTextAlignment(.center)
                        .foregroundColor(SoyehtTheme.textSecondary)
                    Button("Try again") { Task { await model.load() } }
                        .font(Typography.sansNav)
                        .foregroundColor(SoyehtTheme.accentGreen)
                        .padding(.top, 6)
                }
            }
        }
        .background(SoyehtTheme.bgPrimary)
        .task { await model.load() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Button(action: onDismiss) {
                Image(systemName: "chevron.left")
                    .font(Typography.sansNav)
                    .foregroundColor(SoyehtTheme.textSecondary)
            }
            Text("Share an app")
                .font(Typography.monoBodyLargeMedium)
                .foregroundColor(SoyehtTheme.textPrimary)
            Spacer()
            Button(action: onShowActiveShares) {
                Text("Active Shares")
                    .font(Typography.sansNav)
                    .foregroundColor(SoyehtTheme.accentGreen)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var picker: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.apps.isEmpty {
                centered {
                    Text("No apps to share yet")
                        .font(Typography.monoBodyLargeMedium)
                        .foregroundColor(SoyehtTheme.textPrimary)
                    Text("Install one from the Claw Store and it'll show up here.")
                        .font(Typography.monoTag)
                        .multilineTextAlignment(.center)
                        .foregroundColor(SoyehtTheme.textSecondary)
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        sectionLabel("// which app")
                        ForEach(model.apps) { app in
                            appRow(app)
                        }

                        sectionLabel("// for how long")
                        Picker("", selection: $model.duration) {
                            ForEach(ShareAppViewModel.Duration.allCases) { option in
                                Text(option.label).tag(option)
                            }
                        }
                        .pickerStyle(.segmented)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 20)

                        Text("Anyone with the link can open this app until it expires. They don't join your home.")
                            .font(Typography.monoTag)
                            .foregroundColor(SoyehtTheme.textSecondary)
                            .padding(.horizontal, 16)

                        if model.showsStoppedAppWarning, let selectedApp = model.selectedApp {
                            stoppedAppWarning(selectedApp)
                        }
                    }
                }

                shareButton
            }
        }
    }

    private func appRow(_ app: ShareableApp) -> some View {
        let isSelected = model.selectedAppID == app.appID
        return Button {
            model.selectedAppID = app.appID
        } label: {
            HStack(spacing: 12) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .foregroundColor(isSelected ? SoyehtTheme.accentGreen : SoyehtTheme.textTertiary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(app.displayName)
                        .font(Typography.monoBodyLargeMedium)
                        .foregroundColor(SoyehtTheme.textPrimary)
                    if !app.isRunning {
                        Text("not running right now")
                            .font(Typography.monoTag)
                            .foregroundColor(SoyehtTheme.textSecondary)
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// D1 (warn-and-allow): a stopped app is shareable, but the owner must
    /// see the condition stated plainly — not just a row's fine print — and
    /// know what the guest will see until the app comes back up.
    private func stoppedAppWarning(_ app: ShareableApp) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(SoyehtTheme.textSecondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(app.displayName) isn't running right now")
                    .font(Typography.monoBodyLargeMedium)
                    .foregroundColor(SoyehtTheme.textPrimary)
                Text("You can still share it. Whoever opens the link will see a waiting screen until it's back up.")
                    .font(Typography.monoTag)
                    .foregroundColor(SoyehtTheme.textSecondary)
            }
            Spacer()
        }
        .padding(12)
        .background(SoyehtTheme.bgSecondary)
        .cornerRadius(8)
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .accessibilityElement(children: .combine)
    }

    private var shareButton: some View {
        Button {
            Task { await model.share() }
        } label: {
            HStack {
                Spacer()
                if case .minting = model.phase {
                    ProgressView().tint(SoyehtTheme.bgPrimary)
                } else {
                    Text("Create link")
                        .font(Typography.sansNav)
                        .foregroundColor(SoyehtTheme.bgPrimary)
                }
                Spacer()
            }
            .padding(.vertical, 14)
            .background(model.canShare ? SoyehtTheme.accentGreen : SoyehtTheme.textTertiary)
            .cornerRadius(10)
        }
        .disabled(!model.canShare)
        .padding(16)
    }

    private func sharedResult(link: String, expiresAt: Date) -> some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "link")
                .font(.system(size: 30))
                .foregroundColor(SoyehtTheme.accentGreen)

            Text("Link ready")
                .font(Typography.monoBodyLargeMedium)
                .foregroundColor(SoyehtTheme.textPrimary)

            Text("Expires \(ShareAppViewModel.unambiguousExpiryLabel(for: expiresAt))")
                .font(Typography.monoTag)
                .foregroundColor(SoyehtTheme.textSecondary)

            // The link is the credential, not the primary thing on screen —
            // Send (the system share sheet) and Copy Link are the primary
            // actions; the raw link is available on request via Details
            // rather than always shown (§5.2).
            HStack(spacing: 12) {
                ShareLink(item: link) {
                    HStack {
                        Spacer()
                        Text("Send")
                            .font(Typography.sansNav)
                            .foregroundColor(SoyehtTheme.bgPrimary)
                        Spacer()
                    }
                    .padding(.vertical, 14)
                    .background(SoyehtTheme.accentGreen)
                    .cornerRadius(10)
                }

                Button {
                    copyLink()
                } label: {
                    HStack {
                        Spacer()
                        Text(didCopyLink ? "Copied" : "Copy Link")
                            .font(Typography.sansNav)
                            .foregroundColor(SoyehtTheme.textPrimary)
                        Spacer()
                    }
                    .padding(.vertical, 14)
                    .background(SoyehtTheme.bgSecondary)
                    .cornerRadius(10)
                }
                .accessibilityLabel(Text("Copy Link"))
                .accessibilityHint(Text("Copies the share link to the clipboard."))
            }
            .padding(.horizontal, 16)

            DisclosureGroup("Details", isExpanded: $showsLinkDetails) {
                Text(link)
                    .font(Typography.monoTag)
                    .foregroundColor(SoyehtTheme.textSecondary)
                    .lineLimit(3)
                    .truncationMode(.middle)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(SoyehtTheme.bgSecondary)
                    .cornerRadius(8)
                    .textSelection(.enabled)
            }
            .font(Typography.monoTag)
            .foregroundColor(SoyehtTheme.textSecondary)
            .padding(.horizontal, 16)

            Button("Share another") { model.shareAnother() }
                .font(Typography.sansNav)
                .foregroundColor(SoyehtTheme.textSecondary)

            Spacer()
        }
    }

    private func copyLink() {
        guard model.copyLink() else { return }
        didCopyLink = true
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            didCopyLink = false
        }
    }

    @ViewBuilder
    private func sectionLabel(_ text: String) -> some View {
        Text(verbatim: text)
            .font(Typography.monoTag)
            .foregroundColor(SoyehtTheme.textSecondary)
            .padding(.horizontal, 16)
            .padding(.top, 20)
            .padding(.bottom, 8)
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
