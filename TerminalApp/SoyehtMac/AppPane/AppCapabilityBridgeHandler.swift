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
///      (the app scheme from `AppOrigin`, local, 0) — the pane's origin.
///      The scheme is named in `AppOrigin` and nowhere else, prose
///      included: a source guard requires that single mention, and
///      restating a format here is how 2b kept saying `<id>` long after
///      2a had moved to the install identity;
///   4. the origin has a non-empty host;
///   5. only then is the capability looked up, keyed by the OBSERVED
///      origin's app.
@MainActor
final class AppCapabilityBridgeHandler: NSObject, WKScriptMessageHandlerWithReply {
    static let worldName = AppBridgePrincipalValidator.worldName
    static let handlerName = "soyehtBridge"

    private static let logger = Logger(subsystem: "com.soyeht.mac", category: "app.bridge")

    private let paneID: Conversation.ID
    private let installID: String
    /// Named `appOrigin`, never `origin`: the validation scope below binds a
    /// local `origin` for the OBSERVED WKSecurityOrigin, and a member called
    /// `origin` would be shadowed by it — comparing the observed origin with
    /// itself, which passes always. The compiler caught it once; the name
    /// keeps it from being reintroduced.
    private let appOrigin: AppOrigin
    /// Audit metadata only. The declared id names the app for a human reading
    /// the log; it never selects an origin and never grants anything.
    private let declaredAppID: String
    private var rateLimiter = CapabilityRateLimiter.metricsDefault
    private weak var userContentController: WKUserContentController?

    init(paneID: Conversation.ID, record: AppInstallRecord) {
        self.paneID = paneID
        self.installID = record.installID
        self.appOrigin = record.origin
        self.declaredAppID = record.manifest.id
    }

    // MARK: - Installation

    static var bridgeWorld: WKContentWorld {
        WKContentWorld.world(name: worldName)
    }

    /// The relay is the ONLY code the app can talk to, and it is transport,
    /// not policy: it forwards a CustomEvent detail to the native handler
    /// and dispatches the native reply back. All authorization is native.
    /// `forMainFrameOnly: true` is load-bearing — see the class doc.
    ///
    /// Injected at DOCUMENT START so installation strictly precedes any
    /// script of the app — the 2b E2E measured that calls made during page
    /// load raced a document-end relay and met silence. With document-start
    /// injection the race cannot happen: once app code runs, the relay is
    /// already listening, and EVERY request gets a response (grant, denial,
    /// or error). Silence then has exactly one meaning — no bridge in this
    /// frame — which is also the subframe semantics.
    ///
    /// Readiness signal follows the readyState pattern (property AND event,
    /// never the event alone — a deferred script attaching after the event
    /// fired would never see it): the relay marks
    /// `document.documentElement[data-soyeht-bridge="ready"]` and dispatches
    /// `soyeht.bridge.ready`; consumers check the attribute FIRST, then
    /// listen.
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
          function announceReady() {
            var root = document.documentElement;
            if (root) { root.setAttribute("data-soyeht-bridge", "ready"); }
            window.dispatchEvent(new CustomEvent("soyeht.bridge.ready"));
          }
          if (document.readyState === "loading") {
            document.addEventListener("DOMContentLoaded", announceReady, { once: true });
          } else {
            announceReady();
          }
        })();
        """,
        injectionTime: .atDocumentStart,
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
        // Renamed from `userContentController`: the member of the same name
        // would be shadowed here, which is the shape that nearly disabled the
        // principal check via `origin`. Inert today only because the member is
        // unused in this method.
        _ controller: WKUserContentController,
        didReceive message: WKScriptMessage,
        replyHandler: @escaping (Any?, String?) -> Void
    ) {
        // Steps 1-4: principal validation, in contract order — the pure
        // validator owns the order, and the order is the confused-deputy
        // defense (domain-tested with synthetic fixtures, since the 2a CSP
        // makes a real subframe E2E-impossible by blocking frame loads).
        // Every failure here is a denial — and denials are audited, because
        // a log that only records success cannot detect an attack.
        let origin = message.frameInfo.securityOrigin
        let observedOrigin = "\(origin.protocol)://\(origin.host)\(origin.port != 0 ? ":\(origin.port)" : "")"

        func audit(_ result: CapabilityAuditEntry.Result, command: String) {
            CapabilityAuditLog.record(
                paneID: paneID.uuidString,
                origin: observedOrigin,
                appID: declaredAppID,
                command: command,
                result: result
            )
        }

        if let refusal = AppBridgePrincipalValidator.firstRefusal(
            worldName: message.world.name,
            isMainFrame: message.frameInfo.isMainFrame,
            scheme: origin.protocol,
            host: origin.host,
            port: origin.port,
            expectedWorldName: Self.worldName,
            expectedScheme: appOrigin.scheme,
            expectedHost: AppOrigin.host
        ) {
            switch refusal {
            case .wrongWorld:
                // Nothing about the message is trustworthy — log only.
                Self.logger.error("bridge_wrong_world pane=\(self.paneID.uuidString, privacy: .public)")
                replyHandler(nil, "wrong world")
            case .subframe:
                // The iframe case — the acceptance test that defines the phase.
                audit(.denied, command: AppBridgePrincipalRefusal.subframe.rawValue)
                Self.logger.log("bridge_deny_subframe pane=\(self.paneID.uuidString, privacy: .public)")
                replyHandler(Self.wire(CapabilityResponse.failure(id: "", error: .notGranted)), nil)
            case .foreignOrigin, .emptyHost:
                Self.logger.error("bridge_wrong_origin pane=\(self.paneID.uuidString, privacy: .public) origin=\(observedOrigin, privacy: .public)")
                audit(.denied, command: AppBridgePrincipalRefusal.foreignOrigin.rawValue)
                replyHandler(Self.wire(CapabilityResponse.failure(id: "", error: .notGranted)), nil)
            }
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
