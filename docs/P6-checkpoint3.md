# Lurume P6 检查点三实现记录

日期：2026-08-30

结论：通过，等待用户验收；未进入检查点四

## 菜单、设置与状态绑定

- Lurume 应用菜单已加入“检查更新…”，并直接使用 Sparkle 的 `canCheckForUpdates` 决定是否可用。
- 设置窗口“通用”页已加入“软件更新”区和“自动检查更新”开关；开关直接读写 Sparkle 的 `automaticallyChecksForUpdates`，没有在 `AppSettings` 中保存第二份偏好。
- 更新控制器由应用生命周期唯一持有；菜单和设置共用同一实例，没有创建重复调度器。
- 设置说明明确自动检查间隔为 24 小时、发现更新后仍会询问用户，不会静默下载或安装。
- 菜单和设置的可用状态、开关状态及辅助功能值会随 Sparkle 状态同步更新。

## 第二次启动许可与中文界面

- 工程没有设置 `SUEnableAutomaticChecks`，保留 Sparkle `2.9.6` 的默认许可时机。
- 清理隔离测试偏好后，首次启动没有出现更新许可提示。
- 第二次启动出现 Sparkle 标准简体中文提示“自动检查更新？”，并提供“自动检查”和“不检查”两个选择。
- 实测选择“不检查”后应用正常继续运行，设置中的开关保持关闭；拒绝许可没有造成卡死。
- Sparkle 随最终 App 打包了 `zh_CN.lproj`，已静态核对自动检查许可、获取更新信息失败和“更新错误”等关键字符串。

## 失败路径与低干扰验证

- 手动“检查更新…”使用一个仅指向 `127.0.0.1` 的不存在 appcast 进行隔离验证；Sparkle 显示标准简体中文错误“获取升级信息时出现错误，请稍后再试。”，应用其他功能保持可用。
- 自动检查使用同类 localhost 失败源运行；等待后没有弹出错误窗口，符合后台失败低干扰要求。
- 自动检查偏好由 Sparkle 自身保存；关闭后 Lurume 不运行自建定时器，也没有绕过该偏好发起检查的代码路径。
- 上述验证没有访问公开 feed、GitHub Release 或 GitHub Pages，也没有改变任何公开状态。
- GUI 验证前已备份正式 Lurume 偏好，完成后逐项恢复；恢复后的 plist 与测试前语义内容一致。

## 安装前保存边界

- 新增更新安装保存边界，并接入 Sparkle 的 `willInstallUpdate` 委托回调。
- Sparkle 准备安装时，Lurume 先刷新文献库延迟保存和当前页码，再关闭笔记编辑器，使正在编辑的笔记经过现有保存路径落盘。
- 保存边界使用弱引用连接现有控制器，不把更新逻辑写入 `LibraryStore`、PDF 阅读控制器或笔记存储，也没有修改任何用户数据 schema。
- 自动化测试锁定保存顺序为“文献库与页码 → 笔记编辑器”。检查点四仍需在正式 `v0.0.3 → v0.0.4` 更新中验证安装、重启及完整阅读状态恢复。

## 自动化、Release 与安全校验

- 全量测试共 122 项，0 失败；新增覆盖生产配置默认许可、菜单检查状态、设置双向绑定、禁用状态和安装保存顺序的测试。
- Universal Release 构建成功，主二进制包含 `x86_64 / arm64`，最低系统版本为 macOS 15。
- Release App 通过 `codesign --verify --deep --strict`，内嵌 Sparkle Framework、Updater 与 XPC 服务签名结构有效。
- 最终主 App entitlement 只有 App Sandbox、用户所选文件只读访问以及 `-spks` / `-spki` 两项 Sparkle Mach lookup 例外，没有 `com.apple.security.network.client`。
- 最终 `Info.plist` 包含正式 HTTPS feed、公钥和既定安全配置，且没有 `SUEnableAutomaticChecks`；当前版本仍为 `0.0.2 (2)`，版本升级留给检查点四的正式发布准备。
- XcodeGen 仍是工程配置来源，没有替换 Sparkle 标准更新器、App Sandbox、工程生成方式或其他计划核心组件。

## 验收边界

检查点三可以通过的理由是：菜单、设置、第二次启动许可、拒绝路径、中文错误、后台低干扰、安装前保存边界、自动化测试和最终 Universal Release 均已有验证证据。

它不代表公开更新链路已经发布。`prepare-release`、`publish-release`、`v0.0.3` 引导版本、公开 Release 与 Pages、真实稳定 `v0.0.3 → v0.0.4` 安装重启、完整状态恢复和最终性能矩阵仍属于检查点四。进入任何会修改 GitHub、Pages、标签或公开 appcast 的步骤前，仍需再次取得用户明确确认。
