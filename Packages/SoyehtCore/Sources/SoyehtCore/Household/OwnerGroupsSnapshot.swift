import Foundation

/// The owner's group/membership snapshot for the person-first SHARED APPS
/// display — mirrors the planned read endpoint
/// `GET /api/v1/claw-share/groups` (owner-PoP), derived from the engine's
/// `ProjectedState`. Decoded from canonical CBOR.
///
/// The live GET endpoint is a server slice (tracked for @vivian); this is the
/// iOS read model + decoder, defined against the agreed wire shape and
/// lab-testable now. When the endpoint lands, an HTTP reader decodes its body
/// straight into this model (byte-tight via the shared shape).
public struct OwnerGroupsSnapshot: Equatable, Sendable {
    public var groups: [OwnerGroup]
    public var publishedClaws: [String]

    public init(groups: [OwnerGroup], publishedClaws: [String]) {
        self.groups = groups
        self.publishedClaws = publishedClaws
    }
}

/// One named group the owner has (e.g. "Family" = você + Dani) with its members
/// and the claws granted to it.
public struct OwnerGroup: Equatable, Sendable {
    public var groupID: String
    public var name: String
    public var members: [OwnerGroupMember]
    public var grantedClaws: [String]

    public init(groupID: String, name: String, members: [OwnerGroupMember], grantedClaws: [String]) {
        self.groupID = groupID
        self.name = name
        self.members = members
        self.grantedClaws = grantedClaws
    }
}

/// A person in a group — `label` is the owner-chosen display name ("Dani");
/// `deviceCount` is how many of their devices are currently enrolled+active
/// (feeds the "live" affordance once paired with the live-session source).
public struct OwnerGroupMember: Equatable, Sendable {
    public var memberID: String
    public var label: String
    public var deviceCount: UInt64

    public init(memberID: String, label: String, deviceCount: UInt64) {
        self.memberID = memberID
        self.label = label
        self.deviceCount = deviceCount
    }
}

public enum OwnerGroupsDecodeError: Error, Equatable {
    case notMap
    case unsupportedVersion
    case missingField(String)
    case wrongType(String)
}

/// Decodes the `GET /api/v1/claw-share/groups` canonical-CBOR body into
/// `OwnerGroupsSnapshot`. Strict on shape: rejects a wrong/missing version and
/// any field of the wrong CBOR type, so a contract drift surfaces loudly.
public enum OwnerGroupsDecoder {
    public static func decode(_ data: Data) throws -> OwnerGroupsSnapshot {
        guard case let .map(top) = try HouseholdCBOR.decode(data) else {
            throw OwnerGroupsDecodeError.notMap
        }
        guard case .unsigned(1)? = top["v"] else {
            throw OwnerGroupsDecodeError.unsupportedVersion
        }
        let groups = try array(top, "groups").map(decodeGroup)
        let published = try textArray(top, "published_claws")
        return OwnerGroupsSnapshot(groups: groups, publishedClaws: published)
    }

    private static func decodeGroup(_ value: HouseholdCBORValue) throws -> OwnerGroup {
        guard case let .map(map) = value else { throw OwnerGroupsDecodeError.wrongType("group") }
        return OwnerGroup(
            groupID: try text(map, "group_id"),
            name: try text(map, "name"),
            members: try array(map, "members").map(decodeMember),
            grantedClaws: try textArray(map, "granted_claws")
        )
    }

    private static func decodeMember(_ value: HouseholdCBORValue) throws -> OwnerGroupMember {
        guard case let .map(map) = value else { throw OwnerGroupsDecodeError.wrongType("member") }
        guard case let .unsigned(count)? = map["device_count"] else {
            throw OwnerGroupsDecodeError.wrongType("device_count")
        }
        return OwnerGroupMember(
            memberID: try text(map, "member_id"),
            label: try text(map, "label"),
            deviceCount: count
        )
    }

    // MARK: - Field helpers

    private static func text(_ map: [String: HouseholdCBORValue], _ key: String) throws -> String {
        guard let v = map[key] else { throw OwnerGroupsDecodeError.missingField(key) }
        guard case let .text(s) = v else { throw OwnerGroupsDecodeError.wrongType(key) }
        return s
    }

    private static func array(_ map: [String: HouseholdCBORValue], _ key: String) throws -> [HouseholdCBORValue] {
        guard let v = map[key] else { throw OwnerGroupsDecodeError.missingField(key) }
        guard case let .array(a) = v else { throw OwnerGroupsDecodeError.wrongType(key) }
        return a
    }

    private static func textArray(_ map: [String: HouseholdCBORValue], _ key: String) throws -> [String] {
        try array(map, key).map { element in
            guard case let .text(s) = element else { throw OwnerGroupsDecodeError.wrongType(key) }
            return s
        }
    }
}
