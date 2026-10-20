# Snapline AutoText 开发与验证

本文面向构建、测试和维护本项目的开发者。下载安装与日常操作见[产品首页](../README.md)和[使用指南](usage.zh-CN.md)。

## 维护范围

当前 macOS 定制版本为 **1.6.10**，支持 macOS 14 及以上。本项目仅维护 `macos/` 的新增功能；仓库保留上游 Windows 源码与素材供参考，不提供 Windows 定制发行版，也不承诺 Windows 具有 macOS 定制功能。

## 构建安装包

完整 Xcode 或 Command Line Tools 可用于构建。打包脚本生成包含 Apple Silicon 和 Intel 两种架构的 universal 应用。从仓库根目录执行：

```bash
cd macos
VERSION=1.6.10 SIGN_IDENTITY=- bash scripts/make-dmg.sh
```

产物位于 `macos/build/`：`Snapline.app`、`Snapline-1.6.10.dmg` 和 `Snapline-1.6.10-mac.zip`。

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

## 1.6.10 验证范围

本地 Debug 与 standalone 通过 **125 个测试、1,604 个检查，0 个失败**。新增覆盖 4 点垂直拉出、短距离斜向拉出、水平整理后 8 点转向、微小手抖保留单击、双击编辑、拖拽取消长按，以及边角按钮按下不执行、松手提交或取消。

原生 AppKit 事件测试直接调用实际 `GrabView`，检查只准备一次拖拽、使用原始 mouse-down 锚点、导出图片文件 URL 和边角拖动不执行丢弃/编辑。探针只替代最终会话启动，不向桌面发送合成输入；原有完整文字传输与图片复制测试继续运行。

隔离应用使用虚构便签和图片、私有数据目录与剪贴板。本地 WebKit 聊天输入框实际接收到完整文字和换行，拖入类型为 `text/plain`，没有便签图片。图片文件导出格式已由事件与剪贴板测试覆盖，第三方聊天软件的实际接收能力仍取决于目标应用。本地测试页没有发送消息或网络请求。

拖拽锚点遵循 [Apple 的 AppKit 接口说明](https://developer.apple.com/documentation/appkit/nsview/begindraggingsession(with:event:source:))。Debug 隔离 bundle 可以用 `SnaplineDiagnosticDataDirectory` 和 `SnaplineDiagnosticShowOnLaunch` 在启动时展开测试挂架；正式发行版不包含这个测试入口。

## 1.6.9 验证记录

本地 Debug 与 standalone 通过 **116 个测试、1,521 个检查，0 个失败**。新增覆盖安静收集、默认关闭悬停、主动展开会话、操作期间保护、旧设置迁移、快捷键录制与保留组合，以及不占正式容量的引导练习。

原生 Carbon 注册测试验证了组合键占用、只路由自身事件、修改失败时保留旧快捷键及成功修改后释放旧组合。测试事件仅发送到测试进程，不生成桌面键盘输入。可注册不代表其它应用中没有同名命令，安装引导建议在常用应用中试按。

隔离 GUI 使用私有剪贴板，确认复制文字和 PNG 后均保存内容、保持挂架隐藏并显示新增提示；默认悬停关闭，推荐快捷键注册成功。中文引导中的实际按键练习完成了示例展开与收起，并验证了修改快捷键和恢复推荐组合；示例不读取真实剪贴板或占用工作区。跨应用的实际全局按键与拖拽手势仍需在用户常用应用中确认。

## 1.6.8 验证记录

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

应用内版本为 **1.6.10**，main 产物标记 `1.6.10`，PR 产物标记 `dev`。CI 只有仓库读取权限，不自动创建 Release，也不构建 Windows 定制版。

## 来源与许可证

本项目基于 [mohabujubara/snapline v1.6.2](https://github.com/mohabujubara/snapline/tree/v1.6.2)，其设计与实现源自 [Tendedero](https://github.com/alejandrobujan/tendedero)。[README.upstream.md](../README.upstream.md) 保留上游说明，[LICENSE](../LICENSE) 保留 MIT 许可证及版权声明。
