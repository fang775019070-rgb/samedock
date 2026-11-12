# Changelog

Condensed from the project's release notes. SameDock is a fork of
[EchoDock](https://github.com/baikaihao/EchoDock); earlier history belongs to that project.

## 1.1.10 — 2026-11-12
- Windows are kept clear of the SameDock bar after the app itself moves, zooms or restores them (e.g. a Word document zoomed to full height), and windows already open when SameDock starts are checked once. Windows the user drags over the bar are left alone; adjustments per window are capped so SameDock never fights an app.

## 1.1.9 — 2026-11-12
- Newly opened free-size windows (e.g. Excel workbooks) whose bottom ran under the bar are moved up or shortened. This happened because, with the system Dock on another screen, macOS reports the full screen height as usable.

## 1.1.8 — 2026-11-10
- Fixed a one-frame flash of the whole bar when a minimized-window thumbnail is removed (window closed, restored, or its app quit).

## 1.1.7 — 2026-11-10
- Thumbnails no longer all vanish and reappear when an app launches or quits; a closing window's tile collapses smoothly; thumbnails captured mid-animation no longer replace good ones.

## 1.1.6 — 2026-11-10
- Faster thumbnails after minimizing (median about 0.8 s on the test Mac, down from about 1.8 s) and cleaner cropping of dark windows (no black edges).

## 1.1.5 — 2026-11-06
- Interface follows the macOS language (English / Chinese). Clearer permission states; the welcome card closes once permissions work. Release builds require an explicit persistent signing identity and use the Hardened Runtime; source builds can use `--allow-ad-hoc`.

## 1.1.4 — 2026-11-06
- "Reserve space for windows" is on by default again and uses only the screens that show SameDock; full-screen windows are protected.

## 1.1.3 — 2026-11-06
- Unified first-run and permissions card. Permission prompts only from user action. Window entries without a valid thumbnail stay hidden until one is captured; capture failures retry with limits.

## 1.1.2 — 2026-11-06
- Renamed to SameDock (bundle ID and settings keys unchanged).

## 1.1.1 — 2026-11-06 (as Docklune)
- Automatic placement: keep the system Dock on the built-in screen and show the companion Dock on external screens. Trash ejects mounted disks safely instead of deleting.

## 1.1.0 — 2026-11-06 (as Docklune)
- First release of the fork: automatic detection and exclusion of the system Dock's screen, sync of native Dock items and minimized-window thumbnails after permission, simplified settings, fixes for empty thumbnails and black edges.
