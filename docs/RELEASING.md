# 发布与产物管理

`./script/build_and_run.sh --release --build-only` 创建 Apple Silicon 正式包。版本与 build 位于构建入口；Bundle ID 保持 `local.novelreader.app`。

## 发布顺序

1. 记录 Git 提交、dirty 状态与源码指纹，构建本地 Web 页面及 Release 二进制。
2. 在 `.cache/products/staging/<build-id>` 生成应用、ZIP、dSYM ZIP 和发布清单；dSYM 与可执行文件 UUID 必须一致。
3. 验证签名、压缩包内容、源码一致性及 `Configurations/release-size-budget.json` 的预算。失败不修改 `dist`。
4. 将完整暂存目录提升为 `dist`，提升失败恢复旧目录；成功后整理前代备份并保留最近三代。

目录替换覆盖可捕获的文件操作失败，不承诺跨进程强制退出或断电的多次 rename 原子性。中断留下的 `generation-*.backup` 必须在清理前检查。

## 产物与证据

`dist` 中仅有 `MyEditor.app`、`MyEditor.zip`、`MyEditor.dSYM.zip` 和 `MyEditor.release-manifest.json`。调试构建在 `.cache/products/debug`，自动 GUI 验证包在 `.cache/products/validation`，均不会覆盖正式包。各自保留一代调试备份。

清单 schema 2 保留原有字段，增加预算配置 SHA-256 和压缩包验证结果；源码指纹覆盖应用源码、资源、Web 构建输入和发布工具，排除文档、测试结果及审计输出。预算配置单独哈希。历史备份占用记录为验证时的实测值，清理后可能变化。

应用使用本地 ad-hoc 签名；此流程不代表 Developer ID 公证或公开发布。依赖许可证随 Web 构建生成并附在应用资源中。
