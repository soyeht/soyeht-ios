import Foundation
import SoyehtCore

enum PairMachineStageTransport: String, Sendable, Equatable {
    case tailscale
    case lan
}

struct PairMachineStageResult: Sendable, Equatable {
    let pairMachineURI: URL
    let fingerprint: String
    let ttlUnix: UInt64
    let transportUsed: PairMachineStageTransport
    let fellBackFromTailscale: Bool
}

enum DaemonPairMachineStageError: Error, Equatable, Sendable {
    case endpointUnavailable
    case noTransportAddress(PairMachineStageTransport)
    case alreadyPaired(state: String?)
    case daemonError(code: String, message: String?)
    case invalidResponse
}

struct DaemonPairMachineStageClient: Sendable {
    typealias TransportPerform = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    static let path = "/bootstrap/pair-machine/local/stage"

    private let baseURL: URL
    private let perform: TransportPerform
    private let now: @Sendable () -> Date

    init(
        baseURL: URL = TheyOSEnvironment.bootstrapBaseURL,
        transport: @escaping TransportPerform = { req in try await URLSession.shared.data(for: req) },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.baseURL = baseURL
        self.perform = transport
        self.now = now
    }

    func stage() async throws -> PairMachineStageResult {
        do {
            return try await stage(transport: .tailscale, fellBackFromTailscale: false)
        } catch DaemonPairMachineStageError.noTransportAddress(.tailscale) {
            return try await stage(transport: .lan, fellBackFromTailscale: true)
        }
    }

    func stage(transport: PairMachineStageTransport) async throws -> PairMachineStageResult {
        try await stage(transport: transport, fellBackFromTailscale: false)
    }

    private func stage(
        transport: PairMachineStageTransport,
        fellBackFromTailscale: Bool
    ) async throws -> PairMachineStageResult {
        let url = Self.endpointURL(baseURL: baseURL)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/cbor", forHTTPHeaderField: "Accept")
        request.httpBody = try Self.encodeRequest(transport: transport)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await perform(request)
        } catch let error as DaemonPairMachineStageError {
            throw error
        } catch {
            throw DaemonPairMachineStageError.endpointUnavailable
        }

        guard let http = response as? HTTPURLResponse else {
            throw DaemonPairMachineStageError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw Self.decodeError(data, attemptedTransport: transport, statusCode: http.statusCode)
        }
        guard Self.isCBORContentType(http.value(forHTTPHeaderField: "Content-Type")) else {
            throw DaemonPairMachineStageError.invalidResponse
        }

        return try Self.decodeStageResult(
            data,
            transportUsed: transport,
            fellBackFromTailscale: fellBackFromTailscale,
            now: now()
        )
    }

    private static func endpointURL(baseURL: URL) -> URL {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        let basePath = components.percentEncodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.percentEncodedPath = basePath.isEmpty ? path : "/\(basePath)\(path)"
        components.percentEncodedQuery = nil
        components.fragment = nil
        return components.url!
    }

    private static func encodeRequest(transport: PairMachineStageTransport) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "v": 1,
            "transport": transport.rawValue,
        ])
    }

    private static func isCBORContentType(_ value: String?) -> Bool {
        value?
            .split(separator: ";")
            .first
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() } == "application/cbor"
    }

    private static func decodeStageResult(
        _ data: Data,
        transportUsed: PairMachineStageTransport,
        fellBackFromTailscale: Bool,
        now: Date
    ) throws -> PairMachineStageResult {
        guard case .map(let map) = try? HouseholdCBOR.decode(data),
              case .text(let uriRaw) = map["pair_machine_uri"],
              case .text(let fingerprint) = map["fingerprint"],
              case .unsigned(let ttlUnix) = map["ttl_unix"],
              let uri = URL(string: uriRaw) else {
            throw DaemonPairMachineStageError.invalidResponse
        }

        _ = try PairMachineQR(url: uri, now: now)
        return PairMachineStageResult(
            pairMachineURI: uri,
            fingerprint: fingerprint,
            ttlUnix: ttlUnix,
            transportUsed: transportUsed,
            fellBackFromTailscale: fellBackFromTailscale
        )
    }

    private static func decodeError(
        _ data: Data,
        attemptedTransport: PairMachineStageTransport,
        statusCode: Int
    ) -> DaemonPairMachineStageError {
        if statusCode == 404 {
            return .endpointUnavailable
        }
        guard case .map(let map) = try? HouseholdCBOR.decode(data),
              case .text(let code) = map["error"] else {
            return .invalidResponse
        }

        let message = textValue(map["message"]) ?? textValue(map["reason"])
        switch code {
        case "no_transport_address":
            return .noTransportAddress(parseTransport(textValue(map["transport"])) ?? attemptedTransport)
        case "household_already_paired":
            return .alreadyPaired(state: textValue(map["state"]))
        default:
            return .daemonError(code: code, message: message)
        }
    }

    private static func textValue(_ value: HouseholdCBORValue?) -> String? {
        guard case .text(let text) = value else { return nil }
        return text
    }

    private static func parseTransport(_ raw: String?) -> PairMachineStageTransport? {
        guard let normalized = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else {
            return nil
        }
        if normalized.contains("tail") { return .tailscale }
        if normalized.contains("lan") { return .lan }
        return PairMachineStageTransport(rawValue: normalized)
    }
}
