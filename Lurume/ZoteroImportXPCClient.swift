import Foundation

protocol ZoteroImportRequestSending: Sendable {
    func start(
        _ request: ZoteroImportXPCRequest,
        eventHandler: @escaping @Sendable (ZoteroImportXPCEvent) -> Void
    ) throws
    func cancel(requestID: String)
}

enum ZoteroImportXPCClientError: LocalizedError, Equatable {
    case unavailable

    var errorDescription: String? {
        "无法启动 Zotero 导入服务。"
    }
}

final class ZoteroImportXPCClient: NSObject, ZoteroImportXPCClientProtocol,
    ZoteroImportRequestSending, @unchecked Sendable {
    private let connectionLock = NSLock()
    private var connection: NSXPCConnection?
    private let handlerLock = NSLock()
    private var handlers: [String: @Sendable (ZoteroImportXPCEvent) -> Void] = [:]

    deinit {
        connectionLock.lock()
        let active = connection
        connection = nil
        connectionLock.unlock()
        active?.invalidate()
    }

    func start(
        _ request: ZoteroImportXPCRequest,
        eventHandler: @escaping @Sendable (ZoteroImportXPCEvent) -> Void
    ) throws {
        handlerLock.lock()
        guard handlers[request.requestID] == nil else {
            handlerLock.unlock()
            throw ZoteroImportXPCClientError.unavailable
        }
        handlers[request.requestID] = eventHandler
        handlerLock.unlock()

        let connection = connectionForUse()
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ [weak self] _ in
            self?.fail(requestID: request.requestID)
        }) as? ZoteroImportXPCServiceProtocol else {
            removeHandler(requestID: request.requestID)
            throw ZoteroImportXPCClientError.unavailable
        }
        proxy.start(request) { [weak self] accepted in
            if !accepted { self?.fail(requestID: request.requestID) }
        }
    }

    func cancel(requestID: String) {
        removeHandler(requestID: requestID)
        connectionLock.lock()
        let active = connection
        connectionLock.unlock()
        (active?.remoteObjectProxy as? ZoteroImportXPCServiceProtocol)?
            .cancel(requestID: requestID)
        invalidateConnectionIfIdle()
    }

    func receive(_ event: ZoteroImportXPCEvent) {
        handlerLock.lock()
        let handler = handlers[event.requestID]
        if Self.terminalKinds.contains(event.kind) {
            handlers[event.requestID] = nil
        }
        handlerLock.unlock()
        handler?(event)
        if Self.terminalKinds.contains(event.kind) { invalidateConnectionIfIdle() }
    }

    private func connectionForUse() -> NSXPCConnection {
        connectionLock.lock()
        defer { connectionLock.unlock() }
        if let connection { return connection }

        let newConnection = NSXPCConnection(serviceName: ZoteroImportXPCConstants.serviceName)
        newConnection.remoteObjectInterface = NSXPCInterface(with: ZoteroImportXPCServiceProtocol.self)
        newConnection.exportedInterface = NSXPCInterface(with: ZoteroImportXPCClientProtocol.self)
        newConnection.exportedObject = self
        newConnection.interruptionHandler = { [weak self] in self?.failAllActiveRequests() }
        newConnection.invalidationHandler = { [weak self, weak newConnection] in
            self?.clearConnectionIfCurrent(newConnection)
            self?.failAllActiveRequests()
        }
        connection = newConnection
        newConnection.resume()
        return newConnection
    }

    private func fail(requestID: String) {
        handlerLock.lock()
        let handler = handlers.removeValue(forKey: requestID)
        handlerLock.unlock()
        handler?(
            ZoteroImportXPCEvent(
                requestID: requestID,
                kind: "failed",
                errorCode: "xpc_unavailable",
                message: "Zotero 导入服务连接已中断。"
            )
        )
        invalidateConnectionIfIdle()
    }

    private func failAllActiveRequests() {
        handlerLock.lock()
        let active = handlers
        handlers.removeAll()
        handlerLock.unlock()
        for (requestID, handler) in active {
            handler(
                ZoteroImportXPCEvent(
                    requestID: requestID,
                    kind: "failed",
                    errorCode: "xpc_unavailable",
                    message: "Zotero 导入服务连接已中断。"
                )
            )
        }
        invalidateConnectionIfIdle()
    }

    private func removeHandler(requestID: String) {
        handlerLock.lock()
        handlers[requestID] = nil
        handlerLock.unlock()
    }

    private func clearConnectionIfCurrent(_ candidate: NSXPCConnection?) {
        connectionLock.lock()
        if connection === candidate { connection = nil }
        connectionLock.unlock()
    }

    private func invalidateConnectionIfIdle() {
        connectionLock.lock()
        handlerLock.lock()
        guard handlers.isEmpty else {
            handlerLock.unlock()
            connectionLock.unlock()
            return
        }
        let idle = connection
        connection = nil
        handlerLock.unlock()
        connectionLock.unlock()
        idle?.invalidate()
    }

#if DEBUG
    var hasActiveConnectionForTesting: Bool {
        connectionLock.lock()
        defer { connectionLock.unlock() }
        return connection != nil
    }
#endif

    private static let terminalKinds: Set<String> = ["completed", "failed", "cancelled"]
}
