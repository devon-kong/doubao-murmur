import CryptoKit
import Foundation

/// Typed client for the loopback-only `murmur-mirror` helper.
struct RemoteClipboardClient {
    static let protocolVersion = 2

    private let baseURL: URL
    private let session: URLSession

    private static let defaultSession: URLSession = {
        let configuration = URLSessionConfiguration.default
        // Human-paced dictation can still have several outstanding ACKs. Keep
        // transport concurrency above that range so one slow response does not
        // merely move the global gate into URLSession's connection pool.
        configuration.httpMaximumConnectionsPerHost = 32
        return URLSession(configuration: configuration)
    }()

    init(baseURL: URL = URL(string: "http://127.0.0.1:17771")!, session: URLSession? = nil) {
        self.baseURL = baseURL
        self.session = session ?? Self.defaultSession
    }

    func health() async throws {
        let (data, response) = try await send(method: "GET", path: "/health", body: nil)
        guard response.statusCode == 200 else {
            throw RemoteClipboardClientError.unexpectedStatus(response.statusCode)
        }

        let health = try JSONDecoder().decode(HealthResponse.self, from: data)
        guard health.ok else { throw RemoteClipboardClientError.rejected }
        guard health.protocolVersion == Self.protocolVersion else {
            throw RemoteClipboardClientError.unsupportedProtocol(health.protocolVersion)
        }
    }

    @discardableResult
    func write(text: String) async throws -> ClipboardAcknowledgement {
        guard !text.isEmpty else { throw RemoteClipboardClientError.emptyText }

        let body = try JSONEncoder().encode(ClipboardRequest(text: text))
        let (data, response) = try await send(method: "POST", path: "/clipboard", body: body)
        guard response.statusCode == 200 else {
            throw RemoteClipboardClientError.unexpectedStatus(response.statusCode)
        }

        let acknowledgement = try JSONDecoder().decode(ClipboardAcknowledgement.self, from: data)
        guard acknowledgement.ok else { throw RemoteClipboardClientError.rejected }
        guard acknowledgement.protocolVersion == Self.protocolVersion else {
            throw RemoteClipboardClientError.unsupportedProtocol(acknowledgement.protocolVersion)
        }
        guard acknowledgement.sha256 == Self.sha256(of: text) else {
            throw RemoteClipboardClientError.hashMismatch
        }
        return acknowledgement
    }

    @discardableResult
    func paste(
        text: String,
        identity: PasteOrderIdentity,
        onTransportEvent: (RemoteClipboardTransportEvent) -> Void = { _ in }
    ) async throws -> RemotePasteAcknowledgement {
        guard !text.isEmpty else { throw RemoteClipboardClientError.emptyText }

        let body = try JSONEncoder().encode(
            RemotePasteRequest(
                requestId: identity.requestId,
                controllerSessionId: identity.controllerSessionId,
                sequence: identity.sequence,
                text: text
            )
        )
        let startedAt = DispatchTime.now().uptimeNanoseconds
        let (data, response) = try await send(method: "POST", path: "/paste", body: body)
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - startedAt) / 1_000_000
        onTransportEvent(.responseReceived(httpStatus: response.statusCode, durationMilliseconds: elapsed))
        guard response.statusCode == 200 else {
            throw RemoteClipboardClientError.unexpectedStatus(response.statusCode)
        }

        let acknowledgement = try JSONDecoder().decode(RemotePasteAcknowledgement.self, from: data)
        guard acknowledgement.ok, acknowledgement.eventPosted else {
            throw RemoteClipboardClientError.rejected
        }
        guard acknowledgement.protocolVersion == Self.protocolVersion else {
            throw RemoteClipboardClientError.unsupportedProtocol(acknowledgement.protocolVersion)
        }
        guard acknowledgement.requestId == identity.requestId else {
            throw RemoteClipboardClientError.requestMismatch
        }
        guard acknowledgement.controllerSessionId == identity.controllerSessionId else {
            throw RemoteClipboardClientError.controllerSessionMismatch
        }
        guard acknowledgement.sequence == identity.sequence else {
            throw RemoteClipboardClientError.sequenceMismatch
        }
        guard acknowledgement.sha256 == Self.sha256(of: text) else {
            throw RemoteClipboardClientError.hashMismatch
        }
        return acknowledgement
    }

    private func send(method: String, path: String, body: Data?) async throws -> (Data, HTTPURLResponse) {
        guard let url = URL(string: path, relativeTo: baseURL) else {
            throw RemoteClipboardClientError.invalidEndpoint
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 3
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw RemoteClipboardClientError.invalidResponse
        }
        return (data, httpResponse)
    }

    private static func sha256(of text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

struct ClipboardAcknowledgement: Decodable {
    let ok: Bool
    let protocolVersion: Int
    let sha256: String
    let changeCount: Int
}

struct RemotePasteAcknowledgement: Decodable {
    let ok: Bool
    let protocolVersion: Int
    let sha256: String
    let changeCount: Int
    let requestId: UUID
    let controllerSessionId: UUID
    let sequence: Int64
    let eventPosted: Bool
    let targetProcessIdentifier: Int32
    let targetBundleIdentifier: String?
}

private struct HealthResponse: Decodable {
    let ok: Bool
    let protocolVersion: Int
}

private struct ClipboardRequest: Encodable {
    let text: String
}

private struct RemotePasteRequest: Encodable {
    let requestId: UUID
    let controllerSessionId: UUID
    let sequence: Int64
    let text: String
}

enum RemoteClipboardClientError: LocalizedError {
    case invalidEndpoint
    case invalidResponse
    case unexpectedStatus(Int)
    case unsupportedProtocol(Int)
    case hashMismatch
    case requestMismatch
    case controllerSessionMismatch
    case sequenceMismatch
    case rejected
    case emptyText

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint: return "Invalid remote clipboard endpoint."
        case .invalidResponse: return "Remote clipboard returned an invalid response."
        case let .unexpectedStatus(status): return "Remote clipboard returned HTTP \(status)."
        case let .unsupportedProtocol(version): return "Remote clipboard protocol \(version) is unsupported."
        case .hashMismatch: return "Remote clipboard acknowledgement did not match the submitted text."
        case .requestMismatch: return "Remote paste acknowledgement did not match the submitted request."
        case .controllerSessionMismatch: return "Remote paste acknowledgement did not match the controller session."
        case .sequenceMismatch: return "Remote paste acknowledgement did not match the order sequence."
        case .rejected: return "Remote clipboard rejected the request."
        case .emptyText: return "Remote clipboard text must not be empty."
        }
    }
}
