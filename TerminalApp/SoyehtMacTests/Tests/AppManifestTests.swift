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

    // MARK: - Guardas que estavam MUDAS
    //
    // Medido antes de escrever estes testes: remover cada uma das quatro guardas
    // abaixo deixava os 694 testes do pacote VERDES. Estavam aplicadas
    // corretamente pelo produto e provadas por nada, o que num repositório sem
    // CI é onde a próxima regressão vive.

    func testUnsupportedSchemaVersionIsRejected() {
        assertRejected(variant(of: valid,
                               replacing: #""schemaVersion":1"#,
                               with: #""schemaVersion":2"#),
                       with: .unsupportedSchemaVersion)
    }

    /// `isValidIdentifier` tem DUAS sub-guardas, comprimento e alfabeto, e ambas
    /// devolvem o mesmo erro. Um teste só deixaria metade por provar.
    func testIdentifierOutsideAllowedAlphabetIsRejected() {
        assertRejected(variant(of: valid,
                               replacing: #""id":"notes-app""#,
                               with: #""id":"Notes-App""#),
                       with: .invalidIdentifier)
    }

    func testIdentifierBelowMinimumLengthIsRejected() {
        assertRejected(variant(of: valid,
                               replacing: #""id":"notes-app""#,
                               with: #""id":"ab""#),
                       with: .invalidIdentifier)
    }

    func testInvalidPublisherIdentifierIsRejected() {
        assertRejected(variant(of: valid,
                               replacing: #""id":"acme""#,
                               with: #""id":"ac""#),
                       with: .invalidPublisherID)
    }

    /// O valor declarado é uma capacidade **conhecida**: o que se prova é que o
    /// campo é recusado por existir, não por conter algo inválido.
    func testDeclaredOptionalCapabilitiesAreRejected() {
        assertRejected(variant(of: valid,
                               replacing: #""optionalCapabilities":[]"#,
                               with: #""optionalCapabilities":["metrics.read"]"#),
                       with: .capabilitiesNotAllowed)
    }

    // MARK: - Vocabulário e constantes fixados
    //
    // Sem isto, o teste de capacidade desconhecida prova apenas que UMA string
    // é recusada, e não que o vocabulário é fechado: acrescentar um caso novo ao
    // enum passava sem nenhum teste ficar vermelho.

    func testCapabilityVocabularyIsClosedToExactlyTheseValues() {
        XCTAssertEqual(Set(AppCapability.allCases.map(\.rawValue)), ["metrics.read"],
                       "o vocabulário de capacidades mudou; alargá-lo é mudança de contrato e precisa de decisão explícita, não de um caso novo no enum")
    }

    /// O teste do portão de tamanho usa `maximumByteCount + 1`, logo é
    /// auto-referencial: aumentar o limite mantinha-o verde. Fixar o valor faz a
    /// mudança do limite ficar visível.
    func testManifestSizeLimitIsPinned() {
        XCTAssertEqual(AppManifest.maximumByteCount, 64 * 1024)
    }

    // MARK: - Ordem das verificações
    //
    // Uma entrada que falha duas guardas tem de ser recusada pela PRIMEIRA. É a
    // ordem que impede que um refactor mova uma verificação para depois de outra
    // que já aceitou o valor.

    func testUnknownKeyIsRejectedBeforeAnyValueIsValidated() {
        let bothWrong = variant(of: String(valid.dropLast()) + #","injected":true}"#,
                                replacing: #""schemaVersion":1"#,
                                with: #""schemaVersion":2"#)
        assertRejected(bothWrong, with: .unknownKey("injected"))
    }

    /// Ordem NÃO óbvia, e é por isso que está fixada: o publisher é decodificado
    /// nos **argumentos** do inicializador, então a validação dele corre antes de
    /// qualquer `guard` do corpo. Mover essa decodificação para dentro do corpo
    /// inverteria isto sem quebrar mais nada.
    func testPublisherIsValidatedBeforeTheManifestBodyGuards() {
        let bothWrong = variant(of: variant(of: valid,
                                            replacing: #""id":"acme""#,
                                            with: #""id":"ac""#),
                                replacing: #""schemaVersion":1"#,
                                with: #""schemaVersion":2"#)
        assertRejected(bothWrong, with: .invalidPublisherID)
    }

    func testSchemaVersionIsCheckedBeforeTheIdentifier() {
        let bothWrong = variant(of: variant(of: valid,
                                            replacing: #""schemaVersion":1"#,
                                            with: #""schemaVersion":2"#),
                                replacing: #""id":"notes-app""#,
                                with: #""id":"Notes-App""#)
        assertRejected(bothWrong, with: .unsupportedSchemaVersion)
    }

    func testCapabilitiesAreValidatedBeforeOptionalCapabilitiesAreRefused() {
        let bothWrong = variant(of: variant(of: valid,
                                            replacing: #""capabilities":[]"#,
                                            with: #""capabilities":["network.read"]"#),
                                replacing: #""optionalCapabilities":[]"#,
                                with: #""optionalCapabilities":["metrics.read"]"#)
        assertRejected(bothWrong, with: .unknownCapability)
    }
}
