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
    private let stopAccessing: (@Sendable () -> Void)?

    init(url: URL) {
        self.url = url
        let didStartAccessing = url.startAccessingSecurityScopedResource()
        if didStartAccessing {
            stopAccessing = { @Sendable in
                url.stopAccessingSecurityScopedResource()
            }
        } else {
            stopAccessing = nil
        }
    }

    init(
        url: URL,
        startAccessing: @Sendable (URL) -> Bool,
        stopAccessing: @escaping @Sendable (URL) -> Void
    ) {
        self.url = url
        let didStartAccessing = startAccessing(url)
        if didStartAccessing {
            self.stopAccessing = { @Sendable in stopAccessing(url) }
        } else {
            self.stopAccessing = nil
        }
    }

    deinit {
        stopAccessing?()
    }
}
