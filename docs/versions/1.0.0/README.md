# QuillTeX 1.0.0

QuillTeX 首次发布，提供文稿管理、多文件工程、LaTeX 编辑、本地编译和 PDF 预览，让写作与成稿保持在同一个工作区。

**macOS 14+ · Apple Silicon**

## 首发功能

- 本地文稿库、最近打开与模板，支持多标签编辑和多文件工程。
- 章节、标签和图表导航，帮助定位长篇文稿与子文件。
- LaTeX 语法高亮及命令、环境、标签和引用键补全。
- 使用 XeLaTeX、pdfLaTeX 或 LuaLaTeX 本地编译，点击诊断跳转到对应源码。
- 源码与 PDF 并排显示，支持缩放、页面适配及 ⌘-点击双向定位。
- 独立标签栏可按需显示或隐藏；点击顶栏文件名可重命名并设置 Finder 标签。
- 切换主文件时同步工程、编译目标与预览；自动编译期间继续显示已有 PDF。
- 从 Finder 打开 `.tex` 文件，识别 `% !TeX root = ...`；支持在工程中切换主文件。
- 统一的分类设置界面，包含编译配置、自动构建、插件入口与应用信息。
- 每天自动检查 GitHub 正式版；有更新时在应用内提示、下载并安装，也可从应用菜单或 About 手动检查。

## 下载与安装

从 [Releases](https://github.com/YoungDrifter/QuillTeX/releases/tag/v1.0.0) 下载 `QuillTeX-1.0.0.dmg`，打开后将 **QuillTeX.app** 拖入 **Applications**。`SHA256SUMS.txt` 提供安装包校验值。

当前版本使用 ad-hoc 签名，尚未经过 Apple 公证。

编译文稿需要本机安装 TeX（MacTeX / TeX Live）；未安装时仍可编辑与导航。

## 演示文档

[打开演示工程](demo/main.tex) · [查看演示 PDF](demo/main.pdf)

演示工程包含主文稿和多个章节，可用于体验源码编辑、工程导航、编译与 PDF 预览。

## 界面预览

### 启动页

从本地文稿库打开文档，或创建新的文稿。

![QuillTeX 1.0.0 启动页](images/welcome.png)

### 写作与预览

在同一个工作区编辑 LaTeX 源码并查看 PDF 成稿。

![QuillTeX 1.0.0 写作与预览](images/writing.png)

### 结构导航

通过章节、标签和图表索引定位文稿内容。

![QuillTeX 1.0.0 结构导航](images/navigation.png)

### 工程管理

浏览主文稿、子文件和目录结构。

![QuillTeX 1.0.0 工程管理](images/project.png)
