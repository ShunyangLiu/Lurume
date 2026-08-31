import Foundation

enum TranslationXPCConnectionPolicy {
    static let allowedBundleIdentifiers = [
        "app.lurume.Lurume",
        "app.lurume.TranslationProbe"
    ]

    static func codeSigningRequirement(teamIdentifier: String?) -> String {
        let identities = allowedBundleIdentifiers
            .map { "identifier \"\(escaped($0))\"" }
            .joined(separator: " or ")
        guard let teamIdentifier else {
            return "(\(identities))"
        }
        return "(\(identities)) and anchor apple generic and "
            + "certificate leaf[subject.OU] = \"\(escaped(teamIdentifier))\""
    }

    private static func escaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
