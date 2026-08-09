import Foundation
import NatProbeFFI

@main
struct NatProbeFFISmoke {
    static func main() throws {
        let settings = natProbeDefaultSettings()
        print("NatProbeFFISmoke: linked, default servers = \(settings.server1), \(settings.server2)")

        let labels = NatProbeLabels(country: "BR", asn: nil, networkType: "ethernet")
        let observation = try natProbeObserve(settings: settings, labels: labels)
        // fullJson carries the real mapped/observed public IP — never print
        // it. This is a link/execution smoke check, not a sample collector;
        // an address-free summary is enough to prove observe() ran.
        print(
            "NatProbeFFISmoke: observe() ran — "
            + "network_type=\(observation.networkType ?? "unknown") "
            + "observed_at=\(observation.observedAt) "
            + "ipv6_available=\(observation.ipv6Available)"
        )
    }
}
