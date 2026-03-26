import UIKit
import SwiftTerm

public class WebSocketTerminalView: TerminalView, TerminalViewDelegate {
    private var webSocketTask: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    private var configuredURL: String?
    private var isConnected = false

    public override init(frame: CGRect) {
        super.init(frame: frame)
        terminalDelegate = self
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        disconnect()
    }

    // MARK: - Connection

    func configure(wsUrl: String) {
        guard configuredURL != wsUrl else { return }
        configuredURL = wsUrl

        disconnect()
        connect(wsUrl: wsUrl)
    }

    private func connect(wsUrl: String) {
        guard let url = URL(string: wsUrl) else {
            feed(text: "[ERROR] Invalid WebSocket URL\r\n")
            return
        }

        let config = URLSessionConfiguration.default
        urlSession = URLSession(configuration: config)
        webSocketTask = urlSession?.webSocketTask(with: url)
        webSocketTask?.resume()
        isConnected = true

        receiveLoop()

        DispatchQueue.main.async { [weak self] in
            self?.becomeFirstResponder()
        }
    }

    private func disconnect() {
        isConnected = false
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
    }

    // MARK: - Receive Loop

    private func receiveLoop() {
        webSocketTask?.receive { [weak self] result in
            guard let self, self.isConnected else { return }

            switch result {
            case .success(let message):
                switch message {
                case .data(let data):
                    let bytes = [UInt8](data)
                    self.feedChunked(bytes)
                case .string(let text):
                    if let data = text.data(using: .utf8) {
                        let bytes = [UInt8](data)
                        self.feedChunked(bytes)
                    }
                @unknown default:
                    break
                }
                self.receiveLoop()

            case .failure(let error):
                DispatchQueue.main.async {
                    self.feed(text: "\r\n[WS] Connection closed: \(error.localizedDescription)\r\n")
                }
                self.isConnected = false
            }
        }
    }

    private func feedChunked(_ bytes: [UInt8]) {
        let chunkSize = 4096
        var offset = 0
        while offset < bytes.count {
            let end = min(offset + chunkSize, bytes.count)
            let chunk = bytes[offset..<end]
            DispatchQueue.main.async { [weak self] in
                self?.feed(byteArray: chunk)
            }
            offset = end
        }
    }

    // MARK: - TerminalViewDelegate

    public func send(source: TerminalView, data: ArraySlice<UInt8>) {
        guard isConnected, let task = webSocketTask else { return }
        let bytes = Data(data)
        // JSON-wrapped input (matches xterm.js protocol: {"type":"input","data":"..."})
        if let text = String(data: bytes, encoding: .utf8),
           let jsonData = try? JSONSerialization.data(withJSONObject: ["type": "input", "data": text]),
           let json = String(data: jsonData, encoding: .utf8) {
            task.send(.string(json)) { _ in }
            return
        }
        // Fallback: send raw binary
        task.send(.data(bytes)) { error in
            if let error {
                DispatchQueue.main.async { [weak self] in
                    self?.feed(text: "\r\n[WS] Send error: \(error.localizedDescription)\r\n")
                }
            }
        }
    }

    public func scrolled(source: TerminalView, position: Double) {}
    public func setTerminalTitle(source: TerminalView, title: String) {}

    public func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        // Send resize as JSON control message
        guard isConnected, let task = webSocketTask else { return }
        let resize = "{\"type\":\"resize\",\"cols\":\(newCols),\"rows\":\(newRows)}"
        task.send(.string(resize)) { _ in }
    }

    public func clipboardCopy(source: TerminalView, content: Data) {
        if let str = String(bytes: content, encoding: .utf8) {
            UIPasteboard.general.string = str
        }
    }

    public func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    public func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        if let url = URL(string: link) {
            UIApplication.shared.open(url)
        }
    }

    public func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}
