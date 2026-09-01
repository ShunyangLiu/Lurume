# P8 检查点五：复制事务、发布加固与验收

日期：2026-09-01

结论：**检查点五实现、合成验收、Zotero 10.0.1 隔离数据主路径验收与最终清理均已通过，
P8 五个检查点完成。真实验收使用两份无敏感测试 PDF，覆盖 Local API 预览、持久化目录授权、
复制发布、嵌套文献集、主窗口撤销接线和同源重导；迁移过程未向 Zotero 写入，来源 PDF 字节
未被修改。**

## 本检查点完成内容

- 主 App 的文件 entitlement 从 `user-selected.read-only` 替换为
  `user-selected.read-write`；仍无 generic network client、Downloads/home/absolute-path 广泛文件
  权限或 Release 调试权限。Zotero 与 Translation XPC 都没有文件权限。
- Zotero 向导新增来源根和目标目录的系统选择器。根书签只在向导打开时恢复，不在
  普通启动时扫描。API 返回的 `file:` URL 依然是不可信候选：必须是普通文件，不得为
  符号链接或 Finder 替身，解析后仍须位于同卷已授权根内。
- 来源根与目标在两个方向上都不得相等或包含。路径判定会解析符号链接、规范化
  Unicode，并根据所在卷是否大小写敏感选择比较方式。复制开始前还会重新核对目标
  目录类型、解析路径和文件身份。
- 最终预览先在后台逐个打开已授权 PDF，以 1 MiB 有界缓冲计算 SHA-256，并重新执行
  PDF 结构、文件身份、大小与修改时间核对。用户可排除单项、选择变化附件是保留旧版
  还是另存新文献，选择根文献集位置，并对同名文献集明确选择编号新建或合并。
- 重导严格使用“来源 key → FileIdentity → SHA-256”优先级。未变的同源附件不复制；不同
  来源但同哈希的 PDF 复用同一记录并增加来源别名；同源内容变化默认保留现有记录；
  仅元数据相似不合并。手动编辑和手动清空的字段仍优先。

## 复制、发布与崩溃恢复

Zotero PDF 只复制到用户单独授权的目标，布局为“目标/文库名/原附件名.pdf”。文件和文库
名会移除路径语义并限长；重名追加稳定编号。最终文件用同卷 hard link 创建后删除暂存名，
利用 `link(2)` 的已存在目标失败语义保证永不覆盖。

事务顺序为：

1. 先在 Application Support 原子保存日志，再在目标卷创建
   `.lurume-import-staging/<transaction UUID>`；
2. 每个源文件在复制前后各复核一次，暂存副本重新计算 SHA-256；
3. 在日志先写入预定最终相对路径，以不覆盖方式创建最终名，然后以最终 URL 身份回写
   日志并创建每篇论文的只读书签；
4. 所有有效项都准备好后，一次原子保存完整 `LibrarySnapshot`，再发布内存状态；
5. 快照发布前的取消或失败只按日志身份删除本事务文件和本事务创建且仍为空的文库
   目录；快照发布后即使日志清理失败也绝不删除已被快照引用的 PDF。

启动恢复只有三种结果：全部最终文件都能被当前快照以 paper ID + FileIdentity 证明时保留；
零个被引用时按身份回滚；部分可证明时停止自动清理并提示人工检查。日志拒绝绝对路径、
`.` 和 `..`，不保存 API Key、PDF 内容或哈希。整批发布只注册一个撤销动作，撤销不删除
用户目标目录中的副本，界面和 Undo 名称都明示这一点。

## 自动化与性能样本

最终全量回归：

```text
261 total: 238 passed, 23 skipped, 0 failed
```

23 项跳过都是需要受控 localhost fixture 的网络用例。P7 Translation runner 和 P8 Zotero runner
随后独立 exit 0；P8 runner 为 22 项无跳过的 XPC/网络集成用例。P6 非网络发布脚本
正向与反向夹具全部通过。

检查点五及真实验收修复新增 11 项主 App 测试，覆盖双向目录重叠、符号链接、目标根被替换、
源在预览后变化、不覆盖命名、双端哈希、原子持久化、撤销保留副本、回滚、已发布/未发布/
部分可证明恢复、日志路径越界、未变/变化/同哈希重导，以及只被叶子论文间接需要的祖先
文献集发布。合成规划矩阵在当前机器上对 1,000 篇论文、100 个嵌套文献集和每篇两个归属
用时约 0.023 秒；这是内存规划样本，不是真实磁盘复制承诺。

P8 检查点三的真实文件系统 fixture 继续覆盖三层目录和 50 个 PDF，并锁定最大并发数。

## Release 与 DMG 复核

P6 `prepare-release` 现在对 Release App 和挂载 DMG 执行同一组检查：

- 主 App 必须有 sandbox + user-selected read-write，且不得残留 read-only、通用网络或广泛目录权限；
- `XPCServices` 中必须恰好各有一份 Translation XPC 与 Zotero Import XPC；
- 两个 XPC 分别锁定 Bundle ID、`XPC!` 包类型、macOS 15、Universal 架构、严格签名和
  sandbox + network client 最小权限；
- 生产二进制扫描拒绝 P7/P8 固定夹具文本、占位 Key、测试路径和 localhost endpoint。

当前 Universal Release 与临时 HFS+ UDZO DMG 已完成构建、校验、只读挂载和上述全部断言。
样本 App 为 19,292 KiB，其中 Translation XPC 460 KiB、Zotero Import XPC 760 KiB；DMG 为
6,055,527 bytes。这些是本机 ad-hoc Release 样本，不是已签名公开版。本检查点没有创建标签、
GitHub Release 或 appcast。

## Zotero 10.0.1 与真实文件系统验收

用户明确授权使用本机 Zotero 10.0.1 和 `Downloads/papers` 中的无敏感测试 PDF。Zotero 中的
隔离层级为 `gu / Lurume P8 Test / Nested Papers`，两份 PDF 分别位于父级和叶子级。Local API
预览读取 5 个项目，识别 2 个可迁移 PDF、3 个必要文献集、1 个便笺/批注和 6 个标签；界面只把
两份 PDF 列入迁移。

首次真实走查发现并修复了四个自动化未覆盖的问题：SwiftUI sheet 内嵌 `fileImporter` 不显示、
sheet 自己的 `UndoManager` 在关闭后丢失、候选发布只保留叶子归属而漏掉祖先文献集、持久化书签
恢复后丢失原安全作用域 URL。目录选择改用向导直接启动的 `NSOpenPanel`；两个导入向导显式使用
主窗口撤销管理器；发布对直接归属做祖先闭包；书签恢复保留解析得到的访问 URL，同时继续用
规范化解析路径做边界校验。

修复后的真实迁移结果为：新增文献 2、复用文献 0、新增文献集 3、复用文献集 0、失败 0，
复制 7,981,888 bytes。目标文件位于临时空目录下的 `我的文库` 子目录，两份目标 SHA-256 分别为：

```text
Conductor: db4dca59a25206cc94da1b491d082e01bcd849e3756ee164e3cfb8aac6772a6b
Stealing:  eb8697b6ec47c6522d17247359f949426516af8d54263bd8626d1f3e62bcef23
```

它们与两份来源 PDF 逐一相同；来源在文件夹批量导入和 Zotero 复制迁移前后哈希均未变化。
主窗口显示 10 篇文献、完整三层 Zotero 文献集和正确的标题/作者/年份；关闭向导后“撤销”菜单
保持启用。再次生成同一文献集的最终计划得到复制 0、复用 2、预计复制 0 KB。

文件夹原位导入另行实测：整个 `Downloads/papers` 因包含大型工具目录而安全触发 100,000 项硬
上限；缩小到 `Downloads/papers/router` 后成功导入 49 篇 PDF、2 个嵌套文献集，0 失败、9 个
非候选跳过、总计 167,140,692 bytes；重导为新增 0、复用 49。测试记录随后通过界面移除，来源
PDF 哈希保持不变。

用户再次确认后已完成最终清理：Lurume 中本次新增的 2 条记录和 3 个文献集通过主窗口撤销一次
移除，文库恢复为测试前的 8 篇文献及 `adas`、`paper` 两个文献集，持久化文件 SHA-256 恢复为
`40a8aa2a91f3c565624a4cc6aa0f35ddb7882c6b9c64a1e611c74608c653f56b`。Zotero 中只删除了测试
文献集 `Lurume P8 Test` 及其子集，原有 `gu` 保留；两条测试文献移入 Zotero 回收站但未清空，
以保留误操作恢复能力。临时目标目录及其中两份测试副本已删除。

清理后再次计算两份 `Downloads/papers` 来源 PDF 的 SHA-256，仍分别为
`db4dca59a25206cc94da1b491d082e01bcd849e3756ee164e3cfb8aac6772a6b` 和
`eb8697b6ec47c6522d17247359f949426516af8d54263bd8626d1f3e62bcef23`，与验收前一致。版本冲突、
崩溃恢复、多归属和不覆盖既有目标继续由受控自动化覆盖；本次真实数据走查没有故意制造这些
破坏性或故障场景。
