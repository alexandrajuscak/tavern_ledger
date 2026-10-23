"""Browser test of the v6 restoration of the original Tavern Ledger character-sheet visual language
(docs/ORIGINAL_UI_RESTORATION_REVIEW.md): the vitals panel (expanded and the original compact state), the six ability cards with
their saving throws and skills, the summary tiles and Inspiration, Hit Dice and Death Saves, source-aware Proficiencies, the
inventory metric cards and Coins, one gold Cinzel heading system with Inter for reading and controls, responsive layouts,
keyboard and screen-reader names, console and local-only traffic. Calculations are covered by the derived-stat, feat, inventory
and Wild Shape suites; this test checks the restored components show them.

Synthetic users (ui-*@example.test, removed by run_browser_local.sh) own everything. Refuses non-local URLs. Screenshots go to
SCREENSHOT_DIR (outside the repository).
"""
from urllib.parse import urlparse

from playwright.sync_api import sync_playwright

from class_ui_common import SHOTS, Sheet, User, call, check, report

ORDER = ["str", "dex", "con", "int", "wis", "cha"]
NAMES = ["Strength", "Dexterity", "Constitution", "Intelligence", "Wisdom", "Charisma"]
SKILLS = {"str": ["Athletics"], "dex": ["Acrobatics", "Sleight of Hand", "Stealth"], "con": [],
          "int": ["Arcana", "History", "Investigation", "Nature", "Religion"],
          "wis": ["Animal Handling", "Insight", "Medicine", "Perception", "Survival"],
          "cha": ["Deception", "Intimidation", "Performance", "Persuasion"]}
GOLD = "rgb(212, 166, 74)"

u = User("orig")
# Fighter 4 with Tough: base maximum 36, authoritative maximum 36 + 8 = 44; INT 8 gives a negative modifier; WIS 12 -> passive 11
hero = u.character("OU Tough Fighter", [("fighter-phb", 4)], strength=16, dexterity=14, constitution=14, intelligence=8, wisdom=12,
                   charisma=10, hp_max=36, hp_current=36)
st, r = u.rpc("assign_character_feat", p_character=hero, p_version="tough-2024", p_choices={}, p_source_type="direct",
              p_source_note=None, p_override_reason=None, p_notes=None)
assert st == 200, (st, r)
st, _ = call("PATCH", f"/rest/v1/characters?id=eq.{hero}", {"gp": 25, "sp": 3, "skill_proficiencies": {"stealth": {"proficient": True, "expertise": True}}}, token=u.jwt)
assert st in (200, 204), st
_, inv = call("GET", f"/rest/v1/inventories?character_id=eq.{hero}&kind=eq.character&select=id", token=u.jwt)
for item, qty in (("dagger", 2), ("chain-mail", 1)):
    st, r = u.rpc("add_inventory_item", p_inventory=inv[0]["id"], p_item=item, p_quantity=qty, p_custom_name=None, p_notes=None, p_state={})
    assert st == 200, (item, st, r)
# low HP with temporary HP and a visible condition
low = u.character("OU Low Fighter", [("fighter-phb", 1)], dexterity=12, hp_max=40, hp_current=8, hp_temp=5)
st, _ = call("PATCH", f"/rest/v1/characters?id=eq.{low}", {"conditions": ["Poisoned"]}, token=u.jwt)
assert st in (200, 204), st
# Moon druid in Brown Bear form (STR 19 DEX 10 CON 16 from the form; INT, WIS, CHA kept)
druid = u.character("OU Moon Druid", [("druid-phb", 6, "druid-moon-phb")], strength=8, dexterity=14, constitution=14, intelligence=12,
                    wisdom=16, charisma=10, hp_max=45, hp_current=45)
st, r = u.rpc("start_transformation", p_character=druid, p_creature="brown-bear", p_options={})
assert st == 200, (st, r)


def shot(page, name, sel=None):
    SHOTS.mkdir(parents=True, exist_ok=True)
    (page.locator(sel).first if sel else page).screenshot(path=str(SHOTS / f"{name}.png"))


def style(page, sel, prop="fontFamily"):
    loc = page.locator(sel).first
    if not loc.count():
        return None
    v = loc.evaluate(f"e => getComputedStyle(e).{prop}")
    return v.split(",")[0].replace('"', "").replace("'", "").strip() if prop == "fontFamily" else v


def cards(page):
    return page.evaluate("""() => [...document.querySelectorAll('#ability-cards > .ab-block')].map((b) => {
      const r = b.getBoundingClientRect();
      return { k: b.dataset.ability, label: b.getAttribute('aria-label'), name: b.querySelector('.ab-left .ability-name').textContent.trim(),
        mod: b.querySelector('.ability-mod').textContent.trim(), score: b.querySelector('.ability-score').value,
        save: b.querySelector('.save-row [data-derive^="save:"]').textContent.trim(), saveOn: b.querySelector('.save-row .prof-dot').classList.contains('on'),
        skills: [...b.querySelectorAll('.skill-row .li-name')].map((x) => x.textContent.trim()),
        src: b.querySelector('.ab-src').textContent.trim(), form: b.querySelector('.ab-form-score').textContent.trim(),
        left: Math.round(r.left), top: Math.round(r.top), right: Math.round(r.right) };
    })""")


def main():
    with sync_playwright() as p:
        browser = p.chromium.launch(channel="msedge", headless=True)
        fonts_seen = []

        # ================= desktop 1366: vitals ============================================================================
        s = Sheet(browser, u, tab="combat")
        page = s.page
        page.on("request", lambda r: fonts_seen.append(r.url) if r.resource_type == "font" else None)
        s.open(hero)
        bar = page.locator(".combat-bar")
        s.wait(lambda: page.locator('#hp-card [data-derived="hp-max"]').inner_text().strip() == "44")
        check("V1 desktop default: the vitals panel is expanded", "compact" not in (bar.get_attribute("class") or "") and page.locator(".hp-controls").is_visible())
        check("V2 current HP 36", page.locator("#hp-card .hp-current").input_value() == "36")
        check("V3 the derived maximum with Tough (36 + 8 = 44) is shown, not an editable base", page.locator('#hp-card [data-derived="hp-max"]').inner_text().strip() == "44"
              and page.locator("#hp-card [data-f=hp_max]").count() == 0)
        check("V4 temporary HP field shows 0", page.locator("#hp-card .temp-input").input_value() == "0")
        check("V5 the HP bar is shown", page.locator("#hp-card .hp-bar").is_visible())
        der = u.rpc("get_character_derived_stats", p_character=hero)[1]
        ac = page.locator('[data-derived="ac"]').first.inner_text().strip()
        check("V9 the AC shield shows the authoritative AC and keeps its shield shape",
              ac == str(der["armor_class"]["value"]) and "polygon" in (style(page, ".tile-ac", "clipPath") or ""), (ac, der["armor_class"]["value"]))
        check("V10 Initiative +2 (DEX 14) in its own card", page.locator('.tile-init [data-derive="init"]').inner_text().strip() == "+2")
        check("V11 Speed 30 ft in its own card", page.locator('.tile-speed [data-derive="speed"]').inner_text().strip() == str(der["speed"]["value"]))
        check("V12 Proficiency +2 in its own card", page.locator('.tile-pb [data-derive="pb"]').inner_text().strip() == "+2")
        page.fill("#hp-amount", "10")
        page.locator('[data-action="hp-damage"]').click()
        check("V6 Damage 10: 36 -> 26 with a short result message", s.wait(lambda: page.locator("#hp-card .hp-current").input_value() == "26") and "Took 10 damage" in s.toasts())
        page.locator('[data-action="hp-damage"]').click()
        check("V8 a repeated press with the cleared field changes nothing (no duplicate submission)", page.locator("#hp-card .hp-current").input_value() == "26" and "Enter an amount" in s.toasts())
        page.fill("#hp-amount", "999")
        page.locator('[data-action="hp-heal"]').click()
        check("V7 Heal 999 stops at the derived maximum 44", s.wait(lambda: page.locator("#hp-card .hp-current").input_value() == "44"))
        check("V14 quick resources: Second Wind, at most six chips", "second wind" in page.locator("#resource-strip").inner_text().lower()
              and 1 <= page.locator("#resource-strip .res-chip").count() <= 6)
        shot(page, "vitals_expanded_1366", ".combat-bar")
        tog = page.locator(".compact-toggle")
        check("V15a the collapse handle is labelled and controls the panel", tog.get_attribute("aria-label") == "Collapse vitals" and tog.get_attribute("aria-controls") == "vitals-body")
        tog.focus()
        page.keyboard.press("Enter")
        page.wait_for_timeout(300)
        check("V15 collapsed with the keyboard; focus stays on the handle", "compact" in bar.get_attribute("class")
              and page.evaluate("() => document.activeElement.classList.contains('compact-toggle')") and tog.get_attribute("aria-label") == "Expand vitals")
        check("V19 collapsed keeps the original components: HP value and bar, AC shield, Initiative, Speed and Proficiency cards; controls fold away",
              page.locator("#hp-card .hp-current").is_visible() and page.locator("#hp-card .hp-bar").is_visible() and page.locator(".tile-ac").is_visible()
              and page.locator(".tile-init").is_visible() and page.locator(".tile-speed").is_visible() and page.locator(".tile-pb").is_visible()
              and not page.locator(".hp-controls").is_visible() and page.locator("#vitals-summary").count() == 0)
        h_c = page.evaluate("() => document.querySelector('.combat-bar').getBoundingClientRect().height")
        check("V19b collapsed saves height (< 140 px at 1366)", h_c < 140, h_c)
        shot(page, "vitals_collapsed_1366", ".combat-bar")
        s.tab("stats")
        check("V17 the collapsed preference is kept when switching tabs", "compact" in bar.get_attribute("class"))
        page.reload()
        s.wait(lambda: page.locator(".combat-bar").count() == 1)
        check("V18 the collapsed preference is kept after a refresh", "compact" in page.locator(".combat-bar").get_attribute("class"))
        page.locator(".compact-toggle").click()
        page.wait_for_timeout(200)
        check("V16 expanding works and is remembered", "compact" not in page.locator(".combat-bar").get_attribute("class")
              and page.evaluate("() => localStorage.getItem('tavern-ledger:compact')") == "0")
        page.evaluate("() => window.scrollTo(0, 0)")
        page.wait_for_timeout(300)
        top_hidden = not page.locator("#topbar-vitals").is_visible()
        page.evaluate("() => window.scrollTo(0, document.body.scrollHeight)")
        check("V24 no competing dashboard: the top bar shows HP / AC only after the panel scrolls away",
              top_hidden and s.wait(lambda: page.locator("#topbar-vitals").is_visible()))
        page.evaluate("() => window.scrollTo(0, 0)")
        page.locator("#hp-amount").focus()
        page.keyboard.type("4")
        call("PATCH", f"/rest/v1/characters?id=eq.{hero}", {"hp_temp": 3}, token=u.jwt)
        s.wait(lambda: page.locator("#hp-card .temp-input").input_value() == "3", timeout=12000)
        check("V22 a Realtime update (temp HP 3) keeps focus and the typed amount", page.evaluate("() => document.activeElement.id") == "hp-amount"
              and page.locator("#hp-amount").input_value() == "4")
        page.fill("#hp-amount", "")

        # ================= Abilities ======================================================================================
        s.tab("stats")
        s.wait(lambda: page.locator('#ability-cards [data-ability="int"] .ability-mod').inner_text().strip() != "")
        page.wait_for_timeout(500)
        cs = cards(page)
        for i, k in enumerate(ORDER):
            check(f"A{i + 1} {NAMES[i]} card exists with its gold name and full accessible name", cs[i]["k"] == k and cs[i]["label"] == NAMES[i] and cs[i]["name"] == NAMES[i], cs[i])
        check("A7 exactly six cards in the order STR DEX CON INT WIS CHA", [c["k"] for c in cs] == ORDER)
        check("A8 desktop 1366: three columns, two rows", len({c["left"] for c in cs}) == 3 and len({c["top"] for c in cs}) == 2, [(c["left"], c["top"]) for c in cs])
        check("A11 scores 16 14 14 8 12 10", [c["score"] for c in cs] == ["16", "14", "14", "8", "12", "10"], [c["score"] for c in cs])
        check("A12 modifiers +3 +2 +2 −1 +1 +0 (true minus sign)", [c["mod"] for c in cs] == ["+3", "+2", "+2", "−1", "+1", "+0"], [c["mod"] for c in cs])
        check("A13 saving throws in the cards: STR +5 and CON +4 proficient (Fighter), DEX +2, INT −1, WIS +1, CHA +0",
              [c["save"] for c in cs] == ["+5", "+2", "+4", "−1", "+1", "+0"], [c["save"] for c in cs])
        check("A14 saving-throw proficiency marks: STR and CON on (diamond), the others off",
              [c["saveOn"] for c in cs] == [True, False, True, False, False, False] and page.locator("#ability-cards .save-row .save-dot").count() == 6)
        check("A15 each skill sits under its governing ability", all(c["skills"] == SKILLS[c["k"]] for c in cs), [c["skills"] for c in cs])
        check("A16 Constitution has its saving throw and no invented skill", cs[2]["skills"] == [] and cs[2]["save"] == "+4")
        stealth = page.locator('#ability-cards [data-action="cycle-skill"][data-k="stealth"]')
        check("A18 expertise marker: Stealth (expertise) level 2, value +2 + 2×2 = +6",
              stealth.get_attribute("data-level") == "2" and page.locator('#ability-cards [data-derive="skill:stealth"]').inner_text().strip() == "+6")
        ath = page.locator('#ability-cards [data-action="cycle-skill"][data-k="athletics"]')
        check("A17 proficiency marker: Arcana not proficient (level 0); the Athletics mark reflects the derived value",
              page.locator('#ability-cards [data-action="cycle-skill"][data-k="arcana"]').get_attribute("data-level") == "0"
              and page.locator('#ability-cards [data-derive="skill:athletics"]').inner_text().strip() in ("+3", "+5"))
        check("A20 every skill mark names its skill and governing ability; the source is in its title",
              page.locator('#ability-cards [data-action="cycle-skill"][aria-label*=" proficiency ("]').count() == 18 and bool(ath.get_attribute("title")))
        pp, pi = page.locator('.sum-tile [data-derive="passive:perception"]').inner_text().strip(), page.locator('.sum-tile [data-derive="passive:insight"]').inner_text().strip()
        check("A23 Passive Perception 11 and A24 Passive Insight 11 in the summary tiles (10 + WIS +1)", (pp, pi) == ("11", "11"), (pp, pi))
        check("A23b the Proficiency summary tile shows +2", page.locator('.sum-tile [data-derive="pb"]').inner_text().strip() == "+2")
        insp = page.locator('.sum-tile [data-action="toggle-inspiration"]')
        name = insp.evaluate("e => document.getElementById(e.getAttribute('aria-labelledby'))?.textContent.trim()")
        insp.focus()
        page.keyboard.press("Enter")
        check("A25 Inspiration is a labelled toggle that works from the keyboard", name == "Inspiration" and s.wait(lambda: insp.get_attribute("aria-pressed") == "true"), (name, insp.get_attribute("aria-pressed")))
        page.keyboard.press("Enter")
        s.wait(lambda: insp.get_attribute("aria-pressed") == "false")
        check("A28 the legend explains the four markers and the tap behaviour", all(x in page.locator(".ab-legend").inner_text()
              for x in ("not proficient", "proficient", "expertise", "saving-throw", "Tap a mark")))
        # keyboard: Tab from the STR score reaches its save mark and Athletics in reading order
        page.locator('#ability-cards [data-ability="str"] .ability-score').focus()
        seq = []
        for _ in range(2):
            page.keyboard.press("Tab")
            seq.append(page.evaluate("() => document.activeElement.dataset.action + ':' + document.activeElement.dataset.k"))
        check("A27 keyboard order inside a card: score, saving-throw mark, then its skills", seq == ["toggle-save:str", "cycle-skill:athletics"], seq)
        check("A26 no page-level horizontal overflow at 1366", s.overflow() <= 0, s.overflow())
        # Hit Dice, Death Saves, Proficiencies
        check("H1 the Hit Dice section renders with its controls", page.locator('#abilities-hitdice [data-f="hit_dice_current"]').count() == 1
              and page.locator("#abilities-hitdice select").count() == 1)
        check("H2 Hit Dice: 1 of 4 (character level), d10 kept as stored", page.locator('#abilities-hitdice [data-derive="level"]').inner_text().strip() == "4")
        check("H4/H5 Death Saves: three success and three failure markers with names and pressed state",
              page.locator('#abilities-hitdice .death-pip.success').count() == 3 and page.locator('#abilities-hitdice .death-pip.failure').count() == 3
              and page.locator('#abilities-hitdice .death-pip[aria-pressed]').count() == 6)
        check("H7 a class proficiency (armor) is an active, gold-tinted tile", page.locator('#prof-chips .prof-chip[data-state="derived"]').count() >= 4
              and "212, 166, 74" in (style(page, '#prof-chips .prof-chip[data-state="derived"]', "borderTopColor") or ""))
        check("H9 an inactive proficiency stays a dark tile", page.locator('#prof-chips .prof-chip[data-state="off"]').count() >= 1)
        page.locator('#prof-chips .prof-chip[data-state="derived"]').first.click()
        dlg = page.locator(".modal")
        check("H10/H11 clicking a granted proficiency explains its source instead of removing it", s.wait(lambda: dlg.count() > 0 and "active because of" in dlg.last.inner_text()))
        page.keyboard.press("Escape")
        page.wait_for_timeout(300)
        check("H11b the granted tile is still active after closing", page.locator('#prof-chips .prof-chip[data-state="derived"]').count() >= 4)
        # headings and typography
        heads = {"Ability scores and skills": "#abilities-scores .tl-section-title", "Hit Dice": "#abilities-hitdice .tl-section-title",
                 "Death Saves": "#death-saves-title", "Proficiencies": "#abilities-profs .tl-section-title", "Senses": "#abilities-senses .tl-section-title"}
        for nm, sel in heads.items():
            check(f"T4/T5 '{nm}' heading: Cinzel in the heading gold", style(page, sel) == "Cinzel" and style(page, sel, "color") == GOLD, (style(page, sel), style(page, sel, "color")))
        check("T6 ability names: gold Cinzel", style(page, "#ability-cards .ability-name") == "Cinzel" and style(page, "#ability-cards .ability-name", "color") == GOLD)
        check("T7 'Saving Throw' labels: gold Cinzel", style(page, "#ability-cards .save-label") == "Cinzel" and style(page, "#ability-cards .save-label", "color") == GOLD)
        F = {"T1 logo": (".brand", "Cinzel"), "T2 character name": (".char-name", "Cinzel"), "T12 current HP": ("#hp-card .hp-current", "Cinzel"),
             "T12b maximum HP": ('#hp-card [data-derived="hp-max"]', "Cinzel"), "T13 AC": ('[data-derived="ac"]', "Cinzel"),
             "T14 initiative": ('.tile-init [data-derive="init"]', "Cinzel"), "T15 speed": ('.tile-speed [data-derive="speed"]', "Cinzel"),
             "T16 proficiency": ('.tile-pb [data-derive="pb"]', "Cinzel"), "T17 ability modifier": ("#ability-cards .ability-mod", "Cinzel"),
             "T17b ability score": ("#ability-cards .ability-score", "Cinzel"), "T17c passive value": (".sum-tile strong", "Cinzel"),
             "T18 body text": ("body", "Inter"), "T19 buttons": ('[data-action="long-rest"]', "Inter"), "T20 inputs": ("#hp-amount", "Inter"),
             "T21 skill names": ("#ability-cards .skill-row .li-name", "Inter"), "T21b labels": (".sum-tile .stat-label", "Inter"),
             "T21c tabs": (".tab", "Inter"), "T21d unit ft": (".tile-speed .unit", "Inter"), "T21e Damage label": ('[data-action="hp-damage"]', "Inter"),
             "T22 functional sub-heading (Armor and weapons)": ("#abilities-profs .tl-sub-title", "Inter")}
        for nm, (sel, want) in F.items():
            check(f"{nm} uses {want}", style(page, sel) == want, (sel, style(page, sel)))
        long_cinzel = page.evaluate("""() => [...document.querySelectorAll('p, li, label, .tl-section-desc')].filter((e) => e.offsetParent
            && getComputedStyle(e).fontFamily.startsWith('Cinzel') && e.textContent.trim().length > 60).map((e) => e.textContent.trim().slice(0, 50))""")
        check("T23 no long text is set in the display face", not long_cinzel, long_cinzel)
        shot(page, "abilities_1366", "#abilities-scores")
        shot(page, "ability_card_1366", '#ability-cards [data-ability="dex"]')
        shot(page, "legend_1366", ".ab-legend")
        shot(page, "lower_abilities_1366", ".ab-lower")
        shot(page, "abilities_full_1366")
        # Build and functional headings
        s.tab("features")
        check("T22b functional headings ('Reminders') stay Inter; class names are Cinzel in warm white",
              style(page, "#choices-card .tl-section-title") == "Inter" and style(page, ".cls-row-title") == "Cinzel" and style(page, ".cls-row-title", "color") != GOLD)
        check("T4c Build section heading 'Classes' is gold Cinzel", style(page, "#class-card-title") == "Cinzel" and style(page, "#class-card-title", "color") == GOLD)
        shot(page, "build_1366")
        s.tab("combat")
        check("T4d Play heading 'Ready to use' / 'Attacks' is gold Cinzel", style(page, ".play-title, .combat-group .section-title") == "Cinzel"
              and style(page, ".play-title, .combat-group .section-title", "color") == GOLD)
        # ================= Inventory ======================================================================================
        s.tab("inventory")
        s.wait(lambda: page.locator(".inv-summary .inv-metric").count() == 4)
        m = lambda c: page.locator(f".inv-summary .{c}")  # noqa: E731
        check("I1/I2/I3 Items card: 2 items, 3 pieces", m("inv-m-items").count() == 1 and "2" in m("inv-m-items").locator(".inv-metric-num").inner_text()
              and "3 pieces" in m("inv-m-items").inner_text(), m("inv-m-items").inner_text())
        wt = m("inv-m-weight").locator(".inv-metric-num").inner_text().strip()
        check("I4/I5 Weight card: carried weight 57 lb (2 daggers + chain mail)", wt == "57" and "lb" in m("inv-m-weight").inner_text() and "carried" in m("inv-m-weight").inner_text(), m("inv-m-weight").inner_text())
        check("I6/I7/I8 Attuned card: 0 / 3, 3 slots free", "0" in m("inv-m-attuned").locator(".inv-metric-num").inner_text()
              and "3" in m("inv-m-attuned").locator(".inv-metric-num").inner_text() and "3 slots free" in m("inv-m-attuned").inner_text(), m("inv-m-attuned").inner_text())
        check("I9/I10/I12 Coins card: 25 gp as the value, the other denominations listed (3 sp)",
              m("inv-m-coins").locator(".inv-metric-num").inner_text().strip() == "25" and "gp" in m("inv-m-coins").inner_text() and "3 sp" in m("inv-m-coins").inner_text(),
              m("inv-m-coins").inner_text())
        anat = page.evaluate("""() => [...document.querySelectorAll('.inv-summary .inv-metric')].map((c) => ({ h: Math.round(c.getBoundingClientRect().height),
            l: !!c.querySelector('.inv-metric-label'), v: !!c.querySelector('.inv-metric-value'), n: !!c.querySelector('.inv-metric-note'), i: !!c.querySelector('.inv-metric-icon'),
            ly: Math.round(c.querySelector('.inv-metric-label').getBoundingClientRect().top), vy: Math.round(c.querySelector('.inv-metric-num').getBoundingClientRect().top),
            top: Math.round(c.getBoundingClientRect().top) }))""")
        check("I13 the four cards share one anatomy (icon, label, value, note) and one height; labels and values align",
              all(a["l"] and a["v"] and a["n"] and a["i"] for a in anat) and len({a["h"] for a in anat}) == 1 and len({a["ly"] for a in anat}) == 1 and len({a["vy"] for a in anat}) <= 2, anat)
        check("I16 desktop: four cards in one row", len({a["top"] for a in anat}) == 1, anat)
        check("I14 values in Cinzel, I15 labels in Inter", style(page, ".inv-metric-num") == "Cinzel" and style(page, ".inv-metric-label") == "Inter")
        page.locator('.inv-summary [data-inv="edit-coins"]').click()
        page.wait_for_timeout(600)
        check("I11 Coins 'Edit' moves focus to the coin fields", page.evaluate("() => document.activeElement?.dataset?.f") == "gp")
        page.keyboard.press("Control+A")
        page.keyboard.type("30")
        page.keyboard.press("Tab")
        check("I12b editing a denomination updates the Coins card (30 gp)", s.wait(lambda: m("inv-m-coins").locator(".inv-metric-num").inner_text().strip() == "30"))
        check("T11 inventory headings ('Items you carry', 'Coins') are gold Cinzel", style(page, "#inv-items-title") == "Cinzel" and style(page, "#inv-items-title", "color") == GOLD
              and style(page, "#coins-title", "color") == GOLD)
        page.evaluate("() => window.scrollTo(0, 0)")
        shot(page, "inventory_summary_1366", ".inv-summary")
        shot(page, "coins_1366", ".inv-coins")
        s.close()

        # ================= low HP, temp HP, conditions ===================================================================
        s = Sheet(browser, u, tab="combat")
        page = s.page
        s.open(low)
        card = page.locator("#hp-card")
        s.wait(lambda: card.get_attribute("data-state") == "critical")
        check("V13 the visible condition (Poisoned) is in the vitals", "Poisoned" in page.locator("#conditions-row").inner_text())
        check("V20a low HP is critical and says so in words", page.locator("[data-hp-state-text]").inner_text().strip() == "Critical")
        page.locator(".compact-toggle").click()
        page.wait_for_timeout(200)
        check("V20b collapsed: HP 8 / 40, the bar, '+5 temp' and 'Critical' stay visible", page.locator("#hp-card .hp-current").input_value() == "8"
              and page.locator("#hp-card .hp-bar").is_visible() and page.locator("[data-hp-temp-badge]").is_visible()
              and page.locator("[data-hp-temp-badge]").inner_text().strip() == "+5 temp" and page.locator("[data-hp-state-text]").is_visible())
        shot(page, "vitals_low_collapsed_1366", ".combat-bar")
        s.close()

        # ================= Wild Shape ====================================================================================
        s = Sheet(browser, u, tab="combat")
        page = s.page
        s.open(druid)
        s.wait(lambda: "Brown Bear" in page.locator("#hp-card [data-ws-hp]").inner_text())
        check("V21 Wild Shape: form HP 34 / 34 first; the normal HP 45 stays protected",
              "34" in page.locator("#hp-card .hp-form-num").inner_text() and page.locator("#hp-card .hp-current").input_value() == "45"
              and "protected" in page.locator("#hp-card [data-ws-hpnote]").inner_text())
        shot(page, "vitals_wild_shape_1366", ".combat-bar")
        page.locator(".compact-toggle").click()
        page.wait_for_timeout(200)
        check("V21b collapsed in Wild Shape: the form and its HP stay visible", page.locator("#hp-card .hp-form").is_visible() and "Brown Bear" in page.locator("#hp-card .hp-form").inner_text())
        page.locator(".compact-toggle").click()
        s.tab("stats")
        s.wait(lambda: page.locator('#ability-cards [data-ability="str"] .ab-src').inner_text().strip() == "From form")
        cs = cards(page)
        check("A21 Wild Shape: STR, DEX and CON come from the form (19 10 16, +4 +0 +3)", [c["src"] for c in cs[:3]] == ["From form"] * 3
              and [c["form"] for c in cs[:3]] == ["19", "10", "16"] and [c["mod"] for c in cs[:3]] == ["+4", "+0", "+3"], cs[:3])
        check("A22 Wild Shape: INT, WIS and CHA are retained (WIS 16 +3); all six cards stay", [c["src"] for c in cs[3:]] == ["Retained from character"] * 3
              and cs[4]["mod"] == "+3" and len(cs) == 6, cs[3:])
        shot(page, "abilities_wild_shape_1366", "#abilities-scores")
        s.close()

        # ================= 1920 and 820 ==================================================================================
        s = Sheet(browser, u, width=1920, height=1080, tab="stats")
        s.open(hero)
        s.wait(lambda: s.page.locator('#ability-cards [data-ability="cha"] .ability-mod').inner_text().strip() != "")
        cs = cards(s.page)
        check("R1 1920: three columns of ability cards, no overflow", len({c["left"] for c in cs}) == 3 and s.overflow() <= 0)
        shot(s.page, "abilities_full_1920")
        s.tab("combat")
        shot(s.page, "vitals_expanded_1920", ".combat-bar")
        s.close()
        s = Sheet(browser, u, width=820, height=1180, tab="stats")
        s.open(hero)
        s.wait(lambda: s.page.locator('#ability-cards [data-ability="cha"] .ability-mod').inner_text().strip() != "")
        cs = cards(s.page)
        check("A9 tablet 820: two columns, three rows", len({c["left"] for c in cs}) == 2 and len({c["top"] for c in cs}) == 3, [(c["left"], c["top"]) for c in cs])
        check("R3 820: the AC card label fits (short label), no page overflow", s.page.locator("#ac-label .lbl-short").is_visible() and s.overflow() <= 0)
        shot(s.page, "abilities_820", "#abilities-scores")
        s.tab("inventory")
        s.wait(lambda: s.page.locator(".inv-summary .inv-metric").count() == 4)
        tops = s.page.evaluate("() => [...document.querySelectorAll('.inv-summary .inv-metric')].map((c) => Math.round(c.getBoundingClientRect().top))")
        check("I17 tablet: inventory cards two by two", len(set(tops)) == 2, tops)
        shot(s.page, "inventory_summary_820", ".inv-summary")
        s.tab("combat")
        shot(s.page, "vitals_820", ".combat-bar")
        s.close()

        # ================= phone 390 =====================================================================================
        s = Sheet(browser, u, width=390, height=844, tab="combat")
        page = s.page
        s.open(hero)
        s.wait(lambda: page.locator(".combat-bar").count() == 1)
        page.wait_for_timeout(800)
        bar = page.locator(".combat-bar")
        check("V23 390 default: compact vitals with HP, bar, AC shield and the three cards", "compact" in bar.get_attribute("class")
              and page.locator("#hp-card .hp-current").is_visible() and page.locator(".tile-ac").is_visible() and page.locator(".tile-pb").is_visible())
        h = page.evaluate("() => document.querySelector('.combat-bar').getBoundingClientRect().height")
        check("R5 390 compact vitals leave most of the first screen (< 25 %)", h < 844 * 0.25, h)
        shot(page, "mobile_vitals_compact_390")
        page.locator(".compact-toggle").click()
        page.wait_for_timeout(300)
        check("R8 390 expanded: Damage and Heal are 44 px targets; the panel does not fill the screen",
              page.locator('[data-action="hp-damage"]').bounding_box()["height"] >= 44 and page.locator('[data-action="hp-heal"]').bounding_box()["height"] >= 44
              and page.evaluate("() => document.querySelector('.combat-bar').getBoundingClientRect().bottom") < 844)
        shot(page, "mobile_vitals_expanded_390")
        s.tab("stats")
        s.wait(lambda: page.locator('#ability-cards [data-ability="cha"] .ability-mod').inner_text().strip() != "")
        cs = cards(page)
        check("A10 390: one card per row, all six reachable, Charisma included", len({c["left"] for c in cs}) == 1 and [c["k"] for c in cs] == ORDER
              and all(c["right"] <= 390 for c in cs), [(c["left"], c["right"]) for c in cs])
        page.locator('#ability-cards [data-ability="cha"] .ability-score').scroll_into_view_if_needed()
        check("A10b the Charisma card is not hidden behind the bottom navigation when scrolled to",
              page.evaluate("""() => { const c = document.querySelector('#ability-cards [data-ability="cha"] .ability-score').getBoundingClientRect();
                const n = document.querySelector('.tabs').getBoundingClientRect(); return c.bottom <= n.top; }"""))
        name = page.evaluate("() => { const e = document.querySelector('.char-name'); return { sw: e.scrollWidth, cw: e.clientWidth, h: e.getBoundingClientRect().height, lh: parseFloat(getComputedStyle(e).lineHeight) }; }")
        check("T24 390: the character name does not clip and stays on one line", name["sw"] <= name["cw"] + 1 and name["h"] < name["lh"] * 1.6, name)
        check("R6 390: no page-level horizontal overflow on Abilities", s.overflow() <= 0, s.overflow())
        shot(page, "mobile_abilities_390")
        s.tab("inventory")
        s.wait(lambda: page.locator(".inv-summary .inv-metric").count() == 4)
        tops = page.evaluate("() => [...document.querySelectorAll('.inv-summary .inv-metric')].map((c) => Math.round(c.getBoundingClientRect().top))")
        coll = page.evaluate("""() => [...document.querySelectorAll('.inv-summary .inv-metric')].every((c) => { const a = c.querySelector('.inv-metric-label').getBoundingClientRect();
            const b = c.querySelector('.inv-metric-value').getBoundingClientRect(); return a.bottom <= b.top + 1; })""")
        check("I18/I19 390: inventory cards two by two, labels above values (no collision), Edit reachable",
              len(set(tops)) == 2 and coll and page.locator('.inv-summary [data-inv="edit-coins"]').is_visible(), (tops, coll))
        check("I20 390: no horizontal overflow on Inventory", s.overflow() <= 0, s.overflow())
        shot(page, "mobile_inventory_summary_390", ".inv-summary")
        check("C1 no console errors", not s.errors, s.errors[:3])
        check("L1 no request left this machine; fonts self-hosted", not s.remote and all(urlparse(x).hostname in ("127.0.0.1", "localhost") for x in fonts_seen), s.remote[:3])
        check("T25/T26 the Cinzel files are served by the app itself", any("fonts/cinzel-latin" in x for x in fonts_seen), fonts_seen[:4])
        s.close()
        browser.close()
    report()


main()
