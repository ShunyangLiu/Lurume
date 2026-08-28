enum LibrarySchema: Sendable {
    /// v3：新增三态阅读状态。v1/v2 在载入时自动迁移。
    static let currentVersion = 3
}
