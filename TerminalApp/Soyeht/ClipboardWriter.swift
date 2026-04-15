import Foundation
import UIKit
import os

protocol ClipboardWriting: Sendable {
    var requiresMainThread: Bool { get }
    func writeString(_ value: String)
}

struct UIPasteboardClipboard: ClipboardWriting {
    let requiresMainThread = true

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
        let write = {
            backend.writeString(string)
            logger.debug("[Clipboard] Wrote remote clipboard payload to UIPasteboard")
        }

        if backend.requiresMainThread && !Thread.isMainThread {
            DispatchQueue.main.async(execute: write)
        } else {
            write()
        }
    }
}
