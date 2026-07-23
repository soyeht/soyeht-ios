import Darwin
import Foundation
import SoyehtCore
import os

// libproc (part of libSystem; no extra linkage). Used to enumerate every
// process still attached to a pane's TTY at close time — job control puts
// each shell job in its own process group, so killing the shell's pgid alone
// misses agent CLIs (the historical source of leaked `claude` orphans).
@_silgen_name("proc_listpids")
private func soyeht_proc_listpids(
    _ type: UInt32,
    _ typeinfo: UInt32,
    _ buffer: UnsafeMutableRawPointer?,
    _ buffersize: Int32
) -> Int32

@_silgen_name("proc_pidinfo")
private func soyeht_proc_pidinfo(
    _ pid: pid_t,
    _ flavor: Int32,
    _ arg: UInt64,
    _ buffer: UnsafeMutableRawPointer?,
    _ buffersize: Int32
) -> Int32

/// `PROC_TTY_ONLY` from <sys/proc_info.h>.
private let procTTYOnly: UInt32 = 3

/// `PROC_PIDLISTFDS` and `PROX_FDTYPE_VNODE` from <sys/proc_info.h>.
private let procPIDListFDs: Int32 = 1
private let procFDTypeVnode: UInt32 = 1

private struct SoyehtProcFDInfo {
    var procFD: Int32
    var procFDType: UInt32
}

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
    /// this PID the initial process-group ID as well.
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

    /// Input bytes accepted but not yet written to the master (ioQueue-only).
    /// The master is O_NONBLOCK and writes never loop: when the kernel input
    /// queue is full (a TUI blocked on its own stdout stops reading stdin),
    /// the remainder waits here for a write source instead of wedging the
    /// ioQueue — a blocking input write on the same serial queue as the read
    /// source deadlocked the whole pane (child stuck in write(2), reader
    /// starved, each waiting on the other).
    private var pendingInput = Data()
    private var writeSource: DispatchSourceWrite?
    private static let maxPendingInputBytes = 4 * 1024 * 1024

    /// Guards `readSuspended`/`closed` transitions. `pauseReading()` and
    /// `resumeReading()` may be called from any thread (the feed bridge calls
    /// them from main and from `ioQueue`); a suspended source must be resumed
    /// exactly once before `cancel()` or GCD traps.
    private let stateLock = NSLock()
    private var readSuspended = false

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
    init(
        shellPath: String? = nil,
        cwd: URL,
        cols: Int,
        rows: Int,
        loginPath: String? = nil,
        extraEnvironment: [String: String] = [:]
    ) throws {
        let plan = Self.resolveSpawnPlan(
            shellPath: shellPath,
            cwd: cwd,
            loginPath: loginPath,
            extraEnvironment: extraEnvironment
        )
        let shell = plan.shell

        // Open a real controlling PTY with the right initial size so the first
        // screen-filling program sees a sane geometry (vim, less, htop).
        var master: Int32 = -1
        var ws = winsize(
            ws_row: UInt16(max(rows, 1)),
            ws_col: UInt16(max(cols, 1)),
            ws_xpixel: 0,
            ws_ypixel: 0
        )

        // argv[0] conventionally matches the shell basename so `ps` / `$0`
        // show `bash` not `/bin/bash` (see `resolveSpawnPlan`).
        let argvStrings = plan.argv
        let argv: [UnsafeMutablePointer<CChar>?] = argvStrings.map { strdup($0) } + [nil]
        defer { argv.forEach { if let p = $0 { free(p) } } }

        let envDict = plan.env
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

        // Non-blocking master: reads already tolerate EAGAIN, and writes must
        // never block the ioQueue (see `pendingInput`).
        let fdFlags = fcntl(master, F_GETFL)
        if fdFlags >= 0 {
            _ = fcntl(master, F_SETFL, fdFlags | O_NONBLOCK)
        }
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
        guard !data.isEmpty else { return }
        ioQueue.async { [weak self] in
            guard let self, !self.closed else { return }
            if self.pendingInput.count + data.count > Self.maxPendingInputBytes {
                Self.logger.error("pending input over \(Self.maxPendingInputBytes) bytes; dropping \(data.count)-byte write (child not reading stdin)")
                return
            }
            self.pendingInput.append(data)
            self.flushPendingInput()
        }
    }

    /// ioQueue-only. Writes as much pending input as the kernel accepts; on a
    /// full input queue (EAGAIN) arms a write source and returns immediately
    /// so the read source keeps draining output on this same queue.
    private func flushPendingInput() {
        guard !closed else { return }
        while !pendingInput.isEmpty {
            let n = pendingInput.withUnsafeBytes { buf -> Int in
                guard let base = buf.baseAddress else { return 0 }
                return Darwin.write(masterFD, base, buf.count)
            }
            if n > 0 {
                pendingInput.removeFirst(n)
            } else if n < 0 && errno == EINTR {
                continue
            } else if n < 0 && errno == EAGAIN {
                armWriteSource()
                return
            } else {
                Self.logger.error("write failed errno=\(errno)")
                pendingInput.removeAll()
                break
            }
        }
        stateLock.lock()
        writeSource?.cancel()
        writeSource = nil
        stateLock.unlock()
    }

    private func armWriteSource() {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !closed, writeSource == nil else { return }
        let src = DispatchSource.makeWriteSource(fileDescriptor: masterFD, queue: ioQueue)
        src.setEventHandler { [weak self] in self?.flushPendingInput() }
        writeSource = src
        src.resume()
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

    /// Stop draining the PTY master. The kernel buffer (~64 KiB) then fills and
    /// the foreground program blocks in `write()` — genuine terminal flow
    /// control, same contract xterm.js/VS Code use (`pty.pause()`), applied when
    /// the UI consumer falls behind. Must be paired with `resumeReading()`;
    /// short pauses are invisible to the child.
    func pauseReading() {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !closed, !readSuspended, let src = readSource else { return }
        readSuspended = true
        src.suspend()
    }

    /// Resume draining after `pauseReading()`. Safe to call redundantly.
    func resumeReading() {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard readSuspended, let src = readSource else { return }
        readSuspended = false
        src.resume()
    }

    /// SIGHUP the terminal-facing processes so the shell and its jobs
    /// terminate as if the user closed a Terminal tab. The actual FD close
    /// happens from the read source's cancel handler.
    ///
    /// Agent CLIs in raw mode (claude, some node TUIs) ignore SIGHUP, which
    /// used to leak them as detached orphans after the pane closed — so after
    /// a grace period surviving terminal jobs are escalated to SIGTERM and
    /// finally SIGKILL. Pipe/socket-backed helpers are deliberately excluded:
    /// MCP servers inherit the controlling TTY but communicate with their
    /// owning client over private stdio. Killing them independently drops the
    /// client's tool transport; killing the client closes those pipes and lets
    /// helpers exit naturally.
    func close() {
        stateLock.lock()
        if closed {
            stateLock.unlock()
            return
        }
        closed = true
        // Snapshot terminal-facing jobs before the master closes — afterwards
        // the TTY association is revoked and survivors become unfindable.
        var terminalPIDs = Self.terminalProcessPIDs(on: slaveTTYPath)
        if !terminalPIDs.contains(pid) {
            terminalPIDs.append(pid)
        }
        Self.signalProcesses(terminalPIDs, signal: SIGHUP)
        if readSuspended, let src = readSource {
            readSuspended = false
            src.resume()
        }
        writeSource?.cancel()
        writeSource = nil
        stateLock.unlock()
        readSource?.cancel()
        readSource = nil
        exitSource?.cancel()
        exitSource = nil
        Self.scheduleTerminationEscalation(leaderPID: pid, terminalPIDs: terminalPIDs)
    }

    /// Every terminal-facing pid whose controlling terminal is `ttyPath`.
    /// `PROC_TTY_ONLY` alone is too broad: MCP servers inherit the controlling
    /// TTY even though stdin/stdout are pipes or sockets to the agent client.
    /// Requiring fd 0 or 1 to be a vnode keeps real terminal jobs in the reap
    /// set while leaving those helpers to their normal parent/EOF lifecycle.
    private static func terminalProcessPIDs(on ttyPath: String?) -> [pid_t] {
        guard let ttyPath else { return [] }
        var st = stat()
        guard stat(ttyPath, &st) == 0 else { return [] }
        let ttyDev = UInt32(st.st_rdev)
        let byteCount = soyeht_proc_listpids(procTTYOnly, ttyDev, nil, 0)
        guard byteCount > 0 else { return [] }
        let capacity = Int(byteCount) / MemoryLayout<pid_t>.size + 8
        var pids = [pid_t](repeating: 0, count: capacity)
        let written = pids.withUnsafeMutableBytes { buf in
            soyeht_proc_listpids(procTTYOnly, ttyDev, buf.baseAddress, Int32(buf.count))
        }
        guard written > 0 else { return [] }
        return Array(pids.prefix(Int(written) / MemoryLayout<pid_t>.size))
            .filter { $0 > 0 && hasTerminalStandardIO($0) }
    }

    static func hasTerminalStandardIO(_ processID: pid_t) -> Bool {
        let byteCount = soyeht_proc_pidinfo(processID, procPIDListFDs, 0, nil, 0)
        // Preserve the historical reap behavior if libproc cannot classify a
        // process; exclusion is reserved for a positive pipe/socket finding.
        guard byteCount > 0 else { return true }

        let capacity = Int(byteCount) / MemoryLayout<SoyehtProcFDInfo>.stride + 8
        var descriptors = [SoyehtProcFDInfo](
            repeating: SoyehtProcFDInfo(procFD: -1, procFDType: 0),
            count: capacity
        )
        let written = descriptors.withUnsafeMutableBytes { buffer in
            soyeht_proc_pidinfo(
                processID,
                procPIDListFDs,
                0,
                buffer.baseAddress,
                Int32(buffer.count)
            )
        }
        guard written > 0 else { return true }

        let count = Int(written) / MemoryLayout<SoyehtProcFDInfo>.stride
        return descriptors.prefix(count).contains { descriptor in
            (descriptor.procFD == STDIN_FILENO || descriptor.procFD == STDOUT_FILENO)
                && descriptor.procFDType == procFDTypeVnode
        }
    }

    private static func signalProcesses(_ processIDs: [pid_t], signal: Int32) {
        for processID in Set(processIDs) where Darwin.kill(processID, 0) == 0 {
            _ = Darwin.kill(processID, signal)
        }
    }

    /// SIGHUP → (2s) SIGTERM → (2s) SIGKILL for whatever survives of the
    /// pane's terminal-facing processes. Reaps the leader along the way.
    /// Captures only values, so it is safe to schedule from `deinit`.
    private static func scheduleTerminationEscalation(
        leaderPID: pid_t,
        terminalPIDs: [pid_t]
    ) {
        let queue = DispatchQueue.global(qos: .utility)

        func signalSurvivors(_ sig: Int32) -> Bool {
            var survivors: [pid_t] = []
            for processID in Set(terminalPIDs) where Darwin.kill(processID, 0) == 0 {
                survivors.append(processID)
            }
            signalProcesses(survivors, signal: sig)
            return !survivors.isEmpty
        }

        queue.asyncAfter(deadline: .now() + 2) {
            var status: Int32 = 0
            _ = waitpid(leaderPID, &status, WNOHANG)
            guard signalSurvivors(SIGTERM) else { return }
            logger.notice("pane processes survived SIGHUP; sent SIGTERM")
            queue.asyncAfter(deadline: .now() + 2) {
                var status2: Int32 = 0
                _ = waitpid(leaderPID, &status2, WNOHANG)
                guard signalSurvivors(SIGKILL) else { return }
                logger.warning("pane processes survived SIGTERM; sent SIGKILL")
                queue.asyncAfter(deadline: .now() + 1) {
                    var status3: Int32 = 0
                    _ = waitpid(leaderPID, &status3, WNOHANG)
                }
            }
        }
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

    // MARK: - Spawn plan (shared with the engine-broker path)

    /// Fully-resolved shell/argv/env for spawning a local pane's interactive
    /// shell. `shell` is the full path actually executed (`execve`'s target);
    /// `argv` is what the child sees as its argument vector (`argv[0]` is
    /// just the basename, for `ps`/`$0` cosmetics — POSIX doesn't require it
    /// to match the exec path).
    struct SpawnPlan: Equatable {
        let shell: String
        let argv: [String]
        let env: [String: String]
    }

    /// Pure computation of `SpawnPlan`, factored out of `init` so the
    /// engine-broker path (persistent panes) can build byte-for-byte
    /// identical `{argv, cwd, env}` for `POST /terminals/local` without
    /// duplicating this logic and risking drift.
    static func resolveSpawnPlan(
        shellPath: String? = nil,
        cwd: URL,
        loginPath: String? = nil,
        extraEnvironment: [String: String] = [:],
        inheritedEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) -> SpawnPlan {
        let debugShellOverride = inheritedEnvironment["SOYEHT_LOCAL_SHELL"]
        let shell = shellPath
            ?? debugShellOverride
            ?? "/bin/bash"
        let usesDebugShellOverride = shellPath == nil && debugShellOverride != nil
        let shellName = (shell as NSString).lastPathComponent

        // The default is an interactive non-login shell: bash reads
        // ~/.bashrc but skips heavier login hooks such as conda/rvm in
        // ~/.bash_profile. Set SOYEHT_LOCAL_SHELL_LOGIN=1 when comparing
        // against Terminal.app.
        let wantsLoginShell = inheritedEnvironment["SOYEHT_LOCAL_SHELL_LOGIN"] == "1"
        let argvStrings = argv(forShellName: shellName, login: wantsLoginShell)

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
            envDict["PS1"] = inheritedEnvironment["SOYEHT_LOCAL_PS1"] ?? defaultBashPrompt
        }
        if !wantsLoginShell, let loginPath {
            envDict["PATH"] = loginPath
        }
        for (key, value) in extraEnvironment {
            guard !key.isEmpty, !value.isEmpty else { continue }
            envDict[key] = value
        }
        return SpawnPlan(shell: shell, argv: argvStrings, env: envDict)
    }
}
