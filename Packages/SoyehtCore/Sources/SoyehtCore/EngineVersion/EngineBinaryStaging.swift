import Darwin
import Foundation

/// Publishes a complete executable with one rename in the destination directory.
/// Existing mapped images keep their inode; a previously absent helper is also
/// installed without a delete/create gap. Activation belongs to the lifecycle.
public enum EngineBinaryStaging {
    public static func stage(source: URL, destination: URL) throws {
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).tmp-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try FileManager.default.copyItem(at: source, to: temporary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: temporary.path)
        let descriptor = Darwin.open(temporary.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        defer { Darwin.close(descriptor) }
        try fullSync(descriptor)
        guard rename(temporary.path, destination.path) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        let parent = Darwin.open(destination.deletingLastPathComponent().path,
                                 O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        defer { Darwin.close(parent) }
        try fullSync(parent)
    }

    private static func fullSync(_ descriptor: Int32) throws {
        // Durability also depends on the filesystem/device honoring this
        // barrier. Publish bytes before the name, then persist the rename.
        guard fcntl(descriptor, F_FULLFSYNC) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }
}
