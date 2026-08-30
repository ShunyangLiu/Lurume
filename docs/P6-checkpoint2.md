# Lurume P6 检查点二实现记录

日期：2026-08-30

结论：通过，等待用户验收；未进入检查点三

## 正式信任根与备份

- 经用户明确授权，使用 Sparkle `2.9.6` 的官方工具生成正式 EdDSA 更新密钥。
- 正式私钥保存在登录钥匙串的 `ShunyangLiu` 账户中；公钥已写入 XcodeGen 工程源与最终 App 配置。
- 加密备份保存在 `/Users/lumin/Documents/Lurume/Lurume-Update-Key-Backup.dmg`。镜像使用 AES 加密并限制为当前用户读写；镜像内只包含导出的私钥文件，不包含密码提示或明文密码。
- 已完成“挂载加密备份 → 恢复到隔离测试账户 → 对测试产物签名并验证”的恢复演练，恢复得到的公钥与正式 App 公钥一致。
- 恢复演练产生的临时钥匙串账户已在用户确认后删除；登录钥匙串中只保留正式账户。该临时条目不可恢复，但它只是正式密钥的测试副本，正式条目和加密备份均未删除。
- 钥匙串授权窗口需要输入当前 Mac 登录密码；它与加密备份镜像密码是两个独立凭据。

## 最终 Sparkle 安全配置

工程源与生成的 `Info.plist` 当前固定配置：

- `SUFeedURL = https://shunyangliu.github.io/Lurume/appcast.xml`
- `SUPublicEDKey` 与正式私钥匹配
- `SUVerifyUpdateBeforeExtraction = YES`
- `SURequireSignedFeed = YES`
- `SUSignedFeedFailureExpirationInterval = 0`
- `SUAllowsAutomaticUpdates = NO`
- `SUEnableSystemProfiling = NO`
- `SUScheduledCheckInterval = 86400`
- Installer Launcher 与 Downloader 两项专用服务保持启用

主 App 仍没有 `com.apple.security.network.client` entitlement，更新网络访问继续只由 Sparkle 专用 Downloader 服务承担。检查点二没有启动 updater、加入菜单或修改设置界面；这些仍属于检查点三。

## 本地签名与拒绝矩阵

新增 `Tests/P6Security`，其中只保存确定性的非秘密样本和本地测试脚本。仓库不保存私钥、生成后的签名、签名 appcast 或可发布更新包。

正式密钥已通过更新归档、外部更新说明和 appcast 的签名与验证，并完成最初三项篡改拒绝验证。随后使用一次性隔离密钥扩展并复核完整的五项拒绝矩阵：

1. 更新归档内容被修改；
2. 外部更新说明内容被修改；
3. 已签名 appcast 的版本字段被修改；
4. 已签名 appcast 的下载地址被修改；
5. 已签名 appcast 的归档长度被修改。

有效的更新归档、更新说明和 appcast 均验证通过，上述五种篡改均被拒绝。扩展矩阵使用一次性密钥验证测试逻辑；正式密钥则通过恢复演练、直接签名验证和核心三项拒绝路径证明信任根可用。测试脚本只打印通过/拒绝状态，不打印签名或私钥内容，并在退出时清理私有临时目录。

## 工程与自动化验证

- 新增自动化测试，锁定正式 feed、公钥、签名 feed、解压前验证、禁止失败回退、禁止静默更新、禁用系统画像、24 小时间隔和两项 XPC 服务配置。
- XcodeGen 仍是工程配置的唯一来源；`Info.plist` 已由 `project.yml` 重新生成，没有手工维护第二份配置。
- 最终全量测试共 119 项，0 失败；其中包含新增的生产 Sparkle 安全配置测试。
- Universal Release 构建通过，主二进制同时包含 `x86_64 / arm64`，最低系统版本为 macOS 15。
- Release App 通过 `codesign --verify --deep --strict`；最终 entitlement 只有 App Sandbox、用户所选文件只读访问和 `-spks` / `-spki` 两项 Sparkle Mach lookup 例外，没有主进程通用网络权限。

## 托管边界

正式 feed 使用项目级 GitHub Pages 地址 `https://shunyangliu.github.io/Lurume/appcast.xml`，不使用与本项目无关的 `lurume.me` 域名。

当前仓库 Pages 尚未启用，账户级 Pages 仓库仍存在旧 `CNAME`，因此该地址目前可能被旧域名映射重定向而不可用。检查点二只固定客户端配置，不修改任何公开状态；移除旧映射、启用 Lurume Pages、上传 appcast 或创建 Release 均留到检查点四，并在操作前再次取得用户明确授权。由于 updater 仍未启动，当前构建不会访问这个尚未发布的地址。

## 安全清理与验收边界

- 私钥没有进入仓库、构建产物、测试夹具、终端输出或 GitHub。
- 加密备份当前处于未挂载状态。
- 隔离测试私钥、恢复演练临时文件和临时钥匙串账户均已清理。
- 未创建或修改 Git 标签、GitHub Release、GitHub Pages、公开 appcast 或更新说明。

检查点二可以通过的理由是：正式信任根、加密备份、恢复可用性、生产配置、签名样本和篡改拒绝路径均已有验证证据。它不代表更新界面或公开发布链路已经完成；用户确认备份状态后才能进入检查点三。
