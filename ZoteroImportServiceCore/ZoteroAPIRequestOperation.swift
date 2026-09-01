import Foundation

struct ZoteroTimeoutPolicy: Equatable, Sendable {
    static let production = ZoteroTimeoutPolicy(firstByte: 10, idle: 15, total: 30)

    let firstByte: TimeInterval
    let idle: TimeInterval
    let total: TimeInterval
}

final class ZoteroAPIRequestOperation: NSObject, @unchecked Sendable {
    typealias EventHandler = @Sendable (ZoteroImportXPCEvent) -> Void
    typealias CompletionHandler = @Sendable (String) -> Void

    private static let maximumRedirectCount = 3

    private let request: ZoteroImportXPCRequest
    private let endpointPolicy: ZoteroEndpointPolicy
    private let timeoutPolicy: ZoteroTimeoutPolicy
    private let eventHandler: EventHandler
    private let completionHandler: CompletionHandler
    private let stateQueue: DispatchQueue
    private let delegateQueue: OperationQueue

    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var response: HTTPURLResponse?
    private var responseData = Data()
    private var firstByteTimer: DispatchWorkItem?
    private var idleTimer: DispatchWorkItem?
    private var totalTimer: DispatchWorkItem?
    private var redirectCount = 0
    private var isFinished = false
    private var wasCancelledByClient = false

    init(
        request: ZoteroImportXPCRequest,
        endpointPolicy: ZoteroEndpointPolicy = .production,
        timeoutPolicy: ZoteroTimeoutPolicy = .production,
        eventHandler: @escaping EventHandler,
        completionHandler: @escaping CompletionHandler
    ) {
        self.request = request
        self.endpointPolicy = endpointPolicy
        self.timeoutPolicy = timeoutPolicy
        self.eventHandler = eventHandler
        self.completionHandler = completionHandler
        stateQueue = DispatchQueue(
            label: "app.lurume.zotero-request.\(request.requestID)",
            qos: .userInitiated
        )
        delegateQueue = OperationQueue()
        super.init()
        delegateQueue.name = "app.lurume.zotero-urlsession.\(request.requestID)"
        delegateQueue.maxConcurrentOperationCount = 1
        delegateQueue.underlyingQueue = stateQueue
    }

    func start() {
        stateQueue.async { [self] in
            guard !isFinished else { return }
            do {
                let urlRequest = try endpointPolicy.makeURLRequest(from: request)
                let configuration = URLSessionConfiguration.ephemeral
                configuration.urlCache = nil
                configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
                configuration.httpShouldSetCookies = false
                configuration.httpCookieStorage = nil
                configuration.timeoutIntervalForRequest = timeoutPolicy.total
                configuration.timeoutIntervalForResource = timeoutPolicy.total
                let session = URLSession(
                    configuration: configuration,
                    delegate: self,
                    delegateQueue: delegateQueue
                )
                self.session = session
                let task = session.dataTask(with: urlRequest)
                self.task = task
                scheduleFirstByteTimeout()
                scheduleTotalTimeout()
                task.resume()
            } catch let error as ZoteroServiceError {
                finish(with: error)
            } catch {
                finish(with: .invalidRequest)
            }
        }
    }

    func cancel() {
        stateQueue.async { [self] in
            guard !isFinished else { return }
            wasCancelledByClient = true
            finish(with: .cancelled)
        }
    }

    private func scheduleFirstByteTimeout() {
        let timer = DispatchWorkItem { [weak self] in self?.finish(with: .firstByteTimeout) }
        firstByteTimer = timer
        stateQueue.asyncAfter(deadline: .now() + timeoutPolicy.firstByte, execute: timer)
    }

    private func scheduleIdleTimeout() {
        idleTimer?.cancel()
        let timer = DispatchWorkItem { [weak self] in self?.finish(with: .idleTimeout) }
        idleTimer = timer
        stateQueue.asyncAfter(deadline: .now() + timeoutPolicy.idle, execute: timer)
    }

    private func scheduleTotalTimeout() {
        let timer = DispatchWorkItem { [weak self] in self?.finish(with: .requestTimeout) }
        totalTimer = timer
        stateQueue.asyncAfter(deadline: .now() + timeoutPolicy.total, execute: timer)
    }

    private func finishSuccessfully(payload: ZoteroServicePayload) {
        guard !isFinished else { return }
        do {
            let encoded = try JSONEncoder().encode(payload)
            guard encoded.count <= ZoteroResponseParser.maximumResponseBytes else {
                finish(with: .responseTooLarge)
                return
            }
            isFinished = true
            cancelTimers()
            task?.cancel()
            session?.finishTasksAndInvalidate()
            responseData.removeAll(keepingCapacity: false)
            eventHandler(
                ZoteroImportXPCEvent(
                    requestID: request.requestID,
                    kind: "completed",
                    payload: encoded
                )
            )
            completionHandler(request.requestID)
        } catch {
            finish(with: .invalidResponse)
        }
    }

    private func finish(with error: ZoteroServiceError) {
        guard !isFinished else { return }
        isFinished = true
        cancelTimers()
        task?.cancel()
        session?.invalidateAndCancel()
        responseData.removeAll(keepingCapacity: false)
        eventHandler(
            ZoteroImportXPCEvent(
                requestID: request.requestID,
                kind: error == .cancelled ? "cancelled" : "failed",
                errorCode: error.code,
                message: error.safeMessage
            )
        )
        completionHandler(request.requestID)
    }

    private func cancelTimers() {
        firstByteTimer?.cancel()
        idleTimer?.cancel()
        totalTimer?.cancel()
        firstByteTimer = nil
        idleTimer = nil
        totalTimer = nil
    }
}

extension ZoteroAPIRequestOperation: URLSessionDataDelegate, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard !isFinished, let response = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            finish(with: .invalidResponse)
            return
        }
        guard (200..<300).contains(response.statusCode) else {
            completionHandler(.cancel)
            finish(with: response.statusCode == 412 ? .serverChanged : .http(status: response.statusCode))
            return
        }
        if let expectedServerID = request.serverID,
           response.value(forHTTPHeaderField: "Zotero-Server-ID") != expectedServerID {
            completionHandler(.cancel)
            finish(with: .serverChanged)
            return
        }
        self.response = response
        firstByteTimer?.cancel()
        firstByteTimer = nil
        scheduleIdleTimeout()
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard !isFinished else { return }
        guard responseData.count <= ZoteroResponseParser.maximumResponseBytes - data.count else {
            finish(with: .responseTooLarge)
            return
        }
        responseData.append(data)
        scheduleIdleTimeout()
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard !isFinished else { return }
        if wasCancelledByClient {
            finish(with: .cancelled)
            return
        }
        if let error {
            let code = (error as NSError).code
            finish(with: code == NSURLErrorTimedOut ? .requestTimeout : .connection)
            return
        }
        guard let response,
              (200..<300).contains(response.statusCode),
              let kind = ZoteroImportRequestKind(rawValue: request.kind)
        else {
            finish(with: .invalidResponse)
            return
        }
        do {
            let payload = try ZoteroResponseParser.parse(
                data: responseData,
                response: response,
                kind: kind,
                requestLimit: request.limit
            )
            finishSuccessfully(payload: payload)
        } catch let error as ZoteroServiceError {
            finish(with: error)
        } catch {
            finish(with: .invalidResponse)
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest redirectedRequest: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let redirectedURL = redirectedRequest.url,
              endpointPolicy.isSameOrigin(redirectedURL),
              redirectedRequest.httpMethod == "GET"
        else {
            completionHandler(nil)
            finish(with: .invalidResponse)
            return
        }
        redirectCount += 1
        guard redirectCount <= Self.maximumRedirectCount else {
            completionHandler(nil)
            finish(with: .invalidResponse)
            return
        }
        completionHandler(redirectedRequest)
    }
}
