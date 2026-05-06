import Foundation

public enum Phase3WireError: Error, Equatable {
    case wrongResponseShape
    case wrongContentType(String?)
    case malformedErrorBody
    case missingErrorVersion
    case unsupportedErrorVersion(UInt64)
    case missingErrorField
    case statusError(httpStatus: Int, code: String, message: String?)
    case transportFailed
}

public struct Phase3WireClient: Sendable {
    public typealias TransportPerform = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    public static let contentType = "application/cbor"

    private let perform: TransportPerform

    public init(perform: @escaping TransportPerform = Phase3WireClient.urlSessionTransport()) {
        self.perform = perform
    }

    public static func urlSessionTransport(_ session: URLSession = .shared) -> TransportPerform {
        { request in try await session.data(for: request) }
    }

    /// Sends `body` (canonical CBOR bytes) to a Phase 3 endpoint and returns
    /// the raw CBOR bytes of a 2xx response. Non-2xx responses, wrong
    /// content-types, and malformed error bodies all surface as typed
    /// `Phase3WireError` cases — there is no JSON fallback (FR-030 + FR-031).
    public func send(
        method: String,
        url: URL,
        body: Data,
        additionalHeaders: [String: String] = [:]
    ) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = method.uppercased()
        request.setValue(Self.contentType, forHTTPHeaderField: "Content-Type")
        request.setValue(Self.contentType, forHTTPHeaderField: "Accept")
        for (header, value) in additionalHeaders {
            request.setValue(value, forHTTPHeaderField: header)
        }
        request.httpBody = body

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await perform(request)
        } catch let error as Phase3WireError {
            throw error
        } catch {
            throw Phase3WireError.transportFailed
        }

        guard let http = response as? HTTPURLResponse else {
            throw Phase3WireError.wrongResponseShape
        }

        let returnedContentType = http.value(forHTTPHeaderField: "Content-Type")
            ?? http.value(forHTTPHeaderField: "content-type")
        let primaryType = returnedContentType?
            .split(separator: ";")
            .first
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        guard primaryType == Self.contentType else {
            throw Phase3WireError.wrongContentType(returnedContentType)
        }

        if (200..<300).contains(http.statusCode) {
            return data
        }

        // 4xx / 5xx: MUST parse as canonical CBOR `{v=1, error=<string>, message?: <string>}`.
        let decoded: HouseholdCBORValue
        do {
            decoded = try HouseholdCBOR.decode(data)
        } catch {
            throw Phase3WireError.malformedErrorBody
        }
        guard case .map(let map) = decoded else {
            throw Phase3WireError.malformedErrorBody
        }
        guard let versionField = map["v"], case .unsigned(let version) = versionField else {
            throw Phase3WireError.missingErrorVersion
        }
        guard version == 1 else {
            throw Phase3WireError.unsupportedErrorVersion(version)
        }
        guard let errorField = map["error"], case .text(let code) = errorField else {
            throw Phase3WireError.missingErrorField
        }
        var message: String? = nil
        if case .text(let text) = map["message"] {
            message = text
        }
        throw Phase3WireError.statusError(
            httpStatus: http.statusCode,
            code: code,
            message: message
        )
    }
}
