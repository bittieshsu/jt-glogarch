#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Jason Cheng (Jason Tools)
"""Alerting e2e: real bulk changes against a real Graylog, then clean up.

Run against a TEST Graylog only (e.g. .83) — it creates and deletes event
definitions, notifications and a user:

    GL_URL=http://<test-graylog>:9000 GL_USER=admin GL_PASS=... \
        python3 scripts/e2e-alerting-test.py

Everything it creates is named jt-e2e-alert-*; leftovers from an aborted run are
removed at the start. Prints RESULT: ALL PASS on success.

Steps
  [1] sign in as a Graylog user (session, the way the Web UI does)
  [2] create 2 notifications + 30 definitions, 12 of them DISABLED
  [3] add N2 to all 30 -> every one has N2, NO definition changed state,
      every other field byte-identical
  [4] a definition edited in Graylog between preview and apply is skipped,
      not overwritten
  [5] replace N1 -> N2 (remove was covered in [4])
  [6] undo the replace batch -> notifications exactly as before it
  [7] the Graylog system definition is never written
  [8] a Reader-role user cannot change anything: batch stops, nothing written
"""

from __future__ import annotations

import asyncio
import copy
import os
import sys
import tempfile
from pathlib import Path

import httpx

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from glogarch.core.database import ArchiveDB  # noqa: E402
from glogarch.graylog import alerting as gla  # noqa: E402

URL = os.environ.get("GL_URL", "http://127.0.0.1:9000").rstrip("/")
USER = os.environ.get("GL_USER", "admin")
PW = os.environ.get("GL_PASS", "")
PFX = "jt-e2e-alert-"
H = {"Accept": "application/json", "X-Requested-By": "jt-e2e"}
fails: list[str] = []


def check(cond, msg):
    print(("  PASS " if cond else "  FAIL ") + msg)
    if not cond:
        fails.append(msg)


def admin() -> httpx.Client:
    return httpx.Client(base_url=URL + "/api", auth=(USER, PW), headers=H, timeout=30)


def cleanup(c: httpx.Client):
    defs = c.get("/events/definitions", params={"per_page": 500}).json()["event_definitions"]
    for d in defs:
        if d["title"].startswith(PFX):
            c.delete(f"/events/definitions/{d['id']}")
    ns = c.get("/events/notifications", params={"per_page": 500}).json()["notifications"]
    for n in ns:
        if n["title"].startswith(PFX):
            c.delete(f"/events/notifications/{n['id']}")
    if c.get(f"/users/{PFX}reader").status_code == 200:
        c.delete(f"/users/{PFX}reader")


def create_notif(c, title):
    body = {"title": title, "description": "e2e", "config": {"type": "http-notification-v1",
                                                            "url": "http://127.0.0.1:9/never"}}
    r = c.post("/events/notifications", json={"entity": body})      # Graylog 7
    if r.status_code == 400:
        r = c.post("/events/notifications", json=body)                # Graylog 6
    r.raise_for_status()
    return r.json()["id"]


def create_def(c, i, enabled, notifs):
    body = {"title": f"{PFX}{i:02d}", "description": f"e2e {i}", "priority": 1 + i % 3, "alert": False,
            "config": {"type": "aggregation-v1", "query": f"jt_e2e_never_matches_{i}",
                       "query_parameters": [], "streams": [], "filters": [],
                       "search_within_ms": 300000, "execute_every_ms": 300000,
                       "use_cron_scheduling": False, "group_by": [], "series": [],
                       "conditions": {"expression": None}, "event_limit": 100},
            "field_spec": {}, "key_spec": [],
            "notification_settings": {"grace_period_ms": 60000 * i, "backlog_size": i},
            "notifications": [{"notification_id": n, "notification_parameters": None} for n in notifs],
            "storage": [{"type": "persist-to-streams-v1", "streams": ["000000000000000000000002"]}]}
    params = {"schedule": "true" if enabled else "false"}
    r = c.post("/events/definitions", params=params, json={"entity": body})
    if r.status_code == 400:
        r = c.post("/events/definitions", params=params, json=body)
    r.raise_for_status()
    return r.json()["id"]


def snapshot(c) -> dict:
    defs = c.get("/events/definitions", params={"per_page": 500}).json()["event_definitions"]
    return {d["id"]: d for d in defs if d["title"].startswith(PFX)}


def strip(d):
    d = copy.deepcopy(d)
    for k in ("notifications", "updated_at", "matched_at"):
        d.pop(k, None)
    return d


async def run_batch(ident_auth, db, defs, ids, action, batch_id, items=None, undoes=None):
    async with gla.AlertingClient(URL, ident_auth) as cl:
        if items is None:
            items = gla.plan(defs, ids, action)["change"]
        return await gla.apply_batch(cl, db, batch_id=batch_id, server="e2e", username=USER,
                                     items=items, action=action, delay=0, undoes_batch=undoes)


async def main():
    if not PW:
        print("GL_PASS is required")
        return 2
    c = admin()
    print(f"Graylog {c.get('/system').json().get('version')} at {URL}")
    cleanup(c)
    db = ArchiveDB(str(Path(tempfile.mkdtemp()) / "e2e-alerting.db"))

    print("[1] sign in as a Graylog user")
    sess = await gla.create_session(URL, USER, PW, False)
    auth = (sess["session_id"], "session")
    async with gla.AlertingClient(URL, auth) as cl:
        check(await cl.whoami() == USER, f"session belongs to {USER}")

    try:
        print("[2] create 2 notifications + 30 definitions (12 disabled)")
        n1, n2 = create_notif(c, PFX + "n1"), create_notif(c, PFX + "n2")
        ids = [create_def(c, i, enabled=(i % 5 >= 2), notifs=[n1] if i % 2 else []) for i in range(30)]
        before = snapshot(c)
        disabled = {i for i, d in before.items() if d["state"] != "ENABLED"}
        check(len(before) == 30 and len(disabled) == 12, f"30 created, {len(disabled)} disabled")

        print("[3] add N2 to all 30")
        async with gla.AlertingClient(URL, auth) as cl:
            all_defs = await cl.list_definitions()
        r = await run_batch(auth, db, all_defs, ids, gla.Action(type="add", ids=[n2]), "b-add")
        after = snapshot(c)
        check(r["changed"] == 30 and not r["failed"], f"changed {r['changed']}, failed {len(r['failed'])}")
        check(all(n2 in gla.notif_ids(d) for d in after.values()), "every definition has N2")
        check({i for i, d in after.items() if d["state"] != "ENABLED"} == disabled,
              "no definition changed enabled/disabled state")
        check(all(strip(after[i]) == strip(before[i]) for i in ids), "every other field identical")
        check(all(gla.notif_ids(after[i])[:-1] == gla.notif_ids(before[i]) for i in ids),
              "existing notifications kept, in order")

        print("[4] edited between preview and apply -> skipped")
        async with gla.AlertingClient(URL, auth) as cl:
            all_defs = await cl.list_definitions()
        rem = gla.Action(type="remove", ids=[n2])
        items = gla.plan(all_defs, ids[:3], rem)["change"]
        target = copy.deepcopy(after[ids[1]])
        target["notifications"] = []
        c.put(f"/events/definitions/{ids[1]}", params={"schedule": "true" if gla.schedule_for(target) else "false"},
              json=target).raise_for_status()
        r = await run_batch(auth, db, all_defs, ids[:3], rem, "b-conflict", items=items)
        check(r["changed"] == 2 and [s["id"] for s in r["skipped"]] == [ids[1]],
              "the edited definition was skipped, the other two changed")
        check(gla.notif_ids(snapshot(c)[ids[1]]) == [], "the edit made in Graylog was kept")

        print("[5] replace N1 -> N2")
        async with gla.AlertingClient(URL, auth) as cl:
            all_defs = await cl.list_definitions()
        pre_replace = snapshot(c)
        rep = gla.Action(type="replace", src=n1, dst=n2)
        r = await run_batch(auth, db, all_defs, ids, rep, "b-replace")
        s = snapshot(c)
        check(not any(n1 in gla.notif_ids(d) for d in s.values()), "N1 gone everywhere")
        check(all(gla.notif_ids(d).count(n2) <= 1 for d in s.values()), "N2 never listed twice")
        check({i for i, d in s.items() if d["state"] != "ENABLED"} == disabled, "states unchanged")

        print("[6] undo the replace batch")
        items = gla.restore_items(db.list_alerting_changes("b-replace"))
        r = await run_batch(auth, db, [], [], gla.Action(type="restore"), "b-undo", items=items,
                            undoes="b-replace")
        s = snapshot(c)
        check(all(gla.notif_ids(s[i]) == gla.notif_ids(pre_replace[i]) for i in ids),
              "notifications exactly as before the replace")
        check({i for i, d in s.items() if d["state"] != "ENABLED"} == disabled, "states unchanged")

        print("[7] the Graylog system definition is never written")
        async with gla.AlertingClient(URL, auth) as cl:
            all_defs = await cl.list_definitions()
        sysdefs = [d for d in all_defs if d.get("_scope") == gla.SYSTEM_SCOPE]
        if sysdefs:
            p = gla.plan(all_defs, [sysdefs[0]["id"]], gla.Action(type="add", ids=[n2]))
            check(not p["change"] and p["skipped"], "system definition skipped in the plan")
        else:
            print("  (no system definition on this Graylog)")

        print("[8] a Reader cannot change anything")
        ur = c.post("/users", json={"username": PFX + "reader", "password": "Jt-e2e-Reader-2026!",
                                    "email": "jt-e2e@example.invalid", "first_name": "jt", "last_name": "e2e",
                                    "roles": ["Reader"], "permissions": []})
        if ur.status_code in (200, 201):
            rs = await gla.create_session(URL, PFX + "reader", "Jt-e2e-Reader-2026!", False)
            before_r = snapshot(c)
            try:
                async with gla.AlertingClient(URL, (rs["session_id"], "session")) as cl:
                    try:
                        visible = await cl.list_definitions()
                    except gla.GraylogPermissionError:
                        visible = []
                items = [{"id": i, "title": "", "before": gla.notif_ids(before_r[i])} for i in ids[:3]]
                r = await run_batch((rs["session_id"], "session"), db, visible, [],
                                    gla.Action(type="add", ids=[n1]), "b-reader", items=items)
                check(r["changed"] == 0 and (r["aborted"] or r["failed"]),
                      f"refused ({r['aborted'] or r['failed'][0]['reason']})")
                check(all(gla.notif_ids(snapshot(c)[i]) == gla.notif_ids(before_r[i]) for i in ids[:3]),
                      "nothing written")
            finally:
                await gla.delete_session(URL, rs["session_id"], False)
        else:
            check(False, f"could not create the Reader user: HTTP {ur.status_code} {ur.text[:120]}")
    finally:
        await gla.delete_session(URL, sess["session_id"], False)
        cleanup(c)
        left = snapshot(c)
        check(not left, "cleanup removed every jt-e2e-alert definition")
        db.close()

    print("RESULT: ALL PASS" if not fails else f"RESULT: {len(fails)} FAIL")
    return 0 if not fails else 1


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
