"""Browser test of the spellcaster phase (Wizard + Evocation, Sorcerer + Draconic, Cleric + Life, Bard + Lore) and the
redesigned Spells tab: source summary (DC / attack, spellbook summary), Add Spell with the spellbook record, readiness
groups (ready / not prepared), prepare toggle, Arcane Recovery dialog, Flexible Casting (create a slot, use the temporary
slot), domain spells always prepared, Magical Secrets from any list up to the castable level, mobile layout, keyboard,
local-only network, no console errors.
"""
from playwright.sync_api import sync_playwright

from class_ui_common import SHOTS, Sheet, User, check, report


def main():
    u = User("casters")
    wiz = u.character("Wizard UI Tester", [("wizard-phb", 5, "wizard-evocation-phb")], intelligence=16, dexterity=14)
    sor = u.character("Sorcerer UI Tester", [("sorcerer-phb", 3, "sorcerer-draconic-bloodline-phb")], charisma=16, dexterity=14)
    cle = u.character("Cleric UI Tester", [("cleric-phb", 3, "cleric-life-phb")], wisdom=16)
    bard = u.character("Bard UI Tester", [("bard-phb", 10)], charisma=16)
    SHOTS.mkdir(parents=True, exist_ok=True)
    with sync_playwright() as p:
        browser = p.chromium.launch(channel="msedge", headless=True)
        s = Sheet(browser, u, tab="spells")
        page = s.page
        s.open(wiz)
        s.tab("spells")
        src = page.locator("#spellcasting-sources .sp-source").first
        check("SP1 the Wizard source is named after the class (not the school) and leads with Save DC 14 and attack +6",
              s.wait(lambda: "WIZARD" in src.inner_text().upper() and "14" in src.locator("[data-source-stats]").inner_text()
                     and "+6" in src.locator("[data-source-stats]").inner_text()), src.inner_text()[:300])
        check("SP2 the spellbook summary shows 0 spells of 14 free at Wizard 5; the empty list explains what to do",
              "14 free by your level" in src.inner_text() and "spellbook should hold 14 spells" in page.locator("#spellbook-list").inner_text())
        check("SP3 the old free-text spells and manual slots are folded away",
              not page.locator("[data-legacy-spells]").evaluate("d => d.open"))
        # ---- Add Spell with the spellbook record ----------------------------------------------------------------------
        page.click("[data-action=spell-add]")
        page.wait_for_selector(".modal [data-cf=q]")
        page.fill(".modal [data-cf=q]", "Magic Missile")
        page.wait_for_timeout(300)
        page.locator(".modal [data-pick='magic-missile-phb']").click()
        page.wait_for_selector(".modal [data-acquisition]")
        page.select_option(".modal [data-acquisition]", "copied")
        page.click(".modal [data-add-save]")
        page.wait_for_selector(".modal [data-add-save]", state="detached")
        check("SP4 Add Spell asks how the spell entered the spellbook; the summary counts it as copied",
              s.wait(lambda: "1 copied" in page.locator("#spellcasting-sources").inner_text()), page.locator("#spellcasting-sources").inner_text()[:300])
        idle = page.locator('[data-sp-section="idle"]')
        check("SP5 a spellbook spell that is not prepared is listed under 'Not prepared' (open while nothing is ready)",
              s.wait(lambda: idle.count() == 1 and "Magic Missile" in idle.inner_text()))
        page.locator('[data-sp-section="idle"] input[data-action=spell-prepare]').first.check()
        check("SP6 ticking Prepared moves it to 'Ready to cast' (1st level)",
              s.wait(lambda: "Magic Missile" in page.locator('[data-sp-section="ready"]').inner_text()))
        page.locator("[data-action=spell-detail][data-spell='magic-missile-phb']").first.click()
        page.wait_for_selector(".modal [data-acq]")
        check("SP7 the spell details show the spellbook record (Copied) and can change it",
              page.locator(".modal [data-acq]").input_value() == "copied")
        page.keyboard.press("Escape")
        page.wait_for_timeout(300)
        # ---- Arcane Recovery ------------------------------------------------------------------------------------------
        page.locator('[data-action=slot-use][data-level="2"]').click()
        s.wait(lambda: "2 / 3 remaining" in page.locator("#slot-tracker").inner_text())
        page.locator('[data-action=slot-use][data-level="1"]').click()
        s.wait(lambda: "3 / 4 remaining" in page.locator("#slot-tracker").inner_text())
        rec = page.locator("[data-action=slot-recover]")
        check("SP8 after spending slots the Arcane Recovery button is enabled (budget 3 slot levels)",
              s.wait(lambda: not rec.is_disabled()) and "3 slot levels" in page.locator("[data-slot-actions]").inner_text())
        rec.click()
        page.wait_for_selector(".modal [data-recover-form]")
        boxes = page.locator(".modal input[name=slot]")
        boxes.nth(0).check()
        boxes.nth(1).check()
        total = page.locator(".modal [data-recover-total]").inner_text()
        page.click(".modal [data-recover-ok]")
        check("SP9 the dialog adds up the chosen levels (3 of 3) and recovers both slots",
              "3 of 3" in total and s.wait(lambda: "2 / 3 remaining" not in page.locator("#slot-tracker").inner_text()
                                             and "3 / 3 remaining" in page.locator("#slot-tracker").inner_text()), total)
        check("SP10 Arcane Recovery is then used (button disabled, 'already used')",
              s.wait(lambda: rec.is_disabled() and "already used" in page.locator("[data-slot-actions]").inner_text()))
        page.screenshot(path=str(SHOTS / "class-spells-wizard.png"), full_page=True)

        # ---- Sorcerer: Flexible Casting --------------------------------------------------------------------------------
        s.open(sor)
        s.tab("spells")
        page.locator("[data-action=slot-convert]").click()
        page.wait_for_selector(".modal [data-flex]")
        check("SP11 Flexible Casting lists slot costs; 'turn a slot into points' is off while the points are full",
              "3 points" in page.locator(".modal").inner_text() and page.locator(".modal input[name=convert]").first.is_disabled())
        page.locator(".modal input[name=create][value='2']").check()
        page.click(".modal [data-flex-create]")
        tmp = page.locator('[data-slot-pool="temporary"]')
        check("SP12 creating a 2nd-level slot spends 3 points and shows a temporary slot with Use",
              s.wait(lambda: tmp.count() == 1 and "1 / 1" in tmp.inner_text()))
        tmp.locator("[data-action=temp-use]").click()
        check("SP13 using the temporary slot: 0 / 1 and Use disabled",
              s.wait(lambda: "0 / 1" in tmp.inner_text() and tmp.locator("[data-action=temp-use]").is_disabled()))
        s.tab("features")
        check("SP14 Draconic Resilience: Sorcerer AC 15 without armor (13 + DEX 2)",
              s.wait(lambda: page.locator('[data-derived="ac"]').first.inner_text().strip() == "15"), page.locator('[data-derived="ac"]').first.inner_text())

        # ---- Cleric: domain spells ---------------------------------------------------------------------------------------
        s.open(cle)
        s.tab("spells")
        ready = page.locator('[data-sp-section="ready"]')
        check("SP15 Life Domain spells are ready to cast and marked Always prepared (Bless, Spiritual Weapon)",
              s.wait(lambda: "Bless" in ready.inner_text() and "Spiritual Weapon" in ready.inner_text() and "Always prepared" in ready.inner_text()),
              ready.inner_text()[:300] if ready.count() else "")
        check("SP16 the Cleric source counts 0 prepared (domain spells are not counted)",
              "Prepared 0 /" in page.locator("#spellcasting-sources").inner_text())

        # ---- Bard: Magical Secrets ---------------------------------------------------------------------------------------
        s.open(bard)
        s.tab("features")
        key = "bard-phb-u10-magical-secrets:bard-magical-secrets-phb-spells"
        s.goto_choice(key)
        sel = s.choice(key).locator("select[name=spell]").first
        check("SP17 Magical Secrets offers spells of any class list up to 5th level (Fireball yes, Disintegrate no)",
              s.wait(lambda: sel.locator("option[value='fireball-phb']").count() == 1)
              and sel.locator("option[value='disintegrate-phb']").count() == 0)
        sel.select_option("fireball-phb")
        s.choice(key).locator("select[name=spell]").nth(1).select_option("hunters-mark-phb")
        s.save(key)
        check("SP18 two Magical Secrets are saved", s.wait(lambda: "Chosen: Fireball, Hunter's Mark" in s.panel.locator(f'[data-cf-choice-wrap="{key}"]').inner_text()),
              s.panel.locator(f'[data-cf-choice-wrap="{key}"]').inner_text()[:200])
        s.tab("spells")
        check("SP19 Magical Secrets appear in the Bard's spells (feature source, ready to cast)",
              s.wait(lambda: "Fireball" in page.locator('[data-sp-section="ready"]').inner_text()))
        check("SP20 no console errors and only local network traffic", not s.errors and not s.remote, (s.errors[:3], s.remote[:3]))
        s.close()

        m = Sheet(browser, u, width=390, height=844, tab="spells")
        m.open(wiz)
        m.tab("spells")
        m.page.wait_for_timeout(800)
        check("SP21 mobile 390 px: the Spells tab has no horizontal overflow", m.overflow() <= 0, m.overflow())
        m.page.locator("[data-action=slot-recover]").focus()
        m.page.screenshot(path=str(SHOTS / "class-spells-mobile.png"), full_page=True)
        m.close()
        browser.close()
    report()


if __name__ == "__main__":
    main()
