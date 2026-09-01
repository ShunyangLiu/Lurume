import Foundation

let delegate = ZoteroImportServiceListenerDelegate()
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
