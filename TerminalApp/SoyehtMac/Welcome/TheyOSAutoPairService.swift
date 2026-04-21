import Foundation
import SoyehtCore

/// Drives the three-request pairing flow that lets the macOS app claim a
/// session on a freshly-installed theyOS instance without asking the user
/// for a link:
///
///     1. Read `~/.theyos/bootstrap-token` (single-use Bearer the admin
///        backend accepts until a real admin session exists).
///     2. POST /api/v1/mobile/pair-token with that Bearer → server-level
///        pair token (works even with zero instances provisioned).
///     3. POST /api/v1/mobile/pair with the pair token → session token.
///        `SoyehtAPIClient.pairServer` already owns this request, so we
///        hand the pair token to it and the resulting `PairedServer` is
///        added to `SessionStore` automatically.
///
/// Matches the contract validated in Fase 0.C against
/// `~/Documents/theyos/admin/rust/server-rs`.
@MainActor
final class TheyOSAutoPairService {

    enum AutoPairError: LocalizedError {
        case bootstrapTokenMissing
        case pairTokenRequestFailed(Int)
        case pairTokenDecodeFailed

        var errorDescription: String? {
            switch self {
            case .bootstrapTokenMissing:
                return "Arquivo ~/.theyos/bootstrap-token ausente. Rode o install novamente."
            case .pairTokenRequestFailed(let code):
                return "Servidor rejeitou o token de install (HTTP \(code))."
            case .pairTokenDecodeFailed:
                return "Resposta inesperada do endpoint de pareamento."
            }
        }
    }

    private let apiClient: SoyehtAPIClient
    private let session: URLSession
    private let host: String

    init(
        apiClient: SoyehtAPIClient = .shared,
        session: URLSession = .shared,
        host: String = TheyOSEnvironment.adminHost
    ) {
        self.apiClient = apiClient
        self.session = session
        self.host = host
    }

    /// Runs the auto-pair flow. Returns the `PairedServer` on success —
    /// the server is already stored in `SessionStore.shared` when this
    /// method returns, mirroring `pairServer`'s contract.
    func autoPair() async throws -> PairedServer {
        guard let bootstrap = TheyOSEnvironment.readBootstrapToken() else {
            throw AutoPairError.bootstrapTokenMissing
        }

        let pairToken = try await requestPairToken(bootstrap: bootstrap)
        let paired = try await apiClient.pairServer(token: pairToken, host: host)
        return paired
    }

    /// POST /api/v1/mobile/pair-token with the bootstrap Bearer. The server
    /// mints a server-level pair token (instance_id == "__server_pair__")
    /// that we redeem in step 3 via `pairServer`.
    private func requestPairToken(bootstrap: String) async throws -> String {
        var url = URL(string: "http://\(host)/api/v1/mobile/pair-token")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(bootstrap)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(PairTokenRequestBody(ttlSecs: 900))

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AutoPairError.pairTokenDecodeFailed
        }
        guard (200...299).contains(http.statusCode) else {
            throw AutoPairError.pairTokenRequestFailed(http.statusCode)
        }
        guard let body = try? JSONDecoder().decode(PairTokenResponseBody.self, from: data) else {
            throw AutoPairError.pairTokenDecodeFailed
        }
        _ = url  // silence "never mutated" — url is reused if we ever retry
        return body.token
    }

    private struct PairTokenRequestBody: Encodable {
        let ttlSecs: Int

        private enum CodingKeys: String, CodingKey {
            case ttlSecs = "ttl_secs"
        }
    }

    private struct PairTokenResponseBody: Decodable {
        let token: String
    }
}
