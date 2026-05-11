import Darwin
import Foundation
import SoyehtCore
import os

/// Local Mac pseudo-terminal wrapper. Spawns the bash quick-start shell inside
/// a PTY pair. The picker labels this path as "bash", so the default must not
/// follow `$SHELL` to a potentially-heavy zsh/fish setup. Callers pass in the
/// PATH they want the spawn to inherit (typically resolved via
/// `LoginShellEnvironmentResolver`); a `nil` `loginPath` falls back to
/// whatever PATH the host process inherited.
///
/// This is the `CommanderState.native(pid:)` transport — the third architectural
/// mode alongside remote tmux (WebSocket + theyos server) and QR hand-off. Used
/// exclusively by the `bash` row in the driQx picker (`AgentType.shell`); every
/// other agent still goes through the remote path.
///
/// Threading: `init`, `write(_:)`, `resize(cols:rows:)`, and `close()` may be
/// called from any queue. The read loop runs on a private serial queue and
/// delivers `onData` and `onExit` callbacks back on that same queue — callers
/// should hop to `@MainActor` if they touch UI.
final class NativePTY {

    enum Error: Swift.Error, LocalizedError {
        case openptyFailed(errno: Int32)
        case spawnFailed(errno: Int32)

        var errorDescription: String? {
            switch self {
            case .openptyFailed(let e):
                return "openpty failed (errno=\(e): \(String(cString: strerror(e))))"
            case .spawnFailed(let e):
                return "forkpty failed (errno=\(e): \(String(cString: strerror(e))))"
            }
        }
    }

    private static let logger = Logger(subsystem: "com.soyeht.mac", category: "native-pty")

    /// Child shell's PID. `forkpty` creates a new session for the child, making
    /// this PID the process-group ID as well, so `kill(-pid, SIGHUP)` closes the
    /// whole job tree — backgrounded processes included.
    let pid: pid_t

    /// Slave-side TTY path, e.g. `/dev/ttys010`. Used by automation to map an
    /// MCP server process back to the Soyeht pane whose PTY launched it.
    let slaveTTYPath: String?

    /// Parent-side PTY master FD. Stays open until `close()`.
    private let masterFD: Int32

    /// Serial queue for all FD I/O + exit handling.
    private let ioQueue = DispatchQueue(label: "com.soyeht.mac.native-pty.io", qos: .userInitiated)

    private var readSource: DispatchSourceRead?
    private var exitSource: DispatchSourceProcess?
    private var closed = false

    /// Fired on the private queue whenever the PTY has bytes available.
    /// Callers should hop to the main queue before touching AppKit.
    var onData: ((Data) -> Void)?

    /// Fired on the private queue once the child shell exits. `code` is the
    /// raw `waitpid` status — use `WEXITSTATUS(code)` to get the exit code or
    /// `WTERMSIG(code)` for the terminating signal.
    var onExit: ((Int32) -> Void)?

    // MARK: - Init

    /// Spawn a PTY running an interactive shell.
    ///
    /// - Parameters:
    ///   - shellPath: When non-nil, runs this shell instead of the default
    ///     `/bin/bash`. When nil, `SOYEHT_LOCAL_SHELL` may replace the default
    ///     for debugging.
    ///   - cwd: Initial working directory. Must exist and be readable.
    ///   - cols: Initial terminal width.
    ///   - rows: Initial terminal height.
    ///   - loginPath: Pre-resolved PATH to inject into the spawn, normally
    ///     produced by `LoginShellEnvironmentResolver` so the non-login bash
    ///     can find homebrew/npm/per-user shims. `nil` keeps the host's
    ///     inherited PATH (only useful for tests / login-shell mode).
    init(shellPath: String? = nil, cwd: URL, cols: Int, rows: Int, loginPath: String? = nil) throws {
        let inheritedEnvironment = ProcessInfo.processInfo.environment
        let debugShellOverride = inheritedEnvironment["SOYEHT_LOCAL_SHELL"]
        let shell = shellPath
            ?? debugShellOverride
            ?? "/bin/bash"
        let usesDebugShellOverride = shellPath == nil && debugShellOverride != nil
        let shellName = (shell as NSString).lastPathComponent

        // Open a real controlling PTY with the right initial size so the first
        // screen-filling program sees a sane geometry (vim, less, htop).
        var master: Int32 = -1
        var ws = winsize(
            ws_row: UInt16(max(rows, 1)),
            ws_col: UInt16(max(cols, 1)),
            ws_xpixel: 0,
            ws_ypixel: 0
        )

        // Build argv: argv[0] conventionally matches the shell basename so
        // `ps` / `$0` show `bash` not `/bin/bash`. The default is an
        // interactive non-login shell: bash reads ~/.bashrc but skips heavier
        // login hooks such as conda/rvm in ~/.bash_profile. Set
        // SOYEHT_LOCAL_SHELL_LOGIN=1 when comparing against Terminal.app.
        let wantsLoginShell = ProcessInfo.processInfo.environment["SOYEHT_LOCAL_SHELL_LOGIN"] == "1"
        let argvStrings = Self.argv(forShellName: shellName, login: wantsLoginShell)
        let argv: [UnsafeMutablePointer<CChar>?] = argvStrings.map { strdup($0) } + [nil]
        defer { argv.forEach { if let p = $0 { free(p) } } }

        // Inherit the Soyeht environment, then advertise the color support
        // this terminal actually implements. Drop inherited color policy
        // overrides so interactive CLIs choose their natural ANSI/truecolor
        // styling from TERM/COLORTERM and TTY detection.
        var envDict = TerminalProcessEnvironment.interactiveShellEnvironment(
            inherited: inheritedEnvironment,
            cwdPath: cwd.path
        )
        if !usesDebugShellOverride {
            envDict["SHELL"] = shell
        }
        if shellName == "bash" {
            envDict["BASH_SILENCE_DEPRECATION_WARNING"] = "1"
            envDict["PS1"] = ProcessInfo.processInfo.environment["SOYEHT_LOCAL_PS1"]
                ?? Self.defaultBashPrompt
        }
        if !wantsLoginShell, let loginPath {
            envDict["PATH"] = loginPath
        }
        let envStrings = envDict.map { "\($0.key)=\($0.value)" }
        let envArr: [UnsafeMutablePointer<CChar>?] = envStrings.map { strdup($0) } + [nil]
        defer { envArr.forEach { if let p = $0 { free(p) } } }
        let cwdPath = strdup(cwd.path)
        defer { if let cwdPath { free(cwdPath) } }

        // forkpty gives the child a controlling terminal and its own session.
        // That matters for TUI apps: TIOCSWINSZ on the master then reaches the
        // foreground process group as SIGWINCH instead of only changing kernel
        // bookkeeping.
        let childPid = argv.withUnsafeBufferPointer { argPtr in
            envArr.withUnsafeBufferPointer { envPtr in
                shell.withCString { shellCstr in
                    let pid = forkpty(&master, nil, nil, &ws)
                    if pid == 0 {
                        if let cwdPath {
                            _ = Darwin.chdir(cwdPath)
                        }
                        execve(
                            shellCstr,
                            UnsafeMutablePointer(mutating: argPtr.baseAddress),
                            UnsafeMutablePointer(mutating: envPtr.baseAddress)
                        )
                        _exit(127)
                    }
                    return pid
                }
            }
        }

        guard childPid > 0 else {
            let spawnErrno = errno
            if master >= 0 {
                Darwin.close(master)
            }
            throw Error.spawnFailed(errno: spawnErrno)
        }

        self.pid = childPid
        self.masterFD = master
        self.slaveTTYPath = Self.resolveSlaveTTYPath(masterFD: master)
        Self.logger.info("spawned shell \(shell, privacy: .public) argv=\(argvStrings.joined(separator: " "), privacy: .public) pid=\(childPid) cols=\(cols) rows=\(rows)")

        // Read loop: DispatchSource calls us every time the master FD has
        // bytes. `readAvailable()` drains the buffer non-blockingly.
        let rSrc = DispatchSource.makeReadSource(fileDescriptor: master, queue: ioQueue)
        rSrc.setEventHandler { [weak self] in self?.readAvailable() }
        rSrc.setCancelHandler { [weak self] in
            guard let self else { return }
            Darwin.close(self.masterFD)
        }
        self.readSource = rSrc
        rSrc.resume()

        // Watch child death — we translate it to a single `onExit` event.
        let xSrc = DispatchSource.makeProcessSource(
            identifier: childPid,
            eventMask: .exit,
            queue: ioQueue
        )
        xSrc.setEventHandler { [weak self] in self?.handleExit() }
        self.exitSource = xSrc
        xSrc.resume()
    }

    // MARK: - I/O

    /// Write raw bytes (typed keystrokes, paste content, control sequences)
    /// into the PTY master. No-op after `close()`.
    func write(_ data: Data) {
        guard !closed else { return }
        data.withUnsafeBytes { buf in
            guard let base = buf.baseAddress else { return }
            var total = 0
            while total < buf.count {
                let n = Darwin.write(masterFD, base.advanced(by: total), buf.count - total)
                if n < 0 {
                    if errno == EINTR { continue }
                    Self.logger.error("write failed errno=\(errno)")
                    return
                }
                total += n
            }
        }
    }

    /// Propagate SwiftTerm's geometry change to the kernel so the shell
    /// dispatches `SIGWINCH` to foreground programs (vim redraws, less
    /// repaginates, prompts rewrap).
    func resize(cols: Int, rows: Int) {
        guard !closed else { return }
        var ws = winsize(
            ws_row: UInt16(max(rows, 1)),
            ws_col: UInt16(max(cols, 1)),
            ws_xpixel: 0,
            ws_ypixel: 0
        )
        if ioctl(masterFD, UInt(TIOCSWINSZ), &ws) != 0 {
            Self.logger.error("TIOCSWINSZ failed errno=\(errno)")
            return
        }
        signalWindowSizeChanged()
    }

    private func signalWindowSizeChanged() {
        // A PTY without a controlling foreground process group may accept
        // TIOCSWINSZ without delivering SIGWINCH to fullscreen programs. Try the
        // terminal foreground pgrp first, then fall back to the shell pgrp we
        // created at spawn time.
        let foregroundPgrp = Darwin.tcgetpgrp(masterFD)
        if foregroundPgrp > 0, Darwin.kill(-foregroundPgrp, SIGWINCH) == 0 {
            return
        }
        if Darwin.kill(-pid, SIGWINCH) != 0 {
            Self.logger.error("SIGWINCH failed errno=\(errno)")
        }
    }

    /// SIGHUP the process group so the shell and its jobs (background ones
    /// included) terminate as if the user closed a Terminal tab. The actual
    /// FD close happens from the read source's cancel handler.
    func close() {
        guard !closed else { return }
        closed = true
        // Negative pid == process-group kill.
        _ = Darwin.kill(-pid, SIGHUP)
        readSource?.cancel()
        readSource = nil
        exitSource?.cancel()
        exitSource = nil
    }

    deinit {
        if !closed { close() }
    }

    // MARK: - Private

    private static func resolveSlaveTTYPath(masterFD: Int32) -> String? {
        guard let tty = Darwin.ptsname(masterFD) else { return nil }
        return String(cString: tty)
    }

    private func readAvailable() {
        // 8 KiB scratch buffer — big enough to drain bursts without starving
        // other PTYs on the same ioQueue.
        var buf = [UInt8](repeating: 0, count: 8 * 1024)
        let n = buf.withUnsafeMutableBufferPointer { bptr -> Int in
            guard let base = bptr.baseAddress else { return 0 }
            return Darwin.read(masterFD, base, bptr.count)
        }
        if n > 0 {
            let data = Data(buf[0..<n])
            onData?(data)
        } else if n == 0 {
            // EOF — child closed its side. Exit source will fire separately.
            readSource?.cancel()
            readSource = nil
        } else {
            if errno == EINTR || errno == EAGAIN { return }
            Self.logger.error("read failed errno=\(errno)")
            readSource?.cancel()
            readSource = nil
        }
    }

    private func handleExit() {
        var status: Int32 = 0
        let reaped = waitpid(pid, &status, WNOHANG)
        if reaped > 0 {
            Self.logger.info("pid=\(self.pid) exited status=\(status)")
            onExit?(status)
        }
        exitSource?.cancel()
        exitSource = nil
    }

    private static func argv(forShellName shellName: String, login: Bool) -> [String] {
        if login {
            return [shellName, "-l", "-i"]
        }
        return [shellName, "-i"]
    }

    private static let defaultBashPrompt = "\\[\\e[32m\\]soyeht\\[\\e[0m\\] \\[\\e[36m\\]\\W\\[\\e[0m\\] \\$ "
}
