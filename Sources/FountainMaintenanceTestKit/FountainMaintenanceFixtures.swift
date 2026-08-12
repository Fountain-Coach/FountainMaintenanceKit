import Foundation
import FountainMaintenanceCore
import FountainMaintenanceClient

public enum FountainMaintenanceFixtures {
    public static let secretReference = MaintenanceSecretReference(
        service: "FountainCoach", account: "maintenance", label: "Book Library maintenance")

    public static func request(kind: MaintenanceOperationKind = .healthVerify,
                               confirmation: Bool = true) -> MaintenanceOperationRequest {
        MaintenanceOperationRequest(id: "operation-fixture", idempotencyKey: "idem-fixture", kind: kind,
                                    actor: "owner@example.test", targetAlias: "book-library",
                                    requestedScope: "library:read", expectedRevision: "revision-fixture",
                                    secretReference: secretReference, confirmation: confirmation)
    }

    public static func release() -> MaintenanceReleaseManifest {
        MaintenanceReleaseManifest(id: "release-fixture", providerRevision: "provider-revision",
                                   contentDigest: "sha256:fixture", endpointAlias: "book-library",
                                   packageRevision: "package-fixture")
    }
}

public actor FixtureMaintenanceTransport: MaintenanceTransport {
    public private(set) var requests: [URLRequest] = []
    private let receipt: MaintenanceOperationReceipt

    public init(receipt: MaintenanceOperationReceipt) { self.receipt = receipt }

    public func send(_ request: URLRequest, secretReference: MaintenanceSecretReference?) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let data = try JSONEncoder().encode(receipt)
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        return (data, response)
    }
}
