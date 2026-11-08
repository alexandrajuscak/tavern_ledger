"""Browser test of the Wild Shape gameplay mode (docs/WILD_SHAPE_UI.md) against the LOCAL Supabase stack.

Covers the idle panel (uses, Druid level, CR and movement limits, multiclass, elemental), the form picker (search, filters,
sort, favorites, seen forms, compare, locked reasons), the transformation review, the active-form sheet (abilities, saves,
AC, movement, senses, actions, traits, spells, equipment), form HP (damage, heal, adjust, lethal confirmation, carry-over),
revert, uses, the sheet header and Stats tab while transformed, Combat Wild Shape healing, limited form abilities,
Beast Spells, Realtime between two pages, export, keyboard, mobile, local-only network and console errors.
Every number shown comes from the server; the checks compare the page with the database.
"""
import json
import re

from playwright.sync_api import sync_playwright

from class_ui_common import APP, RUN, SHOTS, Sheet, User, call, check, report


def main():
    u = User("wildshape")
    moon = u.character("WS Moon 6", [("druid-phb", 6, "druid-moon-phb")], wisdom=16, dexterity=14, constitution=14)
    young = u.character("WS Druid 2", [("druid-phb", 2)], wisdom=16)
    multi = u.character("WS Fighter Druid", [("fighter-phb", 3), ("druid-phb", 2)], wisdom=14)
    elder = u.character("WS Moon 10", [("druid-phb", 10, "druid-moon-phb")], wisdom=18, constitution=14)
    sage = u.character("WS Druid 18", [("druid-phb", 18)], wisdom=20)
    SHOTS.mkdir(parents=True, exist_ok=True)

    def rows(path):
        return call("GET", f"/rest/v1/{path}", token=u.jwt)[1]

    def form_row(cid):
        r = rows(f"character_transformations?character_id=eq.{cid}&select=creature_id,hp_current,hp_temp")
        return r[0] if r else None

    with sync_playwright() as p:
        browser = p.chromium.launch(channel="msedge", headless=True)
        s = Sheet(browser, u, tab="features")
        page = s.page
        txt = lambda sel: page.locator(sel).first.inner_text() if page.locator(sel).count() else ""

        # ---------------------------------------------------------------- idle panels
        s.open(young)
        s.tab("features")
        idle = '#class-transform [data-transform="idle"]'
        s.wait(lambda: page.locator(idle).count() == 1)
        t = txt(idle)
        check("WSU1 Druid 2: 2 / 2 uses, beast forms up to CR 1/4, swimming locked until Druid 4, flying until Druid 8",
              "2 / 2" in t and "CR 1/4" in t and "Swimming forms from Druid 4" in t and "Flying forms from Druid 8" in t, t)
        check("WSU2 Druid 2 is not Circle of the Moon and has no Elemental Wild Shape line",
              "Circle of the Moon" not in t and "Elemental" not in t, t)
        s.open(multi)
        s.tab("features")
        s.wait(lambda: page.locator(idle).count() == 1)
        t = txt(idle)
        check("WSU3 multiclass Fighter 3 / Druid 2: limits use the Druid level (2), the character level 5 is explained",
              "Druid level 2" in t and "character level 5" in t and "CR 1/4" in t, t)
        s.open(elder)
        s.tab("features")
        s.wait(lambda: page.locator(idle).count() == 1)
        t = txt(idle)
        check("WSU4 Moon Druid 10: CR 3, swimming and flying allowed, Elemental Wild Shape listed",
              "CR 3" in t and "✓ Swimming forms" in t and "✓ Flying forms" in t and "Elemental Wild Shape" in t, t)

        s.open(moon)
        s.tab("features")
        s.wait(lambda: page.locator(idle).count() == 1)
        t = txt(idle)
        check("WSU5 Moon Druid 6: 2 / 2 uses, CR 2, Circle of the Moon tag, swimming yes, flying from Druid 8, seen forms: warning only",
              "2 / 2" in t and "CR 2" in t and "Circle of the Moon" in t and "✓ Swimming forms" in t and "Flying forms from Druid 8" in t
              and "warning only" in t, t)

        # ---------------------------------------------------------------- picker
        page.click(f"{idle} [data-action=tf-pick]")
        page.wait_for_selector(".modal [data-ws-picker]")
        modal = page.locator(".modal").last
        res = modal.locator("[data-ws-results]")
        check("WSU6 the picker opens with the focus in the search field",
              s.wait(lambda: page.evaluate("() => document.activeElement?.dataset?.f") == "q"))
        check("WSU7 the default list shows usable forms only: Brown Bear yes, Giant Eagle (flying) no, count announced",
              s.wait(lambda: res.locator('[data-ws-form="brown-bear"]').count() == 1) and res.locator('[data-ws-form="giant-eagle"]').count() == 0
              and "forms shown" in modal.locator("[data-ws-count]").inner_text())
        card = res.locator('[data-ws-form="brown-bear"]')
        ct = card.inner_text()
        check("WSU8 the Brown Bear card: CR 1, Large, HP 34, AC 11, walk 40 ft and climb 30 ft, Multiattack, Keen Smell",
              all(x in ct for x in ("CR 1", "Large", "HP 34", "AC 11", "40 ft", "climb 30 ft", "Multiattack", "Keen Smell")), ct)
        check("WSU9 an unseen usable form says so (warning mode) and offers Mark seen",
              card.get_attribute("data-status") == "eligible_unseen" and card.locator("[data-ws-seen]").count() == 1, card.get_attribute("data-status"))
        modal.locator('[data-f="status"]').select_option("all")
        modal.locator('[data-f="q"]').fill("eagle")
        eagle = res.locator('[data-ws-form="giant-eagle"]')
        check("WSU10 All forms: Giant Eagle is locked with a reason (flying) and its Transform button is disabled",
              s.wait(lambda: eagle.count() == 1) and "fly" in eagle.inner_text().lower() and eagle.locator("[data-ws-take]").is_disabled(), eagle.inner_text() if eagle.count() else "")
        modal.locator('[data-f="q"]').fill("pack tactics")
        check("WSU11 search by trait name: pack tactics finds the Wolf",
              s.wait(lambda: res.locator('[data-ws-form="wolf"]').count() == 1))
        modal.locator('[data-f="q"]').fill("")
        modal.locator('[data-f="status"]').select_option("usable")
        modal.locator('[data-f="move"]').select_option("swim")
        cards = res.locator("[data-ws-form]")
        s.wait(lambda: cards.count() > 0)
        swim_ok = all("swim" in cards.nth(i).inner_text() for i in range(cards.count()))
        check("WSU12 Movement = swim: every listed form has a swimming speed", cards.count() > 0 and swim_ok, cards.count())
        modal.locator('[data-f="move"]').select_option("")
        modal.locator('[data-f="cr"]').select_option("0.25")
        s.page.wait_for_timeout(200)
        crs = [c.get_attribute("data-ws-form") for c in cards.all()]
        check("WSU13 Max CR 1/4 hides the Brown Bear and the Wolf stays (CR 1/4)",
              "brown-bear" not in crs and "wolf" in crs, crs[:10])
        modal.locator('[data-f="cr"]').select_option("")
        modal.locator('[data-f="sort"]').select_option("hp")
        s.page.wait_for_timeout(200)
        hps = [int(c.locator(".ws-form-stats strong").first.inner_text().split()[1]) for c in cards.all()[:5]]
        check("WSU14 sorting by HP puts the highest hit points first", hps == sorted(hps, reverse=True) and len(hps) > 2, hps)
        modal.locator('[data-f="sort"]').select_option("cr")
        fav = res.locator('[data-ws-fav="wolf"]')
        fav.click()
        check("WSU15 starring the Wolf: the button is pressed and the favorite is stored on the server",
              s.wait(lambda: res.locator('[data-ws-fav="wolf"]').get_attribute("aria-pressed") == "true")
              and s.wait(lambda: len(rows(f"character_form_favorites?character_id=eq.{moon}&creature_id=eq.wolf&select=creature_id")) == 1))
        check("WSU16 the favorite keeps the keyboard focus and is listed first",
              page.evaluate("() => document.activeElement?.dataset?.wsFav") == "wolf" and cards.first.get_attribute("data-ws-form") == "wolf",
              cards.first.get_attribute("data-ws-form"))
        modal.locator('[data-f="status"]').select_option("favorites")
        s.page.wait_for_timeout(200)
        check("WSU17 the Favorites filter shows only the Wolf", [c.get_attribute("data-ws-form") for c in cards.all()] == ["wolf"])
        modal.locator('[data-f="status"]').select_option("usable")
        res.locator('[data-ws-compare="wolf"]').check()
        check("WSU18 one form checked: the compare bar stays hidden", modal.locator("[data-ws-compare-bar]").is_hidden())
        res.locator('[data-ws-compare="brown-bear"]').check()
        check("WSU19 two forms checked: the compare bar shows 2 selected",
              s.wait(lambda: modal.locator("[data-ws-compare-bar]").is_visible()) and "2 selected" in modal.locator("[data-ws-compare-count]").inner_text())
        modal.locator("[data-ws-compare-open]").click()
        cmp = page.locator(".modal .ws-compare")
        check("WSU20 the comparison table has a column per form, highlights differing rows and ranks nothing",
              s.wait(lambda: cmp.count() == 1) and cmp.locator("thead th").count() == 3 and cmp.locator("tr.is-diff").count() >= 3
              and "ranks the forms" in page.locator(".modal").last.inner_text())
        page.keyboard.press("Escape")
        check("WSU21 Escape closes only the comparison; the picker stays open",
              s.wait(lambda: page.locator(".modal .ws-compare").count() == 0) and page.locator(".modal [data-ws-picker]").count() == 1)
        res.locator('[data-ws-seen="brown-bear"]').click()
        check("WSU22 Mark seen: the Brown Bear becomes a seen form (server) and its card says so",
              s.wait(lambda: res.locator('[data-ws-form="brown-bear"]').get_attribute("data-status") == "eligible_seen")
              and len(rows(f"character_seen_forms?character_id=eq.{moon}&creature_id=eq.brown-bear&select=source")) == 1)

        # ---------------------------------------------------------------- review and transformation
        res.locator('[data-ws-take="brown-bear"]').click()
        page.wait_for_selector(".modal .ws-review")
        rv = page.locator(".modal").last
        rt = rv.inner_text()
        check("WSU23 the review shows the cost (1 use, 2 left), the duration (3 hours), protected HP and merge as the default",
              "1 Wild Shape use" in rt and "2 left" in rt and "3 hours" in rt and "protected" in rt
              and rv.locator('[name=eqmode][value=merge]').is_checked(), rt)
        rv.locator("[data-close]").first.click()
        page.wait_for_timeout(500)
        check("WSU24 cancelling the review transforms nothing", form_row(moon) is None)
        page.click(f"{idle} [data-action=tf-quick][data-creature=wolf]")
        page.wait_for_selector(".modal .ws-review")
        page.locator(".modal").last.locator("[data-close]").first.click()
        page.click(f"{idle} [data-action=tf-pick]")
        page.wait_for_selector(".modal [data-ws-picker]")
        page.locator('.modal [data-ws-take="brown-bear"]').click()
        page.wait_for_selector(".modal [data-ws-confirm]")
        page.locator(".modal [data-ws-confirm]").click()
        mini = '#class-transform [data-transform="active"]'
        check("WSU25 Transform: the class page shows a compact In Wild Shape: Brown Bear summary with 34 / 34 form HP",
              s.wait(lambda: page.locator(mini).count() == 1 and "Brown Bear" in page.locator(mini).text_content() and "34 / 34" in txt(mini)), txt("#class-transform"))
        fr = form_row(moon)
        check("WSU26 the server holds the form: brown-bear, 34 HP, one use spent",
              fr and fr["creature_id"] == "brown-bear" and fr["hp_current"] == 34
              and rows(f"character_resources?character_id=eq.{moon}&feature_resource_id=eq.druid-wild-shape-phb-uses&select=expended")[0]["expended"] == 1, fr)
        page.click(f"{mini} [data-action=tf-open-combat]")
        act = '#combat-transform [data-transform="active"]'
        check("WSU27 Open the Wild Shape sheet switches to the Combat tab with the full form mode",
              s.wait(lambda: page.locator(act).is_visible()))
        head = page.locator(f"{act} .ws-head").text_content()
        check("WSU28 the form header: Brown Bear, CR 1, Large beast, SRD source, up to 3 h, Wild Shape: 1 / 2 left, Revert button",
              all(x in head for x in ("Brown Bear", "CR 1", "Large", "beast", "Up to 3 h", "1 / 2 left", "Revert")), head)
        ab = lambda k: page.locator(f'{act} [data-ws-ability="{k}"]').inner_text()
        check("WSU29 physical abilities come from the form (STR 19, DEX 10, CON 16), mental ones are yours (WIS 16)",
              (ab("str"), ab("dex"), ab("con"), ab("wis")) == ("19", "10", "16", "16"), (ab("str"), ab("dex"), ab("con"), ab("wis")))
        srcs = page.locator(f"{act} .ws-abilities .ws-src").all_inner_texts()
        check("WSU30 each ability says where it comes from (Form / Kept, with the full source for screen readers)",
              srcs[:3] == ["Form"] * 3 and srcs[3:] == ["Kept"] * 3 and "retained from" in txt(f"{act} .ws-abilities"), srcs)
        sv = lambda k: page.locator(f'{act} [data-ws-save="{k}"]').inner_text()
        check("WSU31 saving throws: STR +4 (form), WIS +6 (your proficiency), INT +3",
              (sv("str"), sv("wis"), sv("int")) == ("+4", "+6", "+3"), (sv("str"), sv("wis"), sv("int")))
        check("WSU32 AC 11 (natural armor of the form)", page.locator(f"{act} [data-ws-ac]").inner_text() == "11")
        mv = txt(f"{act} .ws-moves")
        check("WSU33 movement: walk 40 ft, climb 30 ft, no swim or fly; passive Perception shown",
              "Walk 40 ft" in mv.replace("\n", " ") and "Climb 30 ft" in mv.replace("\n", " ") and "Passive Perception" in txt(f"{act} .ws-senses"), mv)
        acts = txt(f"{act} .ws-actions")
        check("WSU34 actions: Multiattack (1 × Bite + 1 × Claws), Bite +5 to hit (SRD 5.1 value) 1d8 + 4 piercing, Claws 2d6 + 4 slashing",
              "1 × Bite" in acts and "1 × Claws" in acts and "+5 to hit" in acts and "1d8 + 4 piercing" in acts and "2d6 + 4 slashing" in acts, acts)
        check("WSU35 traits grouped: Keen Smell under Senses", "Keen Smell" in txt(f'{act} [data-ws-traits="senses"]'))
        check("WSU36 spells: cannot cast in this form (Druid 6, no Beast Spells)", "Cannot cast" in txt(f"{act} [data-ws-cast]"))
        check("WSU37 retained features and equipment are listed (nothing equipped, merge rule explained)",
              "features" in txt(f"{act} .ws-card:has(#ws-ret)") and "Nothing equipped" in txt(f"{act} .ws-card:has(#ws-eq)"))
        check("WSU38 the HP card shows the form's HP first (Brown Bear) and says damage and healing go to the form",
              s.wait(lambda: page.locator("[data-ws-hpnote]").is_visible()) and "apply to the form" in txt("[data-ws-hpnote]")
              and "Brown Bear" in txt("[data-ws-hp]"))
        check("WSU39 the header speed shows the form speed", "Form: walk 40 ft" in txt("#speed-note"), txt("#speed-note"))

        # ---------------------------------------------------------------- HP
        page.locator(f"{act} [data-action=tf-damage]").click()
        check("WSU40 Damage without an amount asks for one and changes nothing", s.wait(lambda: "Enter an amount" in s.toasts()) and form_row(moon)["hp_current"] == 34)
        page.locator(f"{act} [data-tf-amount]").fill("10")
        page.locator(f"{act} [data-action=tf-damage]").click()
        check("WSU41 10 damage: 24 / 34 on the page and the server, still Healthy (over half), announced in the live region",
              s.wait(lambda: "24" in txt(f"{act} [data-ws-form-hp]") and form_row(moon)["hp_current"] == 24)
              and "Healthy" in txt(f"{act} .ws-hp-state") and "10 damage" in txt("#ws-status"), txt("#ws-status"))
        hp = rows(f"characters?id=eq.{moon}&select=hp_current")[0]["hp_current"]
        check("WSU42 the normal form HP is untouched (protected)", hp == 40 and "40" in txt(f"{act} [data-ws-normal-hp]"), hp)
        page.locator(f"{act} [data-tf-amount]").fill("5")
        page.locator(f"{act} [data-action=tf-heal]").click()
        check("WSU43 healing 5: 29 / 34", s.wait(lambda: form_row(moon)["hp_current"] == 29 and "29" in txt(f"{act} [data-ws-form-hp]")))
        page.locator("#hp-amount").fill("4")
        page.locator("[data-action=hp-damage]").first.click() if page.locator("[data-action=hp-damage]").count() else None
        check("WSU44 the main HP card's Damage applies to the form while transformed (29 -> 25), normal HP stays 40",
              s.wait(lambda: form_row(moon)["hp_current"] == 25) and rows(f"characters?id=eq.{moon}&select=hp_current")[0]["hp_current"] == 40,
              form_row(moon))
        page.locator(f"{act} [data-action=tf-adjust]").click()
        page.wait_for_selector(".modal [data-ws-adjust]")
        adj = page.locator(".modal").last
        adj.locator("input[name=hp]").fill("20")
        adj.locator("input[name=temp]").fill("3")
        adj.locator("[data-ok]").click()
        check("WSU45 Adjust needs a reason (the form refuses to save without one)",
              page.locator(".modal [data-ws-adjust]").count() == 1 and form_row(moon)["hp_current"] == 25)
        adj.locator("input[name=reason]").fill("table correction")
        adj.locator("[data-ok]").click()
        check("WSU46 Adjust to 20 + 3 temp: the page shows 20 / 34 +3 temp",
              s.wait(lambda: form_row(moon) == {"creature_id": "brown-bear", "hp_current": 20, "hp_temp": 3}
                     and "+3 temp" in txt(f"{act} [data-ws-form-hp]")), form_row(moon))
        page.locator(f"{act} [data-tf-amount]").fill("30")
        page.locator(f"{act} [data-action=tf-damage]").click()
        page.wait_for_selector(".modal [data-ok]")
        lt = page.locator(".modal").last.inner_text()
        check("WSU47 lethal damage asks first: Wild Shape will end, 7 damage carries over (40 -> 33)",
              "Wild Shape will end" in lt and "7 damage will carry over" in lt and "40 → 33" in lt, lt)
        page.locator(".modal").last.locator("[data-close]").first.click()
        page.wait_for_timeout(500)
        check("WSU48 cancelling the lethal damage changes nothing", form_row(moon)["hp_current"] == 20)
        page.locator(f"{act} [data-tf-amount]").fill("30")
        page.locator(f"{act} [data-action=tf-damage]").click()
        page.wait_for_selector(".modal [data-ok]")
        page.locator(".modal").last.locator("[data-ok]").click()
        check("WSU49 confirmed: the form ends, the message names the carry-over, the panel returns to idle",
              s.wait(lambda: "7 damage carries over" in s.toasts()) and s.wait(lambda: page.locator('#combat-transform [data-transform="idle"]').count() == 1), s.toasts())
        hp = rows(f"characters?id=eq.{moon}&select=hp_current")[0]["hp_current"]
        check("WSU50 the normal form took the 7 carried-over damage once (40 -> 33) and no use was refunded or spent",
              hp == 33 and form_row(moon) is None and "1 / 2" in txt('#combat-transform [data-transform="idle"]'), hp)
        check("WSU51 the Stats ability tile and header return to normal (STR note gone, speed note normal)",
              s.wait(lambda: "Form:" not in txt("#speed-note") and page.locator("[data-ws-hpnote]").is_hidden()),
              (txt("#speed-note"), page.locator("[data-ws-hpnote]").is_hidden()))

        # ---------------------------------------------------------------- favorite quick start, Stats tab, manual revert, no uses left
        page.click('#combat-transform [data-action=tf-quick][data-creature=wolf]')
        page.wait_for_selector(".modal [data-ws-confirm]")
        page.locator(".modal [data-ws-confirm]").click()
        check("WSU52 the favorite quick button transforms into the Wolf after the review", s.wait(lambda: (form_row(moon) or {}).get("creature_id") == "wolf"))
        s.tab("stats")
        check("WSU53 the Stats tab shows the form's physical scores in the notes (Wolf form, character base score 10)",
              s.wait(lambda: "Wolf form · character base score 10" in txt('[data-derived="abnote:str"]')), txt('[data-derived="abnote:str"]'))
        s.tab("combat")
        page.locator(f"{act} [data-action=tf-end]").click()
        page.wait_for_selector(".modal [data-ok]")
        rt = page.locator(".modal").last.inner_text()
        check("WSU54 revert asks with what returns and says no use is spent", "No Wild Shape use is spent" in rt and "33" in rt, rt)
        page.locator(".modal").last.locator("[data-ok]").click()
        idle_c = '#combat-transform [data-transform="idle"]'
        check("WSU55 after revert: idle, 0 / 2 uses, Choose a form disabled with the rest hint",
              s.wait(lambda: page.locator(idle_c).count() == 1 and "0 / 2" in txt(idle_c))
              and page.locator(f"{idle_c} [data-action=tf-pick]").is_disabled() and "No uses left" in txt(idle_c), txt(idle_c))
        page.screenshot(path=str(SHOTS / "wild-shape-idle.png"), full_page=True)

        # ---------------------------------------------------------------- export
        with page.expect_download() as dl:
            s.tab("bio")
            page.click("[data-action=export-json]")
        data = json.loads(open(dl.value.path(), encoding="utf-8").read())
        ws = data.get("wildShape") or {}
        check("WSU56 the JSON export carries the seen forms and favorites (Brown Bear seen, Wolf favorite), no active form",
              {"creature": "brown-bear", "source": "seen"} in ws.get("seen", []) and "wolf" in ws.get("favorites", []) and ws.get("active") is None, ws)
        # import: seen forms and favorites come back; an active form, an "unrestricted" setting and unknown forms do not
        data["name"] = f"WS Imported {RUN}"
        ws["active"] = {"creature": "brown-bear", "formHp": 999, "formHpMax": 999}
        ws["settings"] = {"seenMode": "unrestricted", "defaultEquipment": "drop", "confirmLethal": False}
        ws["seen"].append({"creature": "no-such-beast", "source": "seen"})
        data["wildShape"] = ws
        imp = SHOTS / f"wild_shape_{RUN}.json"
        imp.write_text(json.dumps(data), encoding="utf-8")
        page.goto(APP)
        page.click("#btn-import")
        page.set_input_files(".modal input[name=file]", str(imp))
        page.locator(".modal button[type=submit]").click()
        page.wait_for_url(re.compile(r"#/c/"), timeout=20000)
        new_id = page.url.split("#/c/")[1].split("/")[0]
        page.wait_for_timeout(1500)
        st, tf = u.rpc("get_character_transformation", p_character=new_id)
        seen = {o["id"] for o in tf["options"] if o["seen"]}
        favs = {o["id"] for o in tf["options"] if o["favorite"]}
        check("WSU56b import: Brown Bear seen and Wolf favorite restored; no active form, unknown form skipped, uses as exported (0 / 2, nothing spent by the import),"
              " seen rule not switched off, equipment default and lethal confirmation restored",
              seen == {"brown-bear"} and favs == {"wolf"} and tf["active"] is None and tf["resources"][0]["remaining"] == 0
              and tf["settings"]["seen_mode"] == "warn" and tf["settings"]["default_equipment"] == "drop" and tf["settings"]["confirm_lethal"] is False,
              (seen, favs, tf["active"], tf["settings"], tf["resources"]))
        s.close()

        # ---------------------------------------------------------------- Moon Druid 10: elementals, Combat Wild Shape, Realtime
        s = Sheet(browser, u, tab="combat")
        page = s.page
        txt = lambda sel: page.locator(sel).first.inner_text() if page.locator(sel).count() else ""
        s.open(elder)
        s.tab("combat")
        page.click('#combat-transform [data-action=tf-pick]')
        page.wait_for_selector(".modal [data-ws-picker]")
        mt = page.locator(".modal [data-ws-results]")
        check("WSU57 Moon Druid 10: the picker has an Elemental Wild Shape group (2 uses each) with the Air Elemental",
              s.wait(lambda: "Elemental Wild Shape (2 uses each)" in mt.text_content() and mt.locator('[data-ws-form="air-elemental"]').count() == 1))
        page.locator('.modal [data-ws-take="giant-spider"]').click()
        page.wait_for_selector(".modal [data-ws-confirm]")
        page.locator(".modal [data-ws-confirm]").click()
        s.wait(lambda: (form_row(elder) or {}).get("creature_id") == "giant-spider")
        web = page.locator('#combat-transform [data-ws-action-card="Web"]')
        check("WSU58 Giant Spider: Web shows Recharge 5–6: available, DC 12 DEX save and the restrained condition",
              s.wait(lambda: web.count() == 1) and "Recharge 5–6: available" in web.inner_text() and "DC 12" in web.inner_text()
              and "Restrained" in web.inner_text(), web.inner_text() if web.count() else "")
        web.locator("[data-op=use]").click()
        check("WSU59 Use: Web is marked used, Use disabled, Roll recharge enabled",
              s.wait(lambda: "used" in page.locator('#combat-transform [data-ws-action-card="Web"]').inner_text())
              and page.locator('#combat-transform [data-ws-action-card="Web"] [data-op=use]').is_disabled()
              and page.locator('#combat-transform [data-ws-action-card="Web"] [data-op=roll]').is_enabled())
        page.locator('#combat-transform [data-ws-action-card="Web"] [data-op=restore]').click()
        check("WSU60 Restore: Web is available again",
              s.wait(lambda: "available" in page.locator('#combat-transform [data-ws-action-card="Web"]').inner_text()))
        page.locator('#combat-transform [data-action=tf-end]').click()
        page.locator(".modal").last.locator("[data-ok]").click()
        s.wait(lambda: form_row(elder) is None)
        page.click('#combat-transform [data-action=tf-pick]')
        page.wait_for_selector(".modal [data-ws-picker]")
        page.locator('.modal [data-ws-take="brown-bear"]').click()
        page.wait_for_selector(".modal [data-ws-confirm]")
        page.locator(".modal [data-ws-confirm]").click()
        s.wait(lambda: (form_row(elder) or {}).get("creature_id") == "brown-bear")
        act = '#combat-transform [data-transform="active"]'
        page.locator(f"{act} [data-tf-amount]").fill("10")
        page.locator(f"{act} [data-action=tf-damage]").click()
        s.wait(lambda: form_row(elder)["hp_current"] == 24)

        o = Sheet(browser, u, tab="combat")             # a second page on the same character
        o.open(elder)
        o.tab("combat")
        o.wait(lambda: "24" in o.page.locator(f"{act} [data-ws-form-hp]").inner_text())
        page.locator(f"{act} [data-action=tf-combat-heal]").click()
        page.wait_for_selector(".modal [data-ws-heal]")
        hm = page.locator(".modal").last
        check("WSU61 Combat Wild Shape: no slot is preselected and the confirm button waits for a choice",
              hm.locator("[data-ok]").is_disabled() and not any(r.is_checked() for r in hm.locator("[name=slot]").all()))
        hm.locator('[name=slot][value="standard:1"]').check()
        hm.locator("input[name=roll]").fill("5")
        check("WSU62 choosing a 1st-level slot previews 1d8 (1–8)", "1d8 (1–8)" in hm.locator("[data-heal-preview]").inner_text())
        hm.locator("[data-ok]").click()
        check("WSU63 healing with your roll 5: 24 -> 29, one 1st-level slot spent, toast names the roll",
              s.wait(lambda: form_row(elder)["hp_current"] == 29) and "Rolled 5" in s.toasts()
              and rows(f"character_spell_slot_state?character_id=eq.{elder}&pool=eq.standard&slot_level=eq.1&select=expended")[0]["expended"] == 1, s.toasts())
        check("WSU64 Realtime: the second page shows the healed form HP without reloading",
              o.wait(lambda: "29" in o.page.locator(f"{act} [data-ws-form-hp]").inner_text()))
        page.locator(f"{act} [data-tf-amount]").focus()
        page.keyboard.press("Tab")
        check("WSU65 keyboard: Tab from the amount reaches the Damage button",
              page.evaluate("() => document.activeElement?.dataset?.action") == "tf-damage")
        check("WSU66 no console errors and only local network traffic (both pages)",
              not s.errors and not s.remote and not o.errors and not o.remote, (s.errors[:3], o.errors[:3], s.remote[:2]))
        page.screenshot(path=str(SHOTS / "wild-shape-active.png"), full_page=True)
        o.close()
        s.close()

        # ---------------------------------------------------------------- seen mode enforce, Beast Spells, mobile
        st, _ = u.rpc("set_wild_shape_settings", p_character=young, p_seen_mode="enforce", p_default_equipment=None, p_confirm_lethal=None)
        s = Sheet(browser, u, tab="combat")
        page = s.page
        s.open(young)
        s.tab("combat")
        page.click('#combat-transform [data-action=tf-pick]')
        page.wait_for_selector(".modal [data-ws-picker]")
        r2 = page.locator(".modal [data-ws-results]")
        check("WSU67 seen forms required: no form is usable until one is marked seen",
              st == 200 and s.wait(lambda: "No form matches" in r2.inner_text()), r2.inner_text()[:200])
        page.locator('.modal [data-f="status"]').select_option("all")
        page.locator('.modal [data-f="q"]').fill("wolf")
        wolf = r2.locator('[data-ws-form="wolf"]')
        check("WSU68 the Wolf is locked as not seen yet and can be marked seen",
              s.wait(lambda: wolf.get_attribute("data-status") == "unseen_locked") and "not seen" in wolf.inner_text().lower())
        wolf.locator("[data-ws-seen]").click()
        check("WSU69 after Mark seen the Wolf's Transform button is enabled",
              s.wait(lambda: r2.locator('[data-ws-take="wolf"]').is_enabled()))
        page.keyboard.press("Escape")
        s.close()
        s = Sheet(browser, u, tab="combat")
        s.open(sage)
        s.tab("combat")
        s.page.click('#combat-transform [data-action=tf-pick]')
        s.page.wait_for_selector(".modal [data-ws-picker]")
        s.page.locator('.modal [data-ws-take="wolf"]').click()
        s.page.wait_for_selector(".modal [data-ws-confirm]")
        s.page.locator(".modal [data-ws-confirm]").click()
        check("WSU70 Druid 18: Beast Spells, the form can cast", s.wait(lambda: "Can cast in this form" in s.page.locator("#combat-transform [data-ws-cast]").inner_text()
                                                                       and "Beast Spells" in s.page.locator("#combat-transform [data-ws-cast]").inner_text()))
        s.close()

        u.rpc("short_rest_character", p_character=elder)      # Wild Shape uses come back on a short rest
        m = Sheet(browser, u, width=390, height=844, tab="combat")
        m.open(elder)
        m.tab("combat")
        m.wait(lambda: m.page.locator(f"{act}").count() == 1)
        check("WSU71 mobile 390 px: the active form mode has no horizontal overflow", m.overflow() <= 0, m.overflow())
        m.page.screenshot(path=str(SHOTS / "wild-shape-mobile.png"), full_page=True)
        m.page.locator(f"{act} [data-action=tf-end]").click()
        m.page.locator(".modal").last.locator("[data-ok]").click()
        m.wait(lambda: m.page.locator('#combat-transform [data-action=tf-pick]').count() == 1)
        m.page.click('#combat-transform [data-action=tf-pick]')
        m.page.wait_for_selector(".modal [data-ws-picker]")
        check("WSU72 mobile 390 px: the form picker has no horizontal overflow", m.overflow() <= 0, m.overflow())
        check("WSU73 mobile: search stays visible, the filters are folded and the first form card is on the first screen",
              m.page.locator('.modal [data-f="q"]').is_visible() and not m.page.locator(".modal .ws-filters").evaluate("d => d.open")
              and m.page.locator(".modal [data-ws-form]").first.bounding_box()["y"] < 844)
        m.page.screenshot(path=str(SHOTS / "wild-shape-picker-mobile.png"))
        m.close()
        browser.close()
    report()


if __name__ == "__main__":
    main()
