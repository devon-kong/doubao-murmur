import Foundation

struct UpdateChecker {
    struct UpdateInfo {
        let version: String
        let tag: String
        let downloadURL: URL
        /// Direct URL to the ZIP asset
        var assetURL: URL {
            UpdateChecker.assetURL(forTag: tag)
        }
    }

    enum CheckError: LocalizedError {
        case noRelease
        case networkError

        var errorDescription: String? {
            switch self {
            case .noRelease:
                return "未找到已发布的版本。"
            case .networkError:
                return "无法连接到 GitHub，请检查网络连接。"
            }
        }
    }

    static let repository = "devon-kong/doubao-murmur"
    private static let latestURL = "https://github.com/\(repository)/releases/latest"

    static func assetURL(forTag tag: String) -> URL {
        URL(string: "https://github.com/\(repository)/releases/download/\(tag)/Doubao-Murmur-\(tag).zip")!
    }

    static func check() async throws -> UpdateInfo? {
        guard let url = URL(string: latestURL) else { return nil }

        // Use a session that doesn't follow redirects, so we can read the Location header
        let delegate = NoRedirectDelegate()
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        var request = URLRequest(url: url)
        request.timeoutInterval = 10

        let (_, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (300...399).contains(httpResponse.statusCode),
              let location = httpResponse.value(forHTTPHeaderField: "Location"),
              let redirectURL = URL(string: location) else {
            throw CheckError.noRelease
        }

        // Location is like: https://github.com/devon-kong/doubao-murmur/releases/tag/v1.3.0
        let tag = redirectURL.lastPathComponent
        let remoteVersion = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"

        if isNewer(remote: remoteVersion, current: currentVersion) {
            return UpdateInfo(version: remoteVersion, tag: tag, downloadURL: redirectURL)
        }
        return nil
    }

    static func isNewer(remote: String, current: String) -> Bool {
        let r = remote.split(separator: ".").compactMap { Int($0) }
        let c = current.split(separator: ".").compactMap { Int($0) }
        for i in 0..<max(r.count, c.count) {
            let rv = i < r.count ? r[i] : 0
            let cv = i < c.count ? c[i] : 0
            if rv > cv { return true }
            if rv < cv { return false }
        }
        return false
    }
}

private class NoRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        // Return nil to stop following the redirect
        completionHandler(nil)
    }
}
