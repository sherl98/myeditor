# MyEditor

面向 macOS 的本地 Markdown 阅读与编辑应用。原生 SwiftUI / AppKit 窗口搭配 WebKit 编辑器，支持直接编辑正文、查看 Markdown 源码、目录导航、全文搜索和 Mermaid 图表。

## 功能

- 打开或拖入本地 Markdown 文件，并在独立窗口中编辑。
- 正文编辑与 Markdown 源码视图，支持代码块与本地 Mermaid 渲染。
- 标题目录、搜索高亮与匹配项导航。
- 自动保存、外部文件变更检测、冲突处理与恢复副本。
- 字体、字号与外观设置，以及最近打开的文档。

这是持续开发中的 macOS 应用。Mermaid 和编辑器依赖在构建时打包到本地；应用不需要 API 密钥。文档中的外部链接和远程资源仍可能访问网络。

## 开发环境

- Apple Silicon Mac，macOS 26 或更新版本。
- Swift 6.2 工具链及 `swift-format`；项目格式基准为 6.2.3。
- Node.js 24 与 npm；Web 依赖由 `EditorWeb/package-lock.json` 锁定。
- 可用的 Apple 命令行开发工具（`xcrun`、`swift`、`codesign`）。

## 安装和运行

在仓库根目录执行：

```sh
npm --prefix EditorWeb ci
./script/build_and_run.sh
```

启动脚本会正常退出已有的应用实例，再构建并启动调试应用。仅构建、不启动时使用：

```sh
./script/build_and_run.sh --build-only
```

调试应用位于 `.cache/products/debug/MyEditor.app`。

## 验证

```sh
./script/check.sh
```

这会检查代码格式、构建原生目标、运行文档核心与 Web / 发布脚本测试、构建 Web 资源并校验文档链接。核心检查是独立的 SwiftPM 可执行目标，使用 `./script/swiftpm.sh run NovelReaderChecks`，而非 `swift test`。

实际 AppKit / WebKit 集成检查需在 macOS 图形会话中逐项运行：

```sh
./script/build_and_run.sh --editor-checks
./script/build_and_run.sh --feature-checks
./script/build_and_run.sh --drop-checks
```

## 构建应用包

```sh
./script/build_and_run.sh --release --build-only
```

产物写入 `dist/`，包含应用、ZIP、调试符号和发布清单。当前采用本机 ad-hoc 签名；尚未配置 Developer ID 公证或 App Store 分发。

## 项目结构

| 路径 | 内容 |
| --- | --- |
| `Sources/ManuscriptCore` | 文档状态、保存、冲突与恢复 |
| `Sources/MyEditor` | 原生窗口、设置、搜索与 WebKit 桥接 |
| `EditorWeb` | React / MDXEditor / CodeMirror 编辑器与图表 |
| `Tests` / `EditorWeb/test` | 原生核心、Web 和构建脚本检查 |
| `Fixtures` | 合成测试文档及生成器 |
| `Resources` / `Configurations` | 图标和构建预算 |
| `script` | 构建、检查、格式化及发布工具 |
| `docs` | 架构、开发、验证及发布指南 |

详见[文档索引](docs/README.md)。

