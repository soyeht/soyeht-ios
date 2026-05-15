import Foundation

// Internal utilities shared by all /bootstrap/* clients.
// Mirrors the static helpers in JoinRequestStagingClient but uses BootstrapError.
enum BootstrapWire {
    static let contentType = "application/cbor"

    static func isCBORContentType(_ value: String?) -> Bool {
        value?
            .split(separator: ";")
            .first
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() } == contentType
    }

    // Returns (URL, percentEncodedPath) for signing.
    static func endpointURL(baseURL: URL, path: String) -> (URL, String) {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        let basePath = components.percentEncodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.percentEncodedPath = basePath.isEmpty ? path : "/\(basePath)\(path)"
        components.percentEncodedQuery = nil
        components.fragment = nil
        return (components.url!, components.percentEncodedPath)
    }

    // Decode and verify canonical CBOR encoding (fail-closed per contract).
    static func decodeCanonical(_ data: Data) throws -> HouseholdCBORValue {
        let decoded: HouseholdCBORValue
        do {
            decoded = try HouseholdCBOR.decode(data)
        } catch {
            throw BootstrapError.protocolViolation(detail: .unexpectedResponseShape)
        }
        guard HouseholdCBOR.encode(decoded) == data else {
            throw BootstrapError.protocolViolation(detail: .unexpectedResponseShape)
        }
        return decoded
    }

    // Decode a CBOR error envelope into a BootstrapError.
    static func decodeError(_ data: Data) -> BootstrapError {
        let decoded: HouseholdCBORValue
        do {
            decoded = try HouseholdCBOR.decode(data)
        } catch {
            return .protocolViolation(detail: .malformedErrorBody)
        }
        guard case .map(let map) = decoded else {
            return .protocolViolation(detail: .malformedErrorBody)
        }
        guard case .unsigned(let v) = map["v"], v == 1 else {
            return .protocolViolation(detail: .unexpectedResponseShape)
        }
        guard case .text(let code) = map["error"] else {
            return .protocolViolation(detail: .missingRequiredField)
        }
        var message: String?
        if let msgVal = map["message"], case .text(let text) = msgVal {
            message = text
        }
        return .serverError(code: code, message: message)
    }

    // Send a request and return raw response body, throwing BootstrapError on failure.
    static func send(
        method: String,
        url: URL,
        body: Data?,
        authorization: String?,
        perform: @Sendable (URLRequest) async throws -> (Data, URLResponse)
    ) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = method
        if body != nil {
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        request.setValue(contentType, forHTTPHeaderField: "Accept")
        if let auth = authorization {
            request.setValue(auth, forHTTPHeaderField: "Authorization")
        }
        request.httpBody = body

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
        let ct = http.value(forHTTPHeaderField: "Content-Type")
        guard isCBORContentType(ct) else {
            throw BootstrapError.protocolViolation(detail: .wrongContentType(returned: ct))
        }
        guard (200..<300).contains(http.statusCode) else {
            throw decodeError(data)
        }
        return data
    }
}
