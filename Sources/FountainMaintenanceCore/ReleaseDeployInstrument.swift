import Foundation

/// FCIS contract for promoting one pinned server release through a host adapter.
/// The instrument is deliberately release-agnostic: no product version, provider,
/// hostname, or filesystem path is encoded here.
public struct ReleaseDeployRequest: Codable, Equatable, Sendable {
    public let releaseID: String
    public let sourceRevision: String
    public let packageResolutionDigest: String
    public let artifactDigest: String
    public let targetAlias: String
    public let targetHost: String
    public let releaseRoot: String
    public let serviceName: String
    public let rollbackReleaseID: String
    public let confirmation: Bool

    public init(releaseID: String, sourceRevision: String, packageResolutionDigest: String,
                artifactDigest: String, targetAlias: String, targetHost: String,
                releaseRoot: String, serviceName: String, rollbackReleaseID: String,
                confirmation: Bool) {
        self.releaseID = releaseID; self.sourceRevision = sourceRevision
        self.packageResolutionDigest = packageResolutionDigest; self.artifactDigest = artifactDigest
        self.targetAlias = targetAlias; self.targetHost = targetHost; self.releaseRoot = releaseRoot
        self.serviceName = serviceName; self.rollbackReleaseID = rollbackReleaseID
        self.confirmation = confirmation
    }
}

public struct ReleaseDeployReceipt: Codable, Equatable, Sendable {
    public let releaseID: String
    public let sourceRevision: String
    public let targetAlias: String
    public let previousReleaseID: String
    public let healthVerified: Bool
    public let routePatchVerified: Bool
    public let rolledBack: Bool

    public init(releaseID: String, sourceRevision: String, targetAlias: String,
                previousReleaseID: String, healthVerified: Bool,
                routePatchVerified: Bool, rolledBack: Bool) {
        self.releaseID = releaseID; self.sourceRevision = sourceRevision
        self.targetAlias = targetAlias; self.previousReleaseID = previousReleaseID
        self.healthVerified = healthVerified; self.routePatchVerified = routePatchVerified
        self.rolledBack = rolledBack
    }
}

public enum ReleaseDeployStage: String, Codable, CaseIterable, Sendable {
    case candidateValidated, staged, switched, healthVerified, routePatchVerified, rolledBack, completed
}

public enum ReleaseDeployInstrument {
    public static let operation = MaintenanceOperationKind.releaseDeploy
    public static let identity = "fountaincoach.release-deploy@0.1.0"

    public static func validate(_ request: ReleaseDeployRequest) throws {
        guard request.confirmation else { throw Validation.confirmationRequired }
        guard !request.releaseID.isEmpty, !request.sourceRevision.isEmpty,
              !request.packageResolutionDigest.isEmpty, !request.artifactDigest.isEmpty,
              !request.targetAlias.isEmpty, !request.targetHost.isEmpty,
              !request.releaseRoot.isEmpty, !request.serviceName.isEmpty,
              !request.rollbackReleaseID.isEmpty else { throw Validation.missingIdentity }
        guard request.releaseID != request.rollbackReleaseID else { throw Validation.rollbackMustDiffer }
    }

    public enum Validation: Error, Equatable, Sendable {
        case confirmationRequired, missingIdentity, rollbackMustDiffer
    }
}

/// Provider-specific effect boundary. Implementations perform SSH/host-agent
/// work; the MaintenanceKit contract remains independent of any host or
/// release version.
public protocol ReleaseDeployHostAdapter: Sendable {
    func validateCandidate(_ request: ReleaseDeployRequest) async throws
    func stage(_ request: ReleaseDeployRequest) async throws
    func switchRelease(_ request: ReleaseDeployRequest) async throws
    func verifyHealthAndRoutePatch(_ request: ReleaseDeployRequest) async throws
    func rollback(_ request: ReleaseDeployRequest) async throws
}

public struct ReleaseDeployWorkflow: Sendable {
    public init() {}

    public func execute(_ request: ReleaseDeployRequest,
                        using adapter: any ReleaseDeployHostAdapter) async throws -> ReleaseDeployReceipt {
        try ReleaseDeployInstrument.validate(request)
        do {
            try await adapter.validateCandidate(request)
            try await adapter.stage(request)
            try await adapter.switchRelease(request)
            try await adapter.verifyHealthAndRoutePatch(request)
            return ReleaseDeployReceipt(releaseID: request.releaseID,
                                        sourceRevision: request.sourceRevision,
                                        targetAlias: request.targetAlias,
                                        previousReleaseID: request.rollbackReleaseID,
                                        healthVerified: true,
                                        routePatchVerified: true,
                                        rolledBack: false)
        } catch {
            try await adapter.rollback(request)
            throw error
        }
    }
}
