import Foundation

final class TranslationService: NSObject, TranslationXPCServiceProtocol, @unchecked Sendable {
    private weak var connection: NSXPCConnection?
    private let lock = NSLock()
    private var operations: [String: TranslationRequestOperation] = [:]

    init(connection: NSXPCConnection) {
        self.connection = connection
    }

    func start(_ request: TranslationXPCRequest, withReply reply: @escaping (Bool) -> Void) {
        let operation = TranslationRequestOperation(
            request: request,
            eventHandler: { [weak self] event in
                self?.send(event)
            },
            completionHandler: { [weak self] requestID in
                self?.removeOperation(requestID: requestID)
            }
        )

        lock.lock()
        guard operations[request.requestID] == nil else {
            lock.unlock()
            reply(false)
            return
        }
        operations[request.requestID] = operation
        lock.unlock()

        reply(true)
        operation.start()
    }

    func cancel(requestID: String) {
        lock.lock()
        let operation = operations[requestID]
        lock.unlock()
        operation?.cancel()
    }

    func ping(withReply reply: @escaping (String) -> Void) {
        reply("ready")
    }

    func cancelAll() {
        lock.lock()
        let activeOperations = Array(operations.values)
        operations.removeAll()
        lock.unlock()
        activeOperations.forEach { $0.cancel() }
    }

    private func removeOperation(requestID: String) {
        lock.lock()
        operations[requestID] = nil
        lock.unlock()
    }

    private func send(_ event: TranslationXPCEvent) {
        guard let proxy = connection?.remoteObjectProxyWithErrorHandler({ _ in })
            as? TranslationXPCClientProtocol
        else {
            return
        }
        proxy.receive(event)
    }
}

final class TranslationServiceListenerDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        let service = TranslationService(connection: connection)
        connection.exportedInterface = TranslationXPCInterfaces.service()
        connection.exportedObject = service
        connection.remoteObjectInterface = TranslationXPCInterfaces.client()
        connection.invalidationHandler = { [weak service] in
            service?.cancelAll()
        }
        connection.interruptionHandler = { [weak service] in
            service?.cancelAll()
        }
        connection.resume()
        return true
    }
}

enum TranslationXPCInterfaces {
    static func service() -> NSXPCInterface {
        NSXPCInterface(with: TranslationXPCServiceProtocol.self)
    }

    static func client() -> NSXPCInterface {
        NSXPCInterface(with: TranslationXPCClientProtocol.self)
    }
}
