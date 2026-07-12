# zyncir — macOS ↔ Android - clipboard sync

A focused menu-bar utility that keeps the **macOS** and **Android** clipboards in
sync, both directions, over Wireless Debugging — and moves files between the two.
Pair once; it auto-reconnects on the LAN whenever the phone is reachable. It stays
deliberately small: clipboard sync, simple file transfer, and autoconnect, with
screen mirroring delegated to scrcpy.

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
- An **Apple code-signing identity** (e.g. *Apple Development*) to sign the app.
  This is required, not cosmetic: on **macOS 15+ (Sequoia/Tahoe)**, Local Network
  Privacy only grants LAN access to a code-signed app, so wireless `adb connect`
  is silently blocked for an unsigned build. List yours with
  `security find-identity -v -p codesigning`.

## Build

```sh
git clone https://github.com/zupodaniel/zyncir
cd zyncir

# Provide your code-signing identity (required). Either copy the template…
cp mac-app/packaging/signing.local.example mac-app/packaging/signing.local
#   …then edit signing.local and set CODESIGN_ID to your identity,
# or just export it for this shell:
export CODESIGN_ID="Apple Development: Your Name (TEAMID)"

./build.sh
```

This builds `android-helper/build/zyncir.jar` (javac + d8, no Gradle), embeds it
into the macOS app, assembles a `.app` bundle, and **code-signs** it — producing
`mac-app/.build/release/zyncir.app`. `signing.local` is gitignored, so your
identity never lands in the repo.

## Run

Open the built app in **Finder**: double-click
`mac-app/.build/release/zyncir.app`, or move it to `/Applications` and launch it
there. A clipboard glyph appears in the menu bar. Use **Pair new device (Wi-Fi)…**,
enter the code shown on the phone's *Pair device with pairing code* screen, and
you're done — it reconnects automatically thereafter. Quit from the menu's
**Quit zyncir**.

On the **first wireless connection**, macOS prompts *"zyncir would like to find
devices on your local network"* — click **Allow** (required for wireless adb).

> Launch it **as a bundle** (Finder, or `open zyncir.app`), not the raw
> `Contents/MacOS/zyncird` binary — only the bundle carries the signed identity
> the Local Network grant attaches to. (USB works either way.)
>
> Optional developer helper: `./zyncir` builds (if needed) and launches the app;
> `./zyncir --build` forces a rebuild + relaunch; `./zyncir --stop` quits it.

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
- **Privacy:** clipboard content and transferred files travel only over the local
  adb channel — never a cloud — and file contents/names are **never written to
  logs** on either side.
- **macOS Local Network:** the connection to the phone is made by the adb server
  zyncir spawns; on macOS 15+ that requires Local Network permission, which is why
  zyncir ships as a signed `.app` — the grant attaches to its identity and
  persists across rebuilds.

## File transfer

Alongside the clipboard, zyncir moves whole files over the same adb connection
(via `adb push`/`adb pull` — file bytes never touch the clipboard channel). Two
device folders under Downloads are created automatically while connected:

- `Download/zyncir/` — files **sent from the Mac** land here.
- `Download/zyncir/send/` — drop a file here **on the phone** (Files app → *Move
  to* / *Copy to*) to send it to the Mac.

**Mac → Android:** menu **Send file(s) to device…** → pick one or more files;
they're pushed to `Download/zyncir/` (a best-effort media scan makes images/video
show up in Gallery).

**Android → Mac:** while connected, zyncir watches `Download/zyncir/send/` (~2 s),
pulls any new file into `~/Downloads` (never overwriting — it appends " (2)",
" (3)", …), removes the device copy, drops the file on the Mac clipboard so you
can paste it immediately, and posts a notification (tap it to reveal the file in
Finder). Files larger than **100 MB** are not pulled automatically — a
notification with a **Download** action surfaces them instead, so a large transfer
stays behind an explicit tap.

## Coexistence with Android Studio / scrcpy

Designed to be a well-behaved adb citizen:

- **Reuses your existing `adb`** (resolved from `$ANDROID_HOME`/`$ANDROID_SDK_ROOT`/
  `~/Library/Android/sdk`/`PATH`), so the shared adb server is never killed by a
  version mismatch. Override with the `ADB` env var if needed.
- **Always `adb -s <serial> …`**, so it never hijacks the IDE's selected device
  or trips "more than one device" when the phone is also on USB.
- Uses a unique `localabstract:zyncir` socket (scrcpy uses `scrcpy`) and an
  OS-allocated forward port. It **never** kills the adb server on its own; if the
  IDE restarts the server, zyncir just reconnects. (A manual **Restart adb server**
  menu item reclaims the server under zyncir and reconnects, if a terminal/IDE
  respawned it under an owner without Local Network access.)

## Menu

The menu-bar item shows the connection status, the count of available devices,
and these actions:

- **Mirror screen (scrcpy)** — launch scrcpy against the connected device (shown when a device is paired).
- **Send file(s) to device…** — push chosen files to the device's `Download/zyncir/` folder (shown when connected).
- **Select device (N)…** — pick which connected device to sync with; `N` is how many are available.
- **Pair new device (Wi-Fi)…** — first-time Wireless-debugging pairing by code.
- **Forget device** — clear the saved pairing (shown when a device is paired).
- **Restart adb server** — kill the adb server and restart it *from zyncir* (so the new server is owned by the signed app and keeps Local Network access for wireless adb), then reconnect. Use it to reclaim adb after a terminal/IDE respawned the server.
- **Quit zyncir**.

## Functions

- **Pairing:** phone → Wireless debugging → *Pair with code*; app → **Pair new device (Wi-Fi)…** → enter code.
- **Android → Mac:** copy text on the phone (app not focused); `pbpaste` on the Mac shows it within ~1 s.
- **Mac → Android:** `pbcopy` on the Mac; paste into a phone text field.
- **Mac → Android files:** **Send file(s) to device…**, pick a file; it appears in the phone's Files app under `Download/zyncir/`.
- **Android → Mac files:** move a file into `Download/zyncir/send/` on the phone; within ~2 s it lands in `~/Downloads` and on the Mac clipboard.
- **Loop guard:** copy once on each side; the value must not ping-pong or duplicate.
- **Autoconnect:** toggle the phone's Wi-Fi off/on; the app returns to *Connected* with no re-pairing.
- **Restart resilience:** quit and relaunch the app; it reconnects automatically.
- **Power:** with the helper running idle, `adb shell top -n 1 | grep app_process` shows it is not busy-looping.
- **Coexistence:** with Android Studio open and a USB device attached, start zyncir over wireless; `adb devices`
   shows both transports, no "version doesn't match / killing server" appears, and a running scrcpy session is unaffected.

## Licensing

Apache-2.0. The device helper adapts scrcpy's `FakeContext`, `Workarounds`, and
`ClipboardManager` (Apache-2.0); see `NOTICE` and the per-file headers.

## Author

Created by **Daniel Zupo** — https://github.com/zupodaniel
(project: https://github.com/zupodaniel/zyncir).
