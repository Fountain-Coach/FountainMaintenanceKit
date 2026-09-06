import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import FountainMaintenanceCore

public enum MaintenanceApprovalClientTransportError: Error, Equatable, Sendable {
    case invalidEndpoint, invalidChallengeID, invalidSubmission, requestFailed
    case invalidResponse, httpStatus(Int), malformedReceipt, receiptMismatch
}

public protocol MaintenanceApprovalClientTransport: Sendable {
    func submit(_ submission: MaintenanceApprovalSubmission, endpoint: URL) async throws -> MaintenanceApprovalSessionReceipt
}

public struct URLSessionMaintenanceApprovalClientTransport: MaintenanceApprovalClientTransport, Sendable {
    public static let requestTimeout: TimeInterval = 30
    private let session: URLSession
    private let timeout: TimeInterval

    public init(session: URLSession = .shared, timeout: TimeInterval = requestTimeout) throws {
        guard timeout > 0 else { throw MaintenanceApprovalClientTransportError.invalidEndpoint }
        self.session = session; self.timeout = timeout
    }

    public func submit(_ submission: MaintenanceApprovalSubmission, endpoint: URL) async throws -> MaintenanceApprovalSessionReceipt {
        try Self.validateEndpoint(endpoint)
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"; request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONEncoder().encode(submission)
        let body: Data; let response: URLResponse
        do { (body, response) = try await session.data(for: request) }
        catch { throw MaintenanceApprovalClientTransportError.requestFailed }
        guard let httpResponse = response as? HTTPURLResponse else { throw MaintenanceApprovalClientTransportError.invalidResponse }
        guard (200..<300).contains(httpResponse.statusCode) else { throw MaintenanceApprovalClientTransportError.httpStatus(httpResponse.statusCode) }
        guard let receipt = try? JSONDecoder().decode(MaintenanceApprovalSessionReceipt.self, from: body) else {
            throw MaintenanceApprovalClientTransportError.malformedReceipt
        }
        guard receipt.challengeID == submission.challengeID else { throw MaintenanceApprovalClientTransportError.receiptMismatch }
        return receipt
    }

    fileprivate static func validateEndpoint(_ endpoint: URL) throws {
        guard let scheme = endpoint.scheme?.lowercased(), let host = endpoint.host, !host.isEmpty,
              scheme == "https" || ((host == "localhost" || host == "127.0.0.1") && scheme == "http") else {
            throw MaintenanceApprovalClientTransportError.invalidEndpoint
        }
    }
}

public struct MaintenanceApprovalClient: Sendable {
    private let transport: any MaintenanceApprovalClientTransport

    public init(transport: any MaintenanceApprovalClientTransport) { self.transport = transport }
    public init() throws { transport = try URLSessionMaintenanceApprovalClientTransport() }

    public func submit(publicChallenge: MaintenanceApprovalPublicChallenge, approval: MaintenanceSignedApproval) async throws -> MaintenanceApprovalSessionReceipt {
        let endpoint = try Self.endpoint(for: publicChallenge)
        let submission: MaintenanceApprovalSubmission
        do { submission = try MaintenanceApprovalSubmission(challengeID: publicChallenge.challengeID, approval: approval) }
        catch { throw MaintenanceApprovalClientTransportError.invalidSubmission }
        let receipt = try await transport.submit(submission, endpoint: endpoint)
        guard receipt.challengeID == publicChallenge.challengeID else { throw MaintenanceApprovalClientTransportError.receiptMismatch }
        return receipt
    }

    public static func endpoint(for publicChallenge: MaintenanceApprovalPublicChallenge) throws -> URL {
        guard isSafeChallengeID(publicChallenge.challengeID), let origin = URL(string: publicChallenge.approvalOrigin) else {
            throw MaintenanceApprovalClientTransportError.invalidChallengeID
        }
        try URLSessionMaintenanceApprovalClientTransport.validateEndpoint(origin)
        return origin.appendingPathComponent("approve", isDirectory: true).appendingPathComponent(publicChallenge.challengeID)
    }

    private static func isSafeChallengeID(_ value: String) -> Bool {
        guard !value.isEmpty else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        return value.unicodeScalars.allSatisfy(allowed.contains)
    }
}
