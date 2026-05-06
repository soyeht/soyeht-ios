import Foundation

public enum HouseholdCBORError: Error, Equatable {
    case invalidData
    case unsupportedAdditionalInfo(UInt8)
    case unsupportedMajorType(UInt8)
    case nonTextMapKey
    case trailingBytes
}

public enum HouseholdCBORValue: Equatable, Sendable {
    case unsigned(UInt64)
    case negative(Int64)
    case bytes(Data)
    case text(String)
    case array([HouseholdCBORValue])
    case map([String: HouseholdCBORValue])
    case bool(Bool)
    case null
}

public enum HouseholdCBOR {
    public static func pairingProofContext(
        householdId: String,
        nonce: Data,
        personPublicKey: Data
    ) -> Data {
        encode(.map([
            "hh_id": .text(householdId),
            "nonce": .bytes(nonce),
            "p_pub": .bytes(personPublicKey),
            "purpose": .text("pair-device-confirm"),
            "v": .unsigned(1),
        ]))
    }

    public static func requestSigningContext(
        method: String,
        pathAndQuery: String,
        timestamp: UInt64,
        bodyHash: Data
    ) -> Data {
        encode(.map([
            "body_hash": .bytes(bodyHash),
            "method": .text(method.uppercased()),
            "path_and_query": .text(pathAndQuery),
            "timestamp": .unsigned(timestamp),
            "v": .unsigned(1),
        ]))
    }

    public static func encode(_ value: HouseholdCBORValue) -> Data {
        var data = Data()
        append(value, to: &data)
        return data
    }

    public static func decode(_ data: Data) throws -> HouseholdCBORValue {
        var parser = Parser(data: data)
        let value = try parser.parseValue()
        guard parser.isAtEnd else { throw HouseholdCBORError.trailingBytes }
        return value
    }

    public static func canonicalMapWithoutKey(_ data: Data, removing key: String) throws -> Data {
        guard case .map(var map) = try decode(data) else {
            throw HouseholdCBORError.invalidData
        }
        map.removeValue(forKey: key)
        return encode(.map(map))
    }

    private static func append(_ value: HouseholdCBORValue, to data: inout Data) {
        switch value {
        case .unsigned(let value):
            appendType(major: 0, value: value, to: &data)
        case .negative(let value):
            appendType(major: 1, value: UInt64(-1 - value), to: &data)
        case .bytes(let bytes):
            appendType(major: 2, value: UInt64(bytes.count), to: &data)
            data.append(bytes)
        case .text(let text):
            let bytes = Data(text.utf8)
            appendType(major: 3, value: UInt64(bytes.count), to: &data)
            data.append(bytes)
        case .array(let values):
            appendType(major: 4, value: UInt64(values.count), to: &data)
            values.forEach { append($0, to: &data) }
        case .map(let map):
            let sorted = map.map { (key: $0.key, value: $0.value) }.sorted { lhs, rhs in
                encode(.text(lhs.key)).lexicographicallyPrecedes(encode(.text(rhs.key)))
            }
            appendType(major: 5, value: UInt64(sorted.count), to: &data)
            for (key, value) in sorted {
                append(.text(key), to: &data)
                append(value, to: &data)
            }
        case .bool(let value):
            data.append(value ? 0xF5 : 0xF4)
        case .null:
            data.append(0xF6)
        }
    }

    private static func appendType(major: UInt8, value: UInt64, to data: inout Data) {
        let prefix = major << 5
        if value < 24 {
            data.append(prefix | UInt8(value))
        } else if value <= UInt64(UInt8.max) {
            data.append(prefix | 24)
            data.append(UInt8(value))
        } else if value <= UInt64(UInt16.max) {
            data.append(prefix | 25)
            data.append(UInt8((value >> 8) & 0xFF))
            data.append(UInt8(value & 0xFF))
        } else if value <= UInt64(UInt32.max) {
            data.append(prefix | 26)
            for shift in stride(from: 24, through: 0, by: -8) {
                data.append(UInt8((value >> UInt64(shift)) & 0xFF))
            }
        } else {
            data.append(prefix | 27)
            for shift in stride(from: 56, through: 0, by: -8) {
                data.append(UInt8((value >> UInt64(shift)) & 0xFF))
            }
        }
    }

    private struct Parser {
        let data: Data
        var index = 0
        var isAtEnd: Bool { index == data.count }

        mutating func parseValue() throws -> HouseholdCBORValue {
            let initial = try readByte()
            let major = initial >> 5
            let additional = initial & 0x1F
            switch major {
            case 0:
                return .unsigned(try readArgument(additional))
            case 1:
                let argument = try readArgument(additional)
                return .negative(-1 - Int64(argument))
            case 2:
                let length = Int(try readArgument(additional))
                return .bytes(try readData(count: length))
            case 3:
                let length = Int(try readArgument(additional))
                guard let text = String(data: try readData(count: length), encoding: .utf8) else {
                    throw HouseholdCBORError.invalidData
                }
                return .text(text)
            case 4:
                let count = Int(try readArgument(additional))
                var values: [HouseholdCBORValue] = []
                values.reserveCapacity(count)
                for _ in 0..<count {
                    values.append(try parseValue())
                }
                return .array(values)
            case 5:
                let count = Int(try readArgument(additional))
                var map: [String: HouseholdCBORValue] = [:]
                for _ in 0..<count {
                    guard case .text(let key) = try parseValue() else {
                        throw HouseholdCBORError.nonTextMapKey
                    }
                    map[key] = try parseValue()
                }
                return .map(map)
            case 7:
                switch additional {
                case 20: return .bool(false)
                case 21: return .bool(true)
                case 22: return .null
                default: throw HouseholdCBORError.unsupportedAdditionalInfo(additional)
                }
            default:
                throw HouseholdCBORError.unsupportedMajorType(major)
            }
        }

        mutating func readArgument(_ additional: UInt8) throws -> UInt64 {
            switch additional {
            case 0..<24:
                return UInt64(additional)
            case 24:
                return UInt64(try readByte())
            case 25:
                return UInt64(try readUInt(byteCount: 2))
            case 26:
                return UInt64(try readUInt(byteCount: 4))
            case 27:
                return try readUInt(byteCount: 8)
            default:
                throw HouseholdCBORError.unsupportedAdditionalInfo(additional)
            }
        }

        mutating func readByte() throws -> UInt8 {
            guard index < data.count else { throw HouseholdCBORError.invalidData }
            defer { index += 1 }
            return data[index]
        }

        mutating func readUInt(byteCount: Int) throws -> UInt64 {
            let bytes = try readData(count: byteCount)
            return bytes.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        }

        mutating func readData(count: Int) throws -> Data {
            guard count >= 0, index + count <= data.count else {
                throw HouseholdCBORError.invalidData
            }
            defer { index += count }
            return data[index..<index + count]
        }
    }
}
