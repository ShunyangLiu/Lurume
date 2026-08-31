import Foundation

enum CollectionExpansionStateCodec {
    static func decode(_ storage: String) -> Set<UUID> {
        Set(storage.split(separator: ",").compactMap {
            UUID(uuidString: String($0))
        })
    }

    static func encode(_ ids: Set<UUID>) -> String {
        ids.map(\.uuidString).sorted().joined(separator: ",")
    }

    static func pruning(_ storage: String, validIDs: Set<UUID>) -> String {
        encode(decode(storage).intersection(validIDs))
    }
}
