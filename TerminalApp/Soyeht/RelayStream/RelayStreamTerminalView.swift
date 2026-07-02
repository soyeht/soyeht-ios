import Foundation
import SwiftTerm
import UIKit
import os

final class RelayStreamTerminalView: TerminalView, TerminalViewDelegate {
    private static let logger = Logger(subsystem: "com.soyeht.mobile", category: "relay-stream")

    private var configuration: RelayStreamTerminalConfiguration?
    private var receiveTask: Task<Void, Never>?
    private var isOpen = false
    private var isFeedingServerData = false

    var urlOpener: any URLOpening = ConfirmingURLOpener.shared
    var onConnectionFailed: ((Error) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        terminalDelegate = self
        getTerminal().changeScrollback(5000)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        receiveTask?.cancel()
        if let session = configuration?.session {
            Task {
                try? await session.close()
            }
        }
    }

    func configure(configuration: RelayStreamTerminalConfiguration) {
        guard self.configuration?.id != configuration.id else { return }
        receiveTask?.cancel()
        self.configuration = configuration
        isOpen = true
        startReceiveLoop(session: configuration.session)
        DispatchQueue.main.async { [weak self] in
            _ = self?.becomeFirstResponder()
        }
    }

    private func startReceiveLoop(session: any RelayStreamTerminalSession) {
        receiveTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    let frame = try await session.nextFrame()
                    await MainActor.run {
                        self?.handle(frame)
                    }
                } catch {
                    await MainActor.run {
                        self?.closeFromError(error)
                    }
                    return
                }
            }
        }
    }

    private func handle(_ frame: RelayStreamTerminalFrame) {
        switch frame {
        case .data(let data):
            feedChunked([UInt8](data))
        case .window, .health, .open:
            break
        case .close:
            closeFromRemote(message: "Session closed.")
        case .exitCode(let code):
            closeFromRemote(message: "Process exited with code \(code).")
        case .exitSignal(let signal):
            closeFromRemote(message: "Process exited with signal \(signal).")
        case .exitLost:
            closeFromRemote(message: "Session ended.")
        case .error(let text):
            closeFromRemote(message: text.isEmpty ? "Relay stream error." : text)
        }
    }

    private func closeFromRemote(message: String) {
        isOpen = false
        receiveTask?.cancel()
        receiveTask = nil
        closeSession()
        feed(text: "\r\n[relay] \(message)\r\n")
        onConnectionFailed?(NSError(
            domain: "SoyehtRelayStream",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]
        ))
    }

    private func closeFromError(_ error: Error) {
        isOpen = false
        receiveTask?.cancel()
        receiveTask = nil
        closeSession()
        Self.logger.error("[relay] receive failed: \(error.localizedDescription, privacy: .public)")
        feed(text: "\r\n[relay] \(error.localizedDescription)\r\n")
        onConnectionFailed?(error)
    }

    private func closeSession() {
        guard let session = configuration?.session else { return }
        Task {
            try? await session.close()
        }
    }

    private func feedChunked(_ bytes: [UInt8]) {
        let chunkSize = 4096
        var offset = 0
        while offset < bytes.count {
            let end = min(offset + chunkSize, bytes.count)
            let chunk = bytes[offset..<end]
            isFeedingServerData = true
            feed(byteArray: chunk)
            isFeedingServerData = false
            offset = end
        }
    }

    override func insertText(_ text: String) {
        onSoftKeyboardInput?()
        var bytes: [UInt8] = []
        for byte in text.utf8 {
            if byte == 0x0A {
                bytes.append(contentsOf: returnByteSequence)
            } else {
                bytes.append(byte)
            }
        }
        sendRelayInput(Data(bytes))
    }

    override func send(source: Terminal, data: ArraySlice<UInt8>) {
        guard !isFeedingServerData else { return }
        super.send(source: source, data: data)
    }

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        sendRelayInput(Data(data))
    }

    private func sendRelayInput(_ bytes: Data) {
        guard isOpen, let session = configuration?.session else { return }
        Task { [weak self] in
            do {
                try await session.send(data: bytes)
            } catch {
                await MainActor.run {
                    self?.closeFromError(error)
                }
            }
        }
    }

    func scrolled(source: TerminalView, position: Double) {}
    func setTerminalTitle(source: TerminalView, title: String) {}

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        guard isOpen, let session = configuration?.session else { return }
        let cols = UInt16(clamping: newCols)
        let rows = UInt16(clamping: newRows)
        Task { [weak self] in
            do {
                try await session.resize(cols: cols, rows: rows)
            } catch {
                await MainActor.run {
                    self?.closeFromError(error)
                }
            }
        }
    }

    func clipboardCopy(source: TerminalView, content: Data) {
        ClipboardWriter.write(content, logger: Self.logger)
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        guard let url = TerminalLinkAllowlist.externalLinkURL(from: link) else {
            Self.logger.warning("[relay] blocked terminal link request")
            return
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.urlOpener.open(url, from: self)
        }
    }

    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}
