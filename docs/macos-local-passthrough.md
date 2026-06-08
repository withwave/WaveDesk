# Fork features (macOS)

This fork adds two desktop client features:

1. **`Ctrl + Arrow` local passthrough** (macOS) — toggle in the remote
   toolbar's keyboard menu. Off by default; only passes when checked. Backed by
   the global local option `allow-ctrl-arrow-local`, read directly by the grab
   loop. See below.
2. **Always start remote session in full screen** — global option in the
   **main window** Settings → General → Other, next to "Open connection in new
   tab" (`kOptionStartRemoteFullscreen` = `"start-remote-fullscreen"`). On by
   default. When a new remote-desktop **window** opens, it enters full screen
   by reusing the existing fullscreen path in `restoreWindowPosition()`
   (`flutter/lib/common.dart`) — the same `stateGlobal.setFullscreen(true)` /
   `kWindowEventSetFullscreen` the toolbar's "Enter full screen" uses. The
   option is added as an extra trigger to the existing `lpos.isFullscreen`
   branch (saved-position path) and to the no-saved-position path, gated to
   `WindowType.RemoteDesktop`. Because the key is not prefixed `enable-`/
   `allow-`, an unset value resolves to `true` (default on); unchecking stores
   `"N"`. It lives in the main window (not a per-session toolbar) because it
   governs how *future* connections open. Note: this applies when a new
   **window** is created; adding a connection as a tab to an existing window
   keeps RustDesk's existing behavior (the tab handler exits fullscreen to
   reveal the new tab).

---

# macOS Local Passthrough — `Ctrl + Arrow` to Mission Control

## Summary

While controlling a remote host from a **macOS** client, RustDesk's keyboard
hook normally forwards every keystroke to the remote and suppresses it locally.
This means macOS's built-in Spaces shortcuts (`Ctrl + ←/→/↑/↓`, used by Mission
Control to switch desktops) stop working on the local Mac during a session.

This feature lets the macOS client **pass `Ctrl + Arrow` to the local OS** so
local Spaces switching keeps working, while leaving every other key combination
(including `Ctrl + C/V`, plain typing, etc.) sent to the remote unchanged.

The feature is **off by default** and is toggled **per session** from the remote
toolbar's keyboard menu: *"Pass Ctrl+Arrow to local (Mission Control)"*.

## Behavior

| Input | Local macOS | Remote host |
|---|---|---|
| `Ctrl ↓` (press) | Ctrl recognized (passthrough) | Ctrl press received |
| `← ↓` (arrow press) | Arrow → **Spaces switch** | nothing received |
| `← ↑` (arrow release) | Arrow release | nothing received |
| `Ctrl ↑` (release) | Ctrl release (passthrough) | Ctrl release received |
| `Ctrl + C`, typing, … | (unchanged) | sent to remote (unchanged) |

- **Local:** `Ctrl↓ → ← → Ctrl↑` forms a complete chord → Spaces switch works.
- **Remote:** only sees a harmless `Ctrl↓ → Ctrl↑` tap (no orphan arrow key,
  no stuck modifier).

The `Ctrl` key itself is intentionally sent to **both** local and remote: the
remote needs the modifier state kept in sync, and the local OS needs `Ctrl` held
for the Mission Control chord to form. Only the **arrow** key is withheld from
the remote.

## Implementation

Platform-guarded to macOS (`#[cfg(target_os = "macos")]`). Windows/Linux Spaces
semantics differ and are out of scope.

### Rust — `src/keyboard.rs`
Inside `start_grab_loop()`'s `try_handle_keyboard` grab callback (after the
CapsLock guard, before the main remote-forwarding logic):

- `OPTION_CTRL_ARROW_LOCAL` (`"allow-ctrl-arrow-local"`) — global local option
  key.
- `is_ctrl_arrow_local_enabled()` — `LocalConfig::get_option(...) == "Y"`. A
  global read (not a per-session lookup), so it is reliable from the grab loop
  thread and consistent across windows. Off by default (only `"Y"` enables).
- `is_local_passthrough_chord(key)` — true for an arrow key while a `Ctrl`
  modifier is held (read from `MODIFIERS_STATE`).
- The passthrough block runs only when the hook is active, the key is a
  Ctrl/Arrow key, and the option is enabled — so the per-keystroke option read
  is skipped for all other keys.

The rdev grab callback returns `Some(event)` to pass an event to the local OS,
or `None` to consume it. The block returns `Some(event)` for `Ctrl` (after also
forwarding it to the remote) and for `Ctrl + Arrow` (without forwarding).

### Flutter UI
- `flutter/lib/consts.dart` — `kOptionCtrlArrowLocal = "allow-ctrl-arrow-local"`
  (must match the Rust constant; the `allow-` prefix makes the bool helpers
  default to off).
- `flutter/lib/common/widgets/toolbar.dart` — `toolbarKeyboardToggles()` adds a
  checkbox in the keyboard menu when the **local** machine is macOS. It reads/
  writes the global local option (`mainGetLocalBoolOptionSync` /
  `mainSetLocalOption` + `bool2option`), the same plumbing the grab loop reads.
- `src/lang/en.rs`, `src/lang/ko.rs` — UI string translations.

## Notes / Gotchas

- **Modifier orphan:** passing only the arrow (not `Ctrl`) to the local OS would
  leave the local side with a bare arrow and no Ctrl, so the Spaces chord would
  fail. Forwarding `Ctrl` to the local OS is required.
- **Local side effect:** while enabled, the local OS also sees `Ctrl` presses
  even though RustDesk is focused. A bare `Ctrl` tap is harmless; this is why the
  feature is opt-in.
- **Scope:** macOS client only; off by default; global toggle (applies to all
  sessions once enabled).
