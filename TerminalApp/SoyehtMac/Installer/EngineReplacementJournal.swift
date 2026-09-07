import Foundation
import Darwin
import SoyehtCore

/// Serialized intent for one profile's engine replacement. The exclusive lock
/// spans read, decision and mutation, not merely the final write. A malformed
/// or unreadable record never grants authority to start another replacement.
final class EngineReplacementJournal {
    enum Failure: Error, Equatable {
        case busy, invalidRecord, malformedJSON, incompleteWrite, wrongProfile, invalidTransition
        case storageUnavailable(Int32)
    }

    enum Phase: String, Codable, Sendable {
        case prepared
        /// Persisted before invoking bootout; a crash can precede the command.
        case removalUncertain
        /// Absence was observed. Recovery of a load never requests removal.
        case awaitingLoad
        case awaitingReadback
        case completed
    }

    struct Record: Codable, Equatable, Sendable {
        let formatVersion: Int
        let operationID: UUID
        let profileKind: String
        let expectedArtifact: EngineArtifactIdentity
        let plistDigest: String
        let priorEnginePID: UInt32?
        let priorEngineBootID: String?
        let priorBrokerBootID: UUID
        var phase: Phase
        var authorizedLegacyRemoval: LegacyEngineObservation? = nil
        var legacyConsentRevision: UInt64? = nil
    }

    enum WriteStep: CaseIterable { case recordSynced, renamed, directorySynced }
    private let rootFD: Int32
    private let lockFD: Int32
    private let profile: SoyehtInstallProfile.Kind
    private let checkpoint: (WriteStep) throws -> Void
    private static let recordLimit = 16_384

    convenience init(directory: URL, profile: SoyehtInstallProfile.Kind,
         checkpoint: @escaping (WriteStep) throws -> Void = { _ in }) throws {
        try self.init(directory: directory, profile: profile, shared: false, checkpoint: checkpoint)
    }

    /// Held across one CREATE response (including an uncertain response).
    /// Existing sessions restore without this lease. Its shared lock prevents
    /// replacement from starting after the pending-state check but before POST.
    final class CreationLease: @unchecked Sendable {
        // Immutable ownership of kernel file locks; moving the lease between
        // tasks only changes where deinit releases its descriptors.
        private let reader: EngineReplacementJournal
        fileprivate init(reader: EngineReplacementJournal) { self.reader = reader }
    }

    static func directory(in support: URL) -> URL {
        support.appendingPathComponent("engine-replacement", isDirectory: true)
    }

    static func acquireCreationLease(directory: URL, profile: SoyehtInstallProfile.Kind) throws -> CreationLease {
        let reader = try EngineReplacementJournal(directory: directory, profile: profile,
                                                   shared: true, checkpoint: { _ in })
        guard try reader.read() == nil else { throw Failure.busy }
        return CreationLease(reader: reader)
    }

    private init(directory: URL, profile: SoyehtInstallProfile.Kind, shared: Bool,
                 checkpoint: @escaping (WriteStep) throws -> Void) throws {
        self.profile = profile
        self.checkpoint = checkpoint
        // The prepared installation must already own the parent directory.
        // Persist the new directory entry as well as subsequent record renames.
        if mkdir(directory.path, 0o700) != 0 && errno != EEXIST {
            throw Failure.storageUnavailable(errno)
        }
        let parent = Darwin.open(directory.deletingLastPathComponent().path,
                                 O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else { throw Failure.storageUnavailable(errno) }
        let parentSync = fcntl(parent, F_FULLFSYNC)
        let parentError = errno
        Darwin.close(parent)
        guard parentSync == 0 else { throw Failure.storageUnavailable(parentError) }
        let root = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard root >= 0 else { throw Failure.storageUnavailable(errno) }
        var info = stat()
        guard fstat(root, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o777 == 0o700 else {
            Darwin.close(root)
            throw Failure.storageUnavailable(EACCES)
        }
        let lock = openat(root, ".lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard lock >= 0 else {
            let code = errno; Darwin.close(root); throw Failure.storageUnavailable(code)
        }
        guard fstat(lock, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), info.st_mode & 0o777 == 0o600 else {
            Darwin.close(lock); Darwin.close(root); throw Failure.storageUnavailable(EACCES)
        }
        guard flock(lock, (shared ? LOCK_SH : LOCK_EX) | LOCK_NB) == 0 else {
            let code = errno; Darwin.close(lock); Darwin.close(root)
            if code == EWOULDBLOCK { throw Failure.busy }
            throw Failure.storageUnavailable(code)
        }
        rootFD = root
        lockFD = lock
    }

    deinit {
        _ = flock(lockFD, LOCK_UN)
        Darwin.close(lockFD)
        Darwin.close(rootFD)
    }

    func read() throws -> Record? {
        var metadata = stat()
        if fstatat(rootFD, "pending.next", &metadata, AT_SYMLINK_NOFOLLOW) == 0 {
            throw Failure.incompleteWrite
        }
        guard errno == ENOENT else { throw Failure.storageUnavailable(errno) }
        return try readRecord(named: "pending.json")
    }

    /// Explicit Resume may finish a structurally valid interrupted journal
    /// write, or discard syntax-truncated staging after validating the committed
    /// record. It never chooses a different target.
    /// Service/process preconditions still have to be revalidated afterwards.
    func recoverInterruptedWrite() throws {
        // Validate the authoritative record before touching staging. A partial
        // write to .next cannot authorize a command: save has not returned.
        // Syntax-truncated staging is therefore discardable on explicit Resume;
        // an unknown schema/target or an unreadable file is not.
        let existing = try readRecord(named: "pending.json")
        let staged: Record
        do {
            guard let value = try readRecord(named: "pending.next") else { return }
            staged = value
        } catch Failure.malformedJSON {
            guard unlinkat(rootFD, "pending.next", 0) == 0 else { throw Failure.storageUnavailable(errno) }
            try fullSync(rootFD)
            return
        }
        try validateSuccessor(staged, existing: existing)
        let descriptor = openat(rootFD, "pending.next", O_RDWR | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw Failure.storageUnavailable(errno) }
        defer { Darwin.close(descriptor) }
        try fullSync(descriptor)
        guard renameat(rootFD, "pending.next", rootFD, "pending.json") == 0 else { throw Failure.storageUnavailable(errno) }
        try fullSync(rootFD)
    }

    private func readRecord(named name: String) throws -> Record? {
        var metadata = stat()
        let descriptor = openat(rootFD, name, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        if descriptor < 0 {
            guard errno == ENOENT else { throw Failure.storageUnavailable(errno) }
            return nil
        }
        let reader = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? reader.close() }
        guard fstat(descriptor, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_uid == getuid(), metadata.st_mode & 0o777 == 0o600 else {
            throw Failure.storageUnavailable(EACCES)
        }
        let data = try reader.read(upToCount: Self.recordLimit + 1) ?? Data()
        guard data.count <= Self.recordLimit else { throw Failure.invalidRecord }
        guard (try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)) != nil else {
            throw Failure.malformedJSON
        }
        guard let record = try? JSONDecoder().decode(Record.self, from: data) else { throw Failure.invalidRecord }
        try validate(record)
        return record
    }

    func save(_ record: Record) throws {
        try validate(record)
        try validateSuccessor(record, existing: read())
        let data = try JSONEncoder().encode(record)
        guard data.count <= Self.recordLimit else { throw Failure.invalidRecord }
        let descriptor = openat(rootFD, "pending.next", O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard descriptor >= 0 else { throw Failure.storageUnavailable(errno) }
        let writer = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? writer.close() }
        // Retain an incomplete staging file on failure. Recovery must not read
        // the old phase as permission to start a different operation.
        try writer.write(contentsOf: data)
        try fullSync(descriptor)
        try checkpoint(.recordSynced)
        guard renameat(rootFD, "pending.next", rootFD, "pending.json") == 0 else { throw Failure.storageUnavailable(errno) }
        try checkpoint(.renamed)
        try fullSync(rootFD)
        try checkpoint(.directorySynced)
    }

    private func validateSuccessor(_ record: Record, existing: Record?) throws {
        if var existing {
            guard existing.operationID == record.operationID else { throw Failure.busy }
            let priorPhase = existing.phase
            if record.legacyConsentRevision != existing.legacyConsentRevision {
                guard priorPhase == .prepared || priorPhase == .removalUncertain,
                      record.phase == priorPhase,
                      existing.authorizedLegacyRemoval != nil,
                      record.authorizedLegacyRemoval != nil,
                      (existing.legacyConsentRevision ?? 0) < UInt64.max,
                      record.legacyConsentRevision == (existing.legacyConsentRevision ?? 0) + 1 else {
                    throw Failure.invalidTransition
                }
                existing.legacyConsentRevision = record.legacyConsentRevision
                existing.authorizedLegacyRemoval = record.authorizedLegacyRemoval
            }
            existing.phase = record.phase
            guard existing == record else { throw Failure.invalidRecord }
            guard Self.allowsTransition(from: priorPhase, to: record.phase) else { throw Failure.invalidTransition }
        } else if record.phase != .prepared {
            throw Failure.invalidTransition
        }
    }

    /// A newly observed legacy process needs a new explicit approval. Keep the
    /// same target, operation and uncertainty; renewing consent never unblocks
    /// CREATE or forgets a removal that may already be in flight.
    func renewLegacyConsent(expected: Record, observed: LegacyEngineObservation) throws {
        guard try read() == expected else { throw Failure.busy }
        guard (expected.legacyConsentRevision ?? 0) < UInt64.max else { throw Failure.invalidRecord }
        var renewed = expected
        renewed.authorizedLegacyRemoval = observed
        renewed.legacyConsentRevision = (expected.legacyConsentRevision ?? 0) + 1
        try save(renewed)
    }

    private static func allowsTransition(from: Phase, to: Phase) -> Bool {
        if from == to { return true }
        if to == .completed { return true }
        switch (from, to) {
        case (.prepared, .removalUncertain), (.prepared, .awaitingLoad),
             (.removalUncertain, .awaitingLoad), (.awaitingLoad, .awaitingReadback),
             (.awaitingReadback, .awaitingLoad): return true
        default: return false
        }
    }

    /// Persist completion before removing the entry. A lost unlink can only
    /// recover a completed operation, never permission to repeat its removal.
    func complete(_ record: Record) throws {
        var completed = record
        completed.phase = .completed
        try save(completed)
        guard unlinkat(rootFD, "pending.json", 0) == 0 else { throw Failure.storageUnavailable(errno) }
        try fullSync(rootFD)
    }

    private func validate(_ record: Record) throws {
        guard record.profileKind == profile.rawValue else { throw Failure.wrongProfile }
        guard [1, 2].contains(record.formatVersion),
              record.expectedArtifact.compareImage(to: record.expectedArtifact) == .sameImage,
              record.plistDigest.utf8.count == 64,
              record.plistDigest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              (record.priorEnginePID == nil) == (record.priorEngineBootID == nil),
              record.priorEnginePID != 0 else { throw Failure.invalidRecord }
        if let legacy = record.authorizedLegacyRemoval {
            let installation: SoyehtInstallProfile = profile == .dev ? .dev : .release
            guard record.formatVersion == 2, record.priorEnginePID == nil,
                  legacy.isValid(profile: installation) else { throw Failure.invalidRecord }
        }
        if let revision = record.legacyConsentRevision {
            guard revision > 0, record.authorizedLegacyRemoval != nil else { throw Failure.invalidRecord }
        }
        if let boot = record.priorEngineBootID {
            guard boot.utf8.count == 32,
                  boot.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
                throw Failure.invalidRecord
            }
        }
    }

    private func fullSync(_ descriptor: Int32) throws {
        // An acknowledgement requires the storage barrier, not just atomic
        // visibility. This relies on the filesystem/device honoring F_FULLFSYNC.
        guard fcntl(descriptor, F_FULLFSYNC) == 0 else { throw Failure.storageUnavailable(errno) }
    }
}
