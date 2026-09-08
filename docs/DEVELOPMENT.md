# 开发指南

## 安装与启动

从仓库根目录运行 `npm --prefix EditorWeb ci`。使用 Node 24 与 Swift 6.2；格式基准为 swift-format 6.2.3 和锁文件中的 Prettier 3。

- `./script/build_and_run.sh`：正常退出已有应用、构建调试包并启动。
- `./script/build_and_run.sh --build-only`：只构建，不关闭正在运行的应用。
- `./script/build_and_run.sh --verify`：启动并确认进程存在；不代表 UI 验证通过。
- `./script/check.sh`：格式、原生构建、核心/Web/发布测试、Web 构建和文档链接检查。
- `./script/format.sh --write`：修改自有代码格式。
- `./script/swiftpm.sh run NovelReaderChecks`：独立核心检查；原有名称与参数保留。

SwiftPM 的缓存被定向到本项目。受限宿主若阻止嵌套清单沙盒，应使用宿主批准的构建权限；包装脚本也保留显式的 `NOVELREADER_NESTED_SANDBOX=1` 兼容选项，不默认关闭沙盒。

## 修改约定

Swift 使用四空格，Web 使用双空格；UTF-8、LF、末尾换行由 `.editorconfig` 固定。先做路径迁移，再格式化，最后修改行为，分别保留可审查的提交。

只格式化自有源码与脚本；不改第三方依赖、锁文件内容、历史证据或生成的 HTML。生成产物与缓存不加入 Git。开发指南中的仓库链接使用相对路径，不依赖作者机器用户名。

新增验证样本放入 `Fixtures` 或通过其中的确定性生成器创建。测试不得依赖仓库外的私人文档。GUI 检查使用独立的 `local.myeditor.validation` 标识、`MyEditorValidation` 进程、偏好与 `.cache/products/validation` 产物目录，不关闭正常应用窗口。合成样本随调试验证包提供，避免依赖 Documents 文件读取授权。

`.codex` 是本机生成的环境配置，保留现有 Run 入口且不加入源码基线。开发工具不引入运行时依赖。

## 自动检查

`./script/check.sh` 顺序执行格式检查、SwiftPM 应用构建、核心会话检查、Node 测试、Vite 生产构建及当前文档链接检查。失败立即停止，不更新正式应用。

`Tests/CoreChecks` 仍为 SwiftPM 可执行检查目标，不伪装成 `swift test` 测试套件。所有保存、冲突、恢复和重命名用例使用临时文件。`EditorWeb/test` 检查 Markdown、查找文本、字体及源码适配；`Tests/BuildScripts` 检查预算、指纹、备份保留和失败回滚。

## 实际 WebKit 验证

通过构建入口逐项运行：

```sh
./script/build_and_run.sh --editor-checks
./script/build_and_run.sh --feature-checks
./script/build_and_run.sh --drop-checks
```

一次只启用一个检查模式。自动检查使用独立应用标识与偏好，不重启正常应用；调试 JavaScript 验证设有 25 秒超时，特性报告逐组记录进度。输出位置记录在 `.cache/last-validation-directory`；对应目录包含 `context.json`、合成文档、检查 JSON 和可选截图。context 记录构建标识、源码指纹、样本 SHA-256 与环境。不同运行不合并旧结果。

搜索验收需要在真实 AppKit/WKWebView 中检查：逐字删空、全选删除、原生取消按钮、Esc、快速换词、点击正文保留查询、后台恢复、输入法组合状态，以及普通正文/跨格式/表格/代码/原始 Markdown/Mermaid 源码。结果数归零不等于画面高亮已清除。截图检查清空后无需额外点击或滚动，高亮持续消失，正文、模式、滚动位置和撤销历史不变。

自动发送 composition 事件或标记文本只能覆盖程序边界；实际中文输入法候选窗口和提交仍需交互验证。运行时内存统计只覆盖原生进程，不等于原生加 WebKit 的总占用。Node 微基准不代表 WKWebView 输入延迟。

## 相关文档

- [架构](ARCHITECTURE.md)：模块职责、数据流与故障边界。
- [发布](RELEASING.md)：应用包、DMG、签名及产物管理。
