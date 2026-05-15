import Foundation

/// Public accessor for SoyehtCore's resource bundle.
///
/// Consumers (tests, app targets) need this to resolve keys from the
/// SoyehtCore `Localizable.xcstrings` at runtime — `Bundle.module` is
/// synthesised with internal access by SPM, so a public wrapper is
/// the only way to exercise the bundle wiring from outside the package.
///
/// Used by `SoyehtTests/I18nSmokeTests` to verify that the `.process`
/// directive in `Package.swift` is actually shipping the catalog in every
/// `lproj` — a failure mode the JSON-level coverage test cannot detect.
public enum SoyehtCoreResources {
    public static var bundle: Bundle { .module }
}
