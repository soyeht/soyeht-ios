import Foundation

/// Extends `BannedVocabularyAuditor` to also flag error-voice and presentation
/// phrases per research R17 / FR-119.
///
/// Banned error-voice terms (case-insensitive):
///   erro, falha, inválido, rejeitado, aguarde, carregando, processando,
///   problema, sucesso, concluído
///
/// These terms should never appear verbatim in user-visible strings; preferred
/// substitutes are listed in `CopyVoiceAuditor.substitutes`.
public struct CopyVoiceAuditor: Sendable {
    /// Terms banned in error-voice copy (FR-119 + research R17).
    public static let errorVoiceTerms: [String] = [
        "erro",
        "falha",
        "inválido",
        "invalido",
        "rejeitado",
        "aguarde",
        "carregando",
        "processando",
        "problema",
        "sucesso",
        "concluído",
        "concluido",
    ]

    /// Preferred substitutes for the banned error-voice terms (for documentation / CI reporting).
    public static let substitutes: [String: String] = [
        "erro": "Algo aconteceu / Não consegui",
        "falha": "Não funcionou desta vez",
        "inválido": "Não reconheci esse formato",
        "rejeitado": "Não pude confirmar",
        "aguarde": "Estou preparando...",
        "carregando": "Estou trabalhando / Buscando...",
        "processando": "(use verbo específico: Verificando, Acordando, Salvando)",
        "problema": "Algo aconteceu",
        "sucesso": "Pronto / Tudo certo",
        "concluído": "Sua casa está viva",
    ]

    private let underlying: BannedVocabularyAuditor

    public init() {
        underlying = BannedVocabularyAuditor(additionalTerms: Self.errorVoiceTerms)
    }

    /// Audits a single `.xcstrings` file for both FR-001 and FR-119 violations.
    public func audit(fileURL: URL) throws -> [BannedVocabularyViolation] {
        try underlying.audit(fileURL: fileURL)
    }

    /// Audits raw `.xcstrings` JSON data.
    public func audit(data: Data, filePath: String) throws -> [BannedVocabularyViolation] {
        try underlying.audit(data: data, filePath: filePath)
    }

    /// Audits multiple files; aggregates all violations.
    public func auditAll(fileURLs: [URL]) throws -> [BannedVocabularyViolation] {
        try underlying.auditAll(fileURLs: fileURLs)
    }
}
