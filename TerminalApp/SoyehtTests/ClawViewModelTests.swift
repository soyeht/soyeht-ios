import Testing
import Foundation
@testable import Soyeht

// MARK: - Test Helper

private func makeClaw(_ name: String, status: String = "ready", description: String = "test") -> Claw {
    Claw(name: name, description: description, language: "go", buildable: true, status: status, installedAt: nil, jobId: nil, error: nil)
}

// MARK: - ClawStoreViewModel Tests

@Suite("ClawStoreViewModel", .serialized)
struct ClawStoreViewModelTests {

    @Test("featuredClaw returns the claw marked as featured in mock data")
    func featuredClawReturnsMockFeatured() {
        let vm = ClawStoreViewModel()
        // Simulate loaded claws directly
        vm.claws = [
            makeClaw("ironclaw", description: "Rust-based"),
            makeClaw("picoclaw", description: "Go-based"),
        ]

        #expect(vm.featuredClaw?.name == "ironclaw")
    }

    @Test("trendingClaws returns non-featured claws (max 2)")
    func trendingClawsReturnsNonFeatured() {
        let vm = ClawStoreViewModel()
        vm.claws = [
            makeClaw("ironclaw", description: "a"),
            makeClaw("picoclaw", description: "b"),
            makeClaw("nullclaw", status: "not_installed", description: "c"),
            makeClaw("zeroclaw", description: "d"),
        ]

        #expect(vm.trendingClaws.count == 2)
        #expect(vm.trendingClaws.allSatisfy { $0.name != "ironclaw" })
    }

    @Test("moreClaws excludes featured and trending")
    func moreClawsExcludesFeaturedAndTrending() {
        let vm = ClawStoreViewModel()
        vm.claws = [
            makeClaw("ironclaw", description: "a"),
            makeClaw("picoclaw", description: "b"),
            makeClaw("nullclaw", status: "not_installed", description: "c"),
            makeClaw("zeroclaw", description: "d"),
            makeClaw("shadowclaw", status: "not_installed", description: "e"),
        ]

        let moreNames = vm.moreClaws.map(\.name)
        #expect(!moreNames.contains("ironclaw"))
        #expect(moreNames.count >= 1)
    }

    @Test("availableCount and installedCount are correct")
    func countsAreCorrect() {
        let vm = ClawStoreViewModel()
        vm.claws = [
            makeClaw("a", description: "x"),
            makeClaw("b", status: "not_installed", description: "y"),
            makeClaw("c", description: "z"),
        ]

        #expect(vm.availableCount == 3)
        #expect(vm.installedCount == 2)
    }
}

// MARK: - ClawSetupViewModel Tests

@Suite("ClawSetupViewModel", .serialized)
struct ClawSetupViewModelTests {

    @Test("initial clawName is derived from claw name")
    func initialClawName() {
        let claw = makeClaw("picoclaw", description: "test")
        let vm = ClawSetupViewModel(claw: claw)
        #expect(vm.clawName == "picoclaw-workspace")
    }

    @Test("canDeploy is false when clawName is empty")
    func canDeployFalseWhenNameEmpty() {
        let claw = makeClaw("picoclaw", description: "test")
        let store = SessionStore.shared
        let server = PairedServer(id: "s1-test", host: "test.host", name: "test", role: "admin", pairedAt: Date(), expiresAt: nil)
        store.addServer(server, token: "tok")

        let vm = ClawSetupViewModel(claw: claw, store: store)
        vm.clawName = "   "
        #expect(vm.canDeploy == false)
    }

    @Test("canDeploy is true with valid name and server")
    func canDeployTrueWithValidData() {
        let claw = makeClaw("picoclaw", description: "test")
        let store = SessionStore.shared
        let server = PairedServer(id: "s-deploy-check", host: "deploy.host", name: "deploy", role: "admin", pairedAt: Date(), expiresAt: nil)
        store.addServer(server, token: "tok")

        let vm = ClawSetupViewModel(claw: claw, store: store)
        vm.selectedServerIndex = store.pairedServers.firstIndex(where: { $0.id == "s-deploy-check" }) ?? 0
        #expect(vm.canDeploy == true)
    }

    @Test("isDeployComplete is true when status is active")
    func isDeployCompleteWhenActive() {
        let claw = makeClaw("picoclaw", description: "test")
        let vm = ClawSetupViewModel(claw: claw)
        vm.provisioningStatus = "active"
        #expect(vm.isDeployComplete == true)
    }

    @Test("isProvisioning is true when deploying with provisioning status")
    func isProvisioningDuringDeploy() {
        let claw = makeClaw("picoclaw", description: "test")
        let vm = ClawSetupViewModel(claw: claw)
        vm.deployedInstanceId = "inst_1"
        vm.provisioningStatus = "provisioning"
        #expect(vm.isProvisioning == true)
    }
}

// MARK: - ClawDetailViewModel Tests

@Suite("ClawDetailViewModel")
struct ClawDetailViewModelTests {

    @Test("storeInfo returns correct data for known claw")
    func storeInfoReturnsCorrectData() {
        let claw = makeClaw("ironclaw", description: "test")
        let vm = ClawDetailViewModel(claw: claw)

        #expect(vm.storeInfo.language == "Rust")
        #expect(vm.storeInfo.rating == 4.9)
        #expect(vm.storeInfo.featured == true)
    }

    @Test("reviews returns mock reviews")
    func reviewsReturnsMockReviews() {
        let claw = makeClaw("ironclaw", description: "test")
        let vm = ClawDetailViewModel(claw: claw)

        #expect(vm.reviews.count == 3)
        #expect(vm.reviews[0].author == "paulo.marcos")
    }

    @Test("detailSpecs returns correct specs")
    func detailSpecsReturnsCorrectSpecs() {
        let claw = makeClaw("picoclaw", description: "test")
        let vm = ClawDetailViewModel(claw: claw)

        #expect(vm.detailSpecs.version == "v1.8.3")
        #expect(vm.detailSpecs.license == "MIT")
    }
}
