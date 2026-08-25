import AppKit
import CryptoKit
import Darwin
import Foundation

private let serviceProtocolVersion = 1
private let defaultPort: UInt16 = 17771
private let maxHeaderBytes = 16 * 1024
private let maxBodyBytes = 64 * 1024

private struct JSONResponse: Encodable {
    let ok: Bool
    let protocolVersion: Int
    let error: String?
    let sha256: String?
    let changeCount: Int?

    init(ok: Bool, error: String? = nil, sha256: String? = nil, changeCount: Int? = nil) {
        self.ok = ok
        self.protocolVersion = serviceProtocolVersion
        self.error = error
        self.sha256 = sha256
        self.changeCount = changeCount
    }
}

private struct ClipboardPayload: Codable {
    let text: String
}

private struct HTTPResponse {
    let status: Int
    let reason: String
    let body: Data

    static func json(status: Int, reason: String, payload: JSONResponse) -> HTTPResponse {
        let encoder = JSONEncoder()
        // The helper never emits clipboard text, even on failures.
        let body = (try? encoder.encode(payload)) ?? Data("{\"ok\":false}".utf8)
        return HTTPResponse(status: status, reason: reason, body: body)
    }

    func wireData() -> Data {
        let header = "HTTP/1.1 \(status) \(reason)\r\n" +
            "Content-Type: application/json; charset=utf-8\r\n" +
            "Content-Length: \(body.count)\r\n" +
            "Connection: close\r\n\r\n"
        return Data(header.utf8) + body
    }
}

private final class MirrorServer {
    private let socketFileDescriptor: Int32
    private let acceptSource: DispatchSourceRead
    private let queue = DispatchQueue(label: "com.doubao.murmur.mirror.listener")

    init(port: UInt16) throws {
        let fileDescriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard fileDescriptor >= 0 else { throw ServerError.socket(errno) }
        socketFileDescriptor = fileDescriptor

        var reuseAddress: Int32 = 1
        guard setsockopt(fileDescriptor, SOL_SOCKET, SO_REUSEADDR, &reuseAddress, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            close(fileDescriptor)
            throw ServerError.socket(errno)
        }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(port).bigEndian
        guard inet_pton(AF_INET, "127.0.0.1", &address.sin_addr) == 1 else {
            close(fileDescriptor)
            throw ServerError.invalidLoopbackAddress
        }
        let bindResult = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fileDescriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            close(fileDescriptor)
            throw ServerError.socket(errno)
        }
        guard listen(fileDescriptor, SOMAXCONN) == 0 else {
            close(fileDescriptor)
            throw ServerError.socket(errno)
        }
        let currentFlags = fcntl(fileDescriptor, F_GETFL)
        guard currentFlags >= 0, fcntl(fileDescriptor, F_SETFL, currentFlags | O_NONBLOCK) == 0 else {
            close(fileDescriptor)
            throw ServerError.socket(errno)
        }

        acceptSource = DispatchSource.makeReadSource(fileDescriptor: fileDescriptor, queue: queue)
        acceptSource.setEventHandler { [weak self] in self?.acceptPendingConnections() }
        acceptSource.setCancelHandler { close(fileDescriptor) }
    }

    func start() {
        acceptSource.resume()
    }

    private func acceptPendingConnections() {
        while true {
            var address = sockaddr()
            var length = socklen_t(MemoryLayout<sockaddr>.size)
            let acceptedFileDescriptor = withUnsafeMutablePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    accept(socketFileDescriptor, $0, &length)
                }
            }
            if acceptedFileDescriptor >= 0 {
                var noSigPipe: Int32 = 1
                _ = setsockopt(acceptedFileDescriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
                let connectionFlags = fcntl(acceptedFileDescriptor, F_GETFL)
                if connectionFlags >= 0 {
                    _ = fcntl(acceptedFileDescriptor, F_SETFL, connectionFlags & ~O_NONBLOCK)
                }
                MirrorConnection(socketFileDescriptor: acceptedFileDescriptor).start()
                continue
            }
            guard errno != EAGAIN && errno != EWOULDBLOCK else { return }
            fputs("murmur-mirror accept failed.\n", stderr)
            return
        }
    }
}

private enum ServerError: LocalizedError {
    case invalidLoopbackAddress
    case socket(Int32)

    var errorDescription: String? {
        switch self {
        case .invalidLoopbackAddress: return "Could not construct the loopback listener address."
        case let .socket(code): return "Loopback listener setup failed (errno \(code))."
        }
    }
}

private final class MirrorConnection {
    private let socketFileDescriptor: Int32
    private let queue = DispatchQueue(label: "com.doubao.murmur.mirror.connection")
    private var buffer = Data()

    init(socketFileDescriptor: Int32) {
        self.socketFileDescriptor = socketFileDescriptor
    }

    func start() {
        queue.async { [self] in
            readAndRespond()
        }
    }

    private func readAndRespond() {
        defer { close(socketFileDescriptor) }
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let bytesRead = chunk.withUnsafeMutableBytes {
                recv(socketFileDescriptor, $0.baseAddress, $0.count, 0)
            }
            if bytesRead > 0 {
                buffer.append(contentsOf: chunk.prefix(Int(bytesRead)))
                if buffer.count > maxHeaderBytes + maxBodyBytes {
                    send(error(status: 413, reason: "Payload Too Large", message: "Request exceeds the size limit."))
                    return
                }
                if case let .response(response) = parseIfComplete() {
                    send(response)
                    return
                }
                continue
            }
            if bytesRead == 0 {
                send(error(status: 400, reason: "Bad Request", message: "Incomplete HTTP request."))
            } else if errno == EINTR {
                continue
            } else if errno != EINTR {
                send(error(status: 400, reason: "Bad Request", message: "Could not read HTTP request."))
            }
            return
        }
    }

    private enum ParseResult {
        case incomplete
        case response(HTTPResponse)
    }

    private func parseIfComplete() -> ParseResult {
        let separator = Data("\r\n\r\n".utf8)
        guard let range = buffer.range(of: separator) else {
            if buffer.count > maxHeaderBytes {
                return .response(error(status: 431, reason: "Request Header Fields Too Large", message: "HTTP headers exceed the size limit."))
            }
            return .incomplete
        }

        let headerEnd = range.upperBound
        guard headerEnd <= maxHeaderBytes else {
            return .response(error(status: 431, reason: "Request Header Fields Too Large", message: "HTTP headers exceed the size limit."))
        }
        guard let headerText = String(data: buffer[..<range.lowerBound], encoding: .utf8) else {
            return .response(error(status: 400, reason: "Bad Request", message: "HTTP headers must be UTF-8."))
        }
        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            return .response(error(status: 400, reason: "Bad Request", message: "Missing request line."))
        }
        let requestParts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard requestParts.count == 3, requestParts[2].hasPrefix("HTTP/") else {
            return .response(error(status: 400, reason: "Bad Request", message: "Malformed request line."))
        }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else {
                return .response(error(status: 400, reason: "Bad Request", message: "Malformed HTTP header."))
            }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, headers[name] == nil else {
                return .response(error(status: 400, reason: "Bad Request", message: "Duplicate or invalid HTTP header."))
            }
            headers[name] = value
        }

        let method = String(requestParts[0])
        let path = String(requestParts[1])
        guard method == "GET" || method == "POST" else {
            return .response(error(status: 405, reason: "Method Not Allowed", message: "Only GET and POST are supported."))
        }
        guard headers["transfer-encoding"] == nil else {
            return .response(error(status: 400, reason: "Bad Request", message: "Chunked requests are not supported."))
        }

        if method == "GET" {
            guard path == "/health" else {
                return .response(error(status: 404, reason: "Not Found", message: "Unknown endpoint."))
            }
            return .response(.json(status: 200, reason: "OK", payload: JSONResponse(ok: true)))
        }

        guard path == "/clipboard" else {
            return .response(error(status: 404, reason: "Not Found", message: "Unknown endpoint."))
        }
        guard isJSONContentType(headers["content-type"]) else {
            return .response(error(status: 415, reason: "Unsupported Media Type", message: "Content-Type must be application/json."))
        }
        guard let contentLengthText = headers["content-length"],
              let contentLength = Int(contentLengthText), contentLength >= 0 else {
            return .response(error(status: 411, reason: "Length Required", message: "Content-Length is required."))
        }
        guard contentLength <= maxBodyBytes else {
            return .response(error(status: 413, reason: "Payload Too Large", message: "Request body exceeds the size limit."))
        }
        guard buffer.count >= headerEnd + contentLength else { return .incomplete }

        let body = buffer.subdata(in: headerEnd..<(headerEnd + contentLength))
        guard let payload = try? JSONDecoder().decode(ClipboardPayload.self, from: body) else {
            return .response(error(status: 400, reason: "Bad Request", message: "Body must be a JSON object with text."))
        }
        guard !payload.text.isEmpty else {
            return .response(error(status: 422, reason: "Unprocessable Content", message: "text must not be empty."))
        }
        return .response(writeClipboard(payload.text))
    }

    private func isJSONContentType(_ value: String?) -> Bool {
        guard let value else { return false }
        return value.split(separator: ";", maxSplits: 1).first?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "application/json"
    }

    private func writeClipboard(_ text: String) -> HTTPResponse {
        // Socket callbacks run on a private background queue. AppKit
        // pasteboard access is confined to the main thread, while dispatchMain
        // keeps that queue active for the helper's whole lifetime.
        if Thread.isMainThread {
            return writeClipboardOnMainThread(text)
        }
        return DispatchQueue.main.sync {
            writeClipboardOnMainThread(text)
        }
    }

    private func writeClipboardOnMainThread(_ text: String) -> HTTPResponse {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string), pasteboard.string(forType: .string) == text else {
            return error(status: 500, reason: "Internal Server Error", message: "Could not verify clipboard write.")
        }
        let sha256 = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
        return .json(status: 200, reason: "OK", payload: JSONResponse(ok: true, sha256: sha256, changeCount: pasteboard.changeCount))
    }

    private func error(status: Int, reason: String, message: String) -> HTTPResponse {
        .json(status: status, reason: reason, payload: JSONResponse(ok: false, error: message))
    }

    private func send(_ response: HTTPResponse) {
        let data = response.wireData()
        var offset = 0
        data.withUnsafeBytes { rawBuffer in
            while offset < data.count {
                let bytesSent = Darwin.send(socketFileDescriptor, rawBuffer.baseAddress!.advanced(by: offset), data.count - offset, 0)
                if bytesSent > 0 {
                    offset += Int(bytesSent)
                } else if bytesSent < 0 && errno == EINTR {
                    continue
                } else {
                    return
                }
            }
        }
    }
}

private struct PasteboardSnapshot {
    private struct Item {
        let representations: [(NSPasteboard.PasteboardType, Data)]
    }

    private let items: [Item]

    static func capture(from pasteboard: NSPasteboard = .general) throws -> PasteboardSnapshot {
        let items = try (pasteboard.pasteboardItems ?? []).map { pasteboardItem -> Item in
            let representations = try pasteboardItem.types.map { type -> (NSPasteboard.PasteboardType, Data) in
                guard let data = pasteboardItem.data(forType: type) else {
                    throw SmokeError.cannotSnapshotPasteboard
                }
                return (type, data)
            }
            return Item(representations: representations)
        }
        return PasteboardSnapshot(items: items)
    }

    func restoreAndVerify(on pasteboard: NSPasteboard = .general) throws {
        pasteboard.clearContents()
        if !items.isEmpty {
            let restoredItems = items.map { item -> NSPasteboardItem in
                let restored = NSPasteboardItem()
                for (type, data) in item.representations {
                    restored.setData(data, forType: type)
                }
                return restored
            }
            guard pasteboard.writeObjects(restoredItems) else {
                throw SmokeError.cannotRestorePasteboard
            }
        }

        let actualItems = pasteboard.pasteboardItems ?? []
        guard actualItems.count == items.count else { throw SmokeError.cannotRestorePasteboard }
        for (expected, actual) in zip(items, actualItems) {
            guard actual.types.count == expected.representations.count else { throw SmokeError.cannotRestorePasteboard }
            for (type, data) in expected.representations {
                guard actual.data(forType: type) == data else { throw SmokeError.cannotRestorePasteboard }
            }
        }
    }
}

private enum SmokeError: LocalizedError {
    case cannotSnapshotPasteboard
    case cannotRestorePasteboard
    case requestFailed
    case validationFailed(String)

    var errorDescription: String? {
        switch self {
        case .cannotSnapshotPasteboard: return "Could not safely snapshot the current clipboard."
        case .cannotRestorePasteboard: return "Could not restore the original clipboard exactly."
        case .requestFailed: return "HTTP smoke request failed."
        case let .validationFailed(stage): return "HTTP smoke response did not satisfy the \(stage) check."
        }
    }
}

private struct SmokeClient {
    private struct Health: Decodable { let ok: Bool; let protocolVersion: Int }
    private struct Acknowledgement: Decodable { let ok: Bool; let protocolVersion: Int; let sha256: String; let changeCount: Int }
    private struct ErrorResponse: Decodable { let error: String? }

    let port: UInt16

    func run() -> Int32 {
        do {
            let snapshot = try PasteboardSnapshot.capture()
            var primaryError: Error?
            do {
                try exerciseProtocol()
            } catch {
                primaryError = error
            }
            do {
                try snapshot.restoreAndVerify()
            } catch {
                fputs("murmur-mirror smoke could not restore the original clipboard.\n", stderr)
                return 1
            }
            if let primaryError {
                fputs("murmur-mirror smoke failed protocol validation: \(primaryError.localizedDescription)\n", stderr)
                return 1
            }
            print("murmur-mirror smoke passed")
            return 0
        } catch SmokeError.cannotSnapshotPasteboard {
            fputs("murmur-mirror smoke stopped before writing because the clipboard could not be safely snapshotted.\n", stderr)
            return 1
        } catch {
            fputs("murmur-mirror smoke failed before clipboard validation.\n", stderr)
            return 1
        }
    }

    private func exerciseProtocol() throws {
        let health = try request(method: "GET", path: "/health", body: nil, contentType: nil)
        guard health.status == 200 else {
            let message = (try? JSONDecoder().decode(ErrorResponse.self, from: health.body))?.error ?? "no JSON error"
            throw SmokeError.validationFailed("health status \(health.status): \(message)")
        }
        guard let decodedHealth = try? JSONDecoder().decode(Health.self, from: health.body) else {
            throw SmokeError.validationFailed("health JSON")
        }
        guard decodedHealth.ok, decodedHealth.protocolVersion == serviceProtocolVersion else {
            throw SmokeError.validationFailed("health protocol")
        }

        let malformed = try request(method: "POST", path: "/clipboard", body: Data("{\"text\":".utf8), contentType: "application/json")
        guard malformed.status == 400 else { throw SmokeError.validationFailed("malformed JSON") }

        let wrongContentType = try request(method: "POST", path: "/clipboard", body: Data("ignored".utf8), contentType: "text/plain")
        guard wrongContentType.status == 415 else { throw SmokeError.validationFailed("Content-Type rejection") }

        let emptyText = try request(method: "POST", path: "/clipboard", body: Data("{\"text\":\"\"}".utf8), contentType: "application/json")
        guard emptyText.status == 422 else { throw SmokeError.validationFailed("empty text rejection") }

        let text = "murmur-mirror-smoke-\(UUID().uuidString)"
        let body = try JSONEncoder().encode(ClipboardPayload(text: text))
        let success = try request(method: "POST", path: "/clipboard", body: body, contentType: "application/json")
        guard success.status == 200,
              let acknowledgement = try? JSONDecoder().decode(Acknowledgement.self, from: success.body),
              acknowledgement.ok,
              acknowledgement.protocolVersion == serviceProtocolVersion,
              acknowledgement.sha256 == sha256(of: text),
              acknowledgement.changeCount >= 0,
              NSPasteboard.general.string(forType: .string) == text else {
            throw SmokeError.validationFailed("successful clipboard acknowledgement")
        }
    }

    private func request(method: String, path: String, body: Data?, contentType: String?) throws -> (status: Int, body: Data) {
        guard let url = URL(string: "http://127.0.0.1:\(port)\(path)") else { throw SmokeError.requestFailed }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 3
        request.httpBody = body
        if let contentType { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }

        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<(Data, URLResponse), Error>?
        URLSession.shared.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            if let error {
                result = .failure(error)
            } else if let data, let response {
                result = .success((data, response))
            } else {
                result = .failure(SmokeError.requestFailed)
            }
        }.resume()
        guard semaphore.wait(timeout: .now() + 5) == .success,
              let result,
              case let .success((data, response)) = result,
              let http = response as? HTTPURLResponse else {
            throw SmokeError.requestFailed
        }
        return (http.statusCode, data)
    }

    private func sha256(of text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

private func parsePort(arguments: [String]) -> UInt16? {
    guard let valueIndex = arguments.firstIndex(of: "--port"), arguments.indices.contains(valueIndex + 1) else { return nil }
    return UInt16(arguments[valueIndex + 1])
}

let arguments = Array(CommandLine.arguments.dropFirst())
let port = parsePort(arguments: arguments) ?? defaultPort

if arguments.contains("--smoke-client") {
    exit(SmokeClient(port: port).run())
}

do {
    let server = try MirrorServer(port: port)
    server.start()
    dispatchMain()
} catch {
    fputs("murmur-mirror could not start: \(error.localizedDescription)\n", stderr)
    exit(1)
}
