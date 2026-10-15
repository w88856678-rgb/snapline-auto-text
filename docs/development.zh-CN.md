# Snapline AutoText 开发与验证

本文面向构建、测试和维护本项目的开发者。下载安装与日常操作见[产品首页](../README.md)和[使用指南](usage.zh-CN.md)。

## 维护范围

当前 macOS 定制版本为 **1.6.8**，支持 macOS 14 及以上。本项目仅维护 `macos/` 的新增功能；仓库保留上游 Windows 源码与素材供参考，不提供 Windows 定制发行版，也不承诺 Windows 具有 macOS 定制功能。

## 构建安装包

完整 Xcode 或 Command Line Tools 可用于构建。打包脚本生成包含 Apple Silicon 和 Intel 两种架构的 universal 应用。从仓库根目录执行：

```bash
cd macos
VERSION=1.6.8 SIGN_IDENTITY=- bash scripts/make-dmg.sh
```

产物位于 `macos/build/`：`Snapline.app`、`Snapline-1.6.8.dmg` 和 `Snapline-1.6.8-mac.zip`。

`SIGN_IDENTITY=-` 强制 ad hoc 签名。当前公开发行版尚未经过 Apple 公证；发布者如需公证，应自行配置 Developer ID 与公证流程。默认 SDK 构建失败时，脚本会尝试已安装的 macOS 26 SDK；也可通过 `SDKROOT` 指定兼容 SDK。

## 运行测试

完整 Xcode 环境运行标准 XCTest：

```bash
cd macos
swift test
```

缺少 XCTest 的 Command Line Tools 环境，可链接真实应用 Debug 对象执行同一批测试：

```bash
cd macos
swift build -c debug --triple "$(uname -m)-apple-macosx14.0"
python3 Tests/Standalone/run.py --build-root .build
```

如需指定兼容 SDK，构建与 runner 应使用相同的 `SDKROOT`。测试使用独立剪贴板、临时文件和只读设置保护，不启动正式应用。

## 1.6.8 验证范围

本地 Debug 与 standalone 通过 **103 个测试、1,415 个检查，0 个失败**。新增覆盖图片解码、透明度和朝向、PNG/TIFF 像素内容去重、网页元信息、单张 Finder 图片、混合图文复制顺序、独立开关、落盘挂起、浏览保护及中文语言匹配。

隔离的实际 GUI 使用私有剪贴板和演示图片，确认 PNG、TIFF、Finder JPEG 和文字均能挂上；迟到的截图文件不会重复挂起或改变最近目标；仍在架上的文件图片可复用并定位，取下后可再次复制挂起。单击图片后，私有剪贴板含 PNG 及本应用复制标记，分辨率保持 360 × 220。该测试未改动用户实际剪贴板或资料。

简体中文资源完成界面 key 覆盖和占位符检查；隔离 bundle 验证了实际中文资源加载、格式化文本及英语回退。

真实跨应用图片/文字拖拽的兼容性仍未完成实机验证；日常推荐单击复制后在目标应用粘贴。

## 1.6.7 验证记录

本地 Debug 与 standalone 验证通过 **65 个测试、721 个检查，0 个失败**，包括最近入口、浏览位置保护、重复便签重启定位、10 项滚动逻辑测试，以及原生滚动事件到控制器的桥接测试。

已完成 TextEdit 的实际 ⌘C 自动挂便签与单击便签后 ⌘V 粘贴纯文字。实机 GUI 验证确认：第一页最近优先，箭头可翻到更早页；满 20 项时在浏览中复制，当前七张卡片保持不变并提示更新；点击入口后定位最近卡片并显示标签。

滚轮操作的 UI 自动化工具返回 `AXError.notImplemented`。虽然事后观察到页码变化，仍不将它计为独立实机手势验证；滚动行为由逻辑与原生事件桥接测试覆盖。

文字便签拖出时仅提供纯文字，不附带 PNG、TIFF 或文件 URL。纯文字传输格式已经通过测试，真实跨应用拖拽仍未完成实机验证。

## 持续集成

[GitHub Actions](https://github.com/w88856678-rgb/snapline-auto-text/actions) 在 main 推送、针对 main 的 Pull Request 或手动触发时运行 macOS 标准 `swift test`，随后构建 universal 应用并上传 DMG/ZIP。

应用内版本为 **1.6.8**，main 产物标记 `1.6.8`，PR 产物标记 `dev`。CI 只有仓库读取权限，不自动创建 Release，也不构建 Windows 定制版。

## 来源与许可证

本项目基于 [mohabujubara/snapline v1.6.2](https://github.com/mohabujubara/snapline/tree/v1.6.2)，其设计与实现源自 [Tendedero](https://github.com/alejandrobujan/tendedero)。[README.upstream.md](../README.upstream.md) 保留上游说明，[LICENSE](../LICENSE) 保留 MIT 许可证及版权声明。
