import Foundation
import NatProbeFFI
import Network
import XCTest

/// M0a — NAT mapping probe run from a physical device. Plain UDP socket via
/// the vendored `nat-probe-rs`: no Network Extension entitlement, no VPN
/// configuration, so unlike M0b this needs no interactive system prompt.
final class NatProbeDeviceTests: XCTestCase {
    /// Simulator-safe, never skipped: proves the FFI binding actually links
    /// and runs, not just compiles. `natProbeDefaultSettings()` touches no
    /// network, so it's the right thing to assert on in CI — the two tests
    /// below skip on simulator and CI never invokes the Smoke target, so
    /// without this the ABI itself is never exercised by automation, only
    /// built.
    func testDefaultSettingsABI() throws {
        let settings = natProbeDefaultSettings()
        XCTAssertFalse(settings.server1.isEmpty)
        XCTAssertFalse(settings.server2.isEmpty)
        XCTAssertGreaterThan(settings.timeoutMs, 0)
        XCTAssertGreaterThan(settings.attempts, 0)
    }

    func testObserveFromCurrentNetwork() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Physical-device NAT sample collection only; a simulator run would attempt real STUN/DNS traffic and could record an invalid sample.")
        #else
        let networkType = try currentNetworkType(timeout: 5)
        guard networkType != "unknown" else {
            throw XCTSkip("Could not resolve a concrete network type; not recording an ambiguous sample.")
        }

        // Engine-side review of this probe: an all-empty NAT sample (v4 AND
        // v6, even DNS-over-UDP to a public literal) isn't NAT telemetry, it's
        // "no data path yet" — most likely the interface hadn't actually
        // attached right after a network toggle. Gate on a real TCP
        // connection first so we never record
        // a misleading empty row again; skip cleanly instead of guessing.
        let tcpReachable = try tcpReachability(host: "apple.com", port: 443, timeout: 10)
        print(
            "TCP_REACHABILITY_JSONL: "
            + "{\"network_type\":\"\(networkType)\",\"tcp_reachable\":\(tcpReachable)}"
        )
        guard tcpReachable else {
            // A print+return here would record XCTest PASS for a test that
            // verified nothing — throw XCTSkip so the run is honestly
            // reported as skipped, not green-by-accident.
            throw XCTSkip("No real data connectivity confirmed via TCP; not recording a NAT sample.")
        }

        let settings = natProbeDefaultSettings()
        let labels = NatProbeLabels(country: "BR", asn: nil, networkType: networkType)

        let observation = try natProbeObserve(settings: settings, labels: labels)

        // `fullJson` carries the device's real mapped/observed public IP.
        // The xcodebuild log is not a safe place for that (it gets grepped
        // into agent messages, pasted into chats, screenshotted) — the
        // complete record goes only into a local file excluded from backup,
        // never printed. A failure to persist it throws instead of failing
        // silently, so a green test can't mean "didn't actually record
        // anything."
        try appendLocalSample(jsonLine: observation.fullJson)

        let networkTypeField: String = observation.networkType ?? "unknown"
        let rttField: String = observation.rttMs.map { String($0) } ?? "null"
        let mappingConsistentField: String = observation.mappingConsistent.map { String($0) } ?? "null"
        let mappingConsistentV6Field: String = observation.mappingConsistentV6.map { String($0) } ?? "null"
        // Interface names (e.g. "utun4") carry no personal data, unlike the
        // address fields left out of this line — safe to log directly.
        // Non-empty here means a tunnel-like interface, possibly this app's
        // own claw-share extension, was up during the observation.
        let tunnelInterfacesField = "[" + observation.tunnelInterfaces
            .map { "\"\($0)\"" }
            .joined(separator: ",") + "]"
        let sanitizedLine: String = "{\"network_type\":\"\(networkTypeField)\","
            + "\"observed_at\":\(observation.observedAt),"
            + "\"rtt_ms\":\(rttField),"
            + "\"ipv6_available\":\(observation.ipv6Available),"
            + "\"mapping_consistent\":\(mappingConsistentField),"
            + "\"mapping_consistent_v6\":\(mappingConsistentV6Field),"
            + "\"tunnel_interfaces\":\(tunnelInterfacesField)}"
        print("NAT_PROBE_JSONL: " + sanitizedLine)

        XCTAssertGreaterThan(observation.observedAt, 0)
        #endif
    }

    private enum LocalSampleError: Error {
        case containerUnavailable
    }

    private func appendLocalSample(jsonLine: String) throws {
        // Caches, not Documents: Documents is backed up (iCloud/iTunes) by
        // default, and this file carries real observed public IPs — it must
        // never leave the device. Caches is excluded from backup by
        // definition, no extra flag needed.
        guard let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        else { throw LocalSampleError.containerUnavailable }
        let file = dir.appendingPathComponent("m0a-nat-probe-samples.jsonl")
        let line = Data((jsonLine + "\n").utf8)
        if let handle = try? FileHandle(forWritingTo: file) {
            _ = try handle.seekToEnd()
            try handle.write(contentsOf: line)
            try handle.close()
        } else {
            try line.write(to: file)
        }
    }

    private func tcpReachability(host: String, port: UInt16, timeout: TimeInterval) throws -> Bool {
        let queue = DispatchQueue(label: "com.soyeht.mobile.natprobe.tcp")
        let connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port)!,
            using: .tcp
        )
        let semaphore = DispatchSemaphore(value: 0)
        var reachable = false

        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                reachable = true
                semaphore.signal()
            case .failed, .cancelled:
                semaphore.signal()
            default:
                break
            }
        }
        connection.start(queue: queue)
        _ = semaphore.wait(timeout: .now() + timeout)
        connection.cancel()
        return reachable
    }

    /// Distinguishes "IPv4 is unreachable at the IP layer" (IPv6-only host,
    /// no/failing CLAT) from "these specific STUN destinations are blocked":
    /// sends a minimal DNS query, by IPv4 and IPv6 LITERAL address (no name
    /// resolution involved), to a destination almost nothing blocks. If both
    /// literals fail the same way STUN did, that points at the network path
    /// itself rather than those two STUN servers/ports specifically.
    func testLiteralAddressReachabilityOnCurrentNetwork() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Physical-device NAT sample collection only; a simulator run would attempt real STUN/DNS traffic and could record an invalid sample.")
        #else
        let v4Reachable = try literalUDPReachability(host: "1.1.1.1", timeout: 3)
        let v6Reachable = try literalUDPReachability(host: "2606:4700:4700::1111", timeout: 3)
        let networkType = try currentNetworkType(timeout: 5)

        print(
            "LITERAL_REACHABILITY_JSONL: "
            + "{\"network_type\":\"\(networkType)\","
            + "\"v4_literal_reachable\":\(v4Reachable),"
            + "\"v6_literal_reachable\":\(v6Reachable)}"
        )
        #endif
    }

    private func literalUDPReachability(host: String, timeout: TimeInterval) throws -> Bool {
        let queue = DispatchQueue(label: "com.soyeht.mobile.natprobe.literal")
        let connection = NWConnection(host: NWEndpoint.Host(host), port: 53, using: .udp)
        let semaphore = DispatchSemaphore(value: 0)
        var reachable = false

        // Minimal DNS query for example.com/A, transaction id 0x1234. DNS-over-UDP:53
        // to a public literal is about as close to "almost nothing blocks this" as
        // a single packet gets.
        let query: [UInt8] = [
            0x12, 0x34,
            0x01, 0x00,
            0x00, 0x01,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x07, 0x65, 0x78, 0x61, 0x6D, 0x70, 0x6C, 0x65,
            0x03, 0x63, 0x6F, 0x6D,
            0x00,
            0x00, 0x01,
            0x00, 0x01,
        ]

        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                connection.send(
                    content: Data(query),
                    completion: .contentProcessed { _ in
                        connection.receiveMessage { data, _, _, _ in
                            if let data, !data.isEmpty {
                                reachable = true
                            }
                            semaphore.signal()
                        }
                    }
                )
            case .failed:
                semaphore.signal()
            default:
                break
            }
        }
        connection.start(queue: queue)
        _ = semaphore.wait(timeout: .now() + timeout)
        connection.cancel()
        return reachable
    }

    private func currentNetworkType(timeout: TimeInterval) throws -> String {
        let monitor = NWPathMonitor()
        let semaphore = DispatchSemaphore(value: 0)
        var result = "unknown"

        monitor.pathUpdateHandler = { path in
            defer { semaphore.signal() }
            guard path.status == .satisfied else { return }
            if path.usesInterfaceType(.wifi) {
                result = "wifi"
            } else if path.usesInterfaceType(.cellular) {
                // `isExpensive` flags any costly network (LTE included, not
                // just 5G) — it is not a radio-generation signal. Recording
                // it as "5g" mislabels ordinary LTE samples. There is no
                // public API for the actual generation without a
                // CoreTelephony entitlement this app doesn't have, so record
                // the honest, coarser label instead of a guess.
                result = "cellular"
            } else if path.usesInterfaceType(.wiredEthernet) {
                result = "ethernet"
            }
        }
        let queue = DispatchQueue(label: "com.soyeht.mobile.natprobe.pathmonitor")
        monitor.start(queue: queue)
        defer { monitor.cancel() }

        _ = semaphore.wait(timeout: .now() + timeout)
        return result
    }
}
