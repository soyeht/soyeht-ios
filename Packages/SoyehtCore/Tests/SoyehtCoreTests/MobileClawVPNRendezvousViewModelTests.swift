import Foundation
import Testing

@testable import SoyehtCore

@Suite("Mobile Claw VPN rendezvous view model")
struct MobileClawVPNRendezvousViewModelTests {
  private struct SampleError: Error, CustomStringConvertible, CustomDebugStringConvertible {
    let description: String
    let debugDescription: String
  }

  private final class Calls: @unchecked Sendable {
    private let lock = NSLock()
    private var _authorize = 0
    private var _arguments: [(String, String)] = []

    func authorize(deviceId: String, clawId: String) {
      lock.lock()
      _authorize += 1
      _arguments.append((deviceId, clawId))
      lock.unlock()
    }

    var authorizeCount: Int {
      lock.lock()
      defer { lock.unlock() }
      return _authorize
    }

    var arguments: [(String, String)] {
      lock.lock()
      defer { lock.unlock() }
      return _arguments
    }
  }

  private actor Gate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var opened = false

    func wait() async {
      if opened { return }
      await withCheckedContinuation { continuation = $0 }
    }

    func open() {
      opened = true
      continuation?.resume()
      continuation = nil
    }
  }

  private static func authorization() -> MobileClawVPNRendezvousAuthorization {
    MobileClawVPNRendezvousAuthorization(
      product: "product_a_mobile_claw_vpn",
      mode: "mesh_c_rendezvous_preflight",
      productionActivation: false,
      operation: "authorize_rendezvous",
      authorized: true,
      status: MobileClawVPNStatusResponse(
        product: "product_a_mobile_claw_vpn",
        mode: "mesh_c_status_only",
        productionActivation: false,
        state: "configured",
        snapshotPresent: true,
        enrolledDeviceCount: 1,
        availableClawCount: 2,
        grantCount: 3,
        offerCount: 4,
        sessionCount: 5
      )
    )
  }

  private static func productionAuthorization() -> MobileClawVPNRendezvousAuthorization {
    MobileClawVPNRendezvousAuthorization(
      product: "product_a_mobile_claw_vpn",
      mode: "mesh_c_rendezvous_preflight",
      productionActivation: true,
      operation: "authorize_rendezvous",
      authorized: true,
      status: MobileClawVPNStatusResponse(
        product: "product_a_mobile_claw_vpn",
        mode: "mesh_c_status_only",
        productionActivation: true,
        state: "configured",
        snapshotPresent: true,
        enrolledDeviceCount: 1,
        availableClawCount: 2,
        grantCount: 3,
        offerCount: 4,
        sessionCount: 5
      )
    )
  }

  private static func nestedProductionAuthorization() -> MobileClawVPNRendezvousAuthorization {
    MobileClawVPNRendezvousAuthorization(
      product: "product_a_mobile_claw_vpn",
      mode: "mesh_c_rendezvous_preflight",
      productionActivation: false,
      operation: "authorize_rendezvous",
      authorized: true,
      status: MobileClawVPNStatusResponse(
        product: "product_a_mobile_claw_vpn",
        mode: "mesh_c_status_only",
        productionActivation: true,
        state: "configured",
        snapshotPresent: true,
        enrolledDeviceCount: 1,
        availableClawCount: 2,
        grantCount: 3,
        offerCount: 4,
        sessionCount: 5
      )
    )
  }

  @Test @MainActor
  func authorizePublishesAuthorizedStateWithoutTokenEcho() async {
    let calls = Calls()
    let authorization = Self.authorization()
    let vm = MobileClawVPNRendezvousViewModel(
      authorize: { deviceId, clawId in
        calls.authorize(deviceId: deviceId, clawId: clawId)
        return authorization
      }
    )

    await vm.authorize(deviceId: "device-alpha", clawId: "claw-alpha")

    #expect(vm.phase == .authorized(authorization))
    #expect(calls.authorizeCount == 1)
    #expect(calls.arguments.first?.0 == "device-alpha")
    #expect(calls.arguments.first?.1 == "claw-alpha")
    #expect(!String(describing: vm.phase).contains("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"))
    #expect(!String(reflecting: vm.phase).contains("bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"))
  }

  @Test @MainActor
  func productionActivationResponseFailsClosed() async {
    let authorization = Self.productionAuthorization()
    let vm = MobileClawVPNRendezvousViewModel(
      authorize: { _, _ in authorization }
    )

    await vm.authorize(deviceId: "device-alpha", clawId: "claw-alpha")

    #expect(vm.phase == .failed(canRetry: true))
    #expect(!String(describing: vm.phase).contains("Production active"))
    #expect(!String(reflecting: vm.phase).contains("productionActivation: true"))
  }

  @Test @MainActor
  func nestedProductionActivationResponseFailsClosed() async {
    let authorization = Self.nestedProductionAuthorization()
    let vm = MobileClawVPNRendezvousViewModel(
      authorize: { _, _ in authorization }
    )

    await vm.authorize(deviceId: "device-alpha", clawId: "claw-alpha")

    #expect(vm.phase == .failed(canRetry: true))
    #expect(!String(describing: vm.phase).contains("Production active"))
    #expect(!String(reflecting: vm.phase).contains("productionActivation: true"))
  }

  @Test @MainActor
  func authorizeFailureCollapsesToGenericRetryableState() async {
    let vm = MobileClawVPNRendezvousViewModel(
      authorize: { _, _ in
        throw SampleError(
          description: "offer token aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
          debugDescription: "rendezvous token bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
        )
      }
    )

    await vm.authorize(deviceId: "device-alpha", clawId: "claw-alpha")

    #expect(vm.phase == .failed(canRetry: true))
    #expect(!String(describing: vm.phase).contains("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"))
    #expect(!String(reflecting: vm.phase).contains("bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"))
  }

  @Test @MainActor
  func reentrantAuthorizeWhileAuthorizingIsIgnored() async {
    let calls = Calls()
    let gate = Gate()
    let authorization = Self.authorization()
    let vm = MobileClawVPNRendezvousViewModel(
      authorize: { deviceId, clawId in
        calls.authorize(deviceId: deviceId, clawId: clawId)
        await gate.wait()
        return authorization
      }
    )

    let first = Task { await vm.authorize(deviceId: "device-alpha", clawId: "claw-alpha") }
    while vm.phase != .authorizing { await Task.yield() }

    await vm.authorize(deviceId: "device-beta", clawId: "claw-beta")
    await gate.open()
    await first.value

    #expect(calls.authorizeCount == 1)
    #expect(calls.arguments.first?.0 == "device-alpha")
    #expect(calls.arguments.first?.1 == "claw-alpha")
    #expect(vm.phase == .authorized(authorization))
  }
}
