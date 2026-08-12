import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import FountainMaintenanceCore

public enum MaintenanceClientError: Error, Equatable, Sendable {
    case invalidEndpoint
    case transport(String)
    case server(status: Int, message: String)
    case malformedResponse
}

/// Transport boundary for the maintenance API. Authentication is deliberately owned by the transport/host adapter;
/// callers provide only the opaque SecretStore reference associated with the operation.
public protocol MaintenanceTransport: Sendable {
    func send(_ request: URLRequest, secretReference: MaintenanceSecretReference?) async throws -> (Data, HTTPURLResponse)
}

/// Supplies a credential only for the duration of one transport operation.
///
/// Implementations are host adapters (for example Reframe's SecretStore adapter). The reference is safe to
/// persist; the secret value is not. A provider must never return the value in a request model, receipt, log, or
/// error. The closure is the only place the transport may use it.
public protocol MaintenanceSecretProvider: Sendable {
    func withSecret<T: Sendable>(
        reference: MaintenanceSecretReference,
        operation: @escaping @Sendable (Data) async throws -> T
    ) async throws -> T
}

public struct URLSessionMaintenanceTransport: MaintenanceTransport {
    private let session: URLSession
    private let secretProvider: (any MaintenanceSecretProvider)?

    public init(session: URLSession = .shared, secretProvider: (any MaintenanceSecretProvider)? = nil) {
        self.session = session
        self.secretProvider = secretProvider
    }

    public func send(_ request: URLRequest, secretReference: MaintenanceSecretReference?) async throws -> (Data, HTTPURLResponse) {
        if let secretReference, let secretProvider {
            return try await secretProvider.withSecret(reference: secretReference) { secret in
                var authenticatedRequest = request
                guard let token = String(data: secret, encoding: .utf8), !token.isEmpty else {
                    throw MaintenanceClientError.transport("maintenance credential is not UTF-8")
                }
                authenticatedRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                return try await Self.perform(authenticatedRequest, session: session)
            }
        }
        return try await Self.perform(request, session: session)
    }

    private static func perform(_ request: URLRequest, session: URLSession) async throws -> (Data, HTTPURLResponse) {
        do {
            let result = try await session.data(for: request)
            guard let response = result.1 as? HTTPURLResponse else { throw MaintenanceClientError.malformedResponse }
            return (result.0, response)
        } catch let error as MaintenanceClientError { throw error }
        catch { throw MaintenanceClientError.transport(error.localizedDescription) }
    }
}

/// Typed client for the service-owned maintenance origin. It does not perform repository discovery, SSH, shell
/// mutation, or credential lookup. A host adapter may use the SecretStore reference while sending the request.
public struct FountainMaintenanceClient: Sendable {
    public let endpoint: URL
    private let transport: any MaintenanceTransport

    public init(endpoint: URL, transport: any MaintenanceTransport = URLSessionMaintenanceTransport()) throws {
        guard endpoint.scheme == "https" || endpoint.host == "localhost" || endpoint.host == "127.0.0.1" else {
            throw MaintenanceClientError.invalidEndpoint
        }
        self.endpoint = endpoint; self.transport = transport
    }

    public func submit(_ operation: MaintenanceOperationRequest) async throws -> MaintenanceOperationReceipt {
        try MaintenanceValidator.validate(operation)
        var request = try makeRequest(path: "/v1/maintenance/operations", method: "POST", body: operation)
        request.setValue(operation.idempotencyKey, forHTTPHeaderField: "Idempotency-Key")
        return try await send(request, secretReference: operation.secretReference, as: MaintenanceOperationReceipt.self)
    }

    public func receipt(id: String, secretReference: MaintenanceSecretReference? = nil) async throws -> MaintenanceOperationReceipt {
        let request = try makeRequest(path: "/v1/maintenance/operations/\(try escaped(id))", method: "GET", body: Optional<EmptyBody>.none)
        return try await send(request, secretReference: secretReference, as: MaintenanceOperationReceipt.self)
    }

    private func makeRequest<T: Encodable>(path: String, method: String, body: T? = nil) throws -> URLRequest {
        guard let url = URL(string: path, relativeTo: endpoint)?.absoluteURL else { throw MaintenanceClientError.invalidEndpoint }
        var request = URLRequest(url: url); request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
        }
        return request
    }

    private struct EmptyBody: Encodable {}

    private func send<T: Decodable>(_ request: URLRequest, secretReference: MaintenanceSecretReference?, as type: T.Type) async throws -> T {
        let (data, response) = try await transport.send(request, secretReference: secretReference)
        guard (200..<300).contains(response.statusCode) else {
            throw MaintenanceClientError.server(status: response.statusCode, message: String(decoding: data, as: UTF8.self))
        }
        do { return try JSONDecoder().decode(type, from: data) }
        catch { throw MaintenanceClientError.malformedResponse }
    }

    private func escaped(_ value: String) throws -> String {
        guard let encoded = value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
            throw MaintenanceClientError.invalidEndpoint
        }
        return encoded
    }
}
