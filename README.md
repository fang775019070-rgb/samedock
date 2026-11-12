# SameDock

**Your Dock. Every screen.** · [简体中文](README.zh-CN.md)

SameDock is a free, open-source macOS app that shows a Dock on the other screens of a multi-display Mac. It follows the system Dock: the same apps, running indicators and minimized-window thumbnails appear on every screen you enable, while the screen that currently hosts the macOS Dock is left alone so the two never overlap.

SameDock is a fork of [EchoDock](https://github.com/baikaihao/EchoDock) by **baikaihao**, and is licensed under the **GNU AGPL v3.0 only** like the original. See [Credits and license](#credits-and-license).

Website: <https://samedock.fang775019070.chatgpt.site>

> Screenshots: none are included yet.

## Features

- **A Dock on each enabled display.** Bottom, left, right or top position. The display with the system Dock is detected and excluded automatically; new displays can be enabled automatically.
- **Follows the system Dock.** Pinned apps, running apps and indicators are read from the macOS Dock. You can switch apps, show or hide them, quit them and restore their windows from any screen.
- **Minimized-window thumbnails** (macOS 14+). They appear in SameDock as in the system Dock; click one to restore that window. Captures are limited to the Dock's own item area, kept in memory only, and never written to disk or uploaded.
- **Trash and Eject.** Drop files to move them to Trash (with undo), or drop a mounted disk to eject it safely.
- **Keeps windows clear of the bar.** Optional: maximized, zoomed or newly opened windows on a SameDock screen are kept above the bar, while windows you drag over it yourself are left where you put them.
- **Dock-style look and feel:** magnification, launch bounce, icon size and spacing, glass or blurred backgrounds, hide in full screen, hide when idle.
- **Native Dock placement helper:** optionally pin the macOS Dock to a chosen display.
- English and Simplified Chinese interface (follows the macOS language). Launch at Login. No analytics, no accounts, no automatic network updates.

SameDock does not replace or modify the macOS Dock and does not change hardware display limits.

## Requirements

- A Mac with **Apple silicon** (release builds are arm64 only).
- **macOS 13 Ventura or later**; window thumbnails need **macOS 14 Sonoma or later**.
- **System Settings → Desktop & Dock → "Displays have separate Spaces"** turned on (SameDock reminds you if it is off).

## Install

1. Download the latest `SameDock-x.y.z-arm64.zip` from [Releases](../../releases) (or from the website), unzip it and move `SameDock.app` to **Applications**.
2. Open it. Release builds are signed with the developer's own certificate. They are **not** signed with an Apple Developer ID and **not notarized** by Apple, so macOS will block the first launch:
   - Open **System Settings → Privacy & Security**, scroll down, and click **Open Anyway** next to the SameDock message, then confirm. ([Apple's instructions](https://support.apple.com/102445))
   - Only do this if you trust the download. Managed Macs may not allow it.
3. Follow the two permission steps SameDock shows on first launch (see below). If macOS asks you to quit and reopen the app, do so.

Updates are manual: quit SameDock, then replace the app. Because updates keep the same signing certificate and bundle ID, permissions normally carry over, but check them after an update.

**Uninstall:** turn off Launch at Login in SameDock's settings, quit it from its menu, and move the app to the Trash. Remove it from the Accessibility and Screen Recording lists in System Settings if you like.

## Permissions

| Permission | Why |
|---|---|
| **Accessibility** | To read the system Dock's items, switch, hide and quit apps, minimize, close and restore windows, and keep windows clear of the bar. |
| **Screen Recording** | Only for minimized-window thumbnails. SameDock captures just the item area of the identified Dock window (no other windows, no audio), keeps the image in memory, and never saves or uploads it. Without it, everything else still works and thumbnails stay hidden. |

Turning a feature off in SameDock does not revoke the macOS permission; you can revoke it in System Settings at any time.

## Build from source

Needs an Apple silicon Mac with Xcode or Apple's Command Line Tools (Swift 5.9+).

```sh
git clone https://github.com/<your-account>/samedock.git
cd samedock

# Build an ad-hoc signed app into a new folder (the script refuses to overwrite).
python3 build-local.py ./build/SameDock.app --allow-ad-hoc

# Run the tests (Swift Testing, using the Command Line Tools frameworks).
swift test --build-system native --disable-xctest --enable-swift-testing -j 4 \
  -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks
```

An ad-hoc build gets a new code identity each time, so macOS may ask you to grant the permissions again after rebuilding. To sign with your own persistent certificate instead, pass `--signing-identity <SHA-1 fingerprint>` (or set `SAMEDOCK_SIGNING_IDENTITY`). No private key or signing material is part of this repository.

The Swift package and source folders still use the upstream name `EchoDock`; the app's bundle identifier is `app.docklune.mac`.

To regenerate the code-drawn icon:

```sh
swift scripts/make-icon.swift EchoDock/Resources
iconutil -c icns EchoDock/Resources/Docklune.iconset -o EchoDock/Resources/AppIcon.icns
```

## Status and known limits

- Tested mainly on one Apple silicon Mac with an external display above the built-in screen. Hot-plugging displays, sleep/wake, projectors and long-running use have had limited testing.
- Not notarized by Apple (see Install).
- Intel Macs are not supported by the release builds.

Bug reports and pull requests are welcome via [Issues](../../issues).

## Credits and license

SameDock is a modified version of **[EchoDock](https://github.com/baikaihao/EchoDock)**, Copyright (C) 2026 baikaihao, licensed under the GNU Affero General Public License version 3 only. SameDock's own changes (native Dock sync and placement, thumbnails, window clearance, the SameDock name and icon, and others listed in [CHANGELOG.md](CHANGELOG.md)) are released under the same license. See [NOTICE.md](NOTICE.md).

This program is distributed in the hope that it will be useful, but **without any warranty**. See [LICENSE](LICENSE) for the full terms. SameDock is not affiliated with or endorsed by Apple or the EchoDock author.
