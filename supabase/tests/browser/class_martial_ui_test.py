"""Browser test of the martial phase (Fighter + Champion, Rogue + Thief) on the redesigned class page.

Checks through the UI: overview, Next actions with Choose buttons (keyboard), folded finished choices with Change,
playtest options folded away, quick resource use and rests, subclass picker with source / implementation, level review,
Combat tab (attack count, critical range, Sneak Attack rider), Rogue Expertise with thieves' tools, mobile layout,
local-only network, no console errors.
"""
from playwright.sync_api import sync_playwright

from class_ui_common import SHOTS, Sheet, User, check, report


def main():
    u = User("martial")
    fighter = u.character("Fighter UI Tester", [("fighter-phb", 1)], strength=16, dexterity=14, constitution=14)
    rogue = u.character("Rogue UI Tester", [("rogue-phb", 1)], dexterity=16, intelligence=12)
    SHOTS.mkdir(parents=True, exist_ok=True)
    with sync_playwright() as p:
        browser = p.chromium.launch(channel="msedge", headless=True)
        s = Sheet(browser, u)
        s.open(fighter)
        page, panel = s.page, s.panel
        s.tab("features")
        check("M1 the class page loads with an overview (Fighter 1, character level, proficiency bonus)",
              s.wait(lambda: "Fighter 1" in panel.locator("[data-cf-overview]").inner_text()
                     and "proficiency bonus +2" in panel.locator("[data-cf-overview]").inner_text()), panel.inner_text()[:300])
        acts = panel.locator("[data-cf-actions]")
        check("M2 Next actions lists the two open choices (two skills, fighting style) with buttons",
              acts.locator("[data-cf-goto]").count() == 2 and "Fighting style" in acts.inner_text() and "2 skills" in acts.inner_text(), acts.inner_text())
        style = "fighter-phb-u1-fighting-style:fighter-fighting-style-phb-style"
        skills = "fighter-phb-u1-proficiencies:fighter-proficiencies-phb-skills"
        check("M3 playtest (UA) fighting styles are folded away by default (Mariner is not visible)",
              not s.choice(style).locator("input[value=mariner]").is_visible() and s.choice(style).locator(".cf-playtest").count() == 1)
        # keyboard: Tab to the first Choose button and press Enter -> focus lands inside the choice
        acts.locator("[data-cf-goto]").first.focus()
        page.keyboard.press("Enter")
        page.wait_for_timeout(600)
        focused_key = page.evaluate("() => document.activeElement?.closest('[data-cf-choice-key]')?.dataset.cfChoiceKey")
        check("M4 keyboard: Enter on a Choose button moves focus into that choice", focused_key in (style, skills), focused_key)
        s.choice(style).locator("input[value=archery]").check()
        s.save(style)
        check("M5 saving the fighting style folds it to its result (Chosen: Archery) and Next actions shrinks to one item",
              s.wait(lambda: "Chosen: Archery" in panel.locator(f'[data-cf-choice-wrap="{style}"]').inner_text())
              and panel.locator("[data-cf-actions] [data-cf-goto]").count() == 1)
        s.goto_choice(skills)
        s.choice(skills).locator("input[value=athletics]").check()
        s.choice(skills).locator("input[value=perception]").check()
        s.save(skills)
        check("M6 after the skills: 'All class choices are made.'", s.wait(lambda: "All class choices are made" in panel.inner_text()))
        s.open_change(style)
        s.choice(style).locator("input[value=defense]").check()
        s.save(style)
        check("M7 Change reopens a finished choice; switching Archery -> Defense is saved", s.wait(
            lambda: "Chosen: Defense" in panel.locator(f'[data-cf-choice-wrap="{style}"]').inner_text()),
            (s.toasts(), panel.locator(f'[data-cf-choice-wrap="{style}"]').inner_text()[:200]))
        s.tab("combat")
        glance = page.locator("#combat-states [data-cf-glance]")
        sw = glance.locator('[data-cf-quick$=":fighter-second-wind-phb-uses"]')
        check("M8 At a glance offers Second Wind 1 / 1 with a quick Use button", sw.count() == 1 and "1 / 1" in sw.inner_text())
        sw.locator("[data-cf-action=res-use]").click()
        check("M9 using Second Wind: 0 / 1 and the Use button is disabled",
              s.wait(lambda: "0 / 1" in glance.locator('[data-cf-quick$=":fighter-second-wind-phb-uses"]').inner_text()
                     and glance.locator('[data-cf-quick$=":fighter-second-wind-phb-uses"] [data-cf-action=res-use]').is_disabled()))
        page.locator("[data-action=short-rest]").first.click()
        dlg = page.locator(".modal").last.inner_text()
        page.locator(".modal [data-ok]").last.click()
        page.wait_for_selector(".modal [data-rest-summary]", timeout=15000); page.locator(".modal [data-rest-ok]").last.click(); page.wait_for_selector(".modal [data-rest-summary]", state="detached", timeout=5000)
        check("M10 the short rest dialog names Second Wind; afterwards it is 1 / 1 again",
              "Second Wind" in dlg and s.wait(lambda: "1 / 1" in page.locator('[data-cf-glance] [data-cf-quick$=":fighter-second-wind-phb-uses"]').inner_text()), dlg)

        row = page.eval_on_selector("#class-card-body [data-class-row]", "e => e.dataset.classRow")
        review = s.set_level(row, 3)
        check("M11 raising to Fighter 3 shows the review first (Action Surge, Martial Archetype)",
              "Action Surge" in review and "Martial Archetype" in review, review[:300])
        s.tab("features")
        check("M12 Next actions now asks for the Martial Archetype", s.wait(lambda: "Martial Archetype" in panel.locator("[data-cf-actions]").inner_text()))
        sub = "fighter-phb-u3-martial-archetype:fighter-martial-archetype-phb-archetype"
        s.goto_choice(sub)
        picker = s.choice(sub)
        check("M13 the subclass picker lists the official archetypes with their source and implementation (Champion: features in the app; Battle Master: name only)",
              "Features in the app" in picker.locator("label", has_text="Champion").inner_text()
              and "Name only" in picker.locator("label", has_text="Battle Master").inner_text()
              and not picker.locator("input[value='fighter-echo-knight-egw']").is_visible(), picker.inner_text()[:400])
        picker.locator("input[value='fighter-champion-phb']").check()
        s.save(sub)
        check("M14 Champion chosen: subclass block shows it; Play → Attacks shows the critical range 19-20",
              s.wait(lambda: "Champion" in panel.locator("[data-cf-subclass]").inner_text() and "19–20" in page.locator("#feature-attacks").text_content()))
        s.set_level(row, 5)
        s.tab("combat")
        check("M15 Combat tab: 2 attacks and critical hit on 19-20", s.wait(lambda: "2 attacks" in page.locator("[data-attack-rules]").inner_text()
                                                                          and "19–20" in page.locator("[data-attack-rules]").inner_text()))
        s.tab("features")
        check("M16 old levels are folded unless you opened them (level 2 closed, level 5 open)",
              not panel.locator('details.cf-level[data-cf-level="2"]').evaluate("d => d.open")
              and panel.locator('details.cf-level[data-cf-level="5"]').evaluate("d => d.open"))
        page.screenshot(path=str(SHOTS / "class-martial-fighter.png"), full_page=True)

        # ---- Rogue -----------------------------------------------------------------------------------------------
        s.open(rogue)
        s.tab("features")
        rsk = "rogue-phb-u1-proficiencies:rogue-proficiencies-phb-skills"
        rex = "rogue-phb-u1-expertise:rogue-expertise-phb-expertise"
        s.goto_choice(rsk)
        for k in ("stealth", "perception", "acrobatics", "deception"):
            s.choice(rsk).locator(f"input[value={k}]").check()
        s.save(rsk)
        check("M17 Rogue Expertise offers thieves' tools next to the skills",
              s.wait(lambda: s.choice(rex).locator("input[value=thieves-tools]").count() == 1), s.choice(rex).inner_text()[:300])
        s.choice(rex).locator("input[value=stealth]").check()
        s.choice(rex).locator("input[value=thieves-tools]").check()
        s.save(rex)
        check("M18 Expertise (Stealth, thieves' tools) is saved", s.wait(lambda: "Chosen: Stealth, Thieves' tools" in panel.locator(f'[data-cf-choice-wrap="{rex}"]').inner_text()),
              panel.locator(f'[data-cf-choice-wrap="{rex}"]').inner_text())
        rider = page.locator("#feature-attacks [data-attack-rider='Sneak Attack']")
        check("M19 Play → Attacks shows Sneak Attack 1d6 once per turn with its conditions",
              s.wait(lambda: rider.count() == 1 and "Sneak Attack 1d6" in rider.text_content() and "once per turn" in rider.text_content()))
        s.tab("stats")
        stealth = page.locator('[data-derive="skill:stealth"]').first.inner_text()
        check("M20 Stats: Stealth +7 with expertise (DEX 3 + 2 x PB 2)", stealth.strip() in ("+7", "+7"), stealth)
        s.tab("combat")
        check("M21 Combat tab lists the Sneak Attack rider (extra damage you add yourself)",
              s.wait(lambda: "Sneak Attack 1d6" in page.locator("[data-attack-rider='Sneak Attack']").inner_text()))
        check("M22 no console errors and only local network traffic", not s.errors and not s.remote, (s.errors[:3], s.remote[:3]))
        s.close()

        m = Sheet(browser, u, width=390, height=844)
        m.open(fighter)
        m.tab("features")
        m.page.wait_for_timeout(800)
        check("M23 mobile 390 px: the class page has no horizontal overflow", m.overflow() <= 0, m.overflow())
        m.page.screenshot(path=str(SHOTS / "class-martial-mobile.png"), full_page=True)
        m.close()
        browser.close()
    report()


if __name__ == "__main__":
    main()
