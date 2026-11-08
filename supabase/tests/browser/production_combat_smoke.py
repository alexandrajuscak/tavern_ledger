"""Production smoke of the Combat Builder release (docs/COMBAT_BUILDER_PRODUCTION_RELEASE_REPORT.md).

SYNTHETIC accounts only (scripts/fluent/smoke_users.sql: smoke-fl-*@example.test, their own campaign and two characters, plus a
synthetic Moon Druid created here). Never opens or changes a real player's character. Removal: scripts/combat/smoke_cleanup.sql.
Env:
  SMOKE_RUN, SMOKE_PW   the fixture's run tag and password (never printed)
  PROD_APP              the site (default the production URL); a local copy of a commit for the shadow smoke
  APP_QS                query string, e.g. '?env=staging' (the shadow smoke: a local origin reads the git-ignored config.staging.js)
  EXPECT_LINK           '1' = the DM must see the Combat link (flag 'dm'); '0' = the flag is off (link hidden for everyone)
  ASSET_V               the expected asset version (?v=N)
  OUT                   JSON summary path (timings, sizes, counts; no player data)
The Supabase URL and publishable key are read from js/config.js of the served site (browser-safe values).
The DM flow runs through the DM's own session (PostgREST + the DM's JWT, the same RLS and RPCs as the UI); the UI part checks
navigation, the live tracker, the player's sheet following a linked HP change through Realtime, and the player's denial.
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
QS = os.environ.get("APP_QS", "")
RUN, PW = os.environ["SMOKE_RUN"], os.environ["SMOKE_PW"]
EXPECT_LINK = os.environ.get("EXPECT_LINK", "1") == "1"
ASSET_V = os.environ.get("ASSET_V", "")
OUT = os.environ.get("OUT")
EMAIL = lambda kind: f"smoke-fl-{kind}-{RUN}@example.test"
HERO, SOLO, DRUID = f"Smoke FL Hero {RUN}", f"Smoke FL Solo {RUN}", f"Smoke FL Druid {RUN}"
SECRETS = ("Ogre", "Large shape", "Smoke ambush note", "Smoke secret curse")
results, summary, timings = [], {}, {}


def check(name, ok, detail=""):
    results.append(bool(ok))
    print(("PASSED  " if ok else "FAILED  ") + name + ("" if ok else f"   <-- {str(detail)[:300]}"), flush=True)


def site_config():
    if os.environ.get("LOCAL_API"):   # rehearsal against the LOCAL stack only (a local origin reads js/config.local.js)
        assert re.match(r"^http://127\.0\.0\.1:\d+$", os.environ["LOCAL_API"])
        return os.environ["LOCAL_API"], os.environ["LOCAL_KEY"], os.environ.get("LOCAL_FLAG", "dm")
    with urllib.request.urlopen(APP + "js/config.js?nocache=" + uuid.uuid4().hex[:8], timeout=30) as r:
        src = r.read().decode()
    url = re.search(r"SUPABASE_URL = '([^']+)'", src).group(1)
    key = re.search(r"SUPABASE_PUBLISHABLE_KEY = '([^']+)'", src).group(1)
    flag = re.search(r"COMBAT_BUILDER = '([^']+)'", src).group(1)
    assert key.startswith("sb_publishable_"), "not a publishable key"
    if "env=staging" in QS:           # shadow smoke: the local copy's git-ignored config.staging.js must point at the same project
        with urllib.request.urlopen(APP + "js/config.staging.js?nocache=" + uuid.uuid4().hex[:8], timeout=30) as r:
            stg = r.read().decode()
        assert re.search(r"STAGING_SUPABASE_URL = '([^']+)'", stg).group(1) == url, "config.staging.js is not the production project"
    return url, key, flag


SUPA, KEY, SITE_FLAG = None, None, None


def http(method, path, body=None, jwt=None):
    path = urllib.parse.quote(path, safe="/?&=.,()_-:*")
    req = urllib.request.Request(SUPA + path, method=method, data=json.dumps(body).encode() if body is not None else None,
                                 headers={"apikey": KEY, "Authorization": f"Bearer {jwt or KEY}", "Content-Type": "application/json",
                                          "Prefer": "return=representation"})
    t0 = time.time()
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            raw = r.read()
            st = r.status
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

    def post(self, path, body):
        return http("POST", "/rest/v1/" + path, body, self.jwt)[:2]

    def patch(self, path, body):
        return http("PATCH", "/rest/v1/" + path, body, self.jwt)[:2]


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
        time.sleep(0.2)
    return False


class Page:
    def __init__(self, b, kind):
        self.ctx = b.new_context(viewport={"width": 1366, "height": 900})
        self.ctx.add_init_script("localStorage.setItem('tavern-ledger:tab', 'combat');")
        self.page = self.ctx.new_page()
        self.errors, self.reqs = [], []
        self.page.on("console", lambda m: self.errors.append(m.text) if m.type == "error" else None)
        self.page.on("pageerror", lambda e: self.errors.append(f"pageerror: {e}"))
        self.page.on("request", lambda r: self.reqs.append(re.sub(r".*/rest/v1/(rpc/)?", "", r.url.split("?")[0])) if "/rest/v1/" in r.url else None)
        p = self.page
        p.goto(APP + QS)
        p.fill("input[name=email]", EMAIL(kind))
        p.fill("input[name=password]", PW)
        p.click("button[value=signin]")
        p.wait_for_selector(".char-card, .empty-state", timeout=30000)

    def go(self, hash_):
        self.page.goto(APP + QS + hash_)

    def close(self):
        self.ctx.close()


def run():
    global SUPA, KEY, SITE_FLAG
    SUPA, KEY, SITE_FLAG = site_config()
    summary["site_flag"] = SITE_FLAG
    dm, pl, st_ = Api("dm"), Api("player"), Api("stranger")
    st, chars = pl.get(f"characters?select=id,name,campaign_id,hp_current,hp_max&name=in.(\"{HERO}\",\"{SOLO}\")")
    by = {c["name"]: c for c in chars}
    hero, solo, camp = by[HERO]["id"], by[SOLO]["id"], by[HERO]["campaign_id"]
    check("CS-00 fixture: Hero in the smoke campaign, Solo outside", camp and by[SOLO]["campaign_id"] is None and by[HERO]["hp_current"] == 12)

    # ---- synthetic Moon Druid in Brown Bear form (normal HP 30), joined to the smoke campaign
    st, rows = pl.post("characters", {"owner_id": pl.id, "name": DRUID, "level": 1, "hp_max": 30, "hp_current": 30, "strength": 10,
                                      "dexterity": 14, "constitution": 14, "intelligence": 10, "wisdom": 16, "charisma": 10})
    druid = rows[0]["id"]
    st1, r1 = pl.rpc("set_character_class", p_character=druid, p_class_version="druid-phb", p_level=6, p_subclass_version="druid-moon-phb")
    st2, r2 = pl.rpc("start_transformation", p_character=druid, p_creature="brown-bear", p_options={})
    st3, _ = pl.patch(f"characters?id=eq.{druid}", {"campaign_id": camp})
    st4, form = pl.rpc("get_character_transformation", p_character=druid)
    fhp = (form or {}).get("form", {}).get("hp_current") if isinstance(form, dict) else None
    if fhp is None:
        st5, tr = pl.get(f"character_transformations?character_id=eq.{druid}&select=hp_current")
        fhp = tr[0]["hp_current"] if tr else None
    check("CS-01 synthetic Moon Druid 6 in Brown Bear form, in the smoke campaign", st1 == 200 and st2 == 200 and st3 in (200, 204) and fhp,
          (st1, st2, st3, str(r2)[:200], fhp))
    summary["form_hp"] = fhp

    # ---- DM builds the encounter (RPCs of the DM's session)
    st, r = dm.rpc("combat_list_encounters", "combat_home", p_campaign=camp, p_include_archived=False)
    check("CS-02 Combat Home list (empty campaign)", st == 200, (st, str(r)[:200]))
    st, r = dm.rpc("combat_create_encounter", "create", p_campaign=camp, p_name=f"Smoke fight {RUN}", p_ruleset="2024",
                   p_description=None, p_settings={}, p_request=str(uuid.uuid4()))
    enc = (r or {}).get("encounter", {}).get("id") if isinstance(r, dict) else None
    check("CS-03 DM creates a draft encounter", st == 200 and enc and r["encounter"]["status"] == "draft", (st, str(r)[:200]))
    st, r = dm.rpc("combat_add_characters", "add_party", p_encounter=enc, p_characters=[hero, druid], p_options={})
    check("CS-04 Add party: the Hero and the Druid", st == 200, (st, str(r)[:200]))
    st, lib = dm.rpc("combat_monster_library", "monster_search", p_campaign=camp, p_query="wolf", p_filters={}, p_limit=24, p_offset=0)
    names = json.dumps(lib)
    check("CS-05 monster search finds the SRD Wolf", st == 200 and "srd52-wolf" in names, (st, names[:200]))
    st, lib_all = dm.rpc("combat_monster_library", "monster_library_page", p_campaign=camp, p_query=None, p_filters={}, p_limit=24, p_offset=0)
    st, r = dm.rpc("combat_add_monsters", "add_monster", p_encounter=enc, p_source_kind="srd2024", p_source_id="srd52-ogre",
                   p_options={"hidden": True, "player_label": "Large shape"}, p_request=str(uuid.uuid4()))
    ogre = r["added"][0]
    st, r = dm.rpc("combat_add_monsters", "add_monster", p_encounter=enc, p_source_kind="srd2024", p_source_id="srd52-wolf",
                   p_options={"quantity": 2}, p_request=str(uuid.uuid4()))
    wolves = r["added"]
    check("CS-06 SRD monsters added: a hidden Ogre and a group of two Wolves", st == 200 and len(wolves) == 2, (st, str(r)[:200]))
    st, e = dm.rpc("combat_get_encounter", "encounter_open", p_encounter=enc)
    parts = {p["id"]: p for p in e["participants"]}
    pc = {p["character_id"]: p["id"] for p in e["participants"] if p["kind"] == "character"}
    check("CS-07 the wolves share one Initiative group", len({parts[w].get("group_key") for w in wolves}) == 1 and parts[wolves[0]].get("group_key"))

    # ---- Initiative: player final totals, a manual monster total, an automatic group roll, tie review
    st, r = dm.rpc("combat_set_initiative", "set_initiative", p_encounter=enc, p_values=[{"id": pc[hero], "initiative": 17}, {"id": pc[druid], "initiative": 9},
                   {"id": ogre, "initiative": 17}], p_request=str(uuid.uuid4()))
    st2, r2 = dm.rpc("combat_roll_initiative", "roll_initiative", p_encounter=enc, p_participants=[wolves[0]], p_options={}, p_request=str(uuid.uuid4()))
    st, e = dm.rpc("combat_get_encounter", p_encounter=enc)
    parts = {p["id"]: p for p in e["participants"]}
    check("CS-08 player final totals are stored exactly (17 stays 17, 9 stays 9)", parts[pc[hero]]["initiative"] == 17 and parts[pc[druid]]["initiative"] == 9,
          (parts[pc[hero]]["initiative"], parts[pc[druid]]["initiative"]))
    check("CS-09 manual monster total stored (Ogre 17)", parts[ogre]["initiative"] == 17)
    check("CS-10 automatic roll of one wolf rolls the whole group to one total",
          st2 == 200 and parts[wolves[0]]["initiative"] is not None and parts[wolves[0]]["initiative"] == parts[wolves[1]]["initiative"],
          (st2, str(r2)[:200], [parts[w]["initiative"] for w in wolves]))
    st, r = dm.rpc("combat_start", "start", p_encounter=enc, p_accept_ties=False, p_request=str(uuid.uuid4()))
    check("CS-11 Start asks for a tie review (Hero 17 = Ogre 17)", st == 200 and r.get("needs_tie_review") is True, (st, str(r)[:200]))
    st, r = dm.rpc("combat_start", "start", p_encounter=enc, p_accept_ties=True, p_request=str(uuid.uuid4()))
    st, e = dm.rpc("combat_get_encounter", p_encounter=enc)
    check("CS-12 combat starts after the tie review (round 1)", e["encounter"]["status"] == "active" and e["encounter"].get("round") == 1, str(e["encounter"])[:200])

    # ---- UI: the DM's live tracker, the player's sheet, the player's denial
    with sync_playwright() as p:
        b = p.chromium.launch(channel="msedge", headless=True)
        D = Page(b, "dm")
        dp = D.page
        v = dp.evaluate("() => [...new Set([...document.querySelectorAll('script[src],link[href]')].map((e) => (e.src || e.href).match(/[?]v=(\\d+)/)?.[1]).filter(Boolean))]")
        if ASSET_V:
            check(f"CS-13 one asset version (?v={ASSET_V})", v == [ASSET_V], v)
        link = dp.locator("#combat-link")
        check("CS-14 the DM's Combat link " + ("is shown (flag 'dm')" if EXPECT_LINK else "is hidden (flag 'off')"),
              wait(lambda: link.is_visible(), 8) if EXPECT_LINK else not link.is_visible())
        if EXPECT_LINK:
            t0 = time.time()
            D.go("#/combat")
            ok = wait(lambda: dp.locator(".cb-card", has_text=f"Smoke fight {RUN}").count() >= 1, 20)
            summary["ui_combat_home_ms"] = round((time.time() - t0) * 1000)
            check("CS-15 Combat Home lists the running encounter", ok)
            t0 = time.time()
            D.go(f"#/combat/e/{enc}")
            ok = wait(lambda: dp.locator(".cb-live").count() == 1 and dp.locator(".cb-row").count() >= 5, 20)
            summary["ui_encounter_open_ms"] = round((time.time() - t0) * 1000)
            check("CS-16 the live tracker opens with all five combatants", ok, dp.locator(".cb-row").count())
            cur0 = dp.locator("[data-cb-current]").first.inner_text() if dp.locator("[data-cb-current]").count() else ""
            t0 = time.time()
            dp.locator("[data-cb=next]").first.click()
            ok = wait(lambda: (dp.locator("[data-cb-current]").first.inner_text() if dp.locator("[data-cb-current]").count() else "") != cur0, 10)
            summary["ui_next_turn_ms"] = round((time.time() - t0) * 1000)
            check("CS-17 Next turn in the UI moves the current combatant", ok)
        else:
            D.go(f"#/combat/e/{enc}")
            dp.wait_for_timeout(2500)
            check("CS-15 with the flag off a direct #/combat link goes home", "#/combat" not in dp.url and dp.locator(".cb-live").count() == 0, dp.url)

        P = Page(b, "player")
        pp = P.page
        check("CS-18 the player sees no Combat link", not pp.locator("#combat-link").is_visible())
        P.go("#/combat")
        pp.wait_for_timeout(2000)
        check("CS-19 the player's direct #/combat goes back home", "#/combat" not in pp.url and pp.locator(".cb-live").count() == 0, pp.url)
        P.go(f"#/c/{hero}")
        pp.wait_for_selector("#hp-card .hp-current", timeout=30000)
        wait(lambda: pp.locator("#hp-card .hp-current").input_value().strip() == "12", 15)
        mark = len(P.reqs)

        # linked HP: the DM damages the Hero in the encounter -> the player's open sheet follows (Realtime), once
        t0 = time.time()
        st, r = dm.rpc("combat_apply_hp", "hp_damage", p_participant=pc[hero], p_op="damage", p_amount=2, p_reason="smoke", p_request=str(uuid.uuid4()))
        ok = wait(lambda: pp.locator("#hp-card .hp-current").input_value().strip() == "10", 15)
        summary["realtime_linked_hp_ms"] = round((time.time() - t0) * 1000)
        st_c, row = pl.get(f"characters?id=eq.{hero}&select=hp_current")
        check("CS-20 linked HP: 2 damage in the Combat Builder -> the character is 10 (applied once)", st == 200 and row[0]["hp_current"] == 10, (st, str(r)[:200], row))
        check("CS-21 the player's open sheet shows 10 through Realtime", ok, pp.locator("#hp-card .hp-current").input_value())
        heavy = [x for x in P.reqs[mark:] if x in ("get_character_shell", "get_character_view")]
        check("CS-22 no full sheet reload for the HP change", not heavy, P.reqs[mark:][:12])
        summary["sheet_requests_after_hp"] = P.reqs[mark:][:20]
        st, r = dm.rpc("combat_apply_hp", "hp_heal", p_participant=pc[hero], p_op="heal", p_amount=2, p_reason="smoke restore", p_request=str(uuid.uuid4()))
        ok = wait(lambda: pp.locator("#hp-card .hp-current").input_value().strip() == "12", 15)
        st_c, row = pl.get(f"characters?id=eq.{hero}&select=hp_current")
        check("CS-23 heal 2 restores the exact HP (12) on the character and the sheet", row[0]["hp_current"] == 12 and ok, row)
        # the sheet's own Damage button still goes through the atomic RPC and the Combat Builder sees it
        st, r = pl.rpc("apply_character_hp", "sheet_hp", p_character=hero, p_op="damage", p_amount=1)
        st2, part = dm.rpc("combat_get_participant", p_participant=pc[hero])
        st3, r3 = pl.rpc("apply_character_hp", p_character=hero, p_op="heal", p_amount=1)
        check("CS-24 sheet HP change (1 damage, then healed) applies once through apply_character_hp", st == 200 and r["after"]["hp"] == 11 and st3 == 200 and r3["after"]["hp"] == 12,
              (st, str(r)[:150], st3, str(r3)[:150]))
        check("CS-25 player sheet without console errors", not P.errors, P.errors[:3])

        # Wild Shape overflow: damage form HP + 1 -> the form ends and exactly 1 reaches normal HP (30 -> 29)
        st, r = dm.rpc("combat_apply_hp", "hp_wild_shape", p_participant=pc[druid], p_op="damage", p_amount=fhp + 1, p_reason="smoke overflow", p_request=str(uuid.uuid4()))
        st_c, row = pl.get(f"characters?id=eq.{druid}&select=hp_current")
        st_t, tr = pl.get(f"character_transformations?character_id=eq.{druid}&select=character_id")
        check(f"CS-26 Wild Shape: {fhp + 1} damage ends the {fhp} HP form and only 1 reaches normal HP (30 -> 29)",
              st == 200 and row[0]["hp_current"] == 29 and tr == [], (st, str(r)[:250], row, tr))

        # effects, concentration-free condition, pause / resume
        st, r = dm.rpc("combat_add_effect", "effect_add", p_encounter=enc, p_effect={"effect_type": "condition", "condition_key": "prone", "target": pc[hero]}, p_request=str(uuid.uuid4()))
        eff = (((r or {}).get("effects") or [{}])[0].get("id")) if isinstance(r, dict) else None
        st2, r2 = dm.rpc("combat_add_effect", p_encounter=enc, p_effect={"effect_type": "custom", "name": "Smoke secret curse", "target": pc[hero], "visibility": "dm"}, p_request=str(uuid.uuid4()))
        dm.rpc("combat_update_encounter", p_encounter=enc, p_patch={"dm_notes": "Smoke ambush note"}, p_expected_rev=None)
        check("CS-27 a condition and a DM-only effect are added", st == 200 and st2 == 200 and eff, (st, str(r)[:200], st2))

        # player-safe view: running encounter, no hidden monster, no DM notes, no DM-only effect, monster HP as a word
        st, view = pl.rpc("get_combat_player_view", "player_view", p_encounter=enc)
        txt = json.dumps(view)
        check("CS-28 player-safe view: active, Prone visible", st == 200 and view["encounter"]["status"] == "active" and "Prone" in txt, (st, txt[:200]))
        check("CS-29 player-safe view hides the Ogre, its disguise, DM notes and the DM-only effect", not any(s in txt for s in SECRETS) and "dm_notes" not in txt,
              [s for s in SECRETS if s in txt])
        mon = [x for x in view["participants"] if x["kind"] == "monster"]
        check("CS-30 visible monsters show HP only as a state word", mon and all("current" not in (m.get("hp") or {}) for m in mon), mon[:1])
        st, r = pl.rpc("combat_get_encounter", p_encounter=enc)
        check("CS-31 player denied the DM read model", denied(st, r), (st, str(r)[:150]))
        st, r = pl.rpc("combat_apply_hp", p_participant=wolves[0], p_op="damage", p_amount=3, p_reason=None, p_request=str(uuid.uuid4()))
        check("CS-32 player cannot change monster HP", denied(st, r), (st, str(r)[:150]))
        for fn, args in (("combat_get_encounter", {"p_encounter": enc}), ("get_combat_player_view", {"p_encounter": enc}),
                         ("combat_list_encounters", {"p_campaign": camp, "p_include_archived": False}), ("apply_character_hp", {"p_character": hero, "p_op": "damage", "p_amount": 1})):
            st, r = st_.rpc(fn, **args)
            check(f"CS-33 unrelated user denied: {fn}", denied(st, r), (st, str(r)[:150]))
            st, r, _, _ = http("POST", f"/rest/v1/rpc/{fn}", args)
            check(f"CS-34 anonymous denied: {fn}", st in (401, 403, 404) or "42501" in json.dumps(r), (st, str(r)[:150]))
        st, rows, _, _ = http("GET", "/rest/v1/combat_encounters?select=id")
        check("CS-35 anonymous reads no encounter rows", st in (401, 403) or rows == [], (st, str(rows)[:100]))
        for tbl in ("combat_encounters", "combat_participants", "combat_effects", "combat_events", "combat_changes"):
            st, rows = pl.get(f"{tbl}?select=*")
            check(f"CS-36 player table read returns no {tbl} rows (RLS)", st == 200 and rows == [], (st, str(rows)[:100]))

        st, r = dm.rpc("combat_end_effect", "effect_end", p_effect=eff, p_reason="removed", p_request=str(uuid.uuid4()))
        check("CS-37 the condition is removed", st == 200, (st, str(r)[:150]))
        st, e = dm.rpc("combat_get_encounter", p_encounter=enc)
        st, r = dm.rpc("combat_next_turn", "next_turn", p_encounter=enc, p_expected_turn_rev=e["encounter"]["turn_rev"], p_mode="next", p_request=str(uuid.uuid4()))
        check("CS-38 Next turn through the API", st == 200, (st, str(r)[:150]))
        st, r = dm.rpc("combat_pause", "pause", p_encounter=enc, p_request=str(uuid.uuid4()))
        st2, r2 = dm.rpc("combat_resume", "resume", p_encounter=enc, p_request=str(uuid.uuid4()))
        check("CS-39 pause and resume", st == 200 and st2 == 200, (st, st2, str(r2)[:150]))
        st, r = dm.rpc("combat_finish", "finish", p_encounter=enc, p_notes="smoke", p_decisions={}, p_confirm=True, p_request=str(uuid.uuid4()))
        st2, s = dm.rpc("combat_get_summary", "summary", p_encounter=enc)
        check("CS-40 finish and summary", st == 200 and st2 == 200 and isinstance(s, dict), (st, str(r)[:150], st2, str(s)[:150]))
        st, r = dm.rpc("combat_archive_encounter", p_encounter=enc, p_archived=True)
        check("CS-41 the finished encounter is archived", st == 200, (st, str(r)[:150]))
        check("CS-42 DM page without console errors", not D.errors, D.errors[:3])
        D.close(); P.close()
        b.close()

    # ---- items: delete an unused herb (typed name), a used one is archive-only; icon and herb kind stored
    st, it = dm.rpc("create_homebrew_item", p_request_id=str(uuid.uuid4()), p_definition={"name": f"Smoke root {RUN}", "kind_id": "herbs_plants",
                    "category_id": "plant-root", "icon_key": "plant.root"}, p_stats={})
    iid = (it or {}).get("id") if isinstance(it, dict) else None
    st2, row = dm.get(f"items?id=eq.{iid}&select=kind_id,icon_key")
    check("CS-43 a Herbs & Plants item with an icon override is created", st == 200 and row and row[0] == {"kind_id": "herbs_plants", "icon_key": "plant.root"}, (st, str(it)[:200], row))
    st, pv = dm.rpc("preview_item_deletion", "item_delete_preview", p_item=iid)
    st2, r2 = dm.rpc("delete_custom_item", p_item=iid, p_confirm_name="wrong name")
    st3, r3 = dm.rpc("delete_custom_item", p_item=iid, p_confirm_name=f"Smoke root {RUN}")
    st4, row = dm.get(f"items?id=eq.{iid}&select=id")
    check("CS-44 an unused item: preview allows deletion, a wrong name is refused, the exact name deletes it",
          st == 200 and st2 >= 400 and st3 == 200 and row == [], (st, str(pv)[:150], st2, st3, str(r3)[:150], row))
    # a campaign potion the player puts into the Hero's inventory: used -> the DM cannot delete it (archive instead)
    st, it = dm.rpc("create_homebrew_item", p_request_id=str(uuid.uuid4()), p_definition={"name": f"Smoke tonic {RUN}", "kind_id": "potion",
                    "campaign_id": camp}, p_stats={})
    tid = (it or {}).get("id") if isinstance(it, dict) else None
    st_i, inv = pl.get(f"inventories?character_id=eq.{hero}&kind=eq.character&select=id")
    st_a, _ = pl.rpc("add_inventory_item", p_inventory=inv[0]["id"], p_item=tid, p_quantity=1, p_custom_name=None, p_notes=None, p_state={})
    st, pv = dm.rpc("preview_item_deletion", p_item=tid)
    st2, r2 = dm.rpc("delete_custom_item", p_item=tid, p_confirm_name=f"Smoke tonic {RUN}")
    st3, row = dm.get(f"items?id=eq.{tid}&select=id")
    check("CS-45 a used item cannot be deleted (archive instead); it stays", st_a == 200 and st == 200 and st2 >= 400 and len(row) == 1,
          (str(it)[:200], st_a, st, str(pv)[:200], st2, str(r2)[:150]))

    # ---- feats: direct removal with a preview on the synthetic Solo character
    st, r = pl.rpc("assign_character_feat", p_character=solo, p_version="tough-2024", p_choices={}, p_source_type="direct", p_source_note=None,
                   p_override_reason=None, p_notes=None)
    st_f, feats = pl.get(f"character_feats?character_id=eq.{solo}&select=id")
    fid = feats[0]["id"] if feats else None
    st2, pv = pl.rpc("preview_character_feat_removal", "feat_preview", p_character_feat=fid)
    st3, r3 = pl.rpc("remove_character_feat", "feat_remove", p_character_feat=fid, p_reason="smoke")
    st4, feats = pl.get(f"character_feats?character_id=eq.{solo}&select=id")
    check("CS-46 direct feat removal: preview, remove, gone", st == 200 and st2 == 200 and st3 == 200 and feats == [], (st, st2, str(pv)[:150], st3, str(r3)[:150]))
    st, r = pl.rpc("remove_character_feat", p_character_feat=fid, p_reason="again")
    check("CS-47 removing it again is refused with the clear message (feat_absent), not a raw lookup error", st >= 400
          and (r or {}).get("hint") == "feat_absent" and "no longer on the character" in (r or {}).get("message", ""), (st, str(r)[:150]))
    st, r = st_.rpc("preview_character_feat_removal", p_character_feat=fid)
    check("CS-48 unrelated user learns nothing (no campaign name)", st >= 400 and "Smoke FL" not in json.dumps(r), (st, str(r)[:150]))


if __name__ == "__main__":
    t0 = time.time()
    try:
        run()
    finally:
        summary["timings"] = {k: {"n": len(v), "max_ms": max(x["ms"] for x in v), "mean_ms": round(sum(x["ms"] for x in v) / len(v)),
                                  "max_bytes": max(x["bytes"] for x in v), "statuses": sorted({x["status"] for x in v})} for k, v in timings.items()}
        summary["passed"], summary["failed"], summary["seconds"] = sum(results), len(results) - sum(results), round(time.time() - t0)
        print(json.dumps(summary, indent=1))
        if OUT:
            with open(OUT, "w", encoding="utf-8") as f:
                json.dump(summary, f, indent=1)
        print(f"{sum(results)} passed, {len(results) - sum(results)} failed")
