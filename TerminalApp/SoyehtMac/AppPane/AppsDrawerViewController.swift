import AppKit
import SwiftUI
import SoyehtCore

/// The right-side drawer that lists installed apps and installs new ones.
///
/// Structurally a mirror of `ClawDrawerViewController`, and deliberately so:
/// same panel surface, same hosting rules, same theme notification. Apps and
/// Claws are different concepts that share one drawer slot, so they must look
/// like siblings rather than like two people's ideas.
///
/// **Style**: nothing here paints a neomorphic shadow. Panel elevation comes
/// from `MacSurface.Shadows.drawerPanelSet`, which is empty in the classic
/// style, and the SwiftUI content uses semantic radii plus a hairline stroke —
/// so classic renders flat and neomorphic renders raised from one code path.
@MainActor
final class AppsDrawerViewController: NSViewController {
    var onDismiss: (() -> Void)?
    var onOpenApp: ((AppInstallRecord) -> Void)?

    private let viewModel = AppsDrawerViewModel()
    private var hostingController: NSHostingController<AppsDrawerRootView>?

    override func loadView() {
        let root = MacStyledSurfaceView()
        applyPanelStyle(to: root)
        self.view = root

        let host = NSHostingController(rootView: AppsDrawerRootView(
            viewModel: viewModel,
            onOpenApp: { [weak self] record in self?.onOpenApp?(record) },
            onDismiss: { [weak self] in self?.onDismiss?() }
        ))
        // Same reason as the Claw drawer: the drawer lives in a fixed-width
        // overlay, so SwiftUI's ideal size must not reach the window.
        host.sizingOptions = []
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        host.view.wantsLayer = true
        host.view.layer?.backgroundColor = NSColor.clear.cgColor
        root.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.topAnchor.constraint(equalTo: root.topAnchor),
            host.view.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            host.view.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        hostingController = host
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(preferencesDidChange),
            name: .preferencesDidChange,
            object: nil
        )
        viewModel.refresh()
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    func refresh() { viewModel.refresh() }

    func applyTheme() {
        if let root = view as? MacStyledSurfaceView { applyPanelStyle(to: root) }
        viewModel.themeToken = UUID()
    }

    private func applyPanelStyle(to root: MacStyledSurfaceView) {
        let neo = MacSurface.style == .neomorphic
        root.applyStyle(
            fill: neo ? MacTheme.neoWell : MacTheme.surfaceBase,
            gradient: neo ? (MacTheme.neoConvexStart, MacTheme.neoConvexEnd) : nil,
            cornerRadius: neo ? MacSurface.Radius.panel : 0,
            shadows: MacSurface.Shadows.drawerPanelSet
        )
    }

    @objc private func preferencesDidChange() { applyTheme() }
}

@MainActor
final class AppsDrawerViewModel: ObservableObject {
    @Published var installed: [AppInstallRecord] = []
    /// Bumped on theme change so SwiftUI re-reads the AppKit-derived colours.
    @Published var themeToken = UUID()
    /// A bundle the person picked and has not yet accepted. Its presence is
    /// what puts the sheet on screen: nothing is copied until they accept.
    @Published var pendingInstall: AppBundleInspection?
    @Published var failure: String?

    func refresh() { installed = AppInstallStore.installed }

    /// Step one of installing: read what the folder declares and show it.
    func chooseBundle() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Inspect"
        panel.message = "Pick a folder containing manifest.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            pendingInstall = try AppInstallStore.inspect(bundleAt: url)
        } catch {
            failure = Self.describe(error)
        }
    }

    /// Step two: copy it, but only the bundle they were actually shown.
    func acceptPendingInstall() {
        guard let pending = pendingInstall else { return }
        do {
            _ = try AppInstallStore.install(pending)
            pendingInstall = nil
            refresh()
        } catch AppInstallStore.InstallError.bundleChangedSinceInspection {
            pendingInstall = nil
            failure = "That folder changed while you were looking at it. Nothing was installed — inspect it again."
        } catch {
            pendingInstall = nil
            failure = Self.describe(error)
        }
    }

    func cancelPendingInstall() { pendingInstall = nil }

    /// Never surfaces a path, host or the existence of a file: an install
    /// dialog is not a place to leak the filesystem back to the caller.
    private static func describe(_ error: Error) -> String {
        if error is AppManifestError { return "That folder's manifest.json is not a valid app manifest." }
        if case AppInstallStore.InstallError.unsupportedBundleEntry = error {
            return "That folder contains something an app bundle cannot hold."
        }
        return "That folder could not be read as an app bundle."
    }
}

struct AppsDrawerRootView: View {
    @ObservedObject var viewModel: AppsDrawerViewModel
    let onOpenApp: (AppInstallRecord) -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            header
            Text("Local HTML apps. Each runs in its own origin, with no network access.")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(AppsDrawerTokens.textMuted)
                .fixedSize(horizontal: false, vertical: true)

            if viewModel.installed.isEmpty {
                emptyState
            } else {
                ScrollView { VStack(spacing: 10) { ForEach(viewModel.installed, id: \.installID, content: row) } }
            }

            Spacer(minLength: 0)
            if let failure = viewModel.failure { failureBanner(failure) }
            installButton
        }
        .padding(18)
        .id(viewModel.themeToken)
        .sheet(item: Binding(get: { viewModel.pendingInstall }, set: { if $0 == nil { viewModel.cancelPendingInstall() } })) { inspection in
            AppInstallSheet(
                inspection: inspection,
                onCancel: { viewModel.cancelPendingInstall() },
                onInstall: { viewModel.acceptPendingInstall() }
            )
        }
    }

    private var header: some View {
        HStack(spacing: 9) {
            Text("Your Apps").font(.system(size: 20, weight: .bold)).foregroundStyle(AppsDrawerTokens.textPrimary)
            Spacer()
            Button(action: onDismiss) {
                Image(systemName: "xmark").font(.system(size: 11, weight: .bold))
                    .foregroundStyle(AppsDrawerTokens.textMuted).frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)
            .overlay(circleOutline)
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("No apps installed").font(.system(size: 13, weight: .semibold))
                .foregroundStyle(AppsDrawerTokens.textPrimary)
            Text("An app is a folder with manifest.json and its HTML. Nothing is downloaded — you pick the folder.")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(AppsDrawerTokens.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: MacSurface.Radius.card).fill(AppsDrawerTokens.panel))
        .overlay(RoundedRectangle(cornerRadius: MacSurface.Radius.card)
            .stroke(AppsDrawerTokens.stroke, lineWidth: MacSurface.Border.hairline))
    }

    private func row(_ record: AppInstallRecord) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(record.manifest.name).font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(AppsDrawerTokens.textPrimary).lineLimit(1)
                HStack(spacing: 6) {
                    Text("\(record.manifest.version) · local")
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(AppsDrawerTokens.textMuted)
                    ForEach(record.manifest.capabilities, id: \.self) { capability in
                        chip(capability.uppercased(), tint: AppsDrawerTokens.accent)
                    }
                    if record.manifest.capabilities.isEmpty {
                        chip("NO ACCESS", tint: AppsDrawerTokens.textMuted)
                    }
                }
            }
            Spacer(minLength: 0)
            Button { onOpenApp(record) } label: {
                Image(systemName: "play.fill").font(.system(size: 11, weight: .bold))
                    .foregroundStyle(AppsDrawerTokens.accent).frame(width: 34, height: 34)
            }
            .buttonStyle(.plain)
            .overlay(circleOutline)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: MacSurface.Radius.card).fill(AppsDrawerTokens.panel))
        .overlay(RoundedRectangle(cornerRadius: MacSurface.Radius.card)
            .stroke(AppsDrawerTokens.stroke, lineWidth: MacSurface.Border.hairline))
    }

    /// Decoration only, and it MUST NOT take hits. A stroked shape in an
    /// `.overlay` sits on top of the button and swallows the click. Measured
    /// in the E2E: "Install app…" (which draws its shape with `.background`)
    /// worked, while both icon buttons did nothing at all — same code, one
    /// modifier apart.
    private var circleOutline: some View {
        Circle()
            .stroke(AppsDrawerTokens.stroke, lineWidth: MacSurface.Border.hairline)
            .allowsHitTesting(false)
    }

    private func chip(_ text: String, tint: Color) -> some View {
        Text(text).font(.system(size: 10, weight: .bold)).foregroundStyle(tint)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .overlay(RoundedRectangle(cornerRadius: MacSurface.Radius.chip)
                .stroke(AppsDrawerTokens.stroke, lineWidth: MacSurface.Border.hairline))
    }

    private func failureBanner(_ message: String) -> some View {
        Text(message).font(.system(size: 11, weight: .medium))
            .foregroundStyle(AppsDrawerTokens.warning)
            .fixedSize(horizontal: false, vertical: true)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(RoundedRectangle(cornerRadius: MacSurface.Radius.control)
                .stroke(AppsDrawerTokens.stroke, lineWidth: MacSurface.Border.hairline))
    }

    private var installButton: some View {
        Button { viewModel.chooseBundle() } label: {
            HStack(spacing: 8) {
                Image(systemName: "folder.badge.plus").font(.system(size: 12, weight: .bold))
                Text("Install app…").font(.system(size: 15, weight: .bold))
            }
            .foregroundStyle(AppsDrawerTokens.buttonTextOnAccent)
            .frame(maxWidth: .infinity).padding(.vertical, 12)
            .background(RoundedRectangle(cornerRadius: MacSurface.Radius.control).fill(AppsDrawerTokens.accent))
        }
        .buttonStyle(.plain)
    }
}

/// Shows what a candidate bundle DECLARES, before anything is copied.
///
/// Every value on this sheet comes from the bundle itself. The wording says so,
/// because the one thing this screen must not do is make a declaration look
/// like a verification — nothing here has been signed or reviewed by anyone.
struct AppInstallSheet: View {
    let inspection: AppBundleInspection
    let onCancel: () -> Void
    let onInstall: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Install app").font(.system(size: 20, weight: .bold))
                .foregroundStyle(AppsDrawerTokens.textPrimary)

            HStack(spacing: 8) {
                Text(inspection.manifest.name).font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(AppsDrawerTokens.textPrimary)
                Text("NOT VERIFIED").font(.system(size: 10, weight: .bold))
                    .foregroundStyle(AppsDrawerTokens.warning)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .overlay(RoundedRectangle(cornerRadius: MacSurface.Radius.chip)
                        .stroke(AppsDrawerTokens.stroke, lineWidth: MacSurface.Border.hairline))
            }
            Text("No signature, no review. You are trusting this folder.")
                .font(.system(size: 11, weight: .medium)).foregroundStyle(AppsDrawerTokens.textMuted)

            section("MANIFEST DECLARES") {
                field("Name", inspection.manifest.name)
                field("Version", inspection.manifest.version)
                field("Publisher", inspection.manifest.publisher.displayName)
                field("Entry", inspection.manifest.entry)
            }

            section("DECLARED CAPABILITIES") {
                if inspection.manifest.capabilities.isEmpty {
                    Text("None. It can render, and nothing else.")
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(AppsDrawerTokens.textMuted)
                } else {
                    ForEach(inspection.manifest.capabilities, id: \.self) { capability in
                        Text(AppInstallSheet.describe(capability))
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(AppsDrawerTokens.textPrimary)
                    }
                }
            }

            Text("Runs in its own origin. No network access.")
                .font(.system(size: 12, weight: .medium)).foregroundStyle(AppsDrawerTokens.textMuted)

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                Button("Install", action: onInstall).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    /// Spelled out in the terms of what the app can actually observe, because
    /// "metrics.read" tells the person nothing about what they are agreeing to.
    static func describe(_ capability: String) -> String {
        capability == AppCapability.metricsRead.rawValue
            ? "System metrics — CPU load per core, memory used and free, uptime"
            : capability
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 11, weight: .bold)).foregroundStyle(AppsDrawerTokens.textMuted)
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: MacSurface.Radius.card)
            .stroke(AppsDrawerTokens.stroke, lineWidth: MacSurface.Border.hairline))
    }

    private func field(_ key: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(key).font(.system(size: 12, weight: .medium))
                .foregroundStyle(AppsDrawerTokens.textMuted).frame(width: 88, alignment: .leading)
            Text(value).font(.system(size: 12, weight: .semibold))
                .foregroundStyle(AppsDrawerTokens.textPrimary)
        }
    }
}

/// Colours come from the same theme source the Claw drawer uses, so both
/// drawers move together when the palette or the design style changes.
private enum AppsDrawerTokens {
    static var panel: Color { MacClawStoreTheme.bgCard }
    static var stroke: Color { MacClawStoreTheme.readableStroke }
    static var accent: Color { MacClawStoreTheme.statusGreen }
    static var warning: Color { MacClawStoreTheme.accentAmber }
    static var textPrimary: Color { MacClawStoreTheme.textPrimary }
    static var textMuted: Color { MacClawStoreTheme.textMuted }
    static var buttonTextOnAccent: Color { MacClawStoreTheme.buttonTextOnAccent }
}
