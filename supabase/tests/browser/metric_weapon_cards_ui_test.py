"""Metric display and weapon cards (phase 2, frontend-only release ?v=32; Part 1 party identification is NOT in this build).
LOCAL ONLY, synthetic users. Adapted from ra_release_ui_test.py (checks RA4-RA14 + the converter unit tests).

1. Weapon cards (Play): an unidentified weapon in B's hand shows only its decoy; an ordinary weapon (dagger: properties, thrown
   range) and a magic campaign weapon (rarity, attunement, description); keyboard; a phone width has no horizontal scroll.
2. Metric toggle (A, Bio -> Display): the speed, an inventory weight and a spell range switch to metric and back; the choice
   survives a reload and works on ?fluent=0; inputs stay US.
3. The converter unit tests (supabase/tests/js/units.test.mjs) run in the page.
Usage: APP_URL=... python metric_weapon_cards_ui_test.py   (run_browser_local.sh sets the environment)
"""
import uuid

from playwright.sync_api import sync_playwright

import isolation as iso
from class_ui_common import APP, RUN, Sheet, User, call, check, report

q = iso.psql
BLADE, BLADE_DESC = f"Starfang {RUN}", f"A blade of falling starlight {RUN}"
EDGE, EDGE_DESC = f"Shadow Edge {RUN}", f"Drinks the light {RUN}"


def homebrew(dm, camp, name, kind, desc, extra=None, stats=None):
    d = {"name": name, "kind_id": kind, "campaign_id": camp, "description": desc}
    d.update(extra or {})
    st, it = dm.rpc("create_homebrew_item", p_request_id=str(uuid.uuid4()), p_definition=d, p_stats=stats or {})
    assert st == 200, (st, it)
    return it["id"]


def inv(user, cid):
    _, rows = call("GET", f"/rest/v1/inventories?character_id=eq.{cid}&kind=eq.character&select=id", token=user.jwt)
    return rows[0]["id"]


def run():
    dm, pa, pb = User("mwdm"), User("mwpa"), User("mwpb")
    camp = str(uuid.uuid4())
    q(f"insert into public.campaigns (id, name, created_by) values ('{camp}', 'MW Table {RUN}', '{dm.id}');"
      f"insert into public.campaign_members (campaign_id, user_id, role) values ('{camp}', '{dm.id}', 'dm'), ('{camp}', '{pa.id}', 'player'), ('{camp}', '{pb.id}', 'player');"
      f"insert into public.campaign_governance (campaign_id, preset) values ('{camp}', 'relaxed');")
    cha = pa.character(f"MW Alpha {RUN}", [("wizard-phb", 1)], dexterity=16)
    chb = pb.character(f"MW Beta {RUN}", [("fighter-phb", 1)], strength=16)
    q(f"update public.characters set campaign_id = '{camp}' where id in ('{cha}', '{chb}');"
      f"insert into public.character_governance (character_id, setup_complete) values ('{cha}', true), ('{chb}', true);")
    # weapons: A dagger (ordinary) + a magic campaign blade; B a campaign weapon that the DM hides after it is equipped
    blade = homebrew(dm, camp, BLADE, "weapon", BLADE_DESC, {"category_id": "martial-melee", "weight_lb": 3, "is_magic": True,
                     "rarity_id": "rare", "requires_attunement": True},
                     {"weapon": {"weapon_group": "martial", "damage_dice": "1d8", "damage_type_id": "radiant", "properties": ["finesse"]}})
    edge = homebrew(dm, camp, EDGE, "weapon", EDGE_DESC, {"category_id": "martial-melee", "weight_lb": 3},
                    {"weapon": {"weapon_group": "martial", "damage_dice": "1d6", "damage_type_id": "necrotic", "properties": ["light"]}})
    assert dm.rpc("set_item_identify_options", p_item=edge, p_options={"unidentified_name": "Rusty knife", "unidentified_description": "Plain and pitted."})[0] == 200
    ia, ib = inv(pa, cha), inv(pb, chb)
    st, dg = pa.rpc("add_inventory_item", p_inventory=ia, p_item="dagger", p_quantity=1, p_custom_name=None, p_notes=None, p_state=None)
    assert st == 200, dg
    assert pa.rpc("equip_item", p_item=dg, p_slot="off_hand", p_replace=True)[0] == 200
    assert dm.rpc("dm_give_item", p_item=blade, p_characters=[cha], p_quantity=1, p_identified=True)[0] == 200
    _, rows = call("GET", f"/rest/v1/inventory_items?inventory_id=eq.{ia}&item_id=eq.{blade}&select=id", token=pa.jwt)
    assert pa.rpc("equip_item", p_item=rows[0]["id"], p_slot="main_hand", p_replace=True)[0] == 200
    assert dm.rpc("dm_give_item", p_item=edge, p_characters=[chb], p_quantity=1, p_identified=True)[0] == 200
    _, rows = call("GET", f"/rest/v1/inventory_items?inventory_id=eq.{ib}&item_id=eq.{edge}&select=id", token=pb.jwt)
    assert pb.rpc("equip_item", p_item=rows[0]["id"], p_slot="main_hand", p_replace=True)[0] == 200
    st, r = dm.rpc("dm_set_item_knowledge", p_item=edge, p_characters=[chb], p_reveal=[], p_mode="set", p_campaign=camp)
    assert st == 200, r
    # a spell with a range for the metric check (Fire Bolt: 120 feet)
    _, rows = call("GET", f"/rest/v1/character_spellcasting_sources?character_id=eq.{cha}&select=id", token=pa.jwt)
    assert pa.rpc("set_character_spell", p_character=cha, p_source=rows[0]["id"], p_spell_version="fire-bolt-phb", p_known=True, p_prepared=False,
                  p_always_prepared=False, p_casting_ability=None, p_ritual_allowed=None, p_notes=None)[0] == 200

    with sync_playwright() as p:
        br = p.chromium.launch(channel="msedge", headless=True)
        # ---- 1a. the unidentified weapon in B's hand ------------------------------------------------------------------------------
        B = Sheet(br, pb, tab="combat")
        bp = B.page
        B.open(chb)
        B.tab("combat")
        card = bp.locator(".wpn-card.wpn-unknown")
        B.wait(lambda: card.count() > 0)
        txt = bp.locator("#equipped-weapons").inner_text() if bp.locator("#equipped-weapons").count() else ""
        check("RA4 B's hidden weapon: a card with the decoy only (no true name, no description, no numbers)",
              card.count() == 1 and "Rusty knife" in txt and EDGE not in bp.content() and EDGE_DESC not in bp.content()
              and card.locator("[data-attack-bonus]").count() == 0, txt[:300])
        B.close()

        # ---- 3. weapon cards for A --------------------------------------------------------------------------------------------
        A = Sheet(br, pa, tab="inventory")
        ap = A.page
        A.open(cha)
        A.wait(lambda: BLADE in ap.locator("#panel-inventory").inner_text())
        A.tab("combat")
        mag = ap.locator(".derived-weapon", has_text=BLADE)
        dag = ap.locator(".derived-weapon", has_text="Dagger")
        A.wait(lambda: mag.count() == 1 and "Rare" in mag.inner_text())
        mt, dt = (mag.inner_text() if mag.count() else ""), (dag.inner_text() if dag.count() else "")
        check("RA5 magic weapon card: icon, rarity, attunement, damage type, finesse, description, To hit / Damage, one breakdown",
              mag.locator("img.wpn-icon").count() == 1 and "Rare" in mt and "Needs attunement" in mt and "Radiant" in mt and "Finesse" in mt
              and BLADE_DESC in mt and mag.locator("[data-attack-bonus]").count() == 1 and mag.locator("summary").count() == 1
              and mag.get_attribute("data-rarity") == "rare", mt[:400])
        check("RA6 ordinary weapon card (dagger): properties and thrown range, no rarity tag",
              "Finesse" in dt and "Light" in dt and "Thrown" in dt and "Range 20 ft / 60 ft" in dt and dag.locator("[data-wpn-rarity]").count() == 0, dt[:300])
        mag.locator("summary").focus()
        ap.keyboard.press("Enter")
        check("RA7 keyboard: Enter on the breakdown opens it", mag.locator("details").evaluate("d => d.open"))
        ap.set_viewport_size({"width": 375, "height": 800})
        ap.wait_for_timeout(400)
        check("RA8 phone width (375 px): no horizontal scroll on Play", A.overflow() <= 0, A.overflow())
        ap.set_viewport_size({"width": 1366, "height": 900})

        # ---- 2. metric toggle ---------------------------------------------------------------------------------------------------
        speed = lambda: ap.locator('.tile-speed').first.inner_text().replace("\n", " ")
        us_speed = speed()
        A.tab("bio")
        ap.locator('[data-units-switch] [data-units="metric"]').click()
        ap.wait_for_timeout(300)
        m_speed = speed()
        A.tab("combat")
        m_range = dag.inner_text()
        A.tab("inventory")
        m_inv = ap.locator("#panel-inventory").inner_text()
        A.tab("spells")
        A.wait(lambda: "Fire Bolt" in ap.locator("#panel-spells").inner_text())
        m_spell = ap.locator("#panel-spells").inner_text()
        check("RA9 Metric: speed 30 ft -> 9 m, dagger range 6 m / 18 m, inventory weights in kg, Fire Bolt 120 feet -> 36 meters",
              "30" in us_speed and "ft" in us_speed and "9" in m_speed and " m" in m_speed and "ft" not in m_speed
              and "Range 6 m / 18 m" in m_range and " kg" in m_inv and "36 meters" in m_spell and "120 feet" not in m_spell,
              (us_speed, m_speed, m_range[:200], m_inv[:200], m_spell[:300]))
        A.tab("combat")
        base = ap.locator('input[aria-label="Base walking speed in feet"]')
        check("RA10 inputs stay US under Metric (base walking speed field keeps 30)", base.count() == 0 or base.first.input_value() == "30",
              base.first.input_value() if base.count() else "")
        ap.goto(f"{APP}?fluent=0#/c/{cha}")
        A.wait(lambda: ap.locator(".tab").count() > 0)
        A.wait(lambda: " m" in speed())
        check("RA11 the choice survives a reload and works on ?fluent=0", " m" in speed() and "ft" not in speed(), speed())
        A.tab("bio")
        ap.locator('[data-units-switch] [data-units="us"]').click()
        ap.wait_for_timeout(300)
        A.tab("spells")
        A.wait(lambda: "Fire Bolt" in ap.locator("#panel-spells").inner_text())
        check("RA12 back to US: speed 30 ft and Fire Bolt 120 feet again", "30" in speed() and "ft" in speed()
              and "120 feet" in ap.locator("#panel-spells").inner_text(), (speed(), ap.locator("#panel-spells").inner_text()[:200]))

        # ---- 4. converter unit tests in the page ----------------------------------------------------------------------------------
        r = ap.evaluate("() => import('/supabase/tests/js/units.test.mjs').then((m) => m.run()).catch((e) => ({ error: e.message }))")
        check(f"RA13 converter unit tests: {r.get('passed')} passed, {r.get('failed')} failed", r.get("failed") == 0 and r.get("passed", 0) >= 40, r)
        errs = [e for e in A.errors if "favicon" not in e]
        check("RA14 no page errors on A's sheet", not errs, errs[:3])
        A.close()
        br.close()
    report()


if __name__ == "__main__":
    run()
