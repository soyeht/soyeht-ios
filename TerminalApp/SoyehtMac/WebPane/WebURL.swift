import Foundation

enum WebURLError: Error, LocalizedError {
    case malformed(String)
    case unsupportedScheme(String)
    case missingHost(String)
    case credentialsInURL(String)

    var errorDescription: String? {
        switch self {
        case .malformed(let raw):
            return "Invalid web URL: \(raw)"
        case .unsupportedScheme(let scheme):
            return "Unsupported web URL scheme: \(scheme)"
        case .missingHost(let raw):
            return "Web URL requires a host: \(raw)"
        case .credentialsInURL(let raw):
            return "Web URL must not include credentials: \(raw)"
        }
    }
}

enum WebURL {
    private static let bareHostExpression = try! NSRegularExpression(pattern: #"^(?:(?:localhost)|(?:\d{1,3}(?:\.\d{1,3}){3})|(?:\[[0-9A-Fa-f:.]+\])|(?:(?:[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z0-9][A-Za-z0-9-]*))(?:\:[0-9]{1,5})?(?:[/?#][^\s]*)?$"#)

    /// Normalizes a human-entered bare host before it reaches `validate`.
    /// This is intentionally narrower than URL parsing: only a conventional
    /// domain, localhost, or IPv4/IPv6 literal (with an optional numeric
    /// port) receives an HTTPS prefix. Scheme-like strings therefore cannot
    /// turn into an alternative entry point around the fail-closed validator.
    static func normalizeUserInput(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }

        if let scheme = URLComponents(string: trimmed)?.scheme?.lowercased(),
           scheme == "http" || scheme == "https" {
            return trimmed
        }

        return isBareHostInput(trimmed) ? "https://\(trimmed)" : trimmed
    }

    /// The single fail-closed entry point for URLs loaded by a web pane.
    static func validate(_ raw: String) throws -> URL {
        guard !raw.isEmpty,
              let components = URLComponents(string: raw),
              let scheme = components.scheme else {
            throw WebURLError.malformed(raw)
        }

        guard scheme.caseInsensitiveCompare("http") == .orderedSame
                || scheme.caseInsensitiveCompare("https") == .orderedSame else {
            throw WebURLError.unsupportedScheme(scheme)
        }

        guard let host = components.host, !host.isEmpty else {
            throw WebURLError.missingHost(raw)
        }

        guard components.user == nil, components.password == nil else {
            throw WebURLError.credentialsInURL(raw)
        }

        var normalized = components
        normalized.scheme = scheme.lowercased()
        normalized.host = host.lowercased()
        guard let url = normalized.url else {
            throw WebURLError.malformed(raw)
        }
        return url
    }

    /// Produces the stable identity used for web-pane deduplication. Callers
    /// must validate untrusted input before using it to construct state.
    static func canonical(_ raw: String) -> String {
        guard var components = URLComponents(string: raw),
              let scheme = components.scheme,
              let host = components.host else {
            return raw
        }

        components.scheme = scheme.lowercased()
        components.host = host.lowercased()
        components.fragment = nil

        // Only the origin spelling has an equivalent empty-path form. A
        // trailing slash on any other path can identify a distinct resource.
        if components.percentEncodedPath == "/" {
            components.percentEncodedPath = ""
        }

        if let port = components.port,
           (components.scheme == "http" && port == 80)
                || (components.scheme == "https" && port == 443) {
            components.port = nil
        }

        return components.string ?? raw
    }

    private static func isBareHostInput(_ raw: String) -> Bool {
        // Match only complete input. The final component admits an optional
        // path, query, or fragment, while the authority remains a hostname
        // shape rather than an arbitrary URI scheme.
        let range = NSRange(raw.startIndex..., in: raw)
        return bareHostExpression.firstMatch(in: raw, range: range) != nil
    }
}
