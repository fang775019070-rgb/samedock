# SameDock

**每一块屏幕，都有顺手的 Dock。** · [English](README.md)

SameDock 是一款免费、开源的 macOS 应用，为多显示器 Mac 的其他屏幕提供 Dock。它跟随系统 Dock：在你启用的每块屏幕上显示同样的应用、运行指示和最小化窗口缩略图；当前承载系统 Dock 的屏幕会自动排除，两者不会重叠。

SameDock 基于 **baikaihao** 的 [EchoDock](https://github.com/baikaihao/EchoDock) 修改而来，与原项目一样采用 **GNU AGPL v3.0（仅此版本）** 许可。详见[致谢与许可](#致谢与许可)。

官网：<https://samedock.fang775019070.chatgpt.site>

> 截图：暂未提供。

## 功能

- **每块启用的屏幕都有 Dock**，可放在底部、左侧、右侧或顶部。自动识别并排除系统 Dock 所在屏幕，新接入的屏幕可自动启用。
- **跟随系统 Dock**：固定应用、运行中应用及指示点读取自 macOS Dock；可在任意屏幕切换、显示/隐藏、退出应用并恢复窗口。
- **最小化窗口缩略图**（需 macOS 14+）：与系统 Dock 一样出现在 SameDock 中，点击即可恢复该窗口。只截取 Dock 自身的图块区域，仅保存在内存中，不写入磁盘、不上传。
- **废纸篓与推出**：拖入文件移到废纸篓（可撤销），拖入已挂载磁盘则安全推出。
- **窗口避让底栏**（可选）：SameDock 所在屏幕上最大化、缩放或新打开的窗口会保持在底栏上方；你自己拖到底栏上的窗口保持原位。
- **类原生外观**：放大效果、启动弹跳、图标大小与间距、玻璃或高斯模糊背景、全屏时隐藏、闲置时隐藏。
- **原生 Dock 位置助手**：可选择把系统 Dock 固定在指定显示器。
- 中英文界面（跟随 macOS 语言）；登录时启动；无统计分析、无账户、无自动联网更新。

SameDock 不替换也不修改 macOS 的 Dock，也不会突破硬件的显示器数量限制。

## 系统要求

- **Apple 芯片** Mac（发布版仅 arm64）。
- **macOS 13 Ventura 或更高**；窗口缩略图需要 **macOS 14 Sonoma 或更高**。
- 在 **系统设置 → 桌面与程序坞** 中打开 **“显示器具有单独的空间”**（未打开时 SameDock 会提示）。

## 安装

1. 从 [Releases](../../releases)（或官网）下载最新的 `SameDock-x.y.z-arm64.zip`，解压后把 `SameDock.app` 拖入 **应用程序**。
2. 打开应用。发布版使用开发者自有证书签名，**不是**苹果 Developer ID 签名，也**未经苹果公证**，因此首次打开会被 macOS 拦截：
   - 打开 **系统设置 → 隐私与安全性**，向下滚动，在 SameDock 提示旁点击 **“仍要打开”** 并确认。（[苹果说明](https://support.apple.com/zh-cn/102445)）
   - 请仅在信任下载来源时这样做；受管理的 Mac 可能不允许。
3. 按首次启动时的两步提示授权（见下文）。如系统要求退出并重新打开，请照做。

更新需手动进行：先退出 SameDock，再替换应用。更新保持同一签名证书和应用标识，权限通常会保留，但更新后请确认一下。

**卸载**：在设置中关闭“登录时启动”，从菜单退出，再把应用移到废纸篓；如需要，可在系统设置的“辅助功能”和“屏幕录制”列表中删除它。

## 权限

| 权限 | 用途 |
|---|---|
| **辅助功能** | 读取系统 Dock 的项目；切换、隐藏、退出应用；最小化、关闭、恢复窗口；让窗口避让底栏。 |
| **屏幕录制** | 仅用于最小化窗口缩略图。只截取已识别 Dock 窗口的图块区域（不含其他窗口和音频），图像只在内存中，不保存、不上传。未授权时其他功能照常，缩略图保持隐藏。 |

在 SameDock 中关闭某项功能不会撤销系统权限，可随时在系统设置中撤销。

## 从源码构建

需要 Apple 芯片 Mac，并安装 Xcode 或苹果命令行工具（Swift 5.9+）。

```sh
git clone https://github.com/<your-account>/samedock.git
cd samedock

# 构建临时（ad-hoc）签名的应用到新目录（脚本不会覆盖已有应用）
python3 build-local.py ./build/SameDock.app --allow-ad-hoc

# 运行测试（Swift Testing，使用命令行工具自带框架）
swift test --build-system native --disable-xctest --enable-swift-testing -j 4 \
  -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks
```

ad-hoc 构建每次代码身份都不同，重新构建后 macOS 可能要求重新授权。如需使用自己的持久证书签名，传入 `--signing-identity <SHA-1 指纹>`（或设置 `SAMEDOCK_SIGNING_IDENTITY`）。本仓库不包含任何私钥或签名材料。

Swift 包和源码目录仍沿用上游名称 `EchoDock`；应用标识为 `app.docklune.mac`。

重新生成代码绘制的图标：

```sh
swift scripts/make-icon.swift EchoDock/Resources
iconutil -c icns EchoDock/Resources/Docklune.iconset -o EchoDock/Resources/AppIcon.icns
```

## 现状与已知局限

- 主要在一台 Apple 芯片 Mac（外接显示器位于内置屏上方）上测试；显示器热插拔、睡眠唤醒、投影仪和长时间运行的测试有限。
- 未经苹果公证（见“安装”）。
- 发布版不支持 Intel Mac。

欢迎通过 [Issues](../../issues) 反馈问题或提交 Pull Request。

## 致谢与许可

SameDock 是 **[EchoDock](https://github.com/baikaihao/EchoDock)**（Copyright (C) 2026 baikaihao，GNU Affero 通用公共许可证第 3 版，仅此版本）的修改版。SameDock 自身的改动（原生 Dock 同步与定位、缩略图、窗口避让、SameDock 名称与图标，以及 [CHANGELOG.md](CHANGELOG.md) 中列出的其他改动）以相同许可证发布。详见 [NOTICE.md](NOTICE.md)。

本程序按“原样”提供，**不附带任何担保**。完整条款见 [LICENSE](LICENSE)。SameDock 与苹果公司及 EchoDock 作者无关联，也未获其认可。
