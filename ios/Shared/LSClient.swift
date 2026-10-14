import Foundation

/// Sender-side LocalSend v2 client for one host.
final class LSClient: @unchecked Sendable {
    let host: String
    let port: Int
    let me: ClientIdentity.Material
    let expectedFingerprint: String?
    private let delegate: LSSessionDelegate
    private let session: URLSession

    /// - expectedFingerprint: pinned server cert fingerprint, or nil for discovery (TOFU).
    init(host: String, port: Int = LS.port, expectedFingerprint: String?, me: ClientIdentity.Material,
         connectTimeout: TimeInterval = 4) {
        self.host = host
        self.port = port
        self.me = me
        self.expectedFingerprint = expectedFingerprint?.uppercased()
        self.delegate = LSSessionDelegate(identity: me.identity, expectedFingerprint: expectedFingerprint)
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = connectTimeout
        config.waitsForConnectivity = false
        config.httpMaximumConnectionsPerHost = 4
        self.session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }

    deinit { session.invalidateAndCancel() }

    var myInfo: LSDeviceInfo {
        LSDeviceInfo(alias: AppConfig.alias, version: LS.version, deviceModel: AppConfig.deviceModel,
                     deviceType: "mobile", fingerprint: me.fingerprint, port: LS.port,
                     protocol: "https", download: false)
    }

    /// Server cert fingerprint seen during the last TLS handshake with this host.
    var serverFingerprint: String? { delegate.observedFingerprint(host: host) }

    private func url(_ path: String, _ query: [String: String] = [:]) -> URL {
        var c = URLComponents()
        c.scheme = "https"; c.host = host; c.port = port; c.path = LS.api + path
        if !query.isEmpty { c.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) } }
        return c.url!
    }

    private func check(_ response: URLResponse, _ data: Data) throws -> Int {
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        if (200..<300).contains(status) { return status }
        throw LSError.from(status: status, body: String(data: data, encoding: .utf8) ?? "")
    }

    private func mapTransport(_ error: Error) -> Error {
        // When the server asked for a client cert (stock LocalSend, the mock), CFNetwork reports its
        // HTTP 403 (declined / unanswered prompt) as -1206 instead of delivering the response.
        // A real client-cert TLS failure surfaces as a secure-connection error, not this one.
        if let e = error as? URLError, e.code == .clientCertificateRequired { return LSError.rejected }
        if error is URLError, let expected = expectedFingerprint,
           let seen = serverFingerprint, seen != expected {
            return LSError.fingerprintMismatch(expected: expected, got: seen)
        }
        if error is URLError { return LSError.unreachable(host) }
        return error
    }

    // MARK: Endpoints

    /// Two-way discovery handshake. Used by subnet scan and pairing.
    func register() async throws -> LSDeviceInfo {
        var req = URLRequest(url: url("/register"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(myInfo)
        do {
            let (data, resp) = try await session.data(for: req)
            _ = try check(resp, data)
            return try JSONDecoder().decode(LSDeviceInfo.self, from: data)
        } catch { throw mapTransport(error) }
    }

    /// Cheap liveness + identity probe for the pinned PC.
    func info() async throws -> LSDeviceInfo {
        do {
            let (data, resp) = try await session.data(from: url("/info"))
            _ = try check(resp, data)
            return try JSONDecoder().decode(LSDeviceInfo.self, from: data)
        } catch { throw mapTransport(error) }
    }

    /// Blocks until the PC user accepts (manual accept) or rejects. Returns nil on 204
    /// (nothing to upload: text message accepted, or receiver already has the files).
    func prepareUpload(files: [LSFileDTO], pin: String? = nil,
                       acceptTimeout: TimeInterval = 600) async throws -> LSPrepareUploadResponse? {
        var req = URLRequest(url: url("/prepare-upload", pin.map { ["pin": $0] } ?? [:]))
        req.httpMethod = "POST"
        req.timeoutInterval = acceptTimeout
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(
            LSPrepareUploadRequest(info: myInfo, files: Dictionary(uniqueKeysWithValues: files.map { ($0.id, $0) })))
        do {
            let (data, resp) = try await session.data(for: req)
            let status = try check(resp, data)
            if status == 204 { return nil }
            return try JSONDecoder().decode(LSPrepareUploadResponse.self, from: data)
        } catch { throw mapTransport(error) }
    }

    /// Streams the file from disk (never loads it into memory: share extensions are capped near 120MB).
    func upload(sessionId: String, fileId: String, token: String, fileURL: URL,
                progress: @escaping (Double) -> Void) async throws {
        var req = URLRequest(url: url("/upload", ["sessionId": sessionId, "fileId": fileId, "token": token]))
        req.httpMethod = "POST"
        req.timeoutInterval = 120
        req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            // The progress handler is cleared by LSSessionDelegate when the task completes.
            let task = session.uploadTask(with: req, fromFile: fileURL) { [weak self] data, resp, error in
                if let error { return cont.resume(throwing: self?.mapTransport(error) ?? error) }
                do { _ = try self?.check(resp!, data ?? Data()); cont.resume() }
                catch { cont.resume(throwing: error) }
            }
            delegate.setProgressHandler(taskId: task.taskIdentifier, progress)
            task.resume()
        }
    }

    func cancel(sessionId: String) async {
        var req = URLRequest(url: url("/cancel", ["sessionId": sessionId]))
        req.httpMethod = "POST"
        _ = try? await session.data(for: req)
    }
}
