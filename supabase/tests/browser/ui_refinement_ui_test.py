"""Browser test of the UI refinement (docs/UI_REFINEMENT_REVIEW.md): section hierarchy, school-only spell icons (corrected 2026-10-22), the icon
registry and fallbacks, and the lineage-based new-character flow with legacy race compatibility and export / import.

Synthetic users (ui-*@example.test, removed by run_browser_local.sh) own everything that is changed; a campaign
"UI Refinement Campaign" (standard governance, legacy content off) is created and removed by this test. The checks go through
the UI; the service role only prepares users, the campaign and its membership. Refuses non-local URLs.
"""
import json
import re
import subprocess
import uuid
from pathlib import Path

from playwright.sync_api import sync_playwright

from class_ui_common import APP, RUN, SHOTS, Sheet, User, check, report

DB = "supabase_db_tavern_ledger"
CAMP_NAME = "UI Refinement Campaign"
EMOJI = re.compile("[\U0001F300-\U0001FAFF⛀-⛿]")


def sql(q):
    r = subprocess.run(["docker", "exec", "-i", DB, "psql", "-U", "postgres", "-qAt", "-v", "ON_ERROR_STOP=1"], input=q.encode(), capture_output=True)
    if r.returncode:
        raise SystemExit(r.stderr.decode())
    return r.stdout.decode().strip()


def ok(st):
    return 200 <= st < 300


sql(f"delete from public.characters where campaign_id in (select id from public.campaigns where name = '{CAMP_NAME}');"
    f"delete from public.campaigns where name = '{CAMP_NAME}'")
dm, pl = User("refine-dm"), User("refine-pl")
camp = str(uuid.uuid4())
sql(f"""insert into public.campaigns (id, name, created_by) values ('{camp}', '{CAMP_NAME}', '{dm.id}');
insert into public.campaign_members (campaign_id, user_id, role) values ('{camp}', '{dm.id}', 'dm'), ('{camp}', '{pl.id}', 'player');
insert into public.campaign_governance (campaign_id, preset, content_allow_legacy) values ('{camp}', 'standard', false);""")

wizard = pl.character(f"Refine Wizard {RUN}", classes=[("wizard-phb", 7)], intelligence=16, dexterity=14)
legacy_human = pl.character(f"Legacy Human {RUN}", classes=[("fighter-phb", 2)], race="Human", strength=15)
legacy_gnome = pl.character(f"Legacy Gnome {RUN}", race="Gnome")
legacy_elf = pl.character(f"Legacy Wood Elf {RUN}", race="Wood Elf")
# the wizard's spellbook: same RPC as the Add spell dialog
st, book = pl.rpc("get_character_spellbook", p_character=wizard)
assert ok(st), book
src = next(s["id"] for s in book["sources"] if s.get("id"))
for v in ["fireball-phb", "chill-touch-phb", "ray-of-frost-phb", "magic-missile-phb", "shield-phb", "detect-magic-phb", "ice-storm-phb", "chromatic-orb-phb"]:
    st, r = pl.rpc("set_character_spell", p_character=wizard, p_source=src, p_spell_version=v, p_known=True, p_prepared=False,
                   p_always_prepared=False, p_casting_ability=None, p_ritual_allowed=None, p_notes=None)
    assert ok(st), (v, r)
# then into the governed campaign, set up (later changes follow the campaign rules)
sql(f"update public.characters set campaign_id = '{camp}' where id in ('{wizard}', '{legacy_human}');"
    f"insert into public.character_governance (character_id, setup_complete) values ('{wizard}', true), ('{legacy_human}', true);")


def custom_spell(name, school, effects):
    st, c = dm.rpc("create_dm_content", p_type="spell", p_campaign=camp, p_request_id=str(uuid.uuid4()), p_fields={
        "name": name, "ruleset": "2024", "player_text": "Test spell.", "definition": {"level": 1, "school": school,
        "casting_time": {"unit": "action", "amount": 1}, "range": {"type": "distance", "distance": 60, "unit": "feet"},
        "duration": {"type": "instantaneous"}, "components": {"v": True, "s": True}, "attack_type": "ranged" if effects else None,
        "effects": effects, "class_lists": []}})
    assert ok(st), c
    st, c = dm.rpc("publish_dm_content", p_content=c["id"])
    assert ok(st), c
    return c


ember = custom_spell(f"Ember Lance {RUN}", "evocation", [{"category": "damage", "dice": "2d8", "damage_types": ["fire"]}])
hum = custom_spell(f"Warding Hum {RUN}", "abjuration", [])


def heading_levels(page, panel):
    return page.evaluate(f"""() => [...document.querySelectorAll('#panel-{panel} h1, #panel-{panel} h2, #panel-{panel} h3, #panel-{panel} h4, #panel-{panel} h5, #panel-{panel} h6')]
        .filter((h) => h.offsetParent !== null || h.closest('details')).map((h) => Number(h.tagName[1]))""")


def heading_ok(levels):
    if not levels or levels[0] != 2:
        return False
    return all(b <= a + 1 for a, b in zip(levels, levels[1:]))


def bg(page, sel):
    return page.locator(sel).first.evaluate("e => getComputedStyle(e).backgroundColor")


def icons_ok(page):
    """Every visible icon has loaded pixels, a size and an alt attribute (empty only when aria-hidden)."""
    return page.evaluate("""async () => {
      const imgs = [...document.querySelectorAll('img.tl-icon')].filter((i) => i.offsetParent !== null);
      imgs.forEach((i) => { i.loading = 'eager'; });   // lazy icons below the fold load now
      await Promise.all(imgs.map((i) => i.complete ? null : new Promise((r) => { i.onload = i.onerror = r; setTimeout(r, 3000); })));
      return imgs.filter((i) => !(i.naturalWidth > 0 && i.width > 0 && i.hasAttribute('alt') && (i.alt || i.getAttribute('aria-hidden') === 'true')))
        .map((i) => i.outerHTML.slice(0, 160));
    }""")


def main():
    with sync_playwright() as p:
        browser = p.chromium.launch(channel="msedge", headless=True)
        s = Sheet(browser, pl, tab="stats")
        page = s.page

        # ---- section hierarchy: Abilities -----------------------------------------------------------------------------------
        s.open(wizard)
        s.tab("stats")
        panel = page.locator("#panel-stats")
        titles = panel.locator(".tl-section > .tl-section-head h2").all_inner_texts()
        for i, name in enumerate(["Ability scores and skills", "Hit Dice", "Senses and movement", "Proficiencies"], 1):
            sec = panel.locator(".tl-section", has=page.locator("h2", has_text=name))
            check(f"SH{i} Abilities has its own '{name}' section with an h2 title", sec.count() == 1 and any(name in t for t in titles), titles)
        check("SH6 Abilities headings start with h2 and never skip a level", heading_ok(heading_levels(page, "stats")), heading_levels(page, "stats"))
        check("SH6b Spells headings start with h2 and never skip a level", (s.tab("spells") or True) and s.wait(lambda: page.locator("#spellbook-list .sp-card").count() > 0)
              and heading_ok(heading_levels(page, "spells")), heading_levels(page, "spells"))
        s.tab("stats")
        sec_bg, card_bg, page_bg = bg(page, "#panel-stats .tl-section"), bg(page, "#panel-stats .ab-block"), page.evaluate("getComputedStyle(document.body).backgroundColor")
        check("SH9 section, card and page use three different surface tokens", len({sec_bg, card_bg, page_bg}) == 3, (sec_bg, card_bg, page_bg))
        gaps = page.evaluate("""() => { const s = [...document.querySelectorAll('#panel-stats .tl-section')];
            const r = s.map((x) => x.getBoundingClientRect()); const card = document.querySelectorAll('#panel-stats .ab-block');
            const c0 = card[0].getBoundingClientRect(), c1 = card[1].getBoundingClientRect();
            return { section: r[1].top - r[0].bottom, card: c1.left - c0.right }; }""")
        check("SH9b the gap between sections is larger than the gap between cards", gaps["section"] > gaps["card"] + 6, gaps)
        nested = page.evaluate("() => document.querySelectorAll('.tl-section .tl-section, .tl-section .card .card .card').length")
        check("SH11 no section inside a section and no card three levels deep", nested == 0, nested)

        # ---- Inventory and Build ---------------------------------------------------------------------------------------------
        s.tab("inventory")
        s.wait(lambda: page.locator("#panel-inventory .inv-main").count() > 0)
        inv = page.locator("#panel-inventory .tl-section").count()
        check("SH7 Inventory: Equipped, Items you carry and Coins are separate sections",
              page.locator("#panel-inventory .inv-equipment.tl-section").count() == 1 and page.locator("#panel-inventory .inv-main.tl-section").count() == 1
              and page.locator("#panel-inventory .inv-coins.tl-section").count() == 1 and inv >= 3, inv)
        check("SH7b Inventory headings start with h2 and never skip a level", heading_ok(heading_levels(page, "inventory")), heading_levels(page, "inventory"))
        s.tab("features")
        s.wait(lambda: page.locator("#lineage-card .tl-section-title").count() > 0)
        build = [t.strip() for t in page.locator("#panel-features .tl-section-title").all_inner_texts()]
        check("SH8 Build: Classes, Class features, Lineage, Background, Feats, Reminders and own features are separate sections",
              all(any(n in t for t in build) for n in ["Classes", "Class features", "Lineage", "Background", "Feats", "Reminders", "Your own features"]), build)
        check("SH8b Build headings start with h2 and never skip a level", heading_ok(heading_levels(page, "features")), heading_levels(page, "features"))

        # ---- spell icons (spellbook cards) -----------------------------------------------------------------------------------
        s.tab("spells")
        s.wait(lambda: page.locator("#spellbook-list .sp-card").count() >= 8)

        def card(vid):
            return page.locator(f'#spellbook-list .sp-card[data-spell="{vid}"]').first

        def icon_of(vid):
            return card(vid).locator("img.sp-icon").first

        # school-only rule: the primary icon is the spell's school, whatever damage it deals
        for n, vid, key in [(13, "fireball-phb", "spell.school.evocation"), (14, "chill-touch-phb", "spell.school.necromancy"),
                            (15, "ray-of-frost-phb", "spell.school.evocation"), (16, "magic-missile-phb", "spell.school.evocation"),
                            (18, "shield-phb", "spell.school.abjuration"), (19, "detect-magic-phb", "spell.school.divination"),
                            (21, "ice-storm-phb", "spell.school.evocation"), (23, "chromatic-orb-phb", "spell.school.evocation")]:
            got = icon_of(vid).get_attribute("data-icon") if card(vid).count() else None
            check(f"SI{n} {vid} uses the {key} icon", got == key, got)
        ice = card("ice-storm-phb").inner_text()
        check("SI22 the multi-damage spell shows every damage type as a chip with '+'", "Bludgeoning" in ice and "Cold" in ice and "+" in ice, ice)
        orb = card("chromatic-orb-phb").inner_text()
        check("SI24 the choose-damage spell says 'Choose one' and lists the options",
              "Choose one" in orb and all(x in orb for x in ["Acid", "Cold", "Fire", "Lightning", "Poison", "Thunder"]), orb)
        fb = card("fireball-phb")
        check("SI25 a damaging spell keeps its school badge (Fireball: Evocation) next to the Fire chip",
              "Evocation" in fb.locator(".sp-school").inner_text() and fb.locator('.dmg-chip[data-dmg="fire"]').count() == 1, fb.inner_text())
        ct = card("chill-touch-phb")
        check("SI26 Necromancy (school) and Necrotic (damage) stay separate on Chill Touch",
              ct.get_attribute("data-school") == "necromancy" and "Necromancy" in ct.locator(".sp-school").inner_text()
              and ct.locator('.dmg-chip[data-dmg="necrotic"]').count() == 1 and icon_of("chill-touch-phb").get_attribute("data-icon") == "spell.school.necromancy")
        alts = {v: icon_of(v).get_attribute("alt") for v in ["fireball-phb", "shield-phb", "ice-storm-phb", "chromatic-orb-phb"]}
        check("SI27 primary spell icons have accessible labels (the school in words)",
              alts["fireball-phb"] == "Evocation school" and alts["shield-phb"] == "Abjuration school"
              and alts["ice-storm-phb"] == "Evocation school" and alts["chromatic-orb-phb"] == "Evocation school", alts)
        check("SI58 damage and school meaning are in text, not only in icons or colour",
              "Fire" in fb.inner_text() and "Evocation" in fb.inner_text() and "Abjuration" in card("shield-phb").inner_text())
        bad = icons_ok(page)
        check("SI28 SI29 no broken, blank or zero-sized icon on the Spells section", not bad, bad[:3])

        # ---- spell picker (catalog rows) incl. non-wizard spells and campaign custom spells ---------------------------------
        page.locator("[data-action=spell-add]").click()
        page.wait_for_selector(".modal .sp-pick", timeout=20000)

        def pick_icon(q):
            box = page.locator('.modal input[data-cf="q"]').first
            box.fill(q)
            page.wait_for_timeout(500)
            row = page.locator(".modal .sp-pick", has_text=q).first
            return (row.locator("img.tl-icon").first.get_attribute("data-icon"), row.inner_text()) if row.count() else (None, "")

        for n, q, key in [(17, "Guiding Bolt", "spell.school.evocation"), (20, "Cure Wounds", "spell.school.evocation")]:
            got, txt = pick_icon(q)
            check(f"SI{n} picker: {q} uses {key}", got == key, (got, txt))
        page.select_option('.modal select[data-cf="status"]', "homebrew")   # the picker starts on official spells
        page.wait_for_timeout(300)
        got, txt = pick_icon(f"Ember Lance {RUN}")
        check("SI30 a campaign custom damage spell uses its school icon (Evocation), 'Fire' stays in the row", got == "spell.school.evocation" and "Fire" in txt, (got, txt))
        got, txt = pick_icon(f"Warding Hum {RUN}")
        check("SI31 a campaign custom spell without damage uses its school icon (Abjuration)", got == "spell.school.abjuration", (got, txt))
        page.keyboard.press("Escape")
        page.wait_for_timeout(300)

        # ---- icon registry and fallbacks ---------------------------------------------------------------------------------------
        expected = []                     # console errors this test causes on purpose (a missing file, a refused change)
        n_err = len(s.errors)
        res = page.evaluate("""async () => {
          const m = await import('./js/icons.js?v=35');
          const host = document.createElement('div'); host.id = 'icon-probe'; document.body.append(host);
          host.innerHTML = m.icon('does.not.exist', { size: 24 }) + m.icon('ui/no-such-file', { size: 24 })
            + '<img class="tl-icon" data-icon="ui.attack" src="assets/icons/ui/missing-file.webp" width="24" height="24" alt="" aria-hidden="true">';
          const imgs = [...host.querySelectorAll('img')];
          await new Promise((r) => setTimeout(r, 1500));
          const out = imgs.map((i) => ({ w: i.naturalWidth, width: i.width, src: i.getAttribute('src') }));
          host.remove();
          return out;
        }""")
        expected += s.errors[n_err:]
        check("IC32 IC33 an unknown key and an unknown asset name resolve to a fallback icon with pixels", all(x["w"] > 0 for x in res[:2]), res)
        check("IC37 a file that fails to load is replaced by its fallback at the same size", res[2]["w"] > 0 and res[2]["width"] == 24
              and "missing-file" not in res[2]["src"], res[2])
        texts = " ".join(page.locator(f"#panel-{t}").inner_text() for t in ["combat", "stats", "spells", "inventory", "features", "bio"])
        check("IC34 no emoji used as icons in the sheet sections", not EMOJI.search(texts), EMOJI.findall(texts)[:5])
        audit = json.loads((Path(__file__).resolve().parents[3] / "data" / "reports" / "icon_audit.json").read_text(encoding="utf-8"))
        check("IC35 the icon audit finds no missing, corrupt or visually blank asset",
              not audit["missing_assets"] and not audit["corrupt_assets"] and not audit["visual_issues"] and not audit["unresolved_references"],
              {k: audit[k] for k in ("missing_assets", "corrupt_assets", "visual_issues")})
        check("IC36 unknown-licence assets are listed in the audit report", len(audit["unknown_licence_assets"]) == audit["asset_files"] > 0)

        # ---- legacy race: preserved, no mechanics, governance --------------------------------------------------------------
        s.open(legacy_human)
        s.tab("features")
        callout = page.locator("#lineage-card [data-legacy-race-unmapped]")
        s.wait(lambda: callout.count() == 1)
        st, lin = pl.rpc("get_character_lineage", p_character=legacy_human)
        st2, der = pl.rpc("get_character_derived_stats", p_character=legacy_human)
        check("CC49 an old character keeps its legacy race text and shows it as unmapped",
              callout.count() == 1 and "Human" in callout.inner_text() and "has not been mapped" in callout.inner_text(), callout.inner_text() if callout.count() else "")
        check("CC50 the legacy race grants no lineage mechanics", lin.get("selected") is False and not der.get("lineage"), (lin.get("selected"), der.get("lineage")))
        check("CC51a an exact name match is suggested for review (Human)", callout.locator('[data-lineage-suggestion="human"]').count() == 1)
        callout.locator('[data-lineage-open="human"]').click()
        page.wait_for_selector(".modal input[name=lin-version]", timeout=15000)
        check("CC51b the suggestion opens the picker on the suggested lineage with its traits (mechanical preview)",
              "Human" in page.locator(".modal .lin-title").inner_text() and page.locator(".modal .lin-traits li").count() > 0)
        n_err = len(s.errors)
        page.locator(".modal [data-lin-save]").click()
        page.wait_for_timeout(600)
        if page.locator(".modal [data-ok]").count():
            page.locator(".modal [data-ok]").last.click()
        page.wait_for_timeout(1500)
        expected += s.errors[n_err:]
        st, lin = pl.rpc("get_character_lineage", p_character=legacy_human)
        race = sql(f"select race from public.characters where id = '{legacy_human}'")
        check("CC54 governance: a set-up campaign character cannot change its lineage directly (approval needed); the race text stays",
              lin.get("selected") is False and race == "Human" and ("Ask your DM" in page.locator(".modal").last.inner_text() or "approv" in s.toasts().lower()),
              (lin.get("selected"), race, s.toasts()))
        for _ in range(3):
            page.keyboard.press("Escape")
            page.wait_for_timeout(200)

        # reviewed mapping outside a campaign (player managed)
        s.open(legacy_gnome)
        s.tab("features")
        s.wait(lambda: page.locator('#lineage-card [data-lineage-open="gnome"]').count() == 1)
        page.locator('#lineage-card [data-lineage-open="gnome"]').click()
        page.wait_for_selector(".modal input[name=lin-sub]", timeout=15000)
        page.locator(".modal input[name=lin-sub][value=gnome-rock]").check()
        page.locator(".modal [data-lin-save]").click()
        page.wait_for_timeout(600)
        if page.locator(".modal [data-ok]").count():
            page.locator(".modal [data-ok]").last.click()
        s.wait(lambda: page.locator("#lineage-card [data-lineage-name]").count() == 1)
        st, lin = pl.rpc("get_character_lineage", p_character=legacy_gnome)
        race = sql(f"select race from public.characters where id = '{legacy_gnome}'")
        check("CC51 a reviewed mapping applies the canonical lineage and keeps the legacy text (folded, not active)",
              lin.get("selected") and lin["version"]["id"] == "gnome-phb" and (lin.get("subversion") or {}).get("id") == "gnome-rock"
              and race == "Gnome" and page.locator("#lineage-card [data-legacy-race]").count() == 1
              and page.locator("#lineage-card [data-legacy-race-unmapped]").count() == 0, (lin.get("version"), race))

        # keyboard-only picker and focus return (no suggestion for "Wood Elf": ambiguous)
        s.open(legacy_elf)
        s.tab("features")
        s.wait(lambda: page.locator("#lineage-card [data-legacy-race-unmapped]").count() == 1)
        check("CC49b an ambiguous legacy race ('Wood Elf') gets no automatic suggestion",
              page.locator("#lineage-card [data-lineage-suggestion]").count() == 0 and "No exact match" in page.locator("#lineage-card").inner_text())
        btn = page.locator('#lineage-card [data-focus-key="lineage-choose"]')
        btn.focus()
        page.keyboard.press("Enter")
        page.wait_for_selector(".modal input[name=lin-q]", timeout=15000)
        page.wait_for_timeout(300)
        page.locator(".modal input[name=lin-q]").focus()
        page.keyboard.type("dwarf")
        page.keyboard.press("Enter")
        opened = s.wait(lambda: "Dwarf" in page.locator(".modal .lin-title").inner_text(), timeout=8000)
        check("CC55 keyboard only: type a search and press Enter to open the first result", opened)
        page.keyboard.press("Escape")
        page.wait_for_timeout(500)
        check("CC56 closing the picker returns focus to the button that opened it",
              page.evaluate("() => document.activeElement?.dataset?.focusKey") == "lineage-choose", page.evaluate("() => document.activeElement?.outerHTML?.slice(0, 120)"))
        check("CC53b the legacy race of an unmapped character is still stored", sql(f"select race from public.characters where id = '{legacy_elf}'") == "Wood Elf")

        # ---- new character: canonical lineage ----------------------------------------------------------------------------
        page.goto(APP)
        page.wait_for_selector("#btn-new", timeout=20000)
        page.click("#btn-new")
        page.wait_for_selector("#new-char", timeout=10000)
        check("CC38 the new-character dialog has no free-text Race field", page.locator(".modal input[name=race]").count() == 0
              and "Race" not in page.locator(".modal").inner_text())
        page.fill("#new-char input[name=name]", f"Nova {RUN}")
        page.select_option("#new-char select[name=campaign_id]", camp)
        page.locator(".modal [data-nc-next]").click()
        page.wait_for_selector(".modal input[name=lin-q]", timeout=20000)
        check("CC39 the canonical lineage picker opens as step 2", page.locator('.modal [aria-current="step"]').inner_text().strip().endswith("Lineage"))
        q = page.locator(".modal input[name=lin-q]")
        q.fill("aasimar")
        page.wait_for_timeout(300)
        page.locator('.modal [data-lin-open="aasimar"]').click()
        page.wait_for_selector(".modal input[name=lin-version]", timeout=15000)
        legacy_card = page.locator(".modal label.lin-card", has=page.locator("input[value=aasimar-vgm]"))
        check("CC42 campaign content policy: the legacy version is marked and cannot be chosen by the player",
              legacy_card.locator("input").is_disabled() and "Legacy content is not allowed" in legacy_card.inner_text(), legacy_card.inner_text())
        page.locator(".modal [data-lin-back]").click()
        q = page.locator(".modal input[name=lin-q]")
        q.fill("elf")
        page.wait_for_timeout(300)
        check("CC40 search filters the catalog", page.locator('.modal [data-lin-open="elf"]').count() == 1
              and page.locator(".modal [data-lin-open]").count() < 20, page.locator(".modal [data-lin-open]").count())
        page.locator('.modal [data-lin-open="elf"]').click()
        got = s.wait(lambda: page.locator(".modal input[name=lin-sub]").count() > 0, timeout=8000)
        check("CC41 the first click on a result after searching opens it", got)
        check("CC39b the step indicator moves to Lineage choices", "Lineage choices" in page.locator('.modal [aria-current="step"]').inner_text())
        vcard = page.locator(".modal label.lin-card", has=page.locator("input[name=lin-version]:checked"))
        check("CC43 the exact version is shown (name, source, Current)", "Player's Handbook" in vcard.inner_text() and "Current" in vcard.inner_text(), vcard.inner_text())
        page.locator(".modal input[name=lin-sub][value=elf-high]").check()
        page.wait_for_timeout(300)
        check("CC44 CC45 sub-lineage selection works and its required choices appear",
              page.locator(".modal input[name=lin-sub][value=elf-high]").is_checked() and page.locator(".modal .lin-choice").count() > 0)
        check("CC47 open required choices are announced before saving", "Still to choose" in page.locator(".modal [data-lin-missing]").inner_text(),
              page.locator(".modal [data-lin-missing]").inner_text())
        page.locator(".modal [data-nc-save]").click()
        page.wait_for_selector(".modal [data-ok]", timeout=8000)
        page.locator(".modal [data-ok]").last.click()
        page.wait_for_selector(".modal [data-nc-class] select[name=class]", timeout=20000)
        page.select_option(".modal select[name=class]", "wizard")
        s.wait(lambda: not page.locator(".modal [data-nc-save]").is_disabled(), timeout=10000)
        page.locator(".modal [data-nc-save]").click()
        page.wait_for_selector(".modal [data-nc-review]", timeout=20000)
        rv = page.locator(".modal [data-nc-review]").inner_text()
        check("CC46 the review shows lineage, sub-lineage, class, speed and senses",
              "Elf" in rv and "High Elf" in rv and "Wizard" in rv and "Walk" in rv and "Darkvision" in rv.title(), rv)
        check("CC47b the review lists the open lineage choices as a warning", "Lineage choices still open" in rv, rv)
        page.locator(".modal [data-nc-open]").click()
        page.wait_for_url(re.compile(r"#/c/"), timeout=15000)
        nova = page.url.split("#/c/")[1].split("/")[0]
        st, lin = pl.rpc("get_character_lineage", p_character=nova)
        row = json.loads(sql(f"select to_jsonb(c) from (select race, campaign_id from public.characters where id = '{nova}') c"))
        check("CC48 the new character stores the canonical lineage version and no race text",
              lin.get("selected") and lin["version"]["id"] == "elf-phb" and lin["subversion"]["id"] == "elf-high" and row["race"] == ""
              and row["campaign_id"] == camp, (lin.get("version"), row))

        # export / import
        page.wait_for_timeout(1200)
        s.tab("bio")
        with page.expect_download() as dl:
            page.locator("[data-action=export-json]").click()
        exported = json.loads(Path(dl.value.path()).read_text(encoding="utf-8"))
        lx = exported.get("lineage") or {}
        check("CC52 the export carries the exact lineage version, sub-lineage, id and name, and no invented race",
              lx.get("version") == "elf-phb" and lx.get("subversion") == "elf-high" and lx.get("lineageId") == "elf"
              and "High Elf" in (lx.get("name") or "") and "race" not in exported, (lx, exported.get("race")))
        SHOTS.mkdir(parents=True, exist_ok=True)
        exported["name"] = f"Nova copy {RUN}"
        f1 = SHOTS / f"refine_export_{RUN}.json"
        f1.write_text(json.dumps(exported), encoding="utf-8")
        legacy_file = {"schemaVersion": 1, "name": f"Old Tabaxi {RUN}", "race": "Tabaxi Ranger", "class": "Ranger", "level": 2}
        f2 = SHOTS / f"refine_legacy_{RUN}.json"
        f2.write_text(json.dumps(legacy_file), encoding="utf-8")

        def do_import(path):
            page.goto(APP)
            page.wait_for_selector("#btn-import", timeout=20000)
            page.click("#btn-import")
            page.set_input_files(".modal input[name=file]", str(path))
            page.locator(".modal button[type=submit]").click()
            page.wait_for_url(re.compile(r"#/c/"), timeout=20000)
            page.wait_for_timeout(800)
            return page.url.split("#/c/")[1].split("/")[0], s.toasts()

        copy_id, _ = do_import(f1)
        st, lin = pl.rpc("get_character_lineage", p_character=copy_id)
        check("CC52b importing the export restores the exact lineage (Elf, High Elf)",
              lin.get("selected") and lin["version"]["id"] == "elf-phb" and lin["subversion"]["id"] == "elf-high", lin.get("version"))
        old_id, toast = do_import(f2)
        st, lin = pl.rpc("get_character_lineage", p_character=old_id)
        race = sql(f"select race from public.characters where id = '{old_id}'")
        check("CC53 importing an old file keeps the unresolved legacy race, maps nothing and warns",
              race == "Tabaxi Ranger" and lin.get("selected") is False and "not mapped" in toast, (race, lin.get("selected"), toast))

        # ---- phone width ----------------------------------------------------------------------------------------------
        m = Sheet(browser, pl, width=390, height=844, tab="stats")
        mp = m.page
        m.open(wizard)
        m.tab("stats")
        borders = mp.evaluate("""() => [...document.querySelectorAll('#panel-stats .tl-section')].map((x) => getComputedStyle(x).borderTopWidth)""")
        gap = mp.evaluate("""() => { const s = [...document.querySelectorAll('#panel-stats .tl-section')].map((x) => x.getBoundingClientRect());
            return s[1].top - s[0].bottom; }""")
        check("SH10 at 390 px the sections keep a visible edge and gap", all(b != "0px" for b in borders) and gap >= 12, (borders, gap))
        over = []
        for t in ["stats", "spells", "inventory", "features"]:
            m.tab(t)
            mp.wait_for_timeout(600)
            over.append(m.overflow())
        check("SH12 no horizontal overflow at 390 px (Abilities, Spells, Inventory, Build)", all(o <= 1 for o in over), over)
        mp.goto(APP)
        mp.wait_for_selector("#btn-new", timeout=20000)
        mp.click("#btn-new")
        mp.fill("#new-char input[name=name]", f"Phone Hero {RUN}")
        mp.locator(".modal [data-nc-next]").click()
        mp.wait_for_selector(".modal input[name=lin-q]", timeout=20000)
        mp.locator(".modal input[name=lin-q]").fill("dwarf")
        mp.wait_for_timeout(300)
        mp.locator('.modal [data-lin-open="dwarf"]').click()
        opened = m.wait(lambda: mp.locator(".modal input[name=lin-version]").count() > 0, timeout=8000)
        mover = mp.evaluate("() => { const x = document.querySelector('.modal'); return x.scrollWidth - x.clientWidth; }")
        footer_visible = mp.locator(".modal [data-nc-skip]").is_visible()
        check("CC59 the new-character flow works at 390 px (search, first tap opens, no overflow, actions visible)",
              opened and mover <= 1 and footer_visible, (opened, mover, footer_visible))
        mp.screenshot(path=str(SHOTS / "refine_new_character_390.png"))
        m.close()

        unexpected = [e for e in s.errors if e not in expected]
        check("CC60 no console errors (apart from the deliberate missing file and the refused lineage change)",
              not unexpected and len(expected) <= 3, (unexpected[:3], expected))
        check("CC61 no request to a hosted service", not s.remote, s.remote[:3])
        s.close()
        browser.close()
    sql(f"delete from public.characters where campaign_id = '{camp}' or owner_id in ('{pl.id}', '{dm.id}');"
        f"delete from public.campaigns where id = '{camp}'")
    report()


if __name__ == "__main__":
    main()
