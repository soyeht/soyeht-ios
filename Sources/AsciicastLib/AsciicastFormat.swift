import Foundation

public struct AsciicastHeader: Codable {
    public let version: Int
    public let width: Int
    public let height: Int
    public let timestamp: TimeInterval
    public let command: String?
    public let title: String?
    public let env: [String: String]?

    public init(version: Int, width: Int, height: Int, timestamp: TimeInterval,
                command: String? = nil, title: String? = nil, env: [String: String]? = nil) {
        self.version = version
        self.width = width
        self.height = height
        self.timestamp = timestamp
        self.command = command
        self.title = title
        self.env = env
    }
}

public enum AsciicastEventType: String, Codable {
    case output = "o"
    case input = "i"
    case resize = "r"
    case marker = "m"
}

public struct AsciicastEvent: Codable {
    public let time: TimeInterval
    public let eventType: AsciicastEventType
    public let eventData: String

    public init(time: TimeInterval, eventType: AsciicastEventType, eventData: String) {
        self.time = time
        self.eventType = eventType
        self.eventData = eventData
    }

    public init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        self.time = try container.decode(TimeInterval.self)
        self.eventType = try container.decode(AsciicastEventType.self)
        self.eventData = try container.decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.unkeyedContainer()
        try container.encode(time)
        try container.encode(eventType)
        try container.encode(eventData)
    }
}
