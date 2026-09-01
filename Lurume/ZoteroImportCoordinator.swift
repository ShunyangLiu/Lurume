import Foundation

struct ZoteroMigrationPreview: Equatable, Sendable {
    struct PaperRow: Identifiable, Equatable, Sendable {
        var id: String { attachmentKey }
        var attachmentKey: String
        var title: String
        var fileName: String
        var collectionNames: [String]
        var disposition: ImportDisposition
    }

    var library: ZoteroServiceLibrary
    var scannedItemCount: Int
    var parentItemCount: Int
    var pdfAttachmentCount: Int
    var unavailableAttachmentCount: Int
    var unsupportedAttachmentCount: Int
    var nonPDFAttachmentCount: Int
    var unsupportedItemCount: Int
    var ignoredTagCount: Int
    var ignoredRelationCount: Int
    var parentItemsWithoutPDFCount: Int
    var plannedCollectionCount: Int
    var rows: [PaperRow]
    var plan: LibraryImportPlan
}

struct ZoteroImportRemoteError: LocalizedError, Equatable, Sendable {
    let code: String
    let message: String

    var errorDescription: String? { message }
}

private final class ZoteroAsyncRequestBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<ZoteroServicePayload, Error>?
    private var pendingResult: Result<ZoteroServicePayload, Error>?
    private var finished = false

    func install(_ continuation: CheckedContinuation<ZoteroServicePayload, Error>) {
        lock.lock()
        if let result = pendingResult {
            lock.unlock()
            continuation.resume(with: result)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func finish(_ result: Result<ZoteroServicePayload, Error>) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        if let continuation {
            self.continuation = nil
            lock.unlock()
            continuation.resume(with: result)
        } else {
            pendingResult = result
            lock.unlock()
        }
    }
}

private final class ZoteroRequestExecutor: @unchecked Sendable {
    private let sender: any ZoteroImportRequestSending

    init(sender: any ZoteroImportRequestSending) {
        self.sender = sender
    }

    func perform(_ request: ZoteroImportXPCRequest) async throws -> ZoteroServicePayload {
        let box = ZoteroAsyncRequestBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                box.install(continuation)
                if Task.isCancelled {
                    box.finish(.failure(CancellationError()))
                    return
                }
                do {
                    try sender.start(request) { event in
                        switch event.kind {
                        case "completed":
                            guard let data = event.payload,
                                  let payload = try? JSONDecoder().decode(
                                    ZoteroServicePayload.self,
                                    from: data
                                  )
                            else {
                                box.finish(.failure(ZoteroImportRemoteError(
                                    code: "invalid_response",
                                    message: "Zotero 导入服务返回了无效数据。"
                                )))
                                return
                            }
                            box.finish(.success(payload))
                        case "cancelled":
                            box.finish(.failure(CancellationError()))
                        case "failed":
                            box.finish(.failure(ZoteroImportRemoteError(
                                code: event.errorCode ?? "unknown",
                                message: event.message ?? "Zotero 导入失败。"
                            )))
                        default:
                            break
                        }
                    }
                    if Task.isCancelled {
                        sender.cancel(requestID: request.requestID)
                        box.finish(.failure(CancellationError()))
                    }
                } catch {
                    box.finish(.failure(error))
                }
            }
        } onCancel: {
            sender.cancel(requestID: request.requestID)
            box.finish(.failure(CancellationError()))
        }
    }
}

@MainActor
final class ZoteroImportCoordinator: ObservableObject {
    enum Phase: Equatable {
        case idle
        case connecting
        case selecting
        case scanning
        case preview
        case failed
        case cancelled
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var libraries: [ZoteroServiceLibrary] = []
    @Published private(set) var selectedLibraryID: String?
    @Published private(set) var collections: [ZoteroServiceCollection] = []
    @Published private(set) var selectedCollectionKeys: Set<String> = []
    @Published private(set) var importsWholeLibrary = true
    @Published private(set) var scannedItemCount = 0
    @Published private(set) var preview: ZoteroMigrationPreview?
    @Published private(set) var failureMessage: String?

    private static let pageSize = 100
    private static let maximumPageCount = 1_000
    private let executor: ZoteroRequestExecutor
    private var serverID: String?
    private var workTask: Task<Void, Never>?
    private var generation = UUID()
    private var existingPapers: [PaperRecord] = []

    init(sender: any ZoteroImportRequestSending = ZoteroImportXPCClient()) {
        executor = ZoteroRequestExecutor(sender: sender)
    }

    var isPresented: Bool { phase != .idle }
    var isBusy: Bool { phase == .connecting || phase == .scanning }
    var canScanSelection: Bool {
        phase == .selecting && (importsWholeLibrary || !selectedCollectionKeys.isEmpty)
    }
    var selectedLibrary: ZoteroServiceLibrary? {
        libraries.first(where: { $0.stableID == selectedLibraryID })
    }

    func begin(existingPapers: [PaperRecord]) {
        retireWork()
        let current = UUID()
        generation = current
        self.existingPapers = existingPapers
        libraries = []
        selectedLibraryID = nil
        collections = []
        selectedCollectionKeys = []
        importsWholeLibrary = true
        scannedItemCount = 0
        preview = nil
        failureMessage = nil
        phase = .connecting
        workTask = Task { [weak self] in
            guard let self else { return }
            do {
                let probeRequest = Self.request(kind: .probe)
                let probePayload = try await executor.perform(probeRequest)
                guard let probe = probePayload.probe else {
                    throw ZoteroImportRemoteError(
                        code: "invalid_response",
                        message: "Zotero Local API 缺少版本信息。"
                    )
                }
                try Task.checkCancellation()
                let groups = try await fetchAllLibraries(serverID: probe.serverID)
                try Task.checkCancellation()
                guard generation == current else { return }
                serverID = probe.serverID
                libraries = [ZoteroServiceLibrary(
                    type: "user",
                    id: 0,
                    name: "我的文库",
                    version: nil
                )] + groups
                selectedLibraryID = libraries[0].stableID
                collections = try await fetchAllCollections(
                    library: libraries[0],
                    serverID: probe.serverID
                )
                try Task.checkCancellation()
                guard generation == current else { return }
                phase = .selecting
            } catch is CancellationError {
                guard generation == current else { return }
                phase = .cancelled
            } catch {
                guard generation == current else { return }
                failureMessage = error.localizedDescription
                phase = .failed
            }
            if generation == current { workTask = nil }
        }
    }

    func selectLibrary(stableID: String) {
        guard !isBusy,
              let library = libraries.first(where: { $0.stableID == stableID }),
              let serverID else { return }
        retireWork()
        let current = UUID()
        generation = current
        selectedLibraryID = stableID
        selectedCollectionKeys = []
        importsWholeLibrary = true
        collections = []
        preview = nil
        failureMessage = nil
        phase = .connecting
        workTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await fetchAllCollections(library: library, serverID: serverID)
                try Task.checkCancellation()
                guard generation == current else { return }
                collections = result
                phase = .selecting
            } catch is CancellationError {
                guard generation == current else { return }
                phase = .cancelled
            } catch {
                guard generation == current else { return }
                failureMessage = error.localizedDescription
                phase = .failed
            }
            if generation == current { workTask = nil }
        }
    }

    func setCollectionSelected(_ selected: Bool, key: String) {
        guard phase == .selecting,
              !importsWholeLibrary,
              collections.contains(where: { $0.key == key }) else { return }
        let subtree = descendantKeys(of: key)
        if selected {
            selectedCollectionKeys.formUnion(subtree)
        } else {
            selectedCollectionKeys.subtract(subtree)
        }
    }

    func setImportsWholeLibrary(_ enabled: Bool) {
        guard phase == .selecting else { return }
        importsWholeLibrary = enabled
        if enabled { selectedCollectionKeys = [] }
    }

    func scanSelection() {
        guard phase == .selecting,
              let library = selectedLibrary,
              let serverID else { return }
        guard importsWholeLibrary || !selectedCollectionKeys.isEmpty else { return }
        let selectedKeys = importsWholeLibrary ? [] : selectedCollectionKeys
        retireWork()
        let current = UUID()
        generation = current
        preview = nil
        failureMessage = nil
        scannedItemCount = 0
        phase = .scanning
        workTask = Task { [weak self] in
            guard let self else { return }
            do {
                let allItems = try await fetchAllItems(
                    library: library,
                    serverID: serverID,
                    progress: { count in
                        Task { @MainActor [weak self] in
                            guard let self, generation == current, phase == .scanning else { return }
                            scannedItemCount = count
                        }
                    }
                )
                try Task.checkCancellation()
                let result = try await buildPreview(
                    library: library,
                    serverID: serverID,
                    allItems: allItems,
                    selectedKeys: selectedKeys
                )
                try Task.checkCancellation()
                guard generation == current else { return }
                preview = result
                phase = .preview
            } catch is CancellationError {
                guard generation == current else { return }
                phase = .cancelled
            } catch {
                guard generation == current else { return }
                failureMessage = error.localizedDescription
                phase = .failed
            }
            if generation == current { workTask = nil }
        }
    }

    func backToSelection() {
        guard phase == .preview || phase == .failed || phase == .cancelled else { return }
        retireWork()
        preview = nil
        failureMessage = nil
        phase = .selecting
    }

    func cancel() {
        guard isBusy else { return }
        workTask?.cancel()
        phase = .cancelled
    }

    func dismiss() {
        retireWork()
        generation = UUID()
        phase = .idle
        libraries = []
        collections = []
        selectedCollectionKeys = []
        importsWholeLibrary = true
        selectedLibraryID = nil
        preview = nil
        failureMessage = nil
        serverID = nil
        existingPapers = []
    }

    private func fetchAllLibraries(serverID: String) async throws -> [ZoteroServiceLibrary] {
        let result: [ZoteroServiceLibrary] = try await fetchPages { start in
            let payload = try await executor.perform(Self.request(
                kind: .libraries,
                start: start,
                serverID: serverID
            ))
            guard let values = payload.libraries else {
                throw ZoteroImportRemoteError(
                    code: "invalid_response",
                    message: "Zotero 文库列表无效。"
                )
            }
            return (values, payload.totalResults)
        }
        guard Set(result.map(\.stableID)).count == result.count else {
            throw ZoteroImportRemoteError(code: "duplicate_data", message: "Zotero 文库列表包含重复项目。")
        }
        return result
    }

    private func fetchAllCollections(
        library: ZoteroServiceLibrary,
        serverID: String
    ) async throws -> [ZoteroServiceCollection] {
        let result: [ZoteroServiceCollection] = try await fetchPages { start in
            let payload = try await executor.perform(Self.request(
                kind: .collections,
                library: library,
                start: start,
                serverID: serverID
            ))
            guard let values = payload.collections else {
                throw ZoteroImportRemoteError(
                    code: "invalid_response",
                    message: "Zotero 文献集列表无效。"
                )
            }
            return (values, payload.totalResults)
        }
        guard Set(result.map(\.key)).count == result.count else {
            throw ZoteroImportRemoteError(code: "duplicate_data", message: "Zotero 文献集列表包含重复项目。")
        }
        let keys = Set(result.map(\.key))
        for collection in result {
            if let parent = collection.parentCollection, !keys.contains(parent) {
                throw ZoteroImportRemoteError(
                    code: "invalid_hierarchy",
                    message: "Zotero 文献集层级缺少父节点。"
                )
            }
            var visited: Set<String> = [collection.key]
            var parent = collection.parentCollection
            while let current = parent {
                guard visited.insert(current).inserted else {
                    throw ZoteroImportRemoteError(
                        code: "invalid_hierarchy",
                        message: "Zotero 文献集层级包含循环。"
                    )
                }
                parent = result.first(where: { $0.key == current })?.parentCollection
            }
        }
        return result
    }

    private func fetchAllItems(
        library: ZoteroServiceLibrary,
        serverID: String,
        progress: @escaping @Sendable (Int) -> Void
    ) async throws -> [ZoteroServiceItem] {
        var count = 0
        let result: [ZoteroServiceItem] = try await fetchPages { start in
            let payload = try await executor.perform(Self.request(
                kind: .items,
                library: library,
                start: start,
                serverID: serverID
            ))
            guard let values = payload.items else {
                throw ZoteroImportRemoteError(
                    code: "invalid_response",
                    message: "Zotero 文献列表无效。"
                )
            }
            count += values.count
            progress(count)
            return (values, payload.totalResults)
        }
        guard Set(result.map(\.key)).count == result.count else {
            throw ZoteroImportRemoteError(code: "duplicate_data", message: "Zotero 文献列表包含重复项目。")
        }
        return result
    }

    private func fetchPages<Element: Sendable>(
        page: (Int) async throws -> ([Element], Int?)
    ) async throws -> [Element] {
        var result: [Element] = []
        var start = 0
        var expectedTotal: Int?
        for _ in 0..<Self.maximumPageCount {
            try Task.checkCancellation()
            let (values, total) = try await page(start)
            result.append(contentsOf: values)
            if let total {
                guard expectedTotal == nil || expectedTotal == total,
                      result.count <= total else {
                    throw ZoteroImportRemoteError(
                        code: "invalid_pagination",
                        message: "Zotero 分页响应前后不一致。"
                    )
                }
                expectedTotal = total
                if result.count == total { return result }
            }
            if values.count < Self.pageSize {
                if let expectedTotal, result.count < expectedTotal {
                    throw ZoteroImportRemoteError(
                        code: "invalid_pagination",
                        message: "Zotero 分页响应前后不一致。"
                    )
                }
                return result
            }
            start += values.count
        }
        throw ZoteroImportRemoteError(
            code: "page_limit",
            message: "Zotero 文库超过首版支持的分页上限。"
        )
    }

    private func buildPreview(
        library: ZoteroServiceLibrary,
        serverID: String,
        allItems: [ZoteroServiceItem],
        selectedKeys: Set<String>
    ) async throws -> ZoteroMigrationPreview {
        let includedCollectionKeys = selectedKeys.isEmpty ? nil : selectedKeys
        func scopedCollectionKeys(_ keys: [String]) -> [String] {
            guard let includedCollectionKeys else { return keys }
            return keys.filter(includedCollectionKeys.contains)
        }
        let unsupportedItemTypes: Set<String> = ["note", "annotation"]
        let parents = allItems.filter {
            $0.itemType != "attachment" && !unsupportedItemTypes.contains($0.itemType)
        }.filter { item in
            guard let includedCollectionKeys else { return true }
            return !Set(item.collections).isDisjoint(with: includedCollectionKeys)
        }
        let parentByKey = Dictionary(uniqueKeysWithValues: parents.map { ($0.key, $0) })
        let allAttachments = allItems.filter { $0.itemType == "attachment" }
        let unsupportedItems = allItems.filter { unsupportedItemTypes.contains($0.itemType) }.filter { item in
            if let parent = item.parentItem { return parentByKey[parent] != nil }
            guard let includedCollectionKeys else { return true }
            return !Set(item.collections).isDisjoint(with: includedCollectionKeys)
        }
        let scopedAttachments = allAttachments.filter { attachment in
            if let parent = attachment.parentItem { return parentByKey[parent] != nil }
            guard let includedCollectionKeys else { return true }
            return !Set(attachment.collections).isDisjoint(with: includedCollectionKeys)
        }

        let pdfAttachments = scopedAttachments.filter {
            $0.contentType?.lowercased() == "application/pdf"
        }
        let allowedLinkModes: Set<String> = ["imported_file", "imported_url", "linked_file"]
        let eligibleAttachments = pdfAttachments.filter { attachment in
            guard let mode = attachment.linkMode else { return false }
            return allowedLinkModes.contains(mode)
        }
        let unsupportedCount = pdfAttachments.count - eligibleAttachments.count
        let libraryIdentity = ZoteroLibraryIdentity(type: library.type, id: library.id)
        let collectionDescriptors = collections.map { collection in
            ZoteroCollectionDescriptor(
                source: .zoteroCollection(
                    library: libraryIdentity,
                    collectionKey: collection.key,
                    serverID: serverID
                ),
                name: collection.name,
                parentSource: collection.parentCollection.map {
                    .zoteroCollection(
                        library: libraryIdentity,
                        collectionKey: $0,
                        serverID: serverID
                    )
                }
            )
        }
        let collectionNameByKey = Dictionary(uniqueKeysWithValues: collections.map { ($0.key, $0.name) })

        var attachmentsByParent: [String?: [ZoteroAttachmentDescriptor]] = [:]
        var rowSeed: [(attachment: ZoteroServiceItem, fileName: String, parent: ZoteroServiceItem?)] = []
        var unavailableCount = 0
        for attachment in eligibleAttachments {
            try Task.checkCancellation()
            do {
                let payload = try await executor.perform(Self.request(
                    kind: .attachmentURL,
                    library: library,
                    itemKey: attachment.key,
                    serverID: serverID
                ))
                guard let rawURL = payload.attachmentURL,
                      let fileURL = URL(string: rawURL),
                      fileURL.isFileURL else {
                    throw ZoteroImportRemoteError(
                        code: "invalid_response",
                        message: "Zotero 附件地址无效。"
                    )
                }
                let fileName = normalized(attachment.filename)
                    ?? normalized(fileURL.lastPathComponent)
                    ?? "\(attachment.key).pdf"
                let parent = attachment.parentItem.flatMap { parentByKey[$0] }
                let descriptor = ZoteroAttachmentDescriptor(
                    source: .zoteroAttachment(
                        library: libraryIdentity,
                        parentItemKey: attachment.parentItem,
                        attachmentKey: attachment.key,
                        serverID: serverID
                    ),
                    identity: nil,
                    originalFileName: fileName,
                    label: normalized(attachment.title),
                    propertyMetadata: nil,
                    fingerprint: nil
                )
                attachmentsByParent[attachment.parentItem, default: []].append(descriptor)
                rowSeed.append((attachment, fileName, parent))
            } catch let error as ZoteroImportRemoteError where shouldSkipAttachment(error) {
                unavailableCount += 1
            }
        }

        var descriptors: [ZoteroItemDescriptor] = parents.map { parent in
            ZoteroItemDescriptor(
                metadata: metadataDescriptor(parent),
                collectionSources: scopedCollectionKeys(parent.collections).map {
                    .zoteroCollection(
                        library: libraryIdentity,
                        collectionKey: $0,
                        serverID: serverID
                    )
                },
                attachments: attachmentsByParent[parent.key] ?? []
            )
        }
        for seed in rowSeed where seed.attachment.parentItem == nil {
            let source = ImportSourceIdentity.zoteroAttachment(
                library: libraryIdentity,
                parentItemKey: nil,
                attachmentKey: seed.attachment.key,
                serverID: serverID
            )
            guard let descriptor = attachmentsByParent[nil]?.first(where: { $0.source == source }) else {
                continue
            }
            descriptors.append(ZoteroItemDescriptor(
                metadata: nil,
                collectionSources: scopedCollectionKeys(seed.attachment.collections).map {
                    .zoteroCollection(
                        library: libraryIdentity,
                        collectionKey: $0,
                        serverID: serverID
                    )
                },
                attachments: [descriptor]
            ))
        }
        let plan = ZoteroImportPlanner.plan(
            collections: collectionDescriptors,
            items: descriptors,
            existingPapers: existingPapers
        )
        let dispositionBySource = Dictionary(
            uniqueKeysWithValues: plan.papers.map { ($0.source, $0.disposition) }
        )
        let rows = rowSeed.compactMap { seed -> ZoteroMigrationPreview.PaperRow? in
            let source = ImportSourceIdentity.zoteroAttachment(
                library: libraryIdentity,
                parentItemKey: seed.attachment.parentItem,
                attachmentKey: seed.attachment.key,
                serverID: serverID
            )
            guard let disposition = dispositionBySource[source] else { return nil }
            let title = normalized(seed.parent?.title)
                ?? normalized(seed.attachment.title)
                ?? (seed.fileName as NSString).deletingPathExtension
            let collectionNames = scopedCollectionKeys(
                seed.parent?.collections ?? seed.attachment.collections
            )
                .compactMap { collectionNameByKey[$0] }
            return ZoteroMigrationPreview.PaperRow(
                attachmentKey: seed.attachment.key,
                title: title,
                fileName: seed.fileName,
                collectionNames: collectionNames,
                disposition: disposition
            )
        }
        let parentsWithPDF = Set(rowSeed.compactMap { $0.attachment.parentItem })
        let scopedItems = parents + scopedAttachments + unsupportedItems
        return ZoteroMigrationPreview(
            library: library,
            scannedItemCount: allItems.count,
            parentItemCount: parents.count,
            pdfAttachmentCount: rows.count,
            unavailableAttachmentCount: unavailableCount,
            unsupportedAttachmentCount: unsupportedCount,
            nonPDFAttachmentCount: scopedAttachments.count - pdfAttachments.count,
            unsupportedItemCount: unsupportedItems.count,
            ignoredTagCount: scopedItems.reduce(0) { $0 + $1.ignoredTagCount },
            ignoredRelationCount: scopedItems.reduce(0) { $0 + $1.ignoredRelationCount },
            parentItemsWithoutPDFCount: parents.filter { !parentsWithPDF.contains($0.key) }.count,
            plannedCollectionCount: plan.collections.count,
            rows: rows,
            plan: plan
        )
    }

    private func descendantKeys(of key: String) -> Set<String> {
        let children = Dictionary(grouping: collections, by: \.parentCollection)
        var result: Set<String> = []
        var pending = [key]
        while let current = pending.popLast() {
            guard result.insert(current).inserted else { continue }
            pending.append(contentsOf: (children[current] ?? []).map(\.key))
        }
        return result
    }

    private func metadataDescriptor(_ item: ZoteroServiceItem) -> ZoteroItemMetadataDescriptor {
        var identifiers: [BibliographicIdentifier] = []
        if let value = normalized(item.DOI) {
            identifiers.append(BibliographicIdentifier(kind: .doi, displayValue: value))
        }
        if let value = normalized(item.ISBN) {
            identifiers.append(BibliographicIdentifier(kind: .isbn, displayValue: value))
        }
        if let value = normalized(item.ISSN) {
            identifiers.append(BibliographicIdentifier(kind: .issn, displayValue: value))
        }
        if let value = arXivIdentifier(from: item.extra) {
            identifiers.append(BibliographicIdentifier(kind: .arXiv, displayValue: value))
        }
        return ZoteroItemMetadataDescriptor(
            itemType: item.itemType,
            title: item.title,
            creators: item.creators.map {
                ZoteroCreatorDescriptor(
                    creatorType: $0.creatorType,
                    firstName: $0.firstName,
                    lastName: $0.lastName,
                    name: $0.name
                )
            },
            dateText: item.date,
            parsedYear: item.parsedYear,
            containerTitle: normalized(item.publicationTitle)
                ?? normalized(item.conferenceName)
                ?? normalized(item.proceedingsTitle),
            volume: item.volume,
            issue: item.issue,
            pages: item.pages,
            identifiers: identifiers,
            publisher: item.publisher,
            place: item.place,
            edition: item.edition,
            url: item.url,
            language: item.language,
            abstractText: item.abstractNote
        )
    }

    private func retireWork() {
        workTask?.cancel()
        workTask = nil
    }

    private static func request(
        kind: ZoteroImportRequestKind,
        library: ZoteroServiceLibrary? = nil,
        itemKey: String? = nil,
        start: Int = 0,
        serverID: String? = nil
    ) -> ZoteroImportXPCRequest {
        ZoteroImportXPCRequest(
            requestID: UUID().uuidString,
            kind: kind,
            libraryType: library?.type,
            libraryID: library?.id ?? 0,
            itemKey: itemKey,
            startIndex: start,
            limit: pageSize,
            serverID: serverID,
            testingOrigin: testingOrigin
        )
    }

    private static var testingOrigin: String? {
#if DEBUG
        ProcessInfo.processInfo.environment["LURUME_ZOTERO_FAKE_SERVER"]
#else
        nil
#endif
    }

    private func normalized(_ value: String?) -> String? {
        guard let result = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !result.isEmpty else { return nil }
        return result
    }

    private func arXivIdentifier(from extra: String?) -> String? {
        guard let extra else { return nil }
        for line in extra.split(whereSeparator: \.isNewline) {
            let components = line.split(separator: ":", maxSplits: 1).map(String.init)
            guard components.count == 2 else { continue }
            let label = components[0]
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            guard label == "arxiv" || label == "arxiv id" else { continue }
            let value = components[1].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, value.utf8.count <= 128 else { continue }
            return value
        }
        return nil
    }

    private func shouldSkipAttachment(_ error: ZoteroImportRemoteError) -> Bool {
        if error.code == "invalid_response" { return true }
        guard error.code.hasPrefix("http_"),
              let status = Int(error.code.dropFirst("http_".count)) else { return false }
        return status == 400 || status == 404 || status == 410 || (500...599).contains(status)
    }
}
