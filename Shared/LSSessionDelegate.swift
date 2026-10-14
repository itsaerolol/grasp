import Foundation
import Security

/// Handles both TLS challenges for LocalSend:
/// - Server trust: LocalSend PCs use self-signed certs. We pin by cert fingerprint
///   (expected != nil) or record it for trust-on-first-use during discovery (expected == nil).
/// - Client certificate: present our self-signed identity (server requires mTLS).
final class LSSessionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let identity: SecIdentity
    private let expectedFingerprint: String?
    private let lock = NSLock()
    private var observed: [String: String] = [:]   // host -> server cert fingerprint
    private var progressHandlers: [Int: (Double) -> Void] = [:]

    init(identity: SecIdentity, expectedFingerprint: String?) {
        self.identity = identity
        self.expectedFingerprint = expectedFingerprint?.uppercased()
    }

    func observedFingerprint(host: String) -> String? {
        lock.withLock { observed[host] }
    }

    func setProgressHandler(taskId: Int, _ handler: ((Double) -> Void)?) {
        lock.withLock { progressHandlers[taskId] = handler }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let space = challenge.protectionSpace
        switch space.authenticationMethod {
        case NSURLAuthenticationMethodServerTrust:
            guard let trust = space.serverTrust,
                  let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
                  let leaf = chain.first
            else { return completionHandler(.cancelAuthenticationChallenge, nil) }

            let fp = Fingerprint.of(der: SecCertificateCopyData(leaf) as Data)
            lock.withLock { observed[space.host] = fp }

            if let expected = expectedFingerprint, expected != fp {
                return completionHandler(.cancelAuthenticationChallenge, nil)
            }
            completionHandler(.useCredential, URLCredential(trust: trust))

        case NSURLAuthenticationMethodClientCertificate:
            completionHandler(.useCredential,
                              URLCredential(identity: identity, certificates: nil, persistence: .forSession))

        default:
            completionHandler(.performDefaultHandling, nil)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.withLock { progressHandlers[task.taskIdentifier] = nil }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        guard totalBytesExpectedToSend > 0 else { return }
        let handler = lock.withLock { progressHandlers[task.taskIdentifier] }
        handler?(Double(totalBytesSent) / Double(totalBytesExpectedToSend))
    }
}
