# 验证指南

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

## 调研探针

- `node script/audit/probes.mjs`：检查当前正式包、源码指纹、CommonMark 引用、源码导航及合成文档目录解析。
- `node script/audit/bundle-probe.mjs`：内存构建对比 Mermaid 依赖体积；替身版本不作为交付应用。

可选的 MarkEdit 比较通过 `MARKEDIT_REFERENCE_ROOT` 指定已下载的参考目录，内含 `release.json`、`UpdateArchive-arm64.zip` 与 `release/MarkEdit.app`。缺少参考包会明确记录不可用。
