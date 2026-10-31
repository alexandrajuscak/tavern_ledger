"""Browser test of the 2026-10-22 corrections: the Abilities page shows the original ability cards (since v6 each card holds the
ability, its saving throw and the skills it governs; docs/ORIGINAL_UI_RESTORATION_REVIEW.md), and every spell's primary icon
comes from its school only (damage stays as colored chips). Calculations are covered by the derived-stat, proficiency, background, lineage and Wild Shape suites; this
test checks that the restored blocks show those values.

Synthetic users (ui-*@example.test, removed by run_browser_local.sh) own everything; the campaign "UI Refinement Campaign" is
created and removed here. Refuses non-local URLs. Screenshots go to SCREENSHOT_DIR (outside the repository).
"""
import re
import subprocess
import uuid

from playwright.sync_api import sync_playwright

from class_ui_common import APP, RUN, SHOTS, Sheet, User, call, check, report

DB = "supabase_db_tavern_ledger"
CAMP_NAME = "UI Refinement Campaign"
GROUPS = {"str": ["Athletics"], "dex": ["Acrobatics", "Sleight of Hand", "Stealth"], "con": [],
          "int": ["Arcana", "History", "Investigation", "Nature", "Religion"],
          "wis": ["Animal Handling", "Insight", "Medicine", "Perception", "Survival"],
          "cha": ["Deception", "Intimidation", "Performance", "Persuasion"]}
# spell -> (school, damage chips)
SPELLS = {"fireball-phb": ("evocation", ["fire"]), "cure-wounds-phb": ("evocation", []), "shield-phb": ("abjuration", []),
          "detect-magic-phb": ("divination", []), "misty-step-phb": ("conjuration", []), "hold-person-phb": ("enchantment", []),
          "chill-touch-phb": ("necromancy", ["necrotic"]), "minor-illusion-phb": ("illusion", []), "polymorph-phb": ("transmutation", []),
          "ice-storm-phb": ("evocation", ["bludgeoning", "cold"]), "chromatic-orb-phb": ("evocation", ["acid", "cold", "fire", "lightning", "poison", "thunder"])}


def sql(q):
    r = subprocess.run(["docker", "exec", "-i", DB, "psql", "-U", "postgres", "-qAt", "-v", "ON_ERROR_STOP=1"], input=q.encode(), capture_output=True)
    if r.returncode:
        raise SystemExit(r.stderr.decode())
    return r.stdout.decode().strip()


def rgb(hexv):
    h = hexv.strip().lstrip("#")
    return f"rgb({int(h[0:2], 16)}, {int(h[2:4], 16)}, {int(h[4:6], 16)})"


sql(f"delete from public.characters where campaign_id in (select id from public.campaigns where name = '{CAMP_NAME}');"
    f"delete from public.campaigns where name = '{CAMP_NAME}'")
dm, pl = User("fix-dm"), User("fix-pl")
camp = str(uuid.uuid4())
sql(f"""insert into public.campaigns (id, name, created_by) values ('{camp}', '{CAMP_NAME}', '{dm.id}');
insert into public.campaign_members (campaign_id, user_id, role) values ('{camp}', '{dm.id}', 'dm'), ('{camp}', '{pl.id}', 'player');""")

# Wizard 9 / Cleric 1: proficiency +4, INT 18 (+4), WIS 14 (+2); Arcana expertise and History proficiency set by hand
ch = pl.character(f"Skill Icon Tester {RUN}", [("wizard-phb", 9), ("cleric-phb", 1)], intelligence=18, wisdom=14, dexterity=12)
st, r = call("PATCH", f"/rest/v1/characters?id=eq.{ch}", {"skill_proficiencies": {"arcana": {"proficient": True, "expertise": True},
                                                                                     "history": {"proficient": True, "expertise": False}}}, token=pl.jwt)
assert st in (200, 204), (st, r)
_, rows = call("GET", f"/rest/v1/character_spellcasting_sources?character_id=eq.{ch}&select=id,class_version_id", token=pl.jwt)
src = {("cleric" if (x["class_version_id"] or "").startswith("cleric") else "wizard"): x["id"] for x in rows}
for v in SPELLS:
    st, r = pl.rpc("set_character_spell", p_character=ch, p_source=src["cleric" if v == "cure-wounds-phb" else "wizard"], p_spell_version=v,
                   p_known=True, p_prepared=False, p_always_prepared=False, p_casting_ability=None, p_ritual_allowed=None, p_notes=None)
    assert st == 200, (v, st, r)
sql(f"update public.characters set campaign_id = '{camp}' where id = '{ch}'")


def custom_spell(name, school, effects):
    st, c = dm.rpc("create_dm_content", p_type="spell", p_campaign=camp, p_request_id=str(uuid.uuid4()), p_fields={
        "name": name, "ruleset": "2024", "player_text": "Test spell.", "definition": {"level": 1, "school": school,
        "casting_time": {"unit": "action", "amount": 1}, "range": {"type": "distance", "distance": 60, "unit": "feet"},
        "duration": {"type": "instantaneous"}, "components": {"v": True, "s": True}, "attack_type": "ranged" if effects else None,
        "effects": effects, "class_lists": ["wizard-spell-list"]}})
    assert 200 <= st < 300, c
    st, c = dm.rpc("publish_dm_content", p_content=c["id"])
    assert 200 <= st < 300, c
    return c


# a Conjuration spell that deals Necrotic damage (damage must not pick the icon) and a Divination spell without damage
grave = custom_spell(f"Grave Summons {RUN}", "conjuration", [{"category": "damage", "dice": "2d6", "damage_types": ["necrotic"]}])
omen = custom_spell(f"Quiet Omen {RUN}", "divination", [])


def shot(page, name, sel=None):
    SHOTS.mkdir(parents=True, exist_ok=True)
    (page.locator(sel).first if sel else page).screenshot(path=str(SHOTS / f"{name}.png"))


def skills_layout(page):
    return page.evaluate("""() => {
      const sec = document.querySelector('#abilities-scores');
      const blocks = [...sec.querySelectorAll('#ability-cards > .ab-block')];
      return {
        groups: blocks.map((b) => ({ k: b.dataset.ability, name: b.querySelector('.ab-left .ability-name').textContent.trim(),
          mod: b.querySelector('.ab-left .ability-mod').textContent.trim(),
          skills: [...b.querySelectorAll('.ab-list .skill-row .li-name')].map((x) => x.textContent.trim()),
          savesInCard: b.querySelectorAll('.save-row [data-action="toggle-save"]').length,
          score: b.querySelector('.ab-left .ability-score')?.value })),
        cols: new Set(blocks.map((b) => Math.round(b.getBoundingClientRect().left))).size,
        leftCol: blocks[0] && getComputedStyle(blocks[0]).gridTemplateColumns,
        leftBorder: blocks[0] && getComputedStyle(blocks[0].querySelector('.ab-left')).borderRightStyle,
        flat: sec.querySelectorAll('.skill-list, .li-ability').length,
      };
    }""")


def main():
    with sync_playwright() as p:
        browser = p.chromium.launch(channel="msedge", headless=True)
        s = Sheet(browser, pl, tab="stats")
        page = s.page
        s.open(ch)
        s.tab("stats")
        s.wait(lambda: page.locator('#abilities-scores [data-derive="skill:arcana"]').inner_text().strip() != "")
        page.wait_for_timeout(600)

        # ---- Abilities: the original ability-and-skills cards --------------------------------------------------------------------
        sec = page.locator("#abilities-scores")
        check("K1 the Ability scores and skills section loads with its h2 title", sec.count() == 1 and sec.locator("h2", has_text="Ability scores and skills").count() == 1)
        lay = skills_layout(page)
        check("K2 six cards (STR DEX CON INT WIS CHA), each with name, modifier and score left of a divider and its skills on the right;"
              " Constitution has no invented skill",
              [g["k"] for g in lay["groups"]] == list(GROUPS) and lay["groups"][2]["skills"] == []
              and [g["score"] for g in lay["groups"]] == ["10", "12", "12", "18", "14", "10"] and all(g["skills"] == GROUPS[g["k"]] for g in lay["groups"])
              and lay["leftCol"].startswith("124px") and lay["leftBorder"] == "solid", lay)
        check("K2b each card holds exactly one saving-throw row; no flat alphabetical list", lay["flat"] == 0 and all(g["savesInCard"] == 1 for g in lay["groups"]), lay)
        check("K3 the modifier on each card matches the derived ability modifier (INT 18 -> +4, WIS 14 -> +2)",
              [g["mod"] for g in lay["groups"]] == ["+0", "+1", "+1", "+4", "+2", "+0"], [g["mod"] for g in lay["groups"]])
        val = lambda k: sec.locator(f'[data-derive="skill:{k}"]').inner_text().strip()  # noqa: E731
        dot = lambda k: sec.locator(f'[data-action="cycle-skill"][data-k="{k}"]')  # noqa: E731
        check("K4 modifiers: Arcana expertise +12, History proficient +8, Nature +4, Perception +2, Stealth +1",
              (val("arcana"), val("history"), val("nature"), val("perception"), val("stealth")) == ("+12", "+8", "+4", "+2", "+1"),
              (val("arcana"), val("history"), val("nature"), val("perception"), val("stealth")))
        check("K5 proficiency / expertise marks: Arcana level 2, History level 1, Nature level 0",
              (dot("arcana").get_attribute("data-level"), dot("history").get_attribute("data-level"), dot("nature").get_attribute("data-level")) == ("2", "1", "0"))
        pp = page.locator('#abilities-scores .sum-tile [data-derive="passive:perception"]').inner_text().strip()
        check("K6 Passive Perception (summary tile) agrees with the Perception row (10 + 2)", pp == "12", pp)
        check("K7 every skill button and every block list has an accessible name; the source is in the button title",
              sec.locator('[data-action="cycle-skill"][aria-label*=" proficiency ("]').count() == 18 and sec.locator("ul.ab-list[aria-label$=' saving throw and skills']").count() == 6
              and "Expertise" in (dot("arcana").get_attribute("title") or ""), dot("arcana").get_attribute("title"))
        check("K8 each skill appears exactly once on the page", all(page.locator(f'#panel-stats [data-action="cycle-skill"][data-k="{k}"]').count() == 1
              for k in ["athletics", "acrobatics", "arcana", "insight", "persuasion", "survival"]))
        # keyboard: Space on the focused Nature mark sets proficiency, focus stays on it; two more presses restore it
        dot("nature").focus()
        page.keyboard.press("Space")
        s.wait(lambda: val("nature") == "+8")
        focused = page.evaluate("() => document.activeElement?.dataset?.k")
        check("K9 keyboard: Space on a skill mark sets proficiency (+4 -> +8) and focus stays on that mark", val("nature") == "+8" and focused == "nature", (val("nature"), focused))
        for _ in range(2):
            page.evaluate("() => document.activeElement?.dataset?.k") == "nature" or dot("nature").focus()
            page.keyboard.press("Space")
            page.wait_for_timeout(500)
        s.wait(lambda: dot("nature").get_attribute("data-level") == "0")
        check("K10 cycling expertise and back to none restores the value", val("nature") == "+4" and dot("nature").get_attribute("data-level") == "0", val("nature"))
        check("K11 the marker legend is visible (not proficient, proficient, expertise, saving throw)",
              sec.locator(".ab-legend").is_visible() and all(x in sec.locator(".ab-legend").inner_text() for x in ("not proficient", "expertise", "saving-throw")))
        gaps = page.evaluate("""() => { const r = (id) => document.querySelector(id).getBoundingClientRect();
            return { below: r('#abilities-hitdice').top - r('#abilities-scores').bottom, bg: getComputedStyle(document.querySelector('#abilities-scores')).backgroundColor }; }""")
        check("K12 the Ability section stays clearly separated from the sections below (section gap, own surface)",
              gaps["below"] >= 16 and gaps["bg"] not in ("rgba(0, 0, 0, 0)", "transparent"), gaps)
        check("K13 the other Abilities parts remain: Hit Dice with Death Saves, Senses and movement, Proficiencies",
              page.locator("#abilities-hitdice .death-saves").count() == 1 and page.locator("#abilities-senses").count() == 1 and page.locator("#abilities-profs").count() == 1)
        check("K14 desktop (1366): the blocks are in three columns", lay["cols"] == 3, lay["cols"])
        shot(page, "skills_1366", "#abilities-scores")
        shot(page, "abilities_1366_full")

        # ---- Spells: school-only primary icon ---------------------------------------------------------------------------------
        s.tab("spells")
        s.wait(lambda: page.locator("#spellbook-list .sp-card").count() >= len(SPELLS))
        page.wait_for_timeout(600)
        card = lambda v: page.locator(f'#spellbook-list .sp-card[data-spell="{v}"]').first  # noqa: E731
        tok = lambda n: page.evaluate(f"() => getComputedStyle(document.documentElement).getPropertyValue('{n}').trim()")  # noqa: E731
        n = 0
        for v, (school, dmg) in SPELLS.items():
            n += 1
            c = card(v)
            img = c.locator(".sp-card-top img.sp-icon")
            got = (img.count(), img.first.get_attribute("data-icon") if img.count() else None, img.first.get_attribute("alt") if img.count() else None)
            chips = sorted(c.locator(".dmg-chip[data-dmg]").evaluate_all("es => es.map((e) => e.dataset.dmg)")) if c.count() else None
            check(f"I{n} {v}: one primary icon spell.school.{school} ('{school.title()} school'), badge {school.title()}, chips {dmg or 'none'}",
                  got == (1, f"spell.school.{school}", f"{school.title()} school") and c.get_attribute("data-school") == school
                  and school.title() in c.locator(".sp-school").inner_text() and chips == sorted(dmg), (got, chips))
        check("I12 Fire stays an orange chip (Fireball) and Necrotic a deep-green chip (Chill Touch), distinct from the Necromancy school color",
              card("fireball-phb").locator('.dmg-chip[data-dmg="fire"]').evaluate("e => getComputedStyle(e).borderTopColor") == rgb(tok("--dmg-fire"))
              and card("chill-touch-phb").locator('.dmg-chip[data-dmg="necrotic"]').evaluate("e => getComputedStyle(e).borderTopColor") == rgb(tok("--dmg-necrotic"))
              and tok("--dmg-necrotic") != tok("--school-necromancy"))
        ice, orb = card("ice-storm-phb").inner_text(), card("chromatic-orb-phb")
        check("I13 Ice Storm keeps Bludgeoning + Cold together; Chromatic Orb keeps 'Choose one' with all six options",
              "Bludgeoning" in ice and "Cold" in ice and "+" in ice and orb.locator(".dmg-choice .dmg-chip").count() == 6 and "Choose one" in orb.inner_text())
        check("I14 the school edge stays (Fireball: Evocation red edge)",
              card("fireball-phb").evaluate("e => getComputedStyle(e).borderLeftColor") == rgb(tok("--school-evocation")))
        icons = page.evaluate("""async () => { const imgs = [...document.querySelectorAll('#spellbook-list img.sp-icon')];
            imgs.forEach((i) => { i.loading = 'eager'; });
            await Promise.all(imgs.map((i) => i.complete ? null : new Promise((r) => { i.onload = i.onerror = r; setTimeout(r, 3000); })));
            return { n: imgs.length, keys: [...new Set(imgs.map((i) => i.dataset.icon))],
                     bad: imgs.filter((i) => !(i.naturalWidth > 0 && i.width > 0 && i.alt)).map((i) => i.outerHTML.slice(0, 120)) }; }""")
        check("I15 no primary icon is a damage icon, broken, blank or unlabelled", icons["n"] >= len(SPELLS) and not icons["bad"]
              and all(k.startswith("spell.school.") for k in icons["keys"]), icons)
        card("fireball-phb").locator(".sp-name").focus()
        page.keyboard.press("Enter")
        dlg = page.locator(".modal .sp-detail-icon")
        check("I16 keyboard opens the details; the details icon is the school icon (Fireball: Evocation)",
              s.wait(lambda: dlg.count() == 1) and dlg.get_attribute("data-icon") == "spell.school.evocation" and "Fire" in page.locator(".modal").inner_text())
        shot(page, "spell_detail_fireball_1366", ".modal")
        page.keyboard.press("Escape")
        page.wait_for_timeout(300)
        shot(page, "spells_1366", "#spellbook-list")

        # catalog picker incl. campaign custom spells
        page.locator("[data-action=spell-add]").click()
        page.wait_for_selector(".modal .sp-pick", timeout=20000)

        def pick(q):
            page.locator('.modal input[data-cf="q"]').first.fill(q)
            page.wait_for_timeout(500)
            row = page.locator(".modal .sp-pick", has_text=q).first
            return (row.locator("img.tl-icon").first.get_attribute("data-icon"), row.inner_text()) if row.count() else (None, "")
        got = pick("Fireball")
        check("I17 the catalog picker uses the same school icon (Fireball: Evocation; 'Fire' in the row)", got[0] == "spell.school.evocation" and "Fire" in got[1], got)
        page.select_option('.modal select[data-cf="status"]', "homebrew")
        page.wait_for_timeout(300)
        got = pick(f"Grave Summons {RUN}")
        check("I18 a damaging custom spell uses its selected school (Conjuration), not its Necrotic damage", got[0] == "spell.school.conjuration" and "Necrotic" in got[1], got)
        shot(page, "picker_custom_1366", ".modal")
        got = pick(f"Quiet Omen {RUN}")
        check("I19 a non-damaging custom spell uses its selected school (Divination)", got[0] == "spell.school.divination", got)
        page.keyboard.press("Escape")
        page.wait_for_timeout(300)

        # resolver contract: every school, unresolved school, missing asset -> generic fallback with the school kept as text
        res = page.evaluate("""async () => { const m = await import('./js/spell-icons.js?v=16');
            const schools = ['Abjuration', 'Conjuration', 'Divination', 'Enchantment', 'Evocation', 'Illusion', 'Necromancy', 'Transmutation'];
            const fire = { school: 'Necromancy', effects: [{ category: 'damage', damage_types: ['fire'], damage_mode: 'single' }] };
            return { all: schools.map((s) => m.resolveSpellIcon({ school: s })), none: m.resolveSpellIcon({}), odd: m.resolveSpellIcon({ school: 'Chronurgy' }),
                     fire: m.resolveSpellIcon(fire), heal: m.resolveSpellIcon({ school_id: 'evocation', effects: [{ category: 'healing' }] }) }; }""")
        check("I20 all eight schools resolve directly to their own registered icon",
              all(r["key"] == f"spell.school.{r['school']}" and r["coverage"] == "direct" for r in res["all"]) and len({r["key"] for r in res["all"]}) == 8, res["all"])
        check("I21 a missing or unknown school resolves to the generic spell icon, never to a damage icon",
              res["none"]["key"] == res["odd"]["key"] == "spell.school.generic" and res["none"]["coverage"] == "fallback"
              and "not resolved" in res["none"]["label"], (res["none"], res["odd"]))
        check("I22 damage or healing never changes the icon (Necromancy + Fire -> Necromancy; healing Evocation -> Evocation)",
              res["fire"]["key"] == "spell.school.necromancy" and res["heal"]["key"] == "spell.school.evocation", (res["fire"], res["heal"]))
        miss = page.evaluate("""async () => { const img = document.querySelector('#spellbook-list img.sp-icon'); const c = img.cloneNode();
            c.removeAttribute('data-fallback-step'); document.body.appendChild(c); c.src = 'assets/icons/spell-schools/__missing__.webp';
            await new Promise((r) => setTimeout(r, 1500)); const out = { src: c.getAttribute('src'), w: c.naturalWidth }; c.remove(); return out; }""")
        check("I23 a missing school icon file falls back to the generic spell icon (no broken image)", miss["w"] > 0 and "__missing__" not in miss["src"], miss)
        s.errors[:] = [e for e in s.errors if "__missing__" not in e and "404" not in e]

        # DM custom spell preview: same resolver
        D = Sheet(browser, dm)
        d = D.page
        d.goto(APP + "#/dm/content")
        D.wait(lambda: d.locator("[data-dm-campaign]").count() > 0)
        d.select_option("[data-dm-campaign]", camp)
        d.locator('[data-dm-section="content"]').click()
        D.wait(lambda: d.locator('[data-dm="new-content"][data-type="spell"]').count() > 0)
        d.locator('[data-dm="new-content"][data-type="spell"]').click()
        d.wait_for_selector(".modal [data-ce-form]")
        d.fill(".modal [name=name]", f"Preview Probe {RUN}")
        d.select_option('.modal [name="definition.level"]', "1")
        d.select_option('.modal [name="definition.school"]', "illusion")
        d.locator('.modal [data-ce-act="save"]').click()
        D.wait(lambda: "Draft" in d.locator(".modal .ce-status").inner_text())
        d.locator('.modal [data-ce-act="preview"]').click()
        D.wait(lambda: d.locator(".modal [data-ce-preview] img.tl-icon").count() > 0)
        pv = d.locator(".modal [data-ce-preview] img.tl-icon").first
        check("I24 the DM custom spell preview uses the selected school icon (Illusion)", pv.get_attribute("data-icon") == "spell.school.illusion", pv.get_attribute("data-icon"))
        shot(d, "dm_custom_spell_preview_1366", ".modal")
        D.close()

        # ---- tablet and mobile ---------------------------------------------------------------------------------------------------
        for w, cols in ((820, 2), (390, 1)):
            page.set_viewport_size({"width": w, "height": 900})
            s.tab("stats")
            page.wait_for_timeout(500)
            lay = skills_layout(page)
            check(f"K15 {w}px: Skills blocks in {cols} column(s), no horizontal overflow", lay["cols"] == cols and s.overflow() <= 0, (lay["cols"], s.overflow()))
            shot(page, f"skills_{w}", "#abilities-scores")
            s.tab("spells")
            page.wait_for_timeout(500)
            if w == 390:
                c = card("chill-touch-phb")
                box = c.bounding_box()
                check("I25 390px: spell cards fit (no overflow), icon + badge + chips visible", s.overflow() <= 0 and box["width"] <= 390
                      and c.locator("img.sp-icon").is_visible() and c.locator(".sp-school").is_visible() and c.locator(".dmg-chip").first.is_visible(), (s.overflow(), box))
            shot(page, f"spells_{w}", "#spellbook-list")
        check("C1 no console errors", not s.errors, s.errors[:5])
        check("C2 no hosted requests (local only)", not s.remote, s.remote[:5])
        s.close()
        browser.close()
    sql(f"delete from public.characters where campaign_id in (select id from public.campaigns where name = '{CAMP_NAME}');"
        f"delete from public.campaigns where name = '{CAMP_NAME}'")
    report()


if __name__ == "__main__":
    main()
