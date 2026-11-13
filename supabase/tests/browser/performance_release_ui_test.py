"""Performance release 2026-11 (docs/PERFORMANCE_RELEASE_2026-11.md), browser suite. LOCAL ONLY, synthetic users inside isolation.

PR-01..06  a resource use / restore (own click or another session) re-reads only the resources and the states: no class
           features, class summary or Wild Shape read; every copy of the counter on the page shows the server value.
PR-07..09  Home cards read their derived stats through get_character_reads (the server read cache), never directly.
PR-10..12  the user-scoped catalog caches (spells, lineages, creatures, class spell lists) are dropped when another user signs in on the same page.
Usage: APP_URL=... python performance_release_ui_test.py   (run_browser_local.sh sets the environment)
"""
import json
import re

from playwright.sync_api import sync_playwright

import isolation as iso
from class_ui_common import APP, PW, RUN, Sheet, User, check, report
from incident_probe import USABLE

HEAVY = {"get_character_class_features", "get_character_class_summary", "get_character_transformation", "get_character_spell_slots",
         "get_character_infusions", "get_character_derived_stats", "get_character_proficiencies", "get_character_spellbook"}


class Reads:
    """Every REST / RPC request of a page with the read names of get_character_reads and its answers."""

    def __init__(self, page):
        self.rows, self.by_req = [], {}
        page.on("request", self._req)
        page.on("response", self._res)

    def _req(self, r):
        m = re.search(r"/rest/v1/(rpc/)?([a-z_0-9]+)", r.url)
        if not m:
            return
        names = []
        if m.group(2) == "get_character_reads":
            try:
                names = json.loads(r.post_data or "{}").get("p_reads") or []
            except Exception:
                names = ["?"]
        row = {"name": m.group(2), "rpc": bool(m.group(1)), "reads": names, "url": r.url, "answer": None}
        self.by_req[id(r)] = row
        self.rows.append(row)

    def _res(self, r):
        row = self.by_req.get(id(r.request))
        if row is None or row["name"] != "get_character_reads":
            return
        try:
            row["answer"] = r.json()
        except Exception as e:
            row["answer"] = {"unreadable": repr(e)}

    def mark(self):
        return len(self.rows)

    def since(self, i):
        return self.rows[i:]


def names_of(rows):
    out = set()
    for r in rows:
        out.add(r["name"])
        out.update(r["reads"])
    return out


def open_wait(s, cid):
    s.page.evaluate(f"location.hash = '#/c/{cid}'")
    s.page.wait_for_function(USABLE, timeout=30000)
    s.page.wait_for_timeout(2500)


def resource(u, cid, suffix):
    st, r = u.rpc("get_character_resources", p_character=cid)
    assert st == 200, (st, r)
    return next(x for x in r["resources"] if x["key"].endswith(suffix))


def run(t):
    pl = User("perf")
    other = User("perf-other")
    fighter = pl.character(f"Perf Fighter {RUN}", [("fighter-phb", 3)], strength=16, constitution=14)
    druid = pl.character(f"Perf Druid {RUN}", [("druid-phb", 2)], wisdom=16)
    extra = pl.character(f"Perf Extra {RUN}", [("wizard-phb", 1)], intelligence=16)
    t.note(characters=[fighter, druid, extra])
    sw = resource(pl, fighter, ":fighter-second-wind-phb-uses")["key"]
    with sync_playwright() as p:
        b = p.chromium.launch(channel="msedge", headless=True)
        s = Sheet(b, pl, tab="combat")
        page = s.page
        page.goto(APP + "?fluent=1")
        page.wait_for_selector(".char-card", timeout=20000)
        net = Reads(page)
        open_wait(s, fighter)
        quick = page.locator(f'[data-cf-quick="{sw}"]').first
        check("PR-00 the fighter's Second Wind is ready (1 / 1) on Play", s.wait(lambda: "1 / 1" in quick.inner_text()), quick.inner_text() if quick.count() else "")

        # --- own click
        i = net.mark()
        quick.locator("[data-cf-action=res-use]").click()
        ok = s.wait(lambda: "0 / 1" in page.locator(f'[data-cf-quick="{sw}"]').first.inner_text())
        page.wait_for_timeout(1500)
        seen = names_of(net.since(i))
        check("PR-01 Use: the counter shows 0 / 1", ok, page.locator(f'[data-cf-quick="{sw}"]').first.inner_text())
        check("PR-02 Use: the resources are re-read, the class page / features / Wild Shape / derived stats are not",
              "get_character_resources" in seen and not (seen & HEAVY), sorted(seen))
        chips = page.locator(f'[data-action-uses="{sw}"]').all_inner_texts()
        check("PR-03 the Play action card of the same feature shows the same counter (overlay of the class-features copy)",
              bool(chips) and all("0 / 1 left" in c for c in chips), chips)
        s.tab("features")
        row = page.locator(f'#class-features [data-cf-quick="{sw}"]').first      # rendered from the class-features copy
        full = page.locator(f'#class-resources [data-cf-res="{sw}"]').first        # rendered from the resource read
        check("PR-04 Build shows the same counter in the feature card and in the resource list; Restore is enabled",
              s.wait(lambda: row.count() == 1 and "0 / 1" in row.inner_text() and row.locator("[data-cf-action=res-restore]").is_enabled()
                     and "0 / 1" in (full.text_content() or "")),
              (row.inner_text() if row.count() else "", full.text_content() if full.count() else ""))
        s.tab("combat")

        # --- another session (API): only the revision event arrives
        i = net.mark()
        st, r = pl.rpc("restore_character_resource", p_character=fighter, p_resource_key=sw, p_amount=1)
        ok = st == 200 and s.wait(lambda: "1 / 1" in page.locator(f'[data-cf-quick="{sw}"]').first.inner_text(), 12000)
        page.wait_for_timeout(1500)
        seen = names_of(net.since(i))
        chips = page.locator(f'[data-action-uses="{sw}"]').all_inner_texts()
        check("PR-05 a restore in another session arrives: 1 / 1 on the quick row and on the action card", ok and all("1 / 1 left" in c for c in chips), (st, r, chips))
        check("PR-05 the remote change costs the resource read only", "get_character_resources" in seen and not (seen & HEAVY), sorted(seen))

        # --- Wild Shape panel reads its uses from the transformation read: the overlay keeps it right without that read
        open_wait(s, druid)
        ws = resource(pl, druid, "wild-shape-phb-uses")
        uses = page.locator("[data-ws-uses]").first
        before = uses.inner_text() if uses.count() else ""
        i = net.mark()
        st, r = pl.rpc("expend_character_resource", p_character=druid, p_resource_key=ws["key"], p_amount=1)
        want = f"{ws['remaining'] - 1} / {ws['max']}"
        ok = st == 200 and s.wait(lambda: want in page.locator("[data-ws-uses]").first.inner_text(), 12000)
        page.wait_for_timeout(1500)
        seen = names_of(net.since(i))
        check("PR-06 Wild Shape uses follow a resource change without a Wild Shape read",
              ok and "get_character_transformation" not in seen and "get_character_class_features" not in seen,
              (st, before, page.locator("[data-ws-uses]").first.inner_text() if uses.count() else "", sorted(seen)))

        # --- Home cards
        page.evaluate("() => Object.keys(localStorage).filter((k) => k.startsWith('tavern-ledger:cardstats:') || k.includes('cardstats:')).forEach((k) => localStorage.removeItem(k))")
        i = net.mark()
        page.evaluate("location.hash = '#/'")
        ok = s.wait(lambda: page.locator(".char-card").count() >= 3 and all(x.strip() not in ("", "…", "—") for x in page.locator(".char-card [data-cc-ac]").all_inner_texts()), 20000)
        page.wait_for_timeout(800)
        rows = net.since(i)
        direct = [r for r in rows if r["name"] == "get_character_derived_stats"]
        cards = [r for r in rows if r["name"] == "get_character_reads" and r["reads"] == ["get_character_derived_stats"]]
        check("PR-07 Home: every card shows its AC", ok, page.locator(".char-card [data-cc-ac]").all_inner_texts())
        check("PR-08 Home: derived stats come through get_character_reads (3 cards), never the direct RPC", len(cards) == 3 and not direct,
              [(r["name"], r["reads"]) for r in rows if r["rpc"]])
        page.evaluate("() => Object.keys(localStorage).filter((k) => k.includes('cardstats:')).forEach((k) => localStorage.removeItem(k))")
        i = net.mark()
        page.reload()
        page.wait_for_selector(".char-card", timeout=20000)
        s.wait(lambda: len([r for r in net.since(i) if r["name"] == "get_character_reads" and r["answer"] is not None]) >= 3, 20000)
        hits = [(r["answer"] or {}).get("cache", {}).get("hits") for r in net.since(i) if r["name"] == "get_character_reads"]
        check("PR-09 Home again: the server answers the cards from its read cache (hits = 1 each)", len(hits) == 3 and all(h == 1 for h in hits),
              [r["answer"] if not (r["answer"] or {}).get("reads") else {k: v for k, v in r["answer"].items() if k != "reads"} for r in net.since(i) if r["name"] == "get_character_reads"])

        # --- user switch on the same page
        load = """async () => { const [sp, li, cr, cl] = await Promise.all([import('./js/spell-api.js?v=26'), import('./js/lineage-api.js?v=26'), import('./js/creature-api.js?v=26'), import('./js/class-api.js?v=26')]);
          await Promise.all([sp.getSpellCatalog(), li.getLineageCatalog(), cr.getCreatures(), cl.getSpellListOptions('wizard-spell-list', 1)]); return true; }"""
        CATS = ["class_spell_list_entries", "creatures", "v_lineage_catalog", "v_spell_catalog"]
        cat = lambda rows: sorted({r["name"] for r in rows if r["name"] in CATS})
        i = net.mark(); page.evaluate(load)
        first = cat(net.since(i))
        i = net.mark(); page.evaluate(load)
        again = cat(net.since(i))
        check("PR-10 the catalogs are read once and then served from the session cache", first == CATS and not again, (first, again))
        page.evaluate("async () => { const m = await import('./js/supabase.js?v=26'); await m.supabase.auth.signOut(); }")
        page.wait_for_selector("input[name=email]", timeout=15000)
        page.fill("input[name=email]", other.email); page.fill("input[name=password]", PW); page.click("button[value=signin]")
        page.wait_for_selector(".char-card, .empty-state, a.brand", timeout=20000)
        page.wait_for_timeout(500)
        i = net.mark(); page.evaluate(load)
        switched = cat(net.since(i))
        check("PR-11 another user on the same page: all four catalogs (incl. the class spell list) are read again (nothing of the previous user is reused)",
              switched == CATS, switched)
        check("PR-12 the other user sees no character of the first one", page.locator(".char-card").count() == 0, page.locator(".char-card").count())

        check("PR-99 no console errors", not [e for e in s.errors if "Failed to load resource" not in e], s.errors[:5])
        s.close(); b.close()


if __name__ == "__main__":
    with iso.Isolated("PERF-RELEASE-UI") as t:
        run(t)
    report()
