"""Browser test of the player-first redesign (docs/UI_DESIGN_SYSTEM.md, docs/UX_INFORMATION_ARCHITECTURE_AUDIT.md):

typography (readable Inter for text and controls; the Cinzel display face for titles and prominent numbers since 2026-10-22), self-hosted fonts (no Google Fonts
traffic), the six sheet sections (tabs semantics, arrow keys, bottom navigation on phones), the compact header with state
chips, the vitals bar (top-bar readout after scrolling), the home cards (authoritative maximum HP including a feat, state chips),
icons always labelled or hidden from assistive technology, Play (Ready to use, catalog features grouped by timing),
Spells (school icon, readiness chip), Inventory (empty slots folded), Build (Level up / locked state), Wild Shape in the
vitals, DM Space (Needs you first, never shown to a player), reduced motion and no horizontal overflow at 390 px.

A synthetic user (ui-*@example.test, removed by run_browser_local.sh) owns the characters that are changed. The local demo
accounts (scripts/local/seed_local_demo.py) are only read: Strict Wizard (progression locked), Showcase Paladin (spell cards).
The Wild Shape checks use a synthetic Moon Druid the test transforms itself.
Refuses non-local URLs; no remote traffic except the Supabase client library CDN.
"""
import json
import os
import re
from urllib.parse import urlparse

from playwright.sync_api import sync_playwright

from class_ui_common import API, ANON, APP, SHOTS, Sheet, User, call, check, report

DEMO_PW = os.environ.get("DEMO_PASSWORD", "local-dev-password")


def demo_page(browser, email, width=1366, height=900, tab="combat", reduced=False):
    ctx = browser.new_context(viewport={"width": width, "height": height}, reduced_motion="reduce" if reduced else "no-preference")
    ctx.add_init_script(f"localStorage.setItem('tavern-ledger:local-supabase', JSON.stringify({{url: {json.dumps(API)}, key: {json.dumps(ANON)}}}));"
                        f"localStorage.setItem('tavern-ledger:tab', {json.dumps(tab)});")
    page = ctx.new_page()
    errors, fonts = [], []
    page.on("console", lambda m: errors.append(m.text) if m.type == "error" else None)
    page.on("pageerror", lambda e: errors.append(f"pageerror: {e}"))
    ctx.on("request", lambda r: fonts.append(r.url) if urlparse(r.url).hostname.endswith(("googleapis.com", "gstatic.com")) else None)
    page.goto(APP)
    page.fill("input[name=email]", email)
    page.fill("input[name=password]", DEMO_PW)
    page.click("button[value=signin]")
    page.wait_for_selector(".char-card, .empty-state", timeout=20000)
    return ctx, page, errors, fonts


def demo_id(name):
    _, rows = call("GET", f"/rest/v1/characters?name=eq.{name.replace(' ', '%20')}&select=id")
    return rows[0]["id"] if isinstance(rows, list) and rows else None


def wait(page, fn, timeout=15000):
    for _ in range(timeout // 200):
        try:
            if fn():
                return True
        except Exception:
            pass
        page.wait_for_timeout(200)
    return False


def font(page, sel):
    return page.locator(sel).first.evaluate("e => getComputedStyle(e).fontFamily")


def main():
    u = User("uxr")
    hero = u.character("UX Tough Fighter", [("fighter-phb", 4)], strength=16, dexterity=12, constitution=14, hp_max=36, hp_current=30)
    st, r = u.rpc("assign_character_feat", p_character=hero, p_version="tough-2024", p_choices={}, p_source_type="direct",
                  p_source_note=None, p_override_reason=None, p_notes=None)
    assert st == 200, (st, r)
    barb = u.character("UX Barbarian", [("barbarian-phb", 3)], strength=16, constitution=16)
    # the test owns its Wild Shape state (2026-11-08): a synthetic Moon Druid put into Brown Bear form here, so UX19 / UX21
    # never depend on the demo Showcase Druid's current manual form
    druid = u.character("UX Moon Druid", [("druid-phb", 6, "druid-moon-phb")], strength=8, dexterity=14, constitution=14,
                        intelligence=12, wisdom=16, charisma=10, hp_max=45, hp_current=45)
    st, r = u.rpc("start_transformation", p_character=druid, p_creature="brown-bear", p_options={})
    assert st == 200, (st, r)

    with sync_playwright() as p:
        browser = p.chromium.launch(channel="msedge", headless=True)

        # ---- home: authoritative maximum HP (base 36 + Tough 8), readable cards --------------------------------------------
        s = Sheet(browser, u, tab="combat")
        page = s.page
        card = page.locator(f'.char-card[data-char="{hero}"]')
        check("UX1 the home card shows the derived maximum HP including the Tough feat (30 / 44)",
              s.wait(lambda: "30 / 44" in card.inner_text()), card.inner_text() if card.count() else "no card")
        check("UX2 body text, buttons and inputs use Inter; the page title uses the display face",
              font(page, "body").startswith("Inter") and font(page, "#btn-new").startswith("Inter")
              and font(page, ".title").startswith("Cinzel"), (font(page, "body"), font(page, "#btn-new"), font(page, ".title")))

        # ---- sheet: sections, header, typography ---------------------------------------------------------------------------
        s.open(barb)
        tabs = page.locator(".tabs .tab")
        labels = [t.strip() for t in page.locator(".tabs .tab .tab-label").all_inner_texts()]
        check("UX3 six sections in player order: Play, Abilities, Spells, Inventory, Build, Bio",
              labels == ["Play", "Abilities", "Spells", "Inventory", "Build", "Bio"], labels)
        check("UX4 tabs are a WAI-ARIA tablist: aria-controls points at a tabpanel, one selected tab in the tab order",
              all(page.locator(f"#{tabs.nth(i).get_attribute('aria-controls')}[role=tabpanel]").count() == 1 for i in range(tabs.count()))
              and page.locator(".tabs .tab[tabindex='0']").count() == 1)
        page.locator('.tab[data-tab="combat"]').focus()
        page.keyboard.press("ArrowRight")
        check("UX5 ArrowRight moves to Abilities and shows its panel; End jumps to Bio",
              s.wait(lambda: page.locator('.tab[data-tab="stats"]').get_attribute("aria-selected") == "true"
                     and page.locator('[data-panel="stats"]').is_visible()))
        page.keyboard.press("End")
        check("UX5b ... End selects Bio", s.wait(lambda: page.locator('.tab[data-tab="bio"]').get_attribute("aria-selected") == "true"))
        check("UX6 the character name and prominent stats use the medieval display face (2026-10-22 v5); labels and buttons do not",
              font(page, ".char-name").startswith("Cinzel") and font(page, "[data-derived='ac']").startswith("Cinzel")
              and font(page, ".stat-label").startswith("Inter") and font(page, "[data-action=hp-damage]").startswith("Inter"))
        # the subtitle is derived after the class summary arrives (asynchronous): wait for it instead of reading it at once
        check("UX7 the subtitle names the class first (Barbarian 3)", s.wait(lambda: "Barbarian 3" in page.locator(".char-sub").inner_text()),
              page.locator(".char-sub").inner_text())
        # decorative: alt="" (and usually aria-hidden); meaningful: non-empty alt. A missing alt attribute is the error.
        bad = page.evaluate("""() => [...document.querySelectorAll('img')].filter((i) => i.getAttribute('alt') === null).length""")
        check("UX8 every image has alt text, or an empty alt that marks it decorative", bad == 0, bad)

        # ---- Play: Ready to use + catalog features by timing -----------------------------------------------------------------
        s.tab("combat")
        check("UX9 Play shows 'Ready to use' with Rage and its Start button",
              s.wait(lambda: page.locator('#combat-states [data-cf-state="rage"] [data-cf-action=state-start]').count() == 1))
        check("UX10 catalog class features are grouped by timing (Rage is a bonus action on Play)",
              s.wait(lambda: page.locator('.group-bonus_action [data-class-action]', has_text="Rage").count() >= 1),
              page.locator("#combat-groups").inner_text()[:300])
        check("UX11 passive class features are not listed as actions (Unarmored Defense)",
              page.locator("#combat-groups [data-class-action]", has_text="Unarmored Defense").count() == 0)

        # ---- Build: Level up is a normal action for an unlocked, ungoverned character -------------------------------------------
        s.tab("features")
        check("UX12 Build starts with Next steps and an enabled 'Level up' button",
              s.wait(lambda: page.locator("#level-up-slot [data-action=level-up]").is_enabled()
                     and "Level up" in page.locator("#level-up-slot").inner_text()))

        # ---- top bar readout after scrolling ----------------------------------------------------------------------------------
        s.tab("bio")
        page.evaluate("window.scrollTo(0, document.body.scrollHeight)")
        check("UX13 after scrolling past the vitals, the top bar shows HP and AC",
              s.wait(lambda: page.locator("#topbar-vitals").is_visible() and "/" in page.locator("#topbar-vitals").inner_text()))
        s.close()

        # ---- Inventory: empty equipment slots folded ----------------------------------------------------------------------------
        inv = Sheet(browser, u, tab="inventory")
        inv.open(barb)
        inv.wait(lambda: inv.page.locator(".inv-equipment").count() == 1)
        check("UX14 empty equipment slots are folded under 'Empty slots'",
              inv.wait(lambda: inv.page.locator("details.inv-empty-slots").count() == 1
                       and inv.page.locator("details.inv-empty-slots").get_attribute("open") is None))
        check("UX15 no console errors and only local network traffic (sheet)", not inv.errors and not inv.remote, (inv.errors[:3], inv.remote[:3]))
        inv.close()

        # ---- mobile: bottom navigation, no overflow ------------------------------------------------------------------------------
        m = Sheet(browser, u, width=390, height=844, tab="combat")
        m.open(barb)
        nav = m.page.locator("nav.tabs")
        box = nav.bounding_box()
        check("UX16 390 px: the sections are a bottom bar inside the viewport, all six visible",
              box and box["y"] + box["height"] <= 844 + 1 and box["y"] > 700
              and all(m.page.locator(".tabs .tab").nth(i).is_visible() for i in range(6)), box)
        overflow = {}
        for key in ("combat", "stats", "spells", "inventory", "features", "bio"):
            m.tab(key)
            m.page.wait_for_timeout(300)
            overflow[key] = m.overflow()
        check("UX17 390 px: no horizontal overflow in any section", all(v <= 0 for v in overflow.values()), overflow)
        # phones start with the vitals collapsed (2026-10-22 v5); expand them to measure Damage / Heal
        if "compact" in (m.page.locator(".combat-bar").get_attribute("class") or ""):
            m.page.locator(".compact-toggle").click()
            m.page.wait_for_timeout(200)
        sizes = m.page.evaluate("() => [...document.querySelectorAll('.tabs .tab, [data-action=hp-damage], [data-action=hp-heal]')]"
                                ".map((b) => Math.min(b.getBoundingClientRect().width, b.getBoundingClientRect().height))")
        check("UX18 390 px: navigation and HP buttons are at least 44 px touch targets", min(sizes) >= 44, sizes)
        m.page.screenshot(path=str(SHOTS / "ux-mobile-sheet.png"))
        m.close()

        # ---- synthetic druid (owned by the test): Wild Shape on the home card and in the vitals ---------------------------------
        w = Sheet(browser, u, tab="combat")
        w.page.goto(f"{APP}#/")
        check("UX19 home: an active Wild Shape is visible on the card",
              w.wait(lambda: "Wild Shape: Brown Bear" in w.page.locator(f'.char-card[data-char="{druid}"]').inner_text()))
        w.open(druid)
        check("UX21 Wild Shape: the vitals show the form's HP first and the normal HP as protected",
              w.wait(lambda: "is-form" in (w.page.locator("#hp-card").get_attribute("class") or "")
                     and "Brown Bear" in w.page.locator("[data-ws-hp]").inner_text()
                     and "protected" in w.page.locator("[data-ws-hpnote]").inner_text()
                     and "Wild Shape: Brown Bear" in w.page.locator("#sheet-chips").inner_text()))
        w.close()

        # ---- demo player (read only): lock, spell cards, fonts ---------------------------------------------------------------------
        ctx, dp, derr, dfonts = demo_page(browser, "local-player@example.test", tab="features")
        strict, paladin = demo_id("Strict Wizard"), demo_id("Showcase Paladin")
        dp.goto(f"{APP}#/")
        check("UX19b home: a locked character is visible on the card",
              wait(dp, lambda: "Locked" in dp.locator(f'.char-card[data-char="{strict}"]').inner_text()))
        dp.goto(f"{APP}#/c/{strict}")
        dp.locator('.tab[data-tab="features"]').click()
        check("UX20 locked progression: Level up is disabled and says why; the header shows the lock",
              wait(dp, lambda: dp.locator("#level-up-slot [data-level-up-blocked]").is_disabled()
                   and "paused progression" in dp.locator("#level-up-slot").inner_text()
                   and dp.locator("[data-action=level-up]").count() == 0
                   and "Progression locked" in dp.locator("#sheet-chips").inner_text()))
        dp.goto(f"{APP}#/c/{paladin}")
        dp.locator('.tab[data-tab="spells"]').click()
        first = dp.locator(".sp-card").first
        # since the skills / spell-icon fix the primary icon is the school icon only (docs/SPELL_ICON_COVERAGE.md), and it is labelled
        check("UX22 spell cards lead with a labelled primary icon (the school) and keep the school and readiness as text",
              wait(dp, lambda: first.locator("img.sp-icon").count() == 1 and (first.locator("img.sp-icon").get_attribute("alt") or "") != ""
                   and first.locator(".sp-school").inner_text().strip() != "" and first.locator(".sp-ready").inner_text().strip() != ""))
        check("UX23 fonts are self-hosted: no Google Fonts requests", not dfonts, dfonts[:3])
        check("UX24 the player sees no DM Space link", not dp.locator("#dm-link").is_visible())
        check("UX25 no console errors for the demo player", not derr, derr[:3])
        ctx.close()

        # ---- reduced motion -------------------------------------------------------------------------------------------------------
        ctx, rp, _, _ = demo_page(browser, "local-player@example.test", reduced=True)
        rp.goto(f"{APP}#/c/{paladin}")
        wait(rp, lambda: rp.locator(".panel:not([hidden])").count() == 1)
        anim = rp.locator(".panel:not([hidden])").first.evaluate("e => getComputedStyle(e).animationName")
        check("UX26 reduced motion: section panels do not animate", anim == "none", anim)
        ctx.close()

        # ---- DM: Needs you first ----------------------------------------------------------------------------------------------------
        ctx, dmp, dmerr, _ = demo_page(browser, "local-dm@example.test")
        dmp.goto(f"{APP}#/dm")
        check("UX27 DM Overview starts with 'Needs you' before the counters",
              wait(dmp, lambda: dmp.locator(".dm-needs").count() == 1)
              and dmp.evaluate("() => { const n = document.querySelector('.dm-needs'), s = document.querySelector('.dm-stats');"
                               " return !!(n && s && (n.compareDocumentPosition(s) & Node.DOCUMENT_POSITION_FOLLOWING)); }"))
        check("UX28 no console errors in DM Space", not dmerr, dmerr[:3])
        ctx.close()
        browser.close()
    report()


if __name__ == "__main__":
    main()
