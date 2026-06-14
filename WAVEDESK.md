# WaveDesk

**WaveDesk** is a macOS-focused fork of [RustDesk](https://github.com/rustdesk/rustdesk)
maintained by MODIN COMPANY. It adds a few macOS quality-of-life features and a
distinct app identity, while staying as close to upstream as possible so it can
be rebased easily.

The fork keeps the diff from upstream intentionally small. All changes are
captured as a single patch (`patches/wavedesk.patch`) that can be re-applied to a
fresh upstream checkout with `scripts/apply-wavedesk.sh`.

---

## Features

### 1. macOS `Ctrl + Arrow` local passthrough
While controlling a remote host, the macOS keyboard hook normally forwards every
keystroke to the remote, so the local Mac's Mission Control / Spaces shortcuts
(`Ctrl + ←/→/↑/↓`) stop working. This feature optionally passes `Ctrl + Arrow`
to the **local** OS instead.

- Toggle: remote session toolbar → keyboard menu → **"Pass Ctrl+Arrow to local
  (Mission Control)"**. Off by default.
- **Instant toggle hotkey: `Ctrl + Shift + \`** — flips the option on/off mid
  session without opening the menu (handled in the grab loop, then consumed).
- Backed by the global local option `allow-ctrl-arrow-local`, read directly by
  the rdev grab loop (`src/keyboard.rs`). `Ctrl` is sent to both remote and
  local (to avoid an orphan modifier); only the arrow is withheld from the
  remote.
- Requires the keyboard grab (Input source 1 / Input Monitoring permission).

### 4. Mouse wheel sensitivity (per connection)
macOS emits many high-frequency momentum scroll events; sending one wheel tick
per event over-scrolls the remote. WaveDesk accumulates the raw scroll delta and
emits ticks proportional to the actual physical scroll distance, scaled by an
adjustable sensitivity.

- Adjust: remote session toolbar → mouse menu → **"Mouse wheel speed"**
  (10–300%, default 100%). Higher = more scroll per physical wheel movement.
- **Saved per connection** in the peer's flutter options
  (`sessionGetFlutterOption` / `sessionSetFlutterOption`, key `wheel-speed`), so
  each remote machine keeps its own setting. macOS local client only.
- Implemented in `flutter/lib/models/input_model.dart`
  (`onPointerSignalImage`, `updateWheelSpeed` / `setWheelSpeed`).

### 2. Always start remote session in full screen
New remote-desktop windows can start in full screen automatically.

- Toggle: **main window** Settings → General → Other → **"Always start remote
  session in full screen"** (next to "Open connection in new tab"). On by
  default.
- Option `start-remote-fullscreen`. Reuses the existing fullscreen path in
  `restoreWindowPosition()` (`flutter/lib/common.dart`) — the same
  `setFullscreen(true)` / `kWindowEventSetFullscreen` the toolbar's "Enter full
  screen" uses.

### 3. Prompt for Input Monitoring on explicit input-source switch
When the user explicitly selects **Input source 1** (rdev grab), the app now
prompts for the "Input Monitoring" permission instead of failing silently
(`change_input_source` uses `is_can_input_monitoring(true)`). This is needed for
a separately-signed fork that doesn't inherit upstream's permission grant.

---

## Branding & identity

| Aspect | Upstream | WaveDesk |
|---|---|---|
| App name (Dock/Finder/menus/window) | RustDesk | **WaveDesk** |
| Bundle id (macOS TCC identity) | `com.carriez.rustdesk` | **`com.modin.rustdesk`** |
| Signing | RustDesk team | **Developer ID: MODIN COMPANY (8AC9KUZJ5P)** |
| App icon | RustDesk | WaveDesk wave icon (`flutter/macos/Runner/AppIcon.icns`) |
| **Connection settings** (peers/IDs/passwords) | — | **Shared with installed RustDesk** |

Key design points:

- **Settings are shared** with an installed RustDesk on the same machine because
  the config path is derived from the Rust `APP_NAME` ("RustDesk") and `ORG`
  ("com.carriez"), which are intentionally left unchanged. Only the *displayed*
  name is changed.
- **TCC permissions are independent** (Accessibility, Input Monitoring, Screen
  Recording) because the bundle id and signing certificate differ. WaveDesk must
  be granted these permissions separately — they cannot be inherited from a
  differently-signed app. The grant persists across rebuilds because the
  Developer ID designated requirement (`com.modin.rustdesk` + team `8AC9KUZJ5P`)
  is stable.
- The Swift module name is kept as `RustDesk` (`PRODUCT_MODULE_NAME = RustDesk`)
  so `MainMenu.xib`'s `customModule="RustDesk"` still resolves while
  `PRODUCT_NAME = WaveDesk` renames the executable / `.app`.

---

## Files changed vs upstream

- `src/keyboard.rs` — Ctrl+Arrow passthrough + global option; `Ctrl+Shift+\`
  toggle hotkey; input-source prompt.
- `flutter/lib/common.dart` — start-in-fullscreen; `getWindowName()` → "WaveDesk".
- `flutter/lib/common/widgets/toolbar.dart` — Ctrl+Arrow keyboard-menu toggle.
- `flutter/lib/desktop/pages/desktop_setting_page.dart` — fullscreen setting.
- `flutter/lib/models/input_model.dart` — macOS wheel accumulator + sensitivity.
- `flutter/lib/models/model.dart` — load wheel speed on session attach.
- `flutter/lib/common/widgets/dialog.dart` — "Mouse wheel speed" dialog.
- `flutter/lib/desktop/widgets/remote_toolbar.dart` — wheel-speed menu item.
- `flutter/lib/consts.dart` — option keys; wheel-speed bounds.
- `src/lang/en.rs`, `src/lang/ko.rs` — UI strings; permission prompts → "WaveDesk".
- `flutter/macos/Runner/Info.plist` — CFBundleName/DisplayName/URLName.
- `flutter/macos/Runner/Configs/AppInfo.xcconfig` — PRODUCT_NAME, PRODUCT_MODULE_NAME, bundle id.
- `flutter/macos/Runner.xcodeproj/project.pbxproj` — bundle id.
- `flutter/macos/Runner/AppIcon.icns` — WaveDesk icon.
- `docs/macos-local-passthrough.md` — feature design notes.

---

## Updating from upstream

When upstream RustDesk changes, re-apply the fork on a fresh checkout:

```bash
# in a fresh upstream checkout (or after `git reset --hard <upstream>`)
./scripts/apply-wavedesk.sh
```

The script applies `patches/wavedesk.patch` (a `git diff --binary` of all fork
changes, including the icon). Regenerate the patch after committing new fork
changes:

```bash
git diff --binary <upstream-base>..HEAD > patches/wavedesk.patch
```

---

## Build & sign (macOS arm64)

See the build steps in the project memory / `docs/`. In short:

```bash
# 1. native deps (vcpkg), bridge codegen, submodules — one-time
# 2. cargo build
VCPKG_ROOT=~/vcpkg MACOSX_DEPLOYMENT_TARGET=10.14 \
  cargo build --locked --features hwcodec,flutter --release
cp target/release/liblibrustdesk.dylib target/release/librustdesk.dylib
# 3. flutter build (Flutter 3.24.5)
( cd flutter && flutter build macos --release )   # -> WaveDesk.app
cp -rf target/release/service \
  flutter/build/macos/Build/Products/Release/WaveDesk.app/Contents/MacOS/
# 4. sign + notarize
codesign --force --deep --options runtime --timestamp \
  --entitlements flutter/macos/Runner/Release.entitlements \
  --sign "Developer ID Application: MODIN COMPANY (8AC9KUZJ5P)" WaveDesk.app
```
