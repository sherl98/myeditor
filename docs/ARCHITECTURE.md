# 架构

## 模块职责

`ManuscriptCore` 负责文档会话、UTF-8/BOM/换行保留、串行保存、文件协调、冲突与外部变更；不依赖 SwiftUI、WebKit 或 Web 编辑器。

`MyEditor` 负责 SwiftUI 视图、AppKit 桌面交互、设置与每份文档的 WKWebView。原生搜索用最小的 NSSearchField representable，AppKit 负责文本编辑、取消按钮和焦点绘制。DEBUG GUI 验证集中于应用目标内的 `Diagnostics/Validation`，以便访问内部接口，不扩张公共 API。

`EditorWeb` 保留单个编辑器实例：MDXEditor/Lexical 管理文档事务与撤销，CodeMirror 管理源码块视图；Mermaid 随应用本地打包。`editor`、`markdown`、`search`、`bridge`、`diagram`、`styles` 只划分职责目录，不建立额外应用框架。

## 正文与搜索数据流

正文的 session ID、document revision 和 sequence 用于拒绝迟到消息。输入立即标记待同步，完整源码按序列去重发送；目录解析在停止输入 160 ms 后合并执行，连续输入时最多等待 1 s。保存仍通过显式 flush 获取完整源码，不等待目录绘制。

搜索文本、输入焦点和待确认清理请求分别管理。清空搜索不等待正文 flush；清理回执校验文档、修订号和请求编号。过期的绘制、导航和刷新回调不修改新查询。删除文字或点击原生取消按钮保留搜索焦点；Esc 在非输入法组合状态时清空并回到正文。

## 故障边界

WebKit 中断后冻结最近确认的正文、使旧修订消息失效并暂停保存。用户可导出该快照，或明确选择恢复编辑。输入法候选内容不进入恢复副本，源文件不因中断自动被覆盖；无法追回尚未传到原生侧的最后输入。

本地图片在后台读取，取消后不再发送 WebKit scheme 回调。同步文件读取一旦进入系统调用，取消不能保证立即终止磁盘 I/O。
