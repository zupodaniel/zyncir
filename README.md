# zyncir — macOS ↔ Android - clipboard sync

A focused menu-bar utility that keeps the **macOS** and **Android** clipboards in
sync, both directions, over Wireless Debugging. Pair once; it auto-reconnects on
the LAN whenever the phone is reachable. It does **one thing**: clipboard sync +
autoconnect. File transfer, mirroring, and notifications are intentionally left
to other tools (scrcpy, LocalSend, KDE Connect).

## Why this exists

Since **Android 10**, only the focused app or the default IME may read the
clipboard — a background app cannot. That is why most tools require a manual
button for the Android → Mac direction. zyncir sidesteps this the same way
scrcpy does: a tiny helper launched via `adb` runs as the **shell user**
(`com.android.shell`), which the clipboard service permits. The helper is
**event-driven** (`OnPrimaryClipChangedListener`) — it does work only when the
clipboard actually changes, so it does **not** poll or drain the battery.

## Requirements

- **macOS 13+**
- **Android 15+** (API 35), with Developer Options → **Wireless debugging** enabled
- **Android platform-tools** (`adb`) — the same one Android Studio uses
- Xcode / Swift toolchain and the Android SDK (platform `android-35`, build-tools `35.0.0`) to build

## Build

```sh
./build.sh
```

This builds `android-helper/build/zyncir.jar` (javac + d8, no Gradle), embeds
it into the macOS app, and produces `mac-app/.build/release/zyncird`.

## Run

```sh
mac-app/.build/release/zyncird
```

A clipboard glyph appears in the menu bar. Use **Pair device…**, enter the code
shown on the phone's *Pair device with pairing code* screen, and you're done —
it reconnects automatically thereafter.

> During development you can point the app at a freshly built jar without
> rebuilding the bundle: `ZYNCIR_JAR=android-helper/build/zyncir.jar mac-app/.build/release/zyncird`

## How it works

```
macOS menu-bar app                          Android 15+
  Pairing UI ── adb pair ───────────────▶  Wireless debugging
  Autoconnect ─ adb mdns services ──────▶  _adb-tls-connect._tcp
              ─ adb -s <ip:port> connect
  Bridge ───── adb forward tcp:0 ────────▶ localabstract:zyncir
        NSPasteboard ⇄ TCP (len-prefixed UTF-8) ⇄ app_process helper
                                              FakeContext → ClipboardManager
                                              OnPrimaryClipChangedListener
```

- **Transport:** adb over Wireless Debugging. Discovery uses adb's built-in mDNS
  (macOS `mDNSResponder` is always-on); the connect port is randomized per
  session, so the device's stable mDNS instance name is the identity.
- **Helper launch:** `adb shell CLASSPATH=/data/local/tmp/zyncir.jar app_process / com.zyncir.Server`
- **Loop guard:** both ends track the last value synced in each direction and
  suppress echoes, so a copy does not ping-pong.
- **Privacy:** clipboard content travels only over the local adb channel — never
  a cloud — and is **never written to logs** on either side.

## Coexistence with Android Studio / scrcpy

Designed to be a well-behaved adb citizen:

- **Reuses your existing `adb`** (resolved from `$ANDROID_HOME`/`$ANDROID_SDK_ROOT`/
  `~/Library/Android/sdk`/`PATH`), so the shared adb server is never killed by a
  version mismatch. Override with the `ADB` env var if needed.
- **Always `adb -s <serial> …`**, so it never hijacks the IDE's selected device
  or trips "more than one device" when the phone is also on USB.
- Uses a unique `localabstract:zyncir` socket (scrcpy uses `scrcpy`) and an
  OS-allocated forward port. It **never** calls `adb kill-server`; if the IDE
  restarts the server, zyncir just reconnects.

## Functions

- **Pairing:** phone → Wireless debugging → *Pair with code*; app → **Pair device…** → enter code.
- **Android → Mac:** copy text on the phone (app not focused); `pbpaste` on the Mac shows it within ~1 s.
- **Mac → Android:** `pbcopy` on the Mac; paste into a phone text field.
- **Loop guard:** copy once on each side; the value must not ping-pong or duplicate.
- **Autoconnect:** toggle the phone's Wi-Fi off/on; the app returns to *Connected* with no re-pairing.
- **Restart resilience:** quit and relaunch the app; it reconnects automatically.
- **Power:** with the helper running idle, `adb shell top -n 1 | grep app_process` shows it is not busy-looping.
- **Coexistence:** with Android Studio open and a USB device attached, start zyncir over wireless; `adb devices`
   shows both transports, no "version doesn't match / killing server" appears, and a running scrcpy session is unaffected.

## Licensing

Apache-2.0. The device helper adapts scrcpy's `FakeContext`, `Workarounds`, and
`ClipboardManager` (Apache-2.0); see `NOTICE` and the per-file headers.
