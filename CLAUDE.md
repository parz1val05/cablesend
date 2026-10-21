# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

CableSend is a LocalSend-like file transfer tool that works **over cables** (Ethernet/Thunderbolt as IP, ADB for Android, usbmuxd for iOS). A std-only Rust core plus a Flutter UI. Project docs, UI strings and code comments in the app are in Russian.

## Commands

Rust core (repo root, no external crates — `Cargo.toml` intentionally has no dependencies):
```
cargo build --release                  # CLI binary target/release/cablesend + cdylib/staticlib
cargo test                             # all core tests (CI runs `cargo test --release`)
cargo test safe_names                  # single test by name
python tools/ffi_smoketest.py <tmpdir> # C ABI check via ctypes; needs `cargo build` first and
                                       # hardcodes /home/claude/.../libcablesend.so — fix the path
```

Flutter app (`app/`, needs Flutter >= 3.27 because of `CardThemeData`). Platform folders (`android/`, `windows/`, …) are **not committed**; they are generated:
```
cd app
flutter create --platforms=windows,android --project-name cablesend_app --org com.cablesend .
git checkout -- lib pubspec.yaml analysis_options.yaml README.md   # flutter create may overwrite these
flutter pub get
flutter analyze --no-fatal-infos
CABLESEND_BIN=<path to cablesend(.exe)> flutter run -d windows     # without the core binary the app starts in demo mode
```

Android: `tools/build_android.sh` (cargo-ndk → `jniLibs/<abi>/libcablesend.so`), then `tools/apply_android.sh app` (idempotently patches manifest, `ReceiveService`, `MainActivity` from `app/native/android/*.kt.tmpl`). iOS: `tools/build_ios.sh` on a Mac, then manual Xcode steps in `NATIVE.md`.

CI (`.github/workflows/build.yml`) is the only place the Dart code and the APK/Windows builds are actually compiled: `check` (Rust tests + `flutter analyze`) → `android` / `windows` artifacts.

## Architecture

**Core (`src/`).** Every cable is reduced to a byte stream; protocol and transfer logic are written once.
- `proto.rs` — framing: `u32 BE length` + UTF-8 text, fields separated by `\t`. Flow: `HELLO` both ways → `OFFER n` + n×`FILE size name` → `ACCEPT`/`REJECT` → per file raw bytes, `END sha256`, `OK`/`ERR`.
- `transfer.rs` — send/receive. Safety invariants to preserve: `safe_name` sanitization (path traversal, Windows reserved names/chars, 150-byte limit), writes go to `<final name>.part` (`.part1`, … if taken) and are renamed only after SHA-256 matches, receive dir is prepared *before* asking the user, a connection that closes before `OFFER` is a liveness probe and must not be reported as an error.
- `discovery.rs` — UDP beacon `CABLESEND2` on 53318 carrying an instance id; peers with our own id are dropped and duplicates merged by id.
- `transport.rs` — ADB (`adb forward`/`reverse`, adb located automatically, forward rule removed in `AdbStream::drop`) and usbmuxd (legacy binary protocol; Unix socket or TCP 127.0.0.1:27015 on Windows). Hardware paths are untested.
- `sha256.rs`, `json.rs` — hand-rolled because of the no-dependencies rule.
- `main.rs` — CLI (`receive`, `send`, `peers`, `devices`, `--json` event output). `ffi.rs` — C ABI (`cs_*`, 8 functions on C strings, no callbacks; events pulled via `cs_next_event`). Incoming connections are handled one at a time, so `cs_answer` has no transfer id.

Ports: **53317** TCP receive, **53318** UDP beacon, **53320** phone→PC tunnel (`receive --adb-reverse`).

**App (`app/lib/`).** `AppController` (ChangeNotifier) talks to the abstract `Backend` (`backend/backend.dart`), which has three implementations that must emit identical `BackendEvent`/`Peer`:
- `CliBackend` (desktop) — spawns `cablesend … --json` and parses lines. `receive` and `peers` are separate processes, so it passes them the same `--id` (`_instanceId`); otherwise the PC discovers itself.
- `FfiBackend` (Android/iOS) — `dart:ffi` to `src/ffi.rs`, polls events every 100 ms.
- `DemoBackend` — fake data when the core is missing.

The JSON event schema is shared by the CLI `--json` output, `ffi.rs` and `backend/event_parser.dart` — change all three together (e.g. CLI uses `folder` for the directory, `dir` means transfer direction `in`/`out`; iOS mux id is `mux_id`, not `state`). `CONFLICTS.md` records past mismatches of exactly this kind.

## Notes

- `legacy/` is an older, incompatible Python prototype (HTTP, port 53320 clash). Not part of the build.
- No encryption or peer authentication yet; only manual accept protects the receiver.
- The Dart, Kotlin and real-device ADB/usbmuxd paths have never been verified locally; Rust core and C ABI are the tested parts.
