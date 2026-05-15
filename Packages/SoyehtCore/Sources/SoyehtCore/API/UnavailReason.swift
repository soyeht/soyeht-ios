import Foundation

// Tagged enum with discriminator `type`. Manual Codable.
public enum UnavailReason: Codable, Equatable, Hashable, Sendable {
    case unknownType
    case notInstalled
    case installInProgress(percent: Int)
    case installFailed(error: String)
    case noColdPathAvailable
    case maintenanceMode(retryAfterSecs: Int)

    private enum CodingKeys: String, CodingKey { case type, percent, error, retryAfterSecs }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let tag = try c.decode(String.self, forKey: .type)
        switch tag {
        case "unknown_type":           self = .unknownType
        case "not_installed":          self = .notInstalled
        case "install_in_progress":    self = .installInProgress(percent: try c.decodeIfPresent(Int.self, forKey: .percent) ?? 0)
        case "install_failed":         self = .installFailed(error: try c.decodeIfPresent(String.self, forKey: .error) ?? "unknown")
        case "no_cold_path_available": self = .noColdPathAvailable
        case "maintenance_mode":       self = .maintenanceMode(retryAfterSecs: try c.decodeIfPresent(Int.self, forKey: .retryAfterSecs) ?? 30)
        default:                       self = .unknownType
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .unknownType:              try c.encode("unknown_type",           forKey: .type)
        case .notInstalled:             try c.encode("not_installed",          forKey: .type)
        case .installInProgress(let p): try c.encode("install_in_progress",    forKey: .type); try c.encode(p, forKey: .percent)
        case .installFailed(let e):     try c.encode("install_failed",         forKey: .type); try c.encode(e, forKey: .error)
        case .noColdPathAvailable:      try c.encode("no_cold_path_available", forKey: .type)
        case .maintenanceMode(let r):   try c.encode("maintenance_mode",       forKey: .type); try c.encode(r, forKey: .retryAfterSecs)
        }
    }

    /// Testable overload that resolves `displayMessage` in an explicit locale. Backwards
    /// compatible — production callers continue using the `displayMessage` property which
    /// uses the current locale implicitly. Only tests and diagnostic code should pass a
    /// specific locale.
    ///
    /// Implementation note: `LocalizedStringResource.locale` is a *hint* — on macOS the
    /// Foundation loader falls back to `.current` if the hinted lproj isn't the currently-
    /// resolved one. So this method loads the locale-specific `.lproj` sub-bundle directly
    /// via `Bundle.module` and does the `localizedString(forKey:value:table:)` lookup there.
    public func resolvedDisplayMessage(locale: Locale) -> String {
        let bundle = Self.localeBundle(for: locale)
        switch self {
        case .unknownType:
            return bundle.localizedString(forKey: "unavail.unknownType", value: "unknownType", table: nil)
        case .notInstalled:
            return bundle.localizedString(forKey: "unavail.notInstalled", value: "notInstalled", table: nil)
        case .installInProgress(let p):
            let fmt = bundle.localizedString(forKey: "unavail.installInProgress", value: "installing (%lld%%)", table: nil)
            return String(format: fmt, p)
        case .installFailed(let e):
            let fmt = bundle.localizedString(forKey: "unavail.installFailed", value: "install failed: %@", table: nil)
            return String(format: fmt, e)
        case .noColdPathAvailable:
            return bundle.localizedString(forKey: "unavail.noColdPathAvailable", value: "noColdPathAvailable", table: nil)
        case .maintenanceMode(let r):
            let fmt = bundle.localizedString(forKey: "unavail.maintenanceMode", value: "maintenance (retry in %lld s)", table: nil)
            return String(format: fmt, r)
        }
    }

    /// Resolves the SoyehtCore `.lproj` sub-bundle for `locale`, falling back to the base
    /// language if the full identifier (e.g. `pt-BR`) isn't present, and to `Bundle.module`
    /// if neither resolves.
    private static func localeBundle(for locale: Locale) -> Bundle {
        let module = Bundle.module
        let candidates: [String] = [
            locale.identifier,
            locale.identifier.replacingOccurrences(of: "_", with: "-"),
            locale.language.languageCode?.identifier,
        ].compactMap { $0 }
        for id in candidates {
            if let url = module.url(forResource: id, withExtension: "lproj"),
               let b = Bundle(url: url) {
                return b
            }
        }
        return module
    }

    public var displayMessage: LocalizedStringResource {
        switch self {
        case .unknownType:
            return LocalizedStringResource(
                "unavail.unknownType",
                bundle: .atURL(Bundle.module.bundleURL),
                comment: "Shown in the Claw detail when the server returned an unrecognized claw type tag."
            )
        case .notInstalled:
            return LocalizedStringResource(
                "unavail.notInstalled",
                bundle: .atURL(Bundle.module.bundleURL),
                comment: "Shown when a claw is not installed on the active server."
            )
        case .installInProgress(let p):
            return LocalizedStringResource(
                "unavail.installInProgress",
                defaultValue: "installing (\(p)%)",
                bundle: .atURL(Bundle.module.bundleURL),
                comment: "Claw install in progress. %lld = percent complete (0-100)."
            )
        case .installFailed(let e):
            return LocalizedStringResource(
                "unavail.installFailed",
                defaultValue: "install failed: \(e)",
                bundle: .atURL(Bundle.module.bundleURL),
                comment: "Claw install failed. %@ = raw server error (already a human-readable string; may not be translatable)."
            )
        case .noColdPathAvailable:
            return LocalizedStringResource(
                "unavail.noColdPathAvailable",
                bundle: .atURL(Bundle.module.bundleURL),
                comment: "Server has no capacity available for this claw."
            )
        case .maintenanceMode(let r):
            return LocalizedStringResource(
                "unavail.maintenanceMode",
                defaultValue: "maintenance (retry in \(r)s)",
                bundle: .atURL(Bundle.module.bundleURL),
                comment: "Claw is under maintenance. %lld = seconds until retry."
            )
        }
    }
}
