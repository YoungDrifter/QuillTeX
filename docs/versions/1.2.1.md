# QuillTeX 1.2.1

修复 1.2.0 的分栏问题，并调整分栏状态提示与主文件重命名后的输出文件。

- 打开工程时编辑区与 PDF 预览始终等宽，不再恢复上次会话中漂移的分栏比例；本次会话内拖动分隔线仍可调整，窗口缩放与面板切换会保持当前比例。
- 侧栏/编辑与编辑/预览两条中间分隔线在相邻滚动条显示时暂停拖动，滚动条淡出后恢复，滚动条本身仍优先接收点击。
- 编辑区胶囊显示当前文件的保存状态（Saved / Unsaved），顶栏文件名不再显示未保存圆点；PDF 预览胶囊改为显示编译状态与临时提示，例如 Not built yet、Compiling · showing the previous PDF、Build succeeded、Awaiting compilation、Build failed、SyncTeX was not found…，全部为英文，不再重复 PDF 字样；胶囊宽度随文字自适应，只有过长状态才截断。
- 重命名主 TeX 文件时，同一输出目录中的 PDF 与 LaTeX 辅助文件（aux、log、out、toc、synctex、fls 等）同步改名，预览与 SyncTeX 继续指向同一份输出。
