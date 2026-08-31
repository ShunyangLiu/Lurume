# P7 检查点四：发布与真实远端验收

日期：2026-08-31

结论：**P7 检查点四通过。用户配置的真实 HTTPS 服务已通过流式完成、非流式完成和 401 分类；用户明确接受由受控 localhost 自动化替代无法安全、稳定制造的 429、5xx、断网、跨 origin 重定向及真实停止窗口。最终源码已重新通过全量测试、专用 XPC 测试、Universal Release、临时 DMG 和性能复核。本检查点没有创建公开版本。**

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

环境：MacBook Pro（Apple M4 Pro，24 GB）、macOS 15.7.7、Xcode 26.3；最终源码基线
`3dfea08`，仅有本检查点结论文档待提交。所有本地兼容服务只监听 `127.0.0.1`，不使用真实
Key 或论文文字。

| 项目 | 结果 |
| --- | --- |
| Release XPC 首次冷启动 ping | 初始样本 45.75 ms；最终复核样本 114.95 ms |
| 随后三次新进程启动 ping | 13.57 / 14.60 / 15.67 ms；中位数 14.60 ms |
| 流式固定选区 | 完成，结果为固定 fixture `分块译文` |
| 请求结束后 XPC 回收 | 初始样本 100 ms；最终复核在 5 秒窗口内未观察到，随后独立进程检查确认已退出。客户端结束请求后立即释放 connection，launchd 可短期保留空闲进程 |
| Release App / Translation XPC 体积 | 最终复核 12,104 KiB / 420 KiB；v0.0.4 App 为 10,480 KiB，App 增加 1,624 KiB（15.5%） |
| 本地 DMG 体积 | 最终复核 3,594,922 bytes；v0.0.4 为 3,112,247 bytes，增加 482,675 bytes（15.5%） |
| 无请求 RSS / CPU | 5 秒 107,024 KiB；60 秒 129,520 KiB；3 分钟 127,136 KiB；5 分钟 127,120 KiB；各点 CPU 0% |
| 无请求 Translation XPC | 5 分钟内始终未启动 |
| 真实 HTTPS 短选区完整翻译 | 约 2.7 秒；来源正确显示模型名 |
| 真实 HTTPS 长选区完整翻译 | 2,499 字符约 16 秒；采样时先保持“正在连接”，随后完整完成 |
| 真实 HTTPS 非流式测试连接 | 约 1.9 秒完成 |
| 真实 HTTPS 401 | 约 1.1 秒返回；界面显示认证错误且不包含 Key 或响应正文 |
| 最终 Release 真实请求后 App / XPC RSS | 设置窗口打开时 App 198,512 KiB；30 秒时 XPC 12,944 KiB、CPU 0%。客户端已释放连接，launchd 仍让服务进程短期空闲驻留；该单点同时包含设置 UI、临时 PDF 与译文，不单独归因为翻译缓存 |

最终复跑的完整 Debug 回归共 183 项：167 通过、16 项 localhost fixture 按设计跳过、0 失败；
专用 localhost/XPC runner 17 项全部通过。P6 发布脚本输入、哈希、路径和 Translation XPC
失败分支测试通过。Universal Release 的主 App 与 Translation XPC 均为 `x86_64 / arm64`，
`codesign --verify --deep --strict` 通过。临时 HFS+ UDZO DMG 已完成校验、只读挂载、内嵌 XPC
复检和清理，没有读取 Sparkle 私钥或产生发布产物。

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
| HTTPS 流式模式完成 | 保存用户自己的兼容配置，确认 origin，只选无敏感测试句；来源含模型名 | **通过（组合验收）**：真实服务短、长选区均完成且来源正确；该服务没有暴露可辨认的逐步 delta，协议级增量由 localhost fixture 锁定 |
| 停止与重试 | 流式中停止；保留部分结果且不自动重试。手动重试产生全新请求 | **替代验收通过**：真实服务两次长样本都在取得可靠停止控件前完成；用户明确接受 localhost 的停止、迟到事件和手动重试自动化覆盖 |
| 非流式成功 | 关闭流式后保存；只在完整响应到达后成功 | **通过**：固定测试文本约 1.9 秒完成，随后已恢复并保存流式开关 |
| 401 | 在 App 内临时填入明确无效且可丢弃的 Key；显示认证错误、不泄露响应或 Key、不回退 | **通过**：未保存的无效草稿约 1.1 秒得到 HTTP 401 分类；草稿随后清空，Keychain 项未覆盖 |
| 429 | 使用用户可控的兼容测试端点或服务实际限流；显示限流/Retry-After，不自动重试 | **替代验收通过**：用户明确接受 localhost 自动化覆盖；不会通过消耗用户配额强制触发真实限流 |
| 5xx | 使用用户可控的兼容测试端点；显示服务端错误，阅读操作保持响应 | **替代验收通过**：用户明确接受 localhost 自动化覆盖 |
| 断网 | 由用户临时关闭网络后请求；显示网络错误，不静默切换 Apple | **替代验收通过**：人工尝试中虽观察到 Wi-Fi 关闭，但请求仍成功，不能记为真实断网；Wi-Fi 随后确认恢复连接。用户明确接受 localhost 的 DNS、连接和超时分类自动化覆盖 |
| 跨 origin 重定向 | 使用用户可控 HTTPS 端点返回跨 origin 重定向；跟随前拒绝，Authorization 不发送到新 origin | **替代验收通过**：用户明确接受 localhost 自动化覆盖；跨 origin 在跟随前被拒绝 |
| 清理 | 移除验收专用数据，同时不擅自删除用户日常配置 | **完成**：当前最终 Release 和仍驻留的旧检查点构建中共 5 条 `lurume-p7-remote-*` 文献记录均已移除，对应 5 个 `/private/tmp` PDF 已删除；无效 Key 草稿已清空。用户的真实 Keychain 配置、模型选择与流式设置按其意图保留 |

若服务无法稳定制造 429、5xx、跨域重定向或停止窗口，不应通过消耗配额或攻击厂商端点强行
触发。受控 localhost 自动化已经锁定这些协议、停止和错误分类；用户明确接受它作为本检查点
相应项目的替代验收，但它不等同于真实 TLS、DNS、供应商行为与费用链路的人工证据。

## 检查点四结论

检查点四以及 P7 的计划范围均已完成。真实远端证据与用户接受的 localhost 替代证据在表中
分别标明，没有把人工断网或真实停止伪报为发生。最终复跑没有发现阻塞项；公开发布仍是独立
决策，不属于本次验收或提交。

## 协议依据

- OpenAI Chat Completions：
  <https://developers.openai.com/api/reference/cli/resources/chat/subresources/completions>
- OpenAI API 错误、流式和重试说明：<https://developers.openai.com/api/reference/ruby>
- Apple XPC：<https://developer.apple.com/documentation/xpc>
