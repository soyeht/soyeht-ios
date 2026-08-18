import Darwin
import Foundation

/// Confinamento de acesso a um diretório, imposto pelo kernel.
///
/// Phase 2a contract (`docs/app-identity-phase2a.md` §1): this is the ONE
/// audited path-containment primitive for the app platform. The scheme
/// handler receives paths **controlled by the page**, so access is never
/// decided by comparing strings — every open goes through
///
/// ```
/// openat(rootFD, rel, O_RDONLY | O_RESOLVE_BENEATH | O_NOFOLLOW_ANY | O_CLOEXEC)
/// ```
///
/// measured on this machine (contract table): `O_RESOLVE_BENEATH` is the
/// only flag of the two that confines *by design* (`..` and absolute paths);
/// `O_NOFOLLOW_ANY` closes the symlink escape in any component. The
/// pre-syscall checks below (`absolutePath`, `emptyComponent`,
/// `parentReference`) are an error-clarity layer so callers get a
/// distinguishable reason — the kernel remains the imposer.
///
/// Descriptor discipline (sia's Phase 2c rule, applied from day one): the
/// root fd is opened once, resolved **under the scope lock** for every
/// operation, and never cached outside it. `close()` marks the slot before
/// releasing the descriptor, so a revoked scope can never act on a
/// recycled fd number, and calling `close()` twice is harmless.
///
/// Legitimate symlinks (pnpm `node_modules/.bin`, stow dotfiles) fail
/// closed with `.symlinkComponent` naming the offending component — an
/// explicit error the app can surface to the user. This is expected
/// acceptance behavior, not a bug.
/// ownership is why this is a `final class` and not the `struct` of the
/// contract sketch: a deinit-releasing struct would need `~Copyable`, which
/// blocks ordinary property storage in the scheme handler, and a copyable
/// struct would double-close its fd. A reference type has exactly one
/// owner for the descriptor — the discipline itself.
final class PathScope {
    /// Distinguishable failure reasons. Callers (scheme handler, future
    /// grant registry) map these to user-facing errors; tests assert on
    /// them to prove the escape vectors fail for the *right* cause.
    enum PathScopeError: Error, Equatable {
        /// The root itself is not a directory (or could not be opened).
        case invalidRoot
        /// The scope was closed; no further opens are possible.
        case closed
        /// Relative path is empty.
        case emptyPath
        /// Absolute paths are rejected outright (error-clarity layer; the
        /// kernel would refuse them via `O_RESOLVE_BENEATH` anyway).
        case absolutePath(String)
        /// A `//` collapse or trailing slash produced an empty component.
        case emptyComponent(String)
        /// A component starts with `..` — covers literal `..`, `...`, and
        /// `..namedfork/rsrc` resource forks in one rule.
        case parentReference(String)
        /// `O_NOFOLLOW_ANY` caught a symlink in the named component
        /// (kernel errno `ELOOP`). Includes the component so apps can
        /// explain the failure to the user.
        case symlinkComponent(String)
        /// `O_RESOLVE_BENEATH` refused to resolve the path beneath the
        /// root (kernel errno `ENOTCAPABLE`).
        case escapesScope(String)
        case notFound(String)
        case permissionDenied(String)
        /// A directory entry whose name is not valid UTF-8. The listing
        /// refuses instead of skipping: a skipped entry would be disk
        /// content outside every fingerprint measured through this walk —
        /// the same defect shape as hidden files, by another door.
        case undecodableEntryName(context: String)
        case systemError(String, errno: Int32)

        var errorDescription: String? {
            func quote(_ s: String) -> String { "\"\(s)\"" }
            switch self {
            case .invalidRoot:
                return "PathScope root is not a directory."
            case .closed:
                return "PathScope is closed."
            case .emptyPath:
                return "Empty path."
            case .absolutePath(let p):
                return "Absolute path is not allowed inside the scope: \(quote(p))."
            case .emptyComponent(let p):
                return "Path contains an empty component: \(quote(p))."
            case .parentReference(let p):
                return "Path component may not start with \"..\": \(quote(p))."
            case .symlinkComponent(let p):
                return "Path component is a symlink (not allowed): \(quote(p))."
            case .escapesScope(let p):
                return "Path escapes the scope root: \(quote(p))."
            case .notFound(let p):
                return "File not found: \(quote(p))."
            case .permissionDenied(let p):
                return "Permission denied: \(quote(p))."
            case .undecodableEntryName(let context):
                return "Directory contains an entry name that is not valid UTF-8 (in \(quote(context))). The bundle is refused rather than measured partially."
            case .systemError(let p, let errno):
                return "System error \(errno) for \(quote(p))."
            }
        }
    }

    /// Serializes every open against `close()` so an in-flight `openat`
    /// can never race with revocation and act on a recycled fd number.
    private let lock = NSLock()
    /// Root directory descriptor, `-1` once closed. Guarded by `lock`.
    private var rootFD: Int32

    init(rootDirectory: URL) throws {
        // String-based path handling ends here: this is the ONLY open that
        // uses an absolute path, and it comes from the installer (trusted),
        // never from page-controlled input.
        let fd = open(rootDirectory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else {
            throw PathScopeError.invalidRoot
        }
        rootFD = fd
    }

    deinit {
        close()
    }

    /// Opens a file **beneath the root** for reading and returns its
    /// descriptor. Ownership of the returned fd transfers to the caller.
    ///
    /// - Throws: `PathScopeError` with a distinguishable cause. The escape
    ///   vectors — `..`, absolute paths (with or without symlinks on them),
    ///   and symlinks in any component — never open.
    func openFileForReading(relativePath: String) throws -> Int32 {
        try validate(relativePath)

        lock.lock()
        defer { lock.unlock() }
        guard rootFD >= 0 else {
            throw PathScopeError.closed
        }

        let fd = openat(
            rootFD,
            relativePath,
            O_RDONLY | O_RESOLVE_BENEATH | O_NOFOLLOW_ANY | O_CLOEXEC
        )
        guard fd >= 0 else {
            throw Self.from(errno: errno, path: relativePath, rootFD: rootFD)
        }
        return fd
    }

    /// One directory entry as reported by the kernel. Symlinks surface as
    /// `.other` (`DT_LNK`): they are *visible* as names, but never openable
    /// — callers walking a tree must only recurse into `.directory` and
    /// only read `.file`, treating `.other` (and anything unexpected) as
    /// an error per the fail-closed rule.
    struct Entry: Equatable {
        enum Kind: Equatable { case file, directory, other }
        let name: String
        let kind: Kind
    }

    /// Opens a directory **beneath the root** and returns its descriptor,
    /// compatible with `fdopendir`. Ownership of the fd transfers to the
    /// caller. Use `"."` to re-open the scope root itself.
    ///
    /// Same imposition and same distinguishable errors as
    /// `openFileForReading(relativePath:)` — this is the walk primitive the
    /// installer uses on externally-pointed directories, so the escape
    /// vectors fail identically here.
    func openDirectoryForListing(relativePath: String) throws -> Int32 {
        try validate(relativePath)

        lock.lock()
        defer { lock.unlock() }
        guard rootFD >= 0 else {
            throw PathScopeError.closed
        }

        let fd = openat(
            rootFD,
            relativePath,
            O_RDONLY | O_DIRECTORY | O_RESOLVE_BENEATH | O_NOFOLLOW_ANY | O_CLOEXEC
        )
        guard fd >= 0 else {
            throw Self.from(errno: errno, path: relativePath, rootFD: rootFD)
        }
        return fd
    }

    /// Lists a directory beneath the root (use `"."` for the root itself),
    /// sorted by name for deterministic fingerprints. Does NOT skip hidden
    /// files — the kernel listing is the truth on disk, so a `.payload.js`
    /// is enumerated exactly like any other entry (see the fingerprint
    /// coverage fix). Symlink entries appear with kind `.other`.
    ///
    /// Throws `PathScopeError` for the same vectors as every other open.
    func listDirectoryEntries(relativePath: String) throws -> [Entry] {
        let dirFD = try openDirectoryForListing(relativePath: relativePath)
        // fdopendir consumes the descriptor; closedir releases it.
        guard let dir = fdopendir(dirFD) else {
            Darwin.close(dirFD)
            throw PathScopeError.systemError(relativePath, errno: errno)
        }
        defer { closedir(dir) }

        var entries: [Entry] = []
        while let dp = readdir(dir) {
            let name = withUnsafeBytes(of: dp.pointee.d_name) { raw -> String? in
                guard let base = raw.baseAddress else { return nil }
                return String(validatingUTF8: base.assumingMemoryBound(to: CChar.self))
            }
            // Fail loud, never skip: an undecodable name is disk content
            // that would fall outside every measurement taken through this
            // walk (fingerprint coverage invariant: servable set == measured
            // set). "." and ".." are the only intentional skips — they are
            // kernel artifacts, not content.
            guard let name else {
                throw PathScopeError.undecodableEntryName(context: relativePath)
            }
            guard name != ".", name != ".." else { continue }
            let kind: Entry.Kind
            switch dp.pointee.d_type {
            case UInt8(DT_REG): kind = .file
            case UInt8(DT_DIR): kind = .directory
            default: kind = .other
            }
            entries.append(Entry(name: name, kind: kind))
        }
        return entries.sorted { $0.name < $1.name }
    }

    /// Releases the root descriptor. Idempotent. After this call every
    /// further open throws `.closed`; the fd number is never touched
    /// again, so a recycled number cannot be closed or used twice.
    func close() {
        lock.lock()
        let fd = rootFD
        rootFD = -1
        lock.unlock()
        if fd >= 0 {
            Darwin.close(fd)
        }
    }

    // MARK: - Error-clarity layer (the kernel remains the imposer)

    private func validate(_ path: String) throws {
        guard !path.isEmpty else {
            throw PathScopeError.emptyPath
        }
        guard !path.hasPrefix("/") else {
            throw PathScopeError.absolutePath(path)
        }
        for component in path.split(separator: "/", omittingEmptySubsequences: false) {
            if component.isEmpty {
                throw PathScopeError.emptyComponent(path)
            }
            if component.hasPrefix("..") {
                throw PathScopeError.parentReference(String(component))
            }
        }
    }

    private static func from(errno rawErrno: Int32, path: String, rootFD: Int32) -> PathScopeError {
        switch rawErrno {
        case ELOOP:
            return .symlinkComponent(symlinkHint(path, rootFD: rootFD))
        case ENOTCAPABLE:
            return .escapesScope(path)
        case ENOENT:
            return .notFound(path)
        case EACCES:
            return .permissionDenied(path)
        default:
            return .systemError(path, errno: rawErrno)
        }
    }

    /// Names the offending symlink component for `.symlinkComponent`.
    ///
    /// Diagnostic-only: it runs strictly AFTER the kernel refused the open,
    /// and its outcome changes no access decision — so the check-then-act
    /// hazard this type exists to avoid does not apply here. Any surprise
    /// falls back to reporting the whole path.
    private static func symlinkHint(_ path: String, rootFD: Int32) -> String {
        // Walk on a dup so the scope's own descriptor is never consumed here.
        var dirFD = dup(rootFD)
        guard dirFD >= 0 else { return path }
        defer { Darwin.close(dirFD) }

        let components = path.split(separator: "/").map(String.init)
        for (index, component) in components.enumerated() {
            var st = stat()
            let isLast = index == components.count - 1
            if fstatat(dirFD, component, &st, AT_SYMLINK_NOFOLLOW) == 0,
               (st.st_mode & S_IFMT) == S_IFLNK {
                return component
            }
            if isLast { break }
            let next = openat(dirFD, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { return path }
            Darwin.close(dirFD)
            dirFD = next
        }
        return path
    }
}
