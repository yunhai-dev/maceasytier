#!/bin/bash
# 守护进程协议回归测试（无需 root、无需联网）：
# 以当前用户身份运行 MacEasyTierHelper（非 TUN 配置），验证 START/STATUS/STOP、参数校验、
# owner 进程消失后的自动清理，以及启停耗时。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ARCH="${ARCH:-$(uname -m)}"
CORE="${CORE:-$ROOT/Vendor/easytier/$ARCH/easytier-core}"
WORK="$(mktemp -d /tmp/maceasytier-helper-test.XXXXXX)"
trap 'kill "${HELPER_PID:-0}" 2>/dev/null || true; rm -rf "$WORK"' EXIT

[[ -x "$CORE" ]] || { echo "missing $CORE (run Scripts/fetch-core.sh)" >&2; exit 1; }

xcrun clang -O2 -Wall -Wextra -o "$WORK/helper" "$ROOT/Helper/MacEasyTierHelper.c"

cat > "$WORK/config.toml" <<TOML
instance_name = "helper-test"
hostname = "helper-test"
dhcp = true
listeners = []

[network_identity]
network_name = "helper-test-$$"
network_secret = "helper-test"

[flags]
no_tun = true
TOML
chmod 600 "$WORK/config.toml"

SOCK="$WORK/h.sock"
"$WORK/helper" --socket "$SOCK" --core "$CORE" --uid "$(id -u)" --tag test 2>"$WORK/helper.log" &
HELPER_PID=$!
for _ in $(seq 1 50); do [[ -S "$SOCK" ]] && break; sleep 0.1; done

SOCK="$SOCK" CONFIG="$WORK/config.toml" LOG="$WORK/core.log" python3 - <<'PY'
import os, socket, subprocess, sys, time

SOCK, CONFIG, LOG = os.environ["SOCK"], os.environ["CONFIG"], os.environ["LOG"]

def req(*fields, timeout=5):
    s = socket.socket(socket.AF_UNIX)
    s.settimeout(timeout)
    s.connect(SOCK)
    s.sendall(("\t".join(fields) + "\n").encode())
    data = b""
    while True:
        chunk = s.recv(4096)
        if not chunk:
            break
        data += chunk
    s.close()
    return data.decode().strip()

def start(cid, port, owner):
    return req("START", cid, str(port), str(owner), "info", "-", CONFIG, LOG)

fails = []
def check(name, cond, detail=""):
    print(("PASS " if cond else "FAIL ") + name + (f"  [{detail}]" if detail and not cond else ""))
    if not cond:
        fails.append(name)

check("PING", req("PING").startswith("OK\t2\ttest"))

t = time.time()
reply = start("net-1", 53911, os.getpid())
start_ms = (time.time() - t) * 1000
check("START ok", reply.startswith("OK\t"), reply)
check("START fast (<500ms)", start_ms < 500, f"{start_ms:.0f}ms")
check("START duplicate rejected", "already running" in start("net-1", 53911, os.getpid()))
check("START bad id rejected", start("../x", 53912, os.getpid()).startswith("ERR"))
check("START bad port rejected", start("net-9", 80, os.getpid()).startswith("ERR"))
check("START foreign config rejected",
      req("START", "net-8", "53913", str(os.getpid()), "info", "-", "/etc/hosts", LOG).startswith("ERR"))

status = req("STATUS")
check("STATUS lists core", "CORE\tnet-1\t" in status and status.endswith("END"), status)

t = time.time()
reply = req("STOP", "net-1")
stop_ms = (time.time() - t) * 1000
check("STOP ok", reply == "OK", reply)
check("STOP fast (<1500ms)", stop_ms < 1500, f"{stop_ms:.0f}ms")
check("STATUS empty after STOP", "CORE\t" not in req("STATUS"))
check("STOP unknown is idempotent", req("STOP", "net-1") == "OK")

owner = subprocess.Popen(["sleep", "60"])
check("START with owner", start("net-3", 53914, owner.pid).startswith("OK\t"))
time.sleep(0.5)
owner.kill(); owner.wait()
t = time.time()
while "CORE\t" in req("STATUS") and time.time() - t < 5:
    time.sleep(0.05)
check("owner exit stops core (<2s)", time.time() - t < 2, f"{time.time() - t:.2f}s")

check("START after stop (restart)", start("net-1", 53915, os.getpid()).startswith("OK\t"))
check("STOPALL", req("STOPALL") == "OK")
time.sleep(0.5)
check("STATUS empty after STOPALL", "CORE\t" not in req("STATUS"))

print(f"\nstart={start_ms:.0f}ms stop={stop_ms:.0f}ms")
sys.exit(1 if fails else 0)
PY
