"""Feat removal, source-granted feats, ability-score source rows and the Combat Builder follow-through (docs/FEAT_REMOVAL.md,
docs/ABILITY_SCORE_SOURCE_MODEL.md, docs/COMBAT_BUILDER_FOLLOWUP.md). LOCAL ONLY, synthetic users inside isolation.

Covers: the review dialog (source, exact consequences from the server simulation, permanence, keyboard, focus return, double
click), "Request removal" under approval governance (Ask your DM), locks (no clickable Remove), DM removal, source-granted feats
(background / lineage / class ASI) with their change actions, Realtime in a second session, the progressive and the legacy
(?fluent=0) read paths, export / import, ability source rows without a stale "= score", the authoritative effective score,
"updating" while a base edit saves, Wild Shape physical / retained scores, the Combat Builder's linked values after a base
Dexterity edit and a feat removal, and the 1366 / 820 / 390 / 360 layouts. Screenshots go to SCREENSHOT_DIR.
Usage: APP_URL=... python feat_removal_ui_test.py   (run_browser_local.sh sets the environment)
"""
import json
import re
import uuid

from playwright.sync_api import sync_playwright

import isolation as iso
from class_ui_common import APP, PW, RUN, SHOTS, Sheet, User, call, check, report

SHOTS.mkdir(parents=True, exist_ok=True)
q = iso.psql


def shot(page, name):
    page.screenshot(path=str(SHOTS / f"fr_{name}.png"), full_page=False)


def asi(u, cid, values, unlock="fighter-phb-u4-asi", choice="fighter-asi-phb-asi"):
    st, cf = u.rpc("get_character_class_features", p_character=cid)
    return u.rpc("set_character_feature_choice", p_character=cid, p_character_class=cf["classes"][0]["id"], p_unlock=unlock,
                 p_choice=choice, p_values=values, p_manual_status=None)


def assign(u, cid, feat, choices=None, source="direct"):
    st, r = u.rpc("assign_character_feat", p_character=cid, p_version=feat, p_choices=choices or {}, p_source_type=source,
                  p_source_note=None, p_override_reason=None, p_notes=None)
    assert st == 200, (st, r)
    return q(f"select id from public.character_feats where character_id = '{cid}' and feat_version_id = '{feat}'")


def feat_names(page):
    return [h.inner_text() for h in page.locator("#feats-card .feat-card h4").all()]


def card(page, k):
    return page.locator(f'#ability-cards [data-ability="{k}"] .ab-left')


WIDE_JS = """() => document.documentElement.scrollWidth - document.documentElement.clientWidth"""


def run(t):
    dm, pl, other = User("frdm"), User("frpl"), User("frot")
    rel, std = str(uuid.uuid4()), str(uuid.uuid4())
    q(f"insert into public.campaigns (id, name, created_by) values ('{rel}', 'FR Relaxed {RUN}', '{dm.id}'), ('{std}', 'FR Standard {RUN}', '{dm.id}');"
      f"insert into public.campaign_members (campaign_id, user_id, role) values ('{rel}', '{dm.id}', 'dm'), ('{rel}', '{pl.id}', 'player'),"
      f" ('{std}', '{dm.id}', 'dm'), ('{std}', '{pl.id}', 'player');"
      f"insert into public.campaign_governance (campaign_id, preset) values ('{rel}', 'relaxed'), ('{std}', 'standard');")

    # A: solo fighter 4. Human (+1 every score), ASI +1 STR / +1 DEX, direct Tough and Alert
    a = pl.character(f"FR Abil {RUN}", [("fighter-phb", 4)], strength=15, dexterity=14, constitution=14, wisdom=12)
    st, r = pl.rpc("set_character_lineage", p_character=a, p_version="human-phb")
    check("S0 fixture: Human lineage", st == 200, r)
    asi(pl, a, ["str:1", "dex:1"])
    tough_a = assign(pl, a, "tough-2014")
    alert_a = assign(pl, a, "alert-2014")
    # B: in the standard campaign (feats need approval), a DM reward
    b = pl.character(f"FR Gov {RUN}", [("fighter-phb", 4)], strength=15)
    q(f"update public.characters set campaign_id = '{std}' where id = '{b}'; insert into public.character_governance (character_id, setup_complete) values ('{b}', true);")
    assign(dm, b, "alert-2014", source="campaign_reward")
    # C: relaxed campaign, for Realtime and Combat Builder
    c = pl.character(f"FR Combat {RUN}", [("fighter-phb", 4)], strength=15, dexterity=14, wisdom=12, hp_max=40, hp_current=40)
    q(f"update public.characters set campaign_id = '{rel}' where id = '{c}'; insert into public.character_governance (character_id, setup_complete) values ('{c}', true);")
    alert_c = assign(pl, c, "alert-2014")
    tough_c = assign(pl, c, "tough-2014")
    # S: source-granted feats: background (Sage -> Magic Initiate), Variant Human (Skilled), ASI (Observant)
    s = pl.character(f"FR Sources {RUN}", [("fighter-phb", 4)], strength=15)
    st, r = pl.rpc("set_character_background", p_character=s, p_version="sage-2024", p_ability={"mode": "plus2_plus1", "allocation": {"int": 2, "con": 1}})
    check("S1 fixture: Sage background", st == 200, r)
    pl.rpc("set_character_lineage", p_character=s, p_version="human-phb", p_subversion="human-variant")
    q(f"insert into public.character_lineage_choices (character_id, choice_id, pick, value) values ('{s}', 'human-variant:feat', 1, 'feat:skilled-2014') on conflict do nothing")
    asi(pl, s, ["feat:observant-2014"])
    # L: locked character in the relaxed campaign
    lk = pl.character(f"FR Locked {RUN}", [("fighter-phb", 4)], strength=15)
    q(f"update public.characters set campaign_id = '{rel}' where id = '{lk}'; insert into public.character_governance (character_id, setup_complete, lock_mode, lock_reason) values ('{lk}', true, 'build_locked', 'Session');")
    assign(dm, lk, "alert-2014")
    # W: druid in Wild Shape
    w = pl.character(f"FR Druid {RUN}", [("druid-phb", 2)], strength=10, dexterity=12, constitution=14, wisdom=16)
    st, r = pl.rpc("start_transformation", p_character=w, p_creature="wolf", p_options={})
    check("S2 fixture: Wild Shape (wolf)", st == 200, r)
    t.note(characters=[a, b, c, s, lk, w])

    with sync_playwright() as p:
        br = p.chromium.launch(channel="msedge", headless=True)
        P = Sheet(br, pl, tab="stats")
        pg = P.page

        # ------------------------------------------------------------------------------------- ability source rows
        P.open(a)
        P.wait(lambda: card(pg, "str").locator("[data-ab-source]").count() >= 2)
        txt = card(pg, "str").inner_text()
        check("A1 STR card: base 15 in the input", card(pg, "str").locator("input").input_value() == "15")
        check("A2 STR: one row per source (lineage +1, Fighter ASI +1)", card(pg, "str").locator('[data-ab-source="lineage"]').count() == 1
              and card(pg, "str").locator('[data-ab-source="effect"]').count() == 1, txt)
        check("A3 several sources on one ability: 'Bonuses from sources: +2'", "Bonuses from sources: +2" in txt, txt)
        check("A4 no stale equation: no '= <number>' anywhere in the ability cards",
              not re.search(r"=\s*\d", pg.locator("#ability-cards").inner_text()), pg.locator("#ability-cards").inner_text()[:300])
        eff = card(pg, "str").locator("[data-ab-eff]")
        check("A5 the authoritative effective score is in the card (Score 17 = server)", "Score 17" in eff.inner_text()
              and q(f"select (public._derived_stats_full('{a}') -> 'abilities' -> 'str' ->> 'score')") == "17", eff.inner_text())
        check("A6 screen-reader text names the ability: '+1 Strength from Fighter: Ability Score Improvement'",
              card(pg, "str").locator(".sr-only", has_text="+1 Strength from Fighter: Ability Score Improvement").count() == 1)
        check("A7 modifier follows the effective score (+3)", pg.locator('[data-derive="mod:str"]').inner_text() == "+3")
        check("A8 lineage only (+1): WIS 12 -> Score 13, one row, no total", "Score 13" in card(pg, "wis").inner_text()
              and card(pg, "wis").locator("[data-ab-source]").count() == 1 and "Bonuses from sources" not in card(pg, "wis").inner_text())
        # base edit: 'updating', then the server value; the source rows never change
        inp = card(pg, "str").locator("input")
        inp.fill("12")
        inp.dispatch_event("input")
        pg.wait_for_timeout(80)
        check("A12/A15 while the edited base saves the score says 'updating' (no client arithmetic)", "updating" in eff.inner_text().lower(), eff.inner_text())
        P.wait(lambda: "Score 14" in eff.inner_text(), 10000)
        check("A13 after the save: Score 14 from the server, rows unchanged (+1, +1)", "Score 14" in eff.inner_text()
              and card(pg, "str").locator("[data-ab-source]").count() == 3, card(pg, "str").inner_text())
        check("A34 the base column changed, nothing else stored", q(f"select strength from public.characters where id = '{a}'") == "12")
        inp.fill("15"); inp.dispatch_event("input")
        P.wait(lambda: "Score 17" in eff.inner_text(), 10000)
        check("A12b base increase back: Score 17", "Score 17" in eff.inner_text())
        check("A29 saving throw / skills / passive follow (STR save +5 with proficiency, Athletics +3)",
              pg.locator('[data-derive="save:str"]').inner_text() == "+5" and pg.locator('[data-derive="skill:athletics"]').inner_text() == "+3",
              pg.locator('[data-derive="save:str"]').inner_text() + " " + pg.locator('[data-derive="skill:athletics"]').inner_text())
        shot(pg, "ability_cards_1366")
        # legacy read path
        pg.goto(f"{APP}?fluent=0#/c/{a}")
        P.wait(lambda: card(pg, "str").locator("[data-ab-source]").count() >= 2)
        check("A24 legacy ?fluent=0: the same rows and Score 17, no equation", "Score 17" in card(pg, "str").inner_text()
              and not re.search(r"=\s*\d", pg.locator("#ability-cards").inner_text()))
        pg.goto(f"{APP}?fluent=default#/c/{a}")
        P.wait(lambda: card(pg, "str").locator("[data-ab-source]").count() >= 2)

        # ------------------------------------------------------------------------------------- Wild Shape
        P.open(w)
        P.wait(lambda: "From form" in card(pg, "str").inner_text())
        check("A26 Wild Shape: STR from the form, note names the character's BASE score, no source rows",
              "character base score 10" in card(pg, "str").inner_text() and card(pg, "str").locator("[data-ab-source]").count() == 0
              and card(pg, "str").locator("[data-ab-eff]").inner_text() == "", card(pg, "str").inner_text())
        check("A27 retained WIS: 'Retained from character', no 'updating'", "Retained from character" in card(pg, "wis").inner_text()
              and "updating" not in card(pg, "wis").inner_text().lower(), card(pg, "wis").inner_text())

        # ------------------------------------------------------------------------------------- feat removal dialog
        P.open(a)
        P.tab("features")
        P.wait(lambda: len(feat_names(pg)) >= 2)
        rm = pg.locator(f'#feats-card [data-feat="remove"][data-cf="{tough_a}"]')
        check("F33 Remove has an accessible name with the feat", rm.get_attribute("aria-label") == "Remove feat Tough")
        rm.focus()
        pg.keyboard.press("Enter")
        pg.wait_for_selector(".modal [data-rf-diff]", timeout=10000)
        body = pg.locator(".modal").inner_text()
        check("F-UI1 review dialog: title, source, exact consequence (Maximum HP 48 -> 40), permanence",
              "Remove feat: Tough" in body and "Maximum HP: 48" in body and "40" in body and "This is permanent" in body, body[:400])
        check("F-UI2 the confirm button is focused and labelled Remove feat",
              pg.evaluate("() => document.activeElement?.dataset?.rfOk !== undefined") and pg.locator(".modal [data-rf-ok]").inner_text() == "Remove feat")
        shot(pg, "remove_dialog_1366")
        pg.keyboard.press("Escape")
        pg.wait_for_timeout(400)
        check("F34 Escape cancels and focus returns to the Remove button", pg.evaluate(f"() => document.activeElement?.dataset?.cf === '{tough_a}'")
              and q(f"select count(*) from public.character_feats where id = '{tough_a}'") == "1")
        rm.click()
        pg.wait_for_selector(".modal [data-rf-diff]")
        pg.locator(".modal [data-rf-ok]").dblclick()
        P.wait(lambda: "Tough" not in feat_names(pg), 10000)
        check("F22 double click: removed once, one toast", feat_names(pg).count("Tough") == 0 and P.toasts().count("Feat removed: Tough") == 1, P.toasts())
        check("F15 maximum HP recalculated (48 -> 40)", q(f"select public._feat_hp_bonus('{a}') ->> 'max'") == "40",
              q(f"select public._feat_hp_bonus('{a}') ->> 'max'"))
        # export no longer includes it; import of an old export does not silently recreate it on this character
        st, ex = pl.rpc("export_character_feats", p_character=a)
        check("F28 export no longer includes the removed feat", st == 200 and "tough-2014" not in json.dumps(ex), str(ex)[:200])

        # ------------------------------------------------------------------------------------- source-granted feats
        P.open(s)
        P.tab("features")
        P.wait(lambda: pg.locator("#feats-card [data-feat-granted]").count() >= 3)
        g = {k: pg.locator(f'#feats-card [data-feat-granted="{k}"]') for k in ("background", "lineage", "class")}
        check("F18 background feat: 'Granted by your background' + Change background…, no Remove",
              g["background"].count() == 1 and "Change background" in g["background"].inner_text(), g["background"].all_inner_texts())
        check("F19 lineage feat: 'Granted by your lineage' + Change lineage choice…", g["lineage"].count() == 1 and "Change lineage choice" in g["lineage"].inner_text())
        check("F20 class ASI feat: 'Granted by an Ability Score Improvement' + Change choice…", g["class"].count() == 1 and "Change choice" in g["class"].inner_text())
        check("F20b no Remove button on any source-granted feat", pg.locator('#feats-card [data-feat="remove"]').count() == 0)
        g["class"].locator('[data-feat="source"]').click()
        pg.wait_for_timeout(900)
        check("F21 Change choice… opens the ASI choice in Class features and moves focus into it",
              pg.evaluate("() => document.activeElement?.closest('[data-cf-choice-wrap]')?.dataset.cfChoiceWrap") == "fighter-phb-u4-asi:fighter-asi-phb-asi")
        g["background"].locator('[data-action="bg-choose"]').click()
        pg.wait_for_selector(".modal", timeout=8000)
        check("F21b Change background… opens the background chooser", pg.locator(".modal").count() >= 1)
        pg.keyboard.press("Escape")
        shot(pg, "source_granted_1366")

        # ------------------------------------------------------------------------------------- governance
        P.open(b)
        P.tab("features")
        P.wait(lambda: pg.locator('#feats-card [data-feat="remove"]').count() == 1, 15000)
        btn = pg.locator('#feats-card [data-feat="remove"]')
        check("F4 approval campaign: the action says 'Request removal…'", btn.inner_text().strip() == "Request removal…", btn.inner_text())
        btn.click()
        pg.wait_for_selector(".modal [data-rf-request]", timeout=10000)
        check("F4b the dialog explains the approval and shows the consequence", "approval" in pg.locator(".modal").inner_text()
              and "Initiative bonus" in pg.locator(".modal").inner_text())
        pg.locator(".modal [data-rf-ok]").click()
        P.wait(lambda: pg.locator(".modal [data-send]").count() > 0, 10000)
        check("F4c Request removal opens the campaign's Ask your DM dialog", pg.locator(".modal [data-send]").count() == 1)
        pg.locator(".modal [data-send]").click()
        P.wait(lambda: q(f"select count(*) from public.change_requests where character_id = '{b}' and status = 'submitted'") == "1", 10000)
        check("F4d a removal request is submitted; the feat stays until approved",
              q(f"select count(*) from public.character_feats where character_id = '{b}'") == "1")
        P.open(lk)
        P.tab("features")
        P.wait(lambda: pg.locator("#feats-card .feat-card").count() == 1, 15000)
        P.wait(lambda: pg.locator("#feats-card [data-feat-rm-note]").count() == 1, 8000)
        check("F8 build-locked character: no clickable Remove, an explanation instead",
              pg.locator('#feats-card [data-feat="remove"]').count() == 0 and "locked" in pg.locator("#feats-card [data-feat-rm-note]").inner_text())

        # ------------------------------------------------------------------------------------- Realtime + Combat Builder
        D = Sheet(br, dm, tab="features")
        dp = D.page
        st, r = dm.rpc("combat_create_encounter", p_campaign=rel, p_name=f"FR Fight {RUN}", p_ruleset="2014")
        enc = r["encounter"]["id"] if "encounter" in r else r["id"]
        mods = {c: {"initiative_mod": 2, "dexterity": 14}}
        dm.rpc("combat_add_characters", p_encounter=enc, p_characters=[c], p_options={"mods": mods})
        pid = q(f"select id from public.combat_participants where encounter_id = '{enc}' and linked_character_id = '{c}'")
        t.note(encounter=enc)
        dp.goto(f"{APP}#/combat/e/{enc}")
        dp.wait_for_selector(".cb-builder, .cb-live", timeout=20000)
        D.wait(lambda: q(f"select initiative_mod from public.combat_participants where id = '{pid}'") == "7", 12000)
        check("C0 Initiative modifier follows the sheet before Initiative is rolled (DEX +2, Alert +5 = 7)",
              q(f"select initiative_mod from public.combat_participants where id = '{pid}'") == "7",
              q(f"select initiative_mod from public.combat_participants where id = '{pid}'"))
        # the player edits the base DEX on the sheet (other session)
        P.open(c)
        P.tab("stats")
        di = card(pg, "dex").locator("input")
        di.fill("18"); di.dispatch_event("input")
        D.wait(lambda: q(f"select initiative_mod from public.combat_participants where id = '{pid}'") == "9", 15000)
        check("C1 base DEX 14 -> 18: the draft encounter's Initiative modifier becomes 9 (Realtime, no reload)",
              q(f"select initiative_mod from public.combat_participants where id = '{pid}'") == "9")
        dm.rpc("combat_set_initiative", p_encounter=enc, p_values=[{"id": pid, "initiative": 15}])
        st, r = dm.rpc("combat_start", p_encounter=enc, p_accept_ties=True)
        check("C2 combat started", st == 200, r)
        dp.goto(f"{APP}#/combat/e/{enc}")
        dp.wait_for_selector(".cb-live", timeout=20000)
        dp.locator(f'.cb-row-main[data-id="{pid}"]').first.click()
        dp.wait_for_selector(".cb-detail .cb-statline")
        stat = lambda lbl: dp.locator(f'.cb-detail .cb-stat:has(.cb-stat-label:text-is("{lbl}"))').inner_text()
        D.wait(lambda: "/52" in stat("HP") or "/48" in stat("HP"), 8000)
        hp0, pp0 = stat("HP"), stat("Passive Perc.")
        D2 = Sheet(br, dm, tab="features")       # the DM's sheet of C, open before the player removes anything
        D2.open(c)
        D2.wait(lambda: "Alert" in feat_names(D2.page), 10000)
        reqs = []
        dp.on("request", lambda r_: reqs.append(r_.url) if "combat_get_encounter" in r_.url else None)
        # the player removes Tough and Alert in their window
        P.tab("features")
        for cfid in (tough_c, alert_c):
            pg.locator(f'#feats-card [data-feat="remove"][data-cf="{cfid}"]').click()
            pg.wait_for_selector(".modal [data-rf-diff]")
            pg.locator(".modal [data-rf-ok]").click()
            pg.wait_for_selector(".modal", state="detached", timeout=10000)
        D.wait(lambda: "/40" in stat("HP"), 15000)
        check("C3 running encounter: maximum HP follows the Tough removal (48 -> 40) without a reload", "/40" in stat("HP"), f"{hp0} -> {stat('HP')}")
        check("C4 the rolled Initiative (15) is kept; Alert removal does not re-sort a running combat",
              q(f"select initiative from public.combat_participants where id = '{pid}'") == "15")
        check("C5 targeted refresh: no full encounter reload for the build change", not reqs, reqs[:3])
        # Realtime on the sheet: the DM's sheet of C, open the whole time, drops the feats without a reload
        D2.wait(lambda: "Alert" not in feat_names(D2.page) and "Tough" not in feat_names(D2.page), 15000)
        check("F25 Realtime: another open session's sheet shows the current feats (no reload)",
              "Alert" not in feat_names(D2.page) and "Tough" not in feat_names(D2.page), feat_names(D2.page))
        q(f"delete from public.combat_encounters where id = '{enc}'")

        # ------------------------------------------------------------------------------------- DM removal + layouts
        pg.goto(f"{APP}?fluent=0#/c/{c}")            # the player's legacy-path sheet stays open while the DM removes
        P.wait(lambda: pg.locator(".tab").count() > 0)
        P.tab("features")
        assign(pl, c, "tough-2014")
        P.wait(lambda: "Tough" in feat_names(pg), 15000)
        check("F27a legacy ?fluent=0: a feat added elsewhere appears (Realtime)", "Tough" in feat_names(pg), feat_names(pg))
        D2.open(c)
        D2.wait(lambda: "Tough" in feat_names(D2.page), 10000)
        D2.page.locator('#feats-card [data-feat="remove"]').first.click()
        D2.page.wait_for_selector(".modal [data-rf-diff]")
        D2.page.locator(".modal [data-rf-ok]").click()
        D2.wait(lambda: "Tough" not in feat_names(D2.page), 10000)
        check("F3 the DM removes a player's feat from the sheet", "Tough" not in feat_names(D2.page))
        P.wait(lambda: "Tough" not in feat_names(pg), 15000)
        check("F27 legacy ?fluent=0: the removal reaches the open sheet", "Tough" not in feat_names(pg), feat_names(pg))
        pg.goto(f"{APP}?fluent=default#/")
        aud = q(f"select count(*) from public.campaign_audit_events where character_id = '{c}' and event_type = 'feat_removed'")
        check("F30 audit: one event per removal (3)", aud == "3", aud)

        for (wd, ht) in ((820, 1000), (390, 844), (360, 800)):
            M = Sheet(br, pl, width=wd, height=ht, tab="stats")
            mp = M.page
            M.open(a)
            M.wait(lambda: card(mp, "str").locator("[data-ab-source]").count() >= 2)
            check(f"R{wd} ability rows fit, no horizontal page scroll", mp.evaluate(WIDE_JS) <= 0, mp.evaluate(WIDE_JS))
            shot(mp, f"ability_{wd}")
            M.tab("features")
            M.wait(lambda: mp.locator('#feats-card [data-feat="remove"]').count() >= 1)
            mp.locator('#feats-card [data-feat="remove"]').first.scroll_into_view_if_needed()
            mp.locator('#feats-card [data-feat="remove"]').first.click()
            mp.wait_for_selector(".modal [data-rf-diff]")
            box = mp.locator(".modal [data-rf-ok]").bounding_box()
            check(f"R{wd}b remove dialog: buttons reachable inside the viewport", box and box["y"] + box["height"] <= ht and box["x"] >= 0
                  and mp.evaluate(WIDE_JS) <= 0, box)
            shot(mp, f"remove_dialog_{wd}")
            mp.keyboard.press("Escape")
            M.close()

        errs = [e for e in P.errors + D.errors + D2.errors if "Failed to load resource" not in e]
        check("Z1 no console errors", not errs, errs[:5])
        check("Z2 no request left this machine", not P.remote and not D.remote, (P.remote + D.remote)[:3])
        P.close(); D.close(); D2.close(); br.close()


if __name__ == "__main__":
    with iso.Isolated("FEAT-REMOVAL-UI") as t:
        run(t)
    report()
