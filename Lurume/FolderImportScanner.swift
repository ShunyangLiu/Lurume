import CryptoKit
import Foundation

enum FolderImportError: LocalizedError, Equatable, Sendable {
    case invalidRoot
    case tooManyEntries(limit: Int)
    case libraryChanged
    case noImportablePDFs
    case rootBookmarkUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidRoot:
            "选择的来源不是可安全扫描的普通文件夹。"
        case let .tooManyEntries(limit):
            "文件夹项目数超过安全上限（\(limit)）。"
        case .libraryChanged:
            "预览期间文献库已发生变化，请重新扫描后再确认。"
        case .noImportablePDFs:
            "文件夹中没有可导入的 PDF。"
        case .rootBookmarkUnavailable:
            "无法保存所选文件夹的只读重导授权。"
        }
    }
}

enum FolderScanDiagnosticKind: String, Equatable, Sendable {
    case unreadable
    case disappeared
    case invalidPDF
    case changedDuringScan
    case escapedRoot
    case skippedReference
    case metadataUnavailable
    case bookmarkUnavailable

    var title: String {
        switch self {
        case .unreadable: "无法读取"
        case .disappeared: "扫描期间消失"
        case .invalidPDF: "不是有效 PDF"
        case .changedDuringScan: "扫描期间发生变化"
        case .escapedRoot: "越过授权根目录"
        case .skippedReference: "已跳过引用或 package"
        case .metadataUnavailable: "PDF 属性不可用"
        case .bookmarkUnavailable: "无法创建只读文件授权"
        }
    }
}

struct FolderScanDiagnostic: Identifiable, Equatable, Sendable {
    var relativePath: String
    var kind: FolderScanDiagnosticKind
    var detail: String?

    var id: String {
        "\(kind.rawValue)|\(relativePath)|\(detail ?? "")"
    }
}

struct FolderScanProgress: Equatable, Sendable {
    var discoveredPDFCount: Int
    var processedPDFCount: Int
    var validPDFCount: Int
}

struct ScannedFolderPDF: Equatable, Sendable {
    var url: URL
    var relativePath: String
    var descriptor: FolderPDFDescriptor
}

struct FolderScanResult: Equatable, Sendable {
    var rootURL: URL
    var root: FolderDirectoryDescriptor
    var files: [ScannedFolderPDF]
    var diagnostics: [FolderScanDiagnostic]
    var unsupportedFileCount: Int

    var validByteCount: Int64 {
        files.reduce(into: 0) { total, file in
            total += file.descriptor.fingerprint?.byteCount ?? 0
        }
    }

    var fileBySource: [ImportSourceIdentity: ScannedFolderPDF] {
        Dictionary(uniqueKeysWithValues: files.map { ($0.descriptor.source, $0) })
    }
}

struct FolderVerifiedFile: Equatable, Sendable {
    var identity: FileIdentity
    var fingerprint: PDFContentFingerprint
    var bookmarkData: Data?
}

struct ScannedStandalonePDF: Equatable, Sendable {
    var url: URL
    var identity: FileIdentity
    var originalFileName: String
    var metadata: BibliographicMetadata
    var fingerprint: PDFContentFingerprint
    var bookmarkData: Data
}

enum StandalonePDFScanError: LocalizedError, Equatable, Sendable {
    case invalidFile(name: String, reason: String?)

    var errorDescription: String? {
        switch self {
        case let .invalidFile(name, reason):
            if let reason, !reason.isEmpty {
                "“\(name)”无法导入：\(reason)"
            } else {
                "“\(name)”不是可导入的 PDF。"
            }
        }
    }
}

enum FolderFileVerificationError: LocalizedError, Equatable, Sendable {
    case changedAfterPreview
    case bookmarkUnavailable

    var errorDescription: String? {
        switch self {
        case .changedAfterPreview: "PDF 在预览后发生了变化。"
        case .bookmarkUnavailable: "无法创建 PDF 的只读文件授权。"
        }
    }
}

protocol FolderImportScanning: Sendable {
    func scan(
        rootURL: URL,
        progress: @escaping @Sendable (FolderScanProgress) -> Void
    ) async throws -> FolderScanResult
}

struct FolderImportScanner: FolderImportScanning, Sendable {
    static let defaultMaximumEntryCount = 100_000
    static let defaultMaximumConcurrentFiles = 4
    static let defaultBufferSize = 1_048_576

    private let metadataReader: any PaperMetadataReading
    private let maximumEntryCount: Int
    private let maximumConcurrentFiles: Int
    private let bufferSize: Int

    init(
        metadataReader: any PaperMetadataReading = SystemPaperMetadataReader(),
        maximumEntryCount: Int = defaultMaximumEntryCount,
        maximumConcurrentFiles: Int = defaultMaximumConcurrentFiles,
        bufferSize: Int = defaultBufferSize
    ) {
        self.metadataReader = metadataReader
        self.maximumEntryCount = max(1, maximumEntryCount)
        self.maximumConcurrentFiles = max(1, maximumConcurrentFiles)
        self.bufferSize = max(4_096, bufferSize)
    }

    func scan(
        rootURL: URL,
        progress: @escaping @Sendable (FolderScanProgress) -> Void
    ) async throws -> FolderScanResult {
        let enumeration = try FolderImportScanner.enumerate(
            rootURL: rootURL,
            maximumEntryCount: maximumEntryCount
        )
        try Task.checkCancellation()

        progress(FolderScanProgress(
            discoveredPDFCount: enumeration.pdfs.count,
            processedPDFCount: 0,
            validPDFCount: 0
        ))
        var nextIndex = 0
        var processedCount = 0
        var validCount = 0
        var processed: [ProcessedFile] = []
        processed.reserveCapacity(enumeration.pdfs.count)

        try await withThrowingTaskGroup(of: ProcessedFile.self) { group in
            func addNext() {
                guard nextIndex < enumeration.pdfs.count else { return }
                let candidate = enumeration.pdfs[nextIndex]
                nextIndex += 1
                group.addTask {
                    try await FolderImportScanner.process(
                        candidate,
                        metadataReader: metadataReader,
                        bufferSize: bufferSize
                    )
                }
            }

            for _ in 0..<min(maximumConcurrentFiles, enumeration.pdfs.count) {
                addNext()
            }
            while let item = try await group.next() {
                processed.append(item)
                processedCount += 1
                if item.file != nil { validCount += 1 }
                progress(FolderScanProgress(
                    discoveredPDFCount: enumeration.pdfs.count,
                    processedPDFCount: processedCount,
                    validPDFCount: validCount
                ))
                addNext()
            }
        }
        try Task.checkCancellation()

        let validFiles = processed.compactMap(\.file).map { file -> ScannedFolderPDF in
            var file = file
            file.descriptor.source = .folder(FolderImportSource(
                rootVolumeUUID: enumeration.rootIdentity.volumeUUID,
                rootDocumentIdentifier: enumeration.rootIdentity.documentIdentifier,
                relativePath: file.relativePath
            ))
            return file
        }.sorted {
            $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending
        }
        let diagnostics = (enumeration.diagnostics + processed.flatMap(\.diagnostics)).sorted {
            if $0.relativePath != $1.relativePath {
                return $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending
            }
            return $0.kind.rawValue < $1.kind.rawValue
        }
        return FolderScanResult(
            rootURL: enumeration.rootURL,
            root: FolderImportScanner.makeTree(
                rootURL: enumeration.rootURL,
                rootIdentity: enumeration.rootIdentity,
                rootBookmarkData: enumeration.rootBookmarkData,
                files: validFiles
            ),
            files: validFiles,
            diagnostics: diagnostics,
            unsupportedFileCount: enumeration.unsupportedFileCount
        )
    }

    /// 单个/多个 PDF 入口与文件夹导入共享结构校验、流式哈希和元数据优先级。
    /// 所有候选都成功后才返回，调用方可以继续保持整批原子发布语义。
    func scanStandalonePDFs(at urls: [URL]) async throws -> [ScannedStandalonePDF] {
        let pdfURLs = urls.filter { $0.pathExtension.localizedCaseInsensitiveCompare("pdf") == .orderedSame }
        var nextIndex = 0
        var results: [ScannedStandalonePDF] = []
        results.reserveCapacity(pdfURLs.count)

        try await withThrowingTaskGroup(of: ScannedStandalonePDF.self) { group in
            func addNext() {
                guard nextIndex < pdfURLs.count else { return }
                let url = pdfURLs[nextIndex]
                nextIndex += 1
                group.addTask {
                    let didStartAccessing = url.startAccessingSecurityScopedResource()
                    defer {
                        if didStartAccessing { url.stopAccessingSecurityScopedResource() }
                    }
                    let processed = try await FolderImportScanner.process(
                        EnumeratedPDF(url: url.standardizedFileURL, relativePath: url.lastPathComponent),
                        metadataReader: metadataReader,
                        bufferSize: bufferSize
                    )
                    guard let file = processed.file,
                          let fingerprint = file.descriptor.fingerprint else {
                        let diagnostic = processed.diagnostics.first
                        throw StandalonePDFScanError.invalidFile(
                            name: url.lastPathComponent,
                            reason: diagnostic?.detail ?? diagnostic?.kind.title
                        )
                    }
                    let planned = FolderImportPlanner.plan(
                        root: FolderDirectoryDescriptor(
                            source: file.descriptor.source,
                            name: "Standalone",
                            pdfs: [file.descriptor],
                            children: []
                        ),
                        existingPapers: []
                    ).papers[0]
                    return ScannedStandalonePDF(
                        url: url,
                        identity: file.descriptor.identity,
                        originalFileName: file.descriptor.originalFileName,
                        metadata: planned.metadata,
                        fingerprint: fingerprint,
                        bookmarkData: try SecurityScopedFile.makeBookmark(for: url)
                    )
                }
            }

            for _ in 0..<min(maximumConcurrentFiles, pdfURLs.count) { addNext() }
            while let result = try await group.next() {
                results.append(result)
                addNext()
            }
        }
        try Task.checkCancellation()
        return results.sorted {
            $0.originalFileName.localizedStandardCompare($1.originalFileName) == .orderedAscending
        }
    }

    static func verifyFile(
        at url: URL,
        expectedIdentity: FileIdentity,
        expectedFingerprint: PDFContentFingerprint,
        makeBookmark: Bool,
        bufferSize: Int = defaultBufferSize
    ) async throws -> FolderVerifiedFile {
        let start = try observation(for: url)
        let hash = try hashAndValidatePDF(at: url, bufferSize: max(4_096, bufferSize))
        let end = try observation(for: url)
        guard start == end,
              end.identity == expectedIdentity,
              end.byteCount == expectedFingerprint.byteCount,
              end.modificationDate == expectedFingerprint.modificationDate,
              hash.sha256 == expectedFingerprint.sha256,
              hash.byteCount == expectedFingerprint.byteCount else {
            throw FolderFileVerificationError.changedAfterPreview
        }
        let bookmarkData: Data?
        do {
            bookmarkData = makeBookmark ? try SecurityScopedFile.makeBookmark(for: url) : nil
        } catch {
            throw FolderFileVerificationError.bookmarkUnavailable
        }
        return FolderVerifiedFile(
            identity: end.identity,
            fingerprint: PDFContentFingerprint(
                sha256: hash.sha256,
                byteCount: end.byteCount,
                modificationDate: end.modificationDate
            ),
            bookmarkData: bookmarkData
        )
    }

    /// 检查一个已由用户授权根覆盖的 Zotero PDF。调用方仍须先完成授权根后代校验。
    static func inspectAuthorizedPDF(
        at url: URL,
        bufferSize: Int = defaultBufferSize
    ) async throws -> FolderVerifiedFile {
        let start = try observation(for: url)
        let hash = try hashAndValidatePDF(at: url, bufferSize: max(4_096, bufferSize))
        let end = try observation(for: url)
        guard start == end, hash.byteCount == end.byteCount else {
            throw FolderFileVerificationError.changedAfterPreview
        }
        return FolderVerifiedFile(
            identity: end.identity,
            fingerprint: PDFContentFingerprint(
                sha256: hash.sha256,
                byteCount: end.byteCount,
                modificationDate: end.modificationDate
            ),
            bookmarkData: nil
        )
    }
}

private extension FolderImportScanner {
    struct EnumeratedPDF: Sendable {
        var url: URL
        var relativePath: String
    }

    struct EnumerationResult: Sendable {
        var rootURL: URL
        var rootIdentity: FileIdentity
        var rootBookmarkData: Data
        var pdfs: [EnumeratedPDF]
        var diagnostics: [FolderScanDiagnostic]
        var unsupportedFileCount: Int
    }

    struct FileObservation: Equatable, Sendable {
        var identity: FileIdentity
        var byteCount: Int64
        var modificationDate: Date
    }

    struct ProcessedFile: Sendable {
        var file: ScannedFolderPDF?
        var diagnostics: [FolderScanDiagnostic]
    }

    static func enumerate(
        rootURL: URL,
        maximumEntryCount: Int
    ) throws -> EnumerationResult {
        try Task.checkCancellation()
        let selectedRoot = rootURL.standardizedFileURL
        let rootValues = try selectedRoot.resourceValues(forKeys: [
            .isDirectoryKey,
            .isSymbolicLinkKey,
            .isAliasFileKey,
            .isPackageKey,
        ])
        guard rootValues.isDirectory == true,
              rootValues.isSymbolicLink != true,
              rootValues.isAliasFile != true,
              rootValues.isPackage != true else {
            throw FolderImportError.invalidRoot
        }
        let resolvedRoot = selectedRoot.resolvingSymlinksInPath().standardizedFileURL
        let rootIdentity = try FileIdentity(url: resolvedRoot)
        let rootBookmarkData: Data
        do {
            rootBookmarkData = try SecurityScopedFile.makeBookmark(for: selectedRoot)
        } catch {
            throw FolderImportError.rootBookmarkUnavailable
        }
        let resourceKeys: [URLResourceKey] = [
            .isDirectoryKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .isAliasFileKey,
            .isPackageKey,
        ]
        var diagnostics: [FolderScanDiagnostic] = []
        guard let enumerator = FileManager.default.enumerator(
            at: selectedRoot,
            includingPropertiesForKeys: resourceKeys,
            options: [.skipsHiddenFiles],
            errorHandler: { url, error in
                diagnostics.append(FolderScanDiagnostic(
                    relativePath: relativePath(of: url, under: selectedRoot) ?? url.lastPathComponent,
                    kind: FileManager.default.fileExists(atPath: url.path) ? .unreadable : .disappeared,
                    detail: nil
                ))
                return true
            }
        ) else {
            throw FolderImportError.invalidRoot
        }

        var entryCount = 0
        var unsupportedFileCount = 0
        var pdfs: [EnumeratedPDF] = []
        while let item = enumerator.nextObject() as? URL {
            try Task.checkCancellation()
            entryCount += 1
            guard entryCount <= maximumEntryCount else {
                throw FolderImportError.tooManyEntries(limit: maximumEntryCount)
            }
            guard let relativePath = relativePath(of: item, under: selectedRoot) else {
                diagnostics.append(FolderScanDiagnostic(
                    relativePath: item.lastPathComponent,
                    kind: .escapedRoot
                ))
                enumerator.skipDescendants()
                continue
            }
            do {
                let values = try item.resourceValues(forKeys: Set(resourceKeys))
                if values.isSymbolicLink == true
                    || values.isAliasFile == true
                    || values.isPackage == true {
                    diagnostics.append(FolderScanDiagnostic(
                        relativePath: relativePath,
                        kind: .skippedReference
                    ))
                    if values.isDirectory == true { enumerator.skipDescendants() }
                    continue
                }
                let resolved = item.resolvingSymlinksInPath().standardizedFileURL
                guard isDescendant(resolved, of: resolvedRoot) else {
                    diagnostics.append(FolderScanDiagnostic(
                        relativePath: relativePath,
                        kind: .escapedRoot
                    ))
                    if values.isDirectory == true { enumerator.skipDescendants() }
                    continue
                }
                if values.isDirectory == true { continue }
                guard values.isRegularFile == true else { continue }
                guard item.pathExtension.localizedCaseInsensitiveCompare("pdf") == .orderedSame else {
                    unsupportedFileCount += 1
                    continue
                }
                pdfs.append(EnumeratedPDF(url: item.standardizedFileURL, relativePath: relativePath))
            } catch {
                diagnostics.append(FolderScanDiagnostic(
                    relativePath: relativePath,
                    kind: FileManager.default.fileExists(atPath: item.path) ? .unreadable : .disappeared,
                    detail: nil
                ))
            }
        }
        pdfs.sort { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending }
        return EnumerationResult(
            rootURL: selectedRoot,
            rootIdentity: rootIdentity,
            rootBookmarkData: rootBookmarkData,
            pdfs: pdfs,
            diagnostics: diagnostics,
            unsupportedFileCount: unsupportedFileCount
        )
    }

    static func process(
        _ candidate: EnumeratedPDF,
        metadataReader: any PaperMetadataReading,
        bufferSize: Int
    ) async throws -> ProcessedFile {
        try Task.checkCancellation()
        do {
            let start = try observation(for: candidate.url)
            let hash = try hashAndValidatePDF(at: candidate.url, bufferSize: bufferSize)
            let metadata = await metadataReader.metadata(at: candidate.url)
            try Task.checkCancellation()
            let end = try observation(for: candidate.url)
            guard start == end, hash.byteCount == end.byteCount else {
                return ProcessedFile(file: nil, diagnostics: [FolderScanDiagnostic(
                    relativePath: candidate.relativePath,
                    kind: .changedDuringScan
                )])
            }
            let source = ImportSourceIdentity.folder(FolderImportSource(
                rootVolumeUUID: nil,
                rootDocumentIdentifier: nil,
                relativePath: candidate.relativePath
            ))
            let file = ScannedFolderPDF(
                url: candidate.url,
                relativePath: candidate.relativePath,
                descriptor: FolderPDFDescriptor(
                    source: source,
                    identity: end.identity,
                    originalFileName: candidate.url.lastPathComponent,
                    propertyMetadata: metadata,
                    fingerprint: PDFContentFingerprint(
                        sha256: hash.sha256,
                        byteCount: end.byteCount,
                        modificationDate: end.modificationDate
                    )
                )
            )
            return ProcessedFile(
                file: file,
                diagnostics: metadata == nil ? [FolderScanDiagnostic(
                    relativePath: candidate.relativePath,
                    kind: .metadataUnavailable
                )] : []
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as PDFValidationError {
            return ProcessedFile(file: nil, diagnostics: [FolderScanDiagnostic(
                relativePath: candidate.relativePath,
                kind: .invalidPDF,
                detail: error.localizedDescription
            )])
        } catch {
            return ProcessedFile(file: nil, diagnostics: [FolderScanDiagnostic(
                relativePath: candidate.relativePath,
                kind: FileManager.default.fileExists(atPath: candidate.url.path) ? .unreadable : .disappeared,
                detail: nil
            )])
        }
    }

    enum PDFValidationError: LocalizedError {
        case missingHeader
        case missingEOF

        var errorDescription: String? {
            switch self {
            case .missingHeader: "缺少 PDF 文件头。"
            case .missingEOF: "缺少 PDF 结束标记。"
            }
        }
    }

    struct HashResult: Sendable {
        var sha256: String
        var byteCount: Int64
    }

    static func hashAndValidatePDF(at url: URL, bufferSize: Int) throws -> HashResult {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        var byteCount: Int64 = 0
        var prefix = Data()
        var tail = Data()
        while true {
            try Task.checkCancellation()
            guard let data = try handle.read(upToCount: bufferSize), !data.isEmpty else { break }
            byteCount += Int64(data.count)
            hasher.update(data: data)
            if prefix.count < 8 {
                prefix.append(data.prefix(8 - prefix.count))
            }
            tail.append(data)
            if tail.count > bufferSize {
                tail.removeFirst(tail.count - bufferSize)
            }
        }
        guard prefix.starts(with: Data("%PDF-".utf8)) else {
            throw PDFValidationError.missingHeader
        }
        guard tail.range(of: Data("%%EOF".utf8), options: .backwards) != nil else {
            throw PDFValidationError.missingEOF
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return HashResult(sha256: digest, byteCount: byteCount)
    }

    static func observation(for url: URL) throws -> FileObservation {
        // FileManager attributes are fetched afresh. URL resource values may be cached on the
        // URL instance, which would hide a mutation between the scan and verification passes.
        let referenceValues = try url.resourceValues(forKeys: [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .isAliasFileKey,
        ])
        guard referenceValues.isRegularFile == true,
              referenceValues.isSymbolicLink != true,
              referenceValues.isAliasFile != true else {
            throw FolderFileVerificationError.changedAfterPreview
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let fileSize = (attributes[.size] as? NSNumber)?.int64Value,
              let modificationDate = attributes[.modificationDate] as? Date else {
            throw CocoaError(.fileReadUnknown)
        }
        return FileObservation(
            identity: try FileIdentity(url: url),
            byteCount: fileSize,
            modificationDate: modificationDate
        )
    }

    static func makeTree(
        rootURL: URL,
        rootIdentity: FileIdentity,
        rootBookmarkData: Data,
        files: [ScannedFolderPDF]
    ) -> FolderDirectoryDescriptor {
        let source: (String) -> ImportSourceIdentity = { relativePath in
            .folder(FolderImportSource(
                rootVolumeUUID: rootIdentity.volumeUUID,
                rootDocumentIdentifier: rootIdentity.documentIdentifier,
                relativePath: relativePath,
                rootBookmarkData: relativePath.isEmpty ? rootBookmarkData : nil
            ))
        }
        var directoryPaths: Set<String> = [""]
        for file in files {
            var path = (file.relativePath as NSString).deletingLastPathComponent
            if path == "." { path = "" }
            while true {
                directoryPaths.insert(path)
                guard !path.isEmpty else { break }
                let parent = (path as NSString).deletingLastPathComponent
                path = parent == "." ? "" : parent
            }
        }
        func directory(_ relativePath: String) -> FolderDirectoryDescriptor {
            let childPaths = directoryPaths.filter { path in
                guard path != relativePath else { return false }
                let parent = (path as NSString).deletingLastPathComponent
                return (parent == "." ? "" : parent) == relativePath
            }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            let directPDFs = files.filter { file in
                let parent = (file.relativePath as NSString).deletingLastPathComponent
                return (parent == "." ? "" : parent) == relativePath
            }.map(\.descriptor)
            return FolderDirectoryDescriptor(
                source: source(relativePath),
                name: relativePath.isEmpty
                    ? rootURL.lastPathComponent
                    : (relativePath as NSString).lastPathComponent,
                pdfs: directPDFs,
                children: childPaths.map(directory)
            )
        }
        return directory("")
    }

    static func relativePath(of url: URL, under root: URL) -> String? {
        let rootComponents = root.standardizedFileURL.pathComponents
        let components = url.standardizedFileURL.pathComponents
        guard components.count >= rootComponents.count,
              Array(components.prefix(rootComponents.count)) == rootComponents else {
            return nil
        }
        return components.dropFirst(rootComponents.count).joined(separator: "/")
    }

    static func isDescendant(_ url: URL, of root: URL) -> Bool {
        let rootComponents = root.pathComponents
        let components = url.pathComponents
        return components.count >= rootComponents.count
            && Array(components.prefix(rootComponents.count)) == rootComponents
    }
}
