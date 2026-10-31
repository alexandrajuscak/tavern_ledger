"""Gameplay polish, browser suite (docs/GAMEPLAY_POLISH_AUDIT.md). LOCAL ONLY, synthetic users inside isolation.

Covers: the corrected icons (Weapons no longer the site logo, Tools a lute, a new Illusion school icon; every registry asset
loads), the coin calculator (preview, spend with change, Realtime to a second session, Undo, insufficient funds, bad input,
keyboard, 390 px), the Hungry Jaws lineage counter on Play (source, Use, rest), Magic Initiate spells from a background on the
Spells tab, and the type-aware DM item editor (Tool / Weapon / Armor sections, validation messages).
Usage: APP_URL=... python gameplay_polish_ui_test.py   (run_browser_local.sh sets the environment)
"""
import json
import re
import uuid
from pathlib import Path

from playwright.sync_api import sync_playwright

import isolation as iso
from class_ui_common import APP, RUN, SHOTS, Sheet, User, call, check, report

HASH_JS = """async (path) => { const r = await fetch(path, { cache: 'no-store' }); if (!r.ok) return 'HTTP ' + r.status;
  const b = await r.arrayBuffer(); const d = await crypto.subtle.digest('SHA-256', b);
  return [...new Uint8Array(d)].slice(0, 8).map((x) => x.toString(16).padStart(2, '0')).join(''); }"""


def coin_inputs(page):
    return page.evaluate("() => Object.fromEntries(['cp','sp','ep','gp','pp'].map((k) => [k, document.querySelector(`.inv-coins [data-f=\"${k}\"]`)?.value]))")


def stored_coins(u, cid):
    _, rows = call("GET", f"/rest/v1/characters?id=eq.{cid}&select=cp,sp,ep,gp,pp", token=u.jwt)
    return rows[0]


def export_import(s, cid, new_name):
    """Export the character from the Bio tab, import it as a new character (Home -> Import file); returns (export, new id)."""
    page = s.page
    s.open(cid); s.tab("bio")
    with page.expect_download() as dl:
        page.locator("[data-action=export-json]").click()
    exported = json.loads(Path(dl.value.path()).read_text(encoding="utf-8"))
    exported["name"] = new_name
    SHOTS.mkdir(parents=True, exist_ok=True)
    f = SHOTS / f"gp_transfer_{RUN}_{cid[:8]}.json"
    f.write_text(json.dumps(exported), encoding="utf-8")
    page.goto(APP)
    page.click("#btn-import")
    page.set_input_files(".modal input[name=file]", str(f))
    page.locator(".modal button[type=submit]").click()
    page.wait_for_url(re.compile(r"#/c/"), timeout=30000)
    page.wait_for_timeout(2000)
    return exported, page.url.split("#/c/")[1].split("/")[0]


def run(t):
    pl, dm = User("gpolish"), User("gpolish-dm")
    hero = pl.character(f"GP Hero {RUN}", [("fighter-phb", 1)], dexterity=14, constitution=14)
    sage = pl.character(f"GP Sage {RUN}", [("fighter-phb", 1)], intelligence=14)
    call("PATCH", f"/rest/v1/characters?id=eq.{hero}", {"cp": 0, "sp": 0, "ep": 0, "gp": 1, "pp": 0}, token=pl.jwt)
    camp = str(uuid.uuid4())
    iso.psql(f"insert into public.campaigns (id, name, created_by) values ('{camp}', 'GP Polish Campaign {RUN}', '{dm.id}');"
             f"insert into public.campaign_members (campaign_id, user_id, role) values ('{camp}', '{dm.id}', 'dm');")
    t.note(characters=[hero, sage], campaign=camp)

    with sync_playwright() as p:
        b = p.chromium.launch(channel="msedge", headless=True)
        s = Sheet(b, pl, tab="inventory")
        page = s.page

        # ---- icons ------------------------------------------------------------------------------------------------------
        reg = page.evaluate("async () => { const m = await import('./js/icon-registry.js?v=17'); return m.ICON_REGISTRY || m.default || m.REGISTRY || null; }")
        if not reg:
            reg = page.evaluate("async () => { const m = await import('./js/icon-registry.js?v=17'); return Object.values(m).find((v) => v && typeof v === 'object' && v['item.weapons']) || null; }")
        assets = {k: v.get("asset") for k, v in (reg or {}).items()}
        h = {a: page.evaluate(HASH_JS, f"assets/icons/{a}.webp") for a in ["items/weapons", "items/tools", "classes/fighter", "spell-schools/illusion",
                                                                             "classes/rogue", "spell-schools/divination", "classes/artificer", "items/lute"]}
        check("IC1/IC4 Weapons resolves to its own asset, not the site logo (Fighter emblem)", assets.get("item.weapons") == "items/weapons"
              and h["items/weapons"] != h["classes/fighter"] and not h["items/weapons"].startswith("HTTP"), h)
        check("IC2/IC5 Tools resolves to the lute, distinct from Weapons and from the Artificer emblem",
              assets.get("item.tools") == "items/tools" and h["items/tools"] == h["items/lute"] and h["items/tools"] not in (h["items/weapons"], h["classes/artificer"]), h)
        check("IC3 the site logo is unchanged (classes/fighter)", page.locator("a.brand img.brand-mark").get_attribute("src").endswith("classes/fighter.webp"))
        check("IC6/IC9 Illusion resolves to the new asset, distinct from Rogue and Divination", assets.get("spell.school.illusion") == "spell-schools/illusion"
              and h["spell-schools/illusion"] not in (h["classes/rogue"], h["spell-schools/divination"]), h)
        missing = [a for a in sorted(set(assets.values())) if a and page.evaluate(HASH_JS, f"assets/icons/{a}.webp").startswith("HTTP")]
        check("IC11/IC18 every registry asset loads (no broken path)", reg and not missing, missing[:5])

        # ---- coin calculator ----------------------------------------------------------------------------------------------
        s.open(hero); s.tab("inventory")
        s.wait(lambda: page.locator('[data-action="coin-calc"]').count() == 1)
        page.locator('[data-action="coin-calc"]').click()
        dlg = page.locator(".modal").last
        dlg.locator("[data-coin-calc]").wait_for(timeout=10000)
        page.wait_for_timeout(200)
        check("C25 keyboard: the dialog opens with the focus in the GP field; every coin field has a label",
              page.evaluate("() => document.activeElement?.dataset?.coin") == "gp"
              and dlg.locator("[data-coin][aria-label]").count() == 5, page.evaluate("() => document.activeElement?.outerHTML?.slice(0, 80)"))
        dlg.locator('[data-coin="sp"]').fill("3"); dlg.locator('[data-coin="cp"]').fill("4")
        prev = dlg.locator("[data-coin-preview]").inner_text()
        check("C7/C27 preview: 1 gp - 3 sp 4 cp: takes 1 gp, gives back 6 sp 6 cp, afterwards 6 sp, 6 cp",
              "1 gp" in dlg.locator("[data-coin-removed]").inner_text() and "6 sp, 6 cp" in dlg.locator("[data-coin-added]").inner_text()
              and dlg.locator("[data-coin-after]").inner_text().startswith("6 sp, 6 cp"), prev)
        s2 = Sheet(b, pl, tab="inventory"); s2.open(hero); s2.tab("inventory")
        s2.wait(lambda: coin_inputs(s2.page)["gp"] == "1")
        dlg.locator("[data-coin-apply]").click()
        s.wait(lambda: coin_inputs(page)["sp"] == "6")
        check("C27b applied: the sheet shows the server's result; the database holds exactly the preview",
              coin_inputs(page) == {"cp": "6", "sp": "6", "ep": "0", "gp": "0", "pp": "0"}
              and stored_coins(pl, hero) == {"cp": 6, "sp": 6, "ep": 0, "gp": 0, "pp": 0}, (coin_inputs(page), stored_coins(pl, hero)))
        check("C23 Realtime: the second session shows the new coins without a reload", s2.wait(lambda: coin_inputs(s2.page)["sp"] == "6", 10000), coin_inputs(s2.page))
        dlg.locator("[data-coin-undo]").click()
        s.wait(lambda: coin_inputs(page)["gp"] == "1")
        check("C27c Undo restores the previous coins", stored_coins(pl, hero) == {"cp": 0, "sp": 0, "ep": 0, "gp": 1, "pp": 0}, stored_coins(pl, hero))
        dlg.locator('[data-coin="gp"]').fill("5")
        check("C10 insufficient funds: explained, Apply disabled", "Not enough coins" in dlg.locator("[data-coin-preview]").inner_text()
              and dlg.locator("[data-coin-apply]").is_disabled(), dlg.locator("[data-coin-preview]").inner_text())
        dlg.locator('[data-coin="gp"]').fill("1.5")
        check("C13 a decimal is refused before sending (whole coins only)", "whole coins only" in dlg.locator("[data-coin-preview]").inner_text()
              and dlg.locator("[data-coin-apply]").is_disabled())
        dlg.locator('[data-coin="gp"]').fill("")
        dlg.locator('input[name="coin-mode"][value="gain"]').check()
        dlg.locator('[data-coin="gp"]').fill("12"); dlg.locator('[data-coin="sp"]').fill("5")
        check("C4 gain preview adds the coins as entered", dlg.locator("[data-coin-after]").inner_text().startswith("13 gp, 5 sp"), dlg.locator("[data-coin-after]").inner_text())
        dlg.locator("[data-coin-apply]").dblclick()
        page.wait_for_timeout(1500)
        check("C16 a double click applies the gain once", stored_coins(pl, hero)["gp"] == 13, stored_coins(pl, hero))
        page.keyboard.press("Escape"); page.wait_for_timeout(300)
        # 390 px
        m = Sheet(b, pl, width=390, height=844, tab="inventory"); m.open(hero); m.tab("inventory")
        m.wait(lambda: m.page.locator('[data-action="coin-calc"]').count() == 1)
        m.page.locator('[data-action="coin-calc"]').click(); m.page.locator(".modal [data-coin-calc]").wait_for(timeout=10000)
        m.page.wait_for_timeout(500)   # the bottom sheet slides in (0.2 s transform): measure where it ends
        box = m.page.evaluate("() => { const r = document.querySelector('.modal [data-coin-apply]').getBoundingClientRect(); return [r.right, r.bottom, innerWidth, innerHeight]; }")
        check("C24 390 px: no horizontal overflow, Apply visible", not m.overflow() and box[0] <= box[2] and box[1] <= box[3], (m.overflow(), box))
        m.close(); s2.close()

        # ---- Hungry Jaws (lineage counter) -------------------------------------------------------------------------------
        st, r = pl.rpc("set_character_lineage", p_character=hero, p_version="lizardfolk-mpmm")
        check("L0 the player chooses Lizardfolk (MPMM)", st == 200, r)
        s.open(hero); s.tab("combat")
        jaws = page.locator('[data-cf-quick="r:' + iso.psql(f"select id from public.character_resources where character_id = '{hero}' and resource_key = 'lin-lizardfolk-mpmm-hungry-jaws'") + '"]')
        s.wait(lambda: jaws.count() > 0 or page.locator('.cf-res:has-text("Hungry Jaws")').count() > 0)
        card = page.locator('.cf-res:has-text("Hungry Jaws")').first
        quick = page.locator('.cf-quick:has-text("Hungry Jaws")').first
        check("L13/L14 Play shows Hungry Jaws in Ready to use, with 2 / 2 uses (proficiency bonus at level 1)",
              quick.count() > 0 and "2 / 2" in quick.inner_text(), quick.inner_text() if quick.count() else page.locator("#app").inner_text()[:300])
        if card.count():
            check("L19 the resource card names the source (Lineage: Lizardfolk) and the action", "Lineage: Lizardfolk" in card.inner_text()
                  and "Bonus action bite" in card.inner_text(), card.inner_text()[:300])
        quick.locator('[data-cf-action="res-use"]').click()
        s.wait(lambda: "1 / 2" in page.locator('.cf-quick:has-text("Hungry Jaws")').first.inner_text())
        check("L3 Use decrements once", iso.psql(f"select expended from public.character_resources where character_id = '{hero}' and resource_key = 'lin-lizardfolk-mpmm-hungry-jaws'") == "1")
        st, r = pl.rpc("long_rest_character", p_character=hero)
        s.wait(lambda: "2 / 2" in page.locator('.cf-quick:has-text("Hungry Jaws")').first.inner_text(), 10000)
        check("L6/L9 a long rest restores it and the open sheet updates (Realtime)", "2 / 2" in page.locator('.cf-quick:has-text("Hungry Jaws")').first.inner_text())

        # ---- Magic Initiate from a background ----------------------------------------------------------------------------
        st, r = pl.rpc("set_character_background", p_character=sage, p_version="sage-2024",
                       p_ability={"mode": "2024", "allocation": {"int": 2, "con": 1}})
        if st != 200:
            st, r = pl.rpc("set_character_background", p_character=sage, p_version="sage-2024")
        check("M0 the player chooses the Sage background", st == 200, r)
        cantrips = iso.psql("select string_agg(spell_version_id, ',') from (select e.spell_version_id from public.class_spell_list_entries e join public.spell_versions v on v.id = e.spell_version_id where e.list_id = 'wizard-spell-list' and v.level = 0 order by 1 limit 2) x").split(",")
        spell1 = iso.psql("select e.spell_version_id from public.class_spell_list_entries e join public.spell_versions v on v.id = e.spell_version_id where e.list_id = 'wizard-spell-list' and v.level = 1 order by 1 limit 1")
        st, r = pl.rpc("set_character_feat_choices", p_character=sage, p_grant_key="bg:sage-2024",
                       p_choices={"ability": ["int"], "cantrips": cantrips, "spell1": [spell1]})
        check("M5 the Magic Initiate choices save (background grant)", st == 200, r)
        names = iso.psql(f"select string_agg(name, '|' order by name) from public.spell_versions where id in ('{cantrips[0]}', '{cantrips[1]}', '{spell1}')").split("|")
        s.open(sage); s.tab("spells")
        s.wait(lambda: all(n in page.locator("#spellbook-list").inner_text() for n in names), 15000)
        txt = page.locator("#spellbook-list").inner_text()
        check("M6/M7/M27 the Spells tab lists both cantrips and the level-1 spell", all(n in txt for n in names), (names, txt[:300]))
        check("M8 the source is shown as Magic Initiate", "Magic Initiate" in page.locator(".sheet-root").inner_text())

        # ---- export / import: coins, the lineage counter's use, Magic Initiate choices and spells ------------------------
        pl.rpc("expend_character_resource", p_character=hero, p_resource_key="r:" + iso.psql(
            f"select id from public.character_resources where character_id = '{hero}' and resource_key = 'lin-lizardfolk-mpmm-hungry-jaws'"), p_amount=1, p_reason=None)
        before = stored_coins(pl, hero)
        exp, new_hero = export_import(s, hero, f"GP Hero imported {RUN}")
        check("C29 import keeps every coin exactly (no conversion)", stored_coins(pl, new_hero) == before, (before, stored_coins(pl, new_hero)))
        q = f"select max_formula::text || '|' || expended || '|' || active from public.character_resources where character_id = '%s' and resource_key = 'lin-lizardfolk-mpmm-hungry-jaws'"
        check("L12 import: one Hungry Jaws counter with the same use count (1 used)", iso.psql(q % new_hero) == iso.psql(q % hero)
              and iso.psql(q % new_hero).split("|")[1] == "1"
              and iso.psql(f"select count(*) from public.character_resources where character_id = '{new_hero}' and resource_key like 'lin-%'") == "1",
              (iso.psql(q % hero), iso.psql(q % new_hero)))
        exp2, new_sage = export_import(s, sage, f"GP Sage imported {RUN}")
        q2 = ("select coalesce(string_agg(cs.spell_version_id || ':' || cs.casting_ability, ',' order by cs.spell_version_id), '') from public.character_spells cs "
              "join public.character_spellcasting_sources src on src.id = cs.source_id where src.character_id = '%s' and src.feat_grant_key = 'bg:sage-2024'")
        check("M23 import: the Magic Initiate choices and its 3 spells (Intelligence) come back", iso.psql(q2 % new_sage) == iso.psql(q2 % sage)
              and len(iso.psql(q2 % new_sage).split(",")) == 3, (iso.psql(q2 % sage), iso.psql(q2 % new_sage)))

        # ---- DM item editor ----------------------------------------------------------------------------------------------
        D = Sheet(b, dm); d = D.page
        d.goto(APP + "#/dm/content")
        D.wait(lambda: d.locator("[data-dm-campaign]").count() > 0)
        d.select_option("[data-dm-campaign]", camp)
        D.wait(lambda: d.locator('[data-dm="new-content"][data-type="item"]').count() > 0)
        d.locator('[data-dm="new-content"][data-type="item"]').click()
        d.wait_for_selector(".modal [data-ce-form]")
        md = d.locator(".modal").last
        kinds = md.locator('[name="definition.item.kind_id"] option').evaluate_all("(o) => o.map((x) => x.value)")
        check("H0 the Type list offers only the homebrew types (no mount / vehicle)", "mount" not in kinds and "vehicle" not in kinds and "tool" in kinds, kinds)
        md.locator('[name="definition.item.kind_id"]').select_option("tool")
        vis = lambda k: md.locator(f'[data-ce-for="{k}"]').is_visible()
        check("H11 Tool: neither the Armor nor the Weapon section is shown", not vis("armor") and not vis("weapon"))
        md.locator("[name=name]").fill(f"GP Tinker Kit {RUN}")
        md.locator('[data-ce-act="validate"]').click()
        ok_v = D.wait(lambda: "Ready to publish" in " ".join(D.toasts()) or (md.locator(".ce-status").count() and "Ready" in md.locator(".ce-status").inner_text()), 10000)
        check("H3/H22 a tool without armor fields validates ('Ready to publish')", ok_v,
              (D.toasts(), md.locator(".gov-error").inner_text() if md.locator(".gov-error").count() else ''))
        md.locator('[name="definition.item.kind_id"]').select_option("armor")
        check("H13 Armor: the Armor section appears, Weapon stays hidden", vis("armor") and not vis("weapon"))
        md.locator('[name="definition.item.kind_id"]').select_option("weapon")
        check("H12 Weapon: the Weapon section appears, Armor is hidden", vis("weapon") and not vis("armor"))
        check("H22b required fields are marked", "Damage dice (required)" in md.inner_text())
        page.keyboard.press("Escape")
        D.close()

        check("C30/H23 no console errors", not [e for e in s.errors if "Failed to load resource" not in e], s.errors[:5])
        check("IC13 no request left this machine", not s.remote, s.remote[:3])
        s.close(); b.close()


if __name__ == "__main__":
    with iso.Isolated("GAMEPLAY-POLISH-UI") as t:
        run(t)
    report()
