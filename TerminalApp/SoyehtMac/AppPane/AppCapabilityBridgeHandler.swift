import Foundation
import os
import WebKit

/// The Phase 2b capability bridge (contract docs/capability-bridge-phase2b.md
/// §2). Installed ONLY on app-pane configurations — the Phase 1 web pane
/// never calls `install(on:)`, and the absence of the handler is the
/// control, not a runtime flag.
///
/// What makes this safe:
/// - The handler lives in a NAMED content world; page JS cannot see,
///   enumerate, or overwrite the channel. The app reaches it through a
///   relay user script that shuttles DOM CustomEvents between worlds
///   (the DOM is shared; the JS globals are not).
/// - The relay is injected `forMainFrameOnly: true`: a subframe has NO
///   code in the world where the handler lives. The `isMainFrame` check
///   below is then a second layer, not the only one (about:blank/srcdoc
///   subframes INHERIT the parent's origin and would pass an origin-only
///   check — this is the failure that leaked OAuth tokens in the
///   react-native-webview / Home Assistant class).
/// - Authority comes ONLY from what WebKit reports (world, frameInfo) —
///   never from the message body. Reading an app id, capability name, or
///   token from the body to decide authority would be confused-deputy by
///   construction.
///
/// Validation order is contractual and happens before any dispatch:
///   1. the message's world is the bridge world (measured: observable);
///   2. `frameInfo.isMainFrame`;
///   3. `frameInfo.securityOrigin` equals, by EXACT triple
///      (scheme, host, port) — measured on custom schemes as
///      ("soyehtapp-<id>", "local", 0) — the pane's origin;
///   4. the origin has a non-empty host;
///   5. only then is the capability looked up, keyed by the OBSERVED
///      origin's app.
@MainActor
final class AppCapabilityBridgeHandler: NSObject, WKScriptMessageHandlerWithReply {
    static let worldName = "soyeht-bridge"
    static let handlerName = "soyehtBridge"
    static let bundleHost = "local"

    private static let logger = Logger(subsystem: "com.soyeht.mac", category: "app.bridge")

    private let paneID: Conversation.ID
    private let installID: String
    private let appID: String
    private var rateLimiter = CapabilityRateLimiter.metricsDefault
    private weak var userContentController: WKUserContentController?

    init(paneID: Conversation.ID, installID: String, appID: String) {
        self.paneID = paneID
        self.installID = installID
        self.appID = appID
    }

    // MARK: - Installation

    static var bridgeWorld: WKContentWorld {
        WKContentWorld.world(name: worldName)
    }

    /// The relay is the ONLY code the app can talk to, and it is transport,
    /// not policy: it forwards a CustomEvent detail to the native handler
    /// and dispatches the native reply back. All authorization is native.
    /// `forMainFrameOnly: true` is load-bearing — see the class doc.
    static let relayScript = WKUserScript(
        source: """
        (function () {
          if (window.__soyehtBridgeRelayInstalled) { return; }
          window.__soyehtBridgeRelayInstalled = true;
          window.addEventListener("soyeht.bridge.request", function (event) {
            if (!event.detail || typeof event.detail !== "object") { return; }
            var requestID = String(event.detail.id || "");
            var detail;
            try {
              // Normalize into this world before crossing to native —
              // a page-world object proxy can serialize surprisingly.
              detail = JSON.parse(JSON.stringify(event.detail));
            } catch (e) { return; }
            window.webkit.messageHandlers.soyehtBridge.postMessage(detail).then(function (result) {
              var response = (result && typeof result === "object") ? result : { ok: false, error: { code: "internal_error", message: "Empty bridge reply." } };
              response.id = requestID;
              window.dispatchEvent(new CustomEvent("soyeht.bridge.response", { detail: response }));
            }, function () {
              window.dispatchEvent(new CustomEvent("soyeht.bridge.response", {
                detail: { id: requestID, ok: false, error: { code: "internal_error", message: "Bridge request rejected." } }
              }));
            });
          });
        })();
        """,
        injectionTime: .atDocumentEnd,
        forMainFrameOnly: true,
        in: bridgeWorld
    )

    func install(on configuration: WKWebViewConfiguration) {
        let ucc = configuration.userContentController
        ucc.addScriptMessageHandler(self, contentWorld: Self.bridgeWorld, name: Self.handlerName)
        ucc.addUserScript(Self.relayScript)
        userContentController = ucc
    }

    /// Teardown is structural, not a boolean: the handler is REMOVED, so a
    /// closed pane cannot keep serving capability calls.
    func tearDown() {
        userContentController?.removeScriptMessageHandler(forName: Self.handlerName, contentWorld: Self.bridgeWorld)
        userContentController = nil
    }

    // MARK: - WKScriptMessageHandlerWithReply

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage,
        replyHandler: @escaping (Any?, String?) -> Void
    ) {
        let origin = message.frameInfo.securityOrigin
        let observedOrigin = "\(origin.protocol)://\(origin.host)\(origin.port != 0 ? ":\(origin.port)" : "")"

        func audit(_ result: CapabilityAuditEntry.Result, command: String) {
            CapabilityAuditLog.record(
                paneID: paneID.uuidString,
                origin: observedOrigin,
                appID: appID,
                command: command,
                result: result
            )
        }

        // Steps 1-4: principal validation, in contract order. Every failure
        // here is a denial — and denials are audited, because a log that
        // only records success cannot detect an attack.
        guard message.world.name == Self.worldName else {
            Self.logger.error("bridge_wrong_world pane=\(self.paneID.uuidString, privacy: .public)")
            replyHandler(nil, "wrong world")
            return
        }
        guard message.frameInfo.isMainFrame else {
            // The iframe case — the acceptance test that defines the phase.
            audit(.denied, command: "subframe")
            Self.logger.log("bridge_deny_subframe pane=\(self.paneID.uuidString, privacy: .public)")
            replyHandler(Self.wire(CapabilityResponse.failure(id: "", error: .notGranted)), nil)
            return
        }
        guard origin.host == Self.bundleHost,
              origin.protocol == AppBundleSchemeHandler.scheme(for: appID),
              origin.port == 0,
              !origin.host.isEmpty else {
            Self.logger.error("bridge_wrong_origin pane=\(self.paneID.uuidString, privacy: .public) origin=\(observedOrigin, privacy: .public)")
            audit(.denied, command: "foreign-origin")
            replyHandler(Self.wire(CapabilityResponse.failure(id: "", error: .notGranted)), nil)
            return
        }

        // The body decides WHAT is being asked, never WHO is asking.
        let request: CapabilityRequest
        do {
            let bodyData = try JSONSerialization.data(withJSONObject: message.body)
            request = try CapabilityRequest.decode(bodyData)
        } catch let error as CapabilityRequestError {
            audit(.malformed, command: "unparseable")
            replyHandler(Self.wire(CapabilityResponse.failure(id: "", error: Self.failure(for: error))), nil)
            return
        } catch {
            audit(.malformed, command: "unparseable")
            replyHandler(Self.wire(CapabilityResponse.failure(id: "", error: .malformed)), nil)
            return
        }

        // Step 5: capability lookup keyed by the OBSERVED principal.
        guard AppCapabilityPolicy.allows(installID: installID, command: request.command) else {
            audit(.denied, command: request.command.rawValue)
            Self.logger.log("bridge_deny_not_granted pane=\(self.paneID.uuidString, privacy: .public) command=\(request.command.rawValue, privacy: .public)")
            replyHandler(Self.wire(CapabilityResponse.failure(for: request, error: .notGranted)), nil)
            return
        }

        guard rateLimiter.allow(key: paneID.uuidString) else {
            audit(.rateLimited, command: request.command.rawValue)
            replyHandler(Self.wire(CapabilityResponse.failure(for: request, error: .rateLimited)), nil)
            return
        }

        // Dispatch on the CLOSED command enum. A collector throw maps to
        // internalError — never a sentinel value inside the valid domain
        // (the getloadavg lesson: zeros are how real bugs hide).
        switch request.command {
        case .metricsRead:
            do {
                let snapshot = try SystemMetricsCollector.snapshot()
                audit(.allowed, command: request.command.rawValue)
                replyHandler(Self.wire(CapabilityResponse.success(for: request, result: .metricsRead(snapshot))), nil)
            } catch {
                Self.logger.error("bridge_collector_failed pane=\(self.paneID.uuidString, privacy: .public)")
                audit(.denied, command: request.command.rawValue)
                replyHandler(Self.wire(CapabilityResponse.failure(for: request, error: .internalError)), nil)
            }
        }
    }

    // MARK: - Wire shapes

    /// Failure-code mapping for envelope decode refusals. Missing keys and
    /// invalid ids are malformed envelopes, not new vocabulary.
    private static func failure(for error: CapabilityRequestError) -> CapabilityFailure {
        switch error {
        case .tooLarge(let limit): return .tooLarge(limitBytes: limit)
        case .unknownCommand: return .unknownCommand
        case .unsupportedVersion: return .unsupportedVersion
        case .malformed, .unknownKey, .missingKey, .invalidID: return .malformed
        }
    }

    /// Serializes the response envelope through JSON so only
    /// WebKit-reply-safe types (NSDictionary/NSArray/NSString/NSNumber)
    /// cross the boundary.
    private static func wire(_ response: CapabilityResponse) -> [String: Any] {
        guard let data = try? JSONEncoder().encode(response),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else {
            return ["v": 1, "id": "", "ok": false, "error": ["code": "internal_error", "message": "The request could not be completed."]]
        }
        return dictionary
    }
}
