import Foundation

/// Disk identity for the package's supported thin arm64 executable. This reads
/// Mach-O bytes directly; installation must not depend on Xcode/CLT shims.
/// The UUID is a link identifier, not a signature or integrity proof.
public enum EngineMachOIdentity {
    private static let commandLimit = 1_048_576

    public static func imageUUID(at url: URL) throws -> String? {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let header = try file.read(upToCount: 32) ?? Data()
        guard let bounds = bounds(header) else { return nil }
        let commands = try file.read(upToCount: bounds.size) ?? Data()
        return imageUUID(in: header + commands)
    }

    public static func imageUUID(in data: Data) -> String? {
        let bytes = Array(data)
        guard let bounds = bounds(Data(bytes.prefix(32))), bytes.count >= 32 + bounds.size else { return nil }
        var offset = 32
        let end = offset + bounds.size
        var found: String?
        for _ in 0..<bounds.count {
            guard offset + 8 <= end else { return nil }
            let command = word(bytes, offset)
            let length = Int(word(bytes, offset + 4))
            guard length >= 8, length % 8 == 0, length <= end - offset else { return nil }
            if command == 0x1b {
                guard length == 24, found == nil else { return nil }
                found = bytes[(offset + 8)..<(offset + 24)].map { String(format: "%02x", $0) }.joined()
            }
            offset += length
        }
        return offset == end ? found : nil
    }

    private static func bounds(_ header: Data) -> (count: Int, size: Int)? {
        let bytes = Array(header)
        guard bytes.count == 32, word(bytes, 0) == 0xfeedfacf,
              word(bytes, 4) == 0x0100000c, word(bytes, 12) == 2 else { return nil }
        let count = Int(word(bytes, 16))
        let size = Int(word(bytes, 20))
        guard size <= commandLimit, count <= size / 8 else { return nil }
        return (count, size)
    }

    private static func word(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8
            | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
    }
}
