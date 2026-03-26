import SwiftUI

// MARK: - Model

struct ServerInstance: Identifiable {
    let id = UUID()
    let name: String
    let ip: String
    let port: Int
    let tags: [String]
    let isOnline: Bool
    let username: String
    let password: String
}

// MARK: - Mock Data

private let mockInstances: [ServerInstance] = [
    ServerInstance(name: "dev-server", ip: "192.168.1.10:22", port: 22, tags: ["linux"], isOnline: true, username: "", password: ""),
    ServerInstance(name: "staging-01", ip: "10.0.0.45:22", port: 22, tags: ["linux"], isOnline: true, username: "", password: ""),
    ServerInstance(name: "prod-api", ip: "api.soyeht.io:443", port: 443, tags: ["linux"], isOnline: true, username: "", password: ""),
    ServerInstance(name: "mac-studio", ip: "192.168.1.50:22", port: 22, tags: ["macos"], isOnline: true, username: "", password: ""),
    ServerInstance(name: "win-build", ip: "10.0.0.95:3389", port: 3389, tags: ["windows"], isOnline: false, username: "", password: ""),
]

// MARK: - Mock Session Data

struct TmuxSession: Identifiable {
    let id = UUID()
    let name: String
    let windows: Int
    let created: String
    let isAttached: Bool
}

struct TmuxWindow: Identifiable {
    let id = UUID()
    let index: Int
    let name: String
    let panes: Int
}

private let mockSessions: [TmuxSession] = [
    TmuxSession(name: "claude-code", windows: 3, created: "2h ago", isAttached: true),
    TmuxSession(name: "dev-workflow", windows: 5, created: "1d ago", isAttached: false),
    TmuxSession(name: "monitoring", windows: 2, created: "5d ago", isAttached: false),
    TmuxSession(name: "deploy-pipeline", windows: 1, created: "12d ago", isAttached: false),
]

private let mockWindows: [TmuxWindow] = [
    TmuxWindow(index: 0, name: "claude", panes: 2),
    TmuxWindow(index: 1, name: "bash", panes: 1),
    TmuxWindow(index: 2, name: "htop", panes: 1),
]

// MARK: - Instance List View

struct InstanceListView: View {
    let onConnect: (SSHConnectionInfo, ServerInstance) -> Void

    @State private var selectedInstance: ServerInstance?

    private var connectedCount: Int { mockInstances.filter(\.isOnline).count }
    private var offlineCount: Int { mockInstances.filter { !$0.isOnline }.count }

    var body: some View {
        ZStack {
            SoyehtTheme.bgPrimary.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {
                // Header
                HStack {
                    HStack(spacing: 0) {
                        Text("> ")
                            .foregroundColor(SoyehtTheme.accentGreen)
                        Text("soyeht")
                            .foregroundColor(.white)
                    }
                    .font(.system(size: 20, weight: .bold, design: .monospaced))

                    Spacer()

                    Button(action: {}) {
                        Image(systemName: "gearshape")
                            .font(.system(size: 18))
                            .foregroundColor(SoyehtTheme.textSecondary)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 24)

                // Section label
                Text("// instances")
                    .font(SoyehtTheme.labelFont)
                    .foregroundColor(SoyehtTheme.textComment)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 12)

                // Instance list
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(mockInstances) { instance in
                            InstanceCard(instance: instance)
                                .onTapGesture {
                                    if instance.isOnline {
                                        selectedInstance = instance
                                    }
                                }
                        }

                        // Add instance button
                        Button(action: {}) {
                            HStack {
                                Text("+ add instance")
                                    .font(SoyehtTheme.bodyMono)
                                    .foregroundColor(SoyehtTheme.accentGreen)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(SoyehtTheme.accentGreen.opacity(0.4), lineWidth: 1)
                            )
                        }
                        .buttonStyle(.plain)
                        .padding(.top, 4)
                    }
                    .padding(.horizontal, 20)
                }

                // Footer
                HStack(spacing: 0) {
                    Circle()
                        .fill(SoyehtTheme.statusOnline)
                        .frame(width: 6, height: 6)
                    Text(" \(connectedCount) connected")
                        .foregroundColor(SoyehtTheme.textSecondary)
                    Text("  //  ")
                        .foregroundColor(SoyehtTheme.textComment)
                    Text("\(offlineCount) offline")
                        .foregroundColor(SoyehtTheme.textSecondary)
                }
                .font(SoyehtTheme.smallMono)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            }
        }
        .sheet(item: $selectedInstance) { instance in
            SessionListView(instance: instance) { info in
                selectedInstance = nil
                onConnect(info, instance)
            }
        }
    }
}

// MARK: - Instance Card

private struct InstanceCard: View {
    let instance: ServerInstance

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(instance.isOnline ? SoyehtTheme.statusOnline : SoyehtTheme.statusOffline)
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 4) {
                Text(instance.name)
                    .font(.system(size: 15, weight: .medium, design: .monospaced))
                    .foregroundColor(.white)

                Text(instance.ip)
                    .font(SoyehtTheme.smallMono)
                    .foregroundColor(SoyehtTheme.textSecondary)
            }

            Spacer()

            ForEach(instance.tags, id: \.self) { tag in
                Text("[\(tag)]")
                    .font(SoyehtTheme.tagFont)
                    .foregroundColor(SoyehtTheme.textSecondary)
            }

            Text(">>")
                .font(SoyehtTheme.tagFont)
                .foregroundColor(SoyehtTheme.textComment)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(SoyehtTheme.bgCard)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(SoyehtTheme.bgCardBorder, lineWidth: 1)
                )
        )
        .opacity(instance.isOnline ? 1.0 : 0.5)
    }
}

// MARK: - Session List View

struct SessionListView: View {
    let instance: ServerInstance
    let onAttach: (SSHConnectionInfo) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selectedSession: TmuxSession?

    var body: some View {
        ZStack {
            SoyehtTheme.bgPrimary.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {
                // Header
                HStack {
                    Button(action: { dismiss() }) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundColor(SoyehtTheme.textSecondary)
                    }

                    Text(instance.name)
                        .font(.system(size: 16, weight: .medium, design: .monospaced))
                        .foregroundColor(.white)

                    Circle()
                        .fill(SoyehtTheme.statusOnline)
                        .frame(width: 6, height: 6)

                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 24)

                // Section: tmux sessions
                Text("// tmux sessions")
                    .font(SoyehtTheme.labelFont)
                    .foregroundColor(SoyehtTheme.textComment)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 12)

                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(mockSessions) { session in
                            SessionCard(session: session)
                                .onTapGesture {
                                    selectedSession = session
                                }
                        }

                        // New session button
                        Button(action: {}) {
                            Text("+ new session")
                                .font(SoyehtTheme.bodyMono)
                                .foregroundColor(SoyehtTheme.accentGreen)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 16)
                                .background(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(SoyehtTheme.accentGreen.opacity(0.4), lineWidth: 1)
                                )
                        }
                        .buttonStyle(.plain)
                        .padding(.top, 4)
                    }
                    .padding(.horizontal, 20)
                }

                // Footer
                Text("\(mockSessions.count) active sessions  -  swipe left to delete")
                    .font(SoyehtTheme.smallMono)
                    .foregroundColor(SoyehtTheme.textComment)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
        }
        .sheet(item: $selectedSession) { session in
            SessionDetailView(instance: instance, session: session, onAttach: { info in
                selectedSession = nil
                onAttach(info)
            })
        }
    }
}

// MARK: - Session Card

private struct SessionCard: View {
    let session: TmuxSession

    var body: some View {
        HStack(spacing: 12) {
            Text("$")
                .font(.system(size: 14, weight: .bold, design: .monospaced))
                .foregroundColor(SoyehtTheme.accentGreen)

            VStack(alignment: .leading, spacing: 2) {
                Text(session.name)
                    .font(.system(size: 15, weight: .medium, design: .monospaced))
                    .foregroundColor(.white)

                Text("\(session.windows) windows  -  created \(session.created)")
                    .font(SoyehtTheme.smallMono)
                    .foregroundColor(SoyehtTheme.textSecondary)
            }

            Spacer()

            if session.isAttached {
                Text("attached")
                    .font(SoyehtTheme.tagFont)
                    .foregroundColor(SoyehtTheme.accentGreen)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        Capsule()
                            .fill(SoyehtTheme.accentGreen.opacity(0.15))
                    )
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(SoyehtTheme.bgCard)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(SoyehtTheme.bgCardBorder, lineWidth: 1)
                )
        )
    }
}

// MARK: - Session Detail View

struct SessionDetailView: View {
    let instance: ServerInstance
    let session: TmuxSession
    let onAttach: (SSHConnectionInfo) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            SoyehtTheme.bgPrimary.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {
                // Header
                HStack {
                    Text("$ \(session.name)")
                        .font(.system(size: 16, weight: .medium, design: .monospaced))
                        .foregroundColor(.white)

                    Spacer()

                    if session.isAttached {
                        Text("attached")
                            .font(SoyehtTheme.tagFont)
                            .foregroundColor(SoyehtTheme.accentGreen)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(
                                Capsule()
                                    .fill(SoyehtTheme.accentGreen.opacity(0.15))
                            )
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 24)

                // Section: session details
                Text("// session details")
                    .font(SoyehtTheme.labelFont)
                    .foregroundColor(SoyehtTheme.textComment)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 12)

                // Windows
                VStack(spacing: 6) {
                    ForEach(mockWindows) { window in
                        HStack {
                            Text("[\(window.index)]")
                                .font(SoyehtTheme.bodyMono)
                                .foregroundColor(SoyehtTheme.textComment)

                            Text(window.name)
                                .font(SoyehtTheme.bodyMono)
                                .foregroundColor(.white)

                            Spacer()

                            Text("\(window.panes) pane\(window.panes > 1 ? "s" : "")")
                                .font(SoyehtTheme.smallMono)
                                .foregroundColor(SoyehtTheme.textSecondary)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(SoyehtTheme.bgCard)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(SoyehtTheme.bgCardBorder, lineWidth: 1)
                                )
                        )
                    }
                }
                .padding(.horizontal, 20)

                Spacer()

                // Action buttons
                HStack(spacing: 12) {
                    Button(action: {
                        let info = SSHConnectionInfo(
                            host: instance.ip.components(separatedBy: ":").first ?? "localhost",
                            port: instance.port,
                            username: instance.username.isEmpty ? "user" : instance.username,
                            password: instance.password
                        )
                        onAttach(info)
                    }) {
                        HStack(spacing: 6) {
                            Text("$")
                                .font(.system(size: 14, weight: .bold, design: .monospaced))
                            Text("attach")
                                .font(.system(size: 14, weight: .semibold, design: .monospaced))
                        }
                        .foregroundColor(.black)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(SoyehtTheme.accentGreen)
                        )
                    }
                    .buttonStyle(.plain)

                    Button(action: { dismiss() }) {
                        Text("kill")
                            .font(.system(size: 14, weight: .semibold, design: .monospaced))
                            .foregroundColor(.red)
                            .frame(width: 80)
                            .padding(.vertical, 14)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(SoyehtTheme.bgTertiary)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8)
                                            .stroke(Color.red.opacity(0.3), lineWidth: 1)
                                    )
                            )
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 30)
            }
        }
    }
}
