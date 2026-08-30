# Lurume P6 检查点四实现与验收记录

日期：2026-08-30

结论：`v0.0.3 → v0.0.4` 真实稳定更新链路通过；P6 第一版完成

## 本地两阶段发布工具

- `Scripts/prepare-release` 只在本机运行全量测试、锁定依赖 Release 构建、Universal 与最低系统版本检查、签名结构检查、DMG 生成、EdDSA 签名、appcast 和唯一更新说明生成，成功后才原子写入不可变发布目录。
- `Scripts/publish-release` 在精确版本确认后按“远端 main → 精确标签 → Release 草稿和 DMG → 公开并匿名校验 → gh-pages appcast 和更新说明”的顺序发布。
- 发布器可以安全重试“Release 已公开但 Pages 尚未部署”的状态；既有标签、Release 正文、资产或 Pages 文件只要与清单不一致就拒绝覆盖。
- 专项脚本测试覆盖非法语义版本、非法构建号、错误 Git SHA refspec、更新说明漂移、产物篡改、路径穿越和发布前状态不一致；四个 zsh 文件均通过 `zsh -n` 语法检查。ShellCheck 不支持 zsh，因此不把它的解释器拒绝误记为脚本失败或通过。
- 构建、签名和 appcast 生成均留在开发者 Mac。正式 EdDSA 私钥只从登录钥匙串读取，没有进入仓库、GitHub、脚本参数、终端输出或构建产物。

## v0.0.3 与 v0.0.4 公开链路

- 引导版本 [`v0.0.3`](https://github.com/ShunyangLiu/Lurume/releases/tag/v0.0.3) 绑定 Git 提交 `3cdd9c08f0c58e1d54bf665fe164a4a4cbd4cec8`，由用户在真实 Mac 上手动安装。
- 首个应用内升级版本 [`v0.0.4`](https://github.com/ShunyangLiu/Lurume/releases/tag/v0.0.4) 绑定 Git 提交 `21665ef71eedf6728a812111a98e0d1ecbc1fc11`；远端 main 与标签均指向该提交。
- v0.0.4 DMG 长度为 `3,112,247 B`，SHA-256 为 `98fef853deb4c03bcc8b3e27fe6cc2271ea9e0efcf37e1c08eeaaf55a260ff0b`。
- 公开 appcast SHA-256 为 `22952ab630910e08f92813de54a69c0a452bb51fbe354b83adae2f39eb236aab`；签名更新说明 SHA-256 为 `ab2875770dc98369e2cf828294eb3787dc717a6b91bc84dc52dcd6fa71aeca00`。
- 发布脚本从匿名 HTTPS 重新下载公开 DMG，并核对长度与哈希；GitHub Pages 部署后再次读取 appcast 和更新说明，与本地不可变清单完全一致。
- GitHub Pages 使用 `gh-pages` 根目录、HTTPS 和项目路径 `https://shunyangliu.github.io/Lurume/`，没有遗留自定义域名或旧 `CNAME`。

## 真实应用内升级

用户在另一台真实 Mac 的“应用程序”文件夹安装 v0.0.3，并在升级前打开 PDF、保留可识别页码、高亮、笔记和文献库状态。v0.0.4 发布后，用户只通过 **Lurume → 检查更新…** 执行升级，没有手动下载替换：

1. Sparkle 从稳定 appcast 识别 v0.0.4，并展示简体中文更新说明；
2. 用户确认后完成 DMG 下载、签名验证、安装和应用重启；
3. 重启后的应用版本为 v0.0.4；
4. 原文献库、当前论文、阅读页码、高亮和笔记均完整保留；
5. 用户确认升级过程与恢复结果全部正常。

这证明正式 EdDSA 信任根、GitHub Release、GitHub Pages、沙盒 Downloader、Installer、安装前保存边界和重启恢复在真实稳定链路中可以共同工作。

## 最终体积、启动和内存记录

本地性能样本使用 MacBook Pro（Apple M4 Pro、24 GB 内存）、macOS 15.7.7、Xcode 26.3、同一 7 篇文献库和从已发布 DMG 复制到可写临时目录的 v0.0.4。启动耗时沿用检查点一方法，从界面控制请求启动到主窗口可交互；RSS 来自 `ps`。

| 指标 | 检查点一 | v0.0.4 | 变化 |
| --- | ---: | ---: | ---: |
| Release App 逻辑文件总量 | 10,467,249 B | 10,563,716 B | +96,467 B |
| DMG | 3,085,497 B | 3,112,247 B | +26,750 B |
| 三次启动中位数 | 0.825 s | 0.812 s | -0.013 s |
| 启动约 60 秒 RSS | 106,512 KiB | 106,288 KiB | -224 KiB |

v0.0.4 三次启动样本为 `0.921 / 0.812 / 0.776 s`。首次手动“无更新”检查约 `1.671 s` 显示简体中文“您使用的就是最新版”；20 次完整检查的响应范围为 `1.376–1.745 s`，中位数约 `1.494 s`。

20 次检查后主进程 RSS 为 `127,920 KiB`、CPU 0%，只有一个 Downloader XPC，RSS 为 `14,960 KiB`、CPU 0%，没有随检查次数产生新实例。另一轮超过 10 分钟的观察中，主进程从检查窗口打开时的 `123,536 KiB` 回落到 `121,088 KiB`；唯一 Downloader 为 `14,400 KiB`、CPU 0%。Lurume 正常退出 5 秒后，主进程和 Downloader 均已清除。

打开固定 `normal-main.pdf` 后的即时 RSS 为 `226,944 KiB`；静置超过 5 分钟后 RSS 回落到 `167,104 KiB`、CPU 0%，阅读过程没有等待更新网络。

## Downloader XPC 运行期边界裁决

实测发现，Sparkle 2.9.6 在检查完成时会清理下载会话、使 XPC connection 失效并重新启用 automatic termination，但 macOS 可以在 Lurume 继续运行时保留该 XPC 服务进程，并不保证立即回收。用户确认保留既有安全架构，不给主 App 增加通用网络权限，也不私有分叉 Sparkle；P6 的最终可测试边界调整为：

- Lurume 运行期间至多保留一个 Downloader XPC；
- 空闲 Downloader 必须 CPU 0%、内存有界，且连续检查不得增加实例；
- 主进程内存必须有界并能从检查峰值回落，PDF 阅读不等待更新网络；
- Lurume 正常退出后 Downloader 必须清除；
- 若以后出现多个空闲实例、持续 CPU、持续内存增长或退出后残留，则视为回归。

该裁决只修正性能验收对 macOS automatic termination 时机的过强假设，没有替换 Sparkle 标准更新器、Downloader XPC、App Sandbox、正式信任根或 XcodeGen 工程来源。

## 最终安全与验收边界

- `xcodebuild test` 共执行 122 项测试，0 失败；P6 发布脚本边界测试及 zsh 语法检查通过。
- v0.0.4 为 `x86_64 / arm64` Universal App，最低系统版本为 macOS 15；主 App 继续没有 `com.apple.security.network.client` entitlement。
- App、Sparkle Framework、Updater 和 XPC 服务通过严格代码签名结构验证；DMG、appcast 和外部更新说明使用正式 EdDSA 信任根并通过签名校验。
- 第一版只发布完整 DMG，没有 delta、Beta 通道、静默安装、系统配置档案或自有遥测。
- 当前仍没有 Developer ID 签名和苹果公证；全新安装需要用户在“隐私与安全性”中手动允许，已安装用户可以继续使用应用内更新。
- Intel slice 已完成构建与静态校验；本轮真实应用内升级由另一台真实 Mac 完成，但没有额外记录 Intel 真机升级。
- P6 完成不代表后续更新可以省略本地准备、明确发布确认、公开文件校验或真实升级抽检；每个版本仍须使用相同两阶段发布边界。
