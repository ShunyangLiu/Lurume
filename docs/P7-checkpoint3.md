# P7 检查点三：翻译体验集成

日期：2026-08-31

结论：**通过。自定义大模型已接入选区翻译体验；按计划停在检查点三，不联系真实远端服务，
不进入发布验收。**

## 本检查点完成内容

- `TranslationController` 从 Apple `TranslationSession.Configuration` 单一路径扩展为统一请求
  状态机，能够区分等待、连接、Apple 一次性翻译、模型流式翻译、语言资源准备、完整成功、
  用户停止、响应中断和无结果失败。
- 自动翻译、检查器按钮和 `⇧⌘T` 都读取同一份引擎与配置快照。Apple 路径仍只通过
  `.translationTask` 运行；自定义模型由控制器读取 Keychain 后启动 Translation XPC，未把
  网络请求伪装成系统翻译会话。
- 大模型请求只发送规范化后的当前选区作为 user 消息。论文标题、ID、路径、页码、整页
  `languageSample`、高亮、笔记和历史译文不进入 XPC DTO。
- 固定源语言会把对应名称写入系统提示词；“自动识别”只写入这一意图，由模型根据当前
  选区判断，不使用整页 PDF 样本。
- 规范化选区使用 Swift `String.count` 限制为最多 12,000 字符。超限时在读取 Keychain 和
  创建 XPC 请求之前失败，不截断、不拆分，也不产生网络请求。
- 首次向新的规范化 origin 发送选区前显示确认。只有明确允许后才读取 Key 并启动请求；
  取消确认时保留选区、展示失败与系统翻译选项，不发送任何请求。确认同时供该 origin 的
  手动与自动翻译使用。

## 流式交互、停止与恢复

- 首个文本 delta 到达前显示“正在连接”；首个 delta 立即显示，后续 delta 以 40 ms 短窗口
  合并发布，减少每个 token 触发 SwiftUI 更新的开销。
- 检查器始终显示结果来源：“系统翻译”或“自定义大模型 · 模型名”。模型请求进行中提供
  “停止”，完成前的文字仍可滚动、选择和复制。
- 用户停止后会取消对应 XPC request ID。已有文字时保留并明确标记“生成已停止，内容可能
  不完整”；尚无文字时直接进入失败，不创建空的部分译文。
- 已有文字后收到失败或取消事件时保留部分译文并标记“响应中断”；首个文字前失败只显示
  清理后的错误。
- 停止、中断和失败后提供“重试”和“使用系统翻译”。重试创建全新 request ID 并替换旧
  内容；系统翻译始终从完整原文开始，只影响当前选区，不修改全局首选引擎。
- 不静默回退、不自动重试，也不自动发起第二次可能计费的请求。系统翻译按钮会先检查当前
  语言组合是否可用或可下载，不支持时保持禁用并说明原因。

## 缓存与迟到事件边界

- Apple 与大模型共享进程内会话缓存，但缓存键明确包含引擎。大模型键包含规范化选区、源
  语言、目标语言、规范化 Base URL、模型和完整提示词。
- API Key、论文信息、原始 PDF 文本和流式开关不进入缓存键。只有收到完整终止事件且译文
  非空时写入缓存；停止、中断、失败和测试连接结果均不缓存。
- 新选区、切换论文、清空、切换引擎或修改 URL、模型、语言、提示词、流式选项时，立即
  取消当前工作并递增 generation。事件同时核对 generation 与 request ID，旧 delta、完成和
  错误都不能覆盖新选区。
- 切换论文会清掉旧论文的选区和译文；普通 PDF 选区暂时消失仍保留检查器上一次内容，延续
  P1 的既有交互。

## 受控本机兼容服务

`Tests/P7Translation/fake_openai_server.py` 新增检查点三控制器 fixture。它只监听
`127.0.0.1`，只接受最小 Chat Completions 字段、包含 Lurume 标识的系统提示词和固定的
规范化选区 `fixture selection only`；论文元数据或额外正文会使请求失败。

端到端测试实际经过：

```text
TranslationController
→ Keychain 接口
→ TranslationXPCClient
→ 签名内嵌 Translation XPC
→ localhost HTTP / SSE
→ delta / completed
→ TranslationController 完整成功状态
```

该测试得到流式结果 `connection ok`，并验证模型来源、无 Apple configuration，以及选区的
空白规范化。没有使用真实 API Key、真实论文或真实远端服务。

## 验证结果

- `TranslationControllerTests` 共 24 项全部通过，其中 12 项覆盖自定义模型 consent、选区
  隐私、长度上限、Keychain 失败、自动翻译、停止/中断、完整缓存、配置与论文切换隔离和
  手动系统回退；原有 12 项 Apple 翻译行为继续通过。
- 专用 localhost runner 共 17 项：7 项真实内嵌 XPC（含设置连接测试和控制器端到端流式
  翻译）、10 项网络/超时/重定向测试，全部通过。
- Debug 全量回归 182 项：166 项通过、16 项依赖 localhost fixture 的测试按设计跳过、
  0 项失败；这些 fixture 测试由专用 runner 执行并通过。
- `git diff --check` 通过；代码以 Swift 6 严格并发检查完成编译。

## 未进入的范围

- 没有读取或保存真实 API Key，没有联系 OpenAI 或其他真实远端服务，也没有产生模型费用。
- 没有执行真实 HTTPS、真实模型质量、401/403/429/5xx、断网和真实跨域重定向的人工验收；
  受控错误分类与重定向测试已通过，这些真实环境验证属于检查点四。
- 没有修改 README 的发布承诺、P6 发布脚本、DMG、版本号或公开发布材料。
- 没有做多套配置、Responses API、厂商专有协议、整页/整篇翻译、自动分段、术语表、问答
  或插件系统。

## 协议依据

- OpenAI Chat Completions：
  <https://developers.openai.com/api/reference/cli/resources/chat/subresources/completions>
- WHATWG Server-Sent Events：
  <https://html.spec.whatwg.org/multipage/server-sent-events.html>
- Apple Translation：<https://developer.apple.com/documentation/translation>
- Apple XPC：<https://developer.apple.com/documentation/xpc>
