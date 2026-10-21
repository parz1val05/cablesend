#!/usr/bin/env python3
"""
cablesend — прототип ядра: передача файлов между устройствами по КАБЕЛЮ.

Идея: любой кабель, который даёт IP-связь (Ethernet, USB-тетеринг/NCM/RNDIS,
Thunderbolt Bridge, USB-Ethernet адаптер, host-to-host USB-C cable с сетевым драйвером),
превращается в обычный сетевой интерфейс. Мы его находим, поднимаем link-local адрес
при необходимости, обнаруживаем соседа и гоним файл по HTTP с проверкой SHA-256 и докачкой.
Для Android без тетеринга: мост через ADB. Для iOS: мост через usbmuxd (iproxy).

Зависимости: Python 3.8+, psutil (pip install psutil).
"""
import argparse, hashlib, http.server, json, os, platform, shutil, socket, socketserver
import subprocess, sys, threading, time, urllib.request, urllib.error, urllib.parse

try:
    import psutil
except ImportError:
    sys.exit("Нужен psutil: pip install psutil")

HTTP_PORT = 53320
DISCO_PORT = 53321
CHUNK = 1 << 20
OS_NAME = platform.system()  # Windows / Linux / Darwin


# ───────────────────────── Интерфейсы / тип кабеля ─────────────────────────
def classify(name: str, loopback_ok=False) -> str:
    """Определяем вид кабельного канала по имени интерфейса (эвристика)."""
    n = name.lower()
    if n.startswith("lo") and n not in ("lo0x",):
        return "loopback" if loopback_ok else "skip"
    if any(k in n for k in ("docker", "veth", "br-", "virbr", "vmnet", "vbox", "tun", "tap",
                            "wg", "tailscale", "utun", "awdl", "llw", "vethernet", "zt")):
        return "skip"
    if any(k in n for k in ("wi-fi", "wifi", "wlan", "wlp", "wl0")):
        return "wifi"  # не кабель, но оставим как запасной вариант
    if any(k in n for k in ("rndis", "usb", "enx", "ncm", "rmnet", "bridge", "tbt", "thunderbolt")):
        return "usb/thunderbolt"
    if any(k in n for k in ("eth", "en", "ethernet", "eno", "enp")):
        return "ethernet"
    return "other"


def list_ifaces(loopback_ok=False, include_wifi=False):
    res = []
    stats = psutil.net_if_stats()
    for name, addrs in psutil.net_if_addrs().items():
        st = stats.get(name)
        if not st or not st.isup:
            continue
        kind = classify(name, loopback_ok)
        if kind == "skip" or (kind == "wifi" and not include_wifi):
            continue
        for a in addrs:
            if a.family == socket.AF_INET and a.address:
                res.append({"name": name, "kind": kind, "ip": a.address,
                            "mask": a.netmask, "bcast": a.broadcast,
                            "linklocal": a.address.startswith("169.254.")})
    return res


def needs_ip_hint(name: str) -> str:
    """Команды, чтобы вручную поднять link-local IP на кабельном интерфейсе (нужны права админа)."""
    last = (sum(map(ord, socket.gethostname())) % 250) + 2
    ip = f"169.254.77.{last}"
    if OS_NAME == "Linux":
        return f"sudo ip addr add {ip}/16 dev {name} && sudo ip link set {name} up"
    if OS_NAME == "Darwin":
        return f"sudo ifconfig {name} inet {ip} netmask 255.255.0.0 up"
    if OS_NAME == "Windows":
        return f'netsh interface ip set address name="{name}" static {ip} 255.255.0.0'
    return f"назначьте {ip}/16 интерфейсу {name}"


# ───────────────────────── Обнаружение соседей ─────────────────────────
class Discovery:
    def __init__(self, alias, http_port, loopback_ok=False, include_wifi=False):
        self.alias, self.http_port = alias, http_port
        self.loopback_ok, self.include_wifi = loopback_ok, include_wifi
        self.peers = {}  # key -> dict
        self.stop = threading.Event()

    def _payload(self):
        return json.dumps({"app": "cablesend", "alias": self.alias, "port": self.http_port,
                           "os": OS_NAME}).encode()

    def start(self):
        threading.Thread(target=self._listen, daemon=True).start()
        threading.Thread(target=self._announce, daemon=True).start()

    def _listen(self):
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        if hasattr(socket, "SO_REUSEPORT"):
            s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEPORT, 1)
        s.bind(("", DISCO_PORT))
        s.settimeout(1)
        while not self.stop.is_set():
            try:
                data, (ip, _) = s.recvfrom(2048)
                d = json.loads(data)
                if d.get("app") != "cablesend":
                    continue
                if d["alias"] == self.alias and d["port"] == self.http_port:
                    continue  # это мы сами
                self.peers[f"{ip}:{d['port']}"] = {**d, "ip": ip, "seen": time.time()}
            except (socket.timeout, ValueError, KeyError):
                pass

    def _announce(self):
        while not self.stop.is_set():
            for i in list_ifaces(self.loopback_ok, self.include_wifi):
                targets = [i["bcast"]] if i["bcast"] else []
                if i["kind"] == "loopback":
                    targets = ["127.0.0.1"]
                if i["linklocal"] and not targets:
                    targets = ["169.254.255.255"]
                for t in targets:
                    try:
                        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
                        s.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
                        s.bind((i["ip"], 0))  # отправляем строго через кабельный интерфейс
                        s.sendto(self._payload(), (t, DISCO_PORT))
                        s.close()
                    except OSError:
                        pass
            time.sleep(2)

    def alive(self, ttl=8):
        now = time.time()
        return [p for p in self.peers.values() if now - p["seen"] < ttl]


# ───────────────────────── Приём (HTTP сервер) ─────────────────────────
class Receiver(http.server.BaseHTTPRequestHandler):
    server_version = "cablesend/0.1"
    save_dir = "."
    pin = None
    auto = True
    sessions = {}  # token -> {name,size,sha,tmp}
    lock = threading.Lock()

    def log_message(self, *a):  # тихий сервер
        pass

    def _json(self, code, obj):
        b = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)

    def _auth(self):
        if self.pin and self.headers.get("X-Pin") != self.pin:
            self._json(403, {"error": "bad pin"})
            return False
        return True

    def do_GET(self):
        if self.path == "/api/info":
            self._json(200, {"app": "cablesend", "os": OS_NAME, "alias": socket.gethostname()})
        else:
            self._json(404, {"error": "not found"})

    def do_POST(self):  # предложение файла
        if self.path != "/api/offer" or not self._auth():
            return
        n = int(self.headers.get("Content-Length", 0))
        o = json.loads(self.rfile.read(n))
        name = os.path.basename(o["name"])  # защита от path traversal
        if not name:
            return self._json(400, {"error": "bad name"})
        if not self.auto:
            ans = input(f"\nПринять '{name}' ({o['size']} Б)? [y/N] ").strip().lower()
            if ans != "y":
                return self._json(403, {"error": "declined"})
        tmp = os.path.join(self.save_dir, name + ".part")
        have = os.path.getsize(tmp) if os.path.exists(tmp) else 0
        if have > o["size"]:
            have = 0
        token = hashlib.sha256(os.urandom(16)).hexdigest()[:24]
        with self.lock:
            self.sessions[token] = {"name": name, "size": o["size"], "sha": o["sha256"], "tmp": tmp}
        self._json(200, {"token": token, "offset": have})

    def do_PUT(self):  # данные файла (с докачкой через X-Offset)
        if not self._auth():
            return
        q = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
        s = self.sessions.get((q.get("token") or [""])[0])
        if not s:
            return self._json(403, {"error": "no session"})
        off = int(self.headers.get("X-Offset", 0))
        left = int(self.headers.get("Content-Length", 0))
        mode = "r+b" if (off and os.path.exists(s["tmp"])) else "wb"
        with open(s["tmp"], mode) as f:
            f.seek(off)
            f.truncate(off)
            while left > 0:
                b = self.rfile.read(min(CHUNK, left))
                if not b:
                    break
                f.write(b)
                left -= len(b)
        if left:
            return self._json(400, {"error": "interrupted"})
        h = hashlib.sha256()
        with open(s["tmp"], "rb") as f:
            for blk in iter(lambda: f.read(CHUNK), b""):
                h.update(blk)
        if h.hexdigest() != s["sha"]:
            os.remove(s["tmp"])
            return self._json(422, {"error": "sha256 mismatch"})
        final = os.path.join(self.save_dir, s["name"])
        if os.path.exists(final):
            base, ext = os.path.splitext(final)
            final = f"{base}_{int(time.time())}{ext}"
        os.replace(s["tmp"], final)
        print(f"\n✔ получен: {final} ({s['size']} Б, sha256 ок)")
        self._json(200, {"ok": True})


class ThreadedServer(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True


# ───────────────────────── Отправка ─────────────────────────
def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for b in iter(lambda: f.read(CHUNK), b""):
            h.update(b)
    return h.hexdigest()


class _Progress:
    def __init__(self, f, total, start):
        self.f, self.total, self.sent, self.t0 = f, total, start, time.time()

    def read(self, n=-1):
        b = self.f.read(CHUNK if n < 0 else min(n, CHUNK))
        self.sent += len(b)
        el = max(time.time() - self.t0, 1e-6)
        sys.stdout.write(f"\r  {self.sent*100//max(self.total,1)}%  {self.sent/1e6:.1f} МБ  "
                         f"{(self.sent)/el/1e6:.1f} МБ/с   ")
        sys.stdout.flush()
        return b


def send_file(path, host, port, pin=None):
    size, name = os.path.getsize(path), os.path.basename(path)
    print(f"Считаю sha256 для {name}…")
    sha = sha256_file(path)
    base = f"http://{host}:{port}"
    hdr = {"Content-Type": "application/json"}
    if pin:
        hdr["X-Pin"] = pin
    req = urllib.request.Request(base + "/api/offer", method="POST", headers=hdr,
                                 data=json.dumps({"name": name, "size": size, "sha256": sha}).encode())
    try:
        r = json.load(urllib.request.urlopen(req, timeout=120))
    except urllib.error.HTTPError as e:
        sys.exit(f"Отказ: {e.read().decode()}")
    off = r["offset"]
    if off:
        print(f"Докачка с {off} байт")
    with open(path, "rb") as f:
        f.seek(off)
        body = _Progress(f, size, off)

        class Body:  # urllib требует объект с read и длиной
            def read(self, n=-1):
                return body.read(n)

        h2 = {"X-Offset": str(off), "Content-Length": str(size - off)}
        if pin:
            h2["X-Pin"] = pin
        put = urllib.request.Request(f"{base}/api/upload?token={r['token']}", method="PUT",
                                     data=Body(), headers=h2)
        try:
            urllib.request.urlopen(put, timeout=3600)
        except urllib.error.HTTPError as e:
            sys.exit(f"\nОшибка: {e.read().decode()}")
    print("\n✔ отправлено, хеш подтверждён получателем")


# ───────────────────────── Мосты для телефонов без сети ─────────────────────────
def bridge_adb(port):
    """Android по USB без тетеринга: adb reverse/forward пробрасывает порт по кабелю."""
    if not shutil.which("adb"):
        sys.exit("adb не найден: установите Android platform-tools")
    subprocess.check_call(["adb", "forward", f"tcp:{port}", f"tcp:{port}"])
    subprocess.check_call(["adb", "reverse", f"tcp:{port}", f"tcp:{port}"])
    print(f"ADB: localhost:{port} на ПК ⇄ localhost:{port} на телефоне (по USB). "
          f"Отправляйте на 127.0.0.1:{port}.")


def bridge_ios(port):
    """iPhone/iPad: usbmuxd + iproxy (libimobiledevice) пробрасывает порт приложения на устройстве."""
    if not shutil.which("iproxy"):
        sys.exit("iproxy не найден: установите libimobiledevice (Windows: iTunes/Apple Devices + usbmuxd)")
    print(f"iproxy {port} {port}  — запускаю; приложение на iPhone должно слушать порт {port}")
    subprocess.call(["iproxy", str(port), str(port)])


# ───────────────────────── CLI ─────────────────────────
def main():
    ap = argparse.ArgumentParser(prog="cablesend")
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("ifaces", help="показать кабельные интерфейсы")
    for n in ("listen", "peers", "send"):
        p = sub.add_parser(n)
        p.add_argument("--loopback", action="store_true", help="тест на одной машине")
        p.add_argument("--wifi", action="store_true", help="разрешить Wi-Fi как запасной канал")
        p.add_argument("--port", type=int, default=HTTP_PORT)
        p.add_argument("--pin")
        if n == "listen":
            p.add_argument("--dir", default=".")
            p.add_argument("--ask", action="store_true", help="спрашивать подтверждение")
        if n == "send":
            p.add_argument("file")
            p.add_argument("--to", help="IP[:порт]; без него — первый найденный сосед")
    b = sub.add_parser("bridge", help="мост по USB для Android/iOS")
    b.add_argument("kind", choices=["adb", "ios"])
    b.add_argument("--port", type=int, default=HTTP_PORT)
    a = ap.parse_args()

    if a.cmd == "ifaces":
        found = list_ifaces(include_wifi=True)
        if not found:
            print("Активных интерфейсов не найдено.")
        for i in found:
            print(f"{i['name']:20} {i['kind']:16} {i['ip']:16}{' (link-local)' if i['linklocal'] else ''}")
        print("\nЕсли кабель вставлен, а интерфейс без IP — поднимите link-local адрес:")
        for n, ad in psutil.net_if_addrs().items():
            if classify(n) in ("ethernet", "usb/thunderbolt") and not any(
                    x.family == socket.AF_INET for x in ad):
                print(f"  {n}: {needs_ip_hint(n)}")
        return
    if a.cmd == "bridge":
        return (bridge_adb if a.kind == "adb" else bridge_ios)(a.port)

    alias = socket.gethostname()
    if a.cmd == "listen":
        os.makedirs(a.dir, exist_ok=True)
        Receiver.save_dir, Receiver.pin, Receiver.auto = a.dir, a.pin, not a.ask
        srv = ThreadedServer(("", a.port), Receiver)
        threading.Thread(target=srv.serve_forever, daemon=True).start()
        Discovery(alias, a.port, a.loopback, a.wifi).start()
        print(f"Слушаю на порту {a.port}, папка: {os.path.abspath(a.dir)}. Ctrl+C — выход.")
        try:
            while True:
                time.sleep(1)
        except KeyboardInterrupt:
            pass
        return

    d = Discovery(alias + f"-cli{os.getpid()}", 0, a.loopback, a.wifi)
    d.start()
    if a.cmd == "peers":
        time.sleep(5)
        for p in d.alive():
            print(f"{p['alias']:24} {p['os']:8} {p['ip']}:{p['port']}")
        return
    if a.to:
        host, _, prt = a.to.partition(":")
        port = int(prt or a.port)
    else:
        print("Ищу соседа по кабелю…")
        for _ in range(10):
            time.sleep(1)
            if d.alive():
                break
        al = d.alive()
        if not al:
            sys.exit("Сосед не найден. Проверьте кабель и `cablesend ifaces`.")
        host, port = al[0]["ip"], al[0]["port"]
        print(f"Найден: {al[0]['alias']} ({al[0]['os']}) {host}:{port}")
    send_file(a.file, host, port, a.pin)


if __name__ == "__main__":
    main()
