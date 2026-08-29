# LurumeUpdateTestHost

这是 P6 的隔离 Sparkle 更新宿主，不属于 Lurume 发布产品。它与主 App 使用相同的临时签名、App Sandbox、Installer/Downloader XPC 和 Mach lookup 配置，用来验证旧构建能否从隔离 feed 安装高构建号 DMG。

构建时必须显式提供以下非机密构建设置：

- `LURUME_TEST_FEED_URL`
- `LURUME_TEST_PUBLIC_ED_KEY`
- `CURRENT_PROJECT_VERSION`
- `MARKETING_VERSION`

测试密钥和生成产物只能放在隔离临时目录；不得把任何私钥、公钥实例、feed 地址或签名产物提交到仓库。正式密钥与发布脚本属于 P6 后续检查点。
