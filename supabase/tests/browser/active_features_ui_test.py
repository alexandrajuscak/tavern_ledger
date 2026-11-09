"""Active gameplay features in Play, the feat choice repair and DM content management (docs/ACTIVE_GAMEPLAY_FEATURE_AUDIT.md,
docs/FEAT_SYSTEM_AUDIT.md, docs/CONTENT_MANAGEMENT.md). LOCAL ONLY, synthetic users inside isolation.

Covers: lineage traits and feats as Play cards under their timing (Breath Weapon = Action, Relentless Endurance = Free and
special, Interception = Reaction) with automation labels and no fake Use button; feat counters in Ready to use; the repaired
edit-choices path of a lineage-granted Magic Initiate (spell list options, cantrip / spell pickers, honest "not complete" toast,
spells in the spellbook under the feat's source); a direct feat removal from Play and Build; the Combat Builder's on-request
Active features of a linked character; DM Space: View usage, Delete permanently of an unused draft, a blocked delete of used
content, Duplicate official as homebrew; the progressive and the legacy (?fluent=0) read paths; no horizontal overflow at 390.
Usage: APP_URL=... python active_features_ui_test.py   (run_browser_local.sh sets the environment)
"""
import uuid

from playwright.sync_api import sync_playwright

import isolation as iso
from class_ui_common import APP, RUN, SHOTS, Sheet, User, check, report

SHOTS.mkdir(parents=True, exist_ok=True)
q = iso.psql


def shot(page, name):
    page.screenshot(path=str(SHOTS / f"af_{name}.png"), full_page=False)


def play_text(pg):
    return pg.locator("#combat-groups").inner_text()


def run(t):
    dm, pl = User("afdm"), User("afpl")
    camp = str(uuid.uuid4())
    q(f"insert into public.campaigns (id, name, created_by) values ('{camp}', 'AF Table {RUN}', '{dm.id}');"
      f"insert into public.campaign_members (campaign_id, user_id, role) values ('{camp}', '{dm.id}', 'dm'), ('{camp}', '{pl.id}', 'player');"
      f"insert into public.campaign_governance (campaign_id, preset) values ('{camp}', 'relaxed');")
    # D: Chromatic Dragonborn fighter 5 (Breath Weapon action + Chromatic Warding), Interception (reaction), in the campaign
    d = pl.character(f"AF Dragon {RUN}", [("fighter-phb", 5)], strength=16, constitution=14)
    q(f"update public.characters set campaign_id = '{camp}' where id = '{d}'; insert into public.character_governance (character_id, setup_complete) values ('{d}', true);")
    st, r = pl.rpc("set_character_lineage", p_character=d, p_version="dragonborn-chromatic", p_choices={"dragonborn-chromatic:ancestry": ["blue"]})
    check("S0 fixture: Chromatic Dragonborn", st == 200, r)
    st, r = pl.rpc("assign_character_feat", p_character=d, p_version="interception-2024", p_choices={}, p_source_type="direct",
                   p_source_note=None, p_override_reason=None, p_notes=None)
    check("S1 fixture: Interception (direct)", st == 200, r)
    # H: Half-Orc (Relentless Endurance) + Variant Human style lineage feat: Magic Initiate with NO choices yet
    h = pl.character(f"AF Initiate {RUN}", [("fighter-phb", 4)], strength=15, wisdom=14)
    st, r = pl.rpc("set_character_lineage", p_character=h, p_version="human-phb", p_subversion="human-variant")
    check("S2 fixture: Variant Human", st == 200, r)
    q(f"insert into public.character_lineage_choices (character_id, choice_id, pick, value) values ('{h}', 'human-variant:feat', 1, 'feat:magic-initiate-2024') on conflict do nothing;"
      f"update public.characters set campaign_id = '{camp}' where id = '{h}'; insert into public.character_governance (character_id, setup_complete) values ('{h}', true);")
    t.note(characters=[d, h])

    with sync_playwright() as p:
        br = p.chromium.launch(channel="msedge", headless=True)
        P = Sheet(br, pl, tab="combat")
        pg = P.page

        # ------------------------------------------------------------------------------------------------ Play cards
        P.open(d)
        P.wait(lambda: pg.locator('[data-active-feature="lin:dragonborn-chromatic:breath-weapon"]').count() == 1)
        bw = pg.locator('[data-active-feature="lin:dragonborn-chromatic:breath-weapon"]')
        check("P1 Breath Weapon is a Play card in the Actions group", bw.count() == 1
              and pg.locator('#combat-groups .group-action [data-active-feature="lin:dragonborn-chromatic:breath-weapon"]').count() == 1, play_text(pg)[:400])
        check("P2 the card shows source, timing, uses and an automation label; no Use button on the card",
              "Chromatic Dragonborn" in bw.inner_text() and "Action" in bw.inner_text() and "left" in bw.inner_text()
              and bw.locator(".af-auto").count() == 1 and bw.locator("button").count() == 0, bw.inner_text())
        ic = pg.locator('#combat-groups .group-reaction [data-active-feature^="feat:"]')
        check("P3 Interception (feat) is a Reaction card with its feat source", ic.count() == 1 and "Interception" in ic.inner_text()
              and "Feat" in ic.inner_text(), play_text(pg)[:400])
        check("P4 Chromatic Warding (level 5, action) is shown; Draconic Resistance is a one-line reminder, not a card",
              pg.locator('[data-active-feature="lin:dragonborn-chromatic:chromatic-warding"]').count() == 1
              and pg.locator('#combat-groups .passive-group [data-active-feature="lin:dragonborn-chromatic:draconic-resistance"]').count() == 1)
        check("P5 Ready to use keeps the lineage counters with their Use buttons",
              "Breath Weapon" in pg.locator("#combat-states").inner_text())
        shot(pg, "play_dragon")

        # --------------------------------------------------------------- lineage-granted Magic Initiate: choose now
        P.open(h)
        P.tab("features")
        P.wait(lambda: pg.locator('#feats-card [data-feat="choices"]').count() > 0)
        open_note = pg.locator('#feats-card .feat-open').first.inner_text()
        check("F1 Build names the next step of the open lineage feat (Spell list, Cantrips, ...)",
              "Next step" in open_note and "Spell list" in open_note, open_note)
        pg.locator('#feats-card [data-feat="choices"]').first.click()
        pg.wait_for_selector(".modal [data-choice-form]")
        form = pg.locator(".modal [data-choice-form]")
        check("F2 the Spell list choice now has its options (it had none before the repair)",
              form.locator('[data-choice="list"] input[type=radio]').count() == 3, form.inner_text()[:300])
        form.locator('[data-choice="list"] input[value="cleric-spell-list"]').check()
        P.wait(lambda: form.locator('[data-spell-choice="cantrips"] input').count() > 0)
        check("F3 picking the list loads the cantrip and level-1 pickers from the Cleric list",
              form.locator('[data-spell-choice="cantrips"] input').count() > 3 and form.locator('[data-spell-choice="spell1"] input').count() > 3)
        form.locator('[data-choice="ability"] input[value="wis"]').check()
        form.locator('[data-spell-choice="cantrips"] input[value="guidance-phb"]').check()
        # only one cantrip: saving is honest about what is still open
        pg.locator(".modal [data-save]").click()
        P.wait(lambda: "not complete" in P.toasts())
        check("F4 saving with a missing cantrip says 'Saved, but not complete yet' (never a plain 'Choices saved')",
              "not complete" in P.toasts() and "cantrip" in P.toasts().lower(), P.toasts())
        stored = q(f"select string_agg(split_part(choice_id, ':', 2) || '=' || value, ',' order by choice_id, pick) from public.character_feat_choices where character_id = '{h}'")
        check("F4b ... and what was chosen IS stored (list, ability, one cantrip)", stored == "ability=wis,cantrips=guidance-phb,list=cleric-spell-list", stored)
        P.wait(lambda: "Spell list" not in pg.locator('#feats-card .feat-open').first.inner_text())   # the card follows the save
        pg.locator('#feats-card [data-feat="choices"]').first.click()
        pg.wait_for_selector(".modal [data-choice-form]")
        form = pg.locator(".modal [data-choice-form]")
        P.wait(lambda: form.locator('[data-spell-choice="cantrips"] input').count() > 0)
        check("F5 the stored choices reload (Cleric list and Guidance are selected)",
              form.locator('[data-choice="list"] input[value="cleric-spell-list"]').is_checked()
              and form.locator('[data-spell-choice="cantrips"] input[value="guidance-phb"]').is_checked())
        form.locator('[data-spell-choice="cantrips"] input[value="light-phb"]').check()
        form.locator('[data-spell-choice="spell1"] input[value="bless-phb"]').check()
        pg.locator(".modal [data-save]").click()
        P.wait(lambda: "spellbook" in P.toasts())
        check("F6 complete choices: 'Choices saved. The spells are in your spellbook.'", "spellbook" in P.toasts(), P.toasts())
        src = q(f"select label || '|' || casting_ability || '|' || (select count(*) from public.character_spells cs where cs.source_id = s.id) "
                f"from public.character_spellcasting_sources s where s.character_id = '{h}' and s.feat_grant_key like 'lin:%'")
        check("F7 one feat spell source (Lineage: Variant Human), Wisdom, 3 spells", src.startswith("Magic Initiate (") and src.endswith("|wis|3"), src)
        P.tab("spells")
        P.wait(lambda: "Bless" in pg.locator("#tab-panel-spells, [data-tab-panel='spells'], main").first.inner_text())
        check("F8 the Spells tab lists the feat's spells", "Guidance" in pg.locator("main").inner_text() and "Bless" in pg.locator("main").inner_text())
        # legacy read path
        pg.goto(f"{APP}?fluent=0#/c/{h}")
        P.wait(lambda: pg.locator(".tab").count() > 0)
        P.tab("features")
        P.wait(lambda: pg.locator("#feats-card .feat-card").count() > 0)
        check("F9 legacy read path (?fluent=0): the feat shows no open choices", pg.locator("#feats-card .feat-open").count() == 0)
        pg.goto(f"{APP}?fluent=default#/c/{h}")
        P.wait(lambda: pg.locator(".tab").count() > 0)

        # --------------------------------------------------------------------------- Combat Builder: active features
        D = Sheet(br, dm, tab="combat")
        dp = D.page
        st, enc = dm.rpc("combat_create_encounter", p_campaign=camp, p_name=f"AF Fight {RUN}", p_ruleset="campaign", p_description="",
                         p_settings={}, p_request=str(uuid.uuid4()))
        eid = (enc.get("encounter") or {}).get("id") or enc.get("id") if isinstance(enc, dict) else None
        st2, r2 = dm.rpc("combat_add_characters", p_encounter=eid, p_characters=[d], p_options={}, p_request=str(uuid.uuid4()))
        check("S3 fixture: encounter with the linked dragonborn", st == 200 and st2 == 200, (str(enc)[:200], str(r2)[:200]))
        pid = q(f"select id from public.combat_participants where encounter_id = '{eid}' and linked_character_id = '{d}'")
        st3, r3 = dm.rpc("combat_set_initiative", p_encounter=eid, p_values=[{"id": pid, "initiative": 15}], p_request=str(uuid.uuid4()))
        st4, r4 = dm.rpc("combat_start", p_encounter=eid, p_accept_ties=True, p_request=str(uuid.uuid4()))
        check("S4 fixture: initiative set and the combat started (live tracker)", st3 == 200 and st4 == 200, (str(r3)[:200], str(r4)[:200]))
        dp.goto(f"{APP}#/combat/e/{eid}")
        D.wait(lambda: dp.locator(f".cb-row[data-pid='{pid}']").count() > 0, 20000)
        dp.locator(f".cb-row[data-pid='{pid}'] .cb-row-main").click()
        D.wait(lambda: dp.locator('[data-cb="load-features"]').count() > 0)
        dp.locator('[data-cb="load-features"]').first.click()
        D.wait(lambda: dp.locator(".cb-active-features").count() > 0)
        af = dp.locator(".cb-active-features").first.inner_text() if dp.locator(".cb-active-features").count() else ""
        check("C1 the DM sees the linked character's actions and reactions on request (Breath Weapon, Interception)",
              "Breath Weapon" in af and "Interception" in af, af)
        shot(dp, "combat_features")

        # -------------------------------------------------------------------------------------- DM content management
        dp.goto(APP + "#/dm/overview")
        D.wait(lambda: dp.locator('[data-dm-section="content"]').count() > 0)
        dp.locator('[data-dm-section="content"]').click()
        D.wait(lambda: dp.locator('[data-dm="dup-official"]').count() > 0)
        dp.locator('[data-dm="dup-official"]').click()
        dp.wait_for_selector(".modal [data-do-q]")
        dp.select_option(".modal [data-do-type]", "spell")
        dp.fill(".modal [data-do-q]", "Fire Bolt")
        D.wait(lambda: dp.locator(".modal [data-do-copy]").count() > 0)
        dp.locator(".modal [data-do-copy]").first.click()
        D.wait(lambda: dp.locator(".modal [data-ce-form]").count() > 0)
        check("M1 Duplicate official: a new draft opens in the editor", dp.locator(".modal [data-ce-form] input[name=name]").input_value().endswith("(homebrew)"))
        cid = q(f"select id from public.dm_content where campaign_id = '{camp}' and name = 'Fire Bolt (homebrew)'")
        check("M2 the duplicate is a campaign draft; the official Fire Bolt is unchanged",
              bool(cid) and q(f"select status from public.dm_content where id = '{cid}'") == "draft"
              and q("select count(*) from public.spell_versions where id = 'fire-bolt-phb' and content_version_id is null") == "1")
        dp.locator('.modal [data-ce-act="usage"]').click()
        D.wait(lambda: dp.locator(".modal [data-usage-class]").count() > 0)
        check("M3 View usage: Safe to delete, nothing uses it", dp.locator(".modal [data-usage-class]").get_attribute("data-usage-class") == "safe_to_delete")
        dp.locator('.modal [data-u="delete"]').click()
        dp.wait_for_selector(".modal [data-n]")
        dp.fill(".modal [data-n]", "Fire Bolt (homebrew)")
        dp.locator(".modal [data-ok]").click()
        D.wait(lambda: not q(f"select id from public.dm_content where id = '{cid}'"))
        check("M4 Delete permanently with the typed name removes the unused draft", not q(f"select id from public.dm_content where id = '{cid}'"))
        # used content: duplicate + publish + assign, then the library offers no delete
        st, c2 = dm.rpc("duplicate_official_as_homebrew", p_type="feat", p_ref="alert-2024", p_campaign=camp)
        dm.rpc("publish_dm_content", p_content=c2["id"], p_expected_version=None)
        st, asg = dm.rpc("dm_assign_content", p_content=c2["id"], p_characters=[h], p_mode="dm_grant", p_options={})
        check("S5 fixture: the DM grants the custom feat to the player's character", st == 200 and asg["results"][0]["ok"], asg)
        dp.locator('[data-dm-section="overview"]').click()
        dp.locator('[data-dm-section="content"]').click()
        D.wait(lambda: dp.locator(f'[data-dm="usage-content"][data-id="{c2["id"]}"]').count() > 0)
        dp.locator(f'[data-dm="usage-content"][data-id="{c2["id"]}"]').click()
        D.wait(lambda: dp.locator(".modal [data-usage-class]").count() > 0)
        check("M5 used content: Delete blocked, New version required, Archive offered, no Delete button",
              dp.locator(".modal [data-usage-class]").get_attribute("data-usage-class") == "delete_blocked"
              and dp.locator(".modal [data-usage-edit]").count() == 1 and dp.locator('.modal [data-u="archive"]').count() == 1
              and dp.locator('.modal [data-u="delete"]').count() == 0, dp.locator(".modal").inner_text()[:300])
        shot(dp, "usage_blocked")
        dp.keyboard.press("Escape")
        # realtime: with the player's Play tab open, the DM grants Interception: the Reaction card appears without a reload
        P.open(h)
        P.tab("combat")
        pg.evaluate("() => { window.__afNoReload = 1; }")
        st, r = dm.rpc("assign_character_feat", p_character=h, p_version="interception-2024", p_choices={}, p_source_type="dm_grant",
                       p_source_note=None, p_override_reason=None, p_notes=None)
        check("S6 fixture: the DM grants Interception", st == 200, r)
        ok = P.wait(lambda: pg.locator('#combat-groups .group-reaction [data-active-feature^="feat:"]').count() == 1, 10000)
        check("R1 Realtime: the DM-granted Reaction appears in the open Play tab, no page reload",
              ok and pg.evaluate("() => window.__afNoReload") == 1, play_text(pg)[:300])
        cf = q(f"select id from public.character_feats where character_id = '{h}' and feat_version_id = 'interception-2024'")
        st, r = dm.rpc("remove_character_feat", p_character_feat=cf, p_reason="AF test")
        ok = P.wait(lambda: pg.locator('#combat-groups .group-reaction [data-active-feature^="feat:"]').count() == 0, 10000)
        check("R2 Realtime: after the DM removes it, the card leaves Play (targeted update, no reload)",
              st == 200 and ok and pg.evaluate("() => window.__afNoReload") == 1, r)

        # ------------------------------------------------------------------------------------------------ layouts
        M = Sheet(br, pl, width=390, height=844, tab="combat")
        M.open(d)
        M.wait(lambda: M.page.locator('[data-active-feature]').count() > 0)
        check("L1 390 px: Play cards fit without horizontal scrolling", M.overflow() <= 0, M.overflow())
        shot(M.page, "play_390")

        errs = [e for e in P.errors + D.errors + M.errors if "Failed to load resource" not in e]
        check("Z1 no console errors", not errs, errs[:5])
        check("Z2 no request left this machine", not P.remote and not D.remote, (P.remote + D.remote)[:3])
        P.close(); D.close(); M.close(); br.close()


if __name__ == "__main__":
    with iso.Isolated("ACTIVE-FEATURES-UI") as t:
        run(t)
    report()
