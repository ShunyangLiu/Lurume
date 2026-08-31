import Foundation

struct TranslationTimeoutPolicy: Equatable {
    static let production = TranslationTimeoutPolicy(
        firstByte: 30,
        streamIdle: 90,
        nonStreamingTotal: 120
    )

    let firstByte: TimeInterval
    let streamIdle: TimeInterval
    let nonStreamingTotal: TimeInterval
}

final class TranslationRequestOperation: NSObject, @unchecked Sendable {
    private static let maximumRedirectCount = 5

    typealias EventHandler = @Sendable (TranslationXPCEvent) -> Void
    typealias CompletionHandler = @Sendable (String) -> Void

    private let request: TranslationXPCRequest
    private let timeoutPolicy: TranslationTimeoutPolicy
    private let eventHandler: EventHandler
    private let completionHandler: CompletionHandler
    private let stateQueue: DispatchQueue
    private let delegateQueue: OperationQueue

    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var responseData = Data()
    private var parser = OpenAIChatCompletionSSEParser()
    private var firstByteTimer: DispatchWorkItem?
    private var streamIdleTimer: DispatchWorkItem?
    private var totalTimer: DispatchWorkItem?
    private var isFinished = false
    private var wasCancelledByClient = false
    private var redirectCount = 0

    init(
        request: TranslationXPCRequest,
        timeoutPolicy: TranslationTimeoutPolicy = .production,
        eventHandler: @escaping EventHandler,
        completionHandler: @escaping CompletionHandler
    ) {
        self.request = request
        self.timeoutPolicy = timeoutPolicy
        self.eventHandler = eventHandler
        self.completionHandler = completionHandler
        self.stateQueue = DispatchQueue(
            label: "app.lurume.translation-request.\(request.requestID)",
            qos: .userInitiated
        )
        self.delegateQueue = OperationQueue()
        super.init()
        delegateQueue.name = "app.lurume.translation-urlsession.\(request.requestID)"
        delegateQueue.maxConcurrentOperationCount = 1
        delegateQueue.underlyingQueue = stateQueue
    }

    func start() {
        stateQueue.async { [self] in
            guard !isFinished else { return }
            do {
                let urlRequest = try OpenAIChatCompletionRequestBuilder.makeURLRequest(from: request)
                let configuration = URLSessionConfiguration.ephemeral
                configuration.urlCache = nil
                configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
                configuration.httpShouldSetCookies = false
                configuration.httpCookieStorage = nil
                let sessionTimeout = request.streamsResponse
                    ? 24 * 60 * 60
                    : timeoutPolicy.nonStreamingTotal
                configuration.timeoutIntervalForRequest = sessionTimeout
                configuration.timeoutIntervalForResource = sessionTimeout
                let session = URLSession(
                    configuration: configuration,
                    delegate: self,
                    delegateQueue: delegateQueue
                )
                self.session = session
                let task = session.dataTask(with: urlRequest)
                self.task = task
                scheduleFirstByteTimeout()
                if !request.streamsResponse {
                    scheduleTotalTimeout()
                }
                task.resume()
            } catch let error as TranslationServiceError {
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
            task?.cancel()
            finish(with: .cancelled)
        }
    }

    private func scheduleFirstByteTimeout() {
        let timer = DispatchWorkItem { [weak self] in
            self?.finish(with: .firstByteTimeout)
        }
        firstByteTimer = timer
        stateQueue.asyncAfter(deadline: .now() + timeoutPolicy.firstByte, execute: timer)
    }

    private func scheduleStreamIdleTimeout() {
        streamIdleTimer?.cancel()
        let timer = DispatchWorkItem { [weak self] in
            self?.finish(with: .streamIdleTimeout)
        }
        streamIdleTimer = timer
        stateQueue.asyncAfter(deadline: .now() + timeoutPolicy.streamIdle, execute: timer)
    }

    private func scheduleTotalTimeout() {
        let timer = DispatchWorkItem { [weak self] in
            self?.finish(with: .requestTimeout)
        }
        totalTimer = timer
        stateQueue.asyncAfter(deadline: .now() + timeoutPolicy.nonStreamingTotal, execute: timer)
    }

    private func emit(kind: String, text: String? = nil, error: TranslationServiceError? = nil) {
        eventHandler(
            TranslationXPCEvent(
                requestID: request.requestID,
                kind: kind,
                text: text,
                errorCode: error?.code,
                message: error?.safeMessage
            )
        )
    }

    private func finishSuccessfully() {
        guard !isFinished else { return }
        isFinished = true
        cancelTimers()
        task?.cancel()
        session?.finishTasksAndInvalidate()
        parser.reset()
        responseData.removeAll(keepingCapacity: false)
        emit(kind: "completed")
        completionHandler(request.requestID)
    }

    private func finish(with error: TranslationServiceError) {
        guard !isFinished else { return }
        isFinished = true
        cancelTimers()
        task?.cancel()
        session?.invalidateAndCancel()
        parser.reset()
        responseData.removeAll(keepingCapacity: false)
        emit(kind: error == .cancelled ? "cancelled" : "failed", error: error)
        completionHandler(request.requestID)
    }

    private func cancelTimers() {
        firstByteTimer?.cancel()
        streamIdleTimer?.cancel()
        totalTimer?.cancel()
        firstByteTimer = nil
        streamIdleTimer = nil
        totalTimer = nil
    }
}

extension TranslationRequestOperation: URLSessionDataDelegate, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard !isFinished,
              let httpResponse = response as? HTTPURLResponse
        else {
            completionHandler(.cancel)
            finish(with: .invalidResponse)
            return
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            // Error bodies are intentionally never exposed across XPC. Finishing as soon as
            // the status arrives also prevents a streaming request from waiting on a server
            // that sends error headers but never completes the response body.
            completionHandler(.cancel)
            finish(with: .http(status: httpResponse.statusCode))
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard !isFinished else { return }
        guard let response = dataTask.response as? HTTPURLResponse else {
            finish(with: .invalidResponse)
            return
        }

        if !(200..<300).contains(response.statusCode) {
            return
        }

        if request.streamsResponse {
            let acceptedBefore = parser.acceptedDataFrameCount
            do {
                let events = try parser.append(data)
                if parser.acceptedDataFrameCount > acceptedBefore {
                    firstByteTimer?.cancel()
                    firstByteTimer = nil
                    scheduleStreamIdleTimeout()
                }
                for event in events {
                    switch event {
                    case let .delta(text):
                        emit(kind: "delta", text: text)
                        scheduleStreamIdleTimeout()
                    case .finished:
                        guard parser.receivedText else {
                            finish(with: .nonTextResponse)
                            return
                        }
                        finishSuccessfully()
                    }
                }
            } catch let error as TranslationServiceError {
                finish(with: error)
            } catch {
                finish(with: .invalidResponse)
            }
        } else {
            firstByteTimer?.cancel()
            firstByteTimer = nil
            responseData.append(data)
        }
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
        guard let response = task.response as? HTTPURLResponse else {
            finish(with: .connection)
            return
        }
        guard (200..<300).contains(response.statusCode) else {
            finish(with: .http(status: response.statusCode))
            return
        }
        if let error {
            let code = (error as NSError).code
            finish(with: code == NSURLErrorTimedOut ? .requestTimeout : .connection)
            return
        }

        do {
            if request.streamsResponse {
                for event in try parser.finish() {
                    if case .finished = event {
                        guard parser.receivedText else {
                            finish(with: .nonTextResponse)
                            return
                        }
                    }
                }
                guard parser.receivedText else {
                    finish(with: .nonTextResponse)
                    return
                }
                finishSuccessfully()
            } else {
                let text = try OpenAIChatCompletionResponseParser.parseText(from: responseData)
                emit(kind: "delta", text: text)
                finishSuccessfully()
            }
        } catch let error as TranslationServiceError {
            finish(with: error)
        } catch {
            finish(with: .invalidResponse)
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let original = task.originalRequest?.url,
              let redirected = request.url,
              original.scheme?.lowercased() == redirected.scheme?.lowercased(),
              original.host?.lowercased() == redirected.host?.lowercased(),
              effectivePort(for: original) == effectivePort(for: redirected)
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
        completionHandler(request)
    }

    private func effectivePort(for url: URL) -> Int? {
        if let port = url.port { return port }
        switch url.scheme?.lowercased() {
        case "https": return 443
        case "http": return 80
        default: return nil
        }
    }
}
