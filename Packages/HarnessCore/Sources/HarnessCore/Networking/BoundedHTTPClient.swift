import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct HTTPResult: Sendable {
    public let status: Int
    public let data: Data
    public let retryAfter: String?
}
public enum HTTPFailure: Error, LocalizedError {
    case responseTooLarge, invalidResponse, transport(Int), busy
    public var errorDescription: String? {
        switch self {
        case .responseTooLarge: "The service response exceeded its configured limit."
        case .invalidResponse: "The service did not return an HTTP response."
        case let .transport(code): "The network request did not complete (transport code \(code))."
        case .busy: "The network worker is at its bounded request limit."
        }
    }
}

/// No cookies, disk cache, automatic redirects, or unbounded response accumulation.
/// The caller owns retry policy and cancellation; errors omit URLs and response bodies.
public final class BoundedHTTPClient: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private struct Pending {
        let id: UUID
        let limit: Int
        let completion: @Sendable (Result<HTTPResult, Error>) -> Void
        var data = Data()
        var response: HTTPURLResponse?
        var failure: HTTPFailure?
    }
    private let lock = NSLock()
    private var pending: [Int: Pending] = [:]
    private var tasks: [UUID: URLSessionDataTask] = [:]
    private var session: URLSession!
    private let maximumRequests: Int
    public init(maximumRequests: Int = 4, resourceTimeout: TimeInterval = 30) {
        self.maximumRequests = max(1, min(16, maximumRequests))
        super.init()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil; configuration.httpCookieStorage = nil; configuration.urlCredentialStorage = nil
        configuration.httpShouldSetCookies = false; configuration.httpMaximumConnectionsPerHost = self.maximumRequests
        configuration.timeoutIntervalForRequest = 15; configuration.timeoutIntervalForResource = max(1, min(120, resourceTimeout))
        let callbacks = OperationQueue(); callbacks.maxConcurrentOperationCount = 1
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: callbacks)
    }
    @discardableResult
    public func send(_ request: URLRequest, maximumResponseBytes: Int = 65536,
                     completion: @escaping @Sendable (Result<HTTPResult, Error>) -> Void) throws -> UUID {
        lock.lock(); defer { lock.unlock() }
        guard tasks.count < maximumRequests else { throw HTTPFailure.busy }
        let task = session.dataTask(with: request), id = UUID()
        pending[task.taskIdentifier] = Pending(id: id, limit: max(1, min(8 << 20, maximumResponseBytes)), completion: completion)
        tasks[id] = task; task.resume(); return id
    }
    public func cancel(_ id: UUID) { lock.lock(); let task = tasks[id]; lock.unlock(); task?.cancel() }
    public func cancelAll() { lock.lock(); let current = Array(tasks.values); lock.unlock(); current.forEach { $0.cancel() } }
    public func close() { session.invalidateAndCancel() }
    public func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                           newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                           completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        lock.lock()
        guard var entry = pending[dataTask.taskIdentifier], let response = response as? HTTPURLResponse else {
            lock.unlock(); completionHandler(.cancel); return
        }
        entry.response = response
        let exceedsLimit = response.expectedContentLength > Int64(entry.limit)
        if exceedsLimit { entry.failure = .responseTooLarge }
        pending[dataTask.taskIdentifier] = entry; lock.unlock()
        completionHandler(exceedsLimit ? .cancel : .allow)
    }
    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        guard var entry = pending[dataTask.taskIdentifier] else { lock.unlock(); return }
        let exceedsLimit = data.count > entry.limit - entry.data.count
        if exceedsLimit { entry.failure = .responseTooLarge }
        else { entry.data.append(data) }
        pending[dataTask.taskIdentifier] = entry; lock.unlock()
        if exceedsLimit { dataTask.cancel() }
    }
    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        guard let entry = pending.removeValue(forKey: task.taskIdentifier) else { lock.unlock(); return }
        tasks.removeValue(forKey: entry.id); lock.unlock()
        if let failure = entry.failure { entry.completion(.failure(failure)) }
        else if let error { entry.completion(.failure(HTTPFailure.transport((error as NSError).code))) }
        else if let response = entry.response {
            entry.completion(.success(HTTPResult(status: response.statusCode, data: entry.data, retryAfter: response.value(forHTTPHeaderField: "Retry-After"))))
        } else { entry.completion(.failure(HTTPFailure.invalidResponse)) }
    }
}
