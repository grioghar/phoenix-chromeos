#!/usr/bin/env python3
# Temporary LAN helper for the Vostro: GET /d serves the diagnostic script,
# PUT/POST /up stores whatever the Vostro sends back in /root/brunch-build/diag/.
import http.server, os, time

PORT = 8099
REPO = "/root/phoenix"   # rsync of the phoenix-chromeos repo
BLOBDIR = "/root/brunch-build/movbe"   # built components (never in git)
OUT = "/root/brunch-build/diag"
SCRIPT = r'''#!/bin/sh
{
echo "## CPU / KVM"; grep -c vmx /proc/cpuinfo; ls -l /dev/kvm
cat /sys/module/kvm_intel/parameters/ept /sys/module/kvm_intel/parameters/unrestricted_guest
free -m | head -2; uname -r; grep -m1 "model name" /proc/cpuinfo
echo "## phoenix detect"; curl -s http://HOST:8099/pd > /tmp/phoenix-detect.sh && sh /tmp/phoenix-detect.sh --summary && sh /tmp/phoenix-detect.sh
echo "## input"; grep -E "^N: Name|^H: Handlers" /proc/bus/input/devices; grep -o "psmouse[^ ]*\|i8042[^ ]*" /proc/cmdline
echo "## touchpad detail"; dmesg | grep -iE "alps|psmouse|elantech|synaptics" | tail -20
awk '/Name=.*(ALPS|Alps|Synaptics|SynPS|Elan|ETPS|Touchpad|TouchPad)/,/^$/' /proc/bus/input/devices
ls /etc/gesture/ 2>&1; grep -l -i -E "alps|semi" /etc/gesture/*.conf 2>/dev/null
for f in /etc/gesture/*.conf; do grep -n -i -B2 -A12 "alps" "$f" 2>/dev/null | head -60; done
echo "## GPUs"; lspci -nn 2>/dev/null | grep -iE "vga|3d|display"; ls /sys/class/drm/
echo "## boot disk"; rootdev -d -s
echo "## kvm emulation rate (10 s sample)"
K=/sys/kernel/debug/kvm; mountpoint -q /sys/kernel/debug || mount -t debugfs none /sys/kernel/debug 2>/dev/null
if [ -r $K/insn_emulation ]; then
  for c in insn_emulation exits io_exits; do eval "a_$c=$(cat $K/$c 2>/dev/null || echo 0)"; done; sleep 10
  for c in insn_emulation exits io_exits; do eval "b=\$(cat $K/$c 2>/dev/null || echo 0); a=\$a_$c"; echo "$c/s: $(( (b - a) / 10 ))"; done
else ls $K 2>&1 | head; fi
top -b -n 1 | head -15
echo "## kvm emulated instructions (5 s trace: count rip bytes)"
T=/sys/kernel/debug/tracing
if [ -w $T/events/kvm/kvm_emulate_insn/enable ]; then
  # always switch tracing off again, even if this script is interrupted (it slows the VM down)
  trap 'echo 0 > $T/events/kvm/kvm_emulate_insn/enable; echo > $T/trace' EXIT INT TERM HUP
  echo > $T/trace; echo 1 > $T/events/kvm/kvm_emulate_insn/enable; sleep 5; echo 0 > $T/events/kvm/kvm_emulate_insn/enable
  grep -o 'kvm_emulate_insn: .*' $T/trace | sed 's/kvm_emulate_insn: //' | sort | uniq -c | sort -rn | head -400
  echo "total: $(grep -c kvm_emulate_insn $T/trace)"; echo > $T/trace
else echo "no tracepoint"; ls $T/events/kvm 2>&1 | head -5; fi
echo "## messages (arc/vm)"
grep -i -E 'arcvm|crosvm|concierge|arc_setup|ArcSession|arc-' /var/log/messages | grep -i -E 'error|fail|crash|exit|panic|signal|virgl|gpu|killed|abort|denied' | tail -80
echo "## crosvm/concierge (unfiltered)"
grep -E 'crosvm|vm_concierge|arcvm|ARCVM' /var/log/messages | tail -150
echo "## disk"; df -h /mnt/stateful_partition /home/chronos/user 2>&1
echo "## vmlog"; ls -la /var/log/vmlog/ 2>&1
for f in /var/log/vmlog/arcvm.LATEST /var/log/vmlog/arcvm.log; do [ -r "$f" ] && { echo "--- $f"; tail -150 "$f"; }; done
echo "## arc.log"; tail -40 /var/log/arc.log 2>&1
echo "## ui gpu"; grep -i -E 'gl_renderer|GL_VERSION|crocus|virgl|gpu process' /var/log/ui/ui.LATEST 2>/dev/null | tail -15
echo "## dmesg kvm/gpu"; dmesg 2>/dev/null | grep -i -E 'kvm|vmx|i915|drm|crosvm|virtio' | tail -30
echo "## arcvm pstore (guest kernel log of the last run)"
for f in $(find /run/arcvm /home/root -maxdepth 4 -name '*pstore*' 2>/dev/null); do echo "--- $f"; ls -la "$f"; strings -n 6 "$f" | grep -v '^\s*$' | tail -250; done
echo "## chrome arc lines"
grep -h -i -E 'arc.*(provision|error|stopped|timeout|failed|boot)' /home/chronos/user/log/chrome /var/log/chrome/chrome 2>/dev/null | tail -60
echo "## messages since last StartArcVm"
awk '/StartArcVm/{buf=""} {buf=buf $0 "\n"} END{printf "%s", buf}' /var/log/messages | grep -v arc-setup | tail -200
echo "## android logcat (crashes)"
A=$(command -v android-sh)
if [ -n "$A" ]; then
  timeout 60 $A -c "logcat -d -b crash" 2>&1 | tail -150
  echo "## android logcat (errors/fatal)"
  timeout 60 $A -c "logcat -d *:E" 2>&1 | tail -250
  echo "## android logcat (play/gms)"
  timeout 60 $A -c "logcat -d" 2>&1 | grep -iE "vending|gms|finsky|SIGILL|signal 4|ILL_|dex2oat|Fatal|ANR" | tail -150
  echo "## android installs"
  timeout 60 $A -c "logcat -d" 2>&1 | grep -iE "PackageInstaller|PackageManager|installd|dex2oat|DownloadManager|Finsky.*(install|download)|InstallQueue|session" | tail -120
  timeout 30 $A -c "ps -A -o PID,STAT,TIME,NAME | grep -iE 'dex2oat|installd|vending|download'" 2>&1
  timeout 30 $A -c "df -h /data; uptime" 2>&1
  echo "## android dmesg traps"
  timeout 30 $A -c "dmesg" 2>&1 | grep -iE "trap|invalid opcode|segfault|panic" | tail -30
  echo "## android getprop boot"
  timeout 30 $A -c "getprop sys.boot_completed; getprop dalvik.vm.isa.x86_64.features; getprop dalvik.vm.isa.x86_64.variant" 2>&1
else echo "android-sh not found"; fi
echo "## terminal crash"; grep -i -E 'crosh|terminal' /var/log/messages | tail -10
} > /tmp/arc-diag.txt 2>&1
cp /tmp/arc-diag.txt /home/chronos/user/MyFiles/Downloads/arc-diag.txt 2>/dev/null
curl -s -T /tmp/arc-diag.txt http://HOST:8099/up && echo "Sent to Claude." || echo "Upload failed; the file is in Downloads as arc-diag.txt"
'''

# --- GitHub issues for `phoenix submit` reports. The token (fine-grained, this repo only,
# Issues: read and write) lives outside the repo; without it, reports are only stored locally.
GH_REPO = "grioghar/phoenix-chromeos"
GH_TOKEN_FILE = "/root/phoenix-secrets/github-token"

def github_issue(report):
    import json, re, urllib.request
    if not os.path.isfile(GH_TOKEN_FILE): return None
    token = open(GH_TOKEN_FILE).read().strip()
    field = lambda k: (re.search(r"^%s: (.*)$" % k, report, re.M) or [None, "?"])[1].strip()
    vendor, model = field("sys_vendor"), field("product_name")
    if field("sys_vendor") == "LENOVO": model = field("product_version")
    problem = field("problem")
    title = ("Hardware report: %s %s" % (vendor, model))[:120]
    if problem not in ("?", "not given"): title += " - " + problem[:80]
    assess = re.search(r"## phoenix assessment\n(.*?)\n## ", report, re.S)
    body = ("Submitted with `phoenix submit` (private data removed on the device).\n\n"
            "**Problem:** %s\n**Details:** %s\n\n### Phoenix assessment\n```\n%s\n```\n\n"
            "<details><summary>Full report</summary>\n\n```\n%s\n```\n</details>\n"
            % (problem, field("details"), assess.group(1).strip() if assess else "?", report[:60000]))
    req = urllib.request.Request("https://api.github.com/repos/%s/issues" % GH_REPO, method="POST",
        data=json.dumps({"title": title, "body": body, "labels": ["hardware-report"]}).encode(),
        headers={"Authorization": "Bearer " + token, "Accept": "application/vnd.github+json",
                 "X-GitHub-Api-Version": "2022-11-28", "User-Agent": "phoenix-server"})
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.load(r).get("html_url")

class H(http.server.BaseHTTPRequestHandler):
    def _reply(self, code, body):
        self.send_response(code); self.send_header("Content-Type", "text/plain")
        self.end_headers(); self.wfile.write(body.encode())
    # scripts served from the repo copy; HOST is replaced by the address the client used
    SCRIPTS = {"/v": "cli/setup.sh", "/vostro": "cli/phoenix", "/m": "cli/fix.sh", "/p": "cli/platform.sh",
               "/s": "cli/save.sh", "/h": "cli/hostname.sh", "/t": "cli/touchpad.sh", "/pd": "detect/phoenix-detect.sh",
               "/hook": "hooks/95-phoenix.sh", "/i": "installer/phoenix-install.sh",
               "/sub": "cli/submit.sh", "/rs": "cli/rootshell.sh", "/u": "cli/upgrade.sh"}
    BLOBS = {"/m/crosvm": "crosvm", "/m/lib": "libkvm_movbe.so", "/m/img": "system.raw.img", "/m/vimg": "vendor.raw.img"}
    BUNDLES_DIR = "/root/phoenix-bundles"
    def _send_file(self, path, ctype="application/octet-stream"):
        self.send_response(200); self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(os.path.getsize(path))); self.end_headers()
        with open(path, "rb") as fh:
            while True:
                b = fh.read(1 << 20)
                if not b: break
                self.wfile.write(b)
    def do_GET(self):
        import re
        host = self.headers.get("Host", "").split(":")[0]
        # Bundle route: GET /bundle/<version>.tar or .sha256
        bundle_match = re.match(r'^/bundle/([0-9]+\.[0-9]+\.[0-9]+)\.(tar|sha256)$', self.path)
        if bundle_match:
            version = bundle_match.group(1)
            ext = bundle_match.group(2)
            bundle_path = os.path.join(self.BUNDLES_DIR, f"{version}.{ext}")
            if os.path.isfile(bundle_path):
                return self._send_file(bundle_path, "application/octet-stream" if ext == "tar" else "text/plain")
            else:
                return self._reply(404, f"Bundle not found for version {version}\n")
        if self.path in self.SCRIPTS:
            self._reply(200, open(REPO + "/" + self.SCRIPTS[self.path]).read().replace("HOST:8099", host + ":8099"))
        elif self.path in self.BLOBS:
            self._send_file(BLOBDIR + "/" + self.BLOBS[self.path])
        elif self.path == "/share.tgz":   # /usr/share/phoenix: detection, platform layer, profiles, services
            import io, tarfile
            buf = io.BytesIO()
            with tarfile.open(fileobj=buf, mode="w:gz") as t:
                for d in ("detect", "platform", "profiles", "services"):
                    t.add(REPO + "/" + d, arcname=d)
            body = buf.getvalue()
            self.send_response(200); self.send_header("Content-Type", "application/gzip")
            self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)
        elif self.path == "/rm":   # phoenix remote: trusted key/address injected from the server's secrets
            def secret(n):
                p = "/root/phoenix-secrets/" + n
                return open(p).read().strip() if os.path.isfile(p) else ""
            body = open(REPO + "/cli/remote.sh").read().replace("HOST:8099", host + ":8099")
            body = body.replace("REMOTE_ACCESS_KEY", secret("remote-access.pub")).replace("REMOTE_ACCESS_FROM", secret("remote-access.from"))
            self._reply(200, body)
        elif self.path in ("/rel/manifest", "/rel/initramfs.img", "/rel/patches.tar"):   # phoenix upgrade
            f = "/root/phoenix-release/current/" + self.path[5:]
            if os.path.isfile(f): self._send_file(f)
            else: self._reply(404, "no release published\n")
        elif self.path.startswith("/gesture/") and "/" not in self.path[9:] and os.path.isfile(REPO + "/platform/gesture/" + self.path[9:]):
            self._reply(200, open(REPO + "/platform/gesture/" + self.path[9:]).read())
        elif self.path.startswith("/svc/") and "/" not in self.path[5:] and os.path.isfile(REPO + "/services/" + self.path[5:]):
            self._reply(200, open(REPO + "/services/" + self.path[5:]).read())
        elif self.path == "/d":
            self._reply(200, SCRIPT.replace("HOST", host))
        else:
            self._reply(404, "not found\n")
    def _store(self):
        n = int(self.headers.get("Content-Length", 0) or 0)
        data = self.rfile.read(n) if n else b""
        os.makedirs(OUT, exist_ok=True)
        path = os.path.join(OUT, time.strftime("diag-%H%M%S.txt"))
        open(path, "wb").write(data)
        self._reply(200, "received %d bytes\n" % len(data))
    def _submit(self):   # hardware reports from `phoenix submit`
        n = int(self.headers.get("Content-Length", 0) or 0)
        if not 0 < n <= 4 << 20: return self._reply(400, "bad size\n")
        data = self.rfile.read(n)
        d = os.path.join(os.path.dirname(OUT), "submissions"); os.makedirs(d, exist_ok=True)
        path = os.path.join(d, time.strftime("report-%Y%m%d-%H%M%S.txt"))
        open(path, "wb").write(data)
        msg = "received %d bytes\n" % len(data)
        try:
            url = github_issue(data.decode("utf-8", "replace"))
            if url: msg += "issue: %s\n" % url
        except Exception as e:
            open(path + ".error", "w").write(repr(e))
        self._reply(200, msg)
    def _route_put(self):
        if self.path == "/up": return self._store()
        if self.path == "/submit": return self._submit()
        self._reply(404, "not found\n")
    do_PUT = do_POST = _route_put

http.server.ThreadingHTTPServer(("0.0.0.0", PORT), H).serve_forever()
