import Foundation

struct ResolvedFileReference: Sendable {
    let url: URL
    let refreshedBookmarkData: Data?
}

enum SecurityScopedFile {
    static let bookmarkCreationOptions: URL.BookmarkCreationOptions = [
        .withSecurityScope,
        .securityScopeAllowOnlyReadAccess,
    ]

    static func makeBookmark(for url: URL) throws -> Data {
        try url.bookmarkData(
            options: bookmarkCreationOptions,
            includingResourceValuesForKeys: [
                .volumeUUIDStringKey,
                .documentIdentifierKey,
            ],
            relativeTo: nil
        )
    }

    static func resolve(bookmarkData: Data) throws -> ResolvedFileReference {
        var isStale = false
        let url = try URL(
            resolvingBookmarkData: bookmarkData,
            options: [.withSecurityScope, .withoutUI],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )

        let didStartAccessing = url.startAccessingSecurityScopedResource()
        defer {
            if didStartAccessing {
                url.stopAccessingSecurityScopedResource()
            }
        }
        let refreshedBookmarkData = isStale ? try makeBookmark(for: url) : nil
        return ResolvedFileReference(
            url: url,
            refreshedBookmarkData: refreshedBookmarkData
        )
    }
}

@MainActor
final class SecurityScopedAccess {
    let url: URL
    private let didStartAccessing: Bool

    init(url: URL) {
        self.url = url
        didStartAccessing = url.startAccessingSecurityScopedResource()
    }

    deinit {
        if didStartAccessing {
            url.stopAccessingSecurityScopedResource()
        }
    }
}
