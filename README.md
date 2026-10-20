<p align="center">
  <img src="QuillTeX/App/Assets.xcassets/AppIcon.appiconset/icon_128_128.png" alt="QuillTeX" width="96">
</p>

# QuillTeX

一个克制的原生 macOS LaTeX 编辑器，让源码、工程结构与 PDF 成稿在同一个工作区中保持联系。

**Version 1.1.0** · macOS 14+ · Apple Silicon

[下载 1.1.0](https://github.com/YoungDrifter/QuillTeX/releases/tag/v1.1.0)

![QuillTeX 1.1.0 · 写作与预览](docs/versions/1.1.0/images/writing.png)

## 功能

- 本地文稿库、最近打开与模板，支持多标签编辑和多文件工程。
- 章节、标签和图表导航，帮助定位长篇文稿与子文件。
- LaTeX 语法高亮及随输入更新的行内补全，优先匹配工程自定义命令与环境，支持数学参数跳转。
- 使用 XeLaTeX、pdfLaTeX 或 LuaLaTeX 本地编译，点击诊断跳转到对应源码。
- 可折叠的警告／错误列表与排版校对，帮助检查错误、溢出行和未解析引用。
- 源码与 PDF 并排显示，支持手势缩放、Actual Size、适应宽度和实时缩放比例，以及 ⌘-点击双向定位。
- 新开或切换文件自动显示标签栏，主文件固定在首位，其余标签可拖动排序；点击顶栏文件名可重命名并设置 Finder 标签。
- 主文件固定为工程的编译与预览目标；自动编译期间继续显示已有 PDF。
- 从 Finder 打开 `.tex` 文件，自动补充主文件注释；工程打开后主文件固定，重命名时相关注释同步更新。
- 在展开的文件夹中直接新建 TeX 或文件夹，名称在文件行内编辑，回车或点击侧栏空白处保存，留空使用默认名；右键可重命名或移到废纸篓；子文件按主文稿引用顺序排列，可拖动到引用前后或源码指定行插入。
- 恢复工程标签、编辑位置与 PDF 阅读状态，保留异常退出前的未保存编辑。
- TeX 与 PDF 跟随外部保存自动刷新；存在未保存的 TeX 编辑时，可选择保留当前编辑或采用外部版本。
- 统一的分类设置界面，包含编译配置、自动构建、插件入口与应用信息。
- 每天自动检查 GitHub 正式版；有更新时在应用内提示、下载并安装，也可从应用菜单或 About 手动检查。

## 安装

从 [Releases](https://github.com/YoungDrifter/QuillTeX/releases/tag/v1.1.0) 下载 `QuillTeX-1.1.0.dmg`，打开后将 **QuillTeX.app** 拖入 **Applications**。`SHA256SUMS.txt` 提供安装包校验值。

当前版本使用 ad-hoc 签名，尚未经过 Apple 公证。

编译文稿需要本机安装 TeX（MacTeX / TeX Live）；未安装时仍可编辑与导航。

## 版本记录

### 1.0.0 · 首次发布

首次发布，支持文稿管理、多文件工程、独立标签栏、LaTeX 编辑与补全、主文件管理、本地编译、PDF 预览和双向定位。

[版本介绍与演示](docs/versions/1.0.0/README.md) · [下载 1.0.0](https://github.com/YoungDrifter/QuillTeX/releases/tag/v1.0.0)

### 1.0.1 · 侧栏交互调整

所有侧栏层级默认折叠，优化展开交互；补全框支持限高滚动与鼠标选择，编辑区提供撤销／重做按钮与快捷键；Manual 模式可选择保存后编译，About 显示版本与构建号。

[更新说明](docs/versions/1.0.1/README.md) · [下载 1.0.1](https://github.com/YoungDrifter/QuillTeX/releases/tag/v1.0.1)

### 1.0.2 · 界面统一与最近项目

统一顶栏、标签栏、侧栏与所有弹层的配色、圆角与描边，图标按钮改为一致的圆形点击区；顶栏新增历史记录入口，可直接切换到最近项目；打开文稿改用居中的加号图标，分栏图标改为右侧填充；修复连续点击顶栏按钮边缘误触发窗口放大的问题。

[更新说明](docs/versions/1.0.2/README.md) · [下载 1.0.2](https://github.com/YoungDrifter/QuillTeX/releases/tag/v1.0.2)

### 1.0.3 · 写作与校对优化

优化补全与数学参数输入、长文稿分析、编译诊断与 Result 列表；恢复工程编辑与阅读状态，完善 PDF 定位反馈与排版校对。所有改进直接作为基础功能提供。

[更新说明](docs/versions/1.0.3/README.md) · [下载 1.0.3](https://github.com/YoungDrifter/QuillTeX/releases/tag/v1.0.3)

### 1.1.0 · 写作与交互焕新

跟随输入的行内补全、完整的环境与括号配对、自定义命令优先匹配；可折叠的警告与错误列表；玻璃胶囊分组、统一的滑动选择与悬停反馈，以及对齐的编译设置与策略抽屉。支持子文件标签拖动排序、PDF 实际大小与实时缩放比例，修复导入模板被移出模板库的问题。

[版本介绍与全新演示](docs/versions/1.1.0/README.md) · [下载 1.1.0](https://github.com/YoungDrifter/QuillTeX/releases/tag/v1.1.0)

## 本地构建

安装 Xcode 后，在项目根目录运行：

```sh
xcodebuild -project QuillTeX.xcodeproj -scheme QuillTeX -configuration Debug build
```

使用 Xcode 打开 `QuillTeX.xcodeproj` 进行开发。正式安装包由发布脚本生成，并包含校验文件和签名更新清单。

运行 `./Tests/run.sh` 执行自动化测试。

## 许可证

本项目采用 [MIT License](LICENSE)，允许使用、修改、分发和商业使用，请保留版权及许可证声明。软件按原样提供，不附带任何担保。

## 反馈与贡献

欢迎通过 [Issues](https://github.com/YoungDrifter/QuillTeX/issues) 报告问题或提出建议，也欢迎提交 Pull Request。报告问题时请附上 macOS 版本、应用版本和复现步骤；较大的改动请先开 Issue 讨论。

这是个人维护的项目，按作者的时间与需求持续改进，不承诺固定更新频率或响应时间。
