"""T7 weapon cards like spell cards (?v=40, frontend only). LOCAL ONLY, synthetic users.

One player with several characters (two hand slots each): longsword + dagger, longbow, musket, a campaign homebrew weapon with
the author's gallery icon (item.wand) + javelin, and two campaign weapons the DM made unidentified after they were equipped (a ranged
"Starbow" whose true icon would be the arrows, and a melee "Shadow Edge"). Checks per-weapon icons, reach / range, the name
opening the details dialog, no true icon / name for the masked copies, no console errors, ?fluent=0, and the icon unit tests
(supabase/tests/js/weapon_icons.test.mjs) plus a masked-row render of weaponCardHTML in the page.
Usage: APP_URL=... API_URL=... ANON_KEY=... SERVICE_ROLE_KEY=... python weapon_cards_t7_ui_test.py
Screenshots go to SCREENSHOT_DIR (docs/night/T7_screens, untracked).
"""
import uuid

from playwright.sync_api import sync_playwright

import isolation as iso
from class_ui_common import APP, RUN, SHOTS, Sheet, User, call, check, report

q = iso.psql
HB, HB_DESC = f"Moonstaff {RUN}", f"A staff that hums at night {RUN}"
EDGE = f"Shadow Edge {RUN}"
BOW = f"Starbow {RUN}"


def homebrew(dm, camp, name, kind, desc, extra=None, stats=None):
    d = {"name": name, "kind_id": kind, "campaign_id": camp, "description": desc}
    d.update(extra or {})
    st, it = dm.rpc("create_homebrew_item", p_request_id=str(uuid.uuid4()), p_definition=d, p_stats=stats or {})
    assert st == 200, (st, it)
    return it["id"]


def inv(user, cid):
    _, rows = call("GET", f"/rest/v1/inventories?character_id=eq.{cid}&kind=eq.character&select=id", token=user.jwt)
    return rows[0]["id"]


def add_equip(user, ia, item, slot):
    st, row = user.rpc("add_inventory_item", p_inventory=ia, p_item=item, p_quantity=1, p_custom_name=None, p_notes=None, p_state=None)
    assert st == 200, (item, st, row)
    st, r = user.rpc("equip_item", p_item=row, p_slot=slot, p_replace=True)
    assert st == 200, (item, slot, st, r)
    return row


def give_equip(dm, user, ia, cid, item, slot):
    assert dm.rpc("dm_give_item", p_item=item, p_characters=[cid], p_quantity=1, p_identified=True)[0] == 200
    _, rows = call("GET", f"/rest/v1/inventory_items?inventory_id=eq.{ia}&item_id=eq.{item}&select=id", token=user.jwt)
    st, r = user.rpc("equip_item", p_item=rows[0]["id"], p_slot=slot, p_replace=True)
    assert st == 200, (item, st, r)
    return rows[0]["id"]


def run():
    SHOTS.mkdir(parents=True, exist_ok=True)
    dm, pa = User("t7dm"), User("t7pa")
    camp = str(uuid.uuid4())
    q(f"insert into public.campaigns (id, name, created_by) values ('{camp}', 'T7 Table {RUN}', '{dm.id}');"
      f"insert into public.campaign_members (campaign_id, user_id, role) values ('{camp}', '{dm.id}', 'dm'), ('{camp}', '{pa.id}', 'player');"
      f"insert into public.campaign_governance (campaign_id, preset) values ('{camp}', 'relaxed');")
    chars = {k: pa.character(f"T7 {k} {RUN}", [("fighter-phb", 1)], strength=16, dexterity=14) for k in ("swords", "bow", "gun", "brew", "masked")}
    ids = ",".join(f"'{c}'" for c in chars.values())
    q(f"update public.characters set campaign_id = '{camp}' where id in ({ids});"
      f"insert into public.character_governance (character_id, setup_complete) select id, true from public.characters where id in ({ids});")
    inv_ = {k: inv(pa, c) for k, c in chars.items()}
    add_equip(pa, inv_["swords"], "longsword", "main_hand")
    add_equip(pa, inv_["swords"], "dagger", "off_hand")
    add_equip(pa, inv_["bow"], "longbow", "main_hand")
    add_equip(pa, inv_["gun"], "musket", "main_hand")
    brew = homebrew(dm, camp, HB, "weapon", HB_DESC, {"category_id": "simple-melee", "weight_lb": 4, "icon_key": "item.wand"},
                    {"weapon": {"weapon_group": "simple", "damage_dice": "1d6", "damage_type_id": "bludgeoning", "properties": ["versatile"], "versatile_damage": "1d8"}})
    give_equip(dm, pa, inv_["brew"], chars["brew"], brew, "main_hand")
    add_equip(pa, inv_["brew"], "javelin", "off_hand")
    # masked copies (official items cannot be hidden: campaign homebrew only): a ranged "Starbow" whose true icon would be the
    # arrows, and a melee "Shadow Edge"; both made unidentified by the DM after they are equipped
    bow = homebrew(dm, camp, BOW, "weapon", "Strung with moonlight", {"category_id": "martial-ranged", "weight_lb": 2, "is_magic": True, "rarity_id": "rare"},
                   {"weapon": {"weapon_group": "martial", "damage_dice": "1d8", "damage_type_id": "piercing", "is_ranged": True,
                               "range_normal": 150, "range_max": 600, "properties": ["ammunition"]}})
    assert dm.rpc("set_item_identify_options", p_item=bow, p_options={"unidentified_name": "Bent stick", "unidentified_description": "Probably firewood."})[0] == 200
    give_equip(dm, pa, inv_["masked"], chars["masked"], bow, "main_hand")
    assert dm.rpc("dm_set_item_knowledge", p_item=bow, p_characters=[chars["masked"]], p_reveal=[], p_mode="set", p_campaign=camp)[0] == 200
    edge = homebrew(dm, camp, EDGE, "weapon", "Drinks the light", {"category_id": "martial-melee", "weight_lb": 3},
                    {"weapon": {"weapon_group": "martial", "damage_dice": "1d6", "damage_type_id": "necrotic", "properties": ["light"]}})
    assert dm.rpc("set_item_identify_options", p_item=edge, p_options={"unidentified_name": "Rusty knife", "unidentified_description": "Plain and pitted."})[0] == 200
    give_equip(dm, pa, inv_["masked"], chars["masked"], edge, "off_hand")
    assert dm.rpc("dm_set_item_knowledge", p_item=edge, p_characters=[chars["masked"]], p_reveal=[], p_mode="set", p_campaign=camp)[0] == 200
    _, drv = pa.rpc("get_character_derived_stats", p_character=chars["masked"])
    masked_rows = [w for w in (drv or {}).get("equipped_weapon_attacks", []) if w.get("item_id") is None]
    print("masked rows in derived:", [(w.get("name"), w.get("is_ranged")) for w in masked_rows])

    with sync_playwright() as p:
        br = p.chromium.launch(channel="msedge", headless=True)
        A = Sheet(br, pa, tab="combat")
        ap = A.page

        def cards(cid, shot, n=1):
            A.open(cid)
            A.tab("combat")
            A.wait(lambda: ap.locator("#equipped-weapons .wpn-card").count() >= n)
            ap.wait_for_timeout(600)
            ap.locator("#equipped-weapons").screenshot(path=str(SHOTS / f"{shot}.png"))
            return ap.locator("#equipped-weapons")

        def icon_of(box, text):
            c = box.locator(".wpn-card", has_text=text)
            return c.locator("img.wpn-icon").first.get_attribute("data-icon") if c.count() else None

        box = cards(chars["swords"], "t7_swords", 2)
        ls, dg = box.locator(".wpn-card", has_text="Longsword"), box.locator(".wpn-card", has_text="Dagger")
        check("T1 longsword: sword icon, reach 5 ft, versatile, To hit + damage", icon_of(box, "Longsword") == "slot.main-hand"
              and "Reach 5 ft" in ls.inner_text() and "Versatile (1d10)" in ls.inner_text() and ls.locator("[data-attack-bonus]").count() == 1
              and ls.locator("summary").count() == 1, (icon_of(box, "Longsword"), ls.inner_text()[:300]))
        check("T2 dagger: dagger icon, finesse / light / thrown, reach + thrown range", icon_of(box, "Dagger") == "slot.off-hand"
              and all(x in dg.inner_text() for x in ("Finesse", "Light", "Thrown", "Reach 5 ft", "Range 20 ft / 60 ft")), dg.inner_text()[:300])
        ls.locator("[data-action=weapon-detail]").click()
        ap.wait_for_selector(".modal [data-wpn-detail]", timeout=5000)
        mt = ap.locator(".modal").inner_text()
        ap.locator(".modal").screenshot(path=str(SHOTS / "t7_detail_longsword.png"))
        check("T3 name opens the details dialog (properties explained, reach, two-handed dice)", "Longsword" in mt and "Two-handed" in mt
              and "1d10" in mt and "One or two hands" in mt and "Reach" in mt, mt[:400])
        ap.locator(".modal [data-close]").first.click()
        ap.wait_for_timeout(300)

        box = cards(chars["bow"], "t7_longbow")
        bt = box.locator(".wpn-card", has_text="Longbow").inner_text()
        check("T4 longbow: arrows icon, range 150 / 600, no melee reach", icon_of(box, "Longbow") == "item.ammunition"
              and "Range 150 ft / 600 ft" in bt and "Reach 5 ft" not in bt, bt[:300])
        box = cards(chars["gun"], "t7_musket")
        check("T5 musket: firearm icon, two-handed, range", icon_of(box, "Musket") == "item.firearm" and "Two-handed" in box.inner_text()
              and "Range 120 ft / 480 ft" in box.inner_text(), (icon_of(box, "Musket"), box.inner_text()[:300]))
        # the homebrew weapon's gallery key comes from the catalog detail the Inventory panel loads
        A.open(chars["brew"])
        A.tab("inventory")
        A.wait(lambda: HB in ap.locator("#panel-inventory").inner_text())
        A.tab("combat")
        A.wait(lambda: icon_of(ap.locator("#equipped-weapons"), HB) == "item.wand")
        ap.locator("#equipped-weapons").screenshot(path=str(SHOTS / "t7_homebrew_icon.png"))
        box = ap.locator("#equipped-weapons")
        check("T6 homebrew weapon: the author's gallery icon (item.wand) beats the category icon; javelin: spear icon + thrown range",
              icon_of(box, HB) == "item.wand" and icon_of(box, "Javelin") == "spell.damage.piercing"
              and "Range 30 ft / 120 ft" in box.locator(".wpn-card", has_text="Javelin").inner_text(), (icon_of(box, HB), icon_of(box, "Javelin")))

        # masked copies: open Inventory first so the masked view (known:false) is loaded, then Play
        A.open(chars["masked"])
        A.tab("inventory")
        A.wait(lambda: "Rusty knife" in ap.locator("#panel-inventory").inner_text())
        A.tab("combat")
        A.wait(lambda: ap.locator("#equipped-weapons .wpn-card").count() >= 2)
        ap.wait_for_timeout(600)
        box = ap.locator("#equipped-weapons")
        box.screenshot(path=str(SHOTS / "t7_masked.png"))
        html = ap.content()
        icons = box.locator("img.wpn-icon").evaluate_all("els => els.map((e) => e.dataset.icon)")
        check("T7 masked copies: no true icon (arrows) / name / magic tag, decoy name shown", "item.ammunition" not in icons and EDGE not in html and BOW not in html and "Bent stick" in box.inner_text()
              and "Rusty knife" in box.inner_text() and box.locator("[data-wpn-magic]").count() == 0, (icons, box.inner_text()[:400]))
        if masked_rows:
            mc = box.locator(".wpn-card.derived-weapon").first
            mc.locator("[data-action=weapon-detail]").click()
            ap.wait_for_selector(".modal [data-wpn-detail]", timeout=5000)
            dt = ap.locator(".modal").inner_text()
            dicons = ap.locator(".modal img.wpn-icon").evaluate_all("els => els.map((e) => e.dataset.icon)")
            check("T8 masked copy's dialog: decoy icon, not-identified note", "item.ammunition" not in dicons and "haven’t identified" in dt, (dicons, dt[:300]))
            ap.locator(".modal [data-close]").first.click()

        # in-page: the icon unit tests + weaponCardHTML on a synthetic masked row with a +2 item bonus
        r = ap.evaluate("() => import('/supabase/tests/js/weapon_icons.test.mjs').then((m) => m.run()).catch((e) => ({ error: e.message }))")
        check(f"T9 icon unit tests: {r.get('total')} cases, fails {r.get('fails')}", not r.get("error") and not r.get("fails") and r.get("total", 0) >= 15, r)
        r = ap.evaluate("""() => import('/js/weapon-card.js?v=40').then((m) => {
          const w = { inventory_item_id: 'x', item_id: null, name: 'Longbow', slot_id: 'main_hand', weapon_group: 'martial', is_ranged: true,
            properties: ['ammunition', 'heavy', 'two-handed'], range_normal: 150, range_max: 600, ability: 'dex', ability_modifier: 2,
            proficient: true, proficiency_bonus: 2, attack_bonus: 6, damage: '1d8 + 4', damage_dice: '1d8', damage_type: 'piercing',
            attack_breakdown: [{ effect: 'attack_bonus', source_id: 'x', source_name: 'Secret', value: 2 }],
            damage_breakdown: [{ effect: 'damage_bonus', source_id: 'x', source_name: 'Secret', value: 2 }] };
          const decoy = { known: false, state: 'unidentified', name: 'Old stick', icon: 'item.gear', iconKey: 'item.wand', iconSrc: 'https://evil/x.png' };
          const h = m.weaponCardHTML(w, decoy);
          const k = m.weaponCardHTML({ ...w, item_id: 'longbow' }, { known: true, name: 'Longbow', icon: 'inventory.weapon' });
          return { masked: /data-icon="item.gear"/.test(h) && !/item.ammunition|item.wand|evil|data-wpn-magic/.test(h),
                   known: /data-icon="item.ammunition"/.test(k) && /data-wpn-magic/.test(k) && /Magic \\+2/.test(k) };
        })""")
        check("T10 weaponCardHTML: masked row -> decoy icon only, no gallery key / upload / magic tag; known row -> map icon + Magic +2", r.get("masked") and r.get("known"), r)

        ap.goto(f"{APP}?fluent=0#/c/{chars['swords']}")
        A.wait(lambda: ap.locator(".tab").count() > 0)
        A.tab("combat")
        A.wait(lambda: ap.locator("#equipped-weapons .wpn-card").count() >= 2)
        check("T11 ?fluent=0 renders the Actions weapon cards with icons", ap.locator("#equipped-weapons img.wpn-icon").count() >= 2
              and icon_of(ap.locator("#equipped-weapons"), "Longsword") == "slot.main-hand")
        ap.locator("#equipped-weapons").screenshot(path=str(SHOTS / "t7_fluent0.png"))
        ap.set_viewport_size({"width": 375, "height": 800})
        ap.wait_for_timeout(400)
        check("T12 phone width (375 px): no horizontal scroll on Play", A.overflow() <= 0, A.overflow())
        ap.screenshot(path=str(SHOTS / "t7_phone.png"), full_page=False)
        errs = [e for e in A.errors if "favicon" not in e]
        check("T13 no console / page errors", not errs, errs[:3])
        A.close()
        br.close()
    report()


if __name__ == "__main__":
    run()
