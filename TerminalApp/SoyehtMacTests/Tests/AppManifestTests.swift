import Foundation
import XCTest
@testable import SoyehtMacDomain

final class AppManifestTests: XCTestCase {
    private let valid = #"{"schemaVersion":1,"id":"notes-app","name":"Notes","version":"1.0","entry":"index.html","publisher":{"id":"acme","displayName":"Acme"},"capabilities":[],"optionalCapabilities":[]}"#

    // MARK: - Ajudantes contra verde-pelo-motivo-errado

    /// Deriva uma variante da fixture e **prova que derivou**, exigindo que a
    /// agulha case exatamente uma vez.
    ///
    /// Uma agulha que não casa não falha: `replacingOccurrences` devolve a
    /// fixture intacta e o teste segue a correr sobre a entrada original —
    /// verde sem exercer nada. Uma agulha que casa duas vezes muta mais do que
    /// o teste nomeia. Mesmo idioma que `WorkspaceStoreTests` já usava ao
    /// assertar o seu próprio envenenamento.
    private func variant(of source: String,
                         replacing needle: String,
                         with replacement: String,
                         file: StaticString = #filePath,
                         line: UInt = #line) -> String {
        let occurrences = source.components(separatedBy: needle).count - 1
        XCTAssertEqual(occurrences, 1,
                       "a agulha tinha de casar exatamente uma vez na fixture e casou \(occurrences): \(needle)",
                       file: file, line: line)
        return source.replacingOccurrences(of: needle, with: replacement)
    }

    /// Exige que o manifesto seja recusado **pelo motivo nomeado**, e antes
    /// disso prova que a fixture é JSON bem formado.
    ///
    /// Sem a prova de boa-formação, um erro de sintaxe na fixture satisfaz o
    /// `XCTAssertThrowsError` e a guarda que o teste diz cobrir nunca corre.
    private func assertRejected(_ json: String,
                                with expected: AppManifestError,
                                file: StaticString = #filePath,
                                line: UInt = #line) {
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(json.utf8)),
                         "a fixture não é JSON válido, logo a recusa não provaria a guarda",
                         file: file, line: line)
        XCTAssertThrowsError(try AppManifest.decode(Data(json.utf8)), file: file, line: line) { error in
            XCTAssertEqual(error as? AppManifestError, expected, file: file, line: line)
        }
    }

    // MARK: - Aceitação

    func testValidManifestIsAccepted() throws {
        XCTAssertEqual(try AppManifest.decode(Data(valid.utf8)).id, "notes-app")
    }

    func testKnownCapabilityIsAccepted() throws {
        let raw = variant(of: valid,
                          replacing: #""capabilities":[]"#,
                          with: #""capabilities":["metrics.read"]"#)
        XCTAssertEqual(try AppManifest.decode(Data(raw.utf8)).capabilities,
                       [AppCapability.metricsRead.rawValue])
    }

    // MARK: - Chaves desconhecidas

    func testUnknownManifestKeyIsRejected() {
        assertRejected(String(valid.dropLast()) + #","injected":true}"#,
                       with: .unknownKey("injected"))
    }

    func testUnknownPublisherKeyIsRejected() {
        let injected = #"{"schemaVersion":1,"id":"notes-app","name":"Notes","version":"1.0","entry":"index.html","publisher":{"id":"acme","displayName":"Acme","INJETADA":"bad"},"capabilities":[],"optionalCapabilities":[]}"#
        assertRejected(injected, with: .unknownKey("INJETADA"))
    }

    /// Uma chave válida no manifesto não passa a ser válida dentro do
    /// publisher: cada tipo compara contra o seu próprio vocabulário.
    func testParentKeyInjectedIntoPublisherIsRejected() {
        let injected = #"{"schemaVersion":1,"id":"notes-app","name":"Notes","version":"1.0","entry":"index.html","publisher":{"id":"acme","displayName":"Acme","entry":"bad"},"capabilities":[],"optionalCapabilities":[]}"#
        assertRejected(injected, with: .unknownKey("entry"))
    }

    // MARK: - Recusas de valor

    func testEntryContainingParentReferenceIsRejected() {
        assertRejected(variant(of: valid,
                               replacing: #""entry":"index.html""#,
                               with: #""entry":"../index.html""#),
                       with: .invalidEntry)
    }

    func testUnknownCapabilityIsRejected() {
        assertRejected(variant(of: valid,
                               replacing: #""capabilities":[]"#,
                               with: #""capabilities":["network.read"]"#),
                       with: .unknownCapability)
    }

    func testManifestOverMaximumSizeIsRejectedBeforeDecoding() {
        // Deliberadamente NÃO é JSON: o portão de tamanho tem de agir antes do
        // parser, então aqui a boa-formação não é pré-requisito — é o oposto.
        XCTAssertThrowsError(try AppManifest.decode(Data(repeating: 0x20,
                                                         count: AppManifest.maximumByteCount + 1))) { error in
            XCTAssertEqual(error as? AppManifestError, .fileTooLarge)
        }
    }
}
