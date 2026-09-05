# 翻译预设与本地凭据

本次改动对应 v0.0.9（构建号 9）；更新说明见 [v0.0.9](../release-notes/v0.0.9.md)。

## 配置行为

- 服务商预设包括 OpenAI、Claude / Anthropic、智谱 GLM、OpenRouter、火山方舟、DeepSeek，以及自定义服务。
- 选择服务商后填入普通 API 的 Base URL、协议和一个默认模型；地址和模型都可编辑，模型菜单只是快捷填写，不限制手动输入。
- 默认值不是可用性或最低延迟保证，也不代表账户已开通模型。火山方舟可改填控制台的 `ep-` 接入点 ID；智谱与方舟预设不是 Coding Plan 地址。
- 每家保存一份独立配置。升级前的地址、模型、流式选项、低延迟选项和提示词保留为“自定义服务”。切换预设不会自动覆盖原配置；点击“保存配置”后才成为实际翻译配置。
- API Key 按服务商、协议、规范化后的完整 Base URL 隔离。切换地址或协议会清空未保存的 Key，再加载目标配置的 Key。模型变更不改变 Key。异步读取过期结果不能覆盖新配置。
- Claude 使用原生 `/messages`、`x-api-key` 与 `anthropic-version`。系统提示词单独发送；流式与非流式均支持。流被截断或触及长度限制时保留部分文本并提示失败，不作为完整译文缓存。
- 低延迟选项为兼容服务发送 `temperature=0` 和按选区长度计算的输出上限；GLM、方舟、DeepSeek 和原生 Anthropic 还发送 `thinking.type=disabled`。关闭后不发送可选调优字段；Anthropic 必填的输出上限仍为 8,192。手动选择不兼容这些选项的模型时可关闭。
- 本版不自动获取账户模型列表，也不新增联网权限；请求仍仅由专用 XPC 服务发出，连接测试仍只发送内置文本。

## Key 存储与迁移

Key 为明文，存储于应用沙盒 Application Support 的 `Lurume/translation-credentials/keys.json`；不是加密保管库。
专用目录权限为 `0700`，文件为 `0600`。同一 macOS 用户下的其他程序、管理员或系统备份仍可能访问，因此不要分享该文件或包含它的备份。
普通 UserDefaults 配置及服务商配置快照不包含 Key。

写入使用进程内串行读改写、创建即 `0600` 的独占临时文件、`fsync` 后原子替换。损坏或未来版本的 JSON 不会静默覆盖；拒绝符号链接文件、符号链接凭据目录和非普通文件。
删除 Key 仅删除当前配置记录，不删除其他服务商的 Key，不声称安全擦除磁盘或历史备份。

启动、打开设置和翻译均不会自动读旧钥匙串。用户可点击“从旧版钥匙串读取 Key…”并确认，此时可能出现一次系统授权。
读取结果只填入草稿，核对服务地址后点击保存才写入本地；不会覆盖已有非空草稿，也不会自动删除旧钥匙串条目。
无法授权时可手动填写 Key。Sparkle 发布签名私钥的存储与流程完全不变。

## 预设依据（2026-09-05 核对）

模型 ID 是可维护的小型快照，而非实时模型目录。OpenAI 部分使用 OpenAI Docs 指引核对官方 API 文档，其余使用各平台官方资料。

- [OpenAI GPT-4.1 mini](https://developers.openai.com/api/docs/models/gpt-4.1-mini)、[GPT-4.1](https://developers.openai.com/api/docs/models/gpt-4.1)。
- [Anthropic 模型 ID](https://platform.claude.com/docs/en/about-claude/models/model-ids-and-versions)、[Messages](https://platform.claude.com/docs/en/api/http/messages/create)、[流式事件](https://platform.claude.com/docs/en/build-with-claude/streaming)。
- [智谱 GLM-4.7-Flash](https://docs.bigmodel.cn/cn/guide/models/free/glm-4.7-flash)、[思考模式](https://docs.bigmodel.cn/cn/guide/capabilities/thinking-mode)。
- [OpenRouter 快速开始](https://openrouter.ai/docs/quickstart)、[模型列表接口](https://openrouter.ai/docs/api/api-reference/models/list-all-models-and-their-properties)。另通过无需 Key 的公开模型目录确认三项预设 ID。
- [火山官方服务助手的方舟示例](https://developer.volcengine.com/articles/7628897447645904939)，含北京 API 根地址及 `doubao-seed-2-0-mini-260215`；[Chat Completions 参数](https://www.volcengine.com/docs/82379/1494384)。
- [DeepSeek API 入门](https://api-docs.deepseek.com/)、[思考模式开关](https://api-docs.deepseek.com/guides/thinking_mode/)。

验证采用临时目录、隔离 UserDefaults、模拟 Key 和本机 HTTP 服务，不调用付费远端模型，不读取用户现有 Key。

## 验证结果

- `xcodebuild test`：327 项，297 通过，30 项依赖本机服务的夹具测试按设计跳过，0 失败。
- 翻译 XPC 本机集成：25 / 25 通过，含 Claude 流式、非流式、截断、提前断流和取消。
- Zotero XPC 本机集成：22 / 22 通过。
- P6 发布脚本输入、哈希与路径边界测试通过；正式产物由两阶段发布流程重新测试、构建和签名。
- 在隔离配置下渲染并检查 600 × 680 设置页，保存和测试连接按钮固定在底部；截图保存在测试结果附件。
- `git diff --check` 通过。尚未以各平台真实账户验证模型权限、计费或远端速度，不据此宣称实测加速。
