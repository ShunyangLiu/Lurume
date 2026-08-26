# Lurume P0 实现计划

状态：核心实现完成，真实样本验收中  
更新日期：2026-08-26

## 实现目标

按照 [P0 原型规格](P0-prototype.md)实现一个可构建、可运行、可测试的 macOS 15 原生应用。实现沿一条纵向链路推进，每个阶段结束时都必须重新构建并运行相应测试。

## 工程边界

- 一个 macOS App target：`Lurume`；
- 一个单元测试 target：`LurumeTests`；
- Swift 6，最低 macOS 15；
- SwiftUI 应用外壳，AppKit `PDFView` bridge；
- App Sandbox，仅申请用户所选文件的只读访问；
- 不引入运行时第三方依赖；
- P0 不拆分 Swift Package，不创建 iOS target。

## 最小数据模型

### `PaperRecord`

- `id: UUID`：应用内稳定标识；
- `volumeUUID: String?`：文件所在卷标识；
- `documentIdentifier: Int?`：卷内持久文档标识；
- `bookmarkData: Data`：只读安全作用域 bookmark；
- `fallbackPath: String`：不支持持久标识时的判重与恢复提示；
- `displayName: String`：P0 列表标题；
- `dateAdded: Date`；
- `lastOpenedAt: Date?`；
- `lastPageIndex: Int`：从零开始的 PDFKit 页索引。

### `LibrarySnapshot`

- `schemaVersion: Int`，P0 固定为 `1`；
- `papers: [PaperRecord]`；
- `selectedPaperID: UUID?`。

文献库保存到 Application Support 中的 `library.json`。使用 `JSONEncoder`、ISO 8601 日期和原子替换；P0 不实现旧格式迁移。

自动翻译、目标语言等用户偏好保存在 `UserDefaults`，不混入文献库文件。

## 运行时组件

### `LibraryStore`

负责加载、导入、判重、选择、移除、重新定位和保存文献。文件身份优先比较卷 UUID 与文档标识，缺失时比较 bookmark 解析后的标准化 URL。跨卷副本视为新文献。

页面变化只更新内存状态，并通过短防抖写入 JSON；切换文献和窗口关闭时立即刷新。

### `SecurityScopedAccess`

解析 bookmark，并在当前 PDF 使用期间成对调用 `startAccessingSecurityScopedResource()` 与 `stopAccessingSecurityScopedResource()`。书签过期时尝试刷新；失败时把记录标记为需要重新定位。

### `PDFReaderView`

使用 `NSViewRepresentable` 承载 `PDFView`。Coordinator 监听页码和选区通知，把页码、原始选区文字及页索引回传 SwiftUI。搜索结果通过 `PDFDocument.findString` 和 `highlightedSelections` 管理。

### `TranslationController`

持有当前选区、规范化输入、请求代次和检查器状态。新选区或重新发起翻译都会取消在途任务并递增代次；翻译返回时只有当前代次可以更新界面。

根视图通过 `.translationTask` 获得系统 `TranslationSession`。配置固定使用 `source: nil`，目标语言来自设置。语言包许可和进度由系统 sheet 负责。

翻译调用通过小型协议隔离，以便用可控假实现测试成功、失败、取消与乱序返回。

## 实现顺序

1. 创建工程、沙箱权限、应用与测试 target，完成空壳构建。
2. 实现数据模型、JSON 存储与单元测试。
3. 实现导入、文件身份判重、bookmark 恢复、移除和重新定位。
4. 嵌入 PDFKit，实现阅读、搜索、页码回调与恢复。
5. 接入选区事件、原始文本保留与启发式规范化。
6. 实现翻译状态机、系统 TranslationSession、自动翻译设置和 `⇧⌘T`。
7. 增加取消、乱序、防抖、持久化与判重测试。
8. 使用固定 PDF 样本执行 P0 验收并记录性能基线。

## 构建与验证

开发过程中至少运行：

```sh
xcodebuild -project Lurume.xcodeproj -scheme Lurume -configuration Debug build
xcodebuild -project Lurume.xcodeproj -scheme Lurume -configuration Debug test
```

完成前再执行 Release 构建、深度代码签名检查和 P0 规格中的手动验收。系统翻译必须在真实 Mac 上验证，不能以模拟器结果替代。

## 当前验证结果

截至 2026-08-26：

- Debug 与 Release 构建通过，部署目标为 macOS 15；
- Release 产物同时包含 `arm64` 与 `x86_64`；
- 本地签名通过深度严格检查，包含 App Sandbox 与用户所选文件只读权限；
- 19 项单元测试通过，覆盖 JSON 往返、文件身份、文本规范化（空白折叠、中文断行合并与全角缩进）、手动模式、语言资源准备、自动翻译关闭、在途任务重发与旧结果的代次隔离；
- 应用已在真实 Mac 上启动，单窗口与空文献库布局正常；
- 未调用 macOS 26 才提供的 `TranslationSession.cancel()`。

尚未完成的是固定 PDF 样本集的逐项手动验收、系统语言包下载界面验证与性能基线记录。这些项目需要真实文件选择和人工交互，不以自动化测试结果代替。
