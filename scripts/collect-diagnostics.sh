#!/usr/bin/env bash
# jt-glogarch diagnostics collector — READ-ONLY (changes nothing, deletes nothing).
#
# Run as root on the jt-glogarch host:
#   sudo bash collect-diagnostics.sh              # last 14 days
#   sudo bash collect-diagnostics.sh 2026-09-01   # since a date
#
# Produces /tmp/jt-glogarch-diag-<host>-<time>.tar.gz containing:
#   health.json, version.txt, systemctl.txt, host.txt, oom.txt
#   journal.log.gz          service log since <SINCE>
#   config.redacted.json    config.yaml with passwords/tokens/keys replaced by ***
#   db_*.json               jobs / schedules / archive coverage (DB opened read-only)
#   graylog_<server>.json   Graylog version, JVM, journal, buffers, index sets, index ranges
#   opensearch_<server>.json cluster health, node heap, indices, search thread pool
# Secrets are redacted; hostnames, IPs and index names are NOT (needed for analysis).
set -u
SINCE="${1:-$(date -d '14 days ago' +%F)}"
OPT=/opt/jt-glogarch
TS=$(date +%Y%m%d-%H%M)
WORK=$(mktemp -d /tmp/jt-diag.XXXXXX)
OUTFILE="/tmp/jt-glogarch-diag-$(hostname -s)-${TS}.tar.gz"
echo "==> collecting since ${SINCE} into ${WORK}"

curl -sk --max-time 15 https://localhost:8990/api/health > "$WORK/health.json" 2>&1
systemctl status jt-glogarch --no-pager > "$WORK/systemctl.txt" 2>&1
{ echo "## date"; date; echo "## uptime"; uptime; echo "## nproc"; nproc
  echo "## free -m"; free -m; echo "## df -h"; df -h /data/graylog-archives "$OPT" / 2>&1
  echo "## timezone"; timedatectl 2>/dev/null | grep -i "time zone"
  echo "## top memory processes"; ps -eo pid,rss,etime,comm --sort=-rss | head -15
} > "$WORK/host.txt" 2>&1
dmesg -T 2>/dev/null | grep -iE 'out of memory|oom-kill|killed process' | tail -50 > "$WORK/oom.txt"
echo "==> service journal (may take a moment)"
journalctl -u jt-glogarch --since "$SINCE" -o short-iso --no-pager 2>&1 | gzip > "$WORK/journal.log.gz"

python3 - "$WORK" "$SINCE" "$OPT" <<'PY'
import json, os, re, sqlite3, sys
work, since, opt = sys.argv[1:4]

def save(name, data):
    with open(os.path.join(work, name), "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=1, default=str)

SECRET = re.compile(r"pass|token|secret|key|hash|webhook|chat_id|cookie|credential", re.I)
def redact(o):
    if isinstance(o, dict):
        return {k: ("***" if (SECRET.search(str(k)) and v not in (None, "", [], {})) else redact(v))
                for k, v in o.items()}
    if isinstance(o, list):
        return [redact(v) for v in o]
    return o

try:
    import glogarch
    ver = glogarch.__version__
except Exception as e:
    ver = f"import failed: {e}"
open(os.path.join(work, "version.txt"), "w").write(ver + "\n")

cfg, cfg_path = {}, None
for p in (f"{opt}/config.yaml", "/etc/jt-glogarch/config.yaml"):
    if os.path.exists(p):
        cfg_path = p
        break
if cfg_path:
    try:
        import yaml
        cfg = yaml.safe_load(open(cfg_path, encoding="utf-8")) or {}
        save("config.redacted.json", {"path": cfg_path, "config": redact(cfg)})
    except Exception as e:
        save("config.redacted.json", {"error": str(e)})

# --- database, read-only ------------------------------------------------------
db_path = f"{opt}/jt-glogarch.db"
try:
    con = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True, timeout=30)
    con.row_factory = sqlite3.Row
    q = lambda sql, *a: [dict(r) for r in con.execute(sql, a)]

    def jsonfield(rows, col):
        for r in rows:
            try:
                r[col] = redact(json.loads(r[col])) if r.get(col) else r.get(col)
            except Exception:
                r[col] = "(unparseable)"
        return rows

    save("db_columns.json", {t: [c["name"] for c in q(f"PRAGMA table_info({t})")]
                             for t in ("jobs", "archives", "schedules")})
    jobs = jsonfield(q("SELECT * FROM jobs WHERE created_at >= ? ORDER BY created_at", since), "config_json")
    if jobs and "result_json" in jobs[0]:
        jobs = jsonfield(jobs, "result_json")
    save("db_jobs.json", jobs)
    save("db_running_jobs.json", jsonfield(q("SELECT * FROM jobs WHERE status IN ('running','pending')"), "config_json"))
    save("db_schedules.json", jsonfield(q("SELECT * FROM schedules"), "config_json"))
    save("db_archive_status.json", q("SELECT status, COUNT(*) n, SUM(message_count) msgs FROM archives GROUP BY status"))
    save("db_archive_daily.json", q(
        "SELECT substr(time_from,1,10) day, COUNT(*) archives, SUM(message_count) msgs, "
        "SUM(file_size_bytes) bytes FROM archives WHERE status='completed' GROUP BY day ORDER BY day"))
    save("db_archive_per_index.json", q(
        "SELECT server_name, stream_id, COUNT(*) archives, MIN(time_from) first_from, MAX(time_to) last_to, "
        "SUM(message_count) msgs FROM archives WHERE status='completed' "
        "GROUP BY server_name, stream_id ORDER BY server_name, stream_id"))
    save("db_archives_created_since.json", q(
        "SELECT server_name, stream_id, time_from, time_to, message_count, created_at FROM archives "
        "WHERE created_at >= ? ORDER BY created_at", since))
    save("db_latest_archives.json", q(
        "SELECT server_name, stream_id, time_from, time_to, message_count, status, created_at "
        "FROM archives ORDER BY time_to DESC LIMIT 100"))
except Exception as e:
    save("db_error.json", {"error": str(e)})

# --- Graylog + OpenSearch, read-only GETs -----------------------------------
try:
    import httpx
except Exception:
    httpx = None

def fetch(client, url, auth):
    try:
        r = client.get(url, auth=auth, timeout=30)
        try:
            return {"status": r.status_code, "body": r.json()}
        except Exception:
            return {"status": r.status_code, "text": r.text[:20000]}
    except Exception as e:
        return {"error": str(e)}

if httpx:
    with httpx.Client(verify=False) as c:   # diagnostics only; many sites use self-signed certs
        for s in cfg.get("servers") or []:
            name = re.sub(r"[^A-Za-z0-9_.-]", "_", str(s.get("name", "server")))
            base = str(s.get("url", "")).rstrip("/")
            if base.endswith("/api"):
                base = base[:-4]
            auth = ((s["auth_token"], "token") if s.get("auth_token")
                    else (s.get("username") or "", s.get("password") or ""))
            out = {}
            for ep in ("/api/system", "/api/system/jvm", "/api/system/journal",
                       "/api/system/buffers", "/api/system/indices/index_sets?stats=true",
                       "/api/system/indices/ranges", "/api/system/deflector",
                       "/api/datanodes"):
                out[ep] = fetch(c, base + ep, auth)
            save(f"graylog_{name}.json", out)

            os_cfg = s.get("opensearch") or cfg.get("opensearch") or {}
            hosts = os_cfg.get("hosts") or []
            os_auth = ((os_cfg.get("username"), os_cfg.get("password") or "")
                       if os_cfg.get("username") else None)
            osout = {"hosts": hosts}
            for h in hosts:
                h = h.rstrip("/")
                probe = fetch(c, h + "/_cluster/health", os_auth)
                osout[h] = {"_cluster/health": probe}
                if probe.get("status") == 200:
                    for ep in ("/_cat/nodes?format=json&h=name,ip,node.role,heap.percent,heap.max,ram.percent,cpu,load_1m,disk.used_percent",
                               "/_cat/indices?format=json&h=index,health,status,pri,rep,docs.count,store.size,creation.date.string&s=index",
                               "/_cat/thread_pool/search?format=json&h=node_name,active,queue,rejected,completed",
                               "/_nodes/stats/breaker",
                               "/_cluster/settings?include_defaults=false"):
                        osout[h][ep] = fetch(c, h + ep, os_auth)
                    break
            save(f"opensearch_{name}.json", osout)
print("python collection done")
PY

tar -czf "$OUTFILE" -C "$WORK" . && rm -rf "$WORK"
echo "==> done: $OUTFILE ($(ls -lh "$OUTFILE" | awk '{print $5}'))"
