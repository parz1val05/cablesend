#!/usr/bin/env bash
# Wires the Android foreground service + permissions into the project made by `flutter create`.
# Safe to run twice. Usage: tools/apply_android.sh [path/to/app]   (default: app)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${1:-$ROOT/app}"
python3 - "$APP" "$ROOT/app/native/android" <<'PY'
import os, re, sys
app, tmpl = sys.argv[1], sys.argv[2]
manifest = os.path.join(app, "android/app/src/main/AndroidManifest.xml")
if not os.path.isfile(manifest):
    sys.exit(f"{manifest} not found: run `flutter create --platforms=android .` in {app} first")

# package of the existing MainActivity (Kotlin or Java)
main_dir = os.path.join(app, "android/app/src/main")
found = None
for dp, _, fs in os.walk(main_dir):
    for f in fs:
        if f in ("MainActivity.kt", "MainActivity.java"):
            found = os.path.join(dp, f)
if not found:
    sys.exit("MainActivity not found")
src = open(found, encoding="utf-8").read()
m = re.search(r"^\s*package\s+([\w.]+)", src, re.M)
if not m:
    sys.exit("cannot read package from MainActivity")
pkg = m.group(1)
dest_dir = os.path.dirname(found)

# Java MainActivity is replaced by the Kotlin one
if found.endswith(".java"):
    os.rename(found, found + ".bak")
    found = os.path.join(dest_dir, "MainActivity.kt")
for name, out in (("ReceiveService.kt.tmpl", "ReceiveService.kt"), ("MainActivity.kt.tmpl", "MainActivity.kt")):
    text = open(os.path.join(tmpl, name), encoding="utf-8").read().replace("__PKG__", pkg)
    open(os.path.join(dest_dir, out), "w", encoding="utf-8").write(text)

x = open(manifest, encoding="utf-8").read()
perms = [
    "android.permission.INTERNET",
    "android.permission.ACCESS_WIFI_STATE",
    "android.permission.CHANGE_WIFI_MULTICAST_STATE",
    "android.permission.FOREGROUND_SERVICE",
    "android.permission.FOREGROUND_SERVICE_DATA_SYNC",
    "android.permission.POST_NOTIFICATIONS",
]
add = "".join(f'    <uses-permission android:name="{p}"/>\n' for p in perms if p not in x)
if add:
    x = re.sub(r"(\s*)<application", lambda mm: "\n" + add.rstrip("\n") + mm.group(0), x, count=1)
svc = f'<service android:name="{pkg}.ReceiveService" android:exported="false" android:foregroundServiceType="dataSync"/>'
if "ReceiveService" not in x:
    x = x.replace("</application>", f"    {svc}\n    </application>", 1)
open(manifest, "w", encoding="utf-8").write(x)
print(f"OK: package {pkg}; manifest and Kotlin files updated")
PY
