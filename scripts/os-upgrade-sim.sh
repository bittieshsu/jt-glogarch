#!/bin/bash
# Reproduce "Ubuntu 22.04 -> 24.04 upgraded under jt-glogarch" in a container and
# run the REAL deploy/upgrade.sh against it.
#
# An OS release upgrade moves python3 from 3.10 to 3.12; everything pip installed
# for 3.10 (jt-glogarch and all its dependencies) is invisible to 3.12 and the
# service crash-loops with "No module named ..." until upgrade.sh reinstalls it.
# A real customer (another product) hit exactly this after do-release-upgrade.
#
# The container gets a normal install, then its /usr/local/lib/python3.12 packages
# are moved to python3.10 — the state the OS upgrade leaves — and upgrade.sh runs
# with a small systemctl stand-in that really starts the service. Asserts: the
# service is broken before, upgrade.sh says why, the database is backed up (it
# used to be skipped here), the service is healthy after and every schedule is
# registered. Needs docker and internet (pip, Playwright, apt).
#
# Usage: bash scripts/os-upgrade-sim.sh            (from the repo root)
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SRC="${SRC:-$ROOT/github}"   # SRC=<tree> to run another release's deploy/ scripts
IMAGE="${IMAGE:-ubuntu:24.04}"
[ -d "$SRC/deploy" ] || { echo "run from the jt-glogarch repo (needs github/deploy)"; exit 2; }

read -r -d '' INSIDE <<'INNER'
set -u
export DEBIAN_FRONTEND=noninteractive
fail() { echo "  FAIL: $*"; FAILED=1; }
pass() { echo "  PASS: $*"; }
FAILED=0
apt-get update -qq >/dev/null && apt-get install -y -qq python3-pip git curl sudo openssl sqlite3 ca-certificates >/dev/null 2>&1
useradd -r -m -s /usr/sbin/nologin jt-glogarch
git config --global --add safe.directory '*'   # /src is owned by the host's uid
# --- an install as 22.04 left it: a git clone of the release, config, DB, certs
cp -a /src /tmp/tree && cd /tmp/tree && git init -q && git add -A && git -c user.email=s@s -c user.name=s commit -qm sim
git clone -q --bare /tmp/tree /srv/jt.git && git clone -q /srv/jt.git /opt/jt-glogarch
cd /opt/jt-glogarch
cp deploy/config.yaml.example config.yaml
mkdir -p /data/graylog-archives && chown jt-glogarch:jt-glogarch /data/graylog-archives
mkdir -p certs && openssl req -x509 -newkey rsa:2048 -nodes -keyout certs/server.key -out certs/server.crt \
    -days 30 -subj "/CN=localhost" >/dev/null 2>&1
python3 - <<'PY'
import sqlite3
c = sqlite3.connect("/opt/jt-glogarch/jt-glogarch.db")
c.execute("create table sim_marker(v text)"); c.execute("insert into sim_marker values ('kept-before-upgrade')"); c.commit()
PY
pip install -q --break-system-packages --no-build-isolation --no-cache-dir "/opt/jt-glogarch[report]" >/dev/null 2>&1
chown -R jt-glogarch:jt-glogarch /opt/jt-glogarch
# --- the OS upgrade: what pip installed now belongs to a Python that is gone
mv /usr/local/lib/python3.12/dist-packages /usr/local/lib/python3.10-dist-packages-tmp
mkdir -p /usr/local/lib/python3.10 /usr/local/lib/python3.12/dist-packages
mv /usr/local/lib/python3.10-dist-packages-tmp /usr/local/lib/python3.10/dist-packages
if /usr/local/bin/glogarch --help >/tmp/before.log 2>&1; then
    fail "the simulated OS upgrade did not break the service entry point"
elif grep -q "ModuleNotFoundError" /tmp/before.log; then
    pass "after the OS upgrade the service cannot start: $(grep -m1 ModuleNotFoundError /tmp/before.log)"
fi
# --- systemctl stand-in: restart really starts the server and waits for it
cat > /usr/local/sbin/systemctl <<'SC'
#!/bin/bash
case "$1" in
  restart)
    pkill -f "glogarch server" 2>/dev/null; sleep 1
    (cd /opt/jt-glogarch && sudo -u jt-glogarch nohup /usr/local/bin/glogarch server >/tmp/server.log 2>&1 &)
    for i in $(seq 1 60); do curl -sk https://localhost:8990/api/health >/dev/null 2>&1 && exit 0; sleep 1; done
    exit 0 ;;
  *) exit 0 ;;
esac
SC
chmod +x /usr/local/sbin/systemctl
# --- the real upgrade
bash /opt/jt-glogarch/deploy/upgrade.sh </dev/null >/tmp/upgrade.log 2>&1
rc=$?
grep -v "Running pip as\|pip.pypa.io" /tmp/upgrade.log | sed 's/^/    | /' | tail -40
[ $rc -eq 0 ] && pass "upgrade.sh exit 0" || fail "upgrade.sh exit $rc"
grep -q "python3 is now 3.12, but jt-glogarch was installed for Python 3.10" /tmp/upgrade.log \
    && pass "upgrade.sh says python3 changed and why it reinstalls" || fail "no Python-change notice"
B=$(ls /var/backups/jt-glogarch/jt-glogarch-*.db 2>/dev/null | head -1)
if [ -n "$B" ] && [ "$(sqlite3 "$B" 'select v from sim_marker')" = "kept-before-upgrade" ]; then
    pass "the database was backed up before anything changed ($B)"
else
    fail "no usable database backup"
fi
grep -q "Health: healthy" /tmp/upgrade.log && pass "service healthy after the upgrade" || fail "service not healthy"
S=$(sed -n 's/^ *Schedules registered: *//p' /tmp/upgrade.log)
case "$S" in ?*/?*) [ "${S%%/*}" = "${S##*/}" ] && pass "every enabled schedule registered ($S)" || fail "schedules $S" ;; *) fail "no schedule count";; esac
[ -d /usr/local/lib/python3.12/dist-packages/glogarch ] && pass "reinstalled for Python 3.12" || fail "not reinstalled for 3.12"
/usr/local/bin/glogarch --help >/dev/null 2>&1 && pass "the service entry point runs again" || fail "entry point still broken"
[ "$(sqlite3 /opt/jt-glogarch/jt-glogarch.db 'select v from sim_marker')" = "kept-before-upgrade" ] \
    && pass "database content intact" || fail "database content changed"
[ $FAILED -eq 0 ] && echo "=== RESULT: ALL PASS ===" || echo "=== RESULT: FAIL ==="
exit $FAILED
INNER

docker run --rm -v "$SRC":/src:ro "$IMAGE" bash -c "$INSIDE"
