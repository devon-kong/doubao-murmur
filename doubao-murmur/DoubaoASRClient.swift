import Foundation

/// Parameters needed to establish a WSS ASR connection.
/// Codable so they can be persisted to a local config file.
struct DoubaoASRParams: Codable {
    /// Cookie name→value pairs for authentication.
    let cookies: [String: String]
    let deviceId: String
    let webId: String

    /// Build the Cookie header string for HTTP/WSS requests.
    var cookieHeader: String {
        cookies.map { "\($0.key)=\($0.value)" }.joined(separator: "; ")
    }

    /// Convenience init from HTTPCookie array (extracted from WKWebView).
    init(httpCookies: [HTTPCookie], deviceId: String, webId: String) {
        var dict = [String: String]()
        for cookie in httpCookies {
            dict[cookie.name] = cookie.value
        }
        self.cookies = dict
        self.deviceId = deviceId
        self.webId = webId
    }

    init(cookies: [String: String], deviceId: String, webId: String) {
        self.cookies = cookies
        self.deviceId = deviceId
        self.webId = webId
    }
}

/// Native WebSocket client for Doubao's streaming ASR service.
/// Connects to `wss://ws-samantha.doubao.com/samantha/audio/asr` with cookie auth,
/// sends raw Int16 LE PCM audio data, and receives JSON transcription results.
class DoubaoASRClient {
    /// Audio format the service expects: 16kHz mono Int16.
    private static let sampleRate = 16000
    /// Granularity of the trailing silence padding sent by `finishSending`.
    private static let silenceChunkMs = 100

    private var webSocketTask: URLSessionWebSocketTask?
    private(set) var isConnected = false

    /// Audio data received before the WebSocket is connected is buffered here
    /// and flushed automatically once the connection opens.
    private var pendingAudioBuffer: [Data] = []
    private let bufferLock = NSLock()

    // Callbacks (may be called from URLSession's background thread)
    var onOpen: (() -> Void)?
    var onResult: ((_ text: String) -> Void)?
    var onFinish: (() -> Void)?
    var onError: ((_ error: Error?) -> Void)?
    /// Fired when the server indicates cookie/auth failure (distinct from generic errors).
    var onAuthError: (() -> Void)?

    func connect(params: DoubaoASRParams) {
        var components = URLComponents(string: "wss://ws-samantha.doubao.com/samantha/audio/asr")!
        components.queryItems = [
            URLQueryItem(name: "version_code", value: "20800"),
            URLQueryItem(name: "language", value: "zh"),
            URLQueryItem(name: "device_platform", value: "web"),
            URLQueryItem(name: "aid", value: "497858"),
            URLQueryItem(name: "real_aid", value: "497858"),
            URLQueryItem(name: "pkg_type", value: "release_version"),
            URLQueryItem(name: "device_id", value: params.deviceId),
            URLQueryItem(name: "pc_version", value: "3.12.3"),
            URLQueryItem(name: "web_id", value: params.webId),
            URLQueryItem(name: "tea_uuid", value: params.webId),
            URLQueryItem(name: "region", value: ""),
            URLQueryItem(name: "sys_region", value: ""),
            URLQueryItem(name: "samantha_web", value: "1"),
            URLQueryItem(name: "use-olympus-account", value: "1"),
            URLQueryItem(name: "web_tab_id", value: UUID().uuidString),
            URLQueryItem(name: "format", value: "pcm"),
        ]

        guard let url = components.url else {
            print("[DoubaoASRClient] ❌ Failed to build WSS URL")
            onError?(nil)
            return
        }

        var request = URLRequest(url: url)
        request.setValue(params.cookieHeader, forHTTPHeaderField: "Cookie")
        request.setValue("https://www.doubao.com", forHTTPHeaderField: "Origin")
        request.timeoutInterval = 5

        print("[DoubaoASRClient] Connecting...")

        let task = URLSession.shared.webSocketTask(with: request)
        self.webSocketTask = task
        task.resume()

        receiveMessage()

        // Verify connection is alive
        task.sendPing { [weak self] error in
            guard let self = self else { return }
            if let error = error {
                print("[DoubaoASRClient] ❌ Connection failed: \(error.localizedDescription)")
                self.onError?(error)
            } else {
                print("[DoubaoASRClient] ✅ Connected")
                self.isConnected = true
                self.flushAudioBuffer()
                self.onOpen?()
            }
        }
    }

    /// Send raw PCM audio data. Thread-safe.
    /// If the WebSocket is not yet connected, data is buffered and flushed on connect.
    func sendAudio(_ data: Data) {
        bufferLock.lock()
        if isConnected, let task = webSocketTask {
            bufferLock.unlock()
            task.send(.data(data)) { error in
                if let error = error {
                    print("[DoubaoASRClient] ⚠️ Send error: \(error.localizedDescription)")
                }
            }
        } else {
            pendingAudioBuffer.append(data)
            bufferLock.unlock()
        }
    }

    /// Signal that no more microphone audio will be sent, but keep the WebSocket
    /// open to receive the final transcription results from the server.
    ///
    /// A short tail of digital silence is flushed first. The service emits exactly
    /// one result per audio message it receives, and it withholds the last word
    /// until further audio arrives — so if the stream just stops, that word is
    /// never transcribed. Measured against a known utterance, dropping ~150ms of
    /// tail audio consistently costs the final two characters, and ~100ms of
    /// silence is enough to make the server finalise them; 200ms leaves margin.
    /// The padding is queued immediately rather than paced in real time, so it
    /// adds no wall-clock delay of its own.
    func finishSending(trailingSilenceMs: Int = 200) {
        bufferLock.lock()
        pendingAudioBuffer.removeAll()
        let task = webSocketTask
        let wasConnected = isConnected
        bufferLock.unlock()

        if wasConnected, let task = task, trailingSilenceMs > 0 {
            let bytesPerChunk = Self.sampleRate * 2 * Self.silenceChunkMs / 1000
            let silence = Data(count: bytesPerChunk)
            let chunkCount = max(1, trailingSilenceMs / Self.silenceChunkMs)
            for _ in 0..<chunkCount {
                task.send(.data(silence)) { error in
                    if let error = error {
                        print("[DoubaoASRClient] ⚠️ Silence padding error: \(error.localizedDescription)")
                    }
                }
            }
        }

        isConnected = false
        print("[DoubaoASRClient] Finished sending audio (+\(trailingSilenceMs)ms silence), waiting for final results")
    }

    func disconnect() {
        guard webSocketTask != nil else { return }
        isConnected = false
        bufferLock.lock()
        pendingAudioBuffer.removeAll()
        bufferLock.unlock()
        webSocketTask?.cancel(with: .normalClosure, reason: "1000-".data(using: .utf8))
        webSocketTask = nil
        print("[DoubaoASRClient] Disconnected")
    }

    /// Flush any audio data that was buffered while the WebSocket was connecting.
    private func flushAudioBuffer() {
        bufferLock.lock()
        let buffered = pendingAudioBuffer
        pendingAudioBuffer.removeAll()
        bufferLock.unlock()

        guard !buffered.isEmpty, let task = webSocketTask else { return }
        print("[DoubaoASRClient] Flushing \(buffered.count) buffered audio chunks")
        for data in buffered {
            task.send(.data(data)) { error in
                if let error = error {
                    print("[DoubaoASRClient] ⚠️ Buffer flush error: \(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: - Receive Loop

    private func receiveMessage() {
        webSocketTask?.receive { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let message):
                switch message {
                case .string(let text):
                    self.handleMessage(text)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) {
                        self.handleMessage(text)
                    }
                @unknown default:
                    break
                }
                self.receiveMessage()

            case .failure(let error):
                if self.isConnected {
                    print("[DoubaoASRClient] ❌ Receive error: \(error.localizedDescription)")
                    self.isConnected = false
                    self.onError?(error)
                }
            }
        }
    }

    private func handleMessage(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

        let code = json["code"] as? Int ?? 0
        let event = json["event"] as? String ?? ""
        let message = json["message"] as? String ?? ""

        // Detect auth/cookie errors (non-zero code with auth-related message)
        if code != 0 {
            let lowerMsg = message.lowercased()
            // 709599054 = "Invalid" per spec; also check for cookie/auth keywords
            if code == 709599054
                || lowerMsg.contains("cookie")
                || lowerMsg.contains("auth")
                || lowerMsg.contains("login")
                || lowerMsg.contains("session")
                || lowerMsg.contains("unauthorized")
                || lowerMsg.contains("expired") {
                print("[DoubaoASRClient] ⚠️ Auth error detected: code=\(code), message=\(message)")
                isConnected = false
                onAuthError?()
                return
            }
        }

        switch event {
        case "result":
            if let result = json["result"] as? [String: Any],
               let recognizedText = result["Text"] as? String,
               !recognizedText.isEmpty {
                onResult?(recognizedText)
            }
        case "finish":
            print("[DoubaoASRClient] Received finish event")
            onFinish?()
        default:
            break
        }
    }
}
