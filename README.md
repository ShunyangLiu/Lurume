# Lurume

Lurume 是一款面向 Apple 平台的开源、轻量、原生学术论文阅读器。

项目希望将论文收集、PDF 阅读、翻译、批注、笔记和引用管理整合进一个专注而完整的应用中。

[![Download](https://img.shields.io/github/v/release/ShunyangLiu/Lurume?include_prereleases&label=%E4%B8%8B%E8%BD%BD&sort=semver)](https://github.com/ShunyangLiu/Lurume/releases/latest)

## 下载安装

前往 [Releases 页面](https://github.com/ShunyangLiu/Lurume/releases/latest) 下载最新的 `Lurume.dmg`：

1. 打开 DMG，把 Lurume 拖入 Applications 文件夹；
2. 首次打开时 macOS 会提示“无法验证开发者”。此时不要点“移到废纸篓”，打开
   **系统设置 → 隐私与安全性**，在底部找到关于 Lurume 的提示并点“仍要打开”；
3. 放行只需一次，之后可以正常双击打开。

> Lurume 目前尚未加入 Apple Developer 计划，因此安装包未经过公证，首次打开需要上述
> 手动放行。应用经过 App Sandbox 沙箱保护，只拥有你明确选择打开的 PDF 的只读权限，
> 不会修改你的任何文件。

系统要求：macOS 15 或更新版本，Apple Silicon 与 Intel 芯片均可。

## 项目原则

- 优先提供原生的 macOS 使用体验，并在架构中考虑 iPadOS 和 iOS。
- 本地优先，无需注册账户即可使用。
- 启动迅速、PDF 操作流畅，并保持较低的内存占用。
- 文件属于用户，数据可以自由迁移。
- 翻译和元数据处理绝不能阻塞阅读。
- 保持开源，不在仓库中引入代理开发流程框架。

## 当前状态

macOS 原型已经完成 P1 并通过验收，P2 高亮阅读第一版也已通过首轮真实论文验收。
当前版本包含本地 PDF 引用、PDFKit 阅读器、阅读位置恢复、划词翻译、译文优先检查器、
PDF 属性元数据、手动文献信息编辑、文献库搜索，以及由 Lurume 独立保存的黄色文字高亮
和当前论文高亮列表。翻译默认使用英语原文和简体中文目标语言，可在设置中将原文语言
切换为自动识别。
详见 [P0 原型规格](docs/P0-prototype.md)、[P1 讨论记录](docs/P1-plan.md)、
[P1 实现计划](docs/P1-implementation-plan.md)与 [P1 验收记录](docs/P1-acceptance.md)。
P2 的范围、交互和验收标准详见 [P2 高亮阅读计划](docs/P2-plan.md)。

使用 Xcode 26.3 或更新版本打开 `Lurume.xcodeproj`，选择 `Lurume` scheme 即可构建运行。
工程最低支持 macOS 15，不包含运行时第三方依赖。修改 `project.yml` 后需使用 XcodeGen
重新生成工程。项目以 [MIT 许可证](LICENSE)发布。
