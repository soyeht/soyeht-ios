import CryptoKit
import Foundation
import Testing
@testable import SoyehtCore

@Suite("HouseholdPoPSigner")
struct HouseholdPoPSignerTests {
    @Test func buildsSoyehtPoPAuthorizationHeaderWithoutBearer() throws {
        let key = P256.Signing.PrivateKey()
        let identity = try InMemoryOwnerIdentityKey(publicKey: key.publicKey.compressedRepresentation) { payload in
            try key.signature(for: payload).rawRepresentation
        }
        let signer = HouseholdPoPSigner(
            ownerIdentity: identity,
            now: { Date(timeIntervalSince1970: 1_714_972_800) }
        )
        let body = Data("{\"ok\":true}".utf8)

        let authorization = try signer.authorization(
            method: "get",
            pathAndQuery: "/api/v1/household/snapshot?x=y",
            body: body
        )

        #expect(authorization.method == "GET")
        #expect(authorization.timestamp == 1_714_972_800)
        #expect(authorization.bodyHash == HouseholdHash.blake3(body))
        #expect(authorization.authorizationHeader.hasPrefix("Soyeht-PoP v1:\(identity.personId):1714972800:"))
        #expect(!authorization.authorizationHeader.contains("Bearer"))
        #expect(authorization.signature.count == 64)

        let publicKey = try P256.Signing.PublicKey(compressedRepresentation: identity.publicKey)
        let signature = try P256.Signing.ECDSASignature(rawRepresentation: authorization.signature)
        #expect(publicKey.isValidSignature(signature, for: authorization.signingContext))
    }

    @Test func methodPathTimestampAndBodyChangeSigningContext() throws {
        let key = P256.Signing.PrivateKey()
        let identity = try InMemoryOwnerIdentityKey(publicKey: key.publicKey.compressedRepresentation) { payload in
            try key.signature(for: payload).rawRepresentation
        }

        let first = try HouseholdPoPSigner(
            ownerIdentity: identity,
            now: { Date(timeIntervalSince1970: 1_714_972_800) }
        ).authorization(method: "GET", pathAndQuery: "/a", body: Data())
        let methodChanged = try HouseholdPoPSigner(
            ownerIdentity: identity,
            now: { Date(timeIntervalSince1970: 1_714_972_800) }
        ).authorization(method: "POST", pathAndQuery: "/a", body: Data())
        let pathChanged = try HouseholdPoPSigner(
            ownerIdentity: identity,
            now: { Date(timeIntervalSince1970: 1_714_972_800) }
        ).authorization(method: "GET", pathAndQuery: "/b", body: Data())
        let timestampChanged = try HouseholdPoPSigner(
            ownerIdentity: identity,
            now: { Date(timeIntervalSince1970: 1_714_972_801) }
        ).authorization(method: "GET", pathAndQuery: "/a", body: Data())
        let bodyChanged = try HouseholdPoPSigner(
            ownerIdentity: identity,
            now: { Date(timeIntervalSince1970: 1_714_972_800) }
        ).authorization(method: "GET", pathAndQuery: "/a", body: Data([1]))

        #expect(first.signingContext != methodChanged.signingContext)
        #expect(first.signingContext != pathChanged.signingContext)
        #expect(first.signingContext != timestampChanged.signingContext)
        #expect(first.signingContext != bodyChanged.signingContext)
    }
}
