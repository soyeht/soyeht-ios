import SwiftUI
import SoyehtCore

/// Root SwiftUI view hosted by `ClawStoreWindowController`. Browses the
/// claw catalog; pushes `MacClawDetailView` on selection. Deliberately
/// simpler than the iOS counterpart — no "editor's pick" / "trending"
/// decoration, just a responsive grid that fits the macOS window and
/// surfaces the core install lifecycle directly.
struct MacClawStoreRootView: View {
    let context: ServerContext
    @StateObject private var viewModel: ClawStoreViewModel
    @State private var path: [ClawRoute] = []

    init(context: ServerContext) {
        self.context = context
        _viewModel = StateObject(wrappedValue: ClawStoreViewModel(context: context))
    }

    var body: some View {
        NavigationStack(path: $path) {
            content
                .navigationTitle("claw.store.navigationTitle")
                .toolbar {
                    ToolbarItem(placement: .automatic) {
                        Button {
                            Task { await viewModel.loadClaws() }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .help("claw.store.toolbar.reload.help")
                    }
                }
                .navigationDestination(for: ClawRoute.self) { route in
                    switch route {
                    case .store:
                        content
                    case .detail(let claw):
                        MacClawDetailView(claw: claw, context: context, onInstallStateChanged: {
                            Task { await viewModel.loadClaws() }
                        })
                    case .setup(let claw):
                        MacClawSetupView(claw: claw)
                    }
                }
        }
        .task {
            await viewModel.loadClaws()
        }
        .alert("claw.store.alert.error.title", isPresented: .init(
            get: { viewModel.actionError != nil },
            set: { if !$0 { viewModel.actionError = nil } }
        )) {
            Button("common.button.ok") { viewModel.actionError = nil }
        } message: {
            Text(viewModel.actionError ?? "")
        }
        .frame(minWidth: 680, minHeight: 520)
        .background(MacClawStoreTheme.bgPrimary)
        .preferredColorScheme(MacClawStoreTheme.preferredColorScheme)
    }

    @ViewBuilder
    private var content: some View {
        if viewModel.isLoading && viewModel.claws.isEmpty {
            VStack(spacing: 12) {
                ProgressView().tint(MacClawStoreTheme.statusGreen)
                Text("claw.store.loading")
                    .font(MacTypography.Fonts.clawStoreStatus)
                    .foregroundColor(MacClawStoreTheme.textSecondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = viewModel.errorMessage {
            VStack(spacing: 12) {
                Text(LocalizedStringResource(
                    "claw.store.error.banner",
                    defaultValue: "[!] \(error)",
                    comment: "Banner shown when the claw catalog fails to load. %@ = underlying error (server-supplied)."
                ))
                    .font(MacTypography.Fonts.clawStoreStatus)
                    .foregroundColor(MacClawStoreTheme.textWarning)
                    .multilineTextAlignment(.center)
                Button("common.button.retry") { Task { await viewModel.loadClaws() } }
                    .buttonStyle(.bordered)
            }
            .padding(40)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityIdentifier("soyeht.macClawStore.errorBanner")
        } else if viewModel.claws.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "tray")
                    .font(MacTypography.Fonts.clawStoreEmptyIcon)
                    .foregroundColor(MacClawStoreTheme.textMuted)
                Text("claw.store.empty.title")
                    .font(MacTypography.Fonts.clawStoreEmptyTitle)
                    .foregroundColor(MacClawStoreTheme.textSecondary)
                Text("claw.store.empty.description")
                    .font(MacTypography.Fonts.clawStoreStatus)
                    .foregroundColor(MacClawStoreTheme.textMuted)
                    .multilineTextAlignment(.center)
            }
            .padding(40)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityIdentifier("soyeht.macClawStore.emptyState")
        } else {
            grid
                .accessibilityIdentifier("soyeht.macClawStore.grid")
        }
    }

    private var grid: some View {
        let columns = [
            GridItem(.adaptive(minimum: 240, maximum: 320), spacing: 12, alignment: .top),
        ]
        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(viewModel.claws) { claw in
                        MacClawCardView(
                            claw: claw,
                            showInstallButton: true,
                            onInstall: { Task { await viewModel.installClaw(claw) } },
                            onTap: { path.append(ClawRoute.detail(claw)) }
                        )
                    }
                }
                footer
            }
            .padding(20)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("claw.store.header.subtitle")
                .font(MacTypography.Fonts.clawStoreStatus)
                .foregroundColor(MacClawStoreTheme.textMuted)
            if viewModel.isPolling {
                Text("claw.store.header.polling")
                    .font(MacTypography.Fonts.clawStoreFooter)
                    .foregroundColor(MacClawStoreTheme.accentGreen)
            }
        }
    }

    private var footer: some View {
        Text(LocalizedStringResource(
            "claw.store.footer.summary",
            defaultValue: "\(viewModel.availableCount) claws available · \(viewModel.installedCount) installed",
            comment: "Footer summary below the claw grid. %1$lld = available count, %2$lld = installed count."
        ))
            .font(MacTypography.Fonts.clawStoreFooter)
            .foregroundColor(MacClawStoreTheme.textMuted)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, 8)
    }
}
