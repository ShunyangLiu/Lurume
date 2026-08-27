enum LibrarySchema: Sendable {
    /// v2：新增标题/作者/年份与手动编辑标记。v1 在载入时自动迁移。
    static let currentVersion = 2
}
