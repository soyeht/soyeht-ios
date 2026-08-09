//! FFI wrapper around theyos's `nat-probe-rs` (M0a NAT mapping probe).
//!
//! Deliberately does not expose `NatObservation::servers` (the per-server
//! `ServerOutcome` detail): the plan's JSONL schema only needs the flattened
//! fields already on `NatObservation`, and `full_json` below carries the
//! complete upstream record for anyone who does want it, so nothing is lost
//! by not modeling the enum across the FFI boundary.
//!
//! `tunnel_interfaces` IS flattened, deliberately, unlike `servers`: upstream
//! records it because a row taken while a VPN is up may not describe the
//! network the caller thinks it's measuring, and that's exactly the
//! situation this app's own packet-tunnel extension can put a device in.
//! Leaving it buried in `full_json` only would silently drop the one signal
//! that explains a confounded sample.

uniffi::setup_scaffolding!();

#[derive(Clone, Eq, PartialEq, uniffi::Record)]
pub struct NatProbeSettings {
    pub server1: String,
    pub server2: String,
    pub timeout_ms: u32,
    pub attempts: u32,
}

impl Default for NatProbeSettings {
    fn default() -> Self {
        let defaults = nat_probe_rs::ProbeSettings::default();
        Self {
            server1: defaults.servers[0].clone(),
            server2: defaults.servers[1].clone(),
            timeout_ms: u32::try_from(defaults.timeout.as_millis()).unwrap_or(u32::MAX),
            attempts: defaults.attempts,
        }
    }
}

#[uniffi::export]
fn nat_probe_default_settings() -> NatProbeSettings {
    NatProbeSettings::default()
}

#[derive(Clone, Eq, PartialEq, Default, uniffi::Record)]
pub struct NatProbeLabels {
    pub country: Option<String>,
    pub asn: Option<String>,
    pub network_type: Option<String>,
}

#[derive(Clone, uniffi::Record)]
pub struct NatObservationRecord {
    pub observed_at: u64,
    pub country: Option<String>,
    pub asn: Option<String>,
    pub network_type: Option<String>,
    pub rtt_ms: Option<f64>,
    pub ipv6_available: bool,
    pub local_port: Option<u16>,
    pub mapped_ip_1: Option<String>,
    pub mapped_port_1: Option<u16>,
    pub mapped_ip_2: Option<String>,
    pub mapped_port_2: Option<u16>,
    pub mapping_consistent: Option<bool>,
    pub local_port_v6: Option<u16>,
    pub mapped_ip6_1: Option<String>,
    pub mapped_port6_1: Option<u16>,
    pub mapped_ip6_2: Option<String>,
    pub mapped_port6_2: Option<u16>,
    pub mapping_consistent_v6: Option<bool>,
    /// Non-empty means a tunnel-like interface (`utun`, `tun`, `ipsec`,
    /// `ppp`, `wg`) was up during this observation — a VPN, possibly this
    /// app's own, may have been active. Interface names carry no personal
    /// data, so they're safe to log directly, unlike the address fields
    /// above.
    pub tunnel_interfaces: Vec<String>,
    /// Full upstream `NatObservation`, serde-serialized with the plan's exact
    /// field names (`ipv6_disponivel`, `porta_local`, ...), including
    /// per-server detail this wrapper otherwise flattens away.
    pub full_json: String,
}

#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum NatProbeError {
    #[error("socket error: {message}")]
    Socket { message: String },
}

#[uniffi::export]
fn nat_probe_observe(
    settings: NatProbeSettings,
    labels: NatProbeLabels,
) -> Result<NatObservationRecord, NatProbeError> {
    let real_settings = nat_probe_rs::ProbeSettings {
        servers: [settings.server1, settings.server2],
        timeout: std::time::Duration::from_millis(u64::from(settings.timeout_ms)),
        attempts: settings.attempts,
    };
    let real_labels = nat_probe_rs::ProbeLabels {
        country: labels.country,
        asn: labels.asn,
        network_type: labels.network_type,
    };

    let observation =
        nat_probe_rs::observe(&real_settings, &real_labels).map_err(|error| NatProbeError::Socket {
            message: error.to_string(),
        })?;

    let full_json = serde_json::to_string(&observation).unwrap_or_default();

    Ok(NatObservationRecord {
        observed_at: observation.observed_at,
        country: observation.country,
        asn: observation.asn,
        network_type: observation.network_type,
        rtt_ms: observation.rtt_ms,
        ipv6_available: observation.ipv6_available,
        local_port: observation.local_port,
        mapped_ip_1: observation.mapped_ip_1.map(|ip| ip.to_string()),
        mapped_port_1: observation.mapped_port_1,
        mapped_ip_2: observation.mapped_ip_2.map(|ip| ip.to_string()),
        mapped_port_2: observation.mapped_port_2,
        mapping_consistent: observation.mapping_consistent,
        local_port_v6: observation.local_port_v6,
        mapped_ip6_1: observation.mapped_ip6_1.map(|ip| ip.to_string()),
        mapped_port6_1: observation.mapped_port6_1,
        mapped_ip6_2: observation.mapped_ip6_2.map(|ip| ip.to_string()),
        mapped_port6_2: observation.mapped_port6_2,
        mapping_consistent_v6: observation.mapping_consistent_v6,
        tunnel_interfaces: observation.tunnel_interfaces,
        full_json,
    })
}
