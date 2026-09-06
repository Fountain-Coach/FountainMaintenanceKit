import Foundation
import Crypto

/// A server-issued approval challenge. Only the opaque public projection may
/// leave the server; the complete challenge remains broker-owned.
public struct MaintenanceApprovalChallenge: Codable, Equatable, Sendable {
    public let challengeID: String
    public let operation: String
    public let target: String
    public let scope: String
    public let secretReference: String
    public let nonce: String
    public let expiresAt: Date
    public let correlationID: String
    public let approvalOrigin: String

    public init(
        challengeID: String, operation: String, target: String, scope: String,
        secretReference: String, nonce: String, expiresAt: Date,
        correlationID: String, approvalOrigin: String
    ) throws {
        let values = [challengeID, operation, target, scope, secretReference, nonce, correlationID, approvalOrigin]
        guard values.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
              approvalOrigin.hasPrefix("https://") else {
            throw MaintenanceApprovalVerificationError.invalidChallenge
        }
        self.challengeID = challengeID
        self.operation = operation
        self.target = target
        self.scope = scope
        self.secretReference = secretReference
        self.nonce = nonce
        self.expiresAt = expiresAt
        self.correlationID = correlationID
        self.approvalOrigin = approvalOrigin
    }

    public var qrPayload: String { "\(approvalOrigin)/approve/\(challengeID)" }

    public var bindingDigest: String {
        MaintenanceApprovalAuthority.digest([
            challengeID, operation, target, scope, secretReference, nonce,
            String(expiresAt.timeIntervalSince1970), correlationID, approvalOrigin
        ])
    }
}

public enum MaintenanceApprovalDecision: String, Codable, Sendable {
    case approved
    case denied
}

/// Signed device material. It contains no SecretStore value or operation body.
public struct MaintenanceSignedApproval: Codable, Equatable, Sendable {
    public let challengeBindingDigest: String
    public let decision: MaintenanceApprovalDecision
    public let deviceKeyID: String
    public let approvedAt: Date
    public let expiresAt: Date
    public let signature: Data

    public init(
        challenge: MaintenanceApprovalChallenge, decision: MaintenanceApprovalDecision,
        deviceKeyID: String, approvedAt: Date, expiresAt: Date, signature: Data
    ) throws {
        guard !deviceKeyID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !signature.isEmpty else {
            throw MaintenanceApprovalVerificationError.invalidApproval
        }
        self.challengeBindingDigest = challenge.bindingDigest
        self.decision = decision
        self.deviceKeyID = deviceKeyID
        self.approvedAt = approvedAt
        self.expiresAt = expiresAt
        self.signature = signature
    }

    fileprivate var signingMaterial: String {
        [challengeBindingDigest, decision.rawValue, deviceKeyID,
         String(approvedAt.timeIntervalSince1970), String(expiresAt.timeIntervalSince1970)]
            .joined(separator: "\u{1F}")
    }
}

public actor MaintenanceTrustedDeviceRegistry {
    private var publicKeys: [String: Data] = [:]
    private var revoked: Set<String> = []

    public init() {}

    public func register(deviceKeyID: String, publicKey: Data) throws {
        guard !deviceKeyID.isEmpty, !publicKey.isEmpty,
              (try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey)) != nil else {
            throw MaintenanceApprovalVerificationError.invalidDevice
        }
        publicKeys[deviceKeyID] = publicKey
        revoked.remove(deviceKeyID)
    }

    public func revoke(deviceKeyID: String) { revoked.insert(deviceKeyID) }

    fileprivate func key(for deviceKeyID: String) throws -> Data {
        guard let key = publicKeys[deviceKeyID] else { throw MaintenanceApprovalVerificationError.unknownDevice }
        guard !revoked.contains(deviceKeyID) else { throw MaintenanceApprovalVerificationError.revokedDevice }
        return key
    }
}

public enum MaintenanceApprovalVerificationError: Error, Equatable, Sendable {
    case invalidChallenge, invalidApproval, invalidDevice, unknownDevice, revokedDevice
    case bindingMismatch, invalidSignature, expired, denied, replayed
}

public actor MaintenanceApprovalAuthority {
    private let registry: MaintenanceTrustedDeviceRegistry
    private var consumedChallenges: Set<String> = []

    public init(registry: MaintenanceTrustedDeviceRegistry) { self.registry = registry }

    public func verifyAndConsume(
        challenge: MaintenanceApprovalChallenge, approval: MaintenanceSignedApproval, now: Date = Date()
    ) async throws {
        guard challenge.expiresAt > now, approval.expiresAt > now,
              approval.expiresAt <= challenge.expiresAt, approval.approvedAt <= now else {
            throw MaintenanceApprovalVerificationError.expired
        }
        guard approval.challengeBindingDigest == challenge.bindingDigest else {
            throw MaintenanceApprovalVerificationError.bindingMismatch
        }
        let keyData = try await registry.key(for: approval.deviceKeyID)
        guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData) else {
            throw MaintenanceApprovalVerificationError.invalidDevice
        }
        guard key.isValidSignature(approval.signature, for: Data(approval.signingMaterial.utf8)) else {
            throw MaintenanceApprovalVerificationError.invalidSignature
        }
        guard consumedChallenges.insert(challenge.challengeID).inserted else {
            throw MaintenanceApprovalVerificationError.replayed
        }
        guard approval.decision == .approved else { throw MaintenanceApprovalVerificationError.denied }
    }

    fileprivate static func digest(_ values: [String]) -> String {
        SHA256.hash(data: Data(values.joined(separator: "\u{1F}").utf8))
            .map { String(format: "%02x", $0) }.joined()
    }
}

public struct MaintenanceTrustedDeviceSigner: Sendable {
    private let privateKeyData: Data

    public init(privateKeyData: Data) throws {
        guard (try? Curve25519.Signing.PrivateKey(rawRepresentation: privateKeyData)) != nil else {
            throw MaintenanceApprovalVerificationError.invalidDevice
        }
        self.privateKeyData = privateKeyData
    }

    public var publicKey: Data {
        (try? Curve25519.Signing.PrivateKey(rawRepresentation: privateKeyData).publicKey.rawRepresentation) ?? Data()
    }

    public func sign(
        challenge: MaintenanceApprovalChallenge, decision: MaintenanceApprovalDecision,
        deviceKeyID: String, approvedAt: Date, expiresAt: Date
    ) throws -> MaintenanceSignedApproval {
        let material = [challenge.bindingDigest, decision.rawValue, deviceKeyID,
                        String(approvedAt.timeIntervalSince1970), String(expiresAt.timeIntervalSince1970)]
            .joined(separator: "\u{1F}")
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: privateKeyData)
        return try MaintenanceSignedApproval(
            challenge: challenge, decision: decision, deviceKeyID: deviceKeyID,
            approvedAt: approvedAt, expiresAt: expiresAt,
            signature: try key.signature(for: Data(material.utf8)))
    }
}

public struct MaintenanceApprovalPublicChallenge: Codable, Equatable, Sendable {
    public let challengeID: String
    public let approvalOrigin: String
    public let expiresAt: Date

    fileprivate init(challenge: MaintenanceApprovalChallenge) {
        challengeID = challenge.challengeID
        approvalOrigin = challenge.approvalOrigin
        expiresAt = challenge.expiresAt
    }

    public var qrPayload: String { "\(approvalOrigin)/approve/\(challengeID)" }
}

public enum MaintenanceApprovalBrokerState: String, Codable, Sendable {
    case awaitingApproval = "awaiting-approval", approved, denied, expired, replayed, rejected
}

public struct MaintenanceApprovalLease: Equatable, Sendable {
    public let challengeID: String
    public let operation: String
    public let target: String
    public let scope: String
    public let secretReference: String
    public let correlationID: String

    fileprivate init(challenge: MaintenanceApprovalChallenge) {
        challengeID = challenge.challengeID; operation = challenge.operation; target = challenge.target
        scope = challenge.scope; secretReference = challenge.secretReference; correlationID = challenge.correlationID
    }
}

public struct MaintenanceApprovalSessionReceipt: Codable, Equatable, Sendable {
    public let challengeID: String
    public let operation: String
    public let target: String
    public let scope: String
    public let correlationID: String
    public let state: MaintenanceApprovalBrokerState
    public let deviceKeyID: String?
    public let errorCode: String?
    public let leaseIssued: Bool
    public let terminal: Bool

    fileprivate init(challenge: MaintenanceApprovalChallenge, state: MaintenanceApprovalBrokerState,
                     deviceKeyID: String?, errorCode: String?, leaseIssued: Bool, terminal: Bool) {
        challengeID = challenge.challengeID; operation = challenge.operation; target = challenge.target
        scope = challenge.scope; correlationID = challenge.correlationID; self.state = state
        self.deviceKeyID = deviceKeyID; self.errorCode = errorCode; self.leaseIssued = leaseIssued; self.terminal = terminal
    }
}

public struct MaintenanceApprovalBrokerOutcome: Sendable {
    public let receipt: MaintenanceApprovalSessionReceipt
    public let lease: MaintenanceApprovalLease?
    fileprivate init(receipt: MaintenanceApprovalSessionReceipt, lease: MaintenanceApprovalLease?) {
        self.receipt = receipt; self.lease = lease
    }
}

public enum MaintenanceApprovalBrokerError: Error, Equatable, Sendable {
    case duplicateChallenge, unknownChallenge, expiredChallenge
}

public actor MaintenanceApprovalBroker {
    private struct Session: Sendable {
        let challenge: MaintenanceApprovalChallenge
        var state: MaintenanceApprovalBrokerState = .awaitingApproval
        var deviceKeyID: String?
        var errorCode: String?
        var terminal = false
    }

    private let authority: MaintenanceApprovalAuthority
    private var sessions: [String: Session] = [:]

    public init(registry: MaintenanceTrustedDeviceRegistry) {
        authority = MaintenanceApprovalAuthority(registry: registry)
    }

    public func issue(challenge: MaintenanceApprovalChallenge, now: Date = Date()) throws -> MaintenanceApprovalPublicChallenge {
        guard challenge.expiresAt > now else { throw MaintenanceApprovalBrokerError.expiredChallenge }
        guard sessions[challenge.challengeID] == nil else { throw MaintenanceApprovalBrokerError.duplicateChallenge }
        sessions[challenge.challengeID] = Session(challenge: challenge)
        return MaintenanceApprovalPublicChallenge(challenge: challenge)
    }

    public func publicChallenge(challengeID: String) throws -> MaintenanceApprovalPublicChallenge {
        guard let session = sessions[challengeID] else { throw MaintenanceApprovalBrokerError.unknownChallenge }
        return MaintenanceApprovalPublicChallenge(challenge: session.challenge)
    }

    public func approve(challengeID: String, approval: MaintenanceSignedApproval, now: Date = Date()) async throws -> MaintenanceApprovalBrokerOutcome {
        guard let session = sessions[challengeID] else { throw MaintenanceApprovalBrokerError.unknownChallenge }
        do {
            try await authority.verifyAndConsume(challenge: session.challenge, approval: approval, now: now)
            let lease = MaintenanceApprovalLease(challenge: session.challenge)
            let receipt = MaintenanceApprovalSessionReceipt(challenge: session.challenge, state: .approved,
                                                            deviceKeyID: approval.deviceKeyID, errorCode: nil,
                                                            leaseIssued: true, terminal: true)
            sessions[challengeID] = Session(challenge: session.challenge, state: .approved,
                                            deviceKeyID: approval.deviceKeyID, terminal: true)
            return MaintenanceApprovalBrokerOutcome(receipt: receipt, lease: lease)
        } catch let error as MaintenanceApprovalVerificationError {
            let classification = Self.classify(error)
            if error == .replayed, session.terminal {
                let receipt = MaintenanceApprovalSessionReceipt(challenge: session.challenge, state: .replayed,
                                                                deviceKeyID: approval.deviceKeyID, errorCode: classification.code,
                                                                leaseIssued: false, terminal: true)
                return MaintenanceApprovalBrokerOutcome(receipt: receipt, lease: nil)
            }
            sessions[challengeID] = Session(challenge: session.challenge, state: classification.state,
                                            deviceKeyID: approval.deviceKeyID, errorCode: classification.code,
                                            terminal: classification.terminal)
            let receipt = MaintenanceApprovalSessionReceipt(challenge: session.challenge, state: classification.state,
                                                            deviceKeyID: approval.deviceKeyID, errorCode: classification.code,
                                                            leaseIssued: false, terminal: classification.terminal)
            return MaintenanceApprovalBrokerOutcome(receipt: receipt, lease: nil)
        }
    }

    public func receipt(challengeID: String) throws -> MaintenanceApprovalSessionReceipt {
        guard let session = sessions[challengeID] else { throw MaintenanceApprovalBrokerError.unknownChallenge }
        return MaintenanceApprovalSessionReceipt(challenge: session.challenge, state: session.state,
                                                 deviceKeyID: session.deviceKeyID, errorCode: session.errorCode,
                                                 leaseIssued: session.state == .approved, terminal: session.terminal)
    }

    private static func classify(_ error: MaintenanceApprovalVerificationError) -> (state: MaintenanceApprovalBrokerState, code: String, terminal: Bool) {
        switch error {
        case .denied: return (.denied, "denied", true)
        case .expired: return (.expired, "expired", true)
        case .replayed: return (.replayed, "replayed", true)
        case .invalidChallenge: return (.rejected, "invalid-challenge", false)
        case .invalidApproval: return (.rejected, "invalid-approval", false)
        case .invalidDevice: return (.rejected, "invalid-device", false)
        case .unknownDevice: return (.rejected, "unknown-device", false)
        case .revokedDevice: return (.rejected, "revoked-device", false)
        case .bindingMismatch: return (.rejected, "binding-mismatch", false)
        case .invalidSignature: return (.rejected, "invalid-signature", false)
        }
    }
}

public struct MaintenanceApprovalSubmission: Codable, Equatable, Sendable {
    public let challengeID: String
    public let approval: MaintenanceSignedApproval

    public init(challengeID: String, approval: MaintenanceSignedApproval) throws {
        guard !challengeID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MaintenanceApprovalBrokerError.unknownChallenge
        }
        self.challengeID = challengeID; self.approval = approval
    }
}

public actor MaintenanceApprovalServerAdapter {
    private let broker: MaintenanceApprovalBroker

    public init(broker: MaintenanceApprovalBroker) { self.broker = broker }

    public func issue(challenge: MaintenanceApprovalChallenge, now: Date = Date()) async throws -> MaintenanceApprovalPublicChallenge {
        try await broker.issue(challenge: challenge, now: now)
    }

    public func submit(_ submission: MaintenanceApprovalSubmission, now: Date = Date()) async throws -> MaintenanceApprovalSessionReceipt {
        try await broker.approve(challengeID: submission.challengeID, approval: submission.approval, now: now).receipt
    }

    public func authorize(_ submission: MaintenanceApprovalSubmission, now: Date = Date()) async throws -> MaintenanceApprovalBrokerOutcome {
        try await broker.approve(challengeID: submission.challengeID, approval: submission.approval, now: now)
    }

    public func receipt(challengeID: String) async throws -> MaintenanceApprovalSessionReceipt {
        try await broker.receipt(challengeID: challengeID)
    }
}
