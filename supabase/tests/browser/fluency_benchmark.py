"""Fluency benchmark: the REAL frontend, legacy vs fluent read path, same data (docs/FLUENCY_BENCHMARKS.md). LOCAL ONLY.

Synthetic user and characters inside isolation. Chromium network emulation adds LATENCY per request. The database CPU is
whatever the caller set on the local db container (docker update --cpus 0.5 supabase_db_tavern_ledger = production speed).
Usage: LATENCIES=0,50,150,300 N=5 OUT=<json> python fluency_benchmark.py
"""
import json
import os
import statistics
import time

from playwright.sync_api import sync_playwright

import isolation as iso
from class_ui_common import APP, RUN, Sheet, User
from incident_probe import Net, USABLE, emulate

# Chromium latency emulation had no measurable effect in this setup (docs/FLUENCY_BENCHMARKS.md); default: local latency only
LAT = [int(x) for x in os.environ.get("LATENCIES", "0").split(",")]
N = int(os.environ.get("N", "5"))
OUT = os.environ.get("OUT")
NAME_IN_HEADER = "(n) => !!document.querySelector('.sheet-root .sheet') && document.querySelector('.sheet-root').textContent.includes(n)"


def med(xs):
    xs = [x for x in xs if x is not None]
    return round(statistics.median(xs) * 1000) if xs else None


def p95(xs):
    xs = sorted(x for x in xs if x is not None)
    return round(xs[min(len(xs) - 1, int(len(xs) * 0.95))] * 1000) if xs else None


def no_offline_copy(page):
    """Legacy opens otherwise paint the localStorage offline copy first (not a network result): removed before each open."""
    page.evaluate("() => Object.keys(localStorage).filter((k) => k.includes('bundle:')).forEach((k) => localStorage.removeItem(k))")


def bump_rules_epoch():
    """Every server-side cached rules result becomes invalid (as after a catalog / campaign change): a cold open."""
    iso.psql("update tl_cache.global_rev set rev = rev + 1 where id = 1")


def open_measure(s, net, cid, name, settle=2500):
    no_offline_copy(s.page)
    i = net.mark()
    t0 = time.time()
    s.page.evaluate(f"location.hash = '#/c/{cid}'")
    s.page.wait_for_function(NAME_IN_HEADER, arg=name, timeout=60000); t_id = time.time() - t0
    s.page.wait_for_function(USABLE, timeout=60000); t_vit = time.time() - t0
    s.page.wait_for_timeout(settle)
    rows = net.since(i)
    mine = [r for r in rows if r["t1"]]
    t_full = max((r["t1"] for r in mine), default=t0 + t_vit) - t0
    bad = sum(1 for r in rows if str(r["outcome"]).startswith("failed"))
    return {"identity": t_id, "vitals": t_vit, "full": max(t_full, t_vit), "requests": len(rows), "failed": bad}


def run(t):
    pl = User("bench")
    spec = (("A", [("fighter-phb", 5)]), ("B", [("wizard-phb", 5)]), ("C", [("cleric-phb", 3), ("fighter-phb", 2)]),
            ("D", [("rogue-phb", 2)]), ("E", [("druid-phb", 4)]), ("F", [("paladin-phb", 3)]))
    chars = {k: pl.character(f"Bench {k} {RUN}", v, strength=14, dexterity=14, constitution=14, wisdom=14, intelligence=14) for k, v in spec}
    names = {k: f"Bench {k} {RUN}" for k in chars}
    t.note(characters=list(chars.values()))
    out = {"run": RUN, "n": N, "results": {}}
    with sync_playwright() as p:
        b = p.chromium.launch(channel="msedge", headless=True)
        for mode in ("legacy", "progressive"):
            flag = "0" if mode == "legacy" else "1"
            s = Sheet(b, pl, tab="combat"); s.page.goto(APP + f"?fluent={flag}"); s.page.wait_for_selector(".char-card", timeout=20000)
            net = Net(s.page)
            open_measure(s, net, chars["D"], names["D"])            # warm session catalogs
            for lat in LAT:
                emulate(s, s.page, lat)
                runs = []
                for i in range(N):
                    k = "ABCEF"[i % 5]
                    s.page.evaluate("location.hash = '#/'"); s.page.wait_for_selector(".char-card", timeout=20000); s.page.wait_for_timeout(300)
                    runs.append(open_measure(s, net, chars[k], names[k]))
                key = f"{mode}@{lat}"
                out["results"][key] = {"identity_ms": med([r["identity"] for r in runs]), "vitals_ms": med([r["vitals"] for r in runs]),
                                       "vitals_p95_ms": p95([r["vitals"] for r in runs]), "full_ms": med([r["full"] for r in runs]),
                                       "requests": round(statistics.median(r["requests"] for r in runs)), "failed": sum(r["failed"] for r in runs)}
                print(key, out["results"][key], flush=True)
            # switch A -> B -> C (120 ms apart) at 150 ms; first tab open and cached tab; Background picker
            emulate(s, s.page, 150)
            sw = []
            for _ in range(3):
                s.page.evaluate("location.hash = '#/'"); s.page.wait_for_selector(".char-card", timeout=20000); s.page.wait_for_timeout(300)
                i = net.mark(); t0 = time.time()
                for k in "ABC":
                    s.page.evaluate(f"location.hash = '#/c/{chars[k]}'"); s.page.wait_for_timeout(120)
                s.page.wait_for_function(NAME_IN_HEADER, arg=names["C"], timeout=60000); s.page.wait_for_function(USABLE, timeout=60000)
                sw.append({"c_usable": time.time() - t0, "requests": len(net.since(i)),
                           "stale": s.page.evaluate("(n) => document.querySelector('.sheet-root').textContent.includes(n)", names["A"])})
                s.page.wait_for_timeout(2000)
            out["results"][f"{mode}@switch_ABC_150"] = {"c_usable_ms": med([x["c_usable"] for x in sw]), "requests": round(statistics.median(x["requests"] for x in sw)),
                                                       "stale_render": any(x["stale"] for x in sw)}
            tabs = {}
            for tab in ("spells", "inventory"):
                i = net.mark(); t0 = time.time(); s.page.locator(f'.tab[data-tab="{tab}"]').click()
                sel = "#spellbook-list *" if tab == "spells" else "#inventory-app .inv-summary, #inventory-app [data-inv-row], #inventory-app .empty-state, #inventory-app table"
                try: s.page.wait_for_selector(sel, timeout=30000)
                except Exception: pass
                s.page.wait_for_timeout(1500)
                first = {"ms": round((time.time() - t0) * 1000), "requests": len(net.since(i))}
                s.page.locator('.tab[data-tab="combat"]').click(); s.page.wait_for_timeout(500)
                i = net.mark(); s.page.locator(f'.tab[data-tab="{tab}"]').click(); s.page.wait_for_timeout(800)
                tabs[tab] = {"first": first, "cached_requests": len(net.since(i))}
            out["results"][f"{mode}@tabs_150"] = tabs
            s.page.locator('.tab[data-tab="features"]').click(); s.page.wait_for_timeout(500)
            i = net.mark(); t0 = time.time()
            s.page.locator('[data-action="bg-choose"]').first.click()
            s.page.wait_for_selector(".modal [data-bg-pick]", timeout=30000); t_list = time.time() - t0
            t1 = time.time(); s.page.locator(".modal [data-bg-pick]").first.click()
            s.page.wait_for_selector(".modal [data-bg-editor]", timeout=30000); t_det = time.time() - t1
            out["results"][f"{mode}@background_150"] = {"list_ms": round(t_list * 1000), "detail_ms": round(t_det * 1000),
                                                       "requests": [r["name"] for r in net.since(i)]}
            s.page.keyboard.press("Escape")
            out["results"][f"{mode}@bindings_per_join"] = sorted(set(net.bindings))
            s.close()
            # five players open five characters at the same moment, warm and cold server cache
            for temp in ("warm", "cold"):
                out["results"][f"{mode}@burst5_{temp}"] = burst(b, pl, chars, flag, cold=(temp == "cold"))
                print(mode, "burst", temp, out["results"][f"{mode}@burst5_{temp}"], flush=True)
        b.close()
    return out


def burst(b, pl, chars, flag, cold):
    if True:
        if True:
            pages = []
            for k in "ABCEF":
                x = Sheet(b, pl, tab="combat"); x.page.goto(APP + f"?fluent={flag}"); x.page.wait_for_selector(".char-card", timeout=20000)
                no_offline_copy(x.page); pages.append((k, x, Net(x.page)))
            if cold: bump_rules_epoch()
            t0 = time.time()
            for k, x, _ in pages: x.page.evaluate(f"location.hash = '#/c/{chars[k]}'")
            done = []
            for k, x, nx in pages:
                try:
                    x.page.wait_for_function(USABLE, timeout=60000); done.append(time.time() - t0)
                except Exception:
                    done.append(None)
            time.sleep(2)
            fails = sum(1 for _, _, nx in pages for r in nx.rows if str(r["outcome"]).startswith("failed"))
            ends = [max((r["t1"] for r in nx.rows if r["t1"]), default=t0) - t0 for _, _, nx in pages]
            res = {"usable_median_ms": med(done), "usable_max_ms": round(max(d for d in done if d) * 1000) if any(done) else None,
                   "complete_max_ms": round(max(ends) * 1000), "not_usable": sum(1 for d in done if d is None), "failed_requests": fails,
                   "requests_total": sum(len(nx.rows) for _, _, nx in pages)}
            for _, x, _ in pages: x.close()
            return res


if __name__ == "__main__":
    with iso.Isolated("FLUENCY-BENCH") as t:
        res = run(t)
    print(json.dumps(res, indent=1))
    if OUT:
        with open(OUT, "w", encoding="utf-8") as f: json.dump(res, f, indent=1)
