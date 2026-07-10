#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
repo_root="$(cd "${script_dir}/.." && pwd -P)"
probe="${repo_root}/TerminalApp/SoyehtTests/MobileClawVPNOwnerPresentProbeTests.swift"
project="${repo_root}/TerminalApp/Soyeht.xcodeproj/project.pbxproj"

python3 - "${probe}" "${project}" <<'PY'
import pathlib
import re
import sys

probe_path = pathlib.Path(sys.argv[1])
project_path = pathlib.Path(sys.argv[2])
source = probe_path.read_text(encoding="utf-8")
project = project_path.read_text(encoding="utf-8")

assert "import SoyehtCore" in source
assert "@testable import SoyehtCore" not in source
assert "extension MobileClawVPNStatusResponse: ProbeStatusSource {}" in source
assert (
    "extension MobileClawVPNRendezvousAuthorization: ProbeAuthorizationSource {}"
    in source
)
assert source.count("MobileClawVPNRendezvousViewModel()") == 1
assert "await viewModel.authorize(" in source
assert "deviceId: input.deviceID" in source
assert "clawId: input.clawID" in source
assert "MobileClawVPNRendezvousAuthorization(" not in source

for forbidden in (
    "SoyehtAPIClient", "URLProtocol", "MockURLProtocol",
    "mobileClawVPNStatus", "mobileClawVPNMintOffer",
    "mobileClawVPNConsumeOffer", "mobileClawVPNAuthorizeRendezvous",
    "ProcessInfo.processInfo.environment", "CommandLine.arguments",
    "UserDefaults", "print(", "debugPrint(", "os_log(", "Logger(",
    "XCTAttachment", "XCTContext.runActivity",
):
    assert forbidden not in source, forbidden

consume_start = source.index("private func consumeInput(")
consume_end = source.index("private func writeResult(", consume_start)
consume = source[consume_start:consume_end]
assert "O_RDONLY | O_NOFOLLOW" in consume
assert "metadata.st_nlink == 1" in consume
assert consume.index("unlink(inputURL.path)") < consume.index("decodeCanonical(")
assert "fsync(parent)" in consume

run_start = source.index("func testRunOwnerPresentControlPlane()")
run_end = source.index("func testProbeInputIsStrictAndConsumedBeforeUse()", run_start)
run = source[run_start:run_end]
assert run.index('Bundle.main.bundleIdentifier == "com.soyeht.app.dev"') < run.index(
    "fileExists(atPath: directory.path)"
)
assert run.index("consumeInput(") < run.index("MobileClawVPNRendezvousViewModel()")
assert run.index("MobileClawVPNRendezvousViewModel()") < run.index("viewModel.authorize(")
assert run.index("viewModel.authorize(") < run.index("case let .authorized")
assert run.index("case let .authorized") < run.index(
    "ProbeAuthorizationSnapshot(authorization: authorization)"
)
assert run.index("ProbeAuthorizationSnapshot(authorization: authorization)") < run.index(
    "writeResult(result"
)

snapshot_start = source.index(
    "init<Authorization: ProbeAuthorizationSource>(authorization: Authorization)"
)
snapshot_end = source.index("\n    }\n\n    private struct ProbeStatusFixture", snapshot_start)
snapshot = source[snapshot_start:snapshot_end]
for required in (
    "authorized = authorization.authorized",
    "authorization.productionActivation",
    "authorization.status.productionActivation",
    "authorization.status.snapshotPresent",
    "authorization.status.enrolledDeviceCount",
    "authorization.status.availableClawCount",
    "authorization.status.grantCount",
    "authorization.status.offerCount",
    "authorization.status.sessionCount",
):
    assert required in snapshot, required
assert re.search(r"authorization\.(product|mode|operation)\b", snapshot) is None

assert "O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW" in source
assert "controlPlaneSequenceCompleted: true" in source
assert "rawValuesPrinted: false" in source
assert source.count("MobileClawVPNOwnerPresentProbeTests.swift") == 0
assert project.count("MobileClawVPNOwnerPresentProbeTests.swift") == 6
assert "MobileClawVPNOwnerPresentProbeTests.swift in Sources" in project

print("mobile Claw VPN DEV E2E probe source boundary passed")
PY
