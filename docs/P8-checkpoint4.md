# P8 检查点四：Zotero Local API 与专用 XPC

日期：2026-09-01

结论：**实现与合成验收通过。按计划停在检查点四，不请求真实 Zotero 文件权限，不复制或提交
PDF；真实 Zotero 10.0.1 测试文库验收保留到检查点五。**

## 本检查点完成内容

- 新增内嵌 `LurumeZoteroImportService.xpc`，Bundle ID 固定为
  `app.lurume.Lurume.ZoteroImportService`。服务只拥有 App Sandbox 与 outbound network client，
  没有文件、Keychain、network server、Sparkle Mach lookup 或调试 entitlement。
- 主 App 继续没有通用网络权限，仍只有 `user-selected.read-only`；普通启动、设置、文件夹导入
  都不创建 Zotero XPC connection。只有用户明确打开“从 Zotero 迁移…”后才惰性连接，最后一个
  请求结束或取消后立即使 connection 失效。
- 生产 origin 只能是 `http://127.0.0.1:23119`，基础路径固定为 `/api/`。协议只表达 probe、文库、
  文献集、条目、附件 URL 与取消；URL 由服务内部枚举构造，只发 `GET`，不接收任意 URL、方法、
  请求头或正文。
- 跨 scheme、host 或端口重定向在跟随前拒绝；同源重定向最多 3 次。每次非 probe 响应都必须
  返回本次握手的 `Zotero-Server-ID`，实例突变会终止整个预览。首字节、空闲和总请求超时分别
  为 10、15 和 30 秒，非 2xx 在响应头到达时立即失败。
- 单页最多 100 项、最多 1,000 页；`Total-Results` 必须跨页一致。单响应上限 4 MiB、JSON 深度
  12、单字符串 32 KiB、总结果 1,000,000。XPC 只传显式白名单 DTO；未知 JSON、note 正文、
  relations 内容和响应原文不会跨进程。
- `/file/view/url` 的纯文本 `file:` URL 只作为未受信候选传回主 App。XPC 不打开该 URL，不读
  PDF，不验证路径权限，也不持久化绝对路径。
- XPC 接受连接前固定主 App Bundle ID；Developer ID 构建还要求 Apple anchor 与同一 Team ID。
  ad-hoc 开发构建只能固定 Bundle ID，这是本地测试签名的已知局限，不等同于发布签名强度。
- 新迁移向导可选择个人/群组文库、整个文库或多个文献集子树；保留必要祖先和范围内多重归属，
  分页建立统一规划器预览。父条目元数据优先，一个 PDF 附件对应一条 Lurume 候选；DOI、ISBN、
  ISSN、arXiv 和结构化创作者进入 P8 通用模型。
- 预览区分可迁移 PDF、无 PDF 条目、缺失附件、不支持链接方式、非 PDF、便笺/批注、标签与关系，
  只显示文件名和用户可理解的文献集名称。它没有确认复制按钮，也不调用 `LibraryStore` 发布、
  保存或撤销路径。
- `403`、Zotero 未运行、API/schema 无法验证、跨 origin、响应超限、分页变化、Server-ID 突变、
  超时与取消都有稳定本地错误；不回退 SQLite、云 API、自动启动 Zotero 或自动重试。

## 官方兼容基线

实现以 Zotero 官方 Local API v3 契约为准：本机 API 位于 `localhost:23119/api/`、个人文库为
`users/0`、接口只读，`/file/view/url` 返回纯文本 URL，分页沿用 Web API v3 的 `start`/`limit`。
Lurume 将主机进一步固定为数字地址 `127.0.0.1`，避免 DNS 解析。参考：

- <https://www.zotero.org/support/dev/web_api/v3/local_api>
- <https://www.zotero.org/support/dev/web_api/v3/basics>

检查点开始时重新核对了官方发布记录：当前稳定版为 **Zotero 10.0.1（2026-08-24）**：
<https://www.zotero.org/support/changelog>。

当前测试机器没有安装 Zotero，因此没有读取用户日常文库，也没有声称完成真实 10.0.1/schema
验收。自动化 fixture 报告 API v3、合成 schema 42 和合成 Server-ID，只验证协议与安全边界；
检查点五须在用户明确授权的隔离测试文库上记录真实 Zotero 版本、schema、端点、来源/目标哈希
与迁移结果。

## 自动化与构建结果

合成 fixture 只监听随机的数字 loopback 端口，内容为虚构标题、虚构 key 和不存在的 `file:`
路径。检查点四专项无跳过：

```text
Tests/P8Zotero/run-xpc-integration-tests.zsh
22 total: 22 passed, 0 skipped, 0 failed
```

专项覆盖固定端点、请求字段校验、严格 JSON/附件 URL 解码、分页、XPC 启动、403 遮蔽、跨 origin
重定向、Server-ID 突变、取消、惰性 connection、文库/文献集范围、多重归属、元数据映射和只读
预览。最终 Debug 全量回归：

```text
xcodebuild test -project Lurume.xcodeproj -scheme Lurume -destination platform=macOS
250 total: 227 passed, 23 skipped, 0 failed
```

23 项跳过都依赖受控 localhost fixture；P7 Translation 专用 runner 随后独立通过。P6 非联网
发布脚本边界测试通过，新增 plist、entitlement 和脚本语法检查通过。

Debug 应用与 Universal Release 应用均构建通过。Release 中内嵌 Zotero XPC 为 arm64 + x86_64，
Bundle ID 正确；生产二进制扫描未发现测试环境变量、fixture 路径、`localhost` 或外部 HTTPS
origin。主 App entitlement 仍为 read-only 且无 network client；Zotero XPC 只有 sandbox 与
network client。

## 明确未进入的范围

- 没有打开 API 返回的文件 URL，没有选择或保存 Zotero data directory/外部附件根书签；
- 没有把主 App 改为 `user-selected.read-write`，没有目标目录、暂存目录、复制、双端哈希、最终
  命名、事务日志、崩溃恢复或重导提交；
- 没有修改 Zotero、读取 `zotero.sqlite`、连接 zotero.org、使用 API Key 或发送书目到翻译服务；
- 没有把预览候选写入 Lurume 文献库，也没有创建公开版本；
- P6 发布脚本尚未扩展为强制检查第二个内嵌 XPC；约 1,000 篇文献 fixture、真实 Zotero 测试库、
  文件复制性能与双 XPC DMG 验收属于检查点五。

以上边界完成评审前不进入检查点五。
