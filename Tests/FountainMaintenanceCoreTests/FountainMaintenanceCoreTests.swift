import Foundation
import XCTest
@testable import FountainMaintenanceCore

private actor SharedEnrollmentReplayStore: MaintenanceEnrollmentReplayStore {
    private var consumed: Set<String> = []

    func consume(_ bindingDigest: String) async throws -> Bool {
        consumed.insert(bindingDigest).inserted
    }
}

final class RecoveryProjectionTests: XCTestCase {
    func testProjectionEncodingIsDeterministicAndSorted() throws {
        let first = try RecoveryProjectionDocument(id: "scenario:2", kind: "scenario", contentDigest: "d2", payload: Data("two".utf8))
        let second = try RecoveryProjectionDocument(id: "scenario:1", kind: "scenario", contentDigest: "d1", payload: Data("one".utf8))
        let manifest = try RecoveryProjectionManifest(
            id: "export-1", sourceStoreIdentity: "store-1", sourceStoreSchema: "0.4",
            sourceStoreSequence: 12, exportedAt: Date(timeIntervalSince1970: 0), sourceRevision: "abc",
            documents: [first, second], assets: [], kitVersions: ["FountainMaintenanceKit": "0.3.0"])

        let encoded = try RecoveryProjectionCodec.encode(manifest)
        let decoded = try RecoveryProjectionCodec.decode(encoded)
        XCTAssertEqual(decoded.documents.map(\.id), ["scenario:1", "scenario:2"])
        XCTAssertEqual(encoded, try RecoveryProjectionCodec.encode(decoded))
    }

    func testAssetMustDeclareIncludedOrReferencedDisposition() throws {
        XCTAssertThrowsError(try RecoveryProjectionAsset(id: "asset-1", mediaType: "text/plain", contentDigest: "d", byteLength: 1)) { error in
            XCTAssertEqual(error as? RecoveryProjectionError, .assetDispositionMissing)
        }
        XCTAssertNoThrow(try RecoveryProjectionAsset(id: "asset-1", mediaType: "text/plain", contentDigest: "d", byteLength: 1, omissionReason: "private source"))
    }

    func testReceiptRequiresIdentityAndDigest() throws {
        XCTAssertThrowsError(try RecoveryProjectionReceipt(id: "", idempotencyKey: "k", state: .exported, sourceStoreIdentity: "store", projectionDigest: "digest"))
        XCTAssertNoThrow(try RecoveryProjectionReceipt(id: "r", idempotencyKey: "k", state: .exported, sourceStoreIdentity: "store", projectionDigest: "digest"))
    }
}
import FountainMaintenanceTestKit
import FountainMaintenanceClient

final class FountainMaintenanceCoreTests: XCTestCase {
    private func enrolledRegistry(devicePublicKey: Data) async throws -> MaintenanceTrustedDeviceRegistry {
        let ownerSigner = try MaintenanceEnrollmentSigner(privateKeyData: Data(repeating: 9, count: 32))
        let enrollmentAuthority = try MaintenanceEnrollmentAuthority(approverPublicKeys: ["owner-1": ownerSigner.publicKey])
        let registry = MaintenanceTrustedDeviceRegistry(enrollmentAuthority: enrollmentAuthority)
        let now = Date(timeIntervalSince1970: 1_000)
        let request = try MaintenanceDeviceEnrollmentRequest(
            deviceKeyID: "phone-1", publicKey: devicePublicKey, nonce: "enrollment-nonce",
            expiresAt: now.addingTimeInterval(300))
        let authorization = try ownerSigner.authorize(
            request: request, approverKeyID: "owner-1", approvedAt: now, expiresAt: now.addingTimeInterval(120))
        try await registry.register(request: request, authorization: authorization, now: now)
        return registry
    }

    private struct RecordingSecretProvider: MaintenanceSecretProvider {
        let secret: Data
        func withSecret<T: Sendable>(reference: MaintenanceSecretReference,
                                     operation: @escaping @Sendable (Data) async throws -> T) async throws -> T {
            XCTAssertEqual(reference, FountainMaintenanceFixtures.secretReference)
            return try await operation(secret)
        }
    }

    func testEnrollmentWireContractIsPublicRedactedAndRoundTrips() throws {
        let owner = try MaintenanceEnrollmentSigner(privateKeyData: Data(repeating: 9, count: 32))
        let device = try MaintenanceEnrollmentSigner(privateKeyData: Data(repeating: 10, count: 32))
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let request = try MaintenanceDeviceEnrollmentRequest(
            deviceKeyID: "owner-device",
            publicKey: device.publicKey,
            nonce: "one-time-1",
            expiresAt: now.addingTimeInterval(300))
        let authorization = try owner.authorize(
            request: request,
            approverKeyID: "owner-primary",
            approvedAt: now,
            expiresAt: now.addingTimeInterval(120))
        let submission = MaintenanceDeviceEnrollmentSubmission(
            request: request,
            authorization: authorization)
        let encoded = try JSONEncoder().encode(submission)
        XCTAssertEqual(try JSONDecoder().decode(MaintenanceDeviceEnrollmentSubmission.self, from: encoded), submission)

        let payload = try MaintenanceEnrollmentQRPayload(
            approvalOrigin: "https://approve.fountain.coach/",
            challengeID: request.nonce,
            deviceKeyID: request.deviceKeyID,
            devicePublicKey: request.publicKey,
            expiresAt: request.expiresAt)
        XCTAssertEqual(
            payload.qrPayload,
            "https://approve.fountain.coach/enroll/one-time-1?device=owner-device&publicKey=\(request.publicKey.base64EncodedString())&expiresAt=1700000300.0")
        XCTAssertFalse(payload.qrPayload.contains(authorization.signature.base64EncodedString()))

        let receipt = MaintenanceDeviceEnrollmentReceipt(deviceKeyID: request.deviceKeyID, state: "enrolled")
        XCTAssertTrue(receipt.terminal)
        XCTAssertEqual(try JSONDecoder().decode(MaintenanceDeviceEnrollmentReceipt.self, from: JSONEncoder().encode(receipt)), receipt)
    }

    func testTypedClientCarriesIdempotencyAndOpaqueReferenceWithoutCredential() async throws {
        let operation = FountainMaintenanceFixtures.request()
        let receipt = MaintenanceValidator.receipt(for: operation, authorization: .pending)
        let transport = FixtureMaintenanceTransport(receipt: receipt)
        let client = try FountainMaintenanceClient(endpoint: URL(string: "https://library.example.test")!, transport: transport)
        let returned = try await client.submit(operation)
        let requests = await transport.requests
        XCTAssertEqual(returned, receipt)
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Idempotency-Key"), operation.idempotencyKey)
        XCTAssertFalse(String(decoding: requests[0].httpBody ?? Data(), as: UTF8.self).contains("fixture-secret-value"))
    }

    func testSecretProviderIsAnEphemeralTransportBoundary() async throws {
        let operation = FountainMaintenanceFixtures.request()
        let provider = RecordingSecretProvider(secret: Data("fixture-secret-value".utf8))
        let released = try await provider.withSecret(reference: operation.secretReference!) { secret in
            String(decoding: secret, as: UTF8.self)
        }
        XCTAssertEqual(released, "fixture-secret-value")
    }

    func testLedgerReturnsOriginalReceiptForIdempotentRetryAndRejectsCollision() async throws {
        let ledger = MaintenanceOperationLedger()
        let request = FountainMaintenanceFixtures.request()
        let first = try await ledger.admit(request, authorization: .pending, now: Date(timeIntervalSince1970: 1))
        let retry = try await ledger.admit(request, authorization: .pending, now: Date(timeIntervalSince1970: 2))
        XCTAssertEqual(retry, first)

        let collision = MaintenanceOperationRequest(
            id: "different-operation", idempotencyKey: request.idempotencyKey, kind: .releaseDeploy,
            actor: request.actor, targetAlias: request.targetAlias, requestedScope: request.requestedScope,
            confirmation: true)
        do {
            _ = try await ledger.admit(collision, authorization: .pending)
            XCTFail("reusing an idempotency key for a different request must fail")
        } catch {
            XCTAssertEqual(error as? MaintenanceValidationError, .idempotencyConflict)
        }
    }

    func testRequestRoundTripContainsReferenceNotSecret() throws {
        let request = FountainMaintenanceFixtures.request()
        let data = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(MaintenanceOperationRequest.self, from: data)
        XCTAssertEqual(decoded, request)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("token"))
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("maintenance"))
    }

    func testMissingConfirmationFailsBeforeAuthorization() {
        XCTAssertThrowsError(try MaintenanceValidator.validate(FountainMaintenanceFixtures.request(confirmation: false))) { error in
            XCTAssertEqual(error as? MaintenanceValidationError, .confirmationRequired)
        }
    }

    func testReceiptIsSanitizedAndUsesHostIndependentAlias() throws {
        let request = FountainMaintenanceFixtures.request(kind: .releaseDeploy)
        try MaintenanceValidator.validate(request)
        let receipt = MaintenanceValidator.receipt(for: request, authorization: .approved(actor: "owner@example.test", scope: "library:write"))
        let data = try JSONEncoder().encode(receipt)
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertEqual(receipt.targetAlias, "book-library")
        XCTAssertFalse(json.contains("/Volumes/"))
        XCTAssertFalse(json.contains("privateKey"))
        XCTAssertFalse(json.contains("Authorization"))
    }

    func testMigrationManifestCarriesReferencesAndNoCredential() throws {
        let manifest = MaintenanceMigrationManifest(id: "migration-fixture", exportedAt: Date(timeIntervalSince1970: 0),
                                                     releases: [FountainMaintenanceFixtures.release()], endpointAlias: "book-library",
                                                     secretReferences: [FountainMaintenanceFixtures.secretReference], rollbackReleaseID: "release-fixture")
        let decoded = try JSONDecoder().decode(MaintenanceMigrationManifest.self, from: JSONEncoder().encode(manifest))
        XCTAssertEqual(decoded, manifest)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(manifest), as: UTF8.self).contains("fixture-secret-value"))
    }

    func testApprovalBrokerExposesOnlyOpaqueProjectionAndConsumesOnce() async throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let challenge = try MaintenanceApprovalChallenge(
            challengeID: "challenge-1", operation: "release.deploy", target: "book-library",
            scope: "library:write", secretReference: "service/account/label", nonce: "nonce-1",
            expiresAt: now.addingTimeInterval(300), correlationID: "corr-1",
            approvalOrigin: "https://approve.example.test")
        let signer = try MaintenanceTrustedDeviceSigner(privateKeyData: Data(repeating: 7, count: 32))
        let registry = try await enrolledRegistry(devicePublicKey: signer.publicKey)
        let broker = MaintenanceApprovalBroker(registry: registry)
        let publicChallenge = try await broker.issue(challenge: challenge, now: now)

        let publicJSON = String(decoding: try JSONEncoder().encode(publicChallenge), as: UTF8.self)
        XCTAssertTrue(publicJSON.contains("challenge-1"))
        XCTAssertFalse(publicJSON.contains("service/account/label"))
        XCTAssertFalse(publicJSON.contains("nonce-1"))
        XCTAssertEqual(publicChallenge.qrPayload, "https://approve.example.test/approve/challenge-1")

        let approval = try signer.sign(publicChallenge: publicChallenge, decision: .approved, deviceKeyID: "phone-1",
                                       approvedAt: now, expiresAt: now.addingTimeInterval(120))
        let outcome = try await broker.approve(challengeID: "challenge-1", approval: approval, now: now)
        XCTAssertEqual(outcome.receipt.state, .approved)
        XCTAssertNotNil(outcome.lease)
        let replay = try await broker.approve(challengeID: "challenge-1", approval: approval, now: now)
        XCTAssertEqual(replay.receipt.state, .replayed)
        XCTAssertNil(replay.lease)
    }

    func testEnrollmentRequiresOwnerAuthorizationAndCannotBeReplayed() async throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let device = try MaintenanceTrustedDeviceSigner(privateKeyData: Data(repeating: 7, count: 32))
        let owner = try MaintenanceEnrollmentSigner(privateKeyData: Data(repeating: 9, count: 32))
        let impostor = try MaintenanceEnrollmentSigner(privateKeyData: Data(repeating: 10, count: 32))
        let authority = try MaintenanceEnrollmentAuthority(approverPublicKeys: ["owner-1": owner.publicKey])
        let registry = MaintenanceTrustedDeviceRegistry(enrollmentAuthority: authority)
        let request = try MaintenanceDeviceEnrollmentRequest(
            deviceKeyID: "phone-1", publicKey: device.publicKey, nonce: "nonce", expiresAt: now.addingTimeInterval(300))
        let forged = try impostor.authorize(request: request, approverKeyID: "owner-1",
                                            approvedAt: now, expiresAt: now.addingTimeInterval(120))
        do {
            try await registry.register(request: request, authorization: forged, now: now)
            XCTFail("an untrusted signer must not enroll a device")
        } catch let error as MaintenanceApprovalVerificationError {
            XCTAssertEqual(error, .enrollmentSignatureInvalid)
        }
        let unknownAuthority = try owner.authorize(request: request, approverKeyID: "not-configured",
                                                   approvedAt: now, expiresAt: now.addingTimeInterval(120))
        do {
            try await registry.register(request: request, authorization: unknownAuthority, now: now)
            XCTFail("an unknown owner key must not enroll a device")
        } catch let error as MaintenanceApprovalVerificationError {
            XCTAssertEqual(error, .unknownEnrollmentAuthority)
        }
        let expired = try owner.authorize(request: request, approverKeyID: "owner-1",
                                          approvedAt: now, expiresAt: now.addingTimeInterval(10))
        do {
            try await registry.register(request: request, authorization: expired, now: now.addingTimeInterval(11))
            XCTFail("an expired enrollment must not enroll a device")
        } catch let error as MaintenanceApprovalVerificationError {
            XCTAssertEqual(error, .enrollmentExpired)
        }
        let otherRequest = try MaintenanceDeviceEnrollmentRequest(
            deviceKeyID: "phone-1", publicKey: device.publicKey, nonce: "different-nonce",
            expiresAt: now.addingTimeInterval(300))
        let mismatched = try owner.authorize(request: request, approverKeyID: "owner-1",
                                             approvedAt: now, expiresAt: now.addingTimeInterval(120))
        do {
            try await registry.register(request: otherRequest, authorization: mismatched, now: now)
            XCTFail("an enrollment bound to another request must be refused")
        } catch let error as MaintenanceApprovalVerificationError {
            XCTAssertEqual(error, .bindingMismatch)
        }
        let authorization = try owner.authorize(request: request, approverKeyID: "owner-1",
                                                approvedAt: now, expiresAt: now.addingTimeInterval(120))
        try await registry.register(request: request, authorization: authorization, now: now)
        let registeredIDs = await registry.registeredDeviceIDs()
        XCTAssertEqual(registeredIDs, ["phone-1"])
        do {
            try await registry.register(request: request, authorization: authorization, now: now)
            XCTFail("an enrollment authorization must be one-time")
        } catch let error as MaintenanceApprovalVerificationError {
            XCTAssertEqual(error, .enrollmentReplayed)
        }

        let sharedStore = SharedEnrollmentReplayStore()
        let sharedAuthority = try MaintenanceEnrollmentAuthority(
            approverPublicKeys: ["owner-1": owner.publicKey], replayStore: sharedStore)
        let firstRegistry = MaintenanceTrustedDeviceRegistry(enrollmentAuthority: sharedAuthority)
        try await firstRegistry.register(request: request, authorization: authorization, now: now)
        let secondAuthority = try MaintenanceEnrollmentAuthority(
            approverPublicKeys: ["owner-1": owner.publicKey], replayStore: sharedStore)
        let secondRegistry = MaintenanceTrustedDeviceRegistry(enrollmentAuthority: secondAuthority)
        do {
            try await secondRegistry.register(request: request, authorization: authorization, now: now)
            XCTFail("a durable replay store must refuse reuse across authority instances")
        } catch let error as MaintenanceApprovalVerificationError {
            XCTAssertEqual(error, .enrollmentReplayed)
        }
    }

    func testApprovalClientUsesTheChallengeOriginAndRejectsUnsafeOrigins() async throws {
        let challenge = try MaintenanceApprovalChallenge(
            challengeID: "safe-id_1", operation: "health.verify", target: "book-library",
            scope: "health:read", secretReference: "service/account/label", nonce: "nonce-2",
            expiresAt: Date(timeIntervalSince1970: 2_000), correlationID: "corr-2",
            approvalOrigin: "https://approve.example.test")
        let ownerSigner = try MaintenanceEnrollmentSigner(privateKeyData: Data(repeating: 9, count: 32))
        let enrollmentAuthority = try MaintenanceEnrollmentAuthority(approverPublicKeys: ["owner-1": ownerSigner.publicKey])
        let broker = MaintenanceApprovalBroker(registry: MaintenanceTrustedDeviceRegistry(enrollmentAuthority: enrollmentAuthority))
        let publicChallenge = try await broker.issue(challenge: challenge, now: Date(timeIntervalSince1970: 1_000))
        XCTAssertEqual(
            try MaintenanceApprovalClient.endpoint(for: publicChallenge).absoluteString,
            "https://approve.example.test/approve/safe-id_1")

        let unsafe = try MaintenanceApprovalChallenge(
            challengeID: "../escape", operation: "health.verify", target: "book-library",
            scope: "health:read", secretReference: "service/account/label", nonce: "nonce-3",
            expiresAt: Date(timeIntervalSince1970: 2_000), correlationID: "corr-3",
            approvalOrigin: "https://approve.example.test")
        let unsafeProjection = try await broker.issue(challenge: unsafe, now: Date(timeIntervalSince1970: 1_000))
        XCTAssertThrowsError(try MaintenanceApprovalClient.endpoint(for: unsafeProjection)) { error in
            XCTAssertEqual(error as? MaintenanceApprovalClientTransportError, .invalidChallengeID)
        }
    }
}
