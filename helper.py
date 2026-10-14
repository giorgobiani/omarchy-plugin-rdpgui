#!/usr/bin/env python3
"""Backend for the Remote Desktop bar widget (FreeRDP / sdl-freerdp3).

  helper.py list               JSON: bookmarks, live sessions, VPN profiles
  helper.py connect <id>       Interactive; JSON events on stdout, JSON answers on stdin
  helper.py disconnect <id>
  helper.py focus <id>
  helper.py save               Create / update a bookmark from one JSON line on stdin
  helper.py delete <id>

Bookmarks live in ~/.local/state/omarchy/plugins/shota.rdp/connections.json (no secrets).
Passwords live in the Secret Service keyring and reach FreeRDP through a
private pipe (/args-from:fd), never argv. Sessions run detached with a
per-bookmark Wayland app id (omarchy-rdp-<id>), so they survive shell
restarts and are found again through `hyprctl clients`.
"""

import hashlib
import json
import os
import re
import signal
import socket
import ssl
import struct
import subprocess
import sys
import time
import uuid as uuidlib

# Omarchy convention: plugin data under $XDG_STATE_HOME/omarchy, caches under $XDG_CACHE_HOME/omarchy.
CONFIG_DIR = os.path.join(os.environ.get("XDG_STATE_HOME", os.path.expanduser("~/.local/state")),
                          "omarchy", "plugins", "shota.rdp")
STORE = os.path.join(CONFIG_DIR, "connections.json")
LOG_DIR = os.path.join(os.environ.get("XDG_CACHE_HOME", os.path.expanduser("~/.cache")), "omarchy", "shota.rdp")
KEYRING_SERVICE = "omarchy-rdp"
VPN_PLUGIN = "shota.openconnect"   # talked to only through its IPC target
CLIENT = "sdl-freerdp3"
# Needed for every bookmark; the panel offers to install whatever is missing.
REQUIRED_PACKAGES = ("freerdp", "libsecret", "gnome-keyring")
APP_PREFIX = "omarchy-rdp-"
WINDOW_TIMEOUT = 90
VPN_TIMEOUT = 240
KRB5_STUB = os.path.join(LOG_DIR, "krb5-none.conf")

FIELDS = {
    "name": "", "host": "", "username": "", "domain": "", "vpn": "", "gateway": "",
    "fullscreen": False, "scale": 0, "clipboard": True, "shareHome": False, "sound": True, "kerberos": False, "grabKeyboard": False,
    "rememberPassword": False, "certPin": "", "lastUsed": 0,
}

ERRORS = {
    "LOGON_FAILURE": "Wrong username or password",
    "AUTHENTICATION_FAILED": "Wrong username or password",
    "ACCOUNT_LOCKED_OUT": "This account is locked out",
    "ACCOUNT_DISABLED": "This account is disabled",
    "ACCOUNT_EXPIRED": "This account has expired",
    "PASSWORD_EXPIRED": "The password has expired — change it on the server first",
    "PASSWORD_MUST_CHANGE": "The password must be changed before signing in",
    "WRONG_PASSWORD": "Wrong username or password",
    "LOGON_TYPE_NOT_GRANTED": "This user isn't allowed to sign in over Remote Desktop",
    "INSUFFICIENT_PRIVILEGES": "This user isn't allowed to sign in over Remote Desktop",
    "DNS_NAME_NOT_FOUND": "Host not found",
    "DNS_ERROR": "Host not found",
    "CONNECT_FAILED": "Could not reach the server",
    "CONNECT_TRANSPORT_FAILED": "Could not reach the server",
    "TLS_CONNECT_FAILED": "Secure connection failed (certificate or TLS problem)",
    "SECURITY_NEGO_CONNECT_FAILED": "Security negotiation failed",
    "CONNECT_CANCELLED": "Connection cancelled",
}
AUTH_ERRORS = ("LOGON_FAILURE", "AUTHENTICATION_FAILED", "WRONG_PASSWORD")


def emit(event, **data):
    data["event"] = event
    sys.stdout.write(json.dumps(data) + "\n")
    sys.stdout.flush()


# ----- storage ---------------------------------------------------------------

def load_store():
    try:
        with open(STORE) as f:
            items = json.load(f)
        return [dict(FIELDS, **i) for i in items if isinstance(i, dict) and i.get("id")]
    except (OSError, ValueError):
        return []


def save_store(items):
    os.makedirs(CONFIG_DIR, exist_ok=True)
    tmp = STORE + ".tmp"
    with open(tmp, "w") as f:
        json.dump(items, f, indent=2)
    os.chmod(tmp, 0o600)
    os.replace(tmp, STORE)


def find(items, cid):
    for item in items:
        if item["id"] == cid or item["name"] == cid:
            return item
    return None


def keyring_attrs(cid):
    return ["service", KEYRING_SERVICE, "id", cid]


def keyring_get(cid):
    res = subprocess.run(["secret-tool", "lookup", *keyring_attrs(cid)], capture_output=True, text=True)
    return res.stdout if res.returncode == 0 and res.stdout else None


def keyring_set(cid, name, password):
    res = subprocess.run(["secret-tool", "store", "--label", "Remote Desktop: %s" % name, *keyring_attrs(cid)],
                         input=password, capture_output=True, text=True)
    return res.returncode == 0


def keyring_clear(cid):
    subprocess.run(["secret-tool", "clear", *keyring_attrs(cid)], capture_output=True)


# ----- sessions / windows ------------------------------------------------------

def windows():
    res = subprocess.run(["hyprctl", "clients", "-j"], capture_output=True, text=True)
    try:
        return json.loads(res.stdout)
    except ValueError:
        return []


def pid_file(cid):
    return os.path.join(LOG_DIR, "%s.pid" % cid)


def session_pid(cid):
    try:
        pid = int(open(pid_file(cid)).read().strip())
        os.kill(pid, 0)
        return pid
    except (OSError, ValueError):
        return None


def session_window(cid, clients=None):
    pid = session_pid(cid)
    for c in clients if clients is not None else windows():
        if c.get("class") == APP_PREFIX + cid or c.get("initialClass") == APP_PREFIX + cid:
            return c
        if pid and c.get("pid") == pid:
            return c
    return None


def screen_size():
    res = subprocess.run(["hyprctl", "monitors", "-j"], capture_output=True, text=True)
    try:
        mons = json.loads(res.stdout)
        mon = next((m for m in mons if m.get("focused")), mons[0])
        scale = mon.get("scale") or 1
        return int(mon["width"] / scale), int(mon["height"] / scale)
    except (ValueError, KeyError, IndexError, StopIteration):
        return 1600, 900


def vpn_profiles():
    """Every profile the VPN widget knows (OpenConnect, OpenVPN, OpenVPN 3 SSO);
    straight from NetworkManager when the widget isn't loaded."""
    listed = vpn_widget("profiles")
    if listed:
        try:
            profiles = [{"uuid": p["uuid"], "name": p["name"], "state": p.get("state", "")}
                        for p in json.loads(listed)]
            if profiles:
                return profiles
        except (ValueError, KeyError, TypeError):
            pass

    def terse(*args):
        res = subprocess.run(["nmcli", "-t", *args], capture_output=True, text=True)
        return [re.split(r"(?<!\\):", l) for l in res.stdout.splitlines()]
    active = {row[0]: row[1] for row in terse("-f", "UUID,STATE", "connection", "show", "--active") if len(row) > 1}
    out = []
    for row in terse("-f", "NAME,UUID,TYPE", "connection", "show"):
        if len(row) < 3 or row[2] != "vpn":
            continue
        uuid = row[1]
        service = subprocess.run(["nmcli", "-g", "vpn.service-type", "connection", "show", uuid],
                                 capture_output=True, text=True).stdout.strip()
        if service.endswith((".openconnect", ".openvpn")):
            out.append({"uuid": uuid, "name": row[0].replace("\\:", ":"), "state": active.get(uuid, "")})
    return out


def vpn_widget(method, *args):
    """Call the VPN widget's IPC; returns None when it isn't loaded."""
    res = subprocess.run(["omarchy-shell", VPN_PLUGIN, method, *args], capture_output=True, text=True)
    out = res.stdout.strip()
    return out if res.returncode == 0 and out and "not responding" not in out and "not found" not in out.lower() else None


def cmd_list():
    items = load_store()
    clients = windows()
    out = []
    for item in items:
        public = {k: v for k, v in item.items() if k != "certPin"}
        public["active"] = session_window(item["id"], clients) is not None
        public["trusted"] = bool(item.get("certPin"))
        out.append(public)
    json.dump({"connections": out, "vpns": vpn_profiles(),
               "clientInstalled": bool(subprocess.run(["which", CLIENT], capture_output=True).returncode == 0),
               "missing": missing_packages(REQUIRED_PACKAGES)},
              sys.stdout)


def missing_packages(packages):
    """The packages pacman doesn't have installed (`pacman -T` prints exactly those)."""
    try:
        res = subprocess.run(["pacman", "-T", *packages], capture_output=True, text=True)
    except OSError:
        return []
    return res.stdout.split() if res.returncode == 127 else []


def cmd_focus(cid):
    item = find(load_store(), cid)
    win = session_window(item["id"]) if item else None
    if not win:
        sys.exit(1)
    subprocess.run(["hyprctl", "dispatch", 'hl.dsp.focus({ window = "address:%s" })' % win["address"]],
                   capture_output=True)


def cmd_disconnect(cid):
    item = find(load_store(), cid)
    win = session_window(item["id"]) if item else None
    if not win:
        sys.exit(1)
    try:
        os.kill(int(win["pid"]), signal.SIGTERM)
    except (OSError, ValueError, KeyError):
        sys.exit(1)


def cmd_save():
    req = json.loads(sys.stdin.readline() or "{}")
    items = load_store()
    cid = str(req.get("id") or "")
    item = find(items, cid) if cid else None
    name = str(req.get("name", "")).strip()
    host = str(req.get("host", "")).strip()
    if not name or not host:
        emit("error", text="Name and host are required")
        sys.exit(1)
    if item is None:
        item = dict(FIELDS, id=uuidlib.uuid4().hex[:12])
        items.append(item)
    if item.get("host") != host:
        item["certPin"] = ""
    item.update({
        "name": name, "host": host,
        "username": str(req.get("username", "")).strip(),
        "domain": str(req.get("domain", "")).strip(),
        "vpn": str(req.get("vpn", "")),
        "gateway": str(req.get("gateway", "")).strip(),
        "fullscreen": bool(req.get("fullscreen")),
        "scale": int(req.get("scale") or 0),
        "clipboard": bool(req.get("clipboard", True)),
        "shareHome": bool(req.get("shareHome")),
        "sound": bool(req.get("sound", True)),
        "kerberos": bool(req.get("kerberos")),
        "grabKeyboard": bool(req.get("grabKeyboard")),
    })
    remember = bool(req.get("rememberPassword"))
    password = req.get("password") or ""
    if not remember:
        keyring_clear(item["id"])
    elif password:
        if not keyring_set(item["id"], name, password):
            remember = False
            emit("error", text="Could not store the password in the keyring")
    elif not keyring_get(item["id"]):
        remember = False
    item["rememberPassword"] = remember
    save_store(items)
    emit("saved", id=item["id"])


def cmd_delete(cid):
    items = load_store()
    item = find(items, cid)
    if item:
        keyring_clear(item["id"])
        items.remove(item)
        save_store(items)


# ----- certificate -------------------------------------------------------------

def split_host(host, default_port=3389):
    host = host.strip()
    m = re.match(r"^\[(.+)\](?::(\d+))?$", host)
    if m:
        return m.group(1), int(m.group(2) or default_port)
    if host.count(":") == 1:
        h, p = host.split(":")
        return h, int(p)
    return host, default_port


def fetch_cert(host, port):
    """RDP negotiates TLS after an X.224 exchange, so plain TLS probes don't work.
    Returns (der_bytes | None, ca_trusted: bool, error | None)."""
    try:
        sock = socket.create_connection((host, port), timeout=10)
    except OSError as e:
        return None, False, "Could not reach %s:%d (%s)" % (host, port, e.strerror or e)
    try:
        neg = struct.pack("<BBHI", 0x01, 0x00, 8, 0x0B)          # TLS | CredSSP | CredSSP-EX
        x224 = bytes([6 + len(neg), 0xE0, 0, 0, 0, 0, 0]) + neg
        sock.sendall(struct.pack(">BBH", 3, 0, 4 + len(x224)) + x224)
        head = sock.recv(4)
        if len(head) < 4 or head[0] != 3:
            return None, False, "Not an RDP server"
        body = b""
        length = struct.unpack(">H", head[2:4])[0] - 4
        while len(body) < length:
            chunk = sock.recv(length - len(body))
            if not chunk:
                break
            body += chunk
        if len(body) >= 15 and body[7] == 0x03:
            return None, False, None   # negotiation failure; let FreeRDP sort it out
        if len(body) >= 15 and body[7] == 0x02 and struct.unpack("<I", body[11:15])[0] == 0:
            return None, False, None   # legacy RDP security: no TLS certificate
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
        tls = ctx.wrap_socket(sock, server_hostname=host)
        der = tls.getpeercert(binary_form=True)
        tls.close()
    except OSError as e:
        return None, False, "TLS handshake failed: %s" % e
    finally:
        try:
            sock.close()
        except OSError:
            pass
    # CA check: let openssl verify the leaf against the system store + hostname.
    res = subprocess.run(["openssl", "verify", "-verify_hostname", host], input=ssl.DER_cert_to_PEM_cert(der),
                         capture_output=True, text=True)
    return der, res.returncode == 0, None


def cert_info(der):
    res = subprocess.run(["openssl", "x509", "-inform", "der", "-noout", "-subject", "-enddate"],
                         input=der, capture_output=True)
    lines = res.stdout.decode(errors="replace").splitlines()
    subject = next((l.split("=", 1)[1].strip() for l in lines if l.startswith("subject")), "")
    cn = re.search(r"CN\s*=\s*([^,/]+)", subject)
    expires = next((l.split("=", 1)[1].strip() for l in lines if l.startswith("notAfter")), "")
    return (cn.group(1).strip() if cn else subject), expires


# ----- connect -------------------------------------------------------------------

class Session:
    def __init__(self, cid):
        self.items = load_store()
        self.item = find(self.items, cid)
        self.stdin_buf = ""

    def ask(self, **prompt):
        emit("prompt", **prompt)
        while "\n" not in self.stdin_buf:
            chunk = os.read(0, 4096)
            if not chunk:
                return None
            self.stdin_buf += chunk.decode(errors="replace")
        line, self.stdin_buf = self.stdin_buf.split("\n", 1)
        try:
            msg = json.loads(line)
        except ValueError:
            return None
        return None if msg.get("cancel") else msg

    def save(self):
        save_store(self.items)

    def ensure_vpn(self):
        vpn = self.item.get("vpn")
        if not vpn:
            return True
        profiles = {p["uuid"]: p for p in vpn_profiles()}
        profile = profiles.get(vpn)
        if not profile:
            emit("log", text="Linked VPN profile no longer exists; connecting directly")
            return True
        if profile["state"] == "activated":
            return True
        emit("state", state="vpn", text="Connecting %s…" % profile["name"])
        # The VPN widget owns its own login prompts (password, SMS, SSO…).
        if vpn_widget("connect", vpn) is None:
            emit("error", text="Enable the VPN widget (omarchy-plugin-vpngui) to connect %s" % profile["name"])
            return False
        start = time.time()
        while time.time() < start + VPN_TIMEOUT:
            time.sleep(1.5)
            state = {p["uuid"]: p["state"] for p in vpn_profiles()}.get(vpn, "")
            if state == "activated":
                return True
            # Once the widget is idle again without an active tunnel, the
            # login was cancelled or failed.
            if vpn_widget("phase") == "idle" and state != "activating" and time.time() - start > 3:
                emit("error", text="%s did not connect" % profile["name"])
                return False
        emit("error", text="Timed out waiting for %s" % profile["name"])
        return False

    def ensure_cert(self, host, port):
        emit("state", state="checking", text="Checking %s…" % host)
        der, trusted, err = fetch_cert(host, port)
        if err:
            emit("error", text=err)
            return None
        if der is None or trusted:
            return ""   # nothing to pin: FreeRDP validates CA-signed certs itself
        pin = hashlib.sha256(der).hexdigest()
        if self.item.get("certPin") == pin:
            return pin
        cn, expires = cert_info(der)
        changed = bool(self.item.get("certPin"))
        fingerprint = ":".join(pin[i:i + 2] for i in range(0, 32, 2)).upper() + "…"
        msg = self.ask(kind="cert", label="Trust certificate", secret=False, changed=changed,
                       message=("The server's certificate CHANGED since you last connected. "
                                "Only continue if you expect this." if changed else
                                "The server's certificate isn't signed by a trusted authority "
                                "(normal for Windows servers). Trust it for this connection?"),
                       pin="%s\n%s%s" % (fingerprint, ("CN " + cn) if cn else "",
                                         ("  ·  expires " + expires) if expires else ""))
        if not msg or str(msg.get("answer", "")).lower() != "yes":
            return None
        self.item["certPin"] = pin
        self.save()
        return pin

    def credentials(self, retry_message=""):
        item = self.item
        username = item.get("username", "")
        password = None if retry_message else (keyring_get(item["id"]) if item.get("rememberPassword") else None)
        remember = item.get("rememberPassword", False)
        if not username or retry_message:
            msg = self.ask(kind="text", label="Username", secret=False, value=username,
                           message=retry_message or "Sign in to %s" % item["name"])
            if not msg:
                return None
            username = str(msg.get("answer", "")).strip()
            retry_message = ""
        if password is None:
            msg = self.ask(kind="text", label="Password", secret=True, value="",
                           message=retry_message or ("Password for %s%s on %s" % ((item["domain"] + "\\") if item.get("domain") else "",
                                                                             username, item["name"])),
                           canRemember=True, remember=bool(remember))
            if not msg:
                return None
            password = str(msg.get("answer", ""))
            remember = bool(msg.get("remember"))
        return username, password, remember

    def build_args(self, host, port, username, password, pin):
        item = self.item
        args = ["/v:%s:%d" % (host, port), "/u:%s" % username, "/p:%s" % password,
                "/t:%s" % item["name"], "/log-level:WARN", "+auto-reconnect", "/network:auto"]
        if item.get("domain"):
            args.append("/d:%s" % item["domain"])
        if not item.get("kerberos"):
            # Without a reachable KDC every Kerberos attempt burns ~30 s and the
            # server drops the half-open login; NTLM is what Windows falls back to anyway.
            args.append("/auth-pkg-list:!kerberos")
        if pin:
            args.append("/cert:fingerprint:sha256:%s" % pin)
        if item.get("fullscreen"):
            args.append("/f")
        else:
            # Start at screen size; the Hyprland rule tiles the window and
            # dynamic resolution then follows the tile.
            args += ["+dynamic-resolution", "/size:%dx%d" % screen_size()]
        if not item.get("grabKeyboard"):
            # Keep Super / Hyprland shortcuts on this machine.
            args += ["-grab-keyboard", "-grab-mouse"]
        scale = int(item.get("scale") or 0)
        if scale:
            args += ["/scale:%d" % min((100, 140, 180), key=lambda s: abs(s - scale)),
                     "/scale-desktop:%d" % scale]
        args.append("+clipboard" if item.get("clipboard", True) else "-clipboard")
        if item.get("shareHome"):
            args.append("/drive:home,%s" % os.path.expanduser("~"))
        args.append("/sound" if item.get("sound", True) else "/audio-mode:2")
        if item.get("gateway"):
            gw = "g:%s,u:%s,p:%s" % (item["gateway"], username, password)
            if item.get("domain"):
                gw += ",d:%s" % item["domain"]
            args.append("/gateway:%s" % gw)
        return args

    def launch(self, args):
        os.makedirs(LOG_DIR, exist_ok=True)
        log_path = os.path.join(LOG_DIR, "%s.log" % self.item["id"])
        log = open(log_path, "w")
        r, w = os.pipe()
        env = dict(os.environ, SDL_APP_ID=APP_PREFIX + self.item["id"], SDL_VIDEO_DRIVER="wayland")
        if not self.item.get("kerberos"):
            # A realm-less krb5 config makes Kerberos fail instantly; the system
            # one points at a placeholder realm and each lookup stalls ~30 s.
            env["KRB5_CONFIG"] = KRB5_STUB
            open(KRB5_STUB, "w").write("[libdefaults]\n")
        proc = subprocess.Popen([CLIENT, "/args-from:fd:%d" % r], pass_fds=(r,), stdin=subprocess.DEVNULL,
                                stdout=log, stderr=log, env=env, start_new_session=True)
        os.close(r)
        with open(pid_file(self.item["id"]), "w") as f:
            f.write(str(proc.pid))
        os.write(w, ("\n".join(args) + "\n").encode())
        os.close(w)
        log.close()
        return proc, log_path

    def wait_window(self, proc, log_path):
        """Returns ('ok'|'auth'|'error', message)."""
        deadline = time.time() + WINDOW_TIMEOUT
        while time.time() < deadline:
            time.sleep(0.5)
            if proc.poll() is not None:
                break
            if session_window(self.item["id"]):
                # A window alone isn't success: NLA failures show up right after.
                time.sleep(1.5)
                if proc.poll() is None:
                    return "ok", ""
                break
        else:
            # No window after WINDOW_TIMEOUT: stop it and report what the log says.
            proc.terminate()
            try:
                proc.wait(5)
            except subprocess.TimeoutExpired:
                proc.kill()
        try:
            text = open(log_path, errors="replace").read()
        except OSError:
            text = ""
        codes = re.findall(r"ERRCONNECT_([A-Z_]+)", text)
        code = codes[-1] if codes else ""
        if code in AUTH_ERRORS:
            return "auth", ERRORS[code]
        if code in ERRORS:
            return "error", ERRORS[code]
        errors = [l.split(" - ", 1)[-1] for l in text.splitlines() if "[ERROR]" in l]
        if "Cannot find KDC" in text or "Kerberos database" in text:
            return "error", "Kerberos sign-in failed — turn off “Use Kerberos” for this computer"
        return "error", (errors[-1] if errors else "Timed out opening the session")[:200]

    def run(self):
        item = self.item
        existing = session_window(item["id"])
        if existing:
            cmd_focus(item["id"])
            emit("state", state="connected")
            return True
        if not self.ensure_vpn():
            return False
        host, port = split_host(item["host"])
        pin = self.ensure_cert(host, port)
        if pin is None:
            return False
        retry = ""
        for _ in range(3):
            creds = self.credentials(retry)
            if not creds:
                return False
            username, password, remember = creds
            emit("state", state="connecting", text="Opening %s…" % item["name"])
            proc, log_path = self.launch(self.build_args(host, port, username, password, pin))
            status, message = self.wait_window(proc, log_path)
            if status == "ok":
                item["username"] = username
                item["lastUsed"] = int(time.time())
                if remember:
                    item["rememberPassword"] = keyring_set(item["id"], item["name"], password)
                elif item.get("rememberPassword"):
                    keyring_clear(item["id"])
                    item["rememberPassword"] = False
                self.save()
                emit("state", state="connected")
                return True
            if status == "auth":
                retry = message
                continue
            emit("error", text=message)
            return False
        emit("error", text="Too many failed attempts")
        return False


def cmd_connect(cid):
    session = Session(cid)
    if not session.item:
        emit("error", text="Unknown connection")
        sys.exit(1)
    if subprocess.run(["which", CLIENT], capture_output=True).returncode != 0:
        emit("error", text="FreeRDP is not installed: omarchy pkg add freerdp")
        sys.exit(1)
    signal.signal(signal.SIGTERM, lambda *_: (emit("state", state="cancelled"), os._exit(1)))
    ok = session.run()
    if not ok:
        emit("state", state="cancelled")
    sys.exit(0 if ok else 1)


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    cmd, arg = sys.argv[1], (sys.argv[2] if len(sys.argv) > 2 else "")
    if cmd == "list":
        cmd_list()
    elif cmd == "save":
        cmd_save()
    elif cmd in ("connect", "disconnect", "focus", "delete") and arg:
        {"connect": cmd_connect, "disconnect": cmd_disconnect, "focus": cmd_focus, "delete": cmd_delete}[cmd](arg)
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main()
