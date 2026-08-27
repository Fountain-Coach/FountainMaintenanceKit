import Foundation

public enum MaintenanceOperationKind: String, Codable, Sendable, CaseIterable {
    case healthVerify = "health.verify"
    case candidatePromote = "candidate.promote"
    case releaseDeploy = "release.deploy"
    case releaseRollback = "release.rollback"
    case migrationExport = "migration.export"
    case migrationRestore = "migration.restore"
}

public enum MaintenanceOperationState: String, Codable, Sendable {
    case proposed, awaitingAuthorization, running, succeeded, failed, cancelled
}

public enum MaintenanceAuthorization: Codable, Equatable, Sendable {
    case pending
    case approved(actor: String, scope: String)
    case denied(reason: String)

    private enum CodingKeys: String, CodingKey { case state, actor, scope, reason }
    private enum State: String, Codable { case pending, approved, denied }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .pending: try container.encode(State.pending, forKey: .state)
        case let .approved(actor, scope):
            try container.encode(State.approved, forKey: .state)
            try container.encode(actor, forKey: .actor)
            try container.encode(scope, forKey: .scope)
        case let .denied(reason):
            try container.encode(State.denied, forKey: .state)
            try container.encode(reason, forKey: .reason)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(State.self, forKey: .state) {
        case .pending: self = .pending
        case .approved: self = .approved(actor: try container.decode(String.self, forKey: .actor), scope: try container.decode(String.self, forKey: .scope))
        case .denied: self = .denied(reason: try container.decode(String.self, forKey: .reason))
        }
    }
}

public struct MaintenanceSecretReference: Codable, Equatable, Hashable, Sendable {
    public let service: String
    public let account: String
    public let label: String

    public init(service: String, account: String, label: String) {
        self.service = service; self.account = account; self.label = label
    }
}

public enum SecretAccessState: String, Codable, Sendable {
    case configured, unavailable, denied, expired, rotated
}

public protocol MaintenanceSecretResolver: Sendable {
    func resolve(reference: MaintenanceSecretReference) async throws -> SecretAccessState
}

public struct MaintenanceOperationRequest: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let idempotencyKey: String
    public let kind: MaintenanceOperationKind
    public let actor: String
    public let targetAlias: String
    public let requestedScope: String
    public let expectedRevision: String?
    public let secretReference: MaintenanceSecretReference?
    public let confirmation: Bool

    public init(id: String, idempotencyKey: String, kind: MaintenanceOperationKind, actor: String,
                targetAlias: String, requestedScope: String, expectedRevision: String? = nil,
                secretReference: MaintenanceSecretReference? = nil, confirmation: Bool) {
        self.id = id; self.idempotencyKey = idempotencyKey; self.kind = kind; self.actor = actor
        self.targetAlias = targetAlias; self.requestedScope = requestedScope; self.expectedRevision = expectedRevision
        self.secretReference = secretReference; self.confirmation = confirmation
    }
}

public struct MaintenanceOperationReceipt: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let idempotencyKey: String
    public let kind: MaintenanceOperationKind
    public let state: MaintenanceOperationState
    public let targetAlias: String
    public let actor: String
    public let authorization: MaintenanceAuthorization
    public let previousRelease: String?
    public let currentRelease: String?
    public let verification: [String]
    public let failure: String?
    public let createdAt: Date
    public let updatedAt: Date

    public init(id: String, idempotencyKey: String, kind: MaintenanceOperationKind,
                state: MaintenanceOperationState, targetAlias: String, actor: String,
                authorization: MaintenanceAuthorization, previousRelease: String? = nil,
                currentRelease: String? = nil, verification: [String] = [], failure: String? = nil,
                createdAt: Date, updatedAt: Date) {
        self.id = id; self.idempotencyKey = idempotencyKey; self.kind = kind; self.state = state
        self.targetAlias = targetAlias; self.actor = actor; self.authorization = authorization
        self.previousRelease = previousRelease; self.currentRelease = currentRelease
        self.verification = verification; self.failure = failure; self.createdAt = createdAt; self.updatedAt = updatedAt
    }
}

public struct MaintenanceReleaseManifest: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let providerRevision: String
    public let contentDigest: String
    public let endpointAlias: String
    public let packageRevision: String

    public init(id: String, providerRevision: String, contentDigest: String, endpointAlias: String, packageRevision: String) {
        self.id = id; self.providerRevision = providerRevision; self.contentDigest = contentDigest
        self.endpointAlias = endpointAlias; self.packageRevision = packageRevision
    }
}

public struct MaintenanceMigrationManifest: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let exportedAt: Date
    public let releases: [MaintenanceReleaseManifest]
    public let endpointAlias: String
    public let secretReferences: [MaintenanceSecretReference]
    public let rollbackReleaseID: String?

    public init(id: String, exportedAt: Date, releases: [MaintenanceReleaseManifest], endpointAlias: String,
                secretReferences: [MaintenanceSecretReference] = [], rollbackReleaseID: String? = nil) {
        self.id = id; self.exportedAt = exportedAt; self.releases = releases; self.endpointAlias = endpointAlias
        self.secretReferences = secretReferences; self.rollbackReleaseID = rollbackReleaseID
    }
}

// MARK: - Chapter 117 recovery projection

/// A Store record included in a recovery projection. The payload is already a
/// typed, policy-approved JSON projection; raw Store files are never part of
/// this contract.
public struct RecoveryProjectionDocument: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let kind: String
    public let contentDigest: String
    public let payload: Data

    public init(id: String, kind: String, contentDigest: String, payload: Data) throws {
        guard !id.isEmpty, !kind.isEmpty, !contentDigest.isEmpty, !payload.isEmpty else {
            throw RecoveryProjectionError.invalidDocument
        }
        self.id = id
        self.kind = kind
        self.contentDigest = contentDigest
        self.payload = payload
    }
}

/// A content-addressed attachment reference. Payloads may be omitted by
/// policy, but the reference and omission reason remain recoverable.
public struct RecoveryProjectionAsset: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let mediaType: String
    public let contentDigest: String
    public let byteLength: Int64
    public let includedPayload: Data?
    public let omissionReason: String?

    public init(id: String, mediaType: String, contentDigest: String, byteLength: Int64,
                includedPayload: Data? = nil, omissionReason: String? = nil) throws {
        guard !id.isEmpty, !mediaType.isEmpty, !contentDigest.isEmpty, byteLength >= 0 else {
            throw RecoveryProjectionError.invalidAsset
        }
        guard includedPayload != nil || omissionReason != nil else {
            throw RecoveryProjectionError.assetDispositionMissing
        }
        self.id = id
        self.mediaType = mediaType
        self.contentDigest = contentDigest
        self.byteLength = byteLength
        self.includedPayload = includedPayload
        self.omissionReason = omissionReason
    }
}

public struct RecoveryProjectionManifest: Codable, Equatable, Sendable, Identifiable {
    public static let currentFormatVersion = "fountain-coach.recovery.v1"

    public let id: String
    public let formatVersion: String
    public let sourceStoreIdentity: String
    public let sourceStoreSchema: String
    public let sourceStoreSequence: UInt64
    public let exportedAt: Date
    public let sourceRevision: String
    public let documents: [RecoveryProjectionDocument]
    public let assets: [RecoveryProjectionAsset]
    public let kitVersions: [String: String]

    public init(id: String, sourceStoreIdentity: String, sourceStoreSchema: String,
                sourceStoreSequence: UInt64, exportedAt: Date = Date(), sourceRevision: String,
                documents: [RecoveryProjectionDocument], assets: [RecoveryProjectionAsset],
                kitVersions: [String: String]) throws {
        guard !id.isEmpty, !sourceStoreIdentity.isEmpty, !sourceStoreSchema.isEmpty,
              !sourceRevision.isEmpty, !documents.isEmpty, !kitVersions.isEmpty else {
            throw RecoveryProjectionError.invalidManifest
        }
        self.id = id
        self.formatVersion = Self.currentFormatVersion
        self.sourceStoreIdentity = sourceStoreIdentity
        self.sourceStoreSchema = sourceStoreSchema
        self.sourceStoreSequence = sourceStoreSequence
        self.exportedAt = exportedAt
        self.sourceRevision = sourceRevision
        self.documents = documents.sorted { $0.id < $1.id }
        self.assets = assets.sorted { $0.id < $1.id }
        self.kitVersions = kitVersions
    }
}

public struct RecoveryProjection: Codable, Equatable, Sendable {
    public let manifest: RecoveryProjectionManifest
    public let projectionDigest: String

    public init(manifest: RecoveryProjectionManifest, projectionDigest: String) throws {
        guard !projectionDigest.isEmpty else { throw RecoveryProjectionError.invalidDigest }
        self.manifest = manifest
        self.projectionDigest = projectionDigest
    }
}

public struct RecoveryProjectionReceipt: Codable, Equatable, Sendable, Identifiable {
    public enum State: String, Codable, Sendable { case exported, committed, mirrored, restored, failed }

    public let id: String
    public let idempotencyKey: String
    public let state: State
    public let sourceStoreIdentity: String
    public let projectionDigest: String
    public let localRepository: String?
    public let localCommit: String?
    public let mirrorRepository: String?
    public let mirrorCommit: String?
    public let targetStoreIdentity: String?
    public let verification: [String]
    public let failure: String?

    public init(id: String, idempotencyKey: String, state: State, sourceStoreIdentity: String,
                projectionDigest: String, localRepository: String? = nil, localCommit: String? = nil,
                mirrorRepository: String? = nil, mirrorCommit: String? = nil,
                targetStoreIdentity: String? = nil, verification: [String] = [], failure: String? = nil) throws {
        guard !id.isEmpty, !idempotencyKey.isEmpty, !sourceStoreIdentity.isEmpty,
              !projectionDigest.isEmpty else { throw RecoveryProjectionError.invalidReceipt }
        self.id = id
        self.idempotencyKey = idempotencyKey
        self.state = state
        self.sourceStoreIdentity = sourceStoreIdentity
        self.projectionDigest = projectionDigest
        self.localRepository = localRepository
        self.localCommit = localCommit
        self.mirrorRepository = mirrorRepository
        self.mirrorCommit = mirrorCommit
        self.targetStoreIdentity = targetStoreIdentity
        self.verification = verification
        self.failure = failure
    }
}

public enum RecoveryProjectionError: Error, Equatable, Sendable {
    case invalidDocument
    case invalidAsset
    case assetDispositionMissing
    case invalidManifest
    case invalidDigest
    case invalidReceipt
    case secretMaterialDetected
}

/// Deterministic, secret-free projection boundary. Host adapters own Store
/// reads, Git commits, mirrors, and restores; this type owns the format and
/// completeness checks shared by every host.
public enum RecoveryProjectionCodec {
    public static func encode(_ manifest: RecoveryProjectionManifest) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(manifest)
        guard !data.isEmpty else { throw RecoveryProjectionError.invalidManifest }
        return data
    }

    public static func decode(_ data: Data) throws -> RecoveryProjectionManifest {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(RecoveryProjectionManifest.self, from: data)
        guard manifest.formatVersion == RecoveryProjectionManifest.currentFormatVersion else {
            throw RecoveryProjectionError.invalidManifest
        }
        return manifest
    }

    public static func validate(_ manifest: RecoveryProjectionManifest) throws {
        guard !manifest.documents.isEmpty else { throw RecoveryProjectionError.invalidManifest }
        guard manifest.documents.map(\.id).count == Set(manifest.documents.map(\.id)).count else {
            throw RecoveryProjectionError.invalidManifest
        }
        guard manifest.assets.map(\.id).count == Set(manifest.assets.map(\.id)).count else {
            throw RecoveryProjectionError.invalidManifest
        }
        for asset in manifest.assets where asset.includedPayload == nil && asset.omissionReason == nil {
            throw RecoveryProjectionError.assetDispositionMissing
        }
    }
}

public enum MaintenanceValidationError: Error, Equatable, Sendable {
    case emptyField(String)
    case confirmationRequired
    case authorizationRequired
    case secretValueNotPermitted
    case idempotencyConflict
}

public enum MaintenanceValidator {
    public static func validate(_ request: MaintenanceOperationRequest) throws {
        for (label, value) in [("id", request.id), ("idempotencyKey", request.idempotencyKey),
                               ("actor", request.actor), ("targetAlias", request.targetAlias),
                               ("requestedScope", request.requestedScope)] where value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw MaintenanceValidationError.emptyField(label)
        }
        guard request.confirmation else { throw MaintenanceValidationError.confirmationRequired }
        if request.actor.lowercased().contains("secret") || request.targetAlias.contains("/") || request.targetAlias.contains("\\") {
            throw MaintenanceValidationError.secretValueNotPermitted
        }
    }

    public static func receipt(for request: MaintenanceOperationRequest, authorization: MaintenanceAuthorization,
                              state: MaintenanceOperationState = .proposed, now: Date = Date()) -> MaintenanceOperationReceipt {
        MaintenanceOperationReceipt(id: request.id, idempotencyKey: request.idempotencyKey, kind: request.kind,
                                     state: state, targetAlias: request.targetAlias, actor: request.actor,
                                     authorization: authorization, createdAt: now, updatedAt: now)
    }
}

/// Admission authority for a maintenance service. It deliberately stores only typed requests and sanitized receipts;
/// a host adapter performs the actual operation after admission and authorization.
public actor MaintenanceOperationLedger {
    private struct Entry: Sendable {
        let request: MaintenanceOperationRequest
        let receipt: MaintenanceOperationReceipt
    }

    private var entries: [String: Entry] = [:]

    public init() {}

    /// Admit once per idempotency key. A retry with the same request returns the original receipt; reusing the key
    /// for a different operation is rejected instead of creating a second mutation.
    public func admit(_ request: MaintenanceOperationRequest,
                      authorization: MaintenanceAuthorization,
                      now: Date = Date()) throws -> MaintenanceOperationReceipt {
        try MaintenanceValidator.validate(request)
        if let existing = entries[request.idempotencyKey] {
            guard existing.request == request else { throw MaintenanceValidationError.idempotencyConflict }
            return existing.receipt
        }
        let receipt = MaintenanceValidator.receipt(for: request, authorization: authorization, now: now)
        entries[request.idempotencyKey] = Entry(request: request, receipt: receipt)
        return receipt
    }

    public func receipt(for idempotencyKey: String) -> MaintenanceOperationReceipt? {
        entries[idempotencyKey]?.receipt
    }
}
