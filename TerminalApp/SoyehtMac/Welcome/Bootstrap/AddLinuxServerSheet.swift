import SwiftUI
import SoyehtCore
import Foundation

/// Add-Linux-server flow surfaced from the `Connected Servers` window
/// (and from `HouseCardView` during onboarding). The user types one
/// thing — an SSH alias for the remote theyOS host (typically `devs`) —
/// clicks Connect, and the Mac handles the rest in a single fluid step:
///
///   1. SSH to the remote in one round-trip and read:
///      - admin user + password from `~/theyos/.env`
///      - SSH host ed25519 public key (`awk '{print $2}'` of
///        `/etc/ssh/ssh_host_ed25519_key.pub` — the SSH wire-format
///        base64 blob: 4-byte length prefix + `"ssh-ed25519"` + 4-byte
///        length + 32-byte key, ~51 bytes after base64 decode, *not* a
///        raw 32-byte Ed25519 point. `OperatorFingerprint.derive` BLAKE3s
///        whatever it's given, so the verification words are stable per
///        host even though the input is wire-format rather than the raw
///        point. If a future change adds a phone-side derivation that
///        hashes the raw 32 bytes of the same host, the two sides will
///        not agree — extract `| base64 -d | tail -c 32 | base64` here
///        first to align with that.)
///      - Tailscale Magic DNS hostname from `tailscale status --self --json`
///   2. Derive 6 BIP-39 verification words from the host key using the
///      same `OperatorFingerprint` + `BIP39Wordlist` primitives the
///      iPhone pairing flow uses. The words are shown inline as the
///      machine's identity fingerprint — informational so the
///      operator can spot a wrong host, but the *trust* itself comes
///      from the SSH key auth that already had to succeed for step 1
///      to even fetch credentials.
///   3. Mac issues a single `POST https://<tsdns>/api/v1/auth/login`
///      with the admin creds. The remote `tailscale serve` proxy fronts
///      the admin host's plain-HTTP port with a Tailscale-issued
///      LetsEncrypt certificate, so the same hostname carries both this
///      login and the later `wss://` terminal stream over TLS — no ATS
///      relaxation required.
///   4. Server returns `Set-Cookie: soyeht_session=…`; we register the
///      host (`https://<tsdns>`) as the active paired server. Subsequent
///      terminal panes route through `MacOSWebSocketTerminalView.configure(wsUrl:)`.
///
/// No "Confirm and connect" step — the SSH key trust is the security
/// surface. If the operator has accepted `devs` into known_hosts (or
/// SSH key auth works without prompts), that's the trust contract for
/// this connection. Words are advisory.
///
/// The dev build is unsandboxed (`SoyehtMacDebug.entitlements`), so
/// `Process` + `/usr/bin/ssh` is allowed. Shipping this to end users
/// would need a sandbox-friendly path (XPC helper, or a richer
/// pair-link flow) — for now the sheet is the operator-side entry
/// point that pairs a remote Linux theyOS without requiring a phone in
/// the room.
///
/// ## Known limitation — post-pair UX gap
///
/// The pairing flow above completes successfully and the server is
/// registered, but the rest of the Mac UX after pairing is currently
/// broken for Linux-theyOS-paired servers. Clicking `+` → "New
/// Conversation" calls `GET /api/v1/mobile/instances`, which does not
/// exist on the Linux admin host — that surface uses
/// `/api/v1/instances` with cookie auth instead. The admin host masks
/// the mismatch by returning `200 OK` + HTML SPA fallback for unknown
/// `/api/v1/mobile/*` paths, so the Mac decodes the HTML as JSON and
/// reports a generic 401-shaped failure rather than "endpoint doesn't
/// exist".
///
/// Root cause: `SoyehtAPIClient` was built against the iOS-pair
/// engine (Bearer JWT + `/api/v1/mobile/*`) and is not yet
/// platform-aware. The Linux admin theyOS host exposes:
///
///   - Auth: cookie (`Cookie: soyeht_session=…`) from `POST /api/v1/auth/login`.
///   - Namespaces: `/api/v1/instances`, `/api/v1/terminals/.../workspaces`,
///     `/api/v1/admin/*` — no `/mobile/*` at all.
///
/// Fix is intentionally **out of scope for this PR** (perf + iOS leak
/// fixes); tracked in
/// [#103](https://github.com/soyeht/soyeht-ios/issues/103). The
/// follow-up needs to:
///
///   1. Persist the server kind at pairing time (engine vs Linux
///      admin) on the server record.
///   2. Switch auth headers per kind (`Authorization: Bearer …` vs
///      `Cookie: soyeht_session=…`).
///   3. Switch path prefixes per kind (`/mobile/instances` vs
///      `/instances`), and audit every `SoyehtAPIClient` endpoint.
///   4. Reconcile response shapes (some engine endpoints wrap in
///      `{ data: [...] }`).
///   5. Verify the `wss://` terminal stream path for both server kinds
///      in `MacOSWebSocketTerminalView.configure(wsUrl:)`.
///   6. Surface a clear error when a Mac somehow hits the wrong
///      namespace (no "200 OK + HTML decoded as JSON" silent failures).
///
/// Until that lands, paired Linux servers can be added but cannot
/// host new conversations from the Mac.
@MainActor
struct AddLinuxServerSheet: View {
    let onConnected: () -> Void
    let onCancel: () -> Void

    @State private var sshHost: String = "devs"
    @State private var progressMessage: LocalizedStringResource?
    @State private var identityLine: String?
    @State private var errorMessage: String?
    @State private var isWorking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(LocalizedStringResource(
                "addLinuxServer.title",
                defaultValue: "Add Linux server",
                comment: "Title of the Add Linux server sheet."
            ))
            .font(MacTypography.Fonts.Display.heroTitle)
            .foregroundColor(BrandColors.textPrimary)

            Text(LocalizedStringResource(
                "addLinuxServer.body",
                defaultValue: "Type the SSH alias of the theyOS server. The Mac will fetch credentials over SSH and authenticate automatically.",
                comment: "Body explaining the SSH-driven auto-pair flow."
            ))
            .font(MacTypography.Fonts.Onboarding.flowBody(compact: false))
            .foregroundColor(BrandColors.textMuted)

            VStack(alignment: .leading, spacing: 4) {
                Text(LocalizedStringResource(
                    "addLinuxServer.field.sshHost",
                    defaultValue: "SSH host alias",
                    comment: "Label for SSH host alias field."
                ))
                .font(MacTypography.Fonts.welcomeProgressTitle)
                .foregroundColor(BrandColors.textMuted)
                TextField("addLinuxServer.field.sshHost.placeholder", text: $sshHost)
                    .textFieldStyle(.roundedBorder)
                    .disableAutocorrection(true)
                    .disabled(isWorking)
            }

            statusArea

            HStack(spacing: 8) {
                Spacer()
                Button(action: onCancel) {
                    Text(LocalizedStringResource(
                        "addLinuxServer.cancel",
                        defaultValue: "Cancel",
                        comment: "Cancel button."
                    ))
                }
                .keyboardShortcut(.cancelAction)
                .disabled(isWorking)

                Button(action: connect) {
                    Text(LocalizedStringResource(
                        "addLinuxServer.connect",
                        defaultValue: "Connect",
                        comment: "Primary CTA. Runs the SSH+login pipeline end-to-end."
                    ))
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isWorking || sshHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 520)
    }

    @ViewBuilder
    private var statusArea: some View {
        if let progressMessage {
            HStack(spacing: 8) {
                if isWorking { ProgressView().controlSize(.small) }
                Text(progressMessage)
                    .font(MacTypography.Fonts.welcomeProgressBody)
                    .foregroundColor(BrandColors.textMuted)
            }
        }
        if let identityLine {
            Text(verbatim: identityLine)
                .font(MacTypography.Fonts.welcomeProgressBody.monospacedDigit())
                .foregroundColor(BrandColors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        if let errorMessage {
            Text(verbatim: errorMessage)
                .font(MacTypography.Fonts.welcomeProgressBody)
                .foregroundColor(BrandColors.accentAmber)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Pipeline

    private func connect() {
        let host = sshHost.trimmingCharacters(in: .whitespacesAndNewlines)
        errorMessage = nil
        identityLine = nil
        isWorking = true
        progressMessage = LocalizedStringResource(
            "addLinuxServer.status.ssh",
            defaultValue: "Fetching identity over SSH…",
            comment: "Status during the SSH bootstrap fetch."
        )

        Task {
            do {
                let bootstrap = try await Self.runSSHBootstrap(host: host)
                let words = try Self.deriveVerificationWords(hostKey: bootstrap.sshHostKey)
                let identity = "\(host) (\(bootstrap.tailscaleDNSName)) · \(words.joined(separator: " "))"

                await MainActor.run {
                    identityLine = identity
                    progressMessage = LocalizedStringResource(
                        "addLinuxServer.status.login",
                        defaultValue: "Authenticating over HTTPS…",
                        comment: "Status while running the HTTPS login through Tailscale serve."
                    )
                }

                let httpsHost = "https://\(bootstrap.tailscaleDNSName)"
                let cookie = try await Self.postLogin(
                    httpsHost: httpsHost,
                    username: bootstrap.username,
                    password: bootstrap.password
                )

                await MainActor.run {
                    let server = PairedServer(
                        id: UUID().uuidString,
                        host: httpsHost,
                        name: host,
                        role: nil,
                        pairedAt: Date(),
                        expiresAt: nil,
                        platform: "linux"
                    )
                    let store = SessionStore.shared
                    _ = store.addServer(server, token: cookie)
                    store.setActiveServer(id: server.id)
                    isWorking = false
                    progressMessage = nil
                    onConnected()
                }
            } catch {
                await MainActor.run {
                    isWorking = false
                    progressMessage = nil
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    // MARK: - SSH bootstrap (off-main)

    private struct Bootstrap: Sendable {
        let username: String
        let password: String
        let sshHostKey: Data
        let tailscaleDNSName: String  // e.g. "devs.tailXXXX.ts.net" — the only
                                      // hostname we use. `tailscale serve` proxies
                                      // 443 → admin host, so HTTPS/WSS work with
                                      // Tailscale-issued LE certs.
    }

    private nonisolated static func runSSHBootstrap(host: String) async throws -> Bootstrap {
        // The `host` value reaches us from a user-facing TextField. ssh
        // does NOT treat positional args as terminated by an implicit
        // `--`, so a value like `-oProxyCommand=…` would be parsed as an
        // option (ProxyCommand invokes `/bin/sh -c`, i.e. arbitrary local
        // exec under the Mac user). Two layers of defense:
        //   1. Reject anything that starts with `-` or contains `=` /
        //      whitespace before we even spawn the process.
        //   2. Pass `--` immediately before `host` in `process.arguments`
        //      so ssh treats whatever follows as a destination, even if
        //      the validator misses something exotic.
        if host.isEmpty || host.first == "-" ||
           host.contains("=") || host.contains(where: { $0.isWhitespace }) {
            throw AddLinuxServerError.invalidHost(host)
        }
        // Single SSH round-trip — fetch only what the Mac cannot derive on
        // its own: admin credentials, ed25519 host pubkey (for the BIP-39
        // identity words), and the Tailscale Magic DNS name. Login happens
        // back on the Mac over HTTPS via `tailscale serve` (which fronts
        // the admin host's plain-HTTP port with a Tailscale-issued LE
        // certificate). That keeps both auth and the later WSS terminal
        // stream on the same TLS-terminated public hostname.
        let script = """
        set -e
        USER=$(grep -E '^SOYEHT_ADMIN_USER=' ~/theyos/.env | tail -1 | cut -d= -f2- | tr -d '\\r\\n"' )
        PASS=$(grep -E '^SOYEHT_ADMIN_PASSWORD=' ~/theyos/.env | tail -1 | cut -d= -f2- | tr -d '\\r\\n"' )
        HOSTKEY=$(awk '{print $2}' /etc/ssh/ssh_host_ed25519_key.pub 2>/dev/null)
        [ -z "$HOSTKEY" ] && HOSTKEY=$(awk '{print $2}' /etc/ssh/ssh_host_rsa_key.pub 2>/dev/null | head -1)
        TS_DNS=""
        if command -v tailscale >/dev/null 2>&1; then
            TS_DNS=$(tailscale status --self --json 2>/dev/null \\
                | grep '"DNSName"' \\
                | head -1 \\
                | sed -E 's/.*"DNSName"[[:space:]]*:[[:space:]]*"([^"]*)".*/\\1/' \\
                | sed 's/\\.$//')
        fi
        if [ -z "$TS_DNS" ]; then
            echo "MISSING_TAILSCALE_DNS" >&2
            exit 1
        fi
        printf 'user=%s\\npass=%s\\nhostkey=%s\\ntsdns=%s\\n' "$USER" "$PASS" "$HOSTKEY" "$TS_DNS"
        """

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = [
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=10",
            "-o", "StrictHostKeyChecking=accept-new",
            "--",          // Terminate ssh option parsing so a host value
                           // like `-oProxyCommand=…` cannot smuggle in
                           // arbitrary local exec via ssh's option syntax.
            host,
            script,
        ]
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()

        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            let msg = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "ssh exited \(process.terminationStatus)"
            throw AddLinuxServerError.sshFailed(msg)
        }

        let raw = String(data: outData, encoding: .utf8) ?? ""
        var values: [String: String] = [:]
        for line in raw.split(whereSeparator: { $0 == "\n" }) {
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<eq])
            let value = String(line[line.index(after: eq)...])
            values[key] = value
        }
        guard let user = values["user"], !user.isEmpty,
              let pass = values["pass"], !pass.isEmpty,
              let hostKeyBase64 = values["hostkey"], !hostKeyBase64.isEmpty,
              let hostKey = Data(base64Encoded: hostKeyBase64),
              let tsdns = values["tsdns"], !tsdns.isEmpty else {
            throw AddLinuxServerError.bootstrapShapeUnexpected(raw)
        }
        return Bootstrap(
            username: user,
            password: pass,
            sshHostKey: hostKey,
            tailscaleDNSName: tsdns
        )
    }

    // MARK: - Login (off-main, HTTPS via Tailscale serve)

    private nonisolated static func postLogin(
        httpsHost: String,
        username: String,
        password: String
    ) async throws -> String {
        guard let url = URL(string: "\(httpsHost)/api/v1/auth/login") else {
            throw AddLinuxServerError.invalidLoginURL(httpsHost)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpShouldHandleCookies = false
        let body: [String: String] = ["username": username, "password": password]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AddLinuxServerError.loginFailed("non-HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let snippet = String(data: data.prefix(256), encoding: .utf8) ?? ""
            throw AddLinuxServerError.loginFailed("HTTP \(http.statusCode) — \(snippet)")
        }
        // Extract Set-Cookie `soyeht_session=...; Path=...; ...`. URLSession
        // strips multi-valued Set-Cookie headers; iterate `allHeaderFields`
        // and parse the first cookie we recognise.
        for (key, value) in http.allHeaderFields {
            guard
                let name = (key as? String),
                name.lowercased() == "set-cookie",
                let raw = (value as? String)
            else { continue }
            for piece in raw.split(separator: ",") {
                let trimmed = piece.trimmingCharacters(in: .whitespaces)
                if let eq = trimmed.firstIndex(of: "="),
                   trimmed[..<eq] == "soyeht_session" {
                    let after = trimmed[trimmed.index(after: eq)...]
                    let value = after.split(separator: ";").first.map(String.init) ?? String(after)
                    if !value.isEmpty { return value }
                }
            }
        }
        throw AddLinuxServerError.loginFailed("Missing soyeht_session cookie in response.")
    }

    // MARK: - Verification words (informational)

    private nonisolated static func deriveVerificationWords(hostKey: Data) throws -> [String] {
        let wordlist = try BIP39Wordlist()
        let fingerprint = try OperatorFingerprint.derive(
            machinePublicKey: hostKey,
            wordlist: wordlist
        )
        return fingerprint.words
    }

    enum AddLinuxServerError: LocalizedError {
        case sshFailed(String)
        case bootstrapShapeUnexpected(String)
        case invalidHost(String)
        case invalidLoginURL(String)
        case loginFailed(String)

        var errorDescription: String? {
            switch self {
            case .sshFailed(let msg):
                return "SSH failed: \(msg)"
            case .bootstrapShapeUnexpected(let raw):
                return "Unexpected SSH output:\n\(raw)"
            case .invalidHost(let host):
                return "Host alias contains characters that ssh would treat as options: \(host)"
            case .invalidLoginURL(let host):
                return "Invalid login URL for host: \(host)"
            case .loginFailed(let msg):
                return "Login failed: \(msg)"
            }
        }
    }
}
