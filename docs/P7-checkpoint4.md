# P7 检查点四：发布与真实远端验收

日期：2026-08-31

结论：**本地发布加固与受控 Release 验证已经完成；用户配置的真实 HTTPS 服务已通过流式模式完成、非流式完成和 401 分类，但尚缺可控的 429、5xx、断网、跨 origin 重定向以及可稳定操作的真实停止窗口。因此 P7 暂不宣称最终通过，也不准备公开版本。**

## 已完成的发布边界

- P6 `prepare-release` 现在会在构建产物和挂载后的 DMG 中分别验证
  `Contents/XPCServices/LurumeTranslationService.xpc`：路径与结构、严格签名、唯一固定
  Bundle ID、`XPC!` 包类型、macOS 15 最低版本以及 `arm64 / x86_64` 架构。
- Translation XPC 必须同时具有 App Sandbox 与 outbound network client；文件、Keychain、
  network server、Sparkle Mach lookup、设备、个人信息和 `get-task-allow` entitlement 会使发布
  预检失败。主 App 仍必须没有通用 network client entitlement。
- 生产可执行文件若包含检查点 fixture 的固定选区、固定译文、占位 API Key 或固定本机端点，
  发布预检会失败。发布脚本不会读取翻译钥匙串，也不会联系任何翻译 API。
- Release 探针的 NSXPC 错误回调改为线程安全状态记录，避免 Swift 6 Release 模式在 XPC
  回调队列触发 executor 断言，连接失败现在会给出真实诊断。
- App 侧 Translation XPC 客户端在最后一个请求完成、失败、取消或连接中断后主动失效空闲
  connection；并发请求仍共享连接，直到最后一个 handler 结束。两个端到端测试锁定设置连接
  测试和真实控制器请求结束后不再持有 connection。

## 连接方校验复核

Translation XPC 在导出任何方法前通过 `NSXPCConnection.setCodeSigningRequirement` 校验系统
提供的真实对端凭据。Developer ID 或开发证书构建要求预期 Bundle ID、Apple generic anchor
和与服务相同的 Team ID；当前公开发行仍使用 ad-hoc 签名，只能锁定预期 Bundle ID。

本检查点试验过按连接 PID 反查外层 App 可执行文件路径的第二层校验。它在 Debug 可行，但
沙盒化、没有 `get-task-allow` 的 Release 中无法可靠取得对端静态代码并错误拒绝合法客户端，
因此没有保留。不会为了该检查扩大 XPC entitlement。剩余风险由以下边界降低：XPC 是 App
内嵌按需服务、不读取 Keychain 或文件，API Key 只随单次请求在内存中短暂经过；未来采用
Developer ID 后，现有 requirement 会自动增加 Team ID 与 Apple anchor 条件。

## 本地验证与性能样本

环境：MacBook Pro（Apple M4 Pro，24 GB）、macOS 15.7.7、Xcode 26.3；源码基线
`94f278b` 加本检查点未提交改动。所有本地兼容服务只监听 `127.0.0.1`，不使用真实 Key 或
论文文字。

| 项目 | 结果 |
| --- | --- |
| Release XPC 首次冷启动 ping | 45.75 ms |
| 随后三次新进程启动 ping | 13.57 / 14.60 / 15.67 ms；中位数 14.60 ms |
| 流式固定选区 | 完成，结果为固定 fixture `分块译文` |
| 请求结束后 XPC 回收 | 100 ms 内观察到 |
| Release App / Translation XPC 体积 | 12,128 KiB / 420 KiB；v0.0.4 App 为 10,480 KiB，App 增加 1,648 KiB（15.7%） |
| 本地 DMG 体积 | 3,594,624 bytes；v0.0.4 为 3,112,247 bytes，增加 482,377 bytes（15.5%） |
| 无请求 RSS / CPU | 5 秒 107,024 KiB；60 秒 129,520 KiB；3 分钟 127,136 KiB；5 分钟 127,120 KiB；各点 CPU 0% |
| 无请求 Translation XPC | 5 分钟内始终未启动 |
| 真实 HTTPS 短选区完整翻译 | 约 2.7 秒；来源正确显示模型名 |
| 真实 HTTPS 长选区完整翻译 | 2,499 字符约 16 秒；采样时先保持“正在连接”，随后完整完成 |
| 真实 HTTPS 非流式测试连接 | 约 1.9 秒完成 |
| 真实 HTTPS 401 | 约 1.1 秒返回；界面显示认证错误且不包含 Key 或响应正文 |
| 最终 Release 真实请求后 App / XPC RSS | 设置窗口打开时 App 198,512 KiB；30 秒时 XPC 12,944 KiB、CPU 0%。客户端已释放连接，launchd 仍让服务进程短期空闲驻留；该单点同时包含设置 UI、临时 PDF 与译文，不单独归因为翻译缓存 |

完整 Debug 回归共 183 项：167 通过、16 项 localhost fixture 按设计跳过、0 失败；专用
localhost/XPC runner 17 项全部通过。Universal Release 的主 App 与 Translation XPC 均为
`x86_64 / arm64`，`codesign --verify --deep --strict` 通过。临时 HFS+ UDZO DMG 已完成校验、
只读挂载、内嵌 XPC 复检和清理，没有读取 Sparkle 私钥或产生发布产物。

这些数字只描述当前机器上的 Release 样本，不是跨机器性能承诺。首次请求之前，App RSS 在
延迟加载后从 60 秒样本略微回落并于 3–5 分钟保持约 127 MiB，且 Translation XPC 从未启动。
真实请求后的 XPC 在 30 秒样本仍由系统短期保留，但 CPU 为 0%，客户端也已释放 connection；
这不替代更长时间的真实连续翻译与取消内存验收。

## 真实远端验收规程

真实 API Key 只能在 **Lurume → 设置 → 翻译** 的安全输入框中录入。不得把 Key 发到聊天、
终端参数、环境变量、测试脚本、截图、日志或仓库。验收记录只写服务类型、规范化 origin、
模型、流式开关、耗时和脱敏结果，不记录 Key、原文或完整响应。

本次真实验收使用用户在 App 内配置的 OpenAI-compatible 服务；规范化 origin 为
`https://ark.cn-beijing.volces.com:443`，模型为 `doubao-seed-2.0-mini`。API Key 始终留在
安全输入与 Keychain 路径中，未由命令行、验收记录或仓库读取。请求只使用内置连接测试文本
和专门生成的无敏感英文测试句，没有使用论文内容。

| 场景 | 操作与通过条件 | 状态 |
| --- | --- | --- |
| HTTPS 流式模式完成 | 保存用户自己的兼容配置，确认 origin，只选无敏感测试句；来源含模型名 | **部分通过**：短、长选区均完成且来源正确；本服务在观测窗口内没有暴露可辨认的逐步 delta，协议级增量仍由 localhost fixture 锁定 |
| 停止与重试 | 流式中停止；保留部分结果且不自动重试。手动重试产生全新请求 | **真实服务未完成**：两次专用长样本在界面取得可靠停止控件前完成；可控 localhost 的停止、迟到事件和手动重试测试通过 |
| 非流式成功 | 关闭流式后保存；只在完整响应到达后成功 | **通过**：固定测试文本约 1.9 秒完成，随后已恢复并保存流式开关 |
| 401 | 在 App 内临时填入明确无效且可丢弃的 Key；显示认证错误、不泄露响应或 Key、不回退 | **通过**：未保存的无效草稿约 1.1 秒得到 HTTP 401 分类；草稿随后清空，Keychain 项未覆盖 |
| 429 | 使用用户可控的兼容测试端点或服务实际限流；显示限流/Retry-After，不自动重试 | **待可控 HTTPS fixture**；不通过消耗用户配额强制触发 |
| 5xx | 使用用户可控的兼容测试端点；显示服务端错误，阅读操作保持响应 | **待可控 HTTPS fixture** |
| 断网 | 由用户临时关闭网络后请求；显示网络错误，不静默切换 Apple | **待用户在操作时授权系统网络变更**；DNS、连接和超时分类的 localhost 自动化通过 |
| 跨 origin 重定向 | 使用用户可控 HTTPS 端点返回跨 origin 重定向；跟随前拒绝，Authorization 不发送到新 origin | **待可控 HTTPS fixture**；localhost 跨 origin 跟随前拒绝测试通过 |
| 清理 | 移除验收专用数据，同时不擅自删除用户日常配置 | **部分完成**：无效 Key 仅存在于未保存草稿且已清空；流式设置已恢复。用户的真实 Keychain 配置按其意图保留；临时 PDF 与文献记录待获得删除授权后清除 |

若服务无法稳定制造 429、5xx 或跨域重定向，不应通过消耗配额或攻击厂商端点强行触发；应
使用用户控制的 OpenAI-compatible HTTPS fixture。受控 localhost 自动化已经锁定这些协议和
错误分类，但不能冒充真实 TLS、DNS、供应商行为与费用链路的人工验收。

## 完成检查点四之前仍需

1. 使用用户可控的 OpenAI-compatible HTTPS fixture 完成 429、5xx 和跨 origin 重定向；
2. 在用户即时授权系统网络变更后完成真实断网，或明确接受自动化网络错误覆盖替代该人工项；
3. 使用能够稳定留下操作窗口的服务补录真实停止；当前供应商快速完成不应被伪报为停止通过；
4. 获得删除授权后移除本次导入的临时 PDF 文献记录和对应 `/private/tmp` 文件，但保留用户明确
   配置的真实服务与 Keychain 项；
5. 完成以上场景后，再以未变更的最终源码复跑全量测试、Universal Release、临时 DMG 挂载
   与性能矩阵。全部通过后才能把结论改为“通过”并另行决定是否准备公开版本。

## 协议依据

- OpenAI Chat Completions：
  <https://developers.openai.com/api/reference/cli/resources/chat/subresources/completions>
- OpenAI API 错误、流式和重试说明：<https://developers.openai.com/api/reference/ruby>
- Apple XPC：<https://developer.apple.com/documentation/xpc>
