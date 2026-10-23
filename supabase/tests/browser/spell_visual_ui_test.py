"""Browser test of the spell visual system (docs/SPELL_VISUAL_SYSTEM.md) against the LOCAL stack.

A Wizard 9 with spells of every relevant shape: school identity on the card (edge from the school token, school named in
text), damage chips (Fire orange, Necrotic deep green, distinct from the Necromancy school green), "choose one" and
"deals both" groups, Temp HP and no-damage spells, readiness first, no inline styles, keyboard focus, 390 px, no errors.
"""
import re

from playwright.sync_api import sync_playwright

from class_ui_common import Sheet, User, call, check, report

SPELLS = ["fire-bolt-phb", "chill-touch-phb", "fireball-phb", "chromatic-orb-phb", "shield-phb", "cure-wounds-phb", "ice-storm-phb",
          "blight-phb", "hold-person-phb", "invisibility-phb", "detect-magic-phb", "polymorph-phb", "conjure-elemental-phb", "dispel-magic-phb"]


def rgb(hexv):
    h = hexv.strip().lstrip("#")
    return f"rgb({int(h[0:2], 16)}, {int(h[2:4], 16)}, {int(h[4:6], 16)})"


def main():
    u = User("spellvis")
    ch = u.character("Spell Visual Tester", [("wizard-phb", 9), ("cleric-phb", 1)], intelligence=18, wisdom=14)
    _, rows = call("GET", f"/rest/v1/character_spellcasting_sources?character_id=eq.{ch}&select=id,class_version_id", token=u.jwt)
    src = {("cleric" if (r["class_version_id"] or "").startswith("cleric") else "wizard"): r["id"] for r in rows}
    for sp in SPELLS:
        st, r = u.rpc("set_character_spell", p_character=ch, p_source=src["cleric" if sp == "cure-wounds-phb" else "wizard"], p_spell_version=sp, p_known=True,
                      p_prepared=sp in ("fireball-phb", "shield-phb"), p_always_prepared=False, p_casting_ability=None, p_ritual_allowed=None, p_notes=None)
        assert st == 200, (sp, st, r)
    with sync_playwright() as p:
        browser = p.chromium.launch(channel="msedge", headless=True)
        s = Sheet(browser, u, tab="spells")
        page = s.page
        s.open(ch)
        s.tab("spells")
        page.wait_for_selector("#spellbook-list .sp-card", timeout=20000)
        page.wait_for_timeout(800)
        card = lambda name: page.locator("#spellbook-list .sp-card", has=page.locator(".sp-name", has_text=re.compile(f"^{re.escape(name)}$")))  # noqa: E731
        tok = lambda name: page.evaluate(f"() => getComputedStyle(document.documentElement).getPropertyValue('{name}').trim()")  # noqa: E731
        edge = lambda name: card(name).evaluate("e => getComputedStyle(e).borderLeftColor")  # noqa: E731
        chip_color = lambda name, dmg: card(name).locator(f".dmg-chip[data-dmg={dmg}]").first.evaluate("e => getComputedStyle(e).borderTopColor")  # noqa: E731

        schools = {k: tok(f"--school-{k}") for k in ("abjuration", "conjuration", "divination", "enchantment", "evocation", "illusion", "necromancy", "transmutation")}
        dmg = {k: tok(f"--dmg-{k}") for k in ("acid", "bludgeoning", "cold", "fire", "force", "lightning", "necrotic", "piercing", "poison", "psychic",
                                              "radiant", "slashing", "thunder")}
        check("SV1 every school (8) and damage type (13) has its own token, all different",
              all(schools.values()) and len(set(schools.values())) == 8 and all(dmg.values()) and len(set(dmg.values())) == 13, (schools, dmg))
        check("SV2 the card edge comes from the school (Fireball: Evocation red; Blight: Necromancy green) and the school is named in text",
              edge("Fireball") == rgb(schools["evocation"]) and edge("Blight") == rgb(schools["necromancy"])
              and "Evocation" in card("Fireball").locator(".sp-school").inner_text() and "Necromancy" in card("Blight").locator(".sp-school").inner_text(),
              (edge("Fireball"), edge("Blight")))
        check("SV3 Fire damage is an orange chip and Necrotic a deep green chip that differs from the Necromancy school green",
              chip_color("Fire Bolt", "fire") == rgb(dmg["fire"]) and chip_color("Blight", "necrotic") == rgb(dmg["necrotic"])
              and dmg["necrotic"] != schools["necromancy"] and "Necrotic" in card("Blight").locator(".dmg-chip").inner_text())
        orb = card("Chromatic Orb").locator(".dmg-choice")
        check("SV4 a choose-one spell shows every option under 'Choose one' joined by 'or' (Chromatic Orb: 6 types)",
              orb.count() == 1 and orb.locator(".dmg-chip").count() == 6 and "Choose one" in orb.text_content()
              and "Choose one damage type" in (orb.get_attribute("aria-label") or ""), orb.inner_text() if orb.count() else "")
        storm = card("Ice Storm").locator(".dmg-both")
        check("SV5 a spell dealing two types shows both joined by '+' (Ice Storm: Bludgeoning + Cold)",
              storm.count() == 1 and storm.locator(".dmg-chip").count() == 2 and "Bludgeoning" in storm.text_content() and "Cold" in storm.text_content()
              and "+" in storm.text_content() and "Deals Bludgeoning and Cold" in (storm.get_attribute("aria-label") or ""),
              card("Ice Storm").inner_text()[:200])
        check("SV6 healing gets its own chip (Cure Wounds: Healing); a spell without damage gets no damage color (Shield, Invisibility)",
              card("Cure Wounds").locator(".dmg-chip[data-effect=healing]").count() == 1
              and card("Shield").locator(".dmg-chip").count() == 0 and card("Invisibility").locator(".dmg-chip").count() == 0)
        first = card("Fireball").locator(".sp-tags .sp-ready")
        check("SV7 readiness is the first chip: Prepared (Fireball), Not prepared (Polymorph, spellbook), Ready (cantrip); level beside it",
              first.inner_text().strip() == "Prepared" and card("Polymorph").locator(".sp-ready").inner_text().strip() == "Not prepared"
              and card("Fire Bolt").locator(".sp-ready").inner_text().strip() == "Ready" and "3rd level" in card("Fireball").locator(".sp-level").inner_text())
        check("SV8 concentration, ritual and the slot are text badges (Hold Person: Concentration, Slot 2nd+; Detect Magic: Ritual)",
              "Concentration" in card("Hold Person").inner_text() and "Slot 2nd+" in card("Hold Person").inner_text()
              and "Ritual" in card("Detect Magic").locator(".sp-ritual").inner_text())
        inline = page.evaluate("() => document.querySelectorAll('#spellbook-list [style]').length")
        check("SV9 no inline styles on the spell cards (colors come from tokens via data attributes)", inline == 0, inline)
        name_btn = card("Blight").locator(".sp-name")
        name_btn.focus()
        ring = card("Blight").evaluate("e => getComputedStyle(e).boxShadow")
        check("SV10 keyboard focus inside a card shows a visible ring in the school color", ring and ring != "none" and rgb(schools["necromancy"]) in ring, ring)
        page.keyboard.press("Enter")
        dlg = page.locator(".modal").last
        dlg.wait_for(timeout=5000)
        check("SV11 the detail dialog repeats the school badge and the damage chips (Blight: Necromancy, Necrotic)",
              dlg.locator(".sp-school[data-school=necromancy]").count() == 1 and dlg.locator(".dmg-chip[data-dmg=necrotic]").count() >= 1)
        page.keyboard.press("Escape")
        page.set_viewport_size({"width": 390, "height": 844})
        page.wait_for_timeout(500)
        check("SV12 390 px: no horizontal overflow", s.overflow() <= 0, s.overflow())
        check("SV13 no browser errors and only local network traffic", not s.errors and not s.remote, (s.errors[:3], s.remote[:3]))
        s.close()
        browser.close()
    report()


if __name__ == "__main__":
    main()
