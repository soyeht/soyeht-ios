import Foundation
import os

/// Pure parsing helpers for the Soyeht WebSocket terminal protocol,
/// shared by Soyeht (iOS) and SoyehtMac WebSocket terminal views so
/// the wire format does not drift independently between platforms.
public enum TerminalProtocolCodec {
    private static let logger = Logger(subsystem: "com.soyeht.core", category: "protocol")

    /// Matches protocol control tokens emitted as bare lines on text
    /// frames: `guide`, `resync_done`, `resync-docs`, `snapshot_done`,
    /// and any `resync[_-]*` variant.
    ///
    /// Built lazily and stored as `nil` if compilation ever fails so
    /// the apps degrade to a no-op stripper instead of crashing at
    /// module load — replaces the previous `try!` initializer.
    public static let protocolControlLineRegex: NSRegularExpression? = {
        let pattern = #"(?m)^[ \t]*(?:guide|resync_done|resync-docs|snapshot_done|resync[_-][^\r\n]*)[ \t]*\r?\n?"#
        do {
            return try NSRegularExpression(pattern: pattern)
        } catch {
            logger.error("[Codec] Failed to compile protocolControlLineRegex: \(error.localizedDescription, privacy: .public) — falling through without stripping")
            return nil
        }
    }()

    private static let controlFramePrefix: Data = {
        let magic: [UInt8] = [0x00, 0x01]
        return Data(magic) + Data("CTL:".utf8)
    }()

    /// If `data` is a structured backend control frame
    /// (`\x00\x01CTL:<content>`), returns the content (everything after
    /// the `CTL:` prefix). Returns `nil` for terminal output frames.
    public static func decodeControlFrame(_ data: Data) -> String? {
        guard data.count > controlFramePrefix.count,
              data.starts(with: controlFramePrefix) else { return nil }
        return String(data: data.dropFirst(controlFramePrefix.count), encoding: .utf8)
    }

    /// Extracts the marker name from a control frame payload — the
    /// substring before the first `:`, or the whole payload when no
    /// arguments are present.
    public static func controlMarkerName(from content: String) -> String {
        content.split(separator: ":", maxSplits: 1).first.map(String.init) ?? content
    }

    /// Strips bare protocol control lines from `text` and returns the
    /// cleaned string, or `nil` if the entire payload was protocol
    /// noise (or empty after stripping). Returns the original text
    /// unchanged when it isn't a protocol-control candidate.
    public static func sanitizeProtocolText(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return text }

        if shouldSuppressProtocolText(trimmed) {
            return nil
        }

        guard let regex = protocolControlLineRegex else { return text }

        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let stripped = regex.stringByReplacingMatches(
            in: text,
            options: [],
            range: range,
            withTemplate: ""
        )

        return stripped.isEmpty ? nil : stripped
    }

    /// Returns `true` when `text` is a bare protocol control token that
    /// must not be fed into the terminal view.
    public static func shouldSuppressProtocolText(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        if trimmed == "guide" || trimmed == "resync_done" || trimmed == "resync-docs"
            || trimmed == "snapshot_done" || trimmed == "snapshot_start" {
            return true
        }

        if trimmed.hasPrefix("resync_") || trimmed.hasPrefix("resync-") || trimmed.hasPrefix("snapshot_") {
            return true
        }

        return false
    }
}
