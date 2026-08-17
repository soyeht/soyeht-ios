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
    /// The single fail-closed entry point for URLs loaded by a web pane.
    static func validate(_ raw: String) throws -> URL {
        guard !raw.isEmpty,
              let components = URLComponents(string: raw),
              let url = components.url,
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
}
