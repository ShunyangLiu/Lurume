import Foundation
import Security

final class ZoteroImportService: NSObject, ZoteroImportXPCServiceProtocol, @unchecked Sendable {
    private weak var connection: NSXPCConnection?
    private let endpointPolicy: ZoteroEndpointPolicy
    private let lock = NSLock()
    private var operations: [String: ZoteroAPIRequestOperation] = [:]

    init(connection: NSXPCConnection, endpointPolicy: ZoteroEndpointPolicy) {
        self.connection = connection
        self.endpointPolicy = endpointPolicy
    }

    func start(_ request: ZoteroImportXPCRequest, withReply reply: @escaping (Bool) -> Void) {
        let operation = ZoteroAPIRequestOperation(
            request: request,
            endpointPolicy: endpointPolicy(for: request),
            eventHandler: { [weak self] event in self?.send(event) },
            completionHandler: { [weak self] requestID in self?.removeOperation(requestID) }
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

    private func endpointPolicy(for request: ZoteroImportXPCRequest) -> ZoteroEndpointPolicy {
#if DEBUG
        if let value = request.testingOrigin,
           let url = URL(string: value),
           url.scheme == "http",
           url.host == "127.0.0.1",
           url.port != nil,
           url.path.isEmpty || url.path == "/",
           url.query == nil,
           url.fragment == nil,
           url.user == nil,
           url.password == nil {
            return ZoteroEndpointPolicy.testing(origin: url)
        }
#endif
        return endpointPolicy
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
        let active = Array(operations.values)
        operations.removeAll()
        lock.unlock()
        active.forEach { $0.cancel() }
    }

    private func removeOperation(_ requestID: String) {
        lock.lock()
        operations[requestID] = nil
        lock.unlock()
    }

    private func send(_ event: ZoteroImportXPCEvent) {
        guard let proxy = connection?.remoteObjectProxyWithErrorHandler({ _ in })
            as? ZoteroImportXPCClientProtocol
        else { return }
        proxy.receive(event)
    }
}

final class ZoteroImportServiceListenerDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard ZoteroImportXPCConnectionVerifier.validateAndPin(connection) else { return false }
        let service = ZoteroImportService(
            connection: connection,
            endpointPolicy: .production
        )
        connection.exportedInterface = ZoteroImportXPCInterfaces.service()
        connection.exportedObject = service
        connection.remoteObjectInterface = ZoteroImportXPCInterfaces.client()
        connection.invalidationHandler = { [weak service] in service?.cancelAll() }
        connection.interruptionHandler = { [weak service] in service?.cancelAll() }
        connection.resume()
        return true
    }

}

private enum ZoteroImportXPCConnectionVerifier {
    static func validateAndPin(_ connection: NSXPCConnection) -> Bool {
        guard let signingMode = serviceSigningMode() else {
            NSLog("Zotero import XPC rejected connection: service signature unavailable")
            return false
        }
        connection.setCodeSigningRequirement(
            ZoteroImportXPCConnectionPolicy.codeSigningRequirement(
                teamIdentifier: signingMode.teamIdentifier
            )
        )
        return true
    }

    private enum ServiceSigningMode {
        case adHoc
        case signed(teamIdentifier: String)

        var teamIdentifier: String? {
            switch self {
            case .adHoc: nil
            case let .signed(teamIdentifier): teamIdentifier
            }
        }
    }

    private static func serviceSigningMode() -> ServiceSigningMode? {
        var dynamicCode: SecCode?
        guard SecCodeCopySelf(SecCSFlags(), &dynamicCode) == errSecSuccess,
              let dynamicCode,
              SecCodeCheckValidity(dynamicCode, SecCSFlags(), nil) == errSecSuccess
        else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(dynamicCode, SecCSFlags(), &staticCode) == errSecSuccess,
              let staticCode
        else { return nil }
        var information: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
        guard SecCodeCopySigningInformation(staticCode, flags, &information) == errSecSuccess,
              let values = information as? [CFString: Any],
              let signatureFlags = values[kSecCodeInfoFlags] as? NSNumber
        else { return nil }
        let adHocSignatureFlag: UInt32 = 0x0002
        if signatureFlags.uint32Value & adHocSignatureFlag != 0 { return .adHoc }
        guard let teamIdentifier = values[kSecCodeInfoTeamIdentifier] as? String,
              !teamIdentifier.isEmpty
        else { return nil }
        return .signed(teamIdentifier: teamIdentifier)
    }
}

enum ZoteroImportXPCInterfaces {
    static func service() -> NSXPCInterface {
        NSXPCInterface(with: ZoteroImportXPCServiceProtocol.self)
    }

    static func client() -> NSXPCInterface {
        NSXPCInterface(with: ZoteroImportXPCClientProtocol.self)
    }
}
