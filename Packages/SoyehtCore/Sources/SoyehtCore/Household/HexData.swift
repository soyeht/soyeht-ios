import Foundation

extension Data {
    init?(soyehtHex string: String) {
        guard string.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(string.count / 2)
        var index = string.startIndex
        for _ in 0..<(string.count / 2) {
            let next = string.index(index, offsetBy: 2)
            guard let byte = UInt8(string[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self = Data(bytes)
    }

    func soyehtHexEncodedString() -> String {
        map { String(format: "%02x", $0) }.joined()
    }
}
