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

    private func url(_ path: String, _ query: [String: String] = [:], base: String = LS.api) -> URL {
        var c = URLComponents()
        c.scheme = "https"; c.host = host; c.port = port; c.path = base + path
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
        if error is LSError { return error }
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

    /// Grasp for Windows code pairing. Our client cert is what the PC remembers.
    func pair(code: String) async throws -> LSDeviceInfo {
        struct Body: Encodable { let code: String; let info: LSDeviceInfo }
        var req = URLRequest(url: url("/pair", base: LS.graspApi))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(Body(code: code, info: myInfo))
        do {
            let (data, resp) = try await session.data(for: req)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
            guard status == 200 else { throw LSError.fromPairing(status: status, body: data) }
            return try JSONDecoder().decode(LSDeviceInfo.self, from: data)
        } catch { throw mapTransport(error) }
    }

    /// Grasp for Windows (grasp >= 3): does the PC still list this phone as paired? nil when the PC can't say.
    func pairStatus() async throws -> Bool? {
        do {
            let (data, resp) = try await session.data(from: url("/pair", base: LS.graspApi))
            let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
            if status == 404 || status == 405 { return nil }
            _ = try check(resp, data)
            return ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["paired"] as? Bool
        } catch { throw mapTransport(error) }
    }

    /// Unpair in the app: tells the PC to forget this phone too. Short timeout; a PC that isn't Grasp for
    /// Windows (404) has nothing to forget.
    func unpairRemote() async throws {
        var req = URLRequest(url: url("/unpair", base: LS.graspApi))
        req.httpMethod = "POST"
        req.timeoutInterval = 3
        do {
            let (data, resp) = try await session.data(for: req)
            if (resp as? HTTPURLResponse)?.statusCode == 404 { return }
            _ = try check(resp, data)
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

    // MARK: Windows -> iPhone (Grasp for Windows' outbox: the phone pulls)

    /// What the PC has queued for this phone. 403 = this phone isn't paired by code; 404 = the PC isn't
    /// Grasp for Windows (stock LocalSend has no outbox).
    func outbox() async throws -> [LSOutboxItem] {
        do {
            let (data, resp) = try await session.data(from: url("/outbox", base: LS.graspApi))
            if (resp as? HTTPURLResponse)?.statusCode == 403 { throw LSError.notPairedByCode }
            _ = try check(resp, data)
            return try JSONDecoder().decode(LSOutboxList.self, from: data).items
        } catch { throw mapTransport(error) }
    }

    /// Streams one queued file to disk (URLSession's temp file, never memory) and moves it to `dest`.
    func downloadOutboxFile(id: String, to dest: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        var req = URLRequest(url: url("/outbox/file", ["id": id], base: LS.graspApi))
        req.timeoutInterval = 120
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            var watch: NSKeyValueObservation?
            let task = session.downloadTask(with: req) { [weak self] tmp, resp, error in
                watch?.invalidate()
                if let error { return cont.resume(throwing: self?.mapTransport(error) ?? error) }
                do {
                    guard let self, let tmp, let resp else { throw CocoaError(.fileReadUnknown) }
                    // A refusal's body is a small JSON message, so reading it is fine.
                    _ = try self.check(resp, (resp as? HTTPURLResponse)?.statusCode == 200 ? Data() : (try? Data(contentsOf: tmp)) ?? Data())
                    // The temp file is deleted when this handler returns: move it now.
                    try FileManager.default.moveItem(at: tmp, to: dest)
                    cont.resume()
                } catch { cont.resume(throwing: error) }
            }
            // Completion-handler tasks skip the delegate's data callbacks, but their Progress still updates.
            watch = task.progress.observe(\.fractionCompleted) { p, _ in progress(p.fractionCompleted) }
            task.resume()
        }
    }

    /// The phone saved the item: the PC takes it off the queue.
    func outboxDone(id: String) async throws {
        var req = URLRequest(url: url("/outbox/done", ["id": id], base: LS.graspApi))
        req.httpMethod = "POST"
        do {
            let (data, resp) = try await session.data(for: req)
            _ = try check(resp, data)
        } catch { throw mapTransport(error) }
    }

    /// Tells the PC to end the session; it deletes every file the session saved. Short timeout: the share
    /// sheet waits for this before closing.
    func cancel(sessionId: String) async {
        var req = URLRequest(url: url("/cancel", ["sessionId": sessionId]))
        req.httpMethod = "POST"
        req.timeoutInterval = 3
        _ = try? await session.data(for: req)
    }

    /// Stops every request in flight on this client (an upload's continuation then fails with cancelled).
    func cancelTransfers() async {
        for task in await session.allTasks { task.cancel() }
    }
}
