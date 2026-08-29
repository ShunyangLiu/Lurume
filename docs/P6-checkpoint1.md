# Lurume P6 检查点一实现记录

日期：2026-08-29

结论：通过，等待用户验收；未进入检查点二

## 已完成

- 通过 XcodeGen 与 Swift Package Manager 固定官方 Sparkle `2.9.6`，并提交 `Package.resolved`。
- 主 App 只持有未启动的 `SPUStandardUpdaterController`；检查点一没有加入菜单、设置、许可提示或正式 feed。
- 主 App 启用 Sparkle Installer Launcher 与 Downloader XPC 服务，加入 `-spks`、`-spki` 两项 Mach lookup 临时例外。
- 主 App 保留 App Sandbox 与用户所选文件只读权限，没有加入 `com.apple.security.network.client`。
- Release 配置关闭 Xcode 自动注入的 `get-task-allow`；Debug 与测试配置不受影响。隔离更新在这一最终 entitlement 组合下重新验证通过。
- 上游 Sparkle 完整许可证随 App 打包，“关于”信息中加入依赖归属。
- 增加不参与 Lurume 发布构建的 `LurumeUpdateTestHost`，用于重复验证沙盒、XPC、临时签名和更新安装组合。
- 现有 117 项测试和新增的更新控制器构造测试共 118 项全部通过；Universal Release 构建及严格代码签名结构校验通过。

## 包体、启动与空闲内存

测量环境为同一台 Apple Silicon MacBook Pro、macOS、Xcode 26.3、同一文献库和同一 DerivedData Release 启动方式。启动耗时是 Computer Use 从请求启动到主窗口可交互的三次样本；RSS 来自 `ps`。

| 指标 | 无 Sparkle 基线 | 检查点一 | 变化 |
| --- | ---: | ---: | ---: |
| Release App 逻辑文件总量 | 7,593,555 B | 10,467,249 B | +2,873,694 B |
| DMG | 1,180,814 B（公开 `v0.0.2`） | 3,085,497 B | +1,904,683 B |
| 三次启动中位数 | 0.769 s | 0.825 s | +0.056 s |
| 启动约 20–30 秒 RSS | 106,608 KiB | 106,512 KiB | -96 KiB |
| 检查点一稳定空闲 RSS | 未保留同龄基线样本 | 80,048 KiB（约 15 分钟） | 仅记录，不作跨龄比较 |

三次无 Sparkle 启动样本为 `0.745 / 0.771 / 0.769 s`；三次检查点一样本为 `0.982 / 0.825 / 0.817 s`。当前数据没有显示启动或空闲内存阻塞，但完整的 60 秒、10 分钟、PDF 静置和重复检查矩阵仍属于 P6 后续发布验收，不由本检查点提前宣称完成。

## 隔离更新验证

测试使用一次性 EdDSA 密钥、本机 `127.0.0.1` feed、签名 appcast、签名 DMG 和两个临时签名 Release 构建：

1. 构建 `1.0.0 (1)` 从隔离位置启动，主进程只有 App Sandbox 与两项 Sparkle Mach lookup 例外，没有通用网络权限。
2. Sparkle Downloader XPC 成功读取签名 appcast；标准简体中文窗口识别出 `1.0.1 (2)`。
3. 用户选择“安装更新”后，Downloader 获取完整 DMG，Installer、Autoupdate 与 Updater 进入安装流程。
4. 旧构建通过正常退出边界终止后，Sparkle 原位替换 App 并自动重启；窗口和 App bundle 均确认版本为 `1.0.1 (2)`。
5. 更新后的 App 通过 `codesign --verify --strict`；更新完成 60 秒后不再存在本测试的 Downloader、Installer、Autoupdate 或 Updater 辅助进程。

这证明当前“临时签名 + 无 Developer ID + 无公证 + App Sandbox + Sparkle 专用 XPC”组合可以在不扩大主进程网络权限的前提下完成真实 DMG 更新。观察到的标准流程是在下载完成后等待 App 正常退出再替换并重启；检查点三必须把现有页码、文献库延迟保存和笔记草稿接入这个退出边界。

## 安全清理与边界

- 一次性测试私钥只曾存在于精确的临时目录和唯一钥匙串测试账户；验证完成后两者均已删除。
- 测试公钥、私钥、签名产物、appcast、DMG 和 localhost 实例地址均未写入仓库。
- 未生成正式更新密钥，未访问或修改 GitHub Release、GitHub Pages、标签或正式 appcast。
- 主 App 的 updater 在检查点一保持未启动，避免在正式配置和用户许可界面完成前发起更新工作。
- 正式密钥、签名 feed、拒绝路径和篡改样本仍属于检查点二；未经用户验收和明确授权不得开始。

## 验收边界

检查点一可以通过的理由是：固定依赖、主 App 沙盒边界、真实 Release/DMG、包体与启动基线、一次性签名更新、原位替换重启和辅助进程退出都已有实测证据。它不代表 P6 整体完成，也不代表正式发布信任根已经建立。
