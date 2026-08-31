# P7 检查点一：协议、流式解析与 Translation XPC

日期：2026-08-31

结论：**通过。按计划停在检查点一，不进入设置、Keychain、真实 API 或翻译界面接入。**

## 本检查点完成内容

- 新增签名内嵌的 `LurumeTranslationService.xpc`，以请求 ID、`NSSecureCoding` 请求对象和
  delta / completed / failed / cancelled 回调事件与宿主通信。
- 主 App 只编译共享 XPC 消息定义，不包含网络实现；Chat Completions 构造、URLSession、
  JSON/SSE 解析和超时状态全部位于 Translation XPC。
- 请求体固定为最小公共子集：`model`、system/user 两条 `messages`、`stream`；空 API Key
  完全不发送 Authorization，流式与非流式 `Accept` 分别固定。
- 支持非流式 JSON 与增量 SSE，覆盖 LF/CRLF、任意网络分块、跨块帧、注释心跳、空
  `data:`、`finish_reason`、`[DONE]`、提前断流和非文本响应。
- 固定生产超时为首个合法响应帧 30 秒、流式空闲 90 秒、非流式整体 120 秒；注释、空
  心跳和只有 role 的帧不能让请求永久悬挂。
- 单个完整 SSE 帧和未终止缓冲均限制为 1 MiB；即使同一网络块前部已有完整小帧，后部
  超限的未终止帧也会立即失败并释放缓冲。
- 客户端取消会取消对应 URLSessionTask 并返回 request-scoped cancelled 事件；连接失效会
  取消该连接的全部活动请求。
- 同 origin 重定向可继续；跨 scheme、host 或有效端口的重定向被拒绝。HTTP 错误正文不
  跨 XPC，只返回本地生成的状态分类文案，避免服务端回显原文或 Key。

## 受控假服务器

`Tests/P7Translation/fake_openai_server.py` 只监听 `127.0.0.1`，只接受检查点一固定的最小
请求和占位文本。fixture 覆盖：

- 任意分块的标准 SSE 与 `[DONE]`；
- 非流式 JSON；
- 429；
- 首个 delta 后等待取消；
- 提前 EOF；
- 纯注释心跳、文本后纯心跳、role-only 后纯心跳；
- 非流式延迟；
- 超过 1 MiB 的未终止 SSE 帧。

专用 runner 的 11 项测试全部通过：5 项真实内嵌 XPC 测试和 6 项短策略网络/超时测试。
短策略只注入测试进程；生产常量仍由单元测试锁定为 30/90/120 秒。

```text
Tests/P7Translation/run-xpc-integration-tests.zsh
TranslationXPCIntegrationTests: 5 passed
P7TranslationNetworkOperationTests: 6 passed
```

核心协议/解析器另有 11 项无网络单元测试，覆盖最小请求字段、安全编码、非流式响应、
逐字节 SSE 分块、心跳、提前结束和两种 1 MiB 缓冲边界。

## 回归、Release、签名与权限

- Debug 最终全量回归共 144 项：134 项通过、10 项依赖 localhost fixture 的测试按设计
  跳过、0 项失败；这些 10 项连同额外的 XPC ping 均由专用 runner 执行并通过。
- 主 App Universal Release 构建通过：`x86_64 arm64`。
- Translation XPC Universal Release 构建通过：`x86_64 arm64`。
- `codesign --verify --deep --strict` 对主 App 和 Release 探针均通过。
- 主 App Release entitlement 保持：sandbox、用户选择文件只读、Sparkle 两个 mach lookup
  例外；**没有** `com.apple.security.network.client`。
- Translation XPC Release entitlement 只有 sandbox 与
  `com.apple.security.network.client`；没有文件、相册、摄像头、麦克风或用户数据权限。
- Release 探针本身只有 sandbox、没有网络权限，仍成功通过内嵌 Release XPC 从 localhost
  流式取得 `分块译文`，证明网络能力没有落回宿主进程。

最后一次 Release 可行性探针结果：

```json
{"coldStartMilliseconds":11.263792,"terminal":"completed","text":"分块译文"}
```

探针退出后 100 ms 的首次轮询已经看不到 Translation XPC 进程。该数字是当前机器上的单次
可行性测量，不作为产品性能承诺；它足以确认检查点一不存在常驻空闲进程或明显的首次启动
阻塞。

## 未进入的范围

- 没有设置页、引擎切换、单套配置保存或恢复默认；
- 没有 Keychain 读写，也没有真实 API Key；
- 没有 Base URL 编辑/规范化 UI、origin 隐私确认或“测试连接”按钮；
- 没有把 XPC 接入 `TranslationController`、自动翻译、手动快捷键、检查器流式状态或缓存；
- 没有联系任何远端模型服务，也没有发送真实 PDF、真实选区或论文元数据。

以上内容属于后续检查点。检查点一验收前不继续实现。

## 协议依据

- OpenAI Chat Completions：
  <https://developers.openai.com/api/reference/cli/resources/chat/subresources/completions>
- WHATWG Server-Sent Events：
  <https://html.spec.whatwg.org/multipage/server-sent-events.html>
- Apple XPC：<https://developer.apple.com/documentation/xpc>
- Apple network client entitlement：
  <https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.network.client>
