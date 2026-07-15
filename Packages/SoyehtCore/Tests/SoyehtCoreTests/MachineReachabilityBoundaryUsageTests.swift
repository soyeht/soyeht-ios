import Foundation
import XCTest

/// Source-slice ratchet for the endpoint escape hatch that predates
/// `MachineReachability`. `ActiveHouseholdState.endpoint` is currently a
/// serialized legacy seed, but production code still reads it through a small
/// set of local aliases. New readers must not enlarge that set before the
/// reachability seam is introduced.
///
/// This is deliberately an allowlist of *sites*, not files: an additional
/// `household.endpoint` in `HouseholdMachineJoinRuntime.swift` still fails.
/// Every baseline entry must resolve positively. A migration that removes a
/// reader updates this list in the same PR, so a broken cross-workspace path
/// can never make the test pass by scanning zero files.
final class MachineReachabilityBoundaryUsageTests: XCTestCase {
    func test_activeHouseholdStateEndpointReads_doNotGrowBeyondKnownSites() throws {
        XCTAssertEqual(
            Self.allowedRawEndpointReads.count,
            Self.initialKnownRawEndpointReadCount,
            "The Phase 2 baseline must keep one explicit entry for each of its 15 initially known sites."
        )

        let files = try productionSwiftFiles()
        let filesByPath = Dictionary(uniqueKeysWithValues: files.map { ($0.relativePath, $0) })
        let actual = files.flatMap { endpointReads(in: $0) }

        var allowedReads: Set<EndpointRead> = []
        var unresolvedAllowlistEntries: [String] = []

        for allowed in Self.allowedRawEndpointReads {
            guard let file = filesByPath[allowed.relativePath] else {
                unresolvedAllowlistEntries.append(
                    "\(allowed.relativePath): \(allowed.purpose) source file was not scanned"
                )
                continue
            }

            let anchorRanges = ranges(of: allowed.anchor, in: file.code)
            guard anchorRanges.count == 1, let anchorRange = anchorRanges.first else {
                unresolvedAllowlistEntries.append(
                    "\(allowed.relativePath): \(allowed.purpose) anchor matched \(anchorRanges.count)x"
                )
                continue
            }

            let anchorLine = lineNumber(
                at: NSRange(anchorRange, in: file.code).location,
                in: file.code
            )
            let readsInAnchor = actual.filter { read in
                guard read.relativePath == allowed.relativePath else { return false }
                return read.line >= anchorLine
                    && read.line <= anchorLine + allowed.maximumLineDistance
            }

            guard readsInAnchor.count == 1,
                  let read = readsInAnchor.first,
                  read.expression == allowed.expression else {
                let found = readsInAnchor.map(\.description).joined(separator: ", ")
                unresolvedAllowlistEntries.append(
                    "\(allowed.relativePath): \(allowed.purpose) expected \(allowed.expression) once within \(allowed.maximumLineDistance) line(s) of its anchor, found [\(found)]"
                )
                continue
            }
            allowedReads.insert(read)
        }

        let unexpected = actual
            .filter { !allowedReads.contains($0) }
            .sorted()
        let unresolved = unresolvedAllowlistEntries.sorted()

        XCTAssertEqual(
            allowedReads.count,
            Self.initialKnownRawEndpointReadCount,
            """
            The Phase 2 baseline must resolve all \(Self.initialKnownRawEndpointReadCount) known raw endpoint sites. This is a positive guard against a broken cross-workspace path or an ambiguous anchor.

            Unresolved baseline entries:
            \(unresolved.joined(separator: "\n"))
            """
        )

        XCTAssertTrue(
            unresolved.isEmpty && unexpected.isEmpty,
            """
            ActiveHouseholdState.endpoint may not gain a new production reader outside the Phase 2 baseline.

            Unexpected raw endpoint reads:
            \(unexpected.map(\.description).joined(separator: "\n"))

            Unresolved baseline entries:
            \(unresolved.joined(separator: "\n"))

            Migrate consumers to MachineReachability rather than adding a new allowlist entry.
            """
        )
    }

    // MARK: - Phase 2 baseline (15 sites on origin/main at creation)

    private static let initialKnownRawEndpointReadCount = 15

    private static let allowedRawEndpointReads: [AllowedRawEndpointRead] = [
        .init(
            relativePath: "Packages/SoyehtCore/Sources/SoyehtCore/API/SoyehtAPIClient.swift",
            expression: "household.endpoint",
            anchor: "let url = try buildHouseholdURL(endpoint: endpoint ?? household.endpoint, path: path, queryItems: queryItems)",
            purpose: "generic householdRequest fallback"
        ),
        .init(
            relativePath: "Packages/SoyehtCore/Sources/SoyehtCore/Household/HouseholdDevicePairingService.swift",
            expression: "household.endpoint",
            anchor: "_ = try await httpClient.approvePairing(",
            purpose: "device-pair approval",
            maximumLineDistance: 1
        ),
        .init(
            relativePath: "TerminalApp/Soyeht/Household/HouseholdMachineJoinRuntime.swift",
            expression: "household.endpoint",
            anchor: "let snapshot = HouseholdSnapshotBootstrapper(",
            purpose: "machine snapshot bootstrap",
            maximumLineDistance: 1
        ),
        .init(
            relativePath: "TerminalApp/Soyeht/Household/HouseholdMachineJoinRuntime.swift",
            expression: "household.endpoint",
            anchor: "let client = JoinRequestStagingClient(",
            purpose: "join-request staging",
            maximumLineDistance: 1
        ),
        .init(
            relativePath: "TerminalApp/Soyeht/Household/HouseholdMachineJoinRuntime.swift",
            expression: "household.endpoint",
            anchor: "let client = OwnerApprovalClient(",
            purpose: "owner approval v1",
            maximumLineDistance: 1
        ),
        .init(
            relativePath: "TerminalApp/Soyeht/Household/HouseholdMachineJoinRuntime.swift",
            expression: "household.endpoint",
            anchor: "let client = OwnerApprovalV2Client(",
            purpose: "owner approval v2",
            maximumLineDistance: 1
        ),
        .init(
            relativePath: "TerminalApp/Soyeht/Household/HouseholdMachineJoinRuntime.swift",
            expression: "household.endpoint",
            anchor: "let poller = OwnerEventsLongPoll(",
            purpose: "owner-events long poll",
            maximumLineDistance: 1
        ),
        .init(
            relativePath: "TerminalApp/Soyeht/Household/HouseholdMachineJoinRuntime.swift",
            expression: "household.endpoint",
            anchor: "var components = URLComponents(url: household.endpoint, resolvingAgainstBaseURL: false)!",
            purpose: "gossip WebSocket URL"
        ),
        .init(
            relativePath: "TerminalApp/Soyeht/Household/HouseholdSessionController.swift",
            expression: "current.endpoint",
            anchor: "let client = BootstrapPairDeviceURIClient(baseURL: current.endpoint)",
            purpose: "pair-device URI refresh"
        ),
        .init(
            relativePath: "TerminalApp/Soyeht/Household/HouseholdSessionController.swift",
            expression: "current.endpoint",
            anchor: "endpoint: current.endpoint,",
            purpose: "state reconstruction after household rename"
        ),
        .init(
            relativePath: "TerminalApp/Soyeht/Household/APNSRegistrationCoordinator.swift",
            expression: "session.endpoint",
            anchor: "guard let url = Self.registrationURL(endpoint: session.endpoint) else {",
            purpose: "APNS registration"
        ),
        .init(
            relativePath: "TerminalApp/Soyeht/Identity/SoyehtIdentitySnapshot.swift",
            expression: "raw.endpoint",
            anchor: "var endpoint: URL { raw.endpoint }",
            purpose: "identity facade endpoint accessor"
        ),
        .init(
            relativePath: "TerminalApp/Soyeht/Onboarding/OwnerPasskey/OwnerPasskeyEnrollmentComposer.swift",
            expression: "snapshot.endpoint",
            anchor: "let enrollmentClient = OwnerPasskeyEnrollmentClient(baseURL: snapshot.endpoint, popSigner: popSigner)",
            purpose: "owner passkey enrollment"
        ),
        .init(
            relativePath: "TerminalApp/Soyeht/Onboarding/OwnerPasskey/OwnerPasskeyEnrollmentComposer.swift",
            expression: "snapshot.endpoint",
            anchor: "let statusClient = OwnerPasskeyRegistrationStatusClient(baseURL: snapshot.endpoint, popSigner: popSigner)",
            purpose: "owner passkey registration status"
        ),
        .init(
            relativePath: "TerminalApp/Soyeht/Home/AwaitingNewMacView.swift",
            expression: "identity.endpoint",
            anchor: "let signer = HouseholdSignMachineCertClient(",
            purpose: "machine certificate signing",
            maximumLineDistance: 1
        ),
    ]

    // MARK: - Source scanning

    private struct AllowedRawEndpointRead {
        let relativePath: String
        let expression: String
        let anchor: String
        let purpose: String
        /// Most sites place the raw read on the anchor line. Constructor-style
        /// calls use a one-line window so formatting indentation cannot turn
        /// the positive baseline into a false failure.
        let maximumLineDistance: Int

        init(
            relativePath: String,
            expression: String,
            anchor: String,
            purpose: String,
            maximumLineDistance: Int = 0
        ) {
            self.relativePath = relativePath
            self.expression = expression
            self.anchor = anchor
            self.purpose = purpose
            self.maximumLineDistance = maximumLineDistance
        }
    }

    private struct EndpointRead: Hashable, Comparable, CustomStringConvertible {
        let relativePath: String
        let offset: Int
        let line: Int
        let expression: String

        static func < (lhs: EndpointRead, rhs: EndpointRead) -> Bool {
            if lhs.relativePath != rhs.relativePath {
                return lhs.relativePath < rhs.relativePath
            }
            return lhs.offset < rhs.offset
        }

        var description: String {
            "\(relativePath):\(line): \(expression)"
        }
    }

    private struct SourceFile {
        let relativePath: String
        let code: String
    }

    private static let rawEndpointExpression = try! NSRegularExpression(
        pattern: #"(?<![A-Za-z0-9_])(household|current|session|raw|identity|snapshot|state|active|activeHousehold|householdState)\s*\.\s*endpoint\b"#
    )

    private func endpointReads(in file: SourceFile) -> [EndpointRead] {
        let range = NSRange(file.code.startIndex..., in: file.code)
        let source = file.code as NSString
        return Self.rawEndpointExpression.matches(in: file.code, range: range).map { match in
            let line = lineNumber(at: match.range.location, in: file.code)
            let expression = source.substring(with: match.range)
                .replacingOccurrences(of: #"\s+"#, with: "", options: .regularExpression)
            return EndpointRead(
                relativePath: file.relativePath,
                offset: match.range.location,
                line: line,
                expression: expression
            )
        }
    }

    private func lineNumber(at utf16Offset: Int, in source: String) -> Int {
        let start = String.Index(utf16Offset: utf16Offset, in: source)
        return source[..<start].reduce(into: 1) { count, character in
            if character == "\n" { count += 1 }
        }
    }

    private func productionSwiftFiles() throws -> [SourceFile] {
        let root = try workspaceRoot()
        let productionRoots = [
            "Packages/SoyehtCore/Sources",
            "TerminalApp/Soyeht",
            "TerminalApp/SoyehtMac",
        ]

        var files: [SourceFile] = []
        for relativeRoot in productionRoots {
            let directory = root.appendingPathComponent(relativeRoot)
            guard let enumerator = FileManager.default.enumerator(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else {
                throw NSError(
                    domain: "MachineReachabilityBoundaryUsageTests",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Could not enumerate \(relativeRoot)"]
                )
            }

            for case let url as URL in enumerator where url.pathExtension == "swift" {
                let relativePath = try relativePath(for: url, root: root)
                let source = try String(contentsOf: url, encoding: .utf8)
                files.append(SourceFile(relativePath: relativePath, code: sourceCodeOnly(source)))
            }
        }
        return files.sorted { $0.relativePath < $1.relativePath }
    }

    private func ranges(of needle: String, in source: String) -> [Range<String.Index>] {
        var matches: [Range<String.Index>] = []
        var searchRange = source.startIndex..<source.endIndex
        while let match = source.range(of: needle, range: searchRange) {
            matches.append(match)
            searchRange = match.upperBound..<source.endIndex
        }
        return matches
    }

    private func relativePath(for url: URL, root: URL) throws -> String {
        let rootPath = root.standardizedFileURL.path + "/"
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(rootPath) else {
            throw NSError(
                domain: "MachineReachabilityBoundaryUsageTests",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "\(path) is not under \(rootPath)"]
            )
        }
        return String(path.dropFirst(rootPath.count))
    }

    private func workspaceRoot() throws -> URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 {
            url.deleteLastPathComponent()
        }
        let requiredRoots = [
            "Packages/SoyehtCore/Sources",
            "TerminalApp/Soyeht",
            "TerminalApp/SoyehtMac",
        ]
        let missingRoots = requiredRoots.filter {
            !FileManager.default.fileExists(atPath: url.appendingPathComponent($0).path)
        }
        guard missingRoots.isEmpty else {
            throw NSError(
                domain: "MachineReachabilityBoundaryUsageTests",
                code: 3,
                userInfo: [
                    NSLocalizedDescriptionKey: "Could not locate repository root from #filePath; missing \(missingRoots.joined(separator: ", "))"
                ]
            )
        }
        return url
    }

    /// Equivalent to the `SourceCommentStripper` used by the iOS target. This
    /// package test target cannot import that target, so keep the same
    /// newline-preserving nested-comment behavior locally.
    private func sourceCodeOnly(_ source: String) -> String {
        let characters = Array(source)
        var result = ""
        result.reserveCapacity(characters.count)

        var index = 0
        var inLineComment = false
        var blockDepth = 0

        while index < characters.count {
            let character = characters[index]
            let next = index + 1 < characters.count ? characters[index + 1] : nil

            if inLineComment {
                if character == "\n" {
                    inLineComment = false
                    result.append(character)
                }
                index += 1
            } else if blockDepth > 0 {
                if character == "/" && next == "*" {
                    blockDepth += 1
                    index += 2
                } else if character == "*" && next == "/" {
                    blockDepth -= 1
                    index += 2
                } else {
                    if character == "\n" { result.append(character) }
                    index += 1
                }
            } else if character == "/" && next == "/" {
                inLineComment = true
                index += 2
            } else if character == "/" && next == "*" {
                blockDepth += 1
                index += 2
            } else {
                result.append(character)
                index += 1
            }
        }

        return result
    }
}
