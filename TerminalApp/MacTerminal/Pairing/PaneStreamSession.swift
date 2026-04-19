import Foundation
import Network
import SoyehtCore
import os

private let paneStreamLogger = Logger(subsystem: "com.soyeht.mac", category: "presence")

/// One instance per iPhone→pane WS on the attach listener.
///
/// Flow:
/// 1. On connect, reads the first TEXT frame which must be
///    `{type:"attach_hello", nonce, device_id}`.
/// 2. Validates the nonce via `PaneAttachRegistry.consume(nonce:)`.
/// 3. On success, binds to the pane's `MacOSWebSocketTerminalView` (via
///    `PaneStatusTracker` lookup), sends a `local_handoff_ready` ACK, replays
///    the local scrollback, then proxies binary PTY frames in both directions.
@MainActor
final class PaneStreamSession {

    let id: UUID

    private let connection: NWConnection
    private let onTerminate: (UUID) -> Void

    private var boundPaneID: String?
    private var boundDeviceID: UUID?
    private var observerID: UUID?
    private weak var terminalView: MacOSWebSocketTerminalView?
    private var cancelled = false
    private var authenticated = false

    private let ioQueue = DispatchQueue(label: "com.soyeht.mac.pane-stream-session", qos: .userInitiated)

    init(
        id: UUID,
        connection: NWConnection,
        onTerminate: @escaping (UUID) -> Void
    ) {
        self.id = id
        self.connection = connection
        self.onTerminate = onTerminate
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in self?.handleState(state) }
        }
        connection.start(queue: ioQueue)
    }

    func cancel() {
        guard !cancelled else { return }
        cancelled = true
        if let observerID, let terminalView {
            terminalView.removeLocalOutputObserver(observerID)
        }
        observerID = nil
        connection.cancel()
    }

    private func handleState(_ state: NWConnection.State) {
        switch state {
        case .ready:
            receive()
        case .failed(let error):
            paneStreamLogger.error("pane_stream_failed session=\(self.id.uuidString, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            terminate()
        case .cancelled:
            terminate()
        default:
            break
        }
    }

    private func terminate() {
        guard !cancelled else { return }
        if let observerID, let terminalView {
            terminalView.removeLocalOutputObserver(observerID)
        }
        observerID = nil
        cancelled = true
        onTerminate(id)
    }

    private func receive() {
        connection.receiveMessage { [weak self] content, context, _, error in
            guard let self else { return }
            if error != nil {
                Task { @MainActor [weak self] in self?.terminate() }
                return
            }
            Task { @MainActor [weak self] in
                self?.processFrame(content: content, context: context)
            }
        }
    }

    private func processFrame(content: Data?, context: NWConnection.ContentContext?) {
        guard !cancelled else { return }

        guard let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition)
                as? NWProtocolWebSocket.Metadata else {
            receive()
            return
        }

        switch metadata.opcode {
        case .text:
            if let content, let text = String(data: content, encoding: .utf8) {
                handleText(text)
            }
        case .binary:
            if authenticated, let content, let view = terminalView {
                view.writeToLocalSession(content)
            }
        case .close:
            terminate()
            return
        default:
            break
        }
        receive()
    }

    private func handleText(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else { return }

        switch type {
        case "attach_hello":
            handleAttachHello(json)
        case PairingMessage.input:
            guard authenticated,
                  let payload = json["data"] as? String,
                  let view = terminalView else { return }
            view.writeToLocalSession(Data(payload.utf8))
        case PairingMessage.resize:
            guard authenticated,
                  let cols = json["cols"] as? Int,
                  let rows = json["rows"] as? Int,
                  let view = terminalView else { return }
            view.resizeLocalSession(cols: cols, rows: rows)
        default:
            paneStreamLogger.log("pane_stream_unknown_message type=\(type, privacy: .public)")
        }
    }

    private func handleAttachHello(_ json: [String: Any]) {
        guard let nonce = json["nonce"] as? String,
              let deviceIDStr = json["device_id"] as? String,
              let deviceID = UUID(uuidString: deviceIDStr) else {
            paneStreamLogger.log("attach_hello_malformed")
            sendClose(code: .protocolCode(.policyViolation))
            return
        }

        guard let entry = PaneAttachRegistry.shared.consume(nonce: nonce) else {
            paneStreamLogger.log("attach_nonce_invalid")
            sendClose(code: .protocolCode(.policyViolation))
            return
        }

        guard entry.deviceID == deviceID else {
            paneStreamLogger.log("attach_nonce_device_mismatch expected=\(entry.deviceID.uuidString, privacy: .public) actual=\(deviceID.uuidString, privacy: .public)")
            sendClose(code: .protocolCode(.policyViolation))
            return
        }

        guard let view = PaneStatusTracker.shared.terminalView(for: entry.paneID) else {
            paneStreamLogger.log("attach_pane_gone pane=\(entry.paneID, privacy: .public)")
            sendClose(code: .protocolCode(.policyViolation))
            return
        }

        boundPaneID = entry.paneID
        boundDeviceID = entry.deviceID
        terminalView = view
        authenticated = true

        paneStreamLogger.log("pane_stream_attached pane=\(entry.paneID, privacy: .public) device=\(entry.deviceID.uuidString, privacy: .public)")

        sendJSON([
            "type": PairingMessage.localHandoffReady,
            "pane_id": entry.paneID,
        ])

        observerID = view.addLocalOutputObserver { [weak self] data in
            self?.sendBinary(data)
        }

        let snapshot = view.localReplaySnapshot()
        if !snapshot.isEmpty {
            sendBinary(snapshot)
        }
    }

    private func sendJSON(_ object: [String: Any]) {
        guard !cancelled,
              let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else { return }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "pane-text", metadata: [metadata])
        connection.send(
            content: text.data(using: .utf8),
            contentContext: context,
            isComplete: true,
            completion: .contentProcessed { _ in }
        )
    }

    private func sendBinary(_ data: Data) {
        guard !cancelled, !data.isEmpty else { return }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .binary)
        let context = NWConnection.ContentContext(identifier: "pane-binary", metadata: [metadata])
        connection.send(
            content: data,
            contentContext: context,
            isComplete: true,
            completion: .contentProcessed { _ in }
        )
    }

    private func sendClose(code: NWProtocolWebSocket.CloseCode) {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .close)
        metadata.closeCode = code
        let context = NWConnection.ContentContext(identifier: "pane-close", metadata: [metadata])
        connection.send(content: nil, contentContext: context, isComplete: true, completion: .contentProcessed { [weak self] _ in
            self?.connection.cancel()
        })
    }
}
