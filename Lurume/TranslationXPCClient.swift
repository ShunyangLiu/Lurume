import Foundation

protocol TranslationRequestSending: Sendable {
    func start(
        _ request: TranslationXPCRequest,
        eventHandler: @escaping @Sendable (TranslationXPCEvent) -> Void
    ) throws
    func cancel(requestID: String)
}

enum TranslationXPCClientError: LocalizedError {
    case unavailable

    var errorDescription: String? {
        "无法启动翻译服务。"
    }
}

final class TranslationXPCClient: NSObject, TranslationXPCClientProtocol, TranslationRequestSending,
    @unchecked Sendable {
    private let connectionLock = NSLock()
    private var connection: NSXPCConnection?
    private let lock = NSLock()
    private var handlers: [String: @Sendable (TranslationXPCEvent) -> Void] = [:]

    override init() {
        super.init()
    }

    deinit {
        connectionLock.lock()
        let activeConnection = connection
        connection = nil
        connectionLock.unlock()
        activeConnection?.invalidate()
    }

    func start(
        _ request: TranslationXPCRequest,
        eventHandler: @escaping @Sendable (TranslationXPCEvent) -> Void
    ) throws {
        lock.lock()
        guard handlers[request.requestID] == nil else {
            lock.unlock()
            throw TranslationXPCClientError.unavailable
        }
        handlers[request.requestID] = eventHandler
        lock.unlock()

        let connection = connectionForUse()
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ [weak self] _ in
            self?.fail(requestID: request.requestID)
        }) as? TranslationXPCServiceProtocol else {
            removeHandler(requestID: request.requestID)
            throw TranslationXPCClientError.unavailable
        }
        proxy.start(request) { [weak self] accepted in
            if !accepted {
                self?.fail(requestID: request.requestID)
            }
        }
    }

    func cancel(requestID: String) {
        removeHandler(requestID: requestID)
        connectionLock.lock()
        let activeConnection = connection
        connectionLock.unlock()
        (activeConnection?.remoteObjectProxy as? TranslationXPCServiceProtocol)?
            .cancel(requestID: requestID)
    }

    func receive(_ event: TranslationXPCEvent) {
        lock.lock()
        let handler = handlers[event.requestID]
        if Self.terminalKinds.contains(event.kind) {
            handlers[event.requestID] = nil
        }
        lock.unlock()
        handler?(event)
    }

    private func fail(requestID: String) {
        lock.lock()
        let handler = handlers.removeValue(forKey: requestID)
        lock.unlock()
        handler?(
            TranslationXPCEvent(
                requestID: requestID,
                kind: "failed",
                errorCode: "xpc_unavailable",
                message: "翻译服务连接已中断。"
            )
        )
    }

    private func failAllActiveRequests() {
        lock.lock()
        let activeHandlers = handlers
        handlers.removeAll()
        lock.unlock()
        for (requestID, handler) in activeHandlers {
            handler(
                TranslationXPCEvent(
                    requestID: requestID,
                    kind: "failed",
                    errorCode: "xpc_unavailable",
                    message: "翻译服务连接已中断。"
                )
            )
        }
    }

    private func removeHandler(requestID: String) {
        lock.lock()
        handlers[requestID] = nil
        lock.unlock()
    }

    private func connectionForUse() -> NSXPCConnection {
        connectionLock.lock()
        defer { connectionLock.unlock() }
        if let connection { return connection }

        let newConnection = NSXPCConnection(serviceName: TranslationXPCConstants.serviceName)
        newConnection.remoteObjectInterface = NSXPCInterface(with: TranslationXPCServiceProtocol.self)
        newConnection.exportedInterface = NSXPCInterface(with: TranslationXPCClientProtocol.self)
        newConnection.exportedObject = self
        newConnection.interruptionHandler = { [weak self] in
            self?.failAllActiveRequests()
        }
        newConnection.invalidationHandler = { [weak self, weak newConnection] in
            self?.clearConnectionIfCurrent(newConnection)
            self?.failAllActiveRequests()
        }
        connection = newConnection
        newConnection.resume()
        return newConnection
    }

    private func clearConnectionIfCurrent(_ invalidatedConnection: NSXPCConnection?) {
        connectionLock.lock()
        if connection === invalidatedConnection {
            connection = nil
        }
        connectionLock.unlock()
    }

    private static let terminalKinds: Set<String> = ["completed", "failed", "cancelled"]
}
