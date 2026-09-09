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
    var errorDescription: String? { "无法启动翻译服务。" }
}

final class TranslationXPCClient: NSObject, TranslationXPCClientProtocol, TranslationRequestSending,
    @unchecked Sendable {
    private struct Connection {
        let id: UUID
        let value: NSXPCConnection
    }
    private struct RequestHandler {
        let connectionID: UUID
        let receive: @Sendable (TranslationXPCEvent) -> Void
    }

    // Connection identity and request ownership change in one critical section.
    // An old connection's late invalidation must never fail a newer connection.
    private let idleTimeout: TimeInterval
    private var idleCloseToken: UUID?
    private var idleCloseWork: DispatchWorkItem?
    private let lock = NSLock()
    private var connection: Connection?
    private var handlers: [String: RequestHandler] = [:]
    private let makeConnection: @Sendable () -> NSXPCConnection

    init(idleTimeout: TimeInterval = 30, makeConnection: @escaping @Sendable () -> NSXPCConnection = {
        NSXPCConnection(serviceName: TranslationXPCConstants.serviceName)
    }) {
        self.idleTimeout = max(0, idleTimeout)
        self.makeConnection = makeConnection
        super.init()
    }

    deinit { idleCloseWork?.cancel(); connection?.value.invalidate() }

    func start(
        _ request: TranslationXPCRequest,
        eventHandler: @escaping @Sendable (TranslationXPCEvent) -> Void
    ) throws {
        lock.lock()
        guard handlers[request.requestID] == nil else {
            lock.unlock()
            throw TranslationXPCClientError.unavailable
        }
        let connection = connectionForUseWhileLocked()
        handlers[request.requestID] = RequestHandler(connectionID: connection.id, receive: eventHandler)
        lock.unlock()

        guard let proxy = connection.value.remoteObjectProxyWithErrorHandler({ [weak self] _ in
            self?.fail(requestID: request.requestID, connectionID: connection.id)
        }) as? TranslationXPCServiceProtocol else {
            fail(requestID: request.requestID, connectionID: connection.id)
            throw TranslationXPCClientError.unavailable
        }
        proxy.start(request) { [weak self] accepted in
            if !accepted { self?.fail(requestID: request.requestID, connectionID: connection.id) }
        }
    }

    func cancel(requestID: String) {
        lock.lock()
        guard let handler = handlers.removeValue(forKey: requestID) else {
            lock.unlock()
            return
        }
        let activeConnection = connection?.id == handler.connectionID ? connection?.value : nil
        let idleConnection = detachIdleConnectionWhileLocked()
        lock.unlock()
        (activeConnection?.remoteObjectProxy as? TranslationXPCServiceProtocol)?.cancel(requestID: requestID)
        idleConnection?.invalidate()
    }

    func receive(_ event: TranslationXPCEvent) {
        lock.lock()
        let handler = handlers[event.requestID]
        let terminal = Self.terminalKinds.contains(event.kind)
        if terminal { handlers[event.requestID] = nil }
        let idleConnection = terminal ? detachIdleConnectionWhileLocked() : nil
        lock.unlock()
        handler?.receive(event)
        idleConnection?.invalidate()
    }

    private func fail(requestID: String, connectionID: UUID) {
        // A proxy failure must retire the broken connection immediately, not
        // return it to the idle cache for the next request.
        connectionDidEnd(connectionID)
    }

    private func connectionDidEnd(_ id: UUID) {
        lock.lock()
        let affected = handlers.filter { $0.value.connectionID == id }
        for requestID in affected.keys { handlers[requestID] = nil }
        let endedConnection = connection?.id == id ? connection?.value : nil
        if connection?.id == id { connection = nil }
        lock.unlock()
        for (requestID, handler) in affected { handler.receive(Self.failure(requestID: requestID)) }
        endedConnection?.invalidate()
    }

    private func connectionForUseWhileLocked() -> Connection {
        idleCloseWork?.cancel()
        idleCloseWork = nil
        idleCloseToken = nil
        if let connection { return connection }
        let id = UUID()
        let value = makeConnection()
        value.remoteObjectInterface = NSXPCInterface(with: TranslationXPCServiceProtocol.self)
        value.exportedInterface = NSXPCInterface(with: TranslationXPCClientProtocol.self)
        value.exportedObject = self
        value.interruptionHandler = { [weak self] in self?.connectionDidEnd(id) }
        value.invalidationHandler = { [weak self] in self?.connectionDidEnd(id) }
        let newConnection = Connection(id: id, value: value)
        connection = newConnection
        value.resume()
        return newConnection
    }

    private func detachIdleConnectionWhileLocked() -> NSXPCConnection? {
        guard let connection,
              !handlers.values.contains(where: { $0.connectionID == connection.id }) else { return nil }
        guard idleTimeout > 0 else {
            self.connection = nil
            return connection.value
        }
        idleCloseWork?.cancel()
        let token = UUID()
        idleCloseToken = token
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.lock.lock()
            guard self.idleCloseToken == token,
                  self.connection?.id == connection.id,
                  self.handlers.isEmpty else {
                self.lock.unlock()
                return
            }
            self.connection = nil
            self.idleCloseToken = nil
            self.idleCloseWork = nil
            self.lock.unlock()
            connection.value.invalidate()
        }
        idleCloseWork = work
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + idleTimeout, execute: work)
        return nil
    }

    private static func failure(requestID: String) -> TranslationXPCEvent {
        TranslationXPCEvent(requestID: requestID, kind: "failed", errorCode: "xpc_unavailable",
            message: "翻译服务连接已中断。")
    }

    #if DEBUG
    var hasActiveConnectionForTesting: Bool { lock.withLock { connection != nil } }
    #endif

    private static let terminalKinds: Set<String> = ["completed", "failed", "cancelled"]
}
