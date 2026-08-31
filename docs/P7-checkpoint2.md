# P7 检查点二：设置、钥匙串与安全边界

日期：2026-08-31

结论：**通过。按计划停在检查点二，不把自定义大模型接入 PDF 选区或 TranslationController。**

## 本检查点完成内容

- “设置 → 翻译”新增翻译引擎、Base URL、模型、API Key、流式输出、学术翻译提示词、恢复
  默认、保存配置、删除 Key 和测试连接；设置窗口扩展为可容纳提示词编辑器的尺寸。
- 自定义大模型配置使用草稿：URL、模型、提示词与钥匙串操作全部成功后才发布；验证或
  Keychain 失败时保留上一份成功配置。升级和首次启动仍默认 Apple 系统翻译。
- Base URL、模型、流式选项、提示词、引擎和已确认 origin 存入 UserDefaults；API Key
  只使用稳定 service/account 的 generic password 钥匙串条目，不进入 UserDefaults。
- 空 Key 保存会删除旧钥匙串条目；提供独立删除按钮。Keychain 读写在主线程之外执行，
  错误只显示本地分类文案，不包含 OSStatus、Key 或请求正文。
- Base URL 规范化会去除首尾空白与尾部斜杠、统一 scheme/host 大小写，并固定追加
  `/chat/completions`。粘贴完整端点时先剥除同名后缀，并在界面明确提示。
- 远端地址只允许 HTTPS；HTTP 只允许主机精确为 `localhost`、`127.0.0.1` 或 `::1`。
  用户名、密码、query、fragment、其他 scheme 与非法端口均拒绝。
- 相同 URL 规则同时在主 App 验证器和 Translation XPC 请求构造器执行；重定向只允许
  scheme、host 与有效端口完全相同的 origin，跨 origin 请求在跟随前失败。
- 默认学术提示词按计划落地，保存前去除首尾空白并限制为 4,000 字符；测试请求替换当前
  源/目标语言占位符，原文位置固定为内置英文测试句。
- origin 授权以规范化的 `scheme + host + effective port` 持久化，并提供 loopback/远端两套
  确认文案。它尚未被 PDF 翻译调用；检查点三会在首次发送选区前使用该边界。
- XPC 客户端改为惰性连接：打开 App 或设置窗口不会启动 XPC，只有明确测试连接时才建立。

## 测试连接隐私边界

测试连接使用当前**草稿**配置和流式选项，不自动保存、不自动切换引擎，也不写入翻译缓存。
请求的 user 消息固定为：

```text
This is a connection test from Lurume.
```

它不读取 PDF、选区、论文标题、路径、笔记、历史译文或文献库数据。执行前界面再次确认：

- loopback 目标说明连接本机服务，不使用费用表述；
- 远端目标说明会联网、可能产生少量费用，保留和训练规则由服务方决定。

测试成功展示模型名、完成状态和最多 4,000 字符的返回文字；失败只展示 XPC 生成的安全
错误。受控假服务器只接受固定测试句或检查点一 fixture，不记录请求内容。

## 验证结果

- 配置、持久化、URL、提示词、origin 文案、Keychain 失败回退和固定测试请求单元测试通过。
- OpenAI-compatible 请求边界单元测试通过，包括 XPC 对远端 HTTP、凭据、query、fragment
  和非 HTTP(S) scheme 的二次拒绝。
- 专用 localhost runner 共 14 项：6 项真实内嵌 XPC、8 项网络/超时/重定向测试，全部通过。
- Debug 全量回归 162 项：149 项通过、13 项依赖 localhost fixture 的测试按设计跳过、
  0 项失败；跳过项由专用 runner 执行并通过。
- 主 App 与 Translation XPC 的 Universal Release 构建均为 `x86_64 arm64`，
  `codesign --verify --deep --strict` 通过。
- 主 App Release entitlement 仍只有 sandbox、用户选择文件只读和 Sparkle mach lookup
  例外，**没有** network client。
- Translation XPC Release entitlement 仍只有 sandbox 与 network client，没有文件、相册、
  摄像头、麦克风或其他用户数据权限。
- 无网络权限 Release 探针仍能通过内嵌 XPC 获取 `分块译文`：本次冷启动完成时间约
  65.0 ms，结束后 100 ms 的首次轮询已看不到 XPC 进程。

## 未进入的范围

- 没有从 Keychain 读取真实用户 API Key 联系远端服务；没有真实模型或费用验收。
- 没有把大模型引擎接入自动翻译、`⇧⌘T`、翻译检查器、停止、重试、缓存或手动系统回退。
- 没有发送真实 PDF、真实选区或论文元数据。
- 已确认 origin 的存储与文案已经实现，但尚未弹出选区发送授权；没有确认就发送选区的代码
  路径也尚不存在。
- 没有修改 README 的发布承诺、DMG 或 P6 发布脚本；这些属于检查点四。

以上内容属于后续检查点。检查点二验收前不继续实现。

## 协议依据

- OpenAI Chat Completions：
  <https://developers.openai.com/api/reference/cli/resources/chat/subresources/completions>
- Apple Keychain Services：
  <https://developer.apple.com/documentation/security/keychain-services>
- Apple XPC：<https://developer.apple.com/documentation/xpc>
