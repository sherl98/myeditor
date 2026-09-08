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

调研工具位于 `script/audit`，其新输出写入 `.cache/validation`。

`.codex` 是本机生成的环境配置，保留现有 Run 入口且不加入源码基线。开发工具不引入运行时依赖。
