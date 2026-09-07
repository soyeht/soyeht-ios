import Foundation

/// The app installer, fetch and embed scripts consume the same packaged list.
/// The Rust producer is checked separately against this delivery contract.
public enum EmbeddedEngineHelpers {
    public static var names: [String] { manifest.executables }
    public static var artifactReceiptName: String { manifest.artifactReceipt }

    private struct Manifest: Decodable {
        let executables: [String]
        let artifactReceipt: String
    }

    private static let manifest: Manifest = {
        guard let url = Bundle.module.url(forResource: "embedded-engine-helpers", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let value = try? JSONDecoder().decode(Manifest.self, from: data),
              Set(value.executables).count == value.executables.count,
              value.executables.contains("theyos-engine"), value.executables.contains("soyeht-ptyd"),
              value.executables.allSatisfy({ $0.range(of: "^[a-z0-9][a-z0-9_-]*$", options: .regularExpression) != nil }),
              value.artifactReceipt.range(of: "^[a-z0-9][a-z0-9_-]*\\.json$", options: .regularExpression) != nil else {
            preconditionFailure("Invalid embedded engine helper manifest")
        }
        return value
    }()
}
