#!/usr/bin/env python3
# Temporary LAN helper for the Vostro: GET /d serves the diagnostic script,
# PUT/POST /up stores whatever the Vostro sends back in /root/brunch-build/diag/.
import http.server, os, time

PORT = 8099
REPO = "/root/phoenix"   # rsync of the phoenix-chromeos repo
OUT = "/root/brunch-build/diag"
SCRIPT = r'''#!/bin/sh
{
echo "## CPU / KVM"; grep -c vmx /proc/cpuinfo; ls -l /dev/kvm
cat /sys/module/kvm_intel/parameters/ept /sys/module/kvm_intel/parameters/unrestricted_guest
free -m | head -2; uname -r; grep -m1 "model name" /proc/cpuinfo
echo "## phoenix detect"; curl -s http://HOST:8099/pd > /tmp/phoenix-detect.sh && sh /tmp/phoenix-detect.sh --summary && sh /tmp/phoenix-detect.sh
echo "## input"; grep -E "^N: Name|^H: Handlers" /proc/bus/input/devices; grep -o "psmouse[^ ]*\|i8042[^ ]*" /proc/cmdline
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

class H(http.server.BaseHTTPRequestHandler):
    def _reply(self, code, body):
        self.send_response(code); self.send_header("Content-Type", "text/plain")
        self.end_headers(); self.wfile.write(body.encode())
    def do_GET(self):
        if self.path == "/pd":
            self._reply(200, open(REPO + "/detect/phoenix-detect.sh").read())
        elif self.path == "/h":
            host = self.headers.get("Host", "").split(":")[0]
            self._reply(200, open(REPO + "/cli/hostname.sh").read().replace("HOST", host))
        elif self.path.startswith("/svc/") and "/" not in self.path[5:] and os.path.isfile(REPO + "/services/" + self.path[5:]):
            self._reply(200, open(REPO + "/services/" + self.path[5:]).read())
        elif self.path == "/t":
            self._reply(200, open("/root/brunch-build/touchpad.sh").read())
        elif self.path in ("/v", "/vostro"):
            host = self.headers.get("Host", "").split(":")[0]
            f = "vostro-setup.sh" if self.path == "/v" else "vostro.sh"
            self._reply(200, open("/root/brunch-build/" + f).read().replace("HOST", host))
        elif self.path == "/m":
            host = self.headers.get("Host", "").split(":")[0]
            self._reply(200, open("/root/brunch-build/movbe/movbe-patch.sh").read().replace("HOST", host))
        elif self.path in ("/m/crosvm", "/m/lib", "/m/img", "/m/vimg"):
            f = {"/m/crosvm": "crosvm", "/m/lib": "libkvm_movbe.so", "/m/img": "system.raw.img", "/m/vimg": "vendor.raw.img"}[self.path]
            path = "/root/brunch-build/movbe/" + f
            self.send_response(200); self.send_header("Content-Type", "application/octet-stream")
            self.send_header("Content-Length", str(os.path.getsize(path))); self.end_headers()
            with open(path, "rb") as fh:
                while True:
                    b = fh.read(1 << 20)
                    if not b: break
                    self.wfile.write(b)
        elif self.path == "/i":
            host = self.headers.get("Host", "").split(":")[0]
            self._reply(200, open(REPO + "/installer/phoenix-install.sh").read().replace("HOST:8099", host + ":8099"))
        elif self.path == "/d":
            host = self.headers.get("Host", "").split(":")[0]
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
    do_PUT = do_POST = lambda self: self._store() if self.path == "/up" else self._reply(404, "not found\n")

http.server.ThreadingHTTPServer(("0.0.0.0", PORT), H).serve_forever()
