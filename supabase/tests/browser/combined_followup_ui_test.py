"""Combined follow-up release, browser suite (docs/COMBAT_BUILDER_FOLLOWUP.md part 2). LOCAL ONLY, synthetic users inside isolation.

Covers: final-total Initiative entry (labels, helper text, no Roll on player rows, Enter-to-next, Auto / Manual monster modes,
shared group values, refresh persistence, a second DM window, mobile 390 / 360, the correction dialog after Start), the Wild
Shape overflow message in the Combat Builder (20 HP form, 21 damage -> 1 to normal HP), active class options in Play
(Warlock invocations and Pact Boon, reminders, no duplicate of an attack rider), Artificer infusions in Play and as an Inventory
badge, Herbs & Plants and Potions in the homebrew form with the icon gallery, the Herbs filter and the item icon override, and
the safe permanent delete from the item picker (unused: deleted; used: archive offered instead).
Usage: API_URL=... ANON_KEY=... SERVICE_ROLE_KEY=... APP_URL=... python combined_followup_ui_test.py
"""
import time
import uuid

from playwright.sync_api import sync_playwright

import isolation as iso
from class_ui_common import APP, RUN, SHOTS, Sheet, User, call, check, report

SHOTS.mkdir(parents=True, exist_ok=True)


def q(sql):
    return iso.psql(sql)


def shot(page, name):
    page.screenshot(path=str(SHOTS / f"cf_{name}.png"), full_page=False)


class Win(Sheet):
    def go(self, hash_, sel=None, timeout=20000):
        self.page.goto(f"{APP}{hash_}")
        if sel:
            self.page.wait_for_selector(sel, timeout=timeout)
        self.page.wait_for_timeout(400)


def pid(enc, name, label=None):
    lab = f"= '{label}'" if label else "is null"
    return q(f"select id from public.combat_participants where encounter_id = '{enc}' and display_name = '{name}' and instance_label {lab} and removed_at is null limit 1")


def ini(p):
    return q(f"select coalesce(initiative::text, '') || '|' || coalesce(initiative_mode, '') from public.combat_participants where id = '{p}'")


def run(t):
    dm, pl = User("cfdm"), User("cfpl")
    camp = str(uuid.uuid4())
    q(f"insert into public.campaigns (id, name, created_by) values ('{camp}', 'UI Followup Campaign {RUN}', '{dm.id}');"
      f"insert into public.campaign_members (campaign_id, user_id, role) values ('{camp}', '{dm.id}', 'dm'), ('{camp}', '{pl.id}', 'player');")
    aria = pl.character(f"Aria {RUN}", [("fighter-phb", 3)], dexterity=16, hp_max=30, hp_current=30)
    brom = pl.character(f"Brom {RUN}", [("fighter-phb", 3)], dexterity=8, hp_max=30, hp_current=30)
    druid = pl.character(f"Elara {RUN}", [("druid-phb", 4)], dexterity=12, hp_max=30, hp_current=30)
    for c in (aria, brom, druid):
        call("PATCH", f"/rest/v1/characters?id=eq.{c}", {"campaign_id": camp}, token=pl.jwt)
    cc = q(f"select id from public.character_classes where character_id = '{druid}' limit 1")
    q(f"insert into public.character_transformations (character_id, character_class_id, resource_key, creature_id, cost, hp_max, hp_current, normal_hp_current, normal_hp_temp) "
      f"values ('{druid}', '{cc}', 'wild-shape', 'brown-bear', 1, 20, 20, 30, 0)")
    # the encounter is prepared through the API (the builder itself is covered by combat_builder_ui_test.py)
    st, r = dm.rpc("combat_create_encounter", p_campaign=camp, p_name=f"Followup fight {RUN}", p_ruleset="2024")
    enc = r["encounter"]["id"]
    t.note(campaign=camp, encounter=enc)
    dm.rpc("combat_add_characters", p_encounter=enc, p_characters=[aria, brom, druid], p_options={})
    for c, m in ((aria, 3), (brom, -1), (druid, 1)):
        q(f"update public.combat_participants set initiative_mod = {m} where encounter_id = '{enc}' and linked_character_id = '{c}'")
    dm.rpc("combat_add_monsters", p_encounter=enc, p_source_kind="srd2024", p_source_id="srd52-goblin-warrior", p_options={"quantity": 3})
    dm.rpc("combat_add_monsters", p_encounter=enc, p_source_kind="srd2024", p_source_id="srd52-ogre", p_options={"quantity": 1})
    pa, pb, pd = (q(f"select id from public.combat_participants where encounter_id = '{enc}' and linked_character_id = '{c}'") for c in (aria, brom, druid))
    ga, gb, gc, og = pid(enc, "Goblin Warrior", "A"), pid(enc, "Goblin Warrior", "B"), pid(enc, "Goblin Warrior", "C"), pid(enc, "Ogre")

    with sync_playwright() as p:
        b = p.chromium.launch(channel="msedge", headless=True)
        D = Win(b, dm, width=1366, height=900)
        dp = D.page
        D2 = Win(b, dm, width=1024, height=800)
        D.go(f"#/combat/e/{enc}", ".cb-builder")
        D2.go(f"#/combat/e/{enc}", ".cb-builder")
        dp.wait_for_function("() => document.querySelectorAll('.cb-init-table tbody tr').length >= 7", timeout=15000)
        head = dp.locator(".cb-init-table thead").inner_text()
        check("I1 the column is labelled Final Initiative and the modifier is marked as reference", "final initiative" in head.lower() and "reference" in head.lower(), head)
        help_ = dp.locator("#cb-init-help").inner_text()
        check("I2 helper text: the total the player rolled, including all bonuses", "including all bonuses" in help_, help_)
        inp_a = dp.locator(f"[data-cb-init='{pa}']")
        check("I3 player input: accessible label, helper text linked, numeric keyboard",
              "Final Initiative" in (inp_a.get_attribute("aria-label") or "") and inp_a.get_attribute("aria-describedby") == "cb-init-help"
              and inp_a.get_attribute("inputmode") == "numeric", inp_a.get_attribute("aria-label"))
        check("I4 no Roll button on player rows (players dictate their total)", dp.locator(f"tr[data-pid='{pa}'] [data-cb=roll-one]").count() == 0
              and dp.locator(f"tr[data-pid='{pb}'] [data-cb=roll-one]").count() == 0)
        check("I5 the player's modifier is visible for reference (+3)", "+3" in dp.locator(f"tr[data-pid='{pa}'] .cb-mod-ref").inner_text())
        inp_a.fill("17")
        inp_a.press("Enter")
        ok = D.wait(lambda: ini(pa) == "17|player", 8000)
        check("I6 modifier +3, DM types 17: stored 17 (no modifier added)", ok, ini(pa))
        focused = lambda: dp.evaluate("() => document.activeElement?.dataset?.cbInit")
        check("I7 Enter moves to the next player still missing a value (Brom or Elara, by the current order)",
              D.wait(lambda: focused() in (pb, pd), 5000), focused())
        nxt = focused()
        dp.keyboard.type("8")
        dp.keyboard.press("Enter")
        check("I8 the next value typed is stored as typed (8)", D.wait(lambda: ini(nxt) == "8|player", 8000), ini(nxt))
        if nxt != pb:   # Brom: modifier -1, typed 8 -> 8
            b_in = dp.locator(f"[data-cb-init='{pb}']")
            b_in.fill("8")
            b_in.press("Tab")
            check("I8b modifier -1, DM types 8: stored 8", D.wait(lambda: ini(pb) == "8|player", 8000), ini(pb))
        check("I9 a second DM window sees the typed value (Realtime)", D2.wait(lambda: D2.page.locator(f"[data-cb-init='{pa}']").input_value() == "17", 12000))
        # monsters: Auto roll for the shared goblin group
        check("I10 monsters offer Auto roll / Manual total", dp.locator(f"[data-cb-imode='{ga}'] option").all_inner_texts() == ["Auto roll", "Manual total"])
        dp.locator(f"tr[data-pid='{gb}'] [data-cb=roll-one]").click()
        ok = D.wait(lambda: q(f"select count(distinct initiative) || '/' || count(*) filter (where initiative_mode = 'rolled') from public.combat_participants where id in ('{ga}', '{gb}', '{gc}')") == "1/3", 8000)
        check("I11 Roll on one goblin rolls the shared group once (all three equal, rolled)", ok)
        # Ogre: Manual total
        dp.locator(f"[data-cb-imode='{og}']").select_option("manual")
        dp.wait_for_selector(f"[data-cb-init='{og}']", timeout=5000)
        o = dp.locator(f"[data-cb-init='{og}']")
        o.fill("14")
        o.press("Enter")
        check("I12 manual monster total: Ogre 14, stored as typed", D.wait(lambda: ini(og) == "14|manual", 8000), ini(og))
        # the goblin group switched to Manual: one value for all
        dp.locator(f"[data-cb-imode='{ga}']").select_option("manual")
        dp.wait_for_selector(f"[data-cb-init='{gb}']", timeout=5000)
        g = dp.locator(f"[data-cb-init='{gb}']")
        g.fill("11")
        g.press("Tab")
        ok = D.wait(lambda: q(f"select string_agg(initiative::text || initiative_mode, ',') from public.combat_participants where id in ('{ga}', '{gb}', '{gc}')") == "11manual,11manual,11manual", 8000)
        check("I13 group manual total: typed for goblin B, all three get 11", ok,
              q(f"select string_agg(coalesce(initiative::text, 'null') || '/' || coalesce(initiative_mode, 'null'), ',') from public.combat_participants where id in ('{ga}', '{gb}', '{gc}')"))
        dp.locator(f"[data-cb-init='{pd}']").fill("5")
        dp.locator(f"[data-cb-init='{pd}']").press("Tab")
        D.wait(lambda: ini(pd).startswith("5|"), 8000)
        dp.reload()
        dp.wait_for_selector(".cb-builder", timeout=15000)
        dp.wait_for_timeout(800)
        check("I14 values survive a refresh (17, 8, 14 manual input shown)", dp.locator(f"[data-cb-init='{pa}']").input_value() == "17"
              and dp.locator(f"[data-cb-init='{pb}']").input_value() == "8" and dp.locator(f"[data-cb-init='{og}']").input_value() == "14")
        shot(dp, "initiative_1366")
        for w, h in ((390, 844), (360, 800)):
            dp.set_viewport_size({"width": w, "height": h})
            dp.wait_for_timeout(500)
            shot(dp, f"initiative_{w}")
            check(f"I15 no horizontal page scroll at {w}", D.overflow() <= 1, D.overflow())
            box = dp.locator(f"[data-cb-init='{pa}']").bounding_box()
            check(f"I16 the Final Initiative field is usable at {w} (>= 40 px tall, on screen)", box and box["height"] >= 40 and box["x"] + box["width"] <= w, box)
        dp.set_viewport_size({"width": 1366, "height": 900})
        dp.wait_for_timeout(300)

        # start, then a correction with a reason
        dp.locator("[data-cb=start]").click()
        dp.wait_for_timeout(1200)
        if dp.locator(".modal [data-ties]").count():
            dp.locator(".modal [data-ok]").click()
        dp.wait_for_selector(".cb-live", timeout=15000)
        dp.wait_for_timeout(600)
        dp.locator(f".cb-row[data-pid='{og}']").first.click()
        dp.wait_for_selector("[data-cb=correct-init]", timeout=8000)
        dp.locator("[data-cb=correct-init]").click()
        md = dp.locator(".modal")
        md.locator("[name=init]").fill("25")
        md.locator("[data-ok]").click()
        dp.wait_for_timeout(500)
        check("I17 a correction without a reason is refused in the dialog", ini(og) == "14|manual")
        md.locator("[name=reason]").fill("misheard the total")
        md.locator("[data-ok]").click()
        check("I18 correction after Start: 25 stored as typed, reason in the history", D.wait(lambda: ini(og) == "25|manual", 8000)
              and q(f"select count(*) from public.combat_events where encounter_id = '{enc}' and kind = 'initiative_changed' and details::text like '%misheard the total%'") == "1")

        # Wild Shape overflow in the tracker
        dp.locator(f".cb-row[data-pid='{pd}']").first.click()
        amt = dp.locator(f"[data-cb-amount='{pd}']")
        amt.wait_for(timeout=8000)
        check("W1 the detail panel shows the form and the protected normal HP", "Brown Bear" in dp.locator(".cb-form-note").inner_text()
              and "only the excess" in dp.locator(".cb-form-note").inner_text())
        amt.fill("21")
        prev = dp.locator("[data-cb-preview]").inner_text()
        check("W2 the preview says only the excess 1 reaches normal HP (30 -> 29)", "only the excess 1" in prev and "30 → 29" in prev, prev)
        amt.press("Enter")
        ok = D.wait(lambda: q(f"select hp_current from public.characters where id = '{druid}'") == "29", 8000)
        check("W3 20 HP form, 21 damage: the form ends, normal HP 30 -> 29", ok and q(f"select count(*) from public.character_transformations where character_id = '{druid}'") == "0",
              q(f"select hp_current from public.characters where id = '{druid}'"))
        check("W4 clear feedback: form ended, 1 excess damage applied", D.wait(lambda: "1 excess damage was applied" in D.toasts(), 5000), D.toasts())
        shot(dp, "ws_overflow")

        # ---------------------------------------------------------------------------------------------- Play options
        wl = pl.character(f"Wren {RUN}", [("warlock-phb", 5)], charisma=16)
        wrow = q(f"select id from public.character_classes where character_id = '{wl}' limit 1")
        st2, r2 = pl.rpc("set_character_feature_choice", p_character=wl, p_character_class=wrow, p_unlock="warlock-phb-u3-pact-boon",
                         p_choice="warlock-pact-boon-phb-pact", p_values=["pact-of-the-blade"], p_manual_status=None, p_allow_partial=True)
        st1, r1 = pl.rpc("set_character_feature_choice", p_character=wl, p_character_class=wrow, p_unlock="warlock-phb-u2-eldritch-invocations",
                         p_choice="warlock-eldritch-invocations-phb-invocations", p_values=["devils-sight", "eldritch-smite", "thirsting-blade"], p_manual_status=None, p_allow_partial=True)
        check("C0 fixture: invocations and pact boon chosen", st1 == 200 and st2 == 200, (st1, str(r1)[:200], st2, str(r2)[:200]))
        P = Win(b, pl, width=1366, height=900, tab="combat")
        P.open(wl)
        P.tab("combat")
        pp = P.page
        P.wait(lambda: pp.locator("[data-active-option]").count() >= 2, 15000)
        acts = pp.locator("#cg-action").locator("xpath=..").inner_text() if pp.locator("#cg-action").count() else ""
        check("C1 Pact of the Blade (an action) is in Play > Actions with its source", "Pact of the Blade" in acts and "Pact Boon" in acts, acts[:300])
        spec = pp.locator("#cg-special").locator("xpath=..").inner_text() if pp.locator("#cg-special").count() else ""
        check("C2 Thirsting Blade (changes the Attack action) is a special option, tagged as a reminder", "Thirsting Blade" in spec and "REMINDER" in spec.upper(), spec[:300])
        check("C3 Devil's Sight is under Passive and reminders, not an action", "Devil's Sight" in pp.locator(".passive-group").inner_text()
              and "Devil's Sight" not in acts)
        smite_cards = pp.locator("[data-active-option$=':eldritch-smite']").count()
        check("C4 Eldritch Smite is shown once (as the attack rider), not repeated as a card", smite_cards == 0 and "Eldritch Smite" in pp.locator("#feature-attacks").inner_text())
        shot(pp, "play_warlock")
        # Artificer infusion
        ar = pl.character(f"Tink {RUN}", [("artificer-tce", 2)], intelligence=16)
        arow = q(f"select id from public.character_classes where character_id = '{ar}' limit 1")
        pl.rpc("set_character_feature_choice", p_character=ar, p_character_class=arow, p_unlock="artificer-tce-u2-infuse-item",
               p_choice="artificer-infuse-item-tce-infusions", p_values=["enhanced-weapon", "enhanced-defense", "returning-weapon", "repeating-shot"], p_manual_status=None, p_allow_partial=True)
        inv = q(f"select id from public.inventories where character_id = '{ar}' and kind = 'character' limit 1")
        _, item = pl.rpc("add_inventory_item", p_inventory=inv, p_item="mace", p_quantity=1, p_custom_name=None, p_notes=None, p_state={})
        sti, ri = pl.rpc("apply_infusion", p_character=ar, p_infusion="enhanced-weapon", p_inventory_item=item, p_replicate_item=None)
        check("C5 fixture: Enhanced Weapon infused into a Mace", sti == 200, str(ri)[:200])
        P.open(ar)
        P.tab("combat")
        P.wait(lambda: pp.locator("[data-play-infusion]").count() == 1, 15000)
        txt = pp.locator("[data-play-infusions]").inner_text() if pp.locator("[data-play-infusions]").count() else ""
        check("C6 Play lists the infused item with its effect and source", "Enhanced Weapon" in txt and "on Mace" in txt and "+1 to attack" in txt, txt[:300])
        P.tab("inventory")
        check("C7 Inventory badge on the Mace: Infused: Enhanced Weapon", P.wait(lambda: "Infused: Enhanced Weapon" in " ".join(pp.locator(".inv-b-infused").all_inner_texts()), 15000))
        P.tab("spells")
        check("C8 no infusion or invocation is duplicated as a spell source", pp.locator("[data-option-spells]").count() == 0)

        # ---------------------------------------------------------------------------------------------- items
        mine = dm.character(f"Herbalist {RUN}", [("druid-phb", 2)])
        H = Win(b, dm, width=1366, height=900, tab="inventory")
        hp_ = H.page
        H.open(mine)
        H.tab("inventory")
        hp_.wait_for_selector("[data-inv=add-item]", timeout=15000)
        hp_.locator("[data-inv=add-item]").click()
        hp_.locator(".modal [data-create]").click()
        hb = hp_.locator(".modal .hb-form")
        hb.wait_for(timeout=8000)
        hb.locator("[name=kind_id]").select_option("herbs_plants")
        hb.locator("[name=name]").fill(f"Moonpetal {RUN}")
        hb.locator("[name=category_id]").select_option("plant-flower")
        check("T1 the Herbs & Plants section shows; weapon, armor and potion sections stay hidden",
              hb.locator(".hb-section[data-for=herbs_plants]").is_visible() and not hb.locator(".hb-section[data-for=weapon]").is_visible()
              and not hb.locator(".hb-section[data-for=potion]").is_visible())
        hb.locator("[name=environment]").fill("Moonlit meadows")
        hb.locator("input[name=plant_prop][value=medicinal]").check()
        hb.locator(".icon-opt", has=hp_.locator("input[value='plant.flower']")).click()
        hp_.locator(".modal [data-submit]").click()
        hp_.wait_for_timeout(1500)
        if hp_.locator(".modal [data-submit]").count() and "anyway" in hp_.locator(".modal [data-submit]").inner_text():
            hp_.locator(".modal [data-submit]").click()
        ok = H.wait(lambda: q(f"select kind_id || '|' || coalesce(icon_key, '') || '|' || (details ->> 'environment') from public.items where name = 'Moonpetal {RUN}'") == "herbs_plants|plant.flower|Moonlit meadows", 12000)
        check("T2 a herb with subtype, icon and environment is created (no armor / weapon / potion fields)", ok,
              q(f"select kind_id, icon_key, details from public.items where name = 'Moonpetal {RUN}'"))
        H.wait(lambda: hp_.locator(".inv-chip[data-filter=herbs]").count() == 1, 10000)
        check("T3 the Herbs & Plants filter appears with the herb", hp_.locator(".inv-chip[data-filter=herbs]").count() == 1)
        check("T4 the row uses the chosen icon (plant.flower), not the category default",
              H.wait(lambda: hp_.locator(".inv-item", has_text=f"Moonpetal {RUN}").locator("img[data-icon='plant.flower']").count() >= 1, 8000))
        shot(hp_, "herb_inventory")
        # delete from the picker: an unused herb goes, a used one is archived instead
        _, unused = dm.rpc("create_homebrew_item", p_request_id=str(uuid.uuid4()), p_definition={"name": f"Spare root {RUN}", "kind_id": "herbs_plants"}, p_stats={})
        hp_.locator("[data-inv=add-item]").click()
        pk = hp_.locator(".modal")
        pk.locator("input[name=search]").fill(f"Spare root {RUN}")
        H.wait(lambda: pk.locator(".inv-result").count() == 1, 8000)
        pk.locator(".inv-result [data-del]").click()
        dm2 = hp_.locator(".modal").last
        dm2.locator("[data-confirm-name]").wait_for(timeout=8000)
        check("T5 delete asks for the exact name (button disabled until it matches)", dm2.locator("[data-ok]").is_disabled())
        dm2.locator("[data-confirm-name]").fill(f"Spare root {RUN}")
        dm2.locator("[data-ok]").click()
        check("T6 an unused herb is deleted for good", H.wait(lambda: q(f"select count(*) from public.items where id = '{unused['id']}'") == "0", 8000))
        pk.locator("input[name=search]").fill(f"Moonpetal {RUN}")
        H.wait(lambda: pk.locator(".inv-result").count() == 1, 8000)
        pk.locator(".inv-result [data-del]").click()
        cd = hp_.locator(".modal").last
        cd.wait_for(timeout=8000)
        H.wait(lambda: "cannot be deleted" in cd.inner_text(), 6000)
        check("T7 a used herb cannot be deleted: archive is offered instead", "cannot be deleted" in cd.inner_text() and "Archive" in cd.inner_text(), cd.inner_text()[:200])
        check("T8 ... and it still exists", q(f"select count(*) from public.items where name = 'Moonpetal {RUN}'") == "1")
        errs = [e for e in D.errors + D2.errors + P.errors + H.errors if "Failed to load resource" not in e]
        check("Z1 no console errors", not errs, errs[:5])
        check("Z2 no request left this machine", not (D.remote + P.remote + H.remote), (D.remote + P.remote + H.remote)[:3])
        D.close(); D2.close(); P.close(); H.close(); b.close()


if __name__ == "__main__":
    with iso.Isolated("COMBINED-FOLLOWUP-UI") as t:
        run(t)
    report()
