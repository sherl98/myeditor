# 发布与产物管理

`./script/build_and_run.sh --release --build-only` 创建 Apple Silicon 正式包。版本与 build 位于构建入口；Bundle ID 保持 `local.novelreader.app`。

## 发布顺序

1. 记录 Git 提交、dirty 状态与源码指纹，构建本地 Web 页面及 Release 二进制。
2. 在 `.cache/products/staging/<build-id>` 生成应用、ZIP、DMG、dSYM ZIP 和发布清单；dSYM 与可执行文件 UUID 必须一致。
3. 验证签名、压缩包内容、DMG 挂载后的应用内容与 Applications 快捷方式、源码一致性及 `Configurations/release-size-budget.json` 的预算。失败不修改 `dist`。
4. 将完整暂存目录提升为 `dist`，提升失败恢复旧目录；成功后整理前代备份并保留最近三代。

目录替换覆盖可捕获的文件操作失败，不承诺跨进程强制退出或断电的多次 rename 原子性。中断留下的 `generation-*.backup` 必须在清理前检查。

## 产物与证据

`dist` 中仅有 `MyEditor.app`、`MyEditor.zip`、`MyEditor.dmg`、`MyEditor.dSYM.zip` 和 `MyEditor.release-manifest.json`。调试构建在 `.cache/products/debug`，自动 GUI 验证包在 `.cache/products/validation`，均不会覆盖正式包。各自保留一代调试备份。

清单 schema 3 保留原有字段，增加 DMG 字节数、SHA-256、挂载校验结果及当前签名/公证状态；源码指纹覆盖应用源码、资源、Web 构建输入和发布工具，排除文档、测试结果及审计输出。预算配置单独哈希。历史备份占用记录为验证时的实测值，清理后可能变化。

应用使用本地 ad-hoc 签名；此流程不代表 Developer ID 公证或公开发布。依赖许可证随 Web 构建生成并附在应用资源中。

## DMG 打包

正式构建自动生成 `dist/MyEditor.dmg`。使用 `dmgbuild` 和 macOS 自带的 `hdiutil` 创建压缩的只读 HFS+ 磁盘映像。窗口为白底、应用图标、蓝色箭头和 Applications 快捷方式，隐藏工具栏和侧栏。首次打包需要 Python 3.9+ 和网络，会在 `.cache/dmg-tools` 安装 `script/release/dmg-requirements.txt` 锁定的构建依赖；这些工具不随应用分发。窗口布局由 `script/release/dmg_layout.py` 生成。

需要单独为已有应用打包时，指定一个尚不存在的输出文件：

```sh
node script/release/create_dmg.mjs dist/MyEditor.app .cache/dmg-preview/MyEditor.dmg
```

输入应用必须通过签名校验。打包工具不修改源应用，也不覆盖已有输出。DMG 生成后验证映像校验和，以只读方式挂载，验证应用签名、逐项比对文件内容/权限及符号链接，并检查 Applications 快捷方式。只有校验通过才写入输出路径。卸载失败会保留挂载目录和临时映像，停止发布，不强制卸载或递归清理挂载中的目录。

这些操作需要允许创建和挂载磁盘映像的 macOS 环境。受限宿主中的模拟测试不能替代真实 DMG 验证；若 `hdiutil` 报设备或权限错误，应在具备相应权限的本机终端执行上述命令。

DMG 随同一代 App/ZIP 备份保留或清理；旧的无 DMG 备份仍可用于恢复。DMG 体积单独记录，原有 ZIP 预算继续约束 ZIP。`previousBuildsLogicalBytes` 的实测值包含 DMG，新增产物后如超过既有备份预算，需根据实际大小审查预算，不自动放宽限制。

## 公开源码与对外分发准备

- 公开源码前确定项目许可证，保留开源依赖的版权与许可说明；本次打包改动不自动授予源码开源许可。
- 对外分发前配置 Developer ID Application 签名、Hardened Runtime 和所需 entitlement，再完成 DMG 签名、Apple 公证与凭证附加。证书、私钥和认证信息保存在本机钥匙串或受保护的 CI 凭据中，不提交到仓库。
- 当前构建仍为 ad-hoc 签名且未公证；可生成 DMG 不等于已满足公开分发条件。签名流程升级时应同步更新清单中的 `distribution` 字段。
- 正式发布前，在启用 Gatekeeper 的另一台支持的 Mac 上验证浏览器下载、挂载、拖入 Applications、首次启动、打开与保存合成文档。当前支持 Apple Silicon 和 macOS 26+。

参考：[Apple 的 Mac 软件打包指南](https://developer.apple.com/documentation/xcode/packaging-mac-software-for-distribution)与[公证指南](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)。
