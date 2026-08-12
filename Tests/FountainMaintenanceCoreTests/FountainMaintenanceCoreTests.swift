import Foundation
import XCTest
@testable import FountainMaintenanceCore
import FountainMaintenanceTestKit
import FountainMaintenanceClient

final class FountainMaintenanceCoreTests: XCTestCase {
    private struct RecordingSecretProvider: MaintenanceSecretProvider {
        let secret: Data
        func withSecret<T: Sendable>(reference: MaintenanceSecretReference,
                                     operation: @escaping @Sendable (Data) async throws -> T) async throws -> T {
            XCTAssertEqual(reference, FountainMaintenanceFixtures.secretReference)
            return try await operation(secret)
        }
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
}
