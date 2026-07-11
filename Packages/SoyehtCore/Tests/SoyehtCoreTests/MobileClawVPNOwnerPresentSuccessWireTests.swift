import CryptoKit
import Foundation
@testable import SoyehtCore
import Testing

@Suite("Mobile Claw VPN owner-present success wire C1")
struct MobileClawVPNOwnerPresentSuccessWireTests {
    private static let successFixtureSHA256 =
        "ff9ad533567e29261ecbd8e11e84e9490f1829bd4d2e5b50fe8783dc82b000d1"
    private static let expectedRPID = "owner.dev.example.test"
    private static let expectedOrigin = "https://owner.dev.example.test/"
    private static let ownerPresentMode = "mesh_c_owner_present_offer_control"
    private static let ownerPresentOperation = "owner_present_mint_offer"

    @Test
    func fixtureDependenciesAndPreEffectBoundaryAreClosed() throws {
        let fixtureData = try Self.resourceData(
            "owner_present_success_wire_v1",
            subdirectory: "Fixtures/mobile-claw-vpn/v1"
        )
        let fixture = try Self.decodeFixture(fixtureData)

        #expect(Self.sha256Hex(fixtureData) == Self.successFixtureSHA256)
        var fixtureMutation = fixtureData
        fixtureMutation[fixtureMutation.startIndex] ^= 1
        #expect(Self.sha256Hex(fixtureMutation) != Self.successFixtureSHA256)
        #expect(fixture.contract == "soyeht-mobile-claw-vpn-owner-present-success-wire-v1")
        #expect(fixture.version == 1)
        #expect(fixture.scope == "success-wire-only-pre-effect")
        #expect(fixture.dependencies.count == 3)
        #expect(fixture.flows.count == 2)
        #expect(fixture.negativeContract.rawCborCases.count == 29)
        #expect(fixture.negativeContract.semanticCases.count == 18)
        #expect(Set(fixture.endpointProfiles.keys) == ["start", "finish", "mint_offer"])
        for profile in fixture.endpointProfiles.values {
            #expect(profile.method == "POST")
            #expect(profile.path.hasPrefix("/api/v1/mobile/claw-vpn/owner-present/"))
            #expect(profile.auth == "mobile_bearer")
            #expect(profile.gate == "dev_default_off")
            #expect(profile.requestContentType == "application/cbor")
            #expect(profile.responseContentType == "application/cbor")
            #expect(profile.successStatus == 200)
        }

        for dependency in fixture.dependencies {
            let data: Data
            switch dependency.id {
            case "mobile_owner_approval_execution_v1":
                data = try Self.resourceData(
                    "owner_approval_v2_execution_vectors",
                    subdirectory: "Fixtures/mobile-claw-vpn/v1"
                )
            case "owner_approval_v2_assertion_fields_v1":
                data = try Self.resourceData("owner_approval_v2_assertion_fields_v1")
            case "mobile_claw_vpn_api_shapes_v1":
                data = try Self.resourceData(
                    "api_shapes",
                    subdirectory: "Fixtures/mobile-claw-vpn/v1"
                )
            default:
                Issue.record("unexpected dependency: \(dependency.id)")
                continue
            }
            #expect(Self.sha256Hex(data) == dependency.sha256)
            var mutation = data
            mutation[mutation.startIndex] ^= 1
            #expect(Self.sha256Hex(mutation) != dependency.sha256)
        }

        let assertionData = try Self.resourceData("owner_approval_v2_assertion_fields_v1")
        let assertionObject = try #require(
            JSONSerialization.jsonObject(with: assertionData) as? [String: Any]
        )
        let assertions = try #require(assertionObject["assertions"] as? [[String: Any]])
        #expect(assertions.count == 2)
        for assertion in assertions {
            #expect(Set(assertion.keys) == [
                "id", "credential_id_hex", "authenticator_data_hex",
                "client_data_json_hex", "signature_hex", "user_handle_hex",
            ])
        }
        let assertionText = try #require(String(data: assertionData, encoding: .utf8))
        for implementationDetail in [
            "AuthenticationState", "authentication_state", "verification_state",
            "EC_EC2", "Self_", "allow_backup_eligible_upgrade",
        ] {
            #expect(!assertionText.contains(implementationDetail))
        }

        #expect(fixture.format.mediaType == "application/cbor")
        #expect(fixture.format.errorContract.contains("owner_present_error_wire_v1.json"))
        #expect(
            fixture.runtimeRequirementsNotImplementedByC1.contains {
                $0.contains("owner_present_error_wire_v1")
            }
        )
    }

    @Test
    func thirteenSuccessEnvelopesUseProductionCanonicalCBOR() throws {
        let fixture = try Self.fixture()
        let goldens = Self.goldens(fixture)
        #expect(goldens.count == 13)

        for golden in goldens {
            let bytes = try Self.hexData(golden.canonicalCborHex)
            let value = try Self.strictDecode(bytes, as: golden.kind)
            #expect(HouseholdCBOR.encode(value) == bytes, "\(golden.id): canonical drift")

            switch golden.kind {
            case .startResponse:
                let decoded = try Self.parseStartResponse(value)
                #expect(try decoded.execution.canonicalBytes() == HouseholdCBOR.encode(decoded.executionValue))
                #expect(try decoded.context.canonicalBytes() == HouseholdCBOR.encode(decoded.contextValue))
                _ = try OwnerApprovalV2StartResponse(cbor: value)
            case .finishRequest:
                let decoded = try Self.parseFinishRequest(value)
                let production = OwnerApprovalV2Finish(
                    version: 1,
                    challengeID: decoded.challengeID,
                    approval: decoded.approval
                )
                #expect(try production.canonicalBytes() == bytes)
            default:
                break
            }
        }
    }

    @Test
    func rawCBORNegativesReachTheProductionDecoderAndRejectWithStableReason() throws {
        let fixture = try Self.fixture()
        #expect(fixture.negativeContract.rawCborCases.count == 29)
        #expect(Set(fixture.negativeContract.rawCborCases.map(\.envelope)) == Set(EnvelopeKind.allCases))

        for vector in fixture.negativeContract.rawCborCases {
            let bytes = try Self.hexData(vector.rawCborHex)
            do {
                _ = try Self.strictDecode(bytes, as: vector.envelope)
                Issue.record("\(vector.id): malformed bytes were accepted")
            } catch let reason as WireReason {
                #expect(reason.rawValue == vector.expectedReason, "\(vector.id): \(reason.rawValue)")
            } catch {
                Issue.record("\(vector.id): unstable error \(error)")
            }
        }
    }

    @Test
    func flowGraphBindsSelectorsChallengeContextProofAndMint() throws {
        let fixture = try Self.fixture()
        let assertions = try Self.assertionFields()
        let starts = try Dictionary(uniqueKeysWithValues: fixture.startRequests.map {
            try ($0.id, Self.parseStartRequest(Self.strictDecode(Self.hexData($0.canonicalCborHex), as: .startRequest)))
        })
        let startResponses = try Dictionary(uniqueKeysWithValues: fixture.startResponses.map {
            try ($0.id, Self.parseStartResponse(Self.strictDecode(Self.hexData($0.canonicalCborHex), as: .startResponse)))
        })
        let finishes = try Dictionary(uniqueKeysWithValues: fixture.finishRequests.map {
            try ($0.id, Self.parseFinishRequest(Self.strictDecode(Self.hexData($0.canonicalCborHex), as: .finishRequest)))
        })
        let finishResponses = try Dictionary(uniqueKeysWithValues: fixture.finishResponses.map {
            try ($0.id, Self.parseFinishResponse(Self.strictDecode(Self.hexData($0.canonicalCborHex), as: .finishResponse)))
        })
        let mintRequests = try Dictionary(uniqueKeysWithValues: fixture.mintRequests.map {
            try ($0.id, Self.parseMintRequest(Self.strictDecode(Self.hexData($0.canonicalCborHex), as: .mintRequest)))
        })
        let mintResponses = try Dictionary(uniqueKeysWithValues: fixture.mintResponses.map {
            try ($0.id, Self.parseMintResponse(Self.strictDecode(Self.hexData($0.canonicalCborHex), as: .mintResponse)))
        })

        var aliases = Set<String>()
        var clawIDs = Set<String>()
        for flow in fixture.flows {
            let start = try #require(starts[flow.startRequestId])
            let response = try #require(startResponses[flow.startResponseId])
            let finish = try #require(finishes[flow.finishRequestId])
            let finishResponse = try #require(finishResponses[flow.finishResponseId])
            let mintRequest = try #require(mintRequests[flow.mintRequestId])
            _ = try #require(mintResponses[flow.mintResponseId])
            let finishVector = try #require(
                fixture.finishRequests.first { $0.id == flow.finishRequestId }
            )
            let startResponseVector = try #require(
                fixture.startResponses.first { $0.id == flow.startResponseId }
            )
            let finishResponseVector = try #require(
                fixture.finishResponses.first { $0.id == flow.finishResponseId }
            )
            let mintRequestVector = try #require(
                fixture.mintRequests.first { $0.id == flow.mintRequestId }
            )
            let mintResponseVector = try #require(
                fixture.mintResponses.first { $0.id == flow.mintResponseId }
            )
            let assertion = try #require(assertions[finishVector.assertionFixtureId])

            #expect(startResponseVector.startRequestId == flow.startRequestId)
            #expect(finishVector.startResponseId == flow.startResponseId)
            #expect(finishResponseVector.finishRequestId == flow.finishRequestId)
            #expect(mintRequestVector.finishResponseId == flow.finishResponseId)
            #expect(mintResponseVector.mintRequestId == flow.mintRequestId)
            #expect(startResponseVector.challengeId == response.challengeID)
            #expect(startResponseVector.expectedRpId == response.options.rpID)
            #expect(try Self.hexData(finishResponseVector.proofTokenHex) == finishResponse.proofToken)
            #expect(Self.requestMatchesExecution(start, response.execution))
            #expect(Self.selectorMatches(response.execution, fixture.serverSelectorBindings))
            #expect(finish.challengeID == response.challengeID)
            #expect(try finish.approval.context.canonicalBytes() == response.context.canonicalBytes())
            #expect(try finish.approval.credentialID == (assertion.credentialID()))
            #expect(try finish.approval.authenticatorData == (assertion.authenticatorData()))
            #expect(try finish.approval.clientDataJSON == (assertion.clientDataJSON()))
            #expect(try finish.approval.signature == (assertion.signature()))
            #expect(response.options.allowedCredentialIDs == [finish.approval.credentialID])
            #expect(try Self.clientDataMatches(finish.approval.clientDataJSON, response.options))
            #expect(finishResponse.proofToken == mintRequest.proofToken)

            aliases.insert(response.execution.clawAlias)
            clawIDs.insert(response.execution.clawID)

            var aliasSwap = response.execution
            aliasSwap.clawAlias = aliasSwap.clawAlias == "Claw-M" ? "Claw-L" : "Claw-M"
            #expect(!Self.selectorMatches(aliasSwap, fixture.serverSelectorBindings))
            var idSwap = response.execution
            idSwap.clawID = idSwap.clawID == "claw-m-alpha" ? "claw-l-alpha" : "claw-m-alpha"
            #expect(!Self.selectorMatches(idSwap, fixture.serverSelectorBindings))
            var claimSwap = response.execution
            claimSwap.attemptID = "99999999-9999-4999-8999-999999999999"
            #expect(!Self.requestMatchesExecution(start, claimSwap))

            var hashSwap = response.context
            hashSwap.mobileClawVPNExecutionHash = Data(repeating: 0, count: 32)
            #expect(!Self.contextMatchesExecution(hashSwap, response.execution))
            var timeSwap = response.context
            timeSwap.expiresAt += 1
            #expect(!Self.contextMatchesExecution(timeSwap, response.execution))
        }
        #expect(aliases == ["Claw-M", "Claw-L"])
        #expect(clawIDs == ["claw-m-alpha", "claw-l-alpha"])

        let alternateM = try #require(
            fixture.startResponses.first {
                $0.id == "start-response-claw-m-challenge-b-same-context"
            }
        )
        let primaryM = try #require(startResponses["start-response-claw-m-challenge-a"])
        let alternate = try Self.parseStartResponse(
            Self.strictDecode(Self.hexData(alternateM.canonicalCborHex), as: .startResponse)
        )
        #expect(try primaryM.context.canonicalBytes() == alternate.context.canonicalBytes())
        #expect(primaryM.options.challenge != alternate.options.challenge)
        #expect(try primaryM.options.challenge != (primaryM.context.challengeDigest()))
        #expect(try alternate.options.challenge != (alternate.context.challengeDigest()))
    }

    @Test
    func authorityInjectionOptionsAndResponseConfusionFailClosed() throws {
        let fixture = try Self.fixture()
        let startValue = try Self.strictDecode(
            Self.hexData(fixture.startRequests[0].canonicalCborHex),
            as: .startRequest
        )
        let startMap = try Self.exactMap(startValue, keys: ["v", "claw_alias", "run_claims"])
        for key in fixture.negativeContract.forbiddenStartRequestKeys {
            var injected = startMap
            injected[key] = .text("injected")
            #expect(throws: WireReason.decode) {
                _ = try Self.parseStartRequest(.map(injected))
            }
        }

        let responseValue = try Self.strictDecode(
            Self.hexData(fixture.startResponses[0].canonicalCborHex),
            as: .startResponse
        )
        let response = try Self.parseStartResponse(responseValue)
        let publicKey = response.options.publicKeyMap
        let optionsMutations = try Self.strictOptionsMutations(publicKey)
        #expect(Set(optionsMutations.keys) == Set(fixture.negativeContract.strictOptionsMutations))
        for (name, mutation) in optionsMutations {
            #expect(throws: WireReason.decode, "\(name)") {
                _ = try Self.parseOptions(.map(["publicKey": .map(mutation)]))
            }
        }

        var mint = try Self.parseMintResponse(
            Self.strictDecode(Self.hexData(fixture.mintResponses[0].canonicalCborHex), as: .mintResponse)
        )
        mint.mode = "mesh_c_offer_control"
        #expect(throws: WireReason.mintResponseShape) { try Self.validateMintResponse(mint) }
        mint.mode = Self.ownerPresentMode
        mint.operation = "mint_offer"
        #expect(throws: WireReason.mintResponseShape) { try Self.validateMintResponse(mint) }
        mint.operation = Self.ownerPresentOperation
        mint.ownerApprovalConsumed = false
        #expect(throws: WireReason.mintResponseShape) { try Self.validateMintResponse(mint) }
        mint.ownerApprovalConsumed = true
        mint.productionActivation = true
        #expect(throws: WireReason.mintResponseShape) { try Self.validateMintResponse(mint) }

        var mintRequestMap = try Self.exactMap(
            Self.strictDecode(Self.hexData(fixture.mintRequests[0].canonicalCborHex), as: .mintRequest),
            keys: ["v", "proof_token"]
        )
        mintRequestMap["claw_id"] = .text("injected")
        #expect(throws: WireReason.decode) { _ = try Self.parseMintRequest(.map(mintRequestMap)) }

        var mintResponseMap = try Self.exactMap(
            Self.strictDecode(Self.hexData(fixture.mintResponses[0].canonicalCborHex), as: .mintResponse),
            keys: Self.mintResponseKeys
        )
        mintResponseMap["session_id"] = .text("injected")
        #expect(throws: WireReason.decode) { _ = try Self.parseMintResponse(.map(mintResponseMap)) }
    }

    @Test
    func semanticMutationMatrixCoversEveryDeclaredCase() throws {
        let fixture = try Self.fixture()
        let flow = try #require(fixture.flows.first)
        let startVector = try #require(fixture.startRequests.first { $0.id == flow.startRequestId })
        let responseVector = try #require(fixture.startResponses.first { $0.id == flow.startResponseId })
        let finishVector = try #require(fixture.finishRequests.first { $0.id == flow.finishRequestId })
        let finishResponseVector = try #require(
            fixture.finishResponses.first { $0.id == flow.finishResponseId }
        )
        let mintRequestVector = try #require(fixture.mintRequests.first { $0.id == flow.mintRequestId })
        let mintResponseVector = try #require(
            fixture.mintResponses.first { $0.id == flow.mintResponseId }
        )
        let start = try Self.parseStartRequest(
            Self.strictDecode(Self.hexData(startVector.canonicalCborHex), as: .startRequest)
        )
        let responseValue = try Self.strictDecode(
            Self.hexData(responseVector.canonicalCborHex),
            as: .startResponse
        )
        let response = try Self.parseStartResponse(responseValue)
        let finish = try Self.parseFinishRequest(
            Self.strictDecode(Self.hexData(finishVector.canonicalCborHex), as: .finishRequest)
        )
        let finishResponse = try Self.parseFinishResponse(
            Self.strictDecode(Self.hexData(finishResponseVector.canonicalCborHex), as: .finishResponse)
        )
        let mintRequest = try Self.parseMintRequest(
            Self.strictDecode(Self.hexData(mintRequestVector.canonicalCborHex), as: .mintRequest)
        )
        let mintResponseValue = try Self.strictDecode(
            Self.hexData(mintResponseVector.canonicalCborHex),
            as: .mintResponse
        )
        let mintResponse = try Self.parseMintResponse(mintResponseValue)
        var covered = Set<String>()

        var aliasSwap = response.execution
        aliasSwap.clawAlias = aliasSwap.clawAlias == "Claw-M" ? "Claw-L" : "Claw-M"
        #expect(!Self.selectorMatches(aliasSwap, fixture.serverSelectorBindings))
        covered.insert("flow_selector_mismatch")

        var idSwap = response.execution
        idSwap.clawID = idSwap.clawID == "claw-m-alpha" ? "claw-l-alpha" : "claw-m-alpha"
        #expect(!Self.selectorMatches(idSwap, fixture.serverSelectorBindings))
        covered.insert("flow_selector_server_id_mismatch")

        let wrongChallengeID = String(repeating: "0", count: 32)
        #expect(wrongChallengeID != response.challengeID)
        #expect(!Self.finishMatchesStart(wrongChallengeID, finish.approval.context, response))
        covered.insert("finish_challenge_or_context_mismatch")

        var wrongProof = finishResponse.proofToken
        let proofIndex = try #require(wrongProof.indices.first)
        wrongProof[proofIndex] = wrongProof[proofIndex] ^ 0x01
        #expect(wrongProof != mintRequest.proofToken)
        covered.insert("finish_response_proof_mismatch")

        var clientData = try #require(
            JSONSerialization.jsonObject(with: finish.approval.clientDataJSON) as? [String: Any]
        )
        clientData["challenge"] = PairingCrypto.base64URLEncode(Data(repeating: 0xA5, count: 32))
        let wrongClientData = try JSONSerialization.data(withJSONObject: clientData, options: [.sortedKeys])
        #expect(try !Self.clientDataMatches(wrongClientData, response.options))
        covered.insert("finish_assertion_rp_challenge_mismatch")

        var unknownCredential = finish.approval.credentialID
        let credentialIndex = try #require(unknownCredential.indices.first)
        unknownCredential[credentialIndex] = unknownCredential[credentialIndex] ^ 0x01
        #expect(!response.options.allowedCredentialIDs.contains(unknownCredential))
        covered.insert("finish_assertion_credential_not_allowlisted")

        var claimSwap = response.execution
        claimSwap.attemptID = "99999999-9999-4999-8999-999999999999"
        #expect(!Self.requestMatchesExecution(start, claimSwap))
        covered.insert("start_response_run_claim_mismatch")

        var hashSwap = response.context
        hashSwap.mobileClawVPNExecutionHash = Data(repeating: 0, count: 32)
        #expect(!Self.contextMatchesExecution(hashSwap, response.execution))
        covered.insert("start_response_execution_context_hash_mismatch")

        var timeSwap = response.context
        timeSwap.expiresAt += 1
        #expect(!Self.contextMatchesExecution(timeSwap, response.execution))
        covered.insert("start_response_execution_context_time_mismatch")

        var responseMap = try Self.exactMap(
            responseValue,
            keys: ["v", "challenge_id", "execution", "context", "options"]
        )
        var optionsMap = try Self.exactMap(Self.required(responseMap, "options"), keys: ["publicKey"])
        var publicKeyMap = try Self.exactMap(
            Self.required(optionsMap, "publicKey"),
            keys: ["challenge", "timeout", "rpId", "allowCredentials", "userVerification"]
        )
        publicKeyMap["challenge"] = try .text(
            PairingCrypto.base64URLEncode(response.context.challengeDigest())
        )
        optionsMap["publicKey"] = .map(publicKeyMap)
        responseMap["options"] = .map(optionsMap)
        #expect(throws: WireReason.decode) { _ = try Self.parseStartResponse(.map(responseMap)) }
        covered.insert("start_response_context_digest_used_as_rp_challenge")

        var submittedContextSwap = finish.approval.context
        submittedContextSwap.expiresAt += 1
        #expect(!Self.finishMatchesStart(finish.challengeID, submittedContextSwap, response))
        covered.insert("finish_submitted_context_mismatch")

        var normalMint = mintResponse
        normalMint.mode = "mesh_c_offer_control"
        normalMint.operation = "mint_offer"
        normalMint.ownerApprovalConsumed = false
        normalMint.productionActivation = true
        #expect(throws: WireReason.mintResponseShape) { try Self.validateMintResponse(normalMint) }
        covered.insert("normal_mint_response_as_owner_present")

        var modeSwap = mintResponse
        modeSwap.mode = "mesh_c_offer_control"
        #expect(throws: WireReason.mintResponseShape) { try Self.validateMintResponse(modeSwap) }
        covered.insert("mint_response_normal_mode")

        var operationSwap = mintResponse
        operationSwap.operation = "mint_offer"
        #expect(throws: WireReason.mintResponseShape) { try Self.validateMintResponse(operationSwap) }
        covered.insert("mint_response_normal_operation")

        var consumedSwap = mintResponse
        consumedSwap.ownerApprovalConsumed = false
        #expect(throws: WireReason.mintResponseShape) { try Self.validateMintResponse(consumedSwap) }
        covered.insert("mint_response_owner_approval_not_consumed")

        var activationSwap = mintResponse
        activationSwap.productionActivation = true
        #expect(throws: WireReason.mintResponseShape) { try Self.validateMintResponse(activationSwap) }
        covered.insert("mint_response_production_activation")

        var mintRequestMap = try Self.exactMap(
            Self.strictDecode(Self.hexData(mintRequestVector.canonicalCborHex), as: .mintRequest),
            keys: ["v", "proof_token"]
        )
        mintRequestMap["claw_id"] = .text("injected")
        #expect(throws: WireReason.decode) { _ = try Self.parseMintRequest(.map(mintRequestMap)) }
        covered.insert("mint_request_with_selector_or_ids")

        var mintResponseMap = try Self.exactMap(mintResponseValue, keys: Self.mintResponseKeys)
        mintResponseMap["session_id"] = .text("injected")
        #expect(throws: WireReason.decode) { _ = try Self.parseMintResponse(.map(mintResponseMap)) }
        mintResponseMap.removeValue(forKey: "session_id")
        mintResponseMap["proof_token"] = .bytes(finishResponse.proofToken)
        #expect(throws: WireReason.decode) { _ = try Self.parseMintResponse(.map(mintResponseMap)) }
        covered.insert("mint_response_with_session_id_or_proof_token")

        #expect(covered == Set(fixture.negativeContract.semanticCases))
    }

    @Test
    func shippingSourcesRemainWireAndEffectFreeUntilErrorContractLands() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourcesRoot = packageRoot.appendingPathComponent("Sources/SoyehtCore")
        let enumerator = try #require(FileManager.default.enumerator(at: sourcesRoot, includingPropertiesForKeys: nil))
        let forbidden = [
            "/api/v1/mobile/claw-vpn/owner-present", "owner_present_mint_offer",
            "proof_token", "owner_present_error_wire_v1",
        ]
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let source = try String(contentsOf: url, encoding: .utf8)
            for token in forbidden {
                #expect(!source.contains(token), "shipping source contains \(token): \(url.lastPathComponent)")
            }
        }

        let errorFixture = packageRoot.appendingPathComponent(
            "Tests/SoyehtCoreTests/Fixtures/mobile-claw-vpn/v1/owner_present_error_wire_v1.json"
        )
        #expect(!FileManager.default.fileExists(atPath: errorFixture.path))

        let repositoryRoot = packageRoot.deletingLastPathComponent().deletingLastPathComponent()
        let pin = try String(
            contentsOf: repositoryRoot.appendingPathComponent("scripts/cross-repo-contract.sha"),
            encoding: .utf8
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(pin == "95659bd1cb10581dde7bd94660fd99f2e4bf4eb7")
    }
}

private extension MobileClawVPNOwnerPresentSuccessWireTests {
    struct Fixture: Decodable {
        let contract: String
        let version: Int
        let scope: String
        let dependencies: [Dependency]
        let format: FormatContract
        let endpointProfiles: [String: EndpointProfile]
        let serverSelectorBindings: [SelectorBinding]
        let flows: [Flow]
        let startRequests: [StartRequestVector]
        let startResponses: [StartResponseVector]
        let finishRequests: [FinishRequestVector]
        let finishResponses: [FinishResponseVector]
        let mintRequests: [MintRequestVector]
        let mintResponses: [MintResponseVector]
        let negativeContract: NegativeContract
        let runtimeRequirementsNotImplementedByC1: [String]
    }

    struct Dependency: Decodable {
        let id: String
        let sha256: String
    }

    struct FormatContract: Decodable {
        let mediaType: String
        let errorContract: String
    }

    struct EndpointProfile: Decodable {
        let method: String
        let path: String
        let auth: String
        let gate: String
        let requestContentType: String
        let responseContentType: String
        let successStatus: Int
    }

    struct SelectorBinding: Decodable {
        let clawAlias: String
        let serverClawId: String
    }

    struct Flow: Decodable {
        let id: String
        let startRequestId: String
        let startResponseId: String
        let finishRequestId: String
        let finishResponseId: String
        let mintRequestId: String
        let mintResponseId: String
    }

    struct StartRequestVector: Decodable {
        let id: String
        let canonicalCborHex: String
    }

    struct StartResponseVector: Decodable {
        let id: String
        let startRequestId: String
        let challengeId: String
        let expectedRpId: String
        let canonicalCborHex: String
    }

    struct FinishRequestVector: Decodable {
        let id: String
        let startResponseId: String
        let assertionFixtureId: String
        let canonicalCborHex: String
    }

    struct FinishResponseVector: Decodable {
        let id: String
        let finishRequestId: String
        let proofTokenHex: String
        let canonicalCborHex: String
    }

    struct MintRequestVector: Decodable {
        let id: String
        let finishResponseId: String
        let canonicalCborHex: String
    }

    struct MintResponseVector: Decodable {
        let id: String
        let mintRequestId: String
        let canonicalCborHex: String
    }

    struct NegativeContract: Decodable {
        let forbiddenStartRequestKeys: [String]
        let strictOptionsMutations: [String]
        let rawCborCases: [RawNegative]
        let semanticCases: [String]
    }

    struct RawNegative: Decodable {
        let id: String
        let envelope: EnvelopeKind
        let expectedReason: String
        let rawCborHex: String
    }

    struct AssertionFixture: Decodable {
        let assertions: [AssertionFields]
    }

    struct AssertionFields: Decodable {
        let id: String
        let credentialIdHex: String
        let authenticatorDataHex: String
        let clientDataJsonHex: String
        let signatureHex: String
        let userHandleHex: String?

        func credentialID() throws -> Data {
            try MobileClawVPNOwnerPresentSuccessWireTests.hexData(credentialIdHex)
        }

        func authenticatorData() throws -> Data {
            try MobileClawVPNOwnerPresentSuccessWireTests.hexData(authenticatorDataHex)
        }

        func clientDataJSON() throws -> Data {
            try MobileClawVPNOwnerPresentSuccessWireTests.hexData(clientDataJsonHex)
        }

        func signature() throws -> Data {
            try MobileClawVPNOwnerPresentSuccessWireTests.hexData(signatureHex)
        }
    }

    enum EnvelopeKind: String, Decodable, CaseIterable {
        case startRequest = "start_request"
        case startResponse = "start_response"
        case finishRequest = "finish_request"
        case finishResponse = "finish_response"
        case mintRequest = "mint_request"
        case mintResponse = "mint_response"
    }

    enum WireReason: String, Error {
        case decode
        case nonCanonical = "non_canonical"
        case finishResponseShape = "finish_response_shape"
        case mintRequestShape = "mint_request_shape"
        case mintResponseShape = "mint_response_shape"
    }

    struct Golden {
        let id: String
        let kind: EnvelopeKind
        let canonicalCborHex: String
    }

    struct RunClaims {
        let attemptID: String
        let readinessRunID: String
        let sourceArtifactGitSHA1: Data
        let executionManifestSHA256: Data
        let deviceBindingClaimSHA256: Data
        let executionRunID: String
        let executionClaimSHA256: Data
    }

    struct StartRequest {
        let clawAlias: String
        let claims: RunClaims
    }

    struct OwnerOptions {
        let rpID: String
        let challenge: Data
        let challengeText: String
        let timeout: UInt64
        let allowedCredentialIDs: [Data]
        let userVerification: String
        let publicKeyMap: [String: HouseholdCBORValue]
    }

    struct StartResponse {
        let challengeID: String
        let execution: MobileClawVPNDevE2EExecutionTupleV1
        let executionValue: HouseholdCBORValue
        let context: OwnerApprovalContextV2
        let contextValue: HouseholdCBORValue
        let options: OwnerOptions
    }

    struct FinishRequest {
        let challengeID: String
        let approval: OwnerApprovalV2
    }

    struct FinishResponse {
        let proofToken: Data
    }

    struct MintRequest {
        let proofToken: Data
    }

    struct MintResponse {
        var product: String
        var mode: String
        var productionActivation: Bool
        var operation: String
        var ownerApprovalConsumed: Bool
        var offerToken: String
        let status: [String: HouseholdCBORValue]
    }

    static let mintResponseKeys: Set<String> = [
        "v", "product", "mode", "production_activation", "operation",
        "owner_approval_consumed", "offer_token", "status",
    ]

    static func resourceData(_ name: String, subdirectory: String? = nil) throws -> Data {
        guard let url = Bundle.module.url(
            forResource: name,
            withExtension: "json",
            subdirectory: subdirectory
        ) else {
            throw WireReason.decode
        }
        return try Data(contentsOf: url)
    }

    static func fixture() throws -> Fixture {
        try decodeFixture(resourceData(
            "owner_present_success_wire_v1",
            subdirectory: "Fixtures/mobile-claw-vpn/v1"
        ))
    }

    static func decodeFixture(_ data: Data) throws -> Fixture {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(Fixture.self, from: data)
    }

    static func assertionFields() throws -> [String: AssertionFields] {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let fixture = try decoder.decode(
            AssertionFixture.self,
            from: resourceData("owner_approval_v2_assertion_fields_v1")
        )
        return Dictionary(uniqueKeysWithValues: fixture.assertions.map { ($0.id, $0) })
    }

    static func goldens(_ fixture: Fixture) -> [Golden] {
        fixture.startRequests.map { Golden(id: $0.id, kind: .startRequest, canonicalCborHex: $0.canonicalCborHex) }
            + fixture.startResponses.map { Golden(id: $0.id, kind: .startResponse, canonicalCborHex: $0.canonicalCborHex) }
            + fixture.finishRequests.map { Golden(id: $0.id, kind: .finishRequest, canonicalCborHex: $0.canonicalCborHex) }
            + fixture.finishResponses.map { Golden(id: $0.id, kind: .finishResponse, canonicalCborHex: $0.canonicalCborHex) }
            + fixture.mintRequests.map { Golden(id: $0.id, kind: .mintRequest, canonicalCborHex: $0.canonicalCborHex) }
            + fixture.mintResponses.map { Golden(id: $0.id, kind: .mintResponse, canonicalCborHex: $0.canonicalCborHex) }
    }

    static func strictDecode(_ bytes: Data, as kind: EnvelopeKind) throws -> HouseholdCBORValue {
        let value: HouseholdCBORValue
        do {
            value = try HouseholdCBOR.decode(bytes)
        } catch HouseholdCBORError.trailingBytes {
            throw WireReason.nonCanonical
        } catch HouseholdCBORError.unsupportedAdditionalInfo(31) {
            throw WireReason.nonCanonical
        } catch {
            throw WireReason.decode
        }
        do {
            var scanner = DuplicateMapKeyScanner(bytes)
            if try scanner.containsDuplicateKey() {
                throw WireReason.decode
            }
        } catch let reason as WireReason {
            throw reason
        } catch {
            throw WireReason.decode
        }
        guard HouseholdCBOR.encode(value) == bytes else {
            throw WireReason.nonCanonical
        }
        switch kind {
        case .startRequest: _ = try parseStartRequest(value)
        case .startResponse: _ = try parseStartResponse(value)
        case .finishRequest: _ = try parseFinishRequest(value)
        case .finishResponse: _ = try parseFinishResponse(value)
        case .mintRequest: _ = try parseMintRequest(value)
        case .mintResponse: _ = try parseMintResponse(value)
        }
        return value
    }

    static func parseStartRequest(_ value: HouseholdCBORValue) throws -> StartRequest {
        let map = try exactMap(value, keys: ["v", "claw_alias", "run_claims"])
        guard try unsigned(map, "v") == 1 else { throw WireReason.decode }
        let alias = try text(map, "claw_alias")
        guard alias == "Claw-M" || alias == "Claw-L" else { throw WireReason.decode }
        let claims = try exactMap(
            required(map, "run_claims"),
            keys: [
                "attempt_id", "readiness_run_id", "source_artifact_git_sha1",
                "execution_manifest_sha256", "device_binding_claim_sha256",
                "execution_run_id", "execution_claim_sha256",
            ]
        )
        let result = try RunClaims(
            attemptID: text(claims, "attempt_id"),
            readinessRunID: text(claims, "readiness_run_id"),
            sourceArtifactGitSHA1: bytes(claims, "source_artifact_git_sha1"),
            executionManifestSHA256: bytes(claims, "execution_manifest_sha256"),
            deviceBindingClaimSHA256: bytes(claims, "device_binding_claim_sha256"),
            executionRunID: text(claims, "execution_run_id"),
            executionClaimSHA256: bytes(claims, "execution_claim_sha256")
        )
        guard isCanonicalUUID(result.attemptID),
              isCanonicalUUID(result.readinessRunID),
              isCanonicalUUID(result.executionRunID),
              result.sourceArtifactGitSHA1.count == 20,
              result.executionManifestSHA256.count == 32,
              result.deviceBindingClaimSHA256.count == 32,
              result.executionClaimSHA256.count == 32
        else {
            throw WireReason.decode
        }
        return StartRequest(clawAlias: alias, claims: result)
    }

    static func parseStartResponse(_ value: HouseholdCBORValue) throws -> StartResponse {
        let map = try exactMap(value, keys: ["v", "challenge_id", "execution", "context", "options"])
        guard try unsigned(map, "v") == 1 else { throw WireReason.decode }
        let challengeID = try text(map, "challenge_id")
        guard isLowerHex(challengeID, count: 32) else { throw WireReason.decode }
        let executionValue = try required(map, "execution")
        let contextValue = try required(map, "context")
        let execution: MobileClawVPNDevE2EExecutionTupleV1
        let context: OwnerApprovalContextV2
        do {
            execution = try MobileClawVPNDevE2EExecutionTupleV1(
                canonicalBytes: HouseholdCBOR.encode(executionValue)
            )
            context = try OwnerApprovalContextV2(cbor: contextValue)
        } catch {
            throw WireReason.decode
        }
        let options = try parseOptions(required(map, "options"))
        guard try context.mobileClawVPNExecutionHash == (execution.executionHash()),
              context.householdID == execution.householdID,
              context.issuedAt == execution.issuedAt,
              context.expiresAt == execution.expiresAt,
              try options.challenge != (context.challengeDigest())
        else {
            throw WireReason.decode
        }
        return StartResponse(
            challengeID: challengeID,
            execution: execution,
            executionValue: executionValue,
            context: context,
            contextValue: contextValue,
            options: options
        )
    }

    static func parseOptions(_ value: HouseholdCBORValue) throws -> OwnerOptions {
        let options = try exactMap(value, keys: ["publicKey"])
        let publicKey = try exactMap(
            required(options, "publicKey"),
            keys: ["challenge", "timeout", "rpId", "allowCredentials", "userVerification"]
        )
        let rpID = try text(publicKey, "rpId")
        let challengeText = try text(publicKey, "challenge")
        let timeout = try unsigned(publicKey, "timeout")
        let userVerification = try text(publicKey, "userVerification")
        let descriptors = try array(publicKey, "allowCredentials")
        guard rpID == expectedRPID,
              timeout > 0,
              userVerification == "required",
              !descriptors.isEmpty,
              let challenge = PairingCrypto.base64URLDecode(challengeText),
              challenge.count == 32,
              PairingCrypto.base64URLEncode(challenge) == challengeText
        else {
            throw WireReason.decode
        }
        var allowed: [Data] = []
        for descriptor in descriptors {
            let map = try exactMap(descriptor, keys: ["type", "id"])
            let encodedID = try text(map, "id")
            guard try text(map, "type") == "public-key",
                  let id = PairingCrypto.base64URLDecode(encodedID),
                  !id.isEmpty,
                  id.count <= 1024,
                  PairingCrypto.base64URLEncode(id) == encodedID,
                  !allowed.contains(id)
            else {
                throw WireReason.decode
            }
            allowed.append(id)
        }
        return OwnerOptions(
            rpID: rpID,
            challenge: challenge,
            challengeText: challengeText,
            timeout: timeout,
            allowedCredentialIDs: allowed,
            userVerification: userVerification,
            publicKeyMap: publicKey
        )
    }

    static func parseFinishRequest(_ value: HouseholdCBORValue) throws -> FinishRequest {
        let map = try exactMap(value, keys: ["v", "challenge_id", "approval"])
        guard try unsigned(map, "v") == 1 else { throw WireReason.decode }
        let challengeID = try text(map, "challenge_id")
        guard isLowerHex(challengeID, count: 32) else { throw WireReason.decode }
        let approvalMap = try exactMap(
            required(map, "approval"),
            requiredKeys: [
                "v", "context", "credential_id", "authenticator_data",
                "client_data_json", "signature",
            ],
            optionalKeys: ["user_handle"]
        )
        guard try unsigned(approvalMap, "v") == 2 else { throw WireReason.decode }
        let context: OwnerApprovalContextV2
        do {
            context = try OwnerApprovalContextV2(cbor: required(approvalMap, "context"))
        } catch {
            throw WireReason.decode
        }
        let userHandle: Data?
        if approvalMap["user_handle"] != nil {
            userHandle = try bytes(approvalMap, "user_handle")
        } else {
            userHandle = nil
        }
        return try FinishRequest(
            challengeID: challengeID,
            approval: OwnerApprovalV2(
                version: 2,
                context: context,
                credentialID: bytes(approvalMap, "credential_id"),
                authenticatorData: bytes(approvalMap, "authenticator_data"),
                clientDataJSON: bytes(approvalMap, "client_data_json"),
                signature: bytes(approvalMap, "signature"),
                userHandle: userHandle
            )
        )
    }

    static func parseFinishResponse(_ value: HouseholdCBORValue) throws -> FinishResponse {
        let map = try exactMap(value, keys: ["v", "proof_token"])
        let token = try bytes(map, "proof_token")
        guard try unsigned(map, "v") == 1, token.count == 32 else {
            throw WireReason.finishResponseShape
        }
        return FinishResponse(proofToken: token)
    }

    static func parseMintRequest(_ value: HouseholdCBORValue) throws -> MintRequest {
        let map = try exactMap(value, keys: ["v", "proof_token"])
        let token = try bytes(map, "proof_token")
        guard try unsigned(map, "v") == 1, token.count == 32 else {
            throw WireReason.mintRequestShape
        }
        return MintRequest(proofToken: token)
    }

    static func parseMintResponse(_ value: HouseholdCBORValue) throws -> MintResponse {
        let map = try exactMap(value, keys: mintResponseKeys)
        guard try unsigned(map, "v") == 1 else { throw WireReason.mintResponseShape }
        let status = try exactMap(
            required(map, "status"),
            keys: [
                "product", "mode", "production_activation", "state", "snapshot_present",
                "enrolled_device_count", "available_claw_count", "grant_count",
                "offer_count", "session_count",
            ]
        )
        let result = try MintResponse(
            product: text(map, "product"),
            mode: text(map, "mode"),
            productionActivation: bool(map, "production_activation"),
            operation: text(map, "operation"),
            ownerApprovalConsumed: bool(map, "owner_approval_consumed"),
            offerToken: text(map, "offer_token"),
            status: status
        )
        try validateMintResponse(result)
        return result
    }

    static func validateMintResponse(_ response: MintResponse) throws {
        guard response.product == "product_a_mobile_claw_vpn",
              response.mode == ownerPresentMode,
              !response.productionActivation,
              response.operation == ownerPresentOperation,
              response.ownerApprovalConsumed,
              isLowerHex(response.offerToken, count: 32),
              try text(response.status, "product") == "product_a_mobile_claw_vpn",
              try text(response.status, "mode") == "mesh_c_status_only",
              try bool(response.status, "production_activation") == false,
              try text(response.status, "state") == "configured",
              try bool(response.status, "snapshot_present")
        else {
            throw WireReason.mintResponseShape
        }
    }

    static func requestMatchesExecution(
        _ request: StartRequest,
        _ execution: MobileClawVPNDevE2EExecutionTupleV1
    ) -> Bool {
        request.clawAlias == execution.clawAlias
            && request.claims.attemptID == execution.attemptID
            && request.claims.readinessRunID == execution.readinessRunID
            && request.claims.sourceArtifactGitSHA1 == execution.sourceArtifactGitSHA1
            && request.claims.executionManifestSHA256 == execution.executionManifestSHA256
            && request.claims.deviceBindingClaimSHA256 == execution.deviceBinding
            && request.claims.executionRunID == execution.executionRunID
            && request.claims.executionClaimSHA256 == execution.executionClaimSHA256
    }

    static func selectorMatches(
        _ execution: MobileClawVPNDevE2EExecutionTupleV1,
        _ bindings: [SelectorBinding]
    ) -> Bool {
        bindings.contains {
            $0.clawAlias == execution.clawAlias && $0.serverClawId == execution.clawID
        }
    }

    static func contextMatchesExecution(
        _ context: OwnerApprovalContextV2,
        _ execution: MobileClawVPNDevE2EExecutionTupleV1
    ) -> Bool {
        context.mobileClawVPNExecutionHash == (try? execution.executionHash())
            && context.householdID == execution.householdID
            && context.issuedAt == execution.issuedAt
            && context.expiresAt == execution.expiresAt
    }

    static func finishMatchesStart(
        _ challengeID: String,
        _ context: OwnerApprovalContextV2,
        _ response: StartResponse
    ) -> Bool {
        guard challengeID == response.challengeID,
              let submitted = try? context.canonicalBytes(),
              let expected = try? response.context.canonicalBytes()
        else {
            return false
        }
        return submitted == expected
    }

    static func clientDataMatches(_ bytes: Data, _ options: OwnerOptions) throws -> Bool {
        guard let json = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else {
            return false
        }
        return json["type"] as? String == "webauthn.get"
            && json["challenge"] as? String == options.challengeText
            && json["origin"] as? String == expectedOrigin
    }

    static func strictOptionsMutations(
        _ source: [String: HouseholdCBORValue]
    ) throws -> [String: [String: HouseholdCBORValue]] {
        var result: [String: [String: HouseholdCBORValue]] = [:]
        func setting(_ key: String, _ value: HouseholdCBORValue?) -> [String: HouseholdCBORValue] {
            var map = source
            map[key] = value
            return map
        }
        result["wrong_rp_id"] = setting("rpId", .text("wrong.example.test"))
        result["challenge_padded_base64url"] = try setting(
            "challenge",
            .text(text(source, "challenge") + "=")
        )
        result["challenge_wrong_length"] = setting(
            "challenge",
            .text(PairingCrypto.base64URLEncode(Data(repeating: 1, count: 31)))
        )
        result["user_verification_missing"] = setting("userVerification", nil)
        result["user_verification_preferred"] = setting("userVerification", .text("preferred"))
        result["allow_credentials_missing"] = setting("allowCredentials", nil)
        result["allow_credentials_null"] = setting("allowCredentials", .null)
        result["allow_credentials_empty"] = setting("allowCredentials", .array([]))

        let descriptors = try array(source, "allowCredentials")
        let descriptor = try #require(descriptors.first)
        result["allow_credentials_duplicate_decoded_id"] = setting(
            "allowCredentials",
            .array([descriptor, descriptor])
        )
        var wrongType = try exactMap(descriptor, keys: ["type", "id"])
        wrongType["type"] = .text("password")
        result["descriptor_wrong_type"] = setting("allowCredentials", .array([.map(wrongType)]))
        var extraDescriptor = try exactMap(descriptor, keys: ["type", "id"])
        extraDescriptor["transports"] = .array([.text("internal")])
        result["descriptor_extra_transports"] = setting(
            "allowCredentials",
            .array([.map(extraDescriptor)])
        )
        var extraPublicKey = source
        extraPublicKey["extensions"] = .map([:])
        result["public_key_extra_extensions"] = extraPublicKey
        return result
    }

    static func exactMap(
        _ value: HouseholdCBORValue,
        keys: Set<String>
    ) throws -> [String: HouseholdCBORValue] {
        guard case let .map(map) = value, Set(map.keys) == keys else {
            throw WireReason.decode
        }
        return map
    }

    static func exactMap(
        _ value: HouseholdCBORValue,
        requiredKeys: Set<String>,
        optionalKeys: Set<String>
    ) throws -> [String: HouseholdCBORValue] {
        guard case let .map(map) = value,
              requiredKeys.isSubset(of: Set(map.keys)),
              Set(map.keys).isSubset(of: requiredKeys.union(optionalKeys))
        else {
            throw WireReason.decode
        }
        return map
    }

    static func required(
        _ map: [String: HouseholdCBORValue],
        _ key: String
    ) throws -> HouseholdCBORValue {
        guard let value = map[key] else { throw WireReason.decode }
        return value
    }

    static func text(_ map: [String: HouseholdCBORValue], _ key: String) throws -> String {
        guard case let .text(value) = try required(map, key) else { throw WireReason.decode }
        return value
    }

    static func bytes(_ map: [String: HouseholdCBORValue], _ key: String) throws -> Data {
        guard case let .bytes(value) = try required(map, key) else { throw WireReason.decode }
        return value
    }

    static func unsigned(_ map: [String: HouseholdCBORValue], _ key: String) throws -> UInt64 {
        guard case let .unsigned(value) = try required(map, key) else { throw WireReason.decode }
        return value
    }

    static func bool(_ map: [String: HouseholdCBORValue], _ key: String) throws -> Bool {
        guard case let .bool(value) = try required(map, key) else { throw WireReason.decode }
        return value
    }

    static func array(
        _ map: [String: HouseholdCBORValue],
        _ key: String
    ) throws -> [HouseholdCBORValue] {
        guard case let .array(value) = try required(map, key) else { throw WireReason.decode }
        return value
    }

    static func isCanonicalUUID(_ value: String) -> Bool {
        UUID(uuidString: value)?.uuidString.lowercased() == value
    }

    static func isLowerHex(_ value: String, count: Int) -> Bool {
        value.utf8.count == count && value.utf8.allSatisfy {
            (0x30 ... 0x39).contains($0) || (0x61 ... 0x66).contains($0)
        }
    }

    static func hexData(_ text: String) throws -> Data {
        guard text.count.isMultiple(of: 2) else { throw WireReason.decode }
        var output = Data(capacity: text.count / 2)
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(index, offsetBy: 2)
            guard let byte = UInt8(text[index ..< next], radix: 16) else { throw WireReason.decode }
            output.append(byte)
            index = next
        }
        return output
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

private struct DuplicateMapKeyScanner {
    private let data: Data
    private var index: Data.Index
    private var duplicateFound = false

    init(_ data: Data) {
        self.data = data
        index = data.startIndex
    }

    mutating func containsDuplicateKey() throws -> Bool {
        try scanValue()
        guard index == data.endIndex else { throw ScanError.invalid }
        return duplicateFound
    }

    private mutating func scanValue() throws {
        let initial = try readByte()
        let major = initial >> 5
        let argument = try readArgument(initial & 0x1F)
        switch major {
        case 0, 1:
            return
        case 2, 3:
            try skip(argument)
        case 4:
            let count = try integer(argument)
            for _ in 0 ..< count {
                try scanValue()
            }
        case 5:
            var keys = Set<String>()
            let count = try integer(argument)
            for _ in 0 ..< count {
                let key = try readTextKey()
                if !keys.insert(key).inserted { duplicateFound = true }
                try scanValue()
            }
        case 7 where argument == 20 || argument == 21 || argument == 22:
            return
        default:
            throw ScanError.invalid
        }
    }

    private mutating func readTextKey() throws -> String {
        let initial = try readByte()
        guard initial >> 5 == 3 else { throw ScanError.invalid }
        let length = try integer(readArgument(initial & 0x1F))
        let bytes = try readData(length)
        guard let key = String(data: bytes, encoding: .utf8) else { throw ScanError.invalid }
        return key
    }

    private mutating func readArgument(_ additional: UInt8) throws -> UInt64 {
        switch additional {
        case 0 ..< 24: return UInt64(additional)
        case 24: return try UInt64(readByte())
        case 25: return try readUInt(2)
        case 26: return try readUInt(4)
        case 27: return try readUInt(8)
        default: throw ScanError.invalid
        }
    }

    private mutating func readUInt(_ count: Int) throws -> UInt64 {
        try readData(count).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    }

    private mutating func readByte() throws -> UInt8 {
        guard index < data.endIndex else { throw ScanError.invalid }
        defer { data.formIndex(after: &index) }
        return data[index]
    }

    private mutating func readData(_ count: Int) throws -> Data {
        guard let end = data.index(index, offsetBy: count, limitedBy: data.endIndex) else {
            throw ScanError.invalid
        }
        defer { index = end }
        return Data(data[index ..< end])
    }

    private mutating func skip(_ value: UInt64) throws {
        try skip(integer(value))
    }

    private mutating func skip(_ count: Int) throws {
        _ = try readData(count)
    }

    private func integer(_ value: UInt64) throws -> Int {
        guard let value = Int(exactly: value) else { throw ScanError.invalid }
        return value
    }

    private enum ScanError: Error { case invalid }
}
