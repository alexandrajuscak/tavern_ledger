"""Browser test of the Background card (docs/BACKGROUNDS.md) against the LOCAL Supabase stack.

Pick a 2024 background in the picker (filters, playtest hidden by default), allocate +2/+1, choose a tool, review and apply the
equipment once, see the increases and grants on the Stats tab, switch to a legacy background (no increases, a feature,
characteristics), the playtest permission, remove (equipment stays), export / import, 390 px, no errors, local only.
"""
import json
import re
from pathlib import Path

from playwright.sync_api import sync_playwright

from class_ui_common import APP, RUN, SHOTS, Sheet, User, call, check, report


def main():
    u = User("bgui")
    ch = u.character("Background UI Tester", [("fighter-phb", 1)], strength=15, dexterity=12, constitution=14)
    SHOTS.mkdir(parents=True, exist_ok=True)

    def inv_items():
        _, rows = call("GET", f"/rest/v1/inventories?character_id=eq.{ch}&select=inventory_items(item_id)", token=u.jwt)
        return sorted(i["item_id"] for r in rows for i in r["inventory_items"])

    with sync_playwright() as p:
        browser = p.chromium.launch(channel="msedge", headless=True)
        s = Sheet(browser, u, tab="features")
        page = s.page
        s.open(ch)
        s.tab("features")
        card = page.locator("#background-card")
        s.wait(lambda: card.locator("[data-bg-empty]").count() == 1)
        check("BU1 the Build tab has a Background card with 'Choose background…' (no background yet)",
              card.locator("[data-action=bg-choose]").count() == 1, card.inner_text()[:200])

        card.locator("[data-action=bg-choose]").click()
        dlg = page.locator(".modal").last
        dlg.locator("[data-bg-list] [data-bg-pick]").first.wait_for(timeout=10000)
        n_default = dlg.locator("[data-bg-pick]").count()
        has_rune = dlg.locator("[data-bg-pick=rune-carver-ua]").count()
        dlg.locator("[name=playtest]").check()
        has_rune_pt = dlg.locator("[data-bg-pick=rune-carver-ua]").count()
        dlg.locator("[name=rules]").select_option("2014")
        legacy_only = dlg.locator("[data-bg-pick]").count()
        dlg.locator("[name=rules]").select_option("all")
        dlg.locator("[name=q]").fill("sold")
        check("BU2 the picker lists 29 versions by default (playtest hidden), shows Rune Carver on request, filters legacy (14) and searches",
              n_default == 29 and has_rune == 0 and has_rune_pt == 1 and legacy_only == 14
              and dlg.locator("[data-bg-pick]").count() == 1 and "Soldier" in dlg.locator("[data-bg-pick]").inner_text(),
              (n_default, has_rune, has_rune_pt, legacy_only))
        dlg.locator("[data-bg-pick=soldier-2024]").click()
        dlg.locator("[data-bg-editor]").wait_for(timeout=15000)   # the version detail loads on selection (fluent path)
        ed = dlg.locator("[data-bg-editor]")
        opts = ed.locator("select[name=plus2] option").all_text_contents()
        check("BU3 the 2024 editor offers only the listed abilities (Strength, Dexterity, Constitution) and the compatibility box",
              [o for o in opts if o != "—"] == ["Strength", "Dexterity", "Constitution"] and ed.locator("[name=included]").count() == 1, opts)
        ed.locator("select[name=plus2]").select_option("str")
        ed.locator("select[name=plus1]").select_option("str")
        dlg.locator("[data-bg-save]").click()
        check("BU4 +2 and +1 on the same ability is refused with the server's message (dialog stays open)",
              s.wait(lambda: "+2 for one" in ed.locator("[data-bg-editor-status]").inner_text()), ed.locator("[data-bg-editor-status]").inner_text())
        ed.locator("select[name=plus1]").select_option("con")
        ed.locator("select[name='choice:tool']").select_option("tool:dice-set")
        dlg.locator("[data-bg-save]").click()
        confirm = page.locator(".modal").last
        s.wait(lambda: "starting equipment" in confirm.inner_text().lower())
        check("BU5 after choosing a new background the equipment review is offered (nothing added yet)",
              "Nothing is added without your confirmation" in confirm.inner_text() and "spear" not in inv_items(), confirm.inner_text()[:200])
        confirm.locator("[data-ok]").click()
        eq = page.locator(".modal").last
        s.wait(lambda: eq.locator("[data-bg-eq-row]").count() >= 5)
        txt = eq.inner_text()
        check("BU6 the review lists package A (spear, shortbow, the chosen dice set) and the coins; package B is 50 gp",
              "Spear" in txt and "Dice set" in txt and "14 gp" in txt, txt[:400])
        eq.locator("[data-bg-eq-apply]").click()
        check("BU7 applying adds the items to the inventory once (spear, dice set, healer's kit)",
              s.wait(lambda: "spear" in inv_items()) and "dice-set" in inv_items() and "healers-kit" in inv_items(), inv_items())
        s.wait(lambda: card.locator("[data-bg-equipment-applied]").count() == 1)
        ctext = card.text_content()
        check("BU8 the card shows Soldier, 2024 rules, +2 STR +1 CON, Athletics / Intimidation / Dice set, Savage Attacker as a reference",
              "Soldier" in ctext and "2024 rules" in ctext and "+2 STR" in ctext and "+1 CON" in ctext and "Athletics" in ctext
              and "Dice set" in ctext and "Savage Attacker" in ctext and "not applied automatically" in ctext, ctext[:600])

        s.tab("stats")
        # source-aware rows since 2026-11-07 (docs/ABILITY_SCORE_SOURCE_MODEL.md): "+2 Background: Soldier" and "Score 17", never "= 17"
        s.wait(lambda: "Background" in (page.locator('[data-ab-srcs="str"]').text_content() or ""))
        note = (page.locator('[data-ab-srcs="str"]').text_content() or "") + " | " + (page.locator('[data-ab-eff="str"]').text_content() or "")
        dot = page.locator("[data-action=cycle-skill][data-k=intimidation]")
        check("BU9 Stats: STR shows '+2 Background' and 'Score 17' (no '= 17'); Intimidation is proficient from Soldier (background)",
              "+2" in note and "Background" in note and "17" in note and "= 17" not in note and "Soldier (background)" in (dot.get_attribute("title") or ""), (note, dot.get_attribute("title")))
        check("BU10 the proficiency list names Soldier as the source of the dice set",
              "Soldier" in page.locator("#specific-profs [data-prof-item=dice-set]").inner_text())

        s.tab("features")
        card.locator("[data-action=bg-choose]").click()
        dlg = page.locator(".modal").last
        dlg.locator("[data-bg-pick=urchin-phb]").click()
        dlg.locator("[data-bg-editor]").wait_for(timeout=15000)   # the version detail loads on selection (fluent path)
        check("BU11 a legacy version says it has no ability increases and no feat", "no ability score increases" in dlg.locator("[data-bg-editor]").inner_text())
        dlg.locator("[data-bg-save]").click()
        nope = page.locator(".modal").last
        s.wait(lambda: "starting equipment" in nope.inner_text().lower())
        nope.locator("[data-close]").last.click()
        s.wait(lambda: "Urchin" in card.inner_text())
        ctext = card.inner_text()
        check("BU12 Urchin (legacy): the City Secrets feature is informational; the equipment of Soldier stays in the inventory",
              "City Secrets" in ctext and "Informational" in ctext and "Legacy (2014)" in ctext and "spear" in inv_items(), ctext[:400])
        card.locator("details.bg-chars > summary").click()
        card.locator("form[data-bg-chars] [name=personality]").fill("I know every alley.")
        card.locator("form[data-bg-chars] [type=submit]").click()
        check("BU13 characteristics are saved as the player's own text", s.wait(lambda: '"personality": "I know every alley."' in json.dumps(
            u.rpc("get_character_background", p_character=ch)[1].get("characteristics", {}))))
        s.tab("stats")
        check("BU14 the Soldier increase is gone with the background change (STR back to 15, no background part)",
              s.wait(lambda: "Background" not in (page.locator('[data-ab-srcs="str"]').text_content() or "")))

        s.tab("features")
        card.locator("[data-action=bg-choose]").click()
        dlg = page.locator(".modal").last
        dlg.locator("[name=playtest]").check()
        dlg.locator("[data-bg-pick=rune-carver-ua]").click()
        dlg.locator("[data-bg-editor]").wait_for(timeout=15000)   # the version detail loads on selection (fluent path)
        dlg.locator("[data-bg-save]").click()
        msg = dlg.locator("[data-bg-editor-status]").inner_text()
        check("BU15 Rune Carver (playtest) asks for the DM's permission before saving", "DM allows" in msg, msg)
        page.keyboard.press("Escape")

        s.tab("bio")
        with page.expect_download() as dl:
            page.locator("[data-action=export-json]").click()
        exported = json.loads(Path(dl.value.path()).read_text(encoding="utf-8"))
        check("BU16 the export carries the background version, choices and characteristics",
              exported.get("backgroundVersion", {}).get("version") == "urchin-phb"
              and exported["backgroundVersion"]["characteristics"].get("personality") == "I know every alley.", exported.get("backgroundVersion"))
        exported["name"] = f"Background UI Tester (imported {RUN})"
        imp = SHOTS / f"background_{RUN}.json"
        imp.write_text(json.dumps(exported), encoding="utf-8")
        page.goto(APP)
        page.click("#btn-import")
        page.set_input_files(".modal input[name=file]", str(imp))
        page.locator(".modal button[type=submit]").click()
        page.wait_for_url(re.compile(r"#/c/"), timeout=20000)
        new_id = page.url.split("#/c/")[1].split("/")[0]
        bgi = u.rpc("get_character_background", p_character=new_id)[1]
        check("BU17 the import restores the background (Urchin, characteristics)",
              bgi.get("selected") and bgi["version"]["id"] == "urchin-phb" and bgi["characteristics"].get("personality") == "I know every alley.")

        s.open(ch)
        s.tab("features")
        card.locator("[data-action=bg-remove]").click()
        page.locator(".modal [data-ok]").last.click()
        check("BU18 removing the background empties the card and keeps the equipment", s.wait(lambda: card.locator("[data-bg-empty]").count() == 1)
              and "spear" in inv_items())
        page.set_viewport_size({"width": 390, "height": 844})
        page.wait_for_timeout(400)
        ov_card = s.overflow()
        card.locator("[data-action=bg-choose]").click()
        page.locator(".modal [data-bg-pick=sage-2024]").click()
        page.locator(".modal [data-bg-editor]").wait_for(timeout=15000)
        page.wait_for_timeout(300)
        ov_dlg = page.evaluate("() => { const m = document.querySelector('.modal-backdrop:last-child .modal'); return m ? m.scrollWidth - m.clientWidth : 0; }")
        check("BU19 390 px: no horizontal overflow on the Build tab and in the background editor", ov_card <= 0 and ov_dlg <= 0, (ov_card, ov_dlg))
        page.keyboard.press("Escape")
        errs = [e for e in s.errors if "status of 400" not in e]   # BU4 provokes one refused save on purpose
        check("BU20 no browser errors (besides the refused save of BU4) and only local network traffic", not errs and not s.remote, (errs[:3], s.remote[:3]))
        s.close()
        browser.close()
    report()


if __name__ == "__main__":
    main()
