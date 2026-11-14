"""Production smoke of the active features / feat / content management release
(docs/ACTIVE_FEATURES_AND_CONTENT_MANAGEMENT_RELEASE_REPORT.md).

SYNTHETIC accounts only (scripts/fluent/smoke_users.sql: smoke-fl-*@example.test, their own campaign and two characters). Never
opens or changes a real player's character. Removal: scripts/active/smoke_cleanup.sql (all synthetic rows incl. the smoke DM's
published content and its catalog rows).
Env:
  SMOKE_RUN, SMOKE_PW   the fixture's run tag and password (never printed)
  PROD_APP              the site (default the production URL)
  ASSET_V               the expected asset version (?v=N)
  EXPECT_MGMT           '1' = DM Space shows the content management actions (flag on); '0' = flag off
  LOCAL_API, LOCAL_KEY  local rehearsal only (127.0.0.1)
  OUT                   JSON summary path (timings, sizes; no player data)
"""
import json
import os
import re
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid

from playwright.sync_api import sync_playwright

APP = os.environ.get("PROD_APP", "https://alexandrajuscak.github.io/tavern_ledger/")
RUN, PW = os.environ["SMOKE_RUN"], os.environ["SMOKE_PW"]
ASSET_V = os.environ.get("ASSET_V", "")
EXPECT_MGMT = os.environ.get("EXPECT_MGMT", "1") == "1"
OUT = os.environ.get("OUT")
EMAIL = lambda kind: f"smoke-fl-{kind}-{RUN}@example.test"
HERO, SOLO = f"Smoke FL Hero {RUN}", f"Smoke FL Solo {RUN}"
results, timings = [], {}


def check(name, ok, detail=""):
    results.append(bool(ok))
    print(("PASSED  " if ok else "FAILED  ") + name + ("" if ok else f"   <-- {str(detail)[:300]}"), flush=True)


def site_config():
    if os.environ.get("LOCAL_API"):
        assert re.match(r"^http://127\.0\.0\.1:\d+$", os.environ["LOCAL_API"])
        return os.environ["LOCAL_API"], os.environ["LOCAL_KEY"], None
    with urllib.request.urlopen(APP + "js/config.js?nocache=" + uuid.uuid4().hex[:8], timeout=30) as r:
        src = r.read().decode()
    url = re.search(r"SUPABASE_URL = '([^']+)'", src).group(1)
    key = re.search(r"SUPABASE_PUBLISHABLE_KEY = '([^']+)'", src).group(1)
    assert key.startswith("sb_publishable_"), "not a publishable key"
    return url, key, src


SUPA, KEY, CONFIG_SRC = None, None, None


def http(method, path, body=None, jwt=None):
    path = urllib.parse.quote(path, safe="/?&=.,()_-:*")
    req = urllib.request.Request(SUPA + path, method=method, data=json.dumps(body).encode() if body is not None else None,
                                 headers={"apikey": KEY, "Authorization": f"Bearer {jwt or KEY}", "Content-Type": "application/json",
                                          "Prefer": "return=representation"})
    t0 = time.time()
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            raw, st = r.read(), r.status
    except urllib.error.HTTPError as e:
        raw, st = e.read(), e.code
    ms = round((time.time() - t0) * 1000)
    try:
        data = json.loads(raw) if raw else None
    except ValueError:
        data = raw.decode(errors="replace")
    return st, data, ms, len(raw or b"")


class Api:
    def __init__(self, kind):
        st, body, _, _ = http("POST", "/auth/v1/token?grant_type=password", {"email": EMAIL(kind), "password": PW})
        assert st == 200, ("sign-in failed", kind, st)
        self.jwt, self.id = body["access_token"], body["user"]["id"]

    def rpc(self, fn, label=None, **args):
        st, data, ms, size = http("POST", f"/rest/v1/rpc/{fn}", args, self.jwt)
        if label:
            timings.setdefault(label, []).append({"ms": ms, "bytes": size, "status": st})
        return st, data

    def get(self, path):
        return http("GET", "/rest/v1/" + path, None, self.jwt)[:2]


def denied(st, body):
    return st in (401, 403) or "42501" in json.dumps(body)


def wait(fn, timeout=15):
    end = time.time() + timeout
    while time.time() < end:
        try:
            if fn():
                return True
        except Exception:
            pass
        time.sleep(0.25)
    return False


class Page:
    def __init__(self, b, kind, tab="combat", width=1366):
        self.ctx = b.new_context(viewport={"width": width, "height": 900})
        self.ctx.add_init_script(f"localStorage.setItem('tavern-ledger:tab', '{tab}');")
        if os.environ.get("LOCAL_API"):
            self.ctx.add_init_script(f"localStorage.setItem('tavern-ledger:local-supabase', JSON.stringify({{url: '{SUPA}', key: '{KEY}'}}));")
        self.page = self.ctx.new_page()
        self.errors, self.reqs = [], []
        self.page.on("console", lambda m: self.errors.append(m.text) if m.type == "error" else None)
        self.page.on("pageerror", lambda e: self.errors.append(f"pageerror: {e}"))
        self.page.on("request", lambda r: self.reqs.append(r.url))
        p = self.page
        p.goto(APP)
        p.fill("input[name=email]", EMAIL(kind))
        p.fill("input[name=password]", PW)
        p.click("button[value=signin]")
        p.wait_for_selector(".char-card, .empty-state", timeout=30000)

    def go(self, hash_):
        self.page.goto(APP + hash_)
        self.page.wait_for_timeout(600)

    def open(self, cid):
        self.go(f"#/c/{cid}")
        wait(lambda: self.page.locator(".tab").count() > 0, 20)
        self.page.wait_for_timeout(800)

    def tab(self, key):
        self.page.locator(f'.tab[data-tab="{key}"]').click()
        self.page.wait_for_timeout(500)

    def toasts(self):
        return " ".join(self.page.locator(".toast").all_inner_texts())


def main():
    global SUPA, KEY, CONFIG_SRC
    SUPA, KEY, CONFIG_SRC = site_config()
    if CONFIG_SRC:
        code = "\n".join(l for l in CONFIG_SRC.splitlines() if not l.lstrip().startswith("//"))   # the file's warning comments name them
        check("S-00 site config: production project, publishable key only, no service-role key, no local URL",
              "service_role" not in code and "sb_secret_" not in code and "127.0.0.1" not in code and "localhost" not in code
              and SUPA.startswith("https://") and SUPA.endswith(".supabase.co"))
        mg = re.search(r"CONTENT_MANAGEMENT = '([^']+)'", CONFIG_SRC)
        check("S-01 content management flag as expected", (mg and mg.group(1) != "off") == EXPECT_MGMT, mg.group(1) if mg else None)
    dm, pl, st_ = Api("dm"), Api("player"), Api("stranger")
    s, rows = pl.get(f"characters?select=id,name,campaign_id&name=in.(\"{HERO}\",\"{SOLO}\")")
    ids = {r["name"]: r for r in rows}
    hero, solo = ids[HERO]["id"], ids[SOLO]["id"]
    camp = ids[HERO]["campaign_id"]

    # ---------------------------------------------------------------------------------------------------------------- fixture
    s1, r1 = pl.rpc("set_character_class", p_character=hero, p_class_version="fighter-phb", p_level=5, p_subclass_version=None)
    s2, r2 = pl.rpc("set_character_lineage", p_character=hero, p_version="dragonborn-chromatic", p_choices={"dragonborn-chromatic:ancestry": ["blue"]})
    s3, r3 = dm.rpc("assign_character_feat", p_character=hero, p_version="interception-2024", p_choices={}, p_source_type="dm_grant",
                    p_source_note=None, p_override_reason=None, p_notes=None)
    s4, r4 = pl.rpc("set_character_class", p_character=solo, p_class_version="fighter-phb", p_level=4, p_subclass_version=None)
    s5, r5 = pl.rpc("set_character_lineage", p_character=solo, p_version="human-phb", p_subversion="human-variant",
                    p_choices={"human-variant:feat": ["feat:magic-initiate-2024"]})
    s6, r6 = pl.rpc("assign_character_feat", p_character=solo, p_version="protection-2024", p_choices={}, p_source_type="direct",
                    p_source_note=None, p_override_reason=None, p_notes=None)
    check("S-02 fixture: synthetic fighter + Chromatic Dragonborn + DM-granted Interception; Variant Human with Magic Initiate; Protection",
          all(x == 200 for x in (s1, s2, s3, s4, s5, s6)), [s1, s2, s3, s4, s5, s6, str(r5)[:200], str(r6)[:200]])

    with sync_playwright() as p:
        br = p.chromium.launch(channel="msedge", headless=True)
        P = Page(br, "player")
        pg = P.page
        if ASSET_V:
            vs = pg.evaluate("() => [...new Set([...document.querySelectorAll('script[src],link[href]')].map((e) => (e.src || e.href).match(/[?&]v=(\\d+)/)?.[1]).filter(Boolean))]")
            check(f"S-03 one asset version (?v={ASSET_V})", vs == [ASSET_V], vs)
        # ---------------------------------------------------------------------------------------------------- PLAYER: Play
        P.open(hero)
        wait(lambda: pg.locator('[data-active-feature="lin:dragonborn-chromatic:breath-weapon"]').count() == 1, 20)
        bw = pg.locator('[data-active-feature="lin:dragonborn-chromatic:breath-weapon"]')
        check("P-01 Play: lineage action card (Breath Weapon) under Actions with uses and automation, no Use button on it",
              pg.locator('#combat-groups .group-action [data-active-feature="lin:dragonborn-chromatic:breath-weapon"]').count() == 1
              and "left" in bw.inner_text() and bw.locator("button").count() == 0, pg.locator("#combat-groups").inner_text()[:300])
        check("P-02 Play: feat Reaction card (Interception, source DM grant)", pg.locator('#combat-groups .group-reaction [data-active-feature^="feat:"]').count() == 1)
        check("P-03 Play: class features present (Second Wind, Action Surge) and Ready to use shows the lineage counter",
              "Second Wind" in pg.locator("#combat-groups").inner_text() and "Breath Weapon" in pg.locator("#combat-states").inner_text())
        check("P-04 Play: combat reminder (Draconic Resistance) is a one-line reminder", pg.locator('.passive-group [data-active-feature="lin:dragonborn-chromatic:draconic-resistance"]').count() == 1)
        # ------------------------------------------------------------------------------------- PLAYER: lineage feat choices
        P.open(solo)
        P.tab("features")
        wait(lambda: pg.locator('#feats-card [data-feat="choices"]').count() > 0, 20)
        check("F-01 Build: the lineage-granted Magic Initiate explains its source and shows the next step",
              "Next step" in pg.locator("#feats-card").inner_text() and pg.locator('#feats-card [data-feat-granted="lineage"]').count() >= 1)
        pg.locator('#feats-card [data-feat="choices"]').first.click()
        pg.wait_for_selector(".modal [data-choice-form]")
        form = pg.locator(".modal [data-choice-form]")
        check("F-02 the spell list has its options (repaired)", form.locator('[data-choice="list"] input[type=radio]').count() == 3)
        form.locator('[data-choice="list"] input[value="cleric-spell-list"]').check()
        wait(lambda: form.locator('[data-spell-choice="cantrips"] input').count() > 0)
        form.locator('[data-choice="ability"] input[value="wis"]').check()
        form.locator('[data-spell-choice="cantrips"] input[value="guidance-phb"]').check()
        form.locator('[data-spell-choice="cantrips"] input[value="light-phb"]').check()
        form.locator('[data-spell-choice="spell1"] input[value="bless-phb"]').check()
        t0 = time.time()
        pg.locator(".modal [data-save]").click()
        ok = wait(lambda: "spellbook" in P.toasts(), 15)
        timings["feat_choice_save_ui_ms"] = round((time.time() - t0) * 1000)
        check("F-03 choices saved and applied ('The spells are in your spellbook')", ok, P.toasts())
        P.tab("spells")
        check("F-04 Spells lists Guidance, Light and Bless", wait(lambda: all(x in pg.locator("main").inner_text() for x in ("Guidance", "Light", "Bless")), 15))
        # ------------------------------------------------------------------------------------------ PLAYER: remove a feat
        P.tab("combat")
        wait(lambda: pg.locator('#combat-groups .group-reaction [data-active-feature^="feat:"]').count() == 1, 15)
        had_card = pg.locator('#combat-groups .group-reaction [data-active-feature^="feat:"]').count() == 1
        P.tab("features")
        wait(lambda: pg.locator('#feats-card [data-feat="remove"]').count() > 0, 15)
        pg.locator('#feats-card [data-feat="remove"]').first.click()
        pg.wait_for_selector(".modal", timeout=15000)
        wait(lambda: "Protection" in pg.locator(".modal").inner_text(), 10)
        check("R-01 removal review: server consequence preview names the feat", "Protection" in pg.locator(".modal").inner_text(), pg.locator(".modal").inner_text()[:200])
        pg.locator(".modal .btn-bad, .modal [data-ok]").last.click()
        ok = wait(lambda: pg.locator("#feats-card").inner_text().count("Protection") == 0, 15)
        P.tab("combat")
        check("R-02 the directly assigned feat is removed and its Reaction card leaves Play (no reload)",
              had_card and ok and wait(lambda: pg.locator('#combat-groups .group-reaction [data-active-feature^="feat:"]').count() == 0, 10))

        # --------------------------------------------------------------------------------------------- REALTIME (2nd session)
        P.open(hero)
        P.tab("combat")
        pg.evaluate("() => { window.__smokeNoReload = 1; }")
        cf = pl.get(f"character_feats?select=id&character_id=eq.{hero}&feat_version_id=eq.interception-2024")[1]
        sd, rd = dm.rpc("remove_character_feat", p_character_feat=cf[0]["id"], p_reason="smoke")
        gone = wait(lambda: pg.locator('#combat-groups .group-reaction [data-active-feature^="feat:"]').count() == 0, 15)
        sa, ra = dm.rpc("assign_character_feat", p_character=hero, p_version="interception-2024", p_choices={}, p_source_type="dm_grant",
                        p_source_note=None, p_override_reason=None, p_notes=None)
        back = wait(lambda: pg.locator('#combat-groups .group-reaction [data-active-feature^="feat:"]').count() == 1, 15)
        check("T-01 Realtime: DM removal and grant reach the player's open Play tab without a reload",
              sd == 200 and sa == 200 and gone and back and pg.evaluate("() => window.__smokeNoReload") == 1)

        # --------------------------------------------------------------------------------------------- DM: content management
        D = Page(br, "dm")
        dp = D.page
        s, c1 = dm.rpc("duplicate_official_as_homebrew", "dup", p_type="spell", p_ref="fire-bolt-phb", p_campaign=camp)
        check("M-01 DM duplicates an official spell as a campaign draft", s == 200 and c1.get("status") == "draft", str(c1)[:200])
        s, sv = dm.rpc("save_dm_content", p_content=c1["id"], p_fields={"name": f"Smoke Ember {RUN}", "player_text": "A synthetic smoke spell."},
                       p_expected_revision=None)
        s2, val = dm.rpc("validate_dm_content", p_content=c1["id"])
        s3, pub = dm.rpc("publish_dm_content", "publish", p_content=c1["id"], p_expected_version=None)
        check("M-02 edit draft, validate, publish", s == 200 and s2 == 200 and (val.get("validation") or {}).get("ok") and s3 == 200, [s, s2, s3, str(val)[:150]])
        s, u = dm.rpc("get_dm_content_usage", "usage", p_content=c1["id"])
        check("M-03 usage of the unused published spell: safe_to_delete", s == 200 and u["classification"] == "safe_to_delete" and u["can_delete"], u)
        s, a1 = dm.rpc("archive_dm_content", p_content=c1["id"], p_reason="smoke")
        s2, r1 = dm.rpc("restore_dm_content", p_content=c1["id"])
        check("M-04 archive and restore", s == 200 and s2 == 200)
        s, c2 = dm.rpc("duplicate_official_as_homebrew", p_type="feat", p_ref="alert-2024", p_campaign=camp)
        dm.rpc("publish_dm_content", p_content=c2["id"], p_expected_version=None)
        s, asg = dm.rpc("dm_assign_content", p_content=c2["id"], p_characters=[hero], p_mode="dm_grant", p_options={})
        s2, u2 = dm.rpc("get_dm_content_usage", p_content=c2["id"])
        s3, dl = dm.rpc("delete_unused_dm_content", p_content=c2["id"], p_confirm_name=c2["name"])
        check("M-05 used content: delete_blocked, new version required, the delete is refused (friendly, nothing deleted)",
              u2["classification"] == "delete_blocked" and u2["edit"] == "new_version_required" and s3 >= 400 and "TLUSE" in json.dumps(dl)
              and "constraint" not in json.dumps(dl).lower(), [u2.get("classification"), s3, str(dl)[:200]])
        # UI: Content Library, usage dialog, delete the unused spell through the UI
        D.go("#/dm/overview")
        wait(lambda: dp.locator('[data-dm-section="content"]').count() > 0, 20)
        dp.locator('[data-dm-section="content"]').click()
        has_dup = wait(lambda: dp.locator('[data-dm="dup-official"]').count() > 0, 15)
        check("M-06 DM Space shows Duplicate official / Usage only as configured", has_dup == EXPECT_MGMT)
        if EXPECT_MGMT:
            dp.locator(f'[data-dm="usage-content"][data-id="{c1["id"]}"]').click()
            wait(lambda: dp.locator(".modal [data-usage-class]").count() > 0)
            dp.locator('.modal [data-u="delete"]').click()
            dp.wait_for_selector(".modal [data-n]")
            dp.fill(".modal [data-n]", f"Smoke Ember {RUN}")
            dp.locator(".modal [data-ok]").click()
            s, left = dm.get(f"dm_content?select=id&id=eq.{c1['id']}")
            check("M-07 Delete permanently (typed name) removes the unused spell", wait(lambda: dm.get(f"dm_content?select=id&id=eq.{c1['id']}")[1] == [], 15))
            dp.locator(f'[data-dm="usage-content"][data-id="{c2["id"]}"]').click()
            wait(lambda: dp.locator(".modal [data-usage-class]").count() > 0)
            check("M-08 usage dialog of used content: Delete blocked, no Delete button", dp.locator(".modal [data-usage-class]").get_attribute("data-usage-class") == "delete_blocked"
                  and dp.locator('.modal [data-u="delete"]').count() == 0)
            dp.keyboard.press("Escape")
        # Combat Builder: linked character's active features
        s, enc = dm.rpc("combat_create_encounter", p_campaign=camp, p_name=f"Smoke fight {RUN}", p_ruleset="campaign", p_description="",
                        p_settings={}, p_request=str(uuid.uuid4()))
        eid = (enc.get("encounter") or {}).get("id")
        dm.rpc("combat_add_characters", p_encounter=eid, p_characters=[hero], p_options={}, p_request=str(uuid.uuid4()))
        s, encd = dm.rpc("combat_get_encounter", p_encounter=eid)
        pid = next((x["id"] for x in (encd.get("participants") or []) if x.get("character_id") == hero), None)
        dm.rpc("combat_set_initiative", p_encounter=eid, p_values=[{"id": pid, "initiative": 12}], p_request=str(uuid.uuid4()))
        dm.rpc("combat_start", p_encounter=eid, p_accept_ties=True, p_request=str(uuid.uuid4()))
        D.go(f"#/combat/e/{eid}")
        wait(lambda: dp.locator(f".cb-row[data-pid='{pid}']").count() > 0, 20)
        dp.locator(f".cb-row[data-pid='{pid}'] .cb-row-main").click()
        wait(lambda: dp.locator('[data-cb="load-features"]').count() > 0, 10)
        reads_resp = []
        dp.on("response", lambda r: reads_resp.append(r) if "rpc/get_character_reads" in r.url and r.request.method == "POST" else None)
        t0 = time.time()
        dp.locator('[data-cb="load-features"]').first.click()
        try:   # polls without the 30 s auto-wait of inner_text on a panel that never renders (an error toast instead)
            dp.wait_for_function("() => (document.querySelector('.cb-active-features')?.innerText || '').includes('Breath Weapon')", timeout=15000)
            ok = True
        except Exception:
            ok = False
        timings["combat_features_ms"] = round((time.time() - t0) * 1000)
        try:   # server time, cache use and per-read errors of the feature read (no character data)
            b = reads_resp[-1].json()
            timings["combat_features_server"] = {"status": reads_resp[-1].status, "server_ms": b.get("server_ms"), "cache": b.get("cache"),
                                                 "errors": {k: (v or {}).get("code") for k, v in (b.get("errors") or {}).items()}}
        except Exception as e:
            timings["combat_features_server"] = {"status": reads_resp[-1].status if reads_resp else None, "note": str(e)[:120]}
        if not ok:
            timings["combat_features_toasts"] = D.toasts()[:200]
        check("C-01 Combat Builder: the linked character's active features on request (Breath Weapon, Interception)",
              ok and "Interception" in dp.locator(".cb-active-features").first.inner_text())

        # ------------------------------------------------------------------------------------------------------- SECURITY
        s1, b1 = pl.rpc("get_dm_content_usage", p_content=c2["id"])
        s2, b2 = pl.rpc("delete_unused_dm_content", p_content=c2["id"], p_confirm_name=c2["name"])
        s3, b3 = pl.rpc("duplicate_official_as_homebrew", p_type="spell", p_ref="fire-bolt-phb", p_campaign=camp)
        check("X-01 the player cannot read usage, delete or duplicate (denied)", denied(s1, b1) and denied(s2, b2) and denied(s3, b3), [s1, s2, s3])
        s1, b1 = st_.rpc("get_dm_content_usage", p_content=c2["id"])
        s2, b2 = st_.rpc("duplicate_official_as_homebrew", p_type="spell", p_ref="fire-bolt-phb", p_campaign=camp)
        check("X-02 an unrelated user is denied without the campaign name", denied(s1, b1) and denied(s2, b2) and f"Smoke FL {RUN}" not in json.dumps([b1, b2]))
        s1, b1, _, _ = http("POST", "/rest/v1/rpc/get_dm_content_usage", {"p_content": c2["id"]})
        s2, b2, _, _ = http("POST", "/rest/v1/rpc/delete_unused_dm_content", {"p_content": c2["id"], "p_confirm_name": "x"})
        check("X-03 anonymous is denied", denied(s1, b1) and denied(s2, b2), [s1, s2])
        s, cpt, _, _ = http("GET", "/rest/v1/catalog_play_timing?select=source_id&limit=1")
        check("X-04 the timing catalog is public catalog metadata (readable, no player data)", s == 200 and isinstance(cpt, list))
        s, hid = pl.rpc("get_character_feats", p_character=hero)
        check("X-05 hidden DM data absent from the player's feat read", "Smoke secret" not in json.dumps(hid) and "dm_notes" not in json.dumps(hid))

        errs = [e for e in P.errors + D.errors if "Failed to load resource" not in e]
        check("Z-01 no console errors", not errs, errs[:4])
        P.ctx.close(); D.ctx.close(); br.close()
    print(f"{sum(results)} passed, {len(results) - sum(results)} failed")
    if OUT:
        json.dump({"timings": timings, "passed": sum(results), "failed": len(results) - sum(results)}, open(OUT, "w"), indent=1)
    raise SystemExit(0 if all(results) else 1)


if __name__ == "__main__":
    main()
