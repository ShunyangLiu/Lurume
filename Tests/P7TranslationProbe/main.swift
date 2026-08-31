import Darwin
import Foundation

final class ProbeCallback: NSObject, TranslationXPCClientProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private let terminalSemaphore = DispatchSemaphore(value: 0)
    private var requestID: String?
    private var text = ""
    private var terminal: TranslationXPCEvent?

    func begin(requestID: String) {
        lock.lock()
        self.requestID = requestID
        text = ""
        terminal = nil
        lock.unlock()
    }

    func receive(_ event: TranslationXPCEvent) {
        lock.lock()
        guard event.requestID == requestID else {
            lock.unlock()
            return
        }
        if event.kind == "delta", let delta = event.text {
            text += delta
        }
        if ["completed", "failed", "cancelled"].contains(event.kind) {
            terminal = event
            lock.unlock()
            terminalSemaphore.signal()
            return
        }
        lock.unlock()
    }

    func wait(timeout: TimeInterval) -> (text: String, event: TranslationXPCEvent)? {
        guard terminalSemaphore.wait(timeout: .now() + timeout) == .success else {
            return nil
        }
        lock.lock()
        defer { lock.unlock() }
        guard let terminal else { return nil }
        return (text, terminal)
    }
}

final class ProbeValue: @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?

    func set(_ value: String) {
        lock.lock()
        self.value = value
        lock.unlock()
    }

    func get() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

final class ProbeState: @unchecked Sendable {
    let proxyError = ProbeValue()
    let pingSemaphore = DispatchSemaphore(value: 0)
    let pingValue = ProbeValue()
    let acceptedSemaphore = DispatchSemaphore(value: 0)
    let acceptedValue = ProbeValue()

    func recordProxyError(_ error: Error) {
        proxyError.set(error.localizedDescription)
    }

    func recordPing(_ value: String) {
        pingValue.set(value)
        pingSemaphore.signal()
    }

    func recordAcceptance(_ value: Bool) {
        acceptedValue.set(value ? "yes" : "no")
        acceptedSemaphore.signal()
    }
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

guard CommandLine.arguments.count == 2,
      let endpoint = URL(string: CommandLine.arguments[1]),
      endpoint.scheme == "http",
      endpoint.host == "127.0.0.1"
else {
    fail("usage: LurumeTranslationProbe http://127.0.0.1:<port>/stream")
}

let callback = ProbeCallback()
let state = ProbeState()
let connection = NSXPCConnection(serviceName: TranslationXPCConstants.serviceName)
connection.remoteObjectInterface = NSXPCInterface(with: TranslationXPCServiceProtocol.self)
connection.exportedInterface = NSXPCInterface(with: TranslationXPCClientProtocol.self)
connection.exportedObject = callback
connection.resume()
defer { connection.invalidate() }

guard let proxy = connection.remoteObjectProxyWithErrorHandler(state.recordProxyError) as? TranslationXPCServiceProtocol else {
    fail("Translation XPC proxy unavailable")
}

let launchStart = DispatchTime.now().uptimeNanoseconds
proxy.ping(withReply: state.recordPing)
guard state.pingSemaphore.wait(timeout: .now() + 5) == .success,
      state.pingValue.get() == "ready"
else {
    if let message = state.proxyError.get() {
        fail("XPC proxy failed: \(message)")
    }
    fail("Translation XPC cold-start ping timed out")
}
let launchElapsed = DispatchTime.now().uptimeNanoseconds - launchStart

let requestID = UUID().uuidString
callback.begin(requestID: requestID)
proxy.start(
    TranslationXPCRequest(
        requestID: requestID,
        endpoint: endpoint.absoluteString,
        model: "fixture-model",
        systemPrompt: "Translate the selected text.",
        selectedText: "fixture selection only",
        apiKey: nil,
        streamsResponse: true
    ),
    withReply: state.recordAcceptance
)
guard state.acceptedSemaphore.wait(timeout: .now() + 3) == .success,
      state.acceptedValue.get() == "yes"
else {
    if let message = state.proxyError.get() {
        fail("XPC proxy failed: \(message)")
    }
    fail("Translation XPC rejected the probe request")
}
guard let result = callback.wait(timeout: 8), result.event.kind == "completed" else {
    if let message = state.proxyError.get() {
        fail("XPC proxy failed: \(message)")
    }
    fail("Translation XPC probe request did not complete")
}

let output: [String: Any] = [
    "coldStartMilliseconds": Double(launchElapsed) / 1_000_000,
    "terminal": result.event.kind,
    "text": result.text
]
let outputData = try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys])
FileHandle.standardOutput.write(outputData)
FileHandle.standardOutput.write(Data("\n".utf8))
