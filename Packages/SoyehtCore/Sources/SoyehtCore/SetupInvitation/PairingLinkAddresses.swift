import Foundation

/// Carries the complete listener offer through QR/link transport. The legacy
/// endpoint is a presentation hint; the phone always ranks the embedded offer.
public enum PairingLinkAddresses {
    private static let field = "address_offer"

    public static func offer(in url: URL) throws -> PairingAddressOffer? {
        let fields = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .filter { $0.name == field } ?? []
        guard !fields.isEmpty else { return nil }
        guard fields.count == 1, let value = fields.first?.value, value.utf8.count <= 32_768 else {
            throw PairingAddressError.invalidEndpoint
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try decoder.decode(PairingAddressOffer.self, from: Data(soyehtBase64URL: value))
    }

    public static func attaching(_ offer: PairingAddressOffer, to url: URL) throws -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw PairingAddressError.invalidEndpoint
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .secondsSince1970
        let encoded = try encoder.encode(offer).soyehtBase64URLEncodedString()
        guard encoded.utf8.count <= 32_768 else { throw PairingAddressError.invalidEndpoint }
        var items = components.queryItems?.filter { $0.name != field } ?? []
        items.append(URLQueryItem(name: field, value: encoded))
        components.queryItems = items
        guard let result = components.url else { throw PairingAddressError.invalidEndpoint }
        return result
    }
}
