# P8 检查点一：模型、迁移与纯导入规划器

日期：2026-08-31

结论：**通过。按计划停在检查点一，不进入嵌套文献集界面、真实目录扫描、Zotero 网络或复制事务。**

## 本检查点完成内容

- 文献库 schema 升级到 v5；v1、v2、v3、v4 都保留独立 legacy 解码结构并显式迁移，未知或
  不一致的快照继续拒绝覆盖。
- `PaperRecord` 只持久化一份 `BibliographicMetadata.title`。现有 `title` 是非 Codable 转发
  访问器；手动清空会保存为空并记录覆盖，展示层使用文件名回退，不会重新制造第二份标题。
- 通用书目模型覆盖条目类型、结构化创作者及稳定角色字符串、来源日期与规范化年份、容器、
  卷期页、类型化标识符、出版社、出版地、版本、URL、语言和摘要。
- legacy 作者字符串迁移为单个 literal author，不按逗号猜测姓名；旧 `authors/year` 手动标记
  显式映射到 v5 的 `creators/issuedDate` 原子字段标记。
- 每条文献继续对应一个 PDF，并新增附件标签、SHA-256/字节数/修改时间证据、去重排序的导入
  来源数组，以及最近一次成功导入元数据快照。
- 文件夹来源只保存根目录文件身份与相对路径；绝对路径和 `..` 越界片段不能进入持久化快照。
  Zotero 来源只保存文库身份、collection/item/attachment key 和可选 server ID，不含凭据、
  原始 JSON 或 PDF 内容。
- 文献集增加父 ID、来源与组织状态；持久化校验覆盖父节点缺失、自环/多节点循环、同级规范化
  重名、跨父同名、来源合法性与稳定顺序。
- 纯层级算法覆盖后代集合、递归论文去重、移动到自身/后代拒绝，以及递归删除候选。删除候选
  一次性给出完整子树、更新后的论文归属和受影响论文 ID；不删除论文或 PDF。
- 纯去重规则固定为来源 ID → `FileIdentity` → SHA-256 → 新建；同一来源内容变化单独报告，
  只凭标题或书目相似不会合并。
- 纯重导差异规划器按字段报告可应用变化与手动覆盖冲突；手动清空和创作者原子覆盖不会被
  新来源静默复活。
- 文件夹合成树规划器剪除没有有效 PDF 后代的空分支，PDF 只直接归属所在目录；候选标题使用
  可信 PDF 属性，否则回退文件名，作者保持 literal。
- Zotero DTO 规划器保留未知 item/creator type 和无法解析日期的原文；一个父条目的多个 PDF
  规划成多条独立文献，继承父元数据并各自保留附件标签和来源 ID；独立附件走附件/PDF 回退。

## 迁移与模型测试

新增 `P8LibraryModelTests` 与 `P8ImportPlanningTests`，覆盖：

- v4 到 v5 的字段、阅读状态、归属、时间、手动标记与 literal author 迁移；既有 v1–v3 迁移
  测试继续通过；
- v5 JSON 中不存在顶层 `title/authors/year` 副本；兼容访问器只修改结构化元数据；
- 手动空标题持久化与文件名回退展示；
- 缺失父节点、循环、同级重名、跨父同名、递归成员去重、移动循环拒绝和删除候选；
- DOI 已知前缀规范化，不把任意 URL 查询参数误当作 DOI；
- 绝对或逃逸文件夹来源拒绝；
- 来源、文件身份、哈希的固定去重优先级与同来源内容变化；
- 多层合成目录、空分支剪除、标题判废、literal author 和直接归属；
- Zotero 多 PDF、独立 PDF、父元数据优先、未知角色、无效日期原文保留；
- 手动元数据冲突与未锁字段差异应用。

## 自动化结果

最终 Debug 全量回归：

```text
xcodebuild test -project Lurume.xcodeproj -scheme Lurume -destination platform=macOS
198 total: 182 passed, 16 skipped, 0 failed
```

16 项跳过项都需要受控 localhost fixture。专用 runner 随后独立运行，无跳过：

```text
Tests/P7Translation/run-xpc-integration-tests.zsh
17 total: 17 passed, 0 skipped, 0 failed
```

这同时确认 P8 的纯数据改动没有破坏 P7 的内嵌 Translation XPC、流式请求、重定向与超时
边界。

## 明确未进入的范围

- 没有嵌套来源栏、子文献集创建/拖放、递归计数、删除确认或撤销接线；
- 没有扩展元数据编辑界面；
- 没有目录选择器、真实文件枚举、PDF 校验、哈希任务或安全作用域书签创建；
- 没有新增或修改文件 entitlement；
- 没有 Zotero Local API 请求、Zotero XPC、真实 Zotero 数据或 API Key；
- 没有目标目录、暂存复制、事务日志、崩溃恢复或磁盘文件删除；
- 没有开始检查点二。

以上内容属于后续检查点。检查点一验收前不继续实现。
