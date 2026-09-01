import Foundation

struct ResolvedFileReference: Sendable {
    let url: URL
    let refreshedBookmarkData: Data?
}

enum SecurityScopedFile {
    static func makeBookmark(for url: URL) throws -> Data {
        try makeBookmark(for: url, readOnly: true)
    }

    static func makeBookmark(for url: URL, readOnly: Bool) throws -> Data {
        var options: URL.BookmarkCreationOptions = [.withSecurityScope]
        if readOnly { options.insert(.securityScopeAllowOnlyReadAccess) }
        return try url.bookmarkData(
            options: options,
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
