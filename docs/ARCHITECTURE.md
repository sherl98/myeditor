# 架构

## 模块职责

`ManuscriptCore` 负责文档会话、UTF-8/BOM/换行保留、串行保存、文件协调、冲突与外部变更；不依赖 SwiftUI、WebKit 或 Web 编辑器。旧版本偏好的一次性迁移（`LegacyPreferences`）也在这里，便于独立检查。

`MyEditor` 负责 SwiftUI 视图、AppKit 桌面交互、设置与每份文档的 WKWebView：

- `App`：应用控制器、搜索协调器（`DocumentSearchCoordinator`）、保存与提示流程（`ApplicationController+Saving`）、菜单命令和偏好。
- `Editor`：`MarkdownWebEditor` 桥接、编辑器资源服务（`EditorResourceHandler`）与字体目录。
- `Windows`：文档窗口与工具栏、打开面板、新文稿关闭确认和拖放。
- `Views`：SwiftUI 视图。原生搜索用最小的 NSSearchField representable，AppKit 负责文本编辑、取消按钮和焦点绘制。
- `Diagnostics/Validation`：仅在 DEBUG 编译的真实 WKWebView 验证，以便访问内部接口，不扩张公共 API。

`EditorWeb` 保留单个编辑器实例：MDXEditor/Lexical 管理文档事务与撤销，CodeMirror 管理源码块视图。`editor`、`markdown`、`search`、`bridge`、`diagram`、`styles` 只划分职责目录，不建立额外应用框架。

## 编辑器资源

编辑器页面由 `EditorResourceHandler` 以 `myeditor-app://editor/` 提供，只读取应用包内 `Resources/EditorWeb` 下的文件，拒绝路径穿越；WebKit 不获得文件系统访问权。页面 CSP 为 `script-src 'self'`。

Vite 保留动态导入的分块：首屏只加载主脚本与样式（约 1.36 MB），Mermaid 及各类图表只在文档出现图表时加载。本地图片仍由 `myeditor-resource:` 在后台读取。网络图片默认不请求：页面显示占位图并告知原生，用户可在文档顶部加载，或在设置中打开“自动加载网络图片”。

## 正文同步与保真

导入文档时记录每个顶层 Markdown 块在原文中的位置及其生成的编辑器节点（`src/editor/documentSync.js`）。编辑只标记被改动的顶层块，停顿 150 ms（连续输入时最长 1 s）或 flush 时才导出：

- 未改动的块及块间分隔原样拼接原文字节；改动的块单独序列化，沿用原文的列表符号、强调符号、编号分隔符、分隔线、代码围栏、Setext 标题与引用式链接写法。改动后内容与原块等价（例如撤销）时退回原文。
- 撤销/重做替换整个编辑器状态，只标记根节点；按前后状态的节点身份比较找出真正变化的块。
- 目录按块增量计算：只解析可能含标题的块，章节字数由块的可见字符数累加。
- MDXEditor 自带的整篇导出由构建时补丁跳过（`vite.config.js`）；补丁目标代码不存在时构建失败。补丁只影响性能，未生效时数据流仍正确。
- 块映射异常（例如某个块没有生成节点）时退回整篇规范化导出，并在 `inspect().sync.reason` 中记录原因。

正文的 session ID、document revision 和 sequence 用于拒绝迟到消息。输入立即向原生发送一次“待同步”，导出后才发送完整源码；原生的 flush 从回复中取源码，不重复传输。原生只观察“有无草稿”的变化，草稿全文、确认副本不参与 SwiftUI 观察；文本比较按 UTF-8 字节进行，保存时的文件格式（BOM、CRLF、末尾换行）在快照时计算一次。

段落内的脚注引用、行内公式和 wiki 链接作为行内原文保留，其余内容照常渲染；显示公式与 MDX 类语法保留整段原文。Front Matter 在阅读时折叠为“元数据”。

## 搜索

搜索文本、输入焦点和待确认清理请求分别管理。清空搜索不等待正文 flush；清理回执校验文档、修订号和请求编号。过期的绘制、导航和刷新回调不修改新查询。删除文字或点击原生取消按钮保留搜索焦点；Esc 在非输入法组合状态时清空并回到正文。编辑菜单的撤销/重做在原生文本框获得焦点时交给 AppKit 响应链。

## 故障边界

新建文稿的 `DocumentSession.url` 为空，正文仅在内存中维护。`saveFirst` 完成写入后才绑定正式路径、启动监听及允许自动保存；`DocumentStore` 对并发保存目标和已打开文件进行去重。首次保存保持同一个 WebKit 编辑器及撤销历史，并更新相对图片的目录基准。

关闭新文稿时，短生命周期的 `NewDocumentCloseConfirmation: NSDocument` 只负责系统原生确认面板。它不拥有编辑器或窗口控制器、不会自动保存，显式保存通过回调交给原有会话；删除和取消分别交还关闭流程处理。

WebKit 中断后冻结最近确认的正文、使旧修订消息失效并暂停保存。用户可导出该快照，或明确选择恢复编辑。输入法候选内容不进入恢复副本，源文件不因中断自动被覆盖；无法追回尚未导出到原生侧的最后输入（最长约 1 秒）。

源文件被删除后保留正文并提示；同样的字节重新出现时（例如切换分支）提示自动消失，不重新载入。新文件按 `0666 & ~umask` 创建。

本地图片在后台读取，取消后不再发送 WebKit scheme 回调。同步文件读取一旦进入系统调用，取消不能保证立即终止磁盘 I/O。

## 已知限制

Lexical 把整篇文档渲染进 DOM。开始输入约 1 秒后，系统文字服务会让 WebKit 对可编辑区域整体排版一次：约 12 万字时约 0.4 秒，约 67 万字时约 0.6 秒，每段连续输入一次。这与导出时机和输入法无关；`content-visibility` 会让每次按键更慢。根本解决需要只渲染可见区域的编辑器（例如 CodeMirror 的视口渲染）。
