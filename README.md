# Lurume

Lurume 是一款面向 Apple 平台的开源、轻量、原生学术论文阅读器。

项目希望将论文收集、PDF 阅读、翻译、批注、笔记和引用管理整合进一个专注而完整的应用中。

[![Download](https://img.shields.io/github/v/release/ShunyangLiu/Lurume?include_prereleases&label=%E4%B8%8B%E8%BD%BD&sort=semver)](https://github.com/ShunyangLiu/Lurume/releases/latest)

## 轻量化承诺

轻量不是事后优化，而是 Lurume 的立身之本。我们为此守住四条纪律：

- **系统框架优先**：能力尽量来自 macOS 自带的 PDFKit、Translation 等系统框架，
  不引入任何运行时第三方依赖。未来每接纳一个新依赖，都必须先回答
  “系统框架为什么做不到”。
- **安装包保持个位数 MB**：不捆绑内嵌框架、资源包或后台服务。
  体积一旦逼近承诺边界，优先做功能减法，而不是想办法压缩。
- **性能是验收项**：启动耗时、打开大文档与长时间阅读的内存变化，
  每个阶段都在真实硬件上测量并记录，不做脱离实测的口头承诺。
- **功能克制**：默认只把一件事做到位。每个新能力先问一句
  “拿掉它，应用是否仍然完整”。

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

macOS 原型已经完成 P1 并通过验收，P2 高亮阅读第一版也已通过首轮真实论文验收；P3
阅读导航与文献整理第一版已经实现并完成首轮真实论文手动验收。当前版本包含本地 PDF
引用、PDFKit 阅读器、阅读位置恢复、划词翻译、译文优先检查器、PDF 属性元数据、手动
文献信息编辑、文献库搜索、黄色文字高亮与高亮列表，以及 PDF 自带目录、页面缩略图、
三态阅读状态、状态筛选和文献排序。翻译默认使用英语原文和简体中文目标语言，可在设置
中将原文语言切换为自动识别。
详见 [P0 原型规格](docs/P0-prototype.md)、[P1 讨论记录](docs/P1-plan.md)、
[P1 实现计划](docs/P1-implementation-plan.md)与 [P1 验收记录](docs/P1-acceptance.md)。
P2 的范围、交互和验收标准详见 [P2 高亮阅读计划](docs/P2-plan.md)。P3 的基础目录、
页面缩略图、阅读状态、筛选和排序第一版已经实现，详见
[P3 阅读导航与文献整理计划](docs/P3-plan.md)。

使用 Xcode 26.3 或更新版本打开 `Lurume.xcodeproj`，选择 `Lurume` scheme 即可构建运行。
工程最低支持 macOS 15，不包含运行时第三方依赖。修改 `project.yml` 后需使用 XcodeGen
重新生成工程。项目以 [MIT 许可证](LICENSE)发布。
