import Foundation
import Security

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
        guard TranslationXPCConnectionVerifier.validateAndPin(connection) else {
            return false
        }
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

private enum TranslationXPCConnectionVerifier {
    static func validateAndPin(_ connection: NSXPCConnection) -> Bool {
        guard let signingMode = serviceSigningMode() else {
            NSLog("Translation XPC rejected connection: service signature unavailable")
            return false
        }
        let requirement = TranslationXPCConnectionPolicy.codeSigningRequirement(
            teamIdentifier: signingMode.teamIdentifier
        )
        // NSXPCConnection evaluates this requirement against the real peer credentials,
        // before any exported service method can receive a request or API key.
        connection.setCodeSigningRequirement(requirement)
        return true
    }

    private enum ServiceSigningMode {
        case adHoc
        case developmentOrDistribution(teamIdentifier: String)

        var teamIdentifier: String? {
            switch self {
            case .adHoc: nil
            case let .developmentOrDistribution(teamIdentifier): teamIdentifier
            }
        }
    }

    private static func serviceSigningMode() -> ServiceSigningMode? {
        var dynamicCode: SecCode?
        guard SecCodeCopySelf(SecCSFlags(), &dynamicCode) == errSecSuccess,
              let dynamicCode,
              SecCodeCheckValidity(dynamicCode, SecCSFlags(), nil) == errSecSuccess
        else {
            return nil
        }
        var code: SecStaticCode?
        guard SecCodeCopyStaticCode(dynamicCode, SecCSFlags(), &code) == errSecSuccess,
              let code
        else {
            return nil
        }
        var information: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
        guard SecCodeCopySigningInformation(code, flags, &information) == errSecSuccess,
              let values = information as? [CFString: Any],
              let signatureFlags = values[kSecCodeInfoFlags] as? NSNumber
        else {
            return nil
        }
        let adHocSignatureFlag: UInt32 = 0x0002 // kSecCodeSignatureAdhoc in CSCommon.h
        if signatureFlags.uint32Value & adHocSignatureFlag != 0 {
            return .adHoc
        }
        guard let teamIdentifier = values[kSecCodeInfoTeamIdentifier] as? String,
              !teamIdentifier.isEmpty
        else {
            return nil
        }
        return .developmentOrDistribution(teamIdentifier: teamIdentifier)
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
