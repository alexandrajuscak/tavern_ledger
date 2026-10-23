"""Browser test of resolved proficiencies on the Stats tab (docs/PROFICIENCY_RESOLUTION.md) against the LOCAL stack.

A Wizard 1 / Fighter 1 Mountain Dwarf: class and lineage grants show as active with their source badges without manual rows;
a granted chip explains its source instead of deleting it; inactive chips toggle a manual mark; specific item and language
grants list their sources and only manual marks can be removed; save dots name their sources; 390 px; no errors.
"""
from playwright.sync_api import sync_playwright

from class_ui_common import Sheet, User, call, check, report


def main():
    u = User("profui")
    ch = u.character("Proficiency UI Tester", [("wizard-phb", 1), ("fighter-phb", 1)], strength=14, intelligence=16)
    st, r = u.rpc("set_character_lineage", p_character=ch, p_version="dwarf-phb", p_subversion="dwarf-mountain", p_choices={})
    assert st == 200, (st, r)

    def manual_rows():
        _, rows = call("GET", f"/rest/v1/character_proficiencies?character_id=eq.{ch}&select=group_id,item_id", token=u.jwt)
        return sorted((x["group_id"] or x["item_id"]) for x in rows)

    with sync_playwright() as p:
        browser = p.chromium.launch(channel="msedge", headless=True)
        s = Sheet(browser, u, tab="stats")
        page = s.page
        s.open(ch)
        s.tab("stats")
        chips = page.locator("#prof-chips")
        chip = lambda k: chips.locator(f"[data-k='{k}']")  # noqa: E731
        s.wait(lambda: chip("medium").get_attribute("data-state") == "derived")
        check("PU1 class and lineage grants show as active with source badges (Medium armor: Fighter + Mountain Dwarf), no manual rows",
              chip("light").get_attribute("aria-pressed") == "true" and chip("medium").get_attribute("data-state") == "derived"
              and "Fighter" in chip("medium").inner_text() and "Mountain Dwarf" in chip("medium").inner_text()
              and chip("martial").get_attribute("aria-pressed") == "true" and manual_rows() == [],
              (chips.inner_text(), manual_rows()))
        check("PU2 heavy armor is inactive for a Fighter multiclass (no badge, not pressed)",
              chip("heavy").get_attribute("aria-pressed") == "false" and chip("heavy").get_attribute("data-state") == "off")

        chip("heavy").click()
        check("PU3 an inactive chip becomes a manual mark (badge Manual, one manual row)",
              s.wait(lambda: chip("heavy").get_attribute("data-state") == "manual" and "Manual" in chip("heavy").inner_text()
                     and manual_rows() == ["heavy-armor"]), (chip("heavy").inner_text(), manual_rows()))
        chip("heavy").click()
        check("PU4 clicking the manual chip again removes the mark", s.wait(lambda: chip("heavy").get_attribute("aria-pressed") == "false" and manual_rows() == []))

        chip("light").click()
        dlg = page.locator(".modal").last
        dlg.wait_for(timeout=5000)
        txt = dlg.inner_text()
        check("PU5 a granted chip explains its source instead of switching off (Fighter, class; Open classes)",
              "Fighter" in txt and "cannot be switched off here" in txt and dlg.locator("[data-goto=classes]").count() == 1
              and manual_rows() == [] and chip("light").get_attribute("aria-pressed") == "true", txt)
        dlg.locator("[data-manual=on]").click()
        check("PU6 'Also mark manually' adds a manual mark next to the grant (Fighter + Manual), still active",
              s.wait(lambda: "Manual" in chip("light").inner_text() and manual_rows() == ["light-armor"])
              and chip("light").get_attribute("data-state") == "derived", chip("light").inner_text())
        chip("light").click()
        page.locator(".modal [data-manual=off]").click()
        check("PU7 removing the manual mark keeps the granted proficiency", s.wait(lambda: "Manual" not in chip("light").inner_text() and manual_rows() == [])
              and chip("light").get_attribute("aria-pressed") == "true")

        details = page.locator("#specific-profs")
        check("PU8 lineage item grants (battleaxe) and languages (Dwarvish) list their source and offer no Remove",
              s.wait(lambda: "Battleaxe" in details.inner_text()) and "Mountain Dwarf" in details.locator("[data-prof-item=battleaxe]").inner_text()
              and details.locator("[data-prof-item=battleaxe] [data-action=prof-remove]").count() == 0
              and "Dwarvish" in details.locator("[data-prof-languages]").inner_text(), details.inner_text()[:400])
        u.rpc("set_character_proficiency", p_character=ch, p_group=None, p_item="longsword", p_enabled=True, p_notes=None)
        page.reload()
        s.tab("stats")
        s.wait(lambda: page.locator("#specific-profs [data-prof-item=longsword]").count() == 1)
        details.locator("[data-prof-item=longsword] [data-action=prof-remove]").click()
        check("PU9 a manual item proficiency can be removed from the list (Longsword gone, the battleaxe grant stays)",
              s.wait(lambda: details.locator("[data-prof-item=longsword]").count() == 0) and details.locator("[data-prof-item=battleaxe]").count() == 1)

        title = page.locator("[data-action=toggle-save][data-k=int]").get_attribute("title") or ""
        check("PU10 the save dot names its source (Intelligence: Proficient: Wizard) and STR is not proficient from the multiclass Fighter",
              "Wizard" in title and page.locator("[data-action=toggle-save][data-k=str]").get_attribute("aria-pressed") == "false", title)

        page.set_viewport_size({"width": 390, "height": 844})
        page.wait_for_timeout(500)
        check("PU11 390 px: no horizontal overflow on the Stats tab", s.overflow() <= 0, s.overflow())
        check("PU12 no browser errors and only local network traffic", not s.errors and not s.remote, (s.errors[:3], s.remote[:3]))
        s.close()
        browser.close()
    report()


if __name__ == "__main__":
    main()
