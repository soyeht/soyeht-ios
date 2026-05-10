import Foundation

/// Client for `GET /health`.
///
/// Lightweight liveness check. Returns `engineVersion` from the response body
/// if the engine is responsive; throws `BootstrapError` otherwise.
public struct BootstrapHealthClient: Sendable {
    public typealias TransportPerform = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    static let path = "/health"
    static let contentType = "application/json"

    private let baseURL: URL
    private let perform: TransportPerform

    public init(
        baseURL: URL,
        transport: @escaping TransportPerform = { req in try await URLSession.shared.data(for: req) }
    ) {
        self.baseURL = baseURL
        self.perform = transport
    }

    /// Fetches `/health` and returns the engine version string on success.
    public func check() async throws -> String {
        let (url, _) = BootstrapWire.endpointURL(baseURL: baseURL, path: Self.path)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await perform(request)
        } catch let error as BootstrapError {
            throw error
        } catch {
            throw BootstrapError.networkDrop
        }

        guard let http = response as? HTTPURLResponse else {
            throw BootstrapError.protocolViolation(detail: .unexpectedResponseShape)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw BootstrapError.networkDrop
        }

        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let version = json["version"] as? String {
            return version
        }
        return ""
    }
}
