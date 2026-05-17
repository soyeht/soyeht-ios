import AppKit
import Foundation

struct EditorLoadedDocument {
    var text: String
    var encoding: String.Encoding
    var lineEnding: String
}

enum EditorDocumentError: LocalizedError {
    case fileTooLarge(Int64)
    case binaryFile
    case unreadable

    var errorDescription: String? {
        switch self {
        case .fileTooLarge:
            return "This file is too large to open in the native editor."
        case .binaryFile:
            return "This looks like a binary file."
        case .unreadable:
            return "The file could not be decoded as text."
        }
    }
}

final class EditorDocumentController {
    static let maxTextFileBytes: Int64 = 5 * 1024 * 1024

    static func load(fileURL: URL) throws -> EditorLoadedDocument {
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        guard size <= maxTextFileBytes else { throw EditorDocumentError.fileTooLarge(size) }

        let data = try Data(contentsOf: fileURL)
        guard !data.contains(0) else { throw EditorDocumentError.binaryFile }

        let candidates: [String.Encoding] = [.utf8, .utf16LittleEndian, .utf16BigEndian, .utf16]
        for encoding in candidates {
            if let text = String(data: data, encoding: encoding) {
                return EditorLoadedDocument(
                    text: text,
                    encoding: encoding,
                    lineEnding: text.contains("\r\n") ? "\r\n" : "\n"
                )
            }
        }
        throw EditorDocumentError.unreadable
    }

    static func save(text: String, to fileURL: URL, encoding: String.Encoding, lineEnding: String) throws {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\n", with: lineEnding)
        guard let data = normalized.data(using: encoding) ?? normalized.data(using: .utf8) else {
            throw EditorDocumentError.unreadable
        }
        try data.write(to: fileURL, options: .atomic)
    }
}
