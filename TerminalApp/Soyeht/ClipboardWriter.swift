import Foundation
import UIKit
import os

protocol ClipboardWriting: Sendable {
    func writeString(_ value: String)
}

struct UIPasteboardClipboard: ClipboardWriting {
    func writeString(_ value: String) {
        UIPasteboard.general.string = value
    }
}

enum ClipboardWriter {
    static func write(_ content: Data,
                      logger: Logger,
                      backend: ClipboardWriting = UIPasteboardClipboard()) {
        guard let string = String(data: content, encoding: .utf8) else {
            logger.error("[Clipboard] Ignored remote clipboard payload with invalid UTF-8 (\(content.count) bytes)")
            return
        }

        logger.debug("[Clipboard] Received remote clipboard payload (\(content.count) bytes, \(string.count) chars)")
        DispatchQueue.main.async {
            backend.writeString(string)
            logger.debug("[Clipboard] Wrote remote clipboard payload to UIPasteboard")
        }
    }
}
